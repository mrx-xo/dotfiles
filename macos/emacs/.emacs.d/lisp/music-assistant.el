;;; music-assistant.el --- Native Music Assistant dashboard -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; A native Emacs control surface for Music Assistant.

;;; Code:

(require 'cl-lib)
(require 'music-assistant-client)

(defgroup music-assistant nil
  "Control Music Assistant from Emacs."
  :group 'multimedia)

(defcustom music-assistant-server-url "http://192.168.1.143:8095"
  "Base URL of the Music Assistant server."
  :type 'string
  :group 'music-assistant)

(defcustom music-assistant-default-player-name "MrX.local"
  "Player selected when no remembered player is available."
  :type 'string
  :group 'music-assistant)

(defcustom music-assistant-keychain-service "music-assistant-token"
  "macOS Keychain service containing the API token."
  :type 'string
  :group 'music-assistant)

(defcustom music-assistant-request-timeout 10
  "Seconds before a Music Assistant request fails."
  :type 'number
  :group 'music-assistant)

(defcustom music-assistant-artwork-size 256
  "Square Music Assistant artwork size in pixels."
  :type 'integer
  :group 'music-assistant)

(defvar music-assistant-last-player-id nil
  "Last player explicitly selected in the dashboard.")

(define-derived-mode music-assistant-mode special-mode "Music Assistant"
  "Major mode for the Music Assistant dashboard."
  (setq-local mode-line-format nil))

;;;###autoload
(defun music-assistant ()
  "Open the native Music Assistant dashboard."
  (interactive)
  (let ((buffer (get-buffer-create "*Music Assistant*")))
    (with-current-buffer buffer
      (music-assistant-mode))
    (pop-to-buffer buffer)
    buffer))

(provide 'music-assistant)

;;; music-assistant.el ends here
