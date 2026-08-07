;;; agent-shell-bookmark.el --- Bookmark support for agent-shell sessions  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Daniel Luna

;; Author: Daniel Luna
;; URL: https://github.com/dcluna/agent-shell-bookmark
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (agent-shell "0.50.1"))
;; Keywords: convenience, tools

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Vendored copy of dcluna/agent-shell-bookmark, adapted for this config:
;; no hard (require 'agent-shell) so it loads from agent-shell-config.el
;; in batch mode, and the counsel/ivy integration is dropped (Vertico).
;;
;; Bookmark support for `agent-shell' sessions.  Jumping to an
;; agent-shell bookmark will:
;;
;; - Switch to the buffer if it is already open.
;; - Resume the session by its stored session ID if the buffer is gone.
;; - Fall back to a fresh shell when no session ID was recorded.
;;
;; Use `bookmark-set' (SPC m s) in any agent-shell buffer.

;;; Code:

(require 'bookmark)
(require 'map)

(defvar agent-shell--state)
(declare-function agent-shell "agent-shell")
(declare-function agent-shell-start "agent-shell")
(declare-function agent-shell-select-config "agent-shell")
(declare-function agent-shell--resolve-preferred-config "agent-shell")
(declare-function agent-shell--resolve-config-designator "agent-shell")

;;; Bookmark record creation

(defun agent-shell-bookmark-make-record ()
  "Create a bookmark record for the current `agent-shell' session."
  (let ((session-id (and (boundp 'agent-shell--state)
                         agent-shell--state
                         (map-nested-elt agent-shell--state '(:session :id))))
        (agent-id (and (boundp 'agent-shell--state)
                       agent-shell--state
                       (map-nested-elt agent-shell--state '(:agent-config :identifier))))
        (buf-name (buffer-name))
        (project-path (expand-file-name default-directory)))
    `(,buf-name
      (handler . agent-shell-bookmark-handler)
      (location . ,project-path)
      (session-id . ,session-id)
      (agent-identifier . ,agent-id)
      (buffer-name . ,buf-name)
      (project-path . ,project-path))))

;;; Bookmark jump handler

(defun agent-shell-bookmark--find-config (agent-identifier)
  "Resolve AGENT-IDENTIFIER to a full agent config.
Upstream searched `agent-shell-agent-configs' directly, but entries
there are lazy maker functions in current agent-shell — resolve via
`agent-shell--resolve-config-designator' instead."
  (and agent-identifier
       (agent-shell--resolve-config-designator agent-identifier)))

(defun agent-shell-bookmark-handler (bmk)
  "Handle jumping to an `agent-shell' bookmark BMK.
If the original buffer is still live, ask whether to switch to it
or resume a fresh session.  Otherwise, resume the session by its
stored ID using the same agent that created it."
  (require 'agent-shell)
  (let* ((buf-name (bookmark-prop-get bmk 'buffer-name))
         (session-id (bookmark-prop-get bmk 'session-id))
         (project-path (bookmark-prop-get bmk 'project-path))
         (agent-identifier (bookmark-prop-get bmk 'agent-identifier))
         (buf (and buf-name (get-buffer buf-name))))
    (cond
     ;; Buffer already open — ask whether to reuse or resume fresh.
     ((and buf (buffer-live-p buf))
      (if (y-or-n-p (format "Buffer `%s' exists.  Switch to it? " buf-name))
          (set-buffer buf)
        (if session-id
            (let* ((default-directory (or project-path default-directory))
                   (config (or (agent-shell-bookmark--find-config agent-identifier)
                               (agent-shell--resolve-preferred-config)
                               (agent-shell-select-config
                                :prompt "Resume with agent: "))))
              (agent-shell-start :config config :session-id session-id))
          (let ((default-directory (or project-path default-directory)))
            (agent-shell)))))
     ;; Session ID available — try to resume with the stored agent config.
     (session-id
      (let* ((default-directory (or project-path default-directory))
             (config (or (agent-shell-bookmark--find-config agent-identifier)
                         (agent-shell--resolve-preferred-config)
                         (agent-shell-select-config
                          :prompt "Resume with agent: "))))
        (agent-shell-start :config config :session-id session-id)))
     ;; No session ID — start fresh with session prompt.
     (t
      (let ((default-directory (or project-path default-directory)))
        (agent-shell))))))

;;; Type registration

(put 'agent-shell-bookmark-handler 'bookmark-handler-type "agent-shell")

;;; Hook into agent-shell-mode

(defun agent-shell-bookmark--setup ()
  "Set up bookmark support in the current `agent-shell' buffer."
  (setq-local bookmark-make-record-function
              #'agent-shell-bookmark-make-record))

(add-hook 'agent-shell-mode-hook #'agent-shell-bookmark--setup)

(provide 'agent-shell-bookmark)
;;; agent-shell-bookmark.el ends here
