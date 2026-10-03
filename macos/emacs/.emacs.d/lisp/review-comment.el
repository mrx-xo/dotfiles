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

;;;; Cards

(defface review-comment-rail '((t :background "#fabd2f")) "Draft card rail.")
(defface review-comment-card '((t :background "#32302a" :extend t)) "Draft card background.")
(defface review-comment-tag '((t :foreground "#fabd2f" :weight bold)) "The DRAFT tag.")
(defface review-comment-body '((t :foreground "#ebdbb2")) "Draft text.")
(defface review-comment-dim '((t :foreground "#7c6f64")) "Line range, and all of an outdated card.")

(defun review-comment--wrap (text width)
  (with-temp-buffer
    (insert text)
    (let ((fill-column width)) (fill-region (point-min) (point-max)))
    (split-string (buffer-string) "\n")))

(defun review-comment--card (draft width)
  "The card for DRAFT, WIDTH columns wide, as pane lines.
Its rail and indent are chrome, left out of a selection's text.  Every
character carries `review-comment-id', so a key on the card finds it."
  (let* ((width (max 30 (- (or width 80) 8)))
         (outdated (plist-get draft :outdated))
         (rail (concat (propertize " " 'face 'review-comment-rail 'review-extra-chrome t)
                       (propertize "   " 'review-extra-chrome t)))
         (head (concat (propertize (if outdated "OUTDATED" "DRAFT")
                                   'face (if outdated 'review-comment-dim 'review-comment-tag))
                       (propertize (concat "  " (review-comment--where draft)) 'face 'review-comment-dim)))
         (body (mapcar (lambda (line)
                         (propertize line 'face (if outdated 'review-comment-dim 'review-comment-body)))
                       (review-comment--wrap (plist-get draft :body) width)))
         (pad (lambda ()
                (review-session-short-line
                 0.5 (propertize " " 'face 'review-comment-rail 'review-extra-chrome t
                                 'display '(space :width 1 :height 0.5)))))
         (card (concat (funcall pad)
                       (mapconcat (lambda (line) (concat rail line "\n")) (cons head body) "")
                       (funcall pad))))
    (add-face-text-property 0 (length card) 'review-comment-card t card)
    (put-text-property 0 (length card) 'review-comment-id (plist-get draft :id) card)
    card))

(defun review-comment--anchor-row (file draft)
  "The row of FILE that DRAFT's card stands under, or nil without rows.
The last row at or before the draft's line on its side, so a draft whose
line is gone still has a place."
  (let ((key (if (eq (plist-get draft :side) 'old) :old-no :new-no))
        (line (plist-get draft :line)) (i -1) best)
    (dolist (row (plist-get file :rows))
      (cl-incf i)
      (let ((no (plist-get row key)))
        (when (and no (<= no line)) (setq best i))))
    (or best (and (plist-get file :rows) 0))))

(defun review-comment--extras (session index)
  "The cards of SESSION's drafts in file INDEX, each under its line.
For `review-session-layout-extras-functions'."
  (let* ((file (review-session-file session index))
         (path (plist-get file :path)))
    (review-comment--settle session index)
    (delq nil
          (mapcar
           (lambda (draft)
             (when (equal (plist-get draft :path) path)
               (when-let ((row (review-comment--anchor-row file draft)))
                 (let* ((side (plist-get draft :side))
                        (buffer (if (eq side 'old) (review-session-old-buffer session)
                                  (review-session-new-buffer session)))
                        (window (and (buffer-live-p buffer) (get-buffer-window buffer t))))
                   ;; Extra lines go before a row: under ROW is before ROW + 1.
                   (list (1+ row) side
                         (review-comment--card draft (and window (window-body-width window))))))))
           (review-session-comments session)))))

(add-hook 'review-session-layout-extras-functions #'review-comment--extras)

;;;; Drafts in the session

(defun review-comment--require-pr (session)
  (when (eq (plist-get (review-source-recipe (review-session-source session)) :kind) 'git-range)
    (user-error "This review is a git range, not a PR")))

(defun review-comment--before-p (a b)
  "Non-nil when draft A sorts before draft B: by path, then line, then id."
  (let ((pa (plist-get a :path)) (pb (plist-get b :path)))
    (cond ((string< pa pb) t)
          ((string< pb pa) nil)
          ((/= (plist-get a :line) (plist-get b :line)) (< (plist-get a :line) (plist-get b :line)))
          (t (< (plist-get a :id) (plist-get b :id))))))

(defun review-comment--changed (session)
  "Show and save SESSION's drafts after a change to them."
  (when (eq session review-session--current)
    (review-session--ensure-layout session)
    (review-session--notify session)
    (when (review-source-recipe (review-session-source session))
      (condition-case err (review-store-save session)
        (error (message "Review: could not save the drafts: %s" (error-message-string err)))))))

(defun review-comment--add (session draft)
  "Give DRAFT an id and keep it in SESSION."
  (let ((id (1+ (apply #'max 0 (mapcar (lambda (d) (plist-get d :id))
                                       (review-session-comments session))))))
    (setf (review-session-comments session)
          (sort (cons (append (list :id id) draft) (copy-sequence (review-session-comments session)))
                #'review-comment--before-p))
    (review-comment--changed session)))

(defun review-comment--update (session id body)
  "Give SESSION's draft ID the text BODY."
  (setf (review-session-comments session)
        (mapcar (lambda (d) (if (eql (plist-get d :id) id) (plist-put (copy-sequence d) :body body) d))
                (review-session-comments session)))
  (review-comment--changed session))

(defun review-comment--remove (session id)
  (setf (review-session-comments session)
        (seq-remove (lambda (d) (eql (plist-get d :id) id)) (review-session-comments session)))
  (review-comment--changed session))

(defun review-comment--draft-at (session pos)
  "SESSION's draft whose card the line at POS in this pane belongs to, or nil."
  (when-let ((id (save-excursion
                   (goto-char pos)
                   (get-text-property (line-beginning-position) 'review-comment-id))))
    (seq-find (lambda (d) (eql (plist-get d :id) id)) (review-session-comments session))))

(defun review-comment--target (session)
  "A new draft, without :id and :body, for the line or region in this pane.
Signals a `user-error' where a comment cannot be posted."
  (review-comment--require-pr session)
  (let* ((file (review-session-file session review-pane--file-index))
         (side review-pane--side)
         (selection (review-session-pane-selection)))
    (when (plist-get selection :extra) (user-error "Put point on a source line"))
    (let ((start (plist-get selection :start)) (end (plist-get selection :end)))
      (unless (review-comment--commentable-p file (review-comment--rows file side start end))
        (user-error "Comment on a changed line or its context"))
      (list :path (plist-get file :path) :side side :line end
            :start-line (and (< start end) start)
            :text (review-comment--line-text file side end)))))

;;;; Compose

(defconst review-comment--compose-name "*review-comment*")

(defcustom review-comment-compose-height 8
  "Lines of the compose window in the `window' style."
  :type 'integer :group 'review)

(defvar-local review-comment--compose nil
  "The open compose, a plist: :session :window :position :style :finish
:allow-empty :posting.")

(defvar review-comment-compose-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'review-comment-compose-finish)
    (define-key map (kbd "C-c C-k") #'review-comment-compose-cancel)
    (define-key map (kbd "C-c C-t") #'review-comment-compose-toggle-style)
    map)
  "Keys in the review comment compose buffer.")

(define-derived-mode review-comment-compose-mode text-mode "Review-Comment"
  "Write a review comment.
\\<review-comment-compose-mode-map>\\[review-comment-compose-finish] saves, \
\\[review-comment-compose-cancel] cancels, \\[review-comment-compose-toggle-style] switches the style.")

(defun review-comment--style (name)
  "The (STYLE SHOW HIDE) entry for NAME, or the first installed one."
  (or (assq name review-comment-compose-styles) (car review-comment-compose-styles)))

(defun review-comment--show-window (buffer window _position)
  "Show BUFFER in a short window split under WINDOW, or at the frame's bottom."
  (let ((new (or (and (window-live-p window)
                      (ignore-errors
                        (split-window window (- review-comment-compose-height) 'below)))
                 (display-buffer buffer `((display-buffer-at-bottom)
                                          (window-height . ,review-comment-compose-height))))))
    (when (window-live-p new)
      (set-window-buffer new buffer)
      (select-window new))))

(defun review-comment--hide-window (buffer)
  (dolist (window (get-buffer-window-list buffer nil t))
    (ignore-errors (delete-window window))))

(defun review-comment--compose-show (buffer)
  (let ((c (buffer-local-value 'review-comment--compose buffer)))
    (funcall (nth 1 (review-comment--style (plist-get c :style)))
             buffer (plist-get c :window) (plist-get c :position))))

(defun review-comment--compose (session title window position finish &optional initial allow-empty)
  "Open the compose buffer for SESSION under TITLE and return it.
WINDOW is the pane window it belongs to and POSITION the commented
line's position there, or nil for a review summary.  FINISH is called
with the trimmed text on save; when it returns `wait' the buffer stays
open until `review-comment--compose-close'.  INITIAL is text to start
from.  An empty text cancels unless ALLOW-EMPTY."
  (when (get-buffer review-comment--compose-name)
    (user-error "Finish the open comment first (C-c C-c saves, C-c C-k cancels)"))
  (let ((buffer (get-buffer-create review-comment--compose-name)))
    (with-current-buffer buffer
      (review-comment-compose-mode)
      (when initial (insert initial))
      (setq header-line-format (concat " " title "   C-c C-c save   C-c C-k cancel")
            review-comment--compose
            (list :session session :window window :position position
                  :style (car (review-comment--style review-comment-compose-style))
                  :finish finish :allow-empty allow-empty)))
    (review-comment--compose-show buffer)
    buffer))

(defun review-comment--compose-close ()
  "Hide and kill the compose buffer, and go back to the pane it came from."
  (when-let ((buffer (get-buffer review-comment--compose-name)))
    (let* ((c (buffer-local-value 'review-comment--compose buffer))
           (window (plist-get c :window)))
      (ignore-errors (funcall (nth 2 (review-comment--style (plist-get c :style))) buffer))
      (kill-buffer buffer)
      (when (window-live-p window)
        (unless (eq (window-frame window) (selected-frame))
          (select-frame-set-input-focus (window-frame window)))
        (select-window window)))))

(defun review-comment-compose-finish ()
  "Save the comment being written."
  (interactive)
  (let ((c (or review-comment--compose (user-error "Not writing a review comment")))
        (body (string-trim (buffer-substring-no-properties (point-min) (point-max)))))
    (when (plist-get c :posting) (user-error "The review is being posted"))
    (if (and (string-empty-p body) (not (plist-get c :allow-empty)))
        (review-comment--compose-close)
      (unless (eq (funcall (plist-get c :finish) body) 'wait)
        (review-comment--compose-close)))))

(defun review-comment-compose-cancel ()
  "Drop the comment being written."
  (interactive)
  (unless review-comment--compose (user-error "Not writing a review comment"))
  (when (plist-get review-comment--compose :posting) (user-error "The review is being posted"))
  (review-comment--compose-close))

(defun review-comment-compose-toggle-style ()
  "Show the compose buffer in the next installed style, keeping its text."
  (interactive)
  (let* ((c (or review-comment--compose (user-error "Not writing a review comment")))
         (names (mapcar #'car review-comment-compose-styles))
         (current (plist-get c :style))
         (next (or (cadr (memq current names)) (car names)))
         (buffer (current-buffer)))
    (if (eq next current)
        (message "Only the %s style is installed" current)
      (ignore-errors (funcall (nth 2 (review-comment--style current)) buffer))
      (with-current-buffer buffer
        (setq review-comment--compose (plist-put c :style next)))
      (setq review-comment-compose-style next)
      (review-comment--compose-show buffer))))

;;;; Commands

(defun review-comment-dwim ()
  "Write a comment on this line or selection, or edit the draft at point."
  (interactive)
  (unless (and (derived-mode-p 'review-pane-mode) review-pane--session)
    (user-error "Not in a review pane"))
  (let* ((session review-pane--session)
         (window (selected-window))
         (existing (review-comment--draft-at session (point))))
    (if existing
        (let ((id (plist-get existing :id)))
          (review-comment--compose session (concat "Edit comment on " (review-comment--label existing))
                                   window (point)
                                   (lambda (body) (review-comment--update session id body))
                                   (plist-get existing :body)))
      (let ((target (review-comment--target session))
            (position (point)))
        ;; Leaving the selection also takes Evil out of its visual state.
        (deactivate-mark)
        (review-comment--compose session (concat "Comment on " (review-comment--label target))
                                 window position
                                 (lambda (body)
                                   (review-comment--add session (append target (list :body body)))))))))

(defun review-comment-delete ()
  "Delete the draft comment at point, after asking."
  (interactive)
  (unless (and (derived-mode-p 'review-pane-mode) review-pane--session)
    (user-error "Not in a review pane"))
  (let* ((session review-pane--session)
         (draft (or (review-comment--draft-at session (point))
                    (user-error "No draft comment here"))))
    (when (y-or-n-p (format "Delete the draft on %s? " (review-comment--label draft)))
      (review-comment--remove session (plist-get draft :id)))))

(defconst review-comment-keys
  '(("c" . review-comment-dwim) ("D" . review-comment-delete))
  "Pane keys for draft comments.")

(review-session-bind-keys review-pane-mode-map review-comment-keys)
;; `review-session-bind-keys' covers Evil's normal state; a selection is
;; in its visual state.
(with-eval-after-load 'evil
  (dolist (k review-comment-keys)
    (evil-define-key* 'visual review-pane-mode-map (kbd (car k)) (cdr k))))

;;;; Quitting with drafts

(defun review-comment--quit-query (session)
  "Ask before an interactive quit drops SESSION's drafts; nil keeps the review."
  (let ((n (length (review-session-comments session))))
    (or (zerop n)
        (when (y-or-n-p (format "%d unsent comment%s. Quit and discard %s? "
                                n (if (= n 1) "" "s") (if (= n 1) "it" "them")))
          (setf (review-session-comments session) nil)
          t))))

(defun review-comment--key (session)
  (when-let ((recipe (review-source-recipe (review-session-source session))))
    (review-source-key recipe)))

(defun review-comment--on-quit (session)
  "Close a compose left open, and keep SESSION's unsent drafts for its next start.
An interactive quit has already asked and emptied them."
  (when-let ((buffer (get-buffer review-comment--compose-name)))
    (with-current-buffer buffer
      (setq review-comment--compose (plist-put review-comment--compose :window nil)))
    (review-comment--compose-close))
  (when-let ((drafts (review-session-comments session))
             (key (review-comment--key session)))
    (puthash key (mapcar (lambda (d) (plist-put (copy-sequence d) :pending t)) drafts)
             review-comment--carried)))

(defun review-comment--on-display (session)
  "Hand SESSION the drafts its review closed with, to be placed again.
A resumed review sets its own drafts from its record right after."
  (when-let* ((key (review-comment--key session))
              (drafts (gethash key review-comment--carried)))
    (remhash key review-comment--carried)
    (unless (review-session-comments session)
      (setf (review-session-comments session) drafts)
      ;; The panes were laid out before the drafts arrived: draw the cards
      ;; and the counts now.
      (review-session--ensure-layout session)
      (review-session--notify session))))

(add-hook 'review-session-display-hook #'review-comment--on-display)

(defun review-comment--settle (session index)
  "Place the pending drafts of file INDEX of SESSION on its rows as they are now."
  (let* ((file (review-session-file session index))
         (path (plist-get file :path)))
    (when (plist-get file :rows)
      (setf (review-session-comments session)
            (mapcar (lambda (d)
                      (if (and (plist-get d :pending) (equal (plist-get d :path) path))
                          (review-comment--reanchor d file)
                        d))
                    (review-session-comments session))))))

(defun review-comment--settle-all (session callback)
  "Place every pending draft of SESSION, loading files as needed, then call CALLBACK.
A draft whose file is gone or cannot be loaded as text becomes outdated."
  (let* ((files (review-session-files session))
         (indexes (delete-dups
                   (delq nil
                         (mapcar (lambda (d)
                                   (and (plist-get d :pending)
                                        (cl-position (plist-get d :path) files
                                                     :key (lambda (f) (plist-get f :path)) :test #'equal)))
                                 (review-session-comments session)))))
         (left (length indexes))
         (done (lambda ()
                 (setf (review-session-comments session)
                       (mapcar (lambda (d)
                                 (if (plist-get d :pending)
                                     (plist-put (review-comment--without d :pending) :outdated t)
                                   d))
                               (review-session-comments session)))
                 (funcall callback))))
    (if (zerop left)
        (funcall done)
      (dolist (index indexes)
        (review-session-load session index
                             (lambda (&optional _error)
                               (review-comment--settle session index)
                               (when (zerop (cl-decf left)) (funcall done))))))))

(add-hook 'review-session-quit-query-functions #'review-comment--quit-query)
(add-hook 'review-session-quit-functions #'review-comment--on-quit)

(provide 'review-comment)
;;; review-comment.el ends here
