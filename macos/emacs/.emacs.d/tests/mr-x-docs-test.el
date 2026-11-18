;;; mr-x-docs-test.el --- Tests for mr-x-docs -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(add-to-list 'load-path (expand-file-name "../lisp" (file-name-directory
                                                     (or load-file-name buffer-file-name))))
(require 'mr-x-docs)

(defmacro mr-x-docs-test--with-data (&rest body)
  "Run BODY with `mr-x/docs-data-dir' pointing at a temp tree holding one docset."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "docs-test" t))
          (mr-x/docs-data-dir (file-name-as-directory dir))
          (mr-x/docs--cache nil))
     (make-directory (expand-file-name "fake" dir))
     (with-temp-file (expand-file-name "fake/metadata" dir)
       (prin1 '((name . "Fake") (slug . "fake") (type . "mdn")) (current-buffer)))
     (with-temp-file (expand-file-name "fake/index" dir)
       (prin1 '((pages . ["a" "b/c"])
                (entries . [((name . "alpha") (path . "a") (type . "T"))
                            ((name . "beta.c()") (path . "b/c#c") (type . "T"))]))
              (current-buffer)))
     (unwind-protect (progn ,@body) (delete-directory dir t))))

(ert-deftest mr-x-docs-test-docsets ()
  (mr-x-docs-test--with-data
    (should (equal (mr-x/docs--docsets) '(("fake" . "mdn"))))))

(ert-deftest mr-x-docs-test-entries-split-anchor ()
  (mr-x-docs-test--with-data
    (let ((e (seq-find (lambda (e) (equal (plist-get e :name) "beta.c()"))
                       (mr-x/docs--entries))))
      (should (equal (plist-get e :path) "b/c"))
      (should (equal (plist-get e :anchor) "c"))
      (should (equal (plist-get e :slug) "fake"))
      (should (null (plist-get (seq-find (lambda (e) (equal (plist-get e :name) "alpha"))
                                          (mr-x/docs--entries))
                               :anchor))))))

(provide 'mr-x-docs-test)
;;; mr-x-docs-test.el ends here
