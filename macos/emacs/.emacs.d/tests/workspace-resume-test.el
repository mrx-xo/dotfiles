;;; workspace-resume-test.el --- Strict workspace resume -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'syzygy-recall)
(require 'agent-shell-bookmark)

(defmacro wr-test--transport (&rest body)
  (declare (indent 0))
  `(let ((syzygy-recall--resume-operations (make-hash-table :test #'equal))
         (buf (generate-new-buffer " *workspace-resume-test*"))
         (events nil) (result nil) (starts 0)
         (pipe (make-pipe-process :name "workspace-test-client" :noquery t)))
     (unwind-protect
         (cl-letf (((symbol-function 'agent-shell-bookmark--resume)
                    (lambda (sid _cwd agent &optional _no-focus)
                      (cl-incf starts)
                      (with-current-buffer buf
                        (setq-local agent-shell--state
                                    (list (cons :buffer buf) (cons :initialized t)
                                          (cons :client (list (cons :process pipe)))
                                          (cons :agent-config (list (cons :identifier agent)))
                                          (cons :resume-session-id sid)
                                          (cons :supports-session-load t)))
                        (syzygy-recall--arm-strict-resume :shell-buffer buf))
                      buf))
                   ((symbol-function 'agent-shell-subscribe-to)
                    (lambda (&rest args) (push (plist-get args :on-event) events) 17))
                   ((symbol-function 'agent-shell-unsubscribe) (lambda (&rest _) nil)))
           ,@body)
       (maphash (lambda (_ op)
                  (when-let ((timer (plist-get op :timer))) (cancel-timer timer)))
                syzygy-recall--resume-operations)
       (when (process-live-p pipe) (delete-process pipe))
       (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest workspace-resume-waits-for-initialization-and-matches-provider ()
  (wr-test--transport
    (let* ((pending (syzygy-recall-resume-entry
                     '(:agent codex :session-id "saved" :cwd "/tmp/")
                     (lambda (r) (setq result r))))
           (token (alist-get 'operation pending)))
      (with-current-buffer buf
        (setf (alist-get :session agent-shell--state) '((:id . "saved"))))
      (syzygy-recall--advance-operation token)
      (should-not result)
      (dolist (fn events) (funcall fn '((:event . init-finished))))
      (syzygy-recall--advance-operation token)
      (should (eq (alist-get 'ok result) t))
      (should (buffer-live-p buf))
      (should (= starts 1)))))

(ert-deftest workspace-resume-wrong-provider-never-succeeds ()
  (wr-test--transport
    (let* ((pending (syzygy-recall-resume-entry
                     '(:agent codex :session-id "saved" :cwd "/tmp/")
                     (lambda (r) (setq result r))))
           (token (alist-get 'operation pending)))
      (with-current-buffer buf
        (setf (alist-get :session agent-shell--state) '((:id . "saved")))
        (setf (alist-get :agent-config agent-shell--state) '((:identifier . claude-code))))
      (dolist (fn events) (funcall fn '((:event . init-finished))))
      (syzygy-recall--advance-operation token)
      (should (eq (alist-get 'ok result) :false))
      (should-not (buffer-live-p buf)))))

(ert-deftest workspace-resume-cancel-keeps-preexisting-buffer ()
  (wr-test--transport
    (with-current-buffer buf
      (setq-local agent-shell--state
                  '((:agent-config . ((:identifier . codex)))
                    (:resume-session-id . "saved") (:supports-session-load . t))))
    (let ((pending (syzygy-recall-resume-entry
                    '(:agent codex :session-id "saved" :cwd "/tmp/")
                    (lambda (r) (setq result r)))))
      (syzygy-recall-cancel-resume (alist-get 'operation pending))
      (should (eq (alist-get 'ok result) :false))
      (should (buffer-live-p buf))
      (should (= starts 0)))))

(ert-deftest workspace-resume-attaching-to-another-operation-never-takes-ownership ()
  (wr-test--transport
    (with-current-buffer buf
      (setq-local agent-shell--state
                  '((:agent-config . ((:identifier . codex)))
                    (:resume-session-id . "saved") (:supports-session-load . t))))
    (let* ((original (syzygy-recall--register-operation buf "saved" t nil))
           (attached (syzygy-recall-resume-entry
                      '(:agent codex :session-id "saved" :cwd "/tmp/")
                      (lambda (r) (setq result r)))))
      (syzygy-recall-cancel-resume (alist-get 'operation attached))
      (should (buffer-live-p buf))
      (should-not (plist-get (gethash (alist-get 'operation original)
                                      syzygy-recall--resume-operations) :result)))))

(ert-deftest workspace-resume-timeout-cleans-only-owned-buffer ()
  (wr-test--transport
    (let* ((syzygy-recall-resume-timeout -1)
           (pending (syzygy-recall-resume-entry
                     '(:agent codex :session-id "saved" :cwd "/tmp/")
                     (lambda (r) (setq result r)))))
      (syzygy-recall--advance-operation (alist-get 'operation pending))
      (should (eq (alist-get 'ok result) :false))
      (should (string-match-p "silent" (alist-get 'error result)))
      (should-not (buffer-live-p buf)))))

(ert-deftest workspace-resume-timeout-stops-owned-agent-process ()
  ;; A resume abandoned mid-bootstrap has no agent-shell kill hook yet; the
  ;; process must not outlive the buffer.
  (wr-test--transport
    (let* ((syzygy-recall-resume-timeout -1)
           (pending (syzygy-recall-resume-entry
                     '(:agent codex :session-id "saved" :cwd "/tmp/")
                     (lambda (r) (setq result r)))))
      (should (process-live-p pipe))
      (syzygy-recall--advance-operation (alist-get 'operation pending))
      (should (eq (alist-get 'ok result) :false))
      (should-not (buffer-live-p buf))
      (should-not (process-live-p pipe)))))

(ert-deftest workspace-resume-agent-activity-restarts-stall-clock ()
  ;; A slow replay keeps talking; every message buys another full window.
  (wr-test--transport
    (let* ((syzygy-recall-resume-timeout 0.2)
           (pending (syzygy-recall-resume-entry
                     '(:agent codex :session-id "saved" :cwd "/tmp/")
                     (lambda (r) (setq result r))))
           (token (alist-get 'operation pending)))
      (cancel-timer (plist-get (gethash token syzygy-recall--resume-operations) :timer))
      (sleep-for 0.3)
      (with-current-buffer buf
        (setf (alist-get :last-activity-time agent-shell--state) (current-time)))
      (syzygy-recall--advance-operation token)
      (should-not result)
      (sleep-for 0.3)
      (syzygy-recall--advance-operation token)
      (should (eq (alist-get 'ok result) :false))
      (should (string-match-p "silent" (alist-get 'error result))))))

(ert-deftest workspace-resume-hard-cap-holds-despite-activity ()
  (wr-test--transport
    (let* ((syzygy-recall-resume-hard-timeout -1)
           (pending (syzygy-recall-resume-entry
                     '(:agent codex :session-id "saved" :cwd "/tmp/")
                     (lambda (r) (setq result r))))
           (token (alist-get 'operation pending)))
      (with-current-buffer buf
        (setf (alist-get :last-activity-time agent-shell--state) (current-time)))
      (syzygy-recall--advance-operation token)
      (should (eq (alist-get 'ok result) :false))
      (should (string-match-p "did not finish" (alist-get 'error result))))))

(ert-deftest workspace-resume-existing-session-id-does-not-imply-ready ()
  (wr-test--transport
    (with-current-buffer buf
      (setq-local agent-shell--state
                  '((:agent-config . ((:identifier . codex)))
                    (:session . ((:id . "saved"))) (:supports-session-load . t))))
    (let ((pending (syzygy-recall-resume-entry
                    '(:agent codex :session-id "saved" :cwd "/tmp/")
                    (lambda (r) (setq result r)))))
      (should-not result)
      (should (equal (alist-get 'status pending) "pending"))
      (syzygy-recall-cancel-resume (alist-get 'operation pending)))))

(ert-deftest workspace-resume-other-completion-preserves-initialization-listener ()
  (wr-test--transport
    (let* ((pending (syzygy-recall-resume-entry
                     '(:agent codex :session-id "saved" :cwd "/tmp/")
                     (lambda (r) (setq result r))))
           (syzygy-recall--independent-operation t)
           (other (syzygy-recall--register-operation buf "saved" nil t)))
      (with-current-buffer buf
        (setf (alist-get :session agent-shell--state) '((:id . "saved"))))
      (syzygy-recall--advance-operation (alist-get 'operation other))
      (should (buffer-local-value 'syzygy-recall--entry-subscription buf))
      (dolist (fn events) (funcall fn '((:event . init-finished))))
      (syzygy-recall--advance-operation (alist-get 'operation pending))
      (should (eq (alist-get 'ok result) t)))))

(ert-deftest workspace-resume-existing-model-initialization-must-finish ()
  (wr-test--transport
    (with-current-buffer buf
      (setq-local agent-shell--state
                  `((:agent-config . ((:identifier . codex) (:default-model-id . ,(lambda () "model"))))
                    (:initialized . t) (:client . ((:process . ,pipe)))
                    (:session . ((:id . "saved"))) (:supports-session-load . t))))
    (let ((pending (syzygy-recall-resume-entry
                    '(:agent codex :session-id "saved" :cwd "/tmp/")
                    (lambda (r) (setq result r)))))
      (should-not result)
      (with-current-buffer buf (setf (alist-get :set-model agent-shell--state) t))
      (dolist (fn events) (funcall fn '((:event . init-finished))))
      (syzygy-recall--advance-operation (alist-get 'operation pending))
      (should (eq (alist-get 'ok result) t))
      (should (eq (alist-get 'existing result) t))
      (should (= starts 0)))))
