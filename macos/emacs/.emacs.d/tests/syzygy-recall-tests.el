;;; syzygy-recall-tests.el --- Tests for Syzygy transcript resume -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'json)

(defvar agent-recall-resume-restore-preferences)

(let* ((tests-directory
        (file-name-directory (or load-file-name buffer-file-name)))
       (source (expand-file-name "../lisp/syzygy/syzygy-recall.el"
                                 tests-directory)))
  ;; Force the source under test to load even when init.el already provided an
  ;; installed `syzygy-recall' earlier in the same full-suite process.
  (load source nil nil t))

;; `syzygy-recall' requires agent-recall lazily.  These tests exercise the
;; Syzygy boundary with controlled index/session operations, without starting
;; an ACP process.
(provide 'agent-recall)

(defun syzygy-recall-test--decode (encoded)
  "Decode ENCODED base64 JSON into an alist."
  (json-parse-string
   (decode-coding-string (base64-decode-string encoded) 'utf-8)
   :object-type 'alist :array-type 'list :false-object nil))

(defun syzygy-recall-test--write-transcript (root name agent cwd)
  "Create transcript NAME under ROOT for AGENT and CWD."
  (let ((file (expand-file-name name root)))
    (with-temp-file file
      (insert "# Agent Conversation Transcript\n\n"
              "**Agent:** " agent "\n"
              "**Working Directory:** " cwd "\n\n"
              "---\n\n## User (2026-08-27)\n\nhello\n"))
    file))

(ert-deftest syzygy-recall-test-transcripts-report-resume-readiness ()
  "History marks missing session IDs unavailable while valid sessions resume."
  (let* ((root (make-temp-file "syzygy-recall-" t))
         (cwd (expand-file-name "project" root))
         (_ (make-directory cwd))
         (ready-file (syzygy-recall-test--write-transcript
                      root "2026-08-27-12-00-00.md" "Claude" cwd))
         (missing-file (syzygy-recall-test--write-transcript
                        root "2026-08-27-11-00-00.md" "Claude" cwd))
         (agent-recall--index (make-hash-table :test 'equal)))
    (unwind-protect
        (progn
          (puthash ready-file
                   '(:project "demo" :timestamp "2026-08-27-12-00-00"
                     :session-id "session-ready" :preview "ready")
                   agent-recall--index)
          (puthash missing-file
                   '(:project "demo" :timestamp "2026-08-27-11-00-00"
                     :preview "missing")
                   agent-recall--index)
          (cl-letf (((symbol-function 'agent-recall--index-ensure) #'ignore)
                    ((symbol-function 'agent-recall--read-working-directory)
                     (lambda (_file) cwd))
                    ((symbol-function 'agent-recall--agent-config-for-transcript)
                     (lambda (_file) '((:identifier . "Claude")))))
            (let* ((rows (syzygy-recall-test--decode
                          (syzygy-recall-transcripts-json 10)))
                   (ready (seq-find
                           (lambda (row)
                             (equal (alist-get 'file row) ready-file))
                           rows))
                   (missing (seq-find
                             (lambda (row)
                               (equal (alist-get 'file row) missing-file))
                             rows)))
              (should (eq (alist-get 'resumable ready) t))
              (should (equal (alist-get 'resumeReason ready) ""))
              (should-not (alist-get 'resumable missing))
              (should (equal (alist-get 'resumeReason missing)
                             "No session ID was recorded.")))))
      (delete-directory root t))))

(ert-deftest syzygy-recall-test-resume-rejects-unindexed-transcript ()
  "A transcript-shaped path cannot bypass agent-recall's index."
  (let* ((root (make-temp-file "syzygy-recall-" t))
         (cwd (expand-file-name "project" root))
         (_ (make-directory cwd))
         (file (syzygy-recall-test--write-transcript
                root "2026-08-27-12-00-00.md" "Claude" cwd))
         (agent-recall--index (make-hash-table :test 'equal))
         (starts 0))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-recall--index-ensure) #'ignore)
                  ((symbol-function 'agent-recall--start-resume)
                   (lambda (&rest _args) (cl-incf starts))))
          (let ((result (syzygy-recall-test--decode
                         (syzygy-recall-resume-json
                          (base64-encode-string file t)))))
            (should-not (alist-get 'ok result))
            (should (equal (alist-get 'error result)
                           "Transcript is not present in the agent-recall index."))
            (should (= starts 0))))
      (delete-directory root t))))

(ert-deftest syzygy-recall-test-resume-reuses-existing-session ()
  "An indexed live session is selected without starting a duplicate."
  (let* ((root (make-temp-file "syzygy-recall-" t))
         (cwd (expand-file-name "project" root))
         (_ (make-directory cwd))
         (file (syzygy-recall-test--write-transcript
                root "2026-08-27-12-00-00.md" "Claude" cwd))
         (agent-recall--index (make-hash-table :test 'equal))
         (buffer (generate-new-buffer "*Claude Agent @ demo*"))
         displayed)
    (unwind-protect
        (progn
          (puthash file '(:session-id "session-123") agent-recall--index)
          (with-current-buffer buffer
            (setq-local agent-shell--state
                        '((:session . ((:id . "session-123")))
                          (:supports-session-load . t)
                          (:supports-session-resume . nil))))
          (cl-letf (((symbol-function 'agent-recall--index-ensure) #'ignore)
                    ((symbol-function 'agent-recall--read-working-directory)
                     (lambda (_file) nil))
                    ((symbol-function 'agent-recall--agent-config-for-transcript)
                     (lambda (_file) nil))
                    ((symbol-function 'agent-recall--find-session-buffer)
                     (lambda (session-id)
                       (and (equal session-id "session-123") buffer)))
                    ((symbol-function 'agent-recall--display-buffer)
                     (lambda (selected) (setq displayed selected)))
                    ((symbol-function 'agent-recall--start-resume)
                     (lambda (&rest _args)
                       (ert-fail "existing session should not be restarted"))))
            (let ((result (syzygy-recall-test--decode
                           (syzygy-recall-resume-json
                            (base64-encode-string file t)))))
              (should (eq (alist-get 'ok result) t))
              (should (eq (alist-get 'existing result) t))
              (should (equal (alist-get 'sessionId result) "session-123"))
              (should (equal (alist-get 'bufferName result)
                             "*Claude Agent @ demo*"))
              (should (eq displayed buffer)))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest syzygy-recall-test-resume-awaits-pending-existing-session ()
  "A concurrent pending match is polled, not reported as already resumed."
  (let* ((root (make-temp-file "syzygy-recall-" t))
         (cwd (expand-file-name "project" root))
         (_ (make-directory cwd))
         (file (syzygy-recall-test--write-transcript
                root "2026-08-27-12-00-00.md" "Claude" cwd))
         (agent-recall--index (make-hash-table :test 'equal))
         (buffer (generate-new-buffer "*Claude Agent @ pending*"))
         (starts 0))
    (unwind-protect
        (progn
          (puthash file '(:session-id "session-pending") agent-recall--index)
          (with-current-buffer buffer
            (setq-local agent-shell--state
                        '((:session . nil)
                          (:resume-session-id . "session-pending")
                          (:supports-session-load . t)
                          (:supports-session-resume . nil))))
          (cl-letf (((symbol-function 'agent-recall--index-ensure) #'ignore)
                    ((symbol-function 'agent-recall--read-working-directory)
                     (lambda (_file) cwd))
                    ((symbol-function 'agent-recall--agent-config-for-transcript)
                     (lambda (_file) '((:identifier . "Claude"))))
                    ((symbol-function 'agent-recall--find-session-buffer)
                     (lambda (_session-id) buffer))
                    ((symbol-function 'agent-recall--display-buffer) #'ignore)
                    ((symbol-function 'agent-recall--start-resume)
                     (lambda (&rest _args) (cl-incf starts))))
            (let* ((started (syzygy-recall-test--decode
                             (syzygy-recall-resume-json
                              (base64-encode-string file t))))
                   (operation (alist-get 'operation started))
                   (concurrent (syzygy-recall-test--decode
                                (syzygy-recall-resume-json
                                 (base64-encode-string file t)))))
              (should (eq (alist-get 'ok started) t))
              (should (equal (alist-get 'status started) "pending"))
              (should (stringp operation))
              (should (equal (alist-get 'operation concurrent) operation))
              (should (= starts 0))
              (with-current-buffer buffer
                (setf (alist-get :session agent-shell--state)
                      '((:id . "session-pending"))))
              (let ((finished (syzygy-recall-test--decode
                               (syzygy-recall-resume-status-json
                                (base64-encode-string operation t)))))
                (should (eq (alist-get 'ok finished) t))
                (should (equal (alist-get 'status finished) "ready"))
                (should (eq (alist-get 'existing finished) t))
                (should (equal (alist-get 'sessionId finished)
                               "session-pending"))))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest syzygy-recall-test-pending-external-failure-is-not-killed ()
  "A joined pending buffer is guarded but remains owned by its creator."
  (let* ((root (make-temp-file "syzygy-recall-" t))
         (cwd (expand-file-name "project" root))
         (_ (make-directory cwd))
         (file (syzygy-recall-test--write-transcript
                root "2026-08-27-12-00-00.md" "Codex" cwd))
         (agent-recall--index (make-hash-table :test 'equal))
         (buffer (generate-new-buffer "*Codex Agent @ external-pending*"))
         (fallback-calls 0))
    (unwind-protect
        (progn
          (puthash file '(:session-id "external-session") agent-recall--index)
          (with-current-buffer buffer
            (setq-local agent-shell--state
                        '((:session . nil)
                          (:resume-session-id . "external-session")
                          (:supports-session-load . t)
                          (:supports-session-resume . nil))))
          (cl-letf (((symbol-function 'agent-recall--index-ensure) #'ignore)
                    ((symbol-function 'agent-recall--read-working-directory)
                     (lambda (_file) cwd))
                    ((symbol-function 'agent-recall--agent-config-for-transcript)
                     (lambda (_file) '((:identifier . "Codex"))))
                    ((symbol-function 'agent-recall--find-session-buffer)
                     (lambda (_session-id) buffer))
                    ((symbol-function 'agent-recall--display-buffer) #'ignore)
                    ((symbol-function 'agent-recall--start-resume)
                     (lambda (&rest _args)
                       (ert-fail "pending buffer should not be restarted"))))
            (let* ((started (syzygy-recall-test--decode
                             (syzygy-recall-resume-json
                              (base64-encode-string file t))))
                   (operation (alist-get 'operation started)))
              (with-current-buffer buffer
                (syzygy-recall--guard-new-session
                 (lambda (&rest _args) (cl-incf fallback-calls))
                 :shell-buffer buffer))
              (let ((failed (syzygy-recall-test--decode
                             (syzygy-recall-resume-status-json
                              (base64-encode-string operation t)))))
                (should-not (alist-get 'ok failed))
                (should (= fallback-calls 0))
                (should (buffer-live-p buffer))
                (should-not
                 (buffer-local-value
                  'syzygy-recall--strict-resume-session-id buffer))))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest syzygy-recall-test-external-timeout-deduplicates-lifecycle-monitor ()
  "A hung external resume gets one event monitor and no repeating timer leak."
  (let* ((root (make-temp-file "syzygy-recall-" t))
         (cwd (expand-file-name "project" root))
         (_ (make-directory cwd))
         (file (syzygy-recall-test--write-transcript
                root "2026-08-27-12-00-00.md" "Codex" cwd))
         (agent-recall--index (make-hash-table :test 'equal))
         (buffer (generate-new-buffer "*Codex Agent @ external-hung*"))
         (subscriptions 0)
         unsubscribed)
    (unwind-protect
        (progn
          (puthash file '(:session-id "external-hung") agent-recall--index)
          (with-current-buffer buffer
            (setq-local agent-shell--state
                        '((:session . nil)
                          (:resume-session-id . "external-hung")
                          (:supports-session-load . t)
                          (:supports-session-resume . nil))))
          (cl-letf (((symbol-function 'agent-recall--index-ensure) #'ignore)
                    ((symbol-function 'agent-recall--read-working-directory)
                     (lambda (_file) cwd))
                    ((symbol-function 'agent-recall--agent-config-for-transcript)
                     (lambda (_file) '((:identifier . "Codex"))))
                    ((symbol-function 'agent-recall--find-session-buffer)
                     (lambda (_session-id) buffer))
                    ((symbol-function 'agent-recall--display-buffer) #'ignore)
                    ((symbol-function 'agent-shell-subscribe-to)
                     (lambda (&rest _args)
                       (cl-incf subscriptions)
                       'lifecycle-token))
                    ((symbol-function 'agent-shell-unsubscribe)
                     (lambda (&rest args)
                       (setq unsubscribed (plist-get args :subscription)))))
            (let* ((started (syzygy-recall-test--decode
                             (syzygy-recall-resume-json
                              (base64-encode-string file t))))
                   (token (alist-get 'operation started))
                   (operation (gethash token
                                       syzygy-recall--resume-operations)))
              (setq operation (plist-put operation :deadline 0))
              (puthash token operation syzygy-recall--resume-operations)
              (let ((timed-out (syzygy-recall-test--decode
                                (syzygy-recall-resume-status-json
                                 (base64-encode-string token t)))))
                (should-not (alist-get 'ok timed-out))
                (should (buffer-live-p buffer))
                (setq operation
                      (gethash token syzygy-recall--resume-operations))
                (should (plist-get operation :monitor-external))
                (should-not (plist-get operation :timer))
                (should (eq (plist-get operation :lifecycle-subscription)
                            'lifecycle-token))
                (should (= subscriptions 1)))
              ;; Retrying the same hung buffer returns its terminal result;
              ;; it must not allocate another operation or lifecycle monitor.
              (let ((retry (syzygy-recall-test--decode
                            (syzygy-recall-resume-json
                             (base64-encode-string file t)))))
                (should-not (alist-get 'ok retry))
                (should (= subscriptions 1)))
              ;; A late successful init releases the strict guard and monitor.
              (with-current-buffer buffer
                (setf (alist-get :session agent-shell--state)
                      '((:id . "external-hung"))))
              (syzygy-recall--external-lifecycle-event
               token '((:event . init-session)))
              (should (eq unsubscribed 'lifecycle-token))
              (should-not
               (buffer-local-value
                'syzygy-recall--strict-resume-session-id buffer)))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest syzygy-recall-test-resume-starts-indexed-session ()
  "A dormant indexed session starts asynchronously and is then polled."
  (let* ((root (make-temp-file "syzygy-recall-" t))
         (cwd (expand-file-name "project" root))
         (_ (make-directory cwd))
         (file (syzygy-recall-test--write-transcript
                root "2026-08-27-12-00-00.md" "Codex" cwd))
         (agent-recall--index (make-hash-table :test 'equal))
         (buffer (generate-new-buffer "*Codex Agent @ demo*"))
         (agent-recall-resume-restore-preferences 'ask)
         started
         started-with
         restore-setting)
    (unwind-protect
        (progn
          (puthash file '(:session-id "session-456") agent-recall--index)
          (with-current-buffer buffer
            (setq-local agent-shell--state
                        '((:session . nil)
                          (:supports-session-load . t)
                          (:supports-session-resume . nil))))
          (cl-letf (((symbol-function 'agent-recall--index-ensure) #'ignore)
                    ((symbol-function 'agent-recall--read-working-directory)
                     (lambda (_file) cwd))
                    ((symbol-function 'agent-recall--agent-config-for-transcript)
                     (lambda (_file) '((:identifier . "Codex"))))
                    ((symbol-function 'agent-recall--find-session-buffer)
                     (lambda (_session-id) (and started buffer)))
                    ((symbol-function 'agent-recall--start-resume)
                     (lambda (session-id transcript-file)
                       (setq started-with (list session-id transcript-file))
                       (setq restore-setting
                             agent-recall-resume-restore-preferences)
                       (setq started t)
                       `((:viewport-buffer . ,buffer))))
                    ((symbol-function 'accept-process-output)
                     (lambda (&rest _args)
                       (ert-fail "resume start must not block Emacs"))))
            (let* ((result (syzygy-recall-test--decode
                            (syzygy-recall-resume-json
                             (base64-encode-string file t))))
                   (operation (alist-get 'operation result)))
              (should (eq (alist-get 'ok result) t))
              (should (equal (alist-get 'status result) "pending"))
              (should (stringp operation))
              (should (equal started-with (list "session-456" file)))
              (should (eq restore-setting t))
              (with-current-buffer buffer
                (setf (alist-get :session agent-shell--state)
                      '((:id . "session-456"))))
              (let ((finished (syzygy-recall-test--decode
                               (syzygy-recall-resume-status-json
                                (base64-encode-string operation t)))))
                (should (eq (alist-get 'ok finished) t))
                (should (equal (alist-get 'status finished) "ready"))
                (should-not (alist-get 'existing finished))
                (should (equal (alist-get 'bufferName finished)
                               "*Codex Agent @ demo*"))))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest syzygy-recall-test-resume-rejects-unsupported-provider-fallback ()
  "An unsupported provider must never receive a session/new fallback."
  (let* ((root (make-temp-file "syzygy-recall-" t))
         (cwd (expand-file-name "project" root))
         (_ (make-directory cwd))
         (file (syzygy-recall-test--write-transcript
                root "2026-08-27-12-00-00.md" "Other" cwd))
         (agent-recall--index (make-hash-table :test 'equal))
         (buffer (generate-new-buffer "*Other Agent @ demo*"))
         started
         (fallback-calls 0))
    (unwind-protect
        (progn
          (puthash file '(:session-id "archived-session") agent-recall--index)
          (with-current-buffer buffer
            (setq-local agent-shell--state
                        '((:session . nil)
                          (:resume-session-id . "archived-session")
                          (:supports-session-load . nil)
                          (:supports-session-resume . nil))))
          (cl-letf (((symbol-function 'agent-recall--index-ensure) #'ignore)
                    ((symbol-function 'agent-recall--read-working-directory)
                     (lambda (_file) cwd))
                    ((symbol-function 'agent-recall--agent-config-for-transcript)
                     (lambda (_file) '((:identifier . "Other"))))
                    ((symbol-function 'agent-recall--find-session-buffer)
                     (lambda (_session-id) (and started buffer)))
                    ((symbol-function 'agent-recall--start-resume)
                     (lambda (&rest _args)
                       (setq started t)
                       buffer)))
            (let* ((started-result (syzygy-recall-test--decode
                                    (syzygy-recall-resume-json
                                     (base64-encode-string file t))))
                   (operation (alist-get 'operation started-result)))
              (should (equal (alist-get 'status started-result) "pending"))
              (with-current-buffer buffer
                (syzygy-recall--guard-new-session
                 (lambda (&rest _args) (cl-incf fallback-calls))
                 :shell-buffer buffer))
              (let ((result (syzygy-recall-test--decode
                             (syzygy-recall-resume-status-json
                              (base64-encode-string operation t)))))
                (should-not (alist-get 'ok result))
                (should (equal (alist-get 'status result) "failed"))
                (should (equal (alist-get 'error result)
                               "The agent does not support session resume."))
                (should (= fallback-calls 0))
                (should-not (buffer-live-p buffer))))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest syzygy-recall-test-resume-rejects-new-session-fallback ()
  "A failed load must be stopped before it can start a fresh session."
  (let* ((root (make-temp-file "syzygy-recall-" t))
         (cwd (expand-file-name "project" root))
         (_ (make-directory cwd))
         (file (syzygy-recall-test--write-transcript
                root "2026-08-27-12-00-00.md" "Codex" cwd))
         (agent-recall--index (make-hash-table :test 'equal))
         (buffer (generate-new-buffer "*Codex Agent @ demo*"))
         started
         (fallback-calls 0))
    (unwind-protect
        (progn
          (puthash file '(:session-id "archived-session") agent-recall--index)
          (with-current-buffer buffer
            (setq-local agent-shell--state
                        '((:session . nil)
                          (:resume-session-id . "archived-session")
                          (:supports-session-load . t)
                          (:supports-session-resume . nil))))
          (cl-letf (((symbol-function 'agent-recall--index-ensure) #'ignore)
                    ((symbol-function 'agent-recall--read-working-directory)
                     (lambda (_file) cwd))
                    ((symbol-function 'agent-recall--agent-config-for-transcript)
                     (lambda (_file) '((:identifier . "Codex"))))
                    ((symbol-function 'agent-recall--find-session-buffer)
                     (lambda (_session-id) (and started buffer)))
                    ((symbol-function 'agent-recall--start-resume)
                     (lambda (&rest _args)
                       (setq started t)
                       buffer)))
            (let* ((started-result (syzygy-recall-test--decode
                                    (syzygy-recall-resume-json
                                     (base64-encode-string file t))))
                   (operation (alist-get 'operation started-result)))
              (with-current-buffer buffer
                (syzygy-recall--guard-new-session
                 (lambda (&rest _args) (cl-incf fallback-calls))
                 :shell-buffer buffer))
              (let ((result (syzygy-recall-test--decode
                             (syzygy-recall-resume-status-json
                              (base64-encode-string operation t)))))
                (should-not (alist-get 'ok result))
                (should (equal (alist-get 'error result)
                               "The recorded session could not be restored."))
                (should (= fallback-calls 0))
                (should-not (buffer-live-p buffer))))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest syzygy-recall-test-resume-cleans-buffer-when-start-signals ()
  "A buffer created by a start that later signals remains Syzygy-owned."
  (let* ((root (make-temp-file "syzygy-recall-" t))
         (cwd (expand-file-name "project" root))
         (_ (make-directory cwd))
         (file (syzygy-recall-test--write-transcript
                root "2026-08-27-12-00-00.md" "Codex" cwd))
         (agent-recall--index (make-hash-table :test 'equal))
         (buffer (generate-new-buffer "*Codex Agent @ broken-start*")))
    (unwind-protect
        (progn
          (puthash file '(:session-id "archived-session") agent-recall--index)
          (with-current-buffer buffer
            (setq-local agent-shell--state
                        '((:session . nil)
                          (:resume-session-id . "archived-session"))))
          (cl-letf (((symbol-function 'agent-recall--index-ensure) #'ignore)
                    ((symbol-function 'agent-recall--read-working-directory)
                     (lambda (_file) cwd))
                    ((symbol-function 'agent-recall--agent-config-for-transcript)
                     (lambda (_file) '((:identifier . "Codex"))))
                    ((symbol-function 'agent-recall--find-session-buffer)
                     (lambda (_session-id) nil))
                    ((symbol-function 'agent-recall--start-resume)
                     (lambda (&rest _args)
                       (syzygy-recall--arm-strict-resume
                        :shell-buffer buffer)
                       (error "preference restore failed"))))
            (let ((result (syzygy-recall-test--decode
                           (syzygy-recall-resume-json
                            (base64-encode-string file t)))))
              (should-not (alist-get 'ok result))
              (should (equal (alist-get 'error result)
                             "preference restore failed"))
              (should-not (buffer-live-p buffer)))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest syzygy-recall-test-resume-cleans-buffer-when-start-quits ()
  "A desk-side quit during startup cannot strand a strict resume buffer."
  (let* ((root (make-temp-file "syzygy-recall-" t))
         (cwd (expand-file-name "project" root))
         (_ (make-directory cwd))
         (file (syzygy-recall-test--write-transcript
                root "2026-08-27-12-00-00.md" "Codex" cwd))
         (agent-recall--index (make-hash-table :test 'equal))
         (buffer (generate-new-buffer "*Codex Agent @ quit-start*")))
    (unwind-protect
        (progn
          (puthash file '(:session-id "archived-session") agent-recall--index)
          (with-current-buffer buffer
            (setq-local agent-shell--state
                        '((:session . nil)
                          (:resume-session-id . "archived-session"))))
          (cl-letf (((symbol-function 'agent-recall--index-ensure) #'ignore)
                    ((symbol-function 'agent-recall--read-working-directory)
                     (lambda (_file) cwd))
                    ((symbol-function 'agent-recall--agent-config-for-transcript)
                     (lambda (_file) '((:identifier . "Codex"))))
                    ((symbol-function 'agent-recall--find-session-buffer)
                     (lambda (_session-id) nil))
                    ((symbol-function 'agent-recall--start-resume)
                     (lambda (&rest _args)
                       (syzygy-recall--arm-strict-resume
                        :shell-buffer buffer)
                       (signal 'quit nil))))
            (let ((result (syzygy-recall-test--decode
                           (syzygy-recall-resume-json
                            (base64-encode-string file t)))))
              (should-not (alist-get 'ok result))
              (should (equal (alist-get 'error result) "Quit"))
              (should-not (buffer-live-p buffer)))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory root t))))

(provide 'syzygy-recall-tests)
;;; syzygy-recall-tests.el ends here
