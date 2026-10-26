;;; syzygy-mermaid-test.el --- Tests for syzygy-mermaid -*- lexical-binding: t; -*-

(require 'ert)
(require 'json)
(require 'cl-lib)

(let ((dir (file-name-directory (or load-file-name buffer-file-name))))
  (load (expand-file-name "syzygy-mermaid.el" dir) nil t))

(defmacro syzygy-mermaid-test--with-config (config &rest body)
  "Run BODY with `mr-x/markdown-mermaid-config' returning CONFIG.
The export file is redirected into a temporary directory."
  (declare (indent 1))
  `(let* ((dir (make-temp-file "syzygy-mermaid-test" t))
          (syzygy-mermaid-config-file (expand-file-name "mermaid.json" dir)))
     (unwind-protect
         (cl-letf (((symbol-function 'mr-x/markdown-mermaid-config)
                    (lambda () ,config)))
           ,@body)
       (delete-directory dir t))))

(defun syzygy-mermaid-test--read (file)
  (json-parse-string
   (with-temp-buffer (insert-file-contents file) (buffer-string))
   :object-type 'alist :array-type 'list))

(ert-deftest syzygy-mermaid-export-writes-the-rig-config ()
  (syzygy-mermaid-test--with-config
      '((theme . "base") (themeVariables . ((fontFamily . "Iosevka"))))
    (let ((file (syzygy-export-mermaid-config)))
      (should (equal file syzygy-mermaid-config-file))
      (let ((got (syzygy-mermaid-test--read file)))
        (should (equal (alist-get 'theme got) "base"))
        (should (equal (alist-get 'fontFamily (alist-get 'themeVariables got))
                       "Iosevka"))))))

(ert-deftest syzygy-mermaid-export-drops-start-on-load ()
  ;; The phone renders each block explicitly from `renderDiagrams'; a
  ;; startOnLoad scan would double-render and fight the cache.
  (syzygy-mermaid-test--with-config
      '((theme . "base") (startOnLoad . t))
    (let ((got (syzygy-mermaid-test--read (syzygy-export-mermaid-config))))
      (should-not (assq 'startOnLoad got)))))

(ert-deftest syzygy-mermaid-export-rewrites-only-on-change ()
  (syzygy-mermaid-test--with-config
      '((theme . "base"))
    (let* ((file (syzygy-export-mermaid-config))
           (stamp (file-attribute-modification-time (file-attributes file))))
      (syzygy-export-mermaid-config)
      (should (equal stamp (file-attribute-modification-time
                            (file-attributes file)))))))

(ert-deftest syzygy-mermaid-export-is-nil-without-the-rig-config ()
  ;; markdown-xwidget is lazy; the phone falls back to its built-in
  ;; defaults rather than getting a half-written file.
  (let* ((dir (make-temp-file "syzygy-mermaid-test" t))
         (syzygy-mermaid-config-file (expand-file-name "mermaid.json" dir)))
    (unwind-protect
        (cl-letf (((symbol-function 'mr-x/markdown-mermaid-config) nil))
          (should-not (syzygy-export-mermaid-config))
          (should-not (file-exists-p syzygy-mermaid-config-file)))
      (delete-directory dir t))))

(provide 'syzygy-mermaid-test)
;;; syzygy-mermaid-test.el ends here
