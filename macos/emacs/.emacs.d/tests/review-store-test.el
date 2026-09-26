;;; review-store-test.el --- Pause, resume and the saved record -*- lexical-binding: t; -*-
(require 'ert)
(require 'review-store)

(defconst review-store-test--spec
  '(("a.el" modified "(defun a ()\n  1)\n" "(defun a ()\n  2)\n")
    ("b.el" modified "x\ny\nz\n" "x\nY\nz\nw\n")
    ("c.el" modified "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n" "1\nTWO\n3\n4\n5\n6\n7\n8\nNINE\n10\n")))

(defun review-store-test--source (id)
  (let ((spec review-store-test--spec))
    (make-review-source
     :name "fake" :title "Fake" :range-label "x -> y" :recipe (list :kind 'fake :id id)
     :files (lambda () (mapcar (lambda (s) (list :path (nth 0 s) :old-path (nth 0 s) :kind (nth 1 s))) spec))
     :text (lambda (file side cb)
             (let ((s (seq-find (lambda (x) (equal (car x) (plist-get file :path))) spec)))
               (funcall cb (if (eq side 'old) (nth 2 s) (nth 3 s)))))
     :origin (lambda (file start _end) (list :label (format "%s:%d" (plist-get file :path) start))))))

(defmacro review-store-test--env (&rest body)
  `(let ((review-store-directory (file-name-as-directory (make-temp-file "review-store" t)))
         (review-store--memory (make-hash-table :test #'equal)))
     (unwind-protect (save-window-excursion ,@body)
       (when review-session--current (review-session-quit))
       (delete-directory review-store-directory t))))

(ert-deftest review-store-record-round-trips-through-disk ()
  (review-store-test--env
   (let ((s (review-session-start (review-store-test--source "r1"))))
     (review-session-show 1 0)
     (review-session-toggle-viewed)
     (let* ((record (review-store-save s))
            (_ (clrhash review-store--memory))
            (loaded (review-store-load (plist-get record :key))))
       (should (equal (plist-get loaded :current-path) "b.el"))
       (should (equal (plist-get loaded :viewed) '("b.el")))
       (should (equal (plist-get (nth 1 (plist-get loaded :files)) :new-text) "x\nY\nz\nw\n"))
       (should (equal (plist-get loaded :key) "(:kind fake :id \"r1\")"))))))

(ert-deftest review-store-pause-and-resume-from-disk ()
  (review-store-test--env
   (let ((s (review-session-start (review-store-test--source "r2"))))
     (review-panel-open s)
     (review-session-show 1 0)
     (review-session-toggle-viewed)
     (review-session-pause)
     (should-not review-session--current)
     (clrhash review-store--memory)
     (let ((r (review-session-resume)))
       (should (eq r review-session--current))
       (should (equal (plist-get (review-session-file r) :path) "b.el"))
       (should (equal (review-session-viewed r) '(1)))
       (should (buffer-live-p (review-session-panel r)))))))

(ert-deftest review-store-restore-keeps-folds-and-hunk ()
  (review-store-test--env
   (let ((s (review-session-start (review-store-test--source "r3"))))
     (review-panel-open s)
     (review-session-show 2 1)
     (with-current-buffer (review-session-panel s) (setq review-panel--toggled '(0)))
     (review-session-pause)
     (let ((r (review-session-resume)))
       (should (equal (review-session-current r) 2))
       (should (equal (review-session-hunk r) 1))
       (should (equal (buffer-local-value 'review-panel--toggled (review-session-panel r)) '(0)))))))

(ert-deftest review-store-skips-corrupt-record ()
  (review-store-test--env
   (make-directory review-store-directory t)
   (with-temp-file (expand-file-name "junk.eld" review-store-directory) (insert "(:version 1 :key"))
   (should (null (review-store-list)))
   (should (file-exists-p (expand-file-name "junk.eld" review-store-directory)))))

(ert-deftest review-store-quit-drops-pause-keeps ()
  (review-store-test--env
   (let* ((s (review-session-start (review-store-test--source "r4")))
          (key (review-source-key (review-source-recipe (review-session-source s)))))
     (review-store-save s)
     (review-session-quit)
     (should-not (review-store-load key))
     (setq s (review-session-start (review-store-test--source "r4")))
     (review-session-pause)
     (should (review-store-load key))
     (let ((review-session-keep-on-quit t))
       (review-session-resume)
       (review-session-quit)
       (should (review-store-load key))))))

(ert-deftest review-store-resume-picks-newest-and-pauses-live ()
  (review-store-test--env
   (review-session-start (review-store-test--source "old"))
   (review-session-pause)
   (review-session-start (review-store-test--source "new"))
   (review-session-pause)
   (should (equal (plist-get (car (review-store-list)) :key) "(:kind fake :id \"new\")"))
   (let ((r (review-session-resume)))
     (should (equal (plist-get (review-source-recipe (review-session-source r)) :id) "new")))))

(defun review-store-test--git (dir &rest args)
  (let ((default-directory dir))
    (with-temp-buffer
      (unless (zerop (apply #'call-process "git" nil t nil args)) (error "git %s: %s" args (buffer-string)))
      (string-trim (buffer-string)))))

(defmacro review-store-test--with-repo (var &rest body)
  "A repo whose working tree changes line 3 of a.txt."
  (declare (indent 1))
  `(let ((,var (file-name-as-directory (make-temp-file "review-store-visit" t))))
     (unwind-protect
         (progn
           (review-store-test--git ,var "init" "-q" "-b" "main")
           (review-store-test--git ,var "config" "user.email" "t@example.com")
           (review-store-test--git ,var "config" "user.name" "t")
           (with-temp-file (expand-file-name "a.txt" ,var) (insert "1\n2\n3\n4\n5\n"))
           (review-store-test--git ,var "add" ".")
           (review-store-test--git ,var "commit" "-q" "-m" "base")
           (with-temp-file (expand-file-name "a.txt" ,var) (insert "1\n2\nTHREE\n4\n5\n"))
           ,@body)
       (dolist (b (buffer-list))
         (when (and (buffer-file-name b) (string-prefix-p ,var (buffer-file-name b))) (kill-buffer b)))
       (delete-directory ,var t))))

(ert-deftest review-store-visit-pause-style-pauses-and-opens ()
  (review-store-test--env
   (review-store-test--with-repo dir
     (let ((review-session-visit-style 'pause)
           (s (review-session-start (review-source-git-range dir))))
       (with-selected-window (review-session-new-window s)
         (goto-char (review-session--row-position (review-session-new-buffer s) 2))
         (review-session-visit))
       (should-not review-session--current)
       (should (review-store-load (review-source-key (review-source-recipe (review-source-git-range dir)))))
       (should (equal (buffer-file-name (window-buffer (selected-window)))
                      (expand-file-name "a.txt" dir)))
       (should (= (with-current-buffer (window-buffer (selected-window))
                    (line-number-at-pos (window-point (selected-window))))
                  3))))))

(provide 'review-store-test)
