;;; agent-shell-refs.el --- Reference/quote context attachments for agent-shell -*- lexical-binding: t -*-

;;; Commentary:
;; Select text from Claude's response (or anywhere in the agent-shell buffer),
;; hit a keybinding to "attach" it as context.  Attached refs are silently
;; prepended to your next prompt on send, then cleared.
;;
;; Three visual feedback channels:
;;   1. Modeline segment — 📎N when refs are queued
;;   2. Pulse — region flashes on capture
;;   3. Input preview — truncated snippets bar above the input line
;;      (overlay before-string; clear with the ref commands, not backspace)
;;
;; Keybindings (configured externally):
;;   - Capture:  visual-mode binding → agent-shell-refs-capture
;;   - Preview:  agent-shell-refs-preview (show all in popup)
;;   - Clear:    agent-shell-refs-clear
;;   - Remove:   agent-shell-refs-remove (pick one to drop)

;;; Code:

(require 'cl-lib)
(require 'pulse)

;;; --- Data ---

(defvar-local agent-shell-refs--list nil
  "List of references attached to this agent-shell buffer.
Each entry is a plist (:type TYPE :text TEXT :source SOURCE :line LINE).
Legacy entries may be bare strings; treat those as :type `quote'.
Always go through the `agent-shell-refs--ref-*' accessors.")

;;; --- Types ---
;; One registry drives every visual channel (modeline, headerline,
;; capture message).  Adding a ref type = one entry here plus, if it
;; needs to be auto-detected, a clause in `agent-shell-refs--detect-type'.

(defvar agent-shell-refs-types
  '((quote . (:label "quote" :nerd-fn nerd-icons-mdicon
              :nerd-name "nf-md-comment_quote" :fallback "❝"))
    (file  . (:label "file"  :nerd-fn nerd-icons-mdicon
              :nerd-name "nf-md-file_code_outline" :fallback "📄"))
    (image . (:label "image" :nerd-fn nerd-icons-mdicon
              :nerd-name "nf-md-image_outline" :fallback "🖼"))
    (text  . (:label "text"  :nerd-fn nerd-icons-mdicon
              :nerd-name "nf-md-text_box_outline" :fallback "❝")))
  "Alist of ref TYPE symbol → display spec.
Order matters: the modeline count groups render in this order.")

(defun agent-shell-refs--ref-type (ref)
  "Type symbol of REF (legacy string refs count as `quote')."
  (if (stringp ref) 'quote (or (plist-get ref :type) 'quote)))

(defun agent-shell-refs--ref-text (ref)
  "Captured text of REF."
  (if (stringp ref) ref (plist-get ref :text)))

(defun agent-shell-refs--ref-source (ref)
  "Where REF came from: a file path or buffer name, or nil for legacy refs."
  (and (listp ref) (plist-get ref :source)))

(defun agent-shell-refs--type-icon (type)
  "Icon string for TYPE from `agent-shell-refs-types'.
Falls back to the type's plain-text glyph without nerd-icons, and to
the `quote' spec for unknown types."
  (let ((spec (or (alist-get type agent-shell-refs-types)
                  (alist-get 'quote agent-shell-refs-types))))
    (if (and (require 'nerd-icons nil t)
             (fboundp (plist-get spec :nerd-fn)))
        (funcall (plist-get spec :nerd-fn) (plist-get spec :nerd-name))
      (plist-get spec :fallback))))

(defun agent-shell-refs--detect-type ()
  "Classify a capture happening in the current buffer."
  (cond
   ((derived-mode-p 'agent-shell-mode) 'quote)
   ((derived-mode-p 'image-mode) 'image)
   ((buffer-file-name) 'file)
   (t 'text)))

;;; --- Faces ---

(defface agent-shell-refs-modeline-face
  '((t :inherit font-lock-constant-face :weight bold))
  "Face for the refs modeline indicator."
  :group 'agent-shell)

(defface agent-shell-refs-headerline-face
  '((t :inherit header-line :slant italic))
  "Face for ref snippets in the headerline."
  :group 'agent-shell)

(defface agent-shell-refs-headerline-clip-face
  '((t :inherit font-lock-comment-face))
  "Face for the 📎 icon in the headerline."
  :group 'agent-shell)

(defface agent-shell-refs-headerline-separator-face
  '((t :inherit font-lock-comment-face))
  "Face for the │ separator between snippets."
  :group 'agent-shell)

(defface agent-shell-refs-headerline-more-face
  '((t :inherit font-lock-comment-face :slant italic))
  "Face for the +N more indicator."
  :group 'agent-shell)

;;; --- Capture ---

(defun agent-shell-refs-capture ()
  "Capture the current region as a typed reference and pulse it.
In an `image-mode' buffer no region is needed — the image's file path
becomes the ref."
  (interactive)
  (let* ((type (agent-shell-refs--detect-type))
         (image-p (eq type 'image)))
    (unless (or image-p (use-region-p))
      (user-error "No region selected"))
    (let* ((text (if image-p
                     (or (buffer-file-name)
                         (user-error "Image buffer has no file"))
                   (buffer-substring-no-properties
                    (region-beginning) (region-end))))
           (ref (list :type type
                      :text text
                      :source (if (buffer-file-name)
                                  (abbreviate-file-name (buffer-file-name))
                                (buffer-name))
                      :line (unless image-p
                              (line-number-at-pos (region-beginning)))))
           (shell-buf (agent-shell-refs--find-shell-buffer)))
      (unless shell-buf
        (user-error "No agent-shell buffer found"))
      (with-current-buffer shell-buf
        (push ref agent-shell-refs--list))
      ;; Pulse feedback + drop the region (images have neither)
      (unless image-p
        (pulse-momentary-highlight-region (region-beginning) (region-end)
                                          'highlight)
        (deactivate-mark))
      ;; Message carries the type's icon so you see what got classified
      (let ((count (with-current-buffer shell-buf
                     (length agent-shell-refs--list))))
        (message "%s Referenced (%d attached)"
                 (agent-shell-refs--type-icon type) count))
      ;; Update modeline + input preview
      (with-current-buffer shell-buf
        (agent-shell-refs--update-input-preview)
        (force-mode-line-update)))))

;;; --- Clear / Remove ---

(defun agent-shell-refs-clear ()
  "Clear all attached references."
  (interactive)
  (let ((buf (agent-shell-refs--find-shell-buffer)))
    (when buf
      (with-current-buffer buf
        (setq agent-shell-refs--list nil)
        (agent-shell-refs--update-input-preview)
        (force-mode-line-update))
      (message "%s Refs cleared" (agent-shell-refs--pill-icon)))))

(defun agent-shell-refs-remove ()
  "Pick a reference to remove."
  (interactive)
  (let ((buf (agent-shell-refs--find-shell-buffer)))
    (unless buf (user-error "No agent-shell buffer"))
    (with-current-buffer buf
      (unless agent-shell-refs--list
        (user-error "No refs attached"))
      (let* ((candidates (cl-loop for ref in agent-shell-refs--list
                                  for i from 1
                                  collect (cons (format "%d: %s %s" i
                                                        (agent-shell-refs--type-icon
                                                         (agent-shell-refs--ref-type ref))
                                                        (agent-shell-refs--truncate
                                                         (agent-shell-refs--ref-text ref) 60))
                                                ref)))
             (choice (completing-read "Remove ref: " candidates nil t))
             (ref (cdr (assoc choice candidates))))
        (setq agent-shell-refs--list (delete ref agent-shell-refs--list))
        (agent-shell-refs--update-input-preview)
        (force-mode-line-update)
        (message "%s Removed (%d remaining)" (agent-shell-refs--pill-icon)
                 (length agent-shell-refs--list))))))

;;; --- Preview ---

(defun agent-shell-refs-preview ()
  "Show all attached refs in a temporary buffer."
  (interactive)
  (let ((buf (agent-shell-refs--find-shell-buffer)))
    (unless buf (user-error "No agent-shell buffer"))
    (let ((refs (buffer-local-value 'agent-shell-refs--list buf)))
      (if (null refs)
          (message "%s No refs attached" (agent-shell-refs--pill-icon))
        (with-current-buffer (get-buffer-create "*agent-shell-refs*")
          (let ((inhibit-read-only t))
            (erase-buffer)
            (cl-loop for ref in (reverse refs)
                     for i from 1
                     do (insert (format "── Ref %d [%s]%s ──\n%s\n\n" i
                                        (or (plist-get
                                             (alist-get (agent-shell-refs--ref-type ref)
                                                        agent-shell-refs-types)
                                             :label)
                                            "quote")
                                        (if-let* ((src (agent-shell-refs--ref-source ref)))
                                            (format " %s" src)
                                          "")
                                        (agent-shell-refs--ref-text ref))))
            (goto-char (point-min))
            (special-mode))
          (display-buffer (current-buffer)
                          '((display-buffer-below-selected)
                            (window-height . 0.3))))))))

;;; --- Modeline ---

(defun agent-shell-refs--modeline-indicator ()
  "Return modeline string with per-type ref counts, or empty if none.
One icon+count group per type present, in `agent-shell-refs-types'
order — e.g. \" ❝2 📄1\"."
  (if (and (derived-mode-p 'agent-shell-mode)
           agent-shell-refs--list)
      (propertize (concat " "
                          (string-join
                           (cl-loop for (type . _) in agent-shell-refs-types
                                    for n = (cl-count type agent-shell-refs--list
                                                      :key #'agent-shell-refs--ref-type)
                                    when (> n 0)
                                    collect (format "%s %d"
                                                    (agent-shell-refs--type-icon type) n))
                           " "))
                  'face 'agent-shell-refs-modeline-face
                  'help-echo (format "%d reference(s) attached — click to preview"
                                     (length agent-shell-refs--list))
                  'mouse-face 'mode-line-highlight
                  'local-map (let ((map (make-sparse-keymap)))
                               (define-key map [mode-line mouse-1]
                                           #'agent-shell-refs-preview)
                               map))
    ""))

(defvar agent-shell-refs--modeline-construct
  '(:eval (agent-shell-refs--modeline-indicator))
  "Mode-line construct for refs indicator.")

(put 'agent-shell-refs--modeline-construct 'risky-local-variable t)

;;; --- Input preview ---
;; A display-only bar above the current input line showing which refs are
;; queued, BEFORE you send.  It lives in an overlay `before-string', so it
;; never enters the buffer text shell-maker sends and can't be corrupted by
;; typing/backspace — clear it with the ref commands, not the keyboard.
;; (The header-line is unavailable: agent-shell owns it for its config bar.)

(defvar-local agent-shell-refs--preview-overlay nil
  "Overlay rendering the queued-refs bar above the input line.")

(defun agent-shell-refs--truncate (text max-len)
  "Truncate TEXT to MAX-LEN chars, collapsing whitespace, adding … if needed."
  (let ((clean (replace-regexp-in-string "[\n\r\t ]+" " " (string-trim text))))
    (if (<= (length clean) max-len)
        clean
      (concat (substring clean 0 (- max-len 1)) "…"))))

(defun agent-shell-refs--preview-bar-string ()
  "Build the queued-refs pill bar shown above the input line.
Chips reuse the sent-block pill styling (see `agent-shell-refs--pill'),
so a queued ref reads the same before and after it's sent."
  (when agent-shell-refs--list
    (let* ((refs (reverse agent-shell-refs--list))
           (total (length refs))
           (max-shown 3)
           (shown (seq-take refs max-shown))
           (remaining (- total max-shown))
           (chips (cl-loop for ref in shown
                           for i from 1
                           collect (agent-shell-refs--preview-chip ref i)))
           (bar (string-join chips " ")))
      (if (> remaining 0)
          (concat bar "  "
                  (propertize (format "+%d more" remaining)
                              'face 'agent-shell-refs-headerline-more-face))
        bar))))

(defun agent-shell-refs--input-line-start ()
  "Position at the start of the current input's prompt line, or nil.
Uses the same last-prompt search the submit advice relies on, so the
preview sits on whatever line you're about to type into."
  (save-excursion
    (goto-char (point-max))
    (when (re-search-backward comint-prompt-regexp nil t)
      (line-beginning-position))))

(defun agent-shell-refs--update-input-preview ()
  "Refresh the queued-refs preview overlay above the input line.
Rebuilt from scratch each call: drop the old overlay, and when refs are
queued and a prompt exists, anchor a fresh zero-width overlay whose
`before-string' is the snippet bar plus a newline (its own line above
the prompt)."
  (when (overlayp agent-shell-refs--preview-overlay)
    (delete-overlay agent-shell-refs--preview-overlay)
    (setq agent-shell-refs--preview-overlay nil))
  (let ((pos (and agent-shell-refs--list
                  (agent-shell-refs--input-line-start))))
    (when pos
      (let ((ov (make-overlay pos pos)))
        (overlay-put ov 'before-string
                     (concat (agent-shell-refs--preview-bar-string) "\n"))
        (overlay-put ov 'agent-shell-refs-preview t)
        (setq agent-shell-refs--preview-overlay ov)))))

;;; --- Submit hook ---

(defun agent-shell-refs--quote-block (text)
  "TEXT as a markdown-quoted block."
  (format "> %s" (replace-regexp-in-string "\n" "\n> " text)))

(defun agent-shell-refs--format-one (ref index)
  "Format a single REF, numbered INDEX, for the send block.
The \"Ref N\" header is what `[ref N]' markers in the typed message
refer back to, so the numbering here must match the queue order shown
in the preview chips."
  (let ((text (agent-shell-refs--ref-text ref))
        (source (agent-shell-refs--ref-source ref)))
    (pcase (agent-shell-refs--ref-type ref)
      ('image (format "Ref %d — attached image: %s"
                      index (expand-file-name text)))
      ('file (concat (format "Ref %d — from %s%s:\n" index source
                             (if-let* ((line (plist-get ref :line)))
                                 (format ":%d" line)
                               ""))
                     (agent-shell-refs--quote-block text)))
      ;; quote / text / unknown: plain quoted block, as before
      (_ (concat (format "Ref %d:\n" index)
                 (agent-shell-refs--quote-block text))))))

(defun agent-shell-refs--format-for-send (refs)
  "Format REFS list into a context block string."
  (concat "<referenced-context>\n"
          (string-join
           (cl-loop for ref in (reverse refs)
                    for i from 1
                    collect (agent-shell-refs--format-one ref i))
           "\n\n")
          "\n</referenced-context>\n\n"))

;;; --- Reply markers ---
;; `[ref N]' typed (or inserted via `agent-shell-refs-insert-marker') in
;; the prompt pairs a piece of the message with queued Ref N.  The marker
;; is literal buffer text — the model must see it — styled by font-lock
;; below so it reads as a chip, not markup.

(defun agent-shell-refs-insert-marker (n)
  "Jump to the shell prompt and insert a reply marker for ref N."
  (interactive "NReply to ref: ")
  (let ((buf (agent-shell-refs--find-shell-buffer)))
    (unless buf (user-error "No agent-shell buffer"))
    (let ((count (length (buffer-local-value 'agent-shell-refs--list buf))))
      (when (zerop count)
        (user-error "No refs queued — capture one first"))
      (when (or (< n 1) (> n count))
        (user-error "No ref %d (only %d queued)" n count)))
    (if-let* ((win (get-buffer-window buf t)))
        (progn
          (select-frame-set-input-focus (window-frame win))
          (select-window win))
      (pop-to-buffer buf))
    (goto-char (point-max))
    ;; Layout, whether or not the prompt already has text:
    ;;   <prompt or typed text>
    ;;   [ref N]:
    ;;   <blank>
    ;;   <reply starts here>
    (insert (format "\n[ref %d]:\n\n" n))))

(defface agent-shell-refs-marker-face
  '((t :inherit agent-shell-refs-pill-face :foreground "#fe8019"))
  "Face for `[ref N]' reply markers typed at the prompt.
Gruvbox orange so the marker reads distinctly from the yellow folded
pills that replace the sent context block."
  :group 'agent-shell)

(defun agent-shell-refs--marker-display (n)
  "Display string for marker N: the ref's type icon plus its number.
Looks the type up in the pending queue; once the queue has been sent
\(and cleared) it falls back to the generic quote icon."
  (let* ((refs (and (boundp 'agent-shell-refs--list) agent-shell-refs--list))
         (len (length refs))
         ;; queue is newest-first; capture-order N lives at index len-N
         (ref (and (<= 1 n len) (nth (- len n) refs)))
         (type (if ref (agent-shell-refs--ref-type ref) 'quote)))
    (concat (agent-shell-refs--type-icon type) " " (number-to-string n))))

(defun agent-shell-refs--marker-facespec ()
  "Font-lock facespec for the `[ref N]' match just made.
Tags the text with `agent-shell-refs-marker' so our unfontifier can
strip the `display' prop again -- `display' is deliberately NOT in
`font-lock-extra-managed-props' because agent-shell stores inline
screenshots as `display' text props and font-lock would wipe them."
  (let ((n (string-to-number (match-string-no-properties 1))))
    (list 'face 'agent-shell-refs-marker-face
          'display (agent-shell-refs--marker-display n)
          'agent-shell-refs-marker t)))

(defvar agent-shell-refs--marker-keywords
  '(("\\[ref \\([0-9]+\\)\\]" 0 (agent-shell-refs--marker-facespec) t))
  "Font-lock spec rendering `[ref N]' markers as `<type icon> N' chips.
The literal `[ref N]' text stays in the buffer -- the model reads it --
only its display changes.  Override flag is t so the marker face beats
the bold green `comint-highlight-input' once the marker is sent text.")

(defun agent-shell-refs--unfontify-region (beg end)
  "Default unfontify plus removal of our marker `display' props only."
  (font-lock-default-unfontify-region beg end)
  (let ((pos beg))
    (while (< pos end)
      (let ((next (next-single-property-change pos 'agent-shell-refs-marker nil end)))
        (when (get-text-property pos 'agent-shell-refs-marker)
          (remove-list-of-text-properties
           pos next '(display agent-shell-refs-marker)))
        (setq pos next)))))

(defun agent-shell-refs--setup-buffer ()
  "Per-buffer wiring for marker chips; runs from `agent-shell-mode-hook'."
  (setq-local font-lock-unfontify-region-function
              #'agent-shell-refs--unfontify-region))

;;; --- Sent-block pills ---
;; After a send, the echoed <referenced-context> block is folded into one
;; clickable pill per ref (icon + snippet).  TAB/RET/mouse-1 on a pill
;; unfolds just that ref, dimmed, without touching what was sent.

(defvar agent-shell-refs-pill-snippet-length 22
  "Max chars of a ref shown in its sent pill.")

(defface agent-shell-refs-pill-face
  '((t :foreground "#fabd2f" :background "#1d2021" :weight bold
       :box (:line-width -1 :color "#3c3836")))
  "Face for the folded-ref pills shown in place of the sent block.
Bold on purpose: thin yellow strokes on a dark chip read washed-out.
Chip bg is one step above the ~#101112 the main config uses for
agent-shell buffers — gruvbox's #3c3836 there reads as a light slab."
  :group 'agent-shell)

(defface agent-shell-refs-pill-hover-face
  '((t))
  "Mouse-hover face for sent-ref pills — intentionally empty.
The pill string still carries it as `mouse-face' so it shadows the
`highlight' mouse-face comint stamps on sent input; with focus-follows-
mouse the pointer often rests on the buffer and a visible hover face
made pills look permanently washed out."
  :group 'agent-shell)

(defface agent-shell-refs-sent-block-face
  '((t :foreground "#7c6f64" :slant italic :weight normal))
  "Face for an unfolded ref inside the sent context block.
Fully specified so it overrides the bold green `comint-highlight-input'
the input text carries underneath."
  :group 'agent-shell)

(defun agent-shell-refs--pill-icon ()
  "Speech-bubble icon for pills; plain fallback without nerd-icons."
  (if (require 'nerd-icons nil t)
      (nerd-icons-mdicon "nf-md-comment_quote")
    "❝"))

(defun agent-shell-refs--mirror-face-props (s)
  "Copy each `face' span of string S onto `font-lock-face', return S.
The sent-input region carries both properties, so pills must too or
font-lock-driven redisplay would drop their styling."
  (let ((pos 0))
    (while (< pos (length s))
      (let ((next (or (next-single-property-change pos 'face s) (length s))))
        (put-text-property pos next 'font-lock-face
                           (get-text-property pos 'face s) s)
        (setq pos next))))
  s)

(defun agent-shell-refs--pill (ref ov)
  "Pill string for REF toggling the visibility of overlay OV.
Lives in an overlay `before-string', so only mouse-1 can reach it."
  (let* ((map (make-sparse-keymap))
         (cmd (lambda ()
                (interactive)
                (overlay-put ov 'invisible
                             (if (overlay-get ov 'invisible)
                                 nil
                               'agent-shell-refs))
                (force-window-update (overlay-buffer ov)))))
    (define-key map [mouse-1] cmd)
    (let ((s (concat " " (agent-shell-refs--pill-icon) " "
                     (agent-shell-refs--truncate
                      ref agent-shell-refs-pill-snippet-length)
                     " ▸ ")))
      ;; append: icon keeps its nerd-font family, pill colors fill the rest
      (add-face-text-property 0 (length s) 'agent-shell-refs-pill-face t s)
      (agent-shell-refs--mirror-face-props s)
      (propertize s
                  'keymap map
                  'mouse-face 'agent-shell-refs-pill-hover-face
                  'help-echo "click: toggle referenced context"
                  'agent-shell-refs-pill t))))

(defun agent-shell-refs--preview-chip (ref index)
  "A sent-style pill chip for the queued REF plist, numbered INDEX.
Mirrors `agent-shell-refs--pill' visually so a ref looks identical
before and after send; carries no keymap since there's nothing to
toggle until it's been sent.  INDEX is the number `[ref N]' markers
and `agent-shell-refs-insert-marker' address."
  (let ((s (concat " " (agent-shell-refs--pill-icon)
                   (format " %d · " index)
                   (agent-shell-refs--truncate
                    (agent-shell-refs--ref-text ref)
                    agent-shell-refs-pill-snippet-length)
                   " ▸ ")))
    (add-face-text-property 0 (length s) 'agent-shell-refs-pill-face t s)
    s))

(defun agent-shell-refs--pillify-block-at (tag-beg)
  "Overlay-fold the raw refs block whose opening tag starts at TAG-BEG.
Everything is derived by parsing the block text, so this works no matter
who wrote or rewrote the region.  Idempotent: wipes our overlays in the
block first, then rebuilds.  Returns non-nil on success.

Overlays only — no buffer text and no text properties.  shell-maker
re-reads raw buffer text for history and failed-command echoes, so
inserted pill text would leak into future prompts, and font-lock owns
the `face' property on input regions."
  (save-excursion
    (goto-char tag-beg)
    (when (looking-at "<referenced-context>\n")
      (let* ((body-beg (match-end 0))
             (block-end (and (re-search-forward "^</referenced-context>\n?\n?" nil t)
                             (match-end 0)))
             (body-end (and block-end (match-beginning 0))))
        (when block-end
          (dolist (ov (overlays-in tag-beg block-end))
            (when (overlay-get ov 'agent-shell-refs-ov)
              (delete-overlay ov)))
          ;; spec t already hides any non-nil `invisible'; only extend a list
          (when (listp buffer-invisibility-spec)
            (add-to-invisibility-spec 'agent-shell-refs))
          (cl-flet ((hide (b e)
                      (let ((ov (make-overlay b e nil t nil)))
                        (overlay-put ov 'agent-shell-refs-ov t)
                        (overlay-put ov 'invisible 'agent-shell-refs)
                        (overlay-put ov 'evaporate t)
                        ov)))
            ;; the tag line is replaced (`display'), not made invisible:
            ;; Emacs won't render a before-string that starts a fully
            ;; invisible run, so a hidden-tag-with-pill shows nothing
            (let ((tag-ov (let ((ov (make-overlay tag-beg body-beg nil t nil)))
                            (overlay-put ov 'agent-shell-refs-ov t)
                            (overlay-put ov 'evaporate t)
                            ov))
                  (pos body-beg)
                  (pills nil))
              (while (< pos body-end)
                (let* ((chunk-end (or (save-excursion
                                        (goto-char pos)
                                        (when (search-forward "\n\n" body-end t)
                                          (match-beginning 0)))
                                      ;; last chunk runs to the newline
                                      ;; before the closing tag
                                      (1- body-end)))
                       ;; +1 grabs the trailing newline so an unfolded
                       ;; ref ends its own line
                       (rend (min (1+ chunk-end) block-end))
                       (ov (hide pos rend))
                       ;; "Ref 1:" / "Ref 1 — " send headers become a
                       ;; "1 · " prefix in the pill, matching the queued
                       ;; chips; legacy unnumbered blocks pass through
                       (ref (replace-regexp-in-string
                             "\\`Ref \\([0-9]+\\)\\(?: — \\|:[ \n]*\\)" "\\1 · "
                             (replace-regexp-in-string
                              "^> ?" ""
                              (buffer-substring-no-properties pos chunk-end)))))
                  (overlay-put ov 'face 'agent-shell-refs-sent-block-face)
                  (push (agent-shell-refs--pill ref ov) pills)
                  ;; keep the separator blank line hidden
                  (when (< rend (min (+ chunk-end 2) block-end))
                    (hide rend (min (+ chunk-end 2) block-end)))
                  (setq pos (+ chunk-end 2))))
              ;; closing tag + trailing blank line
              (hide body-end block-end)
              ;; pill row visually replaces the opening tag line
              (overlay-put tag-ov 'display
                           (concat (mapconcat #'identity (nreverse pills) " ")
                                   "\n"))
              t)))))))

(defun agent-shell-refs--block-covered-p (beg end)
  "Non-nil if every char in BEG..END is under one of our overlays."
  (let ((pos beg) (ok t))
    (while (and ok (< pos end))
      (unless (seq-some (lambda (ov) (overlay-get ov 'agent-shell-refs-ov))
                        (overlays-at pos))
        (setq ok nil))
      (setq pos (max (1+ pos) (min (next-overlay-change pos) end))))
    ok))

(defun agent-shell-refs-repair ()
  "Fold every raw refs block in sent-input regions of this buffer.
Skips blocks already fully covered by healthy overlays (preserving
their fold state) and deletes stray zero-length pill overlays left
behind when someone rewrote the text under them."
  (interactive)
  ;; stray empties first (their text was deleted from under them)
  (dolist (ov (overlays-in (point-min) (point-max)))
    (when (and (or (overlay-get ov 'agent-shell-refs-ov)
                   (eq (overlay-get ov 'invisible) 'agent-shell-refs))
               (= (overlay-start ov) (overlay-end ov)))
      (delete-overlay ov)))
  (save-excursion
    (goto-char (point-min))
    (while (search-forward "<referenced-context>" nil t)
      (let ((tag-beg (match-beginning 0)))
        ;; sent input only; agent echoes and tool output carry `output' field
        (when (and (not (eq (get-text-property tag-beg 'field) 'output))
                   (not (save-excursion
                          (goto-char tag-beg)
                          (when (looking-at "<referenced-context>\n")
                            (let ((be (save-excursion
                                        (re-search-forward
                                         "^</referenced-context>\n?\n?" nil t))))
                              (and be (agent-shell-refs--block-covered-p
                                       tag-beg be)))))))
          (agent-shell-refs--pillify-block-at tag-beg)))))
  (force-window-update (current-buffer)))

(defun agent-shell-refs--around-submit (orig-fun &rest args)
  "Advice around `shell-maker-submit' to prepend attached refs.
After the submit goes through, `agent-shell-refs-repair' folds the
echoed block into pills — immediately, and again on short timers in
case agent-shell rewrites the echoed input region asynchronously."
  (let ((had-refs nil))
    (when (and (derived-mode-p 'agent-shell-mode)
               agent-shell-refs--list)
      (setq had-refs t)
      (let ((refs-text (agent-shell-refs--format-for-send agent-shell-refs--list)))
        ;; Find prompt start and prepend refs
        (save-excursion
          (goto-char (point-max))
          (when (re-search-backward comint-prompt-regexp nil t)
            (goto-char (match-end 0))
            (insert refs-text))))
      ;; Clear refs
      (setq agent-shell-refs--list nil)
      (agent-shell-refs--update-input-preview)
      (force-mode-line-update))
    (prog1 (apply orig-fun args)
      (when had-refs
        (let ((buf (current-buffer)))
          (agent-shell-refs-repair)
          (dolist (delay '(0.5 2 5))
            (run-at-time delay nil
                         (lambda ()
                           (when (buffer-live-p buf)
                             (with-current-buffer buf
                               (agent-shell-refs-repair)))))))))))

;;; --- Find shell buffer ---

(defun agent-shell-refs--find-shell-buffer ()
  "Find the appropriate agent-shell buffer for capturing refs.
If we're in an agent-shell buffer, use it.  Otherwise, find the
project's shell buffer."
  (cond
   ((derived-mode-p 'agent-shell-mode) (current-buffer))
   ((and (fboundp 'agent-shell-project-buffers)
         (seq-first (agent-shell-project-buffers))))
   ((and (fboundp 'agent-shell--shell-buffer)
         (ignore-errors (agent-shell--shell-buffer :no-create t))))))

;;; --- Setup / teardown ---

(defun agent-shell-refs-setup ()
  "Enable refs system: modeline segment, submit advice, marker styling."
  (interactive)
  ;; Modeline
  (unless (member 'agent-shell-refs--modeline-construct mode-line-misc-info)
    (setq mode-line-misc-info
          (append mode-line-misc-info
                  (list 'agent-shell-refs--modeline-construct))))
  ;; Submit advice
  (advice-add 'shell-maker-submit :around #'agent-shell-refs--around-submit)
  ;; [ref N] marker pills — remove first so re-running setup can't stack
  ;; duplicate keywords; refresh live buffers so it applies immediately
  (font-lock-remove-keywords 'agent-shell-mode agent-shell-refs--marker-keywords)
  (font-lock-add-keywords 'agent-shell-mode agent-shell-refs--marker-keywords)
  (add-hook 'agent-shell-mode-hook #'agent-shell-refs--setup-buffer)
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (derived-mode-p 'agent-shell-mode)
        (agent-shell-refs--setup-buffer)
        ;; mode-level keywords only reach NEW buffers; patch live ones too
        (font-lock-remove-keywords nil agent-shell-refs--marker-keywords)
        (font-lock-add-keywords nil agent-shell-refs--marker-keywords)
        (font-lock-flush)))))

(defun agent-shell-refs-teardown ()
  "Disable refs system."
  (interactive)
  (setq mode-line-misc-info
        (delq 'agent-shell-refs--modeline-construct mode-line-misc-info))
  (advice-remove 'shell-maker-submit #'agent-shell-refs--around-submit)
  (remove-hook 'agent-shell-mode-hook #'agent-shell-refs--setup-buffer)
  (font-lock-remove-keywords 'agent-shell-mode agent-shell-refs--marker-keywords))

(provide 'agent-shell-refs)

;;; agent-shell-refs.el ends here
