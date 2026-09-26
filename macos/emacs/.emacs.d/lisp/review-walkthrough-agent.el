;;; review-walkthrough-agent.el --- Ask the project agent for a walkthrough -*- lexical-binding: t; -*-
;;; Commentary:
;; Glue, not core: the per-project Quick Ask agent reads the diff, writes a
;; route as JSON, and sends it back with emacsclient.  Emacs never parses
;; the chat reply.  Also gives Quick Ask the current step as context.
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

(defun review-walkthrough-agent--prompt (session file)
  "The request for SESSION's walkthrough; the agent writes its route to FILE."
  (let* ((instructions (expand-file-name review-walkthrough-agent-instructions))
         (socket (if (and (boundp 'server-name) (not (equal server-name "server")))
                     (format " --socket-name=%s" server-name) ""))
         (recipe (review-source-recipe (review-session-source session))))
    (concat
     (if (file-readable-p instructions)
         (with-temp-buffer (insert-file-contents instructions) (buffer-string))
       "Walk me through this change like a senior engineer reviewing it.")
     "\n\n## Deliver it as a walkthrough in my Emacs review viewer\n\n"
     "Do not answer in chat. Build a route of 3 to 10 steps in execution order, write it as JSON to "
     file ", then run exactly:\n\n"
     (format "emacsclient%s --eval \"(progn (require 'review-walkthrough) (review-walkthrough-start-file \\\"%s\\\"))\"\n\n"
             socket file)
     "JSON shape: {\"steps\": [{\"path\": \"repo/relative/path\", \"side\": \"new\", \"line_start\": 12, "
     "\"line_end\": 18, \"title\": \"short title\", \"body\": \"1-3 sentences\", \"question\": \"one review question\"}]}\n"
     "side is \"new\" unless the lines exist only on the old side. Line numbers are that side's real file "
     "lines, and each step must include at least one changed line from the hunks below.\n"
     "The command prints a report. If it starts with retry:, run it again after 5 seconds. If it lists "
     "rejected steps, fix them in the file and run it again.\n"
     (format "Review: %s\n\n" (review-source-key recipe))
     "## The diff\n\n"
     (review-walkthrough-agent--diff session))))

(defun review-walkthrough-request ()
  "Ask this project's agent to build a walkthrough of the review."
  (interactive)
  (let* ((session (review-session--require))
         (shell (mr-x/quick-ask--ensure-session (review-session-directory session)))
         (file (make-temp-file "review-walkthrough" nil ".json"))
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
                       (setq review-walkthrough-agent--last-output
                             (with-current-buffer shell (shell-maker-last-output)))
                       (when (and (eq session review-session--current)
                                  (not (plist-get (review-session-walkthrough session) :steps)))
                         (setf (review-session-walkthrough session) (list :status 'no-route))
                         (review-session--notify session)))))
    (agent-shell--insert-to-shell-buffer
     :shell-buffer shell :text (review-walkthrough-agent--prompt session file) :submit t :no-focus t)
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
  (let ((w (review-session-walkthrough (review-session--require))))
    (cond ((plist-get w :steps)
           (when (y-or-n-p "End this walkthrough? ") (review-walkthrough-quit)))
          ((eq (plist-get w :status) 'no-route) (review-walkthrough-show-answer))
          ((eq (plist-get w :status) 'planning) (message "The agent is still planning the route"))
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
