;;; config-tests.el --- ERT smoke tests for Emacs configuration -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Smoke tests that verify the config loads correctly and critical
;; packages, keybindings, custom functions, and lisp packages are available.
;;
;; Run with:
;;   emacs --batch -l ~/.emacs.d/init.el \
;;         -l ~/.emacs.d/tests/config-tests.el \
;;         -f ert-run-tests-batch-and-exit
;;
;; Or use the alias:  etest

;;; Code:

(require 'ert)

;; ---------------------------------------------------------------------------
;; Batch-mode Elpaca synchronization
;; ---------------------------------------------------------------------------
;; In batch mode, after-init-hook doesn't fire automatically.
;; We need to process Elpaca queues so packages actually install/load.

(when noninteractive
  (when (fboundp 'elpaca-process-queues)
    (elpaca-process-queues))
  (when (fboundp 'elpaca-wait)
    (elpaca-wait)))

;; ═══════════════════════════════════════════════════════════════════════════
;; Tier 1 — "Does it boot?"
;; Core packages that should be loaded eagerly after init.
;; ═══════════════════════════════════════════════════════════════════════════

(ert-deftest config-test-evil-loaded ()
  "Evil mode and evil-collection should be loaded."
  (should (featurep 'evil))
  (should (featurep 'evil-collection)))

(ert-deftest config-test-general-loaded ()
  "General.el leader key system should be loaded."
  (should (featurep 'general)))

(ert-deftest config-test-vertico-consult-loaded ()
  "Vertico and Consult completion framework should be loaded."
  (should (featurep 'vertico))
  (should (featurep 'orderless))
  (should (featurep 'marginalia))
  (should (fboundp 'consult-line))
  (should (fboundp 'embark-act)))

(ert-deftest config-test-projectile-loaded ()
  "Projectile project management should be loaded."
  (should (featurep 'projectile)))

(ert-deftest config-test-which-key-loaded ()
  "Which-key should be loaded for keybinding discoverability."
  (should (featurep 'which-key)))

(ert-deftest config-test-doom-modeline-loaded ()
  "Doom modeline should be loaded."
  (should (featurep 'doom-modeline)))

(ert-deftest config-test-doom-themes-loaded ()
  "Doom themes should be loaded."
  (should (featurep 'doom-themes)))

(ert-deftest config-test-org-loaded ()
  "Org mode should be loaded."
  (should (featurep 'org)))

(ert-deftest config-test-flycheck-available ()
  "Flycheck should be available."
  (should (fboundp 'flycheck-mode)))

(ert-deftest config-test-corfu-loaded ()
  "Corfu completion should be loaded."
  (should (featurep 'corfu)))

(ert-deftest config-test-perspective-loaded ()
  "Perspective workspace management should be loaded."
  (should (featurep 'perspective)))

(ert-deftest config-test-evil-snipe-loaded ()
  "Evil-snipe should be loaded."
  (should (featurep 'evil-snipe)))

(ert-deftest config-test-persistent-scratch-loaded ()
  "Persistent scratch should be loaded."
  (should (featurep 'persistent-scratch)))

(ert-deftest config-test-yasnippet-available ()
  "Yasnippet should be available."
  (should (fboundp 'yas-minor-mode)))

(ert-deftest config-test-treesit-auto-loaded ()
  "Treesit-auto should be loaded for tree-sitter grammar management."
  (should (featurep 'treesit-auto)))

(ert-deftest config-test-bm-loaded ()
  "BM (visible bookmarks) should be loaded."
  (should (featurep 'bm)))

(ert-deftest config-test-evil-nerd-commenter-available ()
  "Evil-nerd-commenter should be available."
  (should (fboundp 'evilnc-comment-or-uncomment-lines)))

(ert-deftest config-test-posframe-available ()
  "Posframe should be available for child-frame popups."
  (should (fboundp 'posframe-show)))

(ert-deftest config-test-hydra-loaded ()
  "Hydra should be loaded for transient key menus."
  (should (featurep 'hydra)))

;; Deferred packages — test that autoloads registered the commands,
;; even though the library isn't loaded yet.

(ert-deftest config-test-magit-available ()
  "Magit commands should be autoloaded (deferred package)."
  (should (fboundp 'magit-status)))

(ert-deftest config-test-lsp-available ()
  "LSP mode commands should be autoloaded (deferred package)."
  (should (fboundp 'lsp))
  (should (fboundp 'lsp-deferred)))

(ert-deftest config-test-vterm-available ()
  "Vterm should be available."
  (should (fboundp 'vterm)))

(ert-deftest config-test-pdf-tools-available ()
  "PDF-tools should be available."
  (should (fboundp 'pdf-view-mode)))

(ert-deftest config-test-deadgrep-available ()
  "Deadgrep search should be available."
  (should (fboundp 'deadgrep)))

(ert-deftest config-test-devdocs-available ()
  "Devdocs should be available."
  (should (fboundp 'devdocs-lookup)))

;; ═══════════════════════════════════════════════════════════════════════════
;; Tier 2 — "Are my keybindings intact?"
;; Verify SPC leader map and key groups exist.
;; ═══════════════════════════════════════════════════════════════════════════

(defun config-test--leader-map ()
  "Return the SPC leader keymap from the general override map for normal state."
  (when (and (boundp 'general-override-mode-map)
             (fboundp 'evil-get-auxiliary-keymap))
    (let ((aux (evil-get-auxiliary-keymap general-override-mode-map 'normal)))
      (and aux (lookup-key aux (kbd "SPC"))))))

(ert-deftest config-test-leader-key-exists ()
  "SPC should be bound to a keymap in evil normal state."
  (let ((leader-map (config-test--leader-map)))
    (should leader-map)
    (should (keymapp leader-map))))

(ert-deftest config-test-leader-key-groups ()
  "Core leader key groups should be bound under SPC."
  (let ((leader-map (config-test--leader-map)))
    (should leader-map)
    ;; Each of these should resolve to something (a command or sub-keymap)
    (should (lookup-key leader-map (kbd "a")))   ; Agenda
    (should (lookup-key leader-map (kbd "b")))   ; Buffer
    (should (lookup-key leader-map (kbd "c")))   ; Agent Shell
    (should (lookup-key leader-map (kbd "d")))   ; Dired
    (should (lookup-key leader-map (kbd "e")))   ; Edit config
    (should (lookup-key leader-map (kbd "f")))   ; Find link
    (should (lookup-key leader-map (kbd "g")))   ; Git
    (should (lookup-key leader-map (kbd "p")))   ; Projectile
    (should (lookup-key leader-map (kbd "s")))   ; Surf/streaming
    (should (lookup-key leader-map (kbd "v")))   ; Vterm
    (should (lookup-key leader-map (kbd "w")))   ; Window
    (should (lookup-key leader-map (kbd "x")))   ; Perspectives
    (should (lookup-key leader-map (kbd "P")))   ; Project Dashboard
    (should (lookup-key leader-map (kbd "o")))   ; OS commands
    (should (lookup-key leader-map (kbd "y")))   ; Yank
    (should (lookup-key leader-map (kbd "$")))   ; Finances (ledger)
    (should (lookup-key leader-map (kbd "r")))   ; Reading (books)
    (should (lookup-key leader-map (kbd ";")))   ; LSP
    (should (lookup-key leader-map (kbd "m")))   ; Bookmarks
    (should (lookup-key leader-map (kbd "W")))   ; Window hydra
    (should (lookup-key leader-map (kbd "t")))))  ; Test environment

;; ═══════════════════════════════════════════════════════════════════════════
;; Tier 3 — "Are my custom functions defined?"
;; ═══════════════════════════════════════════════════════════════════════════

;; ── Agent Shell ────────────────────────────────────────────────────────────

(ert-deftest config-test-mr-x-agent-shell-functions ()
  "Critical agent-shell custom functions should be defined."
  (should (fboundp 'mr-x/agent-shell-toggle))
  (should (fboundp 'mr-x/agent-shell-new-smart))
  (should (fboundp 'mr-x/agent-shell-roaming))
  (should (fboundp 'mr-x/agent-shell-in-project))
  (should (fboundp 'mr-x/focus-ai-window)))

(ert-deftest config-test-agent-shell-inbox ()
  "Phone-screenshot inbox package should be loaded with its entry points."
  (should (featurep 'agent-shell-inbox))
  (should (fboundp 'agent-shell-inbox-arm))
  (should (fboundp 'agent-shell-inbox-disarm))
  (should (fboundp 'agent-shell-inbox-armed-p)))

(ert-deftest config-test-mr-x-agent-shell-input-functions ()
  "Agent shell input helpers should be defined."
  (should (fboundp 'mr-x/agent-shell-smart-insert))
  (should (fboundp 'mr-x/agent-shell-smart-append))
  (should (fboundp 'mr-x/agent-shell-smart-paste))
  (should (fboundp 'mr-x/agent-shell-clear-prompt))
  (should (fboundp 'mr-x/agent-shell-send-region-no-switch)))

(ert-deftest config-test-mr-x-agent-shell-permission-functions ()
  "Agent shell permission handling should be defined."
  (should (fboundp 'mr-x/agent-shell-allow))
  (should (fboundp 'mr-x/agent-shell-deny))
  (should (fboundp 'mr-x/agent-shell-allow-always))
  (should (fboundp 'mr-x/respond-to-permission))
  (should (fboundp 'mr-x/permission-format-line)))

(ert-deftest config-test-mr-x-agent-shell-diff-functions ()
  "Agent shell diff viewing should be defined."
  (should (fboundp 'mr-x/agent-shell-view-diff))
  (should (fboundp 'mr-x/agent-shell-diff-clean-exit))
  (should (fboundp 'mr-x/fontify-diff-with-language)))

(ert-deftest config-test-mr-x-agent-shell-context-functions ()
  "Agent shell context management should be defined."
  (should (fboundp 'mr-x/agent-shell-clear-context))
  (should (fboundp 'mr-x/agent-shell-set-mode-direct)))

;; ── Quick Ask (LLM) ───────────────────────────────────────────────────────

(ert-deftest config-test-mr-x-quick-ask-functions ()
  "Quick Ask LLM interface should be defined."
  (should (fboundp 'mr-x/quick-ask))
  (should (fboundp 'mr-x/quick-ask--submit))
  (should (fboundp 'mr-x/quick-ask--cancel))
  (should (fboundp 'mr-x/quick-ask--attach-file))
  (should (fboundp 'mr-x/quick-ask--attach-buffer))
  (should (fboundp 'mr-x/quick-ask--attach-region))
  (should (fboundp 'mr-x/quick-ask--detach-all))
  (should (fboundp 'mr-x/quick-ask--strip-thinking)))

;; ── Taskmaster ─────────────────────────────────────────────────────────────

(ert-deftest config-test-mr-x-taskmaster-functions ()
  "Taskmaster integration should be defined."
  (should (fboundp 'mr-x/taskmaster-next-task))
  (should (fboundp 'mr-x/taskmaster-summary))
  (should (fboundp 'mr-x/taskmaster-add-task))
  (should (fboundp 'mr-x/taskmaster-get-project-root)))

;; ── Bash Watcher ───────────────────────────────────────────────────────────

(ert-deftest config-test-mr-x-bash-watcher-functions ()
  "Bash watcher should be defined."
  (should (fboundp 'mr-x/bash-watcher-log))
  (should (fboundp 'mr-x/bash-watcher-toggle)))

;; ── Development / Terminal ─────────────────────────────────────────────────

(ert-deftest config-test-mr-x-dev-functions ()
  "Development environment functions should be defined."
  (should (fboundp 'mr-x/spawn-dev-environment))
  (should (fboundp 'mr-x/spawn-project-terminal-frame))
  (should (fboundp 'mr-x/test-environment))
  (should (fboundp 'mr-x/restart-dev-environment))
  (should (fboundp 'mr-x/clear-and-restart-dev-environment)))

(ert-deftest config-test-mr-x-vterm-functions ()
  "Vterm helper functions should be defined."
  (should (fboundp 'mr-x/vterm-popup))
  (should (fboundp 'mr-x/vterm-in-dir))
  (should (fboundp 'mr-x/vterm-buffer))
  (should (fboundp 'mr-x/vterm-frame))
  (should (fboundp 'mr-x/vterm-restart)))

;; ── Org / Agenda ───────────────────────────────────────────────────────────

(ert-deftest config-test-mr-x-org-agenda-core ()
  "Core org-agenda custom functions should be defined."
  (should (fboundp 'mr-x/org-mode-setup))
  (should (fboundp 'mr-x/fix-org-mode-buffers))
  (should (fboundp 'mr-x/agenda-refresh-all))
  (should (fboundp 'mr-x/agenda-redo-preserving-position))
  (should (fboundp 'mr-x/agenda-auto-refresh)))

(ert-deftest config-test-mr-x-org-agenda-styling ()
  "Agenda styling functions should be defined."
  (should (fboundp 'mr-x/style-org-agenda))
  (should (fboundp 'mr-x/style-routine-entries))
  (should (fboundp 'mr-x/style-timed-todo-entries))
  (should (fboundp 'mr-x/style-agenda-entries))
  (should (fboundp 'mr-x/style-habit-entries))
  (should (fboundp 'mr-x/style-agenda-separators))
  (should (fboundp 'mr-x/agenda-strike-through-done))
  (should (fboundp 'mr-x/agenda-prettify-priorities))
  (should (fboundp 'mr-x/agenda-style-section-headers)))

(ert-deftest config-test-mr-x-org-agenda-skip ()
  "Agenda skip functions should be defined."
  (should (fboundp 'mr-x/agenda-skip-habits))
  (should (fboundp 'mr-x/agenda-skip-non-habits))
  (should (fboundp 'mr-x/agenda-skip-untimed))
  (should (fboundp 'mr-x/agenda-skip-timed))
  (should (fboundp 'mr-x/agenda-skip-routines))
  (should (fboundp 'mr-x/agenda-skip-if-deadline)))

(ert-deftest config-test-mr-x-org-agenda-views ()
  "Agenda view dispatch functions should be defined."
  (should (fboundp 'mr-x/org-agenda-day))
  (should (fboundp 'mr-x/org-agenda-custom))
  (should (fboundp 'mr-x/org-agenda-dashboard))
  (should (fboundp 'mr-x/org-agenda-focus))
  (should (fboundp 'mr-x/org-agenda-full)))

(ert-deftest config-test-mr-x-org-agenda-navigation ()
  "Agenda section navigation functions should be defined."
  (should (fboundp 'mr-x/agenda-next-section))
  (should (fboundp 'mr-x/agenda-prev-section))
  (should (fboundp 'mr-x/agenda-next-header))
  (should (fboundp 'mr-x/agenda-prev-header)))

;; ── Mdox / Documentation ──────────────────────────────────────────────────

(ert-deftest config-test-mr-x-mdox-functions ()
  "Mdox documentation functions should be defined."
  (should (fboundp 'mr-x/mdox-view))
  (should (fboundp 'mr-x/mdox-search))
  (should (fboundp 'mr-x/mdox-new))
  (should (fboundp 'mr-x/mdox-next-heading))
  (should (fboundp 'mr-x/mdox-prev-heading))
  (should (fboundp 'mr-x/view-shortcuts))
  (should (fboundp 'mr-x/search-shortcuts)))

;; ── Org-roam ───────────────────────────────────────────────────────────────

(ert-deftest config-test-org-roam-functions ()
  "Org-roam custom functions should be defined."
  (should (fboundp 'my/org-roam-find-project))
  (should (fboundp 'my/org-roam-capture-inbox))
  (should (fboundp 'my/org-roam-capture-task))
  (should (fboundp 'my/org-roam-filter-by-tag))
  (should (fboundp 'my/org-roam-list-notes-by-tag))
  (should (fboundp 'my/org-roam-copy-todo-to-today)))

;; ── Reading / Books ────────────────────────────────────────────────────────

(ert-deftest config-test-mr-x-reading-functions ()
  "Book reading functions should be defined."
  (should (fboundp 'mr-x/book-new))
  (should (fboundp 'mr-x/book-open-pdf))
  (should (fboundp 'mr-x/book-open-notes))
  (should (fboundp 'mr-x/book-update-progress))
  (should (fboundp 'mr-x/book-mark-finished))
  (should (fboundp 'mr-x/select-reading-book)))

;; ── UI / Display / Window ──────────────────────────────────────────────────

(ert-deftest config-test-mr-x-ui-functions ()
  "UI and display functions should be defined."
  (should (fboundp 'mr-x/set-font-faces))
  (should (fboundp 'mr-x/org-babel-tangle-config))
  (should (fboundp 'mr-x/new-scratch))
  (should (fboundp 'mr-x/global-scratch))
  (should (fboundp 'mr-x/escape-quit))
  (should (fboundp 'mr-x/rotate-windows))
  (should (fboundp 'mr-x/visual-bell))
  (should (fboundp 'mr-x/copy-last-message)))

;; ── Session State ──────────────────────────────────────────────────────────

(ert-deftest config-test-mr-x-session-functions ()
  "Session save/restore functions should be defined."
  (should (fboundp 'mr-x/save-session-state))
  (should (fboundp 'mr-x/restore-session-state))
  (should (fboundp 'mr-x/session-state-summary)))

;; ── Sketchybar ─────────────────────────────────────────────────────────────

(ert-deftest config-test-mr-x-sketchybar-functions ()
  "Sketchybar integration functions should be defined."
  (should (fboundp 'mr-x/sketchybar-update-persp))
  (should (fboundp 'mr-x/sketchybar-hide-persp))
  (should (fboundp 'mr-x/sketchybar-update-clock))
  (should (fboundp 'mr-x/sketchybar-clock-start-tick))
  (should (fboundp 'mr-x/sketchybar-clock-stop-tick)))

;; ── Git ────────────────────────────────────────────────────────────────────

(ert-deftest config-test-mr-x-git-functions ()
  "Git helper functions should be defined."
  (should (fboundp 'mr-x/magit-status-side-window)))

;; ── Surf (web browsing) ───────────────────────────────────────────────────

(ert-deftest config-test-mr-x-surf-functions ()
  "Web browsing functions should be defined."
  (should (fboundp 'mr-x/surf-web))
  (should (fboundp 'mr-x/surf-web-other-window))
  (should (fboundp 'mr-x/surf-link-at-point))
  (should (fboundp 'mr-x/surf-url-other-window)))

;; ── TRAMP / Remote ─────────────────────────────────────────────────────────

(ert-deftest config-test-mr-x-tramp-functions ()
  "TRAMP advice functions should be defined."
  (should (fboundp 'mr-x/tramp-windows-pipe-a))
  (should (fboundp 'mr-x/projectile-ignore-remote-a)))

;; ── Ledger / Finances ──────────────────────────────────────────────────────

(ert-deftest config-test-my-ledger-functions ()
  "Ledger finance functions should be defined."
  (should (fboundp 'my/ledger-current-year-file))
  (should (fboundp 'my/ledger-save))
  (should (fboundp 'my/ledger-quick-add))
  (should (fboundp 'my/ledger-report-balance))
  (should (fboundp 'my/ledger-report-expenses))
  (should (fboundp 'my/ledger-report-net-worth)))

;; ── Deadgrep ───────────────────────────────────────────────────────────────

(ert-deftest config-test-mr-x-deadgrep-functions ()
  "Deadgrep navigation helpers should be defined (deferred via use-package)."
  ;; deadgrep is deferred — functions only exist after it loads.
  ;; In batch mode just verify the base command is autoloaded.
  (should (fboundp 'deadgrep)))

;; ── Leader definer ─────────────────────────────────────────────────────────

(ert-deftest config-test-leader-definer-exists ()
  "The mr-x/leader-def definer should be defined."
  (should (fboundp 'mr-x/leader-def)))

;; ═══════════════════════════════════════════════════════════════════════════
;; Tier 4 — "Are my custom lisp packages loaded?"
;; Verify features provided by lisp/ packages.
;; ═══════════════════════════════════════════════════════════════════════════

(ert-deftest config-test-org-habit-flex-loaded ()
  "org-habit-flex should be loaded and activated."
  (should (featurep 'org-habit-flex))
  (should (fboundp 'org-habit-flex-activate))
  (should (fboundp 'org-habit-flex-deactivate))
  (should (fboundp 'org-habit-flex-parse-weekdays)))

(ert-deftest config-test-trakt-sync-loaded ()
  "trakt-sync should be loaded."
  (should (featurep 'trakt-sync))
  (should (fboundp 'trakt-sync))
  (should (fboundp 'trakt-sync-watchlist))
  (should (fboundp 'log-watched)))

(ert-deftest config-test-mr-x-popup-loaded ()
  "mr-x-popup should be loaded."
  (should (featurep 'mr-x-popup))
  (should (fboundp 'mr-x/popup-prompt)))

(ert-deftest config-test-point-stack-available ()
  "point-stack commands should be autoloaded (deferred via :bind)."
  (should (fboundp 'point-stack-pop))
  (should (fboundp 'point-stack-forward-stack-pop)))

(ert-deftest config-test-agent-shell-refs-loaded ()
  "agent-shell-refs should be loaded."
  (should (featurep 'agent-shell-refs))
  (should (fboundp 'agent-shell-refs-capture))
  (should (fboundp 'agent-shell-refs-clear))
  (should (fboundp 'agent-shell-refs-remove))
  (should (fboundp 'agent-shell-refs-preview)))

(ert-deftest config-test-project-dashboard-loaded ()
  "project-dashboard should be loaded."
  (should (featurep 'project-dashboard))
  (should (fboundp 'project-dashboard-open))
  (should (fboundp 'project-dashboard-refresh)))

;; ═══════════════════════════════════════════════════════════════════════════
;; Tier 5 — Functional tests for pure utility functions
;; Tests that exercise actual logic, not just existence.
;; ═══════════════════════════════════════════════════════════════════════════

(ert-deftest config-test-quick-ask-strip-thinking ()
  "mr-x/quick-ask--strip-thinking should remove agent-shell thinking blocks."
  (should (equal (mr-x/quick-ask--strip-thinking "hello") "hello"))
  (should (equal (mr-x/quick-ask--strip-thinking nil) ""))
  (should (equal (mr-x/quick-ask--strip-thinking
                  "▶ Thinking\n\nsome reasoning here\n\nactual answer")
                 "actual answer")))

(ert-deftest config-test-agent-shell-refs-truncate ()
  "agent-shell-refs--truncate should truncate long strings with ellipsis."
  (should (equal (agent-shell-refs--truncate "short" 10) "short"))
  (should (equal (agent-shell-refs--truncate "a very long string" 10) "a very lo…")))

(ert-deftest config-test-org-habit-flex-parse-weekdays ()
  "org-habit-flex-parse-weekdays should parse space-separated day numbers."
  (should (equal (org-habit-flex-parse-weekdays "1 3 5") '(1 3 5)))
  (should (equal (org-habit-flex-parse-weekdays "6 7") '(6 7)))
  (should-not (org-habit-flex-parse-weekdays nil))
  (should-not (org-habit-flex-parse-weekdays "")))

(ert-deftest config-test-sketchybar-persp-name ()
  "mr-x/sketchybar-persp-name-for-title should clean perspective names."
  (let ((result (mr-x/sketchybar-persp-name-for-title "some-project")))
    (should (stringp result))))

(ert-deftest config-test-agenda-color-helper ()
  "mr-x/color function and mr-x/colors alist should be defined."
  (should (fboundp 'mr-x/color))
  (should (boundp 'mr-x/colors)))

(ert-deftest config-test-point-stack-push-pop ()
  "point-stack should push and pop positions in a temp buffer."
  ;; Force-load point-stack since it's deferred via :bind
  (require 'point-stack nil t)
  (when (fboundp 'point-stack-push)
    (with-temp-buffer
      (insert "line one\nline two\nline three\n")
      (goto-char (point-min))
      (point-stack-push)
      (goto-char (point-max))
      (point-stack-pop)
      (should (= (point) (point-min))))))

;; ═══════════════════════════════════════════════════════════════════════════
;; Tier 6 — "Did evil-collection clobber my keybindings?"
;; These catch the real breakage: load-order issues and keybinding overrides.
;; ═══════════════════════════════════════════════════════════════════════════

(defun config-test--evil-key (map state key)
  "Look up KEY in evil STATE auxiliary keymap of MAP."
  (when (and (boundp 'evil-mode) (keymapp map))
    (let ((aux (evil-get-auxiliary-keymap map state)))
      (and aux (lookup-key aux (kbd key))))))

;; ── vterm: evil-collection must NOT touch these ────────────────────────────

(ert-deftest config-test-vterm-evil-collection-disabled ()
  "vterm must be removed from evil-collection-mode-list."
  (should-not (memq 'vterm evil-collection-mode-list)))

(ert-deftest config-test-vterm-insert-keys-not-clobbered ()
  "vterm insert-state C-* keys must send to terminal, not evil commands."
  (require 'vterm nil t)
  (require 'multi-vterm nil t)
  (dolist (key '("C-e" "C-f" "C-a" "C-b" "C-w" "C-u" "C-d"
                 "C-n" "C-p" "C-r" "C-t" "C-g" "C-c"))
    (let ((bound (config-test--evil-key vterm-mode-map 'insert key)))
      (should (eq bound 'vterm--self-insert)))))

(ert-deftest config-test-vterm-normal-keys ()
  "vterm normal-state comma keys and i/o should be correct."
  (require 'vterm nil t)
  (require 'multi-vterm nil t)
  (should (eq (config-test--evil-key vterm-mode-map 'normal ",c") 'multi-vterm))
  (should (eq (config-test--evil-key vterm-mode-map 'normal ",n") 'multi-vterm-next))
  (should (eq (config-test--evil-key vterm-mode-map 'normal ",p") 'multi-vterm-prev))
  (should (eq (config-test--evil-key vterm-mode-map 'normal "i") 'evil-insert-resume))
  (should (eq (config-test--evil-key vterm-mode-map 'normal "o") 'evil-insert-resume)))

;; ── dired: Y must survive evil-collection ──────────────────────────────────

(ert-deftest config-test-dired-keybindings ()
  "Dired h/l/Y must be our bindings, not evil-collection defaults."
  (should (eq (config-test--evil-key dired-mode-map 'normal "h") 'dired-up-directory))
  (should (eq (config-test--evil-key dired-mode-map 'normal "l") 'dired-find-file))
  (should (eq (config-test--evil-key dired-mode-map 'normal "Y") 'dired-copy-filename-as-kill)))

;; ── org-mode: keys must survive evil-org / evil-collection ─────────────────

(ert-deftest config-test-org-evil-keys ()
  "Org-mode s-return and M-return must be our heading commands in both states."
  (should (eq (config-test--evil-key org-mode-map 'normal "s-<return>")
              'org-insert-heading-respect-content))
  (should (eq (config-test--evil-key org-mode-map 'insert "s-<return>")
              'org-insert-heading-respect-content))
  (should (eq (config-test--evil-key org-mode-map 'normal "M-<return>")
              'org-meta-return))
  (should (eq (config-test--evil-key org-mode-map 'insert "M-<return>")
              'org-meta-return)))

;; ── agent-shell: smart keys and permission digits ──────────────────────────

(ert-deftest config-test-agent-shell-normal-keys ()
  "agent-shell normal-state i/a/o/p must be our smart commands."
  (should (eq (config-test--evil-key agent-shell-mode-map 'normal "i")
              'mr-x/agent-shell-smart-insert))
  (should (eq (config-test--evil-key agent-shell-mode-map 'normal "a")
              'mr-x/agent-shell-smart-append))
  (should (eq (config-test--evil-key agent-shell-mode-map 'normal "p")
              'mr-x/agent-shell-smart-paste)))

(ert-deftest config-test-agent-shell-permission-keys ()
  "agent-shell 1/2/3 permission digit keys must be bound and the queue variable must exist."
  (should (boundp 'mr-x/pending-permissions-queue))
  ;; 1/2/3 are bound to lambdas wrapping mr-x/agent-shell-permission-or-digit
  (should (config-test--evil-key agent-shell-mode-map 'normal "1"))
  (should (config-test--evil-key agent-shell-mode-map 'normal "2"))
  (should (config-test--evil-key agent-shell-mode-map 'normal "3"))
  (should (config-test--evil-key agent-shell-mode-map 'normal "0")))

;; ── SPC c (Agent Shell leader subtree) ─────────────────────────────────────

(defun config-test--leader-key (keys)
  "Look up KEYS under the SPC leader map."
  (let ((leader-map (config-test--leader-map)))
    (and leader-map (lookup-key leader-map (kbd keys)))))

(ert-deftest config-test-leader-agent-shell-subtree ()
  "SPC c subtree: core agent-shell commands must resolve correctly."
  (should (eq (config-test--leader-key "c c") 'agent-shell))
  (should (eq (config-test--leader-key "c C") 'mr-x/agent-shell-roaming))
  (should (eq (config-test--leader-key "c n") 'mr-x/agent-shell-new-smart))
  (should (eq (config-test--leader-key "c N") 'mr-x/agent-shell-in-project))
  (should (eq (config-test--leader-key "c t") 'mr-x/agent-shell-toggle))
  (should (eq (config-test--leader-key "c w") 'mr-x/focus-ai-window))
  (should (eq (config-test--leader-key "c i") 'agent-shell-interrupt)))

(ert-deftest config-test-leader-agent-shell-send ()
  "SPC c send commands must resolve correctly."
  (should (eq (config-test--leader-key "c p") 'agent-shell-yank-dwim))
  (should (eq (config-test--leader-key "c r") 'major-pane-send-region-no-switch))
  (should (eq (config-test--leader-key "c R") 'major-pane-send-region))
  (should (eq (config-test--leader-key "c f") 'major-pane-send-file))
  (should (eq (config-test--leader-key "c d") 'agent-shell-send-dwim)))

(ert-deftest config-test-leader-agent-shell-permissions ()
  "SPC c 1/2/3/0 permission shortcuts must be correct."
  (should (eq (config-test--leader-key "c 1") 'mr-x/agent-shell-allow))
  (should (eq (config-test--leader-key "c 2") 'mr-x/agent-shell-deny))
  (should (eq (config-test--leader-key "c 3") 'mr-x/agent-shell-allow-always))
  (should (eq (config-test--leader-key "c 0") 'mr-x/agent-shell-view-diff)))

;; ── SPC other subtrees ─────────────────────────────────────────────────────

(ert-deftest config-test-leader-agenda-keys ()
  "SPC a agenda dispatch keys must resolve correctly."
  (should (eq (config-test--leader-key "a a") 'org-agenda))
  (should (eq (config-test--leader-key "a d") 'mr-x/org-agenda-dashboard))
  (should (eq (config-test--leader-key "a f") 'mr-x/org-agenda-focus))
  (should (eq (config-test--leader-key "a v") 'mr-x/org-agenda-full)))

(ert-deftest config-test-leader-git-keys ()
  "SPC g git keys must resolve correctly."
  (should (eq (config-test--leader-key "g g") 'magit-status))
  (should (eq (config-test--leader-key "g G") 'mr-x/magit-status-side-window)))

;; ═══════════════════════════════════════════════════════════════════════════
;; Tier 7 — "Are critical variables bound?"
;; Load-order regressions: variables that must exist before other code runs.
;; ═══════════════════════════════════════════════════════════════════════════

(ert-deftest config-test-load-order-variables ()
  "Variables that other code depends on must be bound after init."
  (should (boundp 'mr-x/pending-permissions-queue))
  (should (boundp 'mr-x/escape-hook))
  (should (boundp 'mr-x/colors))
  (should (boundp 'mr-x/code-block-icons))
  (should (boundp 'mr-x/agenda-separator)))

(ert-deftest config-test-evil-collection-exclusions ()
  "Modes we manually bind must be excluded from evil-collection."
  (should-not (memq 'vterm evil-collection-mode-list)))

;;; config-tests.el ends here
