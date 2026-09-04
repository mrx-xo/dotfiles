;;; agent-shell-notify.el --- Shadow images for agent-shell notifications -*- lexical-binding: t; -*-

(require 'map)
(require 'subr-x)

(defgroup agent-shell-notify nil
  "macOS notifications for agent-shell conversations."
  :group 'agent-shell)

(defcustom agent-shell-notify-cache-directory
  (expand-file-name "var/agent-shell-shadows/" user-emacs-directory)
  "Directory containing cached DiceBear Shadows PNG files."
  :type 'directory
  :group 'agent-shell-notify)

(defcustom agent-shell-notify-download-timeout 3
  "Maximum seconds curl may spend downloading a Shadow PNG."
  :type 'number
  :group 'agent-shell-notify)

(defconst agent-shell-notify--png-signature
  (unibyte-string #x89 #x50 #x4e #x47 #x0d #x0a #x1a #x0a)
  "The eight-byte PNG file signature.")

(defvar agent-shell-notify--downloads (make-hash-table :test #'equal)
  "Pending notifications keyed by opaque session digest.")

(defun agent-shell-notify--session-id (buffer)
  "Return BUFFER's ACP session ID, or nil when it is unavailable."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (boundp 'agent-shell--state)
        (ignore-errors
          (map-nested-elt agent-shell--state '(:session :id)))))))

(defun agent-shell-notify--digest (session-id)
  "Return SESSION-ID's SHA-256 digest, or nil for an unusable ID."
  (when (and (stringp session-id)
             (not (string-empty-p session-id)))
    (secure-hash 'sha256 session-id)))

(defun agent-shell-notify--cache-file (digest)
  "Return the cache filename for DIGEST."
  (expand-file-name (concat digest ".png")
                    agent-shell-notify-cache-directory))

(defun agent-shell-notify--valid-png-p (file)
  "Return non-nil when FILE begins with a complete PNG signature."
  (condition-case nil
      (and (file-readable-p file)
           (> (file-attribute-size (file-attributes file)) 8)
           (with-temp-buffer
             (set-buffer-multibyte nil)
             (insert-file-contents-literally file nil 0 8)
             (string= (buffer-string) agent-shell-notify--png-signature)))
    (file-error nil)))

(defun agent-shell-notify--spawn (name command &optional sentinel)
  "Start COMMAND asynchronously as NAME without exit queries."
  (make-process :name name
                :buffer nil
                :command command
                :connection-type 'pipe
                :noquery t
                :sentinel sentinel))

(defun agent-shell-notify--deliver-plain (title body)
  "Deliver TITLE and BODY through the existing AppleScript path."
  (when-let ((osascript (executable-find "osascript")))
    (agent-shell-notify--spawn
     "agent-shell-notification"
     (list osascript "-e"
           (format "display notification %S with title %S" body title)))))

(defun agent-shell-notify--deliver-image (title body file)
  "Deliver TITLE and BODY with content image FILE, or fall back to plain."
  (if-let ((notifier (executable-find "terminal-notifier")))
      (let ((finished nil))
        (agent-shell-notify--spawn
         "agent-shell-notification"
         (list notifier
               "-title" title
               "-message" body
               "-contentImage" file)
         (lambda (process _event)
           (when (and (not finished)
                      (memq (process-status process) '(exit signal)))
             (setq finished t)
             (unless (and (eq (process-status process) 'exit)
                          (zerop (process-exit-status process)))
               (agent-shell-notify--deliver-plain title body))))))
    (agent-shell-notify--deliver-plain title body)))

(defun agent-shell-notify--title (buffer fallback-title)
  "Return BUFFER's major-pane title, or FALLBACK-TITLE."
  (if (and (buffer-live-p buffer)
           (fboundp 'major-pane--tab-label))
      (major-pane--tab-label buffer)
    fallback-title))

(defun agent-shell-notify--drain (digest image-file)
  "Deliver and remove all queued notifications for DIGEST.
Use IMAGE-FILE when non-nil; otherwise deliver plain notifications."
  (let ((notifications (nreverse (gethash digest
                                          agent-shell-notify--downloads))))
    (remhash digest agent-shell-notify--downloads)
    (dolist (notification notifications)
      (if image-file
          (agent-shell-notify--deliver-image
           (car notification) (cdr notification) image-file)
        (agent-shell-notify--deliver-plain
         (car notification) (cdr notification))))))

(defun agent-shell-notify--finish-download
    (digest temp-file cache-file process)
  "Finish DIGEST's download from TEMP-FILE after PROCESS exits."
  (when (memq (process-status process) '(exit signal))
    (let ((image-file
           (when (and (eq (process-status process) 'exit)
                      (zerop (process-exit-status process))
                      (agent-shell-notify--valid-png-p temp-file))
             (condition-case nil
                 (progn
                   (rename-file temp-file cache-file t)
                   cache-file)
               (file-error nil)))))
      (unless image-file
        (when (file-exists-p temp-file)
          (delete-file temp-file)))
      (agent-shell-notify--drain digest image-file))))

(defun agent-shell-notify--start-download (digest)
  "Start the one asynchronous Shadow download for DIGEST."
  (if-let ((curl (executable-find "curl")))
      (let (temp-file)
        (condition-case nil
            (progn
              (make-directory agent-shell-notify-cache-directory t)
              (setq temp-file
                    (make-temp-file
                     (expand-file-name (concat "." digest "-")
                                       agent-shell-notify-cache-directory)
                     nil ".png"))
              (let ((cache-file (agent-shell-notify--cache-file digest)))
                (agent-shell-notify--spawn
                 "agent-shell-shadow-download"
                 (list curl
                       "--fail"
                       "--silent"
                       "--show-error"
                       "--location"
                       "--max-time"
                       (number-to-string agent-shell-notify-download-timeout)
                       "--output"
                       temp-file
                       (format
                        "https://api.dicebear.com/10.x/shadows/png?seed=%s&size=128"
                        digest))
                 (lambda (process _event)
                   (agent-shell-notify--finish-download
                    digest temp-file cache-file process)))))
          (error
           (when (and temp-file (file-exists-p temp-file))
             (delete-file temp-file))
           (agent-shell-notify--drain digest nil))))
    (agent-shell-notify--drain digest nil)))

(defun agent-shell-notify--queue-download (digest title body)
  "Queue TITLE and BODY while downloading DIGEST at most once."
  (let ((existing (gethash digest agent-shell-notify--downloads)))
    (puthash digest (cons (cons title body) existing)
             agent-shell-notify--downloads)
    (unless existing
      (agent-shell-notify--start-download digest))))

(defun mr-x/agent-shell-notify (buffer fallback-title body)
  "Notify for BUFFER using FALLBACK-TITLE and BODY."
  (let* ((title (agent-shell-notify--title buffer fallback-title))
         (digest (agent-shell-notify--digest
                  (agent-shell-notify--session-id buffer)))
         (cache-file (and digest
                          (agent-shell-notify--cache-file digest))))
    (cond
     ((not (executable-find "terminal-notifier"))
      (agent-shell-notify--deliver-plain title body))
     ((not digest)
      (agent-shell-notify--deliver-plain title body))
     ((agent-shell-notify--valid-png-p cache-file)
      (agent-shell-notify--deliver-image title body cache-file))
     (t
      (agent-shell-notify--queue-download digest title body)))))

(provide 'agent-shell-notify)
;;; agent-shell-notify.el ends here
