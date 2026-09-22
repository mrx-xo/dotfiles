;;; project-dashboard-art-test.el --- Project dashboard art tests -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Run with:
;;   emacs --batch -l ~/.emacs.d/init.el \
;;     -l ~/.emacs.d/tests/project-dashboard-art-test.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)

(when noninteractive
  (when (fboundp 'elpaca-process-queues)
    (elpaca-process-queues))
  (when (fboundp 'elpaca-wait)
    (elpaca-wait)))

(let* ((test-directory (file-name-directory (or load-file-name buffer-file-name)))
       (dashboard-directory
        (expand-file-name "../lisp/project-dashboard" test-directory)))
  (add-to-list 'load-path dashboard-directory))

(require 'project-dashboard)

(load (expand-file-name
       "../lisp/project-dashboard/project-dashboard-art.el"
       (file-name-directory (or load-file-name buffer-file-name)))
      nil nil t)

(defmacro project-dashboard-art-test--with-cache (&rest body)
  "Run BODY with an isolated temporary art cache."
  (declare (indent 0) (debug t))
  `(let* ((temporary-directory (make-temp-file "project-dashboard-art-test-" t))
          (project-dashboard-art-cache-directory temporary-directory)
          (project-dashboard-art--next-backend nil)
          (project-dashboard-art--in-flight (make-hash-table :test #'equal)))
     (unwind-protect
         (progn ,@body)
       (delete-directory temporary-directory t))))

(ert-deftest project-dashboard-art-test-normalizer ()
  "Normalizer should enforce fences, dimensions, and the character set."
  (should
   (equal (project-dashboard-art-normalize
           "```text\n#@\n=-+*%@x\n: bad\n::\nextra\n```\n" 6 4)
          '("#@    " "=-+*%@" ": ... " "::    ")))
  (should
   (equal (project-dashboard-art-normalize "." 3 3)
          '(".  " "   " "   "))))

(ert-deftest project-dashboard-art-test-cache-round-trip-and-miss ()
  "Cache writes should round-trip and absent projects should miss."
  (project-dashboard-art-test--with-cache
    (should-not (project-dashboard-art-cache-read "missing"))
    (let ((art '("..  " "####")))
      (project-dashboard-art--cache-write "sample/project" art)
      (should (equal (project-dashboard-art-cache-read "sample/project") art)))))

(ert-deftest project-dashboard-art-test-backend-alternation-persists ()
  "Successful generations should alternate and persist backend state."
  (project-dashboard-art-test--with-cache
    (let (used)
      (cl-letf (((symbol-function 'project-dashboard-art--run-backend)
                 (lambda (backend _prompt callback)
                   (setq used backend)
                   (funcall callback "."))))
        (should (project-dashboard-art-generate "sample"))
        (should (eq used 'codex))
        (should (eq project-dashboard-art--next-backend 'claude))))
    (setq project-dashboard-art--next-backend nil)
    (should (eq (project-dashboard-art--load-state) 'claude))))

(ert-deftest project-dashboard-art-test-falls-back-after-both-backends-fail ()
  "Both backend failures should return collection art and leave no cache."
  (project-dashboard-art-test--with-cache
    (let (backends result)
      (cl-letf (((symbol-function 'project-dashboard-art--run-backend)
                 (lambda (backend _prompt callback)
                   (push backend backends)
                   (funcall callback nil)))
                ((symbol-function 'project-dashboard-art-random)
                 (lambda () project-dashboard-art-cat)))
        (should (project-dashboard-art-generate
                 "failure" (lambda (art) (setq result art))))
        (should (equal (nreverse backends) '(codex claude)))
        (should (equal result project-dashboard-art-cat))
        (should-not (project-dashboard-art-cache-read "failure"))))))

(ert-deftest project-dashboard-art-test-random-varies ()
  "Random selection should return more than one collection entry."
  (let (indices)
    (dotimes (_ 200)
      (push (cl-position (project-dashboard-art-random)
                         project-dashboard-art-collection
                         :test #'eq)
            indices))
    (should (> (length (delete-dups indices)) 1))))

(provide 'project-dashboard-art-test)
;;; project-dashboard-art-test.el ends here
