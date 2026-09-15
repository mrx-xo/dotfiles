;;; mr-x-crash-diagnostics-test.el --- Run diagnostics tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'mr-x-crash-diagnostics)

(defmacro crash-diagnostics-test--fixture (&rest body)
  (declare (indent 0) (debug t))
  `(let* ((parent (file-truename (make-temp-file "diagnostics-test-" t)))
          (run (mr-x/crash-run-create parent "sandbox" "/tmp/fixture-init/")))
     (unwind-protect (progn ,@body) (delete-directory parent t))))

(ert-deftest crash-diagnostics-run-unique-private-and-incomplete ()
  (crash-diagnostics-test--fixture
   (let ((other (mr-x/crash-run-create parent "sandbox" "/tmp/fixture-init/")))
     (should-not (equal run other))
     (should-not (plist-get (mr-x/crash-run-metadata run) :pid))
     (should-not (mr-x/crash-run-clean-p run))
     (should (= #o700 (logand #o777 (file-modes run))))
     (should (= #o600 (logand #o777 (file-modes (expand-file-name "metadata.el" run))))))))

(ert-deftest crash-diagnostics-identity-attached-once ()
  (crash-diagnostics-test--fixture
   (let ((identity (mr-x/crash-run-initialized run 123)))
     (should (= 123 (plist-get identity :pid)))
     (should (equal identity (mr-x/crash-run-initialized run 123)))
     (should-error (mr-x/crash-run-initialized run 124))
     (should-error (mr-x/crash-run-mark-clean run (plist-put (copy-sequence identity) :pid 124)))
     (should-not (mr-x/crash-run-clean-p run))
     (mr-x/crash-run-mark-clean run identity)
     (should (mr-x/crash-run-clean-p run)))))

(ert-deftest crash-diagnostics-copied-empty-and-stale-markers-unclean ()
  (crash-diagnostics-test--fixture
   (let* ((identity (mr-x/crash-run-initialized run 123))
          (file (expand-file-name "clean-exit.el" run)))
     (dolist (marker (list nil '(:run-id "old" :pid 123 :exited-at 1)
                           (list :schema-version 1 :run-id (plist-get identity :run-id)
                                 :pid 123 :exited-at 1)))
       (mr-x/crash-capture--write file marker)
       (should-not (mr-x/crash-run-clean-p run)))
     (mr-x/crash-capture--write file "" t)
     (should-not (mr-x/crash-run-clean-p run)))))

(ert-deftest crash-diagnostics-clean-marker-requires-both-pid-and-run-id ()
  (crash-diagnostics-test--fixture
   (let* ((identity (mr-x/crash-run-initialized run 123))
          (id (plist-get identity :run-id))
          (file (expand-file-name "clean-exit.el" run)))
     (dolist (pair (list (cons id 124) (cons "other-run" 123)))
       (mr-x/crash-capture--write
        file (list :schema-version 1 :run-id (car pair) :pid (cdr pair)
                   :exited-at (float-time)))
       (should-not (mr-x/crash-run-clean-p run)))
     (mr-x/crash-run-mark-clean run identity)
     (should (mr-x/crash-run-clean-p run)))))

(ert-deftest crash-diagnostics-rejects-copied-metadata-and-symlink ()
  (crash-diagnostics-test--fixture
   (let ((other (mr-x/crash-run-create parent "sandbox" "/tmp/fixture-init/")))
     (copy-file (expand-file-name "metadata.el" other)
                (expand-file-name "metadata.el" run) t)
     (should-error (mr-x/crash-run-metadata run))
     (make-symbolic-link other (expand-file-name "alias" parent))
     (should-error (mr-x/crash-run-metadata (expand-file-name "alias" parent))))))

(ert-deftest crash-diagnostics-message-tail-byte-bound-and-utf8 ()
  (crash-diagnostics-test--fixture
   (mr-x/crash-diagnostics-messages run (make-string 100000 ?界))
   (let* ((file (expand-file-name "recent-messages.log" run))
          (text (mr-x/crash-capture--text file)))
     (should (<= (file-attribute-size (file-attributes file)) (* 256 1024)))
     (should (string-match-p "truncated" text))
     (should (string-suffix-p "界" text))
     (should-not (string-match-p "�" text))
     (should (= #o600 (logand #o777 (file-modes file)))))))

(ert-deftest crash-diagnostics-rotation-retains-previous-and-bounds-record ()
  (crash-diagnostics-test--fixture
   (let ((mr-x/crash-diagnostics--log-limit 200)
         (mr-x/crash-diagnostics--record-limit 100))
     (dotimes (i 5)
       (mr-x/crash-diagnostics--append run (concat (number-to-string i) (make-string 120 ?界))))
     (dolist (name '("command-errors.log" "command-errors.log.1"))
       (let ((file (expand-file-name name run)))
         (should (<= (file-attribute-size (file-attributes file)) 200))
         (should (string-match-p "truncated" (mr-x/crash-capture--text file)))
         (should (= #o600 (logand #o777 (file-modes file)))))))))

(ert-deftest crash-diagnostics-wrapper-delegates-original-arguments-and-return ()
  (crash-diagnostics-test--fixture
   (let* (calls
          (wrapper (mr-x/crash-diagnostics-wrapper
                    run (lambda (&rest args) (push args calls) 'original-result))))
     (should (eq 'original-result (funcall wrapper '(error "fixture") "context" 'fixture-command)))
     (should (equal calls '(((error "fixture") "context" fixture-command))))
     (let ((text (mr-x/crash-capture--text (expand-file-name "command-errors.log" run))))
       (dolist (word '("fixture" "context" "fixture-command" ":this-command" ":buffer" ":frame"))
         (should (string-match-p word text)))))))

(ert-deftest crash-diagnostics-logging-error-and-quit-never-block-delegate ()
  (crash-diagnostics-test--fixture
   (dolist (failure '(error quit))
     (let* ((calls 0)
            (wrapper (mr-x/crash-diagnostics-wrapper run (lambda (&rest _) (cl-incf calls)))))
       (cl-letf (((symbol-function 'mr-x/crash-diagnostics--append)
                  (lambda (&rest _) (signal failure '("fixture")))))
         (funcall wrapper '(error "original") "" 'fixture))
       (should (= 1 calls))))))

(ert-deftest crash-diagnostics-delegate-error-is-not-swallowed-or-retried ()
  (crash-diagnostics-test--fixture
   (let* ((calls 0)
          (wrapper (mr-x/crash-diagnostics-wrapper
                    run (lambda (&rest _) (cl-incf calls) (signal 'file-error '("original"))))))
     (should (equal (should-error (funcall wrapper '(error "fixture") "" 'fixture))
                    '(file-error "original")))
     (should (= 1 calls)))))

(ert-deftest crash-diagnostics-refuses-symlink-log-target ()
  (crash-diagnostics-test--fixture
   (let ((outside (expand-file-name "outside" parent)))
     (mr-x/crash-capture--write outside "untouched" t)
     (make-symbolic-link outside (expand-file-name "command-errors.log" run))
     (should-error (mr-x/crash-diagnostics--append run "new"))
     (should (equal "untouched" (mr-x/crash-capture--text outside))))))

(ert-deftest crash-diagnostics-failed-pid-write-preserves-early-start-evidence ()
  (crash-diagnostics-test--fixture
   (cl-letf (((symbol-function 'rename-file) (lambda (&rest _) (error "disk failure"))))
     (should-error (mr-x/crash-run-initialized run 123)))
   (should-not (plist-get (mr-x/crash-run-metadata run) :pid))
   (should-not (mr-x/crash-run-clean-p run))
   (should-not (directory-files run nil "\\`\\.write-"))))

(ert-deftest crash-diagnostics-interrupted-rotation-preserves-last-log ()
  (crash-diagnostics-test--fixture
   (let ((mr-x/crash-diagnostics--log-limit 100)
         (mr-x/crash-diagnostics--record-limit 100)
         (rename (symbol-function 'rename-file)))
     (mr-x/crash-diagnostics--append run (make-string 80 ?a))
     (cl-letf (((symbol-function 'rename-file)
                (lambda (from to &optional overwrite)
                  (if (string-suffix-p "/command-errors.log" to)
                      (error "interrupted")
                    (funcall rename from to overwrite)))))
       (should-error (mr-x/crash-diagnostics--append run (make-string 80 ?b))))
     (dolist (name '("command-errors.log" "command-errors.log.1"))
       (should (equal (make-string 80 ?a)
                      (mr-x/crash-capture--text (expand-file-name name run)))))
     (mr-x/crash-diagnostics--append run (make-string 80 ?b))
     (should (equal (make-string 80 ?b)
                    (mr-x/crash-capture--text (expand-file-name "command-errors.log" run)))))))

(ert-deftest crash-diagnostics-wrapper-guards-reentrant-logging ()
  (crash-diagnostics-test--fixture
   (let* ((calls 0) (writes 0)
          (wrapper (mr-x/crash-diagnostics-wrapper run (lambda (&rest _) (cl-incf calls)))))
     (cl-letf (((symbol-function 'mr-x/crash-diagnostics--append)
                (lambda (&rest _)
                  (cl-incf writes)
                  (funcall wrapper '(error "nested") "" 'nested))))
       (funcall wrapper '(error "outer") "" 'outer))
     (should (= 1 writes))
     (should (= 2 calls)))))

(ert-deftest crash-diagnostics-load-is-inert ()
  (let ((handler command-error-function)
        (startup emacs-startup-hook)
        (shutdown kill-emacs-hook))
    (cl-letf (((symbol-function 'write-region) (lambda (&rest _) (ert-fail "load wrote a file")))
              ((symbol-function 'make-directory) (lambda (&rest _) (ert-fail "load made a directory"))))
      (let ((timers (copy-sequence timer-list))
            (idle (copy-sequence timer-idle-list)))
        (load "mr-x-crash-diagnostics" nil t)
        (should (equal timers timer-list))
        (should (equal idle timer-idle-list))))
    (should (eq handler command-error-function))
    (should (equal startup emacs-startup-hook))
    (should (equal shutdown kill-emacs-hook))))

(ert-deftest crash-diagnostics-large-error-retains-context-and-message-tail ()
  (crash-diagnostics-test--fixture
   (let* ((messages (get-buffer-create "*Messages*"))
          (wrapper (mr-x/crash-diagnostics-wrapper run (lambda (&rest _) nil))))
     (with-current-buffer messages
       (let ((inhibit-read-only t)) (goto-char (point-max)) (insert "diagnostic-tail-fixture\n")))
     (funcall wrapper (list 'error (make-string 100000 ?x)) "context-fixture" 'function-fixture)
     (let* ((file (expand-file-name "command-errors.log" run))
            (text (mr-x/crash-capture--text file)))
       (should (<= (file-attribute-size (file-attributes file)) (* 64 1024)))
       (should (string-match-p "context-fixture" text))
       (should (string-match-p "function-fixture" text))
       (should (string-match-p "diagnostic-tail-fixture" text))))))

(provide 'mr-x-crash-diagnostics-test)
;;; mr-x-crash-diagnostics-test.el ends here
