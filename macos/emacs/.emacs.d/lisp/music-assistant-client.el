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
   :open-function open-function
   :send-function send-function
   :close-function close-function
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

(provide 'music-assistant-client)

;;; music-assistant-client.el ends here
