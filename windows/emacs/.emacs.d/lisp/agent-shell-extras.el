;;; agent-shell-extras.el --- MrX agent-shell comfort layer on Vengeance -*- lexical-binding: t; -*-

;; Port of the macOS agent-shell UX: major-pane side panel + display
;; routing, smart editing keys, launch presets, clone, mode words, refs,
;; picker-based send commands, and the SPC c leader map.  The portable
;; modules (major-pane.el, mr-x-agent-send.el, agent-shell-refs.el) are
;; NOT copied — they load straight from the repo's macos/ lisp dir
;; (init.el puts it on load-path), so MrX improvements flow here free.
;;
;; Deliberately left on the Mac side for now (need Windows shims or
;; uninstalled packages): agent-shell-manager/-attention/-sidebar,
;; permission quick-keys + F13-F16, inbox/pins, agent-terminal.

;;; Code:

;; ---------------------------------------------------------------------------
;; Display routing: agent conversations always land in the major-pane,
;; no matter which code path displays them (agent-shell itself,
;; agent-recall resume, anything calling display-buffer/pop-to-buffer).
;; ---------------------------------------------------------------------------

;; Never display acp stderr buffers in a window.
(add-to-list 'display-buffer-alist
             '("\\`acp-client-stderr"
               (display-buffer-no-window)
               (allow-no-window . t)))

(defun mr-x/agent-pane-buffer-p (buffer-name _action)
  "display-buffer-alist condition matching agent conversation buffers.
Real membership: any `major-pane-modes' (derived included) buffer.
The \"Agent @ \" name match is a mode-free fallback.  Deliberately
package-free: this runs inside display-buffer before major-pane may
be loaded."
  (let ((buf (get-buffer buffer-name)))
    (and buf
         (or (apply #'provided-mode-derived-p
                    (buffer-local-value 'major-mode buf)
                    (if (boundp 'major-pane-modes)
                        major-pane-modes
                      '(agent-shell-mode)))
             (string-match-p "Agent @ " buffer-name)))))

(add-to-list 'display-buffer-alist
             '(mr-x/agent-pane-buffer-p (major-pane-display-buffer-action)))

;; The pane window is soft-dedicated: display-buffer/pop-to-buffer won't
;; hijack it for random buffers (help, grep, ...).  'prompt keeps a
;; deliberate escape hatch for STRONG dedication paths, and the flag
;; below extends the protection to the entire switch-to-buffer family
;; (SPC b b, consult-buffer, find-file...) — from the pane, buffers open
;; in the main area instead.  Deliberate takeover: SPC & b.
(setq switch-to-buffer-in-dedicated-window 'prompt)
(setq switch-to-buffer-obey-display-actions t)

;; Fallback for code that reads this variable directly; the
;; display-buffer-alist entry above takes precedence when it matches.
(with-eval-after-load 'agent-shell
  (setq agent-shell-display-action
        '((display-buffer-in-direction)
          (direction . left)
          (window-width . 0.30))))

;; ---------------------------------------------------------------------------
;; major-pane: the side panel itself (loaded from macos/emacs/.emacs.d/lisp).
;; Win key is `super' (set in init.el), so s-i = Win+i, or home-row
;; Super (hold d/k) + i via kanata.
;; ---------------------------------------------------------------------------

(use-package major-pane
  :ensure nil
  :init
  (global-set-key (kbd "s-i") #'major-pane-toggle)
  (global-set-key (kbd "s-M-<right>") #'major-pane-next-tab)
  (global-set-key (kbd "s-M-<left>") #'major-pane-prev-tab)
  ;; Same chord + shift chases green tabs: next/prev convo with a
  ;; finished, unengaged turn.
  (global-set-key (kbd "s-M-S-<right>") #'major-pane-next-done-tab)
  (global-set-key (kbd "s-M-S-<left>") #'major-pane-prev-done-tab)
  ;; Not a command, so it can't go in :commands — autoloaded by hand so
  ;; the display-buffer-alist entry above can route agent buffers into
  ;; the pane before major-pane loads.
  (autoload 'major-pane-display-buffer-action "major-pane")
  :commands (major-pane-toggle
             major-pane-focus
             major-pane-next-tab
             major-pane-prev-tab
             major-pane-next-done-tab
             major-pane-prev-done-tab
             major-pane-capture-buffer
             major-pane-set-home-frame
             major-pane-new-chat
             major-pane-new-ejected-chat
             major-pane-mark-read
             major-pane-anchor-toggle
             major-pane-set-placement
             major-pane-close-conversation
             major-pane-close-all-conversations
             major-pane-eject-conversation
             major-pane-adopt-conversation
             major-pane-exclude-buffer
             major-pane-swap-buffer
             major-pane-set-label
             major-pane-pick-buffer
             major-pane-goto-conversation)
  :config
  ;; No hydra/posframe on this machine — completing-read picker everywhere.
  (setq major-pane-picker-style 'consult))

;; Send commands (region/file/screenshot → picked conversation); they use
;; major-pane only for the picker and goto.
(use-package mr-x-agent-send
  :ensure nil
  :commands (mr-x/agent-send-region
             mr-x/agent-send-region-no-switch
             mr-x/agent-send-file
             mr-x/agent-send-other-file
             mr-x/agent-send-screenshot))

;; ---------------------------------------------------------------------------
;; Smart editing keys inside agent-shell buffers.
;; ---------------------------------------------------------------------------

(with-eval-after-load 'agent-shell
  ;; Pane tab navigation without Super/Windows-key interception.  Browser
  ;; style: C-<tab> / C-S-<tab> cycle the pane's conversation tabs.  The
  ;; GUI delivers shift-tab as C-S-<tab>; a TTY spells it C-S-<iso-lefttab>.
  ;; This overrides upstream's C-<tab> session-mode cycle, which never got
  ;; used; cycling stays reachable on the leader (SPC c m c).  The C-M
  ;; arrows stay as a fallback; expression navigation is untouched elsewhere.
  (define-key agent-shell-mode-map (kbd "C-<tab>") #'major-pane-next-tab)
  (define-key agent-shell-mode-map (kbd "C-S-<tab>") #'major-pane-prev-tab)
  (define-key agent-shell-mode-map (kbd "C-S-<iso-lefttab>") #'major-pane-prev-tab)
  (define-key agent-shell-mode-map (kbd "C-M-<left>") #'major-pane-prev-tab)
  (define-key agent-shell-mode-map (kbd "C-M-<right>") #'major-pane-next-tab)
  (define-key agent-shell-mode-map (kbd "<backtab>") nil)
  ;; evil-collection re-pins C-<tab> to the mode cycle in its normal-state
  ;; auxiliary map, which outranks the mode map; override it per state.
  (with-eval-after-load 'evil
    (evil-define-key '(normal insert visual motion) agent-shell-mode-map
      (kbd "C-<tab>")           #'major-pane-next-tab
      (kbd "C-S-<tab>")         #'major-pane-prev-tab
      (kbd "C-S-<iso-lefttab>") #'major-pane-prev-tab))

  ;; C-<return> sends the prompt from anywhere in the buffer — port of the
  ;; Mac binding.  `agent-shell-submit' is what plain RET runs (upstream
  ;; remaps comint-send-input to it): queue while busy, M-RET to steer,
  ;; `shell-maker-submit' when idle.  It jumps to the prompt itself before
  ;; sending, so C-RET works from history too.
  (define-key agent-shell-mode-map (kbd "C-<return>") #'agent-shell-submit)

  ;; Smart insert/append/paste — jump to the prompt when point sits in
  ;; the history area, refuse politely while the shell is busy.
  (defun mr-x/agent-shell-smart-insert ()
    "Enter insert mode, jumping to prompt if not already there."
    (interactive)
    (cond
     ((shell-maker-point-at-last-prompt-p)
      (evil-insert-state))
     (t
      (goto-char (point-max))
      (if (shell-maker-point-at-last-prompt-p)
          (evil-insert-state)
        (message "Shell is busy — can't insert yet")))))

  (defun mr-x/agent-shell-smart-append ()
    "Enter append mode, jumping to prompt if not already there."
    (interactive)
    (cond
     ((shell-maker-point-at-last-prompt-p)
      (evil-append 1))
     (t
      (goto-char (point-max))
      (if (shell-maker-point-at-last-prompt-p)
          (evil-append 1)
        (message "Shell is busy — can't insert yet")))))

  (defun mr-x/agent-shell-smart-paste ()
    "Paste text or image from clipboard, jumping to prompt if not already there."
    (interactive)
    (unless (shell-maker-point-at-last-prompt-p)
      (goto-char (point-max)))
    (if (shell-maker-point-at-last-prompt-p)
        (call-interactively #'agent-shell-yank-dwim)
      (message "Shell is busy — can't paste yet")))

  ;; Text-first paste for insert-state C-v.  FluidVoice delivers a dictation
  ;; by writing the transcript to the clipboard, sending Ctrl+V, then
  ;; restoring the previous clipboard ~650ms later.  Upstream remaps `yank'
  ;; to `agent-shell-yank-dwim', whose image probe is a synchronous
  ;; `powershell Get-Clipboard -Format image' call that alone outlasts that
  ;; window, so its trailing `yank' read the restored (old) clipboard.  Read
  ;; the text straight away; only probe for an image when there is none.
  ;; `p' keeps the image-first dwim.
  (defun mr-x/agent-shell-paste-text-first ()
    "Yank clipboard text at the prompt, else fall back to `agent-shell-yank-dwim'."
    (interactive)
    (let ((text (ignore-errors (gui-get-selection 'CLIPBOARD 'STRING))))
      (cond
       ((or (null text) (string-empty-p text))
        (call-interactively #'agent-shell-yank-dwim))
       ((progn
          (unless (shell-maker-point-at-last-prompt-p)
            (goto-char (point-max)))
          (shell-maker-point-at-last-prompt-p))
        (call-interactively #'yank))
       (t
        ;; Never drop a dictation: park it where `p' can fetch it.
        (kill-new text)
        (message "Shell is busy — transcript saved to the kill ring (p to paste)")))))

  (defun mr-x/agent-shell-clear-prompt ()
    "Clear the current prompt input in agent-shell."
    (interactive)
    (goto-char (point-max))
    (let ((inhibit-read-only t))
      (delete-region (comint-line-beginning-position) (point-max))))

  (with-eval-after-load 'evil
    (evil-define-key 'normal agent-shell-mode-map
      (kbd "i") #'mr-x/agent-shell-smart-insert
      (kbd "a") #'mr-x/agent-shell-smart-append
      (kbd "A") #'mr-x/agent-shell-smart-append
      (kbd "o") #'mr-x/agent-shell-smart-append
      (kbd "O") #'mr-x/agent-shell-smart-append
      (kbd "p") #'mr-x/agent-shell-smart-paste)
    (evil-define-key 'insert agent-shell-mode-map
      (kbd "C-v") #'mr-x/agent-shell-paste-text-first)
    ;; Win+Backspace clears the prompt (port of Mac's Cmd+Backspace).
    ;; C-<return> sends from either state (see the mode-map bind above;
    ;; repeated here so evil's insert-state map can't shadow it).
    (evil-define-key '(normal insert) agent-shell-mode-map
      (kbd "s-<backspace>") #'mr-x/agent-shell-clear-prompt
      (kbd "C-<return>") #'agent-shell-submit)))

;; ---------------------------------------------------------------------------
;; Launch presets: model + permission-mode in one keystroke.
;;
;; Both `:default-model-id' and `:default-session-mode-id' are
;; config-level and applied the instant a session starts, so a "preset"
;; is just the preferred config with those two overridden.
;; Valid IDs (from the live ACP session): models "default" (Opus 5.5 1M)
;; "opus[1m]" "fable[1m]" "sonnet" "haiku"; modes "auto"
;; "default" "acceptEdits" "plan" "dontAsk" "bypassPermissions".
;; Codex IDs (from a live codex-acp 2.2.2 session here, 2026-10-10).  The
;; session's model list shows suffixed ids ("gpt-5.6-sol[high]") but those
;; are display-only: the `model' option takes BARE families and rejects
;; suffixed ids with -32602.  Effort is its own `reasoning_effort' option,
;; set post-init.
;;   models: "gpt-6.1-sol" (default) "gpt-6-astra" "gpt-6-sol" "gpt-6-luna"
;;           "gpt-5.6-sol" "gpt-5.6-terra" "gpt-5.6-luna"
;;   modes:  "read-only" "workspace-write" "agent" "agent-full-access"
;;   effort: "low" "medium" "high" "xhigh" "max" "ultra"
;; ---------------------------------------------------------------------------

(defvar mr-x/agent-shell-presets
  '((?f "Fable 5.1 · Bypass" "fable[1m]" "bypassPermissions")
    (?o "Opus 5.5 · Bypass"  "opus[1m]"  "bypassPermissions")
    (?s "Sonnet 5 · Accept"  "sonnet"    "acceptEdits")
    (?p "Opus 5.5 · Plan"    "default"   "plan")
    (?a "Astra 6 · Full"     "gpt-6-astra" "agent-full-access"
        agent-shell-openai-make-codex-config "high")
    (?c "Sol 5.6 · Full"     "gpt-5.6-sol" "agent-full-access"
        agent-shell-openai-make-codex-config "high")
    (?x "Sol 5.6 Max · Full" "gpt-5.6-sol" "agent-full-access"
        agent-shell-openai-make-codex-config "max"))
  "Agent-shell launch presets: (CHAR LABEL MODEL-ID MODE-ID [CONFIG-FN EFFORT]).
Each launches a fresh shell with that model and permission mode.
CONFIG-FN, when present, names the agent-config constructor to base the
shell on (e.g. Codex) instead of the preferred (Claude) config.
EFFORT, when present, is sent as the effort config option once the
session is up.")

(defun mr-x/agent-shell--display-new (shell-buffer)
  "Show SHELL-BUFFER: replace current window when already in an
agent-shell, otherwise pop to it.  Honours viewport interaction."
  (if (derived-mode-p 'agent-shell-mode 'agent-shell-viewport-view-mode
                      'agent-shell-viewport-edit-mode)
      (if agent-shell-prefer-viewport-interaction
          (agent-shell-viewport--show-buffer :shell-buffer shell-buffer)
        (switch-to-buffer shell-buffer))
    (if agent-shell-prefer-viewport-interaction
        (agent-shell-viewport--show-buffer :shell-buffer shell-buffer)
      (pop-to-buffer shell-buffer))))

(defun mr-x/agent-shell--config-with (model-id mode-id &optional config-fn)
  "Copy the preferred agent config, overriding model + session mode.
When CONFIG-FN is non-nil, build the base config by calling it instead
of resolving the preferred config: that's how a preset targets a
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

(defun mr-x/agent-shell--preset-prompt (question)
  "One-line listing of `mr-x/agent-shell-presets' ending in QUESTION."
  (concat "Preset  "
          (mapconcat (lambda (p)
                       (format "[%c] %s" (nth 0 p) (nth 1 p)))
                     mr-x/agent-shell-presets "   ")
          question))

(defun mr-x/agent-shell--read-preset (&optional char)
  "Return a preset tuple from `mr-x/agent-shell-presets'.
Reads a preset CHAR interactively (e.g. ?f) unless supplied, erroring
if it matches no preset."
  (let ((char (or char
                  (read-char-choice
                   (mr-x/agent-shell--preset-prompt ": ")
                   (mapcar #'car mr-x/agent-shell-presets)))))
    (or (assq char mr-x/agent-shell-presets)
        (user-error "No preset for %c" char))))

(defun mr-x/agent-shell--read-preset-or-default ()
  "Read a preset char, or RET/SPC for the default (preferred/Claude) config.
Returns a preset tuple from `mr-x/agent-shell-presets', or nil for the
default config."
  (let* ((chars (mapcar #'car mr-x/agent-shell-presets))
         (char (read-char-choice
                (mr-x/agent-shell--preset-prompt "   (RET = Claude default): ")
                (append chars (list ?\r ?\n ?\s)))))
    (unless (memq char '(?\r ?\n ?\s))
      (or (assq char mr-x/agent-shell-presets)
          (user-error "No preset for %c" char)))))

(defun mr-x/agent-shell--pick-project-dir ()
  "Prompt for a launch directory.  Dashboard projects are offered first
\(by name, path annotated), remaining projectile projects below, and any
path typed by hand is accepted.  Returns an expanded directory."
  (let* ((dashboard (bound-and-true-p project-dashboard-projects))
         ;; dashboard paths (expanded) so we can de-dup projectile
         (dash-paths (mapcar (lambda (p) (expand-file-name (cdr p))) dashboard))
         ;; projectile projects not already in dashboard (skip remote/TRAMP)
         (extra (cl-remove-if (lambda (p) (or (file-remote-p p)
                                              (member (expand-file-name p) dash-paths)))
                              (bound-and-true-p projectile-known-projects)))
         ;; build candidates: ((display . path) ...)
         (candidates (append
                      (mapcar (lambda (p) (cons (car p) (expand-file-name (cdr p))))
                              dashboard)
                      (mapcar (lambda (p) (cons (abbreviate-file-name p) (expand-file-name p)))
                              extra)))
         ;; annotation function shows path for dashboard entries
         (annotate (lambda (cand)
                     (when-let ((path (cdr (assoc cand candidates))))
                       (concat "  " (propertize (abbreviate-file-name path)
                                                'face 'completions-annotations)))))
         (choice (completing-read "Agent shell in: "
                                  (lambda (str pred action)
                                    (if (eq action 'metadata)
                                        `(metadata (annotation-function . ,annotate))
                                      (complete-with-action action candidates str pred))))))
    (or (cdr (assoc choice candidates))
        (expand-file-name choice))))

(defun mr-x/agent-shell--spawn-preset (preset)
  "Spawn a fresh agent shell locked to PRESET (a `mr-x/agent-shell-presets'
tuple).  Honours the current `default-directory' as the shell's cwd."
  (require 'agent-shell)
  (let* ((config (mr-x/agent-shell--config-with (nth 2 preset) (nth 3 preset)
                                                (nth 4 preset)))
         (shell-buffer (agent-shell--start :config config
                                           :no-focus t
                                           :new-session t)))
    (mr-x/agent-shell--display-new shell-buffer)
    (when (nth 5 preset)
      (run-at-time 1 nil #'mr-x/agent-shell--set-effort-when-ready
                   shell-buffer (nth 5 preset) 60))
    (message "Agent preset: %s" (nth 1 preset))))

(defun mr-x/agent-shell-start-preset (&optional char)
  "Start a fresh agent shell from a launch preset.
Reads a preset CHAR from `mr-x/agent-shell-presets' (e.g. ?f) unless
supplied, then spawns a new shell locked to that model + permission mode."
  (interactive)
  (mr-x/agent-shell--spawn-preset (mr-x/agent-shell--read-preset char)))

(defun mr-x/agent-shell-preset-in-project ()
  "Spawn a fresh agent shell: pick a preset (RET = Claude default), then
pick a project/path, then start the shell there.  One-shot answer to
\"new <preset> chat in <project>\"."
  (interactive)
  (require 'agent-shell)
  (let* ((preset (mr-x/agent-shell--read-preset-or-default))
         (default-directory (file-name-as-directory
                             (mr-x/agent-shell--pick-project-dir))))
    (if preset
        (mr-x/agent-shell--spawn-preset preset)
      (mr-x/agent-shell-new-smart))))

(defun mr-x/agent-shell-sol ()
  "Spawn a fresh Sol (Codex, high effort) agent shell in one keystroke:
the `?c' preset from `mr-x/agent-shell-presets'."
  (interactive)
  (mr-x/agent-shell--spawn-preset
   (or (assq ?c mr-x/agent-shell-presets)
       (user-error "No Sol preset (?c) defined"))))

(defun mr-x/agent-shell--preset-agent (preset)
  "Identifier of the agent PRESET spawns, e.g. `claude-code' or `codex'."
  (map-elt (if (nth 4 preset)
               (funcall (nth 4 preset))
             (agent-shell--resolve-preferred-config))
           :identifier))

(defun mr-x/agent-shell-apply-preset (&optional char)
  "Apply a preset's model + permission mode to the CURRENT agent shell.
The two changes are async ACP requests, so they are chained: set the
model first, then the mode, then report the applied preset."
  (interactive)
  (require 'agent-shell)
  (unless (derived-mode-p 'agent-shell-mode)
    (user-error "Not in an agent-shell buffer"))
  (unless (map-nested-elt (agent-shell--state) '(:session :id))
    (user-error "No active session"))
  (let* ((preset (mr-x/agent-shell--read-preset char))
         (label (nth 1 preset))
         (model-id (nth 2 preset))
         (mode-id (nth 3 preset))
         (effort (nth 5 preset))
         (agent (mr-x/agent-shell--preset-agent preset))
         (here (map-nested-elt (agent-shell--state) '(:agent-config :identifier)))
         (buffer (current-buffer)))
    ;; A preset names one agent's ids; another agent's chat would reject
    ;; them.  Switching agents needs a new shell.
    (unless (eq agent here)
      (user-error "%s is a %s preset; this chat is %s.  Use SPC c P for a new shell"
                  label agent here))
    (agent-shell--config-option-set-model-id
     :model-id model-id
     :on-success
     (lambda ()
       (with-current-buffer buffer
         (agent-shell--config-option-set-mode-id
          :mode-id mode-id
          :on-success
          (lambda ()
            (with-current-buffer buffer
              (when effort (mr-x/agent-shell--set-effort effort))
              (message "Agent preset applied: %s" label)))))))))

;; ---------------------------------------------------------------------------
;; Clone: a fresh shell wearing the current shell's agent, model,
;; permission mode, effort and directory.  An independent session; no
;; history is copied.
;; ---------------------------------------------------------------------------

(defun mr-x/agent-shell--clone-config (source)
  "Copy SOURCE's agent config pinned to its live model + permission mode.
SOURCE is an agent-shell buffer."
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
  "Set BUF's effort to EFFORT once its session exists, retrying TRIES times.
The session id lands seconds after spawn."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (if (map-nested-elt agent-shell--state '(:session :id))
          (mr-x/agent-shell--set-effort effort)
        (if (> tries 0)
            (run-at-time 1 nil #'mr-x/agent-shell--set-effort-when-ready
                         buf effort (1- tries))
          (message "agent clone: %s never became ready for effort set"
                   (buffer-name buf)))))))

(defun mr-x/agent-shell-clone ()
  "Start a fresh shell with the current shell's agent, model, and directory.
This creates an independent session; it does not fork or copy history.
Display uses agent-shell's normal path so major-pane controls placement."
  (interactive)
  (require 'agent-shell)
  (unless (derived-mode-p 'agent-shell-mode)
    (user-error "Not in an agent-shell buffer"))
  (let* ((effort (agent-shell--current-thought-level-id (agent-shell--state)))
         (buf (agent-shell--start
               :config (mr-x/agent-shell--clone-config (current-buffer))
               :new-session t
               ;; MrX sets `agent-shell-session-strategy' to `new'
               ;; globally; here it is still `prompt', and a clone must
               ;; never offer to resume something else.
               :session-strategy 'new)))
    (when effort
      (run-at-time 1 nil #'mr-x/agent-shell--set-effort-when-ready buf effort 60))
    buf))

;; ---------------------------------------------------------------------------
;; Show, hide and focus the project's shell.
;; ---------------------------------------------------------------------------

(defun mr-x/agent-shell-toggle ()
  "Toggle agent shell display (fixed to find project shells)."
  (interactive)
  (require 'agent-shell)
  (let ((shell-buffer (cond
                       (agent-shell-prefer-viewport-interaction
                        (agent-shell-viewport--buffer))
                       ((derived-mode-p 'agent-shell-mode)
                        (current-buffer))
                       ((or (derived-mode-p 'agent-shell-viewport-view-mode)
                            (derived-mode-p 'agent-shell-viewport-edit-mode))
                        (agent-shell--current-shell))
                       (t (seq-first (agent-shell-project-buffers))))))
    (unless shell-buffer
      (user-error "No agent shell buffers available for current project"))
    (if-let ((window (get-buffer-window shell-buffer)))
        (if (and (> (count-windows) 1)
                 (not (bound-and-true-p transient--prefix)))
            (delete-window window)
          (switch-to-prev-buffer))
      (agent-shell--display-buffer shell-buffer))))

(defun mr-x/focus-ai-window ()
  "Focus the agent-shell window if visible, otherwise show a message."
  (interactive)
  (let ((ai-window nil))
    (walk-windows
     (lambda (w)
       (when (and (not ai-window)
                  (eq (buffer-local-value 'major-mode (window-buffer w))
                      'agent-shell-mode))
         (setq ai-window w))))
    (if ai-window
        (select-window ai-window)
      (mr-x/agent-shell-toggle))))

;; ---------------------------------------------------------------------------
;; Mode words: SPC c m d/e/p/a/b name a permission level by the rig's
;; word for it (`major-pane-mode-words'), resolved against whatever the
;; chat's agent offers.
;; ---------------------------------------------------------------------------

(defun mr-x/agent-shell--mode-buffer ()
  "The agent-shell buffer a mode key acts on: this one, else the project's."
  (require 'agent-shell)
  (let ((buf (or (and (derived-mode-p 'agent-shell-mode) (current-buffer))
                 (seq-first (agent-shell-project-buffers)))))
    (unless buf (user-error "No agent-shell buffer found"))
    (unless (map-nested-elt (buffer-local-value 'agent-shell--state buf)
                            '(:session :id))
      (user-error "No active session"))
    buf))

(defun mr-x/agent-shell-set-mode-direct (mode-id)
  "Set agent-shell session mode directly by MODE-ID, skipping the picker.
Goes through agent-shell's own setter, which updates the `mode' config
option when the agent has one and only falls back to session/set_mode
otherwise, so the banner sees the change."
  (with-current-buffer (mr-x/agent-shell--mode-buffer)
    (when (equal mode-id (agent-shell--current-mode-id (agent-shell--state)))
      (user-error "Already in %s mode" (or (agent-shell--resolve-session-mode-name
                                            mode-id (agent-shell--get-available-modes
                                                     (agent-shell--state)))
                                           mode-id)))
    (agent-shell--config-option-set-mode-id
     :mode-id mode-id
     :on-failure (lambda (err &rest _) (message "Failed to set mode: %s" err)))))

(defun mr-x/agent-shell--preset-mode-word (mode-id)
  "Short lowercase word for session MODE-ID.
The table lives in `major-pane-mode-words' so the banner and the
SPC c m keys cannot drift apart."
  (require 'major-pane)
  (major-pane-mode-word mode-id))

(defun mr-x/agent-shell--codex-plan-option (state)
  "Codex's `collaboration_mode' option in STATE when it offers \"plan\".
Codex keeps Plan out of its permission modes; Claude and OpenCode don't."
  (when-let ((opt (agent-shell--config-option-by-category state "collaboration_mode")))
    (when (seq-find (lambda (v) (equal "plan" (map-elt v :value)))
                    (map-elt opt :options))
      opt)))

(defun mr-x/agent-shell-set-mode-word (&rest words)
  "Switch to the first offered mode whose word is one of WORDS.
Words come from `mr-x/agent-shell--preset-mode-word', so \"full\" means
bypassPermissions on Claude, agent-full-access on Codex and bypass on
OpenCode.  Codex Plan lives in `collaboration_mode', handled here too."
  (with-current-buffer (mr-x/agent-shell--mode-buffer)
    (let* ((state (agent-shell--state))
           (modes (agent-shell--get-available-modes state))
           (hit (seq-find (lambda (m)
                            (member (mr-x/agent-shell--preset-mode-word
                                     (map-elt m :id))
                                    words))
                          modes))
           (plan-opt (mr-x/agent-shell--codex-plan-option state)))
      (cond
       (hit
        ;; Leaving Codex Plan: drop the collaboration mode too.
        (when (and plan-opt (equal "plan" (map-elt plan-opt :current-value)))
          (agent-shell--set-session-config-option
           :config-id (map-elt plan-opt :id) :value "default"))
        (unless (equal (map-elt hit :id) (agent-shell--current-mode-id state))
          (mr-x/agent-shell-set-mode-direct (map-elt hit :id))))
       ((and plan-opt (member "plan" words))
        (agent-shell--set-session-config-option
         :config-id (map-elt plan-opt :id) :value "plan"
         :on-success (lambda () (message "Session mode: Plan"))))
       (t
        (user-error "No %s mode here; offered: %s"
                    (string-join words "/")
                    (mapconcat (lambda (m) (map-elt m :id)) modes ", ")))))))

;; ---------------------------------------------------------------------------
;; Refs: select text anywhere, attach it as context for the next prompt.
;; The module (lisp/agent-shell-refs.el, shared) is pure Elisp: pulse +
;; overlays + font-lock, nerd-icons optional.  Its modeline indicator
;; rides `mode-line-misc-info', which doom-modeline's stock layout shows.
;; ---------------------------------------------------------------------------

(require 'agent-shell-refs)

(defun mr-x/agent-shell-refs-capture-and-go ()
  "Capture region as a ref, drop its [ref N] marker at the prompt,
land in insert mode ready to write about it.  Use SPC c a R for a
silent context-only capture with no marker."
  (interactive)
  (agent-shell-refs-capture)
  (when-let* ((buf (agent-shell-refs--find-shell-buffer)))
    ;; Just-captured ref is newest in capture order → number = count.
    ;; insert-marker handles the window-focus jump itself.
    (let ((n (length (buffer-local-value 'agent-shell-refs--list buf))))
      (agent-shell-refs-insert-marker n))
    (mr-x/agent-shell-smart-insert)))

(defun mr-x/agent-shell-refs-reply-and-go (n)
  "Insert a [ref N] reply marker at the prompt, land in insert mode."
  (interactive "NReply to ref: ")
  (agent-shell-refs-insert-marker n)
  (mr-x/agent-shell-smart-insert))

;; One named command per digit so which-key shows real names,
;; not anonymous lambdas.
(dotimes (i 9)
  (let ((n (1+ i)))
    (defalias (intern (format "mr-x/agent-shell-refs-reply-%d" n))
      (lambda () (interactive) (mr-x/agent-shell-refs-reply-and-go n))
      (format "Insert a [ref %d] reply marker and enter insert mode." n))))

(with-eval-after-load 'agent-shell
  (agent-shell-refs-setup)
  (with-eval-after-load 'evil
    ;; Visual mode: capture selection as a ref
    (evil-define-key 'visual agent-shell-mode-map
      (kbd "C-c r") #'agent-shell-refs-capture)
    ;; Normal mode: manage refs
    (evil-define-key 'normal agent-shell-mode-map
      (kbd "C-c r") #'agent-shell-refs-preview
      (kbd "C-c R") #'agent-shell-refs-clear)))

;; ---------------------------------------------------------------------------
;; Leader bindings.  SPC c mirrors MrX's map key for key (emacs.org,
;; "Agent Shell"), minus the commands that have not been ported yet.
;; Those keys stay free so both machines keep one layout:
;;   e fork          u park           k K catalogue
;;   B z manager     S test env       j attention        , r test prompt
;;   ! block->vterm  I inbox          H y Y syzygy       N phone push
;;   l W watcher     v V L terminal   1 2 3 0 perms
;;   g G goose       / s d  / s s  / b d  / w  recall
;; ---------------------------------------------------------------------------

(mr-x/leader-def
  "c"     '(:ignore t :wk "agent-shell")
  "c c"   '(mr-x/agent-shell-new-smart :wk "new chat (Claude, here)")
  "c n"   '(mr-x/agent-shell-clone :wk "clone shell (model + here)")
  "c P"   '(mr-x/agent-shell-start-preset :wk "preset → new shell")
  "c C"   '(mr-x/agent-shell-preset-in-project :wk "new chat (preset + where)")
  "c x"  '(mr-x/agent-shell-sol :wk "Sol (Codex) shell")
  "c t"  '(mr-x/agent-shell-toggle :wk "toggle agent shell")
  "c w"   '(mr-x/focus-ai-window :wk "focus AI window")
  "c b"   '(major-pane-swap-buffer :wk "swap panel buffer")
  "c ,"   '(:ignore t :wk "prompts")
  "c , p" '(agent-shell-prompt-compose :wk "compose prompt")
  "c p"   '(mr-x/agent-shell-apply-preset :wk "preset → current shell")
  "c r"   '(mr-x/agent-send-region-no-switch :wk "send region (stay)")
  "c R"   '(mr-x/agent-send-region :wk "send region (go)")
  "c f"   '(mr-x/agent-send-file :wk "send file")
  "c F"   '(mr-x/agent-send-other-file :wk "send other file")
  "c d"   '(agent-shell-send-dwim :wk "send dwim (region/error)")
  "c s"   '(mr-x/agent-send-screenshot :wk "send screenshot")
  "c i"   '(agent-shell-interrupt :wk "interrupt")
  "c o"   '(agent-shell-other-buffer :wk "other buffer (viewport/shell)")
  "c m"   '(:ignore t :wk "mode")
  "c m m" '(agent-shell-set-session-mode :wk "pick mode...")
  "c m o" '(agent-shell-set-session-config-option :wk "set option...")
  "c m c" '(agent-shell-cycle-session-mode :wk "cycle")
  ;; Words, not ids: each resolves against whatever the chat's agent
  ;; offers (see `mr-x/agent-shell-set-mode-word').
  "c m d" '((lambda () (interactive) (mr-x/agent-shell-set-mode-word "manual" "ask" "build")) :wk "manual")
  "c m e" '((lambda () (interactive) (mr-x/agent-shell-set-mode-word "accept edits")) :wk "accept edits")
  "c m p" '((lambda () (interactive) (mr-x/agent-shell-set-mode-word "plan")) :wk "plan")
  "c m a" '((lambda () (interactive) (mr-x/agent-shell-set-mode-word "auto")) :wk "auto")
  "c m b" '((lambda () (interactive) (mr-x/agent-shell-set-mode-word "full")) :wk "full")
  "c ."   '(agent-shell-set-session-model :wk "set model")
  "c T"   '(agent-shell-open-transcript :wk "open transcript")
  "c q"   '(agent-shell-prompt-queue :wk "queue request")
  "c l"   '(:ignore t :wk "logs")
  "c l l" '(agent-shell-toggle-logging :wk "toggle logging")
  "c l v" '(agent-shell-view-traffic :wk "view traffic")
  "c l a" '(agent-shell-view-acp-logs :wk "view acp logs")
  "c l r" '(agent-shell-reset-logs :wk "reset logs")
  "c a"   '(:ignore t :wk "refs")
  "c a r" '(mr-x/agent-shell-refs-capture-and-go :wk "capture ref + go")
  "c a R" '(agent-shell-refs-capture :wk "capture ref")
  "c a c" '(agent-shell-refs-clear :wk "clear refs")
  "c a p" '(agent-shell-refs-preview :wk "preview refs")
  "c a d" '(agent-shell-refs-remove :wk "remove ref")
  ;; SPC c a 1..9 — pair the next words you type with queued ref N.
  ;; Spelled out: `mr-x/leader-def' is a macro, so a dotimes can't
  ;; feed it computed keys the way the Mac's general-define-key loop does.
  "c a n" '(mr-x/agent-shell-refs-reply-and-go :wk "reply to ref…")
  "c a 1" '(mr-x/agent-shell-refs-reply-1 :wk "reply to ref 1")
  "c a 2" '(mr-x/agent-shell-refs-reply-2 :wk "reply to ref 2")
  "c a 3" '(mr-x/agent-shell-refs-reply-3 :wk "reply to ref 3")
  "c a 4" '(mr-x/agent-shell-refs-reply-4 :wk "reply to ref 4")
  "c a 5" '(mr-x/agent-shell-refs-reply-5 :wk "reply to ref 5")
  "c a 6" '(mr-x/agent-shell-refs-reply-6 :wk "reply to ref 6")
  "c a 7" '(mr-x/agent-shell-refs-reply-7 :wk "reply to ref 7")
  "c a 8" '(mr-x/agent-shell-refs-reply-8 :wk "reply to ref 8")
  "c a 9" '(mr-x/agent-shell-refs-reply-9 :wk "reply to ref 9")
  "c /"     '(:ignore t :wk "recall")
  "c / s"   '(:ignore t :wk "search")
  "c / s c" '(agent-recall-consult-search :wk "consult")
  "c / b"   '(:ignore t :wk "browse")
  "c / b a" '(agent-recall-browse :wk "all")
  "c / r"   '(agent-recall-resume :wk "resume")
  "c / B"   '(agent-recall-backfill :wk "backfill")
  "c / t"   '(agent-recall-stats :wk "stats"))

(mr-x/leader-def
  "&" '(:ignore t :wk "pane")
  "& w" '(major-pane-focus :wk "focus pane")
  "& n" '(major-pane-new-chat :wk "new chat")
  "& N" '(major-pane-new-ejected-chat :wk "new ejected chat (C-u: new frame)")
  "& l" '(major-pane-set-label :wk "label conversation")
  "& r" '(major-pane-mark-read :wk "mark read (clear green)")
  "& p" '(major-pane-anchor-toggle :wk "anchor tab left (blue rail)")
  "& b" '(major-pane-capture-buffer :wk "capture buffer into pane")
  "& h" '(major-pane-set-home-frame :wk "lock pane to this frame")
  "& m" '(major-pane-set-placement :wk "pane placement")
  "& k" '(major-pane-close-conversation :wk "close conversation")
  "& K" '(major-pane-close-all-conversations :wk "close all")
  "& e" '(major-pane-eject-conversation :wk "eject to main window")
  "& a" '(major-pane-adopt-conversation :wk "adopt back into pane")
  "& f" '((lambda () (interactive)
            (let ((current-prefix-arg '(4)))
              (call-interactively #'major-pane-toggle)))
          :wk "toggle fullscreen"))

(provide 'agent-shell-extras)
;;; agent-shell-extras.el ends here
