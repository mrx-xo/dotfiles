;;; mr-x-crash-runtime.el --- Explicit daemon diagnostic wiring -*- lexical-binding: t; -*-

;;; Commentary:
;; Loading is inert.  The shared launcher calls `mr-x/crash-runtime-arm' as a
;; command-line action, which defers installation until emacs-startup-hook.
;; Emacs 30 sets server-name from daemonp only after command-line actions.
;; Validate the launch environment and metadata before installing anything.
;; This connects diagnostics only; legacy capture/recovery remains separate
;; until the transactional bundle and restore integration is complete.

;;; Code:
(require 'mr-x-crash-diagnostics)
(defvar server-name)
(defvar mr-x/crash-runtime--identity nil)
(defvar mr-x/crash-runtime--directory nil)
(defvar mr-x/crash-runtime--timer nil)
(defvar mr-x/crash-runtime--wrapper nil)
(defvar mr-x/crash-runtime--previous nil)
(defvar mr-x/crash-runtime--last-error nil)

(defun mr-x/crash-runtime--snapshot ()
  "Persist a bounded message tail without disturbing command execution."
  (when mr-x/crash-runtime--directory
    (condition-case err
        (mr-x/crash-diagnostics-messages
         mr-x/crash-runtime--directory
         (if-let ((buffer (get-buffer "*Messages*")))
             (with-current-buffer buffer
               (buffer-substring-no-properties
                (max (point-min) (- (point-max) (* 256 1024))) (point-max)))
           ""))
      ((error quit)
       (setq mr-x/crash-runtime--last-error
             (truncate-string-to-width (error-message-string err) 512))))))

(defun mr-x/crash-runtime--clean ()
  "Persist final messages and mark this exact initialized daemon run clean."
  (mr-x/crash-runtime--snapshot)
  (when mr-x/crash-runtime--identity
    (condition-case err
        (mr-x/crash-run-mark-clean mr-x/crash-runtime--directory mr-x/crash-runtime--identity)
      ((error quit)
       (setq mr-x/crash-runtime--last-error
             (truncate-string-to-width (error-message-string err) 512))))))

(defun mr-x/crash-runtime-stop ()
  "Remove only this library's wiring, preserving evidence and newer handlers."
  (when (timerp mr-x/crash-runtime--timer)
    (cancel-timer mr-x/crash-runtime--timer))
  (when (and mr-x/crash-runtime--wrapper
             (eq command-error-function mr-x/crash-runtime--wrapper))
    (setq command-error-function mr-x/crash-runtime--previous))
  (remove-hook 'kill-emacs-hook #'mr-x/crash-runtime--clean)
  (remove-hook 'emacs-startup-hook #'mr-x/crash-runtime-start)
  (setq mr-x/crash-runtime--identity nil mr-x/crash-runtime--directory nil
        mr-x/crash-runtime--timer nil mr-x/crash-runtime--wrapper nil
        mr-x/crash-runtime--previous nil))

(defun mr-x/crash-runtime-start ()
  "Install run-scoped diagnostics only in the daemon named by valid metadata.
Batch invocations do nothing.  Repeated installation for the same run is a
no-op; environment changes cannot redirect an already active logger."
  (when (and (not noninteractive) (daemonp))
    (let* ((directory (getenv "MR_X_EMACS_RUN_DIRECTORY"))
           (id (getenv "MR_X_EMACS_RUN_ID"))
           (root (mr-x/crash-run--root directory))
           (data (mr-x/crash-run-metadata root))
           (init (file-name-as-directory (file-truename user-emacs-directory))))
      (unless (and (equal id (plist-get data :run-id))
                   (equal server-name (plist-get data :server))
                   (equal (daemonp) server-name)
                   (equal init (plist-get data :init-directory))
                   (equal (file-name-directory (directory-file-name root))
                          (file-truename (expand-file-name "var/crash-recovery/runs/" init))))
        (mr-x/crash-capture--invalid "Daemon launch identity mismatch"))
      (if mr-x/crash-runtime--identity
          (unless (equal root mr-x/crash-runtime--directory)
            (mr-x/crash-capture--invalid "Cannot replace active diagnostic run"))
        (let ((identity (mr-x/crash-run-initialized root (emacs-pid)))
              (previous command-error-function)
              complete)
          (unwind-protect
              (progn
                (setq mr-x/crash-runtime--wrapper (mr-x/crash-diagnostics-wrapper root previous)
                      mr-x/crash-runtime--previous previous
                      mr-x/crash-runtime--timer (run-with-timer 30 30 #'mr-x/crash-runtime--snapshot)
                      mr-x/crash-runtime--directory root
                      command-error-function mr-x/crash-runtime--wrapper)
                (add-hook 'kill-emacs-hook #'mr-x/crash-runtime--clean t)
                (setq mr-x/crash-runtime--identity identity complete t)
                (mr-x/crash-runtime--snapshot))
            (unless complete (mr-x/crash-runtime-stop)))))
      mr-x/crash-runtime--identity)))

(defun mr-x/crash-runtime-arm ()
  "Explicit launcher action: install diagnostics after daemon initialization."
  (when (and (not noninteractive) (daemonp))
    (add-hook 'emacs-startup-hook #'mr-x/crash-runtime-start t)))

(provide 'mr-x-crash-runtime)
;;; mr-x-crash-runtime.el ends here
