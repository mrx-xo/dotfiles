;;; agent-shell-pins.el --- Pinned @-file aliases for agent-shell -*- lexical-binding: t -*-

;;; Commentary:
;; Short handles for files you want @-mentionable from ANY project.
;; Typing @rig in an agent-shell (or its minibuffer composer) completes
;; like a project file regardless of the shell's project; on submit the
;; alias is rewritten to its full path just before agent-shell parses
;; mentions, so the agent receives the actual file content while the
;; prompt stays clean.
;;
;; Add pins by extending `agent-shell-pins-aliases'.
;;
;; NOTE: loaded from agent-shell-config.el — must not hard-require
;; agent-shell (Elpaca hasn't activated packages yet in batch mode).
;; Both advices attach fine to not-yet-defined functions.

;;; Code:

(defvar agent-shell-pins-aliases
  '(("rig"       . "~/roaming/notes/mr-x-rig-mdox.org")
    ("emacs-org" . "~/.dotfiles/macos/emacs/.emacs.d/emacs.org")
    ("claude-md" . "~/.claude/CLAUDE.md"))
  "Alist of (ALIAS . PATH) always offered in agent-shell @ completion.
ALIAS must only use chars in [:alnum:]/_.- (the @ completion char
class).  PATH may be absolute or ~-relative; it replaces the alias at
submit time, so pins work regardless of the shell's project.")

(defun agent-shell-pins--append-aliases (files)
  "Append alias names from `agent-shell-pins-aliases' to FILES."
  (append files (mapcar #'car agent-shell-pins-aliases)))

(advice-add 'agent-shell--project-files :filter-return
            #'agent-shell-pins--append-aliases)

(defun agent-shell-pins--expand-mentions (args)
  "Rewrite @ALIAS mentions in the prompt (car of ARGS) to full paths.
Runs as :filter-args advice on `agent-shell--build-content-blocks',
i.e. just before agent-shell parses @ mentions into content blocks.
The boundary groups mirror `agent-shell--parse-file-mentions': @ at
line start or after a non-word char, alias followed by a char outside
the path char class (or end), so @rig never matches inside @rig-notes."
  (let ((prompt (car args)))
    (pcase-dolist (`(,alias . ,path) agent-shell-pins-aliases)
      (setq prompt (replace-regexp-in-string
                    (concat "\\(^\\|[^[:word:]]\\)@" (regexp-quote alias)
                            "\\([^[:alnum:]/_.-]\\|$\\)")
                    (concat "\\1@" path "\\2")
                    prompt)))
    (cons prompt (cdr args))))

(advice-add 'agent-shell--build-content-blocks :filter-args
            #'agent-shell-pins--expand-mentions)

(provide 'agent-shell-pins)

;;; agent-shell-pins.el ends here
