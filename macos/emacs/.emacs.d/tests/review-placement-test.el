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

(defmacro review-placement-test--fallback (spaces &rest body)
  "Run BODY with display 3 missing and yabai answering SPACES, a list of
JSON strings returned by successive space queries."
  (declare (indent 1))
  `(let (calls (spaces ,spaces))
     (cl-letf (((symbol-function 'frame-live-p) (lambda (_) t))
               ((symbol-function 'frame-visible-p) (lambda (_) t))
               ((symbol-function 'frame-parameter) (lambda (&rest _) "Review diff"))
               ((symbol-function 'run-at-time) #'ignore)
               ((symbol-function 'review-frame--yabai)
                (lambda (args callback)
                  (push args calls)
                  (funcall callback
                           (pcase args
                             (`("query" "--displays") "[{\"index\":1},{\"index\":2}]")
                             (`("query" "--windows")
                              (format "[{\"id\":202,\"pid\":%d,\"title\":\"Review diff\",\"display\":1}]"
                                      (emacs-pid)))
                             (`("query" "--spaces") (if (cdr spaces) (pop spaces) (car spaces)))
                             (_ ""))))))
       (let ((review-frame--space-pending nil)) ,@body)
       (nreverse calls))))

(ert-deftest review-placement-missing-monitor-goes-to-the-review-space ()
  (let ((calls (review-placement-test--fallback
                   '("[{\"index\":1,\"display\":1,\"label\":\"\"},{\"index\":4,\"display\":1,\"label\":\"review\"}]")
                 (review-frame--move 'test 3))))
    (should (member '("window" "202" "--space" "review") calls))
    (should (member '("space" "--focus" "review") calls))
    (should-not (seq-find (lambda (c) (equal (seq-take c 2) '("space" "--create"))) calls))))

(ert-deftest review-placement-creates-the-review-space-on-monitor-one ()
  (let ((calls (review-placement-test--fallback
                   '("[{\"index\":1,\"display\":1,\"label\":\"\"},{\"index\":2,\"display\":2,\"label\":\"\"}]"
                     "[{\"index\":1,\"display\":1,\"label\":\"\"},{\"index\":2,\"display\":1,\"label\":\"\"},{\"index\":3,\"display\":2,\"label\":\"\"}]")
                 (review-frame--move 'test 3))))
    (should (member '("space" "--create" "1") calls))
    ;; The new space is the last one on monitor one.
    (should (member '("space" "2" "--label" "review") calls))
    (should (member '("window" "202" "--space" "review") calls))))

(ert-deftest review-placement-creates-the-review-space-only-once ()
  ;; Both frames fall back at once: the second waits instead of creating.
  (review-placement-test--fallback '("[]")
    (setq review-frame--space-pending t)
    (review-frame--to-space '((id . 202)) "review")
    (should-not (seq-find (lambda (c) (member "--create" c)) calls))))

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
