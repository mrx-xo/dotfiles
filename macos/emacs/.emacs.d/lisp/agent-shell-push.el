;;; agent-shell-push.el --- Opt-in phone push for agent-shell turns -*- lexical-binding: t; -*-

;; Per-buffer, default-off iOS push via the Home Assistant companion app.
;; Fires on three agent-shell-attention events only: turn done, turn
;; failed, permission request.  Ignores the buffer-visible suppression
;; that gates the macOS notification, because an armed buffer is usually
;; still on screen on the Mac the user walked away from.
;; Design: macos/docs/superpowers/specs/2026-09-05-agent-shell-phone-push-design.md

(require 'map)
(require 'json)
(require 'subr-x)

(defgroup agent-shell-push nil
  "Phone push notifications for agent-shell conversations."
  :group 'agent-shell)

(defcustom agent-shell-push-ha-url "https://home.andrade-lab.com"
  "Home Assistant base URL."
  :type 'string
  :group 'agent-shell-push)

(defcustom agent-shell-push-token-file "~/.config/gaia/ha-token.txt"
  "File holding the Home Assistant long-lived access token."
  :type 'file
  :group 'agent-shell-push)

(defcustom agent-shell-push-service "mobile_app_daemon"
  "Home Assistant notify service name for the target phone."
  :type 'string
  :group 'agent-shell-push)

(defcustom agent-shell-push-link-file "~/.acp-mobile/link"
  "File holding the acp-mobile URL that a tapped push should open."
  :type 'file
  :group 'agent-shell-push)

(defcustom agent-shell-push-lighter " [push]"
  "Marker shown in `mode-line-process' while a buffer is armed."
  :type 'string
  :group 'agent-shell-push)

(defvar agent-shell-push-spawn-function #'agent-shell-push--spawn
  "Function called with NAME and COMMAND to run the push. Test seam.")

(defun agent-shell-push--spawn (name command)
  "Start COMMAND asynchronously as NAME without exit queries."
  (make-process :name name
                :command command
                :noquery t
                :buffer nil
                :stderr nil))

(defun agent-shell-push--read-line (file)
  "Return the first non-empty line of FILE, or nil."
  (let ((path (expand-file-name file)))
    (when (file-readable-p path)
      (with-temp-buffer
        (insert-file-contents path)
        (let ((line (string-trim (buffer-string))))
          (unless (string-empty-p line)
            (car (split-string line "\n"))))))))

(defun agent-shell-push--title (buffer)
  "Return BUFFER's major-pane label, or its name."
  (if (and (buffer-live-p buffer) (fboundp 'major-pane--tab-label))
      (major-pane--tab-label buffer)
    (buffer-name buffer)))

(defun agent-shell-push--payload (title body tag)
  "Return the JSON string for a push titled TITLE with BODY grouped by TAG."
  (let* ((link (agent-shell-push--read-line agent-shell-push-link-file))
         (data (append (when link (list (cons 'url link)))
                       (list (cons 'group "agent-shell")
                             (cons 'tag tag)))))
    (json-encode (list (cons 'title title)
                       (cons 'message body)
                       (cons 'data data)))))

(defun agent-shell-push--command (token payload)
  "Return the curl argv posting PAYLOAD with bearer TOKEN."
  (list "curl" "-s" "-o" "/dev/null" "--max-time" "8"
        "-X" "POST"
        "-H" (concat "Authorization: Bearer " token)
        "-H" "Content-Type: application/json"
        "-d" payload
        (format "%s/api/services/notify/%s"
                (string-remove-suffix "/" agent-shell-push-ha-url)
                agent-shell-push-service)))

(defun agent-shell-push-send (buffer body)
  "Push BODY for BUFFER when it is armed.  Never signals."
  (when (and (buffer-live-p buffer)
             (buffer-local-value 'agent-shell-push-mode buffer))
    (let ((token (agent-shell-push--read-line agent-shell-push-token-file)))
      (if (not token)
          (message "agent-shell-push: no HA token at %s"
                   agent-shell-push-token-file)
        (condition-case err
            (funcall agent-shell-push-spawn-function
                     "agent-shell-push"
                     (agent-shell-push--command
                      token
                      (agent-shell-push--payload
                       (agent-shell-push--title buffer)
                       body
                       (buffer-name buffer))))
          (error (message "agent-shell-push: %s" err)))))))

;;; Event filters (mirror agent-shell-attention's wording)

(defun agent-shell-push--describe-stop (stop-reason)
  "Return push text for STOP-REASON, or nil when it must not push."
  (pcase stop-reason
    ("cancelled" nil)
    ("end_turn" "Finished")
    ("max_tokens" "Max token limit reached")
    ("max_turn_requests" "Exceeded request limit")
    ("refusal" "Refused")
    ((pred stringp) (format "Stopped: %s" stop-reason))
    (_ "Finished")))

(defun agent-shell-push--extract-message (value)
  "Return a message string from VALUE (error alist, string, or nil)."
  (cond
   ((stringp value) value)
   ((and (listp value) value)
    (let ((msg (or (map-elt value 'message) (map-elt value :message))))
      (and (stringp msg) msg)))))

(defun agent-shell-push--on-success (buffer response)
  "Push the stop description of RESPONSE for BUFFER."
  (let* ((stop-reason (or (map-elt response 'stopReason)
                          (map-elt response :stop-reason)))
         (body (agent-shell-push--describe-stop stop-reason)))
    (when body
      (agent-shell-push-send buffer body))))

(defun agent-shell-push--on-failure (buffer error raw-message)
  "Push the failure text from ERROR or RAW-MESSAGE for BUFFER."
  (agent-shell-push-send buffer
                         (or (agent-shell-push--extract-message error)
                             (agent-shell-push--extract-message raw-message)
                             "Request failed")))

(defun agent-shell-push--on-event (buffer event)
  "Push permission requests in EVENT for BUFFER; ignore everything else."
  (when (eq (map-elt event :event) 'permission-request)
    (let* ((tool-call (map-nested-elt event '(:data :tool-call)))
           (title (or (map-elt tool-call :title)
                      (map-elt tool-call 'title)
                      "Permission required"))
           (kind (or (map-elt tool-call :kind)
                     (map-elt tool-call 'kind))))
      (agent-shell-push-send buffer
                             (concat "Permission: " title
                                     (if kind (format " (%s)" kind) ""))))))

;; Phone-initiated turns: Emacs never sent that prompt, so agent-shell
;; gets no response and agent-shell-attention never sees turn-complete.
;; acp-multiplex instead broadcasts a synthetic session/update
;; {sessionUpdate: "turn_complete", stopReason} to every frontend except
;; the sender.  Catch it at the raw notification boundary.

(defun agent-shell-push--own-turn-p (state)
  "Non-nil when Emacs itself has a prompt in flight for STATE."
  (and (fboundp 'agent-shell--active-requests-p)
       (agent-shell--active-requests-p state)))

(defun agent-shell-push--on-notification (&rest args)
  "Push when ARGS carry a synthetic turn_complete for a remote turn.
ARGS are the keyword arguments of `agent-shell--on-notification'."
  (let* ((state (plist-get args :state))
         (notification (plist-get args :acp-notification))
         (buffer (map-elt state :buffer)))
    (when (and (buffer-live-p buffer)
               (equal (map-elt notification 'method) "session/update")
               (equal (map-nested-elt notification
                                      '(params update sessionUpdate))
                      "turn_complete")
               (not (agent-shell-push--own-turn-p state)))
      (when-let ((body (agent-shell-push--describe-stop
                        (map-nested-elt notification
                                        '(params update stopReason)))))
        (agent-shell-push-send buffer body)))))

;;; Phone-side control: sidecar read by acp-mobile, setter called by it

(defcustom agent-shell-push-sidecar-file "~/.acp-mobile/push.json"
  "JSON object of armed session IDs, read by acp-mobile for its bell state."
  :type 'file
  :group 'agent-shell-push)

(defun agent-shell-push--session-id (buffer)
  "Return BUFFER's ACP session ID, or nil."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (boundp 'agent-shell--state)
        (ignore-errors
          (map-nested-elt agent-shell--state '(:session :id)))))))

(defun agent-shell-push--armed-session-ids (&optional except)
  "Return session IDs of live armed buffers, skipping buffer EXCEPT."
  (let (ids)
    (dolist (buf (buffer-list))
      (when (and (not (eq buf except))
                 (buffer-local-value 'agent-shell-push-mode buf))
        (when-let ((sid (agent-shell-push--session-id buf)))
          (push sid ids))))
    (nreverse ids)))

(defun agent-shell-push--sync-sidecar (&optional except)
  "Rewrite the sidecar from live armed buffers, skipping EXCEPT.
Never signals: the phone bell is a convenience, not a dependency."
  (condition-case err
      (let ((file (expand-file-name agent-shell-push-sidecar-file))
            (table (make-hash-table :test #'equal)))
        (dolist (sid (agent-shell-push--armed-session-ids except))
          (puthash sid t table))
        (make-directory (file-name-directory file) t)
        (with-temp-file file
          (insert (json-encode table))))
    (error (message "agent-shell-push: sidecar sync failed: %s" err))))

(defun agent-shell-push--on-buffer-killed ()
  "Drop the dying buffer from the sidecar."
  (when agent-shell-push-mode
    (agent-shell-push--sync-sidecar (current-buffer))))

(defun agent-shell-push-set (buffer-name enabled)
  "Set phone push for BUFFER-NAME to ENABLED.  For acp-mobile's /api/push.
Return \"on\" or \"off\", or nil when no such buffer exists."
  (let ((inhibit-quit t))
    (when-let ((buf (get-buffer buffer-name)))
      (with-current-buffer buf
        (agent-shell-push-mode (if enabled 1 -1))
        (if agent-shell-push-mode "on" "off")))))

;;; Minor mode

(defun agent-shell-push--mark-mode-line (on)
  "Add or remove the lighter from `mode-line-process' depending on ON."
  (let ((current (if (listp mode-line-process)
                     mode-line-process
                   (list mode-line-process))))
    (setq mode-line-process
          (if on
              (if (member agent-shell-push-lighter current)
                  current
                (cons agent-shell-push-lighter current))
            (remove agent-shell-push-lighter current))))
  (force-mode-line-update))

;;;###autoload
(define-minor-mode agent-shell-push-mode
  "Push this conversation's done, failed, and permission events to the phone."
  :lighter nil
  (agent-shell-push--mark-mode-line agent-shell-push-mode)
  (if agent-shell-push-mode
      (add-hook 'kill-buffer-hook #'agent-shell-push--on-buffer-killed nil t)
    (remove-hook 'kill-buffer-hook #'agent-shell-push--on-buffer-killed t))
  (agent-shell-push--sync-sidecar)
  (message "Phone push %s for %s"
           (if agent-shell-push-mode "ON" "off")
           (buffer-name)))

(with-eval-after-load 'agent-shell
  (advice-add 'agent-shell--on-notification :before
              #'agent-shell-push--on-notification))

(with-eval-after-load 'agent-shell-attention
  (advice-add 'agent-shell-attention--handle-success :after
              #'agent-shell-push--on-success)
  (advice-add 'agent-shell-attention--handle-failure :after
              #'agent-shell-push--on-failure)
  (advice-add 'agent-shell-attention--handle-event :after
              #'agent-shell-push--on-event))

(provide 'agent-shell-push)
;;; agent-shell-push.el ends here
