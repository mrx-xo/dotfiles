;;; agent-terminal-ux-tests.el --- UX-level tests for agent-terminal -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests the *experience*, not the plumbing: do the commands create the
;; right windows, does hook output render with the right faces/markers,
;; does the buffer tail-follow like a terminal should.
;;
;; Two ways to run (see macos/scripts/agent-terminal-test.sh):
;;   batch (regression, no GUI):
;;     emacs --batch -l lisp/agent-terminal.el -l tests/agent-terminal-ux-tests.el \
;;       --eval '(ert-run-tests-batch-and-exit `(and "^atux-" (not (tag :live))))'
;;   inside the running daemon (windows visibly pop — the demo):
;;     emacsclient --eval '(agent-terminal-ux-run t)'
;;
;; Tests tagged :live need the real session (vterm, tmux) and are skipped
;; in batch.

;;; Code:

(require 'ert)
(require 'agent-terminal)

(defun atux--payload (plist)
  "Base64 JSON payload as agent-terminal-hook.sh would deliver PLIST."
  (base64-encode-string
   (encode-coding-string (json-serialize plist) 'utf-8) t))

(defmacro atux--with-buffer (&rest body)
  "Run BODY against an isolated observer buffer, cleaning up after."
  `(let ((agent-terminal-buffer-name " *atux-observer*")
         (agent-terminal--last-session nil))
     (unwind-protect
         (progn ,@body)
       (when-let ((win (get-buffer-window " *atux-observer*" t)))
         (ignore-errors (delete-window win)))
       (when (get-buffer " *atux-observer*")
         (kill-buffer " *atux-observer*")))))

(defun atux--ingest (phase session command &optional description output)
  (agent-terminal--ingest
   (atux--payload (list :phase phase :session session :cwd "/tmp"
                        :command command :description (or description "")
                        :output (or output "") :interrupted :false))))

;; ── window behavior ────────────────────────────────────────────────────

(ert-deftest atux-observer-toggle-window ()
  "SPC c v: first call pops a bottom side window, second call closes it."
  (atux--with-buffer
   (mr-x/agent-terminal)
   (let ((win (get-buffer-window (agent-terminal--buffer))))
     (should win)
     (should (eq (window-parameter win 'window-side) 'bottom))
     (with-current-buffer (agent-terminal--buffer)
       (should (derived-mode-p 'agent-terminal-mode))
       (should buffer-read-only)))
   (mr-x/agent-terminal)
   (should-not (get-buffer-window (agent-terminal--buffer)))))

(ert-deftest atux-tail-follows-new-output ()
  "A window parked at the end keeps following as output arrives."
  (atux--with-buffer
   (atux--ingest "pre" "sess-tail" "echo one")
   (let ((win (display-buffer (agent-terminal--buffer)
                              '((display-buffer-in-side-window)
                                (side . bottom) (window-height . 0.3)))))
     (set-window-point win (with-current-buffer (agent-terminal--buffer) (point-max)))
     (atux--ingest "post" "sess-tail" "echo one" nil "line-a\nline-b\n")
     (with-current-buffer (agent-terminal--buffer)
       (should (= (window-point win) (point-max)))))))

(ert-deftest atux-scrollback-not-yanked ()
  "A window scrolled up (reading history) is NOT dragged to the bottom."
  (atux--with-buffer
   (atux--ingest "pre" "sess-scroll" "echo one")
   (atux--ingest "post" "sess-scroll" "echo one" nil "old output\n")
   (let ((win (display-buffer (agent-terminal--buffer)
                              '((display-buffer-in-side-window)
                                (side . bottom) (window-height . 0.3)))))
     (set-window-point win (with-current-buffer (agent-terminal--buffer) (point-min)))
     (atux--ingest "post" "sess-scroll" "x" nil "new output\n")
     (with-current-buffer (agent-terminal--buffer)
       (should (< (window-point win) (point-max)))))))

;; ── rendering: what the user actually sees ─────────────────────────────

(ert-deftest atux-prompt-line-rendering ()
  "Commands render as ❯ lines with prompt/command/annotation faces."
  (atux--with-buffer
   (atux--ingest "pre" "abcd1234-ffff" "git status" "Show working tree status")
   (with-current-buffer (agent-terminal--buffer)
     (let ((text (buffer-string)))
       ;; visible structure
       (should (string-match-p "❯ git status" text))
       (should (string-match-p "# Show working tree status" text))
       (should (string-match-p "── abcd1234" text))  ; session separator
       ;; faces: ❯ is the prompt face, command is the command face
       (goto-char (point-min))
       (search-forward "❯")
       (should (eq (get-text-property (match-beginning 0) 'face)
                   'agent-terminal-prompt-face))
       (search-forward "git status")
       (should (eq (get-text-property (match-beginning 0) 'face)
                   'agent-terminal-command-face))))))

(ert-deftest atux-interleaved-session-attribution ()
  "Output from a different session gets a ↳ attribution marker."
  (atux--with-buffer
   (atux--ingest "pre" "session-aaaa" "echo a")
   (atux--ingest "post" "session-bbbb" "echo b" nil "b-output\n")
   (with-current-buffer (agent-terminal--buffer)
     (should (string-match-p "↳ session-" (buffer-string))))))

(ert-deftest atux-truncation-marker ()
  "Oversized output is capped with a visible truncation marker."
  (atux--with-buffer
   (let ((agent-terminal-max-output-lines 200))
     (atux--ingest "post" "sess-trunc" "yes"
                   nil (mapconcat #'number-to-string (number-sequence 1 300) "\n"))
     (with-current-buffer (agent-terminal--buffer)
       (should (string-match-p "\\[… 10[01] lines truncated\\]" (buffer-string)))
       ;; line 250 must NOT have made it in
       (should-not (string-match-p "^250$" (buffer-string)))))))

(ert-deftest atux-ansi-colors-applied ()
  "ANSI escapes in output become real faces, not literal garbage."
  (atux--with-buffer
   (atux--ingest "post" "sess-ansi" "ls" nil "\e[31mredword\e[0m plain\n")
   (with-current-buffer (agent-terminal--buffer)
     (let ((text (buffer-string)))
       ;; escape bytes gone from visible text
       (should-not (string-match-p "\e\\[" text))
       (should (string-match-p "redword" text)))
     (goto-char (point-min))
     (search-forward "redword")
     ;; ansi-color left a face on the colored word
     (should (get-text-property (match-beginning 0) 'face)))))

(ert-deftest atux-interrupted-marker ()
  "Interrupted commands show a visible [interrupted] marker in error face."
  (atux--with-buffer
   (agent-terminal--ingest
    (atux--payload '(:phase "post" :session "sess-int" :cwd "/tmp"
                     :command "sleep 99" :description ""
                     :output "partial\n" :interrupted t)))
   (with-current-buffer (agent-terminal--buffer)
     (goto-char (point-min))
     (should (search-forward "[interrupted]" nil t))
     (should (eq (get-text-property (match-beginning 0) 'face)
                 'agent-terminal-error-face)))))

;; ── toggles ────────────────────────────────────────────────────────────

(ert-deftest atux-tmux-toggle-flag ()
  "C-u SPC c V: toggling flips the flag file and reports state."
  (let* ((flag (make-temp-file "atux-flag-"))
         (agent-terminal-tmux-flag-file flag))
    (delete-file flag)                       ; start OFF
    (unwind-protect
        (progn
          (mr-x/agent-tmux-toggle)
          (should (file-exists-p flag))
          (should (agent-terminal-tmux-enabled-p))
          (mr-x/agent-tmux-toggle)
          (should-not (file-exists-p flag))
          (should-not (agent-terminal-tmux-enabled-p)))
      (ignore-errors (delete-file flag)))))

;; ── live-session-only (vterm + tmux) ───────────────────────────────────

(ert-deftest atux-attach-vterm-live ()
  "SPC c V: attaches a vterm to the agent tmux session in a side window."
  :tags '(:live)
  (skip-unless (and (display-graphic-p) (executable-find "tmux")))
  (unwind-protect
      (progn
        (mr-x/agent-terminal-attach)
        (sit-for 1)                          ; vterm spawn
        (let ((buf (get-buffer "*agent-tmux*")))
          (should buf)
          (with-current-buffer buf
            (should (derived-mode-p 'vterm-mode)))
          (should (get-buffer-window buf)))
        ;; second call closes the window (buffer survives)
        (mr-x/agent-terminal-attach)
        (should-not (get-buffer-window (get-buffer "*agent-tmux*"))))
    (when-let ((buf (get-buffer "*agent-tmux*")))
      (let ((kill-buffer-query-functions nil))
        (kill-buffer buf)))))

;; ── runner for emacsclient (drive the live daemon, watch it happen) ────

(defun agent-terminal-ux-run (&optional include-live)
  "Run the atux- suite; return a summary string.
With INCLUDE-LIVE, also run :live tests (vterm attach — windows will
visibly pop). Failure details land in *Messages*."
  (let* ((selector (if include-live "^atux-" '(and "^atux-" (not (tag :live)))))
         (stats (ert-run-tests-batch selector))
         (total (ert-stats-total stats))
         (bad (ert-stats-completed-unexpected stats)))
    (format "%d/%d passed%s" (- total bad) total
            (if (> bad 0) " — FAILURES (see *Messages*)" ""))))

(provide 'agent-terminal-ux-tests)
;;; agent-terminal-ux-tests.el ends here
