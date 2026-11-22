;;; mr-x-docs-usage-test.el --- Tests for usage search -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(add-to-list 'load-path (expand-file-name "../lisp" (file-name-directory
                                                     (or load-file-name buffer-file-name))))
(require 'mr-x-docs-usage)

(ert-deftest mr-x-docs-usage-test-patterns ()
  (should (equal (mr-x/docs-usage-pattern "Array.prototype.map()" "javascript")
                 "\\.map\\("))
  (should (equal (mr-x/docs-usage-pattern "String.prototype.split()" "dom")
                 "\\.split\\("))
  (should (equal (mr-x/docs-usage-pattern "Promise.all()" "javascript")
                 "\\bPromise\\.all\\("))
  (should (equal (mr-x/docs-usage-pattern "json.loads()" "python~3.12")
                 "\\bjson\\.loads\\("))
  (should (equal (mr-x/docs-usage-pattern "strings.Fields()" "go")
                 "\\bstrings\\.Fields\\("))
  (should (equal (mr-x/docs-usage-pattern "os.Open()" "go")
                 "\\bos\\.Open\\("))
  (should (equal (mr-x/docs-usage-pattern "Promise" "javascript")
                 "\\bPromise\\b"))
  (should (equal (mr-x/docs-usage-pattern "Intl" "javascript") "\\bIntl\\b"))
  (should (equal (mr-x/docs-usage-pattern "json" "python") "\\bjson\\b"))
  (should (equal (mr-x/docs-usage-pattern "Package strings" "go")
                 "\\bstrings\\b"))
  (should (null (mr-x/docs-usage-pattern "12.3. Managing Packages with pip"
                                          "python")))
  (should (null (mr-x/docs-usage-pattern "Errors: handling failures" "go"))))

(defmacro mr-x-docs-usage-test--with-project (&rest body)
  "Run BODY with a temporary project as the current default directory."
  (declare (indent 0))
  `(let ((dir (make-temp-file "docs-usage-test" t)))
     (unwind-protect
         (progn
           (make-directory (expand-file-name ".git" dir))
           (make-directory (expand-file-name "a" dir))
           (make-directory (expand-file-name "b" dir))
           (with-temp-file (expand-file-name "a/x.ts" dir)
             (insert "const ids = rows.map((r) => r.id);\n"
                     "items.map(f)\n"))
           (with-temp-file (expand-file-name "b/y.ts" dir)
             (insert "list.map(g)\n"))
           (let ((default-directory dir))
             ,@body))
       (delete-directory dir t))))

(ert-deftest mr-x-docs-usage-test-search ()
  (skip-unless (executable-find "rg"))
  (mr-x-docs-usage-test--with-project
    (let ((result (mr-x/docs-usage-search "\\.map\\(" default-directory)))
      (should (= (plist-get result :count) 3))
      (should (= (plist-get result :files) 2))
      (should (equal (car (plist-get result :hits))
                     '("a/x.ts" 1 "const ids = rows.map((r) => r.id);")))
       (should (equal (plist-get (mr-x/docs-usage-search "no-such-call" default-directory)
                      :count)
                     0)))))

(ert-deftest mr-x-docs-usage-test-root-without-project ()
  (let ((dir (make-temp-file "docs-usage-no-project" t)))
    (unwind-protect
        (let ((default-directory dir))
          (should (null (mr-x/docs-usage-root))))
      (delete-directory dir t))))
