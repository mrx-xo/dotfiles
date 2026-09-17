;;; bookmark-popup-test.el --- GUI lifecycle checks -*- lexical-binding: t; -*-

(require 'ert)
(require 'bookmark)
(require 'mr-x-bookmark-popup nil t)

(defmacro bookmark-popup-test--with-gui (&rest body)
  "Run BODY in an existing GUI frame and restore its windows."
  `(let ((frame (seq-find #'display-graphic-p (frame-list))))
     (skip-unless frame)
     (with-selected-frame frame
       (save-window-excursion ,@body))))

(ert-deftest bookmark-popup-cancel-preserves-existing-frames ()
  "Cancelling must delete the picker, never an existing Emacs frame."
  (bookmark-popup-test--with-gui
   (let ((before (frame-list))
         (bookmark-alist '(("Example" (filename . "/tmp/example")))))
     (should
      (eq 'cancelled
          (minibuffer-with-setup-hook
              (lambda () (run-at-time 0 nil #'abort-recursive-edit))
            (mr-x/bookmark-popup))))
     (should (equal before (frame-list)))
     (should-not (frame-live-p mr-x/bookmark-popup-frame)))))

(ert-deftest bookmark-popup-error-cleans-up-picker ()
  "A completion failure must not leave a stranded popup or busy flag."
  (bookmark-popup-test--with-gui
   (let ((before (frame-list))
         (bookmark-alist '(("Example" (filename . "/tmp/example")))))
     (should-error
      (minibuffer-with-setup-hook
          (lambda () (error "Completion setup failed"))
        (mr-x/bookmark-popup)))
     (should (equal before (frame-list)))
     (should-not (frame-live-p mr-x/bookmark-popup-frame)))))

(ert-deftest bookmark-popup-file-opens-after-picker-closes ()
  "A file selection must survive closing the temporary picker frame."
  (bookmark-popup-test--with-gui
   (let* ((file (make-temp-file "bookmark-popup-" nil ".txt" "Bookmark test\n"))
          (bookmark-alist `(("Popup fixture" (filename . ,file) (position . 1))))
          (bookmark-save-flag nil)
          (bookmark-history nil)
          (before (frame-list)))
     (unwind-protect
         (progn
           (should
            (eq 'opened
                (minibuffer-with-setup-hook
                    (lambda ()
                      (insert "Popup fixture")
                      (run-at-time 0 nil #'exit-minibuffer))
                  (mr-x/bookmark-popup))))
           (should (equal before (frame-list)))
           (should (equal (file-truename file)
                          (file-truename (buffer-file-name))))
           (should-not (frame-live-p mr-x/bookmark-popup-frame)))
       (when-let ((buffer (get-file-buffer file))) (kill-buffer buffer))
       (delete-file file)))))

(provide 'bookmark-popup-test)
