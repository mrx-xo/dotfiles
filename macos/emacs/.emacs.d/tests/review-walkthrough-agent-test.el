;;; review-walkthrough-agent-test.el --- Asking the project agent for a route -*- lexical-binding: t; -*-
(require 'ert)
(require 'review-walkthrough-agent)
(require 'review-walkthrough-test)

(ert-deftest review-walkthrough-agent-prompt-has-contract-and-diff ()
  (review-walk-test--with s
    (let ((prompt (review-walkthrough-agent--prompt s)))
      (should (string-match-p "```json" prompt))
      (should (string-match-p "line_start" prompt))
      (should (string-match-p "=== a.el" prompt))
      (should (string-match-p "\\+ THREE" prompt))
      (should-not (string-match-p "emacsclient" prompt)))))

(ert-deftest review-walkthrough-agent-prompt-respects-budget ()
  (review-walk-test--with s
    (let* ((review-walkthrough-agent-diff-budget 10)
           (prompt (review-walkthrough-agent--prompt s)))
      (should (string-match-p "hunk body omitted" prompt)))))

(ert-deftest review-walkthrough-agent-route-json-picks-last-block ()
  (should (equal (string-trim
                  (review-walkthrough-agent--route-json
                   (concat "some prose\n```json\n{\"a\": 1}\n```\n"
                           "more prose\n```json\n{\"steps\": []}\n```\ntrailing")))
                 "{\"steps\": []}"))
  (should-not (review-walkthrough-agent--route-json "no fence here")))

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
        (should (string-match-p "```json" sent))
        ;; The agent's reply carries no route: no route.
        (funcall on-event nil)
        (should (eq (plist-get (review-session-walkthrough s) :status) 'no-route))
        (should (equal review-walkthrough-agent--last-output "Here is my answer."))))))

(ert-deftest review-walkthrough-agent-request-applies-reply-route ()
  (review-walk-test--with s
    (review-panel-open s)
    (let (on-event
          (reply (concat "Sure thing, here is the route.\n\n```json\n"
                         "{\"steps\": [{\"path\": \"a.el\", \"line_start\": 3, \"line_end\": 3, \"title\": \"Three\"}]}"
                         "\n```\n")))
      (cl-letf (((symbol-function 'mr-x/quick-ask--ensure-session) (lambda (_dir) (current-buffer)))
                ((symbol-function 'shell-maker-busy) (lambda () nil))
                ((symbol-function 'shell-maker-last-output) (lambda () reply))
                ((symbol-function 'agent-shell-subscribe-to)
                 (lambda (&rest args) (setq on-event (plist-get args :on-event)) 'token))
                ((symbol-function 'agent-shell-unsubscribe) #'ignore)
                ((symbol-function 'agent-shell--insert-to-shell-buffer) #'ignore))
        (review-walkthrough-request)
        (funcall on-event nil)
        (should (= (length (plist-get (review-session-walkthrough s) :steps)) 1))
        (should (= (plist-get (review-session-walkthrough s) :index) 0))))))

(ert-deftest review-walkthrough-agent-request-asks-once-to-correct ()
  (review-walk-test--with s
    (review-panel-open s)
    (let (on-event sent-texts
          (bad-reply (concat "```json\n{\"steps\": [{\"path\": \"a.el\", \"line_start\": 7, "
                             "\"line_end\": 7, \"title\": \"Unchanged\"}]}\n```\n")))
      (cl-letf (((symbol-function 'mr-x/quick-ask--ensure-session) (lambda (_dir) (current-buffer)))
                ((symbol-function 'shell-maker-busy) (lambda () nil))
                ((symbol-function 'shell-maker-last-output) (lambda () bad-reply))
                ((symbol-function 'agent-shell-subscribe-to)
                 (lambda (&rest args) (setq on-event (plist-get args :on-event)) 'token))
                ((symbol-function 'agent-shell-unsubscribe) #'ignore)
                ((symbol-function 'agent-shell--insert-to-shell-buffer)
                 (lambda (&rest args) (push (plist-get args :text) sent-texts))))
        (review-walkthrough-request)
        ;; First reply: the only step is rejected, so the agent gets one
        ;; chance to fix it. `sent-texts' also holds the initial request
        ;; prompt from `review-walkthrough-request' above, so count only
        ;; the follow-up corrections.
        (funcall on-event nil)
        (should (= (length (seq-filter (lambda (s) (string-match-p "rejected" s)) sent-texts)) 1))
        (should (eq (plist-get (review-session-walkthrough s) :status) 'planning))
        ;; Second reply: same bad route. No further correction is asked for.
        (funcall on-event nil)
        (should (eq (plist-get (review-session-walkthrough s) :status) 'no-route))
        (should (= (length (seq-filter (lambda (s) (string-match-p "rejected" s)) sent-texts)) 1))))))

(ert-deftest review-walkthrough-agent-ask-context-carries-step ()
  (review-walk-test--with s
    (review-walkthrough-start review-walk-test--steps)
    (with-current-buffer (review-session-new-buffer s)
      (let ((item (review-walkthrough-agent--ask-context)))
        (should (eq (plist-get item :type) 'walkthrough))
        (should (string-match-p "step 1: Three" (plist-get item :label)))
        (should (string-match-p "\\+ THREE" (plist-get item :content)))))))
