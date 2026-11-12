;;; review-author-agent.el --- Ask the agent that wrote the PR -*- lexical-binding: t; -*-
;;; Commentary:
;; Every question asked inside a review goes to the agent that wrote the
;; change when it can be reached, and otherwise to a replacement that is
;; given the author's handoff, a digest of the author's transcript and the
;; transcript itself to search.  The rungs, first match wins:
;;
;;   author             the author's session is open; attach to it
;;   author-resumed     resumable on this machine; resumed at review open
;;   replacement        a fresh agent; with the transcript when reachable
;;
;; Nothing blocks a review: every failure falls to the next rung, and a
;; review without a handoff behaves as before.
;;
;; The author records its own identity while writing the handoff:
;;
;;   emacsclient --eval "(review-author-agent-record $$)"
;;
;; Emacs walks up the process tree from that shell to the agent-shell
;; client process, so it knows which session is the author without the
;; agent having to know its own id.  The published `session' JSON carries
;; only the agent, session id and a hashed machine; paths stay in a local
;; side file under `review-author-agent-state-directory', one per session,
;; shared by every Emacs on this machine (resuming only works here anyway).
;;
;; Opt-in glue: `review-author-agent-mode' installs the hooks and advice.
;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'map)
(require 'json)
(require 'review-session)
(require 'review-handoff)

(declare-function review-conversation--identity "review-conversation" (shell))
(declare-function review-conversation--machine "review-conversation" ())
(declare-function review-conversation--key "review-conversation" (session))
(declare-function syzygy-recall-resume-entry "syzygy-recall" (entry on-finish))
(declare-function syzygy-recall-cancel-resume "syzygy-recall" (token))
(declare-function agent-shell--start "agent-shell")
(declare-function shell-maker-busy "shell-maker")
(declare-function mr-x/quick-ask--track-response "agent-shell-config" (shell))
(defvar agent-shell--state)
(defvar agent-shell--transcript-file)
(defvar shell-maker--config)
(declare-function shell-maker-config-prompt "shell-maker" (config))
(declare-function agent-shell-subscribe-to "agent-shell")
(declare-function agent-shell-unsubscribe "agent-shell")
(defvar agent-shell-preferred-agent-config)
(defvar major-pane-launch-ejected)
(defvar major-pane-prompt-label-on-start)
(defvar mr-x/quick-ask--shell-buffer)
(defvar mr-x/quick-ask--source-buffer)
(defvar review-pane--session)
(defvar review-panel--session)

(defgroup review-author-agent nil "Ask the agent that wrote the change." :group 'review)

(defcustom review-author-agent-quick-ask 'author
  "Who answers Quick Ask inside a review that has an author handoff.
`author' routes it through the author rungs; `fresh' keeps the cheaper
per-project Quick Ask agent."
  :type '(choice (const author) (const fresh)))

(defcustom review-author-agent-digest-model "openrouter/qwen/qwen3.7-flash"
  "OpenCode model for transcript digests.  Pin a concrete, cheap model id."
  :type 'string)

(defcustom review-author-agent-digest-program "opencode"
  "OpenCode executable used for transcript digests."
  :type 'string)

(defcustom review-author-agent-digest-timeout 300
  "Seconds before a digest run is abandoned."
  :type 'integer)

(defcustom review-author-agent-digest-directory
  (expand-file-name "var/review-digests/" user-emacs-directory)
  "Where transcript digests are cached.  Never published."
  :type 'directory)

(defcustom review-author-agent-state-directory "~/.local/state/review-authors/"
  "Where recorded author identities live, one file per session.
Outside `user-emacs-directory' so the main and sandbox daemons share it."
  :type 'directory)

(defvar review-author-agent-digest-function #'review-author-agent--digest-opencode
  "Called with TRANSCRIPT, OUTPUT-FILE and a DONE callback; builds a digest.
DONE takes nil on success or an error string.  Never blocks.")

(defvar review-author-agent--agents (make-hash-table :test #'equal)
  "Review key -> plist describing who answers that review.
Keys: :rung :buffer :owned :reason :token :transcript :cwd :replacement.")

(defvar review-author-agent--digest-span nil
  "Lines (START . END) the running digest should focus on, or nil.")

(defvar-local review-author-agent--prefix nil
  "Function returning text to put before this shell's next prompt, once.")

;;; Identity

(defun review-author-agent--machine-hash ()
  (secure-hash 'sha256 (review-conversation--machine)))

(defun review-author-agent--side-file (sid)
  (expand-file-name (format "%s.eld" (replace-regexp-in-string "[^A-Za-z0-9_.-]" "_" sid))
                    review-author-agent-state-directory))

(defun review-author-agent--client-pid (buffer)
  (with-current-buffer buffer
    (when-let* (((boundp 'agent-shell--state))
                (client (map-elt agent-shell--state :client))
                (process (map-elt client :process))
                ((processp process)))
      (process-id process))))

(defun review-author-agent--ancestors (pid)
  "PID and its ancestors, nearest first, at most 40."
  (let (chain (n 0))
    (while (and pid (> pid 1) (< n 40))
      (push pid chain)
      (setq pid (alist-get 'ppid (process-attributes pid)) n (1+ n)))
    (nreverse chain)))

(defun review-author-agent--agent-buffers ()
  (seq-filter (lambda (b) (and (local-variable-p 'agent-shell--state b)
                               (buffer-local-value 'agent-shell--state b)))
              (buffer-list)))

(defun review-author-agent--buffer-for-pid (pid)
  "The agent-shell buffer whose client process is PID or an ancestor of it."
  (let ((pids (mapcar (lambda (b) (cons (review-author-agent--client-pid b) b))
                      (review-author-agent--agent-buffers))))
    (cl-some (lambda (p) (alist-get p pids)) (review-author-agent--ancestors pid))))

(defun review-author-agent-record (pid &optional pr head notes)
  "Record the agent-shell session that owns shell PID as a change's author.
Run by the authoring agent through emacsclient with its shell's $$.
Write the local side file and return the `session' JSON for the handoff:
agent, session id and a hashed machine, nothing that locates the machine.
With PR (OWNER/REPO#N) and HEAD, also mark the PR opened, or updated when
this session already marked it.  NOTES is the author's decision-notes file,
kept in the side file for a replacement agent."
  (require 'review-conversation)
  (let* ((buffer (or (review-author-agent--buffer-for-pid pid)
                     (error "No agent-shell session owns process %s" pid)))
         (identity (review-conversation--identity buffer))
         (sid (or (plist-get identity :session-id) (error "The session has no id yet")))
         (file (review-author-agent--side-file sid))
         (identity (if (and notes (not (string-empty-p notes)))
                       (plist-put identity :notes (expand-file-name notes))
                     identity)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (let ((print-length nil) (print-level nil))
        (prin1 identity (current-buffer))))
    (when pr
      (review-author-agent-mark
       buffer (if (seq-some (lambda (f) (review-author-agent--marked-p f pr 'opened))
                            (review-author-agent--transcripts-for (plist-get identity :transcript) pr))
                  'updated 'opened)
       pr head))
    (json-encode `((agent . ,(format "%s" (plist-get identity :agent)))
                   (session_id . ,sid)
                   (machine . ,(review-author-agent--machine-hash))))))

(defun review-author-agent--read-side (sid)
  "The recorded identity for session SID on this machine, or nil."
  (when-let* ((file (review-author-agent--side-file sid))
              ((file-readable-p file)))
    (ignore-errors
      (with-temp-buffer (insert-file-contents file) (read (current-buffer))))))

(defun review-author-agent--live (sid)
  "A running agent-shell buffer for session SID, or nil."
  (seq-find (lambda (b)
              (and (equal (map-nested-elt (buffer-local-value 'agent-shell--state b) '(:session :id)) sid)
                   (let ((p (get-buffer-process b))) (or (null p) (process-live-p p)))))
            (review-author-agent--agent-buffers)))

;;; The resolver

(defun review-author-agent--key (session) (review-conversation--key session))

(defun review-author-agent--entry (session)
  (gethash (review-author-agent--key session) review-author-agent--agents))

(defun review-author-agent--set (session &rest props)
  (let ((key (review-author-agent--key session)))
    (puthash key (let ((e (copy-sequence (gethash key review-author-agent--agents))))
                   (cl-loop for (k v) on props by #'cddr do (setq e (plist-put e k v)))
                   e)
             review-author-agent--agents)))

(defun review-author-agent--notify (session)
  (when (eq session review-session--current)
    (review-session--notify session)))

(defun review-author-agent--fallback-rung (entry)
  (if (and (plist-get entry :transcript) (file-readable-p (plist-get entry :transcript)))
      'replacement-transcript 'replacement))

(defun review-author-agent--fall (session reason)
  "Drop SESSION to its replacement rung for REASON and start the digest."
  (let ((entry (review-author-agent--entry session)))
    (review-author-agent--set session :rung (review-author-agent--fallback-rung entry) :reason reason)
    (review-author-agent--digest session)
    (review-author-agent--notify session)))

(defun review-author-agent-prepare (session)
  "Resolve SESSION's author agent once; resume it in the background if needed.
Return the entry, or nil when the review has no usable handoff."
  (let ((entry (review-author-agent--entry session)))
    (if (and entry (or (memq (plist-get entry :rung) '(resuming replacement replacement-transcript))
                       (and (memq (plist-get entry :rung) '(author author-resumed))
                            (buffer-live-p (plist-get entry :buffer)))))
        entry
      (when-let* ((handoff (review-handoff-get session))
                  ((null (plist-get handoff :error))))
        (let* ((sid (plist-get (plist-get handoff :session) :session_id))
               (side (and sid (review-author-agent--read-side sid)))
               (transcript (plist-get side :transcript))
               (live (and sid (review-author-agent--live sid))))
          (review-author-agent--set session :transcript transcript :head (plist-get handoff :head)
                                    :cwd (plist-get side :cwd) :notes (plist-get side :notes)
                                    :buffer nil :owned nil :reason nil)
          (cond
           (live
            (review-author-agent--set session :rung 'author :buffer live)
            (review-author-agent--prime live session 'author))
           ((null sid) (review-author-agent--fall session "no author session recorded"))
           ((null side) (review-author-agent--fall session "author session is not on this machine"))
           ((not (equal (plist-get side :machine) (review-conversation--machine)))
            (review-author-agent--fall session "author session belongs to another machine"))
           (t (review-author-agent--resume session side)))
          (review-author-agent--notify session)
          (review-author-agent--entry session))))))

(defun review-author-agent--resume (session identity)
  "Resume the author's IDENTITY for SESSION without waiting for it."
  (let ((key (review-author-agent--key session)))
    (review-author-agent--set session :rung 'resuming)
    (condition-case err
        (progn
          (unless (fboundp 'syzygy-recall-resume-entry) (require 'syzygy-recall))
          (let ((result
                 (syzygy-recall-resume-entry
                  identity
                  (lambda (result)
                    (let ((entry (gethash key review-author-agent--agents))
                          (buffer (and (eq (alist-get 'ok result) t)
                                       (get-buffer (alist-get 'bufferName result)))))
                      (when (eq (plist-get entry :rung) 'resuming)
                        (if (buffer-live-p buffer)
                            (progn
                              (puthash key (plist-put (plist-put (plist-put (copy-sequence entry) :rung 'author-resumed)
                                                                 :buffer buffer)
                                                      :owned (not (eq (alist-get 'existing result) t)))
                                       review-author-agent--agents)
                              (when (fboundp 'major-pane-exclude-buffer) (major-pane-exclude-buffer buffer))
                              (review-author-agent--prime buffer session 'author-resumed)
                              (review-author-agent--notify session))
                          (review-author-agent--fall
                           session (format "resume failed: %s" (or (alist-get 'error result) "no session"))))))))))
            (review-author-agent--set session :token (alist-get 'operation result))))
      (error (review-author-agent--fall session (format "resume failed: %s" (error-message-string err)))))))

(defun review-author-agent-shell (session)
  "The buffer to ask about SESSION, or nil when no handoff applies.
The author's live or resumed session when ready, else the replacement."
  (when-let* ((entry (review-author-agent-prepare session)))
    (let ((buffer (plist-get entry :buffer)))
      (if (and (memq (plist-get entry :rung) '(author author-resumed)) (buffer-live-p buffer))
          buffer
        (review-author-agent--replacement session)))))

(defun review-author-agent--replacement (session)
  "SESSION's replacement agent, started on first need and shared after."
  (let ((existing (plist-get (review-author-agent--entry session) :replacement)))
    (if (buffer-live-p existing) existing
      (unless (fboundp 'agent-shell--start) (require 'agent-shell))
      ;; The author's own checkout when known: a forge review's directory is
      ;; only wherever Emacs was when it opened.
      (let* ((cwd (plist-get (review-author-agent--entry session) :cwd))
             (default-directory (file-name-as-directory
                                 (cond ((and cwd (file-directory-p cwd)) cwd)
                                       ((review-session-directory session))
                                       (t default-directory))))
             (major-pane-launch-ejected t)
             (major-pane-prompt-label-on-start nil)
             (shell (agent-shell--start :config agent-shell-preferred-agent-config
                                        :new-session t :no-focus t)))
        (unless (buffer-live-p shell) (user-error "Agent did not start"))
        (when (fboundp 'major-pane-exclude-buffer) (major-pane-exclude-buffer shell))
        (review-author-agent--set session :replacement shell)
        (review-author-agent--prime shell session 'replacement)
        shell))))

;;; What the agent is told, once

(defun review-author-agent--prime (buffer session role)
  "Give BUFFER a one-time prefix for its next prompt about SESSION, as ROLE."
  (with-current-buffer buffer
    (setq-local review-author-agent--prefix
                (lambda () (review-author-agent--prefix-text session role)))))

(defun review-author-agent--prefix-text (session role)
  (let* ((entry (review-author-agent--entry session))
         (handoff (review-handoff-get session))
         (title (review-source-title (review-session-source session)))
         (rules "Check claims, including your own earlier ones, against the current code; do not defend them. Do not edit files or post reviews unless asked."))
    (if (memq role '(author author-resumed))
        (format "[Review] Marcos is reviewing the change you authored: %s. The questions that follow come from the review viewer. %s" title rules)
      (let ((digest (review-author-agent--digest-text session))
            (transcript (plist-get entry :transcript)))
        (concat
         (format "[Review] You are a replacement agent answering review questions about %s. You did not write it; its author is unavailable (%s). %s\n"
                 title (or (plist-get entry :reason) "unknown reason") rules)
         "\nAuthor handoff:\n" (or (plist-get handoff :text) "(route only)") "\n"
         (when-let* ((notes (plist-get entry :notes))
                     ((file-readable-p notes))
                     (text (string-trim (with-temp-buffer (insert-file-contents notes) (buffer-string))))
                     ((not (string-empty-p text))))
           (concat "\nThe author's decision notes, written while working:\n" text "\n"))
         (when digest (concat "\nDigest of the author's transcript:\n" digest "\n"))
         (when (and transcript (file-readable-p transcript))
           (let* ((pr (review-author-agent--pr-id session))
                  (files (review-author-agent--transcripts-for transcript pr))
                  (span (review-author-agent--span transcript pr)))
             (concat
              (format "\nThe author's transcript%s: %s. When the handoff and digest do not answer a question, search them (rg -n, then read around the hit) and cite the file and line you relied on. Do not read them whole.\n"
                      (if (cdr files) "s" "") (string-join files ", "))
              (when span
                (format "In %s the change was made in lines %d to %d; `review-mark' lines delimit it.\n"
                        (file-name-nondirectory transcript) (car span) (cdr span)))))))))))

(defun review-author-agent--prompt-args (args)
  "Put a primed shell's one-time prefix before its next prompt."
  (let ((shell (plist-get args :shell-buffer)))
    (if-let* (((buffer-live-p shell))
              (prefix (buffer-local-value 'review-author-agent--prefix shell)))
        (progn
          (with-current-buffer shell (setq review-author-agent--prefix nil))
          (plist-put (copy-sequence args) :prompt
                     (concat (funcall prefix) "\n\n---\n\n" (plist-get args :prompt))))
      args)))

;;; Digest

(defun review-author-agent--digest-file (session)
  (let ((entry (review-author-agent--entry session)))
    (expand-file-name (format "%s/%s.md"
                              (secure-hash 'sha256 (review-author-agent--key session))
                              (or (plist-get entry :head) "unknown"))
                      review-author-agent-digest-directory)))

(defun review-author-agent--digest-text (session)
  (let ((file (review-author-agent--digest-file session)))
    (when (file-readable-p file)
      (with-temp-buffer (insert-file-contents file) (buffer-string)))))

(defun review-author-agent--digest (session)
  "Build SESSION's transcript digest in the background, once per head."
  (let* ((entry (review-author-agent--entry session))
         (transcript (plist-get entry :transcript))
         (file (review-author-agent--digest-file session)))
    (when (and transcript (file-readable-p transcript)
               (not (file-exists-p file)) (not (plist-get entry :digesting)))
      (review-author-agent--set session :digesting t)
      (make-directory (file-name-directory file) t)
      (let ((key (review-author-agent--key session)))
        (let ((review-author-agent--digest-span
               (review-author-agent--span transcript (review-author-agent--pr-id session))))
          (funcall review-author-agent-digest-function transcript file
                 (lambda (err)
                   (let ((e (gethash key review-author-agent--agents)))
                     (puthash key (plist-put (plist-put (copy-sequence e) :digesting nil) :digest-error err)
                              review-author-agent--agents))
                   (when err (message "Review digest failed: %s" err)))))))))

(defconst review-author-agent--digest-prompt
  "Read the agent transcript file %s in this directory. It is the conversation in which an AI agent wrote a code change that is now under review. Write a digest for a reviewer, in Markdown, at most 1500 words, with these sections: '## Tried and abandoned', '## Decisions', '## Doubts the author had', '## What was run'. Each bullet ends with the transcript line it comes from, as (L1234). Leave out file dumps and chatter. Output only the digest.")

(defun review-author-agent--digest-opencode (transcript output done)
  "Digest TRANSCRIPT into OUTPUT through the cheap OpenCode lane; then DONE."
  (let* ((default-directory (file-name-directory transcript))
         (buffer (generate-new-buffer " *review-digest*"))
         (span review-author-agent--digest-span)
         (prompt (concat (format review-author-agent--digest-prompt (file-name-nondirectory transcript))
                         (when span
                           (format " The change itself was made in lines %d to %d (between the review-mark lines); read only that range, and treat anything after it as later review discussion."
                                   (car span) (cdr span))))))
    (condition-case err
        ;; OpenCode reads stdin when it is a pipe; close it or it waits forever.
        (process-send-eof
         (make-process
         :name "review-digest" :buffer buffer :noquery t :connection-type 'pipe
         :stderr (get-buffer-create " *review-digest-stderr*")
         :command (list "timeout" (number-to-string review-author-agent-digest-timeout)
                        review-author-agent-digest-program "run" "-m" review-author-agent-digest-model prompt)
         :sentinel (lambda (process _event)
                     (unless (process-live-p process)
                       (let ((text (with-current-buffer buffer (string-trim (buffer-string)))))
                         (kill-buffer buffer)
                         (if (and (zerop (process-exit-status process)) (> (length text) 200))
                             (progn (with-temp-file output (insert text "\n")) (funcall done nil))
                           (funcall done (format "exit %s, %d chars" (process-exit-status process) (length text)))))))))
      (error (when (buffer-live-p buffer) (kill-buffer buffer)) (funcall done (error-message-string err))))))

;;; Transcript marks
;;
;; Where a PR's story starts and ends inside an agent's session: a divider in
;; the agent-shell buffer and a visible line plus a machine tag in its
;; transcript.  Digests read only the marked span, and every transcript that
;; carries a PR's tag is offered to a replacement, so a resumed author's new
;; transcript file is found too.  A mark made mid-turn waits for the turn to
;; end, so it never lands inside a streamed message.

(defface review-author-agent-mark '((t :inherit shadow))
  "Face of the PR dividers drawn in agent-shell buffers.")

(defconst review-author-agent--mark-regexp
  "<!-- review-mark v1 pr=\\([^ ]+\\) event=\\([a-z]+\\)"
  "A transcript mark; group 1 is the PR (or -), group 2 the event.")

(defconst review-author-agent--mark-labels
  '((started . "work started") (opened . "PR opened") (updated . "PR updated")
    (merged . "PR merged") (closed . "PR closed")))

(defun review-author-agent--mark-text (pr event head note)
  (let ((time (format-time-string "%Y-%m-%d %H:%M")))
    (format "\n\n---\n\n**▸ %s%s**%s (%s)\n<!-- review-mark v1 pr=%s event=%s head=%s time=%s -->\n\n---\n\n"
            (alist-get event review-author-agent--mark-labels)
            (if pr (concat " " pr) "")
            (cond (note (format " %s" note)) (head (format " · %s" (substring head 0 (min 7 (length head))))) (t ""))
            time (or pr "-") event (or head "-") (format-time-string "%FT%T%z"))))

(defun review-author-agent--turn-start (buffer)
  "Start of the line holding the prompt of BUFFER's current turn, or nil."
  (with-current-buffer buffer
    (when-let* ((config (bound-and-true-p shell-maker--config))
                (prompt (ignore-errors (shell-maker-config-prompt config))))
      (save-excursion
        (goto-char (point-max))
        (when (search-backward prompt nil t) (line-beginning-position))))))

(defun review-author-agent--divider (buffer text &optional pos)
  "Draw TEXT as a dim divider at POS in BUFFER, else above its prompt line."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (or pos (point-max)))
      (forward-line 0)
      (let ((ov (make-overlay (point) (point) nil nil nil)))
        (overlay-put ov 'review-author-agent-mark t)
        (overlay-put ov 'before-string
                     (propertize (concat "──── " text " ────\n") 'face 'review-author-agent-mark))))))

(defun review-author-agent--marked-p (transcript pr event)
  "Whether TRANSCRIPT already carries PR's EVENT mark."
  (and transcript (file-readable-p transcript)
       (with-temp-buffer
         (insert-file-contents transcript)
         (search-forward (format "pr=%s event=%s " pr event) nil t))))

(defun review-author-agent--insert-before-turn (buffer transcript pr event head note)
  "Mark EVENT before BUFFER's current turn, in its transcript and buffer.
The transcript is rewritten with the mark above the turn's last user
heading; agent-shell only appends, so its later writes land after."
  (let ((text (review-author-agent--mark-text pr event head note))
        (label (concat "▸ " (alist-get event review-author-agent--mark-labels)
                       (if pr (concat " " pr) "") (if note (concat " " note) ""))))
    (when (and transcript (file-writable-p transcript))
      (with-temp-buffer
        (insert-file-contents transcript)
        (goto-char (point-max))
        (if (re-search-backward "^## User" nil t)
            (insert (string-trim-left text) "\n")
          (goto-char (point-max)) (insert text))
        (write-region nil nil transcript nil 'no-message)))
    (review-author-agent--divider buffer label (review-author-agent--turn-start buffer))))

(defun review-author-agent--write-mark (buffer transcript pr event head note)
  (let ((text (review-author-agent--mark-text pr event head note)))
    (when (and transcript (file-writable-p transcript))
      (write-region text nil transcript t 'no-message))
    (when (buffer-live-p buffer)
      (review-author-agent--divider
       buffer (concat "▸ " (alist-get event review-author-agent--mark-labels)
                      (if pr (concat " " pr) "")
                      (if note (concat " " note) ""))))))

(defun review-author-agent--turn-active-p (buffer)
  "Whether BUFFER's agent is in a turn: a prompt request is in flight.
A prompt sent without shell-maker never sets its busy flag, so the
request list is the signal; shell-maker's flag is kept as well."
  (with-current-buffer buffer
    (or (seq-some (lambda (r) (equal (map-elt r :method) "session/prompt"))
                  (and (boundp 'agent-shell--state) (map-elt agent-shell--state :active-requests)))
        (and (fboundp 'shell-maker-busy) (ignore-errors (shell-maker-busy))))))

(defun review-author-agent-mark (buffer event &optional pr head note transcript)
  "Mark EVENT for PR in agent-shell BUFFER and its transcript.
EVENT is started, opened, updated, merged or closed.  Without a live
BUFFER, only TRANSCRIPT is written.  A busy BUFFER is marked when its
turn completes."
  (let ((transcript (or transcript
                        (and (buffer-live-p buffer)
                             (buffer-local-value 'agent-shell--transcript-file buffer)))))
    (cond
     ;; Work starts with the turn that asked for it: mark above that turn.
     ((and (eq event 'started) (buffer-live-p buffer) (review-author-agent--turn-active-p buffer))
      (review-author-agent--insert-before-turn buffer transcript pr event head note)
      'written)
     ((and (buffer-live-p buffer) (fboundp 'agent-shell-subscribe-to)
           (review-author-agent--turn-active-p buffer))
      (let (token)
          (setq token (agent-shell-subscribe-to
                       :shell-buffer buffer :event 'turn-complete
                       :on-event (lambda (_event)
                                   (agent-shell-unsubscribe :subscription token)
                                   (review-author-agent--write-mark buffer transcript pr event head note))))
        'queued))
     (t (review-author-agent--write-mark buffer transcript pr event head note)
        'written))))

(defun review-author-agent-mark-start (pid &optional title)
  "Mark that the agent owning shell PID starts feature work, called TITLE.
Run by the authoring agent through emacsclient with its shell's $$."
  (let ((buffer (or (review-author-agent--buffer-for-pid pid)
                    (error "No agent-shell session owns process %s" pid))))
    (format "%s" (review-author-agent-mark buffer 'started nil nil (and title (format "\"%s\"" title))))))

(defun review-author-agent--transcripts-for (transcript pr)
  "TRANSCRIPT plus every transcript beside it that carries PR's marks."
  (let* ((dir (and transcript (file-name-directory transcript)))
         (needle (format "pr=%s event=" pr))
         (tagged (and dir pr (file-directory-p dir)
                      (seq-filter (lambda (f)
                                    (with-temp-buffer
                                      (insert-file-contents f)
                                      (search-forward needle nil t)))
                                  (directory-files dir t "\\.md\\'")))))
    (delete-dups (delq nil (cons (and transcript (file-readable-p transcript) transcript) tagged)))))

(defun review-author-agent--span (transcript pr)
  "Lines (START . END) of TRANSCRIPT where PR was authored, or nil.
From the last `started' mark before PR's first opened mark (else line 1)
to PR's last opened or updated mark."
  (when (and pr transcript (file-readable-p transcript))
    (with-temp-buffer
      (insert-file-contents transcript)
      (let (start first-open last-open last-started)
        (goto-char (point-min))
        (while (re-search-forward review-author-agent--mark-regexp nil t)
          (let ((mpr (match-string 1)) (event (intern (match-string 2))) (line (line-number-at-pos)))
            (cond ((eq event 'started) (unless first-open (setq last-started line)))
                  ((and (equal mpr pr) (memq event '(opened updated)))
                   (unless first-open (setq first-open line start last-started))
                   (setq last-open line)))))
        (when first-open (cons (or start 1) last-open))))))

(defun review-author-agent--pr-id (session)
  "SESSION's PR as OWNER/REPO#N, or nil for a review of a git range."
  (let ((recipe (review-source-recipe (review-session-source session))))
    (when-let* ((number (plist-get recipe :number))
                (owner (plist-get recipe :owner))
                (repo (or (plist-get recipe :repo) (plist-get recipe :name))))
      (format "%s/%s#%s" owner repo number))))

(defun review-author-agent-pr-state (session state)
  "Mark the author's session once when SESSION's PR reaches STATE.
STATE is the readiness state; only `merged' and `closed' are marked."
  (when-let* (((memq state '(merged closed)))
              (pr (review-author-agent--pr-id session))
              (handoff (review-handoff-get session))
              (sid (plist-get (plist-get handoff :session) :session_id))
              (side (review-author-agent--read-side sid))
              (transcript (plist-get side :transcript))
              ((not (review-author-agent--marked-p transcript pr state))))
    (review-author-agent-mark (review-author-agent--live sid) state pr (plist-get handoff :head) nil transcript)))

;;; Labels

(defun review-author-agent-label (session &optional buffer)
  "Who answers SESSION's questions, for headers and footers; nil without a handoff.
With BUFFER, label that buffer's role, or nil when it is not one of ours."
  (when-let* ((entry (review-author-agent--entry session)))
    (let ((rung (plist-get entry :rung)))
      (cond
       ((and buffer (eq buffer (plist-get entry :buffer)))
        (if (eq rung 'author-resumed) "author (resumed)" "author"))
       ((and buffer (eq buffer (plist-get entry :replacement)))
        (if (eq (review-author-agent--fallback-rung entry) 'replacement-transcript)
            "replacement + transcript" "replacement"))
       (buffer nil)
       (t (pcase rung
            ('author "author") ('author-resumed "author (resumed)")
            ('resuming "replacement (author resuming)")
            ('replacement-transcript "replacement + transcript")
            (_ "replacement")))))))

(defun review-author-agent--bar (session)
  (when-let* ((label (review-author-agent-label session)))
    (let ((reason (plist-get (review-author-agent--entry session) :reason)))
      (review-panel--txt (concat "ASK " label (if (and reason (string-prefix-p "replacement" label))
                                                  (format " (%s)" reason) ""))
                         'purple :faded t :height 0.92))))

;;; Quick Ask

(defun review-author-agent--quick-ask-session ()
  (let ((source (bound-and-true-p mr-x/quick-ask--source-buffer)))
    (when (buffer-live-p source)
      (with-current-buffer source
        (let ((s (or (bound-and-true-p review-pane--session) (bound-and-true-p review-panel--session))))
          (and s (eq s review-session--current) s))))))

(defun review-author-agent--quick-ask-ensure (orig &rest args)
  "Send a review's Quick Ask to its author rung, else as before."
  (let* ((session (and (eq review-author-agent-quick-ask 'author) (review-author-agent--quick-ask-session)))
         (shell (and session (review-author-agent-shell session))))
    (if (and shell (not (with-current-buffer shell
                          (and (fboundp 'shell-maker-busy) (ignore-errors (shell-maker-busy))))))
        (progn
          (setq mr-x/quick-ask--shell-buffer shell)
          (when (fboundp 'mr-x/quick-ask--track-response) (mr-x/quick-ask--track-response shell))
          shell)
      (apply orig args))))

(defun review-author-agent--ours-p (buffer)
  (let (found)
    (maphash (lambda (_k e) (when (memq buffer (list (plist-get e :buffer) (plist-get e :replacement)))
                              (setq found t)))
             review-author-agent--agents)
    found))

(defun review-author-agent--quick-ask-reset (orig &rest args)
  "Never let a Quick Ask reset kill an author or replacement session."
  (if (and (boundp 'mr-x/quick-ask--shell-buffer)
           (review-author-agent--ours-p mr-x/quick-ask--shell-buffer))
      (progn (setq mr-x/quick-ask--shell-buffer nil)
             (message "Quick Ask detached from the review agent; it keeps running"))
    (apply orig args)))

(defun review-author-agent--quick-ask-label (label)
  (if-let* ((session (review-author-agent--quick-ask-session))
            ((eq review-author-agent-quick-ask 'author))
            (who (review-author-agent-label session)))
      (concat label " · " who)
    label))

;;; Quit

(defun review-author-agent--owned (session)
  (let ((entry (review-author-agent--entry session)))
    (seq-filter #'buffer-live-p
                (list (and (plist-get entry :owned) (plist-get entry :buffer))
                      (plist-get entry :replacement)))))

(defun review-author-agent--quit-query (session)
  "On an interactive quit, offer to kill the agents this review started."
  (when-let* ((owned (review-author-agent--owned session)))
    (when (y-or-n-p (format "Kill the agent session%s this review started for %s? "
                            (if (cdr owned) "s" "")
                            (review-source-title (review-session-source session))))
      (dolist (b owned)
        (let ((kill-buffer-query-functions nil)) (kill-buffer b)))
      (remhash (review-author-agent--key session) review-author-agent--agents)))
  t)

(defun review-author-agent--closed (session)
  (when-let* ((entry (review-author-agent--entry session))
              (token (plist-get entry :token)))
    (when (and (eq (plist-get entry :rung) 'resuming) (fboundp 'syzygy-recall-cancel-resume))
      (syzygy-recall-cancel-resume token))))

;;; Mode

(defun review-author-agent--collected (session handoff)
  "Re-resolve on a fresh handoff unless the author is already reached for it.
A status refresh of the same head keeps a live, resumed or resuming author;
a fallback answer is checked again, since the handoff may now name a session.
The replacement agent, if any, is kept either way."
  (let ((entry (review-author-agent--entry session)))
    (when (and entry
               (not (and (equal (plist-get entry :head) (plist-get handoff :head))
                         (or (eq (plist-get entry :rung) 'resuming)
                             (and (memq (plist-get entry :rung) '(author author-resumed))
                                  (buffer-live-p (plist-get entry :buffer)))))))
      (review-author-agent--set session :rung nil)))
  (review-author-agent-prepare session))

(defun review-author-agent--displayed (session)
  (when session (review-author-agent-prepare session)))

(define-minor-mode review-author-agent-mode
  "Route review questions to the agent that wrote the change."
  :global t :group 'review-author-agent
  (if review-author-agent-mode
      (progn
        (add-hook 'review-handoff-collected-functions #'review-author-agent--collected)
        (add-hook 'review-session-display-hook #'review-author-agent--displayed)
        (add-hook 'review-session-quit-query-functions #'review-author-agent--quit-query)
        (add-hook 'review-session-quit-functions #'review-author-agent--closed)
        (add-hook 'review-panel-bar-functions #'review-author-agent--bar)
        (advice-add 'agent-shell--send-command :filter-args #'review-author-agent--prompt-args)
        (advice-add 'mr-x/quick-ask--ensure-session :around #'review-author-agent--quick-ask-ensure)
        (advice-add 'mr-x/quick-ask--reset-session :around #'review-author-agent--quick-ask-reset)
        (advice-add 'mr-x/quick-ask--context-label :filter-return #'review-author-agent--quick-ask-label))
    (remove-hook 'review-handoff-collected-functions #'review-author-agent--collected)
    (remove-hook 'review-session-display-hook #'review-author-agent--displayed)
    (remove-hook 'review-session-quit-query-functions #'review-author-agent--quit-query)
    (remove-hook 'review-session-quit-functions #'review-author-agent--closed)
    (remove-hook 'review-panel-bar-functions #'review-author-agent--bar)
    (advice-remove 'agent-shell--send-command #'review-author-agent--prompt-args)
    (advice-remove 'mr-x/quick-ask--ensure-session #'review-author-agent--quick-ask-ensure)
    (advice-remove 'mr-x/quick-ask--reset-session #'review-author-agent--quick-ask-reset)
    (advice-remove 'mr-x/quick-ask--context-label #'review-author-agent--quick-ask-label)))

(provide 'review-author-agent)
;;; review-author-agent.el ends here
