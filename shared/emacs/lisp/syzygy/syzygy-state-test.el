;;; syzygy-state-test.el --- Tests for syzygy-state -*- lexical-binding: t; -*-

;;; Commentary:
;; Run with: emacs --batch -L . -l syzygy-state-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'seq)
(require 'syzygy-state)

(ert-deftest syzygy-state-dir-mac ()
  (let ((system-type 'darwin) (syzygy-state-directory nil))
    (should (equal (syzygy-state-dir) (expand-file-name "~/.acp-mobile/")))))

(ert-deftest syzygy-state-dir-windows-uses-userprofile ()
  (let* ((system-type 'windows-nt) (syzygy-state-directory nil)
         (profile (expand-file-name "profile" temporary-file-directory))
         (process-environment (cons (concat "USERPROFILE=" profile) process-environment)))
    (should (equal (syzygy-state-dir) (expand-file-name ".acp-mobile/" profile)))))

(ert-deftest syzygy-state-dir-windows-without-userprofile ()
  (let ((system-type 'windows-nt) (syzygy-state-directory nil)
        (process-environment (seq-remove (lambda (e) (string-prefix-p "USERPROFILE=" e))
                                         process-environment)))
    (should (file-name-absolute-p (syzygy-state-dir)))
    (should (string-suffix-p ".acp-mobile/" (syzygy-state-dir)))))

(ert-deftest syzygy-state-file-honours-override ()
  (let ((syzygy-state-directory (expand-file-name "syzygy-test/" temporary-file-directory)))
    (should (equal (syzygy-state-file "labels.json")
                   (expand-file-name "syzygy-test/labels.json" temporary-file-directory)))))

(provide 'syzygy-state-test)
;;; syzygy-state-test.el ends here
