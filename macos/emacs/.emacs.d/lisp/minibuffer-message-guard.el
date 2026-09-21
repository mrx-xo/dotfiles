;;; minibuffer-message-guard.el --- Keep background messages out of prompts -*- lexical-binding: t; -*-

;;; Commentary:
;; Standard messages remain logged in *Messages*, but must not become inline
;; minibuffer overlays while reading input.  An idle minibuffer window still
;; contains a minibuffer, so test active-minibuffer-window, not minibufferp.

;;; Code:

(defun mr-x/suppress-message-in-minibuffer (_message)
  "Suppress message display only while a minibuffer prompt is active."
  (when (active-minibuffer-window) t))

;; Run before set-minibuffer-message, which would create the inline overlay.
(add-hook 'set-message-functions #'mr-x/suppress-message-in-minibuffer -90)

(provide 'minibuffer-message-guard)
;;; minibuffer-message-guard.el ends here
