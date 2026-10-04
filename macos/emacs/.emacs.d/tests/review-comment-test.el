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

(ert-deftest review-comment-drafts-follow-their-lines-across-a-refresh ()
  (review-comment-test--with s
    (review-comment-test--at s 'new 3)
    (review-comment-dwim)
    (review-comment-test--write "On THREE.")
    (review-comment-test--at s 'new 12)
    (review-comment-dwim)
    (review-comment-test--write "On TWELVE.")
    ;; A refresh quits as a pause and starts the review again from its
    ;; source, which has moved: one line was added on top, TWELVE is gone.
    (let ((review-session--pausing t)) (review-session-quit))
    (let* ((review-comment-test--spec
            '(("a.el" "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n" "0\n1\n2\nTHREE\n4\n5\n6\n7\n8\n9\n10\n11\n12\n")
              ("b.el" "x\ny\n" "x\nY\n")))
           (fresh (review-session-start (review-comment-test--source))))
      (review-session-load fresh 0 #'ignore)
      (review-session--ensure-layout fresh)
      (let ((three (seq-find (lambda (d) (equal (plist-get d :body) "On THREE."))
                             (review-session-comments fresh)))
            (twelve (seq-find (lambda (d) (equal (plist-get d :body) "On TWELVE."))
                              (review-session-comments fresh))))
        (should (= (plist-get three :line) 4))
        (should-not (plist-get three :pending))
        (should-not (plist-get three :outdated))
        (should (plist-get twelve :outdated))
        (should (cl-some (lambda (l) (string-match-p "OUTDATED" l))
                         (review-comment-test--pane-lines fresh 'new)))))))

(ert-deftest review-comment-drafts-survive-an-unasked-quit ()
  ;; The frame closed by the window manager: nobody was asked.
  (review-comment-test--with s
    (review-comment-test--at s 'new 3)
    (review-comment-dwim)
    (review-comment-test--write "Do not lose me.")
    (review-session-quit)
    (let ((again (review-session-start (review-comment-test--source))))
      (review-session-load again 0 #'ignore)
      (review-session--ensure-layout again)
      (should (equal (mapcar (lambda (d) (plist-get d :body)) (review-session-comments again))
                     '("Do not lose me."))))))

(ert-deftest review-comment-discarded-drafts-do-not-come-back ()
  (review-comment-test--with s
    (review-comment-test--at s 'new 3)
    (review-comment-dwim)
    (review-comment-test--write "Discard me.")
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
      (review-session-quit t))
    (let ((again (review-session-start (review-comment-test--source))))
      (should-not (review-session-comments again)))))

(ert-deftest review-comment-settle-all-marks-drafts-of-missing-files-outdated ()
  (review-comment-test--with s
    (setf (review-session-comments s)
          '((:id 1 :path "gone.el" :side new :line 1 :start-line nil :text "x" :body "b" :pending t)
            (:id 2 :path "b.el" :side new :line 2 :start-line nil :text "Y" :body "b" :pending t)))
    (let (called)
      (review-comment--settle-all s (lambda () (setq called t)))
      (should called))
    (let ((gone (car (review-session-comments s))) (b (cadr (review-session-comments s))))
      (should (plist-get gone :outdated))
      (should-not (plist-get gone :pending))
      (should-not (plist-get b :outdated))
      (should-not (plist-get b :pending)))))

(defmacro review-comment-test--with-drafts (var &rest body)
  "Like `review-comment-test--with', with one draft on a.el line 3 and one outdated."
  (declare (indent 1))
  `(review-comment-test--with ,var
     (setf (review-session-comments ,var)
           (list (list :id 1 :path "a.el" :side 'new :line 3 :start-line nil :text "THREE" :body "Why?")
                 (list :id 2 :path "a.el" :side 'old :line 9 :start-line nil :text "nine" :body "Old note."
                       :outdated t)))
     ,@body))

(ert-deftest review-comment-submit-posts-one-review-and-clears-the-drafts ()
  (review-comment-test--with-drafts s
    (let* (call
           (review-comment-submit-function
            (lambda (session verdict summary drafts success _failure)
              (setq call (list session verdict summary drafts))
              (funcall success))))
      (review-comment-submit s 'request-changes)
      (with-current-buffer "*review-comment*"
        (should (string-match-p "Request changes with 1 line comment" (format "%s" header-line-format)))
        (insert "Please fix.")
        (review-comment-compose-finish))
      (should (eq (nth 0 call) s))
      (should (eq (nth 1 call) 'request-changes))
      ;; The outdated draft rides in the summary, quoted with its place.
      (should (string-prefix-p "Please fix." (nth 2 call)))
      (should (string-match-p "a\\.el:9" (nth 2 call)))
      (should (string-match-p "Old note\\." (nth 2 call)))
      (should (equal (mapcar (lambda (d) (plist-get d :id)) (nth 3 call)) '(1)))
      (should-not (review-session-comments s))
      (should-not (get-buffer "*review-comment*")))))

(ert-deftest review-comment-failed-post-keeps-drafts-and-summary ()
  (review-comment-test--with-drafts s
    (let ((review-comment-submit-function
           (lambda (_session _verdict _summary _drafts _success failure)
             (funcall failure "422 line is not part of the diff"))))
      (review-comment-submit s 'comment)
      (with-current-buffer "*review-comment*"
        (insert "My summary.")
        (review-comment-compose-finish))
      (should (= (length (review-session-comments s)) 2))
      (with-current-buffer "*review-comment*"
        (should (equal (buffer-string) "My summary."))
        (should-not buffer-read-only)
        (should-not (plist-get review-comment--compose :posting))))))

(ert-deftest review-comment-post-in-flight-cannot-be-sent-twice ()
  (review-comment-test--with-drafts s
    (let* ((calls 0) finish
           (review-comment-submit-function
            (lambda (_session _verdict _summary _drafts success _failure)
              (cl-incf calls) (setq finish success))))
      (review-comment-submit s 'comment)
      (with-current-buffer "*review-comment*"
        (review-comment-compose-finish)
        (should buffer-read-only)
        (should-error (review-comment-compose-finish) :type 'user-error)
        (should-error (review-comment-compose-cancel) :type 'user-error))
      (should (= calls 1))
      (funcall finish)
      (should-not (get-buffer "*review-comment*")))))

(ert-deftest review-comment-submit-rules ()
  (review-comment-test--with-drafts s
    (let ((review-comment-submit-function nil))
      (should-error (review-comment-submit s 'comment) :type 'user-error))
    (let* (sent
           (review-comment-submit-function
            (lambda (_s _v summary _d success _f) (setq sent summary) (funcall success))))
      ;; Request changes needs a summary; the compose stays open for it.
      (review-comment-submit s 'request-changes)
      (with-current-buffer "*review-comment*"
        (should-error (review-comment-compose-finish) :type 'user-error))
      (should (get-buffer "*review-comment*"))
      (should-not sent)
      (with-current-buffer "*review-comment*" (review-comment-compose-cancel))
      ;; A comment verdict may have none.
      (review-comment-submit s 'comment)
      (with-current-buffer "*review-comment*" (review-comment-compose-finish))
      (should (stringp sent))
      (should-not (review-session-comments s)))
    ;; Nothing to send.
    (let ((review-comment-submit-function #'ignore))
      (should-error (review-comment-submit s 'comment) :type 'user-error))))

(ert-deftest review-comment-compose-closes-despite-a-kill-buffer-query ()
  ;; perspective.el's `persp-maybe-kill-buffer' refuses to kill a buffer
  ;; shared with another frame's perspective; the compose buffer must go
  ;; all the same, or every later `c' is refused as "finish the open one".
  (review-comment-test--with s
    (let ((kill-buffer-query-functions (list (lambda () nil))))
      (review-comment-test--at s 'new 3)
      (review-comment-dwim)
      (review-comment-test--write "Saved.")
      (should-not (get-buffer "*review-comment*"))
      (should (= (length (review-session-comments s)) 1))
      (review-comment-test--at s 'new 4)
      (review-comment-dwim)
      (should (get-buffer "*review-comment*"))
      (with-current-buffer "*review-comment*" (review-comment-compose-cancel))
      (should-not (get-buffer "*review-comment*")))))

(ert-deftest review-comment-drafts-of-an-unasked-quit-survive-a-restart ()
  ;; The frame is closed by the window manager, then Emacs restarts: the
  ;; in-memory carry is gone, so the saved record must still hold them.
  (review-comment-test--with s
    (review-comment-test--at s 'new 3)
    (review-comment-dwim)
    (review-comment-test--write "Across a restart.")
    (let ((key (review-source-key (review-source-recipe (review-session-source s)))))
      (review-session-quit)
      (clrhash review-comment--carried)
      (clrhash review-store--memory)
      (let ((record (review-store-load key)))
        (should record)
        (should (equal (mapcar (lambda (d) (plist-get d :body)) (plist-get record :comments))
                       '("Across a restart.")))))))

(ert-deftest review-comment-discarded-drafts-leave-no-record ()
  (review-comment-test--with s
    (review-comment-test--at s 'new 3)
    (review-comment-dwim)
    (review-comment-test--write "Discard me.")
    (let ((key (review-source-key (review-source-recipe (review-session-source s)))))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
        (review-session-quit t))
      (clrhash review-store--memory)
      (should-not (review-store-load key)))))

(ert-deftest review-comment-provider-error-leaves-the-compose-usable ()
  ;; A provider that signals instead of calling back must not leave the
  ;; compose read-only and "posting" for ever.
  (review-comment-test--with-drafts s
    (let ((review-comment-submit-function
           (lambda (&rest _) (error "No token for this host"))))
      (review-comment-submit s 'comment)
      (with-current-buffer "*review-comment*"
        (insert "Summary.")
        (review-comment-compose-finish)
        (should-not buffer-read-only)
        (should-not (plist-get review-comment--compose :posting))
        (should (equal (buffer-string) "Summary.")))
      (should (= (length (review-session-comments s)) 2)))))

(ert-deftest review-comment-success-after-the-review-closed-clears-the-carried-drafts ()
  ;; The review frame is closed while the post is in flight.  Its drafts
  ;; were carried; once posted they must not come back to be sent twice.
  (review-comment-test--with-drafts s
    (let* (finish
           (key (review-source-key (review-source-recipe (review-session-source s))))
           (review-comment-submit-function
            (lambda (_s _v _summary _d success _f) (setq finish success))))
      (review-comment-submit s 'comment)
      (with-current-buffer "*review-comment*" (review-comment-compose-finish))
      (review-session-quit)
      (should (gethash key review-comment--carried))
      (funcall finish)
      (should-not (gethash key review-comment--carried))
      (clrhash review-store--memory)
      (should-not (plist-get (review-store-load key) :comments))
      (let ((again (review-session-start (review-comment-test--source))))
        (should-not (review-session-comments again))))))

(provide 'review-comment-test)
;;; review-comment-test.el ends here
