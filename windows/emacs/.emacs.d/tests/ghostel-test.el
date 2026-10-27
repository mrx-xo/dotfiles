;;; ghostel-test.el --- Windows ghostel wiring tests -*- lexical-binding: t; -*-

;; Load the Windows init with its installed packages before this file.
;; These tests check the config, not the native module: no terminal is
;; spawned, so they pass without the DLL downloaded.

(require 'ert)
(require 'cl-lib)
(require 'ghostel)
(require 'evil)

(ert-deftest windows-ghostel-shell-is-powershell ()
  "The shell is set explicitly: $SHELL under this Emacs is cmdproxy.exe."
  (should (listp ghostel-shell))
  (should (string-match-p "powershell\\.exe\\'" (car ghostel-shell)))
  (should (file-executable-p (car ghostel-shell))))

(ert-deftest windows-ghostel-module-lives-outside-elpa ()
  "A loaded DLL cannot be deleted, so the module must not sit in elpa/."
  (should ghostel-module-directory)
  (should-not (string-prefix-p (file-truename package-user-dir)
                               (file-truename ghostel-module-directory))))

(ert-deftest windows-ghostel-popup-displays-in-bottom-side-window ()
  "The SPC v v popup has its own display rule; plain ghostel buffers do not."
  ;; Conditions can be predicates too (the agent pane uses one), so only
  ;; match the string ones.
  (cl-flet ((rule-for (name)
              (seq-find (lambda (entry)
                          (and (stringp (car entry))
                               (string-match-p (car entry) name)))
                        display-buffer-alist)))
    (let ((rule (rule-for mr-x/ghostel-popup-name)))
      (should rule)
      (should (memq 'display-buffer-in-side-window (ensure-list (cadr rule))))
      (should (eq (alist-get 'side (cddr rule)) 'bottom)))
    (should-not (rule-for "*ghostel*"))))

(ert-deftest windows-ghostel-leader-keys ()
  "SPC v mirrors the Mac vterm group with ghostel in vterm's seat."
  (with-temp-buffer
    (delay-mode-hooks (fundamental-mode))
    (evil-local-mode 1)
    (evil-normal-state)
    (pcase-dolist (`(,key . ,cmd)
                   '(("SPC v v" . mr-x/ghostel-popup)
                     ("SPC v b" . ghostel)
                     ("SPC v n" . ghostel-new)
                     ("SPC v d" . mr-x/ghostel-in-dir)
                     ("SPC v e" . mr-x/eshell-popup)
                     ("SPC v E" . eshell)
                     ("SPC v V" . mr-x/windows-terminal-here)))
      (ert-info ((format "%s" key))
        (should (eq (key-binding (kbd key)) cmd))))))

(ert-deftest windows-ghostel-evil-and-eshell-hooks ()
  "evil-ghostel rides ghostel-mode; eshell visual commands go to ghostel."
  (should (memq 'evil-ghostel-mode ghostel-mode-hook))
  (should (memq 'ghostel-eshell-visual-command-mode eshell-load-hook)))

;;; ghostel-test.el ends here
