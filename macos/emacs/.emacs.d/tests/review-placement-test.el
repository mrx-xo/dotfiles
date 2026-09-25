;;; review-placement-test.el --- Non-blocking, scoped yabai placement -*- lexical-binding: t; -*-
(require 'ert)
(require 'review-session)

(defmacro review-placement-test--with (windows &rest body)
  "Run BODY with yabai answering display 3 exists and WINDOWS (a format).
The format receives this Emacs's pid and the pid of another process."
  (declare (indent 1))
  `(let (calls)
     (cl-letf (((symbol-function 'frame-live-p) (lambda (_) t))
               ((symbol-function 'frame-visible-p) (lambda (_) t))
               ((symbol-function 'frame-parameter) (lambda (&rest _) "Review diff"))
               ((symbol-function 'run-at-time) #'ignore)
               ((symbol-function 'review-frame--yabai)
                (lambda (args callback)
                  (push args calls)
                  (funcall callback
                           (pcase args
                             (`("query" "--displays") "[{\"index\":3}]")
                             (`("query" "--windows")
                              (format ,windows (emacs-pid) (1+ (emacs-pid))))
                             (_ ""))))))
       ,@body
       calls)))

(ert-deftest review-placement-never-waits-on-yabai ()
  ;; A synchronous yabai call right after make-frame deadlocks: yabai asks
  ;; this Emacs about the new window and it cannot answer while waiting.
  (let (command)
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
              ((symbol-function 'executable-find) (lambda (&rest _) "/bin/yabai"))
              ((symbol-function 'frame-live-p) (lambda (_) t))
              ((symbol-function 'frame-visible-p) (lambda (_) t))
              ((symbol-function 'call-process)
               (lambda (program &rest _) (ert-fail (format "synchronous %s" program))))
              ((symbol-function 'make-process)
               (lambda (&rest args) (setq command (plist-get args :command)) nil)))
      (let ((system-type 'darwin))
        (review-frame-place 'test 3))
      (should (equal command '("yabai" "-m" "query" "--displays"))))))

(ert-deftest review-placement-targets-only-this-process-and-title ()
  (let ((calls (review-placement-test--with
                   "[{\"id\":101,\"pid\":%2$d,\"title\":\"Review diff\",\"display\":1},
                     {\"id\":202,\"pid\":%1$d,\"title\":\"Review diff\",\"display\":1},
                     {\"id\":303,\"pid\":%1$d,\"title\":\"Review files\",\"display\":1}]"
                 (review-frame--move 'test 3))))
    (should (equal (car calls) '("window" "202" "--display" "3")))))

(ert-deftest review-placement-matches-title-with-stuck-resize-suffix ()
  ;; macOS Emacs appends the size while a window manager resizes the frame.
  (let ((calls (review-placement-test--with
                   "[{\"id\":202,\"pid\":%1$d,\"title\":\"Review diff  —  (209 × 45)\",\"display\":1},
                     {\"id\":303,\"pid\":%1$d,\"title\":\"Review diff extra\",\"display\":1}]"
                 (review-frame--move 'test 3))))
    (should (equal (car calls) '("window" "202" "--display" "3")))))

(ert-deftest review-placement-missing-monitor-does-not-move-any-window ()
  (let ((calls (review-placement-test--with "[]" (review-frame--move 'test 2))))
    (should-not (seq-find (lambda (args) (equal (car args) "window")) calls))))

(ert-deftest review-placement-ambiguous-title-does-not-move-any-window ()
  (let ((calls (review-placement-test--with
                   "[{\"id\":1,\"pid\":%1$d,\"title\":\"Review diff\"},{\"id\":2,\"pid\":%1$d,\"title\":\"Review diff\"}]"
                 (review-frame--move 'test 3 20))))
    (should-not (seq-find (lambda (args) (equal (car args) "window")) calls))))

(ert-deftest review-placement-strip-floats-its-tiled-window-then-resizes ()
  ;; A tiling space would stretch the strip's frame back to full width.
  (dolist (case '((t :false t) (t t nil) (nil t t) (nil :false nil)))
    (pcase-let ((`(,floating ,now ,toggles) case))
      (let (calls resized)
        (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                  ((symbol-function 'frame-visible-p) (lambda (_) t))
                  ((symbol-function 'executable-find) (lambda (&rest _) "/bin/yabai"))
                  ((symbol-function 'frame-parameter) (lambda (&rest _) "Review files"))
                  ((symbol-function 'review-frame--yabai)
                   (lambda (args callback)
                     (push args calls)
                     (funcall callback
                              (if (equal args '("query" "--windows"))
                                  (format "[{\"id\":7,\"pid\":%d,\"title\":\"Review files\",\"is-floating\":%s}]"
                                          (emacs-pid) (if (eq now t) "true" "false"))
                                "")))))
          (let ((system-type 'darwin))
            (review-frame-set-floating 'test floating (lambda () (setq resized t))))
          (should resized)
          (should (eq toggles (and (member '("window" "7" "--toggle" "float") calls) t))))))))

(provide 'review-placement-test)
