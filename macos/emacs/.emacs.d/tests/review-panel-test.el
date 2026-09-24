;;; review-panel-test.el --- Files panel rendering -*- lexical-binding: t; -*-
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

(ert-deftest review-panel-render-header-and-progress ()
  (review-panel-test--with s
    (let ((text (review-panel-render s nil nil)))
      (should (string-match-p "^Fake" text))
      (should (string-match-p "x -> y" text))
      (should (string-match-p "0 of 3 viewed" text))
      (should (string-match-p "a\\.el" text))
      (should (string-match-p "bin\\.dat" text)))))

(ert-deftest review-panel-render-expanded-shows-hunks-of-every-file ()
  (review-panel-test--with s
    (review-session-next-file)
    (let ((text (review-panel-render s nil nil)))
      (should (string-match-p "@@ -2,2 \\+2,3 @@" text))
      (should (string-match-p "hunk 1/1" text)))))

(ert-deftest review-panel-render-folded-hides-hunks ()
  (review-panel-test--with s
    (let ((text (review-panel-render s '(0 1 2) nil)))
      (should-not (string-match-p "@@" text))
      (should (string-match-p "1 hunk" text)))))

(ert-deftest review-panel-render-marks-current-and-viewed ()
  (review-panel-test--with s
    (review-session-next-file)
    (let* ((text (review-panel-render s '(0 1 2) nil))
           (lines (split-string text "\n")))
      (should (seq-find (lambda (l) (and (string-match-p "a\\.el" l)
                                          (string-match-p review-panel-viewed-label l)))
                        lines))
      (should (seq-find (lambda (l) (and (string-match-p "b\\.el" l)
                                          (string-match-p review-panel-current-label l)))
                        lines)))))

(ert-deftest review-panel-render-collapsed-is-narrow ()
  (review-panel-test--with s
    (let ((lines (split-string (review-panel-render s nil t) "\n")))
      (should (seq-every-p (lambda (l) (<= (length l) 8)) lines))
      (should (seq-find (lambda (l) (string-match-p "0" l)) lines))
      (should (equal (cl-count-if (lambda (l) (string-match-p review-panel-pending-label l)) lines) 2)))))

(ert-deftest review-panel-rows-carry-file-and-hunk-properties ()
  (review-panel-test--with s
    (let* ((text (review-panel-render s nil nil))
           (pos (string-match "a\\.el" text)))
      (should (eq (get-text-property pos 'review-file text) 0))
      (should (null (get-text-property pos 'review-hunk text)))
      (let ((h (string-match "@@" text)))
        (should (eq (get-text-property h 'review-file text) 0))
        (should (eq (get-text-property h 'review-hunk text) 0))))))

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
      (review-panel-fold)
      (should (equal review-panel--folded '(0)))
      (should-not (string-match-p "@@ -2,1 \\+2,1" (buffer-string)))
      (review-panel-fold)
      (should (null review-panel--folded)))))

(ert-deftest review-panel-visit-shows-file-at-point ()
  (review-panel-test--with s
    (review-panel-open s)
    (with-current-buffer (review-session-panel s)
      (goto-char (point-min))
      (re-search-forward "b\\.el")
      (review-panel-visit)
      (should (equal (review-session-current s) 1)))))

(ert-deftest review-panel-strip-fits-real-pr-and-git-labels ()
  (review-panel-test--with s
    (dolist (label '("team/project#12345" "feature/long-name...main"))
      (setf (review-source-range-label (review-session-source s)) label)
      (dolist (line (split-string (review-panel-render s nil t) "\n"))
        (should (<= (string-width line) review-panel-strip-width))))))

(ert-deftest review-panel-loads-the-entire-hunk-map ()
  (review-panel-test--with s
    (review-panel-open s)
    (let ((deadline (+ (float-time) 2)))
      (while (and (< (float-time) deadline)
                  (not (plist-get (review-session-file s 1) :loaded)))
        (accept-process-output nil 0.01)))
    (should (plist-get (review-session-file s 1) :hunks))
    (with-current-buffer (review-session-panel s)
      (should (string-match-p (regexp-quote "@@ -2,2 +2,3 @@") (buffer-string))))))

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

(provide 'review-panel-test)
