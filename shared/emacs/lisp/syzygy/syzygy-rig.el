;;; syzygy-rig.el --- Rig helpers SYZYGY calls: presets, spawn, labels, status -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; The agent-shell helpers that acp-mobile reaches through emacsclient
;; (/api/spawn, /api/label, /api/kill) and the sidecar writers it reads
;; (labels.json, status.json), plus the launch presets they share with
;; the desk's SPC c P.  Moved verbatim out of emacs.org; the desk-only
;; commands that call them (`mr-x/agent-shell-apply-preset',
;; `mr-x/agent-shell-clone', the keybindings) stay there.
;;
;; RULE: no hard `require' of `agent-shell', `shell-maker' or
;; `major-pane'.  This file is loaded from agent-shell-config.el through
;; syzygy.el, and Elpaca has not activated packages in batch mode.
;; Their functions are declared below; every `major-pane--labels' read
;; is guarded by `boundp', every `major-pane-set-buffer-label' call by
;; `fboundp', and the advice on `major-pane-set-label' and
;; `agent-shell-restart' is installed once major-pane loads.

;;; Code:

(require 'json)
(require 'map)
(require 'seq)
(require 'subr-x)
(require 'syzygy-state)
(require 'syzygy-launch)
(require 'syzygy-recall)
(require 'syzygy-live)

(declare-function major-pane-set-buffer-label "major-pane")
(declare-function agent-shell--start "agent-shell")
(declare-function agent-shell--state "agent-shell")
(declare-function agent-shell--resolve-preferred-config "agent-shell")
(declare-function agent-shell--current-model-id "agent-shell")
(declare-function agent-shell--current-mode-id "agent-shell")
(declare-function agent-shell--current-thought-level-id "agent-shell")
(declare-function agent-shell--config-option-by-category "agent-shell")
(declare-function agent-shell-viewport--show-buffer "agent-shell-viewport")
(declare-function shell-maker-submit "shell-maker")
(declare-function shell-maker-busy "shell-maker")

(defvar agent-shell--state)
(defvar agent-shell-prefer-viewport-interaction)
(defvar agent-shell-on-exit)
(defvar major-pane--labels)
(defvar mr-x/pending-permissions-queue)

;; Also called by the moved code, all at run time, never at load time.
;; The agent-shell ones resolve once agent-shell loads; the mr-x/ ones
;; are the Mac rig's (emacs.org: `mr-x/color', the Codex-account
;; helpers) and are defined before any of this runs on the Mac.
(declare-function agent-shell-select-config "agent-shell")
(declare-function agent-shell--set-session-config-option "agent-shell")
(declare-function agent-shell--current-shell "agent-shell")
(declare-function major-pane-mode-word "major-pane")
(declare-function mr-x/color "init")
(declare-function mr-x/agent-shell--codex-preset-p "init")
(declare-function mr-x/agent-shell--read-codex-account "init")
(declare-function mr-x/agent-shell--config-for-codex-account "init")
(defvar mr-x/agent-shell-codex-accounts)

(defun mr-x/agent-shell--display-new (shell-buffer)
  "Show SHELL-BUFFER: replace current window when already in an
agent-shell, otherwise pop to it. Honours viewport interaction."
  (if (derived-mode-p 'agent-shell-mode 'agent-shell-viewport-view-mode
                      'agent-shell-viewport-edit-mode)
      ;; Already in agent-shell: replace current window
      (if agent-shell-prefer-viewport-interaction
          (agent-shell-viewport--show-buffer :shell-buffer shell-buffer)
        (switch-to-buffer shell-buffer))
    ;; Not in agent-shell: use normal display
    (if agent-shell-prefer-viewport-interaction
        (agent-shell-viewport--show-buffer :shell-buffer shell-buffer)
      (pop-to-buffer shell-buffer))))

(defvar mr-x/agent-shell-presets
  '((?f "Fable 5.1 · Full" "claude-fable-5-1"    "bypassPermissions")
    (?o "Opus 5.5 · Full"  "opus"                "bypassPermissions")
    (?s "Sonnet 5.5 · Accept edits" "sonnet"     "acceptEdits")
    (?p "Opus 5.5 · Plan"  "default"             "plan")
    (?a "Astra 6 · Full"   "gpt-6-astra"         "agent-full-access"
        agent-shell-openai-make-codex-config "high")
    (?c "Sol 6.1 · Full"   "gpt-6.1-sol"         "agent-full-access"
        agent-shell-openai-make-codex-config "high")
    (?x "Sol 6.1 Max · Full" "gpt-6.1-sol"       "agent-full-access"
        agent-shell-openai-make-codex-config "max")
    (?O "Luna 6 · Build"   "openai/gpt-6-luna"   "build"
        agent-shell-opencode-make-agent-config)
    (?g "GLM 5.3 Flash · Full" "openrouter/z-ai/glm-5.3-flash" "bypass"
        agent-shell-opencode-make-agent-config)
    (?d "DeepSeek Chat · Accept edits" "default" "acceptEdits"
        mr-x/agent-shell-make-deepseek-config))
  "Agent-shell launch presets: (CHAR LABEL MODEL-ID MODE-ID [CONFIG-FN EFFORT]).
Each launches a fresh shell with that model and permission mode.
CONFIG-FN, when present, names the agent-config constructor to base the
shell on (e.g. Codex) instead of the preferred (Claude) config.
EFFORT, when present, is sent as the `reasoning_effort' config option
once the session is up (Codex-only concept).")

(defun mr-x/agent-shell--set-effort (effort &optional on-success)
  "Set the current chat's effort to EFFORT, calling ON-SUCCESS after.
Found by ACP category `thought_level', not id: Claude and OpenCode name
the option \"effort\", Codex \"reasoning_effort\".  Errors when the
agent has no such option or does not offer EFFORT."
  (let ((opt (agent-shell--config-option-by-category (agent-shell--state)
                                                     "thought_level")))
    (unless opt (user-error "This agent has no effort setting"))
    (unless (seq-find (lambda (v) (equal effort (map-elt v :value)))
                      (map-elt opt :options))
      (user-error "Effort %s not offered here" effort))
    (if (equal effort (map-elt opt :current-value))
        (when on-success (funcall on-success))
      (agent-shell--set-session-config-option
       :config-id (map-elt opt :id) :value effort
       :on-success on-success))))

(defun mr-x/agent-shell--set-effort-when-ready (buf effort tries)
  "Set BUF's `reasoning_effort' config option to EFFORT once its
session exists, retrying TRIES times (the session id lands seconds
after spawn, same dance as `mr-x/agent-spawn--send-when-ready')."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (if (map-nested-elt agent-shell--state '(:session :id))
          (mr-x/agent-shell--set-effort effort)
        (if (> tries 0)
            (run-at-time 1 nil #'mr-x/agent-shell--set-effort-when-ready
                         buf effort (1- tries))
          (message "agent preset: %s never became ready for effort set"
                   (buffer-name buf)))))))

(defun mr-x/agent-shell--config-with (model-id mode-id &optional config-fn)
  "Copy the preferred agent config, overriding model + session mode.
When CONFIG-FN is non-nil, build the base config by calling it instead
of resolving the preferred config — that's how a preset targets a
different agent (Codex) entirely.  Returns a fresh config alist so the
original is left untouched."
  (let ((config (copy-alist
                 (or (and config-fn (funcall config-fn))
                     (and (fboundp 'agent-shell--resolve-preferred-config)
                          (agent-shell--resolve-preferred-config))
                     (agent-shell-select-config :prompt "Start new agent: ")
                     (error "No agent config found")))))
    (setf (alist-get :default-model-id config) (lambda () model-id))
    (setf (alist-get :default-session-mode-id config) (lambda () mode-id))
    config))

;; ── Preset picker rendering ──────────────────────────
;; One row per vendor, keys bold, vendor in its palette hue, mode word
;; colored by how much rope it gives the agent.  Rows come from each
;; preset's config constructor, so a new preset lands in its row on
;; its own.  The question sits on the last line where the cursor is.
(defvar mr-x/agent-shell--preset-vendors
  '((claude   "Claude"   orange)
    (codex    "Codex"    green)
    (opencode "OpenCode" lime)
    (deepseek "DeepSeek" gold)
    (other    "Other"    cream))
  "Preset rows: (VENDOR LABEL PALETTE-COLOR), in display order.")

(defun mr-x/agent-shell--preset-vendor (preset)
  "Vendor symbol for PRESET, from its config constructor (nil = Claude)."
  (pcase (nth 4 preset)
    ('nil 'claude)
    ('agent-shell-openai-make-codex-config 'codex)
    ('agent-shell-opencode-make-agent-config 'opencode)
    ('mr-x/agent-shell-make-deepseek-config 'deepseek)
    (_ 'other)))

(defun mr-x/agent-shell--buffer-vendor ()
  "Vendor symbol for the current chat, matching `mr-x/agent-shell--preset-vendor'.
DeepSeek runs on the Claude adapter, so only its mode-line name tells."
  (let ((config (map-elt (agent-shell--state) :agent-config)))
    (pcase (map-elt config :identifier)
      ('claude-code (if (equal (map-elt config :mode-line-name) "DeepSeek")
                        'deepseek 'claude))
      ('codex 'codex)
      ('opencode 'opencode)
      (_ 'other))))

(defun mr-x/agent-shell--preset-mode-word (mode-id)
  "Short lowercase word for session MODE-ID.
The table lives in `major-pane-mode-words' so the banner, this picker
and the SPC c m keys cannot drift apart."
  (require 'major-pane)
  (major-pane-mode-word mode-id))

(defun mr-x/agent-shell--preset-mode-color (word)
  "Palette color name for a mode WORD: red for no guardrails, down to mint."
  (pcase word
    ("full" 'red)
    ((or "accept edits" "auto") 'gold)
    ("build" 'lime)
    (_ 'mint)))

(defun mr-x/agent-shell--preset-entry (preset vendor-label)
  "Render one PRESET as \"k Model mode\", dropping VENDOR-LABEL from the model."
  (let* ((label (nth 1 preset))
         (model (string-trim (replace-regexp-in-string " · .*\\'" "" label)))
         (model (if (and (string-prefix-p vendor-label model)
                         (> (length model) (length vendor-label)))
                    (string-trim (substring model (length vendor-label)))
                  model))
         (word (mr-x/agent-shell--preset-mode-word (nth 3 preset))))
    (concat (propertize (string (nth 0 preset)) 'face 'bold)
            " " model " "
            (propertize word 'face
                        `(:foreground ,(mr-x/color
                                        (mr-x/agent-shell--preset-mode-color word)))))))

(defun mr-x/agent-shell--preset-prompt (question)
  "Multi-line colored listing of `mr-x/agent-shell-presets' ending in QUESTION."
  (let* ((width (apply #'max (mapcar (lambda (v) (length (nth 1 v)))
                                     mr-x/agent-shell--preset-vendors)))
         (rows
          (delq nil
                (mapcar
                 (lambda (vendor)
                   (let ((presets (seq-filter
                                   (lambda (p) (eq (mr-x/agent-shell--preset-vendor p)
                                                   (car vendor)))
                                   mr-x/agent-shell-presets)))
                     (when presets
                       (concat
                        (propertize (format (format "%%-%ds" width) (nth 1 vendor))
                                    'face `(:foreground ,(mr-x/color (nth 2 vendor))
                                            :weight bold))
                        "  "
                        (mapconcat (lambda (p) (mr-x/agent-shell--preset-entry p (nth 1 vendor)))
                                   presets "   ")
                        (when (and (eq (car vendor) 'codex)
                                   (> (length mr-x/agent-shell-codex-accounts) 1))
                          (propertize "   asks account" 'face 'shadow))))))
                 mr-x/agent-shell--preset-vendors))))
    (concat (string-join rows "\n") "\n" question)))

(defun mr-x/agent-shell--read-preset (&optional char)
  "Return a preset tuple from `mr-x/agent-shell-presets'.
Reads a preset CHAR interactively (e.g. ?f) unless supplied, erroring
if it matches no preset."
  (let ((char (or char
                  (read-char-choice
                   (mr-x/agent-shell--preset-prompt "Preset: ")
                   (mapcar #'car mr-x/agent-shell-presets)))))
    (or (assq char mr-x/agent-shell-presets)
        (user-error "No preset for %c" char))))

(defun mr-x/agent-shell--spawn-preset (preset)
  "Spawn a fresh agent shell locked to PRESET (a `mr-x/agent-shell-presets'
tuple).  Honours the current `default-directory' as the shell's cwd, so
callers can `let'-bind it to launch the preset in another project."
  (require 'agent-shell)
  (let* ((account (when (mr-x/agent-shell--codex-preset-p preset)
                    (mr-x/agent-shell--read-codex-account)))
         (config (mr-x/agent-shell--config-with (nth 2 preset) (nth 3 preset)
                                                (nth 4 preset)))
         (config (if account
                     (mr-x/agent-shell--config-for-codex-account config account)
                   config))
         (shell-buffer (agent-shell--start :config config
                                           :no-focus t
                                           :new-session t)))
    (mr-x/agent-shell--display-new shell-buffer)
    (when (nth 5 preset)
      (run-at-time 1 nil #'mr-x/agent-shell--set-effort-when-ready
                   shell-buffer (nth 5 preset) 60))
    (message "Agent preset: %s%s" (nth 1 preset)
             (if (cdr account) (format " (%s)" (car account)) ""))))

(defun mr-x/agent-shell-start-preset (&optional char)
  "Start a fresh agent shell from a launch preset.
Reads a preset CHAR from `mr-x/agent-shell-presets' (e.g. ?f) unless
supplied, then spawns a new shell locked to that model + permission mode."
  (interactive)
  (mr-x/agent-shell--spawn-preset (mr-x/agent-shell--read-preset char)))

;; Mirror major-pane labels into acp-mobile's sidecar
;; (~/.acp-mobile/labels.json, sessionId → label) so phone cards
;; show the same names as the rig.  Syncs ALL live agent-shell
;; buffers on every label change, which handles set + clear alike.
(defun mr-x/agent-label-sync (&rest _)
  "Write agent-shell buffers' major-pane labels to the acp-mobile sidecar."
  (let* ((inhibit-quit t)          ; see mr-x/agent-label-set
         (file (syzygy-state-file "labels.json"))
         (labels (or (ignore-errors
                       (json-parse-string
                        (with-temp-buffer
                          (insert-file-contents file)
                          (buffer-string))))
                     (make-hash-table :test #'equal))))
    (dolist (buf (buffer-list))
      (when-let* (((buffer-live-p buf))
                  (sid (with-current-buffer buf
                         (and (derived-mode-p 'agent-shell-mode)
                              (map-nested-elt agent-shell--state
                                              '(:session :id))))))
        (syzygy-recall-sidecar-label-put
         labels sid (and (boundp 'major-pane--labels)
                         (gethash buf major-pane--labels)))))
    (make-directory (syzygy-state-dir) t)
    (with-temp-file file (insert (json-serialize labels)))))
(with-eval-after-load 'major-pane
  (advice-add 'major-pane-set-label :after #'mr-x/agent-label-sync))

;; Labels (and live mode) must survive SPC c y: agent-shell-restart
;; kills the buffer and creates a replacement under the same name,
;; but major-pane--labels is keyed by buffer OBJECT — the entry
;; died with the buffer (observed: label vanishing after one
;; resync).  Carry both to the successor; the label-heal timer
;; then mirrors the new session id to labels.json within 3s.
(defun mr-x/agent-label--keep-across-restart (orig &rest args)
  "Carry pane label and live mode across ORIG (`agent-shell-restart')."
  (let* ((old-buf (ignore-errors (agent-shell--current-shell)))
         (name (and old-buf (buffer-name old-buf)))
         (label (and old-buf (boundp 'major-pane--labels)
                     (gethash old-buf major-pane--labels)))
         (live (and old-buf (buffer-local-value 'syzygy-live-mode old-buf))))
    (prog1 (apply orig args)
      (when name
        (when-let ((new-buf (get-buffer name)))
          (unless (eq new-buf old-buf)
            (when (and label (fboundp 'major-pane-set-buffer-label))
              (major-pane-set-buffer-label new-buf label))
            (when live (with-current-buffer new-buf
                         (syzygy-live-mode 1)))))))))
(with-eval-after-load 'major-pane
  (advice-add 'agent-shell-restart :around
              #'mr-x/agent-label--keep-across-restart))

;; Phone-side labeling: acp-mobile's /api/label calls this via
;; emacsclient (same bridge as /api/kill).  Updates the same
;; major-pane hash the rig uses, then syncs the sidecar — one
;; source of truth, label shows in SPC b b and on phone cards.
(defun mr-x/agent-label-set (buffer-name label)
  "Set LABEL on BUFFER-NAME's convo (empty LABEL clears).  For acp-mobile."
  ;; inhibit-quit: a stray C-g mid-eval once split the state —
  ;; hash updated, labels.json never written ("*ERROR*: Quit" back
  ;; to /api/label) — so the rig and the phone disagreed until the
  ;; next sync.  Hash write + mirror must be atomic wrt quits.
  (let ((inhibit-quit t))
    (when-let ((buf (get-buffer buffer-name)))
      (when (fboundp 'major-pane-set-buffer-label)
        (if (string-empty-p label)
            (major-pane-set-buffer-label buf nil)
          (major-pane-set-buffer-label buf label)))
      (mr-x/agent-label-sync)
      t)))

;; Phone-side spawn/kill: the receiving ends of acp-mobile's
;; /api/spawn (via the agent-shell-spawn script) and /api/kill.
;; The phone-typed name becomes the pane label; a task, if given,
;; is submitted once the session handshake completes.
(defun mr-x/agent-spawn--send-when-ready (buf task tries)
  "Once BUF's ACP session exists: sync labels, then submit TASK (if any).
The session id arrives seconds after spawn, so both the label→sidecar
sync and the first prompt must wait for it; retry TRIES times.
Quit-proof: a desk-side C-g/ESC aborts whatever elisp is mid-flight,
timer invocations included — one stray quit used to kill the whole
one-shot chain (no label, no first prompt, no error anywhere).  The
ready branch runs under `inhibit-quit' and swallows the deferred quit;
an aborted invocation reschedules itself like a not-ready one."
  (when (buffer-live-p buf)
    (condition-case nil
        (with-current-buffer buf
          (if (map-nested-elt agent-shell--state '(:session :id))
              (let ((inhibit-quit t))
                (mr-x/agent-label-sync)
                (unless (string-empty-p task)
                  (goto-char (point-max))
                  (insert task)
                  (shell-maker-submit))
                (setq quit-flag nil))
            (if (> tries 0)
                (run-at-time 1 nil #'mr-x/agent-spawn--send-when-ready
                             buf task (1- tries))
              (message "agent spawn: %s never became ready" (buffer-name buf)))))
      ((quit error)
       (when (> tries 0)
         (run-at-time 1 nil #'mr-x/agent-spawn--send-when-ready
                      buf task (1- tries)))))))

(defun mr-x/agent-shell--clone-config (source)
  "Copy SOURCE's agent config pinned to its live model + permission mode.
SOURCE is an agent-shell buffer.  This is what `mr-x/agent-shell-clone'
does for the rig; the phone's Clone menu item reaches it through
`mr-x/agent-shell-spawn-for-mobile'."
  (with-current-buffer source
    (unless (derived-mode-p 'agent-shell-mode)
      (error "Not an agent-shell buffer: %s" (buffer-name source)))
    (let* ((state (agent-shell--state))
           (config (copy-alist (map-elt state :agent-config)))
           (model-id (agent-shell--current-model-id state))
           (mode-id (agent-shell--current-mode-id state)))
      (when model-id
        (setf (alist-get :default-model-id config)
              (lambda () model-id)))
      (when mode-id
        (setf (alist-get :default-session-mode-id config)
              (lambda () mode-id)))
      config)))

(defun mr-x/agent-shell-spawn-for-mobile (cwd name task &optional preset clone-of on-created)
  "Spawn an agent-shell convo in CWD, label it NAME, confirm then send TASK.
PRESET, when non-empty, is a char key into `mr-x/agent-shell-presets'
\(e.g. \"f\") — the shell launches with that preset's model +
permission mode, same as C-u SPC c P on the rig.
CLONE-OF, when non-empty, names an existing agent-shell buffer: the new
convo copies its agent, model, permission mode and directory (what
SPC c n does on the rig), CWD may then be empty, and an empty NAME
inherits the source's pane label with a \" 2\" suffix.  A PRESET
still wins over the copied model + mode.  ON-CREATED receives the new
buffer before settings are applied, so the JSON bridge can recover it
even if confirmation fails."
  (let* ((source (and clone-of (not (string-empty-p clone-of))
                      (or (get-buffer clone-of)
                          (error "No such buffer: %s" clone-of))))
         (dir (file-name-as-directory
               (expand-file-name
                (if (and source (or (null cwd) (string-empty-p cwd)))
                    (buffer-local-value 'default-directory source)
                  cwd)))))
    (unless (file-directory-p dir)
      (error "No such directory: %s" dir))
    (let* ((default-directory dir)
           (tuple (and preset (not (string-empty-p preset))
                       (or (assq (string-to-char preset)
                                 mr-x/agent-shell-presets)
                           (error "No preset for %s" preset))))
           (config (cond
                    (tuple (mr-x/agent-shell--config-with
                            (nth 2 tuple) (nth 3 tuple) (nth 4 tuple)))
                    (source (mr-x/agent-shell--clone-config source))
                    (t (agent-shell--resolve-preferred-config))))
           (model-fn (map-elt config :default-model-id))
           (mode-fn (map-elt config :default-session-mode-id))
           (settings `((agent . ,(syzygy-launch--config-id config))
                       (model . ,(when (functionp model-fn) (funcall model-fn)))
                       (mode . ,(when (functionp mode-fn) (funcall mode-fn)))
                       (effort . ,(or (nth 5 tuple)
                                      (and source (not tuple)
                                           (agent-shell--current-thought-level-id
                                            (buffer-local-value 'agent-shell--state source)))))))
           (label (cond
                   ((and name (not (string-empty-p name))) name)
                   (source
                    (when-let ((src-label (and (boundp 'major-pane--labels)
                                            (gethash source major-pane--labels))))
                      (concat src-label " 2")))))
           (config (copy-alist config))
           (_ (setf (alist-get :default-model-id config) nil
                    (alist-get :default-session-mode-id config) nil
                    (alist-get :default-config-options config) nil))
           (buf (agent-shell--start
                 :config config
                 :new-session t :no-focus t)))
      (when on-created (funcall on-created buf))
      (when (and label (fboundp 'major-pane-set-buffer-label))
        (major-pane-set-buffer-label buf label))
      (syzygy-launch--configure buf settings (or task ""))
      (mr-x/agent-label-sync)
      (buffer-name buf))))

(defun meta-agent-shell-close-session (buffer-name)
  "Kill BUFFER-NAME's agent-shell session.  Called by acp-mobile /api/kill."
  (when-let ((buf (get-buffer buffer-name)))
    (with-current-buffer buf
      (setq agent-shell-on-exit nil))
    (let ((kill-buffer-query-functions nil))
      (kill-buffer buf))
    t))

;; Convo status → phone cards (like major-pane's busy markers):
;; poll every 3s, write ~/.acp-mobile/status.json (sessionId →
;; busy/permission/idle) only when something changed.  acp-mobile
;; reads it in /api/sessions.
(defvar mr-x/agent-status--last nil
  "Last serialized status JSON, to skip redundant writes.")

(defun mr-x/agent-status-sync ()
  "Write every agent-shell convo's busy state to the acp-mobile sidecar."
  (let ((statuses (make-hash-table :test #'equal)))
    (dolist (buf (buffer-list))
      (when-let* (((buffer-live-p buf))
                  (sid (with-current-buffer buf
                         (and (derived-mode-p 'agent-shell-mode)
                              (map-nested-elt agent-shell--state
                                              '(:session :id))))))
        (puthash sid
                 (cond ((seq-find (lambda (p) (eq (plist-get p :buffer) buf))
                                  (bound-and-true-p mr-x/pending-permissions-queue))
                        "permission")
                       ;; Local requests have shell-maker's exact busy
                       ;; bit.  Phone requests bypass shell-maker, so
                       ;; syzygy-live tracks their synthesized user and
                       ;; turn_complete lifecycle separately.
                       ((with-current-buffer buf
                          (or (shell-maker-busy)
                              (bound-and-true-p
                               syzygy-live--remote-turn-active)))
                        "busy")
                       (t "idle"))
                 statuses)))
    (let ((json (json-serialize statuses)))
      (unless (equal json mr-x/agent-status--last)
        (setq mr-x/agent-status--last json)
        (make-directory (syzygy-state-dir) t)
        (with-temp-file (syzygy-state-file "status.json")
          (insert json))))))

(defun mr-x/agent-status--sync-after-event (&rest args)
  "Mirror status after an agent-shell lifecycle event in ARGS."
  (when (memq (plist-get args :event)
              '(input-submitted permission-request permission-response
                turn-complete error clean-up))
    ;; Defer one event-loop turn so permission queue cleanup and
    ;; shell-maker's busy transition have both settled.
    (run-at-time 0 nil #'mr-x/agent-status-sync)))

;; Label self-heal on the same cadence: one-shot label syncs
;; (phone /api/label evals, the spawn timer chain) can be aborted
;; by a desk-side C-g mid-flight, leaving the rig's label hash
;; and labels.json disagreeing with no error anywhere.  This
;; repeating timer survives aborted ticks by design, so drift
;; lasts 3s at most.
(defvar mr-x/agent-label--live-last 'unset
  "Live (sid . label) pairs at the last sidecar sync.")

(defun mr-x/agent-label-heal ()
  "Re-run the label sidecar sync whenever live labels drift."
  (let (pairs)
    (dolist (buf (buffer-list))
      (when-let* (((buffer-live-p buf))
                  (sid (with-current-buffer buf
                         (and (derived-mode-p 'agent-shell-mode)
                              (map-nested-elt agent-shell--state
                                              '(:session :id))))))
        (push (cons sid (and (boundp 'major-pane--labels)
                             (gethash buf major-pane--labels)))
              pairs)))
    (setq pairs (sort pairs (lambda (a b) (string< (car a) (car b)))))
    (unless (equal pairs mr-x/agent-label--live-last)
      (mr-x/agent-label-sync)
      (setq mr-x/agent-label--live-last pairs))))

;; Start the sidecar writers only once agent-shell is loaded: a bare
;; `require' (a batch test run, a process without the rig) must not
;; start timers or hooks that write {} over the live status.json.
(with-eval-after-load 'agent-shell
  ;; Remote turn boundaries are explicit, so mirror those immediately;
  ;; the 3s timer below remains the safety net for every other path.
  (add-hook 'syzygy-live-turn-state-change-hook
            #'mr-x/agent-status-sync)

  (advice-remove 'agent-shell--emit-event
                 #'mr-x/agent-status--sync-after-event)
  (advice-add 'agent-shell--emit-event :after
              #'mr-x/agent-status--sync-after-event)

  ;; Idempotent creation: a re-load must not stack duplicate timers,
  ;; and a wedged timer object (observed: next-fire 53h in the past,
  ;; never firing) gets replaced by a fresh one.
  (cancel-function-timers #'mr-x/agent-status-sync)
  (cancel-function-timers #'mr-x/agent-label-heal)
  (run-with-timer 5 3 #'mr-x/agent-status-sync)
  (run-with-timer 6 3 #'mr-x/agent-label-heal))

(provide 'syzygy-rig)
;;; syzygy-rig.el ends here
