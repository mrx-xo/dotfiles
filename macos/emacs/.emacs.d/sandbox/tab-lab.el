;;; tab-lab.el --- major-pane styling playground (SANDBOX ONLY) -*- lexical-binding: t; -*-

;;; Commentary:
;; A persistent lab for auditioning major-pane chrome styles without
;; touching the real config or needing live agents.  Lives in the main
;; .emacs.d (so `emacs-sandbox.sh --fresh' copies it along) but is ONLY
;; loaded by the sandbox init — main Emacs never sees it.
;;
;; Usage (in sandbox):
;;   C-c l  build/rebuild the fake-conversation scene
;;   C-c t  cycle tab styles (default/underline/underline+body/chunky/minimal)
;;   C-c c  cycle active-tab underline color through gruvbox
;;   C-c b  cycle banner background through gruvbox (auto-contrast text)
;;   C-c n  back to normal (clear every override)
;;
;; Everything styling-related happens on the face-override layer, so
;; `C-c n' always returns to whatever major-pane.el really ships.

;;; Code:

(require 'cl-lib)

;;; Palette

(defconst mr-x/tab-lab-gruvbox
  '(("red"        . "#fb4934")
    ("orange"     . "#fe8019")
    ("yellow"     . "#fabd2f")
    ("green"      . "#b8bb26")
    ("aqua"       . "#8ec07c")
    ("blue"       . "#83a598")
    ("purple"     . "#d3869b")
    ("teal"       . "#458588")
    ("faded red"  . "#cc241d")
    ("cream"      . "#fbf1c7")
    ("gray"       . "#928374"))
  "Gruvbox colors the cyclers walk through.")

(defconst mr-x/tab-lab-faces
  '(major-pane-tab-active major-pane-tab-inactive major-pane-tab-separator
    major-pane-banner major-pane-banner-model major-pane-banner-info
    major-pane-banner-separator major-pane-banner-alert)
  "All faces the lab may override.")

;;; Fake agent-shell state (banner segments render fully)

(unless (fboundp 'agent-shell--format-number-compact)
  (defun agent-shell--format-number-compact (n)
    (cond ((>= n 1000000) (format "%gm" (/ (round n 100000) 10.0)))
          ((>= n 1000) (format "%dk" (round n 1000)))
          (t (format "%d" n)))))

(defvar mr-x/tab-lab-fake-state
  `((:config-options
     . (((:id . "model") (:current-value . "claude-fable-5[1m]"))
        ((:id . "effort") (:current-value . "high")
         (:options . (((:value . "high") (:name . "high")))))
        ((:id . "mode") (:current-value . "bypass")
         (:options . (((:value . "bypass") (:name . "Bypass Permissions")))))))
    (:usage . ((:context-used . 161000)
               (:context-size . 1000000)
               (:cost-amount . 20.53)))))

;;; Fake conversation scene

(defconst mr-x/tab-lab-buffers
  '("Claude Agent @ .dotfiles"
    "Claude Agent @ .dotfiles<2>"
    "Claude Agent @ home-lab"
    "Claude Agent @ ask-user-mcp"
    "Claude Agent @ elisp"
    "Claude Agent @ ssh"
    ;; enough extras to overflow a 30%-width pane → exercises tab slicing
    "Claude Agent @ roaming"
    "Claude Agent @ agent-recall"
    "Claude Agent @ major-pane"
    "Claude Agent @ sketchybar"
    "Claude Agent @ windows"
    "Claude Agent @ scripts"))

(defun mr-x/tab-lab--fill-convo (buf)
  "Fill BUF with text that looks like an agent-shell conversation."
  (with-current-buffer buf
    (let ((inhibit-read-only t))
      (erase-buffer)
      (set (make-local-variable 'agent-shell--state) mr-x/tab-lab-fake-state)
      (cl-flet ((ins (text face) (insert (propertize text 'face face))))
        (ins "X " '(:foreground "#fe8019" :weight bold))
        (ins "there's like a gap between the separator and\nthe tab... is there any way to remove that? or nah?\n\n"
             '(:foreground "#d3869b" :weight bold))
        (ins "  Yeah there's a way — the gap isn't actually\n  spacing I added, it's the " '(:foreground "#ebdbb2"))
        (ins "│" '(:foreground "#fe8019" :background "#3c3836"))
        (ins " character itself. A\n  font glyph lives in a full character cell (~8px\n  wide), but the line stroke is only 1px.\n\n"
             '(:foreground "#ebdbb2"))
        (ins "  ▶ " '(:foreground "#928374"))
        (ins " ✓ " '(:foreground "#b8bb26" :background "#3c3836"))
        (ins " run " '(:foreground "#ebdbb2" :background "#3c3836" :box t))
        (ins "  Swap glyph separator for pixel-width\ndivider in sandbox\n\n"
             '(:foreground "#d3869b"))
        (ins "  ▼ Ran a command\n\n" '(:foreground "#928374"))
        (ins "  Look now — the divider should be a thin\n  full-height line sitting directly against the\n  tabs, no dead air on either side.\n"
             '(:foreground "#ebdbb2"))))
    (goto-char (point-min))))

(defun mr-x/tab-lab--pixel-divider ()
  "Use a 2px colored space as the tab divider (vs the │ glyph)."
  (setq major-pane-tab-divider
        (propertize " " 'display '(space :width (2))
                    'face '(:background "#3c3836"))))

;;;###autoload
(defun mr-x/tab-lab ()
  "Build (or rebuild) the tab-lab scene: fake convos + visible pane."
  (interactive)
  (require 'major-pane)
  (dolist (name mr-x/tab-lab-buffers)
    (let ((buf (get-buffer-create name)))
      (mr-x/tab-lab--fill-convo buf)
      (major-pane--register-conversation buf)))
  (mr-x/tab-lab--pixel-divider)
  (let ((buf (get-buffer (car mr-x/tab-lab-buffers))))
    (setf (major-pane-state-active major-pane--state) buf
          (major-pane-state-mode major-pane--state) 'side)
    (major-pane--display buf)
    (major-pane--refresh-decorations))
  (force-mode-line-update t)
  (message "tab-lab: C-c t styles · C-c c underline · C-c b banner · C-c n normal"))

;;; Cyclers

(defvar mr-x/tab-lab--style-index 0)
(defvar mr-x/tab-lab--underline-index -1)
(defvar mr-x/tab-lab--banner-index -1)

(defconst mr-x/tab-lab-styles
  `(("default (flat + divider)" . nil)
    ("1: VSCode underline"
     . ((major-pane-tab-active
         . ((t :foreground "#fbf1c7" :weight bold :box nil
               :underline (:color "#458588"))))
        (major-pane-tab-inactive . ((t :foreground "#7c6f64" :box nil)))))
    ("2: underline + body"
     . ((major-pane-tab-active
         . ((t :background "#3c3836" :foreground "#fbf1c7" :weight bold
               :underline (:color "#fe8019" :position 0)
               :box (:line-width (6 . -1) :color "#3c3836"))))
        (major-pane-tab-inactive
         . ((t :foreground "#7c6f64"
               :box (:line-width (6 . -1) :color "#1d2021"))))))
    ("3: chunky padded blocks"
     . ((major-pane-tab-active
         . ((t :background "#458588" :foreground "#fbf1c7" :weight bold
               :box (:line-width (6 . -2) :color "#458588"))))
        (major-pane-tab-inactive
         . ((t :foreground "#928374"
               :box (:line-width (6 . -2) :color "#1d2021"))))))
    ("4: ultra minimal"
     . ((major-pane-tab-active
         . ((t :background "#458588" :foreground "#fbf1c7"
               :weight bold :box nil)))
        (major-pane-tab-inactive . ((t :foreground "#a89984" :box nil)))
        (major-pane-tab-separator . ((t :foreground "#1d2021")))))))

(defun mr-x/tab-lab-style-cycle ()
  "Cycle candidate tab styles."
  (interactive)
  (setq mr-x/tab-lab--style-index
        (mod (1+ mr-x/tab-lab--style-index) (length mr-x/tab-lab-styles)))
  (let* ((entry (nth mr-x/tab-lab--style-index mr-x/tab-lab-styles))
         (name (car entry))
         (specs (cdr entry)))
    (dolist (f '(major-pane-tab-active major-pane-tab-inactive
                 major-pane-tab-separator))
      (face-spec-set f nil 'face-override-spec))
    (pcase-dolist (`(,face . ,spec) specs)
      (face-spec-set face spec 'face-override-spec))
    (force-mode-line-update t)
    (message "Tab style → %s   (C-c t next)" name)))

(defun mr-x/tab-lab-underline-cycle ()
  "Cycle the active-tab underline through gruvbox (underline+body style)."
  (interactive)
  (setq mr-x/tab-lab--underline-index
        (mod (1+ mr-x/tab-lab--underline-index) (length mr-x/tab-lab-gruvbox)))
  (let* ((entry (nth mr-x/tab-lab--underline-index mr-x/tab-lab-gruvbox))
         (name (car entry))
         (hex (cdr entry)))
    (face-spec-set 'major-pane-tab-active
                   `((t :background "#3c3836" :foreground "#fbf1c7" :weight bold
                        :underline (:color ,hex :position 0)
                        :box (:line-width (6 . -1) :color "#3c3836")))
                   'face-override-spec)
    (face-spec-set 'major-pane-tab-inactive
                   '((t :foreground "#7c6f64"
                        :box (:line-width (6 . -1) :color "#1d2021")))
                   'face-override-spec)
    (force-mode-line-update t)
    (message "Underline → %s (%s)   (C-c c next)" name hex)))

(defun mr-x/tab-lab--luminance (hex)
  "Perceived luminance of HEX color, 0.0 (black) to 1.0 (white)."
  (let ((r (string-to-number (substring hex 1 3) 16))
        (g (string-to-number (substring hex 3 5) 16))
        (b (string-to-number (substring hex 5 7) 16)))
    (/ (+ (* 0.299 r) (* 0.587 g) (* 0.114 b)) 255.0)))

(defun mr-x/tab-lab-banner-cycle ()
  "Cycle the banner background through gruvbox; auto-contrast the text."
  (interactive)
  (setq mr-x/tab-lab--banner-index
        (mod (1+ mr-x/tab-lab--banner-index) (length mr-x/tab-lab-gruvbox)))
  (let* ((entry (nth mr-x/tab-lab--banner-index mr-x/tab-lab-gruvbox))
         (name (car entry))
         (hex (cdr entry))
         (bright (> (mr-x/tab-lab--luminance hex) 0.55))
         (model-fg (if bright "#282828" "#fbf1c7"))
         (info-fg  (if bright "#3c3836" "#d5c4a1"))
         (sep-fg   (if bright "#504945" "#7c6f64")))
    (face-spec-set 'major-pane-banner
                   `((t :background ,hex :foreground ,model-fg
                        :weight bold :box nil))
                   'face-override-spec)
    (face-spec-set 'major-pane-banner-model
                   `((t :foreground ,model-fg :weight bold))
                   'face-override-spec)
    (face-spec-set 'major-pane-banner-info
                   `((t :foreground ,info-fg))
                   'face-override-spec)
    (face-spec-set 'major-pane-banner-separator
                   `((t :foreground ,sep-fg))
                   'face-override-spec)
    (face-spec-set 'major-pane-banner-alert
                   `((t :foreground ,(if bright "#9d0006" "#fb4934")
                        :weight bold))
                   'face-override-spec)
    (force-mode-line-update t)
    (message "Banner → %s (%s, %s text)   (C-c b next)"
             name hex (if bright "dark" "light"))))

(defun mr-x/tab-lab-reset ()
  "Clear every lab override — back to major-pane.el's real styling."
  (interactive)
  (dolist (f mr-x/tab-lab-faces)
    (face-spec-set f nil 'face-override-spec))
  (setq mr-x/tab-lab--style-index 0
        mr-x/tab-lab--underline-index -1
        mr-x/tab-lab--banner-index -1)
  (force-mode-line-update t)
  (message "tab-lab: overrides cleared — showing real config styling"))

;;; Bindings (sandbox-global)

(global-set-key (kbd "C-c l") #'mr-x/tab-lab)
(global-set-key (kbd "C-c t") #'mr-x/tab-lab-style-cycle)
(global-set-key (kbd "C-c c") #'mr-x/tab-lab-underline-cycle)
(global-set-key (kbd "C-c b") #'mr-x/tab-lab-banner-cycle)
(global-set-key (kbd "C-c n") #'mr-x/tab-lab-reset)

(provide 'tab-lab)
;;; tab-lab.el ends here
