;;; syzygy-recall.el --- transcript history API for acp-mobile -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; The phone half of transcript browsing and exact-session resume:
;; acp-mobile's History endpoints eval these JSON bridges over emacsclient.
;; Reads agent-recall's index — the same source as `agent-recall-browse' on
;; the desktop — and refuses agent-shell's normal session/new fallback when
;; an archived session cannot actually be restored.
;;
;; agent-recall is required lazily inside the entry point: this file
;; loads from the syzygy umbrella (agent-shell-config.el), where
;; top-level requires of session-only packages break batch mode.

;;; Code:

(require 'json)
(require 'cl-lib)
(require 'map)
(require 'seq)
(require 'subr-x)

(defvar agent-recall--index nil)
(defvar agent-recall-resume-restore-preferences)
(defvar agent-shell--state nil)
(declare-function agent-recall--index-ensure "agent-recall")
(declare-function agent-recall-session-label "agent-recall")
(declare-function agent-recall--read-working-directory "agent-recall" (file))
(declare-function agent-recall--agent-config-for-transcript "agent-recall" (file))
(declare-function agent-recall--find-session-buffer "agent-recall" (session-id))
(declare-function agent-recall--display-buffer "agent-recall" (buffer))
(declare-function agent-recall--start-resume "agent-recall"
                  (session-id &optional transcript-file))
(declare-function agent-shell-subscribe-to "agent-shell"
                  (&rest args))
(declare-function agent-shell-unsubscribe "agent-shell"
                  (&rest args))

(defvar syzygy-recall--agent-cache (make-hash-table :test 'equal)
  "FILE -> agent name (\"Claude\", \"Codex\", ...) from the transcript header.
Transcripts are append-only, so a header parsed once never changes.")

(defun syzygy-recall-sidecar-label-put (labels session-id label)
  "Record LABEL for SESSION-ID in sidecar hash LABELS.
An empty string is an intentional clear tombstone: it must remain present so
the phone can override an older durable agent-recall label immediately."
  (puthash session-id
           (if (and label (not (string-empty-p label))) label "")
           labels))

(defvar syzygy-recall-resume-timeout 30
  "Seconds before a mobile-owned transcript resume is abandoned.")

(defvar syzygy-recall-resume-result-retention 60
  "Seconds to retain a completed resume result for status polling.")

(defvar syzygy-recall--resume-operations (make-hash-table :test 'equal)
  "Opaque operation token to pending or recently completed resume state.")

(defvar syzygy-recall--resume-sequence 0)
(defvar syzygy-recall--starting-session-id nil)
(defvar syzygy-recall--started-buffer nil)

(defvar-local syzygy-recall--strict-resume-session-id nil
  "Archived session ID this buffer must resume without fallback.")

(defvar-local syzygy-recall--strict-resume-failure nil
  "Failure recorded when agent-shell tries to fall back to session/new.")

(defun syzygy-recall--agent (file)
  "Return the agent name from FILE's transcript header, or \"?\"."
  (or (gethash file syzygy-recall--agent-cache)
      (puthash file
               (with-temp-buffer
                 (insert-file-contents file nil 0 200)
                 (goto-char (point-min))
                 (if (re-search-forward "^\\*\\*Agent:\\*\\* \\(.+\\)$" nil t)
                     (match-string 1)
                   "?"))
               syzygy-recall--agent-cache)))

(defun syzygy-recall--encode-json (value)
  "Serialize VALUE as UTF-8 JSON wrapped in base64."
  (base64-encode-string
   (encode-coding-string (json-serialize value) 'utf-8)
   t))

(defun syzygy-recall--resume-readiness (file entry)
  "Return (RESUMABLE . REASON) for transcript FILE and index ENTRY."
  (let ((session-id (plist-get entry :session-id)))
    (cond
     ((not (file-regular-p file))
      (cons nil "Transcript file is no longer available."))
     ((not (and (stringp session-id) (not (string-empty-p session-id))))
      (cons nil "No session ID was recorded."))
     ((and (fboundp 'agent-recall--find-session-buffer)
           (agent-recall--find-session-buffer session-id))
      (cons t ""))
     ((not (agent-recall--read-working-directory file))
      (cons nil "The recorded working directory is unavailable."))
     ((not (condition-case nil
               (agent-recall--agent-config-for-transcript file)
             (error nil)))
      (cons nil "No matching agent config is available."))
     (t (cons t "")))))

(defun syzygy-recall--buffer-from-display-result (result)
  "Return a live buffer represented by display RESULT, or nil."
  (let ((buffer (cond
                 ((bufferp result) result)
                 ((windowp result) (window-buffer result)))))
    (and (buffer-live-p buffer) buffer)))

(defun syzygy-recall--buffer-session-id (buffer &optional fallback)
  "Return BUFFER's live ACP session ID, or optional FALLBACK."
  (or (and (buffer-live-p buffer)
           (with-current-buffer buffer
             (and (boundp 'agent-shell--state)
                  agent-shell--state
                  (condition-case nil
                      (map-nested-elt agent-shell--state '(:session :id))
                    (error nil)))))
      fallback))

(defun syzygy-recall--buffer-resume-capable-p (buffer)
  "Return non-nil when BUFFER's agent advertised load or resume support."
  (and (buffer-live-p buffer)
       (with-current-buffer buffer
         (and (boundp 'agent-shell--state)
              agent-shell--state
              (or (map-elt agent-shell--state :supports-session-load)
                  (map-elt agent-shell--state :supports-session-resume))))))

(defun syzygy-recall--buffer-resume-failure (buffer)
  "Return BUFFER's strict resume failure, or nil."
  (and (buffer-live-p buffer)
       (buffer-local-value 'syzygy-recall--strict-resume-failure buffer)))

(defun syzygy-recall--arm-buffer (buffer session-id)
  "Require BUFFER to restore SESSION-ID without creating a new session."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq-local syzygy-recall--strict-resume-session-id session-id)
      (setq-local syzygy-recall--strict-resume-failure nil))))

(defun syzygy-recall--arm-strict-resume (&rest args)
  "Arm agent-shell's ARGS shell buffer during a Syzygy resume start.
This advice runs before `agent-shell--handle', while the resume request's
dynamic context is still available and before ACP bootstrapping can fall back."
  (when syzygy-recall--starting-session-id
    (when-let ((buffer (plist-get args :shell-buffer)))
      (setq syzygy-recall--started-buffer buffer)
      (syzygy-recall--arm-buffer buffer
                                 syzygy-recall--starting-session-id))))

(defun syzygy-recall--guard-new-session (original &rest args)
  "Call ORIGINAL with ARGS unless this is a strict transcript resume.
agent-shell normally recovers from unsupported or failed restore requests by
issuing `session/new'.  Mobile History promises to resume the exact archived
conversation, so record a terminal failure before that request is sent."
  (let* ((argument-buffer (plist-get args :shell-buffer))
         (state-buffer (and (boundp 'agent-shell--state)
                            agent-shell--state
                            (map-elt agent-shell--state :buffer)))
         (buffer (cond
                  ((buffer-live-p argument-buffer) argument-buffer)
                  ((buffer-live-p state-buffer) state-buffer)
                  ((derived-mode-p 'agent-shell-mode) (current-buffer))))
         (strict-id (and (buffer-live-p buffer)
                         (buffer-local-value
                          'syzygy-recall--strict-resume-session-id buffer))))
    (if (not strict-id)
        (apply original args)
      (with-current-buffer buffer
        (setq syzygy-recall--strict-resume-failure
              (if (syzygy-recall--buffer-resume-capable-p buffer)
                  "The recorded session could not be restored."
                "The agent does not support session resume.")))
      ;; A timed-out external attempt has no fast timer anymore.  Its single
      ;; lifecycle subscription can be retired now that fallback was blocked.
      (syzygy-recall--settle-external-monitors-for-buffer buffer)
      nil)))

(defun syzygy-recall--clear-strict-resume (buffer session-id)
  "Clear SESSION-ID's strict resume state from BUFFER."
  (when (and (buffer-live-p buffer)
             (equal (buffer-local-value
                     'syzygy-recall--strict-resume-session-id buffer)
                    session-id))
    (with-current-buffer buffer
      (setq syzygy-recall--strict-resume-session-id nil
            syzygy-recall--strict-resume-failure nil))))

(defun syzygy-recall--kill-failed-resume (buffer)
  "Kill BUFFER without prompting after a failed mobile resume."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((kill-buffer-query-functions nil))
        (kill-buffer buffer)))))

(defun syzygy-recall--resume-token ()
  "Return a new opaque token for a resume operation."
  (setq syzygy-recall--resume-sequence
        (1+ syzygy-recall--resume-sequence))
  (substring
   (secure-hash 'sha256
                (format "%s:%s:%s:%s"
                        (emacs-pid) syzygy-recall--resume-sequence
                        (float-time) (random most-positive-fixnum)))
   0 32))

(defun syzygy-recall--ready-result (buffer session-id existing)
  "Return a ready JSON alist for BUFFER and SESSION-ID.
EXISTING records whether the operation reused a pre-existing buffer."
  `((ok . t)
    (status . "ready")
    (bufferName . ,(buffer-name buffer))
    (sessionId . ,session-id)
    (existing . ,(if existing t :false))))

(defun syzygy-recall--failed-result (message)
  "Return a failed JSON alist with MESSAGE."
  `((ok . :false)
    (status . "failed")
    (error . ,message)))

(defun syzygy-recall--pending-result (token operation)
  "Return a pending JSON alist for TOKEN and OPERATION."
  (let ((buffer (plist-get operation :buffer)))
    `((ok . t)
      (status . "pending")
      (operation . ,token)
      (bufferName . ,(and (buffer-live-p buffer) (buffer-name buffer)))
      (sessionId . ,(plist-get operation :session-id))
      (existing . ,(if (plist-get operation :existing) t :false)))))

(defun syzygy-recall--pending-operation (buffer session-id)
  "Return BUFFER's active or externally monitored SESSION-ID operation."
  (let (found)
    (maphash
     (lambda (token operation)
       (when (and (not found)
                  (eq (plist-get operation :buffer) buffer)
                  (equal (plist-get operation :session-id) session-id)
                  (or (not (plist-get operation :result))
                      (plist-get operation :monitor-external)))
         (setq found (cons token operation))))
     syzygy-recall--resume-operations)
    found))

(defun syzygy-recall--cancel-operation-timer (operation)
  "Cancel OPERATION's polling timer and return the updated plist."
  (when-let ((timer (plist-get operation :timer)))
    (when (timerp timer)
      (cancel-timer timer)))
  (plist-put operation :timer nil))

(defun syzygy-recall--unsubscribe-operation (operation)
  "Remove OPERATION's agent-shell lifecycle subscription and return it."
  (let ((buffer (plist-get operation :buffer))
        (subscription (plist-get operation :lifecycle-subscription)))
    (when (and subscription
               (buffer-live-p buffer)
               (fboundp 'agent-shell-unsubscribe))
      (with-current-buffer buffer
        (condition-case nil
            (agent-shell-unsubscribe :subscription subscription)
          (error nil))))
    (plist-put operation :lifecycle-subscription nil)))

(defun syzygy-recall--install-external-lifecycle (token operation)
  "Install one agent-shell lifecycle subscription for TOKEN's OPERATION."
  (unless (plist-get operation :lifecycle-subscription)
    (let ((buffer (plist-get operation :buffer)))
      (when (and (buffer-live-p buffer)
                 (fboundp 'agent-shell-subscribe-to))
        (setq operation
              (plist-put
               operation :lifecycle-subscription
               (agent-shell-subscribe-to
                :shell-buffer buffer
                :on-event
                (lambda (event)
                  (syzygy-recall--external-lifecycle-event token event))))))))
  operation)

(defun syzygy-recall--forget-operation (token)
  "Forget completed resume operation TOKEN."
  (remhash token syzygy-recall--resume-operations))

(defun syzygy-recall--finish-operation (token operation result
                                              &optional monitor-external)
  "Finish TOKEN's OPERATION with RESULT.
When MONITOR-EXTERNAL is non-nil, retain the strict guard and timer until the
pre-existing buffer eventually settles; Syzygy never kills that buffer."
  (let* ((buffer (plist-get operation :buffer))
         (session-id (plist-get operation :session-id))
         (owned (plist-get operation :owned)))
    (setq operation (plist-put operation :result result))
    (setq operation (plist-put operation :monitor-external monitor-external))
    (setq operation (syzygy-recall--cancel-operation-timer operation))
    (if monitor-external
        (setq operation
              (syzygy-recall--install-external-lifecycle token operation))
      (setq operation (syzygy-recall--unsubscribe-operation operation))
      (syzygy-recall--clear-strict-resume buffer session-id)
      (when (and owned (not (eq (alist-get 'ok result) t)))
        (syzygy-recall--kill-failed-resume buffer))
      (run-at-time syzygy-recall-resume-result-retention nil
                   #'syzygy-recall--forget-operation token))
    (puthash token operation syzygy-recall--resume-operations)
    result))

(defun syzygy-recall--release-external-monitor (token operation)
  "Release TOKEN's strict external OPERATION monitor without killing its buffer."
  (let ((buffer (plist-get operation :buffer))
        (session-id (plist-get operation :session-id)))
    (setq operation (syzygy-recall--cancel-operation-timer operation))
    (setq operation (syzygy-recall--unsubscribe-operation operation))
    (syzygy-recall--clear-strict-resume buffer session-id)
    (setq operation (plist-put operation :monitor-external nil))
    (puthash token operation syzygy-recall--resume-operations)
    (run-at-time syzygy-recall-resume-result-retention nil
                 #'syzygy-recall--forget-operation token)
    (plist-get operation :result)))

(defun syzygy-recall--advance-external-monitor (token operation)
  "Release TOKEN's strict guard after an external OPERATION settles."
  (let* ((buffer (plist-get operation :buffer))
         (active-id (syzygy-recall--buffer-session-id buffer)))
    (when (or (not (buffer-live-p buffer))
              active-id
              (syzygy-recall--buffer-resume-failure buffer))
      (syzygy-recall--release-external-monitor token operation))
    (plist-get operation :result)))

(defun syzygy-recall--external-lifecycle-event (token event)
  "Settle external operation TOKEN for agent-shell lifecycle EVENT."
  (when-let ((operation (gethash token syzygy-recall--resume-operations)))
    (when (plist-get operation :monitor-external)
      (pcase (map-elt event :event)
        ('init-session
         (syzygy-recall--advance-external-monitor token operation))
        ('clean-up
         (syzygy-recall--release-external-monitor token operation))))))

(defun syzygy-recall--settle-external-monitors-for-buffer (buffer)
  "Settle timed-out external operations guarded in BUFFER."
  (let (matches)
    (maphash
     (lambda (token operation)
       (when (and (eq (plist-get operation :buffer) buffer)
                  (plist-get operation :monitor-external))
         (push (cons token operation) matches)))
     syzygy-recall--resume-operations)
    (dolist (match matches)
      (syzygy-recall--advance-external-monitor (car match) (cdr match)))))

(defun syzygy-recall--advance-operation (token)
  "Advance resume operation TOKEN without blocking Emacs's command loop."
  (when-let ((operation (gethash token syzygy-recall--resume-operations)))
    (if (plist-get operation :result)
        (if (plist-get operation :monitor-external)
            (syzygy-recall--advance-external-monitor token operation)
          (plist-get operation :result))
      (let* ((buffer (plist-get operation :buffer))
             (session-id (plist-get operation :session-id))
             (active-id (syzygy-recall--buffer-session-id buffer))
             (failure (syzygy-recall--buffer-resume-failure buffer)))
        (cond
         ((not (buffer-live-p buffer))
          (syzygy-recall--finish-operation
           token operation
           (syzygy-recall--failed-result
            "The agent session closed before it could resume.")))
         (failure
          (syzygy-recall--finish-operation
           token operation (syzygy-recall--failed-result failure)))
         (active-id
          (if (and (equal active-id session-id)
                   (syzygy-recall--buffer-resume-capable-p buffer))
              (syzygy-recall--finish-operation
               token operation
               (syzygy-recall--ready-result
                buffer session-id (plist-get operation :existing)))
            (syzygy-recall--finish-operation
             token operation
             (syzygy-recall--failed-result
              (if (syzygy-recall--buffer-resume-capable-p buffer)
                  "The recorded session could not be restored."
                "The agent does not support session resume.")))))
         ((>= (float-time) (plist-get operation :deadline))
          (syzygy-recall--finish-operation
           token operation
           (syzygy-recall--failed-result
            "Timed out waiting for the recorded session to resume.")
           (not (plist-get operation :owned))))
         (t (syzygy-recall--pending-result token operation)))))))

(defun syzygy-recall--operation-tick (token)
  "Timer callback that advances TOKEN and converts internal errors to failure."
  (condition-case err
      (syzygy-recall--advance-operation token)
    (error
     (when-let ((operation (gethash token syzygy-recall--resume-operations)))
       (syzygy-recall--finish-operation
        token operation
        (syzygy-recall--failed-result (error-message-string err)))))))

(defun syzygy-recall--register-operation (buffer session-id owned existing)
  "Register BUFFER restoring SESSION-ID and return a pending result.
OWNED means this request created BUFFER.  EXISTING means it attached to one."
  (if-let ((pending (syzygy-recall--pending-operation buffer session-id)))
      (or (plist-get (cdr pending) :result)
          (syzygy-recall--pending-result (car pending) (cdr pending)))
    (syzygy-recall--arm-buffer buffer session-id)
    (let* ((token (syzygy-recall--resume-token))
           (operation (list :buffer buffer
                            :session-id session-id
                            :owned owned
                            :existing existing
                            :deadline (+ (float-time)
                                         syzygy-recall-resume-timeout))))
      (puthash token operation syzygy-recall--resume-operations)
      (let ((timer (run-at-time 0.1 0.1
                                #'syzygy-recall--operation-tick token)))
        (setq operation (plist-put operation :timer timer))
        (puthash token operation syzygy-recall--resume-operations))
      (syzygy-recall--pending-result token operation))))

(defun syzygy-recall--resume (file)
  "Resume indexed transcript FILE and return its JSON-ready result alist."
  (agent-recall--index-ensure)
  (let ((entry (and (stringp file) (gethash file agent-recall--index))))
    (unless entry
      (error "Transcript is not present in the agent-recall index."))
    (pcase-let ((`(,resumable . ,reason)
                 (syzygy-recall--resume-readiness file entry)))
      (unless resumable (error "%s" reason)))
    (let* ((session-id (plist-get entry :session-id))
           (existing (agent-recall--find-session-buffer session-id))
           (active-id (syzygy-recall--buffer-session-id existing)))
      (cond
       ((and existing (equal active-id session-id))
        (agent-recall--display-buffer existing)
        (syzygy-recall--ready-result existing session-id t))
       ((and existing active-id)
        (error "The recorded session could not be restored."))
       (existing
        (agent-recall--display-buffer existing)
        (syzygy-recall--register-operation existing session-id nil t))
       (t
        (let* ((restore-setting
                (and (boundp 'agent-recall-resume-restore-preferences)
                     agent-recall-resume-restore-preferences))
               (agent-recall-resume-restore-preferences
                (if (eq restore-setting 'ask) t restore-setting))
               (syzygy-recall--starting-session-id session-id)
               (syzygy-recall--started-buffer nil)
               display-result)
          (condition-case err
              (setq display-result
                    (agent-recall--start-resume session-id file))
            ((error quit)
             (when (buffer-live-p syzygy-recall--started-buffer)
               (syzygy-recall--clear-strict-resume
                syzygy-recall--started-buffer session-id)
               (syzygy-recall--kill-failed-resume
                syzygy-recall--started-buffer))
             (signal (car err) (cdr err))))
          (let* ((buffer (or syzygy-recall--started-buffer
                             (syzygy-recall--buffer-from-display-result
                              display-result)
                             (agent-recall--find-session-buffer session-id)))
                 (started-id (syzygy-recall--buffer-session-id buffer)))
            (unless (buffer-live-p buffer)
              (error "The agent session started without a discoverable buffer."))
            ;; Defense in depth for alternative agent-recall display paths;
            ;; the pre-handle advice normally arms this before ACP starts.
            (syzygy-recall--arm-buffer buffer session-id)
            (cond
             ((equal started-id session-id)
              (syzygy-recall--clear-strict-resume buffer session-id)
              (syzygy-recall--ready-result buffer session-id nil))
             (started-id
              (syzygy-recall--clear-strict-resume buffer session-id)
              (syzygy-recall--kill-failed-resume buffer)
              (error "The recorded session could not be restored."))
             (t
              (syzygy-recall--register-operation
               buffer session-id t nil))))))))))

(defun syzygy-recall-resume-json (file-base64)
  "Resume the indexed transcript named by base64 FILE-BASE64.
Return a base64-wrapped JSON result for acp-mobile.  Errors are returned as
structured JSON so the phone can keep the transcript open and explain why."
  (require 'agent-recall)
  (syzygy-recall--encode-json
   (condition-case err
       (let ((file (decode-coding-string
                    (base64-decode-string file-base64) 'utf-8)))
         (syzygy-recall--resume file))
     ((error quit)
      `((ok . :false)
        (status . "failed")
        (error . ,(error-message-string err)))))))

(defun syzygy-recall-resume-status-json (operation-base64)
  "Return base64-wrapped JSON status for OPERATION-BASE64."
  (syzygy-recall--encode-json
   (condition-case err
       (let* ((token (decode-coding-string
                      (base64-decode-string operation-base64) 'utf-8))
              (operation (gethash token syzygy-recall--resume-operations)))
         (unless operation
           (error "Resume operation is no longer available."))
         (syzygy-recall--advance-operation token))
     ((error quit)
      (syzygy-recall--failed-result (error-message-string err))))))

(defun syzygy-recall-transcripts-json (&optional limit)
  "Return the newest LIMIT transcripts as base64-wrapped JSON.
LIMIT defaults to 100; zero returns every indexed transcript.
Each element: file, project, timestamp, agent, preview, sessionId, label,
resumable, resumeReason.
Base64 because emacsclient octal-escapes non-ASCII in printed strings
(\\342\\200\\231 for a curly quote) — ASCII armor sidesteps that."
  (require 'agent-recall)
  (agent-recall--index-ensure)
  (let ((entries '()))
    (maphash (lambda (file e)
               (when (file-exists-p file)
                 (push (cons file e) entries)))
             agent-recall--index)
    (setq entries
          (sort entries
                (lambda (a b)
                  (string> (or (plist-get (cdr a) :timestamp) "")
                           (or (plist-get (cdr b) :timestamp) "")))))
    (unless (and limit (zerop limit))
      (setq entries (seq-take entries (or limit 100))))
    (syzygy-recall--encode-json
     (vconcat
      (mapcar (lambda (fe)
                (let* ((file (car fe))
                       (e (cdr fe))
                       (session-id (or (plist-get e :session-id) ""))
                       (readiness (syzygy-recall--resume-readiness file e)))
                  `((file . ,file)
                    (project . ,(or (plist-get e :project) ""))
                    (timestamp . ,(or (plist-get e :timestamp) ""))
                    (agent . ,(syzygy-recall--agent file))
                    (preview . ,(or (plist-get e :preview) ""))
                    (sessionId . ,session-id)
                    (label . ,(or (agent-recall-session-label session-id) ""))
                    (resumable . ,(if (car readiness) t :false))
                    (resumeReason . ,(cdr readiness)))))
              entries)))))

(unless (advice-member-p #'syzygy-recall--arm-strict-resume
                         'agent-shell--handle)
  (advice-add 'agent-shell--handle :before
              #'syzygy-recall--arm-strict-resume))

(unless (advice-member-p #'syzygy-recall--guard-new-session
                         'agent-shell--initiate-new-session)
  (advice-add 'agent-shell--initiate-new-session :around
              #'syzygy-recall--guard-new-session))

(provide 'syzygy-recall)
;;; syzygy-recall.el ends here
