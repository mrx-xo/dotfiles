;;; review-handoff.el --- The author's walkthrough, published with the change -*- lexical-binding: t; -*-
;;; Commentary:
;; The agent that wrote a change publishes a handoff: readable intent,
;; decisions and evidence, plus a hidden route in the walkthrough format.
;; On a PR it lives in the body, inside a collapsed <details> block:
;;
;;   <!-- review-handoff v1 head=<sha>
;;   {"steps": [...], "session": {...}}
;;   -->
;;
;; A git-range review with no PR reads .git/review-handoffs/<sha>.json,
;; which holds the same JSON.  The route is checked against the reviewed
;; head: a handoff written for an older commit is stale, not wrong.
;; Parsing never signals; a malformed handoff becomes (:error MESSAGE).
;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'review-session)
(require 'review-walkthrough)

(defconst review-handoff--marker
  "<!--[ \t]*review-handoff[ \t]+v1[ \t]+head=\\([0-9a-fA-F]+\\)"
  "Start of a handoff block; group 1 is the head commit it was written for.")

(defun review-handoff--decode (json)
  "Route plist from JSON text: (:steps STEPS :session SESSION), or (:error MSG)."
  (condition-case err
      (let ((data (json-parse-string json :object-type 'plist :array-type 'list
                                     :null-object nil :false-object nil)))
        (unless (plistp data) (error "not a JSON object"))
        (unless (plist-get data :steps) (error "no steps"))
        (list :steps (mapcar #'review-walkthrough--from-json (plist-get data :steps))
              :session (plist-get data :session)))
    (error (list :error (format "invalid handoff route: %s" (error-message-string err))))))

(defun review-handoff--readable (body start end)
  "The readable handoff around the block at START..END in BODY.
The enclosing <details> content without its summary and the hidden block;
the whole BODY without the block when there is no <details>."
  (let* ((open (save-match-data
                 (let ((pos nil) (from 0))
                   (while (and (setq from (string-match "<details[^>]*>" body from)) (< from start))
                     (setq pos (match-end 0) from (match-end 0)))
                   pos)))
         (close (and open (save-match-data (string-match "</details>" body end))))
         (text (concat (substring body (or open 0) start)
                       (substring body end (or close (length body))))))
    (string-trim (replace-regexp-in-string "<summary>.*?</summary>" "" text))))

(defun review-handoff-parse (body)
  "The last handoff in BODY: (:head SHA :steps S :session X :text T), or nil.
A block whose JSON cannot be read gives (:head SHA :error MESSAGE)."
  (when (stringp body)
    (let ((body (replace-regexp-in-string "\r\n" "\n" body))
          (from 0) found)
      (while (string-match review-handoff--marker body from)
        (setq found (list (match-beginning 0) (match-end 0) (downcase (match-string 1 body)))
              from (match-end 0)))
      (when found
        (pcase-let* ((`(,start ,json-start ,head) found)
                     (close (string-search "-->" body json-start)))
          (if (not close)
              (list :head head :error "invalid handoff route: block is not closed with -->")
            (let ((route (review-handoff--decode (substring body json-start close))))
              (append (list :head head) route
                      (list :text (review-handoff--readable body start (+ close 3)))))))))))

(defun review-handoff-read-file (file)
  "The handoff JSON in FILE, as `review-handoff-parse' returns, or nil if absent."
  (when (file-readable-p file)
    (let ((json (with-temp-buffer
                  (let ((coding-system-for-read 'utf-8)) (insert-file-contents file))
                  (buffer-string))))
      (append (list :head (downcase (file-name-base file)))
              (review-handoff--decode json)
              (list :text nil)))))

(defun review-handoff-local-file (directory head)
  "Where a git-range review of HEAD in DIRECTORY keeps its handoff."
  (expand-file-name (format "review-handoffs/%s.json" head)
                    (string-trim (shell-command-to-string
                                  (format "git -C %s rev-parse --absolute-git-dir"
                                          (shell-quote-argument (expand-file-name directory)))))))

(defun review-handoff-same-commit-p (a b)
  "Non-nil when shas A and B name the same commit (either may be abbreviated)."
  (and (stringp a) (stringp b) (>= (min (length a) (length b)) 7)
       (let ((a (downcase a)) (b (downcase b)))
         (or (string-prefix-p a b) (string-prefix-p b a)))))

;;; Storage on the session

(defun review-handoff-get (session)
  "SESSION's handoff, with :stale set when it was written for another commit.
A git-range review looks for its local file the first time it is asked."
  (let ((stored (plist-get (review-session-extensions session) :handoff))
        (recipe (review-source-recipe (review-session-source session))))
    (when (and (null stored) (eq (plist-get recipe :kind) 'git-range))
      (let ((head (cdr (plist-get recipe :revs))))
        (when (stringp head)
          (setq stored (or (review-handoff-read-file
                            (review-handoff-local-file (plist-get recipe :directory) head))
                           (list :none t)))
          (review-handoff--put session (plist-put stored :reviewed head)))))
    (unless (or (null stored) (plist-get stored :none))
      (if (review-handoff-same-commit-p (plist-get stored :head) (plist-get stored :reviewed))
          stored
        (plist-put (copy-sequence stored) :stale t)))))

(defun review-handoff--put (session handoff)
  (setf (review-session-extensions session)
        (plist-put (copy-sequence (review-session-extensions session)) :handoff handoff)))

(defun review-handoff-collect (session body reviewed-head)
  "Store the handoff in PR BODY on SESSION, checked against REVIEWED-HEAD.
Return the stored handoff, or nil when BODY has none."
  (let ((handoff (review-handoff-parse body)))
    (review-handoff--put session (and handoff (plist-put handoff :reviewed reviewed-head)))
    handoff))

;;; Playing it

(defun review-handoff-start (session)
  "Start SESSION's author route.  Return the walkthrough report string."
  (let* ((handoff (review-handoff-get session))
         (report (if (plist-get handoff :error)
                     (concat "error: " (plist-get handoff :error))
                   (review-walkthrough-start (plist-get handoff :steps)))))
    (when (and (string-prefix-p "ok " report) (review-session-walkthrough session))
      (setf (review-session-walkthrough session)
            (plist-put (copy-sequence (review-session-walkthrough session)) :author t))
      (review-session--notify session))
    report))

(defun review-handoff-context-text (session)
  "The handoff's readable text and session reference for a conversation, or nil.
Only while SESSION is playing the author's route."
  (when-let* (((plist-get (review-session-walkthrough session) :author))
              (handoff (review-handoff-get session)))
    (concat "Author handoff"
            (when (plist-get handoff :stale) " (written for an older commit)")
            ":\n" (or (plist-get handoff :text) "(route only, no readable text)") "\n"
            (when-let* ((s (plist-get handoff :session)))
              (format "Author session reference: %S\n" s))
            "Check these claims against the code; do not defend them.\n")))

(defun review-handoff--bar (session)
  "`WALK ready' in the bar when an author route waits and none is running."
  (when-let* (((null (plist-get (review-session-walkthrough session) :steps)))
              (handoff (review-handoff-get session))
              ((null (plist-get handoff :error))))
    (review-panel--txt (if (plist-get handoff :stale) "WALK ready (older commit)" "WALK ready")
                       'purple :weight 'bold :height 0.92)))

(add-hook 'review-panel-bar-functions #'review-handoff--bar)

(provide 'review-handoff)
;;; review-handoff.el ends here
