;;; syzygy-live.el --- Live 2-way sync for multiplexed agent-shell -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Companion (and counterpart) to syzygy-resync.el.  The lockdown
;; treats a phone turn landing in an agent-shell buffer as a desync
;; and locks the buffer until a reload.  This mode treats it as a
;; LIVE conversation instead: the phone's prompt renders in place and
;; the agent's reply streams in right behind it.
;;
;; The discovery that makes this small: agent-shell ALREADY renders
;; out-of-turn agent_message_chunk / tool_call / plan updates (built
;; for background subagents — they stream above the prompt under an
;; "out-of-turn" namespace).  The ONLY out-of-turn update it refuses
;; to render is user_message_chunk, which it flags as an ACP server
;; bug.  So live mode claims exactly that one case — an out-of-turn
;; user chunk in a live buffer — renders it as a phone-prompt block,
;; and passes every other notification through untouched.  The reply
;; then streams via upstream's own machinery.
;;
;; Interplay with the lockdown: the lock triggers inside the warning
;; branch we bypass, so live buffers never lock; buffers with live
;; mode off keep today's lockdown behavior exactly.  Going live
;; requires a synced buffer (SPC c y first when behind) because we
;; can only render turns from now on — history gaps stay gaps until
;; a reload.
;;
;; Simultaneous input: your half-typed draft survives (out-of-turn
;; content lands above the prompt), and `shell-maker-submit' refuses
;; while a phone turn is actively streaming (last out-of-turn chunk
;; under 2s old) so two turns can't interleave.  First submit wins.
;; Known gap: a long silent tool run (>2s between chunks) lifts the
;; guard early — acceptable; the agent queues or rejects.
;;
;; Buffer-local state dies with the buffer, so a reload (SPC c y)
;; drops back to lockdown mode — re-enable after if you want to stay
;; live.  Toggle: SPC c Y.
;;
;; NOTE: loaded from agent-shell-config.el; must NOT hard-require
;; agent-shell (Elpaca hasn't activated packages in batch mode).
;; Advice targets resolve when agent-shell loads.

;;; Code:

(require 'map)
(require 'cl-lib)

(declare-function agent-shell--update-fragment "agent-shell")
(declare-function agent-shell--active-requests-p "agent-shell")
(defvar syzygy-resync--behind)

(defgroup syzygy nil
  "Cross-device conversation continuity for agent-shell."
  :group 'tools
  :prefix "syzygy-")

(defcustom syzygy-live-default t
  "When non-nil, new agent-shell conversations start with live mode on.
A fresh convo is never behind, so enabling at creation always passes
the desync guard.  `syzygy-live-mode' (SPC c Y) stays the per-buffer
opt-out; sessions restored by resync/handoff carry their previous
live state instead."
  :type 'boolean
  :group 'syzygy)

(defvar-local syzygy-live--last-rx nil
  "`float-time' of the last out-of-turn update seen in this buffer.")

(defvar-local syzygy-live--turn-count 0
  "Counter feeding phone-turn fragment block ids.")

;;;###autoload
(define-minor-mode syzygy-live-mode
  "Render phone turns live in this agent-shell buffer instead of locking.
Off (default): the desync lockdown handles phone turns as today."
  :lighter " ⇄LIVE"
  (cond
   ((not syzygy-live-mode)
    (message "Live mode off — desync lockdown back in effect"))
   ((not (derived-mode-p 'agent-shell-mode))
    (setq syzygy-live-mode nil)
    (user-error "Not an agent-shell buffer"))
   ((and (boundp 'syzygy-resync--behind)
         (> syzygy-resync--behind 0))
    (setq syzygy-live-mode nil)
    (user-error "%s is %d phone turn(s) behind — SPC c y first, then go live"
                (buffer-name) syzygy-resync--behind))
   (t
    (message "%s is LIVE — phone turns render here as they stream"
             (buffer-name)))))

(defun syzygy-live--maybe-enable ()
  "Turn on live mode in a freshly created conversation buffer.
On `agent-shell-mode-hook' so it runs at creation, before any turn
can put the buffer behind.  Quiet: the LIVE message on every spawn
would be noise when it's the default."
  (when syzygy-live-default
    (let ((inhibit-message t))
      (syzygy-live-mode 1))))

;; Hook var referenced without requiring agent-shell (batch-load rule).
(add-hook 'agent-shell-mode-hook #'syzygy-live--maybe-enable)

(defun syzygy-live--modeline-indicator ()
  "Modeline indicator for the agent-shell doom-modeline segment.
RETIRED 2026-08-20: live mode became the default
\(`syzygy-live-default'), so the red dot marked every buffer and
meant nothing.  Body kept for a possible polarity flip (mark NOT-live
buffers instead).  The doom-modeline segment still delegates here, so
un-commenting the body is all a revival takes."
  nil
  ;; (when syzygy-live-mode
  ;;   (propertize " ● "
  ;;               'face '(:foreground "#fb4934" :weight bold)
  ;;               'help-echo "syzygy-live: phone turns render here — SPC c Y to turn off"))
  )

(defun syzygy-live--out-of-turn-user-chunk-p (state notification)
  "Non-nil when NOTIFICATION is a user chunk with no request in STATE."
  (and (equal (map-elt notification 'method) "session/update")
       (equal (map-nested-elt notification '(params update sessionUpdate))
              "user_message_chunk")
       (not (agent-shell--active-requests-p state))))

(defun syzygy-live--on-notification (orig &rest args)
  "Around `agent-shell--on-notification': claim phone prompts in live buffers.
ORIG and ARGS as in the advised function."
  (let* ((state (plist-get args :state))
         (notification (plist-get args :acp-notification))
         (buf (map-elt state :buffer)))
    (if (not (and buf
                  (buffer-live-p buf)
                  (buffer-local-value 'syzygy-live-mode buf)))
        (apply orig args)
      (with-current-buffer buf
        (unless (agent-shell--active-requests-p state)
          (setq syzygy-live--last-rx (float-time)))
        (if (not (syzygy-live--out-of-turn-user-chunk-p state notification))
            (apply orig args)
          ;; The phone's prompt: its own block above ours, same
          ;; "out-of-turn" namespace upstream gives the reply chunks.
          ;; CRITICAL: tag :last-entry-type with our OWN value, not
          ;; "user_message_chunk" — upstream reacts to that tag on the
          ;; next notification by inserting an end-of-prompt marker AT
          ;; THE PROCESS MARK (replay bookkeeping, agent-shell.el
          ;; "Replayed user_message_chunks aren't followed by...").
          ;; Out of turn that injects invisible read-only marker text
          ;; into the LIVE input region: markers multiply per phone
          ;; turn, strand any half-typed draft between read-only runs,
          ;; and block typing entirely — the live-mode wedge.
          (let ((new-turn (not (equal (map-elt state :last-entry-type)
                                      "phone_user_message_chunk")))
                (text (or (map-nested-elt notification
                                          '(params update content text))
                          (format "[%s]"
                                  (or (map-nested-elt
                                       notification
                                       '(params update content type))
                                      "unknown")))))
            (when new-turn
              (cl-incf syzygy-live--turn-count))
            (agent-shell--update-fragment
             :state state
             :namespace-id "out-of-turn"
             :block-id (format "phone-turn-%d" syzygy-live--turn-count)
             :label-left (propertize "𐆖 phone"
                                     'font-lock-face 'agent-shell-prompt)
             :body text
             :append t
             :create-new new-turn
             :expanded t
             :above-last-prompt t)
            (map-put! state :last-entry-type "phone_user_message_chunk")))))))

(defun syzygy-live--guard-submit (orig &rest args)
  "Refuse ORIG (`shell-maker-submit', ARGS) while a phone turn streams."
  (if (and syzygy-live-mode
           syzygy-live--last-rx
           (< (- (float-time) syzygy-live--last-rx) 2.0))
      (user-error "Phone turn streaming — give it a beat")
    (apply orig args)))

(defun syzygy-live--live-prompt-fix (orig prompt)
  "Around `agent-shell--live-input-prompt-p' (ORIG, PROMPT): skip markers.
After an above-prompt fragment insert, shell-maker re-emits its
invisible `<shell-maker-end-of-prompt>' marker text after the prompt.
That text carries `field' `output', which makes the stock predicate
declare the prompt dead — so every later chunk of the phone turn falls
back to inserting AFTER the prompt, wedging input behind read-only
text.  In live buffers, ignore `shell-maker--marker' text when scanning
for output after the prompt."
  (if (not syzygy-live-mode)
      (funcall orig prompt)
    (let ((end (marker-position (cdr prompt))))
      (or (= end (point-max))
          (let ((pos end) (ok t))
            (while (and ok (< pos (point-max)))
              (cond
               ((get-text-property pos 'shell-maker--marker)
                (setq pos (or (next-single-property-change pos 'shell-maker--marker)
                              (point-max))))
               ((eq (get-text-property pos 'field) 'output)
                (setq ok nil))
               (t
                (setq pos (or (next-single-property-change pos 'field)
                              (point-max))))))
            ok)))))

(advice-add 'agent-shell--on-notification :around #'syzygy-live--on-notification)
(advice-add 'shell-maker-submit :around #'syzygy-live--guard-submit)
(advice-add 'agent-shell--live-input-prompt-p :around #'syzygy-live--live-prompt-fix)

(provide 'syzygy-live)
;;; syzygy-live.el ends here
