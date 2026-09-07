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

(defvar eks/keymap-only-modes '((vterm-mode . vterm-mode-map))
  "Modes we refuse to actually enter, mapped to the keymap we read instead.

Entering `vterm-mode' spawns a shell process. Killing that buffer then hits
`process-kill-buffer-query-function', which calls `yes-or-no-p' - and a prompt
raised inside an `emacsclient --eval' wedges the whole daemon with no visible
minibuffer to answer it in. Installing the mode map in a plain buffer produces
identical answers with no process, verified 2026-09-07.")

(defun eks/kill (buf)
  "Kill BUF without any chance of prompting.
Every `kill-buffer-query-functions' entry is a potential `y-or-n-p', and this
runs headless, so none of them get a vote."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (let ((proc (get-buffer-process buf)))
        (when proc
          (set-process-query-on-exit-flag proc nil)
          (delete-process proc)))
      (set-buffer-modified-p nil))
    (let ((kill-buffer-query-functions nil)
          (kill-buffer-hook nil))
      (kill-buffer buf))))

(defvar eks/skipped nil
  "Modes we could not probe, so the report can admit the gap.")

(defun eks/mode-available-p (mode-fn)
  "Can MODE-FN be probed right now?
For a keymap-only mode the map must be loaded - falling back to `funcall'
would spawn the very process we are avoiding. For anything else the mode
function must be defined; magit, for instance, is not loaded until first use."
  (let ((faked (assq mode-fn eks/keymap-only-modes)))
    (if faked (boundp (cdr faked)) (fboundp mode-fn))))

(defun eks/enter-mode (mode-fn)
  "Put the current buffer into MODE-FN, or fake it if that would spawn a process.
Returns non-nil when the mode map was installed rather than entered."
  (let ((faked (assq mode-fn eks/keymap-only-modes)))
    (if faked
        (progn (fundamental-mode)
               (setq-local major-mode mode-fn)
               (use-local-map (symbol-value (cdr faked)))
               t)
      (funcall mode-fn)
      nil)))

(defun eks/in-mode (mode-fn)
  "Probe normal/insert/visual state in a scratch buffer running MODE-FN.
Also records MODE-FN's answers for `eks/probe-keys' into `eks/survival',
so entering the mode (which is the slow part) happens once, not twice."
  (let ((buf (get-buffer-create " *eks*")) res faked)
    (unwind-protect
        (with-current-buffer buf
          (erase-buffer) (insert "one\ntwo\nthree\n") (goto-char (point-min))
          (setq faked (eks/enter-mode mode-fn))
          (evil-local-mode 1)
          (evil-normal-state) (setq res (append res (eks/dump-state "normal")))
          (push (format "%s%s\t%s" mode-fn (if faked " (map only)" "")
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
      (eks/kill buf))
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

(setq eks/skipped nil)
(dolist (m '(org-mode dired-mode emacs-lisp-mode markdown-mode magit-status-mode
             vterm-mode))
  (if (eks/mode-available-p m)
      (with-temp-file (expand-file-name (format "live-%s.tsv" m) eks/dir)
        (insert (mapconcat #'identity (eks/in-mode m) "\n") "\n"))
    (push m eks/skipped)))

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
  (insert (mapconcat #'identity (nreverse eks/survival) "\n") "\n")
  (when eks/skipped
    (insert (format "#\tnot probed (not loaded in this session): %s\n"
                    (mapconcat #'symbol-name (nreverse eks/skipped) ", ")))))

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
    (eks/kill buf))
  (setq acc (concat acc "## Text objects (operator + visual `a` / `i`)\n\n```\n"
                    (eks/tree (lookup-key evil-outer-text-objects-map "") "a" 1)
                    (eks/tree (lookup-key evil-inner-text-objects-map "") "i" 1)
                    "```\n"))
  (with-temp-file (expand-file-name "trees.md" eks/dir) (insert acc)))
"eks: live dump done"
