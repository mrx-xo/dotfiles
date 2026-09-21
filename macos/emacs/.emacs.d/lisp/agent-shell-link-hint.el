;;; agent-shell-link-hint.el --- Hint rendered agent links -*- lexical-binding: t; -*-

(require 'link-hint)

(declare-function agent-shell-markdown--open-link "agent-shell-markdown" (url))
(declare-function mr-x/markdown-mermaid-pop-out nil (source))

(defun mr-x/agent-shell-mermaid--legacy-source-at-label (pos)
  "Recover Mermaid source at an older rendered code label at POS."
  (when (and (keymapp (get-text-property pos 'keymap))
             (equal (get-text-property pos 'agent-shell-markdown-source) ""))
    (let ((limit (save-excursion
                   (goto-char pos)
                   (forward-line 4)
                   (point))))
      (when-let* ((body-start
                   (text-property-any
                    pos limit 'agent-shell-markdown-source-block-body t))
                  (fenced-source
                   (get-text-property body-start 'agent-shell-markdown-source))
                  ((stringp fenced-source))
                  ((let ((case-fold-search t))
                     (string-match-p
                      "\\`[[:blank:]]*```+[[:blank:]]*mermaid[[:blank:]]*\n"
                      fenced-source)))
                  (body-end
                   (next-single-property-change
                    body-start 'agent-shell-markdown-source-block-body
                    nil (point-max))))
        (buffer-substring-no-properties body-start body-end)))))

(defun mr-x/agent-shell-mermaid-hint-at-point (&optional pos)
  "Return Mermaid source attached to the rendered label at POS or point."
  (setq pos (or pos (point)))
  (or (get-text-property pos 'mr-x/agent-shell-mermaid-source)
      (mr-x/agent-shell-mermaid--legacy-source-at-label pos)))

(defun mr-x/agent-shell-mermaid-hint-next (bound)
  "Find the next rendered Mermaid label after point and before BOUND."
  (let ((pos (point)))
    (catch 'found
      (while (< (setq pos
                      (min
                       (next-single-property-change
                        pos 'mr-x/agent-shell-mermaid-source nil bound)
                       (next-single-property-change pos 'keymap nil bound)))
                bound)
        (when (mr-x/agent-shell-mermaid-hint-at-point pos)
          (throw 'found pos))))))

(link-hint-define-type 'agent-shell-mermaid
  :next #'mr-x/agent-shell-mermaid-hint-next
  :at-point-p #'mr-x/agent-shell-mermaid-hint-at-point
  :vars '(agent-shell-mode)
  :open #'mr-x/markdown-mermaid-pop-out
  :copy #'kill-new)

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
(add-to-list 'link-hint-types 'link-hint-agent-shell-mermaid)

(provide 'agent-shell-link-hint)
;;; agent-shell-link-hint.el ends here
