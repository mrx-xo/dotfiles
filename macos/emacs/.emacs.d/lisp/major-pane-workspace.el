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
;;   `major-pane-workspace-file' from an idle timer and from
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

(defcustom major-pane-workspace-idle-delay 15
  "Seconds of idle time before the current convo set is written."
  :type 'integer)

(defvar major-pane-workspace--boot nil
  "Start timestamp of this Emacs process once it owns a snapshot entry.
nil until the first save; afterwards saves replace the entry whose
`:started' matches this value instead of pushing a new one.")

(defvar major-pane-workspace--last-written nil
  "Convo list from the last write, to skip no-op writes from the timer.")

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
            :label (gethash buffer major-pane--labels)
            :anchored (and (memq buffer major-pane--anchored) t)
            :buffer-name (buffer-name buffer)
            :transcript (major-pane-workspace--index-transcript sid)))))

(defun major-pane-workspace--collect ()
  "Snapshot entries for the pane's convos, in tab order."
  (delq nil (mapcar #'major-pane-workspace--entry
                    (cl-remove-if-not #'buffer-live-p
                                      (major-pane--ordered-convos)))))

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

(defun major-pane-workspace-save ()
  "Write the current convo set into this process's snapshot entry.
The first call of a process pushes a new entry (unless the pane is
empty, in which case nothing is written); later calls replace it."
  (interactive)
  (let ((convos (major-pane-workspace--collect)))
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

(defun major-pane-workspace--save-if-changed ()
  "Idle-timer body: save when the convo set differs from the last write."
  (unless (equal (major-pane-workspace--collect)
                 major-pane-workspace--last-written)
    (condition-case err
        (major-pane-workspace-save)
      (error (message "major-pane-workspace: save failed: %s"
                      (error-message-string err))))))

;;; Resume

(defun major-pane-workspace--live-buffer (session-id)
  "Return the live agent-shell buffer attached to SESSION-ID, or nil."
  (cl-find-if (lambda (buf)
                (and (local-variable-p 'agent-shell--state buf)
                     (equal (major-pane-workspace--buffer-session-id buf)
                            session-id)))
              (buffer-list)))

(defun major-pane-workspace--resume-entry (entry)
  "Show ENTRY's convo: switch to it when open, resume it otherwise."
  (let ((live (major-pane-workspace--live-buffer (plist-get entry :session-id))))
    (if live
        (pop-to-buffer live)
      (require 'agent-shell-bookmark)
      (agent-shell-bookmark--resume (plist-get entry :session-id)
                                    (plist-get entry :cwd)
                                    (plist-get entry :agent)))))

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
  "Non-nil when agent-recall's browse row helpers are available."
  (and (fboundp 'agent-recall--index-entry-for-file)
       (fboundp 'agent-recall--provider-icon)
       (fboundp 'agent-recall--display-timestamp)
       (fboundp 'agent-recall--make-candidate)))

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
        (dolist (row rows)
          (unless (major-pane-workspace--live-buffer
                   (plist-get (cdr row) :session-id))
            (major-pane-workspace--resume-entry (cdr row))))
      (major-pane-workspace--select-entry (cdr (assoc choice rows))))))

;;; Wiring

(defvar major-pane-workspace--timer nil)

;;;###autoload
(define-minor-mode major-pane-workspace-mode
  "Keep the workspace snapshot file current with the open convo set."
  :global t
  (when major-pane-workspace--timer
    (cancel-timer major-pane-workspace--timer)
    (setq major-pane-workspace--timer nil))
  (remove-hook 'kill-emacs-hook #'major-pane-workspace-save)
  (when major-pane-workspace-mode
    (setq major-pane-workspace--timer
          (run-with-idle-timer major-pane-workspace-idle-delay t
                               #'major-pane-workspace--save-if-changed))
    (add-hook 'kill-emacs-hook #'major-pane-workspace-save)))

(provide 'major-pane-workspace)
;;; major-pane-workspace.el ends here
