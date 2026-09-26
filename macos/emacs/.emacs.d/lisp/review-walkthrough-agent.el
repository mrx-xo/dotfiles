;;; review-walkthrough-agent.el --- Ask the project agent for a walkthrough -*- lexical-binding: t; -*-
;;; Commentary:
;; Glue, not core: the per-project Quick Ask agent reads the diff and
;; replies in chat with a fenced json block holding the route.  Emacs
;; extracts and validates it itself, so the hidden agent never needs tool
;; permissions.  Also gives Quick Ask the current step as context.
;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'review-walkthrough)

(declare-function mr-x/quick-ask--ensure-session "agent-shell-config")
(declare-function agent-shell-subscribe-to "agent-shell")
(declare-function agent-shell-unsubscribe "agent-shell")
(declare-function agent-shell--insert-to-shell-buffer "agent-shell")
(declare-function shell-maker-busy "shell-maker")
(declare-function shell-maker-last-output "shell-maker")
(defvar mr-x/quick-ask-context-functions)

(defcustom review-walkthrough-agent-instructions "~/agent-instructions/walkthrough.md"
  "The walkthrough prompt sent ahead of the diff."
  :type 'file :group 'review)

(defcustom review-walkthrough-agent-diff-budget 60000
  "Characters of diff sent to the agent.  Past it, the largest hunks go by header only."
  :type 'natnum :group 'review)

(defvar review-walkthrough-agent--last-output nil "The agent's last reply to a walkthrough request.")

(defun review-walkthrough-agent--diff (session)
  "SESSION's hunks as text, the largest cut to their header past the budget."
  (let (chunks)
    (cl-loop for file across (review-session-files session)
             do (push (list :text (format "=== %s (%s)" (plist-get file :path) (plist-get file :kind))) chunks)
             (if (not (plist-get file :loaded))
                 (push (list :text "  (text not loaded)") chunks)
               (let ((rows (vconcat (plist-get file :rows))))
                 (dolist (h (plist-get file :hunks))
                   (let ((head (format "@@ -%d,%d +%d,%d @@" (plist-get h :old-start) (plist-get h :old-count)
                                       (plist-get h :new-start) (plist-get h :new-count))))
                     (push (list :head head
                                 :text (concat head "\n"
                                               (or (review-session--selection-diff
                                                    session (append (cl-subseq rows (plist-get h :start)
                                                                               (min (length rows) (1+ (plist-get h :end))))
                                                                    nil))
                                                   "")))
                           chunks))))))
    (setq chunks (nreverse chunks))
    (let ((total (lambda () (apply #'+ (mapcar (lambda (c) (length (plist-get c :text))) chunks))))
          (done nil))
      ;; Stop with a local flag, not by clobbering the defcustom: every
      ;; hunk chunk may already be cut to its header while the total is
      ;; still over budget (headers plus "not loaded" notices alone can
      ;; exceed a very small budget), and that must not permanently
      ;; disable the budget for later calls.
      (while (and (not done) (> (funcall total) review-walkthrough-agent-diff-budget))
        (let ((big (car (sort (seq-filter (lambda (c) (and (plist-get c :head)
                                                            (not (plist-get c :cut))))
                                          chunks)
                              (lambda (a b) (> (length (plist-get a :text)) (length (plist-get b :text))))))))
          (if (not big) (setq done t)
            (plist-put big :text (concat (plist-get big :head) "  (hunk body omitted; read the file)"))
            (plist-put big :cut t)))))
    (mapconcat (lambda (c) (plist-get c :text)) chunks "\n")))

(defun review-walkthrough-agent--prompt (session)
  "The request for SESSION's walkthrough; the agent replies with a json block."
  (let* ((instructions (expand-file-name review-walkthrough-agent-instructions))
         (recipe (review-source-recipe (review-session-source session))))
    (concat
     (if (file-readable-p instructions)
         (with-temp-buffer (insert-file-contents instructions) (buffer-string))
       "Walk me through this change like a senior engineer reviewing it.")
     "\n\n## Deliver it as a walkthrough in my Emacs review viewer\n\n"
     "You may read files in this repository to understand the change, but do not edit any file "
     "and do not run any command.\n"
     "Build a route of 3 to 10 steps in execution order. Reply with exactly one fenced block "
     "tagged json, holding the route, and nothing outside that block that matters:\n\n"
     "```json\n{\"steps\": [{\"path\": \"repo/relative/path\", \"side\": \"new\", \"line_start\": 12, "
     "\"line_end\": 18, \"title\": \"short title\", \"body\": \"1-3 sentences\", "
     "\"question\": \"one review question\"}]}\n```\n\n"
     "side is \"new\" unless the lines exist only on the old side. Line numbers are that side's real file "
     "lines, and each step must include at least one changed line from the hunks below.\n"
     (format "Review: %s\n\n" (review-source-key recipe))
     "## The diff\n\n"
     (review-walkthrough-agent--diff session))))

(defun review-walkthrough-agent--route-json (text)
  "The contents of the last ```json fenced block in TEXT, or nil.
The closing fence must sit right after a newline of its own: JSON strings
cannot contain a raw newline, so a ``` directly after one inside the block
can only be the real fence, never one quoted inside a step's title, body,
or question.  (Emacs regexps only treat ^ as an anchor at the start of the
pattern or right after \\( or \\|, so this matches the newline literally
instead of relying on ^ mid-pattern.)"
  (when text
    (let ((start 0) last)
      (while (string-match "```json\n\\(\\(?:.\\|\n\\)*?\\)\n```" text start)
        (setq last (match-string 1 text))
        (setq start (match-end 0)))
      last)))

(defun review-walkthrough-agent--apply-route (session shell json-text retries corrected)
  "Start SESSION's walkthrough from JSON-TEXT.
RETRIES counts `retry:' attempts already made against this route.
CORRECTED is non-nil once SHELL has already been asked once to fix a
rejected route; a second rejection then gives up rather than asking again.
A signal out of `review-walkthrough-start-file' is a bug, not a bad route
from the agent, so it never triggers a correction round-trip: it just
reports the failure and gives up."
  (when (eq session review-session--current)
    (let* ((file (make-temp-file "review-walkthrough" nil ".json" json-text))
           (result (unwind-protect
                       (condition-case err
                           (review-walkthrough-start-file file)
                         (error (cons :internal-error (error-message-string err))))
                     (delete-file file))))
      (if (and (consp result) (eq (car result) :internal-error))
          (let ((description (cdr result)))
            (setq review-walkthrough-agent--last-output
                  (concat review-walkthrough-agent--last-output "\n\n[internal error] " description))
            (message "[internal error] %s" description)
            (setf (review-session-walkthrough session) (list :status 'no-route))
            (review-session--notify session))
        (let ((report result))
          (cond
           ((string-prefix-p "ok" report)
            (when (string-match-p "\n" report) (message "%s" report)))
           ((string-prefix-p "retry:" report)
            (if (< retries 5)
                (run-at-time 3 nil #'review-walkthrough-agent--apply-route
                             session shell json-text (1+ retries) corrected)
              (setq review-walkthrough-agent--last-output
                    (concat review-walkthrough-agent--last-output "\n" report))
              (setf (review-session-walkthrough session) (list :status 'no-route))
              (review-session--notify session)))
           ((string-prefix-p "error:" report)
            (if corrected
                (progn
                  (setf (review-session-walkthrough session) (list :status 'no-route))
                  (review-session--notify session))
              (review-walkthrough-agent--request-correction session shell report)))))))))

(defun review-walkthrough-agent--request-correction (session shell report)
  "Ask SHELL once to fix the walkthrough route rejected with REPORT."
  (let (token)
    (setq token
          (agent-shell-subscribe-to
           :shell-buffer shell :event 'turn-complete
           :on-event (lambda (_event)
                       (agent-shell-unsubscribe :subscription token)
                       (review-walkthrough-agent--on-reply session shell t))))
    (agent-shell--insert-to-shell-buffer
     :shell-buffer shell
     :text (format "Your walkthrough route was rejected:\n%s\nReply again with only the corrected json block."
                    report)
     :submit t :no-focus t)))

(defun review-walkthrough-agent--on-reply (session shell corrected)
  "Handle SHELL's reply to a walkthrough request for SESSION.
CORRECTED is non-nil when this reply follows a correction request."
  (setq review-walkthrough-agent--last-output (with-current-buffer shell (shell-maker-last-output)))
  (when (eq session review-session--current)
    (let ((json-text (review-walkthrough-agent--route-json review-walkthrough-agent--last-output)))
      (if (not json-text)
          (progn
            (setf (review-session-walkthrough session) (list :status 'no-route))
            (review-session--notify session))
        (review-walkthrough-agent--apply-route session shell json-text 0 corrected)))))

(defun review-walkthrough-request ()
  "Ask this project's agent to build a walkthrough of the review."
  (interactive)
  (let* ((session (review-session--require))
         (shell (mr-x/quick-ask--ensure-session (review-session-directory session)))
         token)
    (when (with-current-buffer shell (shell-maker-busy))
      (user-error "The project agent is busy; try again when it finishes"))
    (setf (review-session-walkthrough session) (list :status 'planning))
    (review-session--notify session)
    (setq token
          (agent-shell-subscribe-to
           :shell-buffer shell :event 'turn-complete
           :on-event (lambda (_event)
                       (agent-shell-unsubscribe :subscription token)
                       (review-walkthrough-agent--on-reply session shell nil))))
    (agent-shell--insert-to-shell-buffer
     :shell-buffer shell :text (review-walkthrough-agent--prompt session) :submit t :no-focus t)
    (message "Asked the project agent for a walkthrough")))

(defun review-walkthrough-show-answer ()
  "Show what the agent said instead of sending a route."
  (interactive)
  (with-current-buffer (get-buffer-create "*review walkthrough answer*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (or review-walkthrough-agent--last-output "No answer yet."))
      (special-mode))
    (display-buffer (current-buffer))))

(defun review-walkthrough-agent-dwim ()
  "Request a walkthrough, end the running one, or show why none came back."
  (interactive)
  (let* ((session (review-session--require))
         (w (review-session-walkthrough session)))
    (cond ((plist-get w :steps)
           (when (y-or-n-p "End this walkthrough? ") (review-walkthrough-quit)))
          ((eq (plist-get w :status) 'no-route) (review-walkthrough-show-answer))
          ((eq (plist-get w :status) 'planning)
           (when (y-or-n-p "The agent is still planning. Show its session? ")
             (pop-to-buffer (mr-x/quick-ask--ensure-session (review-session-directory session)))))
          (t (review-walkthrough-request)))))

(defun review-walkthrough-agent--ask-context ()
  "The current walkthrough step as a Quick Ask context item, in review buffers."
  (when-let* ((_ (derived-mode-p 'review-pane-mode 'review-panel-mode))
              (s review-session--current)
              (step (review-walkthrough--step s)))
    (let* ((file (review-session-file s (review-walkthrough--file-index s (plist-get step :path))))
           (rows (vconcat (plist-get file :rows)))
           (hunk (nth (or (review-walkthrough--hunk-of
                           file (review-walkthrough--rows file (plist-get step :side)
                                                          (plist-get step :line-start) (plist-get step :line-end)))
                          0)
                      (plist-get file :hunks))))
      (list :type 'walkthrough
            :label (format "step %d: %s" (1+ (plist-get (review-session-walkthrough s) :index))
                           (plist-get step :title))
            :content (concat (plist-get step :title) "\n" (or (plist-get step :body) "") "\n\n"
                             (or (review-session--selection-diff
                                  s (append (cl-subseq rows (plist-get hunk :start)
                                                       (min (length rows) (1+ (plist-get hunk :end))))
                                            nil))
                                 ""))))))

(with-eval-after-load 'evil
  (dolist (map (list review-pane-mode-map review-panel-mode-map))
    (evil-define-key* 'normal map (kbd "W") #'review-walkthrough-agent-dwim)))
(dolist (map (list review-pane-mode-map review-panel-mode-map))
  (define-key map (kbd "W") #'review-walkthrough-agent-dwim))

(unless (boundp 'mr-x/quick-ask-context-functions) (setq mr-x/quick-ask-context-functions nil))
(add-hook 'mr-x/quick-ask-context-functions #'review-walkthrough-agent--ask-context)

(provide 'review-walkthrough-agent)
;;; review-walkthrough-agent.el ends here
