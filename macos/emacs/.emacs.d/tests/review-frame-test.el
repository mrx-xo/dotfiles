;;; review-frame-test.el --- Graphical review placement tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'review-panel)
(require 'review-session-test)

(defmacro review-frame-test--with (&rest body)
  "Run BODY on disposable, invisible frames, preserving the user's session."
  (declare (indent 0))
  `(progn
     (unless (equal (bound-and-true-p server-name) "sandbox")
       (error "Graphical review tests must run in the sandbox daemon"))
     (skip-unless (display-graphic-p))
     (let ((review-session--current nil)
           (review-session-display nil)
           (review-panel-display nil)
           (review-session-update-hook nil)
           (review-session-display-hook nil)
           (make-frame-function (symbol-function 'make-frame))
           frames)
       (cl-letf (((symbol-function 'make-frame)
                  (lambda (&optional parameters)
                    (let ((frame (funcall make-frame-function
                                          (append '((visibility . nil)
                                                    (no-focus-on-map . t))
                                                  parameters))))
                      (push frame frames)
                      frame)))
                 ((symbol-function 'select-frame-set-input-focus) #'ignore))
         (unwind-protect
             (with-selected-frame (make-frame '((width . 160) (height . 45)))
               ,@body)
           (review-session-quit)
           (dolist (frame frames)
             (when (frame-live-p frame) (delete-frame frame))))))))

(ert-deftest review-frame-placement-combinations-preserve-origin-and-clean-up ()
  (review-frame-test--with
    (dolist (placement '((nil nil) (nil t) (t nil) (t t)))
      (let* ((review-session-pop-out (car placement))
             (review-panel-pop-out (cadr placement))
             (origin (selected-frame))
             (before (current-window-configuration))
             (session (review-session-start
                       (review-session-test--source review-session-test--spec)))
             (compare (review-session-frame session)))
        (review-panel-open session)
        (let* ((panel (review-session-panel session))
               (panel-frame (review-session-panel-frame session))
               (panel-window (get-buffer-window panel t)))
          (should (eq (not (eq origin compare)) review-session-pop-out))
          (should (eq (not (null panel-frame)) review-panel-pop-out))
          (should (eq (window-frame panel-window) (or panel-frame compare)))
          (when review-panel-pop-out (should-not (eq panel-frame compare)))
          (when review-session-pop-out
            (should (compare-window-configurations before (current-window-configuration))))
          (with-selected-window panel-window (review-session-next-file))
          (should (= (review-session-current session) 1))
          (should (eq (window-frame (review-session-new-window session)) compare))
          (should (eq panel-window (get-buffer-window panel t)))
          (review-session-quit)
          (should (frame-live-p origin))
          (when review-session-pop-out (should-not (frame-live-p compare)))
          (when panel-frame (should-not (frame-live-p panel-frame)))
          (should-not (buffer-live-p panel))
          (should-not (buffer-live-p (review-session-new-buffer session)))
          (should (compare-window-configurations before (current-window-configuration))))))))

(ert-deftest review-frame-manual-close-cleans-up-session ()
  (review-frame-test--with
    (let* ((review-session-pop-out t)
           (review-panel-pop-out t)
           (session (review-session-start
                     (review-session-test--source review-session-test--spec))))
      (review-panel-open session)
      (let ((panel-frame (review-session-panel-frame session)))
        (delete-frame (review-session-frame session))
        (should-not review-session--current)
        (should-not (frame-live-p panel-frame))
        (should-not (buffer-live-p (review-session-new-buffer session)))))))

(ert-deftest review-frame-closed-panel-cleans-up-session ()
  (review-frame-test--with
    (let* ((review-session-pop-out t)
           (review-panel-pop-out t)
           (session (review-session-start
                     (review-session-test--source review-session-test--spec))))
      (review-panel-open session)
      (let ((panel-frame (review-session-panel-frame session))
            (compare-frame (review-session-frame session)))
        (delete-frame panel-frame)
        (should-not review-session--current)
        (should-not (frame-live-p compare-frame))
        (should-not (buffer-live-p (review-session-panel session)))))))

(ert-deftest review-frame-panel-reclaims-popup-and-fills-resized-window ()
  (review-frame-test--with
    (let* ((review-session-pop-out t) (review-panel-pop-out t)
           (s (review-session-start (review-session-test--source review-session-test--spec))))
      (review-panel-open s)
      (let ((frame (review-session-panel-frame s))
            (buffer (review-session-panel s)))
        (with-selected-frame frame
          (set-window-buffer (selected-window) (get-buffer-create " *review layout test*"))
          (display-buffer-in-side-window buffer '((side . bottom) (window-height . 8)))
          (review-panel--refresh s)
          (should (= (length (window-list frame 'nomini)) 1))
          (should-not (window-parameter (get-buffer-window buffer frame) 'window-side))
          (should (eq (buffer-local-value 'popper-popup-status buffer) 'raised))
          (set-frame-width frame 100)
          (review-panel--resized frame)
          (let ((width (window-body-width (get-buffer-window buffer frame))))
            (should (> width 42))
            (with-current-buffer buffer
              (should (= review-panel--render-width width))
              ;; Right-hand text is aligned to the window's own right edge.
              (goto-char (point-min))
              (should (text-property-search-forward
                       'display nil (lambda (_ v) (eq (car-safe (plist-get (cdr-safe v) :align-to)) '-))))
              (should (<= (car (window-text-pixel-size (get-buffer-window buffer frame)))
                          (window-body-width (get-buffer-window buffer frame) t))))))))))

(ert-deftest review-frame-navigation-from-files-frame-scrolls-panes-to-hunk ()
  (review-frame-test--with
    (let* ((review-session-pop-out t) (review-panel-pop-out t)
           (old (mapconcat (lambda (i) (format "line %d" i)) (number-sequence 1 80) "\n"))
           (new (replace-regexp-in-string "^line 60$" "line sixty" old))
           (s (review-session-start (review-session-test--source
                                     `(("a.txt" modified "a\n" "b\n")
                                       ("long.txt" modified ,old ,new))))))
      (review-panel-open s)
      ;; C-j from the files frame: the panes live in another frame.
      (with-selected-window (get-buffer-window (review-session-panel s) t)
        (review-session-next-file))
      (dolist (w (list (review-session-old-window s) (review-session-new-window s)))
        (with-current-buffer (window-buffer w)
          (should (= (line-number-at-pos (window-start w)) 57))
          (should (= (line-number-at-pos (window-point w)) 60)))))))

(provide 'review-frame-test)
