;;; minibuffer-message-guard-test.el --- Prompt message regression checks -*- lexical-binding: t; -*-

(require 'ert)
(require 'seq)
(require 'minibuffer-message-guard)
(require 'mr-x-bookmark-popup nil t)

(defmacro minibuffer-message-guard-test--with-gui (&rest body)
  "Run BODY in an ordinary GUI frame with visible messages enabled."
  `(let ((frame (seq-find
                 (lambda (f) (and (display-graphic-p f)
                                  (not (frame-parameter f 'parent-frame))
                                  (not (eq (frame-parameter f 'minibuffer) 'only))))
                 (frame-list)))
         (inhibit-message nil))
     (skip-unless frame)
     (with-selected-frame frame
       (save-window-excursion ,@body))))

(ert-deftest minibuffer-message-guard-keeps-background-message-out-of-input ()
  "A timer message stays logged without appearing alongside typed input."
  (minibuffer-message-guard-test--with-gui
   (let ((text "[agent-shell] Prompt guard fixture: Finished")
         input overlay)
     (should
      (equal
       "home-lab"
       (minibuffer-with-setup-hook
           (lambda ()
             (insert "home-lab")
             (run-at-time
              0 nil
              (lambda ()
                (with-temp-buffer (message "%s" text))
                (setq input (minibuffer-contents-no-properties)
                      overlay (and (overlayp minibuffer-message-overlay)
                                   (overlay-buffer minibuffer-message-overlay)
                                   (overlay-get minibuffer-message-overlay 'after-string)))
                (exit-minibuffer))))
         (read-from-minibuffer "Bookmark: "))))
     (should (equal input "home-lab"))
     (should-not overlay)
     (with-current-buffer "*Messages*"
       (should (save-excursion (goto-char (point-max)) (search-backward text nil t)))))))

(ert-deftest minibuffer-message-guard-allows-messages-before-and-after-cancel ()
  "An idle minibuffer is not active, and cancelling cannot mute messages."
  (minibuffer-message-guard-test--with-gui
   (message "Prompt guard: before input")
   (should (equal (current-message) "Prompt guard: before input"))
   (condition-case nil
       (minibuffer-with-setup-hook
           (lambda () (run-at-time 0 nil #'abort-recursive-edit))
         (read-from-minibuffer "Cancel fixture: "))
     (quit nil))
   (message "Prompt guard: after cancellation")
   (should (equal (current-message) "Prompt guard: after cancellation"))))

(ert-deftest minibuffer-message-guard-protects-bookmark-popup ()
  "Notifications cannot add inline text to the minibuffer-only picker."
  (minibuffer-message-guard-test--with-gui
   (skip-unless (fboundp 'mr-x/bookmark-popup))
   (let ((bookmark-alist '(("Example" (filename . "/tmp/example")))))
     (let (overlay minibuffer-only)
       (should
        (eq 'cancelled
            (minibuffer-with-setup-hook
                (lambda ()
                  (run-at-time
                   0 nil
                   (lambda ()
                     (setq minibuffer-only
                           (eq (frame-parameter nil 'minibuffer) 'only))
                     (with-temp-buffer
                       (message "[agent-shell] Popup fixture: Finished"))
                     (setq overlay
                           (and (overlayp minibuffer-message-overlay)
                                (overlay-buffer minibuffer-message-overlay)
                                (overlay-get minibuffer-message-overlay 'after-string)))
                     (abort-recursive-edit))))
              (mr-x/bookmark-popup))))
       (should minibuffer-only)
       (should-not overlay)))))

(provide 'minibuffer-message-guard-test)
