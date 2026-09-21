;;; voicelog-test.el --- Tests for voicelog -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'voicelog)

(defconst voicelog-test--zone "America/Chicago")

(defun voicelog-test--row (&rest kv)
  "Build a row alist from KV pairs, as `json-parse-string' would."
  (let (row)
    (while kv
      (push (cons (pop kv) (pop kv)) row))
    (nreverse row)))

;;; persona

(ert-deftest voicelog-persona-known ()
  (let ((p (voicelog--persona "Sergio Assist")))
    (should (equal (plist-get p :name) "NABU"))
    (should (equal (plist-get p :who) "Dad"))
    (should (eq (plist-get p :key) 'nabu))
    (should (eq (plist-get p :face) 'voicelog-nabu)))
  (should (eq (plist-get (voicelog--persona "Yvette Assist") :key) 'pandora))
  (should (eq (plist-get (voicelog--persona "Marx Assist") :key) 'andromeda)))

(ert-deftest voicelog-persona-unknown ()
  (let ((p (voicelog--persona "Guest Assist")))
    (should (equal (plist-get p :name) "Guest"))
    (should (null (plist-get p :who)))
    (should (null (plist-get p :key)))
    (should (eq (plist-get p :face) 'voicelog-neutral)))
  (should (equal (plist-get (voicelog--persona nil) :name) "Unknown")))

;;; origin

(ert-deftest voicelog-origin-absent-key ()
  (should (equal (voicelog--origin (voicelog-test--row 'ts "x")) "?")))

(ert-deftest voicelog-origin-null-is-phone ()
  (should (equal (voicelog--origin (voicelog-test--row 'satellite nil)) "phone")))

(ert-deftest voicelog-origin-satellite-stripped ()
  (should (equal (voicelog--origin (voicelog-test--row 'satellite "assist_satellite.rhea"))
                 "rhea")))

;;; overheard

(ert-deftest voicelog-overheard-short-no ()
  (should-not (voicelog--overheard-p "Turn on the lamp."))
  (should-not (voicelog--overheard-p nil)))

(ert-deftest voicelog-overheard-long-yes ()
  (should (voicelog--overheard-p (make-string 131 ?a))))

(ert-deftest voicelog-overheard-three-sentences-yes ()
  (should (voicelog--overheard-p "One. Two! Three?")))

;;; time

(ert-deftest voicelog-time-labels-local ()
  (let ((row (voicelog-test--row 'ts "2026-09-18T14:53:43.640945+00:00")))
    (should (equal (voicelog--day-key row voicelog-test--zone) "2026-09-18"))
    (should (equal (voicelog--day-label row voicelog-test--zone) "Friday, September 18"))
    (should (equal (voicelog--time-label row voicelog-test--zone) "9:53 AM"))))

(ert-deftest voicelog-time-crosses-midnight ()
  ;; 03:30 UTC on the 19th is still the 18th in Chicago.
  (let ((row (voicelog-test--row 'ts "2026-09-19T03:30:00+00:00")))
    (should (equal (voicelog--day-key row voicelog-test--zone) "2026-09-18"))
    (should (equal (voicelog--time-label row voicelog-test--zone) "10:30 PM"))))

(ert-deftest voicelog-time-bad-ts ()
  (should (equal (voicelog--day-key (voicelog-test--row 'ts "garbage")) ""))
  (should (equal (voicelog--time-label (voicelog-test--row 'ts nil)) "")))

;;; filtering

(defconst voicelog-test--rows
  (list
   (voicelog-test--row 'ts "2026-09-18T14:53:43+00:00" 'run_id "r1"
                       'pipeline "Marx Assist" 'heard "Good morning." 'said "Good morning."
                       'satellite "assist_satellite.pollux")
   (voicelog-test--row 'ts "2026-09-18T13:00:00+00:00" 'run_id "r2"
                       'pipeline "Yvette Assist" 'heard "What is the weather" 'said "Sunny."
                       'satellite nil)
   (voicelog-test--row 'ts "2026-09-17T20:00:00+00:00" 'run_id "r3"
                       'pipeline "Sergio Assist" 'heard "Play the dog song" 'said nil
                       'satellite "assist_satellite.kronos")
   (voicelog-test--row 'ts "2026-09-17T19:00:00+00:00" 'run_id "r4"
                       'pipeline "Sergio Assist" 'heard nil 'said nil
                       'satellite "assist_satellite.kronos")
   (voicelog-test--row 'ts "2026-09-01T19:00:00+00:00" 'run_id "r5"
                       'pipeline "Sergio Assist" 'heard "Old one" 'said "Old reply"))
  "Five rows: r4 is wake-only, r5 predates the satellite key.")

(defun voicelog-test--ids (rows)
  (mapcar (lambda (r) (alist-get 'run_id r)) rows))

(ert-deftest voicelog-visible-drops-wake-only ()
  (should (equal (voicelog-test--ids (voicelog--visible-rows voicelog-test--rows))
                 '("r1" "r2" "r3" "r5"))))

(ert-deftest voicelog-visible-persona ()
  (should (equal (voicelog-test--ids (voicelog--visible-rows voicelog-test--rows :persona 'nabu))
                 '("r3" "r5"))))

(ert-deftest voicelog-visible-today ()
  (should (equal (voicelog-test--ids
                  (voicelog--visible-rows voicelog-test--rows :today t
                                          :today-key "2026-09-18" :zone voicelog-test--zone))
                 '("r1" "r2"))))

(ert-deftest voicelog-visible-query-case-insensitive ()
  (should (equal (voicelog-test--ids (voicelog--visible-rows voicelog-test--rows :query "DOG"))
                 '("r3")))
  (should (equal (voicelog-test--ids (voicelog--visible-rows voicelog-test--rows :query "sunny"))
                 '("r2")))
  (should (equal (voicelog-test--ids (voicelog--visible-rows voicelog-test--rows :query ""))
                 '("r1" "r2" "r3" "r5"))))

(ert-deftest voicelog-visible-origin ()
  (should (equal (voicelog-test--ids (voicelog--visible-rows voicelog-test--rows :origin 'satellite))
                 '("r1" "r3")))
  (should (equal (voicelog-test--ids (voicelog--visible-rows voicelog-test--rows :origin 'phone))
                 '("r2"))))

(ert-deftest voicelog-visible-combined ()
  (should (equal (voicelog-test--ids
                  (voicelog--visible-rows voicelog-test--rows :persona 'nabu :query "dog"
                                          :origin 'satellite))
                 '("r3"))))

;;; rendering

(ert-deftest voicelog-render-two-rows-text ()
  (let* ((rows (list (nth 0 voicelog-test--rows) (nth 2 voicelog-test--rows)))
         (text (voicelog--render-rows rows voicelog-test--zone))
         (lines (split-string text "\n")))
    (should (equal (nth 0 lines)
                   (concat "FRIDAY, SEPTEMBER 18  " (make-string 40 ?─))))
    (should (equal (nth 1 lines) ""))
    (should (equal (nth 2 lines) "┃ ANDROMEDA  Marcos  pollux    9:53 AM"))
    (should (equal (nth 3 lines) "┃ “Good morning.”"))
    (should (equal (nth 4 lines) "┃ ↪ Good morning."))
    (should (equal (nth 5 lines) ""))
    (should (equal (nth 6 lines)
                   (concat "THURSDAY, SEPTEMBER 17  " (make-string 40 ?─))))
    (should (equal (nth 8 lines) "┃ NABU  Dad  kronos    3:00 PM"))
    (should (equal (nth 9 lines) "┃ “Play the dog song”"))
    (should (equal (nth 10 lines) "┃ ↪ no reply"))))

(ert-deftest voicelog-render-faces-and-run-property ()
  (let ((text (voicelog--render-rows (list (nth 0 voicelog-test--rows)) voicelog-test--zone)))
    (with-temp-buffer
      (insert text)
      (goto-char (point-min))
      (forward-line 2)
      (should (voicelog--cue-line-p))
      (should (equal (get-text-property (point) 'voicelog-run) "r1"))
      (search-forward "ANDROMEDA")
      (should (eq (get-text-property (1- (point)) 'face) 'voicelog-andromeda))
      (search-forward "Marcos")
      (should (eq (get-text-property (1- (point)) 'face) 'voicelog-dim))
      (forward-line 1)
      (should-not (voicelog--cue-line-p))
      (search-forward "Good morning.”")
      (should (eq (get-text-property (- (point) 2) 'face) 'voicelog-heard)))))

(ert-deftest voicelog-render-overheard-flag ()
  (let* ((row (voicelog-test--row 'ts "2026-09-18T14:00:00+00:00" 'run_id "r9"
                                  'pipeline "Yvette Assist"
                                  'heard "One. Two. Three. Four." 'said "ok"
                                  'satellite "assist_satellite.rhea"))
         (text (voicelog--render-rows (list row) voicelog-test--zone)))
    (should (string-search "┃ PANDORA  Mom  rhea  overheard?    9:00 AM" text))))

(ert-deftest voicelog-render-unknown-pipeline-no-who ()
  (let* ((row (voicelog-test--row 'ts "2026-09-18T14:00:00+00:00" 'run_id "r8"
                                  'pipeline "Guest Assist" 'heard "hi" 'said "hello"))
         (text (voicelog--render-rows (list row) voicelog-test--zone)))
    (should (string-search "┃ Guest  ?    9:00 AM" text))))

(ert-deftest voicelog-render-empty-list ()
  (should (equal (voicelog--render-rows nil) "")))

;;; mode and render

(defmacro voicelog-test--with-buffer (rows &rest body)
  "Run BODY in a fresh `voicelog-mode' buffer holding ROWS, rendered."
  (declare (indent 1))
  `(with-temp-buffer
     (voicelog-mode)
     (setq voicelog--rows ,rows)
     (setq voicelog--zone voicelog-test--zone)
     (voicelog--render)
     ,@body))

(ert-deftest voicelog-mode-outline-levels ()
  (voicelog-test--with-buffer voicelog-test--rows
    (goto-char (point-min))
    (should (outline-on-heading-p t))
    (should (= (funcall outline-level) 1))
    (forward-line 2)
    (should (outline-on-heading-p t))
    (should (= (funcall outline-level) 2))
    (forward-line 1)
    (should-not (outline-on-heading-p t))))

(ert-deftest voicelog-mode-next-previous-card ()
  (voicelog-test--with-buffer voicelog-test--rows
    (goto-char (point-min))
    (voicelog-next-card)
    (should (equal (get-text-property (point) 'voicelog-run) "r1"))
    (voicelog-next-card)
    (should (equal (get-text-property (point) 'voicelog-run) "r2"))
    ;; r3 is under a new day divider; j skips the divider.
    (voicelog-next-card)
    (should (equal (get-text-property (point) 'voicelog-run) "r3"))
    (voicelog-previous-card)
    (should (equal (get-text-property (point) 'voicelog-run) "r2"))))

(ert-deftest voicelog-mode-next-card-at-end-stays ()
  (voicelog-test--with-buffer voicelog-test--rows
    (goto-char (point-max))
    (voicelog-previous-card)
    (let ((pos (point)))
      (should (equal (get-text-property pos 'voicelog-run) "r5"))
      (voicelog-next-card)
      (should (= (point) pos)))))

(ert-deftest voicelog-mode-persona-filter-rerenders ()
  (voicelog-test--with-buffer voicelog-test--rows
    (voicelog-persona-nabu)
    (should-not (string-search "ANDROMEDA" (buffer-string)))
    (should (string-search "NABU" (buffer-string)))
    (should (string-search "Nabu" header-line-format))
    (voicelog-persona-all)
    (should (string-search "ANDROMEDA" (buffer-string)))))

(ert-deftest voicelog-mode-origin-cycles ()
  (voicelog-test--with-buffer voicelog-test--rows
    (should (null voicelog--origin))
    (voicelog-cycle-origin)
    (should (eq voicelog--origin 'satellite))
    (should-not (string-search "PANDORA" (buffer-string)))
    (voicelog-cycle-origin)
    (should (eq voicelog--origin 'phone))
    (should (string-search "PANDORA" (buffer-string)))
    (should-not (string-search "NABU" (buffer-string)))
    (voicelog-cycle-origin)
    (should (null voicelog--origin))))

(ert-deftest voicelog-mode-empty-state ()
  (voicelog-test--with-buffer voicelog-test--rows
    (setq voicelog--query "zzzz-nothing")
    (voicelog--render)
    (should (string-search "Nothing matches." (buffer-string)))
    (should (string-search "the house has been quiet here" (buffer-string)))))

(ert-deftest voicelog-mode-header-counts-and-status ()
  (voicelog-test--with-buffer voicelog-test--rows
    (should (string-search "4 exchanges · live" header-line-format))
    (setq voicelog--stale t)
    (voicelog--render)
    (should (string-search "stale" header-line-format))
    (setq voicelog--stale nil voicelog--live nil)
    (voicelog--render)
    (should (string-search "paused" header-line-format))))

(ert-deftest voicelog-mode-render-keeps-point-on-card ()
  (voicelog-test--with-buffer voicelog-test--rows
    (goto-char (point-min))
    (voicelog-next-card)
    (voicelog-next-card)
    (forward-line 1)                      ; inside r2's card, on the heard line
    ;; Prepend a new row: r2 moves down, point must follow it.
    (setq voicelog--rows
          (cons (voicelog-test--row 'ts "2026-09-18T15:00:00+00:00" 'run_id "r0"
                                    'pipeline "Marx Assist" 'heard "new" 'said "new"
                                    'satellite "assist_satellite.pollux")
                voicelog--rows))
    (voicelog--render)
    (should (equal (save-excursion (voicelog--card-run-at-point)) "r2"))))

(provide 'voicelog-test)
;;; voicelog-test.el ends here
