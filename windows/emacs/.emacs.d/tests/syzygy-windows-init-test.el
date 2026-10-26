;;; syzygy-windows-init-test.el --- Windows init loads SYZYGY  -*- lexical-binding: t; -*-

;; Load after windows/emacs/.emacs.d/init.el (see windows/README.md):
;; the init must have required `syzygy' from the shared tree.

;;; Code:

(require 'ert)

(ert-deftest syzygy-windows-init-loads-syzygy ()
  (should (featurep 'syzygy))
  (should (featurep 'syzygy-rig))
  (should (string-match-p "shared/emacs/lisp/syzygy"
                          (or (locate-library "syzygy") ""))))

(provide 'syzygy-windows-init-test)
;;; syzygy-windows-init-test.el ends here
