;;; agent-shell-push-test.el --- Tests for agent-shell-push -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)
(require 'json)

(add-to-list
 'load-path
 (expand-file-name "../lisp" (file-name-directory (or load-file-name
                                                      buffer-file-name))))
(require 'agent-shell-push)

(defvar agent-shell-push-test--sent nil
  "Commands the module handed to its spawn seam, newest first.")

(defmacro agent-shell-push-test--with-env (&rest body)
  "Run BODY with fake token and link files and a captured spawn seam."
  (declare (indent 0) (debug t))
  `(let* ((dir (make-temp-file "agent-shell-push-test-" t))
          (agent-shell-push-token-file (expand-file-name "token" dir))
          (agent-shell-push-link-file (expand-file-name "link" dir))
          (agent-shell-push-sidecar-file (expand-file-name "push.json" dir))
          (agent-shell-push-ha-url "https://ha.example")
          (agent-shell-push-service "mobile_app_daemon")
          (agent-shell-push-test--sent nil)
          (agent-shell-push-spawn-function
           (lambda (_name command)
             (push command agent-shell-push-test--sent))))
     (with-temp-file agent-shell-push-token-file (insert "TOKEN\n"))
     (with-temp-file agent-shell-push-link-file
       (insert "http://mrx.ts.net:8090?authkey=K\n"))
     (unwind-protect
         (with-temp-buffer
           (rename-buffer "Claude Agent @ home-lab" t)
           ,@body)
       (delete-directory dir t))))

(defun agent-shell-push-test--payload (command)
  "Return the parsed JSON body from curl COMMAND."
  (let ((json-object-type 'alist)
        (json-key-type 'symbol))
    (json-read-from-string (cadr (member "-d" command)))))

(defun agent-shell-push-test--last-payload ()
  "Return the parsed JSON body of the most recent captured command."
  (agent-shell-push-test--payload (car agent-shell-push-test--sent)))

(ert-deftest agent-shell-push-off-by-default-sends-nothing ()
  "A buffer that was never armed must not push on turn completion."
  (agent-shell-push-test--with-env
    (should-not agent-shell-push-mode)
    (agent-shell-push--on-success (current-buffer)
                                  '((stopReason . "end_turn")))
    (should (null agent-shell-push-test--sent))))

(ert-deftest agent-shell-push-done-sends-when-armed ()
  "An armed buffer pushes a Finished notification on end_turn."
  (agent-shell-push-test--with-env
    (agent-shell-push-mode 1)
    (agent-shell-push--on-success (current-buffer)
                                  '((stopReason . "end_turn")))
    (should (= 1 (length agent-shell-push-test--sent)))
    (let ((payload (agent-shell-push-test--last-payload)))
      (should (equal (alist-get 'message payload) "Finished"))
      (should (equal (alist-get 'title payload) "Claude Agent @ home-lab")))))

(ert-deftest agent-shell-push-cancelled-is-not-pushed ()
  "A user-initiated cancel ends the turn but must not push."
  (agent-shell-push-test--with-env
    (agent-shell-push-mode 1)
    (agent-shell-push--on-success (current-buffer)
                                  '((stopReason . "cancelled")))
    (should (null agent-shell-push-test--sent))))

(ert-deftest agent-shell-push-failure-sends-details ()
  "A failed request pushes the extracted error text."
  (agent-shell-push-test--with-env
    (agent-shell-push-mode 1)
    (agent-shell-push--on-failure (current-buffer)
                                  '((message . "rate limited")) nil)
    (should (= 1 (length agent-shell-push-test--sent)))
    (should (equal (alist-get 'message (agent-shell-push-test--last-payload))
                   "rate limited"))))

(ert-deftest agent-shell-push-failure-falls-back-to-generic-text ()
  "A failure without any message still pushes a readable body."
  (agent-shell-push-test--with-env
    (agent-shell-push-mode 1)
    (agent-shell-push--on-failure (current-buffer) nil nil)
    (should (equal (alist-get 'message (agent-shell-push-test--last-payload))
                   "Request failed"))))

(ert-deftest agent-shell-push-permission-request-sends-label ()
  "A permission request pushes the tool title and kind."
  (agent-shell-push-test--with-env
    (agent-shell-push-mode 1)
    (agent-shell-push--on-event
     (current-buffer)
     '((:event . permission-request)
       (:data . ((:tool-call . ((:title . "rm -rf build")
                                (:kind . "execute")))))))
    (should (= 1 (length agent-shell-push-test--sent)))
    (should (equal (alist-get 'message (agent-shell-push-test--last-payload))
                   "Permission: rm -rf build (execute)"))))

(ert-deftest agent-shell-push-other-events-are-ignored ()
  "Permission responses and turn-complete events do not push via the event path.
turn-complete is covered by the handle-success advice; pushing here too
would double-send."
  (agent-shell-push-test--with-env
    (agent-shell-push-mode 1)
    (agent-shell-push--on-event (current-buffer)
                                '((:event . permission-response)))
    (agent-shell-push--on-event (current-buffer)
                                '((:event . turn-complete)
                                  (:data . ((stopReason . "end_turn")))))
    (should (null agent-shell-push-test--sent))))

(ert-deftest agent-shell-push-payload-carries-link-group-and-tag ()
  "The push deep-links to acp-mobile and groups per conversation."
  (agent-shell-push-test--with-env
    (agent-shell-push-mode 1)
    (agent-shell-push--on-success (current-buffer)
                                  '((stopReason . "end_turn")))
    (let ((data (alist-get 'data (agent-shell-push-test--last-payload))))
      (should (equal (alist-get 'url data) "http://mrx.ts.net:8090?authkey=K"))
      (should (equal (alist-get 'group data) "agent-shell"))
      (should (equal (alist-get 'tag data) "Claude Agent @ home-lab")))))

(ert-deftest agent-shell-push-missing-link-still-sends ()
  "No acp-mobile link file means a push without a URL, not a dropped push."
  (agent-shell-push-test--with-env
    (delete-file agent-shell-push-link-file)
    (agent-shell-push-mode 1)
    (agent-shell-push--on-success (current-buffer)
                                  '((stopReason . "end_turn")))
    (should (= 1 (length agent-shell-push-test--sent)))
    (should-not (assq 'url (alist-get 'data (agent-shell-push-test--last-payload))))))

(ert-deftest agent-shell-push-missing-token-sends-nothing ()
  "Without an HA token the module must not spawn curl or signal."
  (agent-shell-push-test--with-env
    (delete-file agent-shell-push-token-file)
    (agent-shell-push-mode 1)
    (agent-shell-push--on-success (current-buffer)
                                  '((stopReason . "end_turn")))
    (should (null agent-shell-push-test--sent))))

(ert-deftest agent-shell-push-curl-command-shape ()
  "The spawned command is a bearer-authenticated JSON POST to the HA service."
  (agent-shell-push-test--with-env
    (agent-shell-push-mode 1)
    (agent-shell-push--on-success (current-buffer)
                                  '((stopReason . "end_turn")))
    (let ((command (car agent-shell-push-test--sent)))
      (should (equal (car command) "curl"))
      (should (member "-X" command))
      (should (equal (cadr (member "-X" command)) "POST"))
      (should (member "Authorization: Bearer TOKEN" command))
      (should (member "Content-Type: application/json" command))
      (should (equal (car (last command))
                     "https://ha.example/api/services/notify/mobile_app_daemon")))))

(ert-deftest agent-shell-push-mode-marks-mode-line-process ()
  "Arming shows a marker in mode-line-process; disarming removes it."
  (agent-shell-push-test--with-env
    (setq mode-line-process '(":%s"))
    (agent-shell-push-mode 1)
    (should (member agent-shell-push-lighter mode-line-process))
    (should (member ":%s" mode-line-process))
    (agent-shell-push-mode -1)
    (should-not (member agent-shell-push-lighter mode-line-process))
    (should (member ":%s" mode-line-process))))

;;; Phone-side control: sidecar + setter

(defvar agent-shell--state nil)

(defmacro agent-shell-push-test--with-sidecar (&rest body)
  "Run BODY with an isolated sidecar file and two fake session buffers."
  (declare (indent 0) (debug t))
  `(let* ((dir (make-temp-file "agent-shell-push-sidecar-" t))
          (agent-shell-push-sidecar-file (expand-file-name "push.json" dir))
          (a (generate-new-buffer "Claude Agent @ a"))
          (b (generate-new-buffer "Codex Agent @ b")))
     (with-current-buffer a
       (setq-local agent-shell--state (list :session (list :id "sess-a"))))
     (with-current-buffer b
       (setq-local agent-shell--state (list :session (list :id "sess-b"))))
     (unwind-protect
         (progn ,@body)
       (when (buffer-live-p a) (kill-buffer a))
       (when (buffer-live-p b) (kill-buffer b))
       (delete-directory dir t))))

(defun agent-shell-push-test--sidecar ()
  "Return the parsed sidecar as an alist, or nil when absent."
  (when (file-exists-p agent-shell-push-sidecar-file)
    (let ((json-object-type 'alist) (json-key-type 'string))
      (with-temp-buffer
        (insert-file-contents agent-shell-push-sidecar-file)
        (json-read-from-string (buffer-string))))))

(ert-deftest agent-shell-push-sidecar-lists-only-armed-sessions ()
  "Arming writes the session id to the sidecar; unarmed sessions are absent."
  (agent-shell-push-test--with-sidecar
    (with-current-buffer a (agent-shell-push-mode 1))
    (let ((sidecar (agent-shell-push-test--sidecar)))
      (should (eq t (alist-get "sess-a" sidecar nil nil #'equal)))
      (should-not (assoc "sess-b" sidecar)))))

(ert-deftest agent-shell-push-sidecar-drops-disarmed-session ()
  "Disarming rewrites the sidecar without that session."
  (agent-shell-push-test--with-sidecar
    (with-current-buffer a (agent-shell-push-mode 1))
    (with-current-buffer b (agent-shell-push-mode 1))
    (with-current-buffer a (agent-shell-push-mode -1))
    (let ((sidecar (agent-shell-push-test--sidecar)))
      (should-not (assoc "sess-a" sidecar))
      (should (eq t (alist-get "sess-b" sidecar nil nil #'equal))))))

(ert-deftest agent-shell-push-sidecar-drops-killed-buffer ()
  "Killing an armed buffer removes its session from the sidecar."
  (agent-shell-push-test--with-sidecar
    (with-current-buffer a (agent-shell-push-mode 1))
    (kill-buffer a)
    (should-not (assoc "sess-a" (agent-shell-push-test--sidecar)))))

(ert-deftest agent-shell-push-set-by-buffer-name ()
  "The phone setter flips the mode by buffer name and reports the new state."
  (agent-shell-push-test--with-sidecar
    (should (equal (agent-shell-push-set "Claude Agent @ a" t) "on"))
    (should (buffer-local-value 'agent-shell-push-mode a))
    (should (equal (agent-shell-push-set "Claude Agent @ a" nil) "off"))
    (should-not (buffer-local-value 'agent-shell-push-mode a))))

(ert-deftest agent-shell-push-set-unknown-buffer-returns-nil ()
  "An unknown buffer name yields nil so acp-mobile can answer 404."
  (agent-shell-push-test--with-sidecar
    (should (null (agent-shell-push-set "nope" t)))))

(provide 'agent-shell-push-test)
;;; agent-shell-push-test.el ends here
