;;; review-session-visit-test.el --- Visit the real file and come back -*- lexical-binding: t; -*-
(require 'ert)
(require 'review-session)
;; Loaded up front so the store variables below bind dynamically: pause
;; style visits save records, and they must land in a temp directory.
(require 'review-store)

(defun review-visit-test--git (dir &rest args)
  (let ((default-directory dir))
    (with-temp-buffer
      (unless (zerop (apply #'call-process "git" nil t nil args)) (error "git %s: %s" args (buffer-string)))
      (string-trim (buffer-string)))))

(defmacro review-visit-test--with-repo (var &rest body)
  "A repo whose working tree changes line 3 of a.txt."
  (declare (indent 1))
  `(let ((,var (file-name-as-directory (make-temp-file "review-visit" t))))
     (unwind-protect
         (progn
           (review-visit-test--git ,var "init" "-q" "-b" "main")
           (review-visit-test--git ,var "config" "user.email" "t@example.com")
           (review-visit-test--git ,var "config" "user.name" "t")
           (with-temp-file (expand-file-name "a.txt" ,var) (insert "1\n2\n3\n4\n5\n"))
           (review-visit-test--git ,var "add" ".")
           (review-visit-test--git ,var "commit" "-q" "-m" "base")
           (with-temp-file (expand-file-name "a.txt" ,var) (insert "1\n2\nTHREE\n4\n5\n"))
           ,@body)
       (dolist (b (buffer-list))
         (when (and (buffer-file-name b) (string-prefix-p ,var (buffer-file-name b))) (kill-buffer b)))
       (delete-directory ,var t))))

(ert-deftest review-session-quit-runs-quit-functions ()
  (review-visit-test--with-repo dir
    (save-window-excursion
      (let* ((seen nil)
             (review-session-quit-functions (list (lambda (s) (push s seen))))
             (s (review-session-start (review-source-git-range dir))))
        (review-session-quit)
        (should (equal seen (list s)))))))

(ert-deftest review-session-pane-state-round-trips ()
  (review-visit-test--with-repo dir
    (save-window-excursion
      (let ((s (review-session-start (review-source-git-range dir))))
        (unwind-protect
            (let ((state (review-session-pane-state s)))
              (should (integerp (plist-get (plist-get state :new) :row)))
              (with-current-buffer (review-session-new-buffer s) (goto-char (point-max)))
              (review-session-restore-pane-state s state)
              (with-current-buffer (review-session-new-buffer s)
                (should (equal (review-session--row-at
                                (window-point (get-buffer-window (current-buffer) t)))
                               (plist-get (plist-get state :new) :row)))))
          (review-session-quit))))))

(ert-deftest review-session-visit-in-frame-opens-line-and-returns ()
  (review-visit-test--with-repo dir
    (save-window-excursion
      (let ((review-session-visit-style 'in-frame)
            (s (review-session-start (review-source-git-range dir))))
        (unwind-protect
            (progn
              (with-selected-window (review-session-new-window s)
                (goto-char (review-session--row-position (review-session-new-buffer s) 2))
                (review-session-visit))
              (should (equal (buffer-file-name (window-buffer (selected-window)))
                             (expand-file-name "a.txt" dir)))
              ;; `with-selected-window' above restores the current buffer on
              ;; exit (`save-current-buffer'), even though the window keeps
              ;; showing the visited file; batch has one frame, so that
              ;; restored buffer is `*scratch*', not the pane's prior buffer.
              ;; Read the line from the window's own buffer instead of the
              ;; ambient current-buffer.
              (should (= (with-current-buffer (window-buffer (selected-window))
                          (line-number-at-pos (window-point (selected-window))))
                        3))
              (review-session-return)
              (should (eq (window-buffer (review-session-new-window s)) (review-session-new-buffer s)))
              (should (window-live-p (review-session-old-window s))))
          (review-session-quit))))))

(ert-deftest review-session-visit-functions-win ()
  (review-visit-test--with-repo dir
    (save-window-excursion
      (let* ((review-session-visit-style 'in-frame) (called nil)
             (review-session-visit-functions (list (lambda (_s file side line) (setq called (list (plist-get file :path) side line)) t)))
             (s (review-session-start (review-source-git-range dir))))
        (unwind-protect
            (progn
              (with-selected-window (review-session-new-window s)
                (goto-char (review-session--row-position (review-session-new-buffer s) 2))
                (review-session-visit))
              (should (equal called '("a.txt" new 3))))
          (review-session-quit))))))

(defmacro review-visit-test--with-store (&rest body)
  `(let ((review-store-directory (file-name-as-directory (make-temp-file "review-visit-store" t)))
         (review-store--memory (make-hash-table :test #'equal)))
     (unwind-protect (save-window-excursion ,@body)
       (when review-session--current (review-session-quit))
       (delete-directory review-store-directory t))))

(ert-deftest review-session-visit-pause-style-keeps-review-when-it-cannot-open ()
  ;; No visit function and no file link: nothing can open, so the review
  ;; is never paused.
  (review-visit-test--with-store
   (let* ((review-session-visit-style 'pause) (review-session-visit-functions nil)
          (s (review-session-start
              (make-review-source
               :name "fake" :title "Fake" :range-label "x -> y" :recipe '(:kind fake :id "visit")
               :files (lambda () (list (list :path "a.el" :old-path "a.el" :kind 'modified)))
               :text (lambda (_file side cb) (funcall cb (if (eq side 'old) "1\n2\n" "1\nTWO\n")))
               :origin (lambda (file start _end) (list :label (format "%s:%d" (plist-get file :path) start)))))))
     (with-selected-window (review-session-new-window s)
       (goto-char (review-session--row-position (review-session-new-buffer s) 1))
       (should-error (review-session-visit) :type 'user-error))
     (should (eq review-session--current s)))))

(ert-deftest review-session-visit-pause-style-resumes-when-opening-fails ()
  (review-visit-test--with-repo dir
    (review-visit-test--with-store
     (let* ((review-session-visit-style 'pause)
            (review-session-visit-functions (list (lambda (&rest _) (error "Open failed"))))
            (s (review-session-start (review-source-git-range dir))))
       (with-selected-window (review-session-new-window s)
         (goto-char (review-session--row-position (review-session-new-buffer s) 2))
         (should-error (review-session-visit)))
       (should review-session--current)
       (should (equal (plist-get (review-session-file review-session--current) :path) "a.txt"))))))

(provide 'review-session-visit-test)
