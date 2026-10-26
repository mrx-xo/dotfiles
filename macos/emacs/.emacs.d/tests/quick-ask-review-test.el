;;; quick-ask-review-test.el --- Quick ask from review panes -*- lexical-binding: t; -*-
(require 'ert)
(require 'review-session-test)
(require 'syzygy-park)
(require 'posframe)
(require 'evil)
(require 'markdown-mode)
(require 'agent-shell-ui)
(require 'agent-shell-markdown)
(require 'agent-shell)

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

(ert-deftest quick-ask-box-has-no-completion-popup ()
  ;; A question is prose; corfu's auto popup stays off in the box.
  (with-temp-buffer
    (mr-x/quick-ask-mode)
    (should (local-variable-p 'corfu-auto))
    (should-not corfu-auto)))

(ert-deftest quick-ask-box-shows-the-evil-state-in-its-footer ()
  (with-temp-buffer
    (mr-x/quick-ask-mode)
    (evil-local-mode 1)
    (insert "question\n" (review-panel-ask-footer '(("RET" "ask" fg))))
    (cl-letf (((symbol-function 'mr-x/quick-ask--state-tag)
               (lambda () (format "<%s>" evil-state))))
      (evil-insert-state)
      (mr-x/quick-ask--show-state)
      (let* ((row (text-property-any (point-min) (point-max) 'review-ask-footer t))
             (ov mr-x/quick-ask--state-overlay))
        (should row)
        (should (= (overlay-start ov) row))
        (should (equal (overlay-get ov 'before-string) "<insert>"))
        (evil-normal-state)
        (mr-x/quick-ask--show-state)
        (should (equal (overlay-get ov 'before-string) "<normal>"))
        ;; A redraw without a footer takes the tag away.
        (let ((inhibit-read-only t)) (erase-buffer))
        (mr-x/quick-ask--show-state)
        (should-not (overlay-buffer ov))))))

(ert-deftest quick-ask-waiting-point-sits-on-the-thinking-line ()
  ;; After sending, the cursor waits by the spinner, not on the tall
  ;; context row at the top.
  (with-temp-buffer
    (mr-x/quick-ask-mode)
    (review-panel-ask-waiting "origin" "why?")
    (goto-char (point-min))
    (mr-x/quick-ask--wait-point)
    (should (= (point) (line-beginning-position)))
    (should (text-property-any (point) (line-end-position) 'review-ask-anim t))))

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
                       (let ((buf (generate-new-buffer " *qa-fake-shell*")))
                         (with-current-buffer buf
                           (setq-local major-mode 'agent-shell-mode
                                       agent-shell--state `((:buffer . ,buf)
                                                            (:event-subscriptions . nil))))
                         buf)))
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
            (setq-local mr-x/quick-ask--scroll-limit (cons (point-min) 0))
            (let ((w (selected-window)))
              (set-window-start w (save-excursion (goto-char (point-min)) (forward-line 3) (point)))
              (mr-x/quick-ask--clamp-scroll w (window-start w))
              (should (= (window-start w) (point-min)))
              ;; A wheel scroll moves the start itself and passes no START.
              (set-window-start w 5)
              (mr-x/quick-ask--clamp-scroll w)
              (should (= (window-start w) (point-min)))
              (setq-local mr-x/quick-ask--scroll-limit nil)
              (set-window-start w 5)
              (mr-x/quick-ask--clamp-scroll w 5)
              (should (= (window-start w) 5))))
        (kill-buffer buf)))))

(ert-deftest quick-ask-popup-taller-than-its-card-stops-at-the-last-row ()
  ;; A card too tall for its popup scrolls, but only until its footer is
  ;; on the bottom edge: a wheel flick used to scroll the whole card away.
  (save-window-excursion
    (let ((buf (get-buffer-create " *qa-pin*")))
      (unwind-protect
          (progn
            (switch-to-buffer buf)
            (insert (mapconcat #'number-to-string (number-sequence 1 9) "\n"))
            (setq-local mr-x/quick-ask--scroll-limit (cons 7 0))
            (let ((w (selected-window)))
              (set-window-start w (point-max))
              (mr-x/quick-ask--clamp-scroll w)
              (should (= (window-start w) 7))
              (set-window-start w 3)
              (mr-x/quick-ask--clamp-scroll w)
              (should (= (window-start w) 3))))
        (kill-buffer buf)))))

(ert-deftest quick-ask-popup-limits-wheel-scrolls-too ()
  ;; A wheel scroll sets the window start directly, which never runs
  ;; `window-scroll-functions': the limit is also checked before redisplay.
  (save-window-excursion
    (let ((buf (get-buffer-create " *qa-pin*")))
      (unwind-protect
          (progn
            (switch-to-buffer buf)
            (insert "card\n")
            (cl-letf (((symbol-function 'mr-x/quick-ask--posframe-frame)
                       (lambda (&rest _) (selected-frame)))
                      ((symbol-function 'mr-x/quick-ask--content-lines) (lambda (&rest _) 3))
                      ((symbol-function 'mr-x/quick-ask--content-pixels) (lambda (&rest _) 3))
                      ((symbol-function 'set-frame-height) #'ignore))
              (mr-x/quick-ask--fit-float buf 10))
            (should (equal mr-x/quick-ask--scroll-limit (cons (point-min) 0)))
            (should (memq #'mr-x/quick-ask--clamp-scroll pre-redisplay-functions))
            (should (memq #'mr-x/quick-ask--clamp-scroll window-scroll-functions)))
        (kill-buffer buf)))))

(defmacro quick-ask-test--posframes (calls hidden &rest body)
  "Run BODY with posframe stubbed: shows pushed on CALLS, hides on HIDDEN."
  (declare (indent 2))
  `(cl-letf (((symbol-function 'posframe-show)
              ;; Like the real one, which turns line numbers off in its buffer.
              (lambda (b &rest args) (with-current-buffer b (setq-local display-line-numbers nil))
                (push (cons b args) ,calls) nil))
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
            ;; The frame default is a box, as in any frame; evil then sets
            ;; the buffer's cursor per state, after every show.
            (with-current-buffer buf (evil-local-mode 1) (evil-insert-state))
            (let ((mr-x/quick-ask-placement 'float))
              (mr-x/quick-ask--show buf))
            (should (eq (plist-get (cdr (car calls)) :cursor) 'box))
            (with-current-buffer buf
              (setq cursor-type 'box)       ; what posframe-show leaves behind
              (setq mr-x/quick-ask--phase 'response)
              (evil-normal-state))
            (setq calls nil)
            (let ((mr-x/quick-ask-placement 'float))
              (mr-x/quick-ask--show buf))
            (should (eq (plist-get (cdr (car calls)) :cursor) 'box))
            (with-current-buffer buf
              ;; Normal state asks for the frame default: t, which is the box.
              (should (eq cursor-type t))))
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

(ert-deftest quick-ask-popup-never-covers-the-rows-it-asks-about ()
  ;; A tall answer used to flip above the selection's last line and get
  ;; pushed down to the frame's top, burying the whole selection.
  (let ((buf (generate-new-buffer " *qa-rows*")))
    (unwind-protect
        (cl-letf (((symbol-function 'posframe-poshandler-point-bottom-left-corner)
                   (lambda (_info) '(700 . 0))))
          (cl-flet ((y (rows frame-height height)
                      (with-current-buffer buf (setq mr-x/quick-ask--source-rows rows))
                      (cdr (mr-x/quick-ask--poshandler
                            (list :parent-frame-width 2000 :parent-frame-height frame-height
                                  :posframe-width 600 :posframe-height height
                                  :posframe-buffer buf)))))
            ;; Room below: right under the last row.
            (should (= (y '(100 . 200) 800 300) 200))
            ;; Room only above: the card ends just short of the first row.
            (should (= (y '(500 . 700) 800 400) 96))
            ;; Room nowhere: the larger gap, still clear of the rows.
            (should (= (y '(516 . 686) 1357 972) 686))
            (should (= (y '(600 . 700) 800 650) 0))))
      (kill-buffer buf))))

(ert-deftest quick-ask-popup-is-capped-to-the-gap-it-sits-in ()
  ;; Rows at 500..700 px of an 800 px frame, 20 px lines: 24 lines of room
  ;; above, 4 below.
  (should (= (mr-x/quick-ask--float-cap '(500 . 700) 800 20 10) 24))
  ;; A card that fits below stays below.
  (should (= (mr-x/quick-ask--float-cap '(100 . 200) 800 20 10) 29))
  ;; The larger gap when it fits in neither.
  (should (= (mr-x/quick-ask--float-cap '(516 . 686) 1357 20 60) 33))
  ;; Never too small to read, even when the rows fill the frame.
  (should (= (mr-x/quick-ask--float-cap '(10 . 790) 800 20 10) 6)))

(defun quick-ask-test--stream-chunk (chunk)
  "Deliver CHUNK before rendering, in the same order as agent-shell."
  (agent-shell--emit-event :event 'agent-message-chunk :data `((:text-chunk . ,chunk)))
  (goto-char (point-max))
  (let ((range (agent-shell-ui-update-fragment
                (agent-shell-ui-make-fragment-model
                 :namespace-id 1
                 :block-id (format "%s-agent_message_chunk"
                                   (map-elt agent-shell--state :chunked-group-count))
                 :body chunk)
                :append t)))
    (save-restriction
      (narrow-to-region (map-nested-elt range '(:body :start))
                        (map-nested-elt range '(:body :end)))
      (agent-shell-markdown-replace-markup :render-images nil))))

(ert-deftest quick-ask-response-streaming-keeps-exact-markdown ()
  ;; Rendering a partial list item can stash incomplete source markup.
  ;; Quick Ask must capture raw events instead of reconstructing that text.
  (with-temp-buffer
    (let* ((proc (make-pipe-process :name "quick-ask-stream-test"
                                    :buffer (current-buffer) :noquery t))
           (mr-x/quick-ask--sessions (make-hash-table :test #'equal))
           (mr-x/quick-ask--shell-buffer nil)
           (agent-shell-inhibit-system-sleep nil)
           (inhibit-read-only t))
      (unwind-protect
          (progn
            (setq-local major-mode 'agent-shell-mode
                        shell-maker--config t
                        agent-shell--state `((:buffer . ,(current-buffer))
                                             (:event-subscriptions . nil)
                                             (:chunked-group-count . 1)))
            (puthash (mr-x/quick-ask--project-directory default-directory)
                     (current-buffer) mr-x/quick-ask--sessions)
            ;; Reusing a session must not duplicate the text subscriptions.
            (mr-x/quick-ask--ensure-session default-directory)
            (mr-x/quick-ask--ensure-session default-directory)
            (agent-shell--emit-event :event 'agent-message-chunk
                                     :data '((:text-chunk . "Earlier turn.")))
            (agent-shell--emit-event :event 'input-submitted :data '((:prompt . "Why?")))
            (setq-local comint-last-input-end (copy-marker (point-min)))
            (dolist (chunk '("- **Loc" "al selected:** `" "p` stays unchanged.\n"
                             "- `cmd()" "` passes `'/cmd?'`."))
              (quick-ask-test--stream-chunk chunk))
            (agent-shell--emit-event :event 'tool-call-update
                                     :data '((:tool-call-id . "tool") (:tool-call . "Private tool details")))
            (map-put! agent-shell--state :chunked-group-count 2)
            (quick-ask-test--stream-chunk "## Caveat\n\nKeep it local.")
            (agent-shell--emit-event :event 'agent-message-chunk
                                     :data '((:text-chunk . nil)))
            (set-marker (process-mark proc) (point-max))
            (should (equal (mr-x/quick-ask--last-response)
                           "- **Local selected:** `p` stays unchanged.\n- `cmd()` passes `'/cmd?'`.\n\n## Caveat\n\nKeep it local."))
            (let ((response (mr-x/quick-ask--last-response)))
              (with-temp-buffer
                (mr-x/quick-ask-mode)
                (cl-letf (((symbol-function 'mr-x/quick-ask--display-response) #'ignore))
                  (mr-x/quick-ask--show-response "Why?" response))
                (should-not (string-match-p "\\*\\*\\|`\\|##" (buffer-string)))
                (should (string-match-p (regexp-quote "'/cmd?'") (buffer-string)))))
            ;; A later turn with only tools must not reuse the previous answer.
            (agent-shell--emit-event :event 'input-submitted :data '((:prompt . "Next?")))
            (should-not (mr-x/quick-ask--last-response)))
        (delete-process proc)))))

(ert-deftest quick-ask-response-renders-markdown-without-changing-code ()
  (with-temp-buffer
    (mr-x/quick-ask-mode)
    (let ((answer "## Answer\n\nUse **shared** and `light`.\n\n```text\n# literal\n**keep me**\n- keep this too\n```"))
      (cl-letf (((symbol-function 'mr-x/quick-ask--display-response) #'ignore))
        (mr-x/quick-ask--show-response "# untouched question" answer))
      (should (equal mr-x/quick-ask--response answer))
      (goto-char (point-min))
      (should (search-forward "# untouched question" nil t))
      (should (search-forward "Answer" nil t))
      (should (get-text-property (1- (point)) 'agent-shell-markdown-source))
      (should (search-forward "shared" nil t))
      (should (equal (get-text-property (1- (point)) 'agent-shell-markdown-source)
                     "**shared**"))
      (should (search-forward "# literal\n**keep me**\n- keep this too" nil t))
      (should-not (string-match-p "```" (buffer-string))))))

(ert-deftest quick-ask-response-keeps-answer-text-that-looks-like-activity ()
  (with-temp-buffer
    (mr-x/quick-ask-mode)
    (cl-letf (((symbol-function 'mr-x/quick-ask--display-response) #'ignore))
      (mr-x/quick-ask--show-response "why?" "▶ Thinking\n\nAn example heading.\n\nKeep it."))
    (should (equal mr-x/quick-ask--response
                   "▶ Thinking\n\nAn example heading.\n\nKeep it."))))

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

;;; Relative numbers, keyboard focus, file links

(ert-deftest quick-ask-answer-has-relative-line-numbers ()
  ;; The card is read in evil normal state: `5j' needs numbers to count by.
  ;; Only the answer is numbered; the ASK row and the exits are chrome.
  (let ((buf (get-buffer-create "*quick-ask*")))
    (unwind-protect
        (cl-letf (((symbol-function 'mr-x/quick-ask--display-response) #'ignore))
          (with-current-buffer buf
            (mr-x/quick-ask-mode)
            (should-not display-line-numbers)
            (mr-x/quick-ask--show-response "why?" "one\n\ntwo\nthree")
            (should (eq display-line-numbers 'visual))
            (goto-char (point-min))
            (should (get-text-property (point) 'display-line-numbers-disable))
            (search-forward "why?")
            (should (get-text-property (line-beginning-position) 'display-line-numbers-disable))
            (search-forward "two")
            (should-not (get-text-property (line-beginning-position) 'display-line-numbers-disable))
            (search-forward "dismiss")
            (should (get-text-property (line-beginning-position) 'display-line-numbers-disable))))
      (kill-buffer buf))))

(ert-deftest quick-ask-answer-keeps-its-line-numbers-in-the-popup ()
  ;; posframe switches line numbers off in the buffer it shows; the answer
  ;; gets them back after every show.
  (save-window-excursion
    (let* ((source (get-buffer-create " *qa-code*")) calls hidden
           (buf (progn (delete-other-windows) (switch-to-buffer source) (insert "code\n")
                       (quick-ask-test--answer-buffer source))))
      (unwind-protect
          (quick-ask-test--posframes calls hidden
            (cl-letf (((symbol-function 'mr-x/quick-ask--display-response) #'ignore))
              (with-current-buffer buf
                (setq-local mr-x/quick-ask--source-origin '(:label "x"))
                (mr-x/quick-ask--show-response "why?" "one\ntwo")))
            (let ((mr-x/quick-ask-placement 'float))
              (mr-x/quick-ask--show buf))
            (should calls)
            (should (eq (buffer-local-value 'display-line-numbers buf) 'visual)))
        (kill-buffer buf) (kill-buffer source)))))

(ert-deftest quick-ask-toggle-focuses-a-visible-card-before-hiding-it ()
  ;; SPC Q from outside a visible card jumps into it; from inside, it hides.
  (save-window-excursion
    (let* ((source (get-buffer-create " *qa-code*")) calls hidden
           (buf (progn (delete-other-windows) (switch-to-buffer source)
                       (quick-ask-test--answer-buffer source))))
      (unwind-protect
          (quick-ask-test--posframes calls hidden
            (let ((mr-x/quick-ask-placement 'bottom))
              (mr-x/quick-ask--show buf)
              (should (eq (window-buffer) buf))
              (select-window (get-buffer-window source))
              (mr-x/quick-ask-toggle)
              (should (eq (window-buffer) buf))
              (should-not (buffer-local-value 'mr-x/quick-ask--hidden buf))
              (mr-x/quick-ask-toggle)
              (should (buffer-local-value 'mr-x/quick-ask--hidden buf))
              (should (eq (window-buffer) source))))
        (kill-buffer buf) (kill-buffer source)))))

(ert-deftest quick-ask-toggle-focuses-the-floating-card ()
  (save-window-excursion
    (let* ((source (get-buffer-create " *qa-code*")) calls hidden focused
           (buf (progn (delete-other-windows) (switch-to-buffer source)
                       (quick-ask-test--answer-buffer source))))
      (unwind-protect
          (quick-ask-test--posframes calls hidden
            (cl-letf (((symbol-function 'mr-x/quick-ask--posframe-frame)
                       (lambda (_) (selected-frame)))
                      ((symbol-function 'select-frame-set-input-focus)
                       (lambda (frame &rest _) (push frame focused))))
              (let ((mr-x/quick-ask-placement 'float))
                (mr-x/quick-ask--show buf)
                (setq focused nil)
                ;; The card is up, but keys go to the source window.
                (should (eq (window-buffer) source))
                (mr-x/quick-ask-toggle)
                (should (equal focused (list (selected-frame))))
                (should-not hidden)
                (should-not (buffer-local-value 'mr-x/quick-ask--hidden buf)))))
        (kill-buffer buf) (kill-buffer source)))))

(ert-deftest quick-ask-file-links-open-in-the-source-window ()
  ;; A file link in the answer opens where the question came from, never in
  ;; the card's own window; the card hides so SPC Q brings it back.
  (save-window-excursion
    (let* ((source (get-buffer-create " *qa-code*")) calls hidden
           (file (make-temp-file "qa" nil ".el" "x\ny\n"))
           (buf (progn (delete-other-windows) (switch-to-buffer source)
                       (quick-ask-test--answer-buffer source)))
           (source-window (selected-window)))
      (unwind-protect
          (quick-ask-test--posframes calls hidden
            (let ((mr-x/quick-ask-placement 'bottom))
              (mr-x/quick-ask--show buf)
              (should (eq (window-buffer) buf))
              (let ((window (with-current-buffer buf
                              (funcall agent-shell-markdown-open-file-function file))))
                (should (eq window source-window))
                (should (equal (buffer-file-name (window-buffer window)) file))
                (should (eq window (selected-window)))
                (should (buffer-local-value 'mr-x/quick-ask--hidden buf)))))
        (when-let* ((fb (get-file-buffer file))) (kill-buffer fb))
        (delete-file file)
        (kill-buffer buf) (kill-buffer source)))))

(ert-deftest quick-ask-file-links-in-a-review-follow-the-review-visit-style ()
  ;; From a review pane the link opens like `review-session-visit' does:
  ;; in-frame, panes replaced, `review-session-return' brings them back.
  (review-session-test--with s
    (let* ((pane (window-buffer (review-session-new-window s)))
           (file (make-temp-file "qa" nil ".el" "x\ny\n"))
           (buf (quick-ask-test--answer-buffer pane))
           (review-session-visit-style 'in-frame))
      (unwind-protect
          (let ((window (with-current-buffer buf
                          (funcall agent-shell-markdown-open-file-function file))))
            (should (window-live-p window))
            (should (equal (buffer-file-name (window-buffer window)) file))
            (should (review-session-return-state s))
            (should-not (window-live-p (review-session-old-window s))))
        (when-let* ((fb (get-file-buffer file))) (kill-buffer fb))
        (delete-file file)
        (kill-buffer buf)))))

(provide 'quick-ask-review-test)
;;; quick-ask-review-test.el ends here
