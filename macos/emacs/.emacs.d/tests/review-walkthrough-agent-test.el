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

(ert-deftest review-walkthrough-agent-route-json-keeps-embedded-backticks ()
  ;; A step body quoting code in backticks must not truncate the block: the
  ;; closing fence has to start a line, and this ``` sits mid-line.
  (let* ((json (concat "{\"steps\": [{\"path\": \"a.el\", \"line_start\": 3, \"line_end\": 3, "
                       "\"title\": \"Three\", \"body\": \"use ```x``` here\"}]}"))
         (text (concat "prose\n```json\n" json "\n```\ntrailing")))
    (should (equal (string-trim (review-walkthrough-agent--route-json text)) json))))

(ert-deftest review-walkthrough-agent-route-json-unfenced ()
  ;; agent-shell's markdown rendering can strip the ```json fence from
  ;; `shell-maker-last-output' even though the JSON text itself arrives
  ;; intact, so a bare object with no fence at all must still be found.
  (let* ((json "{\"steps\": [{\"path\": \"a.el\", \"line_start\": 3, \"line_end\": 3, \"title\": \"Three\"}]}")
         (text (concat "Here is the route.\n" json "\nHope that helps!")))
    (should (equal (review-walkthrough-agent--route-json text) json))))

(ert-deftest review-walkthrough-agent-route-json-skips-earlier-mention ()
  ;; A prose mention of the shape, before the real route, must not win:
  ;; the last valid JSON object found is the one that counts.
  (let* ((json "{\"steps\": [{\"path\": \"a.el\", \"line_start\": 3, \"line_end\": 3, \"title\": \"Three\"}]}")
         (text (concat "The shape looks like {\"steps\": ...} with one entry per step.\n"
                       "Here is the real route:\n" json "\nDone.")))
    (should (equal (review-walkthrough-agent--route-json text) json))))

(defmacro review-walk-agent-test--stubbed (&rest body)
  "Run BODY with agent-shell stubbed.
`reply' is the agent's last output; `handlers' holds (TOKEN EVENT FUNCTION)
per subscription, newest first; `unsubscribed' and `sent' record the calls."
  (declare (indent 0))
  `(let (reply handlers unsubscribed sent (counter 0))
     (cl-letf (((symbol-function 'mr-x/quick-ask--ensure-session) (lambda (_dir) (current-buffer)))
               ((symbol-function 'shell-maker-busy) (lambda () nil))
               ((symbol-function 'shell-maker-last-output) (lambda () reply))
               ((symbol-function 'agent-shell-subscribe-to)
                (lambda (&rest args)
                  (push (list (cl-incf counter) (plist-get args :event) (plist-get args :on-event)) handlers)
                  counter))
               ((symbol-function 'agent-shell-unsubscribe)
                (lambda (&rest args) (push (plist-get args :subscription) unsubscribed)))
               ((symbol-function 'agent-shell--insert-to-shell-buffer)
                (lambda (&rest args) (push (plist-get args :text) sent))))
       ,@body)))

(defun review-walk-agent-test--handler (handlers event)
  "The newest subscription to EVENT in HANDLERS, as a function."
  (nth 2 (seq-find (lambda (h) (eq (nth 1 h) event)) handlers)))

(defun review-walk-agent-test--fire (handlers event &optional data)
  (funcall (or (review-walk-agent-test--handler handlers event)
               (error "No subscription to %s" event))
           (append (and data (list (cons :data data))) (list (cons :event event)))))

(defconst review-walk-agent-test--route
  (concat "Sure thing, here is the route.\n\n```json\n"
          "{\"steps\": [{\"path\": \"a.el\", \"line_start\": 3, \"line_end\": 3, \"title\": \"Three\"}]}"
          "\n```\n"))

(ert-deftest review-walkthrough-agent-request-round-trip ()
  (review-walk-test--with s
    (review-panel-open s)
    (review-walk-agent-test--stubbed
      (setq reply "Here is my answer.")
      (review-walkthrough-request)
      (should (eq (plist-get (review-session-walkthrough s) :status) 'planning))
      (should (string-match-p "```json" (car sent)))
      ;; The agent's reply carries no route: no route.
      (review-walk-agent-test--fire handlers 'turn-complete)
      (should (eq (plist-get (review-session-walkthrough s) :status) 'no-route))
      (should (equal review-walkthrough-agent--last-output "Here is my answer.")))))

(ert-deftest review-walkthrough-agent-request-applies-reply-route ()
  (review-walk-test--with s
    (review-panel-open s)
    (review-walk-agent-test--stubbed
      (setq reply review-walk-agent-test--route)
      (review-walkthrough-request)
      (review-walk-agent-test--fire handlers 'turn-complete)
      (should (= (length (plist-get (review-session-walkthrough s) :steps)) 1))
      (should (= (plist-get (review-session-walkthrough s) :index) 0)))))

(ert-deftest review-walkthrough-agent-request-asks-once-to-correct ()
  (review-walk-test--with s
    (review-panel-open s)
    (review-walk-agent-test--stubbed
      (setq reply (concat "```json\n{\"steps\": [{\"path\": \"a.el\", \"line_start\": 7, "
                          "\"line_end\": 7, \"title\": \"Unchanged\"}]}\n```\n"))
      (review-walkthrough-request)
      ;; First reply: the only step is rejected, so the agent gets one
      ;; chance to fix it. `sent' also holds the initial request prompt
      ;; from `review-walkthrough-request' above, so count only the
      ;; follow-up corrections.
      (review-walk-agent-test--fire handlers 'turn-complete)
      (should (= (length (seq-filter (lambda (s) (string-match-p "rejected" s)) sent)) 1))
      (should (eq (plist-get (review-session-walkthrough s) :status) 'planning))
      ;; The correction waits on both events too, like the request.
      (should (review-walk-agent-test--handler handlers 'error))
      ;; Second reply: same bad route. No further correction is asked for.
      (review-walk-agent-test--fire handlers 'turn-complete)
      (should (eq (plist-get (review-session-walkthrough s) :status) 'no-route))
      (should (= (length (seq-filter (lambda (s) (string-match-p "rejected" s)) sent)) 1)))))

(ert-deftest review-walkthrough-agent-internal-error-is-not-a-correction ()
  ;; A bug inside review-walkthrough-start (validation, navigation,
  ;; rendering) is not a bad route from the agent: it must not trigger a
  ;; "fix your JSON" round-trip, just a plain failure report.
  (review-walk-test--with s
    (review-panel-open s)
    (review-walk-agent-test--stubbed
      (setq reply review-walk-agent-test--route)
      (cl-letf (((symbol-function 'review-walkthrough-start) (lambda (&rest _) (error "boom"))))
        (review-walkthrough-request)
        (review-walk-agent-test--fire handlers 'turn-complete)
        (should (eq (plist-get (review-session-walkthrough s) :status) 'no-route))
        ;; Only the original request prompt was sent; no correction follow-up.
        (should (= (length sent) 1))
        (should (string-match-p "boom" review-walkthrough-agent--last-output))))))

(ert-deftest review-walkthrough-agent-error-event-ends-planning ()
  ;; agent-shell emits `error', not `turn-complete', when a turn fails.
  ;; Without handling it the panel sticks on "Planning route...".
  (review-walk-test--with s
    (review-panel-open s)
    (let ((review-walkthrough-agent--last-output nil))
      (review-walk-agent-test--stubbed
        (review-walkthrough-request)
        (review-walk-agent-test--fire handlers 'error '((:code . 529) (:message . "Overloaded")))
        (should (eq (plist-get (review-session-walkthrough s) :status) 'no-route))
        (should (string-match-p "Overloaded" review-walkthrough-agent--last-output))
        ;; Both subscriptions are gone, so the next turn cannot fire either.
        (should (equal (sort (copy-sequence unsubscribed) #'<)
                       (sort (mapcar #'car handlers) #'<)))))))

(ert-deftest review-walkthrough-agent-stale-reply-keeps-live-route ()
  ;; A leftover subscription firing on a later turn must not write
  ;; no-route over a walkthrough that no longer waits on it.
  (review-walk-test--with s
    (review-panel-open s)
    (review-walk-agent-test--stubbed
      (setq reply "Unrelated Quick Ask answer.")
      (review-walkthrough-request)
      (let ((stale (review-walk-agent-test--handler handlers 'turn-complete)))
        (review-walkthrough-start review-walk-test--steps)
        (funcall stale '((:event . turn-complete)))
        (should (= (length (plist-get (review-session-walkthrough s) :steps)) 3))))))

(ert-deftest review-walkthrough-agent-reply-after-resume-lands-on-resumed-session ()
  (review-walk-test--with s
    (review-panel-open s)
    (review-walk-agent-test--stubbed
      (setq reply review-walk-agent-test--route)
      (review-walkthrough-request)
      (review-session-pause)
      (let ((r (review-session-resume)))
        (should-not (eq r s))
        (should (eq (plist-get (review-session-walkthrough r) :status) 'planning))
        (review-walk-agent-test--fire handlers 'turn-complete)
        (should (= (length (plist-get (review-session-walkthrough r) :steps)) 1))))))

(ert-deftest review-walkthrough-agent-reply-without-waiting-session-is-dropped ()
  ;; The review quit, then opened again: the new session never asked, so the
  ;; old request's reply is dropped whole, its text included.
  (review-walk-test--with s
    (review-panel-open s)
    (let ((review-walkthrough-agent--last-output nil))
      (review-walk-agent-test--stubbed
        (setq reply review-walk-agent-test--route)
        (review-walkthrough-request)
        (review-session-quit)
        (let ((again (review-session-start (review-walk-test--source))))
          (review-walk-agent-test--fire handlers 'turn-complete)
          (should-not (review-session-walkthrough again))
          (should-not review-walkthrough-agent--last-output))))))

(ert-deftest review-walkthrough-agent-retry-stops-when-request-is-gone ()
  (review-walk-test--with s
    (review-panel-open s)
    (review-walk-agent-test--stubbed
      (setq reply review-walk-agent-test--route)
      (let ((starts 0) timers)
        (cl-letf (((symbol-function 'review-walkthrough-start-file)
                   (lambda (_file) (cl-incf starts) "retry: loading a.el; run the same command again"))
                  ((symbol-function 'run-at-time)
                   (lambda (_time _repeat fn &rest args) (push (cons fn args) timers))))
          (review-walkthrough-request)
          (review-walk-agent-test--fire handlers 'turn-complete)
          (should (= starts 1))
          (should (= (length timers) 1))
          ;; The request is cancelled before the retry runs: it must not
          ;; try again, or write anything over the walkthrough.
          (setf (review-session-walkthrough s) nil)
          (apply (car (car timers)) (cdr (car timers)))
          (should (= starts 1))
          (should-not (review-session-walkthrough s)))))))

(ert-deftest review-walkthrough-agent-dwim-while-planning ()
  (review-walk-test--with s
    (review-panel-open s)
    (review-walk-agent-test--stubbed
      (let (key shown)
        (cl-letf (((symbol-function 'read-key) (lambda (&rest _) key))
                  ((symbol-function 'y-or-n-p) (lambda (&rest _) nil))
                  ((symbol-function 'pop-to-buffer) (lambda (&rest _) (setq shown t))))
          (review-walkthrough-request)
          ;; Any other key: nothing.
          (setq key ?x)
          (review-walkthrough-agent-dwim)
          (should (eq (plist-get (review-session-walkthrough s) :status) 'planning))
          (should-not shown)
          ;; s: show the agent's session, keep planning.
          (setq key ?s)
          (review-walkthrough-agent-dwim)
          (should shown)
          (should (eq (plist-get (review-session-walkthrough s) :status) 'planning))
          ;; c: cancel planning, and stop listening for the reply.
          (setq key ?c)
          (review-walkthrough-agent-dwim)
          (should-not (review-session-walkthrough s))
          (should (equal (sort (copy-sequence unsubscribed) #'<)
                         (sort (mapcar #'car handlers) #'<))))))))

(ert-deftest review-walkthrough-agent-request-busy-does-not-send ()
  ;; A busy shell might just be waiting on an unrelated prompt; offer to
  ;; show it instead of a bare error, but never send the request either way.
  (review-walk-test--with _s
    (let (sent shown (asked 0))
      (cl-letf (((symbol-function 'mr-x/quick-ask--ensure-session) (lambda (_dir) (current-buffer)))
                ((symbol-function 'shell-maker-busy) (lambda () t))
                ((symbol-function 'y-or-n-p) (lambda (_prompt) (cl-incf asked) nil))
                ((symbol-function 'pop-to-buffer) (lambda (&rest _) (setq shown t)))
                ((symbol-function 'agent-shell--insert-to-shell-buffer)
                 (lambda (&rest args) (setq sent (plist-get args :text)))))
        (review-walkthrough-request)
        (should (= asked 1))
        (should-not shown)
        (should-not sent)))))

(ert-deftest review-walkthrough-agent-ask-context-carries-step ()
  (review-walk-test--with s
    (review-walkthrough-start review-walk-test--steps)
    (with-current-buffer (review-session-new-buffer s)
      (let ((item (review-walkthrough-agent--ask-context)))
        (should (eq (plist-get item :type) 'walkthrough))
        (should (string-match-p "step 1: Three" (plist-get item :label)))
        (should (string-match-p "\\+ THREE" (plist-get item :content)))))))
