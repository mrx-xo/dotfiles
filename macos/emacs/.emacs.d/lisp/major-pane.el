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

(defcustom major-pane-buffer-pattern "Claude Agent @"
  "Regex pattern to identify agent-shell buffers."
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

(defun major-pane--in-pane-p (buffer)
  "Non-nil when BUFFER is the active conversation in a visible major-pane."
  (and (not (eq 'hidden (major-pane-state-mode major-pane--state)))
       (eq buffer (major-pane-state-active major-pane--state))))

(defvar-local major-pane--excluded nil
  "When non-nil, this buffer is invisible to `major-pane-toggle'.")


;;; Conversations lifecycle

(defun major-pane--conversation-p (buffer)
  "Non-nil when BUFFER is an agent-shell buffer eligible for the conversations list."
  (and (buffer-live-p buffer)
       (not (buffer-local-value 'major-pane--excluded buffer))
       (or (eq (buffer-local-value 'major-mode buffer) 'agent-shell-mode)
           (string-match-p major-pane-buffer-pattern (buffer-name buffer)))))

(defun major-pane--register-conversation (buffer)
  "Append BUFFER to the conversations list if eligible.
Does nothing when BUFFER is already registered or excluded."
  (when (and (major-pane--conversation-p buffer)
             (not (memq buffer (major-pane-state-conversations major-pane--state))))
    (setf (major-pane-state-conversations major-pane--state)
          (append (major-pane-state-conversations major-pane--state) (list buffer)))))

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

(add-hook 'agent-shell-mode-hook #'major-pane--on-agent-shell-mode)

;;; Labels

(defvar major-pane--labels (make-hash-table :test #'eq)
  "Hash table mapping buffer objects to user-assigned display labels.
Owned by this package; other packages (e.g. agent-shell-manager)
should read/write this table for consistent labels everywhere.")

(defun major-pane--display-name (buf)
  "Return display name for buffer BUF.
Shows label + dimmed buffer name if labeled, otherwise just buffer name."
  (let ((label (gethash buf major-pane--labels)))
    (if label
        (concat label "  " (propertize (buffer-name buf) 'face 'major-pane-dim))
      (buffer-name buf))))

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
  "Display BUFFER in the major-pane and return its window."
  (let ((win (display-buffer buffer
                             `((display-buffer-in-direction)
                               (direction . ,major-pane-direction)
                               (window-width . ,major-pane-width)))))
    (set-window-parameter win 'major-pane t)
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
    (let* ((existing (seq-find (lambda (w) (window-parameter w 'major-pane))
                               (window-list)))
           (win (or existing
                    ;; Called directly, not via `display-buffer', so the
                    ;; alist entry pointing back here cannot recurse.
                    (display-buffer-in-direction
                     buffer
                     `((direction . ,major-pane-direction)
                       (window-width . ,major-pane-width))))))
      (when win
        (unless (eq (window-buffer win) buffer)
          (set-window-buffer win buffer))
        (set-window-parameter win 'major-pane t)
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

(defun major-pane--pane-window ()
  "Return the window marked as the major-pane, or nil.
Self-heals: if the marker was lost (e.g. after `set-window-configuration'),
re-marks the window showing the active conversation."
  (when (not (eq 'hidden (major-pane-state-mode major-pane--state)))
    (or (seq-find (lambda (w) (window-parameter w 'major-pane))
                  (window-list))
        (let* ((active (major-pane-state-active major-pane--state))
               (win (when active (get-buffer-window active))))
          (when win
            (set-window-parameter win 'major-pane t)
            win)))))

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
    (propertize (format " %s " (major-pane--tab-label buf))
                'face (if is-active
                          'major-pane-tab-active
                        'major-pane-tab-inactive)
                'mouse-face 'major-pane-tab-hover
                'local-map map)))

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

(defun major-pane--overflow-marker (count dir)
  "Return the dim overflow marker string for COUNT tabs in DIR (`left'/`right')."
  (propertize (if (eq dir 'left) (format "‹%d " count) (format " %d›" count))
              'face 'major-pane-dim))

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
         (major-pane--overflow-marker lo 'left))
       (mapconcat #'identity (cl-subseq tabs lo (1+ hi)) sep)
       (when filler (concat sep filler))
       (when (> right-hidden 0)
         (let ((marker (major-pane--overflow-marker right-hidden 'right)))
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
               (not (get-buffer-window active)))
      (let ((new (seq-find (lambda (b) (get-buffer-window b)) convos)))
        (when new
          (setf (major-pane-state-active major-pane--state) new)
          (setq active new)))))
  ;; Clear stale pane markers: if a window has the major-pane parameter
  ;; but is no longer showing a conversation buffer, strip all overrides.
  (let ((convos (major-pane-state-conversations major-pane--state)))
    (dolist (w (window-list))
      (when (and (window-parameter w 'major-pane)
                 (not (memq (window-buffer w) convos)))
        (set-window-parameter w 'major-pane nil)
        (set-window-parameter w 'tab-line-format nil)
        (set-window-parameter w 'header-line-format nil))))
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
      (let* ((new-pos (mod (+ pos delta) len))
             (buf (nth new-pos convos))
             (win (major-pane--visible-window)))
        (setf (major-pane-state-active major-pane--state) buf)
        (if win
            (progn (set-window-buffer win buf)
                   (select-window win))
          (select-window (major-pane--display buf)))))))

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

;;; Close

(defun major-pane--do-close (buf)
  "Remove BUF from conversations, kill it, and update the pane.
After killing, shows the next conversation or hides the pane."
  (let ((win (major-pane--pane-window)))
    (when (buffer-live-p buf)
      (kill-buffer buf))
    (when (and win (window-live-p win))
      (if-let ((next (major-pane-state-active major-pane--state)))
          (set-window-buffer win next)
        (setf (major-pane-state-mode major-pane--state) 'hidden)
        (if (= (length (window-list)) 1)
            (bury-buffer)
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
      (if (= (length (window-list)) 1)
          (bury-buffer)
        (delete-window win)))))

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
Uses `agent-shell-buffers' (MRU order) when available,
falls back to pattern matching against `buffer-list'."
  (seq-filter
   (lambda (b)
     (not (buffer-local-value 'major-pane--excluded b)))
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
       (setf (major-pane-state-active major-pane--state) buf)
       (if win
           (set-window-buffer win buf)
         (major-pane--display buf)))
     'swap-buffer)))

;;; Send wrappers
;;
;; These wrap upstream send commands with the picker so you can choose
;; which agent-shell buffer receives the content.  When only one buffer
;; exists, the picker is skipped and the send happens immediately.

;;;###autoload
(defun major-pane-send-region ()
  "Send region to a picked agent-shell buffer and switch to it."
  (interactive)
  (let ((win (major-pane--visible-window)))
    (major-pane-pick-buffer
     (lambda (buf)
       (save-window-excursion
         (agent-shell-insert
          :text (agent-shell--get-region-context
                 :deactivate t
                 :agent-cwd (with-current-buffer buf (agent-shell-cwd)))
          :shell-buffer buf
          :no-focus t))
       (setf (major-pane-state-active major-pane--state) buf)
       (if win
           (progn (set-window-buffer win buf)
                  (select-window win))
         (select-window (major-pane--display buf))))
     'send-region)))

;;;###autoload
(defun major-pane-send-region-no-switch ()
  "Send region to a picked agent-shell buffer without switching."
  (interactive)
  (major-pane-pick-buffer
   (lambda (buf)
     (save-window-excursion
       (agent-shell-insert
        :text (agent-shell--get-region-context
               :deactivate t
               :agent-cwd (with-current-buffer buf (agent-shell-cwd)))
        :shell-buffer buf
        :no-focus t)))
   'send-region))

;;;###autoload
(defun major-pane-send-file ()
  "Send current file to a picked agent-shell buffer."
  (interactive)
  (let ((files (or (agent-shell--buffer-files)
                   (when (buffer-file-name)
                     (list (buffer-file-name)))
                   (list (completing-read "Send file: " (agent-shell--project-files)))
                   (user-error "No file to send"))))
    (major-pane-pick-buffer
     (lambda (buf)
       (save-window-excursion
         (agent-shell-insert
          :text (agent-shell--get-files-context :files files)
          :shell-buffer buf
          :no-focus t)))
     'send-file)))

;;;###autoload
(defun major-pane-send-other-file ()
  "Prompt for a file and send it to a picked agent-shell buffer."
  (interactive)
  (let ((files (list (completing-read "Send file: " (agent-shell--project-files)))))
    (major-pane-pick-buffer
     (lambda (buf)
       (save-window-excursion
         (agent-shell-insert
          :text (agent-shell--get-files-context :files files)
          :shell-buffer buf
          :no-focus t)))
     'send-file)))

;;;###autoload
(defun major-pane-send-screenshot ()
  "Capture a screenshot and send it to the active pane conversation.
Sends directly to the active conversation without a picker."
  (interactive)
  (let* ((buf (or (major-pane--find-buffer)
                  (user-error "No agent-shell buffer")))
         (screenshots-dir (agent-shell--dot-subdir "screenshots"))
         (screenshot-path (agent-shell--capture-screenshot
                           :destination-dir screenshots-dir)))
    (save-window-excursion
      (agent-shell-insert
       :text (agent-shell--get-files-context :files (list screenshot-path))
       :shell-buffer buf
       :no-focus t))))

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
(defun major-pane-toggle (&optional arg)
  "Toggle agent-shell side panel and focus it.
With prefix ARG, toggle full-frame.  Hiding restores focus to
the window that was active before the pane was shown."
  (interactive "P")
  (let ((buf (major-pane--find-buffer))
        (win (major-pane--visible-window))
        (launcher-win (get-buffer-window major-pane-launcher-buffer-name)))
    (cond
     ;; Launcher is open: close it
     (launcher-win
      (major-pane-launcher--quit))
     ;; No agent-shell buffer: show launcher
     ((not buf)
      (major-pane--show-launcher))
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
          (switch-to-buffer buf)
          (delete-other-windows))))
     ;; Visible: hide it
     (win
      (setf (major-pane-state-active major-pane--state) buf
            (major-pane-state-mode major-pane--state) 'hidden)
      (if (= (length (window-list)) 1)
          (bury-buffer)
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
