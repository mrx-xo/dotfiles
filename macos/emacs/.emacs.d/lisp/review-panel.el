;;; review-panel.el --- The files panel beside a review session -*- lexical-binding: t; -*-
;;; Commentary:
;; One buffer, three shapes: expanded (files with their hunks, the default),
;; folded per file, and a 44 px strip.  It re-renders from the session on
;; `review-session-update-hook' and never holds state the session has.
;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'review-session)

(defconst review-panel-viewed-label "done" "Label for a viewed file.")
(defconst review-panel-current-label "current" "Label for the current file.")
(defconst review-panel-pending-label "pending" "Label for a pending file.")
(defcustom review-panel-width 42 "Columns for the expanded panel." :type 'integer :group 'review)
(defcustom review-panel-strip-width 7 "Columns for the collapsed strip." :type 'integer :group 'review)
(defcustom review-panel-pop-out t
  "Open new reviews' file panels in their own graphical frames.
When nil, attach the panel to the compare frame's left side.
Independent of `review-session-pop-out'; terminals always use a side window."
  :type 'boolean :group 'review)

(defface review-panel-current '((t :inherit highlight :extend t)) "Current file row.")
(defface review-panel-viewed '((t :inherit shadow)) "Viewed file row.")
(defface review-panel-kind-add '((t :foreground "#b8bb26" :weight bold)) "A")
(defface review-panel-kind-mod '((t :foreground "#fabd2f" :weight bold)) "M")
(defface review-panel-kind-del '((t :foreground "#fb4934" :weight bold)) "D")
(defface review-panel-dir '((t :foreground "#504945")) "Directory part of a path.")
(defface review-panel-bar '((t :foreground "#fabd2f")) "Progress bar fill.")

(defvar-local review-panel--session nil)
(defvar-local review-panel--folded nil "File indices whose hunks are hidden.")
(defvar-local review-panel--collapsed nil "Non-nil when shown as the strip.")
(defvar-local review-panel--render-width nil "Width used by the last render.")
(defvar review-panel--refreshing nil)

(defun review-panel--kind (file)
  (pcase (plist-get file :kind)
    ('added (propertize "A" 'face 'review-panel-kind-add))
    ('deleted (propertize "D" 'face 'review-panel-kind-del))
    (_ (propertize "M" 'face 'review-panel-kind-mod))))

(defun review-panel--counts (file)
  "Return \"+n -m\" for FILE from its rows, or \"\" before it is loaded."
  (if-let ((rows (plist-get file :rows)))
      (let ((add (cl-count-if (lambda (r) (memq (plist-get r :kind) '(add both))) rows))
            (del (cl-count-if (lambda (r) (memq (plist-get r :kind) '(del both))) rows)))
        (concat (if (> add 0) (propertize (format "+%d" add) 'face 'review-panel-kind-add) "")
                (if (and (> add 0) (> del 0)) " " "")
                (if (> del 0) (propertize (format "-%d" del) 'face 'review-panel-kind-del) "")))
    ""))

(defun review-panel--fit (left right width)
  "Return LEFT padded so RIGHT ends at WIDTH, truncating LEFT if needed."
  (let* ((right (truncate-string-to-width right (max 0 (- width 2))))
         (room (max 0 (- width (string-width right) 1)))
         (left (truncate-string-to-width left room nil nil "\u2026")))
    (concat left (make-string (max 1 (- width (string-width left) (string-width right))) ?\s) right)))

(defun review-panel--bar (viewed total width)
  (let ((fill (if (zerop total) 0 (round (* width (/ (float viewed) total))))))
    (concat (propertize (make-string fill ?\u2501) 'face 'review-panel-bar)
            (propertize (make-string (- width fill) ?\u2501) 'face 'shadow))))

(defun review-panel-render (session folded collapsed &optional width)
  "Render SESSION as panel text.  FOLDED hides hunks per file; COLLAPSED is the strip."
  (let* ((source (review-session-source session))
         (files (review-session-files session))
         (current (review-session-current session))
         (viewed (review-session-viewed session))
         (progress (review-session-progress session))
         (width (or width (if collapsed review-panel-strip-width review-panel-width)))
         (lines nil))
    (cl-flet ((row (text &rest props) (push (apply #'propertize text props) lines)))
      (if collapsed
          (progn
            (row (truncate-string-to-width
                  (let ((label (review-source-range-label source)))
                    (if (string-match "#[0-9]+" label) (match-string 0 label)
                      (review-source-name source))) width) 'review-header t)
            (row (format " %d" (car progress)) 'review-header t)
            (row "  of" 'review-header t)
            (row (format " %d" (cdr progress)) 'review-header t)
            (row "")
            (dotimes (i (length files))
              (row (format "%s" (cond ((= i current) review-panel-current-label)
                                        ((memq i viewed) review-panel-viewed-label)
                                        (t review-panel-pending-label)))
                   'review-file i
                   'face (cond ((= i current) 'review-panel-current) ((memq i viewed) 'review-panel-viewed)))))
        (row (review-source-title source) 'review-header t 'face 'bold)
        (row (propertize (review-source-range-label source) 'face 'shadow) 'review-header t)
        (row "")
        (row (review-panel--fit (format "%d of %d viewed" (car progress) (cdr progress))
                                (let ((cur (aref files current)))
                                  (if (plist-get cur :hunks)
                                      (format "hunk %d/%d" (1+ (review-session-hunk session)) (length (plist-get cur :hunks)))
                                    ""))
                                width)
             'review-header t)
        (row (review-panel--bar (car progress) (cdr progress) width) 'review-header t)
        (row "")
        (dotimes (i (length files))
          (let* ((file (aref files i))
                 (path (plist-get file :path))
                 (dir (file-name-directory path)) (base (file-name-nondirectory path))
                 (glyph (cond ((= i current) review-panel-current-label)
                              ((memq i viewed) review-panel-viewed-label)
                              (t review-panel-pending-label)))
                 (hunks (plist-get file :hunks))
                 (left (concat (format "%s %s " glyph (review-panel--kind file))
                               (if dir (propertize dir 'face 'review-panel-dir) "") base))
                 (right (cond ((plist-get file :error) "failed")
                              ((plist-get file :binary) "no text")
                              ((not (plist-get file :loaded)) "loading")
                              ((and (memq i folded) hunks) (format "%d hunk%s  %s" (length hunks) (if (= 1 (length hunks)) "" "s") (review-panel--counts file)))
                              (t (review-panel--counts file))))
                 (text (review-panel--fit left right width)))
            (row (if (= i current) (concat (propertize text 'face 'review-panel-current)) (if (memq i viewed) (propertize text 'face 'review-panel-viewed) text))
                 'review-file i)
            (unless (memq i folded)
              (let ((h 0))
                (dolist (hunk hunks)
                  (let* ((is-cur (and (= i current) (= h (review-session-hunk session))))
                         (g (cond (is-cur review-panel-current-label)
                                  ((and (= i current) (< h (review-session-hunk session))) review-panel-viewed-label)
                                  ((memq i viewed) review-panel-viewed-label)
                                  (t review-panel-pending-label)))
                         (range (format "@@ -%d,%d +%d,%d @@" (plist-get hunk :old-start) (plist-get hunk :old-count)
                                        (plist-get hunk :new-start) (plist-get hunk :new-count)))
                         (label (plist-get hunk :label)))
                    (row (review-panel--fit (format "  %s %s  %s" g (propertize range 'face 'shadow) label) "" width)
                         'review-file i 'review-hunk h
                         'face (cond (is-cur 'review-panel-current) ((memq i viewed) 'review-panel-viewed))))
                  (cl-incf h)))))))
      (mapconcat #'identity (nreverse lines) "\n"))))

;;;; Buffer

(defvar review-panel-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "TAB") #'review-panel-fold)
    (define-key m (kbd "<tab>") #'review-panel-fold)
    (define-key m (kbd "RET") #'review-panel-visit)
    (define-key m (kbd "C-j") #'review-session-next-file)
    (define-key m (kbd "C-k") #'review-session-prev-file)
    (define-key m (kbd "M-j") #'review-session-next-hunk)
    (define-key m (kbd "M-k") #'review-session-prev-hunk)
    (define-key m (kbd "v") #'review-session-toggle-viewed)
    (define-key m (kbd "u") #'syzygy-park)
    (define-key m (kbd "q") #'review-session-quit)
    m))

(define-derived-mode review-panel-mode special-mode "ReviewFiles"
  "Files panel of a review session."
  (setq truncate-lines t cursor-type nil)
  (setq-local popper-popup-status 'raised))

(with-eval-after-load 'evil
  (evil-define-key 'normal review-panel-mode-map
    (kbd "TAB") #'review-panel-fold (kbd "<tab>") #'review-panel-fold
    (kbd "RET") #'review-panel-visit
    (kbd "C-j") #'review-session-next-file (kbd "C-k") #'review-session-prev-file
    (kbd "M-j") #'review-session-next-hunk (kbd "M-k") #'review-session-prev-hunk
    (kbd "v") #'review-session-toggle-viewed (kbd "q") #'review-session-quit
    (kbd "u") #'syzygy-park))

(defun review-panel--refresh (&optional session)
  "Re-render SESSION's panel, preserving its selected file or hunk."
  (let ((s (or session review-session--current))
        (review-panel--refreshing t))
    (when (and s (buffer-live-p (review-session-panel s)))
      (review-panel--display s)
      (with-current-buffer (review-session-panel s)
        (let ((inhibit-read-only t)
              (file (get-text-property (point) 'review-file))
              (hunk (get-text-property (point) 'review-hunk)))
          (erase-buffer)
          (setq review-panel--render-width
                (if-let ((window (get-buffer-window (current-buffer) t)))
                    (window-body-width window)
                  review-panel-width))
          (insert (review-panel-render s review-panel--folded review-panel--collapsed
                                       review-panel--render-width))
          (goto-char (point-min))
          (when file
            (let ((pos (text-property-any (point-min) (point-max) 'review-file file)))
              (when pos
                (goto-char pos)
                (when (and hunk (not review-panel--collapsed)
                           (not (memq file review-panel--folded)))
                  (while (and (< (point) (point-max))
                              (eq (get-text-property (point) 'review-file) file)
                              (not (eq (get-text-property (point) 'review-hunk) hunk)))
                    (forward-line)))))))))))

(defun review-panel--resized (frame)
  "Reflow the panel when its window in FRAME changes width."
  (when-let* ((s review-session--current)
              (buffer (review-session-panel s))
              (_ (buffer-live-p buffer))
              (window (get-buffer-window buffer frame)))
    (unless (or review-panel--refreshing
                (equal (window-body-width window)
                       (buffer-local-value 'review-panel--render-width buffer)))
      (review-panel--refresh s))))

(add-hook 'window-size-change-functions #'review-panel--resized)

(defun review-panel--on-update (session)
  (if session (review-panel--refresh session)))

(defun review-panel--display (session)
  "Display SESSION's panel in its own frame or beside the compare panes."
  (when (and (frame-live-p (review-session-frame session))
             (buffer-live-p (review-session-panel session)))
    (with-selected-frame (or (review-session-panel-frame session)
                             (review-session-frame session))
      (let* ((buffer (review-session-panel session))
             (width (with-current-buffer buffer
                      (if review-panel--collapsed review-panel-strip-width
                        (if (review-session-panel-frame session) review-panel-width
                          (min review-panel-width
                               (max 12 (/ (frame-width) 3))))))))
        (if (review-session-panel-frame session)
            (let ((window (or (get-buffer-window buffer (selected-frame))
                              (frame-selected-window))))
              ;; A fresh frame can inherit *scratch*'s popup window.  This
              ;; frame belongs to the panel: give it one ordinary window.
              (select-window window)
              (set-window-dedicated-p window nil)
              (dolist (parameter '(window-side window-slot no-other-window
                                   no-delete-other-windows quit-restore))
                (set-window-parameter window parameter nil))
              (let ((ignore-window-parameters t)) (delete-other-windows window))
              (set-window-buffer window buffer))
          (let ((window (display-buffer-in-side-window
                         buffer `((side . left) (slot . 0) (window-width . ,width)))))
            (when (/= width (window-total-width window))
              (window-resize window (- width (window-total-width window)) t t))))))))

(defun review-panel--make-frame ()
  "Create a frame for review files without taking input focus."
  (save-selected-window
    (make-frame `((name . "Review files") (title . "Review files")
                  (width . ,review-panel-width)
                  (height . 45) (min-width . ,review-panel-strip-width)
                  (no-focus-on-map . t)))))

(defun review-panel--preload (session index)
  "Fill SESSION's hunk map incrementally, starting at INDEX."
  (when (and (eq session review-session--current)
             (buffer-live-p (review-session-panel session))
             (< index (length (review-session-files session))))
    (let ((next (lambda (&optional _error)
                  (review-panel--refresh session)
                  (run-at-time 0 nil #'review-panel--preload session (1+ index)))))
      (condition-case err
          (review-session-load session index next)
        (error
         (let ((file (review-session-file session index)))
           (aset (review-session-files session) index
                 (plist-put file :error (error-message-string err))))
         (funcall next))))))

(defun review-panel-open (session)
  "Create SESSION's files panel and begin loading its hunk map."
  (let ((buffer (generate-new-buffer
                 (format "*review files: %s*"
                         (review-source-range-label (review-session-source session))))))
    (with-current-buffer buffer
      (review-panel-mode)
      (setq review-panel--session session
            default-directory (review-session-directory session)))
    (setf (review-session-panel session) buffer)
    (add-hook 'review-session-update-hook #'review-panel--on-update)
    (add-hook 'review-session-display-hook #'review-panel--display)
    (condition-case err
        (progn
          (when (and review-panel-pop-out
                     (display-graphic-p (review-session-frame session)))
            (setf (review-session-panel-frame session) (review-panel--make-frame))
            (review-frame-place (review-session-panel-frame session) review-panel-display))
          (review-panel--refresh session))
      (error (review-session-quit) (signal (car err) (cdr err))))
    (run-at-time 0 nil #'review-panel--preload session 0)
    buffer))

(defun review-panel-fold ()
  "Toggle the hunks of the file at point; on the header, toggle the strip."
  (interactive)
  (let ((i (get-text-property (point) 'review-file)))
    (cond
     ((get-text-property (point) 'review-header)
      (setq review-panel--collapsed (not review-panel--collapsed)))
     (i (setq review-panel--folded (if (memq i review-panel--folded)
                                       (delq i review-panel--folded)
                                     (cons i review-panel--folded))))
     (t (user-error "Put point on a file or the header")))
    (review-panel--refresh review-panel--session)))

(defun review-panel-visit ()
  "Show the file and hunk at point after its text has loaded."
  (interactive)
  (let ((i (get-text-property (point) 'review-file))
        (h (get-text-property (point) 'review-hunk)))
    (unless i (user-error "Put point on a file"))
    (review-session-show i h)))

(provide 'review-panel)
;;; review-panel.el ends here
