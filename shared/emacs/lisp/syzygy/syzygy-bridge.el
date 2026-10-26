;;; syzygy-bridge.el --- shared encoding for acp-mobile elisp bridges -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; acp-mobile's callElisp helper evals one named function per endpoint over
;; emacsclient and reads the printed result.  Anything non-ASCII in a
;; printed string comes back octal-escaped (\342\200\231 for a curly
;; quote), so every bridge returning structured data hands back base64 of
;; UTF-8 JSON instead, and every bridge taking free text receives base64.
;; These two helpers are that convention; each feature file (presets,
;; models, projects) builds on them so the encoding never drifts.

;;; Code:

(require 'json)

(defun syzygy-bridge-encode-json (value)
  "Serialize VALUE as UTF-8 JSON wrapped in base64 without line breaks.
VALUE follows `json-serialize' conventions: alists for objects, vectors
for arrays, t and :false for booleans."
  (base64-encode-string
   (encode-coding-string (json-serialize value) 'utf-8)
   t))

(defun syzygy-bridge-decode-base64 (encoded)
  "Return ENCODED base64 as a UTF-8 string, or nil when ENCODED is nil or empty."
  (and encoded
       (not (string-empty-p encoded))
       (decode-coding-string (base64-decode-string encoded) 'utf-8)))

(provide 'syzygy-bridge)
;;; syzygy-bridge.el ends here
