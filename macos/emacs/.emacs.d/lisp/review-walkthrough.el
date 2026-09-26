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

(defvar review-walkthrough-render-function #'ignore
  "Called with the session to draw the current step.  Set by the renderer.")

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
Target keys: kind, directory, range, host, owner, repo, name, number."
  (let* ((data (with-temp-buffer
                 (let ((coding-system-for-read 'utf-8)) (insert-file-contents file))
                 (json-parse-buffer :object-type 'plist :array-type 'list :null-object nil)))
         (target (when-let ((tg (plist-get data :target)))
                   (plist-put (copy-sequence tg) :kind (intern (plist-get tg :kind))))))
    (review-walkthrough-start (mapcar #'review-walkthrough--from-json (plist-get data :steps)) target)))

(defun review-walkthrough--step (session)
  (let ((w (review-session-walkthrough session)))
    (and (plist-get w :steps) (aref (plist-get w :steps) (plist-get w :index)))))

(defun review-walkthrough--go (session index)
  "Make step INDEX current in SESSION: show its file and hunk, then draw it."
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
  (when (plist-get (review-session-walkthrough session) :steps)
    (review-walkthrough--go session (plist-get (review-session-walkthrough session) :index))))

(add-hook 'review-store-restored-functions #'review-walkthrough--restored)

(provide 'review-walkthrough)
;;; review-walkthrough.el ends here
