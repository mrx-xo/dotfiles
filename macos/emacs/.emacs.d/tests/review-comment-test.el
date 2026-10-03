;;; review-comment-test.el --- Draft comments in a review -*- lexical-binding: t; -*-
(require 'ert)
(require 'review-comment)

(defvar review-comment-test--spec
  '(("a.el" "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n" "1\n2\nTHREE\n4\n5\n6\n7\n8\n9\n10\n11\nTWELVE\n")
    ("b.el" "x\ny\n" "x\nY\n")
    ("c.el" "p\nq\n" "p\nq\nr\n"))
  "Files as (PATH OLD NEW).  a.el changes lines 3 and 12, its last.")

(defun review-comment-test--source (&optional kind)
  (let ((spec review-comment-test--spec))
    (make-review-source
     :name "fake" :title "Fake" :range-label "x -> y"
     :recipe (append (list :kind (or kind 'fake) :id "comment")
                     ;; A git-range key is made from its directory.
                     (and kind (list :directory temporary-file-directory)))
     :files (lambda () (mapcar (lambda (s) (list :path (car s) :old-path (car s) :kind 'modified)) spec))
     :text (lambda (file side cb)
             (let ((s (assoc (plist-get file :path) spec)))
               (funcall cb (if (eq side 'old) (nth 1 s) (nth 2 s)))))
     :origin (lambda (file start _end) (list :label (format "%s:%d" (plist-get file :path) start))))))

(defmacro review-comment-test--with (var &rest body)
  "Run BODY with VAR a live session on the fake source, all files loaded."
  (declare (indent 1))
  `(let ((review-store-directory (file-name-as-directory (make-temp-file "review-comment" t)))
         (review-store--memory (make-hash-table :test #'equal))
         (review-comment--carried (make-hash-table :test #'equal))
         (review-comment-compose-styles '((test ignore ignore)))
         (review-comment-compose-style 'test))
     (save-window-excursion
       (let ((,var (review-session-start (review-comment-test--source))))
         (dotimes (i (length (review-session-files ,var)))
           (review-session-load ,var i #'ignore))
         (unwind-protect (progn ,@body)
           (when (get-buffer "*review-comment*") (kill-buffer "*review-comment*"))
           (when review-session--current (review-session-quit))
           (delete-directory review-store-directory t))))))

(defun review-comment-test--file (session path)
  (seq-find (lambda (f) (equal (plist-get f :path) path)) (review-session-files session)))

(ert-deftest review-comment-rows-by-side-line ()
  (review-comment-test--with s
    (let ((a (review-comment-test--file s "a.el")) (c (review-comment-test--file s "c.el")))
      (should (equal (review-comment--rows a 'new 3 3) '(2)))
      (should (equal (review-comment--rows a 'old 10 12) '(9 10 11)))
      ;; c.el line 3 exists only on the new side.
      (should (equal (review-comment--rows c 'new 3 3) '(2)))
      (should-not (review-comment--rows c 'old 3 3)))))

(ert-deftest review-comment-hunk-rule ()
  (review-comment-test--with s
    (let ((a (review-comment-test--file s "a.el")))
      ;; Hunks sit on rows 2 and 11; three rows of context on each side count.
      (should (review-comment--commentable-p a '(2)))
      (should (review-comment--commentable-p a '(0)))
      (should (review-comment--commentable-p a '(5)))
      (should-not (review-comment--commentable-p a '(6)))
      (should-not (review-comment--commentable-p a '(7)))
      (should (review-comment--commentable-p a '(8)))
      (should (review-comment--commentable-p a '(9 10 11)))
      ;; A range must stay inside one hunk's window, and no rows is no place.
      (should-not (review-comment--commentable-p a '(5 6 7 8)))
      (should-not (review-comment--commentable-p a nil)))))

(ert-deftest review-comment-line-text-and-labels ()
  (review-comment-test--with s
    (let ((a (review-comment-test--file s "a.el")))
      (should (equal (review-comment--line-text a 'new 3) "THREE"))
      (should (equal (review-comment--line-text a 'old 3) "3"))
      (should (equal (review-comment--where '(:line 12)) "line 12"))
      (should (equal (review-comment--where '(:line 12 :start-line 10)) "lines 10-12"))
      (should (equal (review-comment--label '(:path "a.el" :side new :line 12 :start-line 10))
                     "a.el:10-12 (new)")))))

(ert-deftest review-comment-reanchor-follows-the-text ()
  (review-comment-test--with s
    (let* ((a (review-comment-test--file s "a.el"))
           (moved (review-comment--reanchor
                   '(:id 1 :path "a.el" :side new :line 5 :start-line nil :text "THREE" :body "b" :pending t) a))
           (range (review-comment--reanchor
                   '(:id 2 :path "a.el" :side new :line 9 :start-line 8 :text "TWELVE" :body "b" :pending t) a))
           (gone (review-comment--reanchor
                  '(:id 3 :path "a.el" :side new :line 3 :start-line nil :text "no such line" :body "b" :pending t) a))
           (off-hunk (review-comment--reanchor
                      '(:id 4 :path "a.el" :side new :line 2 :start-line nil :text "7" :body "b" :pending t) a)))
      (should (= (plist-get moved :line) 3))
      (should-not (plist-get moved :pending))
      (should-not (plist-get moved :outdated))
      ;; A range keeps its length: 8-9 becomes 11-12.
      (should (= (plist-get range :line) 12))
      (should (= (plist-get range :start-line) 11))
      (should (plist-get gone :outdated))
      (should (= (plist-get gone :line) 3))
      ;; Line 7 still exists but is outside every hunk now: not postable.
      (should (plist-get off-hunk :outdated))
      (should-not (plist-get off-hunk :pending)))))

(defun review-comment-test--at (session side line)
  "Make SIDE's pane of SESSION current with point on source LINE."
  (let* ((buffer (if (eq side 'old) (review-session-old-buffer session)
                   (review-session-new-buffer session)))
         (row (car (review-comment--rows (review-session-file session) side line line))))
    (set-buffer buffer)
    (deactivate-mark)
    (goto-char (review-session--source-position buffer row))))

(defun review-comment-test--write (text)
  "Type TEXT into the open compose buffer and save it."
  (with-current-buffer "*review-comment*"
    (insert text)
    (review-comment-compose-finish)))

(defun review-comment-test--pane-lines (session side)
  (with-current-buffer (if (eq side 'old) (review-session-old-buffer session)
                         (review-session-new-buffer session))
    (split-string (buffer-substring-no-properties (point-min) (point-max)) "\n")))

(ert-deftest review-comment-c-writes-a-draft-and-shows-its-card ()
  (review-comment-test--with s
    (review-comment-test--at s 'new 3)
    (review-comment-dwim)
    (should (get-buffer "*review-comment*"))
    (review-comment-test--write "Why THREE?")
    (should-not (get-buffer "*review-comment*"))
    (let ((draft (car (review-session-comments s))))
      (should (equal (review-comment--without draft :id)
                     '(:path "a.el" :side new :line 3 :start-line nil :text "THREE" :body "Why THREE?")))
      (should (= (plist-get draft :id) 1)))
    (let* ((new (review-comment-test--pane-lines s 'new))
           (old (review-comment-test--pane-lines s 'old))
           (three (cl-position-if (lambda (l) (string-match-p "THREE" l)) new))
           (card (cl-position-if (lambda (l) (string-match-p "Why THREE\\?" l)) new)))
      ;; The card is under its line and the panes stay level.
      (should (> card three))
      (should (< card (cl-position-if (lambda (l) (string-match-p "^ *4 " l)) new)))
      (should (string-match-p "DRAFT" (nth (1- card) new)))
      (should (= (length old) (length new))))))

(ert-deftest review-comment-on-the-last-line-shows-under-it ()
  (review-comment-test--with s
    (review-comment-test--at s 'new 12)
    (review-comment-dwim)
    (review-comment-test--write "End of file.")
    (let* ((new (review-comment-test--pane-lines s 'new))
           (twelve (cl-position-if (lambda (l) (string-match-p "TWELVE" l)) new))
           (card (cl-position-if (lambda (l) (string-match-p "End of file\\." l)) new)))
      (should card)
      (should (> card twelve)))))

(ert-deftest review-comment-selection-makes-a-range-on-one-side ()
  (review-comment-test--with s
    (review-comment-test--at s 'old 10)
    (let ((begin (point))
          (end (progn (review-comment-test--at s 'old 12) (line-end-position))))
      (set-mark begin) (goto-char end) (activate-mark)
      (let ((transient-mark-mode t)) (review-comment-dwim)))
    (review-comment-test--write "These three.")
    (let ((draft (car (review-session-comments s))))
      (should (eq (plist-get draft :side) 'old))
      (should (= (plist-get draft :start-line) 10))
      (should (= (plist-get draft :line) 12))
      (should (equal (plist-get draft :text) "12")))))

(ert-deftest review-comment-refuses-where-it-cannot-be-posted ()
  (review-comment-test--with s
    ;; Line 7 is outside every hunk and its context.
    (review-comment-test--at s 'new 7)
    (should (equal (cadr (should-error (review-comment-dwim) :type 'user-error))
                   "Comment on a changed line or its context"))
    ;; c.el's added line 3 has no old side.
    (review-session-show 2)
    (set-buffer (review-session-old-buffer s))
    (goto-char (review-session--source-position (current-buffer) 2))
    (should-error (review-comment-dwim) :type 'user-error)
    (should-not (review-session-comments s))
    (should-not (get-buffer "*review-comment*"))))

(ert-deftest review-comment-refuses-a-git-range ()
  (review-comment-test--with _s
    (let ((s (review-session-start (review-comment-test--source 'git-range))))
      (review-session-load s 0 #'ignore)
      (review-comment-test--at s 'new 3)
      (should (equal (cadr (should-error (review-comment-dwim) :type 'user-error))
                     "This review is a git range, not a PR")))))

(ert-deftest review-comment-empty-body-and-cancel-leave-nothing ()
  (review-comment-test--with s
    (review-comment-test--at s 'new 3)
    (review-comment-dwim)
    (review-comment-test--write "   \n ")
    (should-not (review-session-comments s))
    (should-not (get-buffer "*review-comment*"))
    (review-comment-test--at s 'new 3)
    (review-comment-dwim)
    (with-current-buffer "*review-comment*" (insert "half") (review-comment-compose-cancel))
    (should-not (review-session-comments s))
    (should-not (get-buffer "*review-comment*"))))

(ert-deftest review-comment-c-on-a-card-edits-and-D-deletes ()
  (review-comment-test--with s
    (review-comment-test--at s 'new 3)
    (review-comment-dwim)
    (review-comment-test--write "First.")
    (set-buffer (review-session-new-buffer s))
    (goto-char (point-min))
    (search-forward "First.")
    (should (equal (plist-get (review-comment--draft-at s (point)) :body) "First."))
    (review-comment-dwim)
    (with-current-buffer "*review-comment*"
      (should (equal (buffer-string) "First."))
      (erase-buffer))
    (review-comment-test--write "Second.")
    (should (= (length (review-session-comments s)) 1))
    (should (equal (plist-get (car (review-session-comments s)) :body) "Second."))
    (set-buffer (review-session-new-buffer s))
    (goto-char (point-min))
    (search-forward "Second.")
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
      (review-comment-delete)
      (should (= (length (review-session-comments s)) 1)))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
      (review-comment-delete))
    (should-not (review-session-comments s))
    (should-not (cl-some (lambda (l) (string-match-p "Second\\." l))
                         (review-comment-test--pane-lines s 'new)))
    ;; D away from a card says so.
    (review-comment-test--at s 'new 3)
    (should-error (review-comment-delete) :type 'user-error)))

(ert-deftest review-comment-card-keeps-every-word ()
  (let* ((body "Première ligne — naïve.\n\nSecond paragraph with a long sentence that has to wrap because it is far wider than the narrow card this test asks for.")
         (card (substring-no-properties
                (review-comment--card (list :id 7 :path "a.el" :side 'new :line 3 :body body) 50))))
    (dolist (word (split-string body "[ \n]+" t))
      (should (string-match-p (regexp-quote word) card)))
    (should (string-match-p "DRAFT" card))
    (should (string-match-p "line 3" card))))

(ert-deftest review-comment-only-one-compose-at-a-time ()
  (review-comment-test--with s
    (review-comment-test--at s 'new 3)
    (review-comment-dwim)
    (review-comment-test--at s 'new 4)
    (should-error (review-comment-dwim) :type 'user-error)
    ;; A quit while composing closes the buffer and raises nothing.
    (let ((review-session--pausing t)) (review-session-quit))
    (should-not (get-buffer "*review-comment*"))))

(ert-deftest review-comment-quit-asks-about-unsent-drafts ()
  (review-comment-test--with s
    (review-comment-test--at s 'new 3)
    (review-comment-dwim)
    (review-comment-test--write "Keep me.")
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
      (should-error (review-session-quit t) :type 'user-error))
    (should (eq review-session--current s))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
      (review-session-quit t))
    (should-not review-session--current)))

(ert-deftest review-comment-window-style-splits-under-the-pane ()
  (review-comment-test--with s
    (let* ((review-comment-compose-styles
            '((window review-comment--show-window review-comment--hide-window)))
           (review-comment-compose-style 'window)
           (pane (get-buffer-window (review-session-new-buffer s))))
      (when pane
        (select-window pane)
        (review-comment-test--at s 'new 3)
        (review-comment-dwim)
        (should (eq (window-buffer (selected-window)) (get-buffer "*review-comment*")))
        (with-current-buffer "*review-comment*"
          ;; One style installed: the toggle says so and changes nothing.
          (review-comment-compose-toggle-style)
          (should (eq (plist-get review-comment--compose :style) 'window))
          (insert "From the window.")
          (review-comment-compose-finish))
        (should-not (get-buffer-window "*review-comment*"))
        (should (= (length (review-session-comments s)) 1))))))

(provide 'review-comment-test)
;;; review-comment-test.el ends here
