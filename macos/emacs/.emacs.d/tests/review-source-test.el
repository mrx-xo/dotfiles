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

(ert-deftest review-source-git-tilde-path-stays-inside-repository ()
  (review-source-test--with-repo dir
    (make-directory (concat dir "/~"))
    (with-temp-file (concat dir "/~/notes.txt") (insert "base\n"))
    (review-source-test--git dir "add" "-f" "~/notes.txt")
    (review-source-test--git dir "commit" "-qm" "tilde directory")
    (with-temp-file (concat dir "/~/notes.txt") (insert "changed\n"))
    (let* ((src (review-source-git-range dir))
           (file (car (funcall (review-source-files src))))
           (reader (symbol-function 'insert-file-contents))
           got)
      (cl-letf (((symbol-function 'insert-file-contents)
                 (lambda (name &rest args)
                   (should (equal name (concat dir "/~/notes.txt")))
                   (apply reader name args))))
        (funcall (review-source-text src) file 'new (lambda (text) (setq got text))))
      (should (equal got "changed\n"))
      (should (equal (plist-get (funcall (review-source-origin src) file 1 1) :link)
                     (concat "file:" (abbreviate-file-name dir) "/~/notes.txt::1"))))))

(ert-deftest review-source-git-does-not-read-through-an-escaping-parent-symlink ()
  (review-source-test--with-repo dir
    (let ((outside (make-temp-file "review-outside-" t)))
      (unwind-protect
          (progn
            (make-directory (concat dir "/nested"))
            (with-temp-file (concat dir "/nested/file.txt") (insert "base\n"))
            (review-source-test--git dir "add" "nested/file.txt")
            (review-source-test--git dir "commit" "-qm" "nested")
            (with-temp-file (concat dir "/nested/file.txt") (insert "changed\n"))
            (let* ((src (review-source-git-range dir))
                   (file (car (funcall (review-source-files src)))))
              (delete-file (concat dir "/nested/file.txt"))
              (delete-directory (concat dir "/nested"))
              (make-symbolic-link outside (concat dir "/nested"))
              (cl-letf (((symbol-function 'insert-file-contents)
                         (lambda (&rest _) (ert-fail "Attempted outside read"))))
                (should-error (funcall (review-source-text src) file 'new #'ignore)
                              :type 'user-error))))
        (delete-directory outside t)))))

(require 'forgejo-pull)
(require 'forgejo-review-ediff)

(ert-deftest review-source-old-side-is-explicit-in-persistable-origin-label ()
  (dolist (source (list (review-source-git-range temporary-file-directory "HEAD~1..HEAD")
                        (review-source-forgejo-pr "https://forge.example" "team" "project" 1 nil)))
    (let ((origin (funcall (review-source-origin source)
                           '(:path "new.txt" :origin-path "old.txt" :side old) 3 4)))
      (should (eq (plist-get origin :side) 'old))
      (should (string-match-p "old.txt:3-4.*(old)" (plist-get origin :label))))))

(defconst review-source-test--patch
  (concat "diff --git a/a.el b/a.el\nindex 1111111..2222222 100644\n--- a/a.el\n+++ b/a.el\n@@ -1 +1 @@\n-old\n+new\n"
          "diff --git a/new.md b/new.md\nnew file mode 100644\nindex 0000000..3333333\n--- /dev/null\n+++ b/new.md\n@@ -0,0 +1 @@\n+hi\n"
          "diff --git a/img.png b/img.png\nindex 4444444..5555555 100644\nBinary files a/img.png and b/img.png differ\n"
          "diff --git a/gone.txt b/gone.txt\ndeleted file mode 100644\nindex 6666666..0000000\n--- a/gone.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-bye\n"))

(defmacro review-source-test--with-patch (&rest body)
  (declare (indent 0))
  `(with-temp-buffer
     (insert review-source-test--patch)
     (diff-mode)
     (setq-local forgejo-repo--host "https://forge.example")
     (setq-local forgejo-repo--owner "team")
     (setq-local forgejo-repo--name "project")
     (setq-local forgejo-diff--pr-number 41)
     ,@body))

(ert-deftest review-source-forgejo-patch-files-kinds-and-blobs ()
  (review-source-test--with-patch
    (let ((files (review-source-forgejo-patch-files)))
      (should (equal (mapcar (lambda (f) (list (plist-get f :path) (plist-get f :kind) (plist-get f :binary))) files)
                     '(("a.el" modified nil) ("new.md" added nil) ("img.png" modified t) ("gone.txt" deleted nil))))
      (should (equal (plist-get (car files) :blobs) '("1111111" "2222222")))
      (should (equal (plist-get (nth 1 files) :old-path) nil)))))

(ert-deftest review-source-forgejo-pure-rename-does-not-abort-the-list ()
  (with-temp-buffer
    (insert review-source-test--patch
            "diff --git a/x.txt b/y.txt\nsimilarity index 100%\nrename from x.txt\nrename to y.txt\n")
    (diff-mode)
    (let ((files (review-source-forgejo-patch-files)))
      (should (equal (length files) 5))
      (should (equal (plist-get (nth 4 files) :kind) 'renamed))
      (should (plist-get (nth 4 files) :binary)))))

(ert-deftest review-source-forgejo-text-checks-blob-and-decodes ()
  (review-source-test--with-patch
    (let* ((files (review-source-forgejo-patch-files))
           (calls nil) (got nil)
           (src (review-source-forgejo-pr "https://forge.example" "team" "project" 41 files)))
      (cl-letf (((symbol-function 'forgejo-api-get)
                 (lambda (host path params cb &rest _args)
                   (push (list path params) calls)
                   (cond ((string-suffix-p "pulls/41" path)
                          (funcall cb '((merge_base . "base1") (head . ((sha . "head1")))) nil))
                         (t (funcall cb `((sha . "2222222abc") (encoding . "base64")
                                          (content . ,(base64-encode-string "new\n")))
                                     nil))))))
        (funcall (review-source-text src) (car files) 'new (lambda (s) (setq got s)))
        (should (equal got "new\n"))
        (should (equal (cadr (car calls)) '(("ref" . "head1"))))
        (should (string-match-p "contents/a.el" (car (car calls))))))))

(ert-deftest review-source-forgejo-fills-title-and-branches-from-metadata ()
  (review-source-test--with-patch
    (let* ((files (review-source-forgejo-patch-files))
           (src (review-source-forgejo-pr "https://forge.example" "team" "project" 41 files))
           (updated nil)
           (review-source-updated-functions (list (lambda (s) (push s updated)))))
      (should (equal (review-source-number src) 41))
      (cl-letf (((symbol-function 'forgejo-api-get)
                 (lambda (_host path _params cb &rest _args)
                   (if (string-suffix-p "pulls/41" path)
                       (funcall cb '((title . "Cache the PR list") (merge_base . "base1")
                                     (base . ((ref . "main")))
                                     (head . ((sha . "head1") (ref . "feat/cache"))))
                                nil)
                     (funcall cb `((sha . "2222222abc") (encoding . "base64")
                                   (content . ,(base64-encode-string "new\n")))
                              nil)))))
        (funcall (review-source-text src) (car files) 'new #'ignore)
        (should (equal (review-source-title src) "Cache the PR list"))
        (should (equal (review-source-subtitle src) "team / project   feat/cache -> main"))
        (should (equal updated (list src)))))))

;; Decoding with plain utf-8 guessed the line endings and turned CRLF into
;; LF, so a line-ending-only change compared as identical text.
(ert-deftest review-source-forgejo-text-keeps-crlf ()
  (review-source-test--with-patch
    (let* ((files (review-source-forgejo-patch-files))
           (src (review-source-forgejo-pr "https://forge.example" "team" "project" 41 files))
           got)
      (cl-letf (((symbol-function 'forgejo-api-get)
                 (lambda (_host path _params cb &rest _args)
                   (if (string-suffix-p "pulls/41" path)
                       (funcall cb '((merge_base . "base1") (head . ((sha . "head1")))) nil)
                     (funcall cb `((sha . "2222222abc") (encoding . "base64")
                                   (content . ,(base64-encode-string "a\r\nb\r\n")))
                              nil)))))
        (funcall (review-source-text src) (car files) 'new (lambda (s) (setq got s)))
        (should (equal got "a\r\nb\r\n"))))))

(ert-deftest review-source-forgejo-text-rejects-drifted-blob ()
  (review-source-test--with-patch
    (let* ((files (review-source-forgejo-patch-files))
           (src (review-source-forgejo-pr "https://forge.example" "team" "project" 41 files))
           failure)
      (cl-letf (((symbol-function 'forgejo-api-get)
                 (lambda (_host path _params cb &rest _args)
                   (if (string-suffix-p "pulls/41" path)
                       (funcall cb '((merge_base . "base1") (head . ((sha . "head1")))) nil)
                     (funcall cb `((sha . "9999999") (encoding . "base64")
                                   (content . ,(base64-encode-string "x"))) nil)))))
        (funcall (review-source-text src) (car files) 'new
                 (lambda (text &optional error) (should-not text) (setq failure error)))
        (should (string-match-p "changed since this patch" failure))))))

(ert-deftest review-source-forgejo-reports-metadata-and-content-errors ()
  (review-source-test--with-patch
    (dolist (stage '(metadata content))
      (let* ((files (review-source-forgejo-patch-files))
             (src (review-source-forgejo-pr "https://forge.example" "team" "project" 41 files))
             failure)
        (cl-letf (((symbol-function 'forgejo-api-get)
                   (lambda (_host path _params cb &rest args)
                     (if (and (eq stage 'content) (string-suffix-p "pulls/41" path))
                         (funcall cb '((merge_base . "base1") (head . ((sha . "head1")))) nil)
                       (funcall (plist-get args :error-callback)
                                '(:status 403 :message "access denied"))))))
          (funcall (review-source-text src) (car files) 'new
                   (lambda (text &optional error) (should-not text) (setq failure error)))
          (should (string-match-p "access denied" failure)))))))

(ert-deftest review-source-forgejo-absent-side-is-empty-without-api ()
  (review-source-test--with-patch
    (let* ((files (review-source-forgejo-patch-files))
           (src (review-source-forgejo-pr "https://forge.example" "team" "project" 41 files))
           (got 'unset))
      (cl-letf (((symbol-function 'forgejo-api-get) (lambda (&rest _) (error "no api call expected"))))
        (funcall (review-source-text src) (nth 1 files) 'old (lambda (s) (setq got s)))
        (should (equal got ""))))))

(ert-deftest review-source-forgejo-binary-paths-and-empty-addition ()
  (with-temp-buffer
    (insert "diff --git a/a/img.png b/a/img.png\nindex 1111111..2222222\nBinary files differ\n"
            "diff --git \"a/tab\\timg.png\" \"b/tab\\timg.png\"\nindex 1111111..2222222\nBinary files differ\n"
            "diff --git a/empty.txt b/empty.txt\nnew file mode 100644\nindex 0000000..e69de29\n")
    (let ((files (review-source-forgejo-patch-files)))
      (should (equal (mapcar (lambda (f) (plist-get f :path)) files)
                     '("a/img.png" "tab\timg.png" "empty.txt")))
      (should (eq (plist-get (nth 2 files) :kind) 'added)))))

(provide 'review-source-test)
