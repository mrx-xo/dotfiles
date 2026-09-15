;;; strudel-control-test.el --- Native Strudel checks -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'strudel-control nil t)

(ert-deftest strudel-empty-patch-response-means-bridge-is-ready ()
  ;; Bun serves the empty startup patch as 204, not 200.
  (cl-letf (((symbol-function 'url-retrieve-synchronously)
             (lambda (&rest _)
               (let ((buffer (generate-new-buffer " *strudel-http-test*")))
                 (with-current-buffer buffer
                   (setq-local url-http-response-status 204))
                 buffer))))
    (should (mr-x/strudel--bridge-up-p))))

(ert-deftest strudel-startup-waits-for-http-before-opening-webkit ()
  (let ((mr-x/strudel--generation 5)
        (mr-x/strudel--deadline (time-add (current-time) 60))
        (mr-x/strudel--timer nil)
        (opened nil))
    (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
              ((symbol-function 'mr-x/strudel--bridge-up-p) (lambda () nil))
              ((symbol-function 'mr-x/strudel--widget-live-p) (lambda () nil))
              ((symbol-function 'xwidget-webkit-browse-url)
               (lambda (&rest _) (setq opened t)))
              ((symbol-function 'xwidget-webkit-current-session) (lambda () nil))
              ((symbol-function 'xwidget-webkit-execute-script) #'ignore))
      (unwind-protect
          (progn (mr-x/strudel--poll 5)
                 (should-not opened)
                 (should (timerp mr-x/strudel--timer)))
        (when (timerp mr-x/strudel--timer) (cancel-timer mr-x/strudel--timer))))))

(ert-deftest strudel-update-sends-unsaved-full-buffer-without-saving ()
  ;; Losing widening or reading the file instead breaks live editing.
  (with-temp-buffer
    (insert "note(\"c3\")\n.s(\"sine\")")
    (set-buffer-modified-p t)
    (narrow-to-region 1 5)
    (let ((mr-x/strudel--ready t) sent)
      (cl-letf (((symbol-function 'mr-x/strudel--post)
                 (lambda (path body) (setq sent (list path body)))))
        (mr-x/strudel-update)
        (should (equal sent '("/eval" "note(\"c3\")\n.s(\"sine\")")))
        (should (buffer-modified-p))
        (should (buffer-narrowed-p))))))

(ert-deftest strudel-update-requires-started-session ()
  (let ((mr-x/strudel--ready nil))
    (should-error (mr-x/strudel-update) :type 'user-error)))

(ert-deftest strudel-stop-cancels-pending-start ()
  ;; A stopped startup must not begin playing when WebKit finishes loading.
  (let ((mr-x/strudel--ready nil)
        (mr-x/strudel--pending "note(\"c3\")")
        (mr-x/strudel--timer (run-at-time 100 nil #'ignore)))
    (unwind-protect
        (progn
          (mr-x/strudel-stop)
          (should-not mr-x/strudel--pending)
          (should-not mr-x/strudel--timer))
      (when (timerp mr-x/strudel--timer)
        (cancel-timer mr-x/strudel--timer)))))
