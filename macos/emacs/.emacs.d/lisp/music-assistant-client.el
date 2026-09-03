;;; music-assistant-client.el --- Music Assistant protocol client -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Transport and state boundary for the native Music Assistant dashboard.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'url-parse)

(defgroup music-assistant-client nil
  "Connect to Music Assistant over its WebSocket API."
  :group 'multimedia)

(cl-defstruct
    (music-assistant-client--pending-request
     (:constructor music-assistant-client--make-pending-request))
  "One in-flight Music Assistant command."
  command
  callback
  errback
  timer
  chunks)

(cl-defstruct
    (music-assistant-client
     (:constructor music-assistant-client--make))
  "Mutable state for one Music Assistant WebSocket connection."
  server-url
  websocket
  (state 'disconnected)
  server-info
  (pending (make-hash-table :test #'equal))
  (request-sequence 0)
  players
  queues
  queue-items
  selected-player-id
  selected-queue-id
  queue-time-received-at
  reconnect-attempt
  reconnect-timer
  intentional-close-p
  terminal-error-p
  last-error
  token-provider
  on-state-change
  request-timeout
  default-player-name
  open-function
  send-function
  close-function
  schedule-function
  cancel-function
  log-entries)

(cl-defun music-assistant-client-create
    (&key server-url token-provider on-state-change
          (request-timeout 10)
          (default-player-name "MrX.local")
          open-function send-function close-function
          (schedule-function #'run-at-time)
          (cancel-function #'cancel-timer))
  "Create a Music Assistant client without opening its connection.

SERVER-URL is the HTTP base URL.  TOKEN-PROVIDER accepts success and
error callbacks.  ON-STATE-CHANGE accepts the client.  The remaining
function arguments are injectable transport and timer boundaries."
  (music-assistant-client--make
   :server-url server-url
   :state 'disconnected
   :pending (make-hash-table :test #'equal)
   :request-sequence 0
   :reconnect-attempt 0
   :token-provider
   (or token-provider
       (lambda (success error)
         (music-assistant-client--read-keychain-token
          "music-assistant-token" success error)))
   :on-state-change (or on-state-change #'ignore)
   :request-timeout request-timeout
   :default-player-name default-player-name
   :open-function (or open-function
                      #'music-assistant-client--default-open)
   :send-function (or send-function
                      #'music-assistant-client--default-send)
   :close-function (or close-function
                       #'music-assistant-client--default-close)
   :schedule-function schedule-function
   :cancel-function cancel-function))

(defun music-assistant-client-websocket-url (server-url)
  "Return the WebSocket endpoint derived from SERVER-URL."
  (unless (and (stringp server-url)
               (or (string-prefix-p "http://" server-url)
                   (string-prefix-p "https://" server-url)))
    (user-error "Invalid Music Assistant server URL: %S" server-url))
  (let* ((trimmed (replace-regexp-in-string "/+\\'" ""
                                             (string-trim server-url)))
         (websocket-url
          (cond
           ((string-prefix-p "https://" trimmed)
            (concat "wss://" (substring trimmed 8)))
           ((string-prefix-p "http://" trimmed)
            (concat "ws://" (substring trimmed 7))))))
    (if (string-suffix-p "/ws" websocket-url)
        websocket-url
      (concat websocket-url "/ws"))))

(defun music-assistant-client--notify (client)
  "Notify CLIENT's state observer without leaking callback errors."
  (condition-case failure
      (funcall (music-assistant-client-on-state-change client) client)
    (error
     (music-assistant-client--log
      client 'callback "state-change-error" nil
      (error-message-string failure)))))

(defun music-assistant-client--set-state
    (client state &optional error-message)
  "Set CLIENT to STATE, optionally recording ERROR-MESSAGE."
  (setf (music-assistant-client-state client) state
        (music-assistant-client-last-error client) error-message)
  (music-assistant-client--log
   client 'state (symbol-name state) nil error-message)
  (music-assistant-client--notify client)
  state)

(defun music-assistant-client--default-open (client url)
  "Open URL with websocket.el for CLIENT."
  (require 'websocket)
  (websocket-open
   url
   :nowait t
   :on-open
   (lambda (websocket)
     (when (eq websocket
               (music-assistant-client-websocket client))
       (music-assistant-client--log
        client 'connection "opened")))
   :on-message
   (lambda (websocket frame)
     (when (eq websocket
               (music-assistant-client-websocket client))
       (music-assistant-client--handle-text
        client (websocket-frame-payload frame))))
   :on-close
   (lambda (websocket)
     (music-assistant-client--handle-close client websocket))
   :on-error
   (lambda (websocket callback _error)
     (when (eq websocket
               (music-assistant-client-websocket client))
       (music-assistant-client--log
        client 'connection "callback-error" nil
        (format "%s callback failed" callback))
       (music-assistant-client--handle-close client websocket)))))

(defun music-assistant-client--default-send (client text)
  "Send TEXT through CLIENT's websocket.el connection."
  (require 'websocket)
  (websocket-send-text
   (music-assistant-client-websocket client) text))

(defun music-assistant-client--default-close (client)
  "Close CLIENT's websocket.el connection if it remains open."
  (require 'websocket)
  (when-let ((websocket
              (music-assistant-client-websocket client)))
    (when (websocket-openp websocket)
      (websocket-close websocket))))

(defun music-assistant-client--cancel-reconnect (client)
  "Cancel CLIENT's pending reconnect timer."
  (when-let ((timer (music-assistant-client-reconnect-timer client)))
    (setf (music-assistant-client-reconnect-timer client) nil)
    (funcall (music-assistant-client-cancel-function client) timer)))

(defun music-assistant-client-connect (client)
  "Begin an asynchronous connection for CLIENT."
  (music-assistant-client--cancel-reconnect client)
  (setf (music-assistant-client-intentional-close-p client) nil
        (music-assistant-client-terminal-error-p client) nil)
  (music-assistant-client--set-state client 'connecting)
  (condition-case failure
      (let ((websocket
             (funcall
              (music-assistant-client-open-function client)
              client
              (music-assistant-client-websocket-url
               (music-assistant-client-server-url client)))))
        (setf (music-assistant-client-websocket client) websocket)
        websocket)
    (error
     (setf (music-assistant-client-websocket client) nil)
     (music-assistant-client--log
      client 'connection "open-failed" nil
      (error-message-string failure))
     (music-assistant-client--schedule-reconnect client)
     nil)))

(defun music-assistant-client--keychain-command (service)
  "Return the argument vector that reads SERVICE from macOS Keychain."
  (list "/usr/bin/security" "find-generic-password" "-w"
        "-a" "emacs" "-s" service))

(defun music-assistant-client--read-keychain-token
    (service success error-callback)
  "Read SERVICE asynchronously and call SUCCESS or ERROR-CALLBACK.

The Keychain value exists only in a temporary process buffer.  Failure
messages never include command output."
  (let ((buffer (generate-new-buffer " *music-assistant-keychain*")))
    (condition-case nil
        (make-process
         :name (generate-new-buffer-name "music-assistant-keychain")
         :buffer buffer
         :stderr buffer
         :command (music-assistant-client--keychain-command service)
         :connection-type 'pipe
         :noquery t
         :sentinel
         (lambda (process _event)
           (when (memq (process-status process) '(exit signal))
             (unwind-protect
                 (if (and (= (process-exit-status process) 0)
                          (buffer-live-p buffer))
                     (let ((token
                            (with-current-buffer buffer
                              (string-trim
                               (buffer-substring-no-properties
                                (point-min) (point-max))))))
                       (if (string-empty-p token)
                           (funcall error-callback
                                    "Music Assistant token missing")
                         (funcall success token)))
                   (funcall error-callback
                            "Music Assistant token missing"))
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (erase-buffer))
                 (kill-buffer buffer))))))
      (error
       (when (buffer-live-p buffer)
         (kill-buffer buffer))
       (funcall error-callback "Music Assistant token unavailable")))))

(defun music-assistant-client--log
    (client direction name &optional message-id details)
  "Append one sanitized log entry to CLIENT.

DIRECTION is a symbol such as send, receive, or event.  NAME is a
command or event name.  MESSAGE-ID and DETAILS are optional.  Auth
details are always discarded as a unit."
  (let* ((safe-details
          (cond
           ((equal name "auth") "<redacted>")
           ((null details) nil)
           ((stringp details) details)
           (t (prin1-to-string details))))
         (entry
          (string-join
           (delq nil
                 (list
                  (format-time-string "%Y-%m-%d %H:%M:%S")
                  (format "%s" direction)
                  name
                  (and message-id (format "id=%s" message-id))
                  (and safe-details
                       (format "details=%s" safe-details))))
           " ")))
    (push entry (music-assistant-client-log-entries client))
    (when (> (length (music-assistant-client-log-entries client)) 200)
      (setcdr (nthcdr 199 (music-assistant-client-log-entries client))
              nil))
    entry))

(defun music-assistant-client--next-message-id (client)
  "Return CLIENT's next unique string message ID."
  (let ((sequence (1+ (music-assistant-client-request-sequence client))))
    (setf (music-assistant-client-request-sequence client) sequence)
    (format "emacs-%d" sequence)))

(defun music-assistant-client--cancel-request-timer (client request)
  "Cancel REQUEST's timer through CLIENT and clear it."
  (when-let ((timer
              (music-assistant-client--pending-request-timer request)))
    (setf (music-assistant-client--pending-request-timer request) nil)
    (funcall (music-assistant-client-cancel-function client) timer)))

(defun music-assistant-client-request
    (client command args callback &optional errback)
  "Send COMMAND with ARGS through CLIENT and correlate its result.

CALLBACK receives a successful result.  ERRBACK receives a plist with
:code, :details, and :command.  Return the unique message ID."
  (let* ((message-id (music-assistant-client--next-message-id client))
         (request
          (music-assistant-client--make-pending-request
           :command command
           :callback (or callback #'ignore)
           :errback (or errback #'ignore)))
         (payload
          (json-serialize
           `((message_id . ,message-id)
             (command . ,command)
             (args . ,(or args (make-hash-table :test #'equal))))
           :null-object nil
           :false-object :false)))
    (puthash message-id request
             (music-assistant-client-pending client))
    (setf (music-assistant-client--pending-request-timer request)
          (funcall
           (music-assistant-client-schedule-function client)
           (music-assistant-client-request-timeout client)
           #'music-assistant-client--request-timeout
           client message-id))
    (music-assistant-client--log client 'send command message-id args)
    (condition-case failure
        (funcall (music-assistant-client-send-function client)
                 client payload)
      (error
       (remhash message-id (music-assistant-client-pending client))
       (music-assistant-client--cancel-request-timer client request)
       (funcall
        (music-assistant-client--pending-request-errback request)
        (list :code 'send-failed
              :details
              (if (equal command "auth")
                  "Failed to send authentication request"
                (error-message-string failure))
              :command command))))
    message-id))

(defun music-assistant-client--result-list (result)
  "Return RESULT in a form suitable for partial-result accumulation."
  (cond
   ((null result) nil)
   ((listp result) result)
   ((vectorp result) (append result nil))
   (t (list result))))

(defun music-assistant-client--handle-success
    (client message-id message)
  "Resolve CLIENT request MESSAGE-ID from success MESSAGE."
  (when-let ((request
              (gethash message-id
                       (music-assistant-client-pending client))))
    (let ((result (alist-get 'result message)))
      (if (eq (alist-get 'partial message) t)
          (setf
           (music-assistant-client--pending-request-chunks request)
           (append
            (music-assistant-client--pending-request-chunks request)
            (music-assistant-client--result-list result)))
        (remhash message-id (music-assistant-client-pending client))
        (music-assistant-client--cancel-request-timer client request)
        (let ((chunks
               (music-assistant-client--pending-request-chunks request)))
          (funcall
           (music-assistant-client--pending-request-callback request)
           (if chunks
               (append chunks
                       (music-assistant-client--result-list result))
             result)))))))

(defun music-assistant-client--handle-error
    (client message-id message)
  "Reject CLIENT request MESSAGE-ID from error MESSAGE."
  (when-let ((request
              (gethash message-id
                       (music-assistant-client-pending client))))
    (remhash message-id (music-assistant-client-pending client))
    (music-assistant-client--cancel-request-timer client request)
    (funcall
     (music-assistant-client--pending-request-errback request)
     (list :code (alist-get 'error_code message)
           :details (or (alist-get 'details message)
                        "Music Assistant request failed")
           :command
           (music-assistant-client--pending-request-command request)))))

(defun music-assistant-client--request-timeout (client message-id)
  "Expire CLIENT's pending request identified by MESSAGE-ID."
  (when-let ((request
              (gethash message-id
                       (music-assistant-client-pending client))))
    (remhash message-id (music-assistant-client-pending client))
    (setf (music-assistant-client--pending-request-timer request) nil)
    (funcall
     (music-assistant-client--pending-request-errback request)
     (list :code 'timeout
           :details "Request timed out"
           :command
           (music-assistant-client--pending-request-command request)))))

(defun music-assistant-client--handle-text (client text)
  "Parse and route one inbound JSON TEXT message for CLIENT."
  (condition-case _failure
      (let* ((message
              (json-parse-string
               text
               :object-type 'alist
               :array-type 'list
               :null-object nil
               :false-object :false))
             (message-id (alist-get 'message_id message)))
        (cond
         ((assq 'error_code message)
          (music-assistant-client--log
           client 'receive "error" message-id
           (alist-get 'details message))
          (music-assistant-client--handle-error
           client message-id message))
         ((assq 'result message)
          (music-assistant-client--log
           client 'receive "result" message-id)
          (music-assistant-client--handle-success
           client message-id message))
         ((assq 'server_id message)
          (if (fboundp 'music-assistant-client--handle-server-info)
              (music-assistant-client--handle-server-info client message)
            (music-assistant-client--log
             client 'receive "server-info")))
         ((assq 'event message)
          (if (fboundp 'music-assistant-client--handle-event)
              (music-assistant-client--handle-event client message)
            (music-assistant-client--log
             client 'event (alist-get 'event message))))
         (t
          (music-assistant-client--log
           client 'receive "unknown-message"))))
    (error
     (music-assistant-client--log
     client 'receive "malformed-message" nil
      "Invalid JSON ignored"))))

(defun music-assistant-client--bootstrap-error (client error)
  "Record a non-terminal bootstrap ERROR for CLIENT."
  (setf (music-assistant-client-last-error client)
        (plist-get error :details))
  (music-assistant-client--log
   client 'receive "bootstrap-error" nil
   (plist-get error :details))
  (music-assistant-client--notify client))

(defun music-assistant-client--set-players (client players)
  "Install PLAYERS returned during CLIENT bootstrap."
  (setf (music-assistant-client-players client) players)
  (when (fboundp 'music-assistant-client--resolve-selection)
    (music-assistant-client--resolve-selection client))
  (music-assistant-client--notify client))

(defun music-assistant-client--set-queues (client queues)
  "Install QUEUES returned during CLIENT bootstrap."
  (setf (music-assistant-client-queues client) queues)
  (when (fboundp 'music-assistant-client--resolve-selection)
    (music-assistant-client--resolve-selection client))
  (music-assistant-client--notify client))

(defun music-assistant-client--bootstrap (client)
  "Request initial player and queue state for ready CLIENT."
  (music-assistant-client-request
   client "players/all" nil
   (apply-partially #'music-assistant-client--set-players client)
   (apply-partially #'music-assistant-client--bootstrap-error client))
  (music-assistant-client-request
   client "player_queues/all" nil
   (apply-partially #'music-assistant-client--set-queues client)
   (apply-partially #'music-assistant-client--bootstrap-error client)))

(defun music-assistant-client--auth-succeeded (client result)
  "Finish CLIENT authentication from RESULT."
  (if (eq (alist-get 'authenticated result) t)
      (progn
        (setf (music-assistant-client-reconnect-attempt client) 0
              (music-assistant-client-terminal-error-p client) nil)
        (music-assistant-client--set-state client 'ready)
        (music-assistant-client--bootstrap client))
    (music-assistant-client--auth-failed
     client
     '(:code authentication-failed
       :details "Music Assistant authentication failed"
       :command "auth"))))

(defun music-assistant-client--auth-failed (client error)
  "Handle CLIENT authentication ERROR without confusing drops for rejection."
  (let ((code (plist-get error :code))
        (details
         (or (plist-get error :details)
             "Music Assistant authentication failed")))
    (if (memq code '(disconnected send-failed timeout))
        (progn
          (setf (music-assistant-client-terminal-error-p client) nil
                (music-assistant-client-last-error client) details)
          (unless (eq code 'disconnected)
            (when (music-assistant-client-websocket client)
              (setf (music-assistant-client-intentional-close-p client)
                    t)
              (condition-case nil
                  (funcall
                   (music-assistant-client-close-function client)
                   client)
                (error nil))
              (setf (music-assistant-client-websocket client) nil
                    (music-assistant-client-intentional-close-p client)
                    nil)))
          (music-assistant-client--schedule-reconnect client))
      (setf (music-assistant-client-terminal-error-p client) t)
      (music-assistant-client--set-state
       client 'auth-required details))))

(defun music-assistant-client--token-ready (client token)
  "Authenticate CLIENT with TOKEN when its handshake is still active."
  (when (and (eq (music-assistant-client-state client)
                 'authenticating)
             (not
              (music-assistant-client-intentional-close-p client)))
    (if (and (stringp token) (not (string-empty-p token)))
        (music-assistant-client-request
         client "auth" `((token . ,token))
         (apply-partially
          #'music-assistant-client--auth-succeeded client)
         (apply-partially
          #'music-assistant-client--auth-failed client))
      (music-assistant-client--auth-failed
       client
       '(:code authentication-required
         :details "Music Assistant token missing"
         :command "auth")))))

(defun music-assistant-client--token-failed (client details)
  "Enter auth-required for CLIENT with safe token failure DETAILS."
  (when (eq (music-assistant-client-state client) 'authenticating)
    (music-assistant-client--auth-failed
     client
     (list :code 'authentication-required
           :details details
           :command "auth"))))

(defun music-assistant-client--handle-server-info (client message)
  "Validate server-info MESSAGE and authenticate CLIENT."
  (setf (music-assistant-client-server-info client) message)
  (music-assistant-client--log
   client 'receive "server-info" nil
   (format "server=%s schema=%s minimum=%s"
           (or (alist-get 'server_version message) "unknown")
           (or (alist-get 'schema_version message) "unknown")
           (or (alist-get 'min_supported_schema_version message)
               "unknown")))
  (if (> (or (alist-get 'min_supported_schema_version message)
             most-positive-fixnum)
         31)
      (progn
        (setf (music-assistant-client-terminal-error-p client) t)
        (music-assistant-client--set-state
         client 'error
         (format
          "Music Assistant requires schema %s; this client supports schema 31"
          (alist-get 'min_supported_schema_version message))))
    (music-assistant-client--set-state client 'authenticating)
    (condition-case _failure
        (funcall
         (music-assistant-client-token-provider client)
         (apply-partially
          #'music-assistant-client--token-ready client)
         (apply-partially
          #'music-assistant-client--token-failed client))
      (error
       (music-assistant-client--token-failed
        client "Music Assistant token unavailable")))))

(defun music-assistant-client--fail-pending (client code details)
  "Reject every pending CLIENT request with CODE and DETAILS."
  (let (requests)
    (maphash
     (lambda (_message-id request)
       (push request requests))
     (music-assistant-client-pending client))
    (clrhash (music-assistant-client-pending client))
    (dolist (request requests)
      (music-assistant-client--cancel-request-timer client request)
      (funcall
       (music-assistant-client--pending-request-errback request)
       (list
        :code code
        :details details
        :command
        (music-assistant-client--pending-request-command request))))))

(defun music-assistant-client--run-reconnect (client)
  "Run CLIENT's scheduled reconnect."
  (setf (music-assistant-client-reconnect-timer client) nil)
  (unless (or (music-assistant-client-intentional-close-p client)
              (music-assistant-client-terminal-error-p client))
    (music-assistant-client-connect client)))

(defun music-assistant-client--schedule-reconnect (client)
  "Schedule CLIENT's next capped reconnect, if allowed."
  (unless (or (music-assistant-client-reconnect-timer client)
              (music-assistant-client-intentional-close-p client)
              (music-assistant-client-terminal-error-p client))
    (let* ((attempt
            (music-assistant-client-reconnect-attempt client))
           (delay
            (aref [1 2 4 8 16 30] (min attempt 5))))
      (setf (music-assistant-client-reconnect-attempt client)
            (1+ attempt))
      (music-assistant-client--set-state
       client 'reconnecting
       (format "Connection lost; retrying in %s seconds" delay))
      (setf (music-assistant-client-reconnect-timer client)
            (funcall
             (music-assistant-client-schedule-function client)
             delay
             #'music-assistant-client--run-reconnect
             client)))))

(defun music-assistant-client--handle-close
    (client &optional websocket)
  "Handle an expected or unexpected close for CLIENT and WEBSOCKET."
  (when (or (null websocket)
            (eq websocket
                (music-assistant-client-websocket client)))
    (setf (music-assistant-client-websocket client) nil)
    (music-assistant-client--fail-pending
     client 'disconnected "Music Assistant disconnected")
    (if (music-assistant-client-intentional-close-p client)
        (music-assistant-client--set-state client 'disconnected)
      (music-assistant-client--schedule-reconnect client))))

(defun music-assistant-client-retry (client)
  "Cancel any delay and reconnect CLIENT immediately."
  (music-assistant-client--cancel-reconnect client)
  (setf (music-assistant-client-reconnect-attempt client) 0
        (music-assistant-client-terminal-error-p client) nil)
  (when (music-assistant-client-websocket client)
    (setf (music-assistant-client-intentional-close-p client) t)
    (condition-case _failure
        (funcall (music-assistant-client-close-function client) client)
      (error nil))
    (setf (music-assistant-client-websocket client) nil
          (music-assistant-client-intentional-close-p client) nil))
  (music-assistant-client-connect client))

(defun music-assistant-client-close (client)
  "Close CLIENT and cancel all resources idempotently."
  (setf (music-assistant-client-intentional-close-p client) t)
  (music-assistant-client--cancel-reconnect client)
  (music-assistant-client--fail-pending
   client 'disconnected "Music Assistant disconnected")
  (when (music-assistant-client-websocket client)
    (condition-case _failure
        (funcall (music-assistant-client-close-function client) client)
      (error
       (music-assistant-client--log
        client 'connection "close-failed")))
    (setf (music-assistant-client-websocket client) nil))
  (music-assistant-client--set-state client 'disconnected)
  nil)

(provide 'music-assistant-client)

;;; music-assistant-client.el ends here
