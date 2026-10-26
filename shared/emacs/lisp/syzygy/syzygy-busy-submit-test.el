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

(defun syzygy-busy-submit-test--notification (kind)
  "Return a minimal ACP notification whose update has KIND."
  `((method . "session/update")
    (params . ((update . ((sessionUpdate . ,kind)
                          (content . ((text . "phone prompt")))))))))

(defun syzygy-busy-submit-test--state (buffer)
  "Return a mutable agent-shell state for BUFFER."
  (let ((state (make-hash-table :test #'eq)))
    (puthash :buffer buffer state)
    state))

(ert-deftest syzygy-live-idle-session-info-does-not-arm-submit-guard ()
  "An unconditional last-rx update must make this test fail."
  (with-temp-buffer
    (let ((state (syzygy-busy-submit-test--state (current-buffer))))
      (setq-local syzygy-live-mode t)
      (setq-local syzygy-live--last-rx nil)
      (setq-local syzygy-live--remote-turn-active nil)
      (cl-letf (((symbol-function 'agent-shell--active-requests-p)
                 (lambda (_) nil)))
        (syzygy-live--on-notification
         (lambda (&rest _) :passed)
         :state state
         :acp-notification
         (syzygy-busy-submit-test--notification "session_info_update")))
      (should-not syzygy-live--last-rx))))

(ert-deftest syzygy-live-out-of-turn-user-chunk-arms-submit-guard ()
  "A phone prompt must timestamp the live submit guard."
  (with-temp-buffer
    (let ((state (syzygy-busy-submit-test--state (current-buffer))))
      (setq-local syzygy-live-mode t)
      (setq-local syzygy-live--last-rx nil)
      (setq-local syzygy-live--remote-turn-active nil)
      (cl-letf (((symbol-function 'agent-shell--active-requests-p)
                 (lambda (_) nil))
                ((symbol-function 'agent-shell--update-fragment)
                 (lambda (&rest _) nil))
                ((symbol-function 'syzygy-live--apply-phone-bar)
                 (lambda (&rest _) nil))
                ((symbol-function 'syzygy-live--sync-prompt-mark)
                 (lambda () nil)))
        (syzygy-live--on-notification
         (lambda (&rest _) :passed)
         :state state
         :acp-notification
         (syzygy-busy-submit-test--notification "user_message_chunk")))
      (should (numberp syzygy-live--last-rx)))))

(ert-deftest syzygy-live-active-remote-turn-chunk-arms-submit-guard ()
  "Any update during a known phone turn must refresh the guard timestamp."
  (with-temp-buffer
    (let ((state (syzygy-busy-submit-test--state (current-buffer))))
      (setq-local syzygy-live-mode t)
      (setq-local syzygy-live--last-rx nil)
      (setq-local syzygy-live--remote-turn-active t)
      (cl-letf (((symbol-function 'agent-shell--active-requests-p)
                 (lambda (_) nil)))
        (syzygy-live--on-notification
         (lambda (&rest _) :passed)
         :state state
         :acp-notification
         (syzygy-busy-submit-test--notification "session_info_update")))
      (should (numberp syzygy-live--last-rx)))))

(provide 'syzygy-busy-submit-test)
;;; syzygy-busy-submit-test.el ends here
