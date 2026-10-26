;;; run-syzygy-tests.el --- Batch bootstrap for the SYZYGY test runners -*- lexical-binding: t; -*-

;;; Commentary:

;; Loaded by run-syzygy-tests.sh and run-syzygy-tests.ps1 right after the -L
;; flags.  The setup lives here, not in --eval arguments, because Windows
;; PowerShell 5.1 strips embedded double quotes when passing arguments to a
;; native program, so a Lisp string in an --eval form reaches Emacs unquoted.
;;
;; The state directory is bound to a fresh temporary directory before any test
;; file loads, so a batch run can never touch the real ~/.acp-mobile sidecars.

;;; Code:

(require 'package)

(when (eq system-type 'windows-nt)
  ;; agent-recall comes from package.el on Windows.
  (setq package-user-dir (expand-file-name ".emacs.d/elpa" (getenv "APPDATA")))
  (package-initialize))

(require 'syzygy-state)
(setq syzygy-state-directory
      (file-name-as-directory (make-temp-file "syzygy-tests-" t)))

;;; run-syzygy-tests.el ends here
