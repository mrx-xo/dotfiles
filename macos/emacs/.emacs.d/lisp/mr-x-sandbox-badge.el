;;; mr-x-sandbox-badge.el --- SANDBOX badge on every sandbox mode line  -*- lexical-binding: t; -*-

;;; Commentary:

;; The sandbox daemon (--socket-name=sandbox) runs a copy of the real
;; config, so without a marker its frames look exactly like the main
;; daemon's.  This adds a red SANDBOX segment right after the bar of every
;; doom-modeline layout and puts SANDBOX in the frame title.
;;
;; The segment goes into whatever layouts exist (`main',
;; `agent-shell-minimal', anything added later) by reading doom-modeline's
;; own registry, so the layouts in emacs.org stay the one definition.  The
;; old approach (a `main' copy appended to the sandbox's init.el by
;; emacs-sandbox.sh) broke twice: it drifted from the real `main', and any
;; later copy of init.el into the sandbox dropped the loader.
;;
;; emacs.org loads this only when `(daemonp)' is "sandbox".

;;; Code:

(require 'doom-modeline)

(defface mr-x/sandbox-badge
  '((t :background "#ff6b6b" :foreground "white" :weight bold))
  "Face for the SANDBOX mode-line badge.")

(defun mr-x/sandbox-badge--padding ()
  "Pixels of red above and below the label.
A face background only covers one text line, which left the badge a thin
strip in a mode line made taller by the 1.25x evil state glyph.  A
sixteenth of the line height (2px at 30px) is the most the badge takes
without making the mode line itself taller: most of that glyph's extra
height is ascent, and padding past its descent adds pixels at the
bottom.  Derived from the font rather than measured, because
`window-mode-line-height' includes this badge and feeding it back grew
the mode line."
  (round (frame-char-height) 16))

(doom-modeline-def-segment sandbox
  "Red SANDBOX badge, the full height of the mode line."
  (let ((color (face-background 'mr-x/sandbox-badge nil t)))
    (concat
     (propertize " SANDBOX "
                 'face `(:inherit mr-x/sandbox-badge
                         :box (:line-width (0 . ,(mr-x/sandbox-badge--padding))
                               :color ,color)))
     (doom-modeline-spc))))

(defun mr-x/sandbox-badge--insert (lhs)
  "Return LHS with the `sandbox' segment after `bar', or first if no bar."
  (cond ((memq 'sandbox lhs) lhs)
        ((memq 'bar lhs)
         (let ((tail (cdr (memq 'bar lhs))))
           (append (butlast lhs (length tail)) '(sandbox) tail)))
        (t (cons 'sandbox lhs))))

(defun mr-x/sandbox-badge--filter-args (args)
  "Put the badge into the layout a `doom-modeline-def-modeline' call defines."
  (pcase-let ((`(,name ,lhs . ,rest) args))
    `(,name ,(mr-x/sandbox-badge--insert lhs) ,@rest)))

(defun mr-x/sandbox-badge-enable ()
  "Mark this Emacs as the sandbox in every mode line and frame title."
  (setq frame-title-format '("SANDBOX - " "%b"))
  ;; Layouts defined from now on get the badge on the way in ...
  (advice-add 'doom-modeline-def-modeline :filter-args
              #'mr-x/sandbox-badge--filter-args)
  ;; ... and the ones already defined are redefined from the registry.
  (pcase-dolist (`(,name ,lhs ,rhs) doom-modeline--modelines)
    (doom-modeline-def-modeline name lhs rhs))
  (force-mode-line-update t))

(provide 'mr-x-sandbox-badge)

;;; mr-x-sandbox-badge.el ends here
