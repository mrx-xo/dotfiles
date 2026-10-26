;;; mr-x-minibuffer.el --- Shared Mac and Windows picker behavior -*- lexical-binding: t; -*-

;;; Commentary:
;; Both platform configs load this module.  Package installation stays in
;; each init file; search input and picker interaction have one owner here.

;;; Code:

(require 'cl-lib)

(defvar vertico-map)
(defvar consult--customize-alist)
(declare-function consult--customize-put "consult" (cmds prop form))

;; Keep a picker in its originating frame and let its height shrink again.
(setq minibuffer-follows-selected-frame nil
      resize-mini-windows t
      eldoc-echo-area-use-multiline-p nil)

(defun mr-x/minibuffer-configure-vertico ()
  "Apply the shared picker interaction after Vertico loads."
  (require 'vertico-directory)
  (setq vertico-count 15
        vertico-resize t
        vertico-cycle t)
  (define-key vertico-map (kbd "C-j") #'vertico-next)
  (define-key vertico-map (kbd "C-k") #'vertico-previous)
  (define-key vertico-map (kbd "C-l") #'vertico-insert)
  ;; Accept the highlighted candidate, or enter its directory.  A plain
  ;; exit-minibuffer would return the unfinished input instead.
  (define-key vertico-map (kbd "RET") #'vertico-directory-enter)
  (define-key vertico-map (kbd "DEL") #'vertico-directory-delete-char)
  (define-key vertico-map (kbd "M-DEL") #'vertico-directory-delete-word)
  (add-hook 'rfn-eshadow-update-overlay-hook #'vertico-directory-tidy))

(defun mr-x/minibuffer-configure-consult ()
  "Offer the symbol at point as history without prefilling line search."
  ;; Remove the old Windows override when applying this in a live session.
  ;; Do not set :initial to nil: callers may deliberately supply an input.
  (cl-remf (alist-get 'consult-line consult--customize-alist) :initial)
  ;; This is consult-customize's setter.  Keep the expression unevaluated
  ;; until search starts, without requiring Consult at module/compile time.
  (consult--customize-put '(consult-line) :add-history '(thing-at-point 'symbol)))

(with-eval-after-load 'vertico
  (mr-x/minibuffer-configure-vertico))

(with-eval-after-load 'consult
  (mr-x/minibuffer-configure-consult))

(provide 'mr-x-minibuffer)
;;; mr-x-minibuffer.el ends here
