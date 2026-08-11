;;; syzygy-resync.el --- Desync guard for multiplexed agent-shell sessions -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; A phone/web client (acp-mobile, through acp-multiplex) can inject
;; turns into the same ACP session an agent-shell buffer is attached
;; to.  Those turns reach Emacs as out-of-turn `user_message_chunk's
;; that shell-maker cannot attach to any prompt, so from that moment
;; the buffer shows an incomplete conversation.  Sending from a stale
;; buffer would interleave two divergent views of one session, so on
;; the first out-of-turn user chunk the buffer is LOCKED:
;;
;; - `buffer-read-only' goes on: every edit path (i, a, c, o, paste,
;;   ...) fails at the Emacs level.  Safe because agent-shell's
;;   writers (`agent-shell--update-fragment'/`--update-text',
;;   `shell-maker--output-filter') all bind `inhibit-read-only', so
;;   replays and further phone turns still render.
;; - a banner overlay sits above the prompt so the state is visible,
;;   not just discoverable by failed keystrokes.
;; - insert state gets bounced back to normal (deferred via timer;
;;   switching states inside `evil-insert-state-entry-hook' directly
;;   is unreliable — `a' slipped through where `i' bounced).
;; - RET (`shell-maker-submit') refuses before it touches any
;;   shell-maker state — blocking later (e.g. `agent-shell--handle')
;;   wedges the buffer busy with a committed-but-never-sent prompt.
;; - `syzygy-resync-buffer' (SPC c y) re-attaches via
;;   `agent-shell-reload': the multiplexer replays the full history,
;;   phone turns included, into a fresh buffer.  C-u SPC c y unlocks
;;   in place instead (history stays stale until the next reload).
;;
;; All lock state is buffer-local, so the reload's buffer swap clears
;; it for free.
;;
;; NOTE: loaded from agent-shell-config.el, so this file must NOT
;; hard-require agent-shell (Elpaca hasn't activated packages yet in
;; batch mode).  Advice targets resolve at runtime.

;;; Code:

(require 'map)
(require 'cl-lib)

(declare-function agent-shell-reload "agent-shell")
(declare-function evil-normal-state "evil-states")

(defface syzygy-resync-banner
  '((t :background "#ff5555" :foreground "#282a36" :weight bold :extend t))
  "Face for the desync banner (Dracula red).")

(defvar-local syzygy-resync--behind 0
  "Count of out-of-turn user turns this buffer has not rendered.")

(defvar-local syzygy-resync--overlay nil
  "Banner overlay shown while the buffer is locked.")

(defun syzygy-resync--locked-p (&optional buf)
  "Non-nil when BUF (default current buffer) is desynced and locked."
  (> (buffer-local-value 'syzygy-resync--behind (or buf (current-buffer))) 0))

(defun syzygy-resync--banner-text ()
  "Banner string for the current desync count."
  (propertize
   (format "  DESYNCED — %d turn(s) sent from phone not shown here — SPC c y to re-sync  \n"
           syzygy-resync--behind)
   'face 'syzygy-resync-banner))

(defun syzygy-resync--show-banner ()
  "Create or refresh the banner overlay above the prompt."
  (let ((pos (save-excursion (goto-char (point-max))
                             (line-beginning-position))))
    (unless (overlayp syzygy-resync--overlay)
      (setq syzygy-resync--overlay (make-overlay pos pos nil t nil)))
    (move-overlay syzygy-resync--overlay pos pos)
    (overlay-put syzygy-resync--overlay 'before-string
                 (syzygy-resync--banner-text))))

(defun syzygy-resync--bounce-insert ()
  "Kick a locked buffer back out of insert state (buffer-local hook).
Deferred: switching states from inside the entry hook is unreliable."
  (when (syzygy-resync--locked-p)
    (run-with-timer
     0 nil
     (lambda (buf)
       (when (and (buffer-live-p buf)
                  (syzygy-resync--locked-p buf))
         (with-current-buffer buf
           (evil-normal-state)
           (message "%s is %d phone turn(s) behind — SPC c y re-syncs"
                    (buffer-name) syzygy-resync--behind))))
     (current-buffer))))

(defun syzygy-resync--lock ()
  "Lock the current buffer: read-only, banner, insert-state bounce."
  (cl-incf syzygy-resync--behind)
  (setq buffer-read-only t)
  (syzygy-resync--show-banner)
  (add-hook 'evil-insert-state-entry-hook
            #'syzygy-resync--bounce-insert nil t)
  (when (and (bound-and-true-p evil-state) (eq evil-state 'insert))
    (evil-normal-state))
  (message "%s: phone turn arrived — buffer locked, SPC c y re-syncs"
           (buffer-name)))

(defun syzygy-resync--unlock ()
  "Lift the lock on the current buffer in place."
  (setq syzygy-resync--behind 0)
  (setq buffer-read-only nil)
  (when (overlayp syzygy-resync--overlay)
    (delete-overlay syzygy-resync--overlay))
  (setq syzygy-resync--overlay nil)
  (remove-hook 'evil-insert-state-entry-hook
               #'syzygy-resync--bounce-insert t))

(defun syzygy-resync--flag (state &rest _)
  "Lock STATE's shell buffer.
Installed on the function agent-shell calls exactly when an
out-of-turn `user_message_chunk' arrives (another client's turn)."
  (when-let* ((buf (map-elt state :buffer))
              ((buffer-live-p buf)))
    (with-current-buffer buf
      (syzygy-resync--lock))))

(defun syzygy-resync--guard-submit (orig &rest args)
  "Refuse ORIG (`shell-maker-submit', ARGS) in a locked buffer.
This runs before shell-maker commits the input, so aborting here
leaves no half-sent state behind."
  (if (syzygy-resync--locked-p)
      (user-error "%s is %d phone turn(s) behind — SPC c y re-syncs (C-u SPC c y unlocks)"
                  (buffer-name) syzygy-resync--behind)
    (apply orig args)))

(defun syzygy-resync-buffer (&optional unlock-only)
  "Replay this session into a fresh buffer, catching up on phone turns.
Thin wrapper over `agent-shell-reload'.  With prefix arg UNLOCK-ONLY,
just lift the lock and allow sending; the phone turns stay hidden
here until the next reload."
  (interactive "P")
  (if unlock-only
      (progn (syzygy-resync--unlock)
             (message "Lock lifted — sends allowed, history still stale"))
    (agent-shell-reload)))

(advice-add 'agent-shell--make-out-of-session-turn-notification-body
            :before #'syzygy-resync--flag)
(advice-add 'shell-maker-submit :around #'syzygy-resync--guard-submit)

(provide 'syzygy-resync)
;;; syzygy-resync.el ends here
