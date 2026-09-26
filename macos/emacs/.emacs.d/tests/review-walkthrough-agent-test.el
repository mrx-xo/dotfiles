;;; review-walkthrough-agent-test.el --- Asking the project agent for a route -*- lexical-binding: t; -*-
(require 'ert)
(require 'review-walkthrough-agent)
(require 'review-walkthrough-test)

(ert-deftest review-walkthrough-agent-prompt-has-contract-and-diff ()
  (review-walk-test--with s
    (let ((prompt (review-walkthrough-agent--prompt s "/tmp/route.json")))
      (should (string-match-p "review-walkthrough-start-file \\\\\"/tmp/route.json\\\\\"" prompt))
      (should (string-match-p "line_start" prompt))
      (should (string-match-p "=== a.el" prompt))
      (should (string-match-p "\\+ THREE" prompt)))))

(ert-deftest review-walkthrough-agent-prompt-respects-budget ()
  (review-walk-test--with s
    (let* ((review-walkthrough-agent-diff-budget 10)
           (prompt (review-walkthrough-agent--prompt s "/tmp/route.json")))
      (should (string-match-p "hunk body omitted" prompt)))))

(ert-deftest review-walkthrough-agent-request-round-trip ()
  (review-walk-test--with s
    (review-panel-open s)
    (let (on-event sent)
      (cl-letf (((symbol-function 'mr-x/quick-ask--ensure-session) (lambda (_dir) (current-buffer)))
                ((symbol-function 'shell-maker-busy) (lambda () nil))
                ((symbol-function 'shell-maker-last-output) (lambda () "Here is my answer."))
                ((symbol-function 'agent-shell-subscribe-to)
                 (lambda (&rest args) (setq on-event (plist-get args :on-event)) 'token))
                ((symbol-function 'agent-shell-unsubscribe) #'ignore)
                ((symbol-function 'agent-shell--insert-to-shell-buffer)
                 (lambda (&rest args) (setq sent (plist-get args :text)))))
        (review-walkthrough-request)
        (should (eq (plist-get (review-session-walkthrough s) :status) 'planning))
        (should (string-match-p "review-walkthrough-start-file" sent))
        ;; The agent never called back: no route.
        (funcall on-event nil)
        (should (eq (plist-get (review-session-walkthrough s) :status) 'no-route))
        (should (equal review-walkthrough-agent--last-output "Here is my answer."))))))

(ert-deftest review-walkthrough-agent-ask-context-carries-step ()
  (review-walk-test--with s
    (review-walkthrough-start review-walk-test--steps)
    (with-current-buffer (review-session-new-buffer s)
      (let ((item (review-walkthrough-agent--ask-context)))
        (should (eq (plist-get item :type) 'walkthrough))
        (should (string-match-p "step 1: Three" (plist-get item :label)))
        (should (string-match-p "\\+ THREE" (plist-get item :content)))))))
