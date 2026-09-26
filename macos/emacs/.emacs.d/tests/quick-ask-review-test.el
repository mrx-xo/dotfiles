;;; quick-ask-review-test.el --- Quick ask from review panes -*- lexical-binding: t; -*-
(require 'ert)
(require 'review-session-test)
(require 'syzygy-park)
(require 'posframe)
(require 'evil)
(require 'markdown-mode)

;; Focused batch runs load just the existing Quick Ask block.  Full-config
;; smoke runs already have it from init.el, and skip this extraction.
(unless (fboundp 'mr-x/quick-ask)
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "../emacs.org" (file-name-directory (or load-file-name buffer-file-name))))
    (goto-char (point-min))
    (search-forward ";;; Quick Ask -")
    (beginning-of-line)
    (let ((start (point)))
      (search-forward "#+end_src")
      (beginning-of-line)
      (eval-region start (point)))))

(ert-deftest quick-ask-response-map-has-four-exits ()
  (dolist (binding '(("q" . mr-x/quick-ask--dismiss)
                     ("c" . mr-x/quick-ask--surface-session)
                     ("u" . mr-x/quick-ask--park)
                     ("y" . mr-x/quick-ask--copy)))
    (should (eq (lookup-key mr-x/quick-ask-response-map (kbd (car binding)))
                (cdr binding)))))

(ert-deftest quick-ask-park-keeps-review-origin-and-clean-context ()
  (review-session-test--with s
    (let ((transient-mark-mode t)
          (syzygy-park-file (make-temp-file "review-park"))
          (syzygy-park--project-items (make-hash-table :test #'equal))
          popup)
      (unwind-protect
          (progn
            (select-window (review-session-new-window s))
            (goto-char (point-min)) (forward-line 1)
            (push-mark (point) t t) (goto-char (point-max))
            (mr-x/quick-ask)
            (setq popup (get-buffer "*quick-ask*"))
            (with-current-buffer popup
              (setq mr-x/quick-ask--question "why?"
                    mr-x/quick-ask--response "because.")
              (mr-x/quick-ask--park))
            (let* ((scope (with-current-buffer (review-session-new-buffer s)
                            (syzygy-park--scope-here)))
                   (items (syzygy-park--items scope))
                   (item (car items)))
              (should (= (length items) 1))
              (should (equal (plist-get item :question) "why?"))
              (should (equal (plist-get item :context) "  2)"))
              (should (equal (plist-get (plist-get item :origin) :label) "a.el:2-2"))))
        (when (buffer-live-p popup) (kill-buffer popup))
        (delete-file syzygy-park-file)))))

(ert-deftest quick-ask-posframe-is-anchored-in-the-source-window ()
  (review-session-test--with s
    (let ((buf (get-buffer-create "*quick-ask*")) shown)
      (unwind-protect
          (progn
            (with-current-buffer buf
              (setq-local mr-x/quick-ask--source-buffer (review-session-new-buffer s))
              (setq-local mr-x/quick-ask--source-region (cons 1 5)))
            (select-window (review-session-old-window s))
            (switch-to-buffer (get-buffer-create " *quick-ask-other*"))
            (cl-letf (((symbol-function 'posframe-show)
                       (lambda (_buf &rest args)
                         (setq shown (list (current-buffer) args)) nil))
                      ((symbol-function 'posframe-workable-p) (lambda () t)))
              (mr-x/quick-ask--display-response buf))
            (should (eq (car shown) (review-session-new-buffer s)))
            (should (integer-or-marker-p (plist-get (cadr shown) :position))))
        (when (buffer-live-p buf) (kill-buffer buf))
        (kill-buffer " *quick-ask-other*")))))

(ert-deftest quick-ask-copy-copies-only-the-response-and-dismisses ()
  (let ((buf (get-buffer-create "*quick-ask*")) (kill-ring nil))
    (with-current-buffer buf
      (setq-local mr-x/quick-ask--response "The answer.")
      (mr-x/quick-ask--copy))
    (should (equal (car kill-ring) "The answer."))
    (should-not (buffer-live-p buf))))

(ert-deftest quick-ask-dismiss-hides-child-frame-without-losing-panes ()
  (review-session-test--with s
    (let ((buf (get-buffer-create "*quick-ask*")) hidden)
      (with-current-buffer buf
        (setq-local mr-x/quick-ask--posframe t
                    mr-x/quick-ask--source-buffer (review-session-new-buffer s))
        (cl-letf (((symbol-function 'posframe-hide) (lambda (b) (setq hidden b))))
          (mr-x/quick-ask--dismiss)))
      (should hidden)
      (should-not (buffer-live-p buf))
      (should (window-live-p (review-session-new-window s))))))


(ert-deftest quick-ask-park-survives-source-navigation ()
  (review-session-test--with s
    (let ((transient-mark-mode t)
          (syzygy-park-file (make-temp-file "review-park"))
          (syzygy-park--project-items (make-hash-table :test #'equal)))
      (unwind-protect
          (progn
            (select-window (review-session-new-window s))
            (goto-char (point-min)) (forward-line 1)
            (push-mark (point) t t) (goto-char (point-max))
            (mr-x/quick-ask)
            (review-session-next-file)
            (with-current-buffer "*quick-ask*"
              (setq mr-x/quick-ask--question "Still about a.el")
              (mr-x/quick-ask--park))
            (with-current-buffer (review-session-new-buffer s)
              (let ((item (car (syzygy-park--items (syzygy-park--scope-here)))))
                (should (equal (plist-get item :context) "  2)"))
                (should (equal (plist-get (plist-get item :origin) :label) "a.el:2-2")))))
        (when (get-buffer "*quick-ask*") (kill-buffer "*quick-ask*"))
        (delete-file syzygy-park-file)))))

(ert-deftest quick-ask-response-is-the-design-card ()
  (let ((buf (get-buffer-create "*quick-ask*")))
    (unwind-protect
        (cl-letf (((symbol-function 'mr-x/quick-ask--display-response) #'ignore))
          (with-current-buffer buf
            (mr-x/quick-ask-mode)
            (setq-local mr-x/quick-ask--source-origin '(:label "a.el 3-4"))
            (mr-x/quick-ask--show-response "why?" "Because **cur**.")
            (should-not header-line-format)
            (should (string-match-p "ASK.*a\\.el 3-4" (buffer-string)))
            (should (string-match-p "Because cur\\." (buffer-string)))
            (should (string-match-p "continue in chat" (buffer-string)))
            (should (equal mr-x/quick-ask--response "Because **cur**."))))
      (kill-buffer buf))))

(defvar agent-shell-preferred-agent-config nil)

(ert-deftest quick-ask-runs-one-session-per-project-root ()
  (let* ((repo (file-name-as-directory (make-temp-file "qa-repo" t)))
         (sub (expand-file-name "lisp/deep/" repo))
         (other (file-name-as-directory (make-temp-file "qa-other" t)))
         (mr-x/quick-ask--sessions (make-hash-table :test #'equal))
         (mr-x/quick-ask--shell-buffer nil)
         started)
    (unwind-protect
        (progn
          (make-directory sub t)
          (let ((default-directory repo)) (call-process "git" nil nil nil "init" "-q"))
          (cl-letf (((symbol-function 'agent-shell--start)
                     (lambda (&rest _)
                       (push default-directory started)
                       (generate-new-buffer " *qa-fake-shell*")))
                    ((symbol-function 'major-pane-exclude-buffer) #'ignore)
                    ((symbol-function 'mr-x/quick-ask--session-healthy-p) #'buffer-live-p))
            (let ((a (mr-x/quick-ask--ensure-session sub))
                  (b (mr-x/quick-ask--ensure-session repo))
                  (c (mr-x/quick-ask--ensure-session other)))
              ;; The agent runs at the project root, once per project.
              (should (equal started (list (file-truename other) (file-truename repo))))
              (should (eq a b))
              (should-not (eq a c))
              (should (eq mr-x/quick-ask--shell-buffer c)))))
      (maphash (lambda (_ b) (when (buffer-live-p b) (kill-buffer b))) mr-x/quick-ask--sessions)
      (delete-directory repo t) (delete-directory other t))))

(ert-deftest quick-ask-popup-grows-to-its-content ()
  ;; posframe counts lines, but the card pads rows in pixels: a line-count
  ;; height hid the bottom of the answer behind a scroll.
  (review-session-test--with s
    (let ((buf (get-buffer-create "*quick-ask*")) calls)
      (unwind-protect
          (progn
            (with-current-buffer buf
              (setq-local mr-x/quick-ask--source-buffer (review-session-new-buffer s))
              (setq-local mr-x/quick-ask--source-region (cons 1 5)))
            (cl-letf (((symbol-function 'posframe-show)
                       (lambda (_buf &rest args) (push args calls) nil))
                      ((symbol-function 'posframe-workable-p) (lambda () t))
                      ((symbol-function 'mr-x/quick-ask--content-lines) (lambda (&rest _) 12)))
              (mr-x/quick-ask--display-response buf))
            (let ((last (car calls)))
              (should (= (plist-get last :height) 12))
              (should (>= (plist-get last :max-height) 12))))
        (when (buffer-live-p buf) (kill-buffer buf))))))

(ert-deftest quick-ask-popup-that-fits-cannot-scroll ()
  ;; Emacs lets any window scroll its last line to the top; a card that
  ;; fits whole stays pinned at its start.
  (save-window-excursion
    (let ((buf (get-buffer-create " *qa-pin*")))
      (unwind-protect
          (progn
            (switch-to-buffer buf)
            (insert (mapconcat #'number-to-string (number-sequence 1 5) "\n"))
            (setq-local mr-x/quick-ask--fits t)
            (let ((w (selected-window)))
              (set-window-start w (save-excursion (goto-char (point-min)) (forward-line 3) (point)))
              (mr-x/quick-ask--pin-start w (window-start w))
              (should (= (window-start w) (point-min)))
              (setq-local mr-x/quick-ask--fits nil)
              (set-window-start w 5)
              (mr-x/quick-ask--pin-start w 5)
              (should (= (window-start w) 5))))
        (kill-buffer buf)))))

(defmacro quick-ask-test--posframes (calls hidden &rest body)
  "Run BODY with posframe stubbed: shows pushed on CALLS, hides on HIDDEN."
  (declare (indent 2))
  `(cl-letf (((symbol-function 'posframe-show) (lambda (b &rest args) (push (cons b args) ,calls) nil))
             ((symbol-function 'posframe-hide) (lambda (b) (push b ,hidden)))
             ((symbol-function 'posframe-workable-p) (lambda () t))
             ((symbol-function 'mr-x/quick-ask--content-lines) (lambda (&rest _) 10))
             ((symbol-function 'mr-x/quick-ask--content-pixels) (lambda (&rest _) nil)))
     ,@body))

(defun quick-ask-test--answer-buffer (source)
  (let ((buf (get-buffer-create "*quick-ask*")))
    (with-current-buffer buf
      (mr-x/quick-ask-mode)
      (setq-local mr-x/quick-ask--source-buffer source
                  mr-x/quick-ask--source-region nil
                  mr-x/quick-ask--placement nil
                  mr-x/quick-ask--hidden nil))
    buf))

(ert-deftest quick-ask-floats-over-any-buffer-by-default ()
  (save-window-excursion
    (let* ((source (get-buffer-create " *qa-code*")) calls hidden
           (buf (progn (switch-to-buffer source) (insert "code\n") (quick-ask-test--answer-buffer source))))
      (unwind-protect
          (quick-ask-test--posframes calls hidden
            (let ((mr-x/quick-ask-placement 'float))
              (mr-x/quick-ask--show buf))
            (should (eq (car (car calls)) buf))
            (should (integer-or-marker-p (plist-get (cdr (car calls)) :position)))
            (should-not (get-buffer-window buf)))
        (kill-buffer buf) (kill-buffer source)))))

(ert-deftest quick-ask-popup-shows-a-cursor ()
  ;; posframe hides the cursor unless told otherwise; typing blind is jarring.
  (save-window-excursion
    (let* ((source (get-buffer-create " *qa-code*")) calls hidden
           (buf (progn (switch-to-buffer source) (quick-ask-test--answer-buffer source))))
      (unwind-protect
          (quick-ask-test--posframes calls hidden
            (let ((mr-x/quick-ask-placement 'float))
              (mr-x/quick-ask--show buf))
            (should (eq (plist-get (cdr (car calls)) :cursor) 'bar))
            (with-current-buffer buf (setq mr-x/quick-ask--phase 'response))
            (setq calls nil)
            (let ((mr-x/quick-ask-placement 'float))
              (mr-x/quick-ask--show buf))
            (should (eq (plist-get (cdr (car calls)) :cursor) 'box)))
        (kill-buffer buf) (kill-buffer source)))))

(ert-deftest quick-ask-sends-both-sides-of-a-review-selection ()
  (review-session-test--with s
    (review-session-next-file)
    (select-window (review-session-new-window s))
    (let ((transient-mark-mode t) calls hidden)
      (unwind-protect
          (quick-ask-test--posframes calls hidden
            (goto-char (point-min)) (push-mark (point) t t) (goto-char (point-max))
            (mr-x/quick-ask)
            (with-current-buffer "*quick-ask*"
              (let ((item (car mr-x/quick-ask--context-items)))
                (should (string-match-p "^- y$" (plist-get item :content)))
                (should (string-match-p "^\\+ Y$" (plist-get item :content))))
              ;; Parking keeps the plain source text.
              (should (equal mr-x/quick-ask--source-context "x\nY\nz\nw"))))
        (when (get-buffer "*quick-ask*") (kill-buffer "*quick-ask*"))))))

(ert-deftest quick-ask-docks-at-the-bottom-when-asked ()
  (save-window-excursion
    (let* ((source (get-buffer-create " *qa-code*")) calls hidden
           (buf (progn (switch-to-buffer source) (quick-ask-test--answer-buffer source))))
      (unwind-protect
          (quick-ask-test--posframes calls hidden
            (let ((mr-x/quick-ask-placement 'bottom))
              (mr-x/quick-ask--show buf))
            (should-not calls)
            (should (window-live-p (get-buffer-window buf))))
        (kill-buffer buf) (kill-buffer source)))))

(ert-deftest quick-ask-hides-and-comes-back-with-its-state ()
  (save-window-excursion
    (let* ((source (get-buffer-create " *qa-code*")) calls hidden
           (buf (progn (switch-to-buffer source) (quick-ask-test--answer-buffer source))))
      (unwind-protect
          (quick-ask-test--posframes calls hidden
            (with-current-buffer buf (insert "typed so far"))
            (let ((mr-x/quick-ask-placement 'float))
              (mr-x/quick-ask--show buf)
              (mr-x/quick-ask-toggle)
              (should (equal hidden (list buf)))
              (should (buffer-local-value 'mr-x/quick-ask--hidden buf))
              (setq calls nil)
              (mr-x/quick-ask-toggle)
              (should (eq (car (car calls)) buf))
              (should-not (buffer-local-value 'mr-x/quick-ask--hidden buf))
              (should (equal (with-current-buffer buf (buffer-string)) "typed so far"))))
        (kill-buffer buf) (kill-buffer source)))))

(ert-deftest quick-ask-switches-between-float-and-bottom ()
  (save-window-excursion
    (let* ((source (get-buffer-create " *qa-code*")) calls hidden
           (buf (progn (switch-to-buffer source) (quick-ask-test--answer-buffer source))))
      (unwind-protect
          (quick-ask-test--posframes calls hidden
            (let ((mr-x/quick-ask-placement 'float))
              (mr-x/quick-ask--show buf)
              (with-current-buffer buf (mr-x/quick-ask-toggle-placement))
              (should (memq buf hidden))
              (should (window-live-p (get-buffer-window buf)))
              (should (eq (buffer-local-value 'mr-x/quick-ask--placement buf) 'bottom))
              (setq calls nil)
              (with-current-buffer buf (mr-x/quick-ask-toggle-placement))
              (should (eq (car (car calls)) buf))
              (should-not (get-buffer-window buf))))
        (kill-buffer buf) (kill-buffer source)))))

(ert-deftest quick-ask-answer-waits-while-hidden-and-notifies ()
  (save-window-excursion
    (let* ((source (get-buffer-create " *qa-code*")) calls hidden notes
           (mr-x/quick-ask-notify-functions (list (lambda (note) (push note notes))))
           (buf (progn (switch-to-buffer source) (quick-ask-test--answer-buffer source))))
      (unwind-protect
          (quick-ask-test--posframes calls hidden
            (with-current-buffer buf
              (setq mr-x/quick-ask--hidden t)
              (mr-x/quick-ask--show-response "why?" "because"))
            (should-not calls)
            (should (eq (car notes) 'ready))
            (should (eq mr-x/quick-ask-notification 'ready))
            (mr-x/quick-ask-toggle)
            (should calls)
            (should-not mr-x/quick-ask-notification))
        (kill-buffer buf) (kill-buffer source)))))

(ert-deftest quick-ask-question-box-is-a-card ()
  (save-window-excursion
    (switch-to-buffer (get-buffer-create " *qa-code*"))
    (insert "code\n")
    (let (calls hidden)
      (unwind-protect
          (quick-ask-test--posframes calls hidden
            (mr-x/quick-ask)
            (with-current-buffer "*quick-ask*"
              (should-not header-line-format)
              (should (string-match-p "ASK" (buffer-string)))
              (dolist (hint '("RET" "ask" "C-c C-q" "hide" "C-c C-t" "dock"))
                (should (string-match-p (regexp-quote hint) (buffer-string))))
              (should (eq (lookup-key mr-x/quick-ask-input-map (kbd "C-c C-q")) #'mr-x/quick-ask-hide))
              (should (eq (lookup-key mr-x/quick-ask-input-map (kbd "C-c C-t")) #'mr-x/quick-ask-toggle-placement))))
        (when (get-buffer "*quick-ask*") (kill-buffer "*quick-ask*"))
        (kill-buffer " *qa-code*")))))

(ert-deftest quick-ask-popup-stays-inside-the-frame ()
  ;; A card anchored near the right edge was clipped; near the bottom it
  ;; belongs above the selection.
  (cl-letf (((symbol-function 'posframe-poshandler-point-bottom-left-corner)
             (lambda (_info) '(700 . 300)))
            ((symbol-function 'posframe-poshandler-point-bottom-left-corner-upward)
             (lambda (_info) '(700 . 50))))
    (should (equal (mr-x/quick-ask--poshandler
                    '(:parent-frame-width 1000 :parent-frame-height 800
                      :posframe-width 600 :posframe-height 200))
                   '(396 . 300)))
    (should (equal (mr-x/quick-ask--poshandler
                    '(:parent-frame-width 2000 :parent-frame-height 400
                      :posframe-width 600 :posframe-height 200))
                   '(700 . 50)))))

(ert-deftest quick-ask-strips-agent-notices-and-thinking ()
  ;; A project's first question goes to a fresh session, whose output
  ;; starts with agent-shell's session notice.
  (should (equal (mr-x/quick-ask--strip-thinking
                  "\n▶ Notices\n\n[session/create] sessionId=6989 phase=register\n\n\nThe answer.\n\nNext: more.\n\n")
                 "The answer.\n\nNext: more."))
  (should (equal (mr-x/quick-ask--strip-thinking
                  "▶ Thinking\n\nreasoning here\n\n▶ Notices\n\n[session/create] x\n\nThe answer.")
                 "The answer."))
  (should (equal (mr-x/quick-ask--strip-thinking "▶ A heading the model wrote\n\nkeep this")
                 "▶ A heading the model wrote\n\nkeep this")))

(ert-deftest quick-ask-terminal-fallback-reuses-bottom-window ()
  (review-session-test--with s
    (select-window (review-session-new-window s))
    (mr-x/quick-ask)
    (let* ((buf (get-buffer "*quick-ask*"))
           (window (get-buffer-window buf)))
      (unwind-protect
          (cl-letf (((symbol-function 'posframe-workable-p) (lambda () nil)))
            (with-current-buffer buf
              (mr-x/quick-ask--show-response "why" "because"))
            (should (eq (get-buffer-window buf) window))
            (should (buffer-live-p (review-session-new-buffer s))))
        (when (buffer-live-p buf)
          (with-current-buffer buf (mr-x/quick-ask--dismiss)))))))

(provide 'quick-ask-review-test)
;;; quick-ask-review-test.el ends here
