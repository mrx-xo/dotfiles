;;; syzygy-recall.el --- transcript history API for acp-mobile -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; The phone half of transcript browsing: acp-mobile's /api/transcripts
;; endpoint evals `syzygy-recall-transcripts-json' over emacsclient and
;; relays the JSON to the web UI's History screen.  Reads agent-recall's
;; index — the same source as `agent-recall-browse' on the desktop.
;;
;; agent-recall is required lazily inside the entry point: this file
;; loads from the syzygy umbrella (agent-shell-config.el), where
;; top-level requires of session-only packages break batch mode.

;;; Code:

(defvar agent-recall--index)
(declare-function agent-recall--index-ensure "agent-recall")

(defvar syzygy-recall--agent-cache (make-hash-table :test 'equal)
  "FILE -> agent name (\"Claude\", \"Codex\", ...) from the transcript header.
Transcripts are append-only, so a header parsed once never changes.")

(defun syzygy-recall--agent (file)
  "Return the agent name from FILE's transcript header, or \"?\"."
  (or (gethash file syzygy-recall--agent-cache)
      (puthash file
               (with-temp-buffer
                 (insert-file-contents file nil 0 200)
                 (goto-char (point-min))
                 (if (re-search-forward "^\\*\\*Agent:\\*\\* \\(.+\\)$" nil t)
                     (match-string 1)
                   "?"))
               syzygy-recall--agent-cache)))

(defun syzygy-recall-transcripts-json (&optional limit)
  "Return the newest LIMIT transcripts (default 100) as base64-wrapped JSON.
Each element: file, project, timestamp, agent, preview, sessionId.
Base64 because emacsclient octal-escapes non-ASCII in printed strings
(\\342\\200\\231 for a curly quote) — ASCII armor sidesteps that."
  (require 'agent-recall)
  (agent-recall--index-ensure)
  (let ((entries '()))
    (maphash (lambda (file e)
               (when (file-exists-p file)
                 (push (cons file e) entries)))
             agent-recall--index)
    (setq entries
          (seq-take (sort entries
                          (lambda (a b)
                            (string> (or (plist-get (cdr a) :timestamp) "")
                                     (or (plist-get (cdr b) :timestamp) ""))))
                    (or limit 100)))
    (base64-encode-string
     (encode-coding-string
      (json-serialize
       (vconcat
        (mapcar (lambda (fe)
                  (let ((file (car fe)) (e (cdr fe)))
                    `((file . ,file)
                      (project . ,(or (plist-get e :project) ""))
                      (timestamp . ,(or (plist-get e :timestamp) ""))
                      (agent . ,(syzygy-recall--agent file))
                      (preview . ,(or (plist-get e :preview) ""))
                      (sessionId . ,(or (plist-get e :session-id) "")))))
                entries)))
      'utf-8)
     t)))

(provide 'syzygy-recall)
;;; syzygy-recall.el ends here
