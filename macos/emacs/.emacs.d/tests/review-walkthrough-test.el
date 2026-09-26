;;; review-walkthrough-test.el --- Agent routes through a review -*- lexical-binding: t; -*-
(require 'ert)
(require 'review-walkthrough)

(defconst review-walk-test--spec
  '(("a.el" "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n" "1\n2\nTHREE\n4\n5\n6\n7\n8\n9\n10\nELEVEN\n12\n")
    ("b.el" "x\ny\n" "x\nY\n")))

(defun review-walk-test--source ()
  (make-review-source
   :name "fake" :title "Fake" :range-label "x -> y" :recipe '(:kind fake :id "walk")
   :files (lambda () (mapcar (lambda (s) (list :path (car s) :old-path (car s) :kind 'modified)) review-walk-test--spec))
   :text (lambda (file side cb)
           (let ((s (assoc (plist-get file :path) review-walk-test--spec)))
             (funcall cb (if (eq side 'old) (nth 1 s) (nth 2 s)))))
   :origin (lambda (file start _end) (list :label (format "%s:%d" (plist-get file :path) start)))))

(defmacro review-walk-test--with (var &rest body)
  (declare (indent 1))
  `(let ((review-store-directory (file-name-as-directory (make-temp-file "review-walk" t)))
         (review-store--memory (make-hash-table :test #'equal)))
     (save-window-excursion
       (let ((,var (review-session-start (review-walk-test--source))))
         (dotimes (i (length (review-session-files ,var)))
           (review-session-load ,var i #'ignore))
         (unwind-protect (progn ,@body)
           (when review-session--current (review-session-quit))
           (delete-directory review-store-directory t))))))

(defconst review-walk-test--steps
  '((:path "a.el" :line-start 3 :line-end 3 :title "Three" :body "Why three.")
    (:path "b.el" :line-start 2 :title "Y")
    (:path "a.el" :line-start 11 :title "Eleven" :question "Is eleven right?")))

(ert-deftest review-walkthrough-start-validates-and-goes-to-step-1 ()
  (review-walk-test--with s
    (should (equal (review-walkthrough-start review-walk-test--steps) "ok 3 of 3 steps"))
    (should (= (plist-get (review-session-walkthrough s) :index) 0))
    (should (equal (plist-get (review-session-file s) :path) "a.el"))
    (should (eq (plist-get (aref (plist-get (review-session-walkthrough s) :steps) 1) :side) 'new))))

(ert-deftest review-walkthrough-partial-route ()
  (review-walk-test--with s
    (let ((report (review-walkthrough-start
                   (append review-walk-test--steps
                           '((:path "a.el" :line-start 7 :title "Unchanged line")
                             (:path "zzz.el" :line-start 1 :title "Missing"))))))
      (should (string-prefix-p "ok 3 of 5 steps" report))
      (should (string-match-p "step 4: a.el:7-7 (new) is not in a hunk (nearest hunk 3-3)" report))
      (should (string-match-p "step 5: zzz.el is not in this review" report)))))

(ert-deftest review-walkthrough-rejects-empty-route ()
  (review-walk-test--with _s
    (should (string-prefix-p "error: no valid steps"
                             (review-walkthrough-start '((:path "a.el" :title "no line")))))))

(ert-deftest review-walkthrough-navigation-crosses-files ()
  (review-walk-test--with s
    (review-walkthrough-start review-walk-test--steps)
    (review-walkthrough-next)
    (should (equal (plist-get (review-session-file s) :path) "b.el"))
    (review-walkthrough-next)
    (should (equal (plist-get (review-session-file s) :path) "a.el"))
    (should (= (review-session-hunk s) 1))
    (should-error (review-walkthrough-next) :type 'user-error)
    (review-walkthrough-goto 1)
    (should (= (plist-get (review-session-walkthrough s) :index) 0))
    (review-walkthrough-quit)
    (should-not (review-session-walkthrough s))))

(ert-deftest review-walkthrough-start-file-reads-json ()
  (review-walk-test--with s
    (let ((file (make-temp-file "walk" nil ".json"
                                "{\"steps\":[{\"path\":\"a.el\",\"side\":\"new\",\"line_start\":3,\"line_end\":3,\"title\":\"It's three\",\"body\":\"Apostrophes are fine.\"}]}")))
      (unwind-protect
          (progn
            (should (equal (review-walkthrough-start-file file) "ok 1 of 1 steps"))
            (should (equal (plist-get (aref (plist-get (review-session-walkthrough s) :steps) 0) :title)
                           "It's three")))
        (delete-file file)))))

(ert-deftest review-walkthrough-survives-pause-and-resume ()
  (review-walk-test--with s
    (review-panel-open s)
    (review-walkthrough-start review-walk-test--steps)
    (review-walkthrough-next)
    (review-session-pause)
    (let ((r (review-session-resume)))
      (should (= (plist-get (review-session-walkthrough r) :index) 1))
      (should (equal (plist-get (review-session-file r) :path) "b.el")))))

(ert-deftest review-walkthrough-retry-while-loading ()
  (let ((review-store-directory (file-name-as-directory (make-temp-file "review-walk" t)))
        (review-store--memory (make-hash-table :test #'equal))
        pending)
    (save-window-excursion
      (let* ((src (review-walk-test--source)))
        (setf (review-source-text src)
              (let ((sync (review-source-text src)))
                (lambda (file side cb)
                  (if (equal (plist-get file :path) "b.el") (push (list file side cb) pending)
                    (funcall sync file side cb)))))
        (review-session-start src)
        (unwind-protect
            (should (string-prefix-p "retry: loading b.el"
                                     (review-walkthrough-start review-walk-test--steps)))
          (review-session-quit))))))

(defun review-walk-test--overlays (buffer kind)
  (with-current-buffer buffer
    (seq-filter (lambda (o) (eq (overlay-get o 'review-walk-kind) kind))
                (overlays-in (point-min) (point-max)))))

(ert-deftest review-walkthrough-render-draws-card-filler-and-dim ()
  (review-walk-test--with s
    (review-walkthrough-start review-walk-test--steps)
    (let ((new (review-session-new-buffer s)) (old (review-session-old-buffer s)))
      (should (= (length (review-walk-test--overlays new 'card)) 1))
      (should (= (length (review-walk-test--overlays old 'filler)) 1))
      (let ((card (overlay-get (car (review-walk-test--overlays new 'card)) 'before-string))
            (filler (overlay-get (car (review-walk-test--overlays old 'filler)) 'before-string)))
        (should (string-match-p "AGENT WALKTHROUGH" card))
        (should (string-match-p "1/3  Three" card))
        (should (= (cl-count ?\n card) (cl-count ?\n filler))))
      (should (review-walk-test--overlays new 'mark))
      (should (review-walk-test--overlays new 'dim)))))

(ert-deftest review-walkthrough-render-survives-relayout ()
  (review-walk-test--with s
    (review-walkthrough-start review-walk-test--steps)
    (with-current-buffer (review-session-new-buffer s) (setq review-pane--layout nil))
    (review-session--ensure-layout s)
    (should (= (length (review-walk-test--overlays (review-session-new-buffer s) 'card)) 1))
    (should (= (length (review-walk-test--overlays (review-session-old-buffer s) 'filler)) 1))))

(ert-deftest review-walkthrough-quit-clears-overlays ()
  (review-walk-test--with s
    (review-walkthrough-start review-walk-test--steps)
    (review-walkthrough-quit)
    (dolist (b (list (review-session-new-buffer s) (review-session-old-buffer s)))
      (with-current-buffer b
        (should-not (seq-find (lambda (o) (overlay-get o 'review-walk)) (overlays-in (point-min) (point-max))))))))

(ert-deftest review-walkthrough-question-and-no-dim-option ()
  (review-walk-test--with s
    (let ((review-walkthrough-dim nil))
      (review-walkthrough-start review-walk-test--steps)
      (review-walkthrough-goto 3)
      (let ((card (overlay-get (car (review-walk-test--overlays (review-session-new-buffer s) 'card)) 'before-string)))
        (should (string-match-p "\\? Is eleven right\\?" card)))
      (should-not (review-walk-test--overlays (review-session-new-buffer s) 'dim)))))

(provide 'review-walkthrough-test)
