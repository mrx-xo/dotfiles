;;; mr-x-crash-workspace.el --- Verified conversation recovery -*- lexical-binding: t; -*-
(require 'cl-lib)
(require 'mr-x-crash-restore)
(require 'major-pane-workspace)
(require 'syzygy-recall)

(defvar mr-x/crash-workspace--buffers nil)
(defvar mr-x/crash-workspace--attempt nil)
(defvar mr-x/crash-workspace-current nil)
(defvar-local mr-x/crash-workspace-owner nil)
(cl-defstruct (mr-x/crash-workspace-attempt (:constructor mr-x/crash-workspace--make))
  owner queue entries session replay done buffers owned token finished previous-inhibit
  failures current)

(defun mr-x/crash-workspace-read-bundle (directory)
  "Read and verify the session and optional workspace in DIRECTORY."
  (let* ((manifest (mr-x/crash-capture--read (expand-file-name "manifest.el" directory)))
         (files (plist-get manifest :files)) values)
    (dolist (name '("session-state.el" "workspace.el"))
      (let ((digest (cdr (assoc name files))) (path (expand-file-name name directory)))
        (when (or digest (file-exists-p path) (equal name "session-state.el"))
          (unless (and digest (equal digest (mr-x/crash-capture--digest path)))
            (error "Recovery evidence digest mismatch: %s" name)))
        (push (and digest (mr-x/crash-capture--read path)) values)))
    (nreverse values)))

(defun mr-x/crash-workspace-key (agent sid)
  "Stable identity of AGENT's SID."
  (unless (and agent (stringp sid) (not (string-empty-p sid)))
    (error "Saved agent identity is incomplete; select its provider manually"))
  (cons (format "%s" agent) sid))

(defun mr-x/crash-workspace--entry-key (entry)
  "Stable identity of workspace ENTRY."
  (mr-x/crash-workspace-key (plist-get entry :agent) (plist-get entry :session-id)))

(defun mr-x/crash-workspace--failure (attempt key)
  "Return ATTEMPT's recorded failure for conversation KEY, or nil."
  (cl-find key (mr-x/crash-workspace-attempt-failures attempt)
           :test #'equal :key #'mr-x/crash-workspace--entry-key))

(defun mr-x/crash-workspace--placeholder (failure)
  "Create an owned read-only buffer standing in for FAILURE's conversation.
The window it occupied is rebuilt around this buffer so the layout survives
one conversation that would not come back; the text says how to get it."
  (let* ((label (plist-get failure :label))
         (agent (plist-get failure :agent))
         (sid (plist-get failure :session-id))
         (buffer (generate-new-buffer
                  (format "*Recovery: %s not resumed*"
                          (or label (format "%s %s" agent (substring sid 0 (min 8 (length sid)))))))))
    (with-current-buffer buffer
      (insert (format "This window held a %s conversation that could not be resumed.\n\n" agent)
              (format "Label:      %s\n" (or label "(none)"))
              (format "Session:    %s\n" sid)
              (format "Directory:  %s\n" (or (plist-get failure :cwd) "?"))
              (format "Transcript: %s\n" (or (plist-get failure :transcript) "?"))
              (format "Error:      %s\n\n" (plist-get failure :error))
              "The recovery bundle was kept.  Resume this conversation from\n"
              "M-x agent-recall-browse, or retry recovery from the splash (SPC R).\n")
      (special-mode))
    (mr-x/crash-workspace-own-buffer buffer)))

(defun mr-x/crash-workspace-buffer (agent sid)
  "Return the verified live buffer for AGENT and SID during frame replay.
A conversation that failed to resume gets a placeholder so its frame is
still rebuilt.  A session neither verified nor known to have failed is a
programming error and aborts the transaction."
  (let* ((key (mr-x/crash-workspace-key agent sid))
         (buffer (cdr (assoc key mr-x/crash-workspace--buffers)))
         (failure (and mr-x/crash-workspace--attempt
                       (mr-x/crash-workspace--failure mr-x/crash-workspace--attempt key))))
    (cond
     ((buffer-live-p buffer) buffer)
     (failure (mr-x/crash-workspace--placeholder failure))
     (t (error "Agent %s session %s has not been verified" agent sid)))))

(defun mr-x/crash-workspace--entries (workspace session)
  "Validate WORKSPACE and add explicitly identified agents referenced by SESSION."
  (let ((entries (copy-tree workspace)))
    (cl-labels ((walk (tree)
                 (if (eq (plist-get tree :type) 'leaf)
                     (let ((spec (plist-get tree :restore-spec)))
                       (when (eq (car spec) 'agent-shell)
                         (let* ((data (cdr spec))
                                (agent (plist-get data :agent))
                                (sid (plist-get data :session-id))
                                (key (mr-x/crash-workspace-key agent sid)))
                           (unless (cl-find key entries :test #'equal
                                            :key (lambda (e) (mr-x/crash-workspace-key
                                                              (plist-get e :agent) (plist-get e :session-id))))
                             (setq entries (append entries
                                                   (list (plist-put (copy-sequence data) :cwd (plist-get data :dir)))))))))
                   (mapc #'walk (plist-get tree :children)))))
      (dolist (frame session) (walk (plist-get frame :window-tree))))
    (mr-x/crash-capture-workspace entries)))

(defun mr-x/crash-workspace-own-buffer (buffer)
  "Register newly created BUFFER with the current replay attempt."
  (when (and mr-x/crash-workspace--attempt (buffer-live-p buffer))
    (with-current-buffer buffer
      (setq mr-x/crash-workspace-owner
            (mr-x/crash-workspace-attempt-owner mr-x/crash-workspace--attempt)))
    (cl-pushnew buffer (mr-x/crash-workspace-attempt-owned mr-x/crash-workspace--attempt)))
  buffer)

(defun mr-x/crash-workspace-cleanup (owner)
  "Clean resources tagged with OWNER; return names that could not be killed."
  (unless owner (error "Cleanup requires an attempt owner"))
  (let (left)
    (dolist (buffer (buffer-list))
      (when (equal (buffer-local-value 'mr-x/crash-workspace-owner buffer) owner)
        (condition-case nil
            (with-current-buffer buffer
              (let ((kill-buffer-query-functions nil)) (kill-buffer buffer)))
          (error nil))
        (when (buffer-live-p buffer) (push (buffer-name buffer) left))))
    (nreverse left)))

(defun mr-x/crash-workspace--presentation (attempt)
  "Apply saved labels, membership and order after successful reconstruction.
Conversations that did not resume have no buffer and are skipped."
  (let ((buffers (mr-x/crash-workspace-attempt-buffers attempt)) pane anchors all)
    (dolist (entry (mr-x/crash-workspace-attempt-entries attempt))
      (when-let ((buffer (cdr (assoc (mr-x/crash-workspace--entry-key entry) buffers))))
        (push buffer all)
        (major-pane-set-buffer-label buffer (plist-get entry :label))
        (with-current-buffer buffer
          (setq-local major-pane--excluded
                      (and (eq (plist-get entry :membership) 'ejected) 'ejected)))
        (if (eq (plist-get entry :membership) 'ejected)
            (major-pane--remove-conversation-background buffer)
          (push buffer pane)
          (major-pane--apply-conversation-background buffer)
          (when (plist-get entry :anchored) (push buffer anchors)))))
    (setf (major-pane-state-conversations major-pane--state)
          (append (nreverse pane)
                  (cl-remove-if (lambda (b) (memq b all)) (major-pane-state-conversations major-pane--state))))
    (setq major-pane--anchored
          (append (nreverse anchors) (cl-remove-if (lambda (b) (memq b all)) major-pane--anchored)))
    (dolist (frame (frame-list))
      (dolist (window (window-list frame 'nomini))
        (when-let ((mode (window-parameter window 'mr-x/restored-pane-mode)))
          (setf (major-pane-state-mode major-pane--state) mode
                (major-pane-state-active major-pane--state) (window-buffer window))
          (set-window-parameter window 'mr-x/restored-pane-mode nil))))
    (force-mode-line-update t)))

(defun mr-x/crash-workspace--finish (attempt result)
  "Complete ATTEMPT once, retaining cleanup failures in RESULT."
  (unless (mr-x/crash-workspace-attempt-finished attempt)
    (setf (mr-x/crash-workspace-attempt-finished attempt) t)
    (if (eq (plist-get result :status) 'restored)
        (dolist (buffer (mr-x/crash-workspace-attempt-owned attempt))
          (when (buffer-live-p buffer)
            (with-current-buffer buffer (setq mr-x/crash-workspace-owner nil))))
      (setq result (plist-put result :agent-leaks
                              (mr-x/crash-workspace-cleanup
                               (mr-x/crash-workspace-attempt-owner attempt)))))
    (setq mr-x/crash-workspace-current nil
          major-pane-workspace-inhibit-save (mr-x/crash-workspace-attempt-previous-inhibit attempt))
    (funcall (mr-x/crash-workspace-attempt-done attempt) result)))

(defun mr-x/crash-workspace--drop-current (attempt entry)
  "Kill the half-started buffer ATTEMPT owns for ENTRY, if any.
Syzygy kills its own failed resumes; this covers a buffer it handed over
as pending and never got to clean, so a failed conversation leaves nothing."
  (let ((current (mr-x/crash-workspace-attempt-current attempt)))
    (when (and current (equal (car current) (mr-x/crash-workspace--entry-key entry)))
      (let ((buffer (cdr current)))
        (setf (mr-x/crash-workspace-attempt-current attempt) nil
              (mr-x/crash-workspace-attempt-owned attempt)
              (delq buffer (mr-x/crash-workspace-attempt-owned attempt)))
        (when (and (buffer-live-p buffer)
                   (equal (buffer-local-value 'mr-x/crash-workspace-owner buffer)
                          (mr-x/crash-workspace-attempt-owner attempt)))
          (with-current-buffer buffer
            (let ((kill-buffer-query-functions nil)) (kill-buffer buffer))))))))

(defun mr-x/crash-workspace--record-failure (attempt entry message)
  "Record that ENTRY did not resume with MESSAGE, then continue ATTEMPT.
One conversation that will not come back must not cost the others."
  (mr-x/crash-workspace--drop-current attempt entry)
  (push (append (list :error message) entry)
        (mr-x/crash-workspace-attempt-failures attempt))
  (mr-x/crash-workspace--advance attempt))

(defun mr-x/crash-workspace--resume-next (attempt entry)
  "Resume ENTRY for ATTEMPT, advancing on success and recording failure.
The callback may run synchronously inside the resume call, so nothing
here relies on the call's return value beyond a genuinely pending result."
  (let ((pending
         (condition-case err
             (syzygy-recall-resume-entry
              entry
              (lambda (result)
                (unless (mr-x/crash-workspace-attempt-finished attempt)
                  (if (not (eq (alist-get 'ok result) t))
                      (mr-x/crash-workspace--record-failure
                       attempt entry (alist-get 'error result))
                    (let* ((buffer (get-buffer (alist-get 'bufferName result)))
                           (mr-x/crash-workspace--attempt attempt))
                      (setf (mr-x/crash-workspace-attempt-current attempt) nil)
                      (unless (eq (alist-get 'existing result) t)
                        (mr-x/crash-workspace-own-buffer buffer))
                      (push (cons (mr-x/crash-workspace--entry-key entry) buffer)
                            (mr-x/crash-workspace-attempt-buffers attempt))
                      (mr-x/crash-workspace--advance attempt))))))
           ((error quit)
            (mr-x/crash-workspace--record-failure attempt entry (error-message-string err))
            nil))))
    (when (and (listp pending)
               (equal (alist-get 'status pending) "pending")
               (not (mr-x/crash-workspace-attempt-finished attempt)))
      (setf (mr-x/crash-workspace-attempt-token attempt) (alist-get 'operation pending))
      (unless (eq (alist-get 'existing pending) t)
        (let ((mr-x/crash-workspace--attempt attempt)
              (buffer (get-buffer (alist-get 'bufferName pending))))
          (mr-x/crash-workspace-own-buffer buffer)
          (setf (mr-x/crash-workspace-attempt-current attempt)
                (cons (mr-x/crash-workspace--entry-key entry) buffer)))))
    nil))

(defun mr-x/crash-workspace--advance (attempt)
  "Resume the next conversation, or reconstruct frames when all have settled."
  (unless (mr-x/crash-workspace-attempt-finished attempt)
    (condition-case err
        (if-let ((entry (pop (mr-x/crash-workspace-attempt-queue attempt))))
            (mr-x/crash-workspace--resume-next attempt entry)
          (let* ((mr-x/crash-workspace--buffers (mr-x/crash-workspace-attempt-buffers attempt))
                 (mr-x/crash-workspace--attempt attempt)
                 (session (mr-x/crash-workspace-attempt-session attempt))
                 (failures (reverse (mr-x/crash-workspace-attempt-failures attempt)))
                 (mr-x/crash-restore-owner (mr-x/crash-workspace-attempt-owner attempt))
                 (_verified
                  (dolist (pair mr-x/crash-workspace--buffers)
                    (unless (and (buffer-live-p (cdr pair))
                                 (syzygy-recall--entry-initialized-p (cdr pair)))
                      (error "A restored conversation closed before frame reconstruction"))))
                 (result (if session
                             (mr-x/crash-restore-frames session (mr-x/crash-workspace-attempt-replay attempt))
                           '(:status restored :frames nil))))
            (when (eq (plist-get result :status) 'restored)
              (let ((old-state (copy-major-pane-state major-pane--state))
                    (old-labels (copy-hash-table major-pane--labels))
                    (old-anchors (copy-sequence major-pane--anchored))
                    (old-membership
                     (mapcar (lambda (pair) (cons (cdr pair)
                                                 (buffer-local-value 'major-pane--excluded (cdr pair))))
                             mr-x/crash-workspace--buffers)))
                (condition-case presentation-error
                    (progn
                      (mr-x/crash-workspace--presentation attempt)
                      (when failures
                        (setq result (append result (list :failed failures)))))
                  ((error quit)
                   (setq major-pane--state old-state major-pane--labels old-labels
                         major-pane--anchored old-anchors)
                   (dolist (pair old-membership)
                     (when (buffer-live-p (car pair))
                       (with-current-buffer (car pair)
                         (setq major-pane--excluded (cdr pair)))))
                   (let (leaked)
                     (dolist (entry (reverse (plist-get result :frames)))
                       (condition-case nil
                           (delete-frame (plist-get entry :frame) t)
                         (error (push (plist-get entry :restore-key) leaked))))
                     (setq result (list :status 'failed :leaked leaked
                                        :errors (list (error-message-string presentation-error)))))))))
            (mr-x/crash-workspace--finish attempt result)))
      ((error quit)
       (mr-x/crash-workspace--finish attempt (list :status 'failed :errors (list (error-message-string err))))))))

(defun mr-x/crash-workspace-start (owner workspace session replay done)
  "Resume WORKSPACE and SESSION, then call DONE with the frame transaction result.
OWNER uniquely identifies this attempt.  Validation happens before any startup.
Conversations that fail to resume are reported under :failed in a restored
result rather than failing the attempt; their windows get placeholders."
  (when mr-x/crash-workspace-current (error "A workspace restore is already running"))
  (let* ((entries (mr-x/crash-workspace--entries workspace session))
         (attempt (mr-x/crash-workspace--make
                   :owner owner :entries entries :queue (copy-sequence entries)
                   :session session :replay replay :done done
                   :previous-inhibit major-pane-workspace-inhibit-save)))
    (mr-x/crash-capture--session-keys session)
    (setq mr-x/crash-workspace-current attempt major-pane-workspace-inhibit-save t)
    (mr-x/crash-workspace--advance attempt)
    attempt))

(defun mr-x/crash-workspace-cancel (attempt)
  "Cancel ATTEMPT and clean its owned resources."
  (unless (mr-x/crash-workspace-attempt-finished attempt)
    (when-let ((token (mr-x/crash-workspace-attempt-token attempt)))
      (syzygy-recall-cancel-resume token))
    (mr-x/crash-workspace--finish attempt '(:status failed :errors ("Recovery cancelled")))))

(provide 'mr-x-crash-workspace)
