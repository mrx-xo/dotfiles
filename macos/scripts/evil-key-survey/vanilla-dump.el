;;; vanilla-dump.el --- stock-evil baseline, for diffing against the live config
;; Run in an isolated batch Emacs (NOT the daemon):
;;   emacs -Q --batch -l vanilla-dump.el
;; It loads only evil + goto-chg from the elpaca builds. It touches nothing else.

(add-to-list 'load-path (expand-file-name "~/.emacs.d/elpaca/builds/evil"))
(add-to-list 'load-path (expand-file-name "~/.emacs.d/elpaca/builds/goto-chg"))
(require 'evil)
(evil-mode 1)

(defvar eks/dir (or (getenv "EKS_DIR") "/tmp/eks"))
(make-directory eks/dir t)

(defun eks/keys ()
  (append (cl-loop for c from 32 to 126 collect (vector c))
          (cl-loop for c from 1 to 26 collect (vector c))
          (list [tab] [backtab] [return] [escape] [backspace] [delete]
                [up] [down] [left] [right] [home] [end] [prior] [next])))

(defun eks/dump-state (state)
  (let (out)
    (dolist (k (eks/keys))
      (let ((def (key-binding k t)))
        (push (format "%s\t%s\t%s" state (key-description k)
                      (cond ((keymapp def) "PREFIX")
                            ((symbolp def) (format "%s" (or def "nil")))
                            (t "other")))
              out)))
    (nreverse out)))

(let ((buf (get-buffer-create "eks")) res)
  (with-current-buffer buf
    (erase-buffer) (insert "one\ntwo\nthree\n") (goto-char (point-min))
    (fundamental-mode) (evil-local-mode 1)
    (evil-normal-state) (setq res (append res (eks/dump-state "normal")))
    (evil-insert-state) (setq res (append res (eks/dump-state "insert")))
    (evil-normal-state)
    (set-mark (point-min)) (goto-char (point-max))
    (ignore-errors (evil-visual-char))
    (setq res (append res (eks/dump-state "visual")))
    (evil-normal-state))
  (with-temp-file (expand-file-name "vanilla.tsv" eks/dir)
    (insert (mapconcat #'identity res "\n") "\n")))
