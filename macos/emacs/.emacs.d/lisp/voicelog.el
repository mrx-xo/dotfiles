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
;; Evil motions are untouched: j k h l gg G / n ? all mean what they
;; always mean.  The mode adds only:
;;
;;   C-j / C-k   next / previous card
;;   TAB         fold or unfold a card     S-TAB   cycle the whole buffer
;;   zM / zR     fold / unfold every card
;;   C-c f       the menu: who, when, where, what, refresh, live, quit
;;   q           quit
;;
;; Data comes from the homelab's voice-log-web `/api/log' endpoint.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'iso8601)
(require 'outline)
(require 'url)
(require 'json)
(require 'transient)

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

;;;; Filtering (pure)

(defun voicelog--nonblank-p (s)
  (and (stringp s) (not (string-empty-p s))))

(defconst voicelog--ranges
  '((today . "today") (yesterday . "yesterday")
    (week . "last 7 days") (month . "last 30 days"))
  "Time-frame keys and their header labels.")

(defun voicelog--days-before (day-key n zone)
  "The YYYY-MM-DD string N days before DAY-KEY in ZONE."
  (let* ((d (iso8601-parse-date day-key))
         (noon (encode-time (list 0 0 12 (decoded-time-day d) (decoded-time-month d)
                                  (decoded-time-year d) nil -1 zone))))
    (format-time-string "%Y-%m-%d" (time-subtract noon (* n 86400)) zone)))

(defun voicelog--range-bounds (range today-key zone)
  "Inclusive (SINCE . UNTIL) day keys for RANGE, or nil for all time."
  (pcase range
    ('today (cons today-key today-key))
    ('yesterday (let ((y (voicelog--days-before today-key 1 zone))) (cons y y)))
    ('week (cons (voicelog--days-before today-key 6 zone) today-key))
    ('month (cons (voicelog--days-before today-key 29 zone) today-key))
    (_ nil)))

(cl-defun voicelog--visible-rows (rows &key persona query today range origin
                                       overheard unanswered today-key zone)
  "Rows of ROWS that pass the active filters, in the same order.
Wake-only rows (neither heard nor said) never show. PERSONA is nil or
a persona key. QUERY is a case-insensitive substring over heard and
said. RANGE is nil, `today', `yesterday', `week', or `month', measured
back from TODAY-KEY; TODAY is the old spelling of RANGE `today'.
ORIGIN is nil, `satellite', or `phone'; rows written before the
satellite key existed match neither. OVERHEARD keeps only rows the
overheard heuristic flags; UNANSWERED keeps only rows with no reply."
  (let* ((today-key (or today-key (format-time-string "%Y-%m-%d" nil zone)))
         (bounds (voicelog--range-bounds (or range (and today 'today)) today-key zone))
         (needle (and (voicelog--nonblank-p query) (downcase query))))
    (cl-remove-if-not
     (lambda (row)
       (let ((heard (alist-get 'heard row))
             (said (alist-get 'said row)))
         (and (or (voicelog--nonblank-p heard) (voicelog--nonblank-p said))
              (or (null persona)
                  (eq persona (plist-get (voicelog--persona (alist-get 'pipeline row)) :key)))
              (or (null bounds)
                  (let ((k (voicelog--day-key row zone)))
                    (and (not (string< k (car bounds))) (not (string> k (cdr bounds))))))
              (or (null needle)
                  (string-search needle
                                 (downcase (concat (or heard "") " " (or said "")))))
              (or (not overheard) (voicelog--overheard-p heard))
              (or (not unanswered) (not (voicelog--nonblank-p said)))
              (pcase origin
                ('nil t)
                ('satellite (let ((s (alist-get 'satellite row)))
                              (and (stringp s) (string-prefix-p "assist_satellite." s))))
                ('phone (let ((cell (assq 'satellite row)))
                          (and cell (null (cdr cell)))))))))
     rows)))

;;;; Rendering (pure)

(defconst voicelog--bar "┃ "
  "Left bar every card line starts with.")

(defconst voicelog--cue-regexp "┃ [^“↪]"
  "A card's first line: the bar, then something that is not a quote or reply.")

(defconst voicelog--day-regexp "[A-Z]+, [A-Z]+ [0-9]+  ─"
  "A day divider line.")

(defun voicelog--cue-line-p ()
  "Non-nil when the current line is a card cue line."
  (save-excursion
    (beginning-of-line)
    (looking-at voicelog--cue-regexp)))

(defun voicelog--insert-day (row zone)
  (insert (propertize (concat (upcase (voicelog--day-label row zone)) "  ")
                      'face 'voicelog-day)
          (propertize (make-string 40 ?─) 'face 'voicelog-rule)
          "\n\n"))

(defun voicelog--insert-card (row zone)
  (let* ((p (voicelog--persona (alist-get 'pipeline row)))
         (face (plist-get p :face))
         (heard (alist-get 'heard row))
         (said (alist-get 'said row))
         (bar (propertize voicelog--bar 'face face))
         (beg (point)))
    (insert bar (propertize (plist-get p :name) 'face face))
    (when (plist-get p :who)
      (insert "  " (propertize (plist-get p :who) 'face 'voicelog-dim)))
    (insert "  " (propertize (voicelog--origin row) 'face 'voicelog-dim))
    (when (voicelog--overheard-p heard)
      (insert "  " (propertize "overheard?" 'face 'voicelog-ember)))
    (insert "    " (propertize (voicelog--time-label row zone) 'face 'voicelog-dim))
    (add-text-properties beg (point) (list 'voicelog-run (alist-get 'run_id row)))
    (insert "\n")
    (when (voicelog--nonblank-p heard)
      (insert bar (propertize (concat "“" heard "”") 'face 'voicelog-heard) "\n"))
    (insert bar (propertize "↪ " 'face face))
    (if (voicelog--nonblank-p said)
        (insert (propertize said 'face 'voicelog-muted))
      (insert (propertize "no reply" 'face '(voicelog-dim italic))))
    (insert "\n\n")))

(defun voicelog--render-rows (rows &optional zone)
  "Return the buffer text for ROWS: day dividers and one card per row.
ZONE overrides the local time zone, for tests."
  (with-temp-buffer
    (let (last-day)
      (dolist (row rows)
        (let ((day (voicelog--day-key row zone)))
          (unless (equal day last-day)
            (setq last-day day)
            (voicelog--insert-day row zone)))
        (voicelog--insert-card row zone)))
    (buffer-string)))

;;;; Buffer state

(defconst voicelog--buffer "*voicelog*")

(defvar-local voicelog--rows nil "Last good rows, newest first.")
(defvar-local voicelog--persona nil "nil, or a persona key.")
(defvar-local voicelog--query nil "Search term, or nil.")
(defvar-local voicelog--range nil "nil, `today', `yesterday', `week', or `month'.")
(defvar-local voicelog--origin nil "nil, `satellite', or `phone'.")
(defvar-local voicelog--overheard nil "Non-nil: only rows flagged overheard?.")
(defvar-local voicelog--unanswered nil "Non-nil: only rows with no reply.")
(defvar-local voicelog--live t "Non-nil: polling is on.")
(defvar-local voicelog--stale nil "Non-nil: the last fetch failed.")
(defvar-local voicelog--timer nil "The poll timer.")
(defvar-local voicelog--newest-run nil "Run id of the newest row at last render.")
(defvar-local voicelog--inflight-since nil "float-time of the pending fetch, or nil.")
(defvar-local voicelog--first-failure nil "Error text when no fetch has ever succeeded.")
(defvar-local voicelog--zone nil "Time zone override, nil for local. Tests set it.")

;;;; Header

(defun voicelog--persona-label (key)
  (pcase key ('nabu "Nabu") ('pandora "Pandora") ('andromeda "Andromeda") (_ nil)))

(defun voicelog--filter-summary ()
  "The active filters as \" · Pandora · yesterday · \"dog\" · satellite\"."
  (mapconcat (lambda (s) (concat " · " s))
             (delq nil (list (voicelog--persona-label voicelog--persona)
                             (alist-get voicelog--range voicelog--ranges)
                             (and (voicelog--nonblank-p voicelog--query)
                                  (format "\"%s\"" voicelog--query))
                             (and voicelog--origin (symbol-name voicelog--origin))
                             (and voicelog--overheard "overheard")
                             (and voicelog--unanswered "unanswered")))
             ""))

(defun voicelog--header (n)
  (concat (propertize "  VOICE LOG" 'face 'bold)
          (propertize (format "   %d exchange%s · %s" n (if (= n 1) "" "s")
                              (cond (voicelog--stale "stale")
                                    ((not voicelog--live) "paused")
                                    (t "live")))
                      'face 'voicelog-muted)
          (propertize (voicelog--filter-summary) 'face 'voicelog-dim)))

;;;; Render into the buffer

(defun voicelog--card-run-at-point ()
  "Run id of the card point is in, or nil on a divider or blank line."
  (save-excursion
    (beginning-of-line)
    (while (and (not (bobp))
                (not (get-text-property (point) 'voicelog-run))
                (not (looking-at voicelog--day-regexp))
                (not (looking-at "^$")))
      (forward-line -1))
    (get-text-property (point) 'voicelog-run)))

(defun voicelog--find-run (run)
  "Position of the cue line for RUN, or nil."
  (save-excursion
    (goto-char (point-min))
    (let (pos)
      (while (and (not pos) (not (eobp)))
        (when (equal (get-text-property (point) 'voicelog-run) run)
          (setq pos (point)))
        (forward-line 1))
      pos)))

(defun voicelog--visible ()
  (voicelog--visible-rows voicelog--rows
                          :persona voicelog--persona :query voicelog--query
                          :range voicelog--range :origin voicelog--origin
                          :overheard voicelog--overheard :unanswered voicelog--unanswered
                          :zone voicelog--zone))

(defun voicelog--render ()
  "Redraw the current buffer from state, keeping point and window start."
  (let* ((run (voicelog--card-run-at-point))
         (line (line-number-at-pos))
         (win (get-buffer-window (current-buffer)))
         (start (and win (window-start win)))
         (visible (voicelog--visible))
         (inhibit-read-only t))
    (erase-buffer)
    (cond
     ((and (null voicelog--rows) voicelog--first-failure)
      (insert "\n  " (propertize "Can't reach the voice log." 'face 'voicelog-muted)
              "\n  " (propertize voicelog-url 'face 'voicelog-dim)
              "\n  " (propertize voicelog--first-failure 'face 'voicelog-dim) "\n"))
     ((null visible)
      (insert "\n  " (propertize "Nothing matches." 'face 'voicelog-muted)
              "\n  " (propertize "the house has been quiet here" 'face 'voicelog-dim) "\n"))
     (t (insert (voicelog--render-rows visible voicelog--zone))))
    (setq header-line-format (voicelog--header (length visible)))
    (setq voicelog--newest-run (and voicelog--rows (alist-get 'run_id (car voicelog--rows))))
    (goto-char (point-min))
    (let ((pos (and run (voicelog--find-run run))))
      (if pos (goto-char pos) (forward-line (1- line))))
    (when (and win start (<= start (point-max)))
      (set-window-start win start))))

;;;; Commands

(defun voicelog--outline-level ()
  (if (looking-at voicelog--bar) 2 1))

(defun voicelog--move-card (n)
  "Move N cards forward (negative: back), skipping day dividers."
  (let ((start (point)))
    (outline-next-visible-heading n)
    (while (and (outline-on-heading-p t) (= (voicelog--outline-level) 1)
                (not (if (> n 0) (eobp) (bobp))))
      (outline-next-visible-heading n))
    (unless (and (outline-on-heading-p t) (= (voicelog--outline-level) 2))
      (goto-char start)
      (message "voicelog: %s card" (if (> n 0) "last" "first")))))

(defun voicelog-next-card () (interactive) (voicelog--move-card 1))
(defun voicelog-previous-card () (interactive) (voicelog--move-card -1))

(defun voicelog--set-persona (key)
  (setq voicelog--persona key)
  (voicelog--render))

(defun voicelog-persona-all () "Show every persona." (interactive) (voicelog--set-persona nil))
(defun voicelog-persona-nabu () "Only Nabu." (interactive) (voicelog--set-persona 'nabu))
(defun voicelog-persona-pandora () "Only Pandora." (interactive) (voicelog--set-persona 'pandora))
(defun voicelog-persona-andromeda () "Only Andromeda." (interactive) (voicelog--set-persona 'andromeda))

(defun voicelog--set-range (range)
  (setq voicelog--range range)
  (voicelog--render))

(defun voicelog-range-all () "All time." (interactive) (voicelog--set-range nil))
(defun voicelog-range-today () "Only today." (interactive) (voicelog--set-range 'today))
(defun voicelog-range-yesterday () "Only yesterday." (interactive) (voicelog--set-range 'yesterday))
(defun voicelog-range-week () "The last 7 days." (interactive) (voicelog--set-range 'week))
(defun voicelog-range-month () "The last 30 days." (interactive) (voicelog--set-range 'month))

(defun voicelog-toggle-today ()
  "Toggle between today and all time."
  (interactive)
  (voicelog--set-range (if (eq voicelog--range 'today) nil 'today)))

(defun voicelog--set-origin (origin)
  (setq voicelog--origin origin)
  (voicelog--render))

(defun voicelog-origin-any () "Any origin." (interactive) (voicelog--set-origin nil))
(defun voicelog-origin-satellite () "Only satellites." (interactive) (voicelog--set-origin 'satellite))
(defun voicelog-origin-phone () "Only phones and browsers." (interactive) (voicelog--set-origin 'phone))

(defun voicelog-cycle-origin ()
  "Cycle origin: any, satellite, phone."
  (interactive)
  (voicelog--set-origin (pcase voicelog--origin
                          ('nil 'satellite) ('satellite 'phone) (_ nil))))

(defun voicelog-search (term)
  "Filter on TERM over heard and said. Empty clears."
  (interactive (list (read-string "search what was said: " voicelog--query)))
  (setq voicelog--query (and (voicelog--nonblank-p term) term))
  (voicelog--render))

(defun voicelog-toggle-overheard ()
  "Toggle: only rows the overheard heuristic flags."
  (interactive)
  (setq voicelog--overheard (not voicelog--overheard))
  (voicelog--render))

(defun voicelog-toggle-unanswered ()
  "Toggle: only rows where the assistant said nothing."
  (interactive)
  (setq voicelog--unanswered (not voicelog--unanswered))
  (voicelog--render))

(defun voicelog-clear-filters ()
  "Drop every filter."
  (interactive)
  (setq voicelog--persona nil voicelog--query nil voicelog--range nil
        voicelog--origin nil voicelog--overheard nil voicelog--unanswered nil)
  (voicelog--render))

(defun voicelog-quit ()
  "Bury the voicelog buffer."
  (interactive)
  (quit-window))

;;;; Menu

(defun voicelog--menu-description ()
  "Transient heading: the same words as the header line."
  (with-current-buffer (if (and (boundp 'transient--original-buffer)
                                (buffer-live-p transient--original-buffer))
                           transient--original-buffer
                         (current-buffer))
    (string-trim (substring-no-properties (voicelog--header (length (voicelog--visible)))))))

(transient-define-prefix voicelog-menu ()
  "Filters and actions for the voice log. Filters stay open so they combine."
  [:description voicelog--menu-description
   ["Who"
    ("a" "everyone" voicelog-persona-all :transient t)
    ("n" "Nabu" voicelog-persona-nabu :transient t)
    ("p" "Pandora" voicelog-persona-pandora :transient t)
    ("m" "Andromeda" voicelog-persona-andromeda :transient t)]
   ["When"
    ("t" "today" voicelog-range-today :transient t)
    ("y" "yesterday" voicelog-range-yesterday :transient t)
    ("w" "last 7 days" voicelog-range-week :transient t)
    ("M" "last 30 days" voicelog-range-month :transient t)
    ("T" "all time" voicelog-range-all :transient t)]
   ["Where"
    ("s" "satellites" voicelog-origin-satellite :transient t)
    ("P" "phones" voicelog-origin-phone :transient t)
    ("S" "anywhere" voicelog-origin-any :transient t)]
   ["What"
    ("/" "search" voicelog-search :transient t)
    ("o" "overheard only" voicelog-toggle-overheard :transient t)
    ("u" "unanswered only" voicelog-toggle-unanswered :transient t)
    ("c" "clear filters" voicelog-clear-filters :transient t)]
   ["Buffer"
    ("r" "refresh" voicelog-refresh :transient t)
    ("l" "live on / off" voicelog-toggle-live :transient t)
    ("q" "quit" voicelog-quit)]])

(defun voicelog-help ()
  "Open the menu."
  (interactive)
  (voicelog-menu))

;;;; Mode

(defvar voicelog-mode-map
  (let ((map (make-sparse-keymap)))
    ;; No single letters: evil motions keep every one of them.
    (define-key map (kbd "C-j") #'voicelog-next-card)
    (define-key map (kbd "C-k") #'voicelog-previous-card)
    (define-key map (kbd "C-c f") #'voicelog-menu)
    (define-key map (kbd "C-c C-c") #'voicelog-menu)
    (define-key map (kbd "C-c r") #'voicelog-refresh)
    (define-key map "zM" #'outline-hide-body)
    (define-key map "zR" #'outline-show-all)
    map)
  "Keymap for `voicelog-mode'.")

(define-derived-mode voicelog-mode special-mode "voicelog"
  "The house voice log: browser cards, org navigation."
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  (setq-local cursor-type 'bar)
  (setq-local outline-regexp (concat voicelog--day-regexp "\\|" voicelog--cue-regexp))
  (setq-local outline-level #'voicelog--outline-level)
  (setq-local outline-minor-mode-cycle t)
  (setq-local outline-minor-mode-highlight nil)
  (outline-minor-mode 1)
  (setq header-line-format (voicelog--header 0))
  (add-hook 'kill-buffer-hook #'voicelog--cleanup nil t))

(defun voicelog--cleanup ()
  "Cancel the poll timer."
  (when voicelog--timer
    (cancel-timer voicelog--timer)
    (setq voicelog--timer nil)))

(declare-function evil-set-initial-state "evil-core")
(declare-function evil-define-key* "evil-core")

(with-eval-after-load 'evil
  ;; Motion state, and only these keys layered on top of it.  The mode
  ;; map is deliberately NOT an overriding map, so special-mode's own
  ;; g / h / SPC / ? bindings never shadow evil either.
  (evil-set-initial-state 'voicelog-mode 'motion)
  (evil-define-key* 'motion voicelog-mode-map
    (kbd "C-j") #'voicelog-next-card
    (kbd "C-k") #'voicelog-previous-card
    (kbd "C-c f") #'voicelog-menu
    (kbd "C-c C-c") #'voicelog-menu
    (kbd "C-c r") #'voicelog-refresh
    "zM" #'outline-hide-body
    "zR" #'outline-show-all
    "q" #'voicelog-quit))

;;;; Fetch

(defvar url-http-response-status)

(defun voicelog--parse-response ()
  "Parse the `url-retrieve' response in the current buffer into rows.
Signals on a non-200 status or bad JSON."
  (let ((status (and (boundp 'url-http-response-status) url-http-response-status)))
    (unless (eq status 200)
      (error "HTTP %s" (or status "no status")))
    (goto-char (point-min))
    (unless (re-search-forward "\r?\n\r?\n" nil t)
      (error "no response body"))
    (let ((body (decode-coding-string (buffer-substring-no-properties (point) (point-max))
                                      'utf-8)))
      (let ((rows (json-parse-string body :object-type 'alist :array-type 'list
                                     :null-object nil :false-object nil)))
        (unless (listp rows) (error "not a JSON array"))
        rows))))

(defun voicelog--on-rows (buffer rows)
  "Store ROWS in BUFFER and re-render when the newest run changed."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq voicelog--inflight-since nil
            voicelog--stale nil
            voicelog--first-failure nil)
      (let ((newest (and rows (alist-get 'run_id (car rows)))))
        (setq voicelog--rows rows)
        (unless (and voicelog--newest-run (equal newest voicelog--newest-run)
                     (not (string-empty-p (buffer-string))))
          (voicelog--render))
        ;; Header status may still need to flip live/stale even when rows did not change.
        (setq header-line-format (voicelog--header (length (voicelog--visible))))))))

(defun voicelog--on-failure (buffer err)
  "Mark BUFFER stale after a failed fetch described by ERR, keeping old rows."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq voicelog--inflight-since nil
            voicelog--stale t)
      (unless voicelog--rows
        (setq voicelog--first-failure (format "%s" err)))
      (voicelog--render)
      (message "voicelog: %s" err))))

(defun voicelog--on-response (status buffer)
  "`url-retrieve' callback: hand rows or the error to BUFFER."
  (let ((response (current-buffer))
        (err (plist-get status :error))
        rows)
    (unwind-protect
        (if err
            (setq err (format "%S" err))
          (condition-case e
              (setq rows (voicelog--parse-response))
            (error (setq err (error-message-string e)))))
      (kill-buffer response))
    (if err
        (voicelog--on-failure buffer err)
      (voicelog--on-rows buffer rows))))

(defun voicelog--fetch (buffer)
  "Start an async fetch of `voicelog-url' for BUFFER."
  (with-current-buffer buffer
    (setq voicelog--inflight-since (float-time)))
  (let ((url-show-status nil))
    (condition-case e
        (url-retrieve voicelog-url #'voicelog--on-response (list buffer) t t)
      (error (voicelog--on-failure buffer (error-message-string e))))))

(defun voicelog--poll (buffer)
  "Timer body: fetch when BUFFER is visible, live, and not mid-fetch."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and voicelog--live (get-buffer-window buffer t))
        (cond
         ((null voicelog--inflight-since)
          (voicelog--fetch buffer))
         ((> (- (float-time) voicelog--inflight-since) voicelog-timeout-seconds)
          (setq voicelog--stale t)
          (voicelog--fetch buffer)))))))

(defun voicelog-refresh ()
  "Fetch now."
  (interactive)
  (setq voicelog--inflight-since nil)
  (voicelog--fetch (current-buffer)))

(defun voicelog-toggle-live ()
  "Toggle polling; the header shows paused while off."
  (interactive)
  (setq voicelog--live (not voicelog--live))
  (setq header-line-format (voicelog--header (length (voicelog--visible))))
  (when voicelog--live (voicelog--poll (current-buffer))))

;;;###autoload
(defun voicelog ()
  "Open the house voice log."
  (interactive)
  (let ((existing (get-buffer voicelog--buffer)))
    (if existing
        (progn (pop-to-buffer existing)
               (voicelog--poll existing))
      (with-current-buffer (get-buffer-create voicelog--buffer)
        (voicelog-mode)
        (let ((inhibit-read-only t))
          (insert "\n  " (propertize "Loading the transcript…" 'face 'voicelog-dim) "\n"))
        (pop-to-buffer (current-buffer))
        (voicelog--fetch (current-buffer))
        (setq voicelog--timer
              (run-at-time voicelog-poll-seconds voicelog-poll-seconds
                           #'voicelog--poll (current-buffer)))))))

(provide 'voicelog)
;;; voicelog.el ends here
