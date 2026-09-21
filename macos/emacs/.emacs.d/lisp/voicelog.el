;;; voicelog.el --- The house voice log, read from Emacs -*- lexical-binding: t; -*-

;; Author: Marcos Andrade
;; Keywords: convenience

;;; Commentary:

;; The Emacs sibling of voicelog.andrade-lab.com: every Assist exchange
;; the house heard, newest first, grouped by day, one card per exchange.
;; Cards look like the browser page; navigation feels like org.
;;
;; M-x voicelog  (or SPC V)
;;
;;   j / k     next / previous card       gg / G  top / bottom
;;   TAB       fold or unfold a card      S-TAB   cycle the whole buffer
;;   a n p m   all / Nabu / Pandora / Andromeda
;;   /         search heard + said        t       toggle today
;;   s         cycle origin: any, satellite, phone
;;   r         refresh now                l       toggle live polling
;;   ?         keys                       q       quit
;;
;; Data comes from the homelab's voice-log-web `/api/log' endpoint.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'iso8601)
(require 'outline)
(require 'url)
(require 'json)

(defgroup voicelog nil
  "Emacs reader for the house voice log."
  :group 'external)

(defcustom voicelog-url "https://voicelog.andrade-lab.com/api/log"
  "JSON endpoint served by voice-log-web on the homelab."
  :type 'string)

(defcustom voicelog-poll-seconds 15
  "Seconds between refreshes while the buffer is visible."
  :type 'number)

(defcustom voicelog-timeout-seconds 5
  "Seconds after which an unanswered fetch counts as failed."
  :type 'number)

;;;; Faces

(defface voicelog-nabu '((t :foreground "#E6A84E" :weight bold))
  "Nabu, Sergio's assistant.")
(defface voicelog-pandora '((t :foreground "#DB8AB6" :weight bold))
  "Pandora, Yvette's assistant.")
(defface voicelog-andromeda '((t :foreground "#6FB6C4" :weight bold))
  "Andromeda, Marcos's assistant.")
(defface voicelog-neutral '((t :foreground "#9B8E79" :weight bold))
  "Any pipeline not in the persona map.")
(defface voicelog-dim '((t :foreground "#6E6353"))
  "Who, origin, time, and other quiet text.")
(defface voicelog-muted '((t :foreground "#A2937C"))
  "The assistant's reply.")
(defface voicelog-ember '((t :foreground "#E27049" :height 0.85))
  "The overheard? flag.")
(defface voicelog-heard '((t :foreground "#EFE7D9" :height 1.1))
  "What the person said.")
(defface voicelog-day '((t :foreground "#6E6353" :weight bold :height 0.9))
  "Day divider.")
(defface voicelog-rule '((t :foreground "#372C1F"))
  "The rule after a day divider.")

;;;; Row helpers (pure)

(defconst voicelog--personas
  '(("Sergio Assist" . (:name "NABU" :who "Dad" :key nabu :face voicelog-nabu))
    ("Yvette Assist" . (:name "PANDORA" :who "Mom" :key pandora :face voicelog-pandora))
    ("Marx Assist" . (:name "ANDROMEDA" :who "Marcos" :key andromeda :face voicelog-andromeda)))
  "Pipeline name to persona plist.")

(defun voicelog--persona (pipeline)
  "Persona plist for PIPELINE, or a neutral one for anything unknown."
  (or (cdr (assoc pipeline voicelog--personas))
      (list :name (string-remove-suffix " Assist" (or pipeline "Unknown"))
            :who nil :key nil :face 'voicelog-neutral)))

(defun voicelog--origin (row)
  "Origin tag for ROW: a satellite name, \"phone\", or \"?\" when unknown.
Rows written before 2026-09-08 have no `satellite' key at all."
  (let ((cell (assq 'satellite row)))
    (cond ((null cell) "?")
          ((null (cdr cell)) "phone")
          (t (string-remove-prefix "assist_satellite." (cdr cell))))))

(defun voicelog--overheard-p (heard)
  "Non-nil when HEARD is probably ambient talk, not a command.
Same heuristic as the browser page: over 130 characters, or three or
more sentence enders."
  (and heard
       (or (> (length heard) 130)
           (>= (cl-count-if (lambda (c) (memq c '(?. ?! ??))) heard) 3))))

(defun voicelog--time (row)
  "ROW's `ts' as a Lisp timestamp, or nil when missing or unparsable."
  (let ((ts (alist-get 'ts row)))
    (and (stringp ts)
         (condition-case nil
             (encode-time (iso8601-parse ts))
           (error nil)))))

(defun voicelog--day-key (row &optional zone)
  "Local calendar day of ROW as YYYY-MM-DD, or \"\" when unknown."
  (let ((time (voicelog--time row)))
    (if time (format-time-string "%Y-%m-%d" time zone) "")))

(defun voicelog--day-label (row &optional zone)
  "Local day of ROW as \"Friday, September 18\", or \"\"."
  (let ((time (voicelog--time row)))
    (if time (format-time-string "%A, %B %-d" time zone) "")))

(defun voicelog--time-label (row &optional zone)
  "Local clock time of ROW as \"9:41 AM\", or \"\"."
  (let ((time (voicelog--time row)))
    (if time (format-time-string "%-I:%M %p" time zone) "")))

(provide 'voicelog)
;;; voicelog.el ends here
