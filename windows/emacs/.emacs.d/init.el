;;; init.el --- Marcos' Windows Emacs (essentials) -*- lexical-binding: t; -*-
;; Focus: Lua + LSP for RE4R modding, agent-shell, evil, gruvbox.

;; ---------- Restore GC after startup ----------
(add-hook 'emacs-startup-hook
          (lambda ()
            (setq gc-cons-threshold (* 64 1024 1024)
                  gc-cons-percentage 0.1)))

;; ---------- package.el + MELPA + use-package ----------
(require 'package)
(setq package-archives
      '(("gnu"    . "https://elpa.gnu.org/packages/")
        ("nongnu" . "https://elpa.nongnu.org/nongnu/")
        ("melpa"  . "https://melpa.org/packages/")))
(package-initialize)
(unless package-archive-contents
  (package-refresh-contents))
(require 'use-package)
(setq use-package-always-ensure t)   ; auto-install anything not present

;; ---------- Compat shim ----------
;; Newer marginalia calls (seconds-to-string DELAY ABBREV PADDING), but those
;; optional args only exist in Emacs 30.1+. On older builds, drop the extras so
;; marginalia's file annotations don't blow up vertico.
(unless (ignore-errors (seconds-to-string 0 t t) t)
  (advice-add 'seconds-to-string :around
              (lambda (orig delay &rest _ignore)
                (funcall orig delay))))

;; ---------- Sane defaults ----------
(setq ring-bell-function 'ignore
      make-backup-files nil
      auto-save-default nil
      create-lockfiles nil
      use-short-answers t)            ; y/n instead of yes/no
(global-display-line-numbers-mode 1)
(setq display-line-numbers-type 'relative)  ; current line absolute, others relative
(column-number-mode 1)
(setq-default indent-tabs-mode nil
              tab-width 4)

;; Make *scratch* an Org buffer instead of Lisp Interaction.
(setq initial-major-mode 'org-mode
      initial-scratch-message "#+title: Scratch\n\n")

;; UTF-8 everywhere, with Unix (LF) line endings by default.
;; (Existing CRLF files still open fine — Emacs auto-detects; this sets the
;;  default for new files and keeps things consistent with macOS/git.)
(prefer-coding-system 'utf-8-unix)
(setq-default buffer-file-coding-system 'utf-8-unix)

;; Font: SpaceMono Nerd Font (primary), FiraCode / Iosevka as fallbacks.
;; Tweak the number after the name to resize.
;; Daemon-aware: `font-family-list' is empty until a GUI frame exists, so under
;; the daemon we must pick + apply the font when the first client frame appears.
(defun my/set-font ()
  "Pick the best available font and apply it to all frames."
  (let ((font (cond
               ((member "SpaceMono Nerd Font"     (font-family-list)) "SpaceMono Nerd Font 15")
               ((member "FiraCode Nerd Font Mono" (font-family-list)) "FiraCode Nerd Font Mono 14")
               ((member "Iosevka NFM Medium" (font-family-list)) "Iosevka NFM Medium 17")
               ((member "Iosevka NFM"        (font-family-list)) "Iosevka NFM 17")
               ((member "Cascadia Code"      (font-family-list)) "Cascadia Code 13")
               ((member "Consolas"           (font-family-list)) "Consolas 13"))))
    (when font
      (set-frame-font font nil t)                          ; all current frames
      (add-to-list 'default-frame-alist `(font . ,font)))  ; future frames
    ;; Symbol fallback.  Left alone, Emacs on Windows sends Dingbats and the
    ;; geometric blocks to MS Gothic, which claims the ranges but lacks the
    ;; org-modern heading stars (U+2726 drew as a hex box).  Segoe UI Symbol
    ;; ships with Windows and has all of them.  Needs a GUI frame, same as
    ;; the font above, hence inside this function.
    (when (member "Segoe UI Symbol" (font-family-list))
      (dolist (range '((#x2700 . #x27BF)      ; Dingbats: ❖ ✦ ✧
                       (#x2B00 . #x2BFF)      ; Misc Symbols and Arrows: ⬡
                       (#x25A0 . #x25FF)))    ; Geometric Shapes: ◈ ◇ ▸
        (set-fontset-font t range "Segoe UI Symbol" nil 'prepend)))))

(if (daemonp)
    ;; No GUI frame at daemon startup — set the font once a client frame opens.
    (add-hook 'server-after-make-frame-hook #'my/set-font)
  (my/set-font))

;; ---------- Evil ----------
(use-package evil
  :init
  (setq evil-want-keybinding nil      ; required by evil-collection
        evil-want-C-u-scroll t
        evil-undo-system 'undo-redo)
  :config
  (evil-mode 1)
  ;; FluidVoice (Windows dictation) delivers a transcript by writing the
  ;; clipboard and sending a synthetic Ctrl+V, then restores the old clipboard
  ;; ~650ms later. Evil's insert-state C-v is `evil-quoted-insert' and the
  ;; global one is `scroll-up-command', so the paste silently vanished. Make
  ;; C-v a clipboard yank everywhere except normal/visual state, where it
  ;; stays `evil-visual-block'. C-q still does quoted-insert.
  (global-set-key (kbd "C-v") #'yank)
  (define-key evil-insert-state-map (kbd "C-v") #'yank))

;; FluidVoice bridge. autohotkey\fluidvoice.ahk swallows Fluid's injected
;; Ctrl+V while an Emacs frame is foreground, writes the transcript to a
;; file and calls this through emacsclient. Any clipboard read from inside
;; Emacs races Fluid's ~650ms clipboard restore whenever Emacs is busy (it
;; pasted older transcripts); handing the text over directly cannot.
(defun mr-x/fluid-insert-file (file)
  "Insert the FluidVoice transcript held in FILE where the user is typing.
In an agent-shell, jump to the prompt first. The text also goes on the
kill ring, so `p' recovers it if the insertion is refused."
  (let ((text (with-temp-buffer
                (let ((coding-system-for-read 'utf-8))
                  (insert-file-contents file))
                (buffer-string)))
        (frame (or (seq-find #'frame-focus-state (frame-list))
                   (selected-frame))))
    (kill-new text)
    (with-selected-window (frame-selected-window frame)
      (when (and (derived-mode-p 'agent-shell-mode)
                 (not (shell-maker-point-at-last-prompt-p)))
        (goto-char (point-max)))
      (condition-case err
          (insert-for-yank text)
        (error (message "FluidVoice: %s — transcript saved to the kill ring (p to paste)"
                        (error-message-string err)))))))

(use-package evil-collection
  :after evil
  :config
  (evil-collection-init))

;; evil binds C-w f (SPC w f) to `ffap-other-window', which Emacs 30 no
;; longer autoloads, so the key was void until ffap happened to load.
(autoload 'ffap-other-window "ffap" nil t)

;; ---------- Leader key (SPC) via general.el ----------
(use-package which-key
  :init (which-key-mode)
  :custom (which-key-idle-delay 0.3))

(use-package general
  :after evil
  :config
  (general-create-definer mr-x/leader-def
    :states '(normal visual motion emacs insert)
    :keymaps 'override
    :prefix "SPC"
    :global-prefix "C-SPC")

  (mr-x/leader-def
    "SPC" '(execute-extended-command :wk "M-x")
    "u"   '(universal-argument :wk "universal arg")  ; mirrors the Mac leader
    ;; files
    "f"   '(:ignore t :wk "file")
    "f f" '(find-file :wk "find file")
    "f s" '(save-buffer :wk "save")
    ;; quick-edit this config (the real git-tracked file under the dotfiles repo,
    ;; not the ~/.emacs.d symlink — so VC/magit act on the repo and there's no
    ;; "follow symlink?" prompt). USERPROFILE on Windows, ~ on macOS.
    "e"   '((lambda () (interactive)
              (find-file (expand-file-name "dotfiles/windows/emacs/.emacs.d/init.el"
                                           (or (getenv "USERPROFILE") "~"))))
            :wk "edit init.el")
    ;; buffers
    "b"   '(:ignore t :wk "buffer")
    "b b" '(switch-to-buffer :wk "switch")
    "b k" '(kill-current-buffer :wk "kill")
    "b r" '(revert-buffer :wk "revert buffer")
    ;; dired
    "d"   '(:ignore t :wk "dired")
    "d d" '(dired :wk "open dired")
    "d j" '(dired-jump :wk "dired jump")
    ;; Real user home: on Windows that's %USERPROFILE% (C:\Users\you), NOT Emacs's
    ;; `~' (which is %APPDATA%\Roaming). On macOS USERPROFILE is unset, so fall to ~.
    "d h" '((lambda () (interactive) (dired (or (getenv "USERPROFILE") "~"))) :wk "dired home")
    "d e" '((lambda () (interactive) (dired (expand-file-name "dotfiles" (or (getenv "USERPROFILE") "~")))) :wk "dired dotfiles")
    "d H" '(dired-omit-mode :wk "toggle omit")
    "d p" '(dired-preview-global-mode :wk "toggle preview")
    ;; git (magit) — same letters as the macOS config
    "g"   '(:ignore t :wk "git")
    "g g" '(magit-status :wk "status")
    "g d" '(magit-diff-unstaged :wk "diff unstaged")
    "g l" '(magit-log-current :wk "log current")
    "g L" '(magit-log-all :wk "log all")
    "g b" '(magit-blame :wk "blame")
    "g c" '(magit-branch-or-checkout :wk "branch or checkout")
    "g p" '(magit-push-current :wk "push current")
    "g P" '(magit-pull-branch :wk "pull branch")
    "g f" '(magit-fetch :wk "fetch")
    ;; windows
    "w"   '(:keymap evil-window-map :package evil :wk "window")
    ;; window layout history, same letters as the Mac
    "h"   '(winner-undo :wk "winner undo")
    "l"   '(winner-redo :wk "winner redo")
    ;; quit / restart
    "q"   '(:ignore t :wk "quit/restart")
    "q r" '(restart-emacs :wk "restart emacs")
    "q q" '(save-buffers-kill-terminal :wk "quit emacs")))

;; The SPC c (agent-shell) map lives in lisp/agent-shell-extras.el, where
;; it mirrors the Mac's map key for key.

;; ---------- Terminal (SPC v) ----------
;; vterm and eat need a Unix pty, which native Windows Emacs doesn't have.
;; ghostel is the first real terminal here: libghostty-vt in a Zig dynamic
;; module, ConPTY underneath on Windows.  It takes vterm's seat in the SPC v
;; group (same letters as the Mac), eshell drops to SPC v e, and Windows
;; Terminal stays on SPC v V for anything that wants its own window.
(use-package ghostel
  :custom
  ;; `ghostel-shell' defaults to $SHELL, which this Emacs build sets to its
  ;; own cmdproxy.exe.  pwsh 7 is not installed; 5.1 carries the riced
  ;; profile from windows/powershell/.
  (ghostel-shell '("C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
                   "-NoLogo"))
  ;; Keep the DLL out of elpa/: Windows cannot delete a loaded DLL, so a
  ;; package upgrade would fail halfway with the module in use.
  (ghostel-module-directory (expand-file-name "ghostel/" user-emacs-directory))
  ;; First use fetches the prebuilt module plus Microsoft's ConPTY
  ;; redistributable from GitHub releases instead of asking.
  (ghostel-module-auto-install 'download))

;; Cursor/point sync for evil states; insert state on entry.
(use-package evil-ghostel
  :after (ghostel evil)
  :hook (ghostel-mode . evil-ghostel-mode))

;; eshell visual commands (less, htop, lazygit...) run in a ghostel buffer.
(use-package ghostel-eshell
  :ensure ghostel
  :hook (eshell-load . ghostel-eshell-visual-command-mode))

;; Popups share the bottom slot: the popup ghostel gets its own buffer name
;; so plain `ghostel' buffers (SPC v b) are left to display normally.
(defconst mr-x/ghostel-popup-name "*ghostel-popup*"
  "Buffer name of the SPC v v ghostel popup.")

(add-to-list 'display-buffer-alist
             `(,(regexp-quote mr-x/ghostel-popup-name)
               (display-buffer-in-side-window)
               (side . bottom)
               (window-height . 0.3)))

(add-to-list 'display-buffer-alist
             '("\\*.*eshell\\*"
               (display-buffer-in-side-window)
               (side . bottom)
               (window-height . 0.3)))

(defun mr-x/ghostel-popup ()
  "Toggle a bottom ghostel popup, started at the project root when in one."
  (interactive)
  (let ((win (get-buffer-window mr-x/ghostel-popup-name)))
    (if win
        (delete-window win)
      (let ((default-directory (if (project-current)
                                   (project-root (project-current))
                                 default-directory))
            (ghostel-buffer-name mr-x/ghostel-popup-name))
        (ghostel)))))

(defun mr-x/ghostel-in-dir ()
  "Open a new ghostel in a directory chosen via prompt."
  (interactive)
  (let ((default-directory (read-directory-name "ghostel dir: ")))
    (ghostel-new)))

(defun mr-x/eshell-popup ()
  "Toggle a bottom eshell, at the project root when in a project."
  (interactive)
  (let ((win (seq-find (lambda (w)
                         (eq (buffer-local-value 'major-mode (window-buffer w))
                             'eshell-mode))
                       (window-list))))
    (if win
        (delete-window win)
      (if (project-current)
          (project-eshell)
        (eshell)))))

(defun mr-x/windows-terminal-here ()
  "Open a Windows Terminal tab at the project root, else `default-directory'."
  (interactive)
  (let* ((proj (project-current))
         (dir (if proj (project-root proj) default-directory))
         ;; No trailing backslash: wt reads \" as an escaped quote.
         (dir (subst-char-in-string
               ?/ ?\\ (directory-file-name (expand-file-name dir)))))
    (start-process "wt" nil "wt.exe" "-w" "0" "nt" "-d" dir)))

;; Insert-state RET in eshell runs `newline' instead of sending the command
;; (same evil-collection snag agent-shell has below).  Make it send.
(with-eval-after-load 'esh-mode
  (with-eval-after-load 'evil
    (evil-define-key '(normal insert) eshell-mode-map
      (kbd "RET") #'eshell-send-input
      [return]    #'eshell-send-input)))

(with-eval-after-load 'general
  (mr-x/leader-def
    "v"   '(:ignore t :wk "terminal")
    "v v" '(mr-x/ghostel-popup :wk "ghostel popup")
    "v b" '(ghostel :wk "ghostel buffer")
    "v n" '(ghostel-new :wk "new ghostel")
    "v d" '(mr-x/ghostel-in-dir :wk "ghostel in dir")
    "v e" '(mr-x/eshell-popup :wk "eshell popup")
    "v E" '(eshell :wk "eshell buffer")
    "v V" '(mr-x/windows-terminal-here :wk "Windows Terminal (project)")))

;; Window-layout undo/redo for SPC h / SPC l.
(winner-mode 1)

;; ---------- Theme: Gruvbox ----------
(use-package doom-themes
  :config
  (setq doom-themes-enable-bold t
        doom-themes-enable-italic t)
  (load-theme 'doom-gruvbox t))

(use-package nerd-icons            ; icon glyphs (FiraCode NF supplies them)
  :custom
  (nerd-icons-font-family "FiraCode Nerd Font Mono")
  (nerd-icons-scale-factor 1.5))   ; make icons bigger everywhere

;; ---------- Ligatures (Fira Code) ----------
;; Needs an Emacs built with Harfbuzz (standard on Windows 28+).
;; If glyphs look broken, check (bound-and-true-p emacs-version) >= 28 + harfbuzz.
(use-package ligature
  :custom
  ;; Not in org: the set below composes "**"/"***" into one glyph, and once
  ;; org-modern has replaced the last star and org-hide has blanked the rest,
  ;; the leftover composition drew a stray asterisk after every heading star.
  (ligature-ignored-major-modes '(minibuffer-inactive-mode org-mode))
  :config
  ;; Enable the standard Fira Code ligature set in all programming + text buffers.
  (ligature-set-ligatures
   't
   '("www" "**" "***" "**/" "*>" "*/" "\\\\" "\\\\\\" "{-" "::" ":::"
     ":=" "!!" "!=" "!==" "-}" "--" "---" "-->" "->" "->>" "-<" "-<<"
     "-~" "#{" "#[" "##" "###" "####" "#(" "#?" "#_" "#_(" ".-" ".="
     ".." "..<" "..." "?=" "??" ";;" "/*" "/**" "//" "///" "/=" "/=="
     "/>" "//=" "&&" "||" "||=" "|=" "|>" "^=" "$>" "++" "+++" "+>"
     "=:=" "==" "===" "==>" "=>" "=>>" "<=" "=<<" "=/=" ">-" ">=" ">=>"
     ">>" ">>-" ">>=" ">>>" "<*" "<*>" "<|" "<|>" "<$" "<$>" "<!--"
     "<-" "<--" "<->" "<+" "<+>" "<=" "<==" "<=>" "<=<" "<>" "<<" "<<-"
     "<<=" "<<<" "<~" "<~~" "</" "</>" "~@" "~-" "~>" "~~" "~~>" "%%"))
  (global-ligature-mode t))

;; File-type icons in dired (folders/files get glyphs)
(use-package nerd-icons-dired
  :hook (dired-mode . nerd-icons-dired-mode))

;; Icons in the minibuffer (vertico) completions
(use-package nerd-icons-completion
  :after marginalia
  :config
  (nerd-icons-completion-mode)
  (add-hook 'marginalia-mode-hook #'nerd-icons-completion-marginalia-setup))

(use-package doom-modeline
  :init (doom-modeline-mode 1)
  :custom
  (doom-modeline-height 42)        ; taller bar so icons aren't cramped
  (doom-modeline-bar-width 4)
  (doom-modeline-modal-modern-icon nil)   ; evil state as a plain colored dot, no letter
  (doom-modeline-buffer-encoding nil))     ; hide the UTF-8/encoding segment

;; ---------- Completion stack (makes LSP feel good) ----------
;; Share interaction with the Mac while keeping package.el installation here.
(require 'mr-x-minibuffer
         (expand-file-name "dotfiles/macos/emacs/.emacs.d/lisp/mr-x-minibuffer.el"
                           (or (getenv "USERPROFILE") "~")))

(use-package vertico
  :init (vertico-mode))

(use-package orderless
  :custom
  (completion-styles '(orderless basic))
  (completion-category-overrides '((file (styles partial-completion)))))

(use-package marginalia
  :init (marginalia-mode))

(use-package consult                 ; consult-ripgrep, consult-line, consult-buffer...
  :bind (("C-s"     . consult-line)
         ("C-x b"   . consult-buffer)
         ("M-g g"   . consult-goto-line)
         ("M-g M-g" . consult-goto-line)
         ("M-s r"   . consult-ripgrep)
         ("M-s l"   . consult-line)
         ("M-s f"   . consult-find))
  :config
  ;; Use consult for xref
  (setq xref-show-xrefs-function #'consult-xref
        xref-show-definitions-function #'consult-xref)
  ;; Auto-preview in consult-imenu
  (consult-customize consult-imenu :preview-key 'any))

(use-package corfu
  :init (global-corfu-mode)
  :custom
  (corfu-auto t)                  ; auto-popup completions
  (corfu-auto-delay 0.1)
  (corfu-auto-prefix 2))

;; ---------- Org ----------
;; Keyword colours: the Mac's dark palette (mr-x/palettes in emacs.org:
;; red, orange, mint, muted) as text, not pill backgrounds.
;; Top level, not :init, because use-package expands :custom before :init.
(defconst my/org-todo-faces
  '(("TODO"      . (:foreground "#FF1800" :weight bold))
    ("NEXT"      . (:foreground "#fe8019" :weight bold))
    ("WAIT"      . (:foreground "#B7CBA8" :weight bold))
    ("DONE"      . (:foreground "#62656A" :weight bold))
    ("CANCELLED" . (:foreground "#62656A" :weight bold)))
  "TODO keyword faces used by both org and org-modern.")

(use-package org
  :ensure nil                          ; built-in
  :custom
  (org-startup-indented t)             ; clean nested indentation
  (org-pretty-entities t)              ; \alpha -> α
  (org-hide-emphasis-markers t)        ; hide the *_/ markup chars
  (org-ellipsis " ‧")                  ; fold indicator, same dot as the Mac
  (org-startup-folded 'content)        ; open folded to headings
  (org-log-done 'time)                 ; stamp a time when you mark DONE
  (org-src-fontify-natively t)         ; syntax-highlight code blocks
  (org-edit-src-content-indentation 0)
  (org-todo-keywords
   '((sequence "TODO(t)" "NEXT(n)" "WAIT(w)" "|" "DONE(d)" "CANCELLED(c)")))
  (org-todo-keyword-faces my/org-todo-faces)
  :config
  ;; Heading faces ported from the Mac emacs.org: a gruvbox ramp down the
  ;; levels (orange, gold, green, aqua, purple, then two greys), level 1
  ;; slightly larger.
  (custom-set-faces
   '(org-level-1 ((t (:foreground "#fe8019" :weight bold :height 1.15))))
   '(org-level-2 ((t (:foreground "#fabd2f" :weight bold))))
   '(org-level-3 ((t (:foreground "#b8bb26"))))
   '(org-level-4 ((t (:foreground "#8ec07c"))))
   '(org-level-5 ((t (:foreground "#d3869b"))))
   '(org-level-6 ((t (:foreground "#505050"))))
   '(org-level-7 ((t (:foreground "#404040"))))
   '(org-link ((t (:foreground "#83a598" :underline t))))))

(use-package org-modern              ; modern, clean org styling
  :after org
  :hook ((org-mode . org-modern-mode)
         (org-agenda-finalize . org-modern-agenda))
  :custom
  ;; Same heading bullets as the Mac, one glyph per level.
  (org-modern-star 'replace)
  (org-modern-replace-stars "❖✦⬡◈✧◇▸")
  (org-modern-hide-stars nil)
  (org-modern-table nil)
  ;; Foreground-only faces: org-modern then skips its inverse-video
  ;; `org-modern-todo' label, so keywords are coloured text, no background.
  (org-modern-todo-faces my/org-todo-faces)
  :config
  ;; org-modern pads each keyword with a space on both sides (hardcoded
  ;; display properties, the pill's inner padding).  Without a pill that
  ;; is just a two-space gap on either side of TODO, so drop it.
  (defun my/org-modern-todo-unpad ()
    "Remove the display padding org-modern puts around a TODO keyword."
    (remove-list-of-text-properties (match-beginning 1) (match-end 1) '(display)))
  (advice-add 'org-modern--todo :after #'my/org-modern-todo-unpad))

;; ---------- Markdown: editing + gruvbox preview inside Emacs ----------
;; Same editing stack as the Mac: markdown-mode wearing the gruvbox faces
;; (they match the preview), poly-markdown owning .md so fenced code blocks
;; get their language's highlighting.  This Emacs build has no xwidgets, so
;; the Mac's markdown-xwidget preview cannot run here; the preview is
;; pandoc -> eww (markdown-live-preview-mode: C-c C-c l, re-renders on save,
;; also on the Mac's C-c C-c x), with the eww/shr faces set to gruvbox
;; below.  C-c C-c p still opens the pandoc HTML in the browser.
;; pandoc: scoop install pandoc.
(use-package markdown-mode
  :custom
  ;; A list, not a string, so the filter path survives markdown-mode's
  ;; space-splitting.  The filter maps fence languages pandoc cannot
  ;; highlight (elisp, sh, ps1...) onto ones it can.
  (markdown-command
   (list "pandoc" "--lua-filter"
         (expand-file-name "dotfiles/windows/emacs/.emacs.d/pandoc-lang-aliases.lua"
                           (or (getenv "USERPROFILE") "~"))))
  (markdown-live-preview-delete-export 'delete-on-export)  ; no .html litter
  ;; Browser preview (C-c C-c p) wears gruvbox too: markdown-mode links
  ;; this stylesheet into the page, and pandoc's token classes give the
  ;; code blocks syntax colours there.  Repo path, not ~ (see dired home).
  (markdown-css-paths
   (list (concat "file:///"
                 (expand-file-name "dotfiles/windows/emacs/.emacs.d/markdown-gruvbox.css"
                                   (or (getenv "USERPROFILE") "~")))))
  :bind (:map markdown-mode-map
         ("C-c C-c x" . markdown-live-preview-mode))
  :config
  ;; Gruvbox-styled markdown faces (matches preview CSS)
  (custom-set-faces
   ;; Headings - orange
   '(markdown-header-face-1 ((t (:foreground "#fe8019" :weight bold :height 1.4))))
   '(markdown-header-face-2 ((t (:foreground "#fe8019" :weight bold :height 1.3))))
   '(markdown-header-face-3 ((t (:foreground "#fe8019" :weight bold :height 1.2))))
   '(markdown-header-face-4 ((t (:foreground "#fabd2f" :weight bold :height 1.1))))
   '(markdown-header-face-5 ((t (:foreground "#fabd2f" :weight bold))))
   '(markdown-header-face-6 ((t (:foreground "#928374" :weight bold))))
   ;; Code - aqua
   '(markdown-code-face ((t (:foreground "#8ec07c" :background "#3c3836"))))
   '(markdown-inline-code-face ((t (:foreground "#8ec07c" :background "#3c3836"))))
   '(markdown-pre-face ((t (:foreground "#8ec07c" :background "#3c3836"))))
   ;; Links - blue
   '(markdown-link-face ((t (:foreground "#83a598"))))
   '(markdown-url-face ((t (:foreground "#83a598" :underline t))))
   ;; Bold/Italic - yellow/purple
   '(markdown-bold-face ((t (:foreground "#fabd2f" :weight bold))))
   '(markdown-italic-face ((t (:foreground "#d3869b" :slant italic))))
   ;; Lists - green
   '(markdown-list-face ((t (:foreground "#b8bb26"))))
   ;; Blockquote - gray
   '(markdown-blockquote-face ((t (:foreground "#928374" :slant italic))))
   ;; Markup characters - dimmed
   '(markdown-markup-face ((t (:foreground "#665c54"))))))

;; Syntax highlighting in markdown code blocks
(use-package polymode)

(use-package poly-markdown
  :after (polymode markdown-mode)
  :mode ("\.md\'" . poly-markdown-mode)
  :config
  ;; Suppress org-element parser errors in polymode indirect buffers
  ;; (org-mode chokes on markdown ** syntax in ```org code blocks)
  (add-to-list 'warning-suppress-types '(org-element)))

;; The rendered preview lives in eww; shr draws it with these faces, so
;; the preview wears the same gruvbox as the source buffer.
(with-eval-after-load 'shr
  (custom-set-faces
   '(shr-h1 ((t (:foreground "#fe8019" :weight bold :height 1.4))))
   '(shr-h2 ((t (:foreground "#fe8019" :weight bold :height 1.3))))
   '(shr-h3 ((t (:foreground "#fe8019" :weight bold :height 1.2))))
   '(shr-h4 ((t (:foreground "#fabd2f" :weight bold :height 1.1))))
   '(shr-h5 ((t (:foreground "#fabd2f" :weight bold))))
   '(shr-h6 ((t (:foreground "#928374" :weight bold))))
   '(shr-code ((t (:foreground "#8ec07c" :background "#3c3836"))))
   '(shr-link ((t (:foreground "#83a598" :underline t))))))

;; ---------- Dired ----------
(use-package dired
  :ensure nil                          ; built-in
  :commands (dired dired-jump)
  :after evil
  :custom
  (dired-kill-when-opening-new-dired-buffer t)
  (dired-listing-switches "-alh")      ; ls-lisp-safe (no GNU-only flags on Windows)
  :config
  ;; Windows has no GNU ls; use Emacs' built-in ls-lisp and group dirs first.
  (require 'ls-lisp)
  (setq ls-lisp-use-insert-directory-program nil
        ls-lisp-dirs-first t)
  ;; h/l navigate like a file tree; Y copies the bare filename.
  ;; Bound on dired-mode-map at config time so it wins over evil-collection
  ;; without the buffer-local-keymap timing issues of evil-local-set-key.
  (evil-define-key 'normal dired-mode-map
    "h" 'dired-up-directory
    "l" 'dired-find-file
    "Y" (lambda () (interactive) (dired-copy-filename-as-kill 0)))
  ;; Clean view: hide details + line numbers; omit dotfiles outside git repos.
  (add-hook 'dired-mode-hook
            (lambda ()
              (dired-hide-details-mode 1)
              (display-line-numbers-mode 1)
              (unless (locate-dominating-file default-directory ".git")
                (dired-omit-mode 1)))))

(use-package dired-x
  :ensure nil                          ; built-in
  :after dired
  :config
  (setq dired-omit-files (rx (seq bol "."))   ; hide dotfiles when omit is on
        dired-omit-verbose nil))

(use-package dired-preview              ; SPC d p toggles a side-window preview
  :after dired
  :config
  (setq dired-preview-delay 0.2
        dired-preview-display-action-alist
        '((display-buffer-in-side-window)
          (side . right)
          (window-width . 0.5))))

;; ---------- Git (magit) ----------
;; Essentials build: plain magit, no delta/difftastic/pane-aware display (those
;; are the macOS setup). Deferred — first `SPC g g' autoloads and installs it.
(use-package magit
  :commands (magit-status magit-get-current-branch)
  :custom
  ;; magit takes over the frame, restores the window layout on quit.
  (magit-display-buffer-function #'magit-display-buffer-fullframe-status-v1))

;; ---------- Lua + LSP (eglot is built-in) ----------
(use-package lua-mode
  :mode "\\.lua\\'"
  :custom (lua-indent-level 4))

(use-package eglot
  :ensure nil                     ; ships with Emacs
  :hook (lua-mode . eglot-ensure)
  :config
  ;; lua-language-server must be on PATH (install via scoop — see notes).
  (add-to-list 'eglot-server-programs
               '(lua-mode . ("lua-language-server"))))

;; ---------- agent-shell (LLM agents in a native buffer) ----------
(use-package acp)                  ; ACP transport (MELPA)
(use-package shell-maker)          ; shell infrastructure agent-shell builds on

;; SPC c c — new agent shell, replacing the current window when already in one
;; (ported from the macOS config; uses agent-shell internals, so require it first).
(defun mr-x/agent-shell-new-smart ()
  "Create a new agent shell, replacing the current window if already in one."
  (interactive)
  (require 'agent-shell)
  (let* ((config (or (agent-shell--resolve-preferred-config)
                     (agent-shell-select-config :prompt "Start new agent: ")
                     (error "No agent config found")))
         (shell-buffer (agent-shell--start :config config
                                           :no-focus t
                                           :new-session t)))
    (if (derived-mode-p 'agent-shell-mode
                        'agent-shell-viewport-view-mode
                        'agent-shell-viewport-edit-mode)
        ;; Already in agent-shell: replace the current window.
        (if agent-shell-prefer-viewport-interaction
            (agent-shell-viewport--show-buffer :shell-buffer shell-buffer)
          (switch-to-buffer shell-buffer))
      ;; Not in agent-shell: display normally.
      (if agent-shell-prefer-viewport-interaction
          (agent-shell-viewport--show-buffer :shell-buffer shell-buffer)
        (pop-to-buffer shell-buffer)))))

(use-package agent-shell
  :after (acp shell-maker)
  :custom
  ;; Plain one-line header (Model/Mode) instead of the big graphical C logo.
  (agent-shell-header-style 'text)
  ;; Recolor input once it's submitted (lime) and the prompt marker (gold) — gruvbox.
  :hook ((agent-shell-mode . (lambda ()
                               ;; Sent input text turns lime once submitted.
                               (face-remap-add-relative 'comint-highlight-input
                                                        :foreground "#b8bb26")))
         (agent-shell-mode . (lambda ()
                               ;; Prompt symbol gruvbox gold.
                               (face-remap-add-relative 'comint-highlight-prompt
                                                        :foreground "#fabd2f"))))
  :config
  ;; Use your existing Claude CLI login — no API key needed.
  (setq agent-shell-anthropic-default-model-id "default")  ; Opus 5.5 1M; aliases resolve in claude-agent-acp
  (setq agent-shell-anthropic-authentication
        (agent-shell-anthropic-make-authentication :login t))
  ;; Inherit the shell environment (PATH, ANTHROPIC_API_KEY if you set one, etc.)
  (setq agent-shell-anthropic-claude-environment
        (agent-shell-make-environment-variables :inherit-env t))
  ;; Codex rides the ChatGPT login from `codex login' (~/.codex/auth.json),
  ;; same no-API-key setup. Needs npm -g @openai/codex and
  ;; @agentclientprotocol/codex-acp; the adapter runs its own bundled codex
  ;; unless CODEX_PATH says otherwise. Launched from the SPC c P presets.
  (setq agent-shell-openai-authentication
        (agent-shell-openai-make-authentication :login t))
  (setq agent-shell-openai-codex-environment
        (agent-shell-make-environment-variables :inherit-env t))
  ;; Image input on Windows (port of the Mac pngpaste/screencapture flow):
  ;;   p in a shell (agent-shell-yank-dwim) -> pastes a clipboard image; uses the
  ;;     built-in "powershell" clipboard handler (Get-Clipboard -Format image),
  ;;     so just Win+Shift+S a region, then p. Works with no extra config.
  ;;   SPC c s (agent-shell-send-screenshot) -> launches the native ms-screenclip
  ;;     overlay (Windows' equivalent of `screencapture -i`) via a wrapper script.
  ;;     The default command is the X11 tool /usr/bin/import, which doesn't exist
  ;;     on Windows, so point it at agent-shell-snip.ps1. -Sta is required for
  ;;     clipboard access from PowerShell.
  (when (eq system-type 'windows-nt)
    (setq agent-shell-screenshot-command
          (list "powershell" "-NoProfile" "-Sta" "-ExecutionPolicy" "Bypass"
                ;; NOTE: on Windows, Emacs `~' (HOME) is %APPDATA%\Roaming, NOT
                ;; %USERPROFILE%, so "~/dotfiles/..." points at a phantom folder.
                ;; Anchor to USERPROFILE, where the dotfiles repo actually lives.
                "-File" (expand-file-name "dotfiles/windows/powershell/agent-shell-snip.ps1"
                                          (getenv "USERPROFILE")))))
  ;; Make the Windows key act as Emacs `super', so s-<return> below mirrors the
  ;; Mac Cmd+Enter. Left at pass-to-system t so a *lone* Win press still opens the
  ;; Start menu and glazewm's lwin+<key> combos keep working (glazewm doesn't bind
  ;; Win+Enter, so that combo falls through to Emacs).
  (when (eq system-type 'windows-nt)
    (setq w32-lwindow-modifier 'super
          w32-rwindow-modifier 'super)
    ;; kanata taps a throwaway <f18> whenever the d/k Super home-row mod engages
    ;; (it cancels the Windows Start-menu pop). Swallow it so holding Super here
    ;; doesn't spam "<f18> is undefined" in the echo area.
    (global-set-key (kbd "<f18>")   #'ignore)
    (global-set-key (kbd "s-<f18>") #'ignore))
  ;; Chat mode is a cosmetic relabel declined on 2026-09-23 (same call as
  ;; the Mac). The persistent prompt stays on at its upstream default.
  (setq agent-shell-chat-mode-enabled nil)
  ;; Never show the "new session / resume previous" picker: every shell
  ;; starts fresh, same as the Mac. Deliberate resumes go through
  ;; agent-recall, which passes session ids explicitly and ignores this.
  (setq agent-shell-session-strategy 'new)
  ;; evil-collection binds insert-state RET to `newline' and normal-state RET
  ;; to the bare `shell-maker-submit'; make both run `agent-shell-submit',
  ;; upstream's own RET: it queues the prompt while the agent is busy (M-RET
  ;; steers instead) and falls through to `shell-maker-submit' when idle, so
  ;; the refs advice still fires.
  (with-eval-after-load 'evil
    (evil-define-key '(normal insert) agent-shell-mode-map
      (kbd "RET") #'agent-shell-submit
      [return]    #'agent-shell-submit)
    ;; Win+Enter submits from any mode (Windows port of Mac's Cmd+Enter "lazy mode").
    (evil-define-key '(normal insert) agent-shell-mode-map
      (kbd "s-<return>") #'agent-shell-submit
      [s-return]         #'agent-shell-submit))
  ;; The October build zebra-stripes markdown tables, and its stripe face
  ;; inherits `lazy-highlight', which doom-gruvbox paints as the gold
  ;; isearch block (#fabd2f bg, bold dark text). Every other row lit up
  ;; like a search hit. Use a quiet gruvbox bg0_s stripe instead.
  (with-eval-after-load 'agent-shell-markdown
    (set-face-attribute 'agent-shell-markdown-table-zebra nil
                        :inherit 'agent-shell-markdown-table
                        :background "#32302f"))
  ;; One prompt symbol for every agent (port of the Mac's block). Upstream
  ;; gives each provider its own verbose prompt ("Claude> ", "Codex> ",
  ;; "Gemini> ", ...). Every provider builds its config through
  ;; `agent-shell-make-agent-config', so filtering that one factory
  ;; standardizes the prompt across all of them at once, including
  ;; providers added later.
  (defvar mr-x/agent-shell-prompt "◇ "
    "Input prompt used for every agent-shell agent by default.
A clean ◇ (modal \"possibility\").")

  (defvar mr-x/agent-shell-prompt-alist nil
    "Per-agent input prompt overrides, keyed by config `:identifier'.
Entries look like (gemini-cli . \"G> \").  Any agent not listed here
uses `mr-x/agent-shell-prompt'.")

  (defun mr-x/agent-shell-prompt-for (identifier)
    "Return the input prompt configured for agent IDENTIFIER."
    (or (alist-get identifier mr-x/agent-shell-prompt-alist)
        mr-x/agent-shell-prompt))

  (defun mr-x/agent-shell-standardize-prompt (config)
    "Replace CONFIG's provider-specific input prompt with ours.
Filters the return value of `agent-shell-make-agent-config', so
authentication, models, session modes, and future config fields keep
coming from the provider untouched."
    (when (consp config)
      (let ((prompt (mr-x/agent-shell-prompt-for
                     (alist-get :identifier config))))
        (setf (alist-get :shell-prompt config)
              (propertize prompt 'face '(:foreground "#fabd2f" :weight bold))
              (alist-get :shell-prompt-regexp config) (regexp-quote prompt))))
    config)

  (unless (advice-member-p #'mr-x/agent-shell-standardize-prompt
                           'agent-shell-make-agent-config)
    (advice-add 'agent-shell-make-agent-config
                :filter-return
                #'mr-x/agent-shell-standardize-prompt))

  ;; Make Claude Code the default agent. :shell-prompt is omitted
  ;; deliberately; the advice above fills it in like it does for every
  ;; other agent.
  (setq agent-shell-preferred-agent-config
        (agent-shell-make-agent-config
         :identifier 'claude-code
         :mode-line-name "Claude"
         :buffer-name "Claude"
         :welcome-function nil  ; no welcome banner (shell-maker skips it when nil)
         :client-maker (lambda (buffer)
                         (agent-shell-anthropic-make-claude-client :buffer buffer))
         :default-model-id (lambda () agent-shell-anthropic-default-model-id))))
;; Start it with  M-x agent-shell

;; ---------- agent-recall (search/browse/resume past agent-shell sessions) ----------
;; On MELPA, so package.el fetches it (unlike the Mac config, which loads a local
;; checkout). consult is used for search since deadgrep isn't installed here.
(use-package agent-recall
  :after agent-shell
  :init
  ;; consult-search lives in agent-recall-consult.el, not the main file, so it
  ;; needs its own autoload rather than going through :commands.
  (autoload 'agent-recall-consult-search "agent-recall-consult" nil t)
  :commands (agent-recall-search
             agent-recall-browse agent-recall-resume
             agent-recall-backfill agent-recall-stats)
  :custom
  (agent-recall-search-paths '("~"))
  (agent-recall-search-function 'consult)
  (agent-recall-browse-sort 'modified-desc)
  (agent-recall-browse-preview t)
  :hook (agent-shell-mode . agent-recall-track-sessions))

;; ---------- MrX agent-shell comfort layer ----------
;; major-pane side panel + display routing, smart editing keys, launch
;; presets, picker-based send commands. The portable modules
;; (major-pane.el, mr-x-agent-send.el) load straight from the repo's
;; macos/ lisp dir — one copy, both machines; the Windows glue lives in
;; windows/emacs/.emacs.d/lisp/agent-shell-extras.el. Anchored to
;; USERPROFILE (Emacs `~' on Windows is %APPDATA%\Roaming, not the home
;; the dotfiles repo lives under).
(dolist (dir '("dotfiles/macos/emacs/.emacs.d/lisp"
               "dotfiles/macos/emacs/.emacs.d/lisp/project-dashboard"
               "dotfiles/windows/emacs/.emacs.d/lisp"))
  (add-to-list 'load-path (expand-file-name dir (or (getenv "USERPROFILE") "~"))))
(require 'agent-shell-extras)

;; ---------- Projects: projectile + project-dashboard (SPC P) ----------
;; The dashboard is the Mac's module, shared from the macos/ lisp dir like
;; major-pane. It hard-requires projectile, which is otherwise only here
;; for project roots and the known-projects list. The project list below
;; is this machine's own (the module's default is the Mac's) and also
;; feeds the SPC c C picker in agent-shell-extras.el.
(use-package projectile
  :init
  (projectile-mode +1)
  :config
  (setq projectile-completion-system 'default))

(with-eval-after-load 'projectile
  (require 'project-dashboard)
  (setq project-dashboard-projects
        `(("dotfiles" . ,(expand-file-name "dotfiles" (or (getenv "USERPROFILE") "~")))
          ("reskate" . "C:/Games/ReSkate")))
  ;; `a' in a dashboard asks for a launch preset, same as SPC c P.
  (setq project-dashboard-agent-shell-function #'mr-x/agent-shell-start-preset)
  (setq projectile-switch-project-action #'project-dashboard--projectile-switch-action))

(mr-x/leader-def
  "P"   '(:ignore t :wk "project dashboard")
  "P p" '(project-dashboard-launch :wk "launch project")
  "P a" '(project-dashboard-add-project :wk "add project")
  "P d" '(project-dashboard-open :wk "dashboard for current"))

;; The repo's .dir-locals.el sets mr-x/project-commands (per-project commands,
;; consumed by mr-x/project-command on the Mac side). This Windows config
;; doesn't use it, but Emacs still processes the dir-local on every visit and
;; flags the `-commands' suffix as risky, prompting every time. Mirror the Mac
;; side's predicate so the value is known-safe.
(put 'mr-x/project-commands 'safe-local-variable #'listp)

(provide 'init)
;;; init.el ends here
(custom-set-variables
 ;; custom-set-variables was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
 '(package-selected-packages
   '(agent-recall consult corfu dired-preview doom-modeline doom-themes
                  evil-collection evil-ghostel general ghostel
                  ligature lua-mode marginalia markdown-mode
                  nerd-icons-completion nerd-icons-dired orderless
                  org-modern poly-markdown polymode vertico))
 '(project-dashboard-projects
   '(("dotfiles" . "c:/Users/mnand/dotfiles")
     ("reskate" . "C:/Games/ReSkate")
     ("reskate mods dash" . "c:/Users/mnand/Projects/reskate-mods/")
     ("ReSkate Visage"
      . "c:/Users/mnand/Projects/ReSkate/ReSkate-Visage/"))))
(custom-set-faces
 ;; custom-set-faces was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
 '(markdown-blockquote-face ((t (:foreground "#928374" :slant italic))))
 '(markdown-bold-face ((t (:foreground "#fabd2f" :weight bold))))
 '(markdown-code-face ((t (:foreground "#8ec07c" :background "#3c3836"))))
 '(markdown-header-face-1 ((t (:foreground "#fe8019" :weight bold :height 1.4))))
 '(markdown-header-face-2 ((t (:foreground "#fe8019" :weight bold :height 1.3))))
 '(markdown-header-face-3 ((t (:foreground "#fe8019" :weight bold :height 1.2))))
 '(markdown-header-face-4 ((t (:foreground "#fabd2f" :weight bold :height 1.1))))
 '(markdown-header-face-5 ((t (:foreground "#fabd2f" :weight bold))))
 '(markdown-header-face-6 ((t (:foreground "#928374" :weight bold))))
 '(markdown-inline-code-face ((t (:foreground "#8ec07c" :background "#3c3836"))))
 '(markdown-italic-face ((t (:foreground "#d3869b" :slant italic))))
 '(markdown-link-face ((t (:foreground "#83a598"))))
 '(markdown-list-face ((t (:foreground "#b8bb26"))))
 '(markdown-markup-face ((t (:foreground "#665c54"))))
 '(markdown-pre-face ((t (:foreground "#8ec07c" :background "#3c3836"))))
 '(markdown-url-face ((t (:foreground "#83a598" :underline t))))
 '(org-level-1 ((t (:foreground "#fe8019" :weight bold :height 1.15))))
 '(org-level-2 ((t (:foreground "#fabd2f" :weight bold))))
 '(org-level-3 ((t (:foreground "#b8bb26"))))
 '(org-level-4 ((t (:foreground "#8ec07c"))))
 '(org-level-5 ((t (:foreground "#d3869b"))))
 '(org-level-6 ((t (:foreground "#505050"))))
 '(org-level-7 ((t (:foreground "#404040"))))
 '(org-link ((t (:foreground "#83a598" :underline t))))
 '(shr-code ((t (:foreground "#8ec07c" :background "#3c3836"))))
 '(shr-h1 ((t (:foreground "#fe8019" :weight bold :height 1.4))))
 '(shr-h2 ((t (:foreground "#fe8019" :weight bold :height 1.3))))
 '(shr-h3 ((t (:foreground "#fe8019" :weight bold :height 1.2))))
 '(shr-h4 ((t (:foreground "#fabd2f" :weight bold :height 1.1))))
 '(shr-h5 ((t (:foreground "#fabd2f" :weight bold))))
 '(shr-h6 ((t (:foreground "#928374" :weight bold))))
 '(shr-link ((t (:foreground "#83a598" :underline t)))))
