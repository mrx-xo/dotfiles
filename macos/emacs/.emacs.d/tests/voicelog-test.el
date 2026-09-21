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

(provide 'voicelog-test)
;;; voicelog-test.el ends here
