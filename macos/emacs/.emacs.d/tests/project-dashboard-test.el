;;; project-dashboard-test.el --- Focused Project Dashboard tests -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Run with:
;;   emacs --batch -l ~/.emacs.d/init.el \
;;     -l ~/.emacs.d/tests/project-dashboard-test.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)

(when noninteractive
  (when (fboundp 'elpaca-process-queues)
    (elpaca-process-queues))
  (when (fboundp 'elpaca-wait)
    (elpaca-wait)))

(require 'project-dashboard)

(ert-deftest project-dashboard-test-recent-conversation-ages-are-relative ()
  "Conversation ages younger than fourteen days should read naturally."
  (let ((now (encode-time 0 0 12 2 9 2026)))
    (dolist (case '(("2026-09-02-11-59-30" . "just now")
                    ("2026-09-02-11-59-00" . "1 min ago")
                    ("2026-09-02-11-55-00" . "5 min ago")
                    ("2026-09-02-09-00-00" . "3 hr ago")
                    ("2026-09-01-12-00-00" . "1 day ago")
                    ("2026-08-19-12-00-01" . "13 days ago")))
      (should (equal (project-dashboard--conversation-age-label
                      (car case) now)
                     (cdr case))))))

(ert-deftest project-dashboard-test-conversation-age-switches-at-fourteen-days ()
  "Conversation age should become an ordinal calendar date at day fourteen."
  (let ((now (encode-time 0 0 12 2 9 2026)))
    (should (equal (project-dashboard--conversation-age-label
                    "2026-08-19-12-00-00" now)
                   "Aug 19th"))))

(ert-deftest project-dashboard-test-old-conversation-age-includes-year ()
  "Calendar dates should include the year when it differs from the current one."
  (let ((now (encode-time 0 0 12 2 9 2026)))
    (should (equal (project-dashboard--conversation-age-label
                    "2025-01-03-12-00-00" now)
                   "Jan 3rd, 2025"))))

(ert-deftest project-dashboard-test-invalid-conversation-date-passes-through ()
  "Impossible calendar timestamps should not become believable dates."
  (let ((now (encode-time 0 0 12 2 9 2026)))
    (should (equal (project-dashboard--conversation-age-label
                    "2026-02-30-12-00-00" now)
                   "2026-02-30-12-00-00"))))

(ert-deftest project-dashboard-test-calendar-date-stays-english-across-locales ()
  "English ordinal dates should not mix in localized month names."
  (let ((now (encode-time 0 0 12 2 9 2026))
        (system-time-locale "fr_FR.UTF-8"))
    (should (equal (project-dashboard--conversation-age-label
                    "2026-08-19-12-00-00" now)
                   "Aug 19th"))))

(ert-deftest project-dashboard-test-recent-conversation-time-never-touches-title ()
  "The rendered age and conversation title should have an explicit gap."
  (cl-letf (((symbol-function 'agent-recall-session-label)
             (lambda (_session-id) nil)))
    (with-temp-buffer
      (project-dashboard--render-recent-conversations
       '(("/tmp/conversation.md"
          :timestamp "unparseable-timestamp"
          :session-id "session-1"
          :preview "Conversation title")))
      (should (string-match-p
               (regexp-quote "unparseable-timestamp  Conversation title")
               (buffer-string))))))

(provide 'project-dashboard-test)
;;; project-dashboard-test.el ends here
