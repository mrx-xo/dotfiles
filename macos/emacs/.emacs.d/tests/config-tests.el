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

(ert-deftest config-test-agent-recall-embark-resume-keeps-picker ()
  "Agent Recall resume should keep its picker while other actions still quit."
  (require 'embark)
  (let ((embark--toggle-quit nil))
    (should-not (embark--quit-p #'agent-recall-embark-resume))
    (should (embark--quit-p #'find-file))))

(ert-deftest config-test-bookmark-annotator-installed ()
  "Custom bookmark annotator (URL fallback for bookmark+) should be registered."
  (should (fboundp 'mr-x/marginalia-annotate-bookmark))
  (should (eq (car (alist-get 'bookmark marginalia-annotators))
              'mr-x/marginalia-annotate-bookmark)))

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

(ert-deftest config-test-mode-hydras-defined ()
  "Per-mode hydras dispatched by `mr-x/mode-hydra' should be defined."
  (should (fboundp 'mr-x/mode-hydra))
  (dolist (body '(hydra-dired/body hydra-ibuffer/body hydra-info/body
                  hydra-ediff/body hydra-window/body hydra-zoom/body))
    (should (fboundp body))))

(ert-deftest config-test-project-commands ()
  "Per-project named commands: function defined, dir-locals var safe,
and bound on RET in `projectile-command-map'."
  (should (fboundp 'mr-x/project-command))
  (should (funcall (get 'mr-x/project-commands 'safe-local-variable) '()))
  (should (require 'projectile nil t))
  (should (eq (lookup-key projectile-command-map (kbd "RET"))
              'mr-x/project-command)))

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

;; ── Monitor Mode ───────────────────────────────────────────────────────────

(ert-deftest config-test-mr-x-mon-functions ()
  "Monitor-mode commands should be defined and the script should exist."
  (should (fboundp 'mr-x/mon))
  (should (fboundp 'mr-x/mon-toggle-3))
  (should (fboundp 'mr-x/mon-toggle-4))
  (should (fboundp 'mr-x/mon-status))
  (should (file-executable-p (expand-file-name mr-x/mon-script))))

;; ── Agent Shell ────────────────────────────────────────────────────────────

(ert-deftest config-test-mr-x-agent-shell-functions ()
  "Critical agent-shell custom functions should be defined."
  (should (fboundp 'mr-x/agent-shell-toggle))
  (should (fboundp 'mr-x/agent-shell-new-smart))
  (should (fboundp 'mr-x/agent-shell-clone))
  (should (fboundp 'mr-x/agent-shell-roaming))
  (should (fboundp 'mr-x/agent-shell-in-project))
  (should (fboundp 'mr-x/focus-ai-window)))

(ert-deftest config-test-opencode-command ()
  "OpenCode should use the installed ACP executable by absolute path."
  (require 'agent-shell-opencode)
  (should (equal agent-shell-opencode-acp-command
                 (list (expand-file-name "~/.opencode/bin/opencode") "acp")))
  (should (file-executable-p (car agent-shell-opencode-acp-command))))

(ert-deftest config-test-agent-shell-clone-reuses-current-model-in-fresh-session ()
  "Clone starts a fresh shell with the source provider, model, and directory."
  (let* ((source-config
          '((:identifier . codex)
            (:default-model-id . (lambda () "old-default"))))
         (source-state
          `((:agent-config . ,source-config)
            (:config-options
             . (((:id . "model")
                 (:category . "model")
                 (:current-value . "gpt-current"))))))
         captured-directory
         captured-args)
    (with-temp-buffer
      (setq-local major-mode 'agent-shell-mode)
      (setq-local default-directory "/tmp/clone-source/")
      (setq-local agent-shell--state source-state)
      (cl-letf (((symbol-function 'agent-shell--start)
                 (lambda (&rest args)
                   (setq captured-directory default-directory
                         captured-args args)
                   'spawned-shell)))
        (should (eq (mr-x/agent-shell-clone) 'spawned-shell))))
    (let ((clone-config (plist-get captured-args :config)))
      (should (equal captured-directory "/tmp/clone-source/"))
      (should (eq (plist-get captured-args :new-session) t))
      (should-not (plist-member captured-args :fork-session-id))
      (should (eq (map-elt clone-config :identifier) 'codex))
      (should-not (eq clone-config source-config))
      (should (equal (funcall (map-elt clone-config :default-model-id))
                     "gpt-current"))
      (should (equal (funcall (map-elt source-config :default-model-id))
                     "old-default")))))

(ert-deftest config-test-agent-shell-clone-is-a-local-slash-command ()
  "The local /clone command resolves to the clone implementation."
  (should (eq (cdr (assoc "clone" mr-x/agent-shell-local-commands))
              'mr-x/agent-shell-clone)))

(ert-deftest config-test-agent-shell-inbox ()
  "Phone-screenshot inbox package should be loaded with its entry points."
  (should (featurep 'agent-shell-inbox))
  (should (fboundp 'agent-shell-inbox-arm))
  (should (fboundp 'agent-shell-inbox-disarm))
  (should (fboundp 'agent-shell-inbox-armed-p)))

(ert-deftest config-test-agent-terminal ()
  "Agent terminal observer package should be loaded with its entry points."
  (should (featurep 'agent-terminal))
  (should (fboundp 'agent-terminal--ingest))
  (should (fboundp 'agent-terminal-clear))
  (should (fboundp 'mr-x/agent-terminal))
  ;; Phase 2 — tmux interception entry points
  (should (fboundp 'mr-x/agent-tmux-toggle))
  (should (fboundp 'mr-x/agent-terminal-attach))
  (should (fboundp 'mr-x/agent-terminal-live))
  (should (fboundp 'agent-terminal-tmux-enabled-p))
  ;; Phase 3 — ACP terminal channel shims
  (should (fboundp 'agent-terminal--acp-add-capability))
  (should (fboundp 'agent-terminal--acp-transform-update))
  (should (fboundp 'agent-terminal--acp-transform-notification)))

(ert-deftest config-test-agent-terminal-acp-transform ()
  "Terminal-channel updates should rewrite to console blocks agent-shell renders.
Payload shapes live-probed from claude-agent-acp 0.54.1 (2026-07-25)."
  ;; Data update: _meta.terminal_output, no content key -> block injected
  (let ((update (json-parse-string
                 "{\"_meta\":{\"terminal_output\":{\"terminal_id\":\"t1\",\"data\":\"hello\"}},\"toolCallId\":\"t1\",\"sessionUpdate\":\"tool_call_update\"}"
                 :object-type 'alist :null-object nil :false-object nil)))
    (agent-terminal--acp-transform-update update)
    (should (string-match-p "```console\nhello\n```"
                            (map-nested-elt (aref (map-elt update 'content) 0)
                                            '(content text)))))
  ;; Completed failure: terminal item + rawOutput + nonzero exit -> block + badge
  (let ((update (json-parse-string
                 "{\"sessionUpdate\":\"tool_call_update\",\"status\":\"failed\",\"rawOutput\":\"boom\",\"content\":[{\"type\":\"terminal\",\"terminalId\":\"t1\"}],\"_meta\":{\"terminal_exit\":{\"terminal_id\":\"t1\",\"exit_code\":3,\"signal\":null}}}"
                 :object-type 'alist :null-object nil :false-object nil)))
    (agent-terminal--acp-transform-update update)
    (let ((text (map-nested-elt (aref (map-elt update 'content) 0) '(content text))))
      (should (string-match-p "boom" text))
      (should (string-match-p "✗ exit 3" text))))
  ;; Placeholder tool_call -> terminal item dropped, nothing invented
  (let ((update (json-parse-string
                 "{\"sessionUpdate\":\"tool_call\",\"status\":\"pending\",\"content\":[{\"type\":\"terminal\",\"terminalId\":\"t1\"}],\"_meta\":{\"terminal_info\":{\"terminal_id\":\"t1\"}}}"
                 :object-type 'alist :null-object nil :false-object nil)))
    (agent-terminal--acp-transform-update update)
    (let ((c (map-elt update 'content)))
      (should (or (null c) (= 0 (length c)))))))

(ert-deftest config-test-agent-terminal-ingest-roundtrip ()
  "A hook-shaped payload should land in the observer buffer; bad input is swallowed."
  (let ((agent-terminal-buffer-name " *agent-terminal-test*")
        (agent-terminal--last-session nil))
    (unwind-protect
        (progn
          (should (agent-terminal--ingest
                   (base64-encode-string
                    (encode-coding-string
                     (json-serialize '(:phase "pre" :session "test1234-abcd"
                                       :cwd "/tmp" :command "echo hi"
                                       :description "Test" :output ""
                                       :interrupted :false))
                     'utf-8)
                    t)))
          (should-not (agent-terminal--ingest "!!!not-base64"))
          (with-current-buffer (agent-terminal--buffer)
            (should (string-match-p "echo hi" (buffer-string)))
            (should (string-match-p "test1234" (buffer-string)))))
      (kill-buffer " *agent-terminal-test*"))))

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

(ert-deftest config-test-popup-placement-policy ()
  "Popup placement lives in display-buffer-alist; popper only tracks.
Popper must NOT control display, the popup rule must be present, and a
'raised buffer must escape the rule (mr-x/vterm-buffer relies on it)."
  (should (null popper-display-control))
  (should (fboundp 'mr-x/popup-buffer-p))
  (should (fboundp 'mr-x/popup-window-height))
  (let ((rule (assq 'mr-x/popup-buffer-p display-buffer-alist)))
    (should rule)
    (should (memq 'display-buffer-in-side-window (cadr rule)))
    (should (equal '(side . bottom) (assq 'side (cddr rule)))))
  ;; membership: vterm names in, raised buffers out, mdox names out
  (let ((buf (generate-new-buffer "*vterm-policy-test*")))
    (unwind-protect
        (progn
          (should (mr-x/popup-buffer-p buf))
          (with-current-buffer buf
            (setq-local popper-popup-status 'raised))
          (should-not (mr-x/popup-buffer-p buf)))
      (kill-buffer buf)))
  (let ((buf (generate-new-buffer "node--Mdox-thing")))
    (unwind-protect
        (should-not (mr-x/popup-buffer-p buf))
      (kill-buffer buf))))

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

(ert-deftest config-test-agent-shell-refs-numbered ()
  "Refs are numbered in the send block and reply commands exist."
  (should (fboundp 'agent-shell-refs-insert-marker))
  (should (fboundp 'mr-x/agent-shell-refs-reply-and-go))
  (should (fboundp 'mr-x/agent-shell-refs-reply-1))
  (should (fboundp 'mr-x/agent-shell-refs-reply-9))
  ;; Capture order = ref number: last-pushed list entry is Ref 1
  (should (equal (agent-shell-refs--format-for-send
                  (list '(:type quote :text "second")
                        '(:type quote :text "first")))
                 (concat "<referenced-context>\n"
                         "Ref 1:\n> first\n\n"
                         "Ref 2:\n> second\n"
                         "</referenced-context>\n\n"))))

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
  "Palette system: mr-x/color + mr-x/frame-profile defined, palettes bound.
`mr-x/color' resolves a semantic name against a profile's palette; an
explicit profile arg must win over the frame default."
  (should (fboundp 'mr-x/color))
  (should (fboundp 'mr-x/frame-profile))
  (should (boundp 'mr-x/palettes))
  (should (assq 'dark mr-x/palettes))
  (should (assq 'eink mr-x/palettes))
  ;; explicit profile resolves from the right palette
  (should (equal (mr-x/color 'gold 'dark) "#fabd2f"))
  (should (equal (mr-x/color 'gold 'eink) "#000000"))
  ;; frame-profile falls back to display type for untagged frames
  (should (memq (mr-x/frame-profile) '(dark eink))))

(ert-deftest config-test-markdown-mermaid-normalizes-pandoc-html ()
  "Pandoc Mermaid fences must become elements Mermaid.js can discover."
  (require 'markdown-xwidget)
  (should (fboundp 'mr-x/markdown-normalize-pandoc-mermaid-html))
  (let* ((input
          (concat
           "<h1>Diagram</h1>\n"
           "<pre class=\"mermaid\"><code>flowchart LR</code></pre>\n"
           "<pre id=\"diagram\" class=\"mermaid\" data-kind=\"flow\">\n"
           "  <code class='sourceCode' data-extra=\"yes\">A --&gt; B</code></pre>\n"
           "<pre class='sourceCode mermaid extra'><code data-n=\"1\">C</code></pre>\n"
           "<pre><code class=\"elisp\">(+ 1 2)</code></pre>"))
         (expected
          (concat
           "<h1>Diagram</h1>\n"
           "<pre><code class=\"mermaid\">flowchart LR</code></pre>\n"
           "<pre id=\"diagram\" data-kind=\"flow\">\n"
           "  <code class='sourceCode mermaid' data-extra=\"yes\">A --&gt; B</code></pre>\n"
           "<pre class='sourceCode extra'><code data-n=\"1\" class=\"mermaid\">C</code></pre>\n"
           "<pre><code class=\"elisp\">(+ 1 2)</code></pre>")))
    (should (equal (mr-x/markdown-normalize-pandoc-mermaid-html input)
                   expected))
    ;; A live-preview refresh can pass an already-normalized file through
    ;; again, so the compatibility transform must be idempotent.
    (should (equal (mr-x/markdown-normalize-pandoc-mermaid-html expected)
                   expected))))

(ert-deftest config-test-markdown-mermaid-file-preserves-encoding ()
  "Normalizing generated HTML must retain its UTF-8 bytes and CRLF endings."
  (require 'markdown-xwidget)
  (let* ((file (make-temp-file "markdown-mermaid-" nil ".html"))
         (input (concat "<p>café</p>\n"
                        "<pre class=\"mermaid\"><code>A</code></pre>\n"))
         (expected (concat "<p>café</p>\n"
                           "<pre><code class=\"mermaid\">A</code></pre>\n")))
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'utf-8-dos))
            (with-temp-file file
              (insert input)))
          (mr-x/markdown-normalize-pandoc-mermaid-file file)
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert-file-contents-literally file)
            (should (equal (buffer-string)
                           (encode-coding-string expected 'utf-8-dos)))))
      (delete-file file))))

(ert-deftest config-test-markdown-mermaid-header-is-customizable ()
  "Generated Mermaid config must expose the approved editable defaults."
  (require 'markdown-xwidget)
  (should (fboundp 'mr-x/markdown-mermaid-header-html))
  (let ((mr-x/markdown-mermaid-look "classic")
        (mr-x/markdown-mermaid-font-family "Iosevka, monospace"))
    (let ((header (mr-x/markdown-mermaid-header-html)))
      (should (string-match-p "\\\"theme\\\":\\\"base\\\"" header))
      (should (string-match-p "\\\"look\\\":\\\"classic\\\"" header))
      (should (string-match-p "Iosevka, monospace" header))
      (should (string-match-p "#282828" header))
      (should (string-match-p "cluster-label" header))
      ;; Mermaid documents `initialize' as a once-per-page operation.  Replace
      ;; markdown-xwidget's small initializer instead of appending a second one.
      (with-temp-buffer
        (insert header)
        (should (= (how-many "mermaid\\.initialize(" (point-min) (point-max))
                   1)))))
  ;; Preserve markdown-xwidget's existing theme knob; `base' remains the
  ;; configured default, but a deliberate package-level override still works.
  (let ((markdown-xwidget-mermaid-theme "forest"))
    (should (string-match-p
             "\\\"theme\\\":\\\"forest\\\""
             (mr-x/markdown-mermaid-header-html))))
  ;; Rebuilding Mermaid config must not drop transcript DOM behavior.
  (should (string-match-p "transcript-meta"
                          (mr-x/markdown-preview-header-html t))))

(ert-deftest config-test-markdown-mermaid-toggle-refreshes-preview ()
  "The Mermaid look key must toggle and immediately refresh a live preview."
  (require 'markdown-xwidget)
  (should (fboundp 'mr-x/markdown-mermaid-toggle-look))
  (require 'markdown-mode)
  (should (eq (keymap-lookup markdown-mode-map "C-c C-c m")
              'mr-x/markdown-mermaid-toggle-look))
  (let ((mr-x/markdown-mermaid-look "classic")
        (markdown-xwidget-preview-mode t)
        (markdown-xhtml-header-content "stale")
        (refreshes 0))
    (cl-letf (((symbol-function 'markdown-live-preview-export)
               (lambda () (cl-incf refreshes))))
      (mr-x/markdown-mermaid-toggle-look)
      (should (equal mr-x/markdown-mermaid-look "handDrawn"))
      (should (= refreshes 1))
      (should (string-match-p "\\\"look\\\":\\\"handDrawn\\\""
                              markdown-xhtml-header-content))
      (mr-x/markdown-mermaid-toggle-look)
      (should (equal mr-x/markdown-mermaid-look "classic"))
      (should (= refreshes 2))))
  ;; Interactive invocation requests persistence without touching Custom in
  ;; this test process.
  (let ((mr-x/markdown-mermaid-look "classic")
        (markdown-xwidget-preview-mode nil)
        persisted)
    (cl-letf (((symbol-function 'customize-save-variable)
               (lambda (variable value)
                 (setq persisted (cons variable value))
                 (set variable value))))
      (mr-x/markdown-mermaid-toggle-look t))
    (should (equal persisted
                   '(mr-x/markdown-mermaid-look . "handDrawn")))
    (should (equal mr-x/markdown-mermaid-look "handDrawn"))))

(ert-deftest config-test-markdown-mermaid-layout-caps-inline-preview ()
  "Inline Mermaid stays moderate while full-viewport mode remains optional."
  (require 'markdown-xwidget)
  (should (fboundp 'mr-x/markdown-mermaid-layout-style))
  (let ((mr-x/markdown-mermaid-full-width nil)
        (mr-x/markdown-mermaid-gutter 24)
        (mr-x/markdown-mermaid-inline-max-width 1100))
    (let ((header (mr-x/markdown-preview-header-html)))
      (should (string-match-p "id=\"mr-x-mermaid-layout\"" header))
      ;; markdown-xwidget's header says `margin: 0 auto', but GitHub's more
      ;; specific `.markdown-body { margin: 0; }' wins after that class is
      ;; attached.  The layout style must restore the intended centering.
      (should (string-match-p
               (regexp-quote "body.markdown-body {")
               header))
      (should (string-match-p
               (regexp-quote "margin-left: auto !important;")
               header))
      (should (string-match-p
               (regexp-quote "margin-right: auto !important;")
               header))
      (should (string-match-p
               (regexp-quote
                "width: min(1100px, calc(100vw - 48px)) !important;")
               header))
      (should (string-match-p
               (regexp-quote
                (concat "margin-left: calc(50% - min(550px, "
                        "calc(50vw - 24px))) !important;"))
               header))
      (should (string-match-p
               (regexp-quote "pre > code.mermaid > svg")
               header))))
  ;; Full-bleed remains available as a deliberate Customize override.
  (let ((mr-x/markdown-mermaid-full-width t)
        (mr-x/markdown-mermaid-gutter 24))
    (let ((header (mr-x/markdown-preview-header-html)))
      (should (string-match-p
               (regexp-quote "width: calc(100vw - 48px) !important;")
               header))
      (should (string-match-p
               (regexp-quote
                "margin-left: calc(50% - 50vw + 24px) !important;")
               header)))))

(ert-deftest config-test-markdown-mermaid-viewer-is-in-generated-page ()
  "Generated previews must carry the diagram viewer and Chrome protocol."
  (require 'markdown-xwidget)
  (should (fboundp 'mr-x/markdown-mermaid-viewer-script))
  (let ((header (mr-x/markdown-preview-header-html)))
    (with-temp-buffer
      (insert header)
      (should (= (how-many "id=\"mr-x-mermaid-viewer-script\""
                           (point-min) (point-max))
                 1)))
    (should (string-match-p "mr-x-mermaid-chrome=app:" header))
    (should (string-match-p "mr-x-mermaid-chrome=tab:" header))
    (should (string-match-p "mr-x-mermaid-view=" header))))

(ert-deftest config-test-markdown-mermaid-launches-both-chrome-modes ()
  "Chrome tab and app-window actions must launch distinct macOS commands."
  (require 'markdown-xwidget)
  (should (fboundp 'mr-x/markdown-mermaid-launch-chrome))
  (let ((mr-x/markdown-mermaid-chrome-application "Google Chrome")
        (mr-x/markdown-mermaid-chrome-profile-directory
         "/tmp/markdown-mermaid-chrome-profile")
        directories
        calls)
    (cl-letf (((symbol-function 'xwidget-webkit-uri)
               (lambda (_xwidget)
                 (concat "file:///tmp/network-diagrams.html"
                         "?mr-x-mermaid-chrome=tab:3")))
              ((symbol-function 'start-process)
               (lambda (&rest arguments)
                 (push arguments calls)
                 'chrome-process))
              ((symbol-function 'make-directory)
               (lambda (directory parents)
                 (push (list directory parents) directories))))
      (should (eq (mr-x/markdown-mermaid-launch-chrome
                   'preview-xwidget 'tab 3)
                  'chrome-process))
      (should (eq (mr-x/markdown-mermaid-launch-chrome
                   'preview-xwidget 'app 3)
                  'chrome-process)))
    (should
     (equal
      (nreverse calls)
      '(("markdown-mermaid-chrome-tab" nil "/usr/bin/open"
         "-a" "Google Chrome"
         "file:///tmp/network-diagrams.html#mr-x-mermaid-view=3")
        ("markdown-mermaid-chrome-app" nil "/usr/bin/open"
         "-na" "Google Chrome" "--args"
         "--user-data-dir=/tmp/markdown-mermaid-chrome-profile"
         "--no-first-run" "--no-default-browser-check"
         "--app=file:///tmp/network-diagrams.html#mr-x-mermaid-view=3"))))
    ;; Native compilation can create its own cache directory while the
    ;; `start-process' call is stubbed, so assert specifically on our profile.
    (should (member '("/tmp/markdown-mermaid-chrome-profile" t)
                    directories))))

(ert-deftest config-test-markdown-xwidget-callback-routes-chrome-actions ()
  "Viewer action navigations route to Chrome; ordinary events delegate."
  (require 'markdown-xwidget)
  (should (fboundp 'mr-x/markdown-xwidget-callback))
  (let (launches delegated current-uri)
    (cl-letf (((symbol-function 'mr-x/markdown-mermaid-launch-chrome)
               (lambda (xwidget mode index)
                 (push (list xwidget mode index) launches)))
              ((symbol-function 'xwidget-webkit-uri)
               (lambda (_xwidget) current-uri))
              ((symbol-function 'xwidget-webkit-execute-script)
               (lambda (&rest _arguments)))
              ((symbol-function 'xwidget-webkit-callback)
               (lambda (xwidget event)
                 (push (list xwidget event) delegated))))
      ;; WebKit does not emit an xwidget event for same-document hash changes.
      ;; A temporary query navigation reliably emits `load-started', which is
      ;; early enough to launch once before the remaining load events delegate.
      (setq current-uri
            "file:///tmp/diagram.html?mr-x-mermaid-chrome=app:2")
      (let ((last-input-event
             '(xwidget-event load-changed preview-xwidget "load-started")))
        (mr-x/markdown-xwidget-callback 'preview-xwidget 'load-changed))
      (setq current-uri
            "file:///tmp/diagram.html?mr-x-mermaid-chrome=tab:4")
      (let ((last-input-event
             '(xwidget-event load-changed preview-xwidget "load-started")))
        (mr-x/markdown-xwidget-callback 'preview-xwidget 'load-changed))
      (setq current-uri "file:///tmp/diagram.html")
      (let ((last-input-event
             '(xwidget-event load-changed preview-xwidget "load-finished")))
        (mr-x/markdown-xwidget-callback 'preview-xwidget 'load-changed)))
    (should (equal (nreverse launches)
                   '((preview-xwidget app 2)
                     (preview-xwidget tab 4))))
    (should (equal delegated
                   '((preview-xwidget load-changed))))))

(ert-deftest config-test-markdown-xwidget-preview-fits-display-window ()
  "A preview's native xwidget must fit the window that displays its buffer."
  (require 'markdown-xwidget)
  (should (fboundp 'mr-x/markdown-xwidget-preview-file))
  (let ((preview-buffer (generate-new-buffer " *markdown-xwidget-test*"))
        (display-window (selected-window))
        normalized-file
        displayed
        resized
        callback-installed
        hscroll-reset)
    (unwind-protect
        (cl-letf (((symbol-function
                    'mr-x/markdown-normalize-pandoc-mermaid-file)
                   (lambda (file)
                     (setq normalized-file file)
                     file))
                  ((symbol-function 'markdown-xwidget-preview)
                   (lambda (_file) preview-buffer))
                  ((symbol-function 'display-buffer)
                   (lambda (buffer action)
                     (setq displayed (list buffer action))
                     display-window))
                  ((symbol-function 'xwidget-webkit-current-session)
                   (lambda () 'preview-session))
                  ((symbol-function 'xwidget-webkit-adjust-size-to-window)
                   (lambda (session window)
                     (setq resized (list session window))))
                  ((symbol-function 'xwidget-put)
                   (lambda (xwidget property value)
                     (setq callback-installed
                           (list xwidget property value))))
                  ((symbol-function 'set-window-hscroll)
                   (lambda (window columns)
                     (setq hscroll-reset (list window columns)))))
          (should (eq (mr-x/markdown-xwidget-preview-file "/tmp/diagram.html")
                      preview-buffer))
          (should (equal normalized-file "/tmp/diagram.html"))
          (should (equal displayed
                         (list preview-buffer '(display-buffer-same-window))))
          (should (equal resized (list 'preview-session display-window)))
          (should (equal callback-installed
                         (list 'preview-session 'callback
                               #'mr-x/markdown-xwidget-callback)))
          (should (equal hscroll-reset (list display-window 0))))
      (kill-buffer preview-buffer)))
  ;; Exercise the preview-mode boundary too: defining the helper without
  ;; installing it would leave users on the old stale-size lambda.
  (let ((markdown-live-preview-window-function nil)
        (markdown-css-paths nil)
        (markdown-command "pandoc")
        (markdown-xhtml-header-content nil))
    (cl-letf (((symbol-function 'markdown-live-preview-mode) #'ignore))
      (markdown-xwidget-preview-mode--enable))
    (should (eq markdown-live-preview-window-function
                #'mr-x/markdown-xwidget-preview-file))))

(ert-deftest config-test-org-todo-keywords-use-named-faces ()
  "Org TODO keywords must resolve to faces that frames can override."
  (should (equal org-modern-todo-faces mr-x/todo-faces))
  (dolist (entry '(("TODO" . mr-x/org-todo-todo-face)
                   ("NEXT" . mr-x/org-todo-next-face)
                   ("WAIT" . mr-x/org-todo-wait-face)
                   ("DONE" . mr-x/org-todo-done-face)
                   ("CANC" . mr-x/org-todo-cancelled-face)))
    (should (facep (cdr entry)))
    (should (eq (org-get-todo-face (car entry)) (cdr entry)))))

(ert-deftest config-test-calliope-org-todo-faces-are-monochrome ()
  "Calliope TODO states must use the approved E Ink hierarchy."
  ;; Creating a disposable tty frame is unsupported in batch mode, so spy at
  ;; the mutation boundary and verify the real styling function's full output.
  (let ((frame (selected-frame))
        face-calls
        frame-parameter-calls)
    (cl-letf (((symbol-function 'mr-x/frame-profile)
               (lambda (&optional _frame) 'eink))
              ((symbol-function 'set-frame-parameter)
               (lambda (target parameter value)
                 (push (list target parameter value) frame-parameter-calls)))
              ((symbol-function 'set-face-attribute)
               (lambda (face target &rest attributes)
                 (push (list face target attributes) face-calls))))
      (mr-x/eink-tty-faces frame))
    (should (member (list frame 'menu-bar-lines 0) frame-parameter-calls))
    (dolist (entry
             '((mr-x/org-todo-todo-face
                (:foreground "#000000" :background "#ffffff"
                 :weight bold :strike-through nil))
               (mr-x/org-todo-next-face
                (:foreground "#ffffff" :background "#000000"
                 :weight bold :strike-through nil))
               (mr-x/org-todo-wait-face
                (:foreground "#000000" :background "#d0d0d0"
                 :weight bold :strike-through nil))
               (mr-x/org-todo-done-face
                (:foreground "#767676" :background "#ffffff"
                 :weight normal :strike-through t))
               (mr-x/org-todo-cancelled-face
                (:foreground "#767676" :background "#ffffff"
                 :weight normal :strike-through t))))
      (let ((call (assq (car entry) face-calls)))
        (should call)
        (should (eq (cadr call) frame))
        (should (equal (caddr call) (cadr entry)))))))

(ert-deftest config-test-eink-faces-cover-existing-frames ()
  "E Ink styling must cover reloads and standalone initial frames."
  (let ((calliope-frame 'calliope-frame)
        (daemon-frame 'daemon-frame)
        applied)
    ;; A daemon reload must restyle an existing tagged Calliope frame without
    ;; touching Emacs's untagged daemon pseudo-frame.
    (cl-letf (((symbol-function 'daemonp) (lambda () t))
              ((symbol-function 'frame-list)
               (lambda () (list calliope-frame daemon-frame)))
              ((symbol-function 'frame-parameter)
               (lambda (frame parameter)
                 (and (eq parameter 'device)
                      (eq frame calliope-frame)
                      'calliope)))
              ((symbol-function 'mr-x/eink-tty-faces)
               (lambda (frame) (push frame applied))))
      (mr-x/apply-eink-faces-to-existing-frames))
    (should (equal applied (list calliope-frame)))
    ;; A non-daemon startup has no after-make-frame event for its initial
    ;; frame, so pass every existing frame through the profile-gated styler.
    (setq applied nil)
    (cl-letf (((symbol-function 'daemonp) (lambda () nil))
              ((symbol-function 'frame-list)
               (lambda () (list daemon-frame calliope-frame)))
              ((symbol-function 'mr-x/eink-tty-faces)
               (lambda (frame) (push frame applied))))
      (mr-x/apply-eink-faces-to-existing-frames))
    (should (equal applied (list calliope-frame daemon-frame)))))

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
  "agent-shell permission actions live on the macro pad (F13-F16); queue variable must exist.
Evil-normal 1/2/3 digit binds were retired in the F-key migration."
  (should (boundp 'mr-x/pending-permissions-queue))
  (should (eq (lookup-key agent-shell-mode-map (kbd "<f13>"))
              'mr-x/agent-shell-allow))
  (should (eq (lookup-key agent-shell-mode-map (kbd "<f14>"))
              'mr-x/agent-shell-deny))
  (should (eq (lookup-key agent-shell-mode-map (kbd "<f15>"))
              'mr-x/agent-shell-allow-always))
  (should (eq (lookup-key agent-shell-mode-map (kbd "<f16>"))
              'mr-x/agent-shell-view-diff)))

;; ── SPC c (Agent Shell leader subtree) ─────────────────────────────────────

(defun config-test--leader-key (keys)
  "Look up KEYS under the SPC leader map."
  (let ((leader-map (config-test--leader-map)))
    (and leader-map (lookup-key leader-map (kbd keys)))))

(ert-deftest config-test-leader-agent-shell-subtree ()
  "SPC c subtree: core agent-shell commands must resolve correctly."
  (should (eq (config-test--leader-key "c c") 'mr-x/agent-shell-new-smart))
  (should (eq (config-test--leader-key "c n") 'mr-x/agent-shell-clone))
  (should (eq (config-test--leader-key "c C") 'mr-x/agent-shell-preset-in-project))
  (should (eq (config-test--leader-key "c x") 'mr-x/agent-shell-sol))
  (should (eq (config-test--leader-key "c P") 'mr-x/agent-shell-start-preset))
  (should (eq (config-test--leader-key "c t") 'mr-x/agent-shell-toggle))
  (should (eq (config-test--leader-key "c w") 'mr-x/focus-ai-window))
  (should (eq (config-test--leader-key "c i") 'agent-shell-interrupt))
  ;; Recall moved c a -> c / (refs/context c x -> c a lives in the global
  ;; normal-state map, not this override leader map, so it isn't checked here).
  (should (eq (config-test--leader-key "c / s c") 'agent-recall-consult-search)))

(ert-deftest config-test-leader-agent-shell-send ()
  "SPC c send commands must resolve correctly."
  (should (eq (config-test--leader-key "c p") 'mr-x/agent-shell-apply-preset))
  (should (eq (config-test--leader-key "c r") 'mr-x/agent-send-region-no-switch))
  (should (eq (config-test--leader-key "c R") 'mr-x/agent-send-region))
  (should (eq (config-test--leader-key "c f") 'mr-x/agent-send-file))
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

(ert-deftest config-test-leader-pane-keys ()
  "SPC & pane keys must resolve correctly."
  (should (eq (config-test--leader-key "& n") 'major-pane-new-chat))
  (should (eq (config-test--leader-key "& N") 'major-pane-new-ejected-chat))
  (should (eq (config-test--leader-key "& l") 'major-pane-set-label))
  (should (eq (config-test--leader-key "& b") 'major-pane-capture-buffer))
  (should (eq (config-test--leader-key "& h") 'major-pane-set-home-frame))
  (should (eq (config-test--leader-key "& k") 'major-pane-close-conversation))
  (should (eq (config-test--leader-key "& K") 'major-pane-close-all-conversations))
  (should (eq (config-test--leader-key "& e") 'major-pane-eject-conversation))
  (should (eq (config-test--leader-key "& a") 'major-pane-adopt-conversation)))

;; ═══════════════════════════════════════════════════════════════════════════
;; Tier 7 — "Are critical variables bound?"
;; Load-order regressions: variables that must exist before other code runs.
;; ═══════════════════════════════════════════════════════════════════════════

(ert-deftest config-test-load-order-variables ()
  "Variables that other code depends on must be bound after init."
  (should (boundp 'mr-x/pending-permissions-queue))
  (should (boundp 'mr-x/escape-hook))
  (should (boundp 'mr-x/palettes))
  (should (boundp 'mr-x/agenda-separator)))

(ert-deftest config-test-agent-shell-markdown-customizations ()
  "In-place renderer customizations register once agent-shell-markdown loads."
  (require 'agent-shell-markdown nil t)
  (if (featurep 'agent-shell-markdown)
      (progn
        (should (boundp 'mr-x/agent-shell-lang-file-alist))
        (should (fboundp 'mr-x/agent-shell-code-block-icon))
        (should (fboundp 'mr-x/agent-shell-restyle-code-labels))
        (should (advice-member-p 'mr-x/agent-shell-restyle-code-labels
                                 'agent-shell-markdown-replace-markup))
        (should (advice-member-p 'mr-x/agent-shell-highlight-code-rainbow
                                 'agent-shell-markdown--highlight-code)))
    (ert-skip "agent-shell-markdown not loadable in batch")))

(ert-deftest config-test-evil-collection-exclusions ()
  "Modes we manually bind must be excluded from evil-collection."
  (should-not (memq 'vterm evil-collection-mode-list)))

(ert-deftest config-test-vertico-directory-bindings ()
  "vertico-directory must own RET/DEL in the minibuffer for file completion."
  (should (fboundp 'vertico-directory-enter))
  (should (eq (keymap-lookup vertico-map "RET") 'vertico-directory-enter))
  (should (eq (keymap-lookup vertico-map "DEL") 'vertico-directory-delete-char))
  ;; use-package :hook appends "-hook" — that suffixed name is the real var.
  (should (memq 'vertico-directory-tidy rfn-eshadow-update-overlay-hook)))

(ert-deftest config-test-major-pane-display-routing ()
  "Agent conversations must route into the major-pane via display-buffer-alist.
Covers all display paths and ALL agent types (Claude, Goose, ...)."
  (should (fboundp 'major-pane-display-buffer-action))
  (should (fboundp 'mr-x/agent-pane-buffer-p))
  (let ((entry (assoc 'mr-x/agent-pane-buffer-p display-buffer-alist)))
    (should entry)
    (should (memq 'major-pane-display-buffer-action (cadr entry))))
  ;; the name fallback must cover every agent type's naming convention
  (dolist (name '("Claude Agent @ proj" "Goose Agent @ proj"))
    (should (with-temp-buffer
              (rename-buffer name t)
              (mr-x/agent-pane-buffer-p (buffer-name) nil)))))

(ert-deftest config-test-major-pane-active-anchor-rail-is-outer-left-edge ()
  "An active anchored tab must not paint yellow outside its orange rail.
The normal active-tab separator remains yellow on the right; only the
separator immediately before the active tab's six-pixel anchor rail stays
dark, making that rail the outer left boundary."
  (require 'major-pane)
  (let* ((left (generate-new-buffer " *major-pane-left-anchor-test*"))
         (active (generate-new-buffer " *major-pane-active-anchor-test*"))
         (right (generate-new-buffer " *major-pane-right-tab-test*"))
         (major-pane--state
          (major-pane--make-state
           :mode 'hidden
           :conversations (list left active right)
           :active active))
         (major-pane--anchored (list left active))
         (major-pane--ping-set nil)
         (major-pane-tab-divider nil))
    (unwind-protect
        (let* ((tabs (major-pane--render-tabs))
               (rails (cl-loop for i below (length tabs)
                               when (equal (get-text-property i 'display tabs)
                                           '(space :width (6)))
                               collect i))
               (active-rail (cadr rails))
               (right-separator
                (cl-loop for i from (1+ active-rail) below (length tabs)
                         when (equal (get-text-property i 'display tabs)
                                     '(space :width (2)))
                         return i)))
          (should (= (length rails) 2))
          (should (eq (get-text-property (1- active-rail) 'face tabs)
                      'major-pane-tab-separator))
          (should (eq (get-text-property right-separator 'face tabs)
                      'major-pane-tab-separator-active)))
      (mapc #'kill-buffer (list left active right)))))

(ert-deftest config-test-major-pane-spinner ()
  "Busy-tab spinner: machinery defined, styles well-formed, no arith-error.
Every style must be a non-empty list of strings — an empty frame list
divides by zero inside the header-line `:eval', which makes Emacs
drop the entire tab row."
  (require 'major-pane)   ; deferred in batch — only autoloads exist until required
  (should (fboundp 'major-pane--spinner-sync))
  (should (fboundp 'major-pane--spinner-tick))
  (should (commandp 'major-pane-spinner-style))
  (dolist (style major-pane-spinner-styles)
    (should (consp (cdr style)))
    (dolist (frame (cdr style))
      (should (stringp frame))))
  ;; frames var must point at one of the named styles
  (should (rassoc major-pane-spinner-frames major-pane-spinner-styles))
  ;; robustness: empty frame list must yield "" rather than signal
  (let ((major-pane-spinner-frames nil))
    (should (equal "" (major-pane--spinner-frame))))
  ;; no busy tabs at test time → timer must not be running
  (major-pane--spinner-sync)
  (should (null major-pane--spinner-timer)))

(ert-deftest config-test-major-pane-ping-keeps-computed-pixel-size ()
  "Done ping must opt out of Emacs' implicit high-DPI image scaling.
`major-pane--ping-build' already computes its canvas in frame pixels;
letting `svg-image' scale it again makes the ping oversized and breaks
its vertical clearance inside boxed tabs."
  (require 'major-pane)
  (let ((image (major-pane--ping-build 0)))
    (should (equal (image-property image :scale) 1))))

(ert-deftest config-test-major-pane-ping-bridges-inactive-done-underline ()
  "The ping SVG must replace the underline hidden by its display cell.
Emacs does not paint a face underline beneath a character replaced by
an image, and its decoration pass covers the SVG's last logical row.
The image therefore paints the penultimate row while the face moves its
underline up one pixel to meet it."
  (require 'major-pane)
  (require 'dom)
  (require 'xml)
  (cl-letf (((symbol-function 'frame-char-height)
             (lambda (&optional _frame) 30)))
    (let* ((image (major-pane--ping-build 0))
           (svg (with-temp-buffer
                  (insert (image-property image :data))
                  (car (xml-parse-region (point-min) (point-max)))))
           (bridge (car (dom-by-tag svg 'rect))))
      (should (equal (dom-attr svg 'width) "18"))
      (should (equal (dom-attr svg 'height) "30"))
      (should bridge)
      (should (equal (dom-attr bridge 'x) "0"))
      (should (equal (dom-attr bridge 'y) "28"))
      (should (equal (dom-attr bridge 'width) "18"))
      (should (equal (dom-attr bridge 'height) "1"))
      (should (equal (dom-attr bridge 'fill) "#b8bb26")))))

(ert-deftest config-test-major-pane-ping-keeps-valid-canvas-with-tiny-frame-metrics ()
  "Batch-mode frame metrics must not produce a negative bridge position."
  (require 'major-pane)
  (require 'dom)
  (require 'xml)
  (cl-letf (((symbol-function 'frame-char-height)
             (lambda (&optional _frame) 1)))
    (let* ((image (major-pane--ping-build 0))
           (svg (with-temp-buffer
                  (insert (image-property image :data))
                  (car (xml-parse-region (point-min) (point-max)))))
           (bridge (car (dom-by-tag svg 'rect))))
      (should (equal (dom-attr svg 'height) "8"))
      (should (equal (dom-attr bridge 'y) "6")))))

(ert-deftest config-test-major-pane-ping-raises-only-its-own-underline ()
  "Only a displayed ping moves the done underline to its bridge row."
  (require 'major-pane)
  (let ((buf (generate-new-buffer " *major-pane-ping-underline-test*"))
        (major-pane--ping-cache (make-hash-table :test 'equal))
        (major-pane--spinner-index 0)
        (major-pane--anchored nil))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (setq major-pane--tab-attention 'done))
          ;; The base/recent done style retains its original bottom position.
          (should (equal (plist-get
                          (face-attribute 'major-pane-tab-attention-done
                                          :underline nil t)
                          :position)
                         0))
          (cl-letf (((symbol-function 'frame-char-height)
                     (lambda (&optional _frame) 30)))
            (let* ((major-pane--ping-set (list buf))
                   (fresh (major-pane--render-tab buf nil))
                   (image-pos (cl-loop for i below (length fresh)
                                       for display = (get-text-property
                                                      i 'display fresh)
                                       when (and (listp display)
                                                 (eq (car display) 'image))
                                       return i))
                   (fresh-face-prop (get-text-property image-pos 'face fresh))
                   (fresh-face (and (consp fresh-face-prop)
                                    (car fresh-face-prop)))
                   (recent (let ((major-pane--ping-set nil))
                             (major-pane--render-tab buf nil))))
              (should fresh-face)
              (should (equal (plist-get (plist-get fresh-face :underline)
                                        :position)
                             1))
              (should (eq (get-text-property 0 'face recent)
                          'major-pane-tab-attention-done)))))
      (kill-buffer buf))))

(ert-deftest config-test-major-pane-ping-hover-bridges-done-underline ()
  "Hovering a pinging done tab must preserve its green underline bridge."
  (require 'major-pane)
  (let ((buf (generate-new-buffer " *major-pane-ping-hover-test*"))
        (major-pane--ping-cache (make-hash-table :test 'equal))
        (major-pane--spinner-index 0)
        (major-pane--anchored nil))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (setq major-pane--tab-attention 'done))
          (let ((major-pane--ping-set (list buf)))
            (cl-letf (((symbol-function 'frame-char-height)
                       (lambda (&optional _frame) 30)))
              (let* ((tab (major-pane--render-tab buf nil))
                     (image-pos (cl-loop for i below (length tab)
                                         for display = (get-text-property
                                                        i 'display tab)
                                         when (and (listp display)
                                                   (eq (car display) 'image))
                                         return i))
                     (hover (get-text-property image-pos 'mouse-face tab))
                     (underline (and (listp hover)
                                     (plist-get hover :underline))))
                (should (listp hover))
                (should (eq (plist-get hover :inherit)
                            'major-pane-tab-hover-done))
                (should (equal (plist-get underline :color) "#b8bb26"))
                (should (equal (plist-get underline :position) 1))))))
      (kill-buffer buf))))

(ert-deftest config-test-major-pane-anchored-ping-hover-bridges-anchor-underline ()
  "Hovering an anchored ping must preserve its orange underline bridge."
  (require 'major-pane)
  (let* ((buf (generate-new-buffer " *major-pane-anchor-hover-test*"))
         (major-pane--ping-cache (make-hash-table :test 'equal))
         (major-pane--spinner-index 0)
         (major-pane--anchored (list buf)))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (setq major-pane--tab-attention 'done))
          (let ((major-pane--ping-set (list buf)))
            (cl-letf (((symbol-function 'frame-char-height)
                       (lambda (&optional _frame) 30)))
              (let* ((tab (major-pane--render-tab buf nil))
                     (image-pos (cl-loop for i below (length tab)
                                         for display = (get-text-property
                                                        i 'display tab)
                                         when (and (listp display)
                                                   (eq (car display) 'image))
                                         return i))
                     (hover (get-text-property image-pos 'mouse-face tab))
                     (underline (and (listp hover)
                                     (plist-get hover :underline))))
                (should (listp hover))
                (should (eq (plist-get hover :inherit)
                            'major-pane-tab-hover-done))
                (should (equal (plist-get underline :color) "#fe8019"))
                (should (equal (plist-get underline :position) 1))))))
      (kill-buffer buf))))

(ert-deftest config-test-major-pane-active-ping-does-not-paint-done-underline ()
  "An active done tab keeps its yellow box and must not gain a green edge."
  (require 'major-pane)
  (require 'dom)
  (require 'xml)
  (let ((buf (generate-new-buffer " *major-pane-active-ping-test*"))
        (major-pane--ping-cache (make-hash-table :test 'equal))
        (major-pane--spinner-index 0)
        (major-pane--anchored nil))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (setq major-pane--tab-attention 'done))
          (let ((major-pane--ping-set (list buf)))
            (cl-letf (((symbol-function 'frame-char-height)
                       (lambda (&optional _frame) 30)))
              (let* ((tab (major-pane--render-tab buf t))
                     (image (cl-loop for i below (length tab)
                                     for display = (get-text-property i 'display tab)
                                     when (and (listp display)
                                               (eq (car display) 'image))
                                     return display))
                     (svg (with-temp-buffer
                            (insert (image-property image :data))
                            (car (xml-parse-region (point-min) (point-max))))))
                (should image)
                (should (equal (dom-attr svg 'height) "30"))
                (should-not (dom-by-tag svg 'rect))))))
      (kill-buffer buf))))

(ert-deftest config-test-major-pane-anchored-ping-bridges-anchor-underline ()
  "An anchored ping must bridge its orange underline, not the done green."
  (require 'major-pane)
  (require 'dom)
  (require 'xml)
  (let* ((buf (generate-new-buffer " *major-pane-anchor-ping-test*"))
         (major-pane--ping-cache (make-hash-table :test 'equal))
         (major-pane--spinner-index 0)
         (major-pane--anchored (list buf)))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (setq major-pane--tab-attention 'done))
          (let ((major-pane--ping-set (list buf)))
            (cl-letf (((symbol-function 'frame-char-height)
                       (lambda (&optional _frame) 30)))
              (let* ((tab (major-pane--render-tab buf nil))
                     (image (cl-loop for i below (length tab)
                                     for display = (get-text-property i 'display tab)
                                     when (and (listp display)
                                               (eq (car display) 'image))
                                     return display))
                     (svg (with-temp-buffer
                            (insert (image-property image :data))
                            (car (xml-parse-region (point-min) (point-max)))))
                     (bridge (car (dom-by-tag svg 'rect)))
                     (image-pos (cl-loop for i below (length tab)
                                         for display = (get-text-property
                                                        i 'display tab)
                                         when (and (listp display)
                                                   (eq (car display) 'image))
                                         return i))
                     (anchor-face (car (get-text-property image-pos 'face tab))))
                (should image)
                (should bridge)
                (should (equal (dom-attr bridge 'y) "28"))
                (should (equal (dom-attr bridge 'fill) "#fe8019"))
                (should (equal (plist-get (plist-get anchor-face :underline)
                                          :position)
                               1))))))
      (kill-buffer buf))))

(ert-deftest config-test-major-pane-ping-busts-legacy-image-cache ()
  "A hot reload must not reuse images built by cache version 1."
  (require 'major-pane)
  (let ((major-pane--ping-cache (make-hash-table :test 'equal))
        (major-pane-ping-size 0.6)
        (major-pane-ping-margin 0.15)
        (major-pane-done-ping-color "#d3869b"))
    ;; Version 1 was the immediately preceding complete cache key: it had
    ;; explicit image scaling, but not the full-height underline bridge.
    (puthash (list 1 0 (frame-char-height) 0.6 0.15 "#d3869b")
             'version-1-short-canvas-image
             major-pane--ping-cache)
    (let ((image (major-pane--ping-image 0)))
      (should-not (eq image 'version-1-short-canvas-image))
      (should (equal (image-property image :scale) 1)))))

;; ═══════════════════════════════════════════════════════════════════════════
;; Tangle freshness — init.el must match a fresh tangle of emacs.org
;; ═══════════════════════════════════════════════════════════════════════════

(ert-deftest config-test-tangled-output-in-sync ()
  "init.el and agent-shell-config.el must match a fresh tangle of emacs.org.
Catches edits to emacs.org made outside Emacs (scripts, agents, git merges)
where the after-save auto-tangle hook never fired.  Works by copying
emacs.org into a temp dir, tangling there (targets are relative, so output
lands in the temp dir), and hashing fresh vs live output."
  (require 'org)
  (let* ((src (expand-file-name "emacs.org" user-emacs-directory))
         (tmpdir (make-temp-file "tangle-sync-" t))
         (tmp-org (expand-file-name "emacs.org" tmpdir)))
    (unwind-protect
        (progn
          (copy-file src tmp-org)
          (let ((org-confirm-babel-evaluate nil))
            (org-babel-tangle-file tmp-org))
          (dolist (file '("init.el" "agent-shell-config.el"))
            (ert-info ((format "%s is stale — re-tangle emacs.org (C-c C-v t)" file))
              (let ((fresh (expand-file-name file tmpdir))
                    (live (expand-file-name file user-emacs-directory)))
                (should (file-exists-p fresh))
                (should (file-exists-p live))
                (cl-flet ((sha256 (f)
                            (with-temp-buffer
                              (insert-file-contents-literally f)
                              (secure-hash 'sha256 (current-buffer)))))
                  (should (string= (sha256 fresh) (sha256 live))))))))
      (delete-directory tmpdir t))))

;; ═══════════════════════════════════════════════════════════════════════════
;; Byte-compile freshness — no stale .elc anywhere in the config
;; ═══════════════════════════════════════════════════════════════════════════

(ert-deftest config-test-load-prefer-newer ()
  "early-init.el must turn on load-prefer-newer so stale .elc files can
never shadow edited .el sources.  Batch runs skip early-init (it's only
part of normal startup), so load it here and check the var it sets."
  (load (expand-file-name "early-init" user-emacs-directory) nil t)
  (should load-prefer-newer))

(ert-deftest config-test-no-stale-elc ()
  "No .elc may be older than its .el source.
Scans elpaca/builds (where .el files are SYMLINKS into sources/ — editing
a package repo silently strands the neighboring .elc), plus lisp/ and the
config root.  Stale .elc = the code you're debugging isn't the code
running.  Fix: M-x elpaca-rebuild <pkg>, or delete the .elc."
  (let (stale)
    (dolist (dir (list (expand-file-name "elpaca/builds" user-emacs-directory)
                       (expand-file-name "lisp" user-emacs-directory)
                       user-emacs-directory))
      (when (file-directory-p dir)
        (dolist (elc (if (string= dir user-emacs-directory)
                         ;; root: don't recurse (would rescan builds/ + elpaca repos)
                         (directory-files dir t "\\.elc\\'")
                       (directory-files-recursively dir "\\.elc\\'")))
          (let ((el (file-truename (substring elc 0 -1)))) ; resolve symlink → repo source
            (when (and (file-exists-p el)
                       (file-newer-than-file-p el elc))
              (push (file-relative-name elc user-emacs-directory) stale))))))
    (should-not stale)))

;; ═══════════════════════════════════════════════════════════════════════════
;; Crash recovery — session snapshots + SPC R review screen
;; ═══════════════════════════════════════════════════════════════════════════

(ert-deftest config-test-crash-recovery-defined ()
  "Crash recovery commands and state variables exist."
  (should (fboundp 'mr-x/crash-recovery))
  (should (fboundp 'mr-x/crash-restore))
  (should (fboundp 'mr-x/crash-open-log))
  (should (fboundp 'mr-x/crash-discard))
  (should (fboundp 'mr-x/crash-pending-p))
  (should (fboundp 'mr-x/session-autosave))
  (should (boundp 'mr-x/crash-state-dir))
  (should (boundp 'mr-x/clean-exit-file))
  (should (boundp 'mr-x/yabai-state-file)))

(ert-deftest config-test-crash-recovery-daemon-only ()
  "Batch runs must not write crash markers or start the autosave timer.
If this fires in batch, the (daemonp) guard around the wiring was lost —
which would make every test run pollute crash detection state."
  (unless (daemonp)
    (should-not mr-x/session-autosave-timer)
    (should-not (member #'mr-x/--write-clean-exit-marker kill-emacs-hook))))

(ert-deftest config-test-lights-available ()
  "The lights dashboard command should be autoloaded."
  (should (fboundp 'lights)))

(ert-deftest config-test-buffer-pane-marker ()
  "Pane-membership marker should be advised onto buffer completion metadata."
  (should (fboundp 'mr-x/buffer-pane-prefix))
  (should (fboundp 'mr-x/buffer-pane-affixation))
  (should (advice-member-p 'mr-x/buffer-pane--metadata-get
                           'completion-metadata-get)))

(ert-deftest config-test-syzygy-resync ()
  "Phone-turn desync guard should be loaded with both advices installed.
The send block must sit on `shell-maker-submit' (pre-commit), NOT on
`agent-shell--handle' — blocking there wedges the buffer busy with a
committed-but-never-sent prompt."
  (should (fboundp 'syzygy-resync-buffer))
  (should (fboundp 'syzygy-resync--bounce-insert))
  (should (advice-member-p 'syzygy-resync--guard-submit 'shell-maker-submit))
  (should-not (advice-member-p 'syzygy-resync--guard 'agent-shell--handle))
  (should (advice-member-p 'syzygy-resync--flag
                           'agent-shell--make-out-of-session-turn-notification-body)))

(ert-deftest config-test-syzygy-package ()
  "The syzygy umbrella loads all three modules with their entry points.
Live mode's phone-prompt claim must sit on `agent-shell--on-notification',
and the handoff script the resume command shells out to must exist."
  (should (featurep 'syzygy))
  (should (fboundp 'syzygy-live-mode))
  (should (advice-member-p 'syzygy-live--on-notification
                           'agent-shell--on-notification))
  (should (advice-member-p 'syzygy-live--guard-submit 'shell-maker-submit))
  (should (fboundp 'syzygy-resume-handoff))
  (should (file-exists-p syzygy-handoff-script)))

(ert-deftest config-test-coding-prompt-trap ()
  "Raw-bytes-only coding prompts must auto-answer utf-8, others still ask.
The blocking \"Select coding system\" prompt stalled the daemon during
phone turns (acp-mobile); the trap answers for pure raw-byte text and
falls through to the interactive prompt for anything else."
  (should (advice-member-p 'mr-x/coding-prompt-trap
                           'select-safe-coding-system-interactively))
  ;; Raw bytes only -> auto-answer utf-8, orig never called.
  (should (eq 'utf-8
              (mr-x/coding-prompt-trap
               (lambda (&rest _) 'prompted)
               (concat "x " (string-to-multibyte (unibyte-string #xe2 #x80 #x94)))
               nil nil '(utf-8) nil 'raw-text)))
  ;; No raw bytes -> defer to the interactive prompt.
  (should (eq 'prompted
              (mr-x/coding-prompt-trap
               (lambda (&rest _) 'prompted)
               "clean text" nil nil '(utf-8) nil 'raw-text))))

(ert-deftest config-test-agent-shell-transcript-coding ()
  "Transcript appends must carry an explicit utf-8 write coding.
agent-shell's `write-region' has no coding binding; one undecoded byte
in a streamed chunk pops the blocking coding-system prompt mid-turn."
  (should (fboundp 'mr-x/agent-shell--transcript-utf8))
  (should (advice-member-p 'mr-x/agent-shell--transcript-utf8
                           'agent-shell--append-transcript)))

;;; config-tests.el ends here
