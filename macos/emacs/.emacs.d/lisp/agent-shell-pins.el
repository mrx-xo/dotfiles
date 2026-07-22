;;; agent-shell-pins.el --- Pinned @-file aliases for agent-shell -*- lexical-binding: t -*-

;;; Commentary:
;; Short handles for files you want @-mentionable from ANY project.
;; Typing @rig in an agent-shell (or its minibuffer composer) completes
;; like a project file regardless of the shell's project; on submit the
;; alias is rewritten to its full path just before agent-shell parses
;; mentions, so the agent receives the actual file content while the
;; prompt stays clean.
;;
;; Managing pins:
;;   - M-x agent-shell-pins-add     — pick a file (find-file style), name it;
;;                                    live immediately AND persisted here
;;   - M-x agent-shell-pins-remove  — unpin, live + persisted
;;   - M-x agent-shell-pins-reload  — after HAND-editing the alist below;
;;                                    needed because re-loading a defvar
;;                                    never overwrites the live value
;;
;; NOTE: loaded from agent-shell-config.el — must not hard-require
;; agent-shell (Elpaca hasn't activated packages yet in batch mode).
;; Both advices attach fine to not-yet-defined functions.

;;; Code:

(defvar agent-shell-pins-aliases
  '(("rig"          . "~/roaming/notes/mr-x-rig-mdox.org")
    ("emacs-org"    . "~/.dotfiles/macos/emacs/.emacs.d/emacs.org")
    ("claude-md"    . "~/.claude/CLAUDE.md")
    ("prd-template" . "~/.dotfiles/macos/emacs/.emacs.d/persistent-completion-docs/TEMPLATE.md")
    ("inventory"    . "/Users/marcosandrade/roaming/notes/mr-x-inventory-mdox.org"))
  
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

;;; Managing pins interactively

(defvar agent-shell-pins-file
  (expand-file-name "lisp/agent-shell-pins.el" user-emacs-directory)
  "Source file holding the `agent-shell-pins-aliases' literal.
`agent-shell-pins-add' and `agent-shell-pins-remove' rewrite the
alist in place so pins survive restarts.")

(defun agent-shell-pins--format-alist (alist)
  "Render ALIST as the aligned quoted-list literal used in this file."
  (let ((w (+ 2 (apply #'max 0 (mapcar (lambda (p) (length (car p))) alist)))))
    (concat "'("
            (mapconcat (lambda (p)
                         (format "(%s . %S)"
                                 (string-pad (format "%S" (car p)) w)
                                 (cdr p)))
                       alist "\n    ")
            ")")))

(defun agent-shell-pins--save ()
  "Rewrite the alist literal in `agent-shell-pins-file' from the live value."
  (with-current-buffer (find-file-noselect agent-shell-pins-file)
    (save-excursion
      (goto-char (point-min))
      (unless (re-search-forward "(defvar agent-shell-pins-aliases\\_>" nil t)
        (user-error "Cannot find agent-shell-pins-aliases in %s"
                    agent-shell-pins-file))
      (re-search-forward "'")
      (backward-char)                  ; sit on the quote
      (let ((start (point)))
        (forward-sexp)                 ; over the whole quoted list
        (delete-region start (point))
        (insert (agent-shell-pins--format-alist agent-shell-pins-aliases))))
    (save-buffer)))

(defun agent-shell-pins-add (file alias)
  "Pin FILE under ALIAS for @ completion in any project.
Takes effect immediately and is persisted to `agent-shell-pins-file'."
  (interactive
   (let* ((f (read-file-name "Pin file: " nil nil t))
          (a (read-string (format "Alias (default @%s): " (file-name-base f))
                          nil nil (file-name-base f))))
     (list f a)))
  (unless (string-match-p "\\`[[:alnum:]/_.-]+\\'" alias)
    (user-error "Alias %S has chars outside [:alnum:]/_.- — @ completion would never match it" alias))
  (let ((path (abbreviate-file-name (expand-file-name file)))
        (existing (assoc alias agent-shell-pins-aliases)))
    (when (and existing
               (not (y-or-n-p (format "@%s → %s already; repoint to %s? "
                                      alias (cdr existing) path))))
      (user-error "Aborted"))
    (if existing
        (setcdr existing path)
      (setq agent-shell-pins-aliases
            (append agent-shell-pins-aliases (list (cons alias path)))))
    (agent-shell-pins--save)
    (message "Pinned @%s → %s" alias path)))

(defun agent-shell-pins-remove (alias)
  "Remove pinned ALIAS, live and from `agent-shell-pins-file'."
  (interactive
   (list (completing-read "Unpin: " (mapcar #'car agent-shell-pins-aliases)
                          nil t)))
  (setq agent-shell-pins-aliases
        (assoc-delete-all alias agent-shell-pins-aliases))
  (agent-shell-pins--save)
  (message "Unpinned @%s" alias))

(defun agent-shell-pins--read-from-file ()
  "Return the alist literal currently in `agent-shell-pins-file'."
  (with-temp-buffer
    (insert-file-contents agent-shell-pins-file)
    (goto-char (point-min))
    (re-search-forward "(defvar agent-shell-pins-aliases\\_>")
    (cadr (read (current-buffer)))))   ; (quote ALIST) → ALIST

(defun agent-shell-pins-reload ()
  "Sync live pins from `agent-shell-pins-file' after hand-editing it.
Needed because re-loading a `defvar' never overwrites the live value."
  (interactive)
  (setq agent-shell-pins-aliases (agent-shell-pins--read-from-file))
  (message "agent-shell pins: %d aliases loaded"
           (length agent-shell-pins-aliases)))

(provide 'agent-shell-pins)

;;; agent-shell-pins.el ends here
