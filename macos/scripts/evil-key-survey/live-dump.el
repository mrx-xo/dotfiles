;;; live-dump.el --- dump effective evil bindings from the running daemon  -*- lexical-binding: t; -*-
;; Loaded via: emacsclient --eval '(load-file ".../live-dump.el")'
;; Writes TSVs + a markdown detail section into $EKS_DIR (default /tmp/eks).

(defvar eks/dir (or (getenv "EKS_DIR") "/tmp/eks"))
(make-directory eks/dir t)

(defun eks/keys ()
  "Every single-key candidate worth probing."
  (append (cl-loop for c from 32 to 126 collect (vector c))
          (cl-loop for c from 1 to 26 collect (vector c))
          (list [tab] [backtab] [return] [escape] [backspace] [delete]
                [up] [down] [left] [right] [home] [end] [prior] [next])))

(defun eks/owner (sym)
  "Short name of the file that defines SYM, for attribution."
  (let ((f (ignore-errors (symbol-file sym 'defun))))
    (if f (file-name-base f) "")))

(defun eks/name (def)
  (cond ((keymapp def) "PREFIX")
        ((symbolp def) (format "%s" (or def "nil")))
        (t "other")))

(defun eks/dump-state (state)
  (let (out)
    (dolist (k (eks/keys))
      (let ((def (key-binding k t)))
        (push (format "%s\t%s\t%s\t%s" state (key-description k) (eks/name def)
                      (if (symbolp def) (eks/owner def) ""))
              out)))
    (nreverse out)))

(defvar eks/probe-keys '("SPC" "SPC f" "<tab>" "TAB" "RET" "<escape>")
  "Multi-key sequences worth reporting per major mode.")

(defvar eks/survival nil
  "Accumulated \"mode<TAB>probe results\" lines, filled by `eks/in-mode'.")

(defun eks/in-mode (mode-fn)
  "Probe normal/insert/visual state in a scratch buffer running MODE-FN.
Also records MODE-FN's answers for `eks/probe-keys' into `eks/survival',
so entering the mode (which is the slow part) happens once, not twice."
  (let ((buf (get-buffer-create " *eks*")) res)
    (with-current-buffer buf
      (erase-buffer) (insert "one\ntwo\nthree\n") (goto-char (point-min))
      (funcall mode-fn) (evil-local-mode 1)
      (evil-normal-state) (setq res (append res (eks/dump-state "normal")))
      (push (format "%s\t%s" mode-fn
                    (mapconcat (lambda (k)
                                 (format "%s=%s" k (eks/name (key-binding (kbd k) t))))
                               eks/probe-keys "  "))
            eks/survival)
      (evil-insert-state) (setq res (append res (eks/dump-state "insert")))
      (evil-normal-state)
      (set-mark (point-min)) (goto-char (point-max))
      (ignore-errors (evil-visual-char))
      (setq res (append res (eks/dump-state "visual")))
      (evil-normal-state))
    (kill-buffer buf)
    res))

;; --- deduped prefix expansion, for the reference trees -----------------------

(defun eks/sub (km)
  (let (acc seen)
    (map-keymap
     (lambda (ev def)
       (when (and (not (eq ev 'keymap)) (or (characterp ev) (symbolp ev)))
         (let ((d (key-description (vector ev))))
           (unless (member d seen)
             (push d seen)
             (push (list d (cond ((keymapp def) "<prefix>")
                                 ((symbolp def) (symbol-name def))
                                 (t "<lambda>"))
                         (and (keymapp def) def))
                   acc)))))
     km)
    (sort acc (lambda (a b) (string< (car a) (car b))))))

(defun eks/tree (km prefix depth)
  (let ((s ""))
    (dolist (e (eks/sub km))
      (setq s (concat s (format "%-22s %s\n" (concat prefix " " (nth 0 e)) (nth 1 e))))
      (when (and (nth 2 e) (> depth 1))
        (setq s (concat s (eks/tree (nth 2 e) (concat prefix " " (nth 0 e)) (1- depth))))))
    s))

;; --- write everything --------------------------------------------------------

(setq eks/survival nil)

(with-temp-file (expand-file-name "live.tsv" eks/dir)
  (insert (mapconcat #'identity (eks/in-mode #'fundamental-mode) "\n") "\n"))

(dolist (m '(org-mode dired-mode emacs-lisp-mode markdown-mode magit-status-mode
             vterm-mode))
  (when (fboundp m)
    (with-temp-file (expand-file-name (format "live-%s.tsv" m) eks/dir)
      (insert (mapconcat #'identity (eks/in-mode m) "\n") "\n"))))

(with-temp-file (expand-file-name "vars.txt" eks/dir)
  (dolist (s '(evil-want-C-u-scroll evil-want-C-i-jump evil-want-Y-yank-to-eol
               evil-undo-system evil-search-module evil-respect-visual-line-mode
               evil-snipe-scope evil-snipe-repeat-scope
               evil-snipe-override-evil-repeat-keys
               evil-collection-setup-minibuffer evil-disable-insert-state-bindings
               general-override-mode which-key-mode))
    (insert (format "%s\t%S\n" s (if (boundp s) (symbol-value s) 'UNBOUND))))
  (insert (format "evil-collection-mode-list-length\t%d\n"
                  (if (boundp 'evil-collection-mode-list)
                      (length evil-collection-mode-list) 0))))

(with-temp-file (expand-file-name "leader-survival.txt" eks/dir)
  (insert (mapconcat #'identity (nreverse eks/survival) "\n") "\n"))

(let ((acc ""))
  (let ((buf (get-buffer-create " *eks3*")))
    (with-current-buffer buf
      (fundamental-mode) (evil-local-mode 1) (evil-normal-state)
      (dolist (p '("SPC" "g" "z" "Z" "[" "]" "C-w" "C-c"))
        (let ((km (key-binding (kbd p) t)))
          (when (keymapp km)
            (setq acc (concat acc (format "## Prefix `%s` (normal state)\n\n```\n" p)
                              (eks/tree km p (if (string= p "SPC") 2 1))
                              "```\n\n"))))))
    (kill-buffer buf))
  (setq acc (concat acc "## Text objects (operator + visual `a` / `i`)\n\n```\n"
                    (eks/tree (lookup-key evil-outer-text-objects-map "") "a" 1)
                    (eks/tree (lookup-key evil-inner-text-objects-map "") "i" 1)
                    "```\n"))
  (with-temp-file (expand-file-name "trees.md" eks/dir) (insert acc)))
"eks: live dump done"
