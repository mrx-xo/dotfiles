;;; agent-shell-link-hint.el --- Hint rendered agent links -*- lexical-binding: t; -*-

(require 'link-hint)

(declare-function agent-shell-markdown--open-link "agent-shell-markdown" (url))

(defun mr-x/agent-shell-link-hint-at-point ()
  "Return the rendered agent link destination at point."
  (get-text-property (point) 'agent-shell-markdown-url))

(defun mr-x/agent-shell-link-hint-next (bound)
  "Find the next rendered agent link after point and before BOUND."
  (let ((pos (point)))
    (catch 'found
      (while (< (setq pos (next-single-property-change
                          pos 'agent-shell-markdown-url nil bound)) bound)
        (when (get-text-property pos 'agent-shell-markdown-url)
          (throw 'found pos))))))

(link-hint-define-type 'agent-shell
  :next #'mr-x/agent-shell-link-hint-next
  :at-point-p #'mr-x/agent-shell-link-hint-at-point
  :vars '(agent-shell-mode)
  :open #'agent-shell-markdown--open-link
  :copy #'kill-new)

(add-to-list 'link-hint-types 'link-hint-agent-shell)

(provide 'agent-shell-link-hint)
;;; agent-shell-link-hint.el ends here
