;;; syzygy.el --- Cross-device conversation continuity -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; SYZYGY ("SIZ-i-jee"): an alignment where separate celestial bodies
;; fall into one straight line — sun–earth–moon at an eclipse.  Here:
;; the fleet's devices snapping into conjunction around one shared
;; agent conversation (see ~/docs/naming.md).
;;
;; The elisp half lives in this directory:
;;
;; - syzygy-resync.el  — desync lockdown when a phone turn lands in an
;;                       attached buffer (SPC c y re-syncs)
;; - syzygy-live.el    — opt-in live mode: phone turns render in place
;;                       instead of locking (SPC c Y)
;; - syzygy-handoff.el — resume a conversation from the other Mac
;;                       (SPC c H)
;; - syzygy-recall.el  — transcript history + exact-session resume JSON for
;;                       acp-mobile (reads agent-recall's index)
;; - syzygy-bridge.el  — base64 JSON encoding shared by the phone bridges
;; - syzygy-presets.el — launch presets for the phone's spawn sheet
;;                       (/api/presets)
;; - syzygy-models.el  — list and switch a live session's model
;;                       (/api/models, /api/model)
;; - syzygy-projects.el — project list for the phone's spawn sheet
;;                        (/api/projects)
;; - syzygy-mermaid.el — export the rig's Mermaid config so the phone's
;;                       diagrams match the xwidget preview
;;                       (/api/mermaid-config)
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
(require 'syzygy-bridge)
(require 'syzygy-presets)
(require 'syzygy-models)
(require 'syzygy-projects)
(require 'syzygy-mermaid)

(provide 'syzygy)
;;; syzygy.el ends here
