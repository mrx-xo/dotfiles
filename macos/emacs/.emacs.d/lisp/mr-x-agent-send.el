;;; mr-x-agent-send.el --- Send content to agent-shell conversations -*- lexical-binding: t; -*-

;;; Commentary:
;; Commands for routing content (region, files, screenshots) into
;; agent-shell conversations.  Extracted from major-pane.el: sending
;; is content routing, not pane management.  The pane is involved in
;; exactly two places: `major-pane-pick-buffer' provides the labeled
;; picker UI, and `major-pane-goto-conversation' focuses a
;; conversation wherever it lives (pane tab or ejected main window).
;;
;; Everything here is prefixed `mr-x/agent-send-' — custom code, not
;; upstream agent-shell (which has its own `agent-shell-send-region'
;; with different, project-scoped targeting).
;;
;; When the target conversation is busy (mid-response), sends follow
;; upstream `agent-shell-send-region' semantics: the queue prompt
;; opens prefilled with the context so the request is queued for when
;; the current response finishes, instead of dumping text into the
;; input area of a running conversation.
;;
;; NOTE: loaded from agent-shell-config.el, so this file must NOT
;; hard-require agent-shell (Elpaca hasn't activated packages yet in
;; batch mode).  major-pane has no such restriction.

;;; Code:

(require 'major-pane)

(declare-function agent-shell-insert "agent-shell")
(declare-function agent-shell-cwd "agent-shell")
(declare-function agent-shell-prompt-queue "agent-shell")
(declare-function agent-shell--prompt-queue-read "agent-shell")
(declare-function agent-shell--get-region-context "agent-shell")
(declare-function agent-shell--get-files-context "agent-shell")
(declare-function agent-shell--buffer-files "agent-shell")
(declare-function agent-shell--project-files "agent-shell")
(declare-function agent-shell--capture-screenshot "agent-shell")
(declare-function agent-shell--dot-subdir "agent-shell")
(declare-function shell-maker-busy "shell-maker")

(defun mr-x/agent-send--insert (buf text)
  "Send TEXT to conversation BUF.
When BUF is idle, insert TEXT into its input area without
submitting, so commentary can be added before sending.  When BUF is
busy, open the queue prompt prefilled with TEXT so the request is
queued behind the in-flight response."
  (if (with-current-buffer buf (shell-maker-busy))
      (with-current-buffer buf
        (agent-shell-prompt-queue
         (agent-shell--prompt-queue-read :initial (concat text "\n\n"))))
    (save-window-excursion
      (agent-shell-insert :text text :shell-buffer buf :no-focus t))))

(defun mr-x/agent-send--region-context (buf)
  "Return the active region's context, with paths relative to BUF's cwd."
  (agent-shell--get-region-context
   :deactivate t
   :agent-cwd (with-current-buffer buf (agent-shell-cwd))))

;;;###autoload
(defun mr-x/agent-send-region ()
  "Send region to a picked agent-shell conversation and go to it."
  (interactive)
  (major-pane-pick-buffer
   (lambda (buf)
     (mr-x/agent-send--insert buf (mr-x/agent-send--region-context buf))
     (major-pane-goto-conversation buf))
   'send-region))

;;;###autoload
(defun mr-x/agent-send-region-no-switch ()
  "Send region to a picked agent-shell conversation without switching."
  (interactive)
  (major-pane-pick-buffer
   (lambda (buf)
     (mr-x/agent-send--insert buf (mr-x/agent-send--region-context buf)))
   'send-region))

;;;###autoload
(defun mr-x/agent-send-file ()
  "Send current file to a picked agent-shell conversation."
  (interactive)
  (let ((files (or (agent-shell--buffer-files)
                   (when (buffer-file-name)
                     (list (buffer-file-name)))
                   (list (completing-read "Send file: "
                                          (agent-shell--project-files)))
                   (user-error "No file to send"))))
    (major-pane-pick-buffer
     (lambda (buf)
       (mr-x/agent-send--insert
        buf (agent-shell--get-files-context :files files)))
     'send-file)))

;;;###autoload
(defun mr-x/agent-send-other-file ()
  "Prompt for a file and send it to a picked agent-shell conversation."
  (interactive)
  (let ((files (list (completing-read "Send file: "
                                      (agent-shell--project-files)))))
    (major-pane-pick-buffer
     (lambda (buf)
       (mr-x/agent-send--insert
        buf (agent-shell--get-files-context :files files)))
     'send-file)))

;;;###autoload
(defun mr-x/agent-send-screenshot ()
  "Capture a screenshot and send it to the active pane conversation.
Sends directly to the active conversation without a picker."
  (interactive)
  (let* ((buf (or (major-pane--find-buffer)
                  (user-error "No agent-shell buffer")))
         (screenshots-dir (agent-shell--dot-subdir "screenshots"))
         (screenshot-path (agent-shell--capture-screenshot
                           :destination-dir screenshots-dir)))
    (mr-x/agent-send--insert
     buf (agent-shell--get-files-context :files (list screenshot-path)))))

;; Old names from when these lived in major-pane.el.
(define-obsolete-function-alias 'major-pane-send-region
  #'mr-x/agent-send-region "2026-07-22")
(define-obsolete-function-alias 'major-pane-send-region-no-switch
  #'mr-x/agent-send-region-no-switch "2026-07-22")
(define-obsolete-function-alias 'major-pane-send-file
  #'mr-x/agent-send-file "2026-07-22")
(define-obsolete-function-alias 'major-pane-send-other-file
  #'mr-x/agent-send-other-file "2026-07-22")
(define-obsolete-function-alias 'major-pane-send-screenshot
  #'mr-x/agent-send-screenshot "2026-07-22")

(provide 'mr-x-agent-send)
;;; mr-x-agent-send.el ends here
