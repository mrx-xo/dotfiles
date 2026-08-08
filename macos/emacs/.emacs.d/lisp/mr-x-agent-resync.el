;;; mr-x-agent-resync.el --- Desync guard for multiplexed agent-shell sessions -*- lexical-binding: t; -*-

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
;; - `mr-x/agent-resync-buffer' (SPC c y) re-attaches via
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

(defface mr-x/agent-resync-banner
  '((t :background "#ff5555" :foreground "#282a36" :weight bold :extend t))
  "Face for the desync banner (Dracula red).")

(defvar-local mr-x/agent-resync--behind 0
  "Count of out-of-turn user turns this buffer has not rendered.")

(defvar-local mr-x/agent-resync--overlay nil
  "Banner overlay shown while the buffer is locked.")

(defun mr-x/agent-resync--locked-p (&optional buf)
  "Non-nil when BUF (default current buffer) is desynced and locked."
  (> (buffer-local-value 'mr-x/agent-resync--behind (or buf (current-buffer))) 0))

(defun mr-x/agent-resync--banner-text ()
  "Banner string for the current desync count."
  (propertize
   (format "  DESYNCED — %d turn(s) sent from phone not shown here — SPC c y to re-sync  \n"
           mr-x/agent-resync--behind)
   'face 'mr-x/agent-resync-banner))

(defun mr-x/agent-resync--show-banner ()
  "Create or refresh the banner overlay above the prompt."
  (let ((pos (save-excursion (goto-char (point-max))
                             (line-beginning-position))))
    (unless (overlayp mr-x/agent-resync--overlay)
      (setq mr-x/agent-resync--overlay (make-overlay pos pos nil t nil)))
    (move-overlay mr-x/agent-resync--overlay pos pos)
    (overlay-put mr-x/agent-resync--overlay 'before-string
                 (mr-x/agent-resync--banner-text))))

(defun mr-x/agent-resync--bounce-insert ()
  "Kick a locked buffer back out of insert state (buffer-local hook).
Deferred: switching states from inside the entry hook is unreliable."
  (when (mr-x/agent-resync--locked-p)
    (run-with-timer
     0 nil
     (lambda (buf)
       (when (and (buffer-live-p buf)
                  (mr-x/agent-resync--locked-p buf))
         (with-current-buffer buf
           (evil-normal-state)
           (message "%s is %d phone turn(s) behind — SPC c y re-syncs"
                    (buffer-name) mr-x/agent-resync--behind))))
     (current-buffer))))

(defun mr-x/agent-resync--lock ()
  "Lock the current buffer: read-only, banner, insert-state bounce."
  (cl-incf mr-x/agent-resync--behind)
  (setq buffer-read-only t)
  (mr-x/agent-resync--show-banner)
  (add-hook 'evil-insert-state-entry-hook
            #'mr-x/agent-resync--bounce-insert nil t)
  (when (and (bound-and-true-p evil-state) (eq evil-state 'insert))
    (evil-normal-state))
  (message "%s: phone turn arrived — buffer locked, SPC c y re-syncs"
           (buffer-name)))

(defun mr-x/agent-resync--unlock ()
  "Lift the lock on the current buffer in place."
  (setq mr-x/agent-resync--behind 0)
  (setq buffer-read-only nil)
  (when (overlayp mr-x/agent-resync--overlay)
    (delete-overlay mr-x/agent-resync--overlay))
  (setq mr-x/agent-resync--overlay nil)
  (remove-hook 'evil-insert-state-entry-hook
               #'mr-x/agent-resync--bounce-insert t))

(defun mr-x/agent-resync--flag (state &rest _)
  "Lock STATE's shell buffer.
Installed on the function agent-shell calls exactly when an
out-of-turn `user_message_chunk' arrives (another client's turn)."
  (when-let* ((buf (map-elt state :buffer))
              ((buffer-live-p buf)))
    (with-current-buffer buf
      (mr-x/agent-resync--lock))))

(defun mr-x/agent-resync--guard-submit (orig &rest args)
  "Refuse ORIG (`shell-maker-submit', ARGS) in a locked buffer.
This runs before shell-maker commits the input, so aborting here
leaves no half-sent state behind."
  (if (mr-x/agent-resync--locked-p)
      (user-error "%s is %d phone turn(s) behind — SPC c y re-syncs (C-u SPC c y unlocks)"
                  (buffer-name) mr-x/agent-resync--behind)
    (apply orig args)))

(defun mr-x/agent-resync-buffer (&optional unlock-only)
  "Replay this session into a fresh buffer, catching up on phone turns.
Thin wrapper over `agent-shell-reload'.  With prefix arg UNLOCK-ONLY,
just lift the lock and allow sending; the phone turns stay hidden
here until the next reload."
  (interactive "P")
  (if unlock-only
      (progn (mr-x/agent-resync--unlock)
             (message "Lock lifted — sends allowed, history still stale"))
    (agent-shell-reload)))

(advice-add 'agent-shell--make-out-of-session-turn-notification-body
            :before #'mr-x/agent-resync--flag)
(advice-add 'shell-maker-submit :around #'mr-x/agent-resync--guard-submit)

(provide 'mr-x-agent-resync)
;;; mr-x-agent-resync.el ends here
