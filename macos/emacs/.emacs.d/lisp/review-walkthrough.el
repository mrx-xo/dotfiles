;;; review-walkthrough.el --- A guided route through a review -*- lexical-binding: t; -*-
;;; Commentary:
;; An agent sends an ordered route of steps, each pointing at lines of the
;; diff.  The session keeps the route, so pausing keeps your place in it.
;; Validation errors go back to the caller as text, never silently.
;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'json)
(require 'review-session)
(require 'review-store)
(require 'review-panel)

(defvar review-walkthrough-render-function #'ignore
  "Called with the session to draw the current step.  Set by the renderer.
It only draws: it never moves a window, so redrawing keeps the panes where
the user left them.  Navigation scrolls to the step itself.")

(defvar review-walkthrough-open-functions nil
  "Alist of (KIND . FUNCTION) that open a review for a TARGET recipe.
FUNCTION returns the session, or nil when the review opens asynchronously.")

(defun review-walkthrough--file-index (session path)
  (cl-position path (review-session-files session) :key (lambda (f) (plist-get f :path)) :test #'equal))

(defun review-walkthrough--rows (file side start end)
  "Rows of FILE whose SIDE line number lies in START..END."
  (let ((key (if (eq side 'old) :old-no :new-no)) (i -1) out)
    (dolist (row (plist-get file :rows))
      (cl-incf i)
      (let ((no (plist-get row key)))
        (when (and no (<= start no end)) (push i out))))
    (nreverse out)))

(defun review-walkthrough--hunk-of (file rows)
  "Index of the first hunk of FILE containing one of ROWS, or nil."
  (cl-position-if (lambda (h) (seq-some (lambda (r) (<= (plist-get h :start) r (plist-get h :end))) rows))
                  (plist-get file :hunks)))

(defun review-walkthrough--nearest (file side line)
  "\" (nearest hunk A-B)\" for the SIDE hunk closest to LINE, or \"\"."
  (let* ((start (if (eq side 'old) :old-start :new-start))
         (count (if (eq side 'old) :old-count :new-count))
         (best (car (sort (copy-sequence (plist-get file :hunks))
                          (lambda (a b) (< (abs (- (plist-get a start) line))
                                           (abs (- (plist-get b start) line))))))))
    (if best
        (format " (nearest hunk %d-%d)" (plist-get best start)
                (+ (plist-get best start) (max 0 (1- (plist-get best count)))))
      "")))

(defun review-walkthrough--normalize (step)
  (let ((start (plist-get step :line-start)))
    (list :path (plist-get step :path)
          :side (or (plist-get step :side) 'new)
          :line-start start
          :line-end (or (plist-get step :line-end) start)
          :title (plist-get step :title)
          :body (plist-get step :body)
          :question (plist-get step :question)
          :children nil)))

(defun review-walkthrough--check (session step n)
  "Nil when STEP, number N, is valid in SESSION; :loading; or an error string."
  (let* ((step (review-walkthrough--normalize step))
         (path (plist-get step :path)) (side (plist-get step :side))
         (start (plist-get step :line-start)) (end (plist-get step :line-end)))
    (cond
     ((not (and (stringp path) (integerp start) (integerp end) (stringp (plist-get step :title))))
      (format "step %d: needs :path, :line-start and :title" n))
     ((not (memq side '(old new))) (format "step %d: :side must be old or new" n))
     ((< end start) (format "step %d: :line-end is before :line-start" n))
     (t
      (let ((index (review-walkthrough--file-index session path)))
        (if (not index) (format "step %d: %s is not in this review" n path)
          (let ((file (review-session-file session index)))
            (cond
             ((or (plist-get file :binary) (plist-get file :unchanged))
              (format "step %d: %s has no text diff" n path))
             ((not (plist-get file :loaded)) :loading)
             ((not (review-walkthrough--hunk-of file (review-walkthrough--rows file side start end)))
              (format "step %d: %s:%d-%d (%s) is not in a hunk%s" n path start end side
                      (review-walkthrough--nearest file side start)))))))))))

(defun review-walkthrough--session (target)
  "The session for TARGET, opening or resuming it if needed, or a report string."
  (let* ((current review-session--current)
         (current-key (and current (review-source-recipe (review-session-source current))
                           (review-source-key (review-source-recipe (review-session-source current))))))
    (cond
     ((null target) (or current "error: no review is open; pass a TARGET"))
     ((equal current-key (review-source-key target)) current)
     (t
      (when current (review-session-pause))
      (let ((saved (review-store-load (review-source-key target))))
        (cond
         (saved (review-store-restore saved))
         ((eq (plist-get target :kind) 'git-range)
          (let ((s (review-session-start (review-source-git-range (plist-get target :directory)
                                                                  (plist-get target :range)))))
            (review-panel-open s)
            s))
         ((alist-get (plist-get target :kind) review-walkthrough-open-functions)
          (or (funcall (alist-get (plist-get target :kind) review-walkthrough-open-functions) target)
              "retry: opening the review; run the same command again in a few seconds"))
         (t (format "error: cannot open a %s review" (plist-get target :kind)))))))))

(defun review-walkthrough-start (steps &optional target)
  "Show STEPS as a walkthrough of TARGET's review (a recipe), or the current one.
Return a report for the calling agent: `ok N of M steps' and one line per
rejected step, `retry: ...', or `error: ...'."
  (let ((session (review-walkthrough--session target)))
    (if (stringp session) session
      (let ((n 0) errors loading valid)
        (dolist (step (append steps nil))
          (cl-incf n)
          (pcase (review-walkthrough--check session step n)
            ('nil (push (review-walkthrough--normalize step) valid))
            (:loading (cl-pushnew (plist-get step :path) loading :test #'equal))
            (err (push err errors))))
        (cond
         (loading
          (dolist (path loading)
            (review-session-load session (review-walkthrough--file-index session path) #'ignore))
          (format "retry: loading %s; run the same command again in a few seconds"
                  (string-join (nreverse loading) ", ")))
         ((null valid)
          (string-join (cons "error: no valid steps" (nreverse errors)) "\n"))
         (t
          ;; Capture the count before `nreverse' below destructively
          ;; relinks `valid': afterward the variable no longer holds
          ;; the whole list, only whatever cons `nreverse' left at its
          ;; head.
          (let ((count (length valid)))
            (setf (review-session-walkthrough session) (list :steps (vconcat (nreverse valid)) :index 0))
            (review-walkthrough--go session 0)
            (string-join (cons (format "ok %d of %d steps" count n) (nreverse errors)) "\n"))))))))

(defun review-walkthrough--from-json (object)
  (let ((keys '((:path . :path) (:side . :side) (:line_start . :line-start) (:line_end . :line-end)
                (:title . :title) (:body . :body) (:question . :question)))
        out)
    (dolist (pair keys)
      (let ((v (plist-get object (car pair))))
        (when v (setq out (plist-put out (cdr pair) (if (eq (car pair) :side) (intern v) v))))))
    out))

(defun review-walkthrough-start-file (file)
  "Start the walkthrough in JSON FILE: {\"target\": {...}, \"steps\": [...]}.
Step keys: path, side, line_start, line_end, title, body, question.
Target keys: kind, directory, range, host, owner, repo, name, number.
FILE that cannot be read or parsed, or whose target has no kind, reports
`error: invalid route file: ...' instead of signalling: an agent's
malformed reply must land on the caller's error/correction path, not
escape it and leave a walkthrough request stalled forever.  Only that
reading and parsing is guarded; once FILE is decoded, `review-walkthrough-start'
runs unprotected, so a real bug in validation, navigation, or rendering
signals normally instead of being relabelled as a bad route."
  (let ((parsed
         (condition-case err
             (let* ((data (with-temp-buffer
                            (let ((coding-system-for-read 'utf-8)) (insert-file-contents file))
                            (json-parse-buffer :object-type 'plist :array-type 'list :null-object nil)))
                    (target (when-let ((tg (plist-get data :target)))
                              (plist-put (copy-sequence tg) :kind (intern (plist-get tg :kind))))))
               (list :steps (mapcar #'review-walkthrough--from-json (plist-get data :steps)) :target target))
           (error (format "error: invalid route file: %s" (error-message-string err))))))
    (if (stringp parsed) parsed
      (review-walkthrough-start (plist-get parsed :steps) (plist-get parsed :target)))))

(defun review-walkthrough--step (session)
  (let ((w (review-session-walkthrough session)))
    (and (plist-get w :steps) (aref (plist-get w :steps) (plist-get w :index)))))

(defun review-walkthrough--go (session index)
  "Make step INDEX current in SESSION: show its file and hunk, draw, scroll there."
  (let* ((w (review-session-walkthrough session))
         (steps (plist-get w :steps))
         (index (max 0 (min index (1- (length steps)))))
         (step (aref steps index))
         (file-index (review-walkthrough--file-index session (plist-get step :path)))
         (file (review-session-file session file-index))
         (hunk (or (review-walkthrough--hunk-of
                    file (review-walkthrough--rows file (plist-get step :side)
                                                   (plist-get step :line-start) (plist-get step :line-end)))
                   0)))
    (setf (review-session-walkthrough session) (plist-put (copy-sequence w) :index index))
    (if (eq file-index (review-session-current session))
        (progn (setf (review-session-hunk session) hunk)
               (review-session--paint-hunk session))
      (review-session-show file-index hunk))
    (funcall review-walkthrough-render-function session)
    (review-walkthrough--scroll-to-step session)
    (review-session--notify session)))

(defun review-walkthrough--require ()
  (let ((s (review-session--require)))
    (unless (plist-get (review-session-walkthrough s) :steps)
      (user-error "No walkthrough in this review"))
    s))

(defun review-walkthrough-next ()
  "Go to the next step of the walkthrough."
  (interactive)
  (let* ((s (review-walkthrough--require)) (w (review-session-walkthrough s)))
    (when (>= (1+ (plist-get w :index)) (length (plist-get w :steps)))
      (user-error "Last step of the walkthrough"))
    (review-walkthrough--go s (1+ (plist-get w :index)))))

(defun review-walkthrough-prev ()
  "Go to the previous step of the walkthrough."
  (interactive)
  (let* ((s (review-walkthrough--require)) (w (review-session-walkthrough s)))
    (when (zerop (plist-get w :index)) (user-error "First step of the walkthrough"))
    (review-walkthrough--go s (1- (plist-get w :index)))))

(defun review-walkthrough-goto (n)
  "Go to step N (1-based) of the walkthrough."
  (interactive "nStep: ")
  (review-walkthrough--go (review-walkthrough--require) (1- n)))

(defun review-walkthrough-quit ()
  "End the walkthrough; the review stays open."
  (interactive)
  (let ((s (review-session--require)))
    (setf (review-session-walkthrough s) nil)
    (funcall review-walkthrough-render-function s)
    (review-session--notify s)))

(defun review-walkthrough--restored (session _record)
  "Draw a resumed walkthrough where SESSION was left.
No navigation: the saved file, hunk and scroll win over the step's."
  (when (plist-get (review-session-walkthrough session) :steps)
    (funcall review-walkthrough-render-function session)
    (review-session--notify session)))

(add-hook 'review-store-restored-functions #'review-walkthrough--restored)

;;;; Rendering
;; Figma "Walkthrough / compare" (37:2): a purple-railed card above the
;; step's lines, a filler of the same height in the other pane so rows stay
;; level, purple line numbers on the step, everything else dimmed.

(defcustom review-walkthrough-dim t
  "Dim every line outside the current walkthrough step."
  :type 'boolean :group 'review)

(defface review-walk-accent '((t :foreground "#d3869b" :weight bold)) "Walkthrough purple.")
(defface review-walk-card '((t :background "#322830" :extend t)) "Card background.")
(defface review-walk-filler '((t :background "#232627" :extend t)) "Filler facing the card.")
(defface review-walk-rail '((t :background "#d3869b")) "Card rail.")
(defface review-walk-title '((t :foreground "#ebdbb2" :weight bold)) "Step title.")
(defface review-walk-body '((t :foreground "#a89984")) "Step explanation.")
(defface review-walk-question '((t :foreground "#fabd2f")) "Review question.")
(defface review-walk-step-number '((t :foreground "#d3869b" :weight bold)) "Line numbers of the step.")
(defface review-walk-dim '((t :foreground "#5a524c")) "Text outside the step.")
(defface review-walk-dim-added '((t :foreground "#5a524c" :background "#23241b" :extend t))
  "Added rows outside the step.  Faces cannot be translucent, so this is a muted copy.")
(defface review-walk-dim-removed '((t :foreground "#5a524c" :background "#281f1e" :extend t))
  "Removed rows outside the step.")

(defun review-walkthrough--wrap (text width)
  (with-temp-buffer
    (insert text)
    (let ((fill-column width)) (fill-region (point-min) (point-max)))
    (split-string (buffer-string) "\n")))

(defun review-walkthrough--card (step n total width)
  "The card for STEP, number N of TOTAL, WIDTH columns wide, as a before-string."
  (let* ((width (max 30 (- (or width 80) 8)))
         (rail (propertize " " 'face 'review-walk-rail))
         (wrap (lambda (text face)
                 (mapcar (lambda (l) (propertize l 'face face)) (review-walkthrough--wrap text width))))
         (lines (append
                 (list (propertize "◆ AGENT WALKTHROUGH" 'face 'review-walk-accent)
                       (concat (propertize (format "%d/%d" n total) 'face 'review-walk-accent) "  "
                               (propertize (plist-get step :title) 'face 'review-walk-title)))
                 (when (plist-get step :body) (funcall wrap (plist-get step :body) 'review-walk-body))
                 (when (plist-get step :question)
                   (funcall wrap (concat "? " (plist-get step :question)) 'review-walk-question))))
         (card (mapconcat (lambda (line) (concat rail "   " line "\n")) lines "")))
    (add-face-text-property 0 (length card) 'review-walk-card t card)
    card))

(defun review-walkthrough--overlay (buffer kind start-row &optional end-row)
  (let* ((start (review-session--row-position buffer start-row))
         (end (if end-row (review-session--row-position buffer end-row) start))
         (o (make-overlay start end buffer)))
    (overlay-put o 'review-walk t)
    (overlay-put o 'review-walk-kind kind)
    (overlay-put o 'priority 90)
    o))

(defun review-walkthrough--mark (buffer first last)
  "Purple line numbers on every line of rows FIRST..LAST in BUFFER."
  (with-current-buffer buffer
    (let ((digits (max 0 (- review-pane--text-column 3))))
      (save-excursion
        (goto-char (review-session--row-position buffer first))
        (let ((end (review-session--row-position buffer (1+ last))))
          (while (< (point) end)
            (let ((o (make-overlay (point) (min (line-end-position) (+ (point) digits)))))
              (overlay-put o 'review-walk t)
              (overlay-put o 'review-walk-kind 'mark)
              (overlay-put o 'priority 95)
              (overlay-put o 'face 'review-walk-step-number))
            (forward-line 1)))))))

(defun review-walkthrough--dim (session buffer first last)
  "Dim every row of BUFFER outside FIRST..LAST, keeping a muted diff colour."
  (with-current-buffer buffer
    (let* ((side review-pane--side)
           (rows (vconcat (plist-get (review-session-file session review-pane--file-index) :rows)))
           (face-of (lambda (row)
                      (let ((kind (plist-get row :kind)))
                        (cond ((and (eq side 'old) (memq kind '(del both)) (plist-get row :old-no))
                               'review-walk-dim-removed)
                              ((and (eq side 'new) (memq kind '(add both)) (plist-get row :new-no))
                               'review-walk-dim-added)
                              (t 'review-walk-dim)))))
           (count (length rows)) (i 0))
      (while (< i count)
        (if (<= first i last) (setq i (1+ last))
          (let ((face (funcall face-of (aref rows i))) (j i))
            (while (and (< (1+ j) count) (not (<= first (1+ j) last))
                        (eq face (funcall face-of (aref rows (1+ j)))))
              (cl-incf j))
            (overlay-put (review-walkthrough--overlay buffer 'dim i (1+ j)) 'face face)
            (setq i (1+ j))))))))

(defun review-walkthrough--step-rows (session)
  "The current step of SESSION and its rows, when its file is in the panes."
  (let ((old (review-session-old-buffer session)) (new (review-session-new-buffer session)))
    (when-let* ((step (review-walkthrough--step session))
                (_ (equal (plist-get step :path) (plist-get (review-session-file session) :path)))
                (_ (and (buffer-live-p old) (buffer-live-p new) (buffer-local-value 'review-pane--diff new)))
                (rows (review-walkthrough--rows (review-session-file session) (plist-get step :side)
                                                (plist-get step :line-start) (plist-get step :line-end))))
      (cons step rows))))

(defun review-walkthrough--draw (session)
  "Draw SESSION's current step in its panes, replacing any earlier drawing.
Overlays only: the windows stay put, so a relayout (resize, zw, zh/zl) or a
resume redraws the step without snapping the panes back to it."
  (let ((old (review-session-old-buffer session)) (new (review-session-new-buffer session)))
    (dolist (b (list old new))
      (when (buffer-live-p b)
        (with-current-buffer b (remove-overlays (point-min) (point-max) 'review-walk t))))
    (when-let ((step-rows (review-walkthrough--step-rows session)))
      (let* ((step (car step-rows)) (rows (cdr step-rows))
             (w (review-session-walkthrough session))
             (first (car rows)) (last (car (last rows)))
             (here (if (eq (plist-get step :side) 'old) old new))
             (there (if (eq here old) new old))
             (window (get-buffer-window here t))
             (card (review-walkthrough--card step (1+ (plist-get w :index)) (length (plist-get w :steps))
                                             (and window (window-body-width window)))))
        (overlay-put (review-walkthrough--overlay here 'card first) 'before-string card)
        (overlay-put (review-walkthrough--overlay there 'filler first) 'before-string
                     (propertize (apply #'concat (make-list (cl-count ?\n card) "\n"))
                                 'face 'review-walk-filler))
        (review-walkthrough--mark here first last)
        (when review-walkthrough-dim
          (review-walkthrough--dim session old first last)
          (review-walkthrough--dim session new first last))))))

(defun review-walkthrough--scroll-to-step (session)
  "Scroll SESSION's panes so the current step's card and lines show."
  (when-let ((step-rows (review-walkthrough--step-rows session)))
    (let ((first (cadr step-rows)))
      (dolist (b (list (review-session-old-buffer session) (review-session-new-buffer session)))
        (when-let ((win (get-buffer-window b t)))
          (set-window-start win (review-session--row-position b (max 0 (- first 2))))
          (set-window-point win (review-session--row-position b first)))))))

(setq review-walkthrough-render-function #'review-walkthrough--draw)
;; The draw-and-scroll renderer of earlier versions sat on this hook; drop
;; it so reloading this file in a live Emacs cannot leave it scrolling.
(remove-hook 'review-session-layout-hook 'review-walkthrough--render)
(add-hook 'review-session-layout-hook #'review-walkthrough--draw)

;;;; Panel and bar
;; Figma "Files panel / walkthrough" (37:407).

(defun review-walkthrough--panel-row (content bg)
  (review-panel--row content :bg bg :pad '(4 4)))

(defun review-walkthrough--panel-section (session _width)
  (when-let ((w (review-session-walkthrough session)))
    (let ((steps (plist-get w :steps)) (index (plist-get w :index))
          (head (lambda (right)
                  (review-panel--row (concat (review-panel--gap 16)
                                             (review-panel--txt "◆ WALKTHROUGH" 'purple :weight 'bold :height 0.92)
                                             (review-panel--gap 10) right)
                                     :bg 'bg-0 :pad '(12 6)))))
      (concat
       (cond
        ((eq (plist-get w :status) 'planning)
         (funcall head (review-panel--txt "Planning route…" 'dim :height 0.92)))
        ((eq (plist-get w :status) 'no-route)
         (funcall head (review-panel--txt "no route returned · W shows the answer" 'yellow :height 0.92)))
        (t
         (concat
          (funcall head (review-panel--txt (format "%d of %d" (1+ index) (length steps)) 'dim :height 0.92))
          (mapconcat
           (lambda (i)
             (let* ((step (aref steps i))
                    (state (cond ((< i index) 'done) ((= i index) 'current) (t 'pending)))
                    (bg (if (eq state 'current) 'bg-1 'bg-0))
                    (text (concat
                           (review-walkthrough--panel-row
                            (concat (review-panel--gap 25)
                                    (review-panel--txt (pcase state ('done "●") ('current "❯") (_ "○"))
                                                       (if (eq state 'pending) 'dim 'purple))
                                    (review-panel--gap 10)
                                    (review-panel--txt (number-to-string (1+ i)) 'dim :height 0.92)
                                    (review-panel--gap 10)
                                    (review-panel--txt (plist-get step :title) (if (eq state 'done) 'dim 'fg)
                                                       :weight (and (eq state 'current) 'medium)))
                            bg)
                           (review-walkthrough--panel-row
                            (concat (review-panel--gap 60)
                                    (review-panel--txt (format "%s:%d" (plist-get step :path) (plist-get step :line-start))
                                                       'mute :height 0.83))
                            bg))))
               (propertize text 'review-walk-step i
                           'review-action (lambda () (review-walkthrough--go session i)))))
           (number-sequence 0 (1- (length steps))) ""))))
       (review-panel--divider)))))

(defun review-walkthrough--bar (session)
  (when-let* ((w (review-session-walkthrough session)) (steps (plist-get w :steps)))
    (review-panel--txt (format "WALK %d/%d" (1+ (plist-get w :index)) (length steps))
                       'purple :weight 'bold :height 0.92)))

(add-hook 'review-panel-section-functions #'review-walkthrough--panel-section)
(add-hook 'review-panel-bar-functions #'review-walkthrough--bar)

(provide 'review-walkthrough)
;;; review-walkthrough.el ends here
