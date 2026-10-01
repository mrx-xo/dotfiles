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
(defvar syzygy-launch--timeout 60
  "Maximum seconds for startup or one launch setting to settle.")
(defvar syzygy-launch--cli-models (make-hash-table :test #'equal)
  "Model choices read from an agent's CLI, keyed by agent id.
Filled once per daemon for agents that expose a model list without a
session. Clear an entry to re-read it.")
(defvar agent-shell-opencode-acp-command)

(defconst syzygy-launch--claude-model-aliases
  '(("fable[1m]" "claude-fable-5-1[1m]" "claude-fable-5-1")
    ("opus[1m]" "opus[1m]" "opus"))
  "Historical rig IDs and their supported advertised replacements.")

(defun syzygy-launch--opencode-cli-output ()
  "Return the stdout of `opencode models', or nil when it fails."
  ;; The ACP command may be wrapped (acp-multiplex ... opencode acp), so
  ;; take the opencode binary itself, wherever it sits in that list.
  (let ((program (or (and (boundp 'agent-shell-opencode-acp-command)
                          (seq-find (lambda (arg)
                                      (and (stringp arg)
                                           (equal (file-name-nondirectory arg) "opencode")))
                                    agent-shell-opencode-acp-command))
                     (executable-find "opencode")
                     (expand-file-name "~/.opencode/bin/opencode"))))
    (when (and program (file-executable-p program))
      (with-temp-buffer
        (when (eq 0 (ignore-errors
                      (call-process program nil (list (current-buffer) nil) nil "models")))
          (buffer-string))))))

(defun syzygy-launch--cli-model-choices (id)
  "Return CLI-advertised model choices for agent ID, or nil.
Only OpenCode lists its models from the command line. The result is a
vector of choices cached in `syzygy-launch--cli-models'."
  (when (equal id "opencode")
    (or (gethash id syzygy-launch--cli-models)
        (when-let* ((output (syzygy-launch--opencode-cli-output))
                    (ids (seq-filter (lambda (line) (string-match-p "\\`[^ \t]+/[^ \t]+\\'" line))
                                     (split-string output "\n" t "[ \t\r]+")))
                    (choices (vconcat (mapcar (lambda (m) (syzygy-launch--choice m m "")) ids))))
          (puthash id choices syzygy-launch--cli-models)))))

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
          (when-let* ((config (map-elt (ignore-errors (agent-shell--state)) :agent-config)))
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

(defun syzygy-launch--resolve-model (agent model choices)
  "Resolve known old AGENT preset MODEL names against advertised CHOICES.
Do not guess by substring or cross agent boundaries.  Prefer the explicit
1M option when the adapter exposes it; newer Claude catalogues advertise
the same models without that historical suffix.  Unknown IDs stay unknown."
  (let ((candidates
         (and (equal agent "claude")
              (or (cdr (assoc model syzygy-launch--claude-model-aliases))
                  (and (stringp model)
                       (list model (concat model "[1m]") (concat model "-1m")))))))
    (or (seq-find (lambda (id) (syzygy-launch--known choices id)) candidates)
        model)))

(defun syzygy-launch--normalize-settings (settings agents)
  "Return a copy of SETTINGS with known old model IDs resolved in AGENTS."
  (let* ((copy (copy-tree settings))
         (agent (seq-find (lambda (a) (equal (alist-get 'id a) (alist-get 'agent copy))) agents)))
    (setf (alist-get 'model copy)
          (syzygy-launch--resolve-model (alist-get 'agent copy) (alist-get 'model copy)
                                       (alist-get 'models agent)))
    copy))

(defun syzygy-launch--model-matches-p (agent requested actual)
  "Whether ACTUAL confirms REQUESTED for AGENT without changing identity.
Claude can add a context suffix while applying a bare model ID.  Never
accept the opposite (dropping an explicitly requested context variant),
or use this rule for another agent."
  (or (equal requested actual)
      (and (equal agent "claude") (stringp requested) (stringp actual)
           (or (equal actual (concat requested "[1m]"))
               (equal actual (concat requested "-1m"))))))

(defun syzygy-launch--catalog ()
  "Build the launch catalogue without starting processes."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (derived-mode-p 'agent-shell-mode)
        (let ((state (ignore-errors (agent-shell--state))))
          (when (map-nested-elt state '(:session :id))
            (puthash (syzygy-launch--config-id (map-elt state :agent-config))
                     (syzygy-launch--state-options state) syzygy-launch--capabilities))))))
  (mapcar
   (lambda (entry)
     (let* ((id (car entry)) (config (cdr entry))
            (cached (gethash id syzygy-launch--capabilities))
            (cli (and (not cached) (syzygy-launch--cli-model-choices id)))
            (options (copy-tree (or cached
                                    (and cli `((models . ,cli) (modes . []) (efforts . [])))
                                    '((models . []) (modes . []) (efforts . [])))))
            (tuples (seq-filter (lambda (p) (equal id (syzygy-presets--agent (nth 4 p))))
                                (and (boundp 'mr-x/agent-shell-presets) mr-x/agent-shell-presets))))
       ;; Cold agents need preset choices.  Warm catalogues are authoritative:
       ;; do not advertise unsupported preset values as if the agent offered them.
       (dolist (pair '((models . 2) (modes . 3) (efforts . 5)))
         (dolist (p tuples)
           (let ((value (nth (cdr pair) p)))
             (when (and (not cached) (not (and cli (eq (car pair) 'models)))
                        (stringp value) (not (string-empty-p value))
                        (not (syzygy-launch--known (alist-get (car pair) options) value)))
               (setf (alist-get (car pair) options)
                     (vconcat (alist-get (car pair) options)
                              (vector (syzygy-launch--choice value value "From a rig preset"))))))))
       ;; Existing phone drafts, pins and custom presets keep their IDs.
       ;; Offer only compatibility aliases that this bridge can actually resolve.
       (when (equal id "claude")
         (dolist (alias (delete-dups
                        (append (mapcar #'car syzygy-launch--claude-model-aliases)
                                (mapcar (lambda (p) (nth 2 p)) tuples))))
           (let* ((models (alist-get 'models options))
                  (resolved (syzygy-launch--resolve-model id alias models)))
             (unless (or (equal resolved alias)
                         (syzygy-launch--known models alias))
               (setf (alist-get 'models options)
                     (vconcat models
                              (vector (syzygy-launch--choice
                                       alias alias
                                       (format "Saved preset alias for %s" resolved)))))))))
       (let* ((model-fn (map-elt config :default-model-id))
              (mode-fn (map-elt config :default-session-mode-id))
              (model (and (functionp model-fn) (funcall model-fn)))
              (mode (and (functionp mode-fn) (funcall mode-fn))))
         `((id . ,id)
           (name . ,(if (equal id "claude") "Claude Code"
                      (or (map-elt config :mode-line-name) id)))
           ,@options
           (source . ,(cond (cached "advertised") (cli "cli") (t "presets")))
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

(defun syzygy-launch--confirm (label value current setter &optional matches)
  "Confirm VALUE via CURRENT, using SETTER's success/failure callbacks.
Each stage has its own deadline.  Late callbacks never submit a prompt.
MATCHES optionally compares the requested and confirmed values."
  (setq matches (or matches #'equal))
  (unless (funcall matches value (funcall current))
    (let ((deadline (+ (float-time) syzygy-launch--timeout)) result failure settled)
      (unwind-protect
          (progn
            (funcall setter
                     (lambda () (unless settled (setq result t)))
                     (lambda (err _raw)
                       (unless settled
                         (setq failure (format "%S" err)))))
            (while (and (not result) (not failure) (< (float-time) deadline))
              (accept-process-output nil 0.05))
            (cond
             (failure
              (user-error "%s %s was rejected: %s; first message was not sent"
                          label value failure))
             ((not result)
              (user-error "%s %s confirmation timed out; first message was not sent" label value))
             ((not (funcall matches value (funcall current)))
              (user-error "%s mismatch: requested %s, agent reports %s; first message was not sent"
                          label value (funcall current)))))
        (setq settled t)))))

(defun syzygy-launch--configure (buffer settings task)
  "Confirm BUFFER's SETTINGS before submitting TASK.
Start without automatic defaults, then apply model, permissions and effort
in order.  A refusal is an error, not agent-shell's optional-default warning."
  (with-current-buffer buffer
    (let ((deadline (+ (float-time) syzygy-launch--timeout)))
      (while (and (not (map-nested-elt (agent-shell--state) '(:session :id)))
                  (< (float-time) deadline))
        (accept-process-output nil 0.05))
      (unless (map-nested-elt (agent-shell--state) '(:session :id))
        (user-error "Agent startup timed out; first message was not sent")))
    (let* ((model (or (alist-get 'model settings)
                      (agent-shell--current-model-id (agent-shell--state))))
           (mode (or (alist-get 'mode settings)
                     (agent-shell--current-mode-id (agent-shell--state))))
           (effort (alist-get 'effort settings)))
      ;; A persisted draft can outlive the catalogue used to create it.
      (when (equal (alist-get 'agent settings) "claude")
        (setq model (syzygy-launch--resolve-model
                     "claude" model
                     (mapcar (lambda (m) `((id . ,(map-elt m :model-id))))
                             (agent-shell--get-available-models (agent-shell--state))))))
      (syzygy-launch--confirm
       "Model" model (lambda () (agent-shell--current-model-id (agent-shell--state)))
       (lambda (success failure)
         (agent-shell--config-option-set-model-id
          :model-id model :on-success success :on-failure failure))
       (lambda (requested actual)
         (syzygy-launch--model-matches-p (alist-get 'agent settings) requested actual)))
      (syzygy-launch--confirm
       "Permissions" mode (lambda () (agent-shell--current-mode-id (agent-shell--state)))
       (lambda (success failure)
         (agent-shell--config-option-set-mode-id
          :mode-id mode :on-success success :on-failure failure)))
      (unless (or (null effort) (equal effort ""))
        (let ((option (agent-shell--config-option-by-category (agent-shell--state) "thought_level")))
          (unless (seq-find (lambda (v) (equal effort (map-elt v :value))) (map-elt option :options))
            (user-error "Effort %s is unavailable on the new session; first message was not sent" effort))
          (syzygy-launch--confirm
           "Effort" effort
           (lambda () (map-elt (agent-shell--config-option-by-category
                                (agent-shell--state) "thought_level") :current-value))
           (lambda (success failure)
             (agent-shell--set-session-config-option
              :config-id (map-elt option :id) :value effort :on-success success :on-failure failure)))))
      ;; Mode/effort responses can replace the entire options list.  Recheck
      ;; the complete selection immediately before allowing a first prompt.
      (unless (and (syzygy-launch--model-matches-p
                    (alist-get 'agent settings) model
                    (agent-shell--current-model-id (agent-shell--state)))
                   (equal mode (agent-shell--current-mode-id (agent-shell--state)))
                   (or (null effort) (equal effort "")
                       (equal effort (map-elt (agent-shell--config-option-by-category
                                              (agent-shell--state) "thought_level") :current-value))))
        (user-error "Agent settings changed during launch; first message was not sent"))
      (setq model (agent-shell--current-model-id (agent-shell--state)))
      ;; Keep restart/clone configuration consistent with confirmed settings.
      (let ((state (agent-shell--state)))
        (map-put! state :set-model t)
        (map-put! state :set-session-mode t)
        (when-let ((config (map-elt state :agent-config)))
          (setf (alist-get :default-model-id config) (lambda () model)
                (alist-get :default-session-mode-id config) (lambda () mode))
          (unless (or (null effort) (equal effort ""))
            (setf (alist-get :default-config-options config)
                  (lambda () `(("thought_level" . ,effort))))
            (map-put! state :set-config-options t))
          (map-put! state :agent-config config)))
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
                (agents (syzygy-launch--catalog))
                (settings (syzygy-launch--normalize-settings (alist-get 'settings req) agents))
                (agent (syzygy-launch--validate settings agents))
                (config (copy-alist (cdr (assoc (alist-get 'id agent) (syzygy-launch--configs)))))
                (cwd (alist-get 'cwd req))
                (name (or (alist-get 'name req) ""))
                (task (or (alist-get 'task req) "")))
           (unless (and (stringp cwd) (not (string-empty-p cwd))
                        (stringp name) (stringp task))
             (user-error "Invalid project, name or first message"))
           (unless config (user-error "Agent configuration is unavailable"))
           (let ((default-directory (file-name-as-directory (expand-file-name cwd))))
             (unless (file-directory-p default-directory) (user-error "No such directory: %s" cwd))
             ;; Explicit settings are mandatory.  agent-shell's automatic
             ;; defaults continue after refusal and discard error details.
             (setf (alist-get :default-model-id config) nil
                   (alist-get :default-session-mode-id config) nil
                   (alist-get :default-config-options config) nil)
             (setq buffer (agent-shell--start :config config :new-session t :no-focus t))
             (unless (string-empty-p name) (major-pane-set-buffer-label buffer name))
             (syzygy-launch--configure buffer settings task)
             (when (fboundp 'mr-x/agent-label-sync)
               (with-current-buffer buffer (mr-x/agent-label-sync)))
             `((ok . t) (bufferName . ,(buffer-name buffer)))))
       ((error quit)
        (message "SYZYGY launch failed%s: %s"
                 (if (buffer-live-p buffer) (format " (%s)" (buffer-name buffer)) "")
                 (error-message-string err))
        `((ok . :false) (error . ,(error-message-string err))
          ,@(when (buffer-live-p buffer) `((bufferName . ,(buffer-name buffer))))))))))

(defun syzygy-launch-legacy-json (encoded)
  "Launch a preset, default or clone from ENCODED with structured recovery."
  (let (buffer)
    (syzygy-bridge-encode-json
     (condition-case err
         (let* ((req (json-parse-string (syzygy-bridge-decode-base64 encoded) :object-type 'alist))
                (name (mr-x/agent-shell-spawn-for-mobile
                       (or (alist-get 'cwd req) "") (or (alist-get 'name req) "")
                       (or (alist-get 'task req) "") (alist-get 'preset req)
                       (alist-get 'cloneOf req) (lambda (created) (setq buffer created)))))
           `((ok . t) (bufferName . ,name)))
       ((error quit)
        (message "SYZYGY legacy launch failed%s: %s"
                 (if (buffer-live-p buffer) (format " (%s)" (buffer-name buffer)) "")
                 (error-message-string err))
        `((ok . :false) (error . ,(error-message-string err))
          ,@(when (buffer-live-p buffer) `((bufferName . ,(buffer-name buffer))))))))))

(provide 'syzygy-launch)
;;; syzygy-launch.el ends here
