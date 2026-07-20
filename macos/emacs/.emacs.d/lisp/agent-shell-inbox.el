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
          (agent-shell-inbox-disarm)
          (condition-case err
              (progn
                (agent-shell-insert
                 :text (agent-shell-inbox--attachment-text image-path)
                 :shell-buffer buf
                 :no-focus t)
                (message "agent-shell-inbox: attached %s to %s"
                         (file-name-nondirectory image-path) (buffer-name buf)))
            (error
             (message "agent-shell-inbox: attach failed (%s); %s left in inbox"
                      (error-message-string err) image-path))))))))

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

;;;###autoload
(defun agent-shell-inbox-arm ()
  "Arm the inbox watcher against the current agent-shell buffer (one-shot).
If this buffer is already armed, disarm instead (toggle)."
  (interactive)
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
    (message "agent-shell-inbox: armed for %s — send a screenshot (%.0fs timeout)"
             (buffer-name) agent-shell-inbox-timeout)))

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
        agent-shell-inbox--poll-timer nil
        agent-shell-inbox--timeout-timer nil
        agent-shell-inbox--fn-descriptor nil
        agent-shell-inbox--seen nil
        agent-shell-inbox--busy-notified nil)
  (force-mode-line-update t))

(provide 'agent-shell-inbox)
;;; agent-shell-inbox.el ends here
