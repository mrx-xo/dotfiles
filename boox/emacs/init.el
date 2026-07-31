;;; init.el --- BOOX Tab Ultra C (Termux) -*- lexical-binding: t; -*-

;; Minimal e-ink Emacs. Terminal-only (no GUI), tuned for a screen that
;; hates animation and loves contrast. Source of truth:
;; ~/.dotfiles/boox/emacs/init.el on MrX — deploy with boox/deploy.sh.
;; Philosophy: field terminal, not workstation. Read org, capture notes,
;; browse synced code. The Macs do the heavy lifting.

;;; --- e-ink survival rules ---------------------------------------------

;; High-contrast light theme; modus-operandi ships with Emacs 28+ and is
;; the best paper-mimic available without installing anything.
(load-theme 'modus-operandi t)

;; No blinking, no creeping — every animation is a full panel flash out here.
(blink-cursor-mode -1)
(setq visible-cursor nil)            ; don't ask the terminal to blink either
(setq ring-bell-function #'ignore)

;; Jump-scroll instead of line-crawl: fewer, bigger refreshes win on e-ink.
(setq scroll-conservatively 0        ; recenter in jumps, not line-by-line
      scroll-step 0
      auto-window-vscroll nil)

;;; --- basics ------------------------------------------------------------

(setq inhibit-startup-screen t
      initial-scratch-message nil
      make-backup-files nil
      auto-save-default nil          ; syncthing is the backup story
      custom-file (locate-user-emacs-file "custom.el"))
(load custom-file :no-error-if-file-is-missing)

(menu-bar-mode -1)
(fido-vertical-mode 1)               ; built-in completion; no package needed
(savehist-mode 1)
(recentf-mode 1)
(global-auto-revert-mode 1)          ; files change under syncthing — follow them

;;; --- evil (the one external package worth the install) ------------------

(require 'package)
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)
(unless package-archive-contents (package-refresh-contents))
(dolist (pkg '(evil))
  (unless (package-installed-p pkg) (package-install pkg)))

(setq evil-want-C-u-scroll t)
(require 'evil)
(evil-mode 1)

;;; --- the synced world ---------------------------------------------------

;; ~/roaming from the Macs lands at /sdcard/roaming via Syncthing-Fork.
;; (Termux needs storage permission once: termux-setup-storage)
(defconst boox/roaming "/sdcard/roaming/"
  "Root of the Syncthing-synced roaming tree.")

(setq org-directory (concat boox/roaming "notes/")
      org-agenda-files (list (concat boox/roaming "agenda/"))
      org-startup-folded 'content
      org-log-done 'time)

;; SPC-ish leader comforts without pulling in general.el
(with-eval-after-load 'evil
  (evil-set-leader 'normal (kbd "SPC"))
  (evil-define-key 'normal 'global
    (kbd "<leader>a") #'org-agenda
    (kbd "<leader>f") #'find-file
    (kbd "<leader>r") #'recentf-open
    (kbd "<leader>b") #'switch-to-buffer
    (kbd "<leader>g") (lambda () (interactive) (dired boox/roaming))))

;;; init.el ends here
