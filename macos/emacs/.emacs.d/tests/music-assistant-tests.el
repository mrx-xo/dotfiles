;;; music-assistant-tests.el --- Tests for native Music Assistant -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Isolated protocol and UI tests for the native Music Assistant dashboard.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'music-assistant-client)
(require 'music-assistant)

(defun music-assistant-test--client (&rest overrides)
  "Return (CLIENT SENT-FUNCTION) built with deterministic OVERRIDES."
  (let (sent)
    (let ((options
           (list
            :server-url "http://music.test:8095"
            :token-provider
            (lambda (success _error)
              (funcall success "fake-token"))
            :on-state-change #'ignore
            :request-timeout 10
            :default-player-name "Desk"
            :open-function
            (lambda (_client _url) 'fake-socket)
            :send-function
            (lambda (_client text) (push text sent))
            :close-function #'ignore
            :schedule-function
            (lambda (_seconds function &rest args)
              (list function args))
            :cancel-function #'ignore)))
      (while overrides
        (setq options
              (plist-put options (pop overrides) (pop overrides))))
      (list (apply #'music-assistant-client-create options)
            (lambda () sent)))))

(defun music-assistant-test--decode (text)
  "Decode Music Assistant JSON TEXT into symbol-keyed alists and lists."
  (json-parse-string text
                     :object-type 'alist
                     :array-type 'list
                     :null-object nil
                     :false-object :false))

(ert-deftest music-assistant-client-websocket-url-normalizes-once ()
  "Catch broken scheme conversion and duplicate /ws suffixes."
  (should
   (equal
    (music-assistant-client-websocket-url "https://music.test/base/")
    "wss://music.test/base/ws"))
  (should
   (equal
    (music-assistant-client-websocket-url "http://music.test:8095/ws")
    "ws://music.test:8095/ws")))

(ert-deftest music-assistant-client-request-serializes-unique-correlated-ids ()
  "Catch reused IDs, missing empty objects, and changed wire keys."
  (pcase-let* ((`(,client ,sent-function)
                (music-assistant-test--client))
               (first
                (music-assistant-client-request
                 client "players/all" nil #'ignore))
               (second
                (music-assistant-client-request
                 client "player_queues/items"
                 '((queue_id . "desk")) #'ignore))
               (messages (funcall sent-function))
               (second-wire
                (music-assistant-test--decode (car messages)))
               (first-text (cadr messages))
               (first-wire
                (music-assistant-test--decode first-text)))
    (should-not (equal first second))
    (should (equal first (alist-get 'message_id first-wire)))
    (should (equal "players/all" (alist-get 'command first-wire)))
    (should (string-match-p "\"args\":{}" first-text))
    (should (equal second (alist-get 'message_id second-wire)))
    (should
     (equal '((queue_id . "desk"))
            (alist-get 'args second-wire)))))

(ert-deftest music-assistant-client-request-correlates-partial-result ()
  "Catch premature callbacks or dropped streamed result chunks."
  (pcase-let* ((`(,client ,_sent-function)
                (music-assistant-test--client))
               (received nil)
               (message-id
                (music-assistant-client-request
                 client "library/tracks" '((limit . 2))
                 (lambda (result) (setq received result)))))
    (music-assistant-client--handle-text
     client
     (json-serialize
      `((message_id . ,message-id)
        (result . [1])
        (partial . t))))
    (should-not received)
    (music-assistant-client--handle-text
     client
     (json-serialize
      `((message_id . ,message-id)
        (result . [2])
        (partial . :false))
      :false-object :false))
    (should (equal received '(1 2)))
    (should
     (= 0 (hash-table-count
           (music-assistant-client-pending client))))))

(ert-deftest music-assistant-client-request-delivers-safe-error-once ()
  "Catch duplicate errbacks and loss of structured server errors."
  (pcase-let* ((`(,client ,_sent-function)
                (music-assistant-test--client))
               (errors nil)
               (message-id
                (music-assistant-client-request
                 client "players/all" nil #'ignore
                 (lambda (error) (push error errors)))))
    (music-assistant-client--handle-text
     client
     (json-serialize
      `((message_id . ,message-id)
        (error_code . 401)
        (details . "Invalid token"))))
    (music-assistant-client--handle-text
     client
     (json-serialize
      `((message_id . ,message-id)
        (error_code . 401)
        (details . "duplicate"))))
    (should (= (length errors) 1))
    (should (equal (car errors)
                   '(:code 401
                     :details "Invalid token"
                     :command "players/all")))))

(ert-deftest music-assistant-client-request-timeout-clears-pending-once ()
  "Catch leaked requests and callbacks firing more than once on timeout."
  (pcase-let* ((`(,client ,_sent-function)
                (music-assistant-test--client))
               (errors nil)
               (message-id
                (music-assistant-client-request
                 client "players/all" nil #'ignore
                 (lambda (error) (push error errors)))))
    (music-assistant-client--request-timeout client message-id)
    (music-assistant-client--request-timeout client message-id)
    (should (= (length errors) 1))
    (should
     (equal
      (car errors)
      '(:code timeout
        :details "Request timed out"
        :command "players/all")))
    (should
     (= 0 (hash-table-count
           (music-assistant-client-pending client))))))

(ert-deftest music-assistant-client-malformed-json-keeps-valid-state ()
  "Catch parser errors escaping callbacks or erasing usable state."
  (pcase-let ((`(,client ,_sent-function)
               (music-assistant-test--client)))
    (setf (music-assistant-client-state client) 'ready)
    (should-not
     (condition-case nil
         (progn
           (music-assistant-client--handle-text client "{broken")
           nil)
       (error t)))
    (should (eq (music-assistant-client-state client) 'ready))
    (should
     (string-match-p
      "malformed"
      (car (music-assistant-client-log-entries client))))))

(ert-deftest music-assistant-client-auth-log-redacts-entire-args ()
  "Catch authentication secrets leaking through sanitized logs."
  (pcase-let ((`(,client ,_sent-function)
               (music-assistant-test--client)))
    (music-assistant-client--log
     client 'send "auth" "emacs-1"
     '((token . "fake-token") (device_name . "Emacs")))
    (let ((line (car (music-assistant-client-log-entries client))))
      (should (string-match-p "<redacted>" line))
      (should-not (string-match-p "fake-token" line))
      (should-not (string-match-p "device_name" line)))))

(ert-deftest music-assistant-client-auth-send-error-redacts-transport-data ()
  "Catch auth frame contents leaking through transport error details."
  (let (received-error)
    (pcase-let
        ((`(,client ,_sent-function)
          (music-assistant-test--client
           :send-function
           (lambda (_client _text)
             (error "closed frame contained fake-token")))))
      (music-assistant-client-request
       client "auth" '((token . "fake-token")) #'ignore
       (lambda (error) (setq received-error error)))
      (should (eq (plist-get received-error :code) 'send-failed))
      (should
       (equal (plist-get received-error :details)
              "Failed to send authentication request"))
      (should-not
       (string-match-p
        "fake-token"
        (mapconcat #'identity
                   (music-assistant-client-log-entries client)
                   "\n"))))))

(ert-deftest music-assistant-client-keychain-command-uses-argument-vector ()
  "Catch shell-based secret retrieval or a changed Keychain identity."
  (should
   (equal
    (music-assistant-client--keychain-command "music-assistant-token")
    '("/usr/bin/security" "find-generic-password" "-w"
      "-a" "emacs" "-s" "music-assistant-token"))))

(ert-deftest music-assistant-client-missing-keychain-token-cleans-buffer ()
  "Catch leaked secret buffers or unsafe diagnostics on lookup failure."
  (let (failure)
    (let ((process
           (music-assistant-client--read-keychain-token
            "music-assistant-test-item-that-does-not-exist"
            (lambda (_token)
              (ert-fail "missing test token unexpectedly resolved"))
            (lambda (message) (setq failure message)))))
      (while (and (processp process) (process-live-p process))
        (accept-process-output process 0.1)))
    (should (equal failure "Music Assistant token missing"))
    (should-not
     (seq-find
      (lambda (buffer)
        (string-prefix-p " *music-assistant-keychain*"
                         (buffer-name buffer)))
      (buffer-list)))))

(provide 'music-assistant-tests)

;;; music-assistant-tests.el ends here
