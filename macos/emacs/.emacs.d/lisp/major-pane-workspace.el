;;; major-pane-workspace.el --- Snapshot the open agent convos, resume them later -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Emacs dies (restart, crash, sleep-wake wedge) and the six agent-shell
;; conversations that were open are gone.  Their transcripts survive
;; and `agent-recall-resume' can bring any one back, but nothing
;; remembers WHICH ones were open, so you fish through the full
;; transcript list by memory.  This module keeps that list.
;;
;; - A snapshot is the ordered list of major-pane convos with their
;;   session id, cwd, agent, label and anchored flag.  It is written to
;;   `major-pane-workspace-file' on workspace changes and from
;;   `kill-emacs-hook', so crashes are covered, not only clean exits.
;; - The file holds a short history: one snapshot per Emacs process,
;;   newest first, capped at `major-pane-workspace-history-size'.  The
;;   current process keeps rewriting its own head entry; a new entry is
;;   pushed only on the first save after startup.  Restarts are the
;;   boundaries, so the set from two restarts ago is still there.
;; - `major-pane-workspace-resume' (SPC c / w) lists the convos of the
;;   previous process's snapshot the same way `agent-recall-browse'
;;   lists transcripts: rows carry the transcript path and the
;;   `agent-recall-transcript' category, so RET opens the transcript
;;   read-only and embark `r' (s-r r) resumes the session, picker
;;   staying open.  Convos already open are marked and `r' just switches
;;   to them.  The first row resumes every closed convo in tab order.
;;   With a prefix argument, pick an older snapshot first.  Without
;;   agent-recall (or for an unindexed session) RET resumes directly
;;   through `agent-shell-bookmark--resume'.
;;
;; NOTE: loaded from agent-shell-config.el, so this file must NOT
;; hard-require agent-shell (Elpaca hasn't activated packages yet in
;; batch mode).  agent-shell symbols resolve at runtime.

;;; Code:

(require 'cl-lib)
(require 'map)
(require 'major-pane)

(defvar agent-shell--state)
(defvar agent-recall--index)
(declare-function agent-shell-bookmark--resume "agent-shell-bookmark"
                  (session-id project-path agent-identifier))
(declare-function agent-recall--index-ensure "agent-recall")
(declare-function agent-recall--open-transcript "agent-recall"
                  (file &optional other-window line force-mode))
(declare-function agent-recall--setup-embark "agent-recall")
(declare-function agent-recall--index-entry-for-file "agent-recall" (file))
(declare-function agent-recall--provider-icon "agent-recall" (file entry))
(declare-function agent-recall--display-timestamp "agent-recall" (ts))
(declare-function agent-recall--make-candidate "agent-recall"
                  (display file &optional line kind))
(declare-function agent-recall--disambiguate-candidates "agent-recall" (candidates))
(declare-function agent-recall--read-browse-candidate "agent-recall" (candidates))

(defgroup major-pane-workspace nil
  "Snapshot and resume the set of open agent-shell conversations."
  :group 'major-pane)

(defcustom major-pane-workspace-file nil
  "File holding the snapshot history.
nil means `major-pane/workspace.el' under no-littering's var directory
(or `user-emacs-directory' without no-littering), resolved at call time
because this module loads before no-littering on a fresh boot."
  :type '(choice (const :tag "Under no-littering var" nil) file))

(defvar no-littering-var-directory)

(defun major-pane-workspace--file ()
  "Return the snapshot file path, resolving the no-littering default late."
  (or major-pane-workspace-file
      (expand-file-name "major-pane/workspace.el"
                        (if (boundp 'no-littering-var-directory)
                            no-littering-var-directory
                          user-emacs-directory))))

(defcustom major-pane-workspace-history-size 5
  "How many snapshots (one per Emacs process) to keep."
  :type 'integer)

(defvar major-pane-workspace--boot nil
  "Start timestamp of this Emacs process once it owns a snapshot entry.
nil until the first save; afterwards saves replace the entry whose
`:started' matches this value instead of pushing a new one.")

(defvar major-pane-workspace--last-written nil
  "Convo list from the last write, to skip unchanged event batches.")

;;; Collect

(defun major-pane-workspace--buffer-session-id (buffer)
  "Return BUFFER's ACP session id, or nil when it has none yet."
  (let ((state (buffer-local-value 'agent-shell--state buffer)))
    (and state (map-nested-elt state '(:session :id)))))

(defun major-pane-workspace--index-transcript (session-id)
  "Transcript file agent-recall's index holds for SESSION-ID, or nil."
  (when (and (boundp 'agent-recall--index) (hash-table-p agent-recall--index))
    (catch 'found
      (maphash (lambda (file entry)
                 (when (equal (plist-get entry :session-id) session-id)
                   (throw 'found file)))
               agent-recall--index)
      nil)))

(defun major-pane-workspace--entry (buffer)
  "Build the snapshot entry for BUFFER, or nil without a session id."
  (when-let ((sid (major-pane-workspace--buffer-session-id buffer)))
    (let ((state (buffer-local-value 'agent-shell--state buffer)))
      (list :session-id sid
            :cwd (expand-file-name (buffer-local-value 'default-directory buffer))
            :agent (map-nested-elt state '(:agent-config :identifier))
            :membership (if (eq (buffer-local-value 'major-pane--excluded buffer) 'ejected)
                            'ejected 'pane)
            :label (gethash buffer major-pane--labels)
            :anchored (and (memq buffer major-pane--anchored) t)
            :buffer-name (buffer-name buffer)
            :transcript (major-pane-workspace--index-transcript sid)))))

(defun major-pane-workspace--collect ()
  "Collect pane tabs followed by ejected user conversations."
  (let ((buffers (append (major-pane--ordered-convos)
                         (cl-remove-if-not
                          (lambda (b)
                            (and (local-variable-p 'agent-shell--state b)
                                 (eq (buffer-local-value 'major-pane--excluded b) 'ejected)))
                          (buffer-list)))))
    (let (seen entries)
      (dolist (buffer (cl-remove-if-not #'buffer-live-p (delete-dups buffers)))
        (when-let ((entry (major-pane-workspace--entry buffer)))
          (let ((key (cons (format "%s" (plist-get entry :agent)) (plist-get entry :session-id))))
            (unless (member key seen)
              (push key seen)
              (push entry entries)))))
      (nreverse entries))))

;;; File

(defun major-pane-workspace--read ()
  "Return the snapshot list from `major-pane-workspace--file', newest first."
  (when (file-exists-p (major-pane-workspace--file))
    (condition-case err
        (with-temp-buffer
          (insert-file-contents (major-pane-workspace--file))
          (let ((data (read (current-buffer))))
            (and (listp data) data)))
      (error
       (message "major-pane-workspace: unreadable %s: %s"
                (major-pane-workspace--file) (error-message-string err))
       nil))))

(defun major-pane-workspace--write (snapshots)
  "Write SNAPSHOTS to `major-pane-workspace--file' atomically."
  (let* ((file (major-pane-workspace--file))
         (dir (file-name-directory file)))
    (unless (file-directory-p dir) (make-directory dir t))
    (let ((temp (make-temp-file (expand-file-name ".workspace-" dir))))
      (with-temp-file temp
        (insert ";; major-pane workspace snapshots -*- no-byte-compile: t -*-\n")
        (let ((print-level nil) (print-length nil))
          (pp snapshots (current-buffer))))
      (rename-file temp file t))))

(defun major-pane-workspace--now ()
  "Timestamp string used for snapshot keys."
  (format-time-string "%F %T"))

(defun major-pane-workspace--save-history (convos)
  "Write the current convo set into this process's snapshot entry.
The first call of a process pushes a new entry (unless the pane is
empty, in which case nothing is written); later calls replace it."
  (progn
    (when (or convos major-pane-workspace--boot)
      (unless major-pane-workspace--boot
        (setq major-pane-workspace--boot (major-pane-workspace--now)))
      (let* ((old (cl-remove-if
                   (lambda (s) (equal (plist-get s :started)
                                      major-pane-workspace--boot))
                   (major-pane-workspace--read)))
             (head (list :started major-pane-workspace--boot
                         :saved (major-pane-workspace--now)
                         :convos convos))
             (snaps (cons head old)))
        (major-pane-workspace--write
         (seq-take snaps major-pane-workspace-history-size))
        (setq major-pane-workspace--last-written convos)))))

(defun major-pane-workspace-save ()
  "Save the current workspace and matching frame capture together."
  (interactive)
  (major-pane-workspace--flush))

(defun major-pane-workspace--save-if-changed ()
  "Compatibility entry point for an explicit workspace flush."
  (major-pane-workspace--flush))

;;; Resume

(defun major-pane-workspace--live-buffer (session-id &optional agent)
  "Return the live agent-shell buffer attached to SESSION-ID, or nil."
  (cl-find-if (lambda (buf)
                (and (local-variable-p 'agent-shell--state buf)
                     (or (null agent)
                         (equal (format "%s" agent)
                                (format "%s" (map-nested-elt (buffer-local-value 'agent-shell--state buf) '(:agent-config :identifier)))))
                     (equal (major-pane-workspace--buffer-session-id buf)
                            session-id)))
              (buffer-list)))

(defun major-pane-workspace--resume-entry (entry)
  "Resume ENTRY with exact identity checking, then restore its presentation."
  (require 'syzygy-recall)
  (syzygy-recall-resume-entry
   entry
   (lambda (result)
     (if (not (eq (alist-get 'ok result) t))
         (message "Workspace resume failed: %s" (alist-get 'error result))
       (let ((buffer (get-buffer (alist-get 'bufferName result))))
         (major-pane-set-buffer-label buffer (plist-get entry :label))
         (with-current-buffer buffer
           (setq-local major-pane--excluded
                       (and (eq (plist-get entry :membership) 'ejected) 'ejected)))
         (unless (eq (plist-get entry :membership) 'ejected)
           (major-pane--register-conversation buffer)
           (when (plist-get entry :anchored)
             (setq major-pane--anchored (append (delq buffer major-pane--anchored) (list buffer)))))
         (pop-to-buffer buffer)
         (major-pane-workspace-request-save))))))

(defun major-pane-workspace--transcript-file (entry)
  "Transcript path for ENTRY: the snapshot's, else agent-recall's index now.
The index lookup covers sessions indexed after the snapshot was taken."
  (let ((file (plist-get entry :transcript)))
    (cond ((and file (file-exists-p file)) file)
          ((fboundp 'agent-recall--index-ensure)
           (agent-recall--index-ensure)
           (major-pane-workspace--index-transcript (plist-get entry :session-id)))
          (t (major-pane-workspace--index-transcript
              (plist-get entry :session-id))))))

(defun major-pane-workspace--select-entry (entry)
  "RET on ENTRY: open its transcript like agent-recall browse, else resume."
  (let ((file (major-pane-workspace--transcript-file entry)))
    (if (and file (fboundp 'agent-recall--open-transcript))
        (agent-recall--open-transcript file)
      (major-pane-workspace--resume-entry entry))))

(defun major-pane-workspace--entry-title (entry)
  "Label of ENTRY, falling back to the project directory name."
  (or (plist-get entry :label)
      (file-name-nondirectory
       (directory-file-name (or (plist-get entry :cwd) "")))))

(defun major-pane-workspace--agent-recall-rows-p ()
  "Non-nil when agent-recall's browse row helpers can be used.
The index must be loaded too: agent-recall gets pulled in lazily by
buffer hooks with `agent-recall--index' still nil, and
`agent-recall--index-entry-for-file' errors on a nil index."
  (and (fboundp 'agent-recall--index-entry-for-file)
       (fboundp 'agent-recall--provider-icon)
       (fboundp 'agent-recall--display-timestamp)
       (fboundp 'agent-recall--make-candidate)
       (boundp 'agent-recall--index)
       (hash-table-p agent-recall--index)))

(defun major-pane-workspace--open-marker (entry)
  "Return the open marker when ENTRY's session has a live buffer, else \"\"."
  (if (major-pane-workspace--live-buffer (plist-get entry :session-id))
      (propertize "  (open)" 'face 'success)
    ""))

(defun major-pane-workspace--browse-display (entry file)
  "Row text for ENTRY in `agent-recall-browse' style.
Same recipe as `agent-recall--list-transcripts': provider icon,
[project], dim timestamp, label — plus the open marker.  FILE is the
transcript the row stands for."
  (let* ((index (agent-recall--index-entry-for-file file))
         (project (or (plist-get index :project)
                      (file-name-nondirectory
                       (directory-file-name (or (plist-get entry :cwd) "")))))
         (label (plist-get entry :label)))
    (concat (agent-recall--provider-icon file index)
            (format "[%s] " project)
            (propertize (or (agent-recall--display-timestamp
                             (plist-get index :timestamp))
                            "")
                        'face 'shadow)
            (if label
                (concat "  " (propertize label 'face 'agent-recall-label))
              "")
            (major-pane-workspace--open-marker entry))))

(defun major-pane-workspace--plain-display (entry)
  "Row text for ENTRY without agent-recall: label, [project] agent, marker."
  (let* ((cwd (or (plist-get entry :cwd) ""))
         (project (file-name-nondirectory (directory-file-name cwd))))
    (concat (major-pane-workspace--entry-title entry)
            "  "
            (propertize (format "[%s] %s" project (or (plist-get entry :agent) "?"))
                        'face 'shadow)
            (major-pane-workspace--open-marker entry))))

(defun major-pane-workspace--make-row (display file)
  "Attach the transcript FILE payload to DISPLAY like agent-recall does,
so its embark actions (o/r/R) and preview act on the row."
  (if (fboundp 'agent-recall--make-candidate)
      (agent-recall--make-candidate display file nil 'browse)
    (propertize display 'agent-recall-file file)))

(defun major-pane-workspace--candidates (snapshot)
  "Picker rows for SNAPSHOT: (CANDIDATE . ENTRY), in snapshot order.
Rows are built with agent-recall's browse recipe when it is loaded."
  ;; Load the index up front so rows whose transcript is already on
  ;; record take the browse path; `major-pane-workspace--transcript-file'
  ;; only ensures it when it has to look the transcript up itself.
  (when (fboundp 'agent-recall--index-ensure)
    (agent-recall--index-ensure))
  (let* ((entries (plist-get snapshot :convos))
         (rows (mapcar
                (lambda (entry)
                  (let ((file (major-pane-workspace--transcript-file entry)))
                    (major-pane-workspace--make-row
                     (if (and file (major-pane-workspace--agent-recall-rows-p))
                         (major-pane-workspace--browse-display entry file)
                       (major-pane-workspace--plain-display entry))
                     file)))
                entries)))
    (when (fboundp 'agent-recall--disambiguate-candidates)
      (setq rows (agent-recall--disambiguate-candidates rows)))
    (cl-mapcar #'cons rows entries)))

(defun major-pane-workspace--default-snapshot (snapshots)
  "The snapshot to offer by default: the newest one not written by this
process, so right after a restart the previous set is what you see.
Falls back to this process's own entry when nothing older exists."
  (or (cl-find-if-not (lambda (s) (equal (plist-get s :started)
                                         major-pane-workspace--boot))
                      snapshots)
      (car snapshots)))

(defun major-pane-workspace--read-choice (candidates snapshot)
  "Pick one of CANDIDATES (rows of SNAPSHOT) and return it.
Goes through agent-recall's browse reader (consult, live transcript
preview, embark) when available, else a plain `completing-read' with
the same category."
  (if (fboundp 'agent-recall--read-browse-candidate)
      (agent-recall--read-browse-candidate candidates)
    (completing-read
     (format "Convo (%s): " (plist-get snapshot :started))
     (lambda (string pred action)
       (if (eq action 'metadata)
           '(metadata (category . agent-recall-transcript)
                      (display-sort-function . identity)
                      (cycle-sort-function . identity))
         (complete-with-action action candidates string pred)))
     nil t)))

(defun major-pane-workspace--snapshot-title (snapshot)
  "One-line description of SNAPSHOT for the history picker."
  (format "%s  %d convo(s), last saved %s"
          (plist-get snapshot :started)
          (length (plist-get snapshot :convos))
          (plist-get snapshot :saved)))

(defun major-pane-workspace--pick-snapshot (snapshots)
  "Let the user choose one of SNAPSHOTS by start time."
  (let* ((rows (mapcar (lambda (s) (cons (major-pane-workspace--snapshot-title s) s))
                       snapshots))
         (choice (completing-read "Workspace from: " (mapcar #'car rows) nil t)))
    (cdr (assoc choice rows))))

;;;###autoload
(defun major-pane-workspace-resume (&optional older)
  "List the convos of the last snapshot, agent-recall browse style.
RET opens the transcript read-only; embark `r' resumes the session
(open ones are switched to).  The first row resumes every closed convo
of the snapshot in tab order.  With prefix OLDER, choose which snapshot
(this Emacs, the previous one, ...) to pick from."
  (interactive "P")
  (when (fboundp 'agent-recall--setup-embark)
    (agent-recall--setup-embark))
  (let* ((snapshots (major-pane-workspace--read))
         (snapshot (cond ((null snapshots)
                          (user-error "No workspace snapshot yet"))
                         (older (major-pane-workspace--pick-snapshot snapshots))
                         (t (major-pane-workspace--default-snapshot snapshots))))
         (rows (major-pane-workspace--candidates snapshot))
         (all-row (major-pane-workspace--make-row
                   (format "[resume all %d]" (length rows)) nil))
         (candidates (cons all-row (mapcar #'car rows)))
         (choice (major-pane-workspace--read-choice candidates snapshot)))
    (if (equal choice all-row)
        (progn
          (require 'mr-x-crash-workspace)
          (mr-x/crash-workspace-start
           (format "workspace-picker-%s" (float-time)) (mapcar #'cdr rows) nil #'ignore
           (lambda (result)
             (message "Workspace resume: %s" (plist-get result :status))
             (major-pane-workspace-request-save))))
      (major-pane-workspace--select-entry (cdr (assoc choice rows))))))

 ;;; Wiring

(defvar major-pane-workspace--timer nil)
(defvar major-pane-workspace--timer-delay nil)
(defvar major-pane-workspace-inhibit-save nil
  "Non-nil while recovery is building an incomplete workspace.")
(defvar major-pane-workspace-capture-function nil
  "Optional function receiving the collected entries before history is saved.
It must signal on capture failure so history cannot advertise an unsaved state.")
(defvar major-pane-workspace-last-error nil)
(defvar-local major-pane-workspace--subscription nil)

(defun major-pane-workspace--flush ()
  "Save one event batch, without waiting for user idle time."
  (when (timerp major-pane-workspace--timer)
    (cancel-timer major-pane-workspace--timer))
  (setq major-pane-workspace--timer nil major-pane-workspace--timer-delay nil)
  (unless major-pane-workspace-inhibit-save
    (condition-case err
        (let ((entries (major-pane-workspace--collect)))
          (when major-pane-workspace-capture-function
            (funcall major-pane-workspace-capture-function entries))
          (when (or (not major-pane-workspace--boot)
                    (not (equal entries major-pane-workspace--last-written)))
            (major-pane-workspace--save-history entries))
          (setq major-pane-workspace-last-error nil))
      (error
       (setq major-pane-workspace-last-error (error-message-string err))
       (message "Workspace save failed: %s" major-pane-workspace-last-error)))))

(defun major-pane-workspace-request-save (&optional delay)
  "Queue a save after the current event; DELAY coalesces layout changes.
The first event sets the deadline.  Further events never postpone it."
  (when (and (not noninteractive) major-pane-workspace-mode (not major-pane-workspace-inhibit-save))
    (setq delay (or delay 0))
    (when (and major-pane-workspace--timer
               (> (or major-pane-workspace--timer-delay 0) delay))
      (cancel-timer major-pane-workspace--timer)
      (setq major-pane-workspace--timer nil))
    (unless major-pane-workspace--timer
      (setq major-pane-workspace--timer-delay delay
            major-pane-workspace--timer
            (run-at-time delay nil #'major-pane-workspace--flush)))))

(defun major-pane-workspace--changed (&rest _)
  "Queue a workspace mutation."
  (major-pane-workspace-request-save))

(defun major-pane-workspace--buffer-changed (&rest _)
  "Capture directory or buffer-name changes of a conversation."
  (when (bound-and-true-p agent-shell--state)
    (major-pane-workspace-request-save)))

(defun major-pane-workspace--layout-changed (&rest _)
  "Coalesce layout events for at most a quarter second."
  (major-pane-workspace-request-save 0.25))

(defun major-pane-workspace--watch-buffer ()
  "Observe actual session initialization and successful buffer closure."
  (add-hook 'kill-buffer-hook #'major-pane-workspace--changed nil t)
  (when (and (derived-mode-p 'agent-shell-mode)
             (fboundp 'agent-shell-subscribe-to)
             (bound-and-true-p agent-shell--state)
             (not major-pane-workspace--subscription))
    (setq major-pane-workspace--subscription
          (agent-shell-subscribe-to
           :shell-buffer (current-buffer)
           :on-event (lambda (event)
                       (when (memq (map-elt event :event)
                                   '(init-session init-finished session-title-changed))
                         (major-pane-workspace-request-save))))))
  ;; Covers enabling the mode after sessions already initialized.
  (major-pane-workspace-request-save))

(defconst major-pane-workspace--mutations
  '(major-pane--register-conversation major-pane--unregister-conversation
    major-pane-set-label major-pane-set-buffer-label major-pane-anchor-toggle
    major-pane--do-eject major-pane--do-adopt major-pane-exclude-buffer))

;;;###autoload
(define-minor-mode major-pane-workspace-mode
  "Persist workspace changes through lifecycle events, with no polling timer."
  :global t
  (when (timerp major-pane-workspace--timer)
    (cancel-timer major-pane-workspace--timer))
  (setq major-pane-workspace--timer nil major-pane-workspace--timer-delay nil)
  (remove-hook 'kill-emacs-hook #'major-pane-workspace-save)
  (remove-hook 'kill-emacs-hook #'major-pane-workspace--flush)
  (dolist (fn '(cd rename-buffer))
    (advice-remove fn #'major-pane-workspace--buffer-changed)
    (when major-pane-workspace-mode
      (advice-add fn :after #'major-pane-workspace--buffer-changed)))
  (dolist (fn major-pane-workspace--mutations)
    (advice-remove fn #'major-pane-workspace--changed))
  (dolist (pair '((agent-shell-mode-hook . major-pane-workspace--watch-buffer)
                  (window-state-change-hook . major-pane-workspace--layout-changed)
                  (window-size-change-functions . major-pane-workspace--layout-changed)
                  (move-frame-functions . major-pane-workspace--layout-changed)
                  (after-make-frame-functions . major-pane-workspace--layout-changed)
                  (delete-frame-functions . major-pane-workspace--layout-changed)))
    (remove-hook (car pair) (cdr pair))
    (when major-pane-workspace-mode (add-hook (car pair) (cdr pair))))
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when major-pane-workspace--subscription
        (when (fboundp 'agent-shell-unsubscribe)
          (agent-shell-unsubscribe :subscription major-pane-workspace--subscription))
        (setq major-pane-workspace--subscription nil))
      (remove-hook 'kill-buffer-hook #'major-pane-workspace--changed t)
      (when (and major-pane-workspace-mode (local-variable-p 'agent-shell--state))
        (major-pane-workspace--watch-buffer))))
  (when major-pane-workspace-mode
    (dolist (fn major-pane-workspace--mutations)
      (advice-add fn :after #'major-pane-workspace--changed))
    (add-hook 'kill-emacs-hook #'major-pane-workspace--flush)
    (major-pane-workspace-request-save)))

(provide 'major-pane-workspace)
;;; major-pane-workspace.el ends here
