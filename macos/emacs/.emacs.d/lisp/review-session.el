;;; review-session.el --- One file at a time, old left, new right -*- lexical-binding: t; -*-
;;; Commentary:
;; The session owns which file and hunk you are on and which files you have
;; marked viewed.  It builds two read-only pane buffers per file from the
;; aligned rows of review-diff.el.  Syntax colours come from fontifying the
;; real text once in a scratch buffer and copying the faces onto the pane
;; lines, so placeholder rows never confuse a major mode.
;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'review-diff)
(require 'review-source)

(autoload 'syzygy-park "syzygy-park" nil t)

(defgroup review nil "Side-by-side review sessions." :group 'tools)
(require 'review-frame)
(autoload 'hydra-review/body "review-hydra" nil t)

(defcustom review-session-pop-out t
  "Open new reviews' side-by-side panes in a separate graphical frame.
When nil, use the invoking frame and restore its layout on quit.
Terminal sessions always use the invoking frame."
  :type 'boolean :group 'review)

(defcustom review-session-pulse t
  "Flash the current hunk in both panes after every jump."
  :type 'boolean :group 'review)

(defface review-eol '((t :inherit shadow)) "Carriage-return marker in a pane.")
(defface review-gutter '((t :inherit shadow)) "Line numbers in a pane.")
(defface review-del '((t :background "#372523" :extend t)) "Removed row.")
(defface review-add '((t :background "#303322" :extend t)) "Added row.")
(defface review-blank '((t :background "#1d2021" :extend t))
  "Placeholder row: the pane background, as in the design.")
(defface review-rail '((t :background "#fe8019")) "Current hunk rail.")
(defface review-mark-del '((t :foreground "#fb4934" :weight bold)) "Minus mark.")
(defface review-del-word '((t :background "#5c2e28")) "Changed words in a removed row.")
(defface review-add-word '((t :background "#4a4d22")) "Changed words in an added row.")
(defface review-flash '((t :background "#7a4a1f" :extend t))
  "Start colour of the highlight after a jump: the design's orange, muted.")
(defface review-mark-add '((t :foreground "#b8bb26" :weight bold)) "Plus mark.")

(cl-defstruct review-session
  source files current hunk viewed layout frame panel
  old-buffer new-buffer old-window new-window request directory
  own-frame panel-frame)

(defvar review-session--current nil "The live session, or nil.")
(defvar review-session-update-hook nil "Run with the session after every change.")
(defvar review-session-display-hook nil
  "Run with the session after its panes are laid out.
The panel subscribes here to put itself back in its side window.")

(defvar-local review-pane--session nil)
(defvar-local review-pane--side nil)
(defvar-local review-pane--file-index nil)

(defun review-session--notify (session)
  (run-hook-with-args 'review-session-update-hook session))

(defun review-session-progress (session)
  "Return (VIEWED . TOTAL) for SESSION."
  (cons (length (review-session-viewed session)) (length (review-session-files session))))

(defun review-session-file (session &optional index)
  "Return file plist INDEX (default current) of SESSION."
  (aref (review-session-files session) (or index (review-session-current session))))

(defun review-session-load (session index callback)
  "Load file INDEX of SESSION once, then invoke CALLBACK while still live.
CALLBACK receives an optional error string if an asynchronous fetch fails.
Concurrent consumers share one load; stale completions cannot alter its cache."
  (let* ((files (review-session-files session))
         (file (aref files index))
         (source (review-session-source session))
         (pending (plist-get file :loading)))
    (cond
     ((or (plist-get file :loaded) (plist-get file :binary) (plist-get file :unchanged))
      (when (eq session review-session--current) (funcall callback)))
     (pending (setcdr pending (append (cdr pending) (list callback))))
     (t
      (setq pending (list (make-symbol "review-load") callback))
      (aset files index (setq file (plist-put file :loading pending)))
      (let (old-done)
        (cl-labels
            ((active ()
               (and (eq session review-session--current)
                    (eq pending (plist-get (aref files index) :loading))))
             (finish (&optional error)
               (when (active)
                 (setq file (plist-put file :loading nil)
                       file (plist-put file :error error))
                 (aset files index file)
                 (dolist (consumer (cdr pending))
                   (if error (funcall consumer error) (funcall consumer)))))
             (new-ready (old new error)
               (when (active)
                 (if error (finish error)
                   (let (failure)
                     (condition-case err
                         (let* ((rows (review-diff-rows (review-diff-ops old new)))
                                (hunks (review-diff-hunks rows)))
                           (dolist (pair (list (cons :old-text old) (cons :new-text new)
                                               (cons :rows rows) (cons :hunks hunks)
                                               (cons :loaded t)))
                             (setq file (plist-put file (car pair) (cdr pair)))))
                       (error (setq failure (error-message-string err))))
                     (finish failure)))))
             (old-ready (old &optional error)
               (when (and (active) (not old-done))
                 (setq old-done t)
                 (if error (finish error)
                   (condition-case err
                       (funcall (review-source-text source) file 'new
                                (lambda (new &optional failure)
                                  (new-ready old new failure)))
                     (error (finish (error-message-string err))))))))
          (condition-case err
              (funcall (review-source-text source) file 'old #'old-ready)
            (error
             (when (active)
               (aset files index (plist-put file :loading nil)))
             (signal (car err) (cdr err))))))))))

;;;; Pane text

(defun review-session--fontified-lines (text path)
  "Return TEXT's lines with faces from the major mode PATH selects."
  (with-temp-buffer
    (insert text)
    (let ((buffer-file-name path) (enable-local-variables nil) (enable-local-eval nil))
      (delay-mode-hooks
        (if (string-match-p "\\.\\(?:md\\|markdown\\)\\'" path)
            (progn (require 'markdown-mode) (markdown-mode))
          (set-auto-mode))))
    (font-lock-mode 1)
    (font-lock-ensure (point-min) (point-max))
    ;; The `face' property travels with the substrings; pane buffers never
    ;; enable font-lock, so it renders as is.
    (review-diff--lines (buffer-string))))

(defun review-session--mark-cr (line)
  "Show LINE's trailing carriage return as a muted \u240d instead of ^M.
Without it a CRLF-to-LF change shows as rows that look identical."
  (if (and line (string-suffix-p "\r" line))
      (concat (substring line 0 -1)
              (propertize "\r" 'display "\u240d" 'face 'review-eol))
    line))

(defun review-session--changed-span (old new)
  "Return (START OLD-END NEW-END), the differing middle of OLD and NEW.
Widened to whole words so a highlight never splits one."
  (let ((lo (length old)) (ln (length new)) (p 0) (s 0))
    (while (and (< p lo) (< p ln) (eq (aref old p) (aref new p))) (cl-incf p))
    (while (and (< s (- lo p)) (< s (- ln p))
                (eq (aref old (- lo 1 s)) (aref new (- ln 1 s))))
      (cl-incf s))
    (cl-flet ((word (str i) (and (<= 0 i) (< i (length str))
                                 (string-match-p "[[:alnum:]_]" (string (aref str i))))))
      (while (and (> p 0) (word old (1- p)) (or (word old p) (word new p))) (cl-decf p))
      (while (and (> s 0) (word old (- lo s))
                  (or (word old (- lo s 1)) (word new (- ln s 1))))
        (cl-decf s)))
    (list p (- lo s) (- ln s))))

(defun review-session--gutter-width (text)
  "Digits in the line-number gutter for TEXT."
  (max 3 (length (number-to-string (max 1 (length (review-diff--lines text)))))))

(defun review-session-pane-text (rows side text &optional path)
  "Render ROWS for SIDE (old or new) of TEXT as one string, gutter included.
Every line carries a `review-row' property with its row index."
  (let* ((path (or path "file.txt"))
         (lines (vconcat (unless (string-empty-p text)
                           (review-session--fontified-lines text path))))
         (width (review-session--gutter-width text))
         (no-key (if (eq side 'old) :old-no :new-no))
         (text-key (if (eq side 'old) :old :new))
         (out nil) (i 0))
    (dolist (row rows)
      (let* ((no (plist-get row no-key))
             (kind (plist-get row :kind))
             (present (plist-get row text-key))
             (line (review-session--mark-cr
                    (and no (or (and (<= no (length lines)) (aref lines (1- no))) present ""))))
             (row-face (cond ((null no) 'review-blank)
                             ((and (eq side 'old) (memq kind '(del both))) 'review-del)
                             ((and (eq side 'new) (memq kind '(add both))) 'review-add)))
             (mark (cond ((null no) " ")
                         ((and (eq side 'old) (memq kind '(del both))) (propertize "-" 'face 'review-mark-del))
                         ((and (eq side 'new) (memq kind '(add both))) (propertize "+" 'face 'review-mark-add))
                         (t " ")))
             (gutter (propertize (format (format "%%%ds " width) (if no (number-to-string no) "")) 'face 'review-gutter))
             (body (concat gutter mark " " (or line ""))))
        ;; A modified row: mark just the words that changed.
        (when (and (eq kind 'both) no (stringp (plist-get row :old)) (stringp (plist-get row :new)))
          (pcase-let* ((`(,from ,old-end ,new-end)
                        (review-session--changed-span (plist-get row :old) (plist-get row :new)))
                       (end (if (eq side 'old) old-end new-end))
                       (offset (- (length body) (length (or line "")))))
            (when (and (< from end) (or (> from 0) (< end (length (or line "")))))
              (add-face-text-property (+ offset from) (min (length body) (+ offset end))
                                      (if (eq side 'old) 'review-del-word 'review-add-word)
                                      nil body))))
        (when row-face
          (add-face-text-property 0 (length body) row-face t body))
        (push (propertize body 'review-row i) out)
        (cl-incf i)))
    (mapconcat #'identity (nreverse out) "\n")))

;;;; Pane buffers

(defvar review-pane-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "C-j") #'review-session-next-file)
    (define-key m (kbd "C-k") #'review-session-prev-file)
    (define-key m (kbd "M-j") #'review-session-next-hunk)
    (define-key m (kbd "M-k") #'review-session-prev-hunk)
    (define-key m (kbd "v") #'review-session-toggle-viewed)
    (define-key m (kbd "u") #'syzygy-park)
    (define-key m (kbd "q") #'review-session-quit)
    m)
  "Keys in a review pane.")

(define-derived-mode review-pane-mode special-mode "Review"
  "Read-only pane of a review session."
  (setq truncate-lines t)
  (setq-local popper-popup-status 'raised)
  (setq-local scroll-margin 0))

(with-eval-after-load 'evil
  (evil-define-key 'normal review-pane-mode-map
		   (kbd "C-j") #'review-session-next-file
		   (kbd "C-k") #'review-session-prev-file
		   (kbd "M-j") #'review-session-next-hunk
		   (kbd "M-k") #'review-session-prev-hunk
		   (kbd "v") #'review-session-toggle-viewed
		   (kbd "u") #'syzygy-park
		   (kbd "q") #'review-session-quit))

(defun review-session--pane-string (session index side)
  "Return file INDEX's rendered SIDE of SESSION, rendering it only once.
Loaded texts never change during a session, so neither does their render;
fontifying a large file is the slow part of every file switch."
  (let* ((files (review-session-files session))
         (file (aref files index))
         (key (if (eq side 'old) :old-pane :new-pane)))
    (or (plist-get file key)
        (let ((text (review-session-pane-text
                     (plist-get file :rows) side
                     (plist-get file (if (eq side 'old) :old-text :new-text))
                     (plist-get file (if (eq side 'old) :old-path :path)))))
          (aset files index (plist-put file key text))
          text))))

(defvar review-session--prerender-timer nil)

(defun review-session--prerender (session)
  "Render the files on either side of SESSION's current one.
Best effort: any user input abandons the work."
  (when (eq session review-session--current)
    (let ((i (review-session-current session)))
      (dolist (index (list (1+ i) (1- i)))
        (when (and (< -1 index (length (review-session-files session)))
                   (not (plist-get (review-session-file session index) :binary))
                   (not (plist-get (review-session-file session index) :unchanged)))
          (ignore-errors
            (review-session-load
             session index
             (lambda (&optional error)
               (unless error
                 (while-no-input
                   (dolist (side '(old new))
                     (review-session--pane-string session index side))))))))))))

(defun review-session--schedule-prerender (session)
  (when (timerp review-session--prerender-timer)
    (cancel-timer review-session--prerender-timer))
  (setq review-session--prerender-timer
        (run-with-idle-timer 0.3 nil #'review-session--prerender session)))

(defun review-session--pane-buffer (session index side)
  "Create the pane buffer for file INDEX, SIDE of SESSION."
  (let* ((file (review-session-file session index))
         (name (format "*review %s: %s*" side (plist-get file :path)))
         (buffer (generate-new-buffer name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (cond
         ((plist-get file :binary)
          (insert (propertize "binary file, nothing to compare" 'face 'shadow)))
         ((plist-get file :unchanged)
          (insert (propertize (if-let ((mode (plist-get file :mode)))
                                  (format "mode %s -> %s, content unchanged" (car mode) (cdr mode))
                                "renamed, content unchanged")
                              'face 'shadow)))
         (t (insert (review-session--pane-string session index side)))))
      (review-pane-mode)
      (setq review-pane--text-column
            (+ 3 (review-session--gutter-width
                  (or (plist-get file (if (eq side 'old) :old-text :new-text)) ""))))
      (setq default-directory (review-session-directory session))
      (setq review-pane--session session review-pane--side side review-pane--file-index index)
      (setq header-line-format
            (format " %s  %s  %s"
                    (upcase (symbol-name side))
                    (pcase (list side (plist-get file :kind))
                      ('(old added) "(new file)")
                      ('(new deleted) "(deleted)")
                      (_ (plist-get file (if (eq side 'old) :old-path :path))))
                    (review-source-range-label (review-session-source session))))
      (set-buffer-modified-p nil)
      (goto-char (point-min)))
    buffer))

(defun review-session--kill-panes (session)
  (dolist (b (list (review-session-old-buffer session) (review-session-new-buffer session)))
    (when (buffer-live-p b) (kill-buffer b))))

(defvar-local review-pane--rail nil "Overlay marking the current hunk.")
(defvar-local review-pane--text-column 0 "Column where a pane's text starts, after the gutter.")

(defun review-session--text-column (buffer)
  (buffer-local-value 'review-pane--text-column buffer))

(defun review-session--flash (start end)
  "Pulse START..END in the current buffer: hold, then fade out.
Emacs's pulse keeps one global overlay, so a second pane would cancel the
first; each pane gets its own overlay here."
  (let* ((o (make-overlay start end))
         (from (or (face-background 'review-flash nil t) "#7a4a1f"))
         (to "#1d2021") (hold 0.2) (step 0.05) (steps 8)
         (rgb (lambda (hex) (mapcar (lambda (i) (string-to-number (substring hex i (+ i 2)) 16))
                                    '(1 3 5)))))
    (overlay-put o 'review-flash t)
    (overlay-put o 'priority 100)
    (overlay-put o 'face `(:background ,from :extend t))
    (when (and (string-prefix-p "#" from) (= (length from) 7))
      (dotimes (i steps)
        (let* ((a (/ (float (1+ i)) steps))
               (color (apply #'format "#%02x%02x%02x"
                             (cl-mapcar (lambda (f b) (round (+ (* (- 1 a) f) (* a b))))
                                        (funcall rgb from) (funcall rgb to)))))
          (run-at-time (+ hold (* i step)) nil
                       (lambda () (when (overlay-buffer o)
                                    (overlay-put o 'face `(:background ,color :extend t))))))))
    (run-at-time (+ hold (* steps step) step) nil #'delete-overlay o)))

(defun review-session--hunk-column (file hunk)
  "Column of the first change in HUNK of FILE, 0 when a row changes whole."
  (let ((rows (cl-subseq (plist-get file :rows) (plist-get hunk :start)
                         (min (length (plist-get file :rows)) (1+ (plist-get hunk :end))))))
    (apply #'min (mapcar (lambda (row)
                           (if (and (eq (plist-get row :kind) 'both)
                                    (stringp (plist-get row :old)) (stringp (plist-get row :new)))
                               (car (review-session--changed-span (plist-get row :old) (plist-get row :new)))
                             0))
                         rows))))

(defun review-session--row-position (buffer row)
  "Return the buffer position of ROW in BUFFER."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (forward-line row)
      (point))))

(defun review-session--paint-hunk (session)
  "Move the rail and both windows to the current hunk of SESSION."
  (let* ((file (review-session-file session))
         (hunk (nth (review-session-hunk session) (plist-get file :hunks))))
    (dolist (buffer (list (review-session-old-buffer session) (review-session-new-buffer session)))
      (when (and (buffer-live-p buffer) hunk)
        (with-current-buffer buffer
          (let ((start (review-session--row-position buffer (plist-get hunk :start)))
                (end (review-session--row-position buffer (1+ (plist-get hunk :end)))))
            (unless (overlayp review-pane--rail)
              (setq review-pane--rail (make-overlay start end)))
            (move-overlay review-pane--rail start end)
            (when review-session-pulse (review-session--flash start end))
            (overlay-put review-pane--rail 'line-prefix (propertize " " 'face 'review-rail))
            (goto-char start)
            ;; Commands also run from the files frame; search every frame.
            (when-let ((w (get-buffer-window buffer t)))
              (set-window-start w (review-session--row-position buffer (max 0 (- (plist-get hunk :start) 3))))
              ;; Long lines: scroll sideways so the change itself is on screen.
              ;; Point goes to the change too, or `auto-hscroll-mode' scrolls
              ;; back to show it at column 0.
              (let* ((column (+ review-pane--text-column (review-session--hunk-column file hunk)))
                     (width (window-body-width w))
                     (at (save-excursion (goto-char start) (move-to-column column) (point))))
                (goto-char at)
                (set-window-point w at)
                (set-window-hscroll w (if (< (+ column 8) width) 0
                                        (max 0 (- column (/ width 3)))))))))))))

(defun review-session--sync-scroll (window start)
  "Keep the other pane level with WINDOW after it scrolls to START."
  (with-current-buffer (window-buffer window)
    (when (and review-pane--session (not (bound-and-true-p review-pane--syncing)))
      (let* ((s review-pane--session)
             (other (if (eq review-pane--side 'old) (review-session-new-buffer s) (review-session-old-buffer s)))
             (row (save-excursion (goto-char start) (1- (line-number-at-pos)))))
        (when-let ((ow (and (buffer-live-p other) (get-buffer-window other t))))
          (with-current-buffer other
            (setq-local review-pane--syncing t)
            (unwind-protect
                (set-window-start ow (review-session--row-position other row))
              (setq-local review-pane--syncing nil))))))))

(defun review-session--display (session)
  "Show both panes of SESSION side by side in its frame.
The two pane windows are made once; later files reuse them, so side
windows (the panel) are left alone and nothing flickers."
  (with-selected-frame (review-session-frame session)
    (let ((old (review-session-old-buffer session)) (new (review-session-new-buffer session))
          (lw (review-session-old-window session)) (rw (review-session-new-window session)))
      (unless (and (window-live-p lw) (window-live-p rw))
        ;; Never split from a side window: `delete-other-windows' would
        ;; leave the survivor tagged as a side window.
        (select-window
         (or (seq-find (lambda (w) (not (window-parameter w 'window-side)))
                       (window-list (review-session-frame session) 'nomini))
             (selected-window)))
        (let ((ignore-window-parameters t)) (delete-other-windows))
        (setq lw (selected-window) rw (split-window-right))
        (setf (review-session-old-window session) lw
              (review-session-new-window session) rw))
      (set-window-buffer lw old)
      (set-window-buffer rw new)
      (dolist (b (list old new))
        (with-current-buffer b
          (add-hook 'window-scroll-functions #'review-session--sync-scroll nil t)))
      (select-window rw)
      (run-hook-with-args 'review-session-display-hook session))))

(defun review-session-show (index &optional hunk viewed)
  "Show file INDEX, selecting HUNK after it loads.
HUNK -1 selects its last hunk.  Mark VIEWED only after navigation succeeds."
  (let* ((session (review-session--require))
         (request (make-symbol "review-request")))
    (unless (and (integerp index) (<= 0 index)
                 (< index (length (review-session-files session))))
      (user-error "No such review file"))
    (setf (review-session-request session) request)
    (review-session-load
     session index
     (lambda (&optional error)
       (when (and (eq session review-session--current)
                  (eq request (review-session-request session))
                  (frame-live-p (review-session-frame session)))
         (if error
             (progn (review-session--notify session) (message "Review: %s" error))
           (let ((old (review-session-old-buffer session))
		 (new (review-session-new-buffer session))
		 (next-old (review-session--pane-buffer session index 'old))
		 next-new)
             (condition-case err
		 (setq next-new (review-session--pane-buffer session index 'new))
               (error (kill-buffer next-old) (signal (car err) (cdr err))))
             (setf (review-session-current session) index
                   (review-session-hunk session)
                   (max 0 (min (or hunk 0)
                               (1- (length (plist-get (review-session-file session index) :hunks)))))
                   (review-session-old-buffer session) next-old
                   (review-session-new-buffer session) next-new)
             (when (eq hunk -1)
               (setf (review-session-hunk session)
                     (max 0 (1- (length (plist-get (review-session-file session) :hunks))))))
             (review-session--display session)
             (dolist (buffer (list old new))
               (when (buffer-live-p buffer) (kill-buffer buffer)))
             (when viewed (review-session--mark-viewed session viewed))
             (review-session--paint-hunk session)
             (review-session--notify session)
             (review-session--schedule-prerender session))))))))

;;;; Commands

(defun review-session--require ()
  (or review-session--current (user-error "No review session is running")))

(defun review-session--mark-viewed (session index)
  (cl-pushnew index (review-session-viewed session)))

(defun review-session-next-file ()
  "Mark the current file viewed and show the next one."
  (interactive)
  (let* ((s (review-session--require)) (i (review-session-current s)))
    (when (>= (1+ i) (length (review-session-files s)))
      (user-error "Last file of the review"))
    (review-session-show (1+ i) nil i)))

(defun review-session-prev-file ()
  "Show the previous file without changing viewed marks."
  (interactive)
  (let* ((s (review-session--require)) (i (review-session-current s)))
    (when (zerop i) (user-error "First file of the review"))
    (review-session-show (1- i))))

(defun review-session-next-hunk ()
  "Move to the next hunk of this file.  Only file keys change files."
  (interactive)
  (let* ((s (review-session--require))
         (hunks (plist-get (review-session-file s) :hunks)))
    (unless (< (1+ (review-session-hunk s)) (length hunks))
      (user-error "Last hunk in this file"))
    (cl-incf (review-session-hunk s))
    (review-session--paint-hunk s)
    (review-session--notify s)))

(defun review-session-prev-hunk ()
  "Move to the previous hunk of this file.  Only file keys change files."
  (interactive)
  (let ((s (review-session--require)))
    (unless (> (review-session-hunk s) 0)
      (user-error "First hunk in this file"))
    (cl-decf (review-session-hunk s))
    (review-session--paint-hunk s)
    (review-session--notify s)))

(defun review-session-toggle-viewed ()
  "Toggle the viewed mark on the current file."
  (interactive)
  (let* ((s (review-session--require)) (i (review-session-current s)))
    (if (memq i (review-session-viewed s))
        (setf (review-session-viewed s) (delq i (review-session-viewed s)))
      (review-session--mark-viewed s i))
    (review-session--notify s)))

(defun review-session-quit ()
  "Close review buffers and owned frames, restoring an in-place layout."
  (interactive)
  (when-let ((s review-session--current))
    (setq review-session--current nil)
    (review-session--kill-panes s)
    (when (buffer-live-p (review-session-panel s)) (kill-buffer (review-session-panel s)))
    (when (frame-live-p (review-session-panel-frame s))
      (delete-frame (review-session-panel-frame s)))
    (if (review-session-own-frame s)
        (when (frame-live-p (review-session-frame s))
          (delete-frame (review-session-frame s)))
      (when (and (frame-live-p (review-session-frame s)) (review-session-layout s))
        (set-window-configuration (review-session-layout s))))
    (run-hook-with-args 'review-session-update-hook nil)))

(defun review-session--frame-deleted (frame)
  "Clean up a review when either of its frames is closed manually."
  (when-let ((s review-session--current))
    (when (memq frame (list (review-session-frame s) (review-session-panel-frame s)))
      ;; The caller is already deleting FRAME; do not delete it recursively
      ;; or restore a layout into it.
      (if (eq frame (review-session-frame s))
          (setf (review-session-frame s) nil)
        (setf (review-session-panel-frame s) nil))
      (review-session-quit))))

(add-hook 'delete-frame-functions #'review-session--frame-deleted)

(defun review-session-start (source)
  "Start reviewing SOURCE and return the session."
  (let ((files (vconcat (copy-tree (funcall (review-source-files source))))))
    (when (zerop (length files)) (user-error "Nothing to review: no changed files"))
    (when review-session--current (review-session-quit))
    (let* ((pop-out (and review-session-pop-out (review-frame-graphic-p)))
           (layout (unless pop-out (current-window-configuration)))
           (frame (if pop-out
                      (save-selected-window
                        (make-frame (review-frame-parameters
                                     '((name . "Review diff") (title . "Review diff") (width . 160)
                                       (height . 45) (no-focus-on-map . t)))))
                    (selected-frame)))
           (session (make-review-session
                    :source source :files files :current 0 :hunk 0 :viewed nil
                    :directory (or (review-source-directory source) default-directory)
                    :layout layout :frame frame :own-frame pop-out)))
      (setq review-session--current session)
      (condition-case err
          (progn
            (review-session-show 0)
            (when pop-out (review-frame-place frame review-session-display))
            (when pop-out (select-frame-set-input-focus frame)))
        (error (review-session-quit) (signal (car err) (cdr err))))
      session)))


(defvar review-panel--session)

(defun review-session-pane-selection (&optional begin end)
  "Map BEGIN..END in this pane to real source lines and text.
Alignment padding and the rendered gutters are excluded.  With no
bounds use the active region, or the source line at point."
  (unless (and (derived-mode-p 'review-pane-mode) review-pane--session)
    (user-error "Not in a review pane"))
  (let* ((file (review-session-file review-pane--session review-pane--file-index))
         (rows (vconcat (plist-get file :rows)))
         (begin (or begin (if (use-region-p) (region-beginning) (point))))
         (end (or end (if (use-region-p) (region-end) begin)))
         (first (1- (line-number-at-pos begin)))
         (last (1- (line-number-at-pos (if (> end begin) (1- end) end))))
         (number-key (if (eq review-pane--side 'old) :old-no :new-no))
         (text-key (if (eq review-pane--side 'old) :old :new))
         numbers text)
    (cl-loop for i from first to (min last (1- (length rows)))
             for row = (aref rows i)
             when (plist-get row number-key)
             do (push (plist-get row number-key) numbers)
             and do (push (plist-get row text-key) text))
    (unless numbers (user-error "Selection contains no source lines"))
    (list :start (car (last numbers)) :end (car numbers)
          :text (string-join (nreverse text) "\n"))))

(defun review-session-origin (&optional begin end)
  "Return the source origin at point, including the side and real line range."
  (let* ((pane (derived-mode-p 'review-pane-mode))
         (session (if pane review-pane--session
                    (and (derived-mode-p 'review-panel-mode) review-panel--session))))
    (when session
      (let* ((index (if pane review-pane--file-index
                      (or (get-text-property (point) 'review-file)
                          (review-session-current session))))
             (file (copy-sequence (review-session-file session index)))
             (hunk (unless pane
                     (nth (or (get-text-property (point) 'review-hunk) 0)
                          (plist-get file :hunks))))
             (side (if pane review-pane--side
                     (if (or (eq (plist-get file :kind) 'deleted)
                             (and hunk (zerop (plist-get hunk :new-count))))
                         'old 'new)))
             (selection (if pane (review-session-pane-selection begin end)
                          (let* ((start (or (plist-get hunk (if (eq side 'old) :old-start :new-start)) 1))
                                 (count (plist-get hunk (if (eq side 'old) :old-count :new-count))))
                            (list :start start
                                  :end (+ start (max 0 (1- (or count 1)))))))))
        (setq file (plist-put file :origin-path
                              (or (and (eq side 'old)
                                       (plist-get file :old-path))
                                  (plist-get file :path))))
        (setq file (plist-put file :side side))
        (funcall (review-source-origin (review-session-source session))
                 file (plist-get selection :start) (plist-get selection :end))))))

(provide 'review-session)
;;; review-session.el ends here
