;;; review-session-test.el --- Session state and pane text -*- lexical-binding: t; -*-
(require 'ert)
(require 'review-session)

(ert-deftest review-session-pane-render-avoids-quadratic-line-lookups ()
  (let* ((text (mapconcat #'identity (make-list 1000 "line") "\n"))
         (rows (review-diff-rows (review-diff-ops text text)))
         (nth-function (symbol-function 'nth)) (traversed 0))
    (cl-letf (((symbol-function 'nth)
               (lambda (n list) (cl-incf traversed n) (funcall nth-function n list))))
      (review-session-pane-text rows 'new text "file.txt"))
    (should (< traversed (* 10 (length rows))))))

(ert-deftest review-session-coalesces-concurrent-loads-and-completes-once ()
  (save-window-excursion
    (let* ((source (make-review-source
                    :name "async" :title "Async" :range-label "range"
                    :files (lambda () (list (list :path "a.el" :old-path "a.el")))))
           pending session completed)
      (setf (review-source-text source)
            (lambda (_file side callback) (push (cons side callback) pending)))
      (unwind-protect
          (progn
            (setq session (review-session-start source))
            (review-session-load session 0 (lambda (&optional error) (push error completed)))
            (should (= (length pending) 1))
            (let ((old (cdr (pop pending))))
              (funcall old "old\n")
              (let ((new (cdr (pop pending))))
                (funcall new "new\n")
                ;; A duplicate/stale error may never poison a successful cache.
                (funcall new nil "late failure"))
              (funcall old nil "older failure"))
            (should (equal completed '(nil)))
            (should (plist-get (review-session-file session) :loaded))
            (should-not (plist-get (review-session-file session) :error))
            (should (equal (plist-get (review-session-file session) :new-text) "new\n")))
        (review-session-quit)))))

(ert-deftest review-session-panel-deletion-origin-uses-old-side-and-range ()
  (require 'review-panel)
  (save-window-excursion
    (let* ((source (review-session-test--source
                    '(("new.txt" modified "one\ntwo\nremoved\nfour\n" "one\ntwo\nfour\n"))))
           session)
      (setf (review-source-origin source)
            (lambda (file start end) (list :path (plist-get file :origin-path)
                                           :side (plist-get file :side)
                                           :start start :end end)))
      (unwind-protect
          (progn
            (setq session (review-session-start source))
            (setf (plist-get (aref (review-session-files session) 0) :old-path) "old.txt")
            (review-panel-open session)
            (with-current-buffer (review-session-panel session)
              (goto-char (text-property-any (point-min) (point-max) 'review-hunk 0))
              (should (equal (review-session-origin)
                             '(:path "old.txt" :side old :start 3 :end 3)))))
        (review-session-quit)))))

(defun review-session-test--source (spec)
  "SPEC is a list of (PATH KIND OLD NEW [BINARY])."
  (make-review-source
   :name "fake" :title "Fake" :range-label "x -> y"
   :files (lambda () (mapcar (lambda (s) (list :path (nth 0 s) :old-path (nth 0 s) :kind (nth 1 s) :binary (nth 4 s))) spec))
   :text (lambda (file side cb)
           (let ((s (seq-find (lambda (x) (equal (car x) (plist-get file :path))) spec)))
             (funcall cb (if (eq side 'old) (nth 2 s) (nth 3 s)))))
   :origin (lambda (file start end) (list :label (format "%s:%d-%d" (plist-get file :path) start end) :link nil :url nil))))

(defconst review-session-test--spec
  '(("a.el" modified "(defun a ()\n  1)\n" "(defun a ()\n  2)\n")
    ("b.el" modified "x\ny\nz\n" "x\nY\nz\nw\n")
    ("bin.dat" modified "" "" t)))

(defmacro review-session-test--with (var &rest body)
  (declare (indent 1))
  `(save-window-excursion
     (let ((,var (review-session-start (review-session-test--source review-session-test--spec))))
       (unwind-protect (progn ,@body)
         (review-session-quit)))))

(ert-deftest review-session-start-loads-first-file-and-panes ()
  (review-session-test--with s
    (should (equal (review-session-current s) 0))
    (should (equal (review-session-hunk s) 0))
    (should (buffer-live-p (review-session-old-buffer s)))
    (should (buffer-live-p (review-session-new-buffer s)))
    (should (equal (length (plist-get (aref (review-session-files s) 0) :hunks)) 1))
    (with-current-buffer (review-session-new-buffer s)
      (should (eq major-mode 'review-pane-mode))
      (should buffer-read-only)
      (should (string-match-p "  2)" (buffer-string))))))

(ert-deftest review-session-next-file-marks-viewed-and-advances ()
  (review-session-test--with s
    (review-session-next-file)
    (should (equal (review-session-current s) 1))
    (should (equal (review-session-viewed s) '(0)))
    (should (equal (review-session-progress s) '(1 . 3)))))

(ert-deftest review-session-next-file-skips-nothing-but-binary-has-no-panes ()
  (review-session-test--with s
    (review-session-next-file) (review-session-next-file)
    (should (equal (review-session-current s) 2))
    (should (plist-get (aref (review-session-files s) 2) :binary))
    (should (null (plist-get (aref (review-session-files s) 2) :hunks)))
    (with-current-buffer (review-session-new-buffer s)
      (should (string-match-p "binary" (buffer-string))))))

(ert-deftest review-session-past-the-end-is-an-error-and-keeps-state ()
  (review-session-test--with s
    (review-session-next-file) (review-session-next-file)
    (should-error (review-session-next-file) :type 'user-error)
    (should (equal (review-session-current s) 2))
    (should (equal (review-session-viewed s) '(1 0)))))

(ert-deftest review-session-prev-file-does-not-mark-viewed ()
  (review-session-test--with s
    (review-session-next-file)
    (review-session-prev-file)
    (should (equal (review-session-current s) 0))
    (should (equal (review-session-viewed s) '(0)))))

(ert-deftest review-session-revisits-reuse-rendered-panes ()
  (let ((renders 0) (render (symbol-function 'review-session-pane-render)))
    (cl-letf (((symbol-function 'review-session-pane-render)
               (lambda (&rest args) (cl-incf renders) (apply render args))))
      (review-session-test--with s
        (should (= renders 2))
        (review-session-next-file)
        (should (= renders 4))
        (review-session-prev-file)
        (review-session-next-file)
        (should (= renders 4))
        (with-current-buffer (review-session-new-buffer s)
          (should (string-match-p "Y" (buffer-string))))))))

(ert-deftest review-session-panes-show-carriage-returns ()
  ;; A CRLF-to-LF change is invisible unless the old side marks its CRs.
  (let* ((old "first\r\nsecond\r\n") (new "first\nsecond\n")
         (rows (review-diff-rows (review-diff-ops old new)))
         (text (review-session-pane-text rows 'old old "crlf.txt"))
         (cr (string-match "\r" text)))
    (should (seq-every-p (lambda (r) (memq (plist-get r :kind) '(del add both))) rows))
    (should cr)
    (should (equal (get-text-property cr 'display text) "\u240d"))
    (should (memq 'review-eol (ensure-list (get-text-property cr 'face text))))
    (should-not (string-match "\r" (review-session-pane-text rows 'new new "crlf.txt")))))

;; Emacs's pulse keeps one global overlay, so pulsing the second pane
;; cancelled the first: only one side ever flashed.
(ert-deftest review-session-flashes-the-hunk-in-both-panes ()
  (cl-flet ((flashed (buffer)
              (with-current-buffer buffer
                (seq-find (lambda (o) (overlay-get o 'review-flash))
                          (overlays-in (point-min) (point-max))))))
    (cl-letf (((symbol-function 'run-at-time) #'ignore))
      (review-session-test--with s
        (review-session-next-file)
        (let ((old (flashed (review-session-old-buffer s)))
              (new (flashed (review-session-new-buffer s))))
          (should old)
          (should new)
          (should (string-match-p "Y" (with-current-buffer (review-session-new-buffer s)
                                        (buffer-substring (overlay-start new) (overlay-end new))))))
        (let ((review-session-pulse nil))
          (review-session-prev-file)
          (should-not (flashed (review-session-new-buffer s))))))))

(ert-deftest review-session-flash-fades-before-it-goes ()
  ;; A 0.35 s grey blink was too faint to notice: hold, then fade out.
  (let (timers)
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (time _repeat fn &rest args) (push (list time fn args) timers))))
      (with-temp-buffer
        (insert "changed line\n")
        (review-session--flash (point-min) (point-max))
        (should (> (length timers) 4))
        (should (>= (apply #'max (mapcar #'car timers)) 0.5))
        (should (eq (cadr (car (sort (copy-sequence timers) (lambda (a b) (> (car a) (car b))))))
                    #'delete-overlay))))))

(ert-deftest review-session-selection-carries-both-sides-as-a-diff ()
  ;; Quick Ask on a selection used to see only this pane's side, so
  ;; "what changed?" could not be answered.
  (review-session-test--with s
    (setf (review-source-old-label (review-session-source s)) "main @ abc1234"
          (review-source-new-label (review-session-source s)) "feat @ def5678")
    (review-session-next-file)
    (with-current-buffer (review-session-new-buffer s)
      (let ((selection (review-session-pane-selection (point-min) (point-max))))
        (should (equal (plist-get selection :text) "x\nY\nz\nw"))
        (should (equal (plist-get selection :diff)
                       (concat "--- main @ abc1234\n+++ feat @ def5678\n"
                               "  x\n- y\n+ Y\n  z\n+ w")))))
    ;; No change in the selection: no diff to send.
    (with-current-buffer (review-session-new-buffer s)
      (should-not (plist-get (review-session-pane-selection (point-min) (1+ (point-min))) :diff)))))

(ert-deftest review-session-highlights-only-the-changed-words ()
  (let* ((old "keep this OLDWORD and this\n") (new "keep this NEWWORD and this\n")
         (rows (review-diff-rows (review-diff-ops old new))))
    (dolist (side '(old new))
      (let* ((text (review-session-pane-text rows side (if (eq side 'old) old new) "f.txt"))
             (word (string-match (if (eq side 'old) "OLDWORD" "NEWWORD") text))
             (face (if (eq side 'old) 'review-del-word 'review-add-word)))
        (should (memq face (ensure-list (get-text-property word 'face text))))
        (should-not (memq face (ensure-list (get-text-property (string-match "keep" text) 'face text))))
        (should-not (memq face (ensure-list (get-text-property (string-match "and" text) 'face text))))))))

(ert-deftest review-session-headers-name-added-and-deleted-sides ()
  ;; The session's own plain header, without the panel's design hooks.
  (save-window-excursion
    (let* ((review-session-display-hook nil) (review-session-update-hook nil)
           (s (review-session-start
              (review-session-test--source
               '(("new.py" added "" "x\n") ("gone.txt" deleted "y\n" ""))))))
      (unwind-protect
          (cl-flet ((header (side) (with-current-buffer
                                       (if (eq side 'old) (review-session-old-buffer s)
                                         (review-session-new-buffer s))
                                     header-line-format)))
            (setf (plist-get (aref (review-session-files s) 0) :old-path) nil)
            (review-session-show 0)
            (should (string-match-p "OLD  (new file)  " (header 'old)))
            (should (string-match-p "NEW  new\\.py  " (header 'new)))
            (review-session-show 1)
            (should (string-match-p "OLD  gone\\.txt  " (header 'old)))
            (should (string-match-p "NEW  (deleted)  " (header 'new))))
        (review-session-quit)))))

(ert-deftest review-session-frameless-daemon-still-pops-out ()
  ;; rv starts the sandbox without frames, so only its terminal frame exists.
  (let ((featurep (symbol-function 'featurep)) params)
    (cl-letf (((symbol-function 'daemonp) (lambda () "sandbox"))
              ((symbol-function 'featurep)
               (lambda (feature &rest args) (or (eq feature 'ns) (apply featurep feature args))))
              ((symbol-function 'make-frame) (lambda (&optional p) (setq params p) (selected-frame)))
              ((symbol-function 'delete-frame) #'ignore)
              ((symbol-function 'select-frame-set-input-focus) #'ignore)
              ((symbol-function 'review-frame-place) #'ignore))
      (let ((review-session-pop-out t))
        (review-session-test--with s
          (should (review-session-own-frame s))
          (should (eq (alist-get 'window-system params) 'ns)))))))

(ert-deftest review-session-prerenders-neighbours ()
  (review-session-test--with s
    (should-not (plist-get (review-session-file s 1) :new-render))
    (review-session--prerender s)
    (should (plist-get (review-session-file s 1) :old-render))
    (should (plist-get (review-session-file s 1) :new-render))
    ;; Binary files have nothing to render.
    (review-session-next-file)
    (review-session--prerender s)
    (should-not (plist-get (review-session-file s 2) :new-render))))

(ert-deftest review-session-hunk-keys-stay-inside-the-file ()
  ;; Hunk keys only walk hunks; only file keys change files.
  (let* ((old (mapconcat (lambda (i) (format "l%d" i)) (number-sequence 1 20) "\n"))
         (new (replace-regexp-in-string
               "^l18$" "L18" (replace-regexp-in-string "^l2$" "L2" old))))
    (save-window-excursion
      (let ((s (review-session-start
                (review-session-test--source
                 `(("a.txt" modified "a\n" "b\n") ("two.txt" modified ,old ,new)
                   ("c.txt" modified "c\n" "d\n"))))))
        (unwind-protect
            (cl-flet ((at () (list (review-session-current s) (review-session-hunk s))))
              (review-session-next-file)
              (should (= (length (plist-get (review-session-file s) :hunks)) 2))
              (review-session-next-hunk)
              (should (equal (at) '(1 1)))
              (should-error (review-session-next-hunk) :type 'user-error)
              (should (equal (at) '(1 1)))
              (review-session-prev-hunk)
              (should-error (review-session-prev-hunk) :type 'user-error)
              (should (equal (at) '(1 0)))
              (should (equal (review-session-viewed s) '(0))))
          (review-session-quit))))))

(ert-deftest review-session-toggle-viewed ()
  (review-session-test--with s
    (review-session-toggle-viewed)
    (should (equal (review-session-viewed s) '(0)))
    (review-session-toggle-viewed)
    (should (equal (review-session-viewed s) nil))))

(ert-deftest review-session-pane-text-gutter-and-blanks ()
  (let* ((rows (review-diff-rows (review-diff-ops "a\nb\n" "a\nX\nY\n")))
         (old (review-session-pane-text rows 'old "a\nb\n"))
         (new (review-session-pane-text rows 'new "a\nX\nY\n"))
         (old-lines (split-string old "\n")) (new-lines (split-string new "\n")))
    (should (equal (length old-lines) (length new-lines)))
    (should (string-match-p "\\`  *1   a\\'" (nth 0 old-lines)))
    (should (string-match-p "\\`  *2 - b\\'" (nth 1 old-lines)))
    (should (string-match-p "\\`  *3 \\+ Y\\'" (nth 2 new-lines)))
    (should (string-match-p "\\`[[:space:]]*\\'" (nth 2 old-lines)))
    (should (eq (get-text-property 0 'review-row new) 0))
    (should (eq (get-text-property (1+ (length (nth 0 new-lines))) 'review-row new) 1))))

(ert-deftest review-session-quit-restores-and-kills ()
  (let (old new)
    (save-window-excursion
      (let ((s (review-session-start (review-session-test--source review-session-test--spec))))
        (setq old (review-session-old-buffer s) new (review-session-new-buffer s))
        (review-session-quit)))
    (should-not (buffer-live-p old))
    (should-not (buffer-live-p new))
    (should (null review-session--current))))

(ert-deftest review-session-update-hook-fires ()
  (let ((n 0))
    (add-hook 'review-session-update-hook (lambda (_s) (cl-incf n)))
    (unwind-protect
        (review-session-test--with s
          (let ((before n))
            (review-session-next-file)
            (should (> n before))))
      (setq review-session-update-hook nil))))


(ert-deftest review-session-late-loads-do-not-reopen-or-replace-panes ()
  (save-window-excursion
    (let (callbacks s)
      (unwind-protect
          (progn
            (setq s
                  (review-session-start
                   (make-review-source
                    :name "async" :title "Async" :range-label "base..head"
                    :files (lambda () '((:path "a.txt" :old-path "a.txt")
                                        (:path "b.txt" :old-path "b.txt")))
                    :text (lambda (file side cb)
                            (if (eq side 'old) (funcall cb "")
                              (push (cons (plist-get file :path) cb) callbacks))))))
            (review-session-show 1)
            (funcall (cdr (assoc "b.txt" callbacks)) "B\n")
            (funcall (cdr (assoc "a.txt" callbacks)) "A\n")
            (should (= (review-session-current s) 1))
            (with-current-buffer (review-session-new-buffer s)
              (should (string-match-p "B" (buffer-string))))
            (review-session-quit)
            (funcall (cdr (assoc "a.txt" callbacks)) "A\n")
            (should-not review-session--current)
            (should-not (buffer-live-p (review-session-new-buffer s))))
        (review-session-quit)))))

(ert-deftest review-session-failed-navigation-does-not-mark-viewed ()
  (review-session-test--with s
    (setf (review-source-text (review-session-source s))
          (lambda (&rest _) (user-error "Source unavailable")))
    (should-error (review-session-next-file) :type 'user-error)
    (should (= (review-session-current s) 0))
    (should-not (review-session-viewed s))))

(ert-deftest review-session-empty-text-is-cached ()
  (save-window-excursion
    (let ((calls 0) s)
      (unwind-protect
          (progn
            (setq s (review-session-start
                     (make-review-source
                      :name "empty" :title "Empty" :range-label "a..b"
                      :files (lambda () '((:path "empty" :old-path "empty")))
                      :text (lambda (_file _side cb) (cl-incf calls) (funcall cb "")))))
            (review-session-load s 0 #'ignore)
            (should (= calls 2)))
        (review-session-quit)))))

(ert-deftest review-session-restores-a-multiwindow-layout ()
  (save-window-excursion
    (split-window-below)
    (let ((before (length (window-list))))
      (let ((s (review-session-start (review-session-test--source review-session-test--spec))))
        (unwind-protect
            (should (and (window-live-p (review-session-old-window s))
                         (window-live-p (review-session-new-window s))))
          (review-session-quit)))
      (should (= before (length (window-list)))))))

;;;; Long lines: wrap and pad, or scroll both panes

(defun review-session-test--layout (old new mode width &optional hscroll)
  "Lay out texts OLD and NEW in MODE at body WIDTH.
Return (OLD-LINES NEW-LINES STARTS)."
  (let* ((rows (review-diff-rows (review-diff-ops old new)))
         (o (review-session-pane-render rows 'old old))
         (n (review-session-pane-render rows 'new new)))
    (pcase-let ((`(,a ,b ,starts) (review-session-pane-layout o n mode width width (or hscroll 0))))
      (list (split-string a "\n") (split-string b "\n") starts))))

(defun review-session-test--faces (string pos)
  (ensure-list (get-text-property pos 'face string)))

(ert-deftest review-session-wrap-pads-the-shorter-side ()
  ;; A wrapped line takes more rows on one side; the other side gets blank
  ;; rows, so the next line starts level in both panes.
  (let ((long (string-join (make-list 12 "word") " ")))
    (pcase-let ((`(,old ,new ,starts)
                 (review-session-test--layout "a\nshort\nz\n" (concat "a\n" long "\nz\n") 'wrap 20)))
      (should (= (length old) (length new)))
      (should (> (length new) 4))
      (should (string-match-p " z\\'" (nth (aref starts 2) old)))
      (should (string-match-p " z\\'" (nth (aref starts 2) new)))
      (dolist (line new) (should (<= (string-width line) (+ 6 20))))
      ;; A continuation row shows ↪ where the line number goes.
      (should (string-match-p "\\`  ↪   word" (nth 2 new)))
      (should (memq 'review-add (review-session-test--faces (nth 2 new) 8)))
      ;; The shorter side's extra rows are blank placeholders.
      (should (string-match-p "\\`[[:space:]]*\\'" (nth 3 old)))
      (should (memq 'review-blank (review-session-test--faces (nth 3 old) 0)))
      ;; Every line of a row knows the row.
      (should (eq (get-text-property 0 'review-row (nth 3 old)) 1))
      (should (eq (get-text-property 0 'review-row (nth 2 new)) 1)))))

(ert-deftest review-session-wrap-indents-past-a-bullet ()
  (pcase-let ((`(,_ ,new) (review-session-test--layout
                           "x\n" "- alpha beta gamma delta epsilon\n" 'wrap 14)))
    (should (string-match-p "\\`  1 \\+ - alpha beta\\'" (nth 0 new)))
    (should (string-match-p "\\`  ↪     gamma delta\\'" (nth 1 new)))))

(ert-deftest review-session-wrap-cuts-a-huge-line-but-shows-its-change ()
  ;; Minified JSON must not fill the screen: past the row cap the line is
  ;; cut.  A change further on than the first rows is what the cut rows
  ;; show, after the line's first row; a count stands for what is skipped.
  (let ((review-session-wrap-max-rows 3)
        (xs (make-string 200 ?x)))
    (pcase-let ((`(,old ,new) (review-session-test--layout
                               (concat xs " old\n") (concat xs " new\n") 'wrap 20)))
      (should (= (length new) 3))
      (dolist (line new) (should (<= (string-width line) (+ 6 20))))
      (should (string-match "\\`  1 \\+ \\(x+\\) … \\+\\([0-9]+\\)\\'" (nth 0 new)))
      (let ((shown (length (match-string 1 (nth 0 new))))
            (skipped (string-to-number (match-string 2 (nth 0 new)))))
        ;; No change in the skipped part, so its count is muted.
        (should (memq 'review-edge (review-session-test--faces (nth 0 new) (+ 7 shown))))
        (should (string-match "\\`  ↪   \\(x+\\)\\'" (nth 1 new)))
        (should (= 200 (+ shown skipped (length (match-string 1 (nth 1 new)))))))
      (should (string-match-p "\\`  ↪   new\\'" (nth 2 new)))
      (should (string-match-p "\\`  ↪   old\\'" (nth 2 old))))
    ;; A change that starts early and runs past the cut: the count is in
    ;; the side's colour.
    (pcase-let ((`(,old ,new) (review-session-test--layout
                               (concat "k " (make-string 200 ?a) "\n")
                               (concat "k " (make-string 200 ?b) "\n") 'wrap 20)))
      (should (= (length new) 3))
      (should (string-match " … " (nth 2 new)))
      (should (memq 'review-mark-add (review-session-test--faces (nth 2 new) (1+ (match-beginning 0)))))
      (should (string-match " … " (nth 2 old)))
      (should (memq 'review-mark-del (review-session-test--faces (nth 2 old) (1+ (match-beginning 0))))))
    ;; A visible change leaves the count muted.
    (pcase-let ((`(,_ ,new) (review-session-test--layout
                             (concat "a" xs "\n") (concat "b" xs "\n") 'wrap 20)))
      (should (string-match " … " (nth 2 new)))
      (should (memq 'review-edge (review-session-test--faces (nth 2 new) (1+ (match-beginning 0))))))))

(ert-deftest review-session-scroll-cuts-at-the-edges-and-marks-hidden-changes ()
  (let ((old (concat (make-string 30 ?a) " old " (make-string 30 ?b) "\nshort\n"))
        (new (concat (make-string 30 ?a) " new " (make-string 30 ?b) "\nshort\n")))
    ;; From column 0 the change is past the right edge.
    (pcase-let ((`(,_ ,new-lines ,starts) (review-session-test--layout old new 'scroll 20 0)))
      (should (equal starts [0 1]))
      (let ((line (nth 0 new-lines)))
        (should (string-match-p "\\`  1 \\+ a\\{20\\}›\\'" line))
        (should (memq 'review-mark-add (review-session-test--faces line (1- (length line))))))
      (should (string-match-p "\\`  2   short\\'" (nth 1 new-lines))))
    ;; Scrolled 40 columns the change is behind the left edge instead.
    (pcase-let ((`(,old-lines ,new-lines) (review-session-test--layout old new 'scroll 20 40)))
      (let ((line (nth 0 new-lines)))
        (should (string-match-p "\\`  1 \\+‹b\\{20\\}›\\'" line))
        (should (memq 'review-mark-add (review-session-test--faces line 5)))
        (should (memq 'review-edge (review-session-test--faces line (1- (length line))))))
      (should (memq 'review-mark-del (review-session-test--faces (nth 0 old-lines) 5)))
      ;; A short line scrolled past its end leaves only the muted mark.
      (should (string-match-p "\\`  2  ‹\\'" (nth 1 new-lines)))
      (should (memq 'review-edge (review-session-test--faces (nth 1 new-lines) 5))))))

(defmacro review-session-test--long (var mode old new &rest body)
  "Run BODY with VAR a session over one file OLD -> NEW, long lines in MODE."
  (declare (indent 4))
  `(save-window-excursion
     (let* ((review-session-long-lines ,mode)
            (,var (review-session-start
                   (review-session-test--source
                    (list (list "long.txt" 'modified ,old ,new) '("next.txt" modified "a\n" "b\n"))))))
       (unwind-protect (progn ,@body)
         (review-session-quit)))))

(ert-deftest review-session-scrolls-sideways-to-a-change-far-right ()
  ;; Scroll mode opens both panes cut at the change.  The panes redraw
  ;; from that column instead of scrolling the window, so the line numbers
  ;; stay put.
  (let* ((far (concat (make-string 300 ?x) " old tail\n"))
         (far-new (concat (make-string 300 ?x) " new tail\n")))
    (review-session-test--long s 'scroll far far-new
      (should (> (review-session-hscroll s) 0))
      (dolist (w (list (review-session-old-window s) (review-session-new-window s)))
        (should (= (window-hscroll w) 0))
        (with-current-buffer (window-buffer w)
          (save-excursion
            (goto-char (window-point w))
            (should (looking-at-p "\\(old\\|new\\) tail"))
            (should (< (current-column) (window-body-width w)))
            (should (looking-back "\\`  1 [-+]‹x* " (line-beginning-position))))))
      (review-session-next-file)
      (should (= (review-session-hscroll s) 0)))))

(ert-deftest review-session-zl-scrolls-both-panes-together ()
  (let ((as (make-string 300 ?a)))
    (review-session-test--long s 'scroll (concat "x\n" as "\n") (concat "y\n" as "\n")
      (should (= (review-session-hscroll s) 0))
      (review-session-scroll-right)
      (should (= (review-session-hscroll s) review-session-scroll-step))
      (dolist (b (list (review-session-old-buffer s) (review-session-new-buffer s)))
        (with-current-buffer b
          (goto-char (point-min))
          (forward-line 1)
          (should (looking-at-p "  2  ‹a"))))
      (dolist (w (list (review-session-old-window s) (review-session-new-window s)))
        (should (= (window-hscroll w) 0)))
      (review-session-scroll-left 5)
      (should (= (review-session-hscroll s) 0))
      (review-session-scroll-right-half)
      (should (> (review-session-hscroll s) review-session-scroll-step))
      ;; Never past the point where the longest line ends at the edge.
      (review-session-scroll-right 1000)
      (with-current-buffer (review-session-new-buffer s)
        (goto-char (point-min))
        (forward-line 1)
        (should (looking-at-p ".*a\\'"))
        (should-not (string-search "›" (buffer-substring (point) (line-end-position))))))))

(ert-deftest review-session-wrap-mode-refuses-sideways-scrolling ()
  (review-session-test--long s 'wrap "x\n" "y\n"
    (should-error (review-session-scroll-right) :type 'user-error)
    (should (= (review-session-hscroll s) 0))))

(ert-deftest review-session-zw-switches-between-wrap-and-scroll ()
  (let ((long (string-join (make-list 60 "word") " ")))
    (review-session-test--long s 'wrap (concat "x\n" long "\n") (concat "y\n" long "\n")
      (let ((lines (lambda () (with-current-buffer (review-session-new-buffer s)
                                (count-lines (point-min) (point-max))))))
        (should (> (funcall lines) 2))
        (review-session-toggle-long-lines)
        (should (eq review-session-long-lines 'scroll))
        (should (= (funcall lines) 2))
        (review-session-toggle-long-lines)
        (should (eq review-session-long-lines 'wrap))
        (should (> (funcall lines) 2))))))

(ert-deftest review-session-wrapped-rows-select-and-scroll-as-rows ()
  (let* ((long (string-join (make-list 60 "word") " "))
         (old (concat "x\n" long "\nz\n")) (new (concat "y\n" long "\nz\n")))
    (review-session-test--long s 'wrap old new
      (with-current-buffer (review-session-new-buffer s)
        ;; Continuation rows are one source line to Quick Ask.
        (should (equal (plist-get (review-session-pane-selection (point-min) (point-max)) :text)
                       (concat "y\n" long "\nz")))
        (should (= (review-session--row-position (current-buffer) 2)
                   (save-excursion (goto-char (point-min))
                                   (re-search-forward "^  3 ")
                                   (line-beginning-position)))))
      ;; Both panes pad to the same lines, so scrolling syncs line for line.
      (let* ((ow (review-session-old-window s)) (nw (review-session-new-window s))
             (start (with-current-buffer (window-buffer ow)
                      (save-excursion (goto-char (point-min)) (forward-line 3) (point)))))
        (set-window-start ow start)
        (review-session--sync-scroll ow start)
        (should (= (with-current-buffer (window-buffer nw)
                     (1- (line-number-at-pos (window-start nw))))
                   3))))))

(ert-deftest review-session-pane-keeps-source-directory ()
  (save-window-excursion
    (let ((src (review-session-test--source review-session-test--spec)))
      (setf (review-source-directory src) temporary-file-directory)
      (let ((s (review-session-start src)))
        (unwind-protect
            (with-current-buffer (review-session-new-buffer s)
              (should (equal default-directory temporary-file-directory)))
          (review-session-quit))))))

(provide 'review-session-test)
