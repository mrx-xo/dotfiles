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

(provide 'music-assistant-tests)

;;; music-assistant-tests.el ends here
