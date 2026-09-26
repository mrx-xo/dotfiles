;;; review-panel-test.el --- Files panel rendering -*- lexical-binding: t; -*-
;; The panel follows Figma file FCZk2pGQidWPYfSWzu4qUk, frames
;; "Files panel / expanded (default)" and "Files strip / collapsed".
(require 'ert)
(require 'review-panel)
(require 'review-session-test)

(ert-deftest review-panel-preload-continues-after-async-failure ()
  (review-panel-test--with s
    (let ((text (review-source-text (review-session-source s))))
      (setf (review-source-text (review-session-source s))
            (lambda (file side callback)
              (if (equal (plist-get file :path) "b.el")
                  (run-at-time 0 nil callback nil "access denied")
                (funcall text file side callback))))
      (review-panel-open s)
      (let ((deadline (+ (float-time) 2)))
        (while (and (< (float-time) deadline)
                    (not (plist-get (review-session-file s 1) :error)))
          (accept-process-output nil 0.01)))
      (should (equal (plist-get (review-session-file s 1) :error) "access denied"))
      (should-not (plist-get (review-session-file s 1) :loaded))
      (with-current-buffer (review-session-panel s)
        (should (string-match-p "failed" (buffer-string)))))))

(defmacro review-panel-test--with (var &rest body)
  (declare (indent 1))
  `(save-window-excursion
     (let ((,var (review-session-start (review-session-test--source review-session-test--spec))))
       (unwind-protect (progn ,@body) (review-session-quit)))))

(defun review-panel-test--line (text regexp)
  "The line of TEXT matching REGEXP."
  (seq-find (lambda (l) (string-match-p regexp l)) (split-string text "\n")))

(ert-deftest review-panel-header-shows-number-title-and-subtitle ()
  (review-panel-test--with s
    (let ((text (review-panel-render s nil nil)))
      (should (string-match-p "Fake" text))
      (should (string-match-p "x -> y" text))
      (should-not (string-match-p "#" text)))
    (setf (review-source-number (review-session-source s)) 41
          (review-source-subtitle (review-session-source s)) "team / project   feat -> main")
    (let ((text (review-panel-render s nil nil)))
      (should (string-match-p "#41.*Fake" text))
      (should (string-match-p "team / project   feat -> main" text)))))

(ert-deftest review-panel-progress-shows-viewed-totals-and-hunk-position ()
  (review-panel-test--with s
    (let ((text (review-panel-render s nil nil)))
      (should (string-match-p "0 of 3 viewed.*\\+1  -1" text))
      (should (string-match-p "hunk 1 of 1 in this file.*1 of 1 hunks total" text)))))

(ert-deftest review-panel-marks-viewed-current-and-pending-with-icons ()
  (review-panel-test--with s
    (review-session-next-file)
    (let ((text (review-panel-render s nil nil)))
      (should (string-match-p "●" (review-panel-test--line text "a\\.el")))
      (should (string-match-p "❯" (review-panel-test--line text "b\\.el")))
      (should (string-match-p "○" (review-panel-test--line text "bin\\.dat")))
      (should-not (string-match-p "done\\|pending\\|current" text)))))

(ert-deftest review-panel-viewed-rows-are-faded ()
  (review-panel-test--with s
    (review-session-next-file)
    (let* ((text (review-panel-render s nil nil))
           (line (review-panel-test--line text "a\\.el"))
           (face (get-text-property (string-match "M" line) 'face line)))
      (should (equal (plist-get face :foreground) (review-panel--hex 'yellow t)))
      (should-not (equal (review-panel--hex 'yellow t) (review-panel--hex 'yellow))))))

(ert-deftest review-panel-expands-only-the-current-file-by-default ()
  (review-panel-test--with s
    (review-session-next-file)
    (let ((text (review-panel-render s nil nil)))
      (should (string-match-p "@@ -2,2 \\+2,3 @@" text))
      (should-not (string-match-p "@@ -2,1 \\+2,1 @@" text))
      (should (string-match-p "1 hunk" (review-panel-test--line text "a\\.el")))
      (should (string-match-p "hunk 1/1" (review-panel-test--line text "b\\.el"))))))

(ert-deftest review-panel-toggles-expand-others-and-fold-current ()
  (review-panel-test--with s
    (review-session-next-file)
    (let ((text (review-panel-render s '(0) nil)))
      (should (string-match-p "@@ -2,1 \\+2,1 @@" text))
      (should (string-match-p "@@ -2,2 \\+2,3 @@" text)))
    (let ((text (review-panel-render s '(1) nil)))
      (should-not (string-match-p "@@" text)))))

(ert-deftest review-panel-hunk-rows-mark-done-current-and-pending ()
  (let* ((old (mapconcat (lambda (i) (format "l%d" i)) (number-sequence 1 20) "\n"))
         (new (replace-regexp-in-string
               "^l18$" "L18" (replace-regexp-in-string "^l2$" "L2" old))))
    (save-window-excursion
      (let ((s (review-session-start
                (review-session-test--source `(("two.txt" modified ,old ,new))))))
        (unwind-protect
            (let ((text (review-panel-render s nil nil)))
              (should (string-match-p "❯.*@@ -2,1" text))
              (should (string-match-p "○.*@@ -18,1" text))
              (review-session-next-hunk)
              (setq text (review-panel-render s nil nil))
              (should (string-match-p "●.*@@ -2,1" text))
              (should (string-match-p "❯.*@@ -18,1" text)))
          (review-session-quit))))))

(ert-deftest review-panel-right-column-reports-binary-and-failures ()
  (review-panel-test--with s
    (review-session-next-file)
    (review-session-next-file)
    (let ((text (review-panel-render s nil nil)))
      (should (string-match-p "binary" (review-panel-test--line text "bin\\.dat"))))
    (setf (plist-get (aref (review-session-files s) 0) :error) "boom")
    (should (string-match-p "failed" (review-panel-test--line (review-panel-render s nil nil) "a\\.el")))))

(ert-deftest review-panel-and-panes-name-a-mode-only-change ()
  (save-window-excursion
    (let* ((source (review-session-test--source '(("a.txt" modified "a\n" "b\n") ("run.sh" modified "x\n" "x\n"))))
           (files (review-source-files source)))
      (setf (review-source-files source)
            (lambda () (let ((fs (funcall files)))
                         (plist-put (nth 1 fs) :unchanged t)
                         (plist-put (nth 1 fs) :mode '("100644" . "100755"))
                         fs)))
      (let ((s (review-session-start source)) (fetched nil))
        (unwind-protect
            (let ((text (review-source-text source)))
              (setf (review-source-text source)
                    (lambda (file side cb) (when (equal (plist-get file :path) "run.sh") (setq fetched t))
                      (funcall text file side cb)))
              (should (string-match-p "mode \\+x" (review-panel-test--line (review-panel-render s nil nil) "run\\.sh")))
              (review-session-next-file)
              (should-not fetched)
              (with-current-buffer (review-session-new-buffer s)
                (should (string-match-p "mode 100644 -> 100755, content unchanged" (buffer-string)))))
          (review-session-quit))))))

(ert-deftest review-panel-long-paths-are-truncated-to-the-width ()
  (review-panel-test--with s
    (setf (plist-get (aref (review-session-files s) 2) :path)
          "services/really/deeply/nested/configuration/with-a-long-file-name.yaml")
    (let ((line (review-panel-test--line (review-panel-render s nil nil 40) "with-a-long")))
      (should (string-match-p "…" line))
      (should (<= (string-width line) 40)))))

(ert-deftest review-panel-long-paths-keep-the-file-name-and-cut-folders-first ()
  (review-panel-test--with s
    (setf (plist-get (aref (review-session-files s) 2) :path)
          "services/really/deeply/nested/configuration/directory/with-a-long-file-name.yaml")
    (let ((wide (review-panel-test--line (review-panel-render s nil nil 75) "with-a-long"))
          (narrow (review-panel-test--line (review-panel-render s nil nil 30) "with-")))
      ;; Folders go from the left, whole, behind an ellipsis.
      (should (string-match-p "…/\\(?:[^/ ]+/\\)*directory/with-a-long-file-name\\.yaml" wide))
      (should-not (string-match-p "services" wide))
      ;; With no room for any folder, only the name remains, cut at its end.
      (should-not (string-match-p "/" narrow))
      (should (string-match-p "with-[^ ]*…" narrow)))))

(ert-deftest review-panel-right-text-never-overlaps-left ()
  (should (string-match-p "right" (review-panel--flush "left" "right" 40)))
  (should (equal (review-panel--flush "a long left side" "right side" 20) "a long left side")))

(ert-deftest review-panel-collapsed-strip-is-narrow-and-iconic ()
  (review-panel-test--with s
    (review-session-next-file)
    (let* ((text (review-panel-render s nil t))
           (lines (split-string text "\n")))
      (should (seq-every-p (lambda (l) (<= (string-width l) review-panel-strip-width)) lines))
      (should (seq-find (lambda (l) (string-match-p "\\`[[:space:]]*1\\'" l)) lines))
      (should (seq-find (lambda (l) (string-match-p "of" l)) lines))
      (should (= 1 (cl-count-if (lambda (l) (string-match-p "●" l)) lines)))
      (should (= 1 (cl-count-if (lambda (l) (string-match-p "❯" l)) lines)))
      (should (= 1 (cl-count-if (lambda (l) (string-match-p "○" l)) lines)))
      (should-not (string-match-p "a\\.el" text)))))

(ert-deftest review-panel-strip-fits-real-pr-and-git-labels ()
  (review-panel-test--with s
    (dolist (number '(12345 nil))
      (setf (review-source-number (review-session-source s)) number)
      (dolist (line (split-string (review-panel-render s nil t) "\n"))
        (should (<= (string-width line) review-panel-strip-width))))))

(ert-deftest review-panel-rows-carry-file-and-hunk-properties ()
  (review-panel-test--with s
    (let* ((text (review-panel-render s nil nil))
           (pos (string-match "a\\.el" text)))
      (should (eq (get-text-property pos 'review-file text) 0))
      (should (null (get-text-property pos 'review-hunk text)))
      (let ((h (string-match "@@" text)))
        (should (eq (get-text-property h 'review-file text) 0))
        (should (eq (get-text-property h 'review-hunk text) 0)))
      (should (get-text-property (string-match "Fake" text) 'review-header text)))))

(ert-deftest review-panel-key-hints-live-in-the-footer ()
  (review-panel-test--with s
    (review-panel-open s)
    (with-current-buffer (review-session-panel s)
      (let ((footer (substring-no-properties (apply (function concat) mode-line-format))))
        (dolist (hint '("C-j/k" "hunk" "J/K" "file" "TAB" "fold" "RET" "open" "x" "viewed" "park"))
          (should (string-match-p (regexp-quote hint) footer))))
      (setq review-panel--collapsed t)
      (review-panel--refresh s)
      (should (equal (string-trim (substring-no-properties (apply (function concat) mode-line-format))) "TAB")))))

(ert-deftest review-panel-open-tracks-session ()
  (review-panel-test--with s
    (review-panel-open s)
    (let ((panel (review-session-panel s)))
      (should (buffer-live-p panel))
      (with-current-buffer panel
        (should (eq major-mode 'review-panel-mode))
        (should (string-match-p "0 of 3" (buffer-string))))
      (review-session-next-file)
      (with-current-buffer panel
        (should (string-match-p "1 of 3" (buffer-string)))))))

(ert-deftest review-panel-refreshes-when-the-source-title-arrives ()
  (review-panel-test--with s
    (review-panel-open s)
    (setf (review-source-title (review-session-source s)) "Late title")
    (run-hook-with-args 'review-source-updated-functions (review-session-source s))
    (with-current-buffer (review-session-panel s)
      (should (string-match-p "Late title" (buffer-string))))))

(ert-deftest review-panel-survives-next-file-from-its-own-window ()
  (review-panel-test--with s
    (review-panel-open s)
    (select-window (get-buffer-window (review-session-panel s)))
    (review-session-next-file)
    (should (window-live-p (get-buffer-window (review-session-panel s))))
    (should (eq (window-parameter (get-buffer-window (review-session-panel s)) 'window-side) 'left))
    (dolist (w (list (review-session-old-window s) (review-session-new-window s)))
      (should (window-live-p w))
      (should-not (window-parameter w 'window-side)))))

(ert-deftest review-panel-fold-toggles-file-at-point ()
  (review-panel-test--with s
    (review-panel-open s)
    (with-current-buffer (review-session-panel s)
      (goto-char (point-min))
      (re-search-forward "a\\.el")
      (should (string-match-p "@@ -2,1 \\+2,1" (buffer-string)))
      (review-panel-fold)
      (should (equal review-panel--toggled '(0)))
      (should-not (string-match-p "@@ -2,1 \\+2,1" (buffer-string)))
      (review-panel-fold)
      (should (null review-panel--toggled)))))

(ert-deftest review-panel-visit-shows-file-at-point ()
  (review-panel-test--with s
    (review-panel-open s)
    (with-current-buffer (review-session-panel s)
      (goto-char (point-min))
      (re-search-forward "b\\.el")
      (review-panel-visit)
      (should (equal (review-session-current s) 1)))))

(ert-deftest review-panel-loads-the-entire-hunk-map ()
  (review-panel-test--with s
    (review-panel-open s)
    (let ((deadline (+ (float-time) 2)))
      (while (and (< (float-time) deadline)
                  (not (plist-get (review-session-file s 1) :loaded)))
        (accept-process-output nil 0.01)))
    (should (plist-get (review-session-file s 1) :hunks))
    (with-current-buffer (review-session-panel s)
      (should (string-match-p "1 hunk" (review-panel-test--line (buffer-string) "b\\.el"))))
    (should (equal (plist-get (car (plist-get (review-session-file s 1) :hunks))
                             :new-count) 3))))

(ert-deftest review-panel-strip-resizes-and-restores-expanded-width ()
  (review-panel-test--with s
    (review-panel-open s)
    (with-current-buffer (review-session-panel s)
      (goto-char (point-min))
      (review-panel-fold)
      (should (<= (window-total-width (get-buffer-window (current-buffer)))
                  (+ 2 review-panel-strip-width)))
      (review-panel-fold)
      (should (> (window-total-width (get-buffer-window (current-buffer)))
                 review-panel-strip-width)))))

(defun review-panel-test--header (buffer)
  (with-current-buffer buffer
    (let ((h header-line-format)) (if (stringp h) h (apply #'concat (flatten-list h))))))

(ert-deftest review-panel-compare-panes-have-design-headers-and-no-mode-lines ()
  (review-panel-test--with s
    (review-panel-open s)
    (setf (review-source-old-label (review-session-source s)) "main @ 9c1e2f4"
          (review-source-new-label (review-session-source s)) "feat @ 41d0aa7")
    (review-session-next-file)
    (let ((old (review-panel-test--header (review-session-old-buffer s)))
          (new (review-panel-test--header (review-session-new-buffer s))))
      (should (string-match-p "OLD +main @ 9c1e2f4" old))
      (should (string-match-p "NEW +feat @ 41d0aa7" new))
      (should (equal (plist-get (get-text-property (string-match "OLD" old) 'face old) :foreground)
                     (review-panel--hex 'red))))
    (dolist (b (list (review-session-old-buffer s) (review-session-new-buffer s)))
      (should-not (buffer-local-value 'mode-line-format b)))))

(ert-deftest review-panel-compare-panes-mark-each-hunk-with-a-band ()
  (review-panel-test--with s
    (review-panel-open s)
    (review-session-next-file)
    (dolist (b (list (review-session-old-buffer s) (review-session-new-buffer s)))
      (with-current-buffer b
        (let ((bands (seq-filter (lambda (o) (overlay-get o 'review-band))
                                 (overlays-in (point-min) (point-max)))))
          (should (= (length bands) 1))
          (should (string-match-p "@@ -2,2 \\+2,3 @@  hunk 1 of 1"
                                  (overlay-get (car bands) 'before-string))))))))

(ert-deftest review-panel-compare-top-bar-tracks-file-and-hunk ()
  (review-panel-test--with s
    (review-panel-open s)
    (let ((bar (get-buffer "*review bar*")))
      (should (buffer-live-p bar))
      (should (eq (window-parameter (get-buffer-window bar t) 'window-side) 'top))
      (with-current-buffer bar
        (should (string-match-p "a\\.el" (buffer-string)))
        (should (string-match-p "file 1 of 3.*hunk 1 of 1.*\\+1.*-1" (buffer-string))))
      (review-session-next-file)
      (with-current-buffer bar
        (should (string-match-p "b\\.el" (buffer-string)))
        (should (string-match-p "file 2 of 3" (buffer-string))))
      (review-session-quit)
      (should-not (buffer-live-p bar)))))

(defvar mr-x/quick-ask-notification nil)
(defvar mr-x/quick-ask-notify-functions nil)

(ert-deftest review-panel-compare-bottom-strip-shows-hints-or-quick-ask-news ()
  (review-panel-test--with s
    (let ((mr-x/quick-ask-notification nil)
          (mr-x/quick-ask-notify-functions nil))
      (review-panel-open s)
      (let ((strip (get-buffer "*review hints*")))
        (should (buffer-live-p strip))
        (should (eq (window-parameter (get-buffer-window strip t) 'window-side) 'bottom))
        (with-current-buffer strip
          (dolist (hint '("C-j/k" "hunk" "J/K" "file" "viewed" "park" "SPC q" "ask" "SPC ," "more"))
            (should (string-match-p (regexp-quote hint) (buffer-string)))))
        ;; A hidden Quick Ask answer replaces the hints until it is shown.
        (setq mr-x/quick-ask-notification 'ready)
        (run-hook-with-args 'mr-x/quick-ask-notify-functions 'ready)
        (with-current-buffer strip
          (should (string-match-p "answer ready" (buffer-string)))
          (should (string-match-p "SPC Q" (buffer-string)))
          (should-not (string-match-p "hunk" (buffer-string))))
        (setq mr-x/quick-ask-notification nil)
        (run-hook-with-args 'mr-x/quick-ask-notify-functions nil)
        (with-current-buffer strip
          (should (string-match-p "hunk" (buffer-string))))
        (review-session-quit)
        (should-not (buffer-live-p strip))))))

(ert-deftest review-panel-ask-card-follows-the-design ()
  (with-temp-buffer
    (let (styled)
      (review-panel-ask-card "a.el 3-4  /  PR #41" "# why let*?" "Because **cur**.\n\nSecond."
                             (lambda () (setq styled (buffer-string))))
      (let ((text (buffer-string)))
        (should (string-match-p "ASK.*a\\.el 3-4  /  PR #41" text))
        (let ((faces (get-text-property (string-match "ASK" text) 'face text)))
          (should (seq-find (lambda (f) (and (consp f) (equal (plist-get f :foreground)
                                                              (review-panel--hex 'yellow))))
                            (if (keywordp (car-safe faces)) (list faces) faces))))
        ;; Markdown styling sees only the answer, never the question.
        (should (equal styled "Because **cur**.\n\nSecond.\n"))
        (should (string-match-p "# why let\\*\\?" text))
        (let ((faces (get-text-property (string-match "Second" text) 'face text)))
          (should (seq-find (lambda (f) (and (consp f) (equal (plist-get f :foreground)
                                                              (review-panel--hex 'dim))))
                            (if (keywordp (car-safe faces)) (list faces) faces))))
        (dolist (exit '("q.*dismiss" "c.*continue in chat" "u.*park it" "y.*copy" "r.*again"))
          (should (string-match-p exit text)))))))

(provide 'review-panel-test)
