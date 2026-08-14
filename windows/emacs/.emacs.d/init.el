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
    ;; windows
    "w"   '(:keymap evil-window-map :package evil :wk "window")
    ;; quit / restart
    "q"   '(:ignore t :wk "quit/restart")
    "q r" '(restart-emacs :wk "restart emacs")
    "q q" '(save-buffers-kill-terminal :wk "quit emacs"))

  ;; ---- Agent Shell (only commands present in this agent-shell build) ----
  (mr-x/leader-def
    "c"     '(:ignore t :wk "agent-shell")
    "c c"   '(agent-shell :wk "start")
    "c n"   '(mr-x/agent-shell-new-smart :wk "new shell (smart)")
    "c o"   '(agent-shell-other-buffer :wk "other buffer")
    "c i"   '(agent-shell-interrupt :wk "interrupt")
    "c q"   '(agent-shell-prompt-queue :wk "queue request")
    "c p"   '(agent-shell-yank-dwim :wk "paste (smart)")
    "c d"   '(agent-shell-send-dwim :wk "send dwim")
    "c R"   '(agent-shell-send-region :wk "send region")
    "c f"   '(agent-shell-send-file :wk "send file")
    "c F"   '(agent-shell-send-other-file :wk "send other file")
    "c s"   '(agent-shell-send-screenshot :wk "send screenshot")
    "c T"   '(agent-shell-open-transcript :wk "transcript")
    "c ."   '(agent-shell-set-session-model :wk "set model")
    "c ,"   '(:ignore t :wk "prompts")
    "c , p" '(agent-shell-prompt-compose :wk "compose prompt")
    "c m"   '(:ignore t :wk "mode/permissions")
    "c m m" '(agent-shell-set-session-mode :wk "pick mode")
    "c m c" '(agent-shell-cycle-session-mode :wk "cycle mode")
    "c m d" '((lambda () (interactive) (mr-x/agent-shell-set-mode-direct "default")) :wk "default")
    "c m e" '((lambda () (interactive) (mr-x/agent-shell-set-mode-direct "acceptEdits")) :wk "accept edits")
    "c m p" '((lambda () (interactive) (mr-x/agent-shell-set-mode-direct "plan")) :wk "plan")
    "c m a" '((lambda () (interactive) (mr-x/agent-shell-set-mode-direct "dontAsk")) :wk "don't ask")
    "c m b" '((lambda () (interactive) (mr-x/agent-shell-set-mode-direct "bypassPermissions")) :wk "bypass perms")
    "c l"   '(:ignore t :wk "logs")
    "c l l" '(agent-shell-toggle-logging :wk "toggle logging")
    "c l v" '(agent-shell-view-traffic :wk "view traffic")
    "c l a" '(agent-shell-view-acp-logs :wk "view acp logs")
    "c l r" '(agent-shell-reset-logs :wk "reset logs")
    "c a"   '(:ignore t :wk "recall")
    "c a s" '(agent-recall-consult-search :wk "search")
    "c a b" '(agent-recall-browse :wk "browse")
    "c a r" '(agent-recall-resume :wk "resume")
    "c a B" '(agent-recall-backfill :wk "backfill")
    "c a t" '(agent-recall-stats :wk "stats")))

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

;; SPC c n — new agent shell, replacing the current window when already in one
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

;; SPC c m d/e/p/a/b — set the agent-shell session mode (permission level)
;; directly, skipping the completing-read picker (ported from the macOS config).
(defun mr-x/agent-shell-set-mode-direct (mode-id)
  "Set agent-shell session mode directly by MODE-ID, skipping the picker."
  (require 'agent-shell)
  (let* ((buf (or (and (derived-mode-p 'agent-shell-mode) (current-buffer))
                  (seq-first (agent-shell-project-buffers))))
         (state (and buf (buffer-local-value 'agent-shell--state buf))))
    (unless buf (user-error "No agent-shell buffer found"))
    (with-current-buffer buf
      (unless (map-nested-elt state '(:session :id))
        (user-error "No active session"))
      (let ((current (map-nested-elt state '(:session :mode-id))))
        (when (and current (string= mode-id current))
          (user-error "Already in %s mode"
                      (or (agent-shell--resolve-session-mode-name
                           mode-id (agent-shell--get-available-modes state))
                          mode-id)))
        (agent-shell--send-request
         :state state
         :client (map-elt state :client)
         :request (acp-make-session-set-mode-request
                   :session-id (map-nested-elt state '(:session :id))
                   :mode-id mode-id)
         :buffer buf
         :on-success (lambda (_)
                       (let ((session (map-elt (agent-shell--state) :session)))
                         (map-put! session :mode-id mode-id)
                         (map-put! (agent-shell--state) :session session)
                         (message "Session mode: %s"
                                  (or (agent-shell--resolve-session-mode-name
                                       mode-id (agent-shell--get-available-modes (agent-shell--state)))
                                      mode-id)))
                       (agent-shell--update-header-and-mode-line))
         :on-failure (lambda (err _)
                       (message "Failed to set mode: %s" err)))))))

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
  (setq agent-shell-anthropic-default-model-id "claude-opus-4-8")  ; change to taste
  (setq agent-shell-anthropic-authentication
        (agent-shell-anthropic-make-authentication :login t))
  ;; Inherit the shell environment (PATH, ANTHROPIC_API_KEY if you set one, etc.)
  (setq agent-shell-anthropic-claude-environment
        (agent-shell-make-environment-variables :inherit-env t))
  ;; Image input on Windows (port of the Mac pngpaste/screencapture flow):
  ;;   SPC c p (agent-shell-yank-dwim)   -> pastes a clipboard image; uses the
  ;;     built-in "powershell" clipboard handler (Get-Clipboard -Format image),
  ;;     so just Win+Shift+S a region, then SPC c p. Works with no extra config.
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
  ;; evil-collection binds insert-state RET to `newline'; make RET submit instead.
  (with-eval-after-load 'evil
    (evil-define-key 'insert agent-shell-mode-map
      (kbd "RET") #'shell-maker-submit
      [return]    #'shell-maker-submit)
    ;; Win+Enter submits from any mode (Windows port of Mac's Cmd+Enter "lazy mode").
    (evil-define-key '(normal insert) agent-shell-mode-map
      (kbd "s-<return>") #'shell-maker-submit
      [s-return]         #'shell-maker-submit))
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

(provide 'init)
;;; init.el ends here
(custom-set-variables
 ;; custom-set-variables was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
 '(package-selected-packages nil))
(custom-set-faces
 ;; custom-set-faces was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
 )
