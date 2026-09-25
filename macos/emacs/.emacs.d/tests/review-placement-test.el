;;; review-placement-test.el --- Scoped yabai placement -*- lexical-binding: t; -*-
(require 'ert)
(require 'review-session)

(ert-deftest review-placement-targets-only-this-process-and-title ()
  (let (calls)
    (cl-letf (((symbol-function 'frame-live-p) (lambda (_) t))
              ((symbol-function 'frame-visible-p) (lambda (_) t))
              ((symbol-function 'frame-parameter) (lambda (&rest _) "Review diff"))
              ((symbol-function 'review-frame--yabai)
               (lambda (&rest args)
                 (push args calls)
                 (pcase args
                   (`("query" "--displays") "[{\"index\":3}]")
                   (`("query" "--windows")
                    (format "[{\"id\":101,\"pid\":%d,\"title\":\"Review diff\",\"display\":1},{\"id\":202,\"pid\":%d,\"title\":\"Review diff\",\"display\":1}]"
                            (1+ (emacs-pid)) (emacs-pid)))
                   (_ "")))))
      (review-frame--move 'test 3)
      (should (equal (car calls) '("window" "202" "--display" "3"))))))

(ert-deftest review-placement-missing-monitor-does-not-move-any-window ()
  (let (calls)
    (cl-letf (((symbol-function 'frame-live-p) (lambda (_) t))
              ((symbol-function 'frame-visible-p) (lambda (_) t))
              ((symbol-function 'frame-parameter) (lambda (&rest _) "Review diff"))
              ((symbol-function 'review-frame--yabai)
               (lambda (&rest args) (push args calls) "[]")))
      (review-frame--move 'test 3)
      (should-not (seq-find (lambda (args) (equal (car args) "window")) calls)))))

(ert-deftest review-placement-ambiguous-title-does-not-move-any-window ()
  (let (calls)
    (cl-letf (((symbol-function 'frame-live-p) (lambda (_) t))
              ((symbol-function 'frame-visible-p) (lambda (_) t))
              ((symbol-function 'frame-parameter) (lambda (&rest _) "Review diff"))
              ((symbol-function 'review-frame--yabai)
               (lambda (&rest args)
                 (push args calls)
                 (if (equal args '("query" "--displays")) "[{\"index\":3}]"
                   (format "[{\"pid\":%d,\"title\":\"Review diff\"},{\"pid\":%d,\"title\":\"Review diff\"}]"
                           (emacs-pid) (emacs-pid))))))
      (review-frame--move 'test 3 10)
      (should-not (seq-find (lambda (args) (equal (car args) "window")) calls)))))

(provide 'review-placement-test)
