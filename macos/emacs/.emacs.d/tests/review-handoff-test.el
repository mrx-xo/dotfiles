;;; review-handoff-test.el --- The author's published walkthrough -*- lexical-binding: t; -*-
(require 'ert)
(require 'review-handoff)
(require 'review-walkthrough-agent)

(defconst review-handoff-test--route
  "{\"steps\":[{\"path\":\"a.el\",\"side\":\"new\",\"line_start\":3,\"line_end\":3,\"title\":\"Three\",\"body\":\"Why three.\"}],
    \"session\":{\"agent\":\"claude\",\"id\":\"abc\"}}")

(defun review-handoff-test--body (&optional head route)
  (format "Fixes the thing.\r\n\r\n<details><summary>Review handoff</summary>\r\n\r\n## Intent\r\nMake three THREE.\r\n\r\n<!-- review-handoff v1 head=%s\r\n%s\r\n-->\r\n</details>\r\n"
          (or head "1234567890abcdef") (or route review-handoff-test--route)))

;;; Parsing

(ert-deftest review-handoff-parse-reads-block ()
  (let ((h (review-handoff-parse (review-handoff-test--body))))
    (should (equal (plist-get h :head) "1234567890abcdef"))
    (should (equal (plist-get (car (plist-get h :steps)) :title) "Three"))
    (should (eq (plist-get (car (plist-get h :steps)) :side) 'new))
    (should (equal (plist-get (plist-get h :session) :id) "abc"))
    (should (string-match-p "## Intent" (plist-get h :text)))
    (should-not (string-match-p "review-handoff\\|<summary>\\|Fixes the thing" (plist-get h :text)))))

(ert-deftest review-handoff-parse-absent ()
  (should-not (review-handoff-parse "Just a description."))
  (should-not (review-handoff-parse nil))
  (should-not (review-handoff-parse :null)))

(ert-deftest review-handoff-parse-malformed-never-signals ()
  (let ((h (review-handoff-parse (review-handoff-test--body nil "{\"steps\": ["))))
    (should (string-prefix-p "invalid handoff route" (plist-get h :error))))
  (should (plist-get (review-handoff-parse "<!-- review-handoff v1 head=abcdef1 {}") :error))
  (should (plist-get (review-handoff-parse (review-handoff-test--body nil "{\"steps\":[]}")) :error)))

(ert-deftest review-handoff-parse-last-block-wins ()
  (let ((h (review-handoff-parse
            (concat (review-handoff-test--body "aaaaaaa1")
                    (review-handoff-test--body "bbbbbbb2")))))
    (should (equal (plist-get h :head) "bbbbbbb2"))))

(ert-deftest review-handoff-parse-without-details ()
  (let ((h (review-handoff-parse
            (format "Intro text.\n<!-- review-handoff v1 head=abcdef12\n%s\n-->\n"
                    review-handoff-test--route))))
    (should (equal (plist-get h :text) "Intro text."))))

(ert-deftest review-handoff-same-commit ()
  (should (review-handoff-same-commit-p "abcdef1" "ABCDEF1234"))
  (should-not (review-handoff-same-commit-p "abcdef1" "abcdef2999"))
  (should-not (review-handoff-same-commit-p "abc" "abcdef")))

(ert-deftest review-handoff-read-file ()
  (let* ((dir (make-temp-file "handoff" t))
         (file (expand-file-name "abcdef1234567.json" dir)))
    (unwind-protect
        (progn
          (should-not (review-handoff-read-file (expand-file-name "missing.json" dir)))
          (with-temp-file file (insert review-handoff-test--route))
          (let ((h (review-handoff-read-file file)))
            (should (equal (plist-get h :head) "abcdef1234567"))
            (should (= (length (plist-get h :steps)) 1))))
      (delete-directory dir t))))

;;; Sessions

(defconst review-handoff-test--spec
  '(("a.el" "1\n2\n3\n4\n5\n" "1\n2\nTHREE\n4\n5\n")))

(defun review-handoff-test--source (&optional recipe)
  (make-review-source
   :name "fake" :title "Fake" :range-label "x -> y" :recipe (or recipe '(:kind fake :id "handoff"))
   :files (lambda () (mapcar (lambda (s) (list :path (car s) :old-path (car s) :kind 'modified))
                             review-handoff-test--spec))
   :text (lambda (file side cb)
           (let ((s (assoc (plist-get file :path) review-handoff-test--spec)))
             (funcall cb (if (eq side 'old) (nth 1 s) (nth 2 s)))))
   :origin (lambda (file start _end) (list :label (format "%s:%d" (plist-get file :path) start)))))

(defmacro review-handoff-test--with (var recipe &rest body)
  (declare (indent 2))
  `(let ((review-store-directory (file-name-as-directory (make-temp-file "review-handoff" t)))
         (review-store--memory (make-hash-table :test #'equal)))
     (save-window-excursion
       (let ((,var (review-session-start (review-handoff-test--source ,recipe))))
         (review-session-load ,var 0 #'ignore)
         (unwind-protect (progn ,@body)
           (when review-session--current (review-session-quit))
           (delete-directory review-store-directory t))))))

(ert-deftest review-handoff-collect-fresh-and-stale ()
  (review-handoff-test--with s nil
    (should-not (review-handoff-get s))
    (review-handoff-collect s (review-handoff-test--body "1234567890abcdef") "1234567890abcdef99")
    (should-not (plist-get (review-handoff-get s) :stale))
    (review-handoff-collect s (review-handoff-test--body "1234567890abcdef") "fedcba9876543210")
    (should (plist-get (review-handoff-get s) :stale))
    (review-handoff-collect s "no handoff here" "fedcba9876543210")
    (should-not (review-handoff-get s))))

(ert-deftest review-handoff-start-marks-author ()
  (review-handoff-test--with s nil
    (review-handoff-collect s (review-handoff-test--body "1234567") "1234567")
    (should (equal (review-handoff-start s) "ok 1 of 1 steps"))
    (should (plist-get (review-session-walkthrough s) :author))
    (should (string-match-p "## Intent" (review-handoff-context-text s)))
    (should (string-match-p "\"abc\"" (review-handoff-context-text s)))))

(ert-deftest review-handoff-context-only-for-author-route ()
  (review-handoff-test--with s nil
    (review-handoff-collect s (review-handoff-test--body "1234567") "1234567")
    (should-not (review-handoff-context-text s))))

(ert-deftest review-handoff-card-labels-author ()
  (let ((step (list :path "a.el" :title "T" :body "B")))
    (should (string-match-p "AUTHOR WALKTHROUGH" (format "%s" (review-walkthrough--card step 1 1 80 t))))
    (should (string-match-p "AGENT WALKTHROUGH" (format "%s" (review-walkthrough--card step 1 1 80))))))

(ert-deftest review-handoff-bar-ready ()
  (review-handoff-test--with s nil
    (should-not (review-handoff--bar s))
    (review-handoff-collect s (review-handoff-test--body "1234567") "1234567")
    (should (string-match-p "WALK ready" (review-handoff--bar s)))
    (review-handoff-start s)
    (should-not (review-handoff--bar s))))

;;; W

(ert-deftest review-handoff-w-retry-keeps-author-route ()
  (review-handoff-test--with s nil
    (review-handoff-collect s (review-handoff-test--body "1234567") "1234567")
    (let (asked)
      (cl-letf (((symbol-function 'review-walkthrough-request) (lambda () (setq asked t)))
                ((symbol-function 'review-handoff-start) (lambda (_) "retry: loading a.el")))
        (review-walkthrough-agent-dwim)
        (should-not asked)))))

(ert-deftest review-handoff-w-plays-author-route ()
  (review-handoff-test--with s nil
    (review-handoff-collect s (review-handoff-test--body "1234567") "1234567")
    (let (asked)
      (cl-letf (((symbol-function 'review-walkthrough-request) (lambda () (setq asked t))))
        (review-walkthrough-agent-dwim)
        (should-not asked)
        (should (plist-get (review-session-walkthrough s) :author))))))

(ert-deftest review-handoff-w-prefix-asks-agent ()
  (review-handoff-test--with s nil
    (review-handoff-collect s (review-handoff-test--body "1234567") "1234567")
    (let (asked)
      (cl-letf (((symbol-function 'review-walkthrough-request) (lambda () (setq asked t))))
        (review-walkthrough-agent-dwim '(4))
        (should asked)))))

(ert-deftest review-handoff-w-stale-and-error ()
  (review-handoff-test--with s nil
    (let (asked)
      (cl-letf (((symbol-function 'review-walkthrough-request) (lambda () (setq asked t)))
                ((symbol-function 'read-key) (lambda (&rest _) ?x)))
        (review-handoff-collect s (review-handoff-test--body "1234567") "7654321")
        (review-walkthrough-agent-dwim)
        (should asked)
        (setq asked nil)
        (review-handoff-collect s (review-handoff-test--body "1234567" "{bad") "1234567")
        (review-walkthrough-agent-dwim)
        (should asked)
        (setq asked nil)
        (review-handoff-collect s (review-handoff-test--body "1234567") "7654321")
        (cl-letf (((symbol-function 'read-key) (lambda (&rest _) ?u)))
          (review-walkthrough-agent-dwim))
        (should-not asked)
        (should (plist-get (review-session-walkthrough s) :author))))))

(ert-deftest review-handoff-w-without-handoff-asks-agent ()
  (review-handoff-test--with s nil
    (let (asked)
      (cl-letf (((symbol-function 'review-walkthrough-request) (lambda () (setq asked t))))
        (review-walkthrough-agent-dwim)
        (should asked)))))

(ert-deftest review-handoff-git-range-local-file ()
  (let* ((repo (make-temp-file "handoff-repo" t))
         (default-directory (file-name-as-directory repo)))
    (unwind-protect
        (progn
          (call-process "git" nil nil nil "init" "-q")
          (let ((head "abcdef0123456789abcdef0123456789abcdef01"))
            (make-directory (expand-file-name ".git/review-handoffs" repo) t)
            (with-temp-file (expand-file-name (format ".git/review-handoffs/%s.json" head) repo)
              (insert review-handoff-test--route))
            (review-handoff-test--with s (list :kind 'git-range :directory repo :range "x"
                                               :revs (cons "0000000" head))
              (let ((h (review-handoff-get s)))
                (should h)
                (should-not (plist-get h :stale))
                (should (equal (review-handoff-start s) "ok 1 of 1 steps"))))
            (review-handoff-test--with s (list :kind 'git-range :directory repo :range "y"
                                               :revs (cons "0000000" "1111111111111111"))
              (should-not (review-handoff-get s))
              ;; The miss is remembered, not looked up again.
              (should (plist-get (plist-get (review-session-extensions s) :handoff) :none)))))
      (delete-directory repo t))))

(ert-deftest review-handoff-survives-store-round-trip ()
  (review-handoff-test--with s nil
    (review-handoff-collect s (review-handoff-test--body "1234567") "1234567")
    (let ((copy (copy-tree (review-session-extensions s))))
      (should (equal (car (read-from-string (prin1-to-string copy))) copy)))))
