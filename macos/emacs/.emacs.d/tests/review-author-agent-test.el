;;; review-author-agent-test.el --- Asking the agent that wrote the PR -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'review-conversation)
(require 'review-author-agent)

(defvar agent-shell--state nil)
(defvar agent-shell-preferred-agent-config nil)

(defconst review-author-test--spec '(("a.el" "1\n2\n3\n4\n5\n" "1\n2\nTHREE\n4\n5\n")))

(defun review-author-test--source ()
  (make-review-source
   :name "fake" :title "PR #9" :range-label "x -> y" :recipe '(:kind fake :id "author")
   :files (lambda () (list (list :path "a.el" :old-path "a.el" :kind 'modified)))
   :text (lambda (_file side cb)
           (let ((s (car review-author-test--spec))) (funcall cb (if (eq side 'old) (nth 1 s) (nth 2 s)))))
   :origin (lambda (file start _end) (list :label (format "%s:%d" (plist-get file :path) start)))))

(defun review-author-test--body (&optional session-json head)
  (format "Summary.\n<details><summary>Review handoff</summary>\n\n## Intent\nMake it THREE.\n\n<!-- review-handoff v1 head=%s\n{\"steps\":[{\"path\":\"a.el\",\"side\":\"new\",\"line_start\":3,\"line_end\":3,\"title\":\"T\",\"body\":\"B\"}]%s}\n-->\n</details>\n"
          (or head "1234567") (if session-json (concat ",\"session\":" session-json) "")))

(defvar review-author-test--repo nil)

(defmacro review-author-test--with (var &rest body)
  (declare (indent 1))
  `(let* ((review-store-directory (file-name-as-directory (make-temp-file "review-author" t)))
          (review-store--memory (make-hash-table :test #'equal))
          (review-author-agent--agents (make-hash-table :test #'equal))
          (review-author-agent-digest-directory (make-temp-file "review-digest" t))
          (review-author-agent-state-directory (file-name-as-directory (make-temp-file "review-state" t)))
          (review-author-test--repo (make-temp-file "review-author-repo" t))
          (killed nil))
     (let ((default-directory (file-name-as-directory review-author-test--repo)))
       (call-process "git" nil nil nil "init" "-q"))
     (review-author-agent-mode 1)
     (save-window-excursion
       (let ((,var (review-session-start (review-author-test--source))))
         (setf (review-session-directory ,var) review-author-test--repo)
         (review-session-load ,var 0 #'ignore)
         (unwind-protect (progn ,@body)
           (when review-session--current (review-session-quit))
           (ignore killed)
           (review-author-agent-mode -1)
           (delete-directory review-store-directory t)
           (delete-directory review-author-test--repo t))))))

(defun review-author-test--agent-buffer (sid)
  (let ((b (generate-new-buffer " *fake-agent*")))
    (with-current-buffer b
      (setq-local agent-shell--state (list (cons :session (list (cons :id sid))))))
    b))

(defun review-author-test--side (sid &optional machine transcript)
  (progn
    (make-directory review-author-agent-state-directory t)
    (with-temp-file (review-author-agent--side-file sid)
      (prin1 (list :agent 'claude-code :session-id sid :cwd review-author-test--repo
                   :machine (or machine (review-conversation--machine)) :transcript transcript)
             (current-buffer)))))

(defconst review-author-test--session "{\"agent\":\"claude-code\",\"session_id\":\"sid-1\",\"machine\":\"h\"}")

;;; Recording

(ert-deftest review-author-agent-ancestors-reach-this-process ()
  (should (equal (car (review-author-agent--ancestors (emacs-pid))) (emacs-pid)))
  (should (> (length (review-author-agent--ancestors (emacs-pid))) 1)))

(ert-deftest review-author-agent-record-finds-owner-and-hides-paths ()
  (let* ((repo (make-temp-file "record-repo" t))
         (review-author-agent-state-directory (file-name-as-directory (make-temp-file "record-state" t)))
         (buffer (review-author-test--agent-buffer "sid-rec"))
         (parent (alist-get 'ppid (process-attributes (emacs-pid)))))
    (unwind-protect
        (let ((default-directory (file-name-as-directory repo)))
          (call-process "git" nil nil nil "init" "-q")
          (cl-letf (((symbol-function 'review-author-agent--agent-buffers) (lambda () (list buffer)))
                    ((symbol-function 'review-author-agent--client-pid) (lambda (_b) parent))
                    ((symbol-function 'review-conversation--identity)
                     (lambda (_b) (list :agent 'claude-code :session-id "sid-rec" :cwd repo
                                        :machine "mrx" :transcript "/t.md"))))
            (let* ((json (review-author-agent-record (emacs-pid)))
                   (data (json-parse-string json :object-type 'plist)))
              (should (equal (plist-get data :session_id) "sid-rec"))
              (should (equal (plist-get data :agent) "claude-code"))
              (should-not (string-match-p "mrx\\|record-repo\\|/t\\.md" json))
              (let ((side (review-author-agent--read-side "sid-rec")))
                (should (equal (plist-get side :transcript) "/t.md"))
                (should (equal (plist-get side :cwd) repo))))
            (should-error (review-author-agent-record 1))))
      (kill-buffer buffer)
      (delete-directory repo t))))

;;; Rungs

(ert-deftest review-author-agent-no-handoff-means-nothing ()
  (review-author-test--with s
    (should-not (review-author-agent-prepare s))
    (should-not (review-author-agent-shell s))
    (should-not (review-author-agent-label s))))

(ert-deftest review-author-agent-live-author ()
  (review-author-test--with s
    (let ((live (review-author-test--agent-buffer "sid-1")))
      (unwind-protect
          (progn
            (review-handoff-collect s (review-author-test--body review-author-test--session) "1234567")
            (should (eq (review-author-agent-shell s) live))
            (should (equal (review-author-agent-label s) "author"))
            (should (equal (review-author-agent-label s live) "author"))
            (should-not (review-author-agent--owned s)))
        (kill-buffer live)))))

(ert-deftest review-author-agent-no-session-falls-to-replacement ()
  (review-author-test--with s
    (review-handoff-collect s (review-author-test--body) "1234567")
    (should (eq (plist-get (review-author-agent--entry s) :rung) 'replacement))
    (should (string-match-p "no author session" (plist-get (review-author-agent--entry s) :reason)))))

(ert-deftest review-author-agent-not-on-this-machine ()
  (review-author-test--with s
    (review-handoff-collect s (review-author-test--body review-author-test--session) "1234567")
    (should (string-match-p "not on this machine" (plist-get (review-author-agent--entry s) :reason)))
    (clrhash review-author-agent--agents)
    (review-author-test--side "sid-1" "other-box")
    (review-author-agent-prepare s)
    (should (string-match-p "another machine" (plist-get (review-author-agent--entry s) :reason)))))

(ert-deftest review-author-agent-resumes-and-owns ()
  (review-author-test--with s
    (review-author-test--side "sid-1")
    (let ((resumed (generate-new-buffer " *resumed*")) asked)
      (unwind-protect
          (cl-letf (((symbol-function 'syzygy-recall-resume-entry)
                     (lambda (identity on-finish)
                       (setq asked identity)
                       (funcall on-finish `((ok . t) (bufferName . ,(buffer-name resumed)) (existing . :false)))
                       '((operation . tok)))))
            (review-handoff-collect s (review-author-test--body review-author-test--session) "1234567")
            (should (equal (plist-get asked :session-id) "sid-1"))
            (should (eq (plist-get (review-author-agent--entry s) :rung) 'author-resumed))
            (should (eq (review-author-agent-shell s) resumed))
            (should (equal (review-author-agent-label s) "author (resumed)"))
            (should (equal (review-author-agent--owned s) (list resumed))))
        (when (buffer-live-p resumed) (kill-buffer resumed))))))

(ert-deftest review-author-agent-resume-of-existing-is-not-owned ()
  (review-author-test--with s
    (review-author-test--side "sid-1")
    (let ((b (generate-new-buffer " *existing*")))
      (unwind-protect
          (cl-letf (((symbol-function 'syzygy-recall-resume-entry)
                     (lambda (_i on-finish)
                       (funcall on-finish `((ok . t) (bufferName . ,(buffer-name b)) (existing . t))) nil)))
            (review-handoff-collect s (review-author-test--body review-author-test--session) "1234567")
            (should-not (review-author-agent--owned s)))
        (kill-buffer b)))))

(ert-deftest review-author-agent-pending-resume-then-failure ()
  (review-author-test--with s
    (let ((transcript (make-temp-file "transcript" nil ".md" "hello")) finish digested)
      (review-author-test--side "sid-1" nil transcript)
      (unwind-protect
          (cl-letf (((symbol-function 'syzygy-recall-resume-entry)
                     (lambda (_i on-finish) (setq finish on-finish) '((operation . tok))))
                    (review-author-agent-digest-function
                     (lambda (tr out done) (setq digested tr) (with-temp-file out (insert "DIGEST")) (funcall done nil))))
            (review-handoff-collect s (review-author-test--body review-author-test--session) "1234567")
            (should (eq (plist-get (review-author-agent--entry s) :rung) 'resuming))
            (should (equal (review-author-agent-label s) "replacement (author resuming)"))
            (should-not digested)
            (funcall finish '((ok . :false) (error . "gone")))
            (should (eq (plist-get (review-author-agent--entry s) :rung) 'replacement-transcript))
            (should (equal digested transcript))
            (should (equal (review-author-agent--digest-text s) "DIGEST")))
        (delete-file transcript)))))

(ert-deftest review-author-agent-resume-error-falls-through ()
  (review-author-test--with s
    (review-author-test--side "sid-1")
    (cl-letf (((symbol-function 'syzygy-recall-resume-entry) (lambda (&rest _) (error "no provider"))))
      (review-handoff-collect s (review-author-test--body review-author-test--session) "1234567")
      (should (eq (plist-get (review-author-agent--entry s) :rung) 'replacement))
      (should (string-match-p "no provider" (plist-get (review-author-agent--entry s) :reason))))))

(ert-deftest review-author-agent-replacement-is-shared-and-primed ()
  (review-author-test--with s
    (let ((transcript (make-temp-file "transcript" nil ".md" "hello")) (starts 0) shell)
      (review-author-test--side "sid-1" "other" transcript)
      (unwind-protect
          (cl-letf (((symbol-function 'agent-shell--start)
                     (lambda (&rest _) (cl-incf starts) (setq shell (generate-new-buffer " *repl*")))))
            (review-handoff-collect s (review-author-test--body review-author-test--session) "1234567")
            (should (eq (review-author-agent-shell s) shell))
            (should (eq (review-author-agent-shell s) shell))
            (should (= starts 1))
            (should (equal (review-author-agent-label s shell) "replacement + transcript"))
            (let* ((args (review-author-agent--prompt-args (list :prompt "why?" :shell-buffer shell)))
                   (prompt (plist-get args :prompt)))
              (should (string-match-p "replacement agent" prompt))
              (should (string-match-p "Make it THREE" prompt))
              (should (string-suffix-p "why?" prompt))
              (should (equal (plist-get (review-author-agent--prompt-args (list :prompt "again" :shell-buffer shell)) :prompt)
                             "again"))))
        (delete-file transcript)
        (when (buffer-live-p shell) (kill-buffer shell))))))

(ert-deftest review-author-agent-replacement-prefix-names-transcript ()
  (review-author-test--with s
    (let ((transcript (make-temp-file "transcript" nil ".md" "hello")))
      (review-author-test--side "sid-1" nil transcript)
      (unwind-protect
          (cl-letf (((symbol-function 'syzygy-recall-resume-entry) (lambda (&rest _) (error "x")))
                    (review-author-agent-digest-function
                     (lambda (_tr out done) (with-temp-file out (insert "THE DIGEST")) (funcall done nil))))
            (review-handoff-collect s (review-author-test--body review-author-test--session) "1234567")
            (let ((text (review-author-agent--prefix-text s 'replacement)))
              (should (string-match-p "THE DIGEST" text))
              (should (string-match-p (regexp-quote transcript) text))
              (should (string-match-p "rg -n" text))))
        (delete-file transcript)))))

(ert-deftest review-author-agent-author-prefix-says-verify ()
  (review-author-test--with s
    (let ((live (review-author-test--agent-buffer "sid-1")))
      (unwind-protect
          (progn
            (review-handoff-collect s (review-author-test--body review-author-test--session) "1234567")
            (let ((prompt (plist-get (review-author-agent--prompt-args (list :prompt "q" :shell-buffer live)) :prompt)))
              (should (string-match-p "you authored: PR #9" prompt))
              (should (string-match-p "do not defend" prompt))))
        (kill-buffer live)))))

(ert-deftest review-author-agent-refresh-keeps-resumed-session ()
  (review-author-test--with s
    (review-author-test--side "sid-1")
    (let ((b (generate-new-buffer " *resumed*")) (calls 0))
      (unwind-protect
          (cl-letf (((symbol-function 'syzygy-recall-resume-entry)
                     (lambda (_i on-finish) (cl-incf calls)
                       (funcall on-finish `((ok . t) (bufferName . ,(buffer-name b)) (existing . :false))) nil)))
            (review-handoff-collect s (review-author-test--body review-author-test--session) "1234567")
            (review-handoff-collect s (review-author-test--body review-author-test--session) "1234567")
            (should (= calls 1))
            (should (review-author-agent--owned s))
            (review-handoff-collect s (review-author-test--body review-author-test--session "abcdef9") "abcdef9")
            (should (= calls 2)))
        (kill-buffer b)))))

;;; Quit

(ert-deftest review-author-agent-quit-kills-only-owned-on-yes ()
  (review-author-test--with s
    (review-author-test--side "sid-1")
    (let ((b (generate-new-buffer " *resumed*")))
      (cl-letf (((symbol-function 'syzygy-recall-resume-entry)
                 (lambda (_i on-finish)
                   (funcall on-finish `((ok . t) (bufferName . ,(buffer-name b)) (existing . :false))) nil)))
        (review-handoff-collect s (review-author-test--body review-author-test--session) "1234567"))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) nil)))
        (should (eq (review-author-agent--quit-query s) t))
        (should (buffer-live-p b)))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) t)))
        (should (eq (review-author-agent--quit-query s) t))
        (should-not (buffer-live-p b))))))

(ert-deftest review-author-agent-quit-never-asks-for-live-author ()
  (review-author-test--with s
    (let ((live (review-author-test--agent-buffer "sid-1")) asked)
      (unwind-protect
          (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) (setq asked t))))
            (review-handoff-collect s (review-author-test--body review-author-test--session) "1234567")
            (should (eq (review-author-agent--quit-query s) t))
            (should-not asked)
            (should (buffer-live-p live)))
        (kill-buffer live)))))

;;; Quick Ask

(defvar mr-x/quick-ask--shell-buffer nil)
(defvar mr-x/quick-ask--source-buffer nil)

(ert-deftest review-author-agent-quick-ask-routes-to-author ()
  (review-author-test--with s
    (let ((live (review-author-test--agent-buffer "sid-1"))
          (source (generate-new-buffer " *pane*"))
          (mr-x/quick-ask--shell-buffer nil))
      (unwind-protect
          (progn
            (with-current-buffer source (setq-local review-pane--session s))
            (review-handoff-collect s (review-author-test--body review-author-test--session) "1234567")
            (let ((mr-x/quick-ask--source-buffer source)
                  (orig (lambda (&rest _) 'project-agent)))
              (should (eq (review-author-agent--quick-ask-ensure orig "/") live))
              (should (eq mr-x/quick-ask--shell-buffer live))
              (should (equal (review-author-agent--quick-ask-label "a.el:3") "a.el:3 · author"))
              (let ((review-author-agent-quick-ask 'fresh))
                (should (eq (review-author-agent--quick-ask-ensure orig "/") 'project-agent))))
            (let ((mr-x/quick-ask--source-buffer nil))
              (should (eq (review-author-agent--quick-ask-ensure (lambda (&rest _) 'project-agent) "/") 'project-agent))))
        (kill-buffer live) (kill-buffer source)))))

(ert-deftest review-author-agent-quick-ask-reset-never-kills-author ()
  (review-author-test--with s
    (let ((live (review-author-test--agent-buffer "sid-1")) reset)
      (unwind-protect
          (progn
            (review-handoff-collect s (review-author-test--body review-author-test--session) "1234567")
            (review-author-agent-shell s)
            (let ((mr-x/quick-ask--shell-buffer live))
              (review-author-agent--quick-ask-reset (lambda () (setq reset t)))
              (should-not reset)
              (should-not mr-x/quick-ask--shell-buffer)
              (should (buffer-live-p live)))
            (let ((mr-x/quick-ask--shell-buffer (get-buffer-create " *other*")))
              (review-author-agent--quick-ask-reset (lambda () (setq reset t)))
              (should reset)))
        (kill-buffer live)))))

;;; Digest runner

(ert-deftest review-author-agent-digest-opencode-runs-and-caches ()
  (let* ((dir (make-temp-file "digest" t))
         (fake (expand-file-name "fake-opencode" dir))
         (transcript (expand-file-name "t.md" dir))
         (out (expand-file-name "out.md" dir))
         result done)
    (unwind-protect
        (progn
          (with-temp-file fake (insert "#!/bin/sh\n[ \"$1\" = run ] || exit 3\ncat >/dev/null\nprintf '## Tried and abandoned\\n%s\\n' \"$(printf 'x%.0s' $(seq 1 250))\"\n"))
          (set-file-modes fake #o755)
          (with-temp-file transcript (insert "transcript"))
          (let ((review-author-agent-digest-program fake))
            (review-author-agent--digest-opencode transcript out (lambda (err) (setq result err done t))))
          (with-timeout (10 (error "digest did not finish")) (while (not done) (accept-process-output nil 0.1)))
          (should-not result)
          (should (string-match-p "Tried and abandoned" (with-temp-buffer (insert-file-contents out) (buffer-string))))
          (setq done nil)
          (let ((review-author-agent-digest-program "/bin/false"))
            (review-author-agent--digest-opencode transcript (expand-file-name "bad.md" dir)
                                                  (lambda (err) (setq result err done t))))
          (with-timeout (10 (error "digest did not finish")) (while (not done) (accept-process-output nil 0.1)))
          (should (stringp result))
          (should-not (file-exists-p (expand-file-name "bad.md" dir))))
      (delete-directory dir t))))

(ert-deftest review-author-agent-new-handoff-rechecks-fallback ()
  (review-author-test--with s
    (let ((live (review-author-test--agent-buffer "sid-1")) (starts 0) shell)
      (unwind-protect
          (cl-letf (((symbol-function 'agent-shell--start)
                     (lambda (&rest _) (cl-incf starts) (setq shell (generate-new-buffer " *repl*")))))
            (review-handoff-collect s (review-author-test--body) "1234567")
            (should (eq (plist-get (review-author-agent--entry s) :rung) 'replacement))
            (review-author-agent-shell s)
            ;; Same head, but the handoff now names the author's session.
            (review-handoff-collect s (review-author-test--body review-author-test--session) "1234567")
            (should (eq (plist-get (review-author-agent--entry s) :rung) 'author))
            (should (eq (review-author-agent-shell s) live))
            (should (eq (plist-get (review-author-agent--entry s) :replacement) shell))
            (should (= starts 1)))
        (kill-buffer live)
        (when (buffer-live-p shell) (kill-buffer shell))))))

(ert-deftest review-author-agent-replacement-starts-in-author-checkout ()
  (review-author-test--with s
    (let ((checkout (make-temp-file "checkout" t)) dir shell)
      (review-author-test--side "sid-1" "other")
      (with-temp-buffer
        (let ((side (review-author-agent--read-side "sid-1")))
          (with-temp-file (review-author-agent--side-file "sid-1")
            (prin1 (plist-put side :cwd checkout) (current-buffer)))))
      (unwind-protect
          (cl-letf (((symbol-function 'agent-shell--start)
                     (lambda (&rest _) (setq dir default-directory shell (generate-new-buffer " *repl*")))))
            (review-handoff-collect s (review-author-test--body review-author-test--session) "1234567")
            (review-author-agent-shell s)
            (should (equal (file-name-as-directory dir) (file-name-as-directory checkout))))
        (delete-directory checkout t)
        (when (buffer-live-p shell) (kill-buffer shell))))))

(ert-deftest review-author-agent-continue-on-author-route-opens-author ()
  (review-author-test--with s
    (let ((live (review-author-test--agent-buffer "sid-1")) shown)
      (unwind-protect
          (cl-letf (((symbol-function 'review-conversation--show)
                     (lambda (_s buffer &optional _focus role) (setq shown (list buffer role)))))
            (review-conversation-mode 1)
            (review-handoff-collect s (review-author-test--body review-author-test--session) "1234567")
            (review-handoff-start s)
            (review-conversation-continue)
            (should (equal shown (list live 'author)))
            (with-current-buffer live
              (setq-local review-conversation--key (review-conversation--key s))
              (should (string-match-p "Review agent: author" (review-conversation--header)))))
        (review-conversation-mode -1)
        (review-author-agent-mode 1)
        (kill-buffer live)))))

;;; Transcript marks

(defvar agent-shell--transcript-file nil)

(defun review-author-test--transcript-buffer (sid transcript)
  (let ((b (review-author-test--agent-buffer sid)))
    (with-current-buffer b
      (setq-local agent-shell--transcript-file transcript)
      (insert "## Agent\nanswer\n𐆖 "))
    b))

(ert-deftest review-author-agent-mark-writes-transcript-and-divider ()
  (let* ((transcript (make-temp-file "t" nil ".md" "# Agent Shell Transcript\n"))
         (b (review-author-test--transcript-buffer "sid-m" transcript)))
    (unwind-protect
        (progn
          (should (eq (review-author-agent-mark b 'opened "mr-x/fx#1" "4f942ff81938") 'written))
          (let ((text (with-temp-buffer (insert-file-contents transcript) (buffer-string))))
            (should (string-match-p "\\*\\*▸ PR opened mr-x/fx#1\\*\\* · 4f942ff" text))
            (should (string-match-p "<!-- review-mark v1 pr=mr-x/fx#1 event=opened head=4f942ff81938 " text)))
          (with-current-buffer b
            (let ((ov (car (seq-filter (lambda (o) (overlay-get o 'review-author-agent-mark))
                                       (overlays-in (point-min) (point-max))))))
              (should ov)
              (should (string-match-p "▸ PR opened mr-x/fx#1" (overlay-get ov 'before-string)))
              ;; The divider sits above the prompt line, not inside the answer.
              (should (= (overlay-start ov) (save-excursion (goto-char (point-max)) (line-beginning-position)))))))
      (kill-buffer b) (delete-file transcript))))

(ert-deftest review-author-agent-mark-waits-for-turn-end ()
  (let* ((transcript (make-temp-file "t" nil ".md" "x\n"))
         (b (review-author-test--transcript-buffer "sid-q" transcript))
         handler unsubscribed)
    (unwind-protect
        (cl-letf (((symbol-function 'agent-shell-subscribe-to)
                   (lambda (&rest args) (setq handler (plist-get args :on-event)) 'tok))
                  ((symbol-function 'agent-shell-unsubscribe) (lambda (&rest _) (setq unsubscribed t))))
          (with-current-buffer b
            (setq-local agent-shell--state
                        (append agent-shell--state
                                (list (cons :active-requests (list (list (cons :method "session/prompt"))))))))
          (should (eq (review-author-agent-mark b 'updated "mr-x/fx#1" "abc1234") 'queued))
          (should-not (string-match-p "review-mark" (with-temp-buffer (insert-file-contents transcript) (buffer-string))))
          (funcall handler '((:event . turn-complete)))
          (should unsubscribed)
          (should (string-match-p "event=updated" (with-temp-buffer (insert-file-contents transcript) (buffer-string)))))
      (kill-buffer b) (delete-file transcript))))

(ert-deftest review-author-agent-record-marks-opened-then-updated ()
  (let* ((dir (make-temp-file "tdir" t))
         (transcript (expand-file-name "2026-11-11.md" dir))
         (review-author-agent-state-directory (file-name-as-directory (make-temp-file "state" t)))
         (b (progn (with-temp-file transcript (insert "# T\n"))
                   (review-author-test--transcript-buffer "sid-r" transcript)))
         (parent (alist-get 'ppid (process-attributes (emacs-pid)))))
    (unwind-protect
        (cl-letf (((symbol-function 'review-author-agent--agent-buffers) (lambda () (list b)))
                  ((symbol-function 'review-author-agent--client-pid) (lambda (_b) parent))
                  ((symbol-function 'review-conversation--identity)
                   (lambda (_b) (list :agent 'claude-code :session-id "sid-r" :cwd dir :machine "m" :transcript transcript))))
          (review-author-agent-record (emacs-pid) "mr-x/fx#2" "1111111aaaa")
          (review-author-agent-record (emacs-pid) "mr-x/fx#2" "2222222bbbb")
          (review-author-agent-record (emacs-pid))
          (let ((text (with-temp-buffer (insert-file-contents transcript) (buffer-string))))
            (with-temp-buffer (insert text) (goto-char (point-min))
                              (should (= 1 (how-many "event=opened"))))
            (should (string-match-p "pr=mr-x/fx#2 event=opened head=1111111aaaa" text))
            (should (string-match-p "pr=mr-x/fx#2 event=updated head=2222222bbbb" text))
            (with-temp-buffer (insert text) (goto-char (point-min))
                              (should (= 2 (how-many "review-mark v1"))))))
      (kill-buffer b) (delete-directory dir t))))

(ert-deftest review-author-agent-mark-start-from-pid ()
  (let* ((transcript (make-temp-file "t" nil ".md" "x\n"))
         (b (review-author-test--transcript-buffer "sid-s" transcript))
         (parent (alist-get 'ppid (process-attributes (emacs-pid)))))
    (unwind-protect
        (cl-letf (((symbol-function 'review-author-agent--agent-buffers) (lambda () (list b)))
                  ((symbol-function 'review-author-agent--client-pid) (lambda (_b) parent)))
          (should (equal (review-author-agent-mark-start (emacs-pid) "author marks") "written"))
          (should (string-match-p "\\*\\*▸ work started\\*\\* \"author marks\".*\n<!-- review-mark v1 pr=- event=started"
                                  (with-temp-buffer (insert-file-contents transcript) (buffer-string)))))
      (kill-buffer b) (delete-file transcript))))

(ert-deftest review-author-agent-span-and-tagged-transcripts ()
  (let* ((dir (make-temp-file "tdir" t))
         (a (expand-file-name "a.md" dir)) (b (expand-file-name "b.md" dir)) (c (expand-file-name "c.md" dir))
         (mark (lambda (pr ev) (review-author-agent--mark-text pr ev "abc1234" nil))))
    (unwind-protect
        (progn
          (with-temp-file a
            (insert "chat\nchat\n" (funcall mark nil 'started) "old work\n" (funcall mark nil 'started)
                    "work\nwork\n" (funcall mark "o/r#1" 'opened) "q&a\n" (funcall mark "o/r#1" 'updated) "more\n"))
          (with-temp-file b (insert "resumed\n" (funcall mark "o/r#1" 'merged)))
          (with-temp-file c (insert "unrelated\n" (funcall mark "o/r#2" 'opened)))
          (let ((span (review-author-agent--span a "o/r#1")))
            (should span)
            (with-temp-buffer
              (insert-file-contents a)
              (goto-char (point-min)) (forward-line (1- (car span)))
              (should (looking-at ".*event=started"))
              (should (save-excursion (re-search-forward "^work$" nil t)))
              (should-not (save-excursion (re-search-forward "^old work$" nil t)))
              (goto-char (point-min)) (forward-line (1- (cdr span)))
              (should (looking-at ".*event=updated"))))
          (should-not (review-author-agent--span a "o/r#9"))
          (should (equal (sort (review-author-agent--transcripts-for a "o/r#1") #'string<) (list a b))))
      (delete-directory dir t))))

(ert-deftest review-author-agent-pr-state-marks-once-without-buffer ()
  (review-author-test--with s
    (let ((transcript (make-temp-file "t" nil ".md" "x\n")))
      (review-author-test--side "sid-1" "other" transcript)
      (unwind-protect
          (cl-letf (((symbol-function 'review-author-agent--pr-id) (lambda (_s) "o/r#3")))
            (review-handoff-collect s (review-author-test--body review-author-test--session) "1234567")
            (review-author-agent-pr-state s 'open)
            (review-author-agent-pr-state s 'merged)
            (review-author-agent-pr-state s 'merged)
            (with-temp-buffer
              (insert-file-contents transcript)
              (should (= 1 (how-many "pr=o/r#3 event=merged")))
              (should (= 0 (how-many "event=open ")))))
        (delete-file transcript)))))

(ert-deftest review-author-agent-digest-gets-span ()
  (review-author-test--with s
    (let* ((dir (make-temp-file "tdir" t))
           (transcript (expand-file-name "t.md" dir)) seen)
      (with-temp-file transcript
        (insert "a\n" (review-author-agent--mark-text nil 'started nil nil) "w\n"
                (review-author-agent--mark-text "o/r#4" 'opened "abc" nil) "q\n"))
      (review-author-test--side "sid-1" "other" transcript)
      (unwind-protect
          (cl-letf (((symbol-function 'review-author-agent--pr-id) (lambda (_s) "o/r#4"))
                    (review-author-agent-digest-function
                     (lambda (_tr _out done) (setq seen review-author-agent--digest-span) (funcall done "stop"))))
            (review-handoff-collect s (review-author-test--body review-author-test--session) "1234567")
            (should (consp seen))
            (should (< (car seen) (cdr seen)))
            (should (string-match-p "lines [0-9]+ to [0-9]+" (review-author-agent--prefix-text s 'replacement))))
        (delete-directory dir t)))))

(ert-deftest review-author-agent-start-mid-turn-goes-above-the-turn ()
  (let* ((transcript (make-temp-file "t" nil ".md"
                                     "## User (1)\nold\n\n## Agent (1)\nold reply\n\n## User (2)\nbuild the feature\n\n## Agent (2)\nworking"))
         (b (review-author-test--agent-buffer "sid-st")))
    (unwind-protect
        (cl-letf (((symbol-function 'review-author-agent--turn-active-p) (lambda (_b) t))
                  ((symbol-function 'review-author-agent--turn-start)
                   (lambda (buf) (with-current-buffer buf (save-excursion (goto-char (point-min)) (forward-line 1) (point))))))
          (with-current-buffer b
            (setq-local agent-shell--transcript-file transcript)
            (insert "> old\n> build the feature\nworking\n"))
          (should (eq (review-author-agent-mark b 'started nil nil "\"feat\"") 'written))
          (with-temp-buffer
            (insert-file-contents transcript)
            (goto-char (point-min))
            (let ((mark (progn (search-forward "event=started") (point)))
                  (turn (progn (goto-char (point-min)) (search-forward "## User (2)") (point)))
                  (first (progn (goto-char (point-min)) (search-forward "## User (1)") (point))))
              (should (< first mark turn))))
          (should (string-suffix-p "working" (with-temp-buffer (insert-file-contents transcript) (buffer-string))))
          (with-current-buffer b
            (let ((ov (car (seq-filter (lambda (o) (overlay-get o 'review-author-agent-mark))
                                       (overlays-in (point-min) (point-max))))))
              (should (= (overlay-start ov) (save-excursion (goto-char (point-min)) (forward-line 1) (point)))))))
      (kill-buffer b) (delete-file transcript))))
