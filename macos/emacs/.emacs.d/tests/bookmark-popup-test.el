;;; bookmark-popup-test.el --- GUI lifecycle checks -*- lexical-binding: t; -*-

(require 'ert)
(require 'bookmark)
(require 'mr-x-bookmark-popup nil t)

(defmacro bookmark-popup-test--with-gui (&rest body)
  "Run BODY in an existing GUI frame and restore its windows."
  `(let ((frame (seq-find
                 (lambda (f)
                   (and (display-graphic-p f)
                        (not (frame-parameter f 'parent-frame))
                        (not (eq (frame-parameter f 'minibuffer) 'only))
                        (not (eq (frame-parameter f 'device) 'calliope))))
                 (frame-list))))
     (skip-unless frame)
     (with-selected-frame frame
       (save-window-excursion ,@body))))

(ert-deftest bookmark-popup-does-not-run-startup-splash ()
  "A transient picker must not run another client frame's startup splash."
  (bookmark-popup-test--with-gui
   (let* ((bookmark-alist '(("Example" (filename . "/tmp/example"))))
          (origin (selected-frame))
          (client (frame-parameter origin 'client))
          (splash-calls 0)
          (initial-buffer-choice
           (lambda ()
             (cl-incf splash-calls)
             (get-buffer-create " *bookmark-popup-splash-test*"))))
     (unwind-protect
         (progn
           ;; The main client frame carries this flag, unlike some restored
           ;; sandbox frames.  make-frame inherits it unless overridden.
           (set-frame-parameter origin 'client 'nowait)
           (minibuffer-with-setup-hook
               (lambda () (run-at-time 0 nil #'abort-recursive-edit))
             (mr-x/bookmark-popup))
           (should (= splash-calls 0)))
       (set-frame-parameter origin 'client client)
       (when-let ((buffer (get-buffer " *bookmark-popup-splash-test*")))
         (kill-buffer buffer))))))

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

(ert-deftest bookmark-popup-selection-stays-local-with-dedicated-origin ()
  "A bookmarked buffer on an excluded frame must not steal the jump."
  (bookmark-popup-test--with-gui
   (let* ((origin (selected-frame))
          (origin-window (selected-window))
          (origin-buffer (window-buffer origin-window))
          (dedication (window-dedicated-p origin-window))
          (file (make-temp-file "bookmark-popup-" nil ".txt" "Local only\n"))
          (buffer (find-file-noselect file))
          (other (make-frame '((window-system . ns) (client . nil)
                               (device . calliope) (visibility . nil))))
          (other-window (frame-selected-window other))
          (display-buffer-base-action
           '((display-buffer-reuse-window) (reusable-frames . visible)))
          (bookmark-alist `(("Local fixture" (filename . ,file) (position . 1))))
          (bookmark-save-flag nil)
          (bookmark-history nil))
     (unwind-protect
         (progn
           (set-window-buffer other-window buffer)
           (set-window-point other-window 5)
           (make-frame-visible other)
           (select-frame origin)
           (delete-other-windows origin-window)
           (set-window-dedicated-p origin-window 'soft)
           (minibuffer-with-setup-hook
               (lambda ()
                 (insert "Local fixture")
                 (run-at-time 0 nil #'exit-minibuffer))
             (mr-x/bookmark-popup))
           (should (eq (selected-frame) origin))
           (should (eq (window-buffer (selected-window)) buffer))
           (should (eq (window-buffer origin-window) origin-buffer))
           (should (eq (window-dedicated-p origin-window) 'soft))
           (should (eq (window-buffer other-window) buffer))
           (should (= (window-point other-window) 5)))
       (when (window-live-p origin-window)
         (set-window-dedicated-p origin-window dedication))
       (when (frame-live-p other) (delete-frame other t))
       (when (buffer-live-p buffer) (kill-buffer buffer))
       (delete-file file)))))

(ert-deftest bookmark-popup-cancel-from-terminal-selects-local-frame ()
  "An eval arriving on a terminal must not restore that terminal frame."
  (bookmark-popup-test--with-gui
   (let* ((terminal (seq-find (lambda (f) (not (display-graphic-p f)))
                              (frame-list)))
          (before (frame-list))
          (bookmark-alist '(("Example" (filename . "/tmp/example")))))
     (skip-unless terminal)
     (let ((terminal-buffer (window-buffer (frame-selected-window terminal))))
       (select-frame terminal)
       (minibuffer-with-setup-hook
           (lambda () (run-at-time 0 nil #'abort-recursive-edit))
         (mr-x/bookmark-popup))
       (should (display-graphic-p (selected-frame)))
       (should (equal before (frame-list)))
       (should (eq terminal-buffer
                   (window-buffer (frame-selected-window terminal))))))))

(ert-deftest bookmark-popup-file-and-directory-from-terminal-stay-local ()
  "File and Dired jumps reuse a Mac frame without changing a terminal."
  (bookmark-popup-test--with-gui
   (let* ((terminal (seq-find (lambda (f) (not (display-graphic-p f)))
                              (frame-list)))
          (directory (make-temp-file "bookmark-popup-" t))
          (file (expand-file-name "fixture.txt" directory))
          (bookmark-save-flag nil)
          (bookmark-history nil)
          buffers)
     (skip-unless terminal)
     (unwind-protect
         (progn
           (write-region "Local file\n" nil file nil 'silent)
           (dolist (target (list file directory))
             (let ((bookmark-alist `(("Terminal fixture" (filename . ,target)
                                                           (position . 1))))
                   (before (frame-list))
                   (terminal-window (frame-selected-window terminal)))
               (let ((buffer (window-buffer terminal-window))
                     (point (window-point terminal-window)))
                 (select-frame terminal)
                 (minibuffer-with-setup-hook
                     (lambda ()
                       (insert "Terminal fixture")
                       (run-at-time 0 nil #'exit-minibuffer))
                   (mr-x/bookmark-popup))
                 (push (current-buffer) buffers)
                 (should (eq (framep (selected-frame)) 'ns))
                 (should (equal before (frame-list)))
                 (should (eq buffer (window-buffer terminal-window)))
                 (should (= point (window-point terminal-window)))
                 (if (equal target directory)
                     (progn
                       (should (derived-mode-p 'dired-mode))
                       (should (file-equal-p directory default-directory)))
                   (should (file-equal-p file (buffer-file-name))))))))
       (dolist (buffer buffers)
         (when (buffer-live-p buffer) (kill-buffer buffer)))
       (delete-directory directory t)))))

(provide 'bookmark-popup-test)
