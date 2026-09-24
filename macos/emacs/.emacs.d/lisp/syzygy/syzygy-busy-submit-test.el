;;; syzygy-busy-submit-test.el --- Busy submit guard contract -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)

(defvar syzygy-busy-submit-test--calls nil)

(cl-defun agent-shell--busy-submit (&key prompt override)
  "Record a busy submit without invoking an ACP client."
  (push (list :prompt prompt :override override)
        syzygy-busy-submit-test--calls)
  :submitted)

(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'syzygy-resync)
(require 'syzygy-live)

(ert-deftest syzygy-busy-submit-resync-lock-blocks-router ()
  "Removing the busy-submit resync advice must let this test fail."
  (with-temp-buffer
    (let ((syzygy-busy-submit-test--calls nil))
      (setq-local syzygy-resync--behind 1)
      (setq-local syzygy-live-mode nil)
      (should-error (agent-shell--busy-submit :prompt "locked")
                    :type 'user-error)
      (should-not syzygy-busy-submit-test--calls))))

(ert-deftest syzygy-busy-submit-resync-unlocked-forwards-keywords ()
  "The resync advice must preserve the router's keyword arguments."
  (with-temp-buffer
    (let ((syzygy-busy-submit-test--calls nil))
      (setq-local syzygy-resync--behind 0)
      (setq-local syzygy-live-mode nil)
      (should (eq (agent-shell--busy-submit :prompt "ready" :override t)
                  :submitted))
      (should (equal syzygy-busy-submit-test--calls
                     '((:prompt "ready" :override t)))))))

(ert-deftest syzygy-busy-submit-live-stream-blocks-router ()
  "Removing the busy-submit live advice must let this test fail."
  (with-temp-buffer
    (let ((syzygy-busy-submit-test--calls nil))
      (setq-local syzygy-resync--behind 0)
      (setq-local syzygy-live-mode t)
      (setq-local syzygy-live--last-rx (float-time))
      (should-error (agent-shell--busy-submit :prompt "overlap")
                    :type 'user-error)
      (should-not syzygy-busy-submit-test--calls))))

(ert-deftest syzygy-busy-submit-live-idle-forwards-prompt ()
  "The live advice must pass a prompt after the streaming guard expires."
  (with-temp-buffer
    (let ((syzygy-busy-submit-test--calls nil))
      (setq-local syzygy-resync--behind 0)
      (setq-local syzygy-live-mode t)
      (setq-local syzygy-live--last-rx (- (float-time) 3.0))
      (should (eq (agent-shell--busy-submit :prompt "after-stream")
                  :submitted))
      (should (equal syzygy-busy-submit-test--calls
                     '((:prompt "after-stream" :override nil)))))))

(provide 'syzygy-busy-submit-test)
;;; syzygy-busy-submit-test.el ends here
