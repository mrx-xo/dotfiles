;;; agent-shell-keys-test.el --- Windows agent-shell key scope tests -*- lexical-binding: t; -*-

;; Load the Windows init with its installed packages before this file.
;; These tests create mode buffers, not agent processes or conversations.

(require 'ert)
(require 'agent-shell)
(require 'evil)

(ert-deftest windows-agent-shell-arrows-select-pane-tabs ()
  "Both arrows reach the correct pane command in every Evil state."
  (with-temp-buffer
    (delay-mode-hooks (agent-shell-mode))
    (evil-local-mode 1)
    (dolist (state '(normal insert visual motion replace operator emacs))
      (evil-change-state state)
      (ert-info ((format "agent-shell in %s state" state))
        (should (eq (key-binding (kbd "C-M-<left>"))
                    'major-pane-prev-tab))
        (should (eq (key-binding (kbd "C-M-<right>"))
                    'major-pane-next-tab))))))

(ert-deftest windows-agent-shell-ctrl-tab-cycles-pane-tabs ()
  "C-<tab> / C-S-<tab> cycle pane tabs in every Evil state, beating
evil-collection's normal-state C-<tab> session-mode cycle."
  (with-temp-buffer
    (delay-mode-hooks (agent-shell-mode))
    (evil-local-mode 1)
    (dolist (state '(normal insert visual motion replace operator emacs))
      (evil-change-state state)
      (ert-info ((format "agent-shell in %s state" state))
        (should (eq (key-binding (kbd "C-<tab>")) 'major-pane-next-tab))
        (should (eq (key-binding (kbd "C-S-<tab>")) 'major-pane-prev-tab))
        (should (eq (key-binding (kbd "C-S-<iso-lefttab>"))
                    'major-pane-prev-tab))))))

(ert-deftest windows-agent-shell-arrows-preserve-other-buffers ()
  "Agent tab navigation must not replace ordinary expression navigation."
  (dolist (mode '(fundamental-mode emacs-lisp-mode org-mode))
    (with-temp-buffer
      (delay-mode-hooks (funcall mode))
      (evil-local-mode 1)
      (dolist (state '(normal insert emacs))
        (evil-change-state state)
        (ert-info ((format "%s in %s state" mode state))
          (should (eq (key-binding (kbd "C-M-<left>")) 'backward-sexp))
          (should (eq (key-binding (kbd "C-M-<right>")) 'forward-sexp)))))))

;;; agent-shell-keys-test.el ends here
