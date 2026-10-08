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
      (add-to-list 'default-frame-alist `(font . ,font))))) ; future frames

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
  (evil-mode 1))

(use-package evil-collection
  :after evil
  :config
  (evil-collection-init))

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
    ;; quit / restart
    "q"   '(:ignore t :wk "quit/restart")
    "q r" '(restart-emacs :wk "restart emacs")
    "q q" '(save-buffers-kill-terminal :wk "quit emacs")))

;; The SPC c (agent-shell) map lives in lisp/agent-shell-extras.el, where
;; it mirrors the Mac's map key for key.

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
  ;; Preview on consult-line: grab symbol at point
  (consult-customize consult-line :initial (thing-at-point 'symbol))
  ;; Auto-preview in consult-imenu
  (consult-customize consult-imenu :preview-key 'any))

(use-package corfu
  :init (global-corfu-mode)
  :custom
  (corfu-auto t)                  ; auto-popup completions
  (corfu-auto-delay 0.1)
  (corfu-auto-prefix 2))

;; ---------- Org ----------
(use-package org
  :ensure nil                          ; built-in
  :custom
  (org-startup-indented t)             ; clean nested indentation
  (org-pretty-entities t)              ; \alpha -> α
  (org-hide-emphasis-markers t)        ; hide the *_/ markup chars
  (org-ellipsis " ▾")                  ; nicer fold indicator
  (org-startup-folded 'content)        ; open folded to headings
  (org-log-done 'time)                 ; stamp a time when you mark DONE
  (org-src-fontify-natively t)         ; syntax-highlight code blocks
  (org-edit-src-content-indentation 0)
  (org-todo-keywords
   '((sequence "TODO(t)" "NEXT(n)" "WAIT(w)" "|" "DONE(d)" "CANCELLED(c)"))))

(use-package org-modern              ; modern, clean org styling
  :after org
  :hook ((org-mode . org-modern-mode)
         (org-agenda-finalize . org-modern-agenda)))

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
  ;; Make Claude Code the default agent, with a clean ◇ prompt (modal "possibility").
  (setq agent-shell-preferred-agent-config
        (agent-shell-make-agent-config
         :identifier 'claude-code
         :mode-line-name "Claude"
         :buffer-name "Claude"
         :shell-prompt (propertize "◇ " 'face '(:foreground "#fabd2f" :weight bold))
         :shell-prompt-regexp "◇ "
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
               "dotfiles/windows/emacs/.emacs.d/lisp"))
  (add-to-list 'load-path (expand-file-name dir (or (getenv "USERPROFILE") "~"))))
(require 'agent-shell-extras)

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
                  evil-collection general ligature lua-mode marginalia
                  markdown-mode nerd-icons-completion nerd-icons-dired
                  orderless org-modern poly-markdown polymode vertico)))
(custom-set-faces
 ;; custom-set-faces was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
 )
