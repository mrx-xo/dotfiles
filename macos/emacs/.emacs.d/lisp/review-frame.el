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

(defun review-frame--yabai (&rest args)
  "Run yabai with ARGS and return its output, or signal an error."
  (with-temp-buffer
    (unless (eq 0 (apply #'call-process "yabai" nil t nil "-m" args))
      (error "Yabai: %s" (string-trim (buffer-string))))
    (buffer-string)))

(defun review-frame--move (frame display &optional attempt)
  "Move FRAME to DISPLAY once yabai has discovered its native window.
Only a unique title belonging to this Emacs process is eligible."
  (when (and (frame-live-p frame) (frame-visible-p frame))
    (condition-case err
        (let* ((displays (json-parse-string (review-frame--yabai "query" "--displays")
                                          :array-type 'list :object-type 'alist))
               (windows (json-parse-string (review-frame--yabai "query" "--windows")
                                         :array-type 'list :object-type 'alist))
               (title (frame-parameter frame 'title))
               (matches (cl-remove-if-not
                         (lambda (w) (and (eql (alist-get 'pid w) (emacs-pid))
                                          (equal (alist-get 'title w) title))) windows)))
          (cond
           ((not (cl-find display displays :key (lambda (d) (alist-get 'index d))))
            (message "Review: display %s is unavailable; leaving frame in place" display))
           ((= (length matches) 1)
            (let ((window (car matches)))
              (unless (eql (alist-get 'display window) display)
                (review-frame--yabai "window" (number-to-string (alist-get 'id window))
                                     "--display" (number-to-string display)))))
           ((< (or attempt 0) 10)
            (run-at-time 0.2 nil #'review-frame--move frame display (1+ (or attempt 0))))
           (t (message "Review: could not identify a unique window for %s" title))))
      (error (message "Review frame placement failed: %s" (error-message-string err))))))

(defun review-frame-place (frame display)
  "Schedule placement of a new graphical review FRAME on DISPLAY."
  (when (and display (eq system-type 'darwin) (display-graphic-p frame)
             (executable-find "yabai"))
    (run-at-time 0.2 nil #'review-frame--move frame display)))

(provide 'review-frame)
