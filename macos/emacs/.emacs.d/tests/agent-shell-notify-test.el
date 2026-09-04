;;; agent-shell-notify-test.el --- Tests for agent-shell-notify -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)

(add-to-list
 'load-path
 (expand-file-name "../lisp" (file-name-directory (or load-file-name
                                                      buffer-file-name))))
(require 'agent-shell-notify)

(defmacro agent-shell-notify-test--with-cache (&rest body)
  "Run BODY with an isolated empty notification cache."
  (declare (indent 0) (debug t))
  `(let ((agent-shell-notify-cache-directory
          (make-temp-file "agent-shell-notify-test-" t))
         (agent-shell-notify--downloads (make-hash-table :test #'equal)))
     (unwind-protect
         (progn ,@body)
       (delete-directory agent-shell-notify-cache-directory t))))

(defun agent-shell-notify-test--write-png (file)
  "Write a minimal PNG-signature-valid fixture to FILE."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert (unibyte-string #x89 #x50 #x4e #x47 #x0d #x0a #x1a #x0a #x00))
    (let ((coding-system-for-write 'no-conversion))
      (write-region (point-min) (point-max) file nil 'silent))))

(defun agent-shell-notify-test--executable (name)
  "Return a deterministic fake executable path for NAME."
  (pcase name
    ("terminal-notifier" "/opt/homebrew/bin/terminal-notifier")
    ("curl" "/usr/bin/curl")
    ("osascript" "/usr/bin/osascript")))

(ert-deftest agent-shell-notify-digest-is-stable-and-distinct ()
  "Session identity must produce a stable opaque SHA-256 seed."
  (should (equal (agent-shell-notify--digest "session-a")
                 "fa57a52dbf08190218529730a3e99db6946c6c29220fb6e0551e21598b0b05db"))
  (should-not (equal (agent-shell-notify--digest "session-a")
                     (agent-shell-notify--digest "session-b"))))

(ert-deftest agent-shell-notify-missing-session-delivers-plain-immediately ()
  "A notification without an ACP session ID must not start a download."
  (agent-shell-notify-test--with-cache
    (let (process-calls)
      (cl-letf (((symbol-function 'executable-find)
                 #'agent-shell-notify-test--executable)
                ((symbol-function 'make-process)
                 (lambda (&rest args)
                   (push args process-calls)
                   'fake-process))
                ((symbol-function 'major-pane--tab-label)
                 (lambda (_) "Pane Label")))
        (with-temp-buffer
          (setq-local agent-shell--state
                      (list (cons :session (list (cons :id nil)))))
          (mr-x/agent-shell-notify (current-buffer) "Fallback" "Finished")))
      (should (= (length process-calls) 1))
      (should (equal (plist-get (car process-calls) :command)
                     '("/usr/bin/osascript" "-e"
                       "display notification \"Finished\" with title \"Pane Label\""))))))

(ert-deftest agent-shell-notify-valid-cache-delivers-image-without-curl ()
  "A valid cache hit must immediately use terminal-notifier."
  (agent-shell-notify-test--with-cache
    (let* ((digest (agent-shell-notify--digest "session-a"))
           (cache-file (agent-shell-notify--cache-file digest))
           process-calls)
      (agent-shell-notify-test--write-png cache-file)
      (cl-letf (((symbol-function 'executable-find)
                 #'agent-shell-notify-test--executable)
                ((symbol-function 'make-process)
                 (lambda (&rest args)
                   (push args process-calls)
                   'fake-process)))
        (with-temp-buffer
          (setq-local agent-shell--state
                      (list (cons :session (list (cons :id "session-a")))))
          (mr-x/agent-shell-notify (current-buffer) "Project" "Finished")))
      (should (= (length process-calls) 1))
      (should
       (equal
        (plist-get (car process-calls) :command)
        (list "/opt/homebrew/bin/terminal-notifier"
              "-title" "Project"
              "-message" "Finished"
              "-contentImage" cache-file))))))

(ert-deftest agent-shell-notify-image-delivery-failure-falls-back-to-plain ()
  "A failed terminal-notifier process must deliver the event with AppleScript."
  (let (process-calls)
    (cl-letf (((symbol-function 'executable-find)
               #'agent-shell-notify-test--executable)
              ((symbol-function 'make-process)
               (lambda (&rest args)
                 (push args process-calls)
                 'fake-process)))
      (agent-shell-notify--deliver-image "Project" "Finished" "/tmp/shadow.png")
      (let ((sentinel (plist-get (car process-calls) :sentinel)))
        (cl-letf (((symbol-function 'process-status) (lambda (_) 'exit))
                  ((symbol-function 'process-exit-status) (lambda (_) 3)))
          (funcall sentinel 'fake-process "failed\n"))))
    (should (= (length process-calls) 2))
    (should (equal (plist-get (car process-calls) :command)
                   '("/usr/bin/osascript" "-e"
                     "display notification \"Finished\" with title \"Project\"")))))

(ert-deftest agent-shell-notify-first-fetch-caches-then-delivers-image ()
  "A successful first fetch must atomically cache and deliver the image."
  (agent-shell-notify-test--with-cache
    (let (process-calls)
      (cl-letf (((symbol-function 'executable-find)
                 #'agent-shell-notify-test--executable)
                ((symbol-function 'make-process)
                 (lambda (&rest args)
                   (push args process-calls)
                   'fake-process)))
        (with-temp-buffer
          (setq-local agent-shell--state
                      (list (cons :session (list (cons :id "session-a")))))
          (mr-x/agent-shell-notify (current-buffer) "Project" "Finished"))
        (let* ((curl-call (car process-calls))
               (curl-command (plist-get curl-call :command))
               (sentinel (plist-get curl-call :sentinel))
               (temp-file (cadr (member "--output" curl-command)))
               (cache-file
                (agent-shell-notify--cache-file
                 "fa57a52dbf08190218529730a3e99db6946c6c29220fb6e0551e21598b0b05db")))
          (should (equal (car curl-command) "/usr/bin/curl"))
          (should (member "--max-time" curl-command))
          (should (member "3" curl-command))
          (should-not
           (seq-some (lambda (argument)
                       (and (stringp argument)
                            (string-match-p "session-a" argument)))
                     curl-command))
          (agent-shell-notify-test--write-png temp-file)
          (cl-letf (((symbol-function 'process-status) (lambda (_) 'exit))
                    ((symbol-function 'process-exit-status) (lambda (_) 0)))
            (funcall sentinel 'fake-process "finished\n"))
          (should (agent-shell-notify--valid-png-p cache-file))
          (should-not (file-exists-p temp-file))
          (should (= (length process-calls) 2))
          (should (equal (car (plist-get (car process-calls) :command))
                         "/opt/homebrew/bin/terminal-notifier")))))))

(ert-deftest agent-shell-notify-invalid-cache-is-refetched ()
  "A non-PNG cache entry must never be passed to terminal-notifier."
  (agent-shell-notify-test--with-cache
    (let* ((digest (agent-shell-notify--digest "session-a"))
           (cache-file (agent-shell-notify--cache-file digest))
           process-calls)
      (with-temp-file cache-file (insert "not a png"))
      (cl-letf (((symbol-function 'executable-find)
                 #'agent-shell-notify-test--executable)
                ((symbol-function 'make-process)
                 (lambda (&rest args)
                   (push args process-calls)
                   'fake-process)))
        (with-temp-buffer
          (setq-local agent-shell--state
                      (list (cons :session (list (cons :id "session-a")))))
          (mr-x/agent-shell-notify (current-buffer) "Project" "Finished")))
      (should (= (length process-calls) 1))
      (should (equal (car (plist-get (car process-calls) :command))
                     "/usr/bin/curl")))))

(ert-deftest agent-shell-notify-concurrent-failure-shares-fetch-without-duplicates ()
  "Concurrent cache misses must share curl and fall back once per event."
  (agent-shell-notify-test--with-cache
    (let (process-calls)
      (cl-letf (((symbol-function 'executable-find)
                 #'agent-shell-notify-test--executable)
                ((symbol-function 'make-process)
                 (lambda (&rest args)
                   (push args process-calls)
                   'fake-process)))
        (with-temp-buffer
          (setq-local agent-shell--state
                      (list (cons :session (list (cons :id "session-a")))))
          (mr-x/agent-shell-notify (current-buffer) "Project" "First")
          (mr-x/agent-shell-notify (current-buffer) "Project" "Second"))
        (should (= (length process-calls) 1))
        (let ((sentinel (plist-get (car process-calls) :sentinel)))
          (cl-letf (((symbol-function 'process-status) (lambda (_) 'exit))
                    ((symbol-function 'process-exit-status) (lambda (_) 22)))
            (funcall sentinel 'fake-process "failed\n")))
        (let ((commands (mapcar (lambda (call) (plist-get call :command))
                                process-calls)))
          (should (= (length commands) 3))
          (should (= (cl-count "/usr/bin/curl" commands
                               :key #'car :test #'equal)
                     1))
          (should (= (cl-count "/usr/bin/osascript" commands
                               :key #'car :test #'equal)
                     2)))))))

(ert-deftest agent-shell-notify-missing-curl-falls-back-without-queueing ()
  "A missing curl executable must produce one immediate plain notification."
  (agent-shell-notify-test--with-cache
    (let (process-calls)
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (name)
                   (unless (equal name "curl")
                     (agent-shell-notify-test--executable name))))
                ((symbol-function 'make-process)
                 (lambda (&rest args)
                   (push args process-calls)
                   'fake-process)))
        (with-temp-buffer
          (setq-local agent-shell--state
                      (list (cons :session (list (cons :id "session-a")))))
          (mr-x/agent-shell-notify (current-buffer) "Project" "Finished")))
      (should (= (length process-calls) 1))
      (should (equal (car (plist-get (car process-calls) :command))
                     "/usr/bin/osascript"))
      (should (= (hash-table-count agent-shell-notify--downloads) 0)))))

(ert-deftest agent-shell-notify-missing-terminal-notifier-skips-fetch ()
  "A missing terminal-notifier must use AppleScript without starting curl."
  (agent-shell-notify-test--with-cache
    (let (process-calls)
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (name)
                   (unless (equal name "terminal-notifier")
                     (agent-shell-notify-test--executable name))))
                ((symbol-function 'make-process)
                 (lambda (&rest args)
                   (push args process-calls)
                   'fake-process)))
        (with-temp-buffer
          (setq-local agent-shell--state
                      (list (cons :session (list (cons :id "session-a")))))
          (mr-x/agent-shell-notify (current-buffer) "Project" "Finished")))
      (should (= (length process-calls) 1))
      (should (equal (car (plist-get (car process-calls) :command))
                     "/usr/bin/osascript")))))

(ert-deftest agent-shell-notify-curl-launch-error-drains-queue-once ()
  "A curl launch error must clean state and deliver one plain notification."
  (agent-shell-notify-test--with-cache
    (let (process-calls)
      (cl-letf (((symbol-function 'executable-find)
                 #'agent-shell-notify-test--executable)
                ((symbol-function 'make-process)
                 (lambda (&rest args)
                   (if (equal (car (plist-get args :command)) "/usr/bin/curl")
                       (error "curl launch failed")
                     (push args process-calls)
                     'fake-process))))
        (with-temp-buffer
          (setq-local agent-shell--state
                      (list (cons :session (list (cons :id "session-a")))))
          (mr-x/agent-shell-notify (current-buffer) "Project" "Finished")))
      (should (= (length process-calls) 1))
      (should (equal (car (plist-get (car process-calls) :command))
                     "/usr/bin/osascript"))
      (should (= (hash-table-count agent-shell-notify--downloads) 0)))))

;;; agent-shell-notify-test.el ends here
