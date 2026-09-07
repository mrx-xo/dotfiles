;;; agent-shell-refs-test.el --- Tests for agent-shell reference rendering -*- lexical-binding: t; -*-

(require 'comint)
(require 'ert)
(require 'seq)
(require 'subr-x)
(require 'agent-shell-refs)

(ert-deftest agent-shell-refs-leading-reply-marker-folds-into-pill ()
  "A leading reply marker becomes the attachment pill without changing payload text."
  (with-temp-buffer
    (insert (concat "<referenced-context>\n"
                    "Ref 1:\n"
                    "> What it does not do\n"
                    "</referenced-context>\n\n"
                    "\n[ref 1]:\n\n"
                    "how big would this be?"))
    (let ((raw-prompt (buffer-string))
          marker-beg)
      (goto-char (point-min))
      (search-forward "[ref 1]")
      (setq marker-beg (match-beginning 0))
      (should (agent-shell-refs--pillify-block-at (point-min)))
      ;; Overlay-only rendering must not alter what shell-maker sends.
      (should (equal raw-prompt (buffer-string)))
      ;; The pill row supplies the only visible newline and prompt indent.
      (let ((tag-overlay
             (seq-find (lambda (overlay) (overlay-get overlay 'display))
                       (overlays-at (point-min)))))
        (should tag-overlay)
        (should (string-suffix-p "\n   "
                                 (overlay-get tag-overlay 'display))))
      ;; The literal marker remains in the payload but disappears visually.
      (should
       (seq-some
        (lambda (overlay)
          (and (overlay-get overlay 'agent-shell-refs-coalesced-marker)
               (eq (overlay-get overlay 'invisible) 'agent-shell-refs)))
        (overlays-at marker-beg))))))

(ert-deftest agent-shell-refs-pending-leading-marker-renders-as-pill-prefix ()
  "The pending prompt combines its preview and leading marker without changing text."
  (with-temp-buffer
    (let ((comint-prompt-regexp "^> ")
          (agent-shell-refs--list
           '((:type quote :text "What it does not do"))))
      (insert "> \n[ref 1]:\n\nhow big would this be?")
      (let ((raw-prompt (buffer-string))
            (prompt-end 3))
        (agent-shell-refs--update-input-preview)
        (should (equal raw-prompt (buffer-string)))
        (should (overlayp agent-shell-refs--preview-overlay))
        ;; The display replaces the marker prefix immediately after the
        ;; prompt, rather than adding a detached bar above the input line.
        (should (= prompt-end
                   (overlay-start agent-shell-refs--preview-overlay)))
        (should (> (overlay-end agent-shell-refs--preview-overlay)
                   (overlay-start agent-shell-refs--preview-overlay)))
        (should
         (string-suffix-p
          "\n   "
          (overlay-get agent-shell-refs--preview-overlay 'display)))))))

(ert-deftest agent-shell-refs-insert-marker-refreshes-merged-preview ()
  "Inserting the first marker immediately activates the merged pending preview."
  (with-temp-buffer
    (let ((buf (current-buffer))
          (comint-prompt-regexp "^> ")
          (agent-shell-refs--list
           '((:type quote :text "What it does not do"))))
      (insert "> ")
      (cl-letf (((symbol-function 'agent-shell-refs--find-shell-buffer)
                 (lambda () buf)))
        (save-window-excursion
          (switch-to-buffer buf)
          (agent-shell-refs-insert-marker 1)
          (should (equal "> \n[ref 1]:\n\n" (buffer-string)))
          (should (overlayp agent-shell-refs--preview-overlay))
          (should (= 3 (overlay-start agent-shell-refs--preview-overlay)))
          (should (> (overlay-end agent-shell-refs--preview-overlay)
                     (overlay-start agent-shell-refs--preview-overlay))))))))

(provide 'agent-shell-refs-test)
;;; agent-shell-refs-test.el ends here
