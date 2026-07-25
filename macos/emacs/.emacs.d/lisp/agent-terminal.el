;;; agent-terminal.el --- Observer buffer for agent Bash commands -*- lexical-binding: t; -*-

;; Author: Marcos Andrade
;; Keywords: tools, processes

;;; Commentary:

;; Phase 1 of the Agent Terminal PRD (docs/agent-terminal-prd.md): a
;; read-only, terminal-styled buffer showing every Bash command any
;; Claude Code session on this machine runs, live-ish.  Fed by
;; PreToolUse/PostToolUse hooks in ~/.claude/settings.json via
;; macos/scripts/agent-terminal-hook.sh, which delivers a base64'd JSON
;; payload to `agent-terminal--ingest' through emacsclient.
;;
;; Loaded from the agent-shell section of emacs.org (tangles to
;; agent-shell-config.el).  Deliberately does NOT require agent-shell —
;; it works for CLI sessions too, and hard-requiring agent-shell breaks
;; batch tangle (house rule).

;;; Code:

(require 'ansi-color)

(defgroup agent-terminal nil
  "Observer buffer for agent Bash commands."
  :group 'tools)

(defcustom agent-terminal-buffer-name "*agent-terminal*"
  "Name of the observer buffer."
  :type 'string)

(defcustom agent-terminal-max-output-lines 200
  "Max lines of one command's output to insert before truncating."
  :type 'natnum)

(defcustom agent-terminal-max-output-chars 16384
  "Max characters of one command's output to insert before truncating."
  :type 'natnum)

(defcustom agent-terminal-max-buffer-lines 10000
  "Total buffer line cap; oldest lines are deleted past this (ring behavior)."
  :type 'natnum)

(defface agent-terminal-prompt-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for the ❯ prompt marker.")

(defface agent-terminal-command-face
  '((t :inherit font-lock-string-face))
  "Face for the command text.")

(defface agent-terminal-annotation-face
  '((t :inherit font-lock-comment-face))
  "Face for timestamps, descriptions, and session markers.")

(defface agent-terminal-error-face
  '((t :inherit error))
  "Face for interruption/error markers.")

(defvar agent-terminal--last-session nil
  "Session id of the most recently printed entry, for separators.")

(define-derived-mode agent-terminal-mode special-mode "AgentTerm"
  "Major mode for the read-only agent terminal observer buffer."
  (setq-local truncate-lines nil)
  (setq-local window-point-insertion-type t)
  (buffer-disable-undo))

(defun agent-terminal--buffer ()
  "Return the observer buffer, creating and initializing it if needed."
  (let ((buf (get-buffer-create agent-terminal-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'agent-terminal-mode)
        (agent-terminal-mode)))
    buf))

(defun agent-terminal--short-session (session)
  "First 8 chars of SESSION id, or \"?\" when empty."
  (if (and session (> (length session) 0))
      (substring session 0 (min 8 (length session)))
    "?"))

(defun agent-terminal--truncate-output (output)
  "Cap OUTPUT at `agent-terminal-max-output-lines'/`-chars' with a marker."
  (let ((truncated nil))
    (when (> (length output) agent-terminal-max-output-chars)
      (setq output (substring output 0 agent-terminal-max-output-chars)
            truncated t))
    (let ((lines (split-string output "\n")))
      (when (> (length lines) agent-terminal-max-output-lines)
        (setq output (string-join
                      (seq-take lines agent-terminal-max-output-lines) "\n")
              truncated (- (length lines) agent-terminal-max-output-lines))))
    (if truncated
        (concat output
                (propertize (if (numberp truncated)
                                (format "\n[… %d lines truncated]" truncated)
                              "\n[… output truncated]")
                            'face 'agent-terminal-annotation-face))
      output)))

(defun agent-terminal--append (insert-fn)
  "Append via INSERT-FN at the tail of the observer buffer.
Applies ANSI colors to the inserted region, trims the buffer ring, and
keeps point following the tail unless the user has scrolled up."
  (with-current-buffer (agent-terminal--buffer)
    (let* ((inhibit-read-only t)
           (follow (>= (point) (point-max)))
           (start (point-max)))
      (save-excursion
        (goto-char (point-max))
        (funcall insert-fn)
        (ansi-color-apply-on-region start (point-max)))
      ;; Ring: drop oldest lines past the cap.
      (save-excursion
        (goto-char (point-max))
        (let ((over (- (line-number-at-pos) agent-terminal-max-buffer-lines)))
          (when (> over 0)
            (goto-char (point-min))
            (forward-line over)
            (delete-region (point-min) (point)))))
      (when follow
        (goto-char (point-max))
        ;; window-point-insertion-type keeps displayed windows tailing;
        ;; this catches windows whose point drifted behind.
        (dolist (win (get-buffer-window-list (current-buffer) nil t))
          (when (>= (window-point win) start)
            (set-window-point win (point-max))))))))

(defun agent-terminal--maybe-separator (session cwd)
  "Insert a dim session separator when SESSION differs from the last entry.
CWD is shown alongside the short session id."
  (unless (equal session agent-terminal--last-session)
    (setq agent-terminal--last-session session)
    (insert (propertize
             (format "── %s · %s %s\n"
                     (agent-terminal--short-session session)
                     (abbreviate-file-name (or cwd ""))
                     (make-string 20 ?─))
             'face 'agent-terminal-annotation-face))))

(defun agent-terminal--insert-command (session cwd command description)
  "Insert the prompt line for COMMAND (DESCRIPTION as dim comment)."
  (agent-terminal--maybe-separator session cwd)
  (insert (propertize (format "\n[%s] " (format-time-string "%H:%M:%S"))
                      'face 'agent-terminal-annotation-face))
  (insert (propertize "❯ " 'face 'agent-terminal-prompt-face))
  (let ((multiline (string-search "\n" command)))
    (if multiline
        (progn
          (when (> (length description) 0)
            (insert (propertize (format "# %s" description)
                                'face 'agent-terminal-annotation-face)
                    "\n  "))
          (insert (propertize
                   (string-replace "\n" "\n  " command)
                   'face 'agent-terminal-command-face)))
      (insert (propertize command 'face 'agent-terminal-command-face))
      (when (> (length description) 0)
        (insert (propertize (format "    # %s" description)
                            'face 'agent-terminal-annotation-face)))))
  (insert "\n"))

(defun agent-terminal--insert-output (session output interrupted)
  "Insert OUTPUT below its command; mark INTERRUPTED commands.
When SESSION isn't the last printed one (interleaved sessions), prefix a
marker attributing the output."
  (unless (equal session agent-terminal--last-session)
    (setq agent-terminal--last-session session)
    (insert (propertize (format "↳ %s:\n" (agent-terminal--short-session session))
                        'face 'agent-terminal-annotation-face)))
  (when (> (length output) 0)
    (insert (agent-terminal--truncate-output output))
    (unless (string-suffix-p "\n" output) (insert "\n")))
  (when interrupted
    (insert (propertize "[interrupted]\n" 'face 'agent-terminal-error-face))))

(defun agent-terminal--ingest (b64)
  "Entry point for agent-terminal-hook.sh.
B64 is base64'd JSON: {phase, session, cwd, command, description,
output, interrupted}.  Errors are swallowed — a malformed payload must
never surface as a user-visible error from a hook."
  (condition-case nil
      (let* ((msg (json-parse-string
                   (decode-coding-string (base64-decode-string b64) 'utf-8)
                   :object-type 'plist :null-object nil :false-object nil))
             (session (plist-get msg :session))
             (cwd (plist-get msg :cwd)))
        (if (equal (plist-get msg :phase) "pre")
            (agent-terminal--append
             (lambda ()
               (agent-terminal--insert-command
                session cwd
                (or (plist-get msg :command) "")
                (or (plist-get msg :description) ""))))
          (agent-terminal--append
           (lambda ()
             (agent-terminal--insert-output
              session
              (or (plist-get msg :output) "")
              (plist-get msg :interrupted)))))
        t)
    (error nil)))

(defun agent-terminal-clear ()
  "Wipe the observer buffer."
  (interactive)
  (with-current-buffer (agent-terminal--buffer)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (setq agent-terminal--last-session nil))))

;;;###autoload
(defun mr-x/agent-terminal ()
  "Toggle the agent terminal observer buffer in a bottom side window."
  (interactive)
  (if-let ((win (get-buffer-window (agent-terminal--buffer))))
      (delete-window win)
    (let ((win (display-buffer (agent-terminal--buffer)
                               '((display-buffer-in-side-window)
                                 (side . bottom)
                                 (window-height . 0.3)))))
      (with-selected-window win
        (goto-char (point-max))))))

(provide 'agent-terminal)
;;; agent-terminal.el ends here
