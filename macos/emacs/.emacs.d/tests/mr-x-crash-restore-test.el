;;; mr-x-crash-restore-test.el --- Frame reconstruction transaction tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'mr-x-crash-restore)

(defvar crash-restore-test--log nil "Recorded calls, oldest first.")

(defun crash-restore-test--session (&rest keys)
  (mapcar (lambda (key) (list :restore-key key :left 10 :top 20 :width 80 :height 24
                              :fullscreen nil :window-tree (list :type 'leaf :buffer key)))
          keys))

(defun crash-restore-test--make-frame (parameters)
  "Fake frame factory: returns a fresh symbol and records the parameters."
  (let ((frame (make-symbol (format "frame:%s" (alist-get 'mr-x/restore-key parameters)))))
    (push (list 'make frame parameters) crash-restore-test--log)
    frame))

(defun crash-restore-test--delete-frame (frame &optional _force)
  (push (list 'delete frame) crash-restore-test--log))

(defun crash-restore-test--restore (session replay &optional delete)
  (setq crash-restore-test--log nil)
  (mr-x/crash-restore-frames session replay
                             #'crash-restore-test--make-frame
                             (or delete #'crash-restore-test--delete-frame)))

(ert-deftest crash-restore-creates-client-nil-frames-with-keys-in-order ()
  (let* ((replayed nil)
         (result (crash-restore-test--restore
                  (crash-restore-test--session "frame-a" "frame-b")
                  (lambda (frame tree) (push (cons frame (plist-get tree :buffer)) replayed)))))
    (should (eq 'restored (plist-get result :status)))
    (should (equal '("frame-a" "frame-b")
                   (mapcar (lambda (f) (plist-get f :restore-key)) (plist-get result :frames))))
    (dolist (entry (reverse crash-restore-test--log))
      (should (eq 'make (car entry)))
      (let ((parameters (nth 2 entry)))
        (should (eq 'ns (alist-get 'window-system parameters)))
        (should (assq 'client parameters))
        (should-not (alist-get 'client parameters))
        (should (equal 10 (alist-get 'left parameters)))
        (should (stringp (alist-get 'mr-x/restore-key parameters)))))
    ;; Each frame's tree was replayed on that frame, in session order.
    (should (equal '("frame-a" "frame-b") (mapcar #'cdr (reverse replayed))))
    (should (equal (mapcar #'car (reverse replayed))
                   (mapcar (lambda (f) (plist-get f :frame)) (plist-get result :frames))))))

(ert-deftest crash-restore-later-failure-deletes-every-frame-of-the-attempt ()
  (let ((result (crash-restore-test--restore
                 (crash-restore-test--session "frame-a" "frame-b" "frame-c")
                 (lambda (_frame tree)
                   (when (equal "frame-b" (plist-get tree :buffer))
                     (error "fixture handler failure"))))))
    (should (eq 'failed (plist-get result :status)))
    (should-not (plist-get result :leaked))
    (let ((errors (plist-get result :errors)))
      (should (= 1 (length errors)))
      (should (equal "frame-b" (plist-get (car errors) :restore-key)))
      (should (eq 'tree (plist-get (car errors) :phase)))
      (should (string-match-p "fixture handler failure" (plist-get (car errors) :error))))
    ;; Two frames were made (a, b); both deleted, newest first; c never made.
    (let* ((log (reverse crash-restore-test--log))
           (made (mapcar #'cadr (cl-remove-if-not (lambda (e) (eq 'make (car e))) log)))
           (deleted (mapcar #'cadr (cl-remove-if-not (lambda (e) (eq 'delete (car e))) log))))
      (should (= 2 (length made)))
      (should (equal (reverse made) deleted)))))

(ert-deftest crash-restore-frame-creation-failure-is-reported-with-phase ()
  (setq crash-restore-test--log nil)
  (let ((result (mr-x/crash-restore-frames
                 (crash-restore-test--session "frame-a")
                 (lambda (&rest _) nil)
                 (lambda (_parameters) (error "fixture display failure"))
                 #'crash-restore-test--delete-frame)))
    (should (eq 'failed (plist-get result :status)))
    (should (eq 'frame (plist-get (car (plist-get result :errors)) :phase)))
    (should-not crash-restore-test--log)))

(ert-deftest crash-restore-undeletable-frames-are-reported-as-leaked ()
  (let ((result (crash-restore-test--restore
                 (crash-restore-test--session "frame-a" "frame-b")
                 (lambda (_frame tree)
                   (when (equal "frame-b" (plist-get tree :buffer)) (error "fixture failure")))
                 (lambda (frame &optional _force)
                   (push (list 'delete frame) crash-restore-test--log)
                   (when (string-suffix-p "frame-a" (symbol-name frame))
                     (error "fixture delete failure"))))))
    (should (eq 'failed (plist-get result :status)))
    (should (equal '("frame-a") (plist-get result :leaked)))
    ;; Cleanup continued past the failing deletion: both deletes attempted.
    (should (= 2 (cl-count 'delete crash-restore-test--log :key #'car)))))

(ert-deftest crash-restore-rejects-malformed-session-before-creating-anything ()
  (dolist (session (list nil
                         '((:restore-key "dup" :window-tree nil) (:restore-key "dup" :window-tree nil))
                         '((:restore-key "" :window-tree nil))
                         '((:left 1))
                         "not a list"))
    (setq crash-restore-test--log nil)
    (should-error (mr-x/crash-restore-frames session (lambda (&rest _) nil)
                                             #'crash-restore-test--make-frame
                                             #'crash-restore-test--delete-frame))
    (should-not crash-restore-test--log)))

(ert-deftest crash-restore-legacy-session-gets-generated-keys ()
  (let ((keyed (mr-x/crash-restore-legacy-session
                '((:left 1 :window-tree nil) (:left 2 :window-tree nil)))))
    (should (= 2 (length keyed)))
    (should (equal '("legacy-1" "legacy-2")
                   (mapcar (lambda (f) (plist-get f :restore-key)) keyed)))
    (should (equal 2 (plist-get (cadr keyed) :left)))))

(provide 'mr-x-crash-restore-test)
;;; mr-x-crash-restore-test.el ends here
