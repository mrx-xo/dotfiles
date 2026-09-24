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

(let* ((test-directory (file-name-directory (or load-file-name buffer-file-name)))
       (dashboard-directory
        (expand-file-name "../lisp/project-dashboard" test-directory)))
  (add-to-list 'load-path dashboard-directory))

(require 'project-dashboard)

(load (expand-file-name
       "../lisp/project-dashboard/project-dashboard-art.el"
       (file-name-directory (or load-file-name buffer-file-name)))
      nil nil t)

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

(ert-deftest project-dashboard-test-recent-conversation-shows-picker-metadata ()
  "A conversation row carries label, tags, open marker, foreign project, and note."
  (cl-letf (((symbol-function 'agent-recall-session-label) (lambda (_) "my-label"))
            ((symbol-function 'agent-recall-catalogue-get)
             (lambda (_) '((tags "keep" "infra") (note "Why it was kept"))))
            ((symbol-function 'major-pane-workspace--live-buffer) (lambda (_) nil)))
    (with-temp-buffer
      (setq project-dashboard--project-root "/tmp/dotfiles/")
      (let ((line (project-dashboard--conversation-line
                   "/tmp/conversation.md"
                   '(:timestamp "x" :session-id "s1" :project "home-lab"
                                :preview "First message"))))
        (dolist (piece '("[home-lab]" "my-label" "#keep #infra"))
          (should (string-match-p (regexp-quote piece) line)))
        (should-not (string-match-p "(open)" line))
        (should (string-match-p "Why it was kept\\|First message" line))
        (should-not (string-match-p "\\[dotfiles\\]"
                                    (project-dashboard--conversation-line
                                     "/tmp/c.md" '(:timestamp "x" :project "dotfiles"))))))))

(ert-deftest project-dashboard-test-open-conversation-prefers-live-label ()
  "An open chat shows its live major-pane label over the stored one."
  (let* ((chat (generate-new-buffer " *chat*"))
         (major-pane--labels (make-hash-table :test #'eq)))
    (puthash chat "LIVE" major-pane--labels)
    (unwind-protect
        (cl-letf (((symbol-function 'agent-recall-session-label) (lambda (_) "stored"))
                  ((symbol-function 'major-pane-workspace--live-buffer) (lambda (_) chat)))
          (with-temp-buffer
            (let ((line (project-dashboard--conversation-line
                         "/tmp/conversation.md" '(:timestamp "x" :session-id "s1"))))
              (should (string-match-p "LIVE" line))
              (should-not (string-match-p "stored" line))
              (should (string-match-p "(open)" line)))))
      (kill-buffer chat))))

(ert-deftest project-dashboard-test-agent-shell-function-runs-in-project-root ()
  "The `a' action calls `project-dashboard-agent-shell-function' with
`default-directory' bound to the project root."
  (let* ((seen nil)
         (project-dashboard-agent-shell-function
          (lambda () (setq seen default-directory))))
    (project-dashboard--start-agent-shell "/tmp/")
    (should (equal seen "/tmp/"))))

(provide 'project-dashboard-test)
;;; project-dashboard-test.el ends here
