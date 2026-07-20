;;; agent-shell-inbox.el --- Attach phone screenshots into an armed agent-shell buffer -*- lexical-binding: t; -*-

;; Author: Marcos Andrade
;; Keywords: convenience, tools

;;; Commentary:

;; Companion to the agent-inbox Telegram daemon
;; (~/.dotfiles/macos/scripts/agent-inbox-daemon.py).  Design doc:
;; ~/.dotfiles/docs/phone-screenshot-ez-send.md
;;
;; Flow: `agent-shell-inbox-arm' in an agent-shell buffer captures that
;; buffer and watches `agent-shell-inbox-directory' (poll primary,
;; file-notify as an optional fast path — kqueue on macOS is unreliable
;; for directory creates).  The first new image file gets attached to the
;; armed buffer's pending prompt via `agent-shell-insert', then the
;; watcher disarms (one-shot).  Submission is left to the user.

;;; Code:

;; No (require 'agent-shell): this file loads from agent-shell-config.el
;; before elpaca has activated packages (same reason agent-shell-refs.el
;; doesn't require it).  Every entry point runs inside an agent-shell
;; buffer, so agent-shell and shell-maker are guaranteed loaded by then.
(require 'cl-lib)
(require 'filenotify)
(require 'seq)

(declare-function agent-shell-insert "agent-shell")
(declare-function agent-shell--get-files-context "agent-shell")
(declare-function shell-maker-busy "shell-maker")

(defgroup agent-shell-inbox nil
  "Attach incoming phone screenshots to an armed agent-shell buffer."
  :group 'agent-shell)

(defcustom agent-shell-inbox-directory (expand-file-name "~/agent-inbox/")
  "Folder the daemon drops incoming screenshots into.
Keep it space-free: `@'-mention parsing splits on whitespace and the
inserted path is not quoted."
  :type 'directory)

(defcustom agent-shell-inbox-timeout 120
  "Seconds to stay armed before auto-disarming."
  :type 'integer)

(defcustom agent-shell-inbox-poll-interval 1.0
  "Polling interval (seconds) for the inbox watcher."
  :type 'number)

(defcustom agent-shell-inbox-image-regexp "\\.\\(png\\|jpe?g\\|webp\\)\\'"
  "Only files matching this (and not dotfiles) are treated as incoming images."
  :type 'regexp)

(defcustom agent-shell-inbox-grace-seconds 60
  "On arm, immediately attach a never-attached image younger than this.
Covers the \"screenshot landed right before/after the arm timed out\"
case: re-arming scoops it up instead of ignoring it as already-seen.
Set to 0 to disable."
  :type 'integer)

(defvar agent-shell-inbox--armed-buffer nil
  "Target buffer while armed, else nil.")
(defvar agent-shell-inbox--deadline nil
  "Time at which the current arm auto-disarms, else nil.")
(defvar agent-shell-inbox--poll-timer nil)
(defvar agent-shell-inbox--timeout-timer nil)
(defvar agent-shell-inbox--fn-descriptor nil)
(defvar agent-shell-inbox--seen nil
  "Inbox filenames snapshotted at arm time.")
(defvar agent-shell-inbox--busy-notified nil
  "Non-nil once the busy-shell message has been shown for the current arm.")
(defvar agent-shell-inbox--multi nil
  "Non-nil while armed in multi-image mode (attach every image until timeout).")
(defvar agent-shell-inbox--attached nil
  "Filenames attached at any point this session (for the grace pickup).")

(defun agent-shell-inbox-armed-p (&optional buffer)
  "Return non-nil if BUFFER (default: current) is the armed target."
  (and agent-shell-inbox--armed-buffer
       (eq (or buffer (current-buffer)) agent-shell-inbox--armed-buffer)))

(defun agent-shell-inbox-remaining-seconds ()
  "Whole seconds until the current arm times out (0 when not armed)."
  (if agent-shell-inbox--deadline
      (max 0 (truncate (float-time (time-subtract agent-shell-inbox--deadline nil))))
    0))

(defun agent-shell-inbox--images ()
  "Qualifying image files in the inbox (absolute paths, no dotfiles)."
  (seq-filter (lambda (f)
                (and (not (string-prefix-p "." (file-name-nondirectory f)))
                     (string-match-p agent-shell-inbox-image-regexp f)))
              (directory-files agent-shell-inbox-directory t nil t)))

(defun agent-shell-inbox--attachment-text (image-path)
  "Sendable `@'-mention text for IMAGE-PATH, with inline thumbnail when possible.
`agent-shell--get-files-context' is a private helper; if it ever
disappears or errors, degrade to a plain @path (identical at the ACP
level, just no preview)."
  (or (and (fboundp 'agent-shell--get-files-context)
           (ignore-errors
             (agent-shell--get-files-context :files (list image-path))))
      (concat "@" (expand-file-name image-path))))

(defun agent-shell-inbox--attach (image-path)
  "Attach IMAGE-PATH to the armed buffer's pending prompt.
One-shot on success.  If the shell is mid-turn, stay armed so the poll
retries until it goes idle (or the arm times out)."
  (when-let* ((buf agent-shell-inbox--armed-buffer))
    (if (not (buffer-live-p buf))
        (progn
          (agent-shell-inbox-disarm)
          (message "agent-shell-inbox: armed buffer gone; %s left in inbox" image-path))
      ;; The with-current-buffer wrapper is load-bearing beyond the busy
      ;; check: `agent-shell-insert' reroutes to a viewport compose buffer
      ;; when called from a non-agent-shell buffer (like a timer) and
      ;; `agent-shell-prefer-viewport-interaction' is set.
      (with-current-buffer buf
        (if (shell-maker-busy)
            (unless agent-shell-inbox--busy-notified
              (setq agent-shell-inbox--busy-notified t)
              (message "agent-shell-inbox: %s busy; will attach when idle"
                       (buffer-name buf)))
          (let ((name (file-name-nondirectory image-path)))
            (if agent-shell-inbox--multi
                ;; Multi mode: stay armed until timeout/manual disarm; mark
                ;; this file seen so the poll doesn't re-attach it forever.
                (progn
                  (cl-pushnew name agent-shell-inbox--seen :test #'equal)
                  (setq agent-shell-inbox--busy-notified nil))
              (agent-shell-inbox-disarm))
            (push name agent-shell-inbox--attached)
            (condition-case err
                (progn
                  (agent-shell-insert
                   :text (agent-shell-inbox--attachment-text image-path)
                   :shell-buffer buf
                   :no-focus t)
                  (message "agent-shell-inbox: attached %s to %s%s"
                           name (buffer-name buf)
                           (if agent-shell-inbox--multi " (still armed)" "")))
              (error
               (message "agent-shell-inbox: attach failed (%s); %s left in inbox"
                        (error-message-string err) image-path)))))))))

(defun agent-shell-inbox--poll ()
  ;; Doubles as the modeline ticker: the countdown segment only rerenders
  ;; when something requests an update, and this fires every second anyway.
  (force-mode-line-update t)
  (let* ((now (mapcar #'file-name-nondirectory (agent-shell-inbox--images)))
         (new (seq-difference now agent-shell-inbox--seen)))
    (when new
      (agent-shell-inbox--attach
       (expand-file-name (car (sort new #'string<)) agent-shell-inbox-directory)))))

(defun agent-shell-inbox--fn-callback (event)
  "Optional fast path; the poll timer is the safety net.
For `renamed' events the NEW name is the 4th element — the 3rd is the
old name (the daemon's dot-prefixed temp file), which the dotfile filter
would always reject."
  (pcase-let ((`(,_desc ,action ,file ,file1) event))
    (let ((path (if (eq action 'renamed) file1 file)))
      (when (and (memq action '(created renamed))
                 path
                 (not (string-prefix-p "." (file-name-nondirectory path)))
                 (string-match-p agent-shell-inbox-image-regexp path))
        (agent-shell-inbox--attach path)))))

(defun agent-shell-inbox--grace-pickup ()
  "Attach the newest never-attached image younger than the grace window.
Timestamped filenames sort chronologically, so `string>' picks newest."
  (when (> agent-shell-inbox-grace-seconds 0)
    (when-let* ((recent (seq-filter
                         (lambda (f)
                           (and (not (member (file-name-nondirectory f)
                                             agent-shell-inbox--attached))
                                (when-let* ((mtime (file-attribute-modification-time
                                                    (file-attributes f))))
                                  (< (float-time (time-subtract nil mtime))
                                     agent-shell-inbox-grace-seconds))))
                         (agent-shell-inbox--images))))
      (let ((path (car (sort (copy-sequence recent) #'string>))))
        ;; Drop it from the seen-snapshot so the poll keeps retrying it
        ;; if the shell is busy right now (attach re-adds it in multi mode).
        (setq agent-shell-inbox--seen
              (delete (file-name-nondirectory path) agent-shell-inbox--seen))
        (agent-shell-inbox--attach path)))))

;;;###autoload
(defun agent-shell-inbox-arm (&optional multi)
  "Arm the inbox watcher against the current agent-shell buffer (one-shot).
If this buffer is already armed, disarm instead (toggle).  With prefix
arg MULTI, stay armed and attach every incoming image until the timeout
or a manual disarm.  An image that arrived within
`agent-shell-inbox-grace-seconds' and was never attached is picked up
immediately."
  (interactive "P")
  (unless (derived-mode-p 'agent-shell-mode)
    (user-error "Not in an agent-shell buffer"))
  (if (agent-shell-inbox-armed-p)
      (progn
        (agent-shell-inbox-disarm)
        (message "agent-shell-inbox: disarmed"))
    (agent-shell-inbox-disarm)          ; clear any prior arm elsewhere
    (unless (file-directory-p agent-shell-inbox-directory)
      (make-directory agent-shell-inbox-directory t))
    (setq agent-shell-inbox--armed-buffer (current-buffer)
          agent-shell-inbox--deadline (time-add nil agent-shell-inbox-timeout)
          agent-shell-inbox--multi (and multi t)
          agent-shell-inbox--busy-notified nil
          agent-shell-inbox--seen (mapcar #'file-name-nondirectory
                                          (agent-shell-inbox--images))
          agent-shell-inbox--poll-timer
          (run-with-timer agent-shell-inbox-poll-interval
                          agent-shell-inbox-poll-interval
                          #'agent-shell-inbox--poll)
          agent-shell-inbox--timeout-timer
          (run-with-timer agent-shell-inbox-timeout nil
                          (lambda ()
                            (agent-shell-inbox-disarm)
                            (message "agent-shell-inbox: timed out, disarmed")))
          agent-shell-inbox--fn-descriptor
          (ignore-errors
            (file-notify-add-watch agent-shell-inbox-directory '(change)
                                   #'agent-shell-inbox--fn-callback)))
    (force-mode-line-update t)
    (message "agent-shell-inbox: armed%s for %s — send a screenshot (%.0fs timeout)"
             (if agent-shell-inbox--multi " [multi]" "")
             (buffer-name) agent-shell-inbox-timeout)
    ;; A screenshot that landed moments ago (e.g. just after a previous
    ;; arm timed out) would otherwise be invisible to the seen-snapshot.
    (agent-shell-inbox--grace-pickup)))

(defun agent-shell-inbox-disarm ()
  "Disarm the inbox watcher (idempotent)."
  (interactive)
  (when (timerp agent-shell-inbox--poll-timer)
    (cancel-timer agent-shell-inbox--poll-timer))
  (when (timerp agent-shell-inbox--timeout-timer)
    (cancel-timer agent-shell-inbox--timeout-timer))
  (when agent-shell-inbox--fn-descriptor
    (ignore-errors (file-notify-rm-watch agent-shell-inbox--fn-descriptor)))
  (setq agent-shell-inbox--armed-buffer nil
        agent-shell-inbox--deadline nil
        agent-shell-inbox--multi nil
        agent-shell-inbox--poll-timer nil
        agent-shell-inbox--timeout-timer nil
        agent-shell-inbox--fn-descriptor nil
        agent-shell-inbox--seen nil
        agent-shell-inbox--busy-notified nil)
  (force-mode-line-update t))

(provide 'agent-shell-inbox)
;;; agent-shell-inbox.el ends here
