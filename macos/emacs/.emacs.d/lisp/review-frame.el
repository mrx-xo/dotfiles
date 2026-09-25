;;; review-frame.el --- Place review frames with yabai -*- lexical-binding: t; -*-
(require 'cl-lib)
(require 'json)
(require 'subr-x)

(defcustom review-session-display 3
  "Yabai display index for a new compare frame, or nil to leave it in place."
  :type '(choice (const :tag "Do not move" nil) (integer :tag "Display index"))
  :group 'review)
(defcustom review-panel-display 2
  "Yabai display index for a new files frame, or nil to leave it in place."
  :type '(choice (const :tag "Do not move" nil) (integer :tag "Display index"))
  :group 'review)

(defun review-frame-graphic-p ()
  "Whether new review frames can be graphical.
A daemon started without frames, as `rv' does, still reaches the macOS
display even though its only frame is a terminal one."
  (or (display-graphic-p) (and (daemonp) (featurep 'ns))))

(defun review-frame-parameters (parameters)
  "Return frame PARAMETERS that make a graphical frame from any frame."
  (if (display-graphic-p) parameters (cons '(window-system . ns) parameters)))

(defun review-frame--yabai (args callback)
  "Run yabai with ARGS, then call CALLBACK with its output.
Never wait on yabai synchronously: after a frame is created, yabai asks
this Emacs about the new window through accessibility, which Emacs
cannot answer while blocked, and both stall until macOS times out."
  (let ((buffer (generate-new-buffer " *review-yabai*")))
    (make-process
     :name "review-yabai" :buffer buffer :noquery t :connection-type 'pipe
     :command (cl-list* "yabai" "-m" args)
     :sentinel
     (lambda (process _event)
       (unless (process-live-p process)
         (unwind-protect
             (condition-case err
                 (let ((output (with-current-buffer buffer (buffer-string))))
                   (unless (eq 0 (process-exit-status process))
                     (error "Yabai: %s" (string-trim output)))
                   (funcall callback output))
               (error (message "Review frame placement failed: %s"
                               (error-message-string err))))
           (kill-buffer buffer)))))))

(defun review-frame--json (output)
  (json-parse-string output :array-type 'list :object-type 'alist))

(defun review-frame--title-p (title window-title)
  "Whether yabai's WINDOW-TITLE belongs to a frame titled TITLE.
Emacs on macOS appends \"  —  (COLS × ROWS)\" while a window manager
resizes a frame, and the suffix can stay."
  (and (stringp window-title)
       (string-match-p (concat "\\`" (regexp-quote title) "\\(?:  —  (.*)\\)?\\'")
                       window-title)))

(defun review-frame--move (frame display &optional attempt)
  "Move FRAME to DISPLAY once yabai has discovered its native window.
Only a unique title belonging to this Emacs process is eligible."
  (when (and (frame-live-p frame) (frame-visible-p frame))
    (review-frame--yabai
     '("query" "--displays")
     (lambda (output)
       (if (not (cl-find display (review-frame--json output)
                         :key (lambda (d) (alist-get 'index d))))
           (message "Review: display %s is unavailable; leaving frame in place" display)
         (review-frame--yabai
          '("query" "--windows")
          (lambda (output)
            (let* ((title (frame-parameter frame 'title))
                   (matches (cl-remove-if-not
                             (lambda (w) (and (eql (alist-get 'pid w) (emacs-pid))
                                              (review-frame--title-p title (alist-get 'title w))))
                             (review-frame--json output))))
              (cond
               ((= (length matches) 1)
                (let ((window (car matches)))
                  (unless (eql (alist-get 'display window) display)
                    (review-frame--yabai
                     (list "window" (number-to-string (alist-get 'id window))
                           "--display" (number-to-string display))
                     #'ignore))))
               ;; Yabai reports a blank title until it finishes adopting it.
               ((< (or attempt 0) 20)
                (run-at-time 0.25 nil #'review-frame--move frame display (1+ (or attempt 0))))
               (t (message "Review: could not identify a unique window for %s" title)))))))))))

(defun review-frame-set-floating (frame floating then)
  "Make FRAME's yabai window FLOATING or tiled, then call THEN.
A tiling space stretches a managed window to fill it, so a frame that
wants its own size must float first.  Without yabai, just call THEN."
  (if (not (and (eq system-type 'darwin) (display-graphic-p frame)
                (frame-visible-p frame) (executable-find "yabai")))
      (funcall then)
    (review-frame--yabai
     '("query" "--windows")
     (lambda (output)
       (let* ((title (frame-parameter frame 'title))
              (matches (cl-remove-if-not
                        (lambda (w) (and (eql (alist-get 'pid w) (emacs-pid))
                                         (review-frame--title-p title (alist-get 'title w))))
                        (review-frame--json output)))
              (window (and (= 1 (length matches)) (car matches))))
         (if (and window (not (eq (eq (alist-get 'is-floating window) t) (and floating t))))
             (review-frame--yabai
              (list "window" (number-to-string (alist-get 'id window)) "--toggle" "float")
              (lambda (_) (funcall then)))
           (funcall then)))))))

(defun review-frame-place (frame display)
  "Move a new graphical review FRAME onto yabai DISPLAY, without blocking."
  (when (and display (eq system-type 'darwin) (display-graphic-p frame)
             (executable-find "yabai"))
    (review-frame--move frame display)))

(provide 'review-frame)
