;;; major-pane.el --- Toggle agent-shell side panel -*- lexical-binding: t; -*-

;;; Commentary:
;; Cmd+i to toggle agent-shell as a left side panel.
;; C-u Cmd+i to toggle full-frame mode with layout restore.
;; When no agent-shell buffer exists, shows a launcher menu.
;; Includes a buffer picker (consult or hydra+posframe) for choosing
;; among multiple agent-shell conversations, with per-action config.
;;
;; IMPORTANT — routing conversations into the pane:
;;   Many code paths display agent-shell buffers (agent-shell itself,
;;   agent-recall resume, plain pop-to-buffer callers).  To make ALL of
;;   them land in the major-pane with state kept in sync, add
;;   `major-pane-display-buffer-action' to `display-buffer-alist' in
;;   your USER CONFIG (e.g. emacs.org), not in this file:
;;
;;     (add-to-list 'display-buffer-alist
;;                  '("Claude Agent @" (major-pane-display-buffer-action)))
;;
;;   Keeping `agent-shell-display-action' set to a matching
;;   display-buffer-in-direction action is a harmless fallback; the
;;   alist entry takes precedence whenever it matches.

;;; Code:

(require 'seq)
(require 'cl-lib)

(defgroup major-pane nil
  "Toggle agent-shell side panel."
  :group 'agent-shell)

;;; Customization

(defcustom major-pane-width 0.30
  "Width of the agent-shell side panel as a fraction of the frame."
  :type 'float
  :group 'major-pane)

(defcustom major-pane-direction 'left
  "Side of the frame for the agent-shell panel."
  :type '(choice (const left) (const right))
  :group 'major-pane)

(defcustom major-pane-modes '(agent-shell-mode)
  "Major modes whose buffers count as pane conversations.
Derived modes match too.  The authoritative membership signal —
`major-pane-buffer-pattern' is only a mode-free fallback (fake
buffers in tests/labs, buffers created before their mode is set)."
  :type '(repeat symbol)
  :group 'major-pane)

(defcustom major-pane-buffer-pattern "Agent @ "
  "Regex fallback identifying agent conversation buffers by name.
agent-shell names buffers \"<Agent> Agent @ <project>\" for every
agent type (Claude, Goose, ...), so this matches them all."
  :type 'string
  :group 'major-pane)

(defcustom major-pane-launcher-buffer-name "*Agent Shell*"
  "Name of the launcher buffer."
  :type 'string
  :group 'major-pane)

(defcustom major-pane-picker-style 'consult
  "Picker style for choosing agent-shell buffers.
Can be a symbol applied globally:
  - `consult' -- use completing-read (works with ivy/vertico/etc.)
  - `hydra' -- use hydra + posframe popup

Or an alist mapping action symbols to styles for per-action config:
  ((send-region . consult)
   (swap-buffer . hydra)
   (t . consult))
The key t serves as the fallback default."
  :type '(choice (const consult)
                 (const hydra)
                 (repeat (cons (choice symbol (const t))
                               (choice (const consult) (const hydra)))))
  :group 'major-pane)

(defcustom major-pane-picker-max-visible 8
  "Maximum items visible in the hydra picker before scrolling."
  :type 'integer
  :group 'major-pane)

(defcustom major-pane-prompt-label-on-start nil
  "When non-nil, prompt for a label when a new conversation is created."
  :type 'boolean
  :group 'major-pane)

;;; Faces
;;
;; All pane chrome styling lives here.  Tweak with `customize-face',
;; `set-face-attribute', or a theme — render code never hardcodes colors.

(defface major-pane-banner
  '((t :background "#458588" :foreground "#fbf1c7" :weight bold :box nil))
  "Base face for the banner row (remapped over `tab-line' in the pane).
Gruvbox neutral blue with cream ink."
  :group 'major-pane)

(defface major-pane-banner-model
  '((t :foreground "#fbf1c7" :weight bold))
  "Face for the model name segment in the banner."
  :group 'major-pane)

(defface major-pane-banner-info
  '((t :foreground "#ebdbb2"))
  "Face for informational banner segments (effort, mode, context, cost)."
  :group 'major-pane)

(defface major-pane-banner-alert
  '((t :foreground "#fb4934" :weight bold))
  "Face for alarming banner segments (e.g. Bypass permission mode)."
  :group 'major-pane)

(defface major-pane-banner-separator
  '((t :foreground "#d5c4a1"))
  "Face for the ➤ separators between banner segments."
  :group 'major-pane)

(defface major-pane-tab-bar
  '((t :background "#1d2021" :box nil))
  "Base face for the tab row (remapped over `header-line' in the pane)."
  :group 'major-pane)

(defface major-pane-tab-active
  '((t :background "#3c3836" :foreground "#fbf1c7" :weight bold
       :underline (:color "#fbf1c7" :position 0)
       :box (:line-width (6 . -1) :color "#3c3836")))
  "Face for the active conversation tab.
Dark body with side padding (same-color box) and a cream underline
along the bottom edge."
  :group 'major-pane)

(defface major-pane-tab-inactive
  '((t :foreground "#7c6f64"
       :box (:line-width (6 . -1) :color "#1d2021")))
  "Face for inactive conversation tabs.
Flat on `major-pane-tab-bar'; the invisible box matches the bar so
tabs get side padding without a visible border."
  :group 'major-pane)

(defface major-pane-tab-attention-busy
  '((t :inherit major-pane-tab-inactive
       :foreground "#fbf1c7"
       :background "#6b3010"
       :box (:line-width (6 . -1) :color "#6b3010")))
  "Face for a tab whose agent is generating — the \"pill\".
Dark ember orange: a low simmer while the convo cooks.  Live status,
not an unseen flag — it survives activation and is replaced by
done/perms when the turn resolves.  Gruvbox-faded scheme: orange =
cooking, green = ready, red = needs you (see
sandbox lisp/major-pane-tab-schemes-test.el for the shootout)."
  :group 'major-pane)

(defface major-pane-tab-active-busy
  '((t :inherit major-pane-tab-active
       :background "#af3a03"
       :box (:line-width (6 . -1) :color "#af3a03")))
  "Face for the active tab while its agent is generating.
Faded gruvbox orange — the fiery notch above the inactive pill — with
the active tab's bold + cream underline kept so \"you are here\" still
reads.  Without this the active face would stomp the busy color."
  :group 'major-pane)

(defface major-pane-tab-active-done
  '((t :inherit major-pane-tab-active
       :background "#98971a"
       :box (:line-width (6 . -1) :color "#98971a")))
  "Face for the active tab with a not-yet-engaged finished turn.
Brighter olive over the active tab's bold + cream underline — the
response is ready and stays flagged until the user enters insert state
in the buffer."
  :group 'major-pane)

(defface major-pane-tab-active-perms
  '((t :inherit major-pane-tab-active
       :background "#cc241d"
       :box (:line-width (6 . -1) :color "#cc241d")))
  "Face for the active tab while a permission request is pending.
Brighter gruvbox red over the active tab's bold + cream underline —
stays red until the prompt is actually answered, even while you're
looking at it."
  :group 'major-pane)

(defface major-pane-tab-attention-done
  '((t :inherit major-pane-tab-inactive
       :foreground "#fbf1c7" :weight bold
       :background "#79740e"
       :underline (:color "#b8bb26" :position 0)
       :box (:line-width (6 . -1) :color "#79740e")))
  "Face for an inactive tab that finished a turn while unfocused.
The \"full\" treatment in green: faded gruvbox green + bright green
underline + bold — a response is ready, CI-green style.  Cleared when
the tab becomes active."
  :group 'major-pane)

(defface major-pane-tab-attention-perms
  '((t :inherit major-pane-tab-inactive
       :foreground "#fbf1c7" :weight bold
       :background "#9d0006"
       :underline (:color "#fb4934" :position 0)
       :box (:line-width (6 . -1) :color "#9d0006")))
  "Face for an inactive tab waiting on a permission response.
The \"full\" treatment in red: faded gruvbox red + bright red underline
+ bold — the agent needs you.  Cleared when the tab becomes active."
  :group 'major-pane)

(defface major-pane-tab-attention-done-marker
  '((t :inherit major-pane-dim :foreground "#b8bb26" :weight bold))
  "Face for the ‹N / N› overflow counter when a hidden convo has a
finished turn (green, matching the done tab)."
  :group 'major-pane)

(defface major-pane-tab-attention-perms-marker
  '((t :inherit major-pane-dim :foreground "#fb4934" :weight bold))
  "Face for the ‹N / N› overflow counter when a hidden convo is
waiting on a permission response (red) — outranks orange."
  :group 'major-pane)

(defface major-pane-tab-attention-busy-marker
  '((t :inherit major-pane-dim :foreground "#99551d"))
  "Face for the ‹N / N› overflow counter when a hidden convo is
generating (dim orange) — outranked by done and perms."
  :group 'major-pane)

(defvar-local major-pane--tab-attention nil
  "Attention state for this conversation, or nil when there's nothing new.
`perms' — waiting on a permission response (full red, outranks all).
`done'  — a turn finished, response ready (full orange).
`busy'  — the agent is generating (orange pill; live status).
`busy' is set on `input-submitted'/`permission-response' for any
registered buffer; `done'/`perms' only for a non-active buffer, and
are cleared when the buffer becomes the active tab (`busy' is not).")

(defface major-pane-tab-separator
  '((t :foreground "#3c3836" :background "#3c3836"))
  "Face for the divider between conversation tabs.
The default divider is a pixel-width space, which draws the
:background; the :foreground covers glyph dividers (e.g. │) set via
`major-pane-tab-divider'."
  :group 'major-pane)

(defface major-pane-tab-hover
  '((t :background "#504945" :foreground "#fbf1c7"))
  "Face for conversation tabs under the mouse."
  :group 'major-pane)

(defface major-pane-icon
  '((t :foreground "#458588"))  ; = major-pane-banner background — keep in sync
  "Face remapped over `nerd-icons-silver' to recolor the robot icon in-pane.
Covers both the in-buffer robot and the doom-modeline mode icon (both
inherit `nerd-icons-silver').  Foreground intentionally matches
`major-pane-banner's background so the icon reads as part of the chrome."
  :group 'major-pane)

(defface major-pane-conversation
  '((t :background "#101112"))
  "Face remapped over `default' in registered conversations.
A shade below the frame's #1d2021 so pane members read as a distinct
surface.  Applied on register and removed on unregister (kill, eject),
so ejected or excluded agent-shell buffers keep the frame background."
  :group 'major-pane)

(defface major-pane-launcher-title
  '((t :weight bold :height 1.3))
  "Face for the launcher panel title."
  :group 'major-pane)

(defface major-pane-launcher-key
  '((t :inherit font-lock-keyword-face))
  "Face for the [n]/[N]/[b] key hints in the launcher panel."
  :group 'major-pane)

(defface major-pane-dim
  '((t :inherit font-lock-comment-face))
  "Face for de-emphasized text (launcher hints, picker overflow,
dimmed buffer names next to labels)."
  :group 'major-pane)

(defface major-pane-picker-title
  '((t :foreground "#83a598" :weight bold :height 1.2))
  "Face for the hydra picker posframe title."
  :group 'major-pane)

(defface major-pane-picker-selected
  '((t :background "#504945" :foreground "#fbf1c7" :weight bold))
  "Face for the selected row in the hydra picker."
  :group 'major-pane)

(defface major-pane-picker-item
  '((t :foreground "#928374"))
  "Face for unselected rows in the hydra picker."
  :group 'major-pane)

(defface major-pane-picker-hint
  '((t :foreground "#665c54" :slant italic))
  "Face for the keybinding hint line in the hydra picker."
  :group 'major-pane)

(defface major-pane-picker-frame
  '((t :background "#1d2021"))
  "Face whose background colors the hydra picker posframe."
  :group 'major-pane)

(defface major-pane-picker-border
  '((t :background "#282828"))
  "Face whose background colors the hydra picker posframe border."
  :group 'major-pane)

;;; State

(cl-defstruct (major-pane-state (:constructor major-pane--make-state))
  "The major-pane container.  Single source of truth for identity.
Geometry (direction, width) lives in the `major-pane-direction' and
`major-pane-width' defcustoms so users can `setq' them at any time
and the next `major-pane--display' call picks up the change."
  (mode          'hidden) ; hidden | side | full
  (conversations nil)     ; ordered list of live agent-shell buffers
  (active        nil)     ; buffer currently displayed in the major-pane
  (saved-winconf nil)     ; window-configuration saved when entering full
  (last-window   nil))    ; window that had focus before the pane was shown

(defvar major-pane--state (major-pane--make-state)
  "The one and only major-pane.")

(defvar major-pane-home-frame nil
  "When set to a frame, the pane is soft-locked to it.
Conversations spawned from other frames land in the home frame's
pane, and `major-pane-toggle' from another frame jumps to the pane
instead of relocating it.  nil (default) lets the pane follow the
user across client frames.  Set with `major-pane-set-home-frame'.")

(defun major-pane--home-frame ()
  "Return the live home frame, or nil.  Auto-clears a dead one."
  (when major-pane-home-frame
    (if (frame-live-p major-pane-home-frame)
        major-pane-home-frame
      (setq major-pane-home-frame nil))))

;;;###autoload
(defun major-pane-set-home-frame (&optional clear)
  "Soft-lock the pane to the selected frame; with prefix CLEAR, unlock.
While locked: convos spawned on other frames land in the home pane,
and `major-pane-toggle' elsewhere jumps to it instead of stealing it."
  (interactive "P")
  (if clear
      (progn (setq major-pane-home-frame nil)
             (message "major-pane: home frame cleared — pane roams freely"))
    (setq major-pane-home-frame (selected-frame))
    (message "major-pane: pane locked to this frame (C-u to unlock)")))

(defun major-pane--in-pane-p (buffer)
  "Non-nil when BUFFER is the active conversation in a visible major-pane."
  (and (not (eq 'hidden (major-pane-state-mode major-pane--state)))
       (eq buffer (major-pane-state-active major-pane--state))))

(defvar-local major-pane--excluded nil
  "When non-nil, this buffer is invisible to `major-pane-toggle'.
The symbol `ejected' means the user sent it out of the pane with
`major-pane-eject-conversation' (and it can be adopted back);
any other non-nil value marks a deliberately hidden background
session (see `major-pane-exclude-buffer').")


;;; Conversations lifecycle

(defun major-pane--conversation-p (buffer)
  "Non-nil when BUFFER is eligible for the conversations list.
Membership: any mode in `major-pane-modes' (derived modes included),
or the `major-pane-buffer-pattern' name fallback; the
`major-pane--excluded' flag vetoes either."
  (and (buffer-live-p buffer)
       (not (buffer-local-value 'major-pane--excluded buffer))
       (or (apply #'provided-mode-derived-p
                  (buffer-local-value 'major-mode buffer)
                  major-pane-modes)
           (string-match-p major-pane-buffer-pattern (buffer-name buffer)))))

(defvar-local major-pane--bg-cookie nil
  "Face-remap cookie for the `major-pane-conversation' background.")

(defun major-pane--apply-conversation-background (buffer)
  "Remap BUFFER's `default' face to `major-pane-conversation'."
  (with-current-buffer buffer
    (unless major-pane--bg-cookie
      (setq major-pane--bg-cookie
            (face-remap-add-relative 'default 'major-pane-conversation)))))

(defun major-pane--remove-conversation-background (buffer)
  "Restore BUFFER's normal `default' face."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when major-pane--bg-cookie
        (face-remap-remove-relative major-pane--bg-cookie)
        (setq major-pane--bg-cookie nil)))))

(defun major-pane--register-conversation (buffer)
  "Append BUFFER to the conversations list if eligible.
Does nothing when BUFFER is already registered or excluded."
  (when (and (major-pane--conversation-p buffer)
             (not (memq buffer (major-pane-state-conversations major-pane--state))))
    (setf (major-pane-state-conversations major-pane--state)
          (append (major-pane-state-conversations major-pane--state) (list buffer)))
    (major-pane--apply-conversation-background buffer)))

(defun major-pane--unregister-conversation ()
  "Remove the current buffer from the conversations list.
If the buffer was active, promote the next neighbor (or previous
if it was last).  When no conversations remain, clear active."
  (let* ((buf (current-buffer))
         (convos (major-pane-state-conversations major-pane--state))
         (pos (cl-position buf convos :test #'eq)))
    (when pos
      (setf (major-pane-state-conversations major-pane--state)
            (delq buf convos))
      (major-pane--remove-conversation-background buf)
      (remhash buf major-pane--labels)
      (when (eq buf (major-pane-state-active major-pane--state))
        (let ((remaining (major-pane-state-conversations major-pane--state)))
          (setf (major-pane-state-active major-pane--state)
                (when remaining
                  (nth (min pos (1- (length remaining))) remaining))))))))

(defun major-pane--on-agent-shell-mode ()
  "Hook run when `agent-shell-mode' starts.
Registers the buffer, sets up unregister on kill, and optionally
prompts for a label."
  (major-pane--register-conversation (current-buffer))
  (when (not (eq 'hidden (major-pane-state-mode major-pane--state)))
    (setf (major-pane-state-active major-pane--state) (current-buffer)))
  (add-hook 'kill-buffer-hook #'major-pane--unregister-conversation nil t)
  (when major-pane-prompt-label-on-start
    (let ((buf (current-buffer)))
      (run-at-time 0 nil
                   (lambda ()
                     (when (buffer-live-p buf)
                       (let ((input (read-string
                                     (format "Label for %s (empty = none): "
                                             (buffer-name buf)))))
                         (unless (string-empty-p input)
                           (puthash buf input major-pane--labels)))))))))

;; Register on every mode in `major-pane-modes' — derived modes fire the
;; parent's hook too, so agent-shell derivatives are covered by the one
;; entry; genuinely foreign modes added to the list get their own hook.
(dolist (mode major-pane-modes)
  (add-hook (intern (format "%s-hook" mode)) #'major-pane--on-agent-shell-mode))

;;; Labels

(defvar major-pane--labels (make-hash-table :test #'eq)
  "Hash table mapping buffer objects to user-assigned display labels.
Owned by this package; other packages (e.g. agent-shell-manager)
should read/write this table for consistent labels everywhere.")

(defun major-pane--display-name (buf)
  "Return display name for buffer BUF.
Shows label + dimmed buffer name if labeled, otherwise just buffer
name.  Ejected conversations get a dim ⏏ suffix."
  (let ((label (gethash buf major-pane--labels)))
    (concat
     (if label
         (concat label "  " (propertize (buffer-name buf) 'face 'major-pane-dim))
       (buffer-name buf))
     (when (eq 'ejected (buffer-local-value 'major-pane--excluded buf))
       (propertize "  ⏏ ejected" 'face 'major-pane-dim)))))

;;;###autoload
(defun major-pane-set-label ()
  "Set a display label for an agent-shell buffer.
When called from an agent-shell buffer, labels that buffer.
Otherwise, prompts to select which buffer to label.
Empty input clears the label."
  (interactive)
  (let* ((bufs (major-pane--buffer-list))
         (buf (cond
               ((null bufs) (user-error "No agent-shell buffers"))
               ((memq (current-buffer) bufs) (current-buffer))
               ((= 1 (length bufs)) (car bufs))
               (t (major-pane--completing-read-buffer
                   "Label buffer: " bufs)))))
    (when buf
      (let* ((current-label (gethash buf major-pane--labels))
             (input (read-string
                     (format "Label for %s: " (buffer-name buf))
                     current-label)))
        (if (string-empty-p input)
            (progn (remhash buf major-pane--labels)
                   (message "Label cleared for %s" (buffer-name buf)))
          (puthash buf input major-pane--labels)
          (message "Labeled %s as \"%s\"" (buffer-name buf) input))))))

;;; Display

(defun major-pane--display (buffer)
  "Display BUFFER in the major-pane and return its window.
Normally the pane lands on the selected frame (moving here if it
lives elsewhere); when `major-pane-home-frame' is set and isn't the
selected frame, the pane lands on the home frame instead."
  (let ((home (major-pane--home-frame)))
    (if (and home (not (eq home (selected-frame))))
        (with-selected-frame home (major-pane--display-1 buffer))
      (major-pane--display-1 buffer))))

(defun major-pane--display-1 (buffer)
  "Display BUFFER in the major-pane on the selected frame; return its window."
  (major-pane--relocate-from-other-frame)
  (let ((win (display-buffer buffer
                             `((display-buffer-in-direction)
                               (direction . ,major-pane-direction)
                               (window-width . ,major-pane-width)))))
    (set-window-parameter win 'major-pane t)
    ;; Soft dedication: display-buffer won't hijack the pane for other
    ;; buffers, but set-window-buffer (tab switching) still works, and
    ;; switch-to-buffer can take over after a prompt (see
    ;; `switch-to-buffer-in-dedicated-window').
    (set-window-dedicated-p win 'soft)
    win))

;;;###autoload
(defun major-pane-display-buffer-action (buffer _alist)
  "Display-buffer action function: route BUFFER into the major-pane.
Reuses the pane window when one is visible, creates it otherwise,
and syncs pane state so chrome and `major-pane-toggle' stay correct.
Declines (returns nil) for `major-pane--excluded' buffers so
`display-buffer' falls through to its other actions.

Intended for `display-buffer-alist' (see Commentary):

  (add-to-list \\='display-buffer-alist
               \\='(\"Claude Agent @\" (major-pane-display-buffer-action)))"
  (unless (buffer-local-value 'major-pane--excluded buffer)
    (let* ((home (major-pane--home-frame))
           (existing (let ((w (seq-find (lambda (w)
                                          (window-parameter w 'major-pane))
                                        (major-pane--all-windows))))
                       (cond
                        ((null w) nil)
                        ;; reuse on the selected frame...
                        ((eq (window-frame w) (selected-frame)) w)
                        ;; ...or wherever it sits when locked to home
                        ((and home (eq (window-frame w) home)) w)
                        ;; otherwise a pane on another frame moves here
                        (t (major-pane--relocate-from-other-frame) nil))))
           (win (or existing
                    ;; Called directly, not via `display-buffer', so the
                    ;; alist entry pointing back here cannot recurse.
                    ;; With a home frame set, the pane is created THERE.
                    (let ((make (lambda ()
                                  (display-buffer-in-direction
                                   buffer
                                   `((direction . ,major-pane-direction)
                                     (window-width . ,major-pane-width))))))
                      (if (and home (not (eq home (selected-frame))))
                          (with-selected-frame home (funcall make))
                        (funcall make))))))
      (when win
        (unless (eq (window-buffer win) buffer)
          (set-window-buffer win buffer))
        (set-window-parameter win 'major-pane t)
        (set-window-dedicated-p win 'soft)
        ;; Mark the pane visible, but never demote a full-frame view —
        ;; in `full' mode the reused window is the full-frame one and
        ;; the swap behaves like a tab switch.
        (when (eq 'hidden (major-pane-state-mode major-pane--state))
          (setf (major-pane-state-mode major-pane--state) 'side))
        (setf (major-pane-state-active major-pane--state) buffer))
      win)))

;;; Pane chrome
;;
;; Two rows at the top of the major-pane window:
;;   tab-line   → agent-shell banner (green, shows model/mode/project)
;;   header-line → conversation tabs (clickable, active tab highlighted)
;; Emacs renders tab-line above header-line — this order is fixed in C.
;; Chrome renders ONLY on the in-pane buffer, never elsewhere.

(defun major-pane--tab-label (buffer)
  "Return tab title for BUFFER: label if set, else stripped directory."
  (let* ((label (gethash buffer major-pane--labels))
         (name (buffer-name buffer))
         (at (string-match " @ " name))
         (dir (if at (substring name (+ at 3)) name)))
    (or label dir)))

(defvar-local major-pane--icon-cookie nil
  "Face-remap cookie for the robot icon recolor, or nil.")

(defvar-local major-pane--banner-cookie nil
  "Face-remap cookie for the tab-line banner.")

(defvar-local major-pane--header-cookie nil
  "Face-remap cookie for the header-line (tab row) background.")

(defun major-pane--all-windows ()
  "All windows across all frames, minibuffers excluded.
There is ONE global pane for the whole daemon — every window scan
must be frame-agnostic or each client frame will conclude the pane
is missing and spawn its own."
  (apply #'append (mapcar (lambda (f) (window-list f 'nomini))
                          (frame-list))))

(defun major-pane--pane-window ()
  "Return the window marked as the major-pane on ANY frame, or nil.
Self-heals: if the marker was lost (e.g. after `set-window-configuration'),
re-marks the window showing the active conversation."
  (when (not (eq 'hidden (major-pane-state-mode major-pane--state)))
    (or (seq-find (lambda (w) (window-parameter w 'major-pane))
                  (major-pane--all-windows))
        (let* ((active (major-pane-state-active major-pane--state))
               (win (when active (get-buffer-window active t))))
          (when win
            (set-window-parameter win 'major-pane t)
            win)))))

(defun major-pane--relocate-from-other-frame ()
  "Remove the pane window when it lives on a frame other than the selected one.
Strips chrome/dedication and deletes the window (or buries the buffer
when it is that frame's only window).  Returns non-nil when a
foreign-frame pane was removed — the caller then re-displays the pane
on the selected frame: the single global pane follows the user.
Refuses to move a pane that sits on `major-pane-home-frame'."
  (let ((win (major-pane--pane-window))
        (home (major-pane--home-frame)))
    (when (and win (not (eq (window-frame win) (selected-frame)))
               (not (and home (eq (window-frame win) home))))
      (set-window-parameter win 'major-pane nil)
      (set-window-parameter win 'tab-line-format nil)
      (set-window-parameter win 'header-line-format nil)
      (set-window-dedicated-p win nil)
      (if (eq win (frame-root-window (window-frame win)))
          (with-selected-window win (bury-buffer))
        (delete-window win))
      t)))

(defun major-pane--banner-for-tab-line (fmt)
  "Adapt header-line FMT for tab-line: remap click maps from header-line to tab-line."
  (when (stringp fmt)
    (let ((s (copy-sequence fmt))
          (pos 0))
      (while (< pos (length s))
        (let* ((next (or (next-single-property-change pos 'local-map s) (length s)))
               (map (get-text-property pos 'local-map s)))
          (when map
            (let ((hl (cdr (assq 'header-line (cdr map)))))
              (when hl
                (put-text-property pos next 'local-map
                                   `(keymap (tab-line . ,hl)) s))))
          (setq pos next)))
      s)))

(defun major-pane--config-option-label (opts id)
  "Return the pretty name of config option ID's current value in OPTS.
Falls back to the raw value, or nil when the option is absent."
  (when-let* ((opt (seq-find (lambda (o) (equal (alist-get :id o) id)) opts))
              (val (alist-get :current-value opt)))
    (or (alist-get :name
                   (seq-find (lambda (choice)
                               (equal (alist-get :value choice) val))
                             (alist-get :options opt)))
        val)))

(defun major-pane--short-model-name (model-id)
  "Shorten MODEL-ID to its bare family name to save banner room.
\"claude-fable-5[1m]\" → \"fable\", \"sonnet[1m]\" → \"sonnet\",
\"claude-haiku-4-5-20251001\" → \"haiku\", \"default\" → \"default\"."
  (let* ((s (string-remove-prefix "claude-" model-id))
         (s (replace-regexp-in-string "\\[.*\\]\\'" "" s))
         ;; Drop version/date segments: everything from the first
         ;; all-digit dash-token onward ("fable-5" → "fable").
         (s (replace-regexp-in-string "-[0-9].*\\'" "" s)))
    (if (string-empty-p s) model-id s)))

(defvar major-pane-short-mode-names
  '(("Bypass Permissions" . "Bypass")
    ("Accept Edits" . "Edits")
    ("Plan Mode" . "Plan"))
  "Alist shortening permission-mode display names for the banner.")

(defun major-pane--short-mode-name (mode-name)
  "Return the abbreviated form of MODE-NAME, or MODE-NAME itself."
  (or (cdr (assoc mode-name major-pane-short-mode-names)) mode-name))

(defun major-pane--format-banner ()
  "Return a banner: model + effort + permission mode + context + cost."
  (let* ((state (buffer-local-value 'agent-shell--state (current-buffer)))
         (opts (alist-get :config-options state))
         (model-opt (seq-find (lambda (o) (equal (alist-get :id o) "model")) opts))
         (model-val (major-pane--short-model-name
                     (or (alist-get :current-value model-opt) "?")))
         (effort-val (major-pane--config-option-label opts "effort"))
         (mode-val (when-let* ((m (major-pane--config-option-label opts "mode")))
                     (major-pane--short-mode-name m)))
         (usage (alist-get :usage state))
         (ctx-used (or (alist-get :context-used usage) 0))
         (ctx-size (or (alist-get :context-size usage) 0))
         (cost (or (alist-get :cost-amount usage) 0.0))
         (pct (if (> ctx-size 0) (/ (* 100.0 ctx-used) ctx-size) 0))
         ;; nil when no usage data yet — segment is omitted entirely.
         (ctx-str (when (> ctx-size 0)
                    (format "%s/%s (%.0f%%%%)"
                            (agent-shell--format-number-compact ctx-used)
                            (agent-shell--format-number-compact ctx-size)
                            pct))))
    (let ((sep (propertize " ➤ " 'face 'major-pane-banner-separator)))
      (concat
       (propertize (format " %s" model-val) 'face 'major-pane-banner-model)
       (when effort-val
         (concat sep (propertize effort-val 'face 'major-pane-banner-info)))
       (when mode-val
         (concat sep
                 (propertize mode-val
                             'face (if (equal mode-val "Bypass")
                                       'major-pane-banner-alert
                                     'major-pane-banner-info))))
       (when ctx-str
         (concat sep (propertize ctx-str 'face 'major-pane-banner-info)))
       (when (> cost 0)
         (concat sep
                 (propertize (format "$%.2f" cost)
                             'face 'major-pane-banner-info)))
       " "))))

(defvar major-pane-tab-divider nil
  "String drawn between conversation tabs.
When nil, a 2-pixel space colored by `major-pane-tab-separator's
background is used — a true thin divider with no glyph-cell padding.
Set to any string (e.g. a propertized │) for a glyph divider.")

(defun major-pane--tab-divider ()
  "Return the divider string drawn between tabs."
  (or major-pane-tab-divider
      (propertize " " 'display '(space :width (2))
                  'face 'major-pane-tab-separator)))

(defvar major-pane-spinner-styles
  '((braille    . ("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏"))
    (dot-orbit  . ("⠁" "⠂" "⠄" "⡀" "⢀" "⠠" "⠐" "⠈"))
    (line       . ("-" "\\" "|" "/"))
    (moon       . ("◐" "◓" "◑" "◒"))
    (arc        . ("◜" "◠" "◝" "◞" "◡" "◟"))
    (triangle   . ("◢" "◣" "◤" "◥"))
    (bar        . ("▁" "▃" "▅" "▇" "█" "▇" "▅" "▃"))
    (pulse      . ("●" "◉" "○" "◉"))
    (ellipsis   . (".  " ".. " "..." "   "))
    (corners    . ("◰" "◳" "◲" "◱"))
    (quarters   . ("◴" "◷" "◶" "◵"))
    (box-bounce . ("▖" "▘" "▝" "▗"))
    (star       . ("✶" "✸" "✹" "✺" "✹" "✷"))
    (toggle     . ("⊶" "⊷"))
    (hamburger  . ("☱" "☲" "☴" "☲"))
    (grow       . ("▏" "▎" "▍" "▌" "▋" "▊" "▉" "▊" "▋" "▌" "▍" "▎"))
    (dqpb       . ("d" "q" "p" "b")))
  "Named frame sets for the busy spinner.
Every frame within a style must be the same pixel width, or the tab
row jiggles on each tick.  (Emoji spinners — clocks, moons, globes —
are deliberately absent: they render at varying widths.)")

(defvar major-pane-spinner-frames
  (alist-get 'star major-pane-spinner-styles)
  "Animation frames shown on a busy tab.
Must all be the same pixel width so the tab row's pixel layout
doesn't shift between ticks.  Switch styles with
`major-pane-spinner-style'.")

(defvar major-pane-spinner-interval 0.15
  "Seconds between spinner frames while any tab is busy.")

(defvar major-pane--spinner-index 0
  "Current frame index into `major-pane-spinner-frames'.")

(defvar major-pane--spinner-timer nil
  "Repeating timer driving the busy spinner, nil when no tab is busy.
The timer exists ONLY while some conversation is mid-turn — redisplay
is forced on every tick, so an unconditional timer would redraw the
header line forever for nothing.")

(defun major-pane-spinner-style (style)
  "Switch the busy spinner to STYLE from `major-pane-spinner-styles'."
  (interactive
   (list (intern (completing-read "Spinner style: "
                                  (mapcar #'car major-pane-spinner-styles)
                                  nil t))))
  (let ((frames (alist-get style major-pane-spinner-styles)))
    (unless frames
      (user-error "No such spinner style: %s" style))
    (setq major-pane-spinner-frames frames
          major-pane--spinner-index 0))
  (force-mode-line-update t))

(defun major-pane--any-busy-p ()
  "Non-nil when any conversation's tab is in the `busy' state."
  (cl-some (lambda (b)
             (and (buffer-live-p b)
                  (eq (buffer-local-value 'major-pane--tab-attention b) 'busy)))
           (major-pane-state-conversations major-pane--state)))

(defun major-pane--spinner-frame ()
  "Return the current spinner frame string.
Empty string when the frame list is empty — this runs inside the
header-line's `:eval', where any signal makes Emacs drop the whole
tab row."
  (if (null major-pane-spinner-frames)
      ""
    (nth (% major-pane--spinner-index (length major-pane-spinner-frames))
         major-pane-spinner-frames)))

(defun major-pane--spinner-tick ()
  "Advance the spinner and redraw, or self-cancel if nothing is busy.
The self-cancel catches busy tabs that vanish without an agent-shell
event — killed buffers, demo resets — so the timer can't leak."
  (if (major-pane--any-busy-p)
      (progn (cl-incf major-pane--spinner-index)
             (force-mode-line-update t))
    (major-pane--spinner-stop)))

(defun major-pane--spinner-stop ()
  "Cancel the spinner timer if it is running."
  (when major-pane--spinner-timer
    (cancel-timer major-pane--spinner-timer)
    (setq major-pane--spinner-timer nil)))

(defun major-pane--spinner-sync ()
  "Start the spinner timer if any tab is busy, stop it if none are."
  (if (major-pane--any-busy-p)
      (unless major-pane--spinner-timer
        (setq major-pane--spinner-timer
              (run-with-timer 0 major-pane-spinner-interval
                              #'major-pane--spinner-tick)))
    (major-pane--spinner-stop)))

(defun major-pane--render-tab (buf is-active)
  "Return the propertized tab string for BUF.
IS-ACTIVE selects the active/inactive face."
  (let ((map (make-sparse-keymap)))
    (define-key map [header-line mouse-1]
      (lambda () (interactive)
        (when (buffer-live-p buf)
          (setf (major-pane-state-active major-pane--state) buf)
          (let ((win (major-pane--pane-window)))
            (when win
              (set-window-buffer win buf)
              (select-window win))))))
    ;; Attention flags survive activation on purpose: passing through a
    ;; buffer isn't engaging with it.  `done' clears on insert-state
    ;; entry (`major-pane--attention-clear-on-insert'), `perms' when the
    ;; prompt is answered, `busy' when the turn resolves.
    (propertize (format " %s%s "
                        (if (eq (buffer-local-value 'major-pane--tab-attention buf)
                                'busy)
                            (concat (major-pane--spinner-frame) " ")
                          "")
                        (major-pane--tab-label buf))
                'face (cond (is-active
                             (pcase (buffer-local-value 'major-pane--tab-attention buf)
                               ('busy 'major-pane-tab-active-busy)
                               ('done 'major-pane-tab-active-done)
                               ('perms 'major-pane-tab-active-perms)
                               (_ 'major-pane-tab-active)))
                            ((pcase (buffer-local-value 'major-pane--tab-attention buf)
                               ('perms 'major-pane-tab-attention-perms)
                               ('done 'major-pane-tab-attention-done)
                               ('busy 'major-pane-tab-attention-busy)))
                            (t 'major-pane-tab-inactive))
                'mouse-face 'major-pane-tab-hover
                'local-map map)))

(defvar major-pane-attention-event-alist
  '((input-submitted . busy)
    (permission-response . busy)
    (permission-request . perms)
    (turn-complete . done))
  "Map agent-shell events to attention states (`busy'/`perms'/`done').
`input-submitted' starts a turn; `permission-response' resumes one
after the user answers, so both land on `busy'.")

(defun major-pane--attention-note-event (&rest args)
  "Track the emitting shell buffer's turn lifecycle on its tab.
Advice on `agent-shell--emit-event': that function only runs with the
shell buffer current, so `current-buffer' is the conversation.  Maps
the event to a state via `major-pane-attention-event-alist'.  `busy'
is live status; `done'/`perms' are unengaged-response flags set even
on the active tab — visiting isn't engaging.  The one exception: if
the user is in the buffer in insert state when the event lands
(composing the next message), the response counts as seen and the flag
is skipped."
  (let* ((event (plist-get args :event))
         (entry (assq event major-pane-attention-event-alist))
         (buf (current-buffer))
         (engaged (and (eq buf (window-buffer (selected-window)))
                       (bound-and-true-p evil-state)
                       (eq evil-state 'insert))))
    (when (and entry
               (memq buf (major-pane-state-conversations major-pane--state)))
      (let ((new (cond ((eq (cdr entry) 'busy) 'busy)
                       (engaged nil) ; typing in it right now — seen
                       (t (cdr entry)))))
        (unless (eq major-pane--tab-attention new)
          (setq major-pane--tab-attention new)
          (major-pane--spinner-sync)
          (force-mode-line-update t))))))

(with-eval-after-load 'agent-shell
  (advice-add 'agent-shell--emit-event :after #'major-pane--attention-note-event))

(defun major-pane--attention-clear-on-insert ()
  "Clear a conversation's `done' flag when the user enters insert state.
Insert state is the engagement signal: you're typing a reply, so the
response has actually been read — not just scrolled past.  Only `done'
clears here; `perms' means a prompt is still pending (typing doesn't
answer it) and `busy' is live status."
  (when (and (eq major-pane--tab-attention 'done)
             major-pane--state
             (memq (current-buffer)
                   (major-pane-state-conversations major-pane--state)))
    (setq major-pane--tab-attention nil)
    (force-mode-line-update t)))

(add-hook 'evil-insert-state-entry-hook #'major-pane--attention-clear-on-insert)

(defun major-pane--attention-severity (buffers)
  "Highest attention severity among BUFFERS: `perms', `done', `busy', or nil.
`perms' (red) outranks `done' (orange) outranks `busy' (dim orange)."
  (let (sev)
    (dolist (b buffers sev)
      (pcase (and (buffer-live-p b)
                  (buffer-local-value 'major-pane--tab-attention b))
        ('perms (setq sev 'perms))
        ('done (unless (eq sev 'perms) (setq sev 'done)))
        ('busy (unless sev (setq sev 'busy)))))))

(defun major-pane--marker-face (severity)
  "Face for an overflow counter summarizing SEVERITY."
  (pcase severity
    ('perms 'major-pane-tab-attention-perms-marker)
    ('done 'major-pane-tab-attention-done-marker)
    ('busy 'major-pane-tab-attention-busy-marker)
    (_ 'major-pane-dim)))

;;; Visual demos
;;
;; Interactive-only harnesses for eyeballing tab styling without real
;; agent-shell sessions.  They HIJACK `major-pane--state' with fake
;; "demo @ …" buffers, so running one in a live pane replaces the real
;; conversation list until you re-register (restart / reopen a shell).
;; Kept in the shipped file (not sandbox-only) so they always track the
;; current faces, states, and render API — no drift.

(defun major-pane-attention-demo ()
  "Fabricate tabs with mixed attention states to preview the coloring.
Visual check — bypasses real agent-shell registration.  Enough tabs
that both sides overflow, so the ‹N / N› counters show their colors
too (red left = a hidden perms convo, orange right = a hidden done
convo)."
  (interactive)
  ;; name . attention  (active tab in the middle so both sides overflow)
  (let* ((spec '(("~/aaa-perms"  . perms)
                 ("~/bbb-done"   . done)
                 ("~/ccc-busy"   . busy)
                 ("~/ddd-done"   . done)
                 ("~/eee-active" . nil)
                 ("~/fff-perms"  . perms)
                 ("~/ggg-busy"   . busy)
                 ("~/hhh-done"   . done)))
         (bufs (mapcar (lambda (s)
                         (let ((b (get-buffer-create (format "demo @ %s" (car s)))))
                           (with-current-buffer b
                             (setq major-pane--tab-attention (cdr s)))
                           ;; real conversation backdrop (#101112) so the tab
                           ;; frame/underline read against production chrome,
                           ;; not the default gray
                           (major-pane--apply-conversation-background b)
                           b))
                       spec))
         (active (nth 4 bufs)))
    (setf (major-pane-state-conversations major-pane--state) bufs
          (major-pane-state-active major-pane--state) active
          (major-pane-state-mode major-pane--state) 'side)
    (switch-to-buffer active)
    (set-window-parameter (selected-window) 'major-pane t)
    (major-pane--enable-pane-chrome)
    (major-pane--spinner-sync)
    (force-mode-line-update t)))

(defun major-pane-attention-lifecycle-demo ()
  "Animate tabs through the turn lifecycle.
Visual check.  Four tabs, no overflow; ~/claude runs the full happy
path (pill → perms → pill → done) while ~/scratch runs a shorter one
(pill → done)."
  (interactive)
  (let* ((names '("~/zsh" "~/dotfiles" "~/claude" "~/scratch"))
         (bufs (mapcar (lambda (n)
                         (let ((b (get-buffer-create (format "demo @ %s" n))))
                           (with-current-buffer b
                             (setq major-pane--tab-attention nil))
                           ;; real conversation backdrop (#101112) so tabs read
                           ;; against production chrome, not the default gray
                           (major-pane--apply-conversation-background b)
                           b))
                       names))
         (target (nth 2 bufs))
         (other (nth 3 bufs)))
    (setf (major-pane-state-conversations major-pane--state) bufs
          (major-pane-state-active major-pane--state) (car bufs)
          (major-pane-state-mode major-pane--state) 'side)
    (switch-to-buffer (car bufs))
    (set-window-parameter (selected-window) 'major-pane t)
    (major-pane--enable-pane-chrome)
    (force-mode-line-update t)
    (message "lifecycle: idle — turns start in 2s")
    (dolist (step `((2  ,target busy  "claude: input-submitted → busy (pill)")
                    (2  ,other  busy  "scratch: input-submitted → busy (pill)")
                    (5  ,target perms "claude: permission-request → perms")
                    (7  ,other  done  "scratch: turn-complete → done")
                    (9  ,target busy  "claude: permission-response → busy (pill)")
                    (12 ,target done  "claude: turn-complete → done")))
      (run-at-time (nth 0 step) nil
                   (lambda (buf state msg)
                     (when (buffer-live-p buf)
                       (with-current-buffer buf
                         (setq major-pane--tab-attention state))
                       (major-pane--spinner-sync)
                       (force-mode-line-update t)
                       (message "lifecycle: %s" msg)))
                   (nth 1 step) (nth 2 step) (nth 3 step)))))

(defun major-pane--render-tabs ()
  "Build a header-line-format string showing conversation tabs.
When the tabs overflow the pane width, shows a slice that always
keeps the active tab visible (expanded alternately left/right so it
stays roughly centered), with dim ‹N / N› overflow counters at the
edges.  The header-line cannot scroll, so slicing is the only way to
guarantee the active tab is on screen."
  (let* ((convos (major-pane-state-conversations major-pane--state))
         (active (major-pane-state-active major-pane--state))
         (win (major-pane--pane-window))
         ;; all layout math in PIXELS — column math drifts as soon as
         ;; dividers or fillers aren't exact multiples of a char cell
         (avail (if win (window-body-width win t) most-positive-fixnum))
         (sep (major-pane--tab-divider))
         (sep-w (string-pixel-width sep))
         (tabs (mapcar (lambda (b) (major-pane--render-tab b (eq b active)))
                       convos))
         (total (+ (apply #'+ (mapcar #'string-pixel-width tabs))
                   (* sep-w (max 0 (1- (length tabs)))))))
    (if (<= total avail)
        (mapconcat #'identity tabs sep)
      (major-pane--render-tab-slice tabs convos active avail sep sep-w))))

(defun major-pane--overflow-marker (count dir &optional face)
  "Return the overflow marker string for COUNT tabs in DIR (`left'/`right').
FACE colors the marker (default `major-pane-dim'); pass an attention
marker face to signal a hidden convo needs attention."
  (propertize (if (eq dir 'left) (format "‹%d " count) (format " %d›" count))
              'face (or face 'major-pane-dim)))

(defun major-pane--overflow-markers-px (lo hi n)
  "Pixels needed by the ‹N / N› markers for slice LO..HI of N tabs."
  (+ (if (> lo 0)
         (string-pixel-width (major-pane--overflow-marker lo 'left))
       0)
     (if (< hi (1- n))
         (string-pixel-width (major-pane--overflow-marker (- n 1 hi) 'right))
       0)))

(defun major-pane--render-tab-slice (tabs convos active avail sep sep-w)
  "Render an AVAIL-pixel-wide slice of TABS keeping ACTIVE visible.
Expands alternately right/left from the active tab, reserving only
the marker pixels actually needed.  Leftover space is filled with a
truncated preview of the next tab, and the N› counter is pinned to
the window's right edge so the row always spans the full width."
  (let* ((n (length tabs))
         (ai (or (cl-position active convos :test #'eq) 0))
         (char-w (frame-char-width))
         (lo ai) (hi ai)
         (width (string-pixel-width (nth ai tabs)))
         (grew t)
         filler)
    ;; expand alternately right then left while the slice + markers fit
    (while grew
      (setq grew nil)
      (when (< hi (1- n))
        (let ((w (+ (string-pixel-width (nth (1+ hi) tabs)) sep-w))
              (mk (major-pane--overflow-markers-px lo (1+ hi) n)))
          (when (<= (+ width w mk) avail)
            (setq hi (1+ hi) width (+ width w) grew t))))
      (when (> lo 0)
        (let ((w (+ (string-pixel-width (nth (1- lo) tabs)) sep-w))
              (mk (major-pane--overflow-markers-px (1- lo) hi n)))
          (when (<= (+ width w mk) avail)
            (setq lo (1- lo) width (+ width w) grew t)))))
    ;; fill leftover pixels with a truncated preview of the next tab
    (when (< hi (1- n))
      (let* ((mk (major-pane--overflow-markers-px lo hi n))
             (room-px (- avail width sep-w mk))
             (room-cols (floor room-px char-w)))
        (when (>= room-cols 4)
          (setq filler (truncate-string-to-width
                        (nth (1+ hi) tabs) room-cols nil nil "…")))))
    (let ((right-hidden (- n 1 hi)))
      (concat
       (when (> lo 0)
         (major-pane--overflow-marker
          lo 'left
          (major-pane--marker-face
           (major-pane--attention-severity (cl-subseq convos 0 lo)))))
       (mapconcat #'identity (cl-subseq tabs lo (1+ hi)) sep)
       (when filler (concat sep filler))
       (when (> right-hidden 0)
         (let ((marker (major-pane--overflow-marker
                        right-hidden 'right
                        (major-pane--marker-face
                         (major-pane--attention-severity
                          (cl-subseq convos (1+ hi) n))))))
           (concat
            ;; stretch glue: pin the counter to the right edge (pixel spec)
            (propertize " " 'display
                        `(space :align-to
                                (- right (,(string-pixel-width marker)))))
            marker)))))))

(defun major-pane--enable-pane-chrome ()
  "Set window parameter overrides on the pane window for chrome rendering.
Uses window parameters for `tab-line-format' and `header-line-format'
so chrome appears ONLY in the pane window, not in other windows
showing the same buffer."
  (let ((win (major-pane--pane-window)))
    (when win
      (set-window-parameter win 'tab-line-format
                            '(:eval (major-pane--format-banner)))
      (set-window-parameter win 'header-line-format
                            '(:eval (major-pane--render-tabs)))))
  ;; Tab-line banner face (buffer-local).
  (unless major-pane--banner-cookie
    (setq major-pane--banner-cookie
          (face-remap-add-relative 'tab-line 'major-pane-banner)))
  ;; Header-line (tab row) — match panel background.
  (unless major-pane--header-cookie
    (setq major-pane--header-cookie
          (face-remap-add-relative 'header-line 'major-pane-tab-bar)))
  ;; Recolor robot icon blue when in-pane.
  (when (and (featurep 'nerd-icons) (not major-pane--icon-cookie))
    (setq major-pane--icon-cookie
          (face-remap-add-relative 'nerd-icons-silver 'major-pane-icon))))

(defun major-pane--disable-pane-chrome ()
  "Clear icon recolor.  Window parameter overrides are cleared
automatically when the pane window is deleted."
  (when major-pane--banner-cookie
    (face-remap-remove-relative major-pane--banner-cookie)
    (setq major-pane--banner-cookie nil))
  (when major-pane--header-cookie
    (face-remap-remove-relative major-pane--header-cookie)
    (setq major-pane--header-cookie nil))
  (when major-pane--icon-cookie
    (face-remap-remove-relative major-pane--icon-cookie)
    (setq major-pane--icon-cookie nil)))

(defun major-pane--refresh-decorations (&rest _)
  "Reconcile tab-line and icon color based on in-pane state.
When tab-line switching changes the pane window's buffer, sync
`active' to match before toggling decorations."
  ;; Ensure active is always a valid conversation.  Catches stale refs,
  ;; killed buffers, and non-conversation buffers that leaked in.
  (let ((active (major-pane-state-active major-pane--state))
        (convos (major-pane-state-conversations major-pane--state)))
    (when (and active
               (not (and (buffer-live-p active) (memq active convos))))
      (setf (major-pane-state-active major-pane--state) (car convos))
      (setq active (car convos)))
    ;; If active lost its window (e.g. tab click swapped it),
    ;; find the conversation that took over.
    (when (and active
               (not (eq 'hidden (major-pane-state-mode major-pane--state)))
               (not (get-buffer-window active t)))
      (let ((new (seq-find (lambda (b) (get-buffer-window b t)) convos)))
        (when new
          (setf (major-pane-state-active major-pane--state) new)
          (setq active new)))))
  ;; Clear stale pane markers: if a window has the major-pane parameter
  ;; but is no longer showing a conversation buffer, strip all overrides
  ;; and release the dedication — the user deliberately took it over,
  ;; so let it behave like a normal window from here on.
  (let ((convos (major-pane-state-conversations major-pane--state)))
    (dolist (w (major-pane--all-windows))
      (when (and (window-parameter w 'major-pane)
                 (not (memq (window-buffer w) convos)))
        (set-window-parameter w 'major-pane nil)
        (set-window-parameter w 'tab-line-format nil)
        (set-window-parameter w 'header-line-format nil)
        (set-window-dedicated-p w nil))))
  ;; Toggle decorations per conversation buffer.
  (dolist (b (major-pane-state-conversations major-pane--state))
    (when (buffer-live-p b)
      (with-current-buffer b
        (if (major-pane--in-pane-p b)
            (major-pane--enable-pane-chrome)
          (major-pane--disable-pane-chrome))))))

(add-hook 'window-configuration-change-hook #'major-pane--refresh-decorations)
(add-hook 'window-buffer-change-functions #'major-pane--refresh-decorations)

;;; Tab switching

(defun major-pane--focus-conversation (buf)
  "Make BUF the active conversation, show it in the pane, and focus it.
Reuses the visible pane window when there is one; otherwise displays
the pane first."
  (let ((win (major-pane--visible-window)))
    (setf (major-pane-state-active major-pane--state) buf)
    (if win
        (progn (set-window-buffer win buf)
               (select-window win))
      (select-window (major-pane--display buf)))))

(defun major-pane--cycle (delta)
  "Cycle the active conversation by DELTA (+1 = next, -1 = prev).
Only works when focus is in the pane.  Displays the new active
buffer in the pane window and focuses it."
  (unless (major-pane--in-pane-p (current-buffer))
    (user-error "Not in the major-pane"))
  (let* ((convos (major-pane-state-conversations major-pane--state))
         (active (major-pane-state-active major-pane--state))
         (len (length convos))
         (pos (cl-position active convos :test #'eq)))
    (when (and pos (> len 1))
      (major-pane--focus-conversation
       (nth (mod (+ pos delta) len) convos)))))

(defun major-pane--cycle-done (delta)
  "Jump to the nearest conversation flagged `done' in direction DELTA.
Searches tab order starting from the active conversation, wrapping
around, and skipping the active tab itself.  Unlike plain cycling this
works from any window — the point is to chase green tabs, so it pulls
you into the pane (displaying it first if hidden)."
  (let* ((convos (major-pane-state-conversations major-pane--state))
         (active (major-pane-state-active major-pane--state))
         (len (length convos))
         (pos (or (cl-position active convos :test #'eq) 0))
         (target (cl-loop for i from 1 below len
                          for buf = (nth (mod (+ pos (* delta i)) len) convos)
                          when (and (buffer-live-p buf)
                                    (eq (buffer-local-value 'major-pane--tab-attention buf)
                                        'done))
                          return buf)))
    (if target
        (major-pane--focus-conversation target)
      (message "No finished conversations waiting"))))

;;;###autoload
(defun major-pane-next-tab ()
  "Switch to the next conversation tab."
  (interactive)
  (major-pane--cycle 1))

;;;###autoload
(defun major-pane-prev-tab ()
  "Switch to the previous conversation tab."
  (interactive)
  (major-pane--cycle -1))

;;;###autoload
(defun major-pane-next-done-tab ()
  "Jump to the next conversation with a finished, unengaged turn (green)."
  (interactive)
  (major-pane--cycle-done 1))

;;;###autoload
(defun major-pane-prev-done-tab ()
  "Jump to the previous conversation with a finished, unengaged turn (green)."
  (interactive)
  (major-pane--cycle-done -1))

;;; Close

(defun major-pane--do-close (buf)
  "Remove BUF from conversations, kill it, and update the pane.
After killing, shows the next conversation or hides the pane."
  (let ((win (major-pane--pane-window)))
    ;; Release dedication first: killing a buffer shown in a dedicated
    ;; window deletes the window before we can show the next convo.
    (when (window-live-p win)
      (set-window-dedicated-p win nil))
    (when (buffer-live-p buf)
      (kill-buffer buf))
    (when (and win (window-live-p win))
      (if-let ((next (major-pane-state-active major-pane--state)))
          (progn (set-window-buffer win next)
                 (set-window-dedicated-p win 'soft))
        (setf (major-pane-state-mode major-pane--state) 'hidden)
        (if (eq win (frame-root-window (window-frame win)))
            (with-selected-window win (bury-buffer))
          (delete-window win))))))

;;;###autoload
(defun major-pane-close-conversation ()
  "Close a conversation: remove it from the pane and kill its buffer.
When focus is in the pane, closes the active conversation.
Otherwise, prompts with the picker."
  (interactive)
  (if (major-pane--in-pane-p (current-buffer))
      (major-pane--do-close (current-buffer))
    (major-pane-pick-buffer #'major-pane--do-close 'close)))

;;;###autoload
(defun major-pane-close-all-conversations ()
  "Close all conversations: remove from the pane and kill their buffers."
  (interactive)
  (let ((convos (copy-sequence (major-pane-state-conversations major-pane--state)))
        (win (major-pane--pane-window)))
    (dolist (buf convos)
      (when (buffer-live-p buf)
        (kill-buffer buf)))
    (setf (major-pane-state-mode major-pane--state) 'hidden)
    (when (and win (window-live-p win))
      (if (eq win (frame-root-window (window-frame win)))
          (with-selected-window win (bury-buffer))
        (delete-window win)))))

;;; Eject / adopt
;;
;; Ejecting sends a conversation OUT of the pane into the main window
;; area: it is unregistered (tabs, toggle, pickers, and the
;; display-buffer routing all ignore it) and shown in a regular
;; window, where it behaves like any other buffer.  Adopting is the
;; inverse: the buffer re-registers and returns to the pane.

(defun major-pane--eject-target-window ()
  "Return a main-area window on the selected frame for an ejected buffer.
Prefers the most recently used non-pane window; when the pane is the
only window, splits a main area off beside it."
  (or (seq-find (lambda (w) (not (window-parameter w 'major-pane)))
                (sort (window-list (selected-frame) 'nomini)
                      (lambda (a b) (> (window-use-time a)
                                       (window-use-time b)))))
      (split-window (frame-root-window)
                    nil
                    (if (eq major-pane-direction 'left) 'right 'left))))

(defun major-pane--do-eject (buf)
  "Unregister BUF from the pane and display it in a main window."
  (let* ((win (major-pane--pane-window))
         (was-shown (and (window-live-p win) (eq (window-buffer win) buf))))
    (with-current-buffer buf
      ;; Keep the label across eject so adopting back restores it
      ;; (unregister clears it).
      (let ((label (gethash buf major-pane--labels)))
        (major-pane--unregister-conversation)
        (when label (puthash buf label major-pane--labels)))
      (setq-local major-pane--excluded 'ejected)
      (major-pane--disable-pane-chrome))
    (when was-shown
      (set-window-dedicated-p win nil)
      (if-let ((next (major-pane-state-active major-pane--state)))
          (progn (set-window-buffer win next)
                 (set-window-dedicated-p win 'soft))
        ;; Last conversation left: retire the pane.
        (setf (major-pane-state-mode major-pane--state) 'hidden
              (major-pane-state-saved-winconf major-pane--state) nil)
        (set-window-parameter win 'major-pane nil)
        (set-window-parameter win 'tab-line-format nil)
        (set-window-parameter win 'header-line-format nil)
        (unless (eq win (frame-root-window (window-frame win)))
          (delete-window win))))
    (select-window (major-pane--eject-target-window))
    (switch-to-buffer buf)))

;;;###autoload
(defun major-pane-eject-conversation ()
  "Eject a conversation from the major-pane into the main window area.
The buffer is unregistered — pane tabs, `major-pane-toggle', the
pickers, and the display-buffer routing all ignore it from here on —
and shown in a regular (non-pane) window, creating one when the pane
is alone on the frame.  When focus is in the pane, ejects the active
conversation; otherwise prompts with the picker.  Bring it back with
`major-pane-adopt-conversation'."
  (interactive)
  (if (major-pane--in-pane-p (current-buffer))
      (major-pane--do-eject (current-buffer))
    (major-pane-pick-buffer #'major-pane--do-eject 'eject)))

(defun major-pane--do-adopt (buf)
  "Re-register ejected BUF and display it in the pane.
Main windows that showed BUF switch back to their previous buffer.
Returns the pane window."
  (with-current-buffer buf
    (setq-local major-pane--excluded nil))
  (major-pane--register-conversation buf)
  (let ((win (major-pane-display-buffer-action buf nil)))
    ;; Don't leave the conversation duplicated in a main window.
    (dolist (w (get-buffer-window-list buf nil t))
      (unless (window-parameter w 'major-pane)
        (switch-to-prev-buffer w)))
    win))

;;;###autoload
(defun major-pane-adopt-conversation ()
  "Bring an ejected conversation back into the major-pane.
Inverse of `major-pane-eject-conversation'.  Only buffers ejected by
that command are offered — deliberately hidden background sessions
\(`major-pane-exclude-buffer') stay hidden.  When called from an
ejected buffer, adopts it directly; otherwise prompts."
  (interactive)
  (let* ((cands (seq-filter
                 (lambda (b)
                   (eq 'ejected (buffer-local-value 'major-pane--excluded b)))
                 (buffer-list)))
         (buf (cond
               ((memq (current-buffer) cands) (current-buffer))
               ((null cands) (user-error "No ejected agent-shell buffers"))
               ((= 1 (length cands)) (car cands))
               (t (major-pane--completing-read-buffer
                   "Adopt conversation: " cands)))))
    (let ((win (major-pane--do-adopt buf)))
      (when (window-live-p win)
        (select-window win)))))

;;; Buffer list

;;;###autoload
(defun major-pane-exclude-buffer (&optional buffer)
  "Hide BUFFER (default current) from the agent panel buffer list.
Marks BUFFER so `major-pane-toggle', the pickers, and
`major-pane--buffer-list' ignore it.  Useful for hidden
background agent-shell sessions (e.g. a Quick Ask session) that
should never show up as a switchable panel buffer."
  (interactive)
  (with-current-buffer (or buffer (current-buffer))
    (setq-local major-pane--excluded t)))

(defun major-pane--buffer-list ()
  "Return list of agent-shell buffers, excluding hidden ones.
Ejected conversations (`major-pane-eject-conversation') stay
listed — they are real conversations that just live outside the
pane, so the send pickers can still reach them.  Deliberately
hidden background sessions (`major-pane-exclude-buffer') are
dropped.  Uses `agent-shell-buffers' (MRU order) when available,
falls back to pattern matching against `buffer-list'."
  (seq-filter
   (lambda (b)
     (memq (buffer-local-value 'major-pane--excluded b) '(nil ejected)))
   (if (fboundp 'agent-shell-buffers)
       (agent-shell-buffers)
     (seq-filter
      (lambda (b)
        (string-match-p major-pane-buffer-pattern (buffer-name b)))
      (buffer-list)))))

(defun major-pane--completing-read-buffer (prompt bufs)
  "PROMPT user to select a buffer from BUFS using completing-read."
  (let* ((candidates (mapcar (lambda (buf)
                               (cons (major-pane--display-name buf) buf))
                             bufs))
         (selected (completing-read prompt
                                    (mapcar #'car candidates) nil t)))
    (cdr (assoc selected candidates))))

;;; Picker: configuration

(defun major-pane--picker-style-for (action)
  "Return the picker style (consult or hydra) for ACTION."
  (if (symbolp major-pane-picker-style)
      major-pane-picker-style
    (or (alist-get action major-pane-picker-style)
        (alist-get t major-pane-picker-style)
        'consult)))

;;; Picker: consult

(defun major-pane--pick-consult (bufs callback)
  "Pick a buffer from BUFS using completing-read, then call CALLBACK."
  (let ((buf (major-pane--completing-read-buffer "Agent buffer: " bufs)))
    (when buf
      (funcall callback buf))))

;;; Picker: hydra + posframe

(defvar major-pane--pick-hydra-bufs nil
  "Buffer list for the current hydra picker session.")
(defvar major-pane--pick-hydra-index 0
  "Current selection index in the hydra picker.")
(defvar major-pane--pick-hydra-callback nil
  "Callback to invoke when hydra picker confirms.")
(defvar major-pane--posframe-buf " *major-pane-picker*"
  "Buffer name for the hydra picker posframe.")

(defun major-pane--pick-hydra-render ()
  "Render the hydra picker posframe with virtual scroll."
  (let* ((bufs major-pane--pick-hydra-bufs)
         (total (length bufs))
         (max-vis major-pane-picker-max-visible)
         (half (/ max-vis 2))
         (start (if (<= total max-vis) 0
                  (min (max 0 (- major-pane--pick-hydra-index half))
                       (- total max-vis))))
         (end (min total (+ start max-vis)))
         (above start)
         (below (- total end))
         (pbuf (get-buffer-create major-pane--posframe-buf)))
    (with-current-buffer pbuf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "  Pick Buffer" 'face 'major-pane-picker-title)
                "\n\n")
        (when (> above 0)
          (insert (propertize (format "    ^ %d more" above)
                              'face 'major-pane-dim)
                  "\n"))
        (cl-loop for i from start below end
                 for b = (nth i bufs)
                 for display = (major-pane--display-name b)
                 for selected-p = (= i major-pane--pick-hydra-index)
                 for prefix = (if selected-p "  > " "    ")
                 do (insert (propertize (concat prefix display)
                                        'face (if selected-p
                                                  'major-pane-picker-selected
                                                'major-pane-picker-item))
                            "\n"))
        (when (> below 0)
          (insert (propertize (format "    v %d more" below)
                              'face 'major-pane-dim)
                  "\n"))
        (insert "\n"
                (propertize "  j next · k prev · RET confirm · q quit"
                            'face 'major-pane-picker-hint)
                "\n")))
    (when (require 'posframe nil t)
      (posframe-show pbuf
                     :position (point)
                     :internal-border-width 16
                     :internal-border-color (face-attribute
                                             'major-pane-picker-border
                                             :background nil 'default)
                     :background-color (face-attribute
                                        'major-pane-picker-frame
                                        :background nil 'default)
                     :min-width 45
                     :min-height 8))))

(defun major-pane--pick-hydra-cleanup ()
  "Clean up hydra picker state."
  (when (require 'posframe nil t)
    (posframe-hide major-pane--posframe-buf))
  (setq major-pane--pick-hydra-index 0
        major-pane--pick-hydra-bufs nil
        major-pane--pick-hydra-callback nil))

(defun major-pane--pick-hydra-next ()
  "Move to next item in hydra picker."
  (interactive)
  (setq major-pane--pick-hydra-index
        (mod (1+ major-pane--pick-hydra-index)
             (length major-pane--pick-hydra-bufs)))
  (major-pane--pick-hydra-render))

(defun major-pane--pick-hydra-prev ()
  "Move to previous item in hydra picker."
  (interactive)
  (setq major-pane--pick-hydra-index
        (mod (1- major-pane--pick-hydra-index)
             (length major-pane--pick-hydra-bufs)))
  (major-pane--pick-hydra-render))

(defun major-pane--pick-hydra-confirm ()
  "Confirm hydra picker selection."
  (interactive)
  (let ((buf (nth major-pane--pick-hydra-index
                  major-pane--pick-hydra-bufs))
        (cb major-pane--pick-hydra-callback))
    (major-pane--pick-hydra-cleanup)
    (when (and buf cb)
      (funcall cb buf))))

(defun major-pane--pick-hydra-abort ()
  "Cancel hydra picker."
  (interactive)
  (major-pane--pick-hydra-cleanup)
  (message "Cancelled."))

(with-eval-after-load 'hydra
  (defhydra major-pane-pick-hydra (:hint none
                                          :foreign-keys warn
                                          :body-pre (major-pane--pick-hydra-render)
                                          :post (major-pane--pick-hydra-cleanup))
    "pick"
    ("j" major-pane--pick-hydra-next)
    ("k" major-pane--pick-hydra-prev)
    ("RET" major-pane--pick-hydra-confirm :exit t)
    ("q" major-pane--pick-hydra-abort :exit t)
    ("<escape>" major-pane--pick-hydra-abort :exit t)))

(defun major-pane--pick-hydra (bufs callback)
  "Pick a buffer from BUFS using hydra + posframe, then call CALLBACK."
  (setq major-pane--pick-hydra-bufs bufs
        major-pane--pick-hydra-index 0
        major-pane--pick-hydra-callback callback)
  (if (fboundp 'major-pane-pick-hydra/body)
      (major-pane-pick-hydra/body)
    (message "Hydra not available, falling back to consult.")
    (major-pane--pick-consult bufs callback)))

;;; Picker: dispatcher

;;;###autoload
(defun major-pane-pick-buffer (callback &optional action)
  "Pick an agent-shell buffer and call CALLBACK with it.
Skips the picker when only one buffer exists.
ACTION is an optional symbol for per-action picker style lookup
against `major-pane-picker-style'."
  (let ((bufs (major-pane--buffer-list)))
    (cond
     ((null bufs)
      (user-error "No agent-shell buffers"))
     ((= 1 (length bufs))
      (funcall callback (car bufs)))
     (t
      (pcase (major-pane--picker-style-for (or action 'default))
        ('hydra (major-pane--pick-hydra bufs callback))
        (_ (major-pane--pick-consult bufs callback)))))))

;;;###autoload
(defun major-pane-swap-buffer ()
  "Swap which agent-shell buffer is displayed in the side panel.
Uses the configured picker style for the `swap-buffer' action."
  (interactive)
  (let ((win (major-pane--visible-window)))
    (major-pane-pick-buffer
     (lambda (buf)
       ;; Swapping to an ejected conversation adopts it back — showing
       ;; an unregistered buffer in the pane would break pane state.
       (if (eq 'ejected (buffer-local-value 'major-pane--excluded buf))
           (major-pane--do-adopt buf)
         (setf (major-pane-state-active major-pane--state) buf)
         (if win
             (set-window-buffer win buf)
           (major-pane--display buf))))
     'swap-buffer)))

;;; Going to a conversation
;;
;; Public entry point for other packages (e.g. agent-send.el) that
;; need to focus a conversation without knowing whether it lives in
;; the pane or was ejected to the main area.

;;;###autoload
(defun major-pane-goto-conversation (buf)
  "Focus conversation BUF wherever it lives.
A registered conversation becomes the active tab in the pane,
showing the pane when hidden.  An ejected conversation is focused
in its main-area window, creating one when the buffer is buried."
  (if (eq 'ejected (buffer-local-value 'major-pane--excluded buf))
      (let ((bwin (get-buffer-window buf t)))
        (if bwin
            (select-window bwin)
          (select-window (major-pane--eject-target-window))
          (switch-to-buffer buf)))
    (setf (major-pane-state-active major-pane--state) buf)
    (let ((win (major-pane--visible-window)))
      (if win
          (progn (set-window-buffer win buf)
                 (select-window win))
        (when (eq 'hidden (major-pane-state-mode major-pane--state))
          (setf (major-pane-state-mode major-pane--state) 'side))
        (select-window (major-pane--display buf))))))

;;; Launcher mode

(defvar major-pane-launcher-mode-map
  (make-sparse-keymap)
  "Keymap for the agent-shell launcher buffer.")

(define-derived-mode major-pane-launcher-mode special-mode "AS-Launcher"
  "Mode for the agent-shell launcher panel."
  (setq cursor-type nil
        buffer-read-only t
        mode-line-format nil))

(with-eval-after-load 'evil
  (evil-define-key 'normal major-pane-launcher-mode-map
    (kbd "n") #'major-pane-launcher--new
    (kbd "N") #'major-pane-launcher--new-from-dir
    (kbd "b") #'major-pane-launcher--browse
    (kbd "q") #'major-pane-launcher--quit
    (kbd "<escape>") #'major-pane-launcher--quit))

;;; Launcher functions

(defun major-pane--show-launcher ()
  "Show the agent-shell launcher in the side panel."
  (let ((buf (get-buffer-create major-pane-launcher-buffer-name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "\n")
        (insert (propertize "  Agent Shell" 'face 'major-pane-launcher-title) "\n\n")
        (insert "  " (propertize "[n]" 'face 'major-pane-launcher-key) " new chat\n")
        (insert "  " (propertize "[N]" 'face 'major-pane-launcher-key) " new chat from dir\n")
        (insert "  " (propertize "[b]" 'face 'major-pane-launcher-key) " browse chats\n\n")
        (insert (propertize "  [q] quit" 'face 'major-pane-dim) "\n"))
      (major-pane-launcher-mode)
      (goto-char (point-min)))
    (select-window (major-pane--display buf))))

(defun major-pane-launcher--quit ()
  "Close the launcher panel."
  (interactive)
  (when-let ((win (get-buffer-window major-pane-launcher-buffer-name)))
    (delete-window win))
  (when-let ((buf (get-buffer major-pane-launcher-buffer-name)))
    (kill-buffer buf)))

(defun major-pane--launch-in-pane (start-fn)
  "Call START-FN to create a new agent-shell, then show it in the pane."
  (major-pane-launcher--quit)
  (setf (major-pane-state-mode major-pane--state) 'side)
  (funcall start-fn))

(defun major-pane-launcher--new ()
  "Start a new agent-shell chat from the launcher."
  (interactive)
  (major-pane--launch-in-pane #'agent-shell))

(defun major-pane-launcher--new-from-dir ()
  "Start a new agent-shell chat in a chosen directory.
Uses `project-dashboard-projects' when available, falls back to
`read-directory-name'."
  (interactive)
  (let* ((projects (when (bound-and-true-p project-dashboard-projects)
                     project-dashboard-projects))
         (table (if projects
                    (completion-table-merge
                     projects
                     #'completion-file-name-table)
                  #'completion-file-name-table))
         (choice (completing-read "Project/dir: " table nil nil))
         (entry (and projects (assoc choice projects)))
         (dir (if entry
                  (expand-file-name (cdr entry))
                (expand-file-name choice))))
    (major-pane--launch-in-pane
     (lambda () (let ((default-directory dir))
                  (agent-shell))))))

(defun major-pane-launcher--browse ()
  "Browse agent-shell chat history."
  (interactive)
  (major-pane-launcher--quit)
  (agent-recall-browse))

;;; Core

(defun major-pane--find-buffer ()
  "Return the active conversation, or the first in the list.
Only returns a buffer that is in the conversations list."
  (let ((active (major-pane-state-active major-pane--state)))
    (or (and (buffer-live-p active)
             (memq active (major-pane-state-conversations major-pane--state))
             active)
        (car (major-pane-state-conversations major-pane--state)))))

(defun major-pane--visible-window ()
  "Return the pane window if visible, or nil."
  (major-pane--pane-window))

;;;###autoload
(defun major-pane-capture-buffer (buffer)
  "Deliberately display BUFFER in the major-pane window.
The pane's protection deflects automatic takeovers (dedication +
display actions); this command is the intentional front door.  The
window sheds its chrome and dedication and behaves like a normal
window until the pane is next shown."
  (interactive "bCapture buffer into pane: ")
  (let ((win (major-pane--pane-window)))
    (unless win (user-error "No visible major-pane"))
    (set-window-dedicated-p win nil)
    (set-window-buffer win buffer)
    (select-window win)))

;;;###autoload
(defun major-pane-toggle (&optional arg)
  "Toggle agent-shell side panel and focus it.
With prefix ARG, toggle full-frame.  Hiding restores focus to
the window that was active before the pane was shown."
  (interactive "P")
  (let ((buf (major-pane--find-buffer))
        ;; A pane visible on ANOTHER frame doesn't count as "visible
        ;; here": remove it there and fall through to the show branch —
        ;; the single global pane follows the user across client frames.
        (win (let ((w (major-pane--visible-window)))
               (if (and w (not (eq (window-frame w) (selected-frame))))
                   (progn (major-pane--relocate-from-other-frame) nil)
                 w)))
        (launcher-win (get-buffer-window major-pane-launcher-buffer-name)))
    (cond
     ;; Launcher is open: close it
     (launcher-win
      (major-pane-launcher--quit))
     ;; No agent-shell buffer: show launcher
     ((not buf)
      (major-pane--show-launcher))
     ;; Home-locked elsewhere: jump to the pane instead of stealing it
     ((let ((home (major-pane--home-frame)))
        (and home (not (eq (selected-frame) home)) (not arg)))
      (let ((home (major-pane--home-frame)))
        (select-frame-set-input-focus home)
        (let ((w (major-pane--pane-window)))
          (if (and w (eq (window-frame w) home))
              (select-window w)
            (setf (major-pane-state-active major-pane--state) buf
                  (major-pane-state-mode major-pane--state) 'side)
            (select-window (major-pane--display buf))))))
     ;; C-u: full-frame toggle
     (arg
      (let ((wc (major-pane-state-saved-winconf major-pane--state)))
        (if wc
            ;; Restore from full → side
            (progn
              (set-window-configuration wc)
              (setf (major-pane-state-saved-winconf major-pane--state) nil
                    (major-pane-state-mode major-pane--state) 'side))
          ;; Go full-frame
          (setf (major-pane-state-last-window major-pane--state) (selected-window))
          (setf (major-pane-state-saved-winconf major-pane--state)
                (current-window-configuration)
                (major-pane-state-active major-pane--state) buf
                (major-pane-state-mode major-pane--state) 'full)
          ;; The pane window is soft-dedicated; release it so our own
          ;; switch-to-buffer doesn't hit the dedication prompt.  The
          ;; saved window configuration restores dedication on the way
          ;; back to side mode.
          (when (window-dedicated-p (selected-window))
            (set-window-dedicated-p (selected-window) nil))
          (switch-to-buffer buf)
          (delete-other-windows))))
     ;; Visible: hide it
     (win
      (setf (major-pane-state-active major-pane--state) buf
            (major-pane-state-mode major-pane--state) 'hidden)
      (if (eq win (frame-root-window (window-frame win)))
          (with-selected-window win (bury-buffer))
        (delete-window win))
      ;; Restore focus to the window that was active before showing.
      (let ((lw (major-pane-state-last-window major-pane--state)))
        (when (and lw (window-live-p lw))
          (select-window lw)))
      (setf (major-pane-state-last-window major-pane--state) nil))
     ;; Hidden: show it on the left
     (t
      (setf (major-pane-state-last-window major-pane--state) (selected-window))
      (setf (major-pane-state-active major-pane--state) buf
            (major-pane-state-mode major-pane--state) 'side)
      (select-window (major-pane--display buf))))))

;;;###autoload
(defun major-pane-focus ()
  "Move focus to the major-pane window, showing the pane first if hidden.
Unlike `major-pane-toggle', never hides the pane.  If the launcher
is open, focus that instead."
  (interactive)
  (let ((win (major-pane--visible-window))
        (launcher-win (get-buffer-window major-pane-launcher-buffer-name)))
    (cond
     (launcher-win
      (select-window launcher-win))
     ((and win (eq (window-frame win) (selected-frame)))
      (select-window win))
     ;; Hidden, on another frame, or home-locked elsewhere: toggle's
     ;; show branch already handles all of these and ends focused.
     (t
      (major-pane-toggle)))))

;;;###autoload
(defun major-pane-show-no-focus ()
  "Show the major-pane without moving focus.
If already visible, do nothing.  If hidden, show it as a side
panel but keep the cursor in the current window."
  (interactive)
  (let ((buf (major-pane--find-buffer))
        (win (major-pane--visible-window)))
    (unless win
      (when buf
        (setf (major-pane-state-last-window major-pane--state) (selected-window))
        (setf (major-pane-state-active major-pane--state) buf
              (major-pane-state-mode major-pane--state) 'side)
        (major-pane--display buf)))))

;;;###autoload
(defun major-pane-new-chat ()
  "Start a new agent-shell chat and display it in the pane."
  (interactive)
  (setf (major-pane-state-mode major-pane--state) 'side)
  (agent-shell))

(provide 'major-pane)
;;; major-pane.el ends here
