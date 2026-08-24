;;; syzygy.el --- Cross-device conversation continuity -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; SYZYGY ("SIZ-i-jee"): an alignment where separate celestial bodies
;; fall into one straight line — sun–earth–moon at an eclipse.  Here:
;; the fleet's devices snapping into conjunction around one shared
;; agent conversation (see ~/.dotfiles/docs/naming.md).
;;
;; The elisp half lives in this directory:
;;
;; - syzygy-resync.el  — desync lockdown when a phone turn lands in an
;;                       attached buffer (SPC c y re-syncs)
;; - syzygy-live.el    — opt-in live mode: phone turns render in place
;;                       instead of locking (SPC c Y)
;; - syzygy-handoff.el — resume a conversation from the other Mac
;;                       (SPC c H)
;; - syzygy-recall.el  — transcript history JSON for acp-mobile's
;;                       History screen (reads agent-recall's index)
;;
;; The non-elisp half lives in ~/.dotfiles/macos/syzygy/: the
;; acp-multiplex/acp-mobile build pin, the acp-mobile launchd agent,
;; agent-session-handoff.sh, and acp-link-to-phone.sh.
;;
;; NOTE: loaded from agent-shell-config.el; neither this file nor any
;; module may hard-require agent-shell (Elpaca hasn't activated
;; packages in batch mode).  Advice targets resolve when agent-shell
;; loads.

;;; Code:

(require 'syzygy-resync)
(require 'syzygy-live)
(require 'syzygy-handoff)
(require 'syzygy-recall)

(provide 'syzygy)
;;; syzygy.el ends here
