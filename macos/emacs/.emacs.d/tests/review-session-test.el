;;; review-session-test.el --- Session state and pane text -*- lexical-binding: t; -*-
(require 'ert)
(require 'review-session)

(defun review-session-test--source (spec)
  "SPEC is a list of (PATH KIND OLD NEW [BINARY])."
  (make-review-source
   :name "fake" :title "Fake" :range-label "x -> y"
   :files (lambda () (mapcar (lambda (s) (list :path (nth 0 s) :old-path (nth 0 s) :kind (nth 1 s) :binary (nth 4 s))) spec))
   :text (lambda (file side cb)
           (let ((s (seq-find (lambda (x) (equal (car x) (plist-get file :path))) spec)))
             (funcall cb (if (eq side 'old) (nth 2 s) (nth 3 s)))))
   :origin (lambda (file start end) (list :label (format "%s:%d-%d" (plist-get file :path) start end) :link nil :url nil))))

(defconst review-session-test--spec
  '(("a.el" modified "(defun a ()\n  1)\n" "(defun a ()\n  2)\n")
    ("b.el" modified "x\ny\nz\n" "x\nY\nz\nw\n")
    ("bin.dat" modified "" "" t)))

(defmacro review-session-test--with (var &rest body)
  (declare (indent 1))
  `(save-window-excursion
     (let ((,var (review-session-start (review-session-test--source review-session-test--spec))))
       (unwind-protect (progn ,@body)
         (review-session-quit)))))

(ert-deftest review-session-start-loads-first-file-and-panes ()
  (review-session-test--with s
    (should (equal (review-session-current s) 0))
    (should (equal (review-session-hunk s) 0))
    (should (buffer-live-p (review-session-old-buffer s)))
    (should (buffer-live-p (review-session-new-buffer s)))
    (should (equal (length (plist-get (aref (review-session-files s) 0) :hunks)) 1))
    (with-current-buffer (review-session-new-buffer s)
      (should (eq major-mode 'review-pane-mode))
      (should buffer-read-only)
      (should (string-match-p "  2)" (buffer-string))))))

(ert-deftest review-session-next-file-marks-viewed-and-advances ()
  (review-session-test--with s
    (review-session-next-file)
    (should (equal (review-session-current s) 1))
    (should (equal (review-session-viewed s) '(0)))
    (should (equal (review-session-progress s) '(1 . 3)))))

(ert-deftest review-session-next-file-skips-nothing-but-binary-has-no-panes ()
  (review-session-test--with s
    (review-session-next-file) (review-session-next-file)
    (should (equal (review-session-current s) 2))
    (should (plist-get (aref (review-session-files s) 2) :binary))
    (should (null (plist-get (aref (review-session-files s) 2) :hunks)))
    (with-current-buffer (review-session-new-buffer s)
      (should (string-match-p "binary" (buffer-string))))))

(ert-deftest review-session-past-the-end-is-an-error-and-keeps-state ()
  (review-session-test--with s
    (review-session-next-file) (review-session-next-file)
    (should-error (review-session-next-file) :type 'user-error)
    (should (equal (review-session-current s) 2))
    (should (equal (review-session-viewed s) '(1 0)))))

(ert-deftest review-session-prev-file-does-not-mark-viewed ()
  (review-session-test--with s
    (review-session-next-file)
    (review-session-prev-file)
    (should (equal (review-session-current s) 0))
    (should (equal (review-session-viewed s) '(0)))))

(ert-deftest review-session-hunks-walk-then-spill-into-next-file ()
  (review-session-test--with s
    (review-session-next-file)
    (should (equal (length (plist-get (aref (review-session-files s) 1) :hunks)) 1))
    (review-session-next-hunk)
    (should (equal (review-session-current s) 2))
    (should-error (review-session-next-hunk) :type 'user-error)
    (review-session-prev-hunk)
    (should (equal (review-session-current s) 1))
    (should (equal (review-session-hunk s) 0))))

(ert-deftest review-session-toggle-viewed ()
  (review-session-test--with s
    (review-session-toggle-viewed)
    (should (equal (review-session-viewed s) '(0)))
    (review-session-toggle-viewed)
    (should (equal (review-session-viewed s) nil))))

(ert-deftest review-session-pane-text-gutter-and-blanks ()
  (let* ((rows (review-diff-rows (review-diff-ops "a\nb\n" "a\nX\nY\n")))
         (old (review-session-pane-text rows 'old "a\nb\n"))
         (new (review-session-pane-text rows 'new "a\nX\nY\n"))
         (old-lines (split-string old "\n")) (new-lines (split-string new "\n")))
    (should (equal (length old-lines) (length new-lines)))
    (should (string-match-p "\\`  *1   a\\'" (nth 0 old-lines)))
    (should (string-match-p "\\`  *2 - b\\'" (nth 1 old-lines)))
    (should (string-match-p "\\`  *3 \\+ Y\\'" (nth 2 new-lines)))
    (should (string-match-p "\\`[[:space:]]*\\'" (nth 2 old-lines)))
    (should (eq (get-text-property 0 'review-row new) 0))
    (should (eq (get-text-property (1+ (length (nth 0 new-lines))) 'review-row new) 1))))

(ert-deftest review-session-quit-restores-and-kills ()
  (let (old new)
    (save-window-excursion
      (let ((s (review-session-start (review-session-test--source review-session-test--spec))))
        (setq old (review-session-old-buffer s) new (review-session-new-buffer s))
        (review-session-quit)))
    (should-not (buffer-live-p old))
    (should-not (buffer-live-p new))
    (should (null review-session--current))))

(ert-deftest review-session-update-hook-fires ()
  (let ((n 0))
    (add-hook 'review-session-update-hook (lambda (_s) (cl-incf n)))
    (unwind-protect
        (review-session-test--with s
          (let ((before n))
            (review-session-next-file)
            (should (> n before))))
      (setq review-session-update-hook nil))))


(ert-deftest review-session-late-loads-do-not-reopen-or-replace-panes ()
  (save-window-excursion
    (let (callbacks s)
      (unwind-protect
          (progn
            (setq s
                  (review-session-start
                   (make-review-source
                    :name "async" :title "Async" :range-label "base..head"
                    :files (lambda () '((:path "a.txt" :old-path "a.txt")
                                        (:path "b.txt" :old-path "b.txt")))
                    :text (lambda (file side cb)
                            (if (eq side 'old) (funcall cb "")
                              (push (cons (plist-get file :path) cb) callbacks))))))
            (review-session-show 1)
            (funcall (cdr (assoc "b.txt" callbacks)) "B\n")
            (funcall (cdr (assoc "a.txt" callbacks)) "A\n")
            (should (= (review-session-current s) 1))
            (with-current-buffer (review-session-new-buffer s)
              (should (string-match-p "B" (buffer-string))))
            (review-session-quit)
            (funcall (cdr (assoc "a.txt" callbacks)) "A\n")
            (should-not review-session--current)
            (should-not (buffer-live-p (review-session-new-buffer s))))
        (review-session-quit)))))

(ert-deftest review-session-failed-navigation-does-not-mark-viewed ()
  (review-session-test--with s
    (setf (review-source-text (review-session-source s))
          (lambda (&rest _) (user-error "Source unavailable")))
    (should-error (review-session-next-file) :type 'user-error)
    (should (= (review-session-current s) 0))
    (should-not (review-session-viewed s))))

(ert-deftest review-session-empty-text-is-cached ()
  (save-window-excursion
    (let ((calls 0) s)
      (unwind-protect
          (progn
            (setq s (review-session-start
                     (make-review-source
                      :name "empty" :title "Empty" :range-label "a..b"
                      :files (lambda () '((:path "empty" :old-path "empty")))
                      :text (lambda (_file _side cb) (cl-incf calls) (funcall cb "")))))
            (review-session-load s 0 #'ignore)
            (should (= calls 2)))
        (review-session-quit)))))

(ert-deftest review-session-restores-a-multiwindow-layout ()
  (save-window-excursion
    (split-window-below)
    (let ((before (length (window-list))))
      (let ((s (review-session-start (review-session-test--source review-session-test--spec))))
        (unwind-protect
            (should (and (window-live-p (review-session-old-window s))
                         (window-live-p (review-session-new-window s))))
          (review-session-quit)))
      (should (= before (length (window-list)))))))

(ert-deftest review-session-pane-keeps-source-directory ()
  (save-window-excursion
    (let ((src (review-session-test--source review-session-test--spec)))
      (setf (review-source-directory src) temporary-file-directory)
      (let ((s (review-session-start src)))
        (unwind-protect
            (with-current-buffer (review-session-new-buffer s)
              (should (equal default-directory temporary-file-directory)))
          (review-session-quit))))))

(provide 'review-session-test)
