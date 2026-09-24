;;; review-source-test.el --- Sources feed the review session -*- lexical-binding: t; -*-
(require 'ert)
(require 'review-source)

(defun review-source-test--git (dir &rest args)
  (let ((default-directory dir))
    (with-temp-buffer
      (unless (zerop (apply #'call-process "git" nil t nil args))
        (error "git %s failed: %s" args (buffer-string)))
      (string-trim (buffer-string)))))

(defmacro review-source-test--with-repo (var &rest body)
  "Make a repo with two commits: a.txt modified, b.txt added, c.txt deleted, bin.dat binary."
  (declare (indent 1))
  `(let ((,var (make-temp-file "review-repo" t)))
     (unwind-protect
         (progn
           (review-source-test--git ,var "init" "-q" "-b" "main")
           (review-source-test--git ,var "config" "user.email" "t@example.com")
           (review-source-test--git ,var "config" "user.name" "t")
           (with-temp-file (expand-file-name "a.txt" ,var) (insert "one\ntwo\nthree\n"))
           (with-temp-file (expand-file-name "c.txt" ,var) (insert "gone\n"))
           (with-temp-file (expand-file-name "bin.dat" ,var) (insert "x\0y"))
           (review-source-test--git ,var "add" ".")
           (review-source-test--git ,var "commit" "-q" "-m" "base")
           (with-temp-file (expand-file-name "a.txt" ,var) (insert "one\nTWO\nthree\n"))
           (with-temp-file (expand-file-name "b.txt" ,var) (insert "new\n"))
           (with-temp-file (expand-file-name "bin.dat" ,var) (insert "x\0z"))
           (delete-file (expand-file-name "c.txt" ,var))
           (review-source-test--git ,var "add" "-A")
           (review-source-test--git ,var "commit" "-q" "-m" "change")
           ,@body)
       (delete-directory ,var t))))

(ert-deftest review-source-git-range-lists-kinds ()
  (review-source-test--with-repo dir
    (let* ((src (review-source-git-range dir "HEAD~1..HEAD"))
           (files (funcall (review-source-files src))))
      (should (equal (mapcar (lambda (f) (cons (plist-get f :path) (plist-get f :kind))) files)
                     '(("a.txt" . modified) ("b.txt" . added) ("bin.dat" . modified) ("c.txt" . deleted))))
      (should (plist-get (nth 2 files) :binary))
      (should-not (plist-get (car files) :binary)))))

(ert-deftest review-source-git-range-texts ()
  (review-source-test--with-repo dir
    (let* ((src (review-source-git-range dir "HEAD~1..HEAD"))
           (files (funcall (review-source-files src)))
           (got nil))
      (funcall (review-source-text src) (car files) 'old (lambda (s) (setq got s)))
      (should (equal got "one\ntwo\nthree\n"))
      (funcall (review-source-text src) (car files) 'new (lambda (s) (setq got s)))
      (should (equal got "one\nTWO\nthree\n"))
      (funcall (review-source-text src) (nth 1 files) 'old (lambda (s) (setq got s)))
      (should (equal got ""))
      (funcall (review-source-text src) (nth 3 files) 'new (lambda (s) (setq got s)))
      (should (equal got "")))))

(ert-deftest review-source-git-range-worktree-reads-live-file ()
  (review-source-test--with-repo dir
    (with-temp-file (expand-file-name "a.txt" dir) (insert "one\nlive\nthree\n"))
    (let* ((src (review-source-git-range dir nil))
           (files (funcall (review-source-files src)))
           (got nil))
      (should (equal (mapcar (lambda (f) (plist-get f :path)) files) '("a.txt")))
      (funcall (review-source-text src) (car files) 'new (lambda (s) (setq got s)))
      (should (equal got "one\nlive\nthree\n")))))

(ert-deftest review-source-git-range-single-commit-is-commit-vs-parent ()
  (review-source-test--with-repo dir
    (with-temp-file (expand-file-name "a.txt" dir) (insert "dirty\n"))
    (let* ((src (review-source-git-range dir "HEAD"))
           (files (funcall (review-source-files src)))
           (got nil))
      (should (equal (mapcar (lambda (f) (plist-get f :path)) files) '("a.txt" "b.txt" "bin.dat" "c.txt")))
      (funcall (review-source-text src) (car files) 'new (lambda (s) (setq got s)))
      (should (equal got "one\nTWO\nthree\n")))))

(ert-deftest review-source-git-range-labels ()
  (review-source-test--with-repo dir
    (let ((src (review-source-git-range dir "HEAD~1..HEAD")))
      (should (equal (review-source-name src) "git"))
      (should (string-match-p "HEAD~1..HEAD" (review-source-range-label src)))
      (let ((origin (funcall (review-source-origin src) (list :path "a.txt") 2 3)))
        (should (equal (plist-get origin :label) "a.txt:2-3 @ HEAD~1..HEAD"))
        (should (string-prefix-p "file:" (plist-get origin :link)))))))

(ert-deftest review-source-git-binary-rename-and-staged-text ()
  (review-source-test--with-repo dir
    (review-source-test--git dir "mv" "bin.dat" "renamed.dat")
    (with-temp-file (expand-file-name "a.txt" dir) (insert "staged\n"))
    (review-source-test--git dir "add" "a.txt")
    (let* ((src (review-source-git-range dir "--staged"))
           (files (funcall (review-source-files src))) got)
      (should (eq (plist-get (cadr files) :kind) 'renamed))
      (should (plist-get (cadr files) :binary))
      (with-temp-file (expand-file-name "a.txt" dir) (insert "later\n"))
      (review-source-test--git dir "add" "a.txt")
      (funcall (review-source-text src) (car files) 'new (lambda (s) (setq got s)))
      (should (equal got "staged\n")))))

(ert-deftest review-source-git-pins-commit-references ()
  (review-source-test--with-repo dir
    (let* ((src (review-source-git-range dir "HEAD"))
           (file (car (funcall (review-source-files src)))) got)
      (with-temp-file (expand-file-name "a.txt" dir) (insert "later\n"))
      (review-source-test--git dir "add" "a.txt")
      (review-source-test--git dir "commit" "-qm" "later")
      (funcall (review-source-text src) file 'new (lambda (s) (setq got s)))
      (should (equal got "one\nTWO\nthree\n")))))

(ert-deftest review-source-git-initial-commit-and-open-range ()
  (review-source-test--with-repo dir
    (let* ((src (review-source-git-range dir "HEAD~1"))
           (files (funcall (review-source-files src))) got)
      (should (= (length files) 3))
      (should (seq-every-p (lambda (f) (eq (plist-get f :kind) 'added)) files))
      (funcall (review-source-text src) (car files) 'old (lambda (s) (setq got s)))
      (should (equal got "")))
    (let* ((src (review-source-git-range dir "HEAD~1..")) got)
      (funcall (review-source-text src) (car (funcall (review-source-files src)))
               'new (lambda (s) (setq got s)))
      (should (equal got "one\nTWO\nthree\n")))))

(ert-deftest review-source-git-read-errors-are-not-empty-files ()
  (review-source-test--with-repo dir
    (should-error (review-source--git-show dir "does-not-exist" "a.txt") :type 'user-error)))

(provide 'review-source-test)
