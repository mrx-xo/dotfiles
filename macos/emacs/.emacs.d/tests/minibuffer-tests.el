;;; minibuffer-tests.el --- Shared picker behavior tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)

;; On the Mac, Elpaca has not activated packages yet when this file is loaded
;; in batch after init.el; flush its queue first.  No-op under package.el.
(when (fboundp 'elpaca-process-queues)
  (elpaca-process-queues))
(when (fboundp 'elpaca-wait)
  (elpaca-wait))

(require 'consult)
(require 'vertico)
(require 'mr-x-minibuffer)

(defun mr-x/minibuffer-test--enter (input candidates base category &optional prefix)
  "Return (CONTENTS EXITED) after Enter with a controlled picker selection.
Use real Vertico insertion/acceptance; replace only minibuffer IO so the
test runs in batch without opening a window on either platform."
  (with-temp-buffer
    (insert input)
    (let ((vertico--index 0)
          (vertico--total (length candidates))
          (vertico--candidates candidates)
          (vertico--base base)
          (vertico--input (list input))
          (vertico--metadata `(metadata (category . ,category)))
          (minibuffer--require-match nil)
          (current-prefix-arg prefix)
          exited)
      (cl-letf (((symbol-function 'minibuffer-contents-no-properties) #'buffer-string)
                ((symbol-function 'delete-minibuffer-contents) #'erase-buffer)
                ((symbol-function 'exit-minibuffer) (lambda () (setq exited t))))
        (call-interactively (lookup-key vertico-map (kbd "RET"))))
      (list (buffer-string) exited))))

(ert-deftest mr-x/minibuffer-enter-accepts-highlighted-result ()
  "Command and search pickers return the selection, not partial input."
  (dolist (category '(command consult-location))
    (should (equal (mr-x/minibuffer-test--enter
                    "find" '("find-file") "" category)
                   '("find-file" t)))))

(ert-deftest mr-x/minibuffer-enter-descends-into-directory ()
  "Enter fills a directory without dismissing the file picker."
  (dolist (base '("/tmp/" "C:/Users/example/"))
    (should (equal (mr-x/minibuffer-test--enter
                    (concat base "pro") '("projects/") base 'file)
                   (list (concat base "projects/") nil)))))

(ert-deftest mr-x/minibuffer-enter-accepts-file ()
  "Enter accepts a selected file on both path styles."
  (dolist (base '("/tmp/" "C:/Users/example/"))
    (should (equal (mr-x/minibuffer-test--enter
                    (concat base "ini") '("init.el") base 'file)
                   (list (concat base "init.el") t)))))

(ert-deftest mr-x/minibuffer-prefix-enter-keeps-raw-input ()
  "The explicit raw-input escape hatch stays available."
  (should (equal (mr-x/minibuffer-test--enter
                  "new-name" '("existing-name") "" 'file '(4))
                 '("new-name" t))))

(ert-deftest mr-x/minibuffer-search-removes-prefill-preserves-explicit-input ()
  "Live migration removes prefill without losing history or caller input."
  (let ((consult--customize-alist
         '((consult-line :initial (thing-at-point 'symbol) :preview-key 'any)))
        (this-command 'consult-line))
    (mr-x/minibuffer-configure-consult)
    (mr-x/minibuffer-configure-consult)
    (with-temp-buffer
      (emacs-lisp-mode)
      (insert "symbol-at-point")
      (let ((plain (consult--customize-args nil))
            (explicit (consult--customize-args '(:initial "deliberate"))))
        (should-not (plist-member plain :initial))
        (should (equal (plist-get plain :add-history) "symbol-at-point"))
        (should (eq (plist-get plain :preview-key) 'any))
        (should (equal (plist-get explicit :initial) "deliberate"))))))

;;; minibuffer-tests.el ends here
