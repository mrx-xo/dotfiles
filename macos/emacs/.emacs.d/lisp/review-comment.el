;;; review-comment.el --- Draft line comments in a review -*- lexical-binding: t; -*-

;;; Commentary:
;; Write comments on lines while reviewing.  A draft is a plist kept in
;; the session's `comments' slot:
;;   :id :path :side (old or new) :line :start-line (nil for one line)
;;   :text (the source text of :line, to find it again) :body
;; and, when set, :outdated (it has no postable place) and :pending (it
;; came from an earlier load of the review and waits to be placed again).
;; Drafts show as cards under their lines, are saved with the review,
;; and are posted together as one review by `review-comment-submit'.
;; This file knows no provider: `review-comment-submit-function' posts.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'review-session)
(require 'review-store)
(require 'review-panel)

(defconst review-comment-context 3
  "Rows of context around a hunk that can take a comment.
Providers accept comments only on lines of their own diff, which shows
three lines of context.")

(defvar review-comment--carried (make-hash-table :test #'equal)
  "Drafts of reviews that closed with them unsent, by review key.")

(defvar review-comment-compose-styles
  '((window review-comment--show-window review-comment--hide-window))
  "Ways to show the compose buffer, as (STYLE SHOW HIDE).
SHOW is called with the buffer, the pane window the comment started in
\(or nil) and the position of the commented line in it (or nil for a
review summary).  HIDE is called with the buffer.")

(defcustom review-comment-compose-style 'window
  "How the compose buffer is shown: a STYLE of `review-comment-compose-styles'."
  :type 'symbol :group 'review)

;;;; The model

(defun review-comment--rows (file side start end)
  "Row indexes of FILE whose SIDE line number lies in START..END."
  (let ((key (if (eq side 'old) :old-no :new-no)) (i -1) out)
    (dolist (row (plist-get file :rows))
      (cl-incf i)
      (let ((no (plist-get row key)))
        (when (and no (<= start no end)) (push i out))))
    (nreverse out)))

(defun review-comment--commentable-p (file rows)
  "Non-nil when ROWS all lie in one hunk of FILE, context rows included."
  (and rows
       (seq-some (lambda (hunk)
                   (let ((low (- (plist-get hunk :start) review-comment-context))
                         (high (+ (plist-get hunk :end) review-comment-context)))
                     (seq-every-p (lambda (row) (<= low row high)) rows)))
                 (plist-get file :hunks))))

(defun review-comment--line-text (file side line)
  "The source text of SIDE's LINE in FILE, or nil."
  (when-let ((row (car (review-comment--rows file side line line))))
    (substring-no-properties
     (plist-get (nth row (plist-get file :rows)) (if (eq side 'old) :old :new)))))

(defun review-comment--where (draft)
  "\"line N\" or \"lines A-B\" for DRAFT."
  (if (plist-get draft :start-line)
      (format "lines %d-%d" (plist-get draft :start-line) (plist-get draft :line))
    (format "line %d" (plist-get draft :line))))

(defun review-comment--label (draft)
  "\"PATH:LINE (SIDE)\" for DRAFT, with a range as A-B."
  (format "%s:%s (%s)" (plist-get draft :path)
          (if (plist-get draft :start-line)
              (format "%d-%d" (plist-get draft :start-line) (plist-get draft :line))
            (plist-get draft :line))
          (plist-get draft :side)))

(defun review-comment--without (draft &rest keys)
  "DRAFT without KEYS."
  (cl-loop for (k v) on draft by #'cddr unless (memq k keys) append (list k v)))

(defun review-comment--reanchor (draft file)
  "DRAFT placed on FILE's rows as they are now.
It goes to the line of its side whose text equals the draft's, nearest
its old line; a range keeps its length.  With no such line, or one that
cannot take a comment, the draft is marked :outdated and keeps its line."
  (let* ((side (plist-get draft :side))
         (number-key (if (eq side 'old) :old-no :new-no))
         (text-key (if (eq side 'old) :old :new))
         (line (plist-get draft :line)) (text (plist-get draft :text))
         (span (and (plist-get draft :start-line) (- line (plist-get draft :start-line))))
         (draft (review-comment--without draft :pending :outdated))
         best)
    (dolist (row (plist-get file :rows))
      (let ((no (plist-get row number-key)))
        (when (and no (equal (plist-get row text-key) text)
                   (or (null best) (< (abs (- no line)) (abs (- best line)))))
          (setq best no))))
    (let ((start (and best span (- best span))))
      (if (and best (or (null start) (>= start 1))
               (review-comment--commentable-p
                file (review-comment--rows file side (or start best) best)))
          (plist-put (plist-put draft :line best) :start-line start)
        (plist-put draft :outdated t)))))

(provide 'review-comment)
;;; review-comment.el ends here
