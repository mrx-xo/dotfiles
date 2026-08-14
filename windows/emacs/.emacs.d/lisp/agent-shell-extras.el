;;; agent-shell-extras.el --- MrX agent-shell comfort layer on Vengeance -*- lexical-binding: t; -*-

;; Port of the macOS agent-shell UX: major-pane side panel + display
;; routing, smart editing keys, launch presets, and picker-based send
;; commands.  The portable modules (major-pane.el, mr-x-agent-send.el)
;; are NOT copied — they load straight from the repo's macos/ lisp dir
;; (init.el puts it on load-path), so MrX improvements flow here free.
;;
;; Deliberately left on the Mac side for now (need Windows shims or
;; uninstalled packages): agent-shell-manager/-attention/-sidebar,
;; permission quick-keys + F13-F16, refs/inbox/pins, agent-terminal.

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
  ;; S-<tab> cycles the session mode (permission level).
  (define-key agent-shell-mode-map (kbd "<backtab>") #'agent-shell-cycle-session-mode)

  ;; C-<return> sends the prompt from anywhere in the buffer — port of the
  ;; Mac binding.  Plain RET is the shell-maker remap of comint-send-input
  ;; to `shell-maker-submit', which is exactly what we reuse here; it jumps
  ;; to the prompt itself before sending, so C-RET works from history too.
  (define-key agent-shell-mode-map (kbd "C-<return>") #'shell-maker-submit)

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
    ;; Win+Backspace clears the prompt (port of Mac's Cmd+Backspace).
    ;; C-<return> sends from either state (see the mode-map bind above;
    ;; repeated here so evil's insert-state map can't shadow it).
    (evil-define-key '(normal insert) agent-shell-mode-map
      (kbd "s-<backspace>") #'mr-x/agent-shell-clear-prompt
      (kbd "C-<return>") #'shell-maker-submit)))

;; ---------------------------------------------------------------------------
;; Launch presets: model + permission-mode in one keystroke.
;;
;; Both `:default-model-id' and `:default-session-mode-id' are
;; config-level and applied the instant a session starts, so a "preset"
;; is just the preferred config with those two overridden.
;; Valid IDs (from the live ACP session): models "default" (Opus 1M)
;; "opus[1m]" "claude-fable-5[1m]" "sonnet" "haiku"; modes "auto"
;; "default" "acceptEdits" "plan" "dontAsk" "bypassPermissions".
;; ---------------------------------------------------------------------------

(defvar mr-x/agent-shell-presets
  '((?f "Fable · Bypass"  "claude-fable-5[1m]" "bypassPermissions")
    (?o "Opus · Bypass"   "opus[1m]"           "bypassPermissions")
    (?s "Sonnet · Accept" "sonnet"             "acceptEdits")
    (?p "Opus · Plan"     "default"            "plan")
    (?h "Haiku · Auto"    "haiku"              "auto"))
  "Agent-shell launch presets: (CHAR LABEL MODEL-ID MODE-ID).
Each launches a fresh shell with that model and permission mode.")

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

(defun mr-x/agent-shell--config-with (model-id mode-id)
  "Copy the preferred agent config, overriding model + session mode.
Returns a fresh config alist so the original is left untouched."
  (let ((config (copy-alist
                 (or (and (fboundp 'agent-shell--resolve-preferred-config)
                          (agent-shell--resolve-preferred-config))
                     (agent-shell-select-config :prompt "Start new agent: ")
                     (error "No agent config found")))))
    (setf (alist-get :default-model-id config) (lambda () model-id))
    (setf (alist-get :default-session-mode-id config) (lambda () mode-id))
    config))

(defun mr-x/agent-shell--read-preset (&optional char)
  "Return a preset tuple from `mr-x/agent-shell-presets'.
Reads a preset CHAR interactively (e.g. ?f) unless supplied, erroring
if it matches no preset."
  (let ((char (or char
                  (read-char-choice
                   (concat "Preset  "
                           (mapconcat (lambda (p)
                                        (format "[%c] %s" (nth 0 p) (nth 1 p)))
                                      mr-x/agent-shell-presets "   ")
                           ": ")
                   (mapcar #'car mr-x/agent-shell-presets)))))
    (or (assq char mr-x/agent-shell-presets)
        (user-error "No preset for %c" char))))

(defun mr-x/agent-shell-start-preset (&optional char)
  "Start a fresh agent shell from a launch preset.
Reads a preset CHAR from `mr-x/agent-shell-presets' (e.g. ?f) unless
supplied, then spawns a new shell locked to that model + permission mode."
  (interactive)
  (require 'agent-shell)
  (let* ((preset (mr-x/agent-shell--read-preset char))
         (config (mr-x/agent-shell--config-with (nth 2 preset) (nth 3 preset)))
         (shell-buffer (agent-shell--start :config config
                                           :no-focus t
                                           :new-session t)))
    (mr-x/agent-shell--display-new shell-buffer)
    (message "Agent preset: %s" (nth 1 preset))))

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
         (buffer (current-buffer)))
    (agent-shell--config-option-set-model-id
     :model-id model-id
     :on-success
     (lambda ()
       (with-current-buffer buffer
         (agent-shell--config-option-set-mode-id
          :mode-id mode-id
          :on-success
          (lambda () (message "Agent preset applied: %s" label))))))))

(defun mr-x/agent-shell-preset-dwim (&optional arg)
  "Apply a preset to the current chat, or launch a fresh preset shell.
Bare call applies the preset's model + permission mode to the current
agent-shell session in place.  With prefix ARG (`C-u'), instead spawn a
fresh shell locked to that preset."
  (interactive "P")
  (if arg
      (call-interactively #'mr-x/agent-shell-start-preset)
    (call-interactively #'mr-x/agent-shell-apply-preset)))

;; ---------------------------------------------------------------------------
;; Leader bindings: pane management (SPC &) + additions under SPC c.
;; Extends/overrides the SPC c map from init.el.
;; ---------------------------------------------------------------------------

(mr-x/leader-def
  "c t" '(major-pane-toggle :wk "toggle pane")
  "c P" '(mr-x/agent-shell-preset-dwim :wk "preset in-place (C-u: new shell)")
  "c b" '(major-pane-swap-buffer :wk "swap panel buffer")
  ;; Picker-based send commands replace the plain agent-shell-send-* binds.
  "c r" '(mr-x/agent-send-region-no-switch :wk "send region (stay)")
  "c R" '(mr-x/agent-send-region :wk "send region (go)")
  "c f" '(mr-x/agent-send-file :wk "send file")
  "c F" '(mr-x/agent-send-other-file :wk "send other file")
  "c s" '(mr-x/agent-send-screenshot :wk "send screenshot"))

(mr-x/leader-def
  "&" '(:ignore t :wk "pane")
  "& w" '(major-pane-focus :wk "focus pane")
  "& n" '(major-pane-new-chat :wk "new chat")
  "& l" '(major-pane-set-label :wk "label conversation")
  "& b" '(major-pane-capture-buffer :wk "capture buffer into pane")
  "& h" '(major-pane-set-home-frame :wk "lock pane to this frame")
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
