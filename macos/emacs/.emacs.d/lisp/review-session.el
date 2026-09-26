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

(defcustom review-session-long-lines 'wrap
  "How the panes show a line wider than its pane.
`wrap': wrap it, padding the other pane with blank rows so both stay
level.  Past `review-session-wrap-max-rows' rows the line is cut, and a
count says how much is hidden.
`scroll': cut it at the pane edge.  \\`zh' and \\`zl' scroll both panes
together; ‹ and › mark text past an edge, in red or green when it hides
a change.
\\`zw' switches between the two."
  :type '(choice (const :tag "Wrap and pad" wrap) (const :tag "Scroll both panes" scroll))
  :group 'review)

(defcustom review-session-wrap-max-rows 4
  "Most rows one wrapped line takes before the rest is cut."
  :type 'natnum :group 'review)

(defcustom review-session-scroll-step 8
  "Columns \\`zh' and \\`zl' scroll both panes in scroll mode."
  :type 'natnum :group 'review)

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
(defface review-edge '((t :inherit shadow))
  "‹, › or a hidden count where a line goes past a pane edge.")

(cl-defstruct review-session
  source files current hunk viewed layout frame panel
  old-buffer new-buffer old-window new-window request directory
  own-frame panel-frame (hscroll 0))

(defvar review-session--current nil "The live session, or nil.")
(defvar review-session-update-hook nil "Run with the session after every change.")
(defvar review-session-display-hook nil
  "Run with the session after its panes are laid out.
The panel subscribes here to put itself back in its side window.")
(defvar review-session-layout-hook nil
  "Run with the session after its pane text is redrawn to fit.
Redrawing drops overlays anchored in the text; the panel puts its hunk
bands back here.")

(defvar-local review-pane--session nil)
(defvar-local review-pane--side nil)
(defvar-local review-pane--file-index nil)
(defvar-local review-pane--diff nil "Non-nil when the pane shows rows, not a notice.")
(defvar-local review-pane--starts nil "The line each row starts on, from the last layout.")
(defvar-local review-pane--layout nil "(MODE WIDTH HSCROLL) of the last layout.")

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

(cl-defstruct (review-cell (:constructor review-cell--make) (:copier nil))
  "One row of one pane: line number, mark, fontified body.
SPAN is the changed words as (START . END) in BODY; COLS holds the
display column before each of BODY's chars, then its width."
  no mark body face span cols)

(cl-defstruct (review-render (:constructor review-render--make) (:copier nil))
  "One side of a file, rendered once: gutter digits and a cell per row."
  gutter cells widest)

(defun review-session--columns (body)
  "Display columns before each char of BODY, then its width, as a vector.
Invisible text, such as hidden Markdown markup, takes none."
  (let* ((len (length body)) (cols (make-vector (1+ len) 0)) (col 0))
    (dotimes (i len)
      (unless (get-text-property i 'invisible body)
        (let ((c (aref body i)))
          (cl-incf col (if (eq c ?\r) 1 (char-width c)))))
      (aset cols (1+ i) col))
    cols))

(defun review-session-pane-render (rows side text &optional path)
  "Render ROWS for SIDE (old or new) of TEXT: a `review-render'.
Fontifying is the slow part and happens once; the panes then lay the
cells out to fit their width."
  (let* ((path (or path "file.txt"))
         (lines (vconcat (unless (string-empty-p text)
                           (review-session--fontified-lines text path))))
         (no-key (if (eq side 'old) :old-no :new-no))
         (text-key (if (eq side 'old) :old :new))
         (changed (if (eq side 'old) '(del both) '(add both)))
         (cells (make-vector (length rows) nil))
         (i 0))
    (dolist (row rows)
      (let* ((no (plist-get row no-key))
             (kind (plist-get row :kind))
             (present (plist-get row text-key))
             ;; A copy: faces go on below, and the fontified lines are shared.
             (body (copy-sequence
                    (or (review-session--mark-cr
                         (and no (or (and (<= no (length lines)) (aref lines (1- no))) present "")))
                        "")))
             span)
        ;; A modified row: mark just the words that changed.
        (when (and (eq kind 'both) no (stringp (plist-get row :old)) (stringp (plist-get row :new)))
          (pcase-let* ((`(,from ,old-end ,new-end)
                        (review-session--changed-span (plist-get row :old) (plist-get row :new)))
                       (end (min (length body) (if (eq side 'old) old-end new-end))))
            (when (and (< from end) (or (> from 0) (< end (length body))))
              (setq span (cons from end))
              (add-face-text-property from end (if (eq side 'old) 'review-del-word 'review-add-word)
                                      nil body))))
        (aset cells i (review-cell--make
                       :no no :body body :span span :cols (review-session--columns body)
                       :face (cond ((null no) 'review-blank)
                                   ((memq kind changed) (if (eq side 'old) 'review-del 'review-add)))
                       :mark (cond ((or (null no) (not (memq kind changed))) " ")
                                   ((eq side 'old) (propertize "-" 'face 'review-mark-del))
                                   (t (propertize "+" 'face 'review-mark-add)))))
        (cl-incf i)))
    (review-render--make :gutter (review-session--gutter-width text) :cells cells)))

(defun review-session--widest (render)
  "Columns of RENDER's widest line."
  (or (review-render-widest render)
      (setf (review-render-widest render)
            (cl-loop for cell across (review-render-cells render)
                     maximize (let ((cols (review-cell-cols cell))) (aref cols (1- (length cols))))
                     into widest finally return (or widest 0)))))

;;;; Layout: wrap and pad, or cut at a shared column

(defun review-session--gutter (digits &optional no)
  (propertize (format (format "%%%ds " digits) (or no "")) 'face 'review-gutter))

(defun review-session--edge (changed side)
  "Face for a mark at a pane edge: SIDE's colour when it hides a change."
  (if changed (if (eq side 'old) 'review-mark-del 'review-mark-add) 'review-edge))

(defun review-session--col-index (cols column &optional from)
  "The last index I from FROM whose (aref COLS I) is at most COLUMN."
  (let ((i (or from 0)) (last (1- (length cols))))
    (while (and (< i last) (<= (aref cols (1+ i)) column)) (cl-incf i))
    i))

(defun review-session--scroll-line (cell digits side width hscroll)
  "CELL cut to WIDTH columns from column HSCROLL, on one line.
‹ and › stand where the line goes on past an edge, in SIDE's colour when
the hidden text holds a change.  A nil WIDTH has no right edge."
  (let* ((body (review-cell-body cell)) (cols (review-cell-cols cell))
         (len (length body)) (span (review-cell-span cell))
         (start (if (<= hscroll 0) 0
                  (let ((i (review-session--col-index cols hscroll)))
                    (if (and (< (aref cols i) hscroll) (< i len)) (1+ i) i))))
         (end (if width (review-session--col-index cols (+ hscroll width) start) len)))
    (concat (review-session--gutter digits (review-cell-no cell))
            (review-cell-mark cell)
            (if (and (> hscroll 0) (> len 0))
                (propertize "‹" 'face (review-session--edge (and span (< (car span) start)) side))
              " ")
            (substring body start end)
            (when (and width (> (aref cols len) (aref cols end)))
              (concat (make-string (max 0 (- width (- (aref cols end) (aref cols start)))) ?\s)
                      (propertize "›" 'face (review-session--edge (and span (> (cdr span) end)) side)))))))

(defconst review-session--indent-regexp
  "\\`[ \t]*\\(?:\\(?:[-*+>]\\|[0-9]+[.)]\\|;+\\|//+\\|#+\\|--\\)[ \t]+\\)?"
  "What wrapped rows indent past: indentation, then a bullet or comment start.")

(defun review-session--wrap-ranges (cell width)
  "Split CELL's body into rows no wider than WIDTH, and pick the ones shown.
A row breaks after the last space that fits.  Continuation rows indent
past the line's own indentation and bullet, so they are that much
narrower.  A line longer than `review-session-wrap-max-rows' rows shows
its first rows; when its change starts further on, its first row and
then the rows of the change, so the change is always on screen.
Return (ROWS INDENT).  Each row is (START END SKIPPED CHANGED): SKIPPED
counts the chars left out after it, or is nil; CHANGED says whether
they hold part of the change."
  (let* ((body (review-cell-body cell)) (cols (review-cell-cols cell))
         (len (length body)) (span (review-cell-span cell))
         (indent (min (/ width 2)
                      (if (string-match review-session--indent-regexp body)
                          (aref cols (match-end 0))
                        0)))
         (max-rows (max 1 review-session-wrap-max-rows))
         (room (lambda (row) (if (= row 0) width (- width indent))))
         (start 0) ranges)
    (while (< start len)
      (let* ((end (max (1+ start) (review-session--col-index
                                   cols (+ (aref cols start) (funcall room (length ranges))) start)))
             (space (and (< end len)
                         (cl-position ?\s body :from-end t :start (1+ start) :end (1+ end)))))
        (push (cons start (or space end)) ranges)
        (setq start (or space end))
        (while (and (< start len) (eq (aref body start) ?\s)) (cl-incf start))))
    (let* ((ranges (vconcat (nreverse (or ranges (list (cons 0 0))))))
           (n (length ranges))
           (row-of (lambda (i) (or (cl-position-if (lambda (r) (<= (car r) i)) ranges :from-end t) 0)))
           (first-change (and span (funcall row-of (car span))))
           (shown
            (cond
             ((<= n max-rows) (number-sequence 0 (1- n)))
             ((or (null first-change) (< first-change max-rows) (< max-rows 2))
              (number-sequence 0 (1- max-rows)))
             ;; The change is past the first rows: the first row for
             ;; context, then the change's rows, one row before it when
             ;; that still fits.
             (t (let* ((last-change (funcall row-of (max (car span) (1- (cdr span)))))
                       (from (if (and (> first-change 1)
                                      (<= (- last-change first-change) (- max-rows 3)))
                                 (1- first-change)
                               first-change)))
                  (cons 0 (number-sequence from (min (1- n) (+ from max-rows -2))))))))
           (reserve (string-width (format " … +%d" len))))
      (list
       (cl-loop
        for (row next) on shown
        for (s . e) = (aref ranges row)
        for resume = (if next (car (aref ranges next)) len)
        collect
        (if (or (eq next (1+ row)) (and (null next) (= row (1- n))))
            (list s e nil nil)
          ;; Rows are left out after this one: shorten it for the count,
          ;; ending on a word when one fits.
          (let* ((e (if (<= (+ (- (aref cols e) (aref cols s)) reserve) (funcall room row)) e
                      (let* ((fit (review-session--col-index
                                   cols (- (+ (aref cols s) (funcall room row)) reserve) s))
                             (space (and (> fit (1+ s))
                                         (cl-position ?\s body :from-end t :start (1+ s) :end (1+ fit)))))
                        (or space fit)))))
            (list s e (- resume e) (and span (< (car span) resume) (> (cdr span) e) t)))))
       indent))))

(defun review-session--cell-lines (cell render side mode width hscroll)
  "CELL's lines in MODE: one line cut at the edges, or its wrapped rows."
  (let ((digits (review-render-gutter render)))
    (if (or (eq mode 'scroll) (null width))
        (list (review-session--scroll-line cell digits side width (if (eq mode 'scroll) hscroll 0)))
      (pcase-let* ((`(,rows ,indent) (review-session--wrap-ranges cell width))
                   (body (review-cell-body cell))
                   (lead (concat (review-session--gutter digits "↪") "  " (make-string indent ?\s)))
                   (first t))
        (mapcar (pcase-lambda (`(,s ,e ,skipped ,changed))
                  (prog1 (concat (if first
                                     (concat (review-session--gutter digits (review-cell-no cell))
                                             (review-cell-mark cell) " ")
                                   lead)
                                 (substring body s e)
                                 (when skipped
                                   (propertize (format " … +%d" skipped)
                                               'face (review-session--edge changed side))))
                    (setq first nil)))
                rows)))))

(defun review-session--finish-row (lines count digits face row)
  "LINES padded to COUNT with blank rows, in FACE, tagged with ROW, as one string."
  (dolist (line lines)
    (when face (add-face-text-property 0 (length line) face t line)))
  (propertize (string-join
               (append lines (make-list (- count (length lines))
                                        (propertize (make-string (+ digits 3) ?\s) 'face 'review-blank)))
               "\n")
              'review-row row))

(defun review-session-pane-layout (old new &optional mode old-width new-width hscroll)
  "Lay out renders OLD and NEW side by side: (OLD-TEXT NEW-TEXT STARTS).
MODE `wrap' wraps bodies to OLD-WIDTH and NEW-WIDTH columns and pads the
shorter side, so every row starts on the same line in both texts.
`scroll' cuts every body to its width from column HSCROLL.  STARTS holds
the line each row starts on."
  (let* ((old-cells (review-render-cells old)) (new-cells (review-render-cells new))
         (count (length old-cells)) (starts (make-vector count 0))
         (line 0) olds news)
    (dotimes (i count)
      (let* ((a (review-session--cell-lines (aref old-cells i) old 'old mode old-width (or hscroll 0)))
             (b (review-session--cell-lines (aref new-cells i) new 'new mode new-width (or hscroll 0)))
             (n (max (length a) (length b))))
        (aset starts i line)
        (push (review-session--finish-row a n (review-render-gutter old) (review-cell-face (aref old-cells i)) i)
              olds)
        (push (review-session--finish-row b n (review-render-gutter new) (review-cell-face (aref new-cells i)) i)
              news)
        (cl-incf line n)))
    (list (string-join (nreverse olds) "\n") (string-join (nreverse news) "\n") starts)))

(defun review-session-pane-text (rows side text &optional path)
  "Render ROWS for SIDE (old or new) of TEXT as one string, gutter included.
Lines are not cut or wrapped.  Every line carries a `review-row' property
with its row index."
  (let ((render (review-session-pane-render rows side text path)) (i -1))
    (mapconcat (lambda (cell)
                 (cl-incf i)
                 (review-session--finish-row (review-session--cell-lines cell render side 'scroll nil 0)
                                             1 (review-render-gutter render) (review-cell-face cell) i))
               (review-render-cells render) "\n")))

;;;; Pane buffers

(defconst review-session-keys
  '(("C-j" . review-session-next-hunk) ("C-k" . review-session-prev-hunk)
    ("J" . review-session-next-file) ("K" . review-session-prev-file)
    ("x" . review-session-toggle-viewed) ("u" . syzygy-park)
    ("q" . review-session-quit))
  "Keys shared by the panes, the files panel and `hydra-review'.
Hunk keys match Magit and diff-mode; `v' stays Evil visual selection.")

(defun review-session-key (command)
  "The key `review-session-keys' gives COMMAND."
  (car (rassq command review-session-keys)))

(defun review-session-bind-keys (map &optional extra)
  "Bind `review-session-keys', then EXTRA, in MAP and its Evil normal state."
  (let ((keys (append review-session-keys extra)))
    (dolist (k keys) (define-key map (kbd (car k)) (cdr k)))
    (with-eval-after-load 'evil
      (dolist (k keys) (evil-define-key* 'normal map (kbd (car k)) (cdr k)))))
  map)

(defconst review-session-long-line-keys
  '(("zh" . review-session-scroll-left) ("zl" . review-session-scroll-right)
    ("zH" . review-session-scroll-left-half) ("zL" . review-session-scroll-right-half)
    ("zw" . review-session-toggle-long-lines)
    ("<wheel-left>" . review-session-scroll-wheel) ("<wheel-right>" . review-session-scroll-wheel))
  "Pane keys for long lines.  Evil's sideways-scroll keys move both panes.")

(defvar review-pane-mode-map
  (review-session-bind-keys (make-sparse-keymap) review-session-long-line-keys)
  "Keys in a review pane.")

(define-derived-mode review-pane-mode special-mode "Review"
  "Read-only pane of a review session."
  (setq truncate-lines t)
  (setq-local popper-popup-status 'raised)
  (setq-local scroll-margin 0))

(defun review-session--pane-render (session index side)
  "Return file INDEX's rendered SIDE of SESSION, rendering it only once.
Loaded texts never change during a session, so neither do their cells;
fontifying a large file is the slow part of every file switch."
  (let* ((files (review-session-files session))
         (file (aref files index))
         (key (if (eq side 'old) :old-render :new-render)))
    (or (plist-get file key)
        (let ((render (review-session-pane-render
                       (plist-get file :rows) side
                       (plist-get file (if (eq side 'old) :old-text :new-text))
                       (plist-get file (if (eq side 'old) :old-path :path)))))
          (aset files index (plist-put file key render))
          render))))

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
                     (review-session--pane-render session index side))))))))))))

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
                              'face 'shadow)))))
      (review-pane-mode)
      ;; The text itself waits for a window: its width decides the layout.
      (setq review-pane--diff (not (or (plist-get file :binary) (plist-get file :unchanged))))
      (add-hook 'window-size-change-functions #'review-session--pane-resized nil t)
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

(defun review-session--hunk-column (session hunk)
  "Display column of the first change in HUNK, 0 when a row changes whole."
  (let* ((rows (plist-get (review-session-file session) :rows))
         (cells (review-render-cells
                 (review-session--pane-render session (review-session-current session) 'new)))
         (row (plist-get hunk :start)))
    (apply #'min
           (mapcar (lambda (r)
                     (prog1 (if (and (eq (plist-get r :kind) 'both)
                                     (stringp (plist-get r :old)) (stringp (plist-get r :new)))
                                (let ((cols (review-cell-cols (aref cells row))))
                                  (aref cols (min (car (review-session--changed-span
                                                        (plist-get r :old) (plist-get r :new)))
                                                  (1- (length cols)))))
                              0)
                       (cl-incf row)))
                   (cl-subseq rows (plist-get hunk :start)
                              (min (length rows) (1+ (plist-get hunk :end))))))))

(defun review-session--row-position (buffer row)
  "Return the buffer position of ROW's first line in BUFFER."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (let ((starts review-pane--starts))
        (if (and starts (>= row (length starts)))
            (goto-char (point-max))
          (forward-line (if starts (aref starts row) row))))
      (point))))

(defun review-session--row-at (pos)
  "The row of the line at POS in this pane.  Wrapped rows share it."
  (save-excursion (goto-char pos) (get-text-property (line-beginning-position) 'review-row)))

(defun review-session--pane-width (buffer)
  "Columns BUFFER's window leaves for line text: less the gutter, the
hunk rail, the edge mark and the column Emacs keeps for its own."
  (let ((window (get-buffer-window buffer t)))
    (max 10 (- (if window (window-body-width window) (/ (frame-width) 2))
               (review-session--text-column buffer) 3))))

(defun review-session--fill-pane (buffer text starts layout)
  "Replace BUFFER's text, keeping the row at its window's top and point's row."
  (with-current-buffer buffer
    (let* ((window (get-buffer-window buffer t))
           (pos (if window (window-point window) (point)))
           (row (and review-pane--layout (review-session--row-at pos)))
           (column (and row (save-excursion (goto-char pos) (current-column))))
           (top (and row window (review-session--row-at (window-start window))))
           (inhibit-read-only t))
      (remove-overlays (point-min) (point-max) 'review-flash t)
      (erase-buffer)
      (insert text)
      (setq review-pane--starts starts review-pane--layout layout)
      (set-buffer-modified-p nil)
      (goto-char (review-session--row-position buffer (or row 0)))
      (when column (move-to-column column))
      (when window
        (set-window-point window (point))
        (set-window-start window (review-session--row-position buffer (or top 0)))
        (set-window-hscroll window 0)))))

(defun review-session--place-rail (session)
  "Mark SESSION's current hunk with the rail in both panes."
  (when-let ((hunk (nth (review-session-hunk session)
                        (plist-get (review-session-file session) :hunks))))
    (dolist (buffer (list (review-session-old-buffer session) (review-session-new-buffer session)))
      (when (and (buffer-live-p buffer) (buffer-local-value 'review-pane--diff buffer))
        (with-current-buffer buffer
          (let ((start (review-session--row-position buffer (plist-get hunk :start)))
                (end (review-session--row-position buffer (1+ (plist-get hunk :end)))))
            (unless (overlayp review-pane--rail)
              (setq review-pane--rail (make-overlay start end)))
            (move-overlay review-pane--rail start end)
            (overlay-put review-pane--rail 'line-prefix (propertize " " 'face 'review-rail))))))))

(defun review-session--ensure-layout (session)
  "Lay SESSION's panes out again unless they already fit their windows.
Both panes are laid out together: wrapping pads each against the other."
  (let ((old (review-session-old-buffer session)) (new (review-session-new-buffer session)))
    (when (and (buffer-live-p old) (buffer-live-p new)
               (buffer-local-value 'review-pane--diff new))
      (let* ((mode review-session-long-lines)
             (hscroll (if (eq mode 'scroll) (review-session-hscroll session) 0))
             (old-width (review-session--pane-width old))
             (new-width (review-session--pane-width new))
             (want-old (list mode old-width hscroll))
             (want-new (list mode new-width hscroll)))
        (unless (and (equal want-old (buffer-local-value 'review-pane--layout old))
                     (equal want-new (buffer-local-value 'review-pane--layout new)))
          (let ((index (buffer-local-value 'review-pane--file-index new)))
            (pcase-let ((`(,old-text ,new-text ,starts)
                         (review-session-pane-layout (review-session--pane-render session index 'old)
                                                (review-session--pane-render session index 'new)
                                                mode old-width new-width hscroll)))
              (review-session--fill-pane old old-text starts want-old)
              (review-session--fill-pane new new-text starts want-new)))
          (review-session--place-rail session)
          (run-hook-with-args 'review-session-layout-hook session))))))

(defun review-session--pane-resized (window)
  "Fit the panes again after WINDOW, showing one of them, changes size."
  (with-current-buffer (window-buffer window)
    (when (and review-pane--session (eq review-pane--session review-session--current))
      (review-session--ensure-layout review-pane--session))))

(defun review-session--paint-hunk (session)
  "Move the rail and both windows to the current hunk of SESSION.
In scroll mode both panes also cut from a column that shows its first
change; they redraw instead of scrolling the window, so the gutter stays."
  (let* ((file (review-session-file session))
         (hunk (nth (review-session-hunk session) (plist-get file :hunks)))
         (old (review-session-old-buffer session)) (new (review-session-new-buffer session)))
    (when (and hunk (buffer-live-p old) (buffer-live-p new)
               (buffer-local-value 'review-pane--diff new))
      (let ((column (review-session--hunk-column session hunk)))
        (when (eq review-session-long-lines 'scroll)
          (let ((width (min (review-session--pane-width old) (review-session--pane-width new))))
            (setf (review-session-hscroll session)
                  (min (review-session--hscroll-limit session)
                       (if (< (+ column 8) width) 0 (max 0 (- column (/ width 3))))))))
        (review-session--ensure-layout session)
        (review-session--place-rail session)
        (dolist (buffer (list old new))
          (with-current-buffer buffer
            (let ((start (review-session--row-position buffer (plist-get hunk :start)))
                  (end (review-session--row-position buffer (1+ (plist-get hunk :end)))))
              (when review-session-pulse (review-session--flash start end))
              (goto-char start)
              ;; Point on the change, as far as the layout shows it.
              (move-to-column (+ review-pane--text-column
                                 (if (eq review-session-long-lines 'scroll)
                                     (max 0 (- column (review-session-hscroll session)))
                                   0)))
              ;; Commands also run from the files frame; search every frame.
              (when-let ((w (get-buffer-window buffer t)))
                (set-window-start w (review-session--row-position
                                     buffer (max 0 (- (plist-get hunk :start) 3))))
                (set-window-point w (point))))))))))

(defun review-session--sync-scroll (window start)
  "Keep the other pane level with WINDOW after it scrolls to START.
Every row takes the same number of lines in both panes, so line N of one
is level with line N of the other."
  (with-current-buffer (window-buffer window)
    (when (and review-pane--session (not (bound-and-true-p review-pane--syncing)))
      (let* ((s review-pane--session)
             (other (if (eq review-pane--side 'old) (review-session-new-buffer s) (review-session-old-buffer s)))
             (line (save-excursion (goto-char start) (1- (line-number-at-pos)))))
        (when-let ((ow (and (buffer-live-p other) (get-buffer-window other t))))
          (with-current-buffer other
            (setq-local review-pane--syncing t)
            (unwind-protect
                (set-window-start ow (save-excursion (goto-char (point-min)) (forward-line line) (point)))
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
                   (review-session-hscroll session) 0
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
             (review-session--ensure-layout session)
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

(defun review-session-toggle-long-lines ()
  "Switch the panes between wrapping long lines and scrolling both sideways.
Both panes go back to the current hunk, scrolled to its first change."
  (interactive)
  (setq review-session-long-lines (if (eq review-session-long-lines 'scroll) 'wrap 'scroll))
  (when-let ((s review-session--current))
    (setf (review-session-hscroll s) 0)
    (review-session--ensure-layout s)
    (review-session--paint-hunk s)
    (review-session--notify s))
  (message "Review: long lines %s"
           (if (eq review-session-long-lines 'scroll) "scroll, zh/zl move both panes" "wrap")))

(defun review-session--hscroll-limit (session)
  "The furthest column SESSION's panes scroll to: the widest line's end at the edge."
  (let* ((old (review-session-old-buffer session)) (new (review-session-new-buffer session))
         (index (buffer-local-value 'review-pane--file-index new)))
    (max 0
         (- (review-session--widest (review-session--pane-render session index 'old))
            (review-session--pane-width old))
         (- (review-session--widest (review-session--pane-render session index 'new))
            (review-session--pane-width new)))))

(defun review-session--scroll-by (delta)
  "Scroll both panes DELTA columns sideways, no further than the widest line."
  (let* ((s (review-session--require))
         (old (review-session-old-buffer s)) (new (review-session-new-buffer s)))
    (unless (eq review-session-long-lines 'scroll)
      (user-error "Long lines wrap in this view; zw scrolls them instead"))
    (when (and (buffer-live-p old) (buffer-live-p new) (buffer-local-value 'review-pane--diff new))
      (setf (review-session-hscroll s)
            (max 0 (min (review-session--hscroll-limit s) (+ (review-session-hscroll s) delta))))
      (review-session--ensure-layout s)
      (force-mode-line-update t))))

(defun review-session-scroll-right (&optional count)
  "Scroll both panes right by COUNT times `review-session-scroll-step' columns."
  (interactive "p")
  (review-session--scroll-by (* (or count 1) review-session-scroll-step)))

(defun review-session-scroll-left (&optional count)
  "Scroll both panes left by COUNT times `review-session-scroll-step' columns."
  (interactive "p")
  (review-session--scroll-by (- (* (or count 1) review-session-scroll-step))))

(defun review-session-scroll-right-half ()
  "Scroll both panes right by half their width."
  (interactive)
  (review-session--scroll-by
   (/ (review-session--pane-width (review-session-new-buffer (review-session--require))) 2)))

(defun review-session-scroll-left-half ()
  "Scroll both panes left by half their width."
  (interactive)
  (review-session--scroll-by
   (- (/ (review-session--pane-width (review-session-new-buffer (review-session--require))) 2))))

(defun review-session-scroll-wheel (event)
  "Scroll both panes sideways for a sideways trackpad swipe or a tilted wheel.
Wrapped panes have nothing to scroll, so there it does nothing."
  (interactive "e")
  (when (eq review-session-long-lines 'scroll)
    (let ((right (eq (event-basic-type event) 'wheel-right)))
      (when (bound-and-true-p mouse-wheel-flip-direction) (setq right (not right)))
      (review-session--scroll-by (if right 2 -2)))))

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
         ;; Rows, not lines: a wrapped row spans several.
         (first (or (review-session--row-at begin) 0))
         (last (or (review-session--row-at (if (> end begin) (1- end) end)) -1))
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
          :text (string-join (nreverse text) "\n")
          :diff (review-session--selection-diff
                 review-pane--session
                 (cl-loop for i from first to (min last (1- (length rows)))
                          collect (aref rows i))))))

(defun review-session--selection-diff (session rows)
  "ROWS as a small unified diff with SESSION's side labels, or nil if unchanged.
Quick Ask sends it, so a question about a change sees both sides."
  (when (seq-find (lambda (row) (not (eq (plist-get row :kind) 'ctx))) rows)
    (let ((source (review-session-source session)))
      (string-join
       (append
        (list (concat "--- " (or (review-source-old-label source) "old"))
              (concat "+++ " (or (review-source-new-label source) "new")))
        (mapcan (lambda (row)
                  (pcase (plist-get row :kind)
                    ('ctx (list (concat "  " (plist-get row :new))))
                    ('del (list (concat "- " (plist-get row :old))))
                    ('add (list (concat "+ " (plist-get row :new))))
                    ('both (list (concat "- " (plist-get row :old))
                                 (concat "+ " (plist-get row :new))))))
                rows))
       "\n"))))

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
