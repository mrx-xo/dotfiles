;;; major-pane-exclusion-test.el --- Background session regression -*- lexical-binding: t; -*-

(require 'ert)
(require 'face-remap)
(require 'major-pane)

(ert-deftest major-pane-exclusion-removes-already-registered-session ()
  "Quick Ask is excluded after its mode hook has registered its buffer."
  (let* ((major-pane--state (major-pane--make-state))
         (major-pane--labels (make-hash-table :test #'eq))
         (major-pane--anchored nil)
         (major-pane-modes '(fundamental-mode))
         (chat (generate-new-buffer " *exclusion-chat*"))
         (background (generate-new-buffer " *exclusion-background*")))
    (unwind-protect
        (progn
          (major-pane--register-conversation chat)
          (major-pane--register-conversation background)
          (setf (major-pane-state-active major-pane--state) background)
          (major-pane-exclude-buffer background)
          (should (equal (major-pane-state-conversations major-pane--state)
                         (list chat)))
          (should (eq (major-pane-state-active major-pane--state) chat))
          (should (buffer-live-p background))
          (should-not (major-pane--conversation-p background))
          (major-pane-exclude-buffer background)
          (should (equal (major-pane-state-conversations major-pane--state)
                         (list chat))))
      (kill-buffer chat)
      (kill-buffer background))))

;;; major-pane-exclusion-test.el ends here
