# Agent Shell Shadow Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every ACP conversation a stable DiceBear Shadows image in its
macOS notifications without changing agent-shell UI or notification ownership.

**Architecture:** A standalone Emacs Lisp module derives a SHA-256 digest from
the buffer's ACP session ID, validates a machine-local PNG cache, and coordinates
one asynchronous curl download per digest. `agent-shell-attention` remains the
only notification trigger; the module delivers image notifications through
terminal-notifier and preserves the current AppleScript notification as the
plain fallback.

**Tech Stack:** Emacs 30.2 with lexical binding, ERT, `make-process`, macOS
AppleScript, curl, terminal-notifier, DiceBear HTTP API, Org Babel tangling, and
Homebrew Bundle.

**Spec:**
`macos/docs/superpowers/specs/2026-09-04-agent-shell-shadow-notifications-design.md`

## Global Constraints

- Work in `.worktrees/agent-shell-shadow-notifications` on branch
  `feat/agent-shell-shadow-notifications`; preserve the dirty main checkout.
- Treat `macos/emacs/.emacs.d/emacs.org` as the configuration source and
  regenerate `agent-shell-config.el` canonically with the Elpaca Org loaded by
  this worktree's `init.el`; never hand-edit generated Lisp.
- Never restart, kill, or reload the main Emacs daemon. Load the verified module
  and configuration with `emacsclient`.
- Keep `agent-shell-attention` as the only notification owner and keep both
  `agent-shell-macext-notifications` and
  `agent-shell-macext-notify-current-buffer` nil.
- Preserve the major-pane label title and agent-shell-attention's existing focus
  suppression; the notifier receives `(BUFFER TITLE BODY)` and does not add its
  own focus policy.
- Use the ACP session ID only as input to SHA-256. Only the 64-character digest
  may appear in the DiceBear URL, cache filename, or download registry.
- Request exactly
  `https://api.dicebear.com/10.x/shadows/png?seed=<sha256>&size=128` with a
  three-second curl timeout.
- Cache only PNG-signature-valid, non-empty files under
  `~/.emacs.d/var/agent-shell-shadows/`; download to the same directory and
  rename atomically after validation.
- Deduplicate concurrent downloads by digest while delivering every queued
  notification exactly once after success or failure.
- Use separate process arguments and `:noquery t` for curl,
  terminal-notifier, and osascript. Never block Emacs on network I/O.
- On a missing session ID, missing dependency, download failure, HTTP error,
  timeout, empty response, invalid response, or process-launch error, deliver
  one plain AppleScript notification for each original event.
- Invoke terminal-notifier with `-title`, `-message`, and `-contentImage`.
  Version 3.1 removed `-sender`; do not pass that ignored, warning-producing
  option. Do not add grouping, sounds, click actions, names, moods, animation,
  or character UI.
- If terminal-notifier exits nonzero or cannot launch, deliver the same event
  once through AppleScript. This preserves notifications when macOS permission
  for terminal-notifier is disabled.
- A machine-local cache guarantees long-term artwork stability only after that
  machine has fetched the image. A different Mac's first fetch after an upstream
  DiceBear art change may differ; this accepted caveat does not expand scope.
- Every production behavior must have a witnessed ERT red-green cycle. Tests
  capture external processes at the command boundary and assert module-visible
  state and files.

## File Structure

- Create `macos/emacs/.emacs.d/lisp/agent-shell-notify.el` for identity
  derivation, PNG validation, cache paths, async download coordination, and
  notification delivery.
- Create `macos/emacs/.emacs.d/tests/agent-shell-notify-test.el` for focused
  deterministic, cache, concurrency, success, and fallback behavior.
- Modify `macos/emacs/.emacs.d/emacs.org` to require the module, assign
  `mr-x/agent-shell-notify`, and disable macext's two notification settings.
- Regenerate `macos/emacs/.emacs.d/agent-shell-config.el` from `emacs.org`.
- Modify `macos/emacs/.emacs.d/tests/config-tests.el` only for module wiring and
  notification-ownership integration assertions.
- Modify `macos/Brewfile` to install terminal-notifier.

The module exposes one public callback:

```emacs-lisp
(mr-x/agent-shell-notify BUFFER FALLBACK-TITLE BODY)
```

The focused test suite may exercise these private seams because each owns a
separate behavior:

```emacs-lisp
(agent-shell-notify--session-id BUFFER)
(agent-shell-notify--digest SESSION-ID)
(agent-shell-notify--cache-file DIGEST)
(agent-shell-notify--valid-png-p FILE)
(agent-shell-notify--deliver-plain TITLE BODY)
(agent-shell-notify--deliver-image TITLE BODY FILE)
(agent-shell-notify--start-download DIGEST)
(agent-shell-notify--finish-download DIGEST TEMP-FILE CACHE-FILE PROCESS)
```

---

### Task 1: Implement deterministic identity, cache validation, and asynchronous delivery

**Files:**

- Create: `macos/emacs/.emacs.d/tests/agent-shell-notify-test.el`
- Create: `macos/emacs/.emacs.d/lisp/agent-shell-notify.el`

**Interfaces:**

- Consumes: buffer-local `agent-shell--state`, optional
  `major-pane--tab-label`, `secure-hash`, `map-nested-elt`, curl,
  terminal-notifier, and osascript.
- Produces: `mr-x/agent-shell-notify`, the private test seams listed above,
  and `agent-shell-notify--downloads`, a digest-keyed table of queued
  `(TITLE . BODY)` events.

- [ ] **Step 1: Write identity, missing-session, and cache-hit tests**

Create `agent-shell-notify-test.el` with lexical binding, require ERT and cl-lib,
put the sibling `lisp/` directory on `load-path`, and require the not-yet-created
module. Add helpers that create an isolated cache and write a minimal valid PNG:

```emacs-lisp
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
```

Add these tests. Each expected digest is hand-derived outside the production
function, and process assertions verify this module's argument-vector contract:

```emacs-lisp
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
```

- [ ] **Step 2: Run the focused suite and witness RED**

Run:

```bash
shadow_root=/Users/marcosandrade/.dotfiles/.worktrees/agent-shell-shadow-notifications
/opt/homebrew/opt/emacs-plus@30/bin/emacs --batch -Q \
  -L "$shadow_root/macos/emacs/.emacs.d/lisp" \
  -l "$shadow_root/macos/emacs/.emacs.d/tests/agent-shell-notify-test.el" \
  -f ert-run-tests-batch-and-exit
```

Expected: load fails because `agent-shell-notify.el` does not exist. This is the
correct RED failure: the production feature required by every test is missing.

- [ ] **Step 3: Add the minimum module for identity, cache hits, and plain delivery**

Create `agent-shell-notify.el` with the public callback and enough helpers to
make the first three tests pass. Use this structure and exact external command
arguments:

```emacs-lisp
;;; agent-shell-notify.el --- Shadow images for agent-shell notifications -*- lexical-binding: t; -*-

(require 'map)
(require 'subr-x)

(defgroup agent-shell-notify nil
  "macOS notifications for agent-shell conversations."
  :group 'agent-shell)

(defcustom agent-shell-notify-cache-directory
  (expand-file-name "var/agent-shell-shadows/" user-emacs-directory)
  "Directory containing cached DiceBear Shadows PNG files."
  :type 'directory
  :group 'agent-shell-notify)

(defcustom agent-shell-notify-download-timeout 3
  "Maximum seconds curl may spend downloading a Shadow PNG."
  :type 'number
  :group 'agent-shell-notify)

(defconst agent-shell-notify--png-signature
  (unibyte-string #x89 #x50 #x4e #x47 #x0d #x0a #x1a #x0a)
  "The eight-byte PNG file signature.")

(defvar agent-shell-notify--downloads (make-hash-table :test #'equal)
  "Pending notifications keyed by opaque session digest.")

(defun agent-shell-notify--session-id (buffer)
  "Return BUFFER's ACP session ID, or nil when it is unavailable."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (boundp 'agent-shell--state)
        (ignore-errors
          (map-nested-elt agent-shell--state '(:session :id)))))))

(defun agent-shell-notify--digest (session-id)
  "Return SESSION-ID's SHA-256 digest, or nil for an unusable ID."
  (when (and (stringp session-id)
             (not (string-empty-p session-id)))
    (secure-hash 'sha256 session-id)))

(defun agent-shell-notify--cache-file (digest)
  "Return the cache filename for DIGEST."
  (expand-file-name (concat digest ".png")
                    agent-shell-notify-cache-directory))

(defun agent-shell-notify--valid-png-p (file)
  "Return non-nil when FILE begins with a complete PNG signature."
  (condition-case nil
      (and (file-readable-p file)
           (> (file-attribute-size (file-attributes file)) 8)
           (with-temp-buffer
             (set-buffer-multibyte nil)
             (insert-file-contents-literally file nil 0 8)
             (string= (buffer-string) agent-shell-notify--png-signature)))
    (file-error nil)))

(defun agent-shell-notify--spawn (name command &optional sentinel)
  "Start COMMAND asynchronously as NAME without exit queries."
  (make-process :name name
                :buffer nil
                :command command
                :connection-type 'pipe
                :noquery t
                :sentinel sentinel))

(defun agent-shell-notify--deliver-plain (title body)
  "Deliver TITLE and BODY through the existing AppleScript path."
  (when-let ((osascript (executable-find "osascript")))
    (agent-shell-notify--spawn
     "agent-shell-notification"
     (list osascript "-e"
           (format "display notification %S with title %S" body title)))))

(defun agent-shell-notify--deliver-image (title body file)
  "Deliver TITLE and BODY with content image FILE, or fall back to plain."
  (if-let ((notifier (executable-find "terminal-notifier")))
      (condition-case nil
          (agent-shell-notify--spawn
           "agent-shell-notification"
           (list notifier
                 "-title" title
                 "-message" body
                 "-contentImage" file)
           (lambda (process _event)
             (when (memq (process-status process) '(exit signal))
               (unless (and (eq (process-status process) 'exit)
                            (zerop (process-exit-status process)))
                 (agent-shell-notify--deliver-plain title body)))))
        (error
         (agent-shell-notify--deliver-plain title body)))
    (agent-shell-notify--deliver-plain title body)))

(defun agent-shell-notify--title (buffer fallback-title)
  "Return BUFFER's major-pane title, or FALLBACK-TITLE."
  (if (and (buffer-live-p buffer)
           (fboundp 'major-pane--tab-label))
      (major-pane--tab-label buffer)
    fallback-title))

(defun mr-x/agent-shell-notify (buffer fallback-title body)
  "Notify for BUFFER using FALLBACK-TITLE and BODY."
  (let* ((title (agent-shell-notify--title buffer fallback-title))
         (digest (agent-shell-notify--digest
                  (agent-shell-notify--session-id buffer)))
         (cache-file (and digest
                          (agent-shell-notify--cache-file digest))))
    (cond
     ((not (executable-find "terminal-notifier"))
      (agent-shell-notify--deliver-plain title body))
     ((not digest)
      (agent-shell-notify--deliver-plain title body))
     ((agent-shell-notify--valid-png-p cache-file)
      (agent-shell-notify--deliver-image title body cache-file))
     (t
      (agent-shell-notify--queue-download digest title body)))))

(provide 'agent-shell-notify)
```

Define `agent-shell-notify--queue-download` temporarily so the first suite can
load, but leave its uncached branch minimal until the next RED tests:

```emacs-lisp
(defun agent-shell-notify--queue-download (_digest title body)
  "Fall back until asynchronous downloads are implemented."
  (agent-shell-notify--deliver-plain title body))
```

- [ ] **Step 4: Run the focused suite and witness GREEN for the first slice**

Run the command from Step 2.

Expected: 3 tests pass, 0 unexpected. Confirm the output contains no warnings.

- [ ] **Step 5: Add RED tests for download success, invalid caches, concurrency, and failure**

Append tests that capture the curl sentinel. Use `(cadr (member "--output"
command))` to obtain the real temporary filename selected by production code.
The success test writes the PNG fixture before invoking the sentinel; process
status and exit code are the only process functions stubbed:

```emacs-lisp
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

(ert-deftest agent-shell-notify-image-delivery-failure-falls-back-once ()
  "A rejected image delivery must preserve the event through AppleScript."
  (let (process-calls)
    (cl-letf (((symbol-function 'executable-find)
               #'agent-shell-notify-test--executable)
              ((symbol-function 'make-process)
               (lambda (&rest args)
                 (push args process-calls)
                 'fake-process)))
      (agent-shell-notify--deliver-image "Project" "Finished" "/tmp/image.png")
      (should (= (length process-calls) 1))
      (let ((sentinel (plist-get (car process-calls) :sentinel)))
        (cl-letf (((symbol-function 'process-status) (lambda (_) 'exit))
                  ((symbol-function 'process-exit-status) (lambda (_) 3)))
          (funcall sentinel 'fake-process "failed\n")))
      (should (= (length process-calls) 2))
      (should (= (cl-count "/opt/homebrew/bin/terminal-notifier" process-calls
                           :key (lambda (call)
                                  (car (plist-get call :command)))
                           :test #'equal)
                 1))
      (should (= (cl-count "/usr/bin/osascript" process-calls
                           :key (lambda (call)
                                  (car (plist-get call :command)))
                           :test #'equal)
                 1)))))
```

- [ ] **Step 6: Run the focused suite and witness the second RED**

Run the command from Step 2.

Expected: the first three tests remain green; the new first-fetch, invalid
cache, concurrency, and missing-curl tests fail because the temporary fallback
does not start or coordinate curl.

- [ ] **Step 7: Implement one-download coordination and atomic completion**

Replace the temporary queue function with the following behaviors. Queue the
event before starting curl so a synchronous `make-process` error drains the
same event. Use a temporary file in the cache directory so rename is atomic:

```emacs-lisp
(defun agent-shell-notify--drain (digest image-file)
  "Deliver and remove all queued notifications for DIGEST.
Use IMAGE-FILE when non-nil; otherwise deliver plain notifications."
  (let ((notifications (nreverse (gethash digest
                                          agent-shell-notify--downloads))))
    (remhash digest agent-shell-notify--downloads)
    (dolist (notification notifications)
      (if image-file
          (agent-shell-notify--deliver-image
           (car notification) (cdr notification) image-file)
        (agent-shell-notify--deliver-plain
         (car notification) (cdr notification))))))

(defun agent-shell-notify--finish-download
    (digest temp-file cache-file process)
  "Finish DIGEST's download from TEMP-FILE after PROCESS exits."
  (when (memq (process-status process) '(exit signal))
    (let ((image-file
           (when (and (eq (process-status process) 'exit)
                      (zerop (process-exit-status process))
                      (agent-shell-notify--valid-png-p temp-file))
             (condition-case nil
                 (progn
                   (rename-file temp-file cache-file t)
                   cache-file)
               (file-error nil)))))
      (unless image-file
        (when (file-exists-p temp-file)
          (delete-file temp-file)))
      (agent-shell-notify--drain digest image-file))))

(defun agent-shell-notify--start-download (digest)
  "Start the one asynchronous Shadow download for DIGEST."
  (if-let ((curl (executable-find "curl")))
      (let (temp-file)
        (condition-case nil
            (progn
              (make-directory agent-shell-notify-cache-directory t)
              (setq temp-file
                    (make-temp-file
                     (expand-file-name (concat "." digest "-")
                                       agent-shell-notify-cache-directory)
                     nil ".png"))
              (let ((cache-file (agent-shell-notify--cache-file digest)))
                (agent-shell-notify--spawn
                 "agent-shell-shadow-download"
                 (list curl
                       "--fail"
                       "--silent"
                       "--show-error"
                       "--location"
                       "--max-time"
                       (number-to-string agent-shell-notify-download-timeout)
                       "--output"
                       temp-file
                       (format
                        "https://api.dicebear.com/10.x/shadows/png?seed=%s&size=128"
                        digest))
                 (lambda (process _event)
                   (agent-shell-notify--finish-download
                    digest temp-file cache-file process)))))
          (error
           (when (and temp-file (file-exists-p temp-file))
             (delete-file temp-file))
           (agent-shell-notify--drain digest nil))))
    (agent-shell-notify--drain digest nil)))

(defun agent-shell-notify--queue-download (digest title body)
  "Queue TITLE and BODY while downloading DIGEST at most once."
  (let ((existing (gethash digest agent-shell-notify--downloads)))
    (puthash digest (cons (cons title body) existing)
             agent-shell-notify--downloads)
    (unless existing
      (agent-shell-notify--start-download digest))))
```

Keep all internal errors inside the module fallback path. Do not log the digest
or raw session ID.

- [ ] **Step 8: Run the focused suite and witness final GREEN**

Run the command from Step 2.

Expected: 10 tests pass, 0 unexpected, with pristine output.

- [ ] **Step 9: Byte-compile the module and commit Task 1**

Run:

```bash
shadow_root=/Users/marcosandrade/.dotfiles/.worktrees/agent-shell-shadow-notifications
/opt/homebrew/opt/emacs-plus@30/bin/emacs --batch -Q \
  -L "$shadow_root/macos/emacs/.emacs.d/lisp" \
  --eval "(progn
            (require 'bytecomp)
            (let ((byte-compile-error-on-warn t)
                  (byte-compile-dest-file-function
                   (lambda (_) (make-temp-file \"agent-shell-notify-\" nil \".elc\"))))
              (byte-compile-file
               \"$shadow_root/macos/emacs/.emacs.d/lisp/agent-shell-notify.el\")))"
```

Expected: exit 0 with no warnings. The compiled artifact goes to the system
temporary directory, so no stale `.elc` enters the worktree.

Commit only the focused module and test:

```bash
git add macos/emacs/.emacs.d/lisp/agent-shell-notify.el \
        macos/emacs/.emacs.d/tests/agent-shell-notify-test.el
git commit -m "feat(emacs): add Shadow notification delivery"
```

---

### Task 2: Wire notification ownership, install the dependency, and verify the generated config

**Files:**

- Modify: `macos/emacs/.emacs.d/tests/config-tests.el`
- Modify: `macos/emacs/.emacs.d/emacs.org`
- Regenerate: `macos/emacs/.emacs.d/agent-shell-config.el`
- Modify: `macos/Brewfile`

**Interfaces:**

- Consumes: Task 1's `mr-x/agent-shell-notify` callback and the existing
  `use-package agent-shell-attention` and `use-package agent-shell-macext`
  blocks.
- Produces: a loaded `agent-shell-notify` feature, attention callback ownership,
  disabled macext notification paths, and a bootstrap-managed
  terminal-notifier executable.

- [ ] **Step 1: Add failing integration assertions**

Near the existing agent-shell integration tests in `config-tests.el`, add:

```emacs-lisp
(ert-deftest config-test-agent-shell-notify-integration ()
  "Agent attention should own notifications through the Shadow module."
  (should (featurep 'agent-shell-notify))
  (should (eq agent-shell-attention-notify-function
              #'mr-x/agent-shell-notify)))

(ert-deftest config-test-agent-shell-macext-notifications-disabled ()
  "Macext must not duplicate notifications owned by agent-shell-attention."
  (require 'agent-shell-macext)
  (should (boundp 'agent-shell-macext-notifications))
  (should-not agent-shell-macext-notifications)
  (should-not agent-shell-macext-notify-current-buffer))
```

Do not duplicate the macext test if it already exists on the branch; extend it
with the second nil assertion instead.

- [ ] **Step 2: Run only the integration tests and witness RED**

Run against the worktree's current generated config:

```bash
shadow_emacs=/Users/marcosandrade/.dotfiles/.worktrees/agent-shell-shadow-notifications/macos/emacs/.emacs.d
/opt/homebrew/opt/emacs-plus@30/bin/emacs --batch \
  --eval "(setq user-emacs-directory \"$shadow_emacs/\")" \
  -l "$shadow_emacs/init.el" \
  -l "$shadow_emacs/tests/config-tests.el" \
  --eval "(ert-run-tests-batch-and-exit
            '(or config-test-agent-shell-notify-integration
                 config-test-agent-shell-macext-notifications-disabled))"
```

Expected: failure because the generated config neither loads the module nor
disables `agent-shell-macext-notifications`.

- [ ] **Step 3: Replace the inline notifier with the module and disable macext**

In `emacs.org`, keep the attention face and renderer. Replace the inline
`mr-x/agent-shell-notify` definition with:

```emacs-lisp
;; Stable per-session Shadows content images with AppleScript fallback.
(require 'agent-shell-notify)
(setq agent-shell-attention-notify-function #'mr-x/agent-shell-notify)
```

Keep `(agent-shell-attention-mode 1)` immediately after the assignment.

In the macext `:custom` block, set both notification settings to nil:

```emacs-lisp
(agent-shell-macext-notifications nil)
(agent-shell-macext-notify-current-buffer nil)
```

Do not change the attention package, its subscriptions, or its focus checks.

- [ ] **Step 4: Add terminal-notifier to Homebrew Bundle**

Add this formula beside the other Emacs/macOS helper tools in `macos/Brewfile`:

```ruby
brew "terminal-notifier"
```

- [ ] **Step 5: Canonically regenerate agent-shell-config.el in the worktree**

Run with this worktree's `user-emacs-directory` so the initialized Elpaca Org,
not built-in Org, performs the tangle:

```bash
shadow_emacs=/Users/marcosandrade/.dotfiles/.worktrees/agent-shell-shadow-notifications/macos/emacs/.emacs.d
/opt/homebrew/opt/emacs-plus@30/bin/emacs --batch \
  --eval "(setq user-emacs-directory \"$shadow_emacs/\")" \
  -l "$shadow_emacs/init.el" \
  --eval "(require 'org)" \
  --eval "(let ((org-confirm-babel-evaluate nil))
            (org-babel-tangle-file \"$shadow_emacs/emacs.org\"))"
```

Expected: Org reports tangled blocks; `agent-shell-config.el` contains the
module require and nil macext settings. `init.el` must remain byte-for-byte
unchanged because the edited source block tangles only to
`agent-shell-config.el`.

- [ ] **Step 6: Re-run integration and focused suites for GREEN**

Run the integration command from Step 2, then the Task 1 focused command.

Expected: both integration tests and all 12 focused tests pass with 0 unexpected.

- [ ] **Step 7: Run the full configuration suite**

Run:

```bash
shadow_emacs=/Users/marcosandrade/.dotfiles/.worktrees/agent-shell-shadow-notifications/macos/emacs/.emacs.d
/opt/homebrew/opt/emacs-plus@30/bin/emacs --batch \
  --eval "(setq user-emacs-directory \"$shadow_emacs/\")" \
  -l "$shadow_emacs/init.el" \
  -l "$shadow_emacs/tests/config-tests.el" \
  -f ert-run-tests-batch-and-exit
```

Expected: all config tests pass, including
`config-test-tangled-output-in-sync`; 0 unexpected results.

- [ ] **Step 8: Commit Task 2**

```bash
git add macos/Brewfile \
        macos/emacs/.emacs.d/emacs.org \
        macos/emacs/.emacs.d/agent-shell-config.el \
        macos/emacs/.emacs.d/tests/config-tests.el
git commit -m "feat(emacs): show session Shadows in notifications"
```

---

## Final Verification

After both reviewed tasks are complete:

1. Install the declared formula with `brew install terminal-notifier` if
   `command -v terminal-notifier` is still empty.
2. Load `agent-shell-notify.el` and evaluate the two notifier assignments in the
   main daemon with `emacsclient`; do not restart Emacs.
3. Query the daemon to prove attention owns the callback and both macext
   notification variables are nil.
4. Invoke `mr-x/agent-shell-notify` for a live agent-shell buffer whose session
   ID exists, wait at most three seconds, and confirm a valid cached PNG exists.
5. Run the focused and full ERT suites once more on the final branch tip before
   claiming completion.
