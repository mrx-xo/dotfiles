;;; review-diagnostics-test.el --- Persistent review evidence -*- lexical-binding: t; -*-
(require 'ert)
(require 'review-frame)

(ert-deftest review-diagnostics-persists-events-and-rotates ()
  (let* ((directory (make-temp-file "review-evidence-" t))
         (review-frame-log-file (expand-file-name "nested/events.log" directory))
         (review-frame-log-max-bytes 1))
    (unwind-protect
        (progn
          (should (fboundp 'review-frame-log))
          (review-frame-log 'first :window "123")
          (review-frame-log 'second :window "456")
          (should (= (logand (file-modes review-frame-log-file) #o777) #o600))
          (should (file-exists-p (concat review-frame-log-file ".1")))
          (with-temp-buffer
            (insert-file-contents review-frame-log-file)
            (let ((record (read (current-buffer))))
              (should (equal (plist-get record :event) 'second))
              (should (= (plist-get record :pid) (emacs-pid)))
              (should (string-match-p "T.*Z$" (plist-get record :time)))
              (should (equal (plist-get record :data) '(:window "456"))))))
      (delete-directory directory t))))

(ert-deftest review-diagnostics-query-evidence-excludes-content-and-other-apps ()
  (should (equal
           (review-frame--query-evidence
            '("query" "--windows")
            (format "[{\"id\":12,\"pid\":%s,\"title\":\"private title\",\"display\":3}, {\"id\":99,\"pid\":-1,\"title\":\"other app\"}]"
                    (emacs-pid)))
           `(((id . 12) (pid . ,(emacs-pid)) (display . 3))))))

(ert-deftest review-diagnostics-write-failure-does-not-break-frame-creation ()
  (let* ((directory (make-temp-file "review-evidence-" t))
         ;; A directory cannot be appended to as a log file.
         (review-frame-log-file directory))
    (unwind-protect
        (progn
          (should (fboundp 'review-frame-create))
          (cl-letf (((symbol-function 'make-frame) (lambda (_) 'created-frame)))
            (should (eq (review-frame-create '((title . "Review diff")))
                        'created-frame))))
      (delete-directory directory t))))

(ert-deftest review-diagnostics-records-before-frame-creation-can-fail ()
  (let* ((directory (make-temp-file "review-evidence-" t))
         (review-frame-log-file (expand-file-name "events.log" directory)))
    (unwind-protect
        (progn
          (should (fboundp 'review-frame-create))
          (cl-letf (((symbol-function 'make-frame) (lambda (_) (error "creation failed"))))
            (should-error (review-frame-create '((title . "Review diff")))))
          (with-temp-buffer
            (insert-file-contents review-frame-log-file)
            (should (eq (plist-get (read (current-buffer)) :event) 'create-start))))
      (delete-directory directory t))))

(ert-deftest review-diagnostics-yabai-failure-has-matching-start-and-end ()
  (let* ((directory (make-temp-file "review-evidence-" t))
         (review-frame-log-file (expand-file-name "events.log" directory))
         (process-environment (copy-sequence process-environment))
         called)
    (unwind-protect
        (progn
          ;; Exercise the real async sentinel without touching the window manager.
          (with-temp-file (expand-file-name "yabai" directory)
            (insert "#!/bin/sh\nexit 7\n"))
          (set-file-modes (expand-file-name "yabai" directory) #o700)
          (let ((exec-path (cons directory exec-path)))
            (let ((process (review-frame--yabai '("window" "123" "--display" "3")
                                                 (lambda (_) (setq called t)))))
              (while (process-live-p process) (accept-process-output process 0.1))
              (accept-process-output process 0.1)))
          (should-not called)
          (should (file-exists-p review-frame-log-file))
          (with-temp-buffer
            (insert-file-contents review-frame-log-file)
            (let ((start (read (current-buffer))) (end (read (current-buffer))))
              (should (eq (plist-get start :event) 'yabai-start))
              (should (eq (plist-get end :event) 'yabai-end))
              (should (equal (plist-get (plist-get start :data) :operation)
                             (plist-get (plist-get end :data) :operation)))
              (should (= (plist-get (plist-get end :data) :status) 7)))))
      (delete-directory directory t))))
