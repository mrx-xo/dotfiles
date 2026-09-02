# Embedded Music Assistant Frontend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Open and reliably reuse Music Assistant's official frontend in a
tracked Emacs xwidget session through M-x music-assistant and SPC s m.

**Architecture:** A small Emacs Lisp wrapper owns only xwidget capability
validation, browser-session creation, same-origin reuse, and buffer cleanup.
The server-hosted Music Assistant frontend remains an opaque upstream
component that owns authentication, player selection, search, queue state,
artwork, playback controls, and reconnection.

**Tech Stack:** Emacs 30.2, Emacs Lisp, built-in xwidget WebKit, Org Babel
tangling, General.el leader bindings, and ERT.

**Spec:** macos/docs/superpowers/specs/2026-08-27-music-assistant-emacs-design.md

## Global Constraints

- Target the current macOS graphical Emacs 30.2 daemon with xwidget WebKit.
- Default music-assistant-server-url to http://192.168.1.143:8095.
- Add no package dependency; websocket.el is not used by this feature.
- Do not call Music Assistant's WebSocket or HTTP APIs from Elisp.
- Do not retrieve, log, persist, or pass a Music Assistant token through
  Emacs Lisp.
- Do not scrape the DOM, inject JavaScript, or customize the hosted frontend.
- Do not implement Emacs-owned player selection or force MrX.local.
- Keep all source definitions in emacs.org; init.el is generated and must
  never be edited independently.
- Keep the wrapper in its own small Org source block near the existing
  xwidget UI configuration.
- Test only the Emacs-owned wrapper boundary; do not assert upstream
  Music Assistant UI behavior in ERT.
- Live-evaluate the verified Org source block into the running daemon before
  the live smoke test.
- Work only in .worktrees/music-assistant-emacs until integration is chosen.
- Do not run macos/scripts/tangle-emacs-org.sh from the feature worktree: it
  hard-codes the main checkout and would regenerate the wrong init.el.

## File Structure

- Modify macos/emacs/.emacs.d/emacs.org.
  Add one Music Assistant subsection and source block after the existing UI
  block, add its table-of-contents entry, and bind SPC s m in the existing
  surf leader subtree.
- Modify macos/emacs/.emacs.d/tests/config-tests.el.
  Add lifecycle tests beside the existing surf tests and a binding assertion
  beside the existing leader assertions.
- Regenerate macos/emacs/.emacs.d/init.el from emacs.org.
  This is generated output and receives no hand edits.
- No music-assistant.el, protocol client, dedicated test file, or package
  declaration is created.

At plan-writing time, local main is commit 62dc949 and its configuration
suite passes 129 of 129 tests. The feature branch is behind main and must be
rebased before implementation. If main advances before execution, record the
new clean baseline and require exactly ten additional passing tests from this
feature.

---

### Task 1: Implement the tracked xwidget session

**Files:**

- Modify: macos/emacs/.emacs.d/emacs.org:18-20, 2979
- Modify: macos/emacs/.emacs.d/tests/config-tests.el:529-541
- Regenerate: macos/emacs/.emacs.d/init.el

**Interfaces:**

- Consumes:
  - xwidget-webkit-browse-url URL &optional NEW-SESSION
  - xwidget-at POSITION
  - xwidget-webkit-uri SESSION
  - xwidget-webkit-goto-uri SESSION URL
  - switch-to-buffer BUFFER
- Produces:
  - music-assistant-server-url: customizable string
  - music-assistant--buffer: Buffer or nil
  - music-assistant--ensure-xwidget: () -> non-nil or user-error
  - music-assistant--origin: (String) -> (SCHEME HOST PORT) or nil
  - music-assistant--same-origin-p: (String String) -> Boolean
  - music-assistant--tracked-session: () -> xwidget session or nil
  - music-assistant--forget-buffer: () -> nil
  - music-assistant--create-session: () -> Buffer
  - music-assistant: interactive () -> Buffer

- [ ] **Step 1: Rebase the clean feature branch onto current main**

Run from the feature worktree:

~~~bash
git status --short --branch
git rebase main
git status --short --branch
git log -3 --oneline --decorate
~~~

Expected: the initial and final worktrees contain no uncommitted files; the
Music Assistant documentation commits are replayed on top of current main.
If a conflict appears, stop and resolve only files touched by those
documentation commits before continuing.

- [ ] **Step 2: Establish the post-rebase configuration-test baseline**

Run:

~~~bash
music_feature_config=/Users/marcosandrade/.dotfiles/.worktrees/music-assistant-emacs/macos/emacs/.emacs.d
music_emacs_bin=/opt/homebrew/opt/emacs-plus@30/bin/emacs

$music_emacs_bin --batch \
  -l $music_feature_config/init.el \
  -l $music_feature_config/tests/config-tests.el \
  --eval "(let ((user-emacs-directory \"$music_feature_config/\"))
            (ert-run-tests-batch-and-exit t))"
~~~

Expected on main commit 62dc949: 129 tests, 129 expected, 0 unexpected.
If main has advanced, save the actual passing count as BASELINE and require
zero unexpected results.

The init loads packages from the installed main Emacs directory. The dynamic
user-emacs-directory binding makes path-sensitive ERT assertions, especially
tangle freshness, inspect the feature worktree.

- [ ] **Step 3: Add the failing lifecycle tests**

Immediately after config-test-mr-x-surf-functions in config-tests.el, insert:

~~~emacs-lisp
(ert-deftest config-test-music-assistant-configuration ()
  "Music Assistant should expose its URL and interactive entry point."
  (should (equal music-assistant-server-url
                 "http://192.168.1.143:8095"))
  (should (commandp 'music-assistant)))

(ert-deftest config-test-music-assistant-same-origin ()
  "Origin checks should ignore paths, host case, and default ports."
  (should
   (music-assistant--same-origin-p
    "http://MUSIC.test/library/album/42"
    "http://music.test:80/"))
  (should
   (music-assistant--same-origin-p
    "https://music.test/queue#current"
    "https://music.test"))
  (should-not
   (music-assistant--same-origin-p
    "http://music.test:8095"
    "http://music.test:8096"))
  (should-not
   (music-assistant--same-origin-p
    "http://music.test"
    "https://music.test")))

(ert-deftest config-test-music-assistant-opens-new-session ()
  "First invocation should create and track a dedicated xwidget session."
  (let ((music-assistant--buffer nil)
        (music-assistant-server-url "http://music.test:8095")
        (starting-buffer (current-buffer))
        created
        browse-call)
    (unwind-protect
        (cl-letf (((symbol-function 'music-assistant--ensure-xwidget)
                   #'ignore)
                  ((symbol-function 'xwidget-webkit-browse-url)
                   (lambda (url new-session)
                     (setq browse-call (list url new-session)
                           created
                           (generate-new-buffer
                            " *music-assistant-create-test*"))
                     (switch-to-buffer created)
                     (setq major-mode 'xwidget-webkit-mode))))
          (should (eq (music-assistant) created))
          (should
           (equal browse-call
                  '("http://music.test:8095" t)))
          (should (eq music-assistant--buffer created))
          (with-current-buffer created
            (should
             (memq #'music-assistant--forget-buffer
                   kill-buffer-hook))))
      (when (buffer-live-p created)
        (kill-buffer created))
      (when (buffer-live-p starting-buffer)
        (switch-to-buffer starting-buffer)))))

(ert-deftest config-test-music-assistant-reuses-same-origin-session ()
  "Repeated invocation should preserve an in-app route and reuse its buffer."
  (let ((tracked
         (generate-new-buffer " *music-assistant-reuse-test*"))
        (music-assistant-server-url "http://music.test:8095")
        displayed
        navigated)
    (unwind-protect
        (let ((music-assistant--buffer tracked))
          (cl-letf
              (((symbol-function 'music-assistant--ensure-xwidget)
                #'ignore)
               ((symbol-function 'music-assistant--tracked-session)
                (lambda () 'music-session))
               ((symbol-function 'xwidget-webkit-uri)
                (lambda (_session)
                  "http://music.test:8095/#/album/42"))
               ((symbol-function 'xwidget-webkit-goto-uri)
                (lambda (&rest args)
                  (setq navigated args)))
               ((symbol-function 'xwidget-webkit-browse-url)
                (lambda (&rest _)
                  (ert-fail "unexpected new xwidget session")))
               ((symbol-function 'switch-to-buffer)
                (lambda (buffer &rest _)
                  (setq displayed buffer)
                  buffer)))
            (should (eq (music-assistant) tracked))
            (should (eq displayed tracked))
            (should-not navigated)))
      (when (buffer-live-p tracked)
        (kill-buffer tracked)))))

(ert-deftest config-test-music-assistant-restores-off-origin-session ()
  "A tracked webview navigated elsewhere should return to Music Assistant."
  (let ((tracked
         (generate-new-buffer " *music-assistant-restore-test*"))
        (music-assistant-server-url "http://music.test:8095")
        displayed
        navigated)
    (unwind-protect
        (let ((music-assistant--buffer tracked))
          (cl-letf
              (((symbol-function 'music-assistant--ensure-xwidget)
                #'ignore)
               ((symbol-function 'music-assistant--tracked-session)
                (lambda () 'music-session))
               ((symbol-function 'xwidget-webkit-uri)
                (lambda (_session)
                  "https://duckduckgo.com"))
               ((symbol-function 'xwidget-webkit-goto-uri)
                (lambda (session url)
                  (setq navigated (list session url))))
               ((symbol-function 'switch-to-buffer)
                (lambda (buffer &rest _)
                  (setq displayed buffer)
                  buffer)))
            (should (eq (music-assistant) tracked))
            (should
             (equal navigated
                    '(music-session
                      "http://music.test:8095")))
            (should (eq displayed tracked))))
      (when (buffer-live-p tracked)
        (kill-buffer tracked)))))

(ert-deftest config-test-music-assistant-rejects-dead-or-invalid-buffer ()
  "Dead buffers and xwidget buffers without a session should not be reused."
  (let ((invalid
         (generate-new-buffer " *music-assistant-invalid-test*"))
        (music-assistant--buffer nil))
    (unwind-protect
        (progn
          (setq music-assistant--buffer invalid)
          (with-current-buffer invalid
            (setq major-mode 'xwidget-webkit-mode))
          (cl-letf (((symbol-function 'xwidget-at)
                     (lambda (&rest _) nil)))
            (should-not
             (music-assistant--tracked-session)))
          (kill-buffer invalid)
          (should-not
           (music-assistant--tracked-session)))
      (when (buffer-live-p invalid)
        (kill-buffer invalid)))))

(ert-deftest config-test-music-assistant-old-kill-keeps-new-session ()
  "Killing an old tracked buffer must not clear a replacement session."
  (let ((old (generate-new-buffer " *music-assistant-old-test*"))
        (new (generate-new-buffer " *music-assistant-new-test*"))
        (music-assistant--buffer nil))
    (unwind-protect
        (progn
          (setq music-assistant--buffer old)
          (with-current-buffer old
            (add-hook 'kill-buffer-hook
                      #'music-assistant--forget-buffer nil t))
          (setq music-assistant--buffer new)
          (kill-buffer old)
          (should (eq music-assistant--buffer new)))
      (when (buffer-live-p old)
        (kill-buffer old))
      (when (buffer-live-p new)
        (kill-buffer new)))))

(ert-deftest config-test-music-assistant-create-failure-clears-state ()
  "A failed xwidget creation should leave no tracked buffer."
  (let ((stale
         (generate-new-buffer " *music-assistant-stale-test*"))
        (music-assistant--buffer nil))
    (unwind-protect
        (progn
          (setq music-assistant--buffer stale)
          (cl-letf
              (((symbol-function 'music-assistant--ensure-xwidget)
                #'ignore)
               ((symbol-function 'music-assistant--tracked-session)
                (lambda () nil))
               ((symbol-function 'xwidget-webkit-browse-url)
                (lambda (&rest _)
                  (error "xwidget creation failed"))))
            (let ((failure
                   (should-error
                    (music-assistant)
                    :type 'error)))
              (should
               (string-match-p
                "xwidget creation failed"
                (error-message-string failure))))
            (should-not music-assistant--buffer)))
      (when (buffer-live-p stale)
        (kill-buffer stale)))))

(ert-deftest config-test-music-assistant-requires-graphical-xwidget ()
  "Invocation without graphical xwidget support should explain recovery."
  (let ((music-assistant--buffer nil)
        (music-assistant-server-url "http://music.test:8095"))
    (cl-letf (((symbol-function 'display-graphic-p)
               (lambda (&optional _display) nil)))
      (let ((failure
             (should-error
              (music-assistant)
              :type 'user-error)))
        (should
         (string-match-p
          "graphical xwidget-enabled Emacs"
          (error-message-string failure)))
        (should
         (string-match-p
          (regexp-quote music-assistant-server-url)
          (error-message-string failure)))))))
~~~

- [ ] **Step 4: Run the focused tests and verify that they fail**

Run:

~~~bash
music_feature_config=/Users/marcosandrade/.dotfiles/.worktrees/music-assistant-emacs/macos/emacs/.emacs.d
music_emacs_bin=/opt/homebrew/opt/emacs-plus@30/bin/emacs

$music_emacs_bin --batch \
  -l $music_feature_config/init.el \
  -l $music_feature_config/tests/config-tests.el \
  --eval "(ert-run-tests-batch-and-exit
           \"^config-test-music-assistant-\")"
~~~

Expected: non-zero exit with all nine new tests unexpected. Representative
failures name the absent music-assistant-server-url, music-assistant command,
and music-assistant--same-origin-p helper. If a new test passes before
implementation, inspect it for a false positive.

- [ ] **Step 5: Add the minimal xwidget wrapper to emacs.org**

Add Music Assistant to the Setup table of contents immediately after UI:

~~~org
  - [[#music-assistant][Music Assistant]]
~~~

After the UI source block and before Gain Some Perspective, insert:

~~~org
** Music Assistant

#+begin_src emacs-lisp :results silent
  (defgroup music-assistant nil
    "Open Music Assistant inside Emacs."
    :group 'multimedia)

  (defcustom music-assistant-server-url
    "http://192.168.1.143:8095"
    "URL of the server-hosted Music Assistant frontend."
    :type 'string
    :group 'music-assistant)

  (defvar music-assistant--buffer nil
    "Tracked xwidget buffer displaying Music Assistant.")

  (defun music-assistant--ensure-xwidget ()
    "Load xwidget support or explain how to reach Music Assistant."
    (unless (and (display-graphic-p)
                 (featurep 'xwidget-internal)
                 (fboundp 'xwidget-webkit-browse-url))
      (user-error
       "Music Assistant requires graphical xwidget-enabled Emacs; open %s externally"
       music-assistant-server-url))
    (require 'xwidget))

  (defun music-assistant--origin (url)
    "Return URL's normalized (SCHEME HOST PORT), or nil."
    (when (stringp url)
      (condition-case nil
          (progn
            (require 'url-parse)
            (let* ((parsed (url-generic-parse-url url))
                   (scheme (url-type parsed))
                   (host (url-host parsed))
                   (port (url-port parsed)))
              (when (and (stringp scheme)
                         (not (equal scheme ""))
                         (stringp host)
                         (not (equal host ""))
                         (numberp port))
                (list (downcase scheme)
                      (downcase host)
                      port))))
        (error nil))))

  (defun music-assistant--same-origin-p (left right)
    "Return non-nil when LEFT and RIGHT have the same URL origin."
    (let ((left-origin (music-assistant--origin left))
          (right-origin (music-assistant--origin right)))
      (and left-origin
           (equal left-origin right-origin))))

  (defun music-assistant--tracked-session ()
    "Return the tracked Music Assistant xwidget session, or nil."
    (when (buffer-live-p music-assistant--buffer)
      (with-current-buffer music-assistant--buffer
        (when (derived-mode-p 'xwidget-webkit-mode)
          (xwidget-at (point-min))))))

  (defun music-assistant--forget-buffer ()
    "Forget the tracked session when its own buffer is killed."
    (when (eq (current-buffer) music-assistant--buffer)
      (setq music-assistant--buffer nil)))

  (defun music-assistant--create-session ()
    "Create, track, and return a fresh Music Assistant xwidget buffer."
    (setq music-assistant--buffer nil)
    (condition-case failure
        (progn
          (xwidget-webkit-browse-url
           music-assistant-server-url t)
          (unless (derived-mode-p 'xwidget-webkit-mode)
            (error
             "Music Assistant did not create an xwidget session"))
          (setq music-assistant--buffer (current-buffer))
          (add-hook 'kill-buffer-hook
                    #'music-assistant--forget-buffer nil t)
          music-assistant--buffer)
      (error
       (setq music-assistant--buffer nil)
       (signal (car failure) (cdr failure)))))

  (defun music-assistant ()
    "Open or return to Music Assistant's official frontend."
    (interactive)
    (music-assistant--ensure-xwidget)
    (let ((session (music-assistant--tracked-session)))
      (if (not session)
          (music-assistant--create-session)
        (let ((current-url (xwidget-webkit-uri session)))
          (when (and (stringp current-url)
                     (not
                      (music-assistant--same-origin-p
                       current-url
                       music-assistant-server-url)))
            (xwidget-webkit-goto-uri
             session music-assistant-server-url)))
        (switch-to-buffer music-assistant--buffer)
        music-assistant--buffer)))
#+end_src
~~~

Do not place this code in the preceding multi-hundred-line UI block. The
small named subsection is the unit later live-evaluated into the daemon.
The silent result mode prevents that live evaluation from inserting an Org
results drawer or dirtying emacs.org.

- [ ] **Step 6: Tangle the worktree copy without touching main**

Run:

~~~bash
music_org_file=/Users/marcosandrade/.dotfiles/.worktrees/music-assistant-emacs/macos/emacs/.emacs.d/emacs.org

emacsclient --eval \
  "(let* ((org-file \"$music_org_file\")
          (visited (find-buffer-visiting org-file)))
     (when (and visited (buffer-modified-p visited))
       (user-error \"Worktree emacs.org has unsaved Emacs edits\"))
     (let ((org-confirm-babel-evaluate nil))
       (org-babel-tangle-file org-file)))"
~~~

Expected: the returned file list includes the worktree's init.el. A fresh
tangle now reports 64 source blocks rather than the 63-block baseline.

Verify that only source, generated output, tests, and the already-created
planning documents differ:

~~~bash
git status --short
git diff --check
git diff -- macos/emacs/.emacs.d/emacs.org \
  macos/emacs/.emacs.d/init.el \
  macos/emacs/.emacs.d/tests/config-tests.el
~~~

- [ ] **Step 7: Run the focused tests and verify that they pass**

Run:

~~~bash
music_feature_config=/Users/marcosandrade/.dotfiles/.worktrees/music-assistant-emacs/macos/emacs/.emacs.d
music_emacs_bin=/opt/homebrew/opt/emacs-plus@30/bin/emacs

$music_emacs_bin --batch \
  -l $music_feature_config/init.el \
  -l $music_feature_config/tests/config-tests.el \
  --eval "(let ((user-emacs-directory \"$music_feature_config/\"))
            (ert-run-tests-batch-and-exit
             \"^config-test-music-assistant-\"))"
~~~

Expected: 9 tests, 9 expected, 0 unexpected.

- [ ] **Step 8: Commit the tested wrapper**

Run:

~~~bash
git add macos/emacs/.emacs.d/emacs.org \
  macos/emacs/.emacs.d/init.el \
  macos/emacs/.emacs.d/tests/config-tests.el
git diff --cached --check
git commit -m "feat(emacs): open Music Assistant in tracked xwidget"
~~~

Expected: one feature commit containing the Org source, its generated init.el
output, and nine passing lifecycle tests.

---

### Task 2: Add the leader-key entry point and run regression tests

**Files:**

- Modify: macos/emacs/.emacs.d/emacs.org:4232-4241
- Modify: macos/emacs/.emacs.d/tests/config-tests.el:1190-1210
- Regenerate: macos/emacs/.emacs.d/init.el

**Interfaces:**

- Consumes:
  - music-assistant: interactive () -> Buffer from Task 1
  - config-test--leader-key KEYS -> command or keymap
- Produces:
  - SPC s m -> music-assistant
  - Which-key label: Music Assistant

- [ ] **Step 1: Add the failing leader-binding test**

Beside the existing SPC leader assertions in config-tests.el, insert:

~~~emacs-lisp
(ert-deftest config-test-leader-music-assistant-key ()
  "SPC s m should open the embedded Music Assistant frontend."
  (should
   (eq (config-test--leader-key "s m")
       'music-assistant)))
~~~

- [ ] **Step 2: Run the binding test and verify that it fails**

Run:

~~~bash
music_feature_config=/Users/marcosandrade/.dotfiles/.worktrees/music-assistant-emacs/macos/emacs/.emacs.d
music_emacs_bin=/opt/homebrew/opt/emacs-plus@30/bin/emacs

$music_emacs_bin --batch \
  -l $music_feature_config/init.el \
  -l $music_feature_config/tests/config-tests.el \
  --eval "(ert-run-tests-batch-and-exit
           \"^config-test-leader-music-assistant-key$\")"
~~~

Expected: 1 unexpected result because SPC s m is not globally bound to
music-assistant. The unrelated ibuffer-local s m binding does not satisfy
this test.

- [ ] **Step 3: Bind SPC s m in the existing surf subtree**

In the existing mr-x/leader-def form for the s subtree, insert this entry
between s l and s o:

~~~emacs-lisp
        "s m" '(music-assistant :wk "Music Assistant")
~~~

Do not add a second s subtree and do not modify the ibuffer-local s m binding.

- [ ] **Step 4: Retangle the worktree and verify the binding test**

Run the worktree-safe tangle and the binding test:

~~~bash
music_feature_config=/Users/marcosandrade/.dotfiles/.worktrees/music-assistant-emacs/macos/emacs/.emacs.d
music_org_file=$music_feature_config/emacs.org
music_emacs_bin=/opt/homebrew/opt/emacs-plus@30/bin/emacs

emacsclient --eval \
  "(let* ((org-file \"$music_org_file\")
          (visited (find-buffer-visiting org-file)))
     (when (and visited (buffer-modified-p visited))
       (user-error \"Worktree emacs.org has unsaved Emacs edits\"))
     (let ((org-confirm-babel-evaluate nil))
       (org-babel-tangle-file org-file)))"

$music_emacs_bin --batch \
  -l $music_feature_config/init.el \
  -l $music_feature_config/tests/config-tests.el \
  --eval "(ert-run-tests-batch-and-exit
           \"^config-test-leader-music-assistant-key$\")"
~~~

Expected: 1 test, 1 expected, 0 unexpected.

- [ ] **Step 5: Run all Music Assistant tests together**

Run:

~~~bash
music_feature_config=/Users/marcosandrade/.dotfiles/.worktrees/music-assistant-emacs/macos/emacs/.emacs.d
music_emacs_bin=/opt/homebrew/opt/emacs-plus@30/bin/emacs

$music_emacs_bin --batch \
  -l $music_feature_config/init.el \
  -l $music_feature_config/tests/config-tests.el \
  --eval "(let ((user-emacs-directory \"$music_feature_config/\"))
            (ert-run-tests-batch-and-exit
             \"music-assistant\"))"
~~~

Expected: 10 tests, 10 expected, 0 unexpected.

- [ ] **Step 6: Run the complete configuration suite**

Run:

~~~bash
music_feature_config=/Users/marcosandrade/.dotfiles/.worktrees/music-assistant-emacs/macos/emacs/.emacs.d
music_emacs_bin=/opt/homebrew/opt/emacs-plus@30/bin/emacs

$music_emacs_bin --batch \
  -l $music_feature_config/init.el \
  -l $music_feature_config/tests/config-tests.el \
  --eval "(let ((user-emacs-directory \"$music_feature_config/\"))
            (ert-run-tests-batch-and-exit t))"
~~~

Expected if the baseline remains 129: 139 tests, 139 expected, 0 unexpected.
If main advanced before the Task 1 rebase, expect BASELINE + 10 tests and no
unexpected results. This run includes config-test-tangled-output-in-sync, so
it proves the generated init.el matches the worktree emacs.org.

- [ ] **Step 7: Commit the binding**

Run:

~~~bash
git status --short
git diff --check
git add macos/emacs/.emacs.d/emacs.org \
  macos/emacs/.emacs.d/init.el \
  macos/emacs/.emacs.d/tests/config-tests.el
git diff --cached --check
git commit -m "feat(emacs): bind Music Assistant frontend"
~~~

Expected: a focused commit containing the leader binding, generated output,
and its passing ERT assertion.

---

### Task 3: Live-evaluate and verify the real integration

**Files:**

- No planned file changes
- Verify: macos/emacs/.emacs.d/emacs.org
- Verify: macos/emacs/.emacs.d/init.el
- Verify: macos/emacs/.emacs.d/tests/config-tests.el

**Interfaces:**

- Consumes:
  - The Music Assistant Org source block from Task 1
  - SPC s m binding from Task 2
  - Running Emacs daemon
  - Music Assistant at http://192.168.1.143:8095
  - MrX.local Music Assistant player
- Produces:
  - Live daemon definitions matching the tested worktree code
  - Evidence that the official frontend renders and controls the shared
    Music Assistant state

- [ ] **Step 1: Re-run automated verification immediately before rollout**

Run:

~~~bash
music_feature_config=/Users/marcosandrade/.dotfiles/.worktrees/music-assistant-emacs/macos/emacs/.emacs.d
music_emacs_bin=/opt/homebrew/opt/emacs-plus@30/bin/emacs

$music_emacs_bin --batch \
  -l $music_feature_config/init.el \
  -l $music_feature_config/tests/config-tests.el \
  --eval "(let ((user-emacs-directory \"$music_feature_config/\"))
            (ert-run-tests-batch-and-exit
             \"music-assistant\"))"

$music_emacs_bin --batch \
  -l $music_feature_config/init.el \
  -l $music_feature_config/tests/config-tests.el \
  --eval "(let ((user-emacs-directory \"$music_feature_config/\"))
            (ert-run-tests-batch-and-exit t))"

git diff HEAD --check
git status --short --branch
~~~

Expected: both ERT commands exit zero, the feature worktree is clean, and the
branch contains the two implementation commits on top of the rebased
documentation commits.

- [ ] **Step 2: Live-evaluate the exact Music Assistant Org block**

Run:

~~~bash
music_org_file=/Users/marcosandrade/.dotfiles/.worktrees/music-assistant-emacs/macos/emacs/.emacs.d/emacs.org

emacsclient --eval \
  "(with-current-buffer
       (find-file-noselect \"$music_org_file\")
     (save-excursion
       (goto-char (point-min))
       (unless (re-search-forward
                \"^\\\\*\\\\* Music Assistant$\" nil t)
         (error \"Music Assistant Org block not found\"))
       (org-babel-next-src-block)
       (org-babel-execute-src-block)))"
~~~

Expected: Org reports evaluation of the emacs-lisp block without an error,
and the running daemon now has the tested option, private helpers, and
interactive command.

- [ ] **Step 3: Live-evaluate the leader binding**

Run:

~~~bash
emacsclient --eval \
  "(mr-x/leader-def
     \"s m\" '(music-assistant :wk \"Music Assistant\"))"
~~~

Then verify the live definitions:

~~~bash
emacsclient --eval \
  "(let* ((aux
           (evil-get-auxiliary-keymap
            general-override-mode-map 'normal))
          (leader (lookup-key aux (kbd \"SPC\"))))
     (list
      (commandp 'music-assistant)
      music-assistant-server-url
      (lookup-key leader (kbd \"s m\"))))"
~~~

Expected:

~~~emacs-lisp
(t "http://192.168.1.143:8095" music-assistant)
~~~

- [ ] **Step 4: Open the embedded frontend**

With a graphical Emacs frame selected, invoke SPC s m. If invoking from the
terminal is necessary, run:

~~~bash
emacsclient --eval "(music-assistant)"
~~~

Expected: Emacs displays an xwidget-webkit-mode buffer containing the
official Music Assistant frontend. A first launch may show Music Assistant's
own login screen; authenticate only inside that page.

Do not place a token in an Emacs command, variable, debug buffer, or shell
argument.

- [ ] **Step 5: Exercise the real playback path**

In the embedded page:

1. Select MrX.local in Music Assistant's player picker.
2. Search for Bladee.
3. Start one result.
4. Confirm artwork, now-playing state, and queue state update in the page.
5. Confirm Home Assistant observes the same MrX.local playback state.
6. Pause the track before leaving the test.

Expected: Music Assistant, not Emacs, performs every media operation, and the
embedded page and Home Assistant agree on the selected player's state.

- [ ] **Step 6: Exercise session reuse and cleanup**

1. Switch to another Emacs buffer, invoke SPC s m again, and confirm Emacs
   returns to the same Music Assistant route.
2. Use the normal xwidget reload command and confirm the frontend reconnects.
3. Kill the Music Assistant xwidget buffer.
4. Invoke SPC s m and confirm a fresh session is created.

Expected: reuse preserves the live session, reload remains upstream xwidget
behavior, and buffer death clears the wrapper's tracked reference.

- [ ] **Step 7: Handle any smoke-test defect with a new red-green cycle**

If the upstream page exposes an xwidget limitation but the wrapper satisfies
its documented contract, record the limitation in the handoff rather than
adding speculative code.

If the wrapper violates its documented contract:

1. Add one focused failing ERT test reproducing the wrapper defect.
2. Run it and confirm the expected failure.
3. Make the smallest emacs.org change that passes it.
4. Retangle the worktree.
5. Run the focused and complete suites.
6. Live-evaluate the corrected block.
7. Repeat the affected smoke-test step.
8. Commit with a specific fix(emacs) message naming the defect.

Use these exact verification commands after the corrective tangle:

~~~bash
music_feature_config=/Users/marcosandrade/.dotfiles/.worktrees/music-assistant-emacs/macos/emacs/.emacs.d
music_emacs_bin=/opt/homebrew/opt/emacs-plus@30/bin/emacs

$music_emacs_bin --batch \
  -l $music_feature_config/init.el \
  -l $music_feature_config/tests/config-tests.el \
  --eval "(let ((user-emacs-directory \"$music_feature_config/\"))
            (ert-run-tests-batch-and-exit
             \"music-assistant\"))"

$music_emacs_bin --batch \
  -l $music_feature_config/init.el \
  -l $music_feature_config/tests/config-tests.el \
  --eval "(let ((user-emacs-directory \"$music_feature_config/\"))
            (ert-run-tests-batch-and-exit t))"
~~~

- [ ] **Step 8: Capture final evidence**

Run:

~~~bash
git status --short --branch
git log -6 --oneline --decorate
git diff main...HEAD --check
git diff --stat main...HEAD
~~~

Expected: a clean feature worktree, no whitespace errors, the approved design
and plan commits, two implementation commits, and only the documented Emacs
configuration, generated output, tests, and planning artifacts in scope.
