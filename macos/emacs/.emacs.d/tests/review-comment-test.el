;;; review-comment-test.el --- Draft comments in a review -*- lexical-binding: t; -*-
(require 'ert)
(require 'review-comment)

(defvar review-comment-test--spec
  '(("a.el" "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n" "1\n2\nTHREE\n4\n5\n6\n7\n8\n9\n10\n11\nTWELVE\n")
    ("b.el" "x\ny\n" "x\nY\n")
    ("c.el" "p\nq\n" "p\nq\nr\n"))
  "Files as (PATH OLD NEW).  a.el changes lines 3 and 12, its last.")

(defun review-comment-test--source (&optional kind)
  (let ((spec review-comment-test--spec))
    (make-review-source
     :name "fake" :title "Fake" :range-label "x -> y"
     :recipe (list :kind (or kind 'fake) :id "comment")
     :files (lambda () (mapcar (lambda (s) (list :path (car s) :old-path (car s) :kind 'modified)) spec))
     :text (lambda (file side cb)
             (let ((s (assoc (plist-get file :path) spec)))
               (funcall cb (if (eq side 'old) (nth 1 s) (nth 2 s)))))
     :origin (lambda (file start _end) (list :label (format "%s:%d" (plist-get file :path) start))))))

(defmacro review-comment-test--with (var &rest body)
  "Run BODY with VAR a live session on the fake source, all files loaded."
  (declare (indent 1))
  `(let ((review-store-directory (file-name-as-directory (make-temp-file "review-comment" t)))
         (review-store--memory (make-hash-table :test #'equal))
         (review-comment--carried (make-hash-table :test #'equal))
         (review-comment-compose-styles '((test ignore ignore)))
         (review-comment-compose-style 'test))
     (save-window-excursion
       (let ((,var (review-session-start (review-comment-test--source))))
         (dotimes (i (length (review-session-files ,var)))
           (review-session-load ,var i #'ignore))
         (unwind-protect (progn ,@body)
           (when (get-buffer "*review-comment*") (kill-buffer "*review-comment*"))
           (when review-session--current (review-session-quit))
           (delete-directory review-store-directory t))))))

(defun review-comment-test--file (session path)
  (seq-find (lambda (f) (equal (plist-get f :path) path)) (review-session-files session)))

(ert-deftest review-comment-rows-by-side-line ()
  (review-comment-test--with s
    (let ((a (review-comment-test--file s "a.el")) (c (review-comment-test--file s "c.el")))
      (should (equal (review-comment--rows a 'new 3 3) '(2)))
      (should (equal (review-comment--rows a 'old 10 12) '(9 10 11)))
      ;; c.el line 3 exists only on the new side.
      (should (equal (review-comment--rows c 'new 3 3) '(2)))
      (should-not (review-comment--rows c 'old 3 3)))))

(ert-deftest review-comment-hunk-rule ()
  (review-comment-test--with s
    (let ((a (review-comment-test--file s "a.el")))
      ;; Hunks sit on rows 2 and 11; three rows of context on each side count.
      (should (review-comment--commentable-p a '(2)))
      (should (review-comment--commentable-p a '(0)))
      (should (review-comment--commentable-p a '(5)))
      (should-not (review-comment--commentable-p a '(6)))
      (should-not (review-comment--commentable-p a '(7)))
      (should (review-comment--commentable-p a '(8)))
      (should (review-comment--commentable-p a '(9 10 11)))
      ;; A range must stay inside one hunk's window, and no rows is no place.
      (should-not (review-comment--commentable-p a '(5 6 7 8)))
      (should-not (review-comment--commentable-p a nil)))))

(ert-deftest review-comment-line-text-and-labels ()
  (review-comment-test--with s
    (let ((a (review-comment-test--file s "a.el")))
      (should (equal (review-comment--line-text a 'new 3) "THREE"))
      (should (equal (review-comment--line-text a 'old 3) "3"))
      (should (equal (review-comment--where '(:line 12)) "line 12"))
      (should (equal (review-comment--where '(:line 12 :start-line 10)) "lines 10-12"))
      (should (equal (review-comment--label '(:path "a.el" :side new :line 12 :start-line 10))
                     "a.el:10-12 (new)")))))

(ert-deftest review-comment-reanchor-follows-the-text ()
  (review-comment-test--with s
    (let* ((a (review-comment-test--file s "a.el"))
           (moved (review-comment--reanchor
                   '(:id 1 :path "a.el" :side new :line 5 :start-line nil :text "THREE" :body "b" :pending t) a))
           (range (review-comment--reanchor
                   '(:id 2 :path "a.el" :side new :line 9 :start-line 8 :text "TWELVE" :body "b" :pending t) a))
           (gone (review-comment--reanchor
                  '(:id 3 :path "a.el" :side new :line 3 :start-line nil :text "no such line" :body "b" :pending t) a))
           (off-hunk (review-comment--reanchor
                      '(:id 4 :path "a.el" :side new :line 2 :start-line nil :text "7" :body "b" :pending t) a)))
      (should (= (plist-get moved :line) 3))
      (should-not (plist-get moved :pending))
      (should-not (plist-get moved :outdated))
      ;; A range keeps its length: 8-9 becomes 11-12.
      (should (= (plist-get range :line) 12))
      (should (= (plist-get range :start-line) 11))
      (should (plist-get gone :outdated))
      (should (= (plist-get gone :line) 3))
      ;; Line 7 still exists but is outside every hunk now: not postable.
      (should (plist-get off-hunk :outdated))
      (should-not (plist-get off-hunk :pending)))))

(provide 'review-comment-test)
;;; review-comment-test.el ends here
