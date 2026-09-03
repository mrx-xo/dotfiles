# Native Emacs Music Assistant Frontend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native Emacs dashboard that controls the shared Music
Assistant player and queue through the schema-31 WebSocket API.

**Architecture:** A transport-independent client module owns authentication,
request correlation, reconnects, player/queue state, and API commands. A
separate special-mode UI renders that state, handles keyboard interaction,
loads artwork asynchronously, and never owns playback. Music Assistant remains
the source of truth used by Emacs, Home Assistant, and the web frontend.

**Tech Stack:** Emacs 30.2, Emacs Lisp with lexical binding, websocket.el,
json.el, url.el, macOS Keychain, Org Babel tangling, General.el, Evil, and ERT.

**Spec:** macos/docs/superpowers/specs/2026-08-27-music-assistant-emacs-design.md

## Global Constraints

- Work only in `.worktrees/music-assistant-emacs` on
  `feature/music-assistant-emacs`; the branch is already rebased onto current
  `main`.
- Execute inline with `superpowers:executing-plans`; do not dispatch
  subagents.
- Target Music Assistant 2.9.13, API schema 31, at
  `http://192.168.1.143:8095`.
- Treat `emacs.org` as configuration source and regenerate `init.el`; never
  hand-edit generated `init.el`.
- Do not use xwidget, Ready Player internals, empv, a sidecar process, DOM
  scraping, or JavaScript injection.
- Keep playback, queues, player state, and library data authoritative in Music
  Assistant.
- Read the API token only from macOS Keychain service
  `music-assistant-token`, account `emacs`, through argument-vector process
  invocation.
- Never put a real token in source, tests, logs, shell arguments, transcript
  output, Git history, or chat.
- Never restart, kill, or reload the main Emacs daemon. Load verified files
  with `emacsclient`.
- Use 256-pixel artwork requests; the live schema-31 image proxy accepts 256
  but rejects the earlier proposed size of 240.
- Every production behavior follows a witnessed ERT red-green cycle.
- Do not run `macos/scripts/tangle-emacs-org.sh` from this worktree because it
  targets the main checkout.

## File Structure

- Create `macos/emacs/.emacs.d/lisp/music-assistant-client.el`.
  This file is the protocol/state boundary and has no UI dependency.
- Create `macos/emacs/.emacs.d/lisp/music-assistant.el`.
  This file owns the special-mode buffer, rendering, commands, artwork, and UI
  timers.
- Create `macos/emacs/.emacs.d/tests/music-assistant-tests.el`.
  This file contains isolated client and UI tests with fake transport and
  timer boundaries.
- Modify `macos/emacs/.emacs.d/tests/config-tests.el`.
  Remove xwidget lifecycle coverage and retain only integration assertions for
  the native command, dependency, persisted player, and leader binding.
- Modify `macos/emacs/.emacs.d/emacs.org`.
  Replace the xwidget wrapper with package/autoload/savehist configuration.
- Regenerate `macos/emacs/.emacs.d/init.el` from `emacs.org`.
- Delete
  `macos/docs/superpowers/plans/2026-09-02-music-assistant-xwidget.md`.
  The failed xwidget experiment remains recoverable from Git history.

The client exposes these stable public interfaces:

```emacs-lisp
(music-assistant-client-create
 :server-url URL
 :token-provider FUNCTION
 :on-state-change FUNCTION
 :request-timeout SECONDS
 :default-player-name NAME
 :open-function FUNCTION
 :send-function FUNCTION
 :close-function FUNCTION
 :schedule-function FUNCTION
 :cancel-function FUNCTION)

(music-assistant-client-connect CLIENT)
(music-assistant-client-close CLIENT)
(music-assistant-client-retry CLIENT)
(music-assistant-client-refresh CLIENT)
(music-assistant-client-request CLIENT COMMAND ARGS CALLBACK &optional ERRBACK)
(music-assistant-client-select-player CLIENT PLAYER-ID)
(music-assistant-client-search-tracks CLIENT QUERY CALLBACK ERRBACK)
(music-assistant-client-play-media CLIENT URI)
(music-assistant-client-play-index CLIENT QUEUE-ITEM-ID)
(music-assistant-client-play-pause CLIENT)
(music-assistant-client-previous CLIENT)
(music-assistant-client-next CLIENT)
(music-assistant-client-seek-relative CLIENT DELTA)
(music-assistant-client-set-volume CLIENT LEVEL)
```

The UI exposes:

```emacs-lisp
(music-assistant)
(music-assistant-mode)
(music-assistant-refresh)
(music-assistant-search)
(music-assistant-choose-player)
(music-assistant-play-pause)
(music-assistant-previous)
(music-assistant-next)
(music-assistant-seek-backward)
(music-assistant-seek-forward)
(music-assistant-volume-down)
(music-assistant-volume-up)
(music-assistant-queue-next)
(music-assistant-queue-previous)
(music-assistant-play-selected)
(music-assistant-quit)
```

---

### Task 1: Retire the xwidget wrapper and establish native module loading

**Files:**

- Create: `macos/emacs/.emacs.d/lisp/music-assistant-client.el`
- Create: `macos/emacs/.emacs.d/lisp/music-assistant.el`
- Modify: `macos/emacs/.emacs.d/emacs.org:2982`
- Modify: `macos/emacs/.emacs.d/tests/config-tests.el:539`
- Regenerate: `macos/emacs/.emacs.d/init.el`

**Interfaces:**

- Consumes: the existing early `lisp/` load-path and General/Evil setup.
- Produces: loadable `music-assistant-client` and `music-assistant`
  features, `music-assistant-mode`, the interactive `music-assistant`
  entrypoint, configuration variables, and an unchanged `SPC s m` binding.

- [ ] **Step 1: Replace xwidget tests with a failing native integration test**

Delete the xwidget-specific tests from
`config-test-music-assistant-same-origin` through
`config-test-music-assistant-requires-graphical-xwidget`. Replace
`config-test-music-assistant-configuration` with:

```emacs-lisp
(ert-deftest config-test-music-assistant-native-configuration ()
  "Music Assistant should load as a native module with secure defaults."
  (require 'music-assistant)
  (should (featurep 'music-assistant-client))
  (with-temp-buffer
    (music-assistant-mode)
    (should (derived-mode-p 'special-mode)))
  (should (commandp 'music-assistant))
  (should (equal music-assistant-server-url
                 "http://192.168.1.143:8095"))
  (should (equal music-assistant-default-player-name "MrX.local"))
  (should (= music-assistant-artwork-size 256))
  (should (memq 'music-assistant-last-player-id
                savehist-additional-variables)))
```

Run:

```bash
music_config=/Users/marcosandrade/.dotfiles/.worktrees/music-assistant-emacs/macos/emacs/.emacs.d
/opt/homebrew/opt/emacs-plus@30/bin/emacs --batch \
  -L "$music_config/lisp" \
  -l "$music_config/init.el" \
  -l "$music_config/tests/config-tests.el" \
  --eval "(let ((user-emacs-directory \"$music_config/\"))
            (ert-run-tests-batch-and-exit
             'config-test-music-assistant-native-configuration))"
```

Expected: FAIL because `music-assistant.el` does not exist.

- [ ] **Step 2: Add minimal loadable client and UI modules**

Create `music-assistant-client.el` with a lexical-binding header,
`(require 'cl-lib)`, `(require 'json)`, `(require 'subr-x)`, the
client group, and `(provide 'music-assistant-client)`.

Create `music-assistant.el` with:

```emacs-lisp
;;; music-assistant.el --- Native Music Assistant dashboard -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'music-assistant-client)

(defgroup music-assistant nil
  "Control Music Assistant from Emacs."
  :group 'multimedia)

(defcustom music-assistant-server-url "http://192.168.1.143:8095"
  "Base URL of the Music Assistant server."
  :type 'string :group 'music-assistant)

(defcustom music-assistant-default-player-name "MrX.local"
  "Player selected when no remembered player is available."
  :type 'string :group 'music-assistant)

(defcustom music-assistant-keychain-service "music-assistant-token"
  "macOS Keychain service containing the API token."
  :type 'string :group 'music-assistant)

(defcustom music-assistant-request-timeout 10
  "Seconds before a Music Assistant request fails."
  :type 'number :group 'music-assistant)

(defcustom music-assistant-artwork-size 256
  "Square Music Assistant artwork size in pixels."
  :type 'integer :group 'music-assistant)

(defvar music-assistant-last-player-id nil
  "Last player explicitly selected in the dashboard.")

(define-derived-mode music-assistant-mode special-mode "Music Assistant"
  "Major mode for the Music Assistant dashboard."
  (setq-local mode-line-format nil))

(defun music-assistant ()
  "Open the native Music Assistant dashboard."
  (interactive)
  (let ((buffer (get-buffer-create "*Music Assistant*")))
    (with-current-buffer buffer
      (music-assistant-mode))
    (pop-to-buffer buffer)
    buffer))

(provide 'music-assistant)
```

- [ ] **Step 3: Replace the Org xwidget block with native configuration**

Keep the `** Music Assistant` heading and replace its source block with:

```emacs-lisp
(use-package websocket
  :ensure t
  :defer t)

(use-package music-assistant
  :ensure nil
  :commands (music-assistant)
  :init
  (require 'savehist)
  (add-to-list 'savehist-additional-variables
               'music-assistant-last-player-id)
  :config
  (when (fboundp 'evil-set-initial-state)
    (evil-set-initial-state 'music-assistant-mode 'motion)))
```

Retain the existing `"s m" '(music-assistant :wk "Music Assistant")`
leader entry.

- [ ] **Step 4: Tangle and verify the green integration test**

Run:

```bash
music_config=/Users/marcosandrade/.dotfiles/.worktrees/music-assistant-emacs/macos/emacs/.emacs.d
cd "$music_config"
/opt/homebrew/opt/emacs-plus@30/bin/emacs --batch -Q \
  --eval "(require 'org)" \
  --eval "(org-babel-tangle-file \"emacs.org\")"
/opt/homebrew/opt/emacs-plus@30/bin/emacs --batch \
  -L "$music_config/lisp" \
  -l "$music_config/init.el" \
  -l "$music_config/tests/config-tests.el" \
  --eval "(let ((user-emacs-directory \"$music_config/\"))
            (ert-run-tests-batch-and-exit
             'config-test-music-assistant-native-configuration))"
```

Expected: the focused test passes and `init.el` contains no
`music-assistant--ensure-xwidget`.

- [ ] **Step 5: Commit the native seam**

```bash
git add macos/emacs/.emacs.d/emacs.org \
        macos/emacs/.emacs.d/init.el \
        macos/emacs/.emacs.d/lisp/music-assistant-client.el \
        macos/emacs/.emacs.d/lisp/music-assistant.el \
        macos/emacs/.emacs.d/tests/config-tests.el \
        macos/docs/superpowers/specs/2026-08-27-music-assistant-emacs-design.md \
        macos/docs/superpowers/plans/2026-09-02-music-assistant-xwidget.md \
        macos/docs/superpowers/plans/2026-09-02-music-assistant-native.md
git commit -m "refactor(emacs): restore native Music Assistant design"
```

---

### Task 2: Implement request correlation, safe token retrieval, and parsing

**Files:**

- Create: `macos/emacs/.emacs.d/tests/music-assistant-tests.el`
- Modify: `macos/emacs/.emacs.d/lisp/music-assistant-client.el`

**Interfaces:**

- Consumes: websocket.el callbacks and frames at the default transport edge.
- Produces:
  - `music-assistant-client` and
    `music-assistant-client--pending-request` structs.
  - `music-assistant-client-websocket-url`.
  - `music-assistant-client-create`.
  - `music-assistant-client-request`.
  - `music-assistant-client--handle-text`.
  - `music-assistant-client--keychain-command`.
  - `music-assistant-client--read-keychain-token`.
  - `music-assistant-client--log`.

- [ ] **Step 1: Add focused request and redaction tests**

Create `music-assistant-tests.el` with lexical binding, require ERT and both
modules, and define a helper that captures serialized outbound frames:

```emacs-lisp
(defun music-assistant-test-client (&rest overrides)
  "Create a deterministic client with OVERRIDES."
  (let ((options
         (list :server-url "http://music.test:8095"
               :token-provider (lambda (ok _error) (funcall ok "fake-token"))
               :on-state-change #'ignore
               :request-timeout 10
               :default-player-name "Desk"
               :open-function (lambda (_client _url) 'fake-socket)
               :send-function (lambda (client text)
                                (push text
                                      (music-assistant-client-test-output
                                       client)))
               :close-function #'ignore
               :schedule-function
               (lambda (_seconds function &rest args)
                 (list function args))
               :cancel-function #'ignore)))
    (while overrides
      (setq options
            (plist-put options (pop overrides) (pop overrides))))
    (apply #'music-assistant-client-create options)))
```

Add tests that assert:

```emacs-lisp
(ert-deftest music-assistant-client-websocket-url-normalizes-once ()
  (should (equal
           (music-assistant-client-websocket-url
            "https://music.test/base/")
           "wss://music.test/base/ws"))
  (should (equal
           (music-assistant-client-websocket-url
            "http://music.test:8095/ws")
           "ws://music.test:8095/ws")))

(ert-deftest music-assistant-client-request-correlates-partial-result ()
  (let* ((client (music-assistant-test-client))
         received)
    (music-assistant-client-request
     client "library/tracks" '((limit . 2))
     (lambda (result) (setq received result)))
    (let* ((wire (json-parse-string
                  (car (music-assistant-client-test-output client))
                  :object-type 'alist :object-key-type 'symbol))
           (id (alist-get 'message_id wire)))
      (should (equal (alist-get 'command wire) "library/tracks"))
      (music-assistant-client--handle-text
       client
       (json-serialize
        `((message_id . ,id) (result . [1]) (partial . t))))
      (should-not received)
      (music-assistant-client--handle-text
       client
       (json-serialize
        `((message_id . ,id) (result . [2]) (partial . :false))))
      (should (equal received '(1 2))))))

(ert-deftest music-assistant-client-request-delivers-safe-error-once ()
  (let* ((client (music-assistant-test-client))
         (errors nil)
         (id (music-assistant-client-request
              client "players/all" nil #'ignore
              (lambda (error) (push error errors)))))
    (music-assistant-client--handle-text
     client
     (json-serialize
      `((message_id . ,id) (error_code . 401)
        (details . "Invalid token"))))
    (music-assistant-client--handle-text
     client
     (json-serialize
      `((message_id . ,id) (error_code . 401)
        (details . "duplicate"))))
    (should (= (length errors) 1))
    (should (equal (plist-get (car errors) :code) 401))))

(ert-deftest music-assistant-client-auth-log-redacts-entire-args ()
  (let ((client (music-assistant-test-client)))
    (music-assistant-client--log
     client 'send "auth" "emacs-1" '((token . "fake-token")))
    (let ((line (car (music-assistant-client-log-entries client))))
      (should (string-match-p "<redacted>" line))
      (should-not (string-match-p "fake-token" line)))))
```

Run:

```bash
music_config=/Users/marcosandrade/.dotfiles/.worktrees/music-assistant-emacs/macos/emacs/.emacs.d
/opt/homebrew/opt/emacs-plus@30/bin/emacs --batch -Q \
  -L "$HOME/.emacs.d/elpaca/builds/websocket" \
  -L "$music_config/lisp" \
  -l "$music_config/tests/music-assistant-tests.el" \
  --eval "(ert-run-tests-batch-and-exit
           \"^music-assistant-client-\")"
```

Expected: failures for missing constructor, URL conversion, request handling,
and logging.

- [ ] **Step 2: Implement the request core**

Use `cl-defstruct` for client state and pending requests. The client slots
must include URL, WebSocket, state, server info, pending table, sequence,
players, queues, queue items, selected IDs, reconnect state, transport/timer
functions, hooks, log entries, and `test-output`.

Use this exact request shape:

```emacs-lisp
(json-serialize
 `((message_id . ,message-id)
   (command . ,command)
   (args . ,(or args (make-hash-table :test #'equal))))
 :null-object nil :false-object :false)
```

`music-assistant-client--handle-text` must parse with symbol keys, route
`error_code` before `result`, accumulate vector/list partial results, cancel
the request timer exactly once, ignore unknown IDs, and catch malformed JSON
without signaling from a process callback.

`music-assistant-client--request-timeout` removes the pending request and
calls its errback with:

```emacs-lisp
(:code timeout :details "Request timed out" :command COMMAND)
```

- [ ] **Step 3: Implement Keychain retrieval and safe logging**

`music-assistant-client--keychain-command` returns:

```emacs-lisp
("/usr/bin/security" "find-generic-password" "-w"
 "-a" "emacs" "-s" SERVICE)
```

`music-assistant-client--read-keychain-token` takes success and error
callbacks, uses `make-process :command` with that list, stores output only in
a generated temporary buffer, trims it on exit 0, kills the buffer in every
path, and returns only safe errors such as `"Music Assistant token missing"`.
It must never invoke a shell or include token contents in an error/log.

Log entries contain timestamp, direction/event, command/event name, message
ID, and safe details. For command `auth`, replace the entire args value with
the literal string `<redacted>`.

- [ ] **Step 4: Verify the request core**

Run the focused command from Step 1. Expected: all tests named
`music-assistant-client-*` pass.

- [ ] **Step 5: Commit**

```bash
git add macos/emacs/.emacs.d/lisp/music-assistant-client.el \
        macos/emacs/.emacs.d/tests/music-assistant-tests.el
git commit -m "feat(emacs): add Music Assistant request client"
```

---

### Task 3: Implement connection, authentication, bootstrap, and reconnects

**Files:**

- Modify: `macos/emacs/.emacs.d/lisp/music-assistant-client.el`
- Modify: `macos/emacs/.emacs.d/tests/music-assistant-tests.el`

**Interfaces:**

- Consumes: Task 2 request parser and injected transport/timer functions.
- Produces:
  - `music-assistant-client-connect`, `music-assistant-client-close`, and
    `music-assistant-client-retry`.
  - Explicit states `disconnected`, `connecting`, `authenticating`,
    `ready`, `reconnecting`, `auth-required`, and `error`.
  - Schema validation and initial `players/all`,
    `player_queues/all`, and `player_queues/items` fetches.

- [ ] **Step 1: Add failing lifecycle tests**

Add tests for these concrete transitions:

```emacs-lisp
(ert-deftest music-assistant-client-authenticates-after-server-info ()
  (let ((client (music-assistant-test-client)))
    (music-assistant-client-connect client)
    (should (eq (music-assistant-client-state client) 'connecting))
    (music-assistant-client--handle-text
     client
     "{\"server_id\":\"s\",\"server_version\":\"2.9.13\",
       \"schema_version\":31,\"min_supported_schema_version\":28,
       \"base_url\":\"http://music.test:8095\"}")
    (should (eq (music-assistant-client-state client) 'authenticating))
    (let* ((auth (json-parse-string
                  (car (music-assistant-client-test-output client))
                  :object-type 'alist :object-key-type 'symbol))
           (id (alist-get 'message_id auth)))
      (should (equal (alist-get 'command auth) "auth"))
      (music-assistant-client--handle-text
       client
       (json-serialize
        `((message_id . ,id)
          (result . ((authenticated . t)))))))
    (should (eq (music-assistant-client-state client) 'ready))
    (should
     (equal
      (sort
       (mapcar
        (lambda (text)
          (alist-get
           'command
           (json-parse-string text :object-type 'alist
                              :object-key-type 'symbol)))
        (music-assistant-client-test-output client))
       #'string<)
      '("auth" "player_queues/all" "players/all")))))

(ert-deftest music-assistant-client-missing-token-is-terminal ()
  (let ((client
         (music-assistant-test-client
          :token-provider
          (lambda (_ok error) (funcall error "missing")))))
    (music-assistant-client-connect client)
    (music-assistant-client--handle-text
     client
     "{\"server_id\":\"s\",\"server_version\":\"2.9.13\",
       \"schema_version\":31,\"min_supported_schema_version\":28,
       \"base_url\":\"http://music.test:8095\"}")
    (should (eq (music-assistant-client-state client) 'auth-required))
    (should-not (music-assistant-client-reconnect-timer client))))

(ert-deftest music-assistant-client-reconnect-backoff-is-single-and-capped ()
  (let (delays)
    (let ((client
           (music-assistant-test-client
            :schedule-function
            (lambda (seconds function &rest args)
              (push seconds delays)
              (list seconds function args)))))
      (dotimes (_ 7)
        (setf (music-assistant-client-reconnect-timer client) nil)
        (music-assistant-client--handle-close client))
      (should (equal (reverse delays) '(1 2 4 8 16 30 30)))
      (setf (music-assistant-client-reconnect-timer client) nil)
      (music-assistant-client--handle-close client)
      (music-assistant-client--handle-close client)
      (should (= (length delays) 8)))))

(ert-deftest music-assistant-client-close-cancels-every-resource ()
  (let ((next-timer 0)
        cancelled
        errors
        (close-count 0))
    (let ((client
           (music-assistant-test-client
            :schedule-function
            (lambda (_seconds _function &rest _args)
              (cl-incf next-timer))
            :cancel-function
            (lambda (timer) (push timer cancelled))
            :close-function
            (lambda (_client) (cl-incf close-count)))))
      (setf (music-assistant-client-websocket client) 'fake-socket)
      (music-assistant-client-request
       client "players/all" nil #'ignore
       (lambda (error) (push error errors)))
      (setf (music-assistant-client-reconnect-timer client) 99)
      (music-assistant-client-close client)
      (music-assistant-client-close client)
      (should (= close-count 1))
      (should (equal (sort cancelled #'<) '(1 99)))
      (should (= (length errors) 1))
      (should (eq (plist-get (car errors) :code) 'disconnected))
      (should (= (hash-table-count
                  (music-assistant-client-pending client))
                 0))
      (should-not (music-assistant-client-reconnect-timer client)))))
```

Expand the final two test bodies with captured lists rather than mocks:
`schedule-function` records its delay and returns a unique cons; the
`cancel-function` pushes that cons into a cancellation list.

Run the dedicated client tests. Expected: the new lifecycle tests fail because
connection functions are missing.

- [ ] **Step 2: Implement the default websocket adapter and handshake**

Require `websocket` only when the default open function runs. Call
`websocket-open` with `:nowait t` and callbacks created with
`apply-partially`. The message callback passes
`(websocket-frame-payload frame)` to
`music-assistant-client--handle-text`. The error callback records a safe
message and routes through the same disconnect state machine.

On a server-info object:

1. Save it.
2. If `min_supported_schema_version` is greater than 31, enter terminal
   `error` with an incompatibility message.
3. Enter `authenticating`.
4. Ask the token provider asynchronously.
5. Send `auth` with only `((token . TOKEN))`.
6. On success enter `ready`, reset reconnect attempt to zero, and request
   players and queues concurrently.
7. On auth error enter `auth-required` and do not reconnect automatically.

- [ ] **Step 3: Implement reconnect and idempotent close**

Unexpected close preserves cached state and schedules one retry using:

```emacs-lisp
(aref [1 2 4 8 16 30]
      (min reconnect-attempt 5))
```

`music-assistant-client-retry` cancels that timer and reconnects immediately.
`music-assistant-client-close` sets an intentional-close flag before closing,
cancels every request/reconnect timer, resolves pending requests as
disconnected, clears callbacks, and remains safe on a second call.

- [ ] **Step 4: Verify and commit**

Run all `music-assistant-client-*` tests. Expected: all pass.

```bash
git add macos/emacs/.emacs.d/lisp/music-assistant-client.el \
        macos/emacs/.emacs.d/tests/music-assistant-tests.el
git commit -m "feat(emacs): connect and authenticate Music Assistant"
```

---

### Task 4: Implement authoritative player, queue, event, and command state

**Files:**

- Modify: `macos/emacs/.emacs.d/lisp/music-assistant-client.el`
- Modify: `macos/emacs/.emacs.d/tests/music-assistant-tests.el`

**Interfaces:**

- Consumes: ready client and request correlation from Tasks 2-3.
- Produces selected-player/queue resolution, event updates, search result
  normalization input, and exact schema-31 command helpers.

- [ ] **Step 1: Add failing selection and event tests**

Use small alists representing live schema-31 objects. Cover:

- Saved available player wins.
- Otherwise exact available `MrX.local` wins.
- Otherwise the first available player sorted case-insensitively wins.
- Disabled, hidden, or unavailable players are excluded.
- No candidate clears selected player and queue.
- `active_source` selects a known queue; otherwise player ID is used when it
  names a queue.
- `player_added`, `player_updated`, and `player_removed` mutate by
  `player_id`.
- `queue_added` and `queue_updated` mutate by `queue_id`.
- `queue_time_updated` updates only elapsed time and its local receipt
  timestamp.
- `queue_items_updated` for the selected queue requests
  `player_queues/items`; the same event for another queue does not.
- Unknown and malformed events retain previous valid state.

The fallback assertion is:

```emacs-lisp
(setf (music-assistant-client-players client)
      '(((player_id . "kitchen") (name . "Kitchen") (available . t)
         (enabled . t) (hide_in_ui . :false))
        ((player_id . "desk") (name . "MrX.local") (available . t)
         (enabled . t) (hide_in_ui . :false))))
(music-assistant-client--select-fallback-player client)
(should (equal (music-assistant-client-selected-player-id client) "desk"))
```

- [ ] **Step 2: Add failing command payload tests**

Capture and decode the newest outbound frame for each public command. Assert
these exact commands and args:

```text
music/search                 search_query, media_types ["track"], limit 25,
                             library_only false
player_queues/play_media     queue_id, media URI, option "replace"
player_queues/play_index     queue_id, index QUEUE-ITEM-ID
player_queues/play_pause     queue_id
player_queues/previous       queue_id
player_queues/next           queue_id
player_queues/seek           queue_id, absolute position
players/cmd/volume_set       player_id, integer volume_level clamped 0..100
```

Seek-relative uses authoritative elapsed time plus delta, clamps to zero and
the current-item duration, then sends the absolute integer position.

Run the focused client suite. Expected: the new state and command tests fail.

- [ ] **Step 3: Implement collection reconciliation and selection**

Write helpers that look up/update/remove alist objects by stable ID without
reordering unrelated entries. Available means `available` is true,
`enabled` is not false, and `hide_in_ui` is not true.

`music-assistant-client-select-player` validates availability, stores the ID
in the client, resolves the active queue, fetches that queue's items, invokes
the state hook, and returns the player. Persistence remains a UI boundary:
only the interactive player picker writes
`music-assistant-last-player-id`.

- [ ] **Step 4: Implement events and public commands**

Route event objects before result/server-info objects in the parser. Store a
local float-time baseline when queue time arrives. Every state mutation invokes
the client state hook after the full mutation is complete.

Public commands must signal `user-error` when no meaningful player/queue is
selected; network callbacks must convert errors into client state and never
signal from the WebSocket filter.

- [ ] **Step 5: Verify and commit**

Run all dedicated client tests. Expected: all pass.

```bash
git add macos/emacs/.emacs.d/lisp/music-assistant-client.el \
        macos/emacs/.emacs.d/tests/music-assistant-tests.el
git commit -m "feat(emacs): model Music Assistant players and queues"
```

---

### Task 5: Build the native special-mode dashboard and interactions

**Files:**

- Modify: `macos/emacs/.emacs.d/lisp/music-assistant.el`
- Modify: `macos/emacs/.emacs.d/tests/music-assistant-tests.el`

**Interfaces:**

- Consumes: Task 4 client state/accessors and command helpers.
- Produces: complete text UI, keymap, queue selection, search picker, player
  picker, and user-facing connection/error states.

- [ ] **Step 1: Add failing renderer tests**

Create real temporary `music-assistant-mode` buffers and real client structs.
Assert rendered text/properties for:

- connecting, authenticating, auth-required, reconnecting, error, ready, no
  player, and no queue states;
- selected player name, title, joined artist names, album/year, elapsed and
  duration, volume, and playback state;
- queue rows with `music-assistant-queue-item-id` properties;
- a distinct `music-assistant-current-item-face` for the playing item and
  `music-assistant-selection-face` for keyboard selection;
- selection preservation by queue item ID, then current item, then first item.

The ready fixture should render text containing:

```text
Music Assistant
MrX.local
Bladee
Icedancer
01:42
03:18
Queue
```

Run `^music-assistant-ui-`. Expected: failures for missing faces/rendering.

- [ ] **Step 2: Implement faces, keymap, state access, and rendering**

Define inherited faces for title, metadata, progress fill/empty, current item,
selection, dimmed stale state, error, and key hints. Define
`music-assistant-mode-map` with:

```emacs-lisp
(define-key map (kbd "SPC") #'music-assistant-play-pause)
(define-key map (kbd "p")   #'music-assistant-previous)
(define-key map (kbd "n")   #'music-assistant-next)
(define-key map (kbd "h")   #'music-assistant-seek-backward)
(define-key map (kbd "l")   #'music-assistant-seek-forward)
(define-key map (kbd "-")   #'music-assistant-volume-down)
(define-key map (kbd "+")   #'music-assistant-volume-up)
(define-key map (kbd "=")   #'music-assistant-volume-up)
(define-key map (kbd "j")   #'music-assistant-queue-next)
(define-key map (kbd "k")   #'music-assistant-queue-previous)
(define-key map (kbd "RET") #'music-assistant-play-selected)
(define-key map (kbd "s")   #'music-assistant-search)
(define-key map (kbd "P")   #'music-assistant-choose-player)
(define-key map (kbd "g")   #'music-assistant-refresh)
(define-key map (kbd "?")   #'describe-mode)
(define-key map (kbd "q")   #'music-assistant-quit)
```

Rendering uses `inhibit-read-only`, `erase-buffer`, and `save-window-excursion`
only; it never calls `set-window-buffer`, selects another window, deletes a
window, or replaces another buffer.

- [ ] **Step 3: Add failing interaction tests**

Test real commands with client functions temporarily rebound at the boundary:

- movement changes selected queue item without leaving the queue;
- RET passes the selected stable item ID;
- search rejects blank input, shows `searching...`, formats candidates as
  `Track — Artist — Album [provider]`, handles empty results, and passes the
  chosen canonical `uri` to play-media;
- player picker labels available players, changes the client selection, sets
  `music-assistant-last-player-id`, and calls `savehist-save`;
- playback/seek/volume commands delegate once and leave rendering to events.

Run UI tests. Expected: the new command tests fail.

- [ ] **Step 4: Implement dashboard lifecycle and commands**

`music-assistant` reuses one live `*Music Assistant*` buffer, creates one
client per buffer, renders immediately, and connects asynchronously. Opening
an existing disconnected/error dashboard invokes retry rather than creating a
second client.

The state callback captures the dashboard buffer, verifies it is live and
still owns that client, and schedules rendering on the main Emacs event loop.
Search and player completion callbacks perform the same stale-buffer/client
checks before opening the minibuffer.

- [ ] **Step 5: Verify and commit**

Run all `music-assistant-ui-*` tests and then the entire dedicated file.
Expected: all pass.

```bash
git add macos/emacs/.emacs.d/lisp/music-assistant.el \
        macos/emacs/.emacs.d/tests/music-assistant-tests.el
git commit -m "feat(emacs): add native Music Assistant dashboard"
```

---

### Task 6: Add progress updates, artwork caching, logging, and cleanup

**Files:**

- Modify: `macos/emacs/.emacs.d/lisp/music-assistant.el`
- Modify: `macos/emacs/.emacs.d/tests/music-assistant-tests.el`

**Interfaces:**

- Consumes: current queue item, server base URL, event receipt baseline, and
  client log entries.
- Produces asynchronous artwork, one-second in-place progress updates, an
  optional log buffer, and idempotent teardown.

- [ ] **Step 1: Add failing progress and artwork tests**

Cover:

- elapsed time advances from the latest server value only while state is
  `playing`, using local receipt time and playback speed;
- elapsed clamps to duration;
- the progress timer exists only while a ready queue is playing;
- proxy ID `abc` resolves to
  `http://music.test:8095/imageproxy/abc?size=256`;
- successful image data caches by final URL;
- a failure marker suppresses another fetch for 30 seconds;
- a callback for an old item cannot replace current artwork;
- response buffers are killed on success and failure;
- artwork failure leaves `[no artwork]` and does not affect controls.

Use injected variables
`music-assistant--url-retrieve-function`,
`music-assistant--create-image-function`,
`music-assistant--schedule-function`, and
`music-assistant--cancel-function`; no unit test performs network I/O.

- [ ] **Step 2: Implement progress and artwork**

Track markers surrounding only the elapsed/progress region. The one-second
timer calls `music-assistant--update-progress`, which replaces that region
under `inhibit-read-only` and does not rerender the queue or move point.

Artwork lookup order is queue-item `image`, then the current media item's
`metadata.images`. Use only an image with a non-empty `proxy_id`. Fetch
with `url-retrieve`; parse after `url-http-end-of-headers`; call
`create-image` with data mode; cache the image object; and verify buffer,
client, and queue-item ID before rerendering.

- [ ] **Step 3: Add failing cleanup and log tests**

Assert:

- `music-assistant-quit` and `kill-buffer-hook` call one idempotent cleanup;
- cleanup closes the client, cancels progress timer, kills outstanding HTTP
  response buffers, clears pending artwork requests, and prevents late
  callbacks from rendering;
- reopening after kill creates a fresh client;
- `music-assistant-show-log` displays safe connection transitions, commands,
  IDs, events, and errors;
- neither fake token nor auth args occur in rendered/log buffers.

- [ ] **Step 4: Implement cleanup and the log viewer**

Use a buffer-local `music-assistant--cleaned-p` guard. Add the same cleanup
function to `kill-buffer-hook`; `music-assistant-quit` calls it and then
`quit-window` without killing other buffers or frames.

Render `*Music Assistant Log*` from the client's already-sanitized entries in
`special-mode`. Never add a raw inbound frame or raw command args to the log.

- [ ] **Step 5: Verify and commit**

Run the dedicated test file. Expected: all client and UI tests pass.

```bash
git add macos/emacs/.emacs.d/lisp/music-assistant.el \
        macos/emacs/.emacs.d/tests/music-assistant-tests.el
git commit -m "feat(emacs): finish Music Assistant dashboard lifecycle"
```

---

### Task 7: Integrate, compile, live-evaluate, and smoke-test

**Files:**

- Modify: `macos/emacs/.emacs.d/tests/config-tests.el`
- Modify: `macos/emacs/.emacs.d/emacs.org`
- Regenerate: `macos/emacs/.emacs.d/init.el`

**Interfaces:**

- Consumes: complete modules and the live Music Assistant server.
- Produces a tangled, tested config loaded into the current daemon and a live
  acceptance result against `MrX.local`.

- [ ] **Step 1: Add and witness final failing integration assertions**

Add or update config tests that require `music-assistant` and assert:

```emacs-lisp
(ert-deftest config-test-music-assistant-native-integration ()
  "The native dashboard should be wired into the complete config."
  (require 'music-assistant)
  (should (featurep 'websocket))
  (should (eq (lookup-key music-assistant-mode-map (kbd "SPC"))
              #'music-assistant-play-pause))
  (should (eq (lookup-key music-assistant-mode-map (kbd "s"))
              #'music-assistant-search))
  (should (eq (lookup-key music-assistant-mode-map (kbd "P"))
              #'music-assistant-choose-player))
  (should (memq 'music-assistant-last-player-id
                savehist-additional-variables)))
```

Update `config-test-leader-music-assistant-key` docstring to say
`"SPC s m should open the native Music Assistant dashboard."`.

Before the final Org adjustment, run the two integration tests and confirm the
new dependency assertion fails if websocket is still deferred and unloaded.
Then change the Org declaration to load websocket before the local package:

```emacs-lisp
(use-package websocket :ensure t)
```

- [ ] **Step 2: Tangle and run all automated verification**

Run:

```bash
music_config=/Users/marcosandrade/.dotfiles/.worktrees/music-assistant-emacs/macos/emacs/.emacs.d
music_emacs=/opt/homebrew/opt/emacs-plus@30/bin/emacs

cd "$music_config"
"$music_emacs" --batch -Q \
  --eval "(require 'org)" \
  --eval "(org-babel-tangle-file \"emacs.org\")"

"$music_emacs" --batch -Q \
  -L "$HOME/.emacs.d/elpaca/builds/websocket" \
  -L "$music_config/lisp" \
  -l "$music_config/tests/music-assistant-tests.el" \
  -f ert-run-tests-batch-and-exit

"$music_emacs" --batch \
  -L "$music_config/lisp" \
  -l "$music_config/init.el" \
  -l "$music_config/tests/config-tests.el" \
  --eval "(let ((user-emacs-directory \"$music_config/\"))
            (ert-run-tests-batch-and-exit t))"

"$music_emacs" --batch -Q \
  -L "$HOME/.emacs.d/elpaca/builds/websocket" \
  -L "$music_config/lisp" \
  --eval "(setq byte-compile-error-on-warn t)" \
  -f batch-byte-compile \
  "$music_config/lisp/music-assistant-client.el" \
  "$music_config/lisp/music-assistant.el"

git diff --check
git status --short
```

Expected: both ERT suites report zero unexpected results; both files compile
without warnings; `git diff --check` exits 0. Remove generated `.elc` files
from the worktree after compilation because the installed config loads source.

- [ ] **Step 3: Commit verified integration**

```bash
git add macos/emacs/.emacs.d/emacs.org \
        macos/emacs/.emacs.d/init.el \
        macos/emacs/.emacs.d/tests/config-tests.el
git commit -m "feat(emacs): wire native Music Assistant dashboard"
```

- [ ] **Step 4: Securely provision the live token if absent**

Check only presence:

```bash
if /usr/bin/security find-generic-password \
     -a emacs -s music-assistant-token >/dev/null 2>&1
then
  print "Music Assistant token present"
else
  print "Music Assistant token missing"
fi
```

If missing, use the already authenticated Chrome Music Assistant profile page
to create a long-lived access token. Put it into Keychain from a private
terminal prompt:

```bash
security add-generic-password -U -a emacs -s music-assistant-token -w
```

Do not paste the token into chat, an Emacs eval form, a shell argument, the
clipboard history, or any captured tool output.

- [ ] **Step 5: Live-evaluate without restarting Emacs**

Load the verified source files and apply the configuration in the current
daemon:

```bash
music_config=/Users/marcosandrade/.dotfiles/.worktrees/music-assistant-emacs/macos/emacs/.emacs.d
emacsclient --eval "(progn
  (load-file \"$music_config/lisp/music-assistant-client.el\")
  (load-file \"$music_config/lisp/music-assistant.el\")
  (require 'savehist)
  (add-to-list 'savehist-additional-variables
               'music-assistant-last-player-id)
  (when (fboundp 'evil-set-initial-state)
    (evil-set-initial-state 'music-assistant-mode 'motion))
  'music-assistant-native-loaded)"
```

Expected: `music-assistant-native-loaded`. Do not restart or reload the
daemon.

- [ ] **Step 6: Run the live acceptance test in a separate Emacs client frame**

Open a dedicated frame:

```bash
emacsclient -c -n --eval "(music-assistant)"
```

Verify all of the following against live server state:

1. The header reaches connected/ready without blocking Emacs.
2. `P` selects `MrX.local` and the choice is remembered.
3. `s` searches for `Bladee` and returns track candidates.
4. Choosing a track replaces the selected queue and starts playback.
5. Queue/title/artwork/progress update from server events.
6. Space pauses playback and the paused state returns through an event.
7. `h`, `l`, `-`, `+`, `p`, `n`, `j`, `k`, and RET operate
   without errors.
8. `q` cleans up its client/timers without affecting the daemon or other
   frames.

Also verify from another client command that the main daemon remains
responsive:

```bash
emacsclient --eval '(list :responsive emacs-version)'
```

- [ ] **Step 7: Run fresh final verification and record status**

Repeat the dedicated ERT suite, complete configuration suite, byte compilation,
`git diff --check`, and `git status --short --branch`. Review the plan
against the spec line by line and record any unimplemented requirement before
claiming completion.

Commit any test-only correction exposed by the live smoke test with a focused
message after witnessing its failing and passing regression test.
