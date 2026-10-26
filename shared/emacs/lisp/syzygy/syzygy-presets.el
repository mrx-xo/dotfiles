;;; syzygy-presets.el --- launch presets for acp-mobile -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; The phone's spawn sheet shows the same launch presets as the rig's
;; `mr-x/agent-shell-start-preset' (emacs.org).  Rather than a hand-copied
;; list in index.html that lags every rig edit, acp-mobile's /api/presets
;; evals `syzygy-presets-json' and renders whatever comes back.  Only the
;; one-char key travels back on spawn; Emacs resolves it.

;;; Code:

(require 'syzygy-bridge)

(defvar mr-x/agent-shell-presets)

(defun syzygy-presets--agent (config-fn)
  "Name the agent a preset's CONFIG-FN constructor targets.
Nil means the preferred (Claude) config.  Unknown constructors fall back
to their function name so a new agent still shows up rather than
disappearing."
  (cond ((null config-fn) "claude")
        ((eq config-fn 'agent-shell-openai-make-codex-config) "codex")
        ((eq config-fn 'agent-shell-opencode-make-agent-config) "opencode")
        ((eq config-fn 'mr-x/agent-shell-make-deepseek-config) "deepseek")
        (t (symbol-name config-fn))))

(defun syzygy-presets--entry (preset)
  "Return the JSON alist for one PRESET tuple of `mr-x/agent-shell-presets'."
  (pcase-let ((`(,char ,label ,model ,mode ,config-fn ,effort) preset))
    `((key . ,(string char))
      (label . ,label)
      (model . ,model)
      (mode . ,mode)
      (agent . ,(syzygy-presets--agent config-fn))
      (effort . ,(or effort "")))))

(defun syzygy-presets-json ()
  "Return `mr-x/agent-shell-presets' as base64-wrapped JSON for acp-mobile.
Each element: key, label, model, mode, agent, effort.  Order is the
rig's order.  Nil when the presets variable is unbound, which the Go
side maps to 404."
  (when (boundp 'mr-x/agent-shell-presets)
    (syzygy-bridge-encode-json
     (vconcat (mapcar #'syzygy-presets--entry mr-x/agent-shell-presets)))))

(defvar major-pane-mode-words)
(defvar major-pane-alert-mode-words)

(defun syzygy-mode-words-json ()
  "Return the rig's permission-mode words as base64-wrapped JSON.
Shape: {words: {MODE-ID: WORD}, alert: [WORD...]}, straight from
`major-pane-mode-words', so the phone's mode button reads the same
word the banner and preset picker show.  Nil when major-pane is not
loaded, which the Go side maps to 404."
  (when (boundp 'major-pane-mode-words)
    (syzygy-bridge-encode-json
     `((words . ,(mapcar (lambda (pair) (cons (intern (car pair)) (cdr pair)))
                         major-pane-mode-words))
       (alert . ,(vconcat major-pane-alert-mode-words))))))

(provide 'syzygy-presets)
;;; syzygy-presets.el ends here
