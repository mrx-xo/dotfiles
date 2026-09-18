;;; agent-shell-refs-test.el --- Tests for agent-shell reference rendering -*- lexical-binding: t; -*-

(require 'comint)
(require 'ert)
(require 'seq)
(require 'subr-x)
(require 'agent-shell-refs)

(ert-deftest agent-shell-refs-single-sent-marker-stays-visible ()
  "One sent ref keeps its `[ref 1]:' marker visible below the pill row."
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
      ;; The pill row ends the tag line and nothing more: no hanging indent.
      (let ((tag-overlay
             (seq-find (lambda (overlay) (overlay-get overlay 'display))
                       (overlays-at (point-min)))))
        (should tag-overlay)
        (should (string-suffix-p "\n" (overlay-get tag-overlay 'display)))
        (should-not (string-suffix-p "\n   " (overlay-get tag-overlay 'display))))
      ;; The marker is not hidden by any of our overlays.
      (should-not
       (seq-some (lambda (overlay) (overlay-get overlay 'invisible))
                 (overlays-at marker-beg))))))

(ert-deftest agent-shell-refs-single-pending-marker-stays-visible ()
  "One queued ref shows the bar above the prompt and leaves its marker in place."
  (with-temp-buffer
    (let ((comint-prompt-regexp "^> ")
          (agent-shell-refs--list
           '((:type quote :text "What it does not do"))))
      (insert "> \n[ref 1]:\n\nhow big would this be?")
      (let ((raw-prompt (buffer-string)))
        (agent-shell-refs--update-input-preview)
        (should (equal raw-prompt (buffer-string)))
        (should (overlayp agent-shell-refs--preview-overlay))
        ;; A zero-width overlay at the prompt line start carrying the bar.
        (should (= 1 (overlay-start agent-shell-refs--preview-overlay)))
        (should (= 1 (overlay-end agent-shell-refs--preview-overlay)))
        (should-not (overlay-get agent-shell-refs--preview-overlay 'display))
        (should (string-suffix-p
                 "\n"
                 (overlay-get agent-shell-refs--preview-overlay 'before-string)))))))

(ert-deftest agent-shell-refs-insert-marker-refreshes-preview ()
  "Inserting the first marker refreshes the bar without swallowing the marker."
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
          (should (= 1 (overlay-start agent-shell-refs--preview-overlay)))
          (should (= 1 (overlay-end agent-shell-refs--preview-overlay))))))))

;;; --- Hue per ref ---

(defun agent-shell-refs-test--fg (s)
  "Foreground the `face' property of string S resolves to at its first char."
  (let ((face (get-text-property 0 'face s)))
    (cond ((and (listp face) (plist-member face :foreground))
           (plist-get face :foreground))
          ((listp face)
           (seq-some (lambda (f) (and (listp f) (plist-get f :foreground))) face))
          (t (face-foreground face nil t)))))

(ert-deftest agent-shell-refs-hue-cycles-by-index ()
  "Ref N takes hue N in capture order and wraps past the palette."
  (let ((agent-shell-refs-hues '("#111111" "#222222")))
    (should (equal "#111111" (agent-shell-refs--hue 1)))
    (should (equal "#222222" (agent-shell-refs--hue 2)))
    (should (equal "#111111" (agent-shell-refs--hue 3)))))

(ert-deftest agent-shell-refs-marker-display-is-hued-icon-without-number ()
  "A reply marker shows only an icon in its ref's hue, no digit."
  (let ((agent-shell-refs-hues '("#abcdef" "#123456")))
    (with-temp-buffer
      (setq agent-shell-refs--list '("second" "first"))
      (let ((d1 (agent-shell-refs--marker-display 1))
            (d2 (agent-shell-refs--marker-display 2)))
        (should-not (string-match-p "[0-9]" d1))
        (should (string-match-p "\\` .* \\'" d1))
        (should (equal "#abcdef" (agent-shell-refs-test--fg d1)))
        (should (equal "#123456" (agent-shell-refs-test--fg d2)))))))

(ert-deftest agent-shell-refs-preview-chip-keeps-number-and-takes-hue ()
  "A queued chip keeps its `N ·' prefix but is coloured by index."
  (let ((agent-shell-refs-hues '("#abcdef" "#123456")))
    (let ((c2 (agent-shell-refs--preview-chip "hello" 2)))
      (should (string-match-p "2 · hello" c2))
      (should (equal "#123456" (agent-shell-refs-test--fg c2))))))

(ert-deftest agent-shell-refs-sent-pill-takes-hue-from-its-number ()
  "A folded sent pill parses its `N ·' prefix and colours itself by N."
  (let ((agent-shell-refs-hues '("#abcdef" "#123456")))
    (with-temp-buffer
      (insert "x")
      (let* ((ov (make-overlay 1 2))
             (p (agent-shell-refs--pill "2 · hello" ov)))
        (should (equal "#123456" (agent-shell-refs-test--fg p)))))))

(provide 'agent-shell-refs-test)
;;; agent-shell-refs-test.el ends here
