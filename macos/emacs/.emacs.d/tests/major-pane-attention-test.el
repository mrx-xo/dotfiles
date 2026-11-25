;;; major-pane-attention-test.el --- "Needs me next" queue -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'face-remap)
(require 'major-pane)

(defmacro major-pane-attention-test--with-chats (names &rest body)
  "Bind NAMES to fresh registered conversation buffers around BODY."
  (declare (indent 1))
  `(let ((major-pane--state (major-pane--make-state))
         (major-pane--labels (make-hash-table :test #'eq))
         (major-pane--anchored nil)
         (major-pane-modes '(fundamental-mode)))
     (let ,(mapcar (lambda (n) `(,n (generate-new-buffer ,(format " *att-%s*" n))))
                   names)
       (unwind-protect
           (progn
             ,@(mapcar (lambda (n) `(major-pane--register-conversation ,n)) names)
             ,@body)
         ,@(mapcar (lambda (n) `(when (buffer-live-p ,n) (kill-buffer ,n))) names)))))

(defun major-pane-attention-test--event (buffer event)
  "Deliver agent-shell EVENT to BUFFER's attention tracking."
  (with-current-buffer buffer
    (major-pane--attention-note-event :event event)))

(defun major-pane-attention-test--set (buffer state reason seconds-ago)
  "Put BUFFER in attention STATE with REASON, entered SECONDS-AGO."
  (with-current-buffer buffer
    (setq major-pane--tab-attention state
          major-pane--attention-reason reason
          major-pane--attention-since (time-subtract nil seconds-ago)
          major-pane--done-at (and (eq state 'done) major-pane--attention-since))))

(ert-deftest major-pane-attention-question-flags-the-tab ()
  "An agent question waits on you like a permission request, with its own reason."
  (major-pane-attention-test--with-chats (a)
    (major-pane-attention-test--event a 'elicitation-request)
    (should (eq (buffer-local-value 'major-pane--tab-attention a) 'perms))
    (should (eq (buffer-local-value 'major-pane--attention-reason a) 'question))
    (should (buffer-local-value 'major-pane--attention-since a))
    (major-pane-attention-test--event a 'elicitation-response)
    (should (eq (buffer-local-value 'major-pane--tab-attention a) 'busy))
    (should-not (buffer-local-value 'major-pane--attention-reason a))))

(ert-deftest major-pane-attention-events-record-reason ()
  (major-pane-attention-test--with-chats (a b)
    (major-pane-attention-test--event a 'permission-request)
    (should (eq (buffer-local-value 'major-pane--attention-reason a) 'approval))
    (major-pane-attention-test--event b 'turn-complete)
    (should (eq (buffer-local-value 'major-pane--tab-attention b) 'done))
    (should (eq (buffer-local-value 'major-pane--attention-reason b) 'finished))))

(ert-deftest major-pane-attention-queue-waiting-first-then-newest ()
  "Waiting chats come before finished ones; each group is newest first."
  (major-pane-attention-test--with-chats (fin-old fin-new wait-new wait-old busy idle)
    (major-pane-attention-test--set fin-old 'done 'finished 300)
    (major-pane-attention-test--set fin-new 'done 'finished 10)
    (major-pane-attention-test--set wait-new 'perms 'approval 5)
    (major-pane-attention-test--set wait-old 'perms 'question 200)
    (major-pane-attention-test--set busy 'busy nil 1)
    (should (equal (major-pane-attention-queue)
                   (list wait-new wait-old fin-new fin-old)))))

(ert-deftest major-pane-attention-finished-outlives-the-green-fade ()
  "A finished chat stays queued after its tab fades; engaging removes it."
  (major-pane-attention-test--with-chats (a)
    (major-pane-attention-test--set a 'done 'finished
                                    (+ major-pane-done-green-seconds 60))
    (should-not (major-pane--done-tier a))          ; the fade cleared the tab
    (should-not (buffer-local-value 'major-pane--tab-attention a))
    (should (equal (major-pane-attention-queue) (list a)))
    (with-current-buffer a
      (cl-letf (((symbol-function 'major-pane--spinner-sync) #'ignore))
        (major-pane-mark-read)))
    (should-not (major-pane-attention-queue))))

(ert-deftest major-pane-attention-new-turn-leaves-the-queue ()
  "Sending a new message makes the chat busy and drops it from the queue."
  (major-pane-attention-test--with-chats (a)
    (major-pane-attention-test--set a 'done 'finished 30)
    (major-pane-attention-test--event a 'input-submitted)
    (should-not (major-pane-attention-queue))))

(ert-deftest major-pane-attention-next-walks-the-queue ()
  "From outside the queue go to its head; from inside go to the next, wrapping."
  (major-pane-attention-test--with-chats (a b c outside)
    (major-pane-attention-test--set a 'perms 'approval 30)
    (major-pane-attention-test--set b 'done 'finished 20)
    (major-pane-attention-test--set c 'done 'finished 10)
    (let (visited)
      (cl-letf (((symbol-function 'major-pane--focus-conversation)
                 (lambda (buf)
                   (push buf visited)
                   (setf (major-pane-state-active major-pane--state) buf)))
                ((symbol-function 'message) #'ignore))
        (setf (major-pane-state-active major-pane--state) outside)
        ;; Queue is a (waiting), then c (finished 10s ago), then b (20s ago).
        (with-current-buffer outside (major-pane-attention-next))
        (with-current-buffer a (major-pane-attention-next))
        (with-current-buffer c (major-pane-attention-next))
        (with-current-buffer b (major-pane-attention-next))
        (with-current-buffer a (major-pane-attention-previous))
        (should (equal (nreverse visited) (list a c b a b)))))))

(ert-deftest major-pane-attention-next-reports-position-and-reason ()
  (major-pane-attention-test--with-chats (a b)
    (major-pane-attention-test--set a 'perms 'question 30)
    (major-pane-attention-test--set b 'done 'finished 20)
    (let (msg)
      (cl-letf (((symbol-function 'major-pane--focus-conversation) #'ignore)
                ((symbol-function 'message)
                 (lambda (fmt &rest args) (setq msg (apply #'format fmt args)))))
        (with-temp-buffer (major-pane-attention-next))
        (should (string-match-p "1/2" msg))
        (should (string-match-p "waiting: question" msg))))))

(ert-deftest major-pane-attention-next-says-so-when-empty ()
  (major-pane-attention-test--with-chats (a)
    (let (msg)
      (cl-letf (((symbol-function 'major-pane--focus-conversation)
                 (lambda (_) (error "Should not move")))
                ((symbol-function 'message)
                 (lambda (fmt &rest args) (setq msg (apply #'format fmt args)))))
        (with-current-buffer a (major-pane-attention-next))
        (should (string-match-p "Nothing needs you" msg))))))

;;; major-pane-attention-test.el ends here
