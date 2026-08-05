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
(require 'map)
(require 'seq)

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

(defface agent-terminal-output-face
  '((t :inherit shadow))
  "Base face for command output (ANSI-colored spans keep their colors).
Output recedes; commands pop — that's the hierarchy.")

(defface agent-terminal-ok-face
  '((t :inherit success))
  "Face for the ● status dot on completed commands.")

(defcustom agent-terminal-session-colors
  '("#bd93f9" "#8be9fd" "#50fa7b" "#ffb86c" "#ff79c6" "#f1fa8c")
  "Palette cycled per session id (separator + attribution labels)."
  :type '(repeat string))

(defun agent-terminal--session-face (session)
  "Stable face plist for SESSION, hashed into the palette."
  (list :foreground
        (nth (mod (sxhash-equal (or session ""))
                  (length agent-terminal-session-colors))
             agent-terminal-session-colors)))

(defun agent-terminal--session-label (session cwd)
  "Human label for SESSION: cwd basename, falling back to the short id."
  (let ((base (and cwd (file-name-nondirectory (directory-file-name cwd)))))
    (if (and base (> (length base) 0))
        base
      (agent-terminal--short-session session))))

(defvar agent-terminal--pending (make-hash-table :test #'equal)
  "Session id → `float-time' of its last pre entry, for duration badges.")

(defun agent-terminal--format-duration (secs)
  "Compact human duration for SECS."
  (cond ((< secs 10) (format "%.1fs" secs))
        ((< secs 60) (format "%ds" (round secs)))
        (t (format "%dm%02ds" (floor secs 60) (mod (round secs) 60)))))

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
        ;; Text-property faces, not the default overlays: overlays get
        ;; expensive at 10k lines, and properties survive kill/yank.
        (let ((ansi-color-apply-face-function
               (lambda (beg end face)
                 (when face (put-text-property beg end 'face face)))))
          (ansi-color-apply-on-region start (point-max))))
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
  "Insert a session separator when SESSION differs from the last entry.
Label = cwd basename in the session's palette color, then short id + cwd."
  (unless (equal session agent-terminal--last-session)
    (setq agent-terminal--last-session session)
    (insert (propertize "── " 'face 'agent-terminal-annotation-face)
            (propertize (format "%s · %s"
                                (agent-terminal--session-label session cwd)
                                (agent-terminal--short-session session))
                        'face (agent-terminal--session-face session))
            (propertize (format " ── %s %s\n"
                                (abbreviate-file-name (or cwd ""))
                                (make-string 12 ?─))
                        'face 'agent-terminal-annotation-face))))

(defun agent-terminal--insert-command (session cwd command description)
  "Insert the prompt line for COMMAND (DESCRIPTION as dim comment).
Stamps the line with `at-entry' / `at-session' text properties and
records the start time for the duration badge."
  (agent-terminal--maybe-separator session cwd)
  (puthash session (float-time) agent-terminal--pending)
  (insert "\n")
  (let ((beg (point)))
    (insert (propertize (format "%s " (format-time-string "%H:%M:%S"))
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
    (insert "\n")
    (add-text-properties beg (point)
                         (list 'at-entry 'command 'at-session session))))

(defun agent-terminal--insert-output (session output interrupted)
  "Insert OUTPUT below its command; append a status line.
Output gets the dim base face, a display-only │ gutter (never enters the
kill ring), and `at-entry' 'output stamps so folding/navigation can find
the block.  Status line: ● + duration, or ✗ interrupted."
  (unless (equal session agent-terminal--last-session)
    (setq agent-terminal--last-session session)
    (insert (propertize "↳ " 'face 'agent-terminal-annotation-face)
            (propertize (format "%s:" (agent-terminal--short-session session))
                        'face (agent-terminal--session-face session))
            "\n"))
  (when (> (length output) 0)
    (let ((beg (point)))
      (insert (agent-terminal--truncate-output output))
      (unless (string-suffix-p "\n" output) (insert "\n"))
      (add-face-text-property beg (point) 'agent-terminal-output-face t)
      (add-text-properties
       beg (point)
       (list 'at-entry 'output 'at-session session
             'line-prefix (propertize "  │ " 'face 'agent-terminal-annotation-face)
             'wrap-prefix "  │   "))))
  (let* ((t0 (gethash session agent-terminal--pending))
         (dur (and t0 (agent-terminal--format-duration (- (float-time) t0)))))
    (remhash session agent-terminal--pending)
    (cond
     (interrupted
      (insert "  "
              (propertize (concat "✗ interrupted" (if dur (format " · %s" dur) ""))
                          'face 'agent-terminal-error-face)
              "\n"))
     (dur
      (insert "  "
              (propertize "●" 'face 'agent-terminal-ok-face)
              (propertize (format " %s" dur) 'face 'agent-terminal-annotation-face)
              "\n")))))

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

;;; Reading tools — folding + command navigation (readability pass)

(defun agent-terminal--output-block-at (pos)
  "Return (BEG . END) of the contiguous output block at or after POS.
Looks forward past the current command line if needed; nil when there is
no output block before the next command."
  (save-excursion
    (goto-char pos)
    (unless (eq (get-text-property (point) 'at-entry) 'output)
      ;; walk forward to the next output block, stopping at the next command
      (let ((m (and (require 'text-property-search nil t)
                    (text-property-search-forward 'at-entry 'output t))))
        (when m (goto-char (prop-match-beginning m)))))
    (when (eq (get-text-property (point) 'at-entry) 'output)
      (let ((beg (if (and (> (point) (point-min))
                          (eq (get-text-property (1- (point)) 'at-entry) 'output))
                     (or (previous-single-property-change (point) 'at-entry)
                         (point-min))
                   (point)))
            (end (or (next-single-property-change (point) 'at-entry)
                     (point-max))))
        (cons beg end)))))

(defun agent-terminal-toggle-fold ()
  "Collapse/expand the output block at point to a ▸ N lines stub.
From the command line, folds the output right below it."
  (interactive)
  (if-let ((block (agent-terminal--output-block-at (point))))
      (let* ((beg (car block)) (end (cdr block))
             (ov (seq-find (lambda (o) (overlay-get o 'agent-terminal-fold))
                           (overlays-in beg end))))
        (if ov
            (delete-overlay ov)
          (let ((o (make-overlay beg end)))
            (overlay-put o 'agent-terminal-fold t)
            (overlay-put o 'evaporate t)
            (overlay-put o 'display
                         (propertize
                          (format "  ▸ %d lines folded (TAB)\n"
                                  (count-lines beg end))
                          'face 'agent-terminal-annotation-face)))))
    (message "No output block here")))

(defun agent-terminal-next-command ()
  "Jump to the next ❯ command line."
  (interactive)
  (require 'text-property-search)
  (let ((m (save-excursion
             ;; searching from inside a matching region returns THAT region —
             ;; consume it first so we land on the next one
             (when (eq (get-text-property (point) 'at-entry) 'command)
               (text-property-search-forward 'at-entry 'command t))
             (text-property-search-forward 'at-entry 'command t))))
    (if m (progn (goto-char (prop-match-beginning m)) (beginning-of-line))
      (message "No next command"))))

(defun agent-terminal-previous-command ()
  "Jump to the previous ❯ command line."
  (interactive)
  (require 'text-property-search)
  (let ((m (save-excursion
             ;; tps-backward inspects the char BEFORE point, so only step
             ;; out when we're strictly inside the region (not at its start)
             (when (and (> (point) (point-min))
                        (eq (get-text-property (1- (point)) 'at-entry) 'command))
               (text-property-search-backward 'at-entry 'command t))
             (text-property-search-backward 'at-entry 'command t))))
    (if m (progn (goto-char (prop-match-beginning m)) (beginning-of-line))
      (message "No previous command"))))

(define-key agent-terminal-mode-map (kbd "TAB") #'agent-terminal-toggle-fold)
(define-key agent-terminal-mode-map (kbd "n") #'agent-terminal-next-command)
(define-key agent-terminal-mode-map (kbd "p") #'agent-terminal-previous-command)
(with-eval-after-load 'evil
  (evil-define-key* '(normal motion) agent-terminal-mode-map
    (kbd "TAB") #'agent-terminal-toggle-fold
    "n" #'agent-terminal-next-command
    "p" #'agent-terminal-previous-command))

;;; Phase 2 — tmux interception (docs/agent-terminal-prd.md)

(defcustom agent-terminal-tmux-flag-file
  (expand-file-name "~/.claude/agent-tmux-enabled")
  "Flag file gating the PreToolUse tmux rewrite (agent-tmux-hook.sh)."
  :type 'file)

(defcustom agent-terminal-tmux-session "agent"
  "Name of the tmux session agent commands are routed into."
  :type 'string)

(defun agent-terminal-tmux-enabled-p ()
  "Non-nil when Bash tool calls are being routed into tmux."
  (file-exists-p agent-terminal-tmux-flag-file))

(defun mr-x/agent-tmux-toggle ()
  "Toggle routing of agent Bash commands into the tmux session.
Takes effect on the next tool call — no session restart needed."
  (interactive)
  (if (agent-terminal-tmux-enabled-p)
      (progn
        (delete-file agent-terminal-tmux-flag-file)
        (message "agent-tmux OFF — Bash tool calls run direct again"))
    (with-temp-file agent-terminal-tmux-flag-file)
    (message "agent-tmux ON — Bash tool calls run in tmux session %S (SPC c V to watch)"
             agent-terminal-tmux-session)))

(defun agent-terminal--tmux-buffer ()
  "Return a live *agent-tmux* vterm buffer, creating it (undisplayed) if needed."
  (let ((buf (get-buffer "*agent-tmux*")))
    (unless (buffer-live-p buf)
      (require 'vterm)
      (let ((vterm-shell (format "tmux new-session -A -s %s"
                                 agent-terminal-tmux-session))
            (vterm-buffer-name "*agent-tmux*"))
        (setq buf (save-window-excursion (vterm)))))
    buf))

;;;###autoload
(defun mr-x/agent-terminal-attach (&optional arg)
  "Toggle a vterm attached to the agent tmux session in a side window.
With prefix ARG, toggle the interception itself instead (see
`mr-x/agent-tmux-toggle')."
  (interactive "P")
  (if arg
      (mr-x/agent-tmux-toggle)
    (if-let* ((buf (get-buffer "*agent-tmux*"))
              (win (get-buffer-window buf)))
        (delete-window win)
      (display-buffer (agent-terminal--tmux-buffer)
                      '((display-buffer-in-side-window)
                        (side . bottom)
                        (slot . 1)      ; right of the observer
                        (window-height . 0.35))))))

;;;###autoload
(defun mr-x/agent-terminal-live (&optional pop-frame)
  "Toggle the whole live setup in one gesture: intercept + observer + pane.
ON: routes agent Bash calls into the tmux session and shows the observer
buffer and the live pane side by side — in bottom side windows, or with
prefix POP-FRAME in a dedicated frame (its own OS window, tiled by
yabai).  OFF: stops interception and closes the windows or frame; the
tmux session and its shell keep running, so `mr-x/agent-terminal-attach'
reattaches anytime.
This couples the machine-wide flag to the windows on purpose — the
granular toggles (`mr-x/agent-tmux-toggle', `mr-x/agent-terminal',
`mr-x/agent-terminal-attach') still work independently."
  (interactive "P")
  (if (agent-terminal-tmux-enabled-p)
      (progn
        (delete-file agent-terminal-tmux-flag-file)
        (dolist (name (list agent-terminal-buffer-name "*agent-tmux*"))
          (when-let ((win (get-buffer-window name)))
            (ignore-errors (delete-window win))))
        (dolist (frame (frame-list))
          (when (frame-parameter frame 'agent-terminal-live)
            (ignore-errors (delete-frame frame))))
        (message "agent-terminal live OFF — commands run direct; tmux session %S still alive"
                 agent-terminal-tmux-session))
    (with-temp-file agent-terminal-tmux-flag-file)
    (if pop-frame
        ;; A fresh frame on this daemon is born already split — persp/popper
        ;; hooks fire inside `make-frame', so `frame-root-window' is the
        ;; internal parent (never live) and any leftover window may be a
        ;; protected side window.  Work from a live leaf
        ;; (`frame-selected-window') and bind `ignore-window-parameters' so
        ;; `delete-other-windows' collapses side windows instead of erroring.
        ;; Both buffers are built first: `agent-terminal--tmux-buffer' spins
        ;; up vterm, whose window hooks would kill a split mid-expression.
        (let* ((obs (agent-terminal--buffer))
               (tmux (agent-terminal--tmux-buffer))
               (frame (make-frame '((name . "agent-terminal")
                                    (agent-terminal-live . t))))
               (left (frame-selected-window frame))
               (ignore-window-parameters t))
          (delete-other-windows left)
          (with-current-buffer obs (goto-char (point-max)))
          (set-window-buffer left obs)
          (set-window-point left (with-current-buffer obs (point-max)))
          (set-window-buffer (split-window left nil 'right) tmux)
          (select-frame-set-input-focus frame))
      (unless (get-buffer-window (agent-terminal--buffer))
        (mr-x/agent-terminal))
      (unless (and (get-buffer "*agent-tmux*")
                   (get-buffer-window "*agent-tmux*"))
        (mr-x/agent-terminal-attach)))
    (message "agent-terminal live ON — every agent Bash call runs in tmux session %S"
             agent-terminal-tmux-session)))

;;; Phase 3 — native ACP terminal channel (docs/agent-terminal-prd.md)
;;
;; The claude-agent-acp adapter (0.54.x) has a dormant terminal channel
;; gated on `clientCapabilities._meta.terminal_output'.  When advertised,
;; Bash tool results arrive as content [{type "terminal"}] with the actual
;; output in `_meta.terminal_output.data' and the exit code in
;; `_meta.terminal_exit.exit_code' — which stock agent-shell silently drops
;; (its extractors nil-guard unknown content types).  Two advices fix that:
;; one advertises the capability on initialize, one rewrites terminal
;; updates into the ```console text blocks agent-shell already renders
;; (mirroring the adapter's own no-capability fallback), plus an exit-code
;; badge.  Both are no-ops for sessions started before load and for agents
;; that never emit terminal content.

(defcustom agent-terminal-acp-capability t
  "When non-nil, advertise the ACP terminal_output capability.
Takes effect for agent-shell sessions started after load.  Set to nil and
start a new session to get stock behavior back."
  :type 'boolean)

(defun agent-terminal--acp-add-capability (request)
  "Advertise terminal_output under clientCapabilities._meta in REQUEST.
Filter-return advice for `acp-make-initialize-request'."
  (when agent-terminal-acp-capability
    (condition-case nil
        (when-let* ((params (alist-get :params request))
                    (caps-cell (assq 'clientCapabilities params)))
          (unless (assq '_meta (cdr caps-cell))
            (setcdr caps-cell (cons '(_meta . ((terminal_output . t)))
                                    (cdr caps-cell)))))
      (error nil)))
  request)

(defun agent-terminal--acp-console-block (data exit-code)
  "Format terminal DATA and EXIT-CODE the way agent-shell renders Bash.
Matches the adapter's own no-capability fallback (```console fence) so the
UX is identical either way, with an exit badge added for failures."
  (let ((fence (when (and data (not (string-empty-p data)))
                 (concat "```console\n" (string-trim-right data) "\n```")))
        (badge (when (and (numberp exit-code) (not (zerop exit-code)))
                 (format "✗ exit %d" exit-code))))
    (string-join (delq nil (list fence badge)) "\n")))

(defun agent-terminal--acp-transform-update (update)
  "Destructively rewrite terminal-channel data in UPDATE (an alist) to text.

Live-probed adapter (0.54.1) lifecycle for one Bash call:
  1. tool_call: content [terminal] + _meta.terminal_info    -> drop placeholder
  2. tool_call_update: content [terminal], no data           -> drop placeholder
  3. tool_call_update: _meta.terminal_output.data, NO content key -> inject block
  4. tool_call_update completed: content [terminal] +
     _meta.terminal_exit + rawOutput                         -> rebuild block + badge

agent-shell's `agent-shell--save-tool-call' drops nil-valued entries
before merging, so writing content nil never clobbers a stored block."
  (let* ((content (map-elt update 'content))
         (meta (map-elt update '_meta))
         (tout (and meta (map-elt meta 'terminal_output)))
         (texit (and meta (map-elt meta 'terminal_exit)))
         (has-terminal (and content
                            (seq-some (lambda (item)
                                        (equal (map-elt item 'type) "terminal"))
                                      content))))
    (when (or has-terminal tout texit)
      (let* ((raw-output (let ((ro (map-elt update 'rawOutput)))
                           (and (stringp ro) ro)))
             (data (or (and tout (map-elt tout 'data)) raw-output))
             (exit-code (and texit (map-elt texit 'exit_code)))
             (kept (and content
                        (seq-remove (lambda (item)
                                      (equal (map-elt item 'type) "terminal"))
                                    content)))
             (text (agent-terminal--acp-console-block data exit-code))
             (block-item (unless (string-empty-p text)
                           `((type . "content")
                             (content . ((type . "text") (text . ,text))))))
             (new-items (append kept (and block-item (list block-item)))))
        (if-let ((cell (assq 'content update)))
            (setcdr cell (and new-items (vconcat new-items)))
          (when new-items
            (nconc update (list (cons 'content (vconcat new-items))))))))))

(defun agent-terminal--acp-transform-notification (args)
  "Filter-args advice for `agent-shell--on-notification'.
Rewrites terminal-flavored tool_call/tool_call_update notifications in
place before agent-shell processes them.  Errors are swallowed — a shim
must never break notification handling."
  (condition-case nil
      (when-let* ((notif (plist-get args :acp-notification))
                  (update (map-nested-elt notif '(params update))))
        (when (member (map-elt update 'sessionUpdate)
                      '("tool_call" "tool_call_update"))
          (agent-terminal--acp-transform-update update)))
    (error nil))
  args)

(with-eval-after-load 'acp
  (advice-add 'acp-make-initialize-request :filter-return
              #'agent-terminal--acp-add-capability))

(with-eval-after-load 'agent-shell
  (advice-add 'agent-shell--on-notification :filter-args
              #'agent-terminal--acp-transform-notification))

;;; Demo tour — launch everything, run real traffic, leave it all open

(defconst agent-terminal--run-script
  (expand-file-name "~/.dotfiles/macos/scripts/agent-term-run.sh")
  "The tmux interception wrapper (Layer 2).")

(defconst agent-terminal--demo-commands
  '(("printf '\\e[1;35m%s\\e[0m\\n' 'agent-terminal demo — this shell is REAL, type in me when done'"
     . "Say hello in the pane")
    ("ls -G ~/.dotfiles/macos/scripts | head -6"
     . "List scripts — colors live in the pane, stripped here")
    ("git -C ~/.dotfiles log --oneline --color=always -4"
     . "Recent commits")
    ("for i in 1 2 3; do printf 'tick %s\\n' $i; sleep 1; done"
     . "Watch the PANE: this runs live there, lands here at the end")
    ("sh -c 'echo oops, this one fails on purpose >&2; exit 3'"
     . "Failures propagate real exit codes"))
  "The demo tour: (command . description) pairs, run in order.")

(defun agent-terminal--demo-ingest (phase cmd desc &optional output)
  "Feed the observer buffer exactly like agent-terminal-hook.sh would."
  (agent-terminal--ingest
   (base64-encode-string
    (encode-coding-string
     (json-serialize (list :phase phase :session "demo-tour-0000" :cwd "~"
                           :command cmd :description desc
                           :output (or output "") :interrupted :false))
     'utf-8)
    t)))

(defun agent-terminal--demo-step (cmds)
  "Run the next demo command through the wrapper; chain until done."
  (if (null cmds)
      (message "demo done — the pane is a live shell (click in, type). SPC c v / SPC c V toggle these windows; C-u SPC c V routes real agent commands here.")
    (let* ((cmd (caar cmds))
           (desc (cdar cmds))
           (b64 (base64-encode-string (encode-coding-string cmd 'utf-8) t))
           (buf (generate-new-buffer " *agent-terminal-demo*")))
      (agent-terminal--demo-ingest "pre" cmd desc)
      (set-process-sentinel
       (start-process "agent-terminal-demo" buf agent-terminal--run-script b64)
       (lambda (proc _event)
         (let ((out (with-current-buffer (process-buffer proc) (buffer-string))))
           (agent-terminal--demo-ingest "post" cmd "" out)
           (kill-buffer (process-buffer proc))
           (run-at-time 1.2 nil #'agent-terminal--demo-step (cdr cmds))))))))

;;;###autoload
(defun agent-terminal-demo ()
  "Launch the whole agent-terminal experience and run a guided tour.

Opens the observer buffer and the live tmux pane side by side at the
bottom, then runs a handful of real commands through the interception
wrapper — you watch them get typed and executed in the pane while the
observer logs them. Everything STAYS OPEN afterwards; the pane is a
real shell you can type into."
  (interactive)
  (unless (file-executable-p agent-terminal--run-script)
    (user-error "Wrapper not found: %s" agent-terminal--run-script))
  ;; observer on the left
  (unless (get-buffer-window (agent-terminal--buffer))
    (mr-x/agent-terminal))
  ;; live pane on the right
  (unless (and (get-buffer "*agent-tmux*")
               (get-buffer-window "*agent-tmux*"))
    (mr-x/agent-terminal-attach))
  ;; give vterm/tmux a beat to attach, then roll the tour
  (run-at-time 1.5 nil #'agent-terminal--demo-step agent-terminal--demo-commands)
  (message "agent-terminal demo rolling — watch the two bottom windows"))

;; Trampoline so M-x agent-terminal-ux-run works in any session: loads the
;; test suite on first call, whose own (interactive) definition replaces
;; this stub, then re-dispatches. No-op if the suite is already loaded.
(unless (fboundp 'agent-terminal-ux-run)
  (defun agent-terminal-ux-run (&optional include-live)
    "Load and run the agent-terminal UX test suite.
With prefix arg INCLUDE-LIVE, also run :live tests (vterm attach)."
    (interactive "P")
    (load (expand-file-name "tests/agent-terminal-ux-tests.el"
                            user-emacs-directory)
          nil t)
    (funcall #'agent-terminal-ux-run include-live)))

(defun agent-terminal-clear ()
  "Wipe the observer buffer."
  (interactive)
  (with-current-buffer (agent-terminal--buffer)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (clrhash agent-terminal--pending)
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
                                 (slot . -1)   ; left of the tmux pane
                                 (window-height . 0.3)))))
      (with-selected-window win
        (goto-char (point-max))))))

(provide 'agent-terminal)
;;; agent-terminal.el ends here
