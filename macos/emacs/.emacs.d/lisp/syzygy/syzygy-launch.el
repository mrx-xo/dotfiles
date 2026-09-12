;;; syzygy-launch.el --- Explicit New Chat settings -*- lexical-binding: t; -*-

;; Config constructors come only from the rig and live agent buffers. The
;; phone sends identifiers, never function names or executable Lisp.
(require 'cl-lib)
(require 'map)
(require 'seq)
(require 'subr-x)
(require 'syzygy-presets)
(require 'syzygy-bridge)

(defvar major-pane--labels)
(defvar syzygy-launch--capabilities (make-hash-table :test #'equal)
  "Last advertised choices for each agent in this daemon.")
(defvar syzygy-launch--timeout 20
  "Maximum seconds to confirm a new session's settings.")

(defun syzygy-launch--config-id (config)
  "Return the phone identifier for trusted CONFIG."
  (cond ((equal (map-elt config :mode-line-name) "DeepSeek") "deepseek")
        ((eq (map-elt config :identifier) 'claude-code) "claude")
        (t (format "%s" (map-elt config :identifier)))))

(defun syzygy-launch--configs ()
  "Resolve configured presets, the preferred agent, and live agents."
  (let (result)
    (when (fboundp 'agent-shell--resolve-preferred-config)
      (when-let* ((config (agent-shell--resolve-preferred-config)))
        (push (cons (syzygy-launch--config-id config) config) result)))
    (dolist (tuple (and (boundp 'mr-x/agent-shell-presets) mr-x/agent-shell-presets))
      (let ((maker (nth 4 tuple)))
        (when (and maker (functionp maker))
          (let ((config (funcall maker)))
            (push (cons (syzygy-presets--agent maker) config) result)))))
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (derived-mode-p 'agent-shell-mode)
          (when-let* ((config (map-elt (agent-shell--state) :agent-config)))
            (let ((id (syzygy-launch--config-id config)))
              (unless (assoc id result) (push (cons id config) result)))))))
    (cl-delete-duplicates (nreverse result) :key #'car :test #'equal)))

(defun syzygy-launch--choice (id name description)
  "Make one JSON choice from ID, NAME and DESCRIPTION."
  `((id . ,id) (name . ,(or name id)) (description . ,(or description ""))))

(defun syzygy-launch--state-options (state)
  "Extract advertised model, mode and effort choices from STATE."
  `((models . ,(vconcat
                (mapcar (lambda (m) (syzygy-launch--choice
                                      (map-elt m :model-id) (map-elt m :name)
                                      (map-elt m :description)))
                        (agent-shell--get-available-models state))))
    (modes . ,(vconcat
               (mapcar (lambda (m) (syzygy-launch--choice
                                     (map-elt m :id) (map-elt m :name)
                                     (map-elt m :description)))
                       (agent-shell--get-available-modes state))))
    (efforts . ,(vconcat
                 (mapcar (lambda (m) (syzygy-launch--choice
                                       (map-elt m :value) (map-elt m :name)
                                       (map-elt m :description)))
                         (map-elt (agent-shell--config-option-by-category state "thought_level")
                                  :options))))))

(defun syzygy-launch--known (choices id)
  "Find ID in CHOICES."
  (seq-find (lambda (c) (equal (alist-get 'id c) id)) choices))

(defun syzygy-launch--catalog ()
  "Build the launch catalogue without starting processes."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (derived-mode-p 'agent-shell-mode)
        (let ((state (agent-shell--state)))
          (when (map-nested-elt state '(:session :id))
            (puthash (syzygy-launch--config-id (map-elt state :agent-config))
                     (syzygy-launch--state-options state) syzygy-launch--capabilities))))))
  (mapcar
   (lambda (entry)
     (let* ((id (car entry)) (config (cdr entry))
            (cached (gethash id syzygy-launch--capabilities))
            (options (copy-tree (or cached '((models . []) (modes . []) (efforts . [])))))
            (tuples (seq-filter (lambda (p) (equal id (syzygy-presets--agent (nth 4 p))))
                                (and (boundp 'mr-x/agent-shell-presets) mr-x/agent-shell-presets))))
       ;; Presets can contain adapter aliases absent from the advertised list.
       ;; Keep those choices, then confirm them against the new session.
       (dolist (pair '((models . 2) (modes . 3) (efforts . 5)))
         (dolist (p tuples)
           (let ((value (nth (cdr pair) p)))
             (when (and (stringp value) (not (string-empty-p value))
                        (not (syzygy-launch--known (alist-get (car pair) options) value)))
               (setf (alist-get (car pair) options)
                     (vconcat (alist-get (car pair) options)
                              (vector (syzygy-launch--choice value value "From a rig preset"))))))))
       (let* ((model-fn (map-elt config :default-model-id))
              (mode-fn (map-elt config :default-session-mode-id))
              (model (and (functionp model-fn) (funcall model-fn)))
              (mode (and (functionp mode-fn) (funcall mode-fn))))
         `((id . ,id)
           (name . ,(if (equal id "claude") "Claude Code"
                      (or (map-elt config :mode-line-name) id)))
           ,@options
           (source . ,(if cached "advertised" "presets"))
           (defaults . ((model . ,(if (syzygy-launch--known (alist-get 'models options) model)
                                     model ""))
                        (mode . ,(if (syzygy-launch--known (alist-get 'modes options) mode)
                                    mode ""))
                        (effort . "")))))))
   (syzygy-launch--configs)))

(defun syzygy-launch-options-json ()
  "Return configured agents and launch choices as base64 JSON."
  (let* ((agents (syzygy-launch--catalog))
         (preferred (and (fboundp 'agent-shell--resolve-preferred-config)
                         (agent-shell--resolve-preferred-config))))
    (syzygy-bridge-encode-json
     `((agents . ,(vconcat agents))
       (defaultAgent . ,(if preferred (syzygy-launch--config-id preferred)
                          (or (alist-get 'id (car agents)) "")))))))

(defun syzygy-launch--validate (settings agents)
  "Validate SETTINGS against trusted AGENTS; return the chosen agent."
  (let ((agent (seq-find (lambda (a) (equal (alist-get 'id a) (alist-get 'agent settings))) agents)))
    (unless agent (user-error "Unknown agent"))
    (dolist (pair '((model . models) (mode . modes) (effort . efforts)))
      (let ((value (alist-get (car pair) settings)))
        (unless (or (and (eq (car pair) 'effort) (or (null value) (equal value "")))
                    (and (stringp value) (syzygy-launch--known (alist-get (cdr pair) agent) value)))
          (user-error "Unknown %s for %s: %s" (car pair) (alist-get 'name agent) value))))
    agent))

(defun syzygy-launch--configure (buffer settings task)
  "Confirm BUFFER's SETTINGS before submitting TASK.
On any timeout or rejected setting, leave the chat open without sending
the first prompt. Never queue a timer that can send it after failure."
  (let ((deadline (+ (float-time) syzygy-launch--timeout)))
    (with-current-buffer buffer
      (while (and (< (float-time) deadline)
                  (let ((s (agent-shell--state)))
                    (not (and (map-nested-elt s '(:session :id))
                              (map-elt s :set-model) (map-elt s :set-session-mode)))))
        (accept-process-output nil 0.05))
      (let ((s (agent-shell--state)))
        (unless (and (map-elt s :set-model) (map-elt s :set-session-mode)
                     (equal (alist-get 'model settings) (agent-shell--current-model-id s))
                     (equal (alist-get 'mode settings) (agent-shell--current-mode-id s)))
          (user-error "Agent did not confirm model and permissions; first message was not sent")))
      (let ((effort (alist-get 'effort settings)))
        (unless (or (null effort) (equal effort ""))
          (let* ((option (agent-shell--config-option-by-category (agent-shell--state) "thought_level"))
                 result failure settled)
            (unless (seq-find (lambda (v) (equal effort (map-elt v :value))) (map-elt option :options))
              (user-error "Effort unavailable on the new session; first message was not sent"))
            (unless (equal effort (map-elt option :current-value))
              (agent-shell--set-session-config-option
               :config-id (map-elt option :id) :value effort
               :on-success (lambda () (unless settled (setq result t)))
               :on-failure (lambda (err _raw) (unless settled (setq failure (format "%s" err)))))
              (while (and (not result) (not failure) (< (float-time) deadline))
                (accept-process-output nil 0.05))
              (setq settled t)
              (unless (and result
                           (equal effort (map-elt
                                          (agent-shell--config-option-by-category
                                           (agent-shell--state) "thought_level")
                                          :current-value)))
                (user-error "Effort not confirmed: %s; first message was not sent" (or failure "timeout")))))))
      (unless (string-empty-p task)
        (goto-char (point-max))
        (insert task)
        (shell-maker-submit)))))

(defun syzygy-launch-json (encoded)
  "Launch from base64 JSON ENCODED and return the exact buffer name.
Return a structured failure, retaining bufferName if creation succeeded
but settings could not be confirmed."
  (let (buffer)
    (syzygy-bridge-encode-json
     (condition-case err
         (let* ((req (json-parse-string (syzygy-bridge-decode-base64 encoded) :object-type 'alist))
                (settings (alist-get 'settings req))
                (agent (syzygy-launch--validate settings (syzygy-launch--catalog)))
                (config (copy-alist (cdr (assoc (alist-get 'id agent) (syzygy-launch--configs)))))
                (cwd (alist-get 'cwd req))
                (name (or (alist-get 'name req) ""))
                (task (or (alist-get 'task req) "")))
           (unless (and (stringp cwd) (not (string-empty-p cwd))
                        (stringp name) (stringp task))
             (user-error "Invalid project, name or first message"))
           (unless config (user-error "Agent configuration is unavailable"))
           (let ((default-directory (file-name-as-directory (expand-file-name cwd)))
                 (model (alist-get 'model settings))
                 (mode (alist-get 'mode settings)))
             (unless (file-directory-p default-directory) (user-error "No such directory: %s" cwd))
             (setf (alist-get :default-model-id config) (lambda () model)
                   (alist-get :default-session-mode-id config) (lambda () mode))
             (setq buffer (agent-shell--start :config config :new-session t :no-focus t))
             (unless (string-empty-p name) (puthash buffer name major-pane--labels))
             (syzygy-launch--configure buffer settings task)
             (when (fboundp 'mr-x/agent-label-sync)
               (with-current-buffer buffer (mr-x/agent-label-sync)))
             `((ok . t) (bufferName . ,(buffer-name buffer)))))
       ((error quit)
        `((ok . :false) (error . ,(error-message-string err))
          ,@(when (buffer-live-p buffer) `((bufferName . ,(buffer-name buffer))))))))))

(provide 'syzygy-launch)
;;; syzygy-launch.el ends here
