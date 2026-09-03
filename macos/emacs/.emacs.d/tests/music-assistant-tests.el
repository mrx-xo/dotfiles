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

(ert-deftest music-assistant-default-scheduler-adapts-run-at-time ()
  "Catch timers treating the first callback argument as the function."
  (let (call)
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (seconds repeat function &rest args)
                 (setq call (list seconds repeat function args))
                 'fake-timer)))
      (should
       (eq
        (music-assistant-client--default-schedule
         2 #'ignore 'payload)
        'fake-timer))
      (should (equal call '(2 nil ignore (payload)))))
    (should
     (eq music-assistant--schedule-function
         #'music-assistant-client--default-schedule))))

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
      (while (and (processp process)
                  (not failure)
                  (accept-process-output process 0.1))))
    (unless failure
      (let ((deadline (+ (float-time) 1)))
        (while (and (not failure) (< (float-time) deadline))
          ;; A process may reach `exit' just before Emacs runs its
          ;; sentinel, so continue draining events until the callback.
          (accept-process-output nil 0.01))))
    (should (equal failure "Music Assistant token missing"))
    (should-not
     (seq-find
      (lambda (buffer)
        (string-prefix-p " *music-assistant-keychain*"
                         (buffer-name buffer)))
      (buffer-list)))))

(ert-deftest music-assistant-client-connect-opens-derived-websocket-url ()
  "Catch connection attempts that use HTTP or omit the WebSocket path."
  (let (opened)
    (pcase-let
        ((`(,client ,_sent-function)
          (music-assistant-test--client
           :open-function
           (lambda (_client url)
             (setq opened url)
             'opened-socket))))
      (music-assistant-client-connect client)
      (should (equal opened "ws://music.test:8095/ws"))
      (should (eq (music-assistant-client-websocket client)
                  'opened-socket))
      (should (eq (music-assistant-client-state client)
                  'connecting)))))

(ert-deftest music-assistant-client-authenticates-after-server-info ()
  "Catch auth before server info or failure to bootstrap ready state."
  (pcase-let
      ((`(,client ,sent-function)
        (music-assistant-test--client)))
    (music-assistant-client-connect client)
    (music-assistant-client--handle-text
     client
     "{\"server_id\":\"s\",\"server_version\":\"2.9.13\",
       \"schema_version\":31,\"min_supported_schema_version\":28,
       \"base_url\":\"http://music.test:8095\"}")
    (should (eq (music-assistant-client-state client)
                'authenticating))
    (let* ((auth
            (music-assistant-test--decode
             (car (funcall sent-function))))
           (message-id (alist-get 'message_id auth)))
      (should (equal (alist-get 'command auth) "auth"))
      (should
       (equal (alist-get 'args auth)
              '((token . "fake-token"))))
      (music-assistant-client--handle-text
       client
       (json-serialize
        `((message_id . ,message-id)
          (result . ((authenticated . t)))))))
    (should (eq (music-assistant-client-state client) 'ready))
    (should
     (equal
      (sort
       (mapcar
        (lambda (text)
          (alist-get 'command
                     (music-assistant-test--decode text)))
        (funcall sent-function))
       #'string<)
      '("auth" "player_queues/all" "players/all")))))

(ert-deftest music-assistant-client-incompatible-schema-is-terminal ()
  "Catch commands being sent to a server that dropped schema-31 support."
  (pcase-let
      ((`(,client ,sent-function)
        (music-assistant-test--client)))
    (music-assistant-client-connect client)
    (music-assistant-client--handle-text
     client
     "{\"server_id\":\"s\",\"server_version\":\"3.0\",
       \"schema_version\":40,\"min_supported_schema_version\":32,
       \"base_url\":\"http://music.test:8095\"}")
    (should (eq (music-assistant-client-state client) 'error))
    (should (music-assistant-client-terminal-error-p client))
    (should (string-match-p
             "schema"
             (music-assistant-client-last-error client)))
    (should-not (funcall sent-function))
    (music-assistant-client--handle-close client)
    (should-not (music-assistant-client-reconnect-timer client))))

(ert-deftest music-assistant-client-missing-token-is-terminal ()
  "Catch missing credentials causing an automatic reconnect storm."
  (pcase-let
      ((`(,client ,_sent-function)
        (music-assistant-test--client
         :token-provider
         (lambda (_success error-callback)
           (funcall error-callback
                    "Music Assistant token missing")))))
    (music-assistant-client-connect client)
    (music-assistant-client--handle-text
     client
     "{\"server_id\":\"s\",\"server_version\":\"2.9.13\",
       \"schema_version\":31,\"min_supported_schema_version\":28,
       \"base_url\":\"http://music.test:8095\"}")
    (should (eq (music-assistant-client-state client)
                'auth-required))
    (should (music-assistant-client-terminal-error-p client))
    (music-assistant-client--handle-close client)
    (should-not (music-assistant-client-reconnect-timer client))))

(ert-deftest music-assistant-client-invalid-token-is-terminal ()
  "Catch rejected auth causing retries or bootstrap API commands."
  (pcase-let
      ((`(,client ,sent-function)
        (music-assistant-test--client)))
    (music-assistant-client-connect client)
    (music-assistant-client--handle-text
     client
     "{\"server_id\":\"s\",\"server_version\":\"2.9.13\",
       \"schema_version\":31,\"min_supported_schema_version\":28,
       \"base_url\":\"http://music.test:8095\"}")
    (let* ((auth
            (music-assistant-test--decode
             (car (funcall sent-function))))
           (message-id (alist-get 'message_id auth)))
      (music-assistant-client--handle-text
       client
       (json-serialize
        `((message_id . ,message-id)
          (error_code . 102)
          (details . "Invalid or expired token")))))
    (should (eq (music-assistant-client-state client)
                'auth-required))
    (should (= (length (funcall sent-function)) 1))
    (music-assistant-client--handle-close client)
    (should-not (music-assistant-client-reconnect-timer client))))

(ert-deftest music-assistant-client-auth-drop-reconnects ()
  "Catch a network drop during auth being mistaken for a bad token."
  (let (scheduled)
    (pcase-let
        ((`(,client ,_sent-function)
          (music-assistant-test--client
           :schedule-function
           (lambda (seconds function &rest args)
             (setq scheduled (list seconds function args))
             scheduled))))
      (music-assistant-client-connect client)
      (music-assistant-client--handle-text
       client
       "{\"server_id\":\"s\",\"server_version\":\"2.9.13\",
         \"schema_version\":31,\"min_supported_schema_version\":28,
         \"base_url\":\"http://music.test:8095\"}")
      (should (eq (music-assistant-client-state client)
                  'authenticating))
      (music-assistant-client--handle-close client)
      (should (eq (music-assistant-client-state client)
                  'reconnecting))
      (should-not
       (music-assistant-client-terminal-error-p client))
      (should (= (car scheduled) 1)))))

(ert-deftest music-assistant-client-reconnect-backoff-is-single-and-capped ()
  "Catch duplicate reconnect timers or unbounded retry delays."
  (let (delays)
    (pcase-let
        ((`(,client ,_sent-function)
          (music-assistant-test--client
           :schedule-function
           (lambda (seconds function &rest args)
             (push seconds delays)
             (list seconds function args)))))
      (setf (music-assistant-client-state client) 'ready)
      (dotimes (_ 7)
        (setf (music-assistant-client-reconnect-timer client) nil)
        (music-assistant-client--handle-close client))
      (should (equal (reverse delays)
                     '(1 2 4 8 16 30 30)))
      (setf (music-assistant-client-reconnect-timer client) nil)
      (music-assistant-client--handle-close client)
      (music-assistant-client--handle-close client)
      (should (= (length delays) 8)))))

(ert-deftest music-assistant-client-manual-retry-cancels-delay ()
  "Catch manual retry leaving a delayed duplicate connection behind."
  (let (cancelled opened)
    (pcase-let
        ((`(,client ,_sent-function)
          (music-assistant-test--client
           :open-function
           (lambda (_client url)
             (push url opened)
             'new-socket)
           :cancel-function
           (lambda (timer) (push timer cancelled)))))
      (setf (music-assistant-client-reconnect-timer client) 'old-timer
            (music-assistant-client-reconnect-attempt client) 5
            (music-assistant-client-state client) 'reconnecting)
      (music-assistant-client-retry client)
      (should (equal cancelled '(old-timer)))
      (should (= (music-assistant-client-reconnect-attempt client) 0))
      (should (equal opened '("ws://music.test:8095/ws")))
      (should (eq (music-assistant-client-state client)
                  'connecting)))))

(ert-deftest music-assistant-client-close-cancels-every-resource ()
  "Catch double close, timer leaks, or abandoned pending callbacks."
  (let ((next-timer 0)
        cancelled
        errors
        (close-count 0))
    (pcase-let
        ((`(,client ,_sent-function)
          (music-assistant-test--client
           :schedule-function
           (lambda (_seconds _function &rest _args)
             (cl-incf next-timer))
           :cancel-function
           (lambda (timer) (push timer cancelled))
           :close-function
           (lambda (_client) (cl-incf close-count)))))
      (setf (music-assistant-client-websocket client) 'fake-socket)
      (music-assistant-client-request
       client "players/all" nil #'ignore
       (lambda (error) (push error errors)))
      (setf (music-assistant-client-reconnect-timer client) 99)
      (music-assistant-client-close client)
      (music-assistant-client-close client)
      (should (= close-count 1))
      (should (equal (sort cancelled #'<) '(1 99)))
      (should (= (length errors) 1))
      (should (eq (plist-get (car errors) :code)
                  'disconnected))
      (should
       (= 0 (hash-table-count
             (music-assistant-client-pending client))))
      (should-not
       (music-assistant-client-reconnect-timer client))
      (should (eq (music-assistant-client-state client)
                  'disconnected)))))

(defun music-assistant-test--player (player-id name &rest overrides)
  "Return a realistic player fixture with OVERRIDES."
  (let ((player
         (copy-tree
          `((player_id . ,player-id)
            (provider . "snapcast")
            (type . "player")
            (name . ,name)
            (available . t)
            (device_info
             . ((model . "Snapclient")
                (manufacturer . "Snapcast")))
            (supported_features . ["pause" "volume_set"])
            (playback_state . "idle")
            (elapsed_time . 0)
            (elapsed_time_last_updated . 0)
            (powered . t)
            (volume_level . 50)
            (volume_muted . :false)
            (active_source)
            (enabled . t)
            (hide_in_ui . :false)))))
    (while overrides
      (setf (alist-get (pop overrides) player)
            (pop overrides)))
    player))

(defun music-assistant-test--queue
    (queue-id name &rest overrides)
  "Return a realistic queue fixture with OVERRIDES."
  (let ((queue
         (copy-tree
          `((queue_id . ,queue-id)
            (active . t)
            (display_name . ,name)
            (available . t)
            (items . 0)
            (shuffle_enabled . :false)
            (repeat_mode . "off")
            (current_index)
            (elapsed_time . 0)
            (elapsed_time_last_updated . 0)
            (playback_speed . 1.0)
            (state . "idle")
            (current_item)
            (next_item)
            (flow_mode . :false)
            (resume_pos . 0)))))
    (while overrides
      (setf (alist-get (pop overrides) queue)
            (pop overrides)))
    queue))

(defun music-assistant-test--queue-item
    (queue-id item-id name &rest overrides)
  "Return a realistic queue item fixture with OVERRIDES."
  (let ((item
         (copy-tree
          `((queue_id . ,queue-id)
            (queue_item_id . ,item-id)
            (name . ,name)
            (duration . 180)
            (sort_index . 0)
            (media_item)
            (image)
            (index . 0)
            (available . t)))))
    (while overrides
      (setf (alist-get (pop overrides) item)
            (pop overrides)))
    item))

(ert-deftest music-assistant-client-player-fallback-order-is-stable ()
  "Catch room hopping or fallback order changes."
  (pcase-let ((`(,client ,_sent-function)
               (music-assistant-test--client
                :default-player-name "MrX.local")))
    (setf
     (music-assistant-client-players client)
     (list
      (music-assistant-test--player "kitchen" "Kitchen")
      (music-assistant-test--player "desk" "MrX.local")
      (music-assistant-test--player "saved" "Saved"))
     (music-assistant-client-selected-player-id client) "saved")
    (music-assistant-client--select-fallback-player client)
    (should
     (equal (music-assistant-client-selected-player-id client)
            "saved"))
    (setf (music-assistant-client-selected-player-id client)
          "missing")
    (music-assistant-client--select-fallback-player client)
    (should
     (equal (music-assistant-client-selected-player-id client)
            "desk"))
    (setf
     (music-assistant-client-players client)
     (list
      (music-assistant-test--player "zeta" "zeta")
      (music-assistant-test--player
       "desk" "MrX.local" 'available :false)
      (music-assistant-test--player "alpha" "Alpha"))
     (music-assistant-client-selected-player-id client) nil)
    (music-assistant-client--select-fallback-player client)
    (should
     (equal (music-assistant-client-selected-player-id client)
            "alpha"))))

(ert-deftest music-assistant-client-player-fallback-excludes-hidden-disabled ()
  "Catch unavailable or hidden players becoming control targets."
  (pcase-let ((`(,client ,_sent-function)
               (music-assistant-test--client)))
    (setf
     (music-assistant-client-players client)
     (list
      (music-assistant-test--player
       "offline" "Offline" 'available :false)
      (music-assistant-test--player
       "disabled" "Disabled" 'enabled :false)
      (music-assistant-test--player
       "hidden" "Hidden" 'hide_in_ui t)))
    (music-assistant-client--select-fallback-player client)
    (should-not
     (music-assistant-client-selected-player-id client))
    (should-not
     (music-assistant-client-selected-queue-id client))))

(ert-deftest music-assistant-client-resolves-active-queue-and-fetches-items ()
  "Catch controls targeting a player's stale or unrelated queue."
  (pcase-let ((`(,client ,sent-function)
               (music-assistant-test--client)))
    (setf
     (music-assistant-client-players client)
     (list
      (music-assistant-test--player
       "desk" "MrX.local" 'active_source "desk-queue"))
     (music-assistant-client-queues client)
     (list
      (music-assistant-test--queue "desk" "Desk fallback")
      (music-assistant-test--queue "desk-queue" "Desk active")))
    (music-assistant-client--resolve-selection client)
    (should
     (equal (music-assistant-client-selected-player-id client)
            "desk"))
    (should
     (equal (music-assistant-client-selected-queue-id client)
            "desk-queue"))
    (let ((wire
           (music-assistant-test--decode
            (car (funcall sent-function)))))
      (should
       (equal (alist-get 'command wire)
              "player_queues/items"))
      (should
       (equal (alist-get 'args wire)
              '((queue_id . "desk-queue")))))
    (setf
     (music-assistant-client-players client)
     (list
      (music-assistant-test--player
       "desk" "MrX.local" 'active_source "unknown"))
     (music-assistant-client-selected-player-id client) "desk"
     (music-assistant-client-selected-queue-id client) nil
     (music-assistant-client-queue-items-queue-id client) nil)
    (music-assistant-client--resolve-selection client)
    (should
     (equal (music-assistant-client-selected-queue-id client)
            "desk"))))

(ert-deftest music-assistant-client-player-events-reconcile-and-fallback ()
  "Catch event updates duplicating players or retaining a removed target."
  (pcase-let ((`(,client ,_sent-function)
               (music-assistant-test--client)))
    (setf
     (music-assistant-client-players client)
     (list
      (music-assistant-test--player "desk" "MrX.local")
      (music-assistant-test--player "kitchen" "Kitchen"))
     (music-assistant-client-selected-player-id client) "desk")
    (music-assistant-client--handle-text
     client
     (json-serialize
      `((event . "player_updated")
        (object_id . "desk")
        (data
         . ,(music-assistant-test--player
             "desk" "Desk renamed" 'volume_level 73)))
      :false-object :false))
    (should (= (length (music-assistant-client-players client)) 2))
    (should
     (= (alist-get
         'volume_level
         (music-assistant-client-player client "desk"))
        73))
    (music-assistant-client--handle-text
     client
     "{\"event\":\"player_removed\",\"object_id\":\"desk\",
       \"data\":null}")
    (should-not (music-assistant-client-player client "desk"))
    (should
     (equal (music-assistant-client-selected-player-id client)
            "kitchen"))))

(ert-deftest music-assistant-client-queue-events-reconcile-authoritative-data ()
  "Catch queue events being ignored or applied to the wrong object."
  (pcase-let ((`(,client ,_sent-function)
               (music-assistant-test--client)))
    (setf
     (music-assistant-client-queues client)
     (list (music-assistant-test--queue "desk" "Desk"))
     (music-assistant-client-selected-queue-id client) "desk")
    (music-assistant-client--handle-text
     client
     (json-serialize
      `((event . "queue_updated")
        (object_id . "desk")
        (data
         . ,(music-assistant-test--queue
             "desk" "Desk" 'state "playing"
             'elapsed_time 42)))
      :false-object :false))
    (should (= (length (music-assistant-client-queues client)) 1))
    (should
     (equal
      (alist-get 'state
                 (music-assistant-client-selected-queue client))
      "playing"))
    (should
     (= (alist-get 'elapsed_time
                   (music-assistant-client-selected-queue client))
        42))))

(ert-deftest music-assistant-client-queue-time-event-updates-only-target ()
  "Catch elapsed-time events replacing queue metadata or another queue."
  (pcase-let ((`(,client ,_sent-function)
               (music-assistant-test--client)))
    (setf
     (music-assistant-client-queues client)
     (list
      (music-assistant-test--queue "desk" "Desk" 'elapsed_time 3)
      (music-assistant-test--queue "kitchen" "Kitchen"
                                   'elapsed_time 8))
     (music-assistant-client-selected-queue-id client) "desk")
    (music-assistant-client--handle-text
     client
     "{\"event\":\"queue_time_updated\",\"object_id\":\"desk\",
       \"data\":51.5}")
    (should
     (= (alist-get 'elapsed_time
                   (music-assistant-client-queue client "desk"))
        51.5))
    (should
     (equal
      (alist-get 'display_name
                 (music-assistant-client-queue client "desk"))
      "Desk"))
    (should
     (= (alist-get 'elapsed_time
                   (music-assistant-client-queue client "kitchen"))
        8))
    (should
     (numberp
      (music-assistant-client-queue-time-received-at client)))))

(ert-deftest music-assistant-client-queue-items-event-refetches-selected-only ()
  "Catch event storms fetching queue items for every room."
  (pcase-let ((`(,client ,sent-function)
               (music-assistant-test--client)))
    (setf (music-assistant-client-selected-queue-id client) "desk")
    (let ((before (length (funcall sent-function))))
      (music-assistant-client--handle-text
       client
       "{\"event\":\"queue_items_updated\",
         \"object_id\":\"kitchen\",\"data\":null}")
      (should (= (length (funcall sent-function)) before))
      (music-assistant-client--handle-text
       client
       "{\"event\":\"queue_items_updated\",
         \"object_id\":\"desk\",\"data\":null}")
      (should (= (length (funcall sent-function))
                 (1+ before)))
      (should
       (equal
        (alist-get
         'command
         (music-assistant-test--decode
          (car (funcall sent-function))))
        "player_queues/items")))))

(ert-deftest music-assistant-client-search-normalizes-track-results ()
  "Catch search using the wrong media scope or returning non-track groups."
  (pcase-let ((`(,client ,sent-function)
               (music-assistant-test--client)))
    (let (tracks)
      (music-assistant-client-search-tracks
       client "bladee"
       (lambda (result) (setq tracks result))
       #'ignore)
      (let* ((wire
              (music-assistant-test--decode
               (car (funcall sent-function))))
             (message-id (alist-get 'message_id wire)))
        (should (equal (alist-get 'command wire) "music/search"))
        (should
         (equal
          (alist-get 'args wire)
          '((search_query . "bladee")
            (media_types . ("track"))
            (limit . 25)
            (library_only . :false))))
        (music-assistant-client--handle-text
         client
         (json-serialize
          `((message_id . ,message-id)
            (result
             . ((artists . [])
                (albums . [])
                (tracks
                 . [((item_id . "track-1")
                     (provider . "spotify")
                     (name . "Be Nice 2 Me")
                     (uri . "spotify://track/track-1")
                     (provider_mappings . []))]))))
          :false-object :false)))
      (should (= (length tracks) 1))
      (should
       (equal (alist-get 'uri (car tracks))
              "spotify://track/track-1")))))

(ert-deftest music-assistant-client-playback-commands-use-selected-queue ()
  "Catch controls sending legacy commands or the player ID as queue ID."
  (pcase-let ((`(,client ,sent-function)
               (music-assistant-test--client)))
    (setf (music-assistant-client-selected-player-id client) "desk"
          (music-assistant-client-selected-queue-id client) "desk-queue")
    (music-assistant-client-play-media
     client "spotify://track/track-1")
    (music-assistant-client-play-index client "queue-item-4")
    (music-assistant-client-play-pause client)
    (music-assistant-client-previous client)
    (music-assistant-client-next client)
    (let ((wires
           (mapcar #'music-assistant-test--decode
                   (reverse (funcall sent-function)))))
      (should
       (equal
        (mapcar (lambda (wire) (alist-get 'command wire)) wires)
        '("player_queues/play_media"
          "player_queues/play_index"
          "player_queues/play_pause"
          "player_queues/previous"
          "player_queues/next")))
      (should
       (equal
        (alist-get 'args (nth 0 wires))
        '((queue_id . "desk-queue")
          (media . "spotify://track/track-1")
          (option . "replace"))))
      (should
       (equal
        (alist-get 'args (nth 1 wires))
        '((queue_id . "desk-queue")
          (index . "queue-item-4")))))))

(ert-deftest music-assistant-client-seek-and-volume-clamp-boundaries ()
  "Catch relative seek and volume escaping authoritative bounds."
  (pcase-let ((`(,client ,sent-function)
               (music-assistant-test--client)))
    (let* ((item
            (music-assistant-test--queue-item
             "desk" "item-1" "Track" 'duration 100))
           (queue
            (music-assistant-test--queue
             "desk" "Desk" 'state "paused"
             'elapsed_time 95 'current_item item)))
      (setf
       (music-assistant-client-selected-player-id client) "desk"
       (music-assistant-client-selected-queue-id client) "desk"
       (music-assistant-client-players client)
       (list
        (music-assistant-test--player
         "desk" "MrX.local" 'volume_level 98))
       (music-assistant-client-queues client) (list queue))
      (music-assistant-client-seek-relative client 10)
      (music-assistant-client-set-volume client 108)
      (let ((wires
             (mapcar #'music-assistant-test--decode
                     (reverse (funcall sent-function)))))
        (should
         (equal (alist-get 'args (car wires))
                '((queue_id . "desk")
                  (position . 100))))
        (should
         (equal (alist-get 'args (cadr wires))
                '((player_id . "desk")
                  (volume_level . 100))))))))

(defun music-assistant-test--media-item ()
  "Return a realistic current-track media item."
  '((uri . "library://track/bladee-1")
    (name . "Be Nice 2 Me")
    (provider . "spotify")
    (artists . (((name . "Bladee"))
                ((name . "Ecco2k"))))
    (album . ((name . "Icedancer")
              (year . 2018)))))

(defun music-assistant-test--ready-client ()
  "Return a ready client populated with dashboard fixtures."
  (pcase-let ((`(,client ,_sent-function)
               (music-assistant-test--client
                :default-player-name "MrX.local")))
    (let* ((media (music-assistant-test--media-item))
           (current
            (music-assistant-test--queue-item
             "desk" "item-1" "Be Nice 2 Me"
             'duration 198 'media_item media 'index 0))
           (next
            (music-assistant-test--queue-item
             "desk" "item-2" "Side by Side"
             'duration 215 'index 1)))
      (setf
       (music-assistant-client-state client) 'ready
       (music-assistant-client-players client)
       (list
        (music-assistant-test--player
         "desk" "MrX.local" 'volume_level 73))
       (music-assistant-client-selected-player-id client) "desk"
       (music-assistant-client-queues client)
       (list
        (music-assistant-test--queue
         "desk" "MrX.local" 'state "playing"
         'elapsed_time 102 'current_item current
         'current_index 0))
       (music-assistant-client-selected-queue-id client) "desk"
       (music-assistant-client-queue-items client)
       (list current next)
       (music-assistant-client-queue-items-queue-id client) "desk"
       (music-assistant-client-queue-time-received-at client)
       (float-time)))
    client))

(defun music-assistant-test--ui-buffer (&optional client)
  "Return a temporary dashboard buffer owning CLIENT."
  (let ((buffer (generate-new-buffer " *music-assistant-ui-test*")))
    (with-current-buffer buffer
      (music-assistant-mode)
      (setq-local music-assistant--client
                  (or client (music-assistant-test--ready-client))))
    buffer))

(defun music-assistant-test--face-at-item-p
    (buffer item-id face)
  "Return non-nil when ITEM-ID in BUFFER includes FACE."
  (with-current-buffer buffer
    (when-let ((position (music-assistant-test--item-position
                          buffer item-id)))
      (memq face
            (ensure-list
             (get-text-property position 'face))))))

(defun music-assistant-test--item-position (buffer item-id)
  "Return the first BUFFER position whose queue ID equals ITEM-ID."
  (with-current-buffer buffer
    (let ((position (point-min))
          found)
      (while (and (< position (point-max)) (not found))
        (when (equal
               (get-text-property
                position 'music-assistant-queue-item-id)
               item-id)
          (setq found position))
        (setq position
              (or (next-single-property-change
                   position 'music-assistant-queue-item-id nil
                   (point-max))
                  (point-max))))
      found)))

(ert-deftest music-assistant-ui-renders-connection-states ()
  "Catch connection failures disappearing behind a blank dashboard."
  (dolist (scenario
           '((connecting nil "Connecting")
             (authenticating nil "Authenticating")
             (auth-required "Token missing" "Keychain")
             (reconnecting "Socket closed" "Reconnecting")
             (error "Schema mismatch" "Schema mismatch")))
    (pcase-let* ((`(,state ,details ,expected) scenario)
                 (client (music-assistant-test--ready-client))
                 (buffer (music-assistant-test--ui-buffer client)))
      (unwind-protect
          (progn
            (setf (music-assistant-client-state client) state
                  (music-assistant-client-last-error client) details)
            (with-current-buffer buffer
              (music-assistant--render)
              (should (string-match-p expected (buffer-string)))
              (should (null mode-line-format))
              (should (string-match-p
                       (downcase (symbol-name state))
                       (downcase (format "%s" header-line-format))))))
        (kill-buffer buffer)))))

(ert-deftest music-assistant-ui-renders-ready-metadata-and-queue ()
  "Catch loss of native dashboard metadata or stable row properties."
  (let* ((client (music-assistant-test--ready-client))
         (buffer (music-assistant-test--ui-buffer client)))
    (unwind-protect
        (with-current-buffer buffer
          (setq-local music-assistant--selected-queue-item-id "item-2")
          (music-assistant--render)
          (let ((text (buffer-string)))
            (dolist (expected
                     '("Music Assistant" "MrX.local" "Be Nice 2 Me"
                       "Bladee" "Ecco2k" "Icedancer" "2018"
                       "01:42" "03:18" "73%" "playing" "Queue"))
              (should (string-match-p expected text))))
          (should (music-assistant-test--item-position
                   buffer "item-1"))
          (should (music-assistant-test--item-position
                   buffer "item-2"))
          (should
           (music-assistant-test--face-at-item-p
            buffer "item-1" 'music-assistant-current-item-face))
          (should
           (music-assistant-test--face-at-item-p
            buffer "item-2" 'music-assistant-selection-face)))
      (kill-buffer buffer))))

(ert-deftest music-assistant-ui-renders-ready-empty-states ()
  "Catch ready clients with partial state rendering as usable."
  (let* ((client (music-assistant-test--ready-client))
         (buffer (music-assistant-test--ui-buffer client)))
    (unwind-protect
        (with-current-buffer buffer
          (setf (music-assistant-client-players client) nil
                (music-assistant-client-selected-player-id client) nil
                (music-assistant-client-selected-queue-id client) nil)
          (music-assistant--render)
          (should (string-match-p "No available player"
                                  (buffer-string)))
          (setf (music-assistant-client-players client)
                (list
                 (music-assistant-test--player
                  "desk" "MrX.local"))
                (music-assistant-client-selected-player-id client)
                "desk")
          (music-assistant--render)
          (should (string-match-p "No active queue"
                                  (buffer-string))))
      (kill-buffer buffer))))

(ert-deftest music-assistant-ui-preserves-stable-queue-selection ()
  "Catch event rerenders making keyboard selection jump unpredictably."
  (let* ((client (music-assistant-test--ready-client))
         (buffer (music-assistant-test--ui-buffer client))
         (first (car (music-assistant-client-queue-items client)))
         (second (cadr (music-assistant-client-queue-items client)))
         (third
          (music-assistant-test--queue-item
           "desk" "item-3" "SmartWater" 'index 2)))
    (unwind-protect
        (with-current-buffer buffer
          (music-assistant--render)
          (should (equal music-assistant--selected-queue-item-id
                         "item-1"))
          (setq music-assistant--selected-queue-item-id "item-2")
          (music-assistant--render)
          (should (equal music-assistant--selected-queue-item-id
                         "item-2"))
          (setf (music-assistant-client-queue-items client)
                (list first third))
          (music-assistant--render)
          (should (equal music-assistant--selected-queue-item-id
                         "item-1"))
          (setf
           (music-assistant-client-queue-items client)
           (list second third)
           (alist-get
            'current_item
            (music-assistant-client-selected-queue client))
           nil)
          (music-assistant--render)
          (should (equal music-assistant--selected-queue-item-id
                         "item-2")))
      (kill-buffer buffer))))

(ert-deftest music-assistant-ui-keymap-exposes-native-controls ()
  "Catch dashboard controls becoming unreachable from motion state."
  (dolist (binding
           '(("SPC" . music-assistant-play-pause)
             ("p" . music-assistant-previous)
             ("n" . music-assistant-next)
             ("h" . music-assistant-seek-backward)
             ("l" . music-assistant-seek-forward)
             ("-" . music-assistant-volume-down)
             ("+" . music-assistant-volume-up)
             ("=" . music-assistant-volume-up)
             ("j" . music-assistant-queue-next)
             ("k" . music-assistant-queue-previous)
             ("RET" . music-assistant-play-selected)
             ("s" . music-assistant-search)
             ("P" . music-assistant-choose-player)
             ("g" . music-assistant-refresh)
             ("?" . describe-mode)
             ("q" . music-assistant-quit)))
    (should (eq (lookup-key music-assistant-mode-map
                            (kbd (car binding)))
                (cdr binding)))))

(ert-deftest music-assistant-ui-queue-movement-and-play-use-stable-id ()
  "Catch queue commands relying on row position rather than stable IDs."
  (let* ((client (music-assistant-test--ready-client))
         (buffer (music-assistant-test--ui-buffer client))
         played)
    (unwind-protect
        (with-current-buffer buffer
          (music-assistant--render)
          (music-assistant-queue-next)
          (should (equal music-assistant--selected-queue-item-id
                         "item-2"))
          (music-assistant-queue-next)
          (should (equal music-assistant--selected-queue-item-id
                         "item-2"))
          (music-assistant-queue-previous)
          (should (equal music-assistant--selected-queue-item-id
                         "item-1"))
          (cl-letf (((symbol-function
                      'music-assistant-client-play-index)
                     (lambda (actual-client item-id)
                       (setq played (list actual-client item-id)))))
            (music-assistant-play-selected))
          (should (equal played (list client "item-1"))))
      (kill-buffer buffer))))

(ert-deftest music-assistant-ui-search-formats-and-plays-canonical-uri ()
  "Catch search becoming blocking or handing display text to playback."
  (let* ((client (music-assistant-test--ready-client))
         (buffer (music-assistant-test--ui-buffer client))
         search-callback
         candidate-seen
         played-uri)
    (unwind-protect
        (with-current-buffer buffer
          (let ((music-assistant--schedule-function
                 (lambda (seconds function &rest args)
                   (if (zerop seconds)
                       (apply function args)
                     'progress-timer))))
            (cl-letf (((symbol-function 'read-string)
                       (lambda (&rest _args) "   ")))
              (should-error (music-assistant-search)
                            :type 'user-error))
            (cl-letf
                (((symbol-function 'read-string)
                  (lambda (&rest _args) "Bladee"))
                 ((symbol-function
                   'music-assistant-client-search-tracks)
                  (lambda (actual-client query callback _errback)
                    (should (eq actual-client client))
                    (should (equal query "Bladee"))
                    (setq search-callback callback)))
                 ((symbol-function 'completing-read)
                  (lambda (_prompt collection &rest _args)
                    (setq candidate-seen (caar collection))
                    candidate-seen))
                 ((symbol-function 'music-assistant-client-play-media)
                  (lambda (actual-client uri)
                    (should (eq actual-client client))
                    (setq played-uri uri))))
              (music-assistant-search)
              (should (string-match-p
                       "searching..."
                       (format "%s" header-line-format)))
              (funcall
               search-callback
               (list
                '((name . "Obedient")
                  (uri . "library://track/obedient")
                  (provider . "spotify")
                  (artists . (((name . "Bladee"))))
                  (album . ((name . "Red Light")))))))
            (should (equal candidate-seen
                           "Obedient — Bladee — Red Light [spotify]"))
            (should (equal played-uri
                           "library://track/obedient"))))
      (kill-buffer buffer))))

(ert-deftest music-assistant-ui-search-empty-results-do-not-play ()
  "Catch empty search results mutating the authoritative queue."
  (let* ((client (music-assistant-test--ready-client))
         (buffer (music-assistant-test--ui-buffer client))
         search-callback
         message-seen
         played)
    (unwind-protect
        (with-current-buffer buffer
          (let ((music-assistant--schedule-function
                 (lambda (seconds function &rest args)
                   (if (zerop seconds)
                       (apply function args)
                     'progress-timer))))
            (cl-letf
                (((symbol-function 'read-string)
                  (lambda (&rest _args) "nothing"))
                 ((symbol-function
                   'music-assistant-client-search-tracks)
                  (lambda (_client _query callback _errback)
                    (setq search-callback callback)))
                 ((symbol-function 'message)
                  (lambda (format-string &rest args)
                    (setq message-seen
                          (apply #'format format-string args))))
                 ((symbol-function 'music-assistant-client-play-media)
                  (lambda (&rest _args) (setq played t))))
              (music-assistant-search)
              (funcall search-callback nil)))
          (should (equal message-seen "No tracks found"))
          (should-not played)
          (should-not music-assistant--searching-p))
      (kill-buffer buffer))))

(ert-deftest music-assistant-ui-player-picker-persists-selection ()
  "Catch the player picker failing to hand off or remember its target."
  (let* ((client (music-assistant-test--ready-client))
         (buffer (music-assistant-test--ui-buffer client))
         (music-assistant-last-player-id nil)
         selected
         saved)
    (setf
     (music-assistant-client-players client)
     (append
      (music-assistant-client-players client)
      (list
       (music-assistant-test--player "kitchen" "Kitchen")
       (music-assistant-test--player
        "offline" "Offline" 'available :false))))
    (unwind-protect
        (with-current-buffer buffer
          (cl-letf
              (((symbol-function 'completing-read)
                (lambda (_prompt collection &rest _args)
                  (should (assoc "Kitchen [snapcast]" collection))
                  (should-not
                   (assoc "Offline [snapcast]" collection))
                  "Kitchen [snapcast]"))
               ((symbol-function 'music-assistant-client-select-player)
                (lambda (actual-client player-id)
                  (should (eq actual-client client))
                  (setq selected player-id)))
               ((symbol-function 'savehist-save)
                (lambda () (setq saved t))))
            (music-assistant-choose-player))
          (should (equal selected "kitchen"))
          (should (equal music-assistant-last-player-id "kitchen"))
          (should saved))
      (kill-buffer buffer))))

(ert-deftest music-assistant-ui-controls-delegate-without-optimism ()
  "Catch UI controls mutating display state before server events arrive."
  (let* ((client (music-assistant-test--ready-client))
         (buffer (music-assistant-test--ui-buffer client))
         calls)
    (unwind-protect
        (with-current-buffer buffer
          (music-assistant--render)
          (let ((before (buffer-string)))
            (cl-letf
                (((symbol-function 'music-assistant-client-play-pause)
                  (lambda (actual) (push (list 'toggle actual) calls)))
                 ((symbol-function 'music-assistant-client-previous)
                  (lambda (actual) (push (list 'previous actual) calls)))
                 ((symbol-function 'music-assistant-client-next)
                  (lambda (actual) (push (list 'next actual) calls)))
                 ((symbol-function
                   'music-assistant-client-seek-relative)
                  (lambda (actual delta)
                    (push (list 'seek actual delta) calls)))
                 ((symbol-function 'music-assistant-client-set-volume)
                  (lambda (actual level)
                    (push (list 'volume actual level) calls)))
                 ((symbol-function 'music-assistant-client-refresh)
                  (lambda (actual) (push (list 'refresh actual) calls))))
              (music-assistant-play-pause)
              (music-assistant-previous)
              (music-assistant-next)
              (music-assistant-seek-backward)
              (music-assistant-seek-forward)
              (music-assistant-volume-down)
              (music-assistant-volume-up)
              (music-assistant-refresh))
            (should (equal before (buffer-string))))
          (should
           (equal
            (reverse calls)
            (list
             (list 'toggle client)
             (list 'previous client)
             (list 'next client)
             (list 'seek client -10)
             (list 'seek client 10)
             (list 'volume client 68)
             (list 'volume client 78)
             (list 'refresh client)))))
      (kill-buffer buffer))))

(ert-deftest music-assistant-ui-reuses-buffer-and-retries-client ()
  "Catch reopening the dashboard leaking clients or duplicate buffers."
  (when-let ((existing (get-buffer "*Music Assistant*")))
    (kill-buffer existing))
  (let ((client (music-assistant-test--ready-client))
        (created 0)
        (connected 0)
        (retried 0)
        first second)
    (setf (music-assistant-client-state client) 'disconnected)
    (unwind-protect
        (save-window-excursion
          (cl-letf
              (((symbol-function 'music-assistant-client-create)
                (lambda (&rest _args)
                  (cl-incf created)
                  client))
               ((symbol-function 'music-assistant-client-connect)
                (lambda (actual)
                  (should (eq actual client))
                  (cl-incf connected)))
               ((symbol-function 'music-assistant-client-retry)
                (lambda (actual)
                  (should (eq actual client))
                  (cl-incf retried))))
            (setq first (music-assistant))
            (setf (music-assistant-client-state client) 'error)
            (setq second (music-assistant))))
      (when (buffer-live-p first)
        (kill-buffer first)))
    (should (eq first second))
    (should (= created 1))
    (should (= connected 1))
    (should (= retried 1))))

(defun music-assistant-test--set-current-image
    (client proxy-id &optional item-id)
  "Give CLIENT's current ITEM-ID an image with PROXY-ID."
  (let* ((queue (music-assistant-client-selected-queue client))
         (current (copy-tree
                   (music-assistant-client-current-item client)))
         (wanted-id (or item-id
                        (music-assistant--item-id current))))
    (setf (alist-get 'queue_item_id current) wanted-id
          (alist-get 'image current) `((proxy_id . ,proxy-id))
          (alist-get 'current_item queue) current)
    current))

(ert-deftest music-assistant-ui-progress-timer-tracks-playing-state ()
  "Catch progress timers leaking while paused, disconnected, or killed."
  (let* ((client (music-assistant-test--ready-client))
         (buffer (music-assistant-test--ui-buffer client))
         scheduled
         cancelled)
    (unwind-protect
        (with-current-buffer buffer
          (let ((music-assistant--schedule-function
                 (lambda (seconds function &rest args)
                   (setq scheduled (list seconds function args))
                   'progress-timer))
                (music-assistant--cancel-function
                 (lambda (timer) (push timer cancelled))))
            (music-assistant--render)
            (should (equal music-assistant--progress-timer
                           'progress-timer))
            (should (= (car scheduled) 1))
            (setf
             (alist-get
              'state (music-assistant-client-selected-queue client))
             "paused")
            (music-assistant--render)
            (should-not music-assistant--progress-timer)
            (should (equal cancelled '(progress-timer)))
            (setf
             (alist-get
              'state (music-assistant-client-selected-queue client))
             "playing"
             (music-assistant-client-state client) 'reconnecting)
            (music-assistant--render)
            (should-not music-assistant--progress-timer)))
      (kill-buffer buffer))))

(ert-deftest music-assistant-ui-progress-update-is-in-place ()
  "Catch one-second progress updates rebuilding queue state or moving point."
  (let* ((client (music-assistant-test--ready-client))
         (buffer (music-assistant-test--ui-buffer client)))
    (unwind-protect
        (with-current-buffer buffer
          (let ((music-assistant--schedule-function
                 (lambda (&rest _args) 'progress-timer)))
            (music-assistant--render)
            (goto-char
             (music-assistant-test--item-position buffer "item-2"))
            (let ((point-marker (copy-marker (point)))
                  (queue-before
                   (buffer-substring-no-properties
                    (line-beginning-position) (line-end-position))))
              (setf
               (alist-get
                'elapsed_time
                (music-assistant-client-selected-queue client))
               103
               (music-assistant-client-queue-time-received-at client)
               (float-time))
              (music-assistant--update-progress buffer client)
              (should (string-match-p "01:43" (buffer-string)))
              (should (equal queue-before
                             (buffer-substring-no-properties
                              (line-beginning-position)
                              (line-end-position))))
              (should (= (point) point-marker))
              (set-marker point-marker nil))))
      (kill-buffer buffer))))

(ert-deftest music-assistant-ui-derived-elapsed-advances-and-clamps ()
  "Catch local progress ignoring speed, pause state, or track duration."
  (let* ((client (music-assistant-test--ready-client))
         (queue (music-assistant-client-selected-queue client))
         (current (music-assistant-client-current-item client)))
    (setf (alist-get 'elapsed_time queue) 190
          (alist-get 'playback_speed queue) 2.0
          (alist-get 'duration current) 198
          (music-assistant-client-queue-time-received-at client) 100)
    (cl-letf (((symbol-function 'float-time)
               (lambda (&optional _time) 105)))
      (should (= (music-assistant-client-current-elapsed client) 198))
      (setf (alist-get 'duration current) 300)
      (should (= (music-assistant-client-current-elapsed client) 200))
      (setf (alist-get 'state queue) "paused")
      (should (= (music-assistant-client-current-elapsed client) 190)))))

(ert-deftest music-assistant-ui-artwork-proxy-url-is-schema-31 ()
  "Catch image requests using an obsolete endpoint or unsupported size."
  (let* ((client (music-assistant-test--ready-client))
         (item (music-assistant-test--set-current-image client "abc")))
    (should
     (equal (music-assistant--artwork-url client item)
            "http://music.test:8095/imageproxy/abc?size=256"))))

(ert-deftest music-assistant-ui-artwork-success-caches-final-url ()
  "Catch artwork redirects being refetched or response buffers leaking."
  (let* ((client (music-assistant-test--ready-client))
         (_item (music-assistant-test--set-current-image client "abc"))
         (buffer (music-assistant-test--ui-buffer client))
         (music-assistant--artwork-cache
          (make-hash-table :test #'equal))
         response-buffer
         image-data)
    (unwind-protect
        (with-current-buffer buffer
          (let ((music-assistant--schedule-function
                 (lambda (&rest _args) 'progress-timer))
                (music-assistant--url-retrieve-function
                 (lambda (_url callback callback-args &rest _ignored)
                   (setq response-buffer
                         (generate-new-buffer
                          " *music-assistant-art-success*"))
                   (with-current-buffer response-buffer
                     (set-buffer-multibyte nil)
                     (insert "HTTP/1.1 200 OK\r\n\r\nPNG-DATA")
                     ;; `url-retrieve' leaves this marker on the final
                     ;; header newline, immediately before the body.
                     (setq-local url-http-end-of-headers 19
                                 url-current-object
                                 (url-generic-parse-url
                                  "http://cdn.test/final.png"))
                     (apply callback nil callback-args))
                   response-buffer))
                (music-assistant--create-image-function
                 (lambda (data &rest _args)
                   (setq image-data data)
                   'fake-image)))
            (music-assistant--render)
            (should (equal image-data "PNG-DATA"))
            (should
             (equal
              (plist-get
               (gethash "http://cdn.test/final.png"
                        music-assistant--artwork-cache)
               :image)
              'fake-image))
            (should (equal music-assistant--artwork-image
                           'fake-image))
            (should-not (buffer-live-p response-buffer))))
      (when (buffer-live-p response-buffer)
        (kill-buffer response-buffer))
      (kill-buffer buffer))))

(ert-deftest music-assistant-ui-artwork-failure-backs-off ()
  "Catch broken artwork hammering the server or disabling controls."
  (let* ((client (music-assistant-test--ready-client))
         (item (music-assistant-test--set-current-image client "bad"))
         (url (music-assistant--artwork-url client item))
         (buffer (music-assistant-test--ui-buffer client))
         (music-assistant--artwork-cache
          (make-hash-table :test #'equal))
         (requests 0)
         responses)
    (unwind-protect
        (with-current-buffer buffer
          (let ((music-assistant--schedule-function
                 (lambda (&rest _args) 'progress-timer))
                (music-assistant--url-retrieve-function
                 (lambda (_url callback callback-args &rest _ignored)
                   (cl-incf requests)
                   (let ((response
                          (generate-new-buffer
                           " *music-assistant-art-failure*")))
                     (push response responses)
                     (with-current-buffer response
                       (apply callback
                              '(:error (error . "broken"))
                              callback-args))
                     response))))
            (music-assistant--render)
            (music-assistant--render)
            (should (= requests 1))
            (should (string-match-p "\[no artwork\]"
                                    (buffer-string)))
            (should (eq (lookup-key music-assistant-mode-map
                                    (kbd "SPC"))
                        #'music-assistant-play-pause))
            (puthash url
                     (list :failed-at (- (float-time) 31))
                     music-assistant--artwork-cache)
            (music-assistant--render)
            (should (= requests 2))
            (should-not
             (seq-some #'buffer-live-p responses))))
      (mapc (lambda (response)
              (when (buffer-live-p response)
                (kill-buffer response)))
            responses)
      (kill-buffer buffer))))

(ert-deftest music-assistant-ui-artwork-stale-callback-is-ignored ()
  "Catch an old track's image replacing the current track artwork."
  (let* ((client (music-assistant-test--ready-client))
         (_item (music-assistant-test--set-current-image client "old"))
         (buffer (music-assistant-test--ui-buffer client))
         (music-assistant--artwork-cache
          (make-hash-table :test #'equal))
         callback callback-args response-buffer)
    (unwind-protect
        (with-current-buffer buffer
          (let ((music-assistant--schedule-function
                 (lambda (&rest _args) 'progress-timer))
                (music-assistant--url-retrieve-function
                 (lambda (_url actual-callback actual-args
                          &rest _ignored)
                   (setq callback actual-callback
                         callback-args actual-args
                         response-buffer
                         (generate-new-buffer
                          " *music-assistant-art-stale*"))
                   response-buffer))
                (music-assistant--create-image-function
                 (lambda (&rest _args) 'old-image)))
            (music-assistant--render)
            (let ((new-current
                   (music-assistant-test--queue-item
                    "desk" "item-new" "New track")))
              (setf
               (alist-get
                'current_item
                (music-assistant-client-selected-queue client))
               new-current))
            (with-current-buffer response-buffer
              (set-buffer-multibyte nil)
              (insert "HTTP/1.1 200 OK\r\n\r\nOLD")
              (setq-local url-http-end-of-headers 19)
              (apply callback nil callback-args))
            (should-not (equal music-assistant--artwork-image
                               'old-image))
            (should-not (buffer-live-p response-buffer))))
      (when (buffer-live-p response-buffer)
        (kill-buffer response-buffer))
      (kill-buffer buffer))))

(ert-deftest music-assistant-ui-cleanup-is-idempotent ()
  "Catch q and kill hooks leaking clients, timers, or HTTP buffers."
  (let* ((client (music-assistant-test--ready-client))
         (buffer (music-assistant-test--ui-buffer client))
         (response (generate-new-buffer
                    " *music-assistant-cleanup-response*"))
         (closed 0)
         cancelled
         (quit-count 0))
    (unwind-protect
        (with-current-buffer buffer
          (setq music-assistant--progress-timer 'progress-timer
                music-assistant--artwork-response-buffers
                (list response))
          (puthash "request" response
                   music-assistant--artwork-requests)
          (let ((music-assistant--cancel-function
                 (lambda (timer) (push timer cancelled))))
            (cl-letf
                (((symbol-function 'music-assistant-client-close)
                  (lambda (actual)
                    (should (eq actual client))
                    (cl-incf closed)))
                 ((symbol-function 'quit-window)
                  (lambda (&rest _args) (cl-incf quit-count))))
              (music-assistant-quit)
              (music-assistant-quit)))
          (should music-assistant--cleaned-p)
          (should (= closed 1))
          (should (= quit-count 2))
          (should (equal cancelled '(progress-timer)))
          (should-not music-assistant--progress-timer)
          (should-not (buffer-live-p response))
          (should (= (hash-table-count
                      music-assistant--artwork-requests)
                     0))
          (should (eq (music-assistant-client-on-state-change client)
                      #'ignore)))
      (when (buffer-live-p response)
        (kill-buffer response))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest music-assistant-ui-kill-hook-cleans-client-once ()
  "Catch killing the dashboard bypassing or repeating client teardown."
  (let* ((client (music-assistant-test--ready-client))
         (buffer (music-assistant-test--ui-buffer client))
         (closed 0))
    (cl-letf (((symbol-function 'music-assistant-client-close)
               (lambda (actual)
                 (should (eq actual client))
                 (cl-incf closed))))
      (kill-buffer buffer))
    (should (= closed 1))))

(ert-deftest music-assistant-ui-cleanup-blocks-late-artwork-render ()
  "Catch an already-cleaned dashboard accepting a late HTTP callback."
  (let* ((client (music-assistant-test--ready-client))
         (_item (music-assistant-test--set-current-image client "late"))
         (buffer (music-assistant-test--ui-buffer client))
         (music-assistant--artwork-cache
          (make-hash-table :test #'equal))
         callback callback-args response-buffer
         (scheduled 0))
    (unwind-protect
        (with-current-buffer buffer
          (let ((music-assistant--schedule-function
                 (lambda (&rest _args)
                   (cl-incf scheduled)
                   'timer))
                (music-assistant--url-retrieve-function
                 (lambda (_url actual-callback actual-args
                          &rest _ignored)
                   (setq callback actual-callback
                         callback-args actual-args
                         response-buffer
                         (generate-new-buffer
                          " *music-assistant-art-late*"))
                   response-buffer))
                (music-assistant--create-image-function
                 (lambda (&rest _args) 'late-image)))
            (music-assistant--render)
            ;; Ignore the progress timer scheduled by the initial render.
            (setq scheduled 0)
            (music-assistant--cleanup)
            (setq response-buffer
                  (generate-new-buffer
                   " *music-assistant-art-late-callback*"))
            (with-current-buffer response-buffer
              (set-buffer-multibyte nil)
              (insert "HTTP/1.1 200 OK\r\n\r\nLATE")
              (setq-local url-http-end-of-headers 19)
              (apply callback nil callback-args))
            (should-not music-assistant--artwork-image)
            (should (= scheduled 0))))
      (when (buffer-live-p response-buffer)
        (kill-buffer response-buffer))
      (kill-buffer buffer))))

(ert-deftest music-assistant-ui-kill-and-reopen-creates-fresh-client ()
  "Catch a killed dashboard resurrecting a cleaned protocol client."
  (when-let ((existing (get-buffer "*Music Assistant*")))
    (kill-buffer existing))
  (let ((first-client (music-assistant-test--ready-client))
        (second-client (music-assistant-test--ready-client))
        (created 0)
        first second)
    (unwind-protect
        (save-window-excursion
          (cl-letf
              (((symbol-function 'music-assistant-client-create)
                (lambda (&rest _args)
                  (prog1
                      (if (= created 0) first-client second-client)
                    (cl-incf created))))
               ((symbol-function 'music-assistant-client-connect)
                #'ignore))
            (setq first (music-assistant))
            (kill-buffer first)
            (setq second (music-assistant))))
      (when (buffer-live-p second)
        (kill-buffer second)))
    (should-not (eq first second))
    (should (= created 2))))

(ert-deftest music-assistant-ui-log-renders-only-sanitized-entries ()
  "Catch tokens or raw authenticated arguments reaching visible buffers."
  (let* ((client (music-assistant-test--ready-client))
         (buffer (music-assistant-test--ui-buffer client))
         log-buffer)
    (music-assistant-client--log
     client 'send "auth" "emacs-1"
     '((token . "fake-token") (device_name . "secret-device")))
    (music-assistant-client--log
     client 'event "queue_updated" nil "desk")
    (unwind-protect
        (with-current-buffer buffer
          (cl-letf (((symbol-function 'display-buffer)
                     (lambda (actual &rest _args)
                       (setq log-buffer actual))))
            (music-assistant-show-log))
          (should (buffer-live-p log-buffer))
          (with-current-buffer log-buffer
            (let ((text (buffer-string)))
              (should (string-match-p "auth" text))
              (should (string-match-p "<redacted>" text))
              (should (string-match-p "queue_updated" text))
              (should-not (string-match-p "fake-token" text))
              (should-not (string-match-p "secret-device" text))))
          (should-not (string-match-p "fake-token"
                                      (buffer-string))))
      (when (buffer-live-p log-buffer)
        (kill-buffer log-buffer))
      (kill-buffer buffer))))

(provide 'music-assistant-tests)

;;; music-assistant-tests.el ends here
