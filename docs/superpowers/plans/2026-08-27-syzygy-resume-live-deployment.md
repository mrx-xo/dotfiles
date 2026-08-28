# Syzygy Resume History Live Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy the already-implemented History → Resume feature directly into the existing production Syzygy app on port `8090`, verify it from the current phone home-screen app, and preserve an exact rollback path.

**Architecture:** Keep the current single-instance architecture. Build the reviewed `acp-mobile` feature commit from its clean worktree, atomically replace the installed production binary, idempotently load the matching Syzygy Elisp into the existing Emacs daemon, and restart the existing launchd job. Do not create a test PWA, second port, controller service, or additional launch agent.

**Tech Stack:** Go 1.25, embedded vanilla HTML/CSS/JavaScript, Emacs Lisp/ERT, `agent-shell`, `agent-recall`, launchd, Tailscale HTTP/WebSocket access.

**Spec:** [`docs/superpowers/plans/2026-08-27-syzygy-resume-live-deployment.md#approved-scope`](./2026-08-27-syzygy-resume-live-deployment.md#approved-scope)

## Global Constraints

- The dedicated “Syzygy Test” app proposal is cancelled. Do not implement it.
- Use the existing production service, URL, auth state, home-screen icon, launchd label, and port `8090`.
- The feature implementation already exists. Do not rewrite it unless a reproducible failing test demonstrates a defect.
- Dotfiles feature implementation commit: `44b31d35bd0e6b9be31da3267166b3ef11a0474c`.
- `acp-mobile` feature implementation commit: `d9a88b2aa24823f7f1784cc7ef2126e1fbdf5cc0`.
- Do not modify, clean, stash, reset, merge, or commit the dirty primary dotfiles checkout at `/Users/marcosandrade/.dotfiles`.
- Do not modify the primary `acp-mobile` checkout at `/Users/marcosandrade/src/acp-mobile`.
- Do not merge or push either feature branch without separate user authorization.
- Do not run `macos/syzygy/build-acp-tools.sh`; it checks out revisions in the primary source repositories and also rebuilds `acp-multiplex`, which is outside this deployment.
- Back up the installed binary before replacing it. Never overwrite an existing backup directory.
- Never print, log, paste, or commit the contents of `/Users/marcosandrade/.acp-mobile/authkey` or an authenticated Syzygy URL.
- Do not automatically resume a transcript or send an agent message during machine verification. The user performs the final phone action.
- Do not kill, resync, reload, or restart existing agent buffers as part of this deployment.
- Treat the missing live-session socket problem as a separate issue. It must not be fixed, hidden, or counted as a regression in this task.
- If any deployment-critical precondition differs from the documented baseline, stop before mutation and report the difference. The dirty primary checkouts and live-session count are context, not deployment gates.
- After Task 3 replaces the binary, use `superpowers:systematic-debugging` for any failed health check and run Task 6 if the new binary or feature path is unhealthy. Do not roll back for the separately documented missing-socket symptom alone.
- Before claiming completion, invoke `superpowers:verification-before-completion` and rerun the final verification commands.

---

## Approved Scope

The user explicitly chose direct live deployment over a parallel test environment. The existing production Syzygy app becomes the test surface:

1. Preserve the installed binary for rollback.
2. Re-run the feature-specific verification suites.
3. Build `acp-mobile` from the reviewed feature worktree.
4. Atomically install it over `/Users/marcosandrade/.local/bin/acp-mobile`.
5. Load the matching feature Elisp into the live Emacs daemon.
6. Restart `com.marcosandrade.acp-mobile` only.
7. Verify the production API over loopback and the Tailscale hostname.
8. Ask the user to test History → Resume from the existing phone icon.

This is a live deployment, not a permanent branch integration. The feature branches remain isolated until the user separately approves merging them.

## Current Ground Truth

Reconfirm the deployment-critical facts used by the commands below at execution time. The primary-checkout and live-session rows are contextual boundaries and may change independently:

| Component | Observed state |
|---|---|
| Dotfiles feature worktree | `/Users/marcosandrade/.dotfiles/.worktrees/syzygy-resume-history`, branch `codex/syzygy-resume-history`, implementation commit `44b31d3` |
| Mobile feature worktree | `/Users/marcosandrade/src/acp-mobile/.worktrees/syzygy-resume-history`, branch `codex/syzygy-resume-history`, clean at `d9a88b2` |
| Primary dotfiles checkout | `main` at `3d58093`, dirty with unrelated user work |
| Primary mobile checkout | clean `syzygy` at `ffe4bde` |
| Installed production binary | VCS base `b34c6f0dab56e91e4781dffe451ade987f733884`, `vcs.modified=true` |
| Installed binary SHA-256 | `fd1d2d0a79403f70ac27c8695e4352ead25e1c5ea2a90427645f8d93ee75a2d0` |
| Current production UI build ID | `1277eedc` |
| Feature UI build ID | `1fa32fc1` |
| Current resume HTTP endpoint | `GET /api/resume-transcript` returns `404` because the feature binary is not installed |
| Live Emacs daemon | Feature functions and both strict-resume advices are already loaded; pending resume-operation count was zero |
| Production launchd service | `com.marcosandrade.acp-mobile` running `/Users/marcosandrade/.local/bin/acp-mobile 8090` |
| History API | Healthy; returns 100 indexed transcripts |
| Live Sessions API | Currently returns only one session because older Unix socket pathnames disappeared |

The interrupted deployment attempt made no production change: the installed binary metadata, modification time, service process, and HTTP build ID remained at the baseline above.

## Known Separate Production Issue

Emacs has multiple live agent buffers, but most corresponding `acp-multiplex` processes have had their filesystem socket names unlinked from:

```text
/var/folders/00/bj21r0n56jq_gsk2q47gk3jw0000gn/T/acp-multiplex/
```

The processes remain alive, but `acp-mobile` discovers sessions by enumerating `*.sock`; therefore those conversations are absent from the Sessions screen. History is unaffected. The exact unlinking actor was not proven, though the use of macOS temporary storage permits cleanup underneath long-lived processes.

Do not use the number of live session cards as a deployment health assertion. Do not resync buffers in this task. A durable socket-location/self-healing fix belongs in a separate plan for `acp-multiplex`.

## File and Responsibility Map

### Dotfiles worktree

- `macos/emacs/.emacs.d/lisp/syzygy/syzygy-recall.el` — validates indexed transcripts, maps transcript agent configs, starts or reuses the exact archived session, guards against `session/new` fallback, and exposes asynchronous JSON start/status functions.
- `macos/emacs/.emacs.d/lisp/syzygy/syzygy.el` — configures automatic preference restoration for phone-initiated resumes.
- `macos/emacs/.emacs.d/tests/syzygy-recall-tests.el` — 11 focused ERT tests for readiness, strict identity, pending operations, ownership, cleanup, timeouts, and errors.
- `macos/syzygy/build-acp-tools.sh` — pins `acp-mobile` to `d9a88b2`; syntax-check it, but do not execute it for this deployment.

### Mobile worktree

- `main.go:305` — registers `POST /api/resume-transcript`.
- `main.go:975` and `main.go:983` — define the resume response contract and the context-bound Emacs start/status polling handler.
- `main_test.go:210` — covers an unavailable transcript response; adjacent tests cover success, pending polling, failures, timeouts, and command cancellation.
- `index.html:4073` — owns the History Resume button state.
- `index.html:4195` — renders unavailable reasons.
- `index.html:4224` — starts resume, handles stale-view cancellation, and selects the exact returned buffer.
- `index_test.mjs:111` — browser-contract fixtures and five UI tests.

### Runtime artifacts

- `/Users/marcosandrade/.local/bin/acp-mobile` — production binary to replace atomically.
- `/Users/marcosandrade/.local/state/syzygy-deployments/pre-resume-d9a88b2/acp-mobile` — required rollback copy created by this plan.
- `/Users/marcosandrade/.acp-mobile/authkey` — existing secret; read only into a shell variable.
- `/Users/marcosandrade/.acp-mobile/link` — existing authenticated phone URL; restart should rewrite the same host/port/key combination.
- `/Users/marcosandrade/Library/Logs/acp-mobile/acp-mobile.err.log` — production service log; redact `authkey=` values before displaying output.
- `/Users/marcosandrade/Library/LaunchAgents/com.marcosandrade.acp-mobile.plist` — existing service definition; do not edit or reinstall it.

## Runtime Interfaces

- `syzygy-recall-resume-json(FILE_BASE64) -> JSON string`: returns either a ready result, a failed result, or a pending operation token without blocking Emacs for the full provider startup window.
- `syzygy-recall-resume-status-json(OPERATION_BASE64) -> JSON string`: polls the exact pending operation.
- `POST /api/resume-transcript` with JSON body `{"file":"<absolute indexed transcript path>"}`: invokes the start function, polls pending status under one request deadline, and returns the exact `bufferName` on success.
- Transcript list entries contain `resumable: boolean` and `resumeReason: string`.
- A successful browser resume closes History and selects the returned live buffer. Repeating the same resume reuses the matching buffer instead of creating `<2>`.

---

### Task 1: Reconfirm Source and Runtime Preconditions

**Files:**
- Read: `/Users/marcosandrade/.dotfiles/.worktrees/syzygy-resume-history`
- Read: `/Users/marcosandrade/src/acp-mobile/.worktrees/syzygy-resume-history`
- Read: `/Users/marcosandrade/.local/bin/acp-mobile`
- Read: `/Users/marcosandrade/.acp-mobile/authkey`

**Interfaces:**
- Consumes: the two reviewed feature commits and the currently installed production binary.
- Produces: a go/no-go decision and an immutable production rollback copy.

- [ ] **Step 1: Verify both feature commits are present and both worktrees are clean**

```bash
set -euo pipefail
dotfiles_feature=/Users/marcosandrade/.dotfiles/.worktrees/syzygy-resume-history
mobile_feature=/Users/marcosandrade/src/acp-mobile/.worktrees/syzygy-resume-history

git -C "$dotfiles_feature" merge-base --is-ancestor \
  44b31d35bd0e6b9be31da3267166b3ef11a0474c HEAD
test -z "$(git -C "$dotfiles_feature" status --porcelain)"

test "$(git -C "$mobile_feature" rev-parse HEAD)" = \
  d9a88b2aa24823f7f1784cc7ef2126e1fbdf5cc0
test -z "$(git -C "$mobile_feature" status --porcelain)"
```

Expected: every command exits `0`. The dotfiles HEAD may include this documentation commit, so test ancestry rather than exact HEAD equality.

- [ ] **Step 2: Verify production still matches the pre-deployment binary baseline**

```bash
set -euo pipefail
go version -m /Users/marcosandrade/.local/bin/acp-mobile
shasum -a 256 /Users/marcosandrade/.local/bin/acp-mobile
```

Expected: VCS revision `b34c6f0dab56e91e4781dffe451ade987f733884`, `vcs.modified=true`, and SHA-256 `fd1d2d0a79403f70ac27c8695e4352ead25e1c5ea2a90427645f8d93ee75a2d0`.

If any value differs, do not overwrite the binary. Report that production changed after this plan was written and establish a new rollback baseline with the user.

- [ ] **Step 3: Verify the service and HTTP baseline without exposing the auth key**

```bash
set -euo pipefail
user_uid=$(id -u)
launchctl print "gui/${user_uid}/com.marcosandrade.acp-mobile" | \
  rg 'state =|pid =|runs =|last exit code'

acp_auth=$(tr -d '\r\n' < /Users/marcosandrade/.acp-mobile/authkey)

sessions_json=$(curl -fsS --max-time 10 -X POST \
  -H "Cookie: authkey=${acp_auth}" \
  http://127.0.0.1:8090/api/sessions)
printf '%s' "$sessions_json" | jq -e '.version == "1277eedc"'

resume_code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
  -H "Cookie: authkey=${acp_auth}" \
  http://127.0.0.1:8090/api/resume-transcript)
test "$resume_code" = 404
```

Expected: launchd is running, the UI build ID is `1277eedc`, and the resume route is absent (`404`).

- [ ] **Step 4: Capture the live Elisp baseline and refuse to proceed during an active resume operation**

```bash
set -euo pipefail
emacsclient --eval "
(list
 :resume-json (fboundp 'syzygy-recall-resume-json)
 :resume-status (fboundp 'syzygy-recall-resume-status-json)
 :guard-handle (not (null
   (advice-member-p #'syzygy-recall--arm-strict-resume
                    'agent-shell--handle)))
 :guard-new-session (not (null
   (advice-member-p #'syzygy-recall--guard-new-session
                    'agent-shell--initiate-new-session)))
 :pending (if (boundp 'syzygy-recall--resume-operations)
              (hash-table-count syzygy-recall--resume-operations)
            0))"
```

Expected for the current daemon: both functions and both guards are non-nil, and `:pending` is `0`. Record this output because rollback must restore the observed baseline, not an assumed one.

- [ ] **Step 5: Create the durable binary rollback copy**

```bash
set -euo pipefail
rollback_dir=/Users/marcosandrade/.local/state/syzygy-deployments/pre-resume-d9a88b2
baseline_sha=fd1d2d0a79403f70ac27c8695e4352ead25e1c5ea2a90427645f8d93ee75a2d0

if test -e "$rollback_dir"; then
  test -x "$rollback_dir/acp-mobile"
else
  mkdir -p "$rollback_dir"
  cp -p /Users/marcosandrade/.local/bin/acp-mobile "$rollback_dir/acp-mobile"
fi

cmp -s /Users/marcosandrade/.local/bin/acp-mobile "$rollback_dir/acp-mobile"
test "$(shasum -a 256 "$rollback_dir/acp-mobile" | awk '{print $1}')" = \
  "$baseline_sha"
```

Expected: a new backup is created, or an already-present exact backup is safely reused after byte-for-byte and hash verification. Never remove or overwrite this directory during the deployment.

No repository commit is required for this task; it creates a local recovery artifact only.

---

### Task 2: Re-run the Reviewed Feature Verification

**Files:**
- Test: `macos/emacs/.emacs.d/tests/syzygy-recall-tests.el`
- Test: `main_test.go`
- Test: `index_test.mjs`
- Read: `macos/syzygy/build-acp-tools.sh`

**Interfaces:**
- Consumes: implementation commits `44b31d3` and `d9a88b2`.
- Produces: fresh evidence that the exact source to deploy remains green.

- [ ] **Step 1: Run the 11 focused ERT tests**

```bash
set -euo pipefail
dotfiles_feature=/Users/marcosandrade/.dotfiles/.worktrees/syzygy-resume-history

/opt/homebrew/opt/emacs-plus@30/bin/emacs --batch -Q \
  -L "$dotfiles_feature/macos/emacs/.emacs.d/lisp/syzygy" \
  -l "$dotfiles_feature/macos/emacs/.emacs.d/tests/syzygy-recall-tests.el" \
  -f ert-run-tests-batch-and-exit
```

Expected: `11` tests run and all `11` pass.

- [ ] **Step 2: Run the mobile race-enabled Go suite**

```bash
set -euo pipefail
cd /Users/marcosandrade/src/acp-mobile/.worktrees/syzygy-resume-history
go test -race -count=1 ./...
```

Expected: exit `0`. The intentionally skipped external integration tests remain skipped.

- [ ] **Step 3: Run static analysis and the browser contract directly**

```bash
set -euo pipefail
cd /Users/marcosandrade/src/acp-mobile/.worktrees/syzygy-resume-history
go vet ./...
node --test index_test.mjs
```

Expected: `go vet` exits `0`; Node reports five passing tests and no failures.

- [ ] **Step 4: Run source hygiene checks**

```bash
set -euo pipefail
git -C /Users/marcosandrade/.dotfiles/.worktrees/syzygy-resume-history \
  diff --check 3d5809364ca877200d1218b1d44bd14e851e53c7..44b31d35bd0e6b9be31da3267166b3ef11a0474c

git -C /Users/marcosandrade/src/acp-mobile/.worktrees/syzygy-resume-history \
  diff --check ffe4bdea462d01d45817a986a2a568746ce364b4..d9a88b2aa24823f7f1784cc7ef2126e1fbdf5cc0

bash -n /Users/marcosandrade/.dotfiles/.worktrees/syzygy-resume-history/macos/syzygy/build-acp-tools.sh
```

Expected: all commands exit `0` with no output.

If a check fails, stop deployment and use `superpowers:systematic-debugging`. Do not patch production or bundle unrelated cleanup.

No repository commit is required: the tested implementation is already committed.

---

### Task 3: Build and Atomically Install the Feature Binary

**Files:**
- Read/build: `/Users/marcosandrade/src/acp-mobile/.worktrees/syzygy-resume-history`
- Replace: `/Users/marcosandrade/.local/bin/acp-mobile`

**Interfaces:**
- Consumes: clean mobile commit `d9a88b2` and the rollback copy from Task 1.
- Produces: an installed executable whose embedded VCS revision is `d9a88b2` and whose embedded UI build ID is `1fa32fc1`.

- [ ] **Step 1: Build, verify, and atomically install in one shell invocation**

```bash
set -euo pipefail
mobile_feature=/Users/marcosandrade/src/acp-mobile/.worktrees/syzygy-resume-history
rollback_dir=/Users/marcosandrade/.local/state/syzygy-deployments/pre-resume-d9a88b2
candidate_bin=$(mktemp /Users/marcosandrade/.local/bin/.acp-mobile.resume-d9a88b2.XXXXXX)

cleanup_candidate() {
  if test -n "${candidate_bin:-}" && test -e "$candidate_bin"; then
    rm -f -- "$candidate_bin"
  fi
}
trap cleanup_candidate EXIT HUP INT TERM

test -x "$rollback_dir/acp-mobile"
cd "$mobile_feature"
go build -trimpath -o "$candidate_bin" .
chmod 0755 "$candidate_bin"

candidate_metadata=$(go version -m "$candidate_bin")
printf '%s\n' "$candidate_metadata" | \
  rg 'vcs.revision=d9a88b2aa24823f7f1784cc7ef2126e1fbdf5cc0'
if printf '%s\n' "$candidate_metadata" | rg -q 'vcs.modified=true'; then
  exit 1
fi

test "$(shasum -a 256 "$mobile_feature/index.html" | awk '{print substr($1,1,8)}')" = \
  1fa32fc1

mv -f -- "$candidate_bin" \
  /Users/marcosandrade/.local/bin/acp-mobile
candidate_bin=
trap - EXIT HUP INT TERM
```

Expected: every command exits `0`. A clean build reports revision `d9a88b2` without `vcs.modified=true`; the installed path then contains the feature binary. Building the candidate in `/Users/marcosandrade/.local/bin` guarantees that the final rename is on the destination filesystem. The running launchd process still uses the prior inode until Task 4 restarts it.

No repository commit is required; this task installs a previously committed build artifact.

---

### Task 4: Load Matching Elisp and Restart Only Syzygy

**Files:**
- Load: `macos/emacs/.emacs.d/lisp/syzygy/syzygy-recall.el`
- Load: `macos/emacs/.emacs.d/lisp/syzygy/syzygy.el`
- Restart: `com.marcosandrade.acp-mobile`

**Interfaces:**
- Consumes: installed feature binary and the live Emacs daemon.
- Produces: matching Go/UI and Elisp feature versions reachable through production port `8090`.

- [ ] **Step 1: Idempotently load the reviewed Elisp into the running daemon**

```bash
set -euo pipefail
emacsclient --eval "
(progn
  (load-file
   \"/Users/marcosandrade/.dotfiles/.worktrees/syzygy-resume-history/macos/emacs/.emacs.d/lisp/syzygy/syzygy-recall.el\")
  (load-file
   \"/Users/marcosandrade/.dotfiles/.worktrees/syzygy-resume-history/macos/emacs/.emacs.d/lisp/syzygy/syzygy.el\")
  (list
   :resume-json (fboundp 'syzygy-recall-resume-json)
   :resume-status (fboundp 'syzygy-recall-resume-status-json)
   :guard-handle (not (null
     (advice-member-p #'syzygy-recall--arm-strict-resume
                      'agent-shell--handle)))
   :guard-new-session (not (null
     (advice-member-p #'syzygy-recall--guard-new-session
                      'agent-shell--initiate-new-session)))
   :pending (hash-table-count syzygy-recall--resume-operations)))"
```

Expected: both functions and guards are non-nil and `:pending` is `0`. Advice registration is guarded by `advice-member-p`, so reloading must not duplicate advice.

- [ ] **Step 2: Restart the existing production launchd job**

```bash
set -euo pipefail
user_uid=$(id -u)
launchctl kickstart -k "gui/${user_uid}/com.marcosandrade.acp-mobile"
```

Expected: only `acp-mobile` restarts. Emacs and all agent processes remain untouched.

- [ ] **Step 3: Wait on HTTP readiness by condition, not a fixed delay**

```bash
set -euo pipefail
acp_auth=$(tr -d '\r\n' < /Users/marcosandrade/.acp-mobile/authkey)
sessions_json=

for attempt in $(seq 1 50); do
  if sessions_json=$(curl -fsS --max-time 2 -X POST \
      -H "Cookie: authkey=${acp_auth}" \
      http://127.0.0.1:8090/api/sessions); then
    break
  fi
  sleep 0.2
done

test -n "$sessions_json"
printf '%s' "$sessions_json" | jq -e '.version == "1fa32fc1"'
```

Expected: the service becomes ready within ten seconds and reports feature UI build `1fa32fc1`.

- [ ] **Step 4: Verify the endpoint exists without starting a resume**

```bash
set -euo pipefail
acp_auth=$(tr -d '\r\n' < /Users/marcosandrade/.acp-mobile/authkey)

resume_code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
  -H "Cookie: authkey=${acp_auth}" \
  http://127.0.0.1:8090/api/resume-transcript)

test "$resume_code" = 405
```

Expected: `405 Method Not Allowed`, proving the registered POST handler answered. Do not POST a transcript during automated verification.

- [ ] **Step 5: Verify History data and remote Tailscale routing**

```bash
set -euo pipefail
acp_auth=$(tr -d '\r\n' < /Users/marcosandrade/.acp-mobile/authkey)

history_json=$(curl -fsS --max-time 20 -X POST \
  -H "Cookie: authkey=${acp_auth}" \
  http://127.0.0.1:8090/api/transcripts)

printf '%s' "$history_json" | jq -e '
  type == "array" and
  length > 0 and
  all(.[]; has("resumable") and has("resumeReason"))'

remote_sessions=$(curl -fsS --max-time 15 -X POST \
  -H "Cookie: authkey=${acp_auth}" \
  http://mrx.tail9179e0.ts.net:8090/api/sessions)

printf '%s' "$remote_sessions" | jq -e '.version == "1fa32fc1"'
```

Expected: History is populated with readiness fields and the same feature build is reachable over the phone’s Tailscale hostname.

- [ ] **Step 6: Inspect only sanitized startup logs**

```bash
set -euo pipefail
tail -n 80 /Users/marcosandrade/Library/Logs/acp-mobile/acp-mobile.err.log | \
  sed -E 's/(authkey=)[0-9a-f]+/\1[REDACTED]/g'
```

Expected: a normal startup line for port `8090` and the Tailscale address, with no panic or bind failure.

Do not fail deployment merely because `/api/sessions` contains one card; that is the documented socket-discovery issue.

No repository commit is required.

---

### Task 5: Run the Phone Acceptance Check

**Files:**
- No file changes.
- User surface: existing Syzygy home-screen app and production URL.

**Interfaces:**
- Consumes: healthy feature build `1fa32fc1` and loaded resume Elisp.
- Produces: user-confirmed end-to-end evidence for exact transcript continuation.

- [ ] **Step 1: Ask the user to close and reopen the existing Syzygy home-screen app**

Expected: the embedded build watcher or a fresh launch loads the new UI. Do not ask the user to install another icon or use another port.

- [ ] **Step 2: Ask the user to open History and choose a memorable resumable Claude or Codex transcript**

Expected: the transcript detail view shows an enabled `resume` button. Unavailable entries show a disabled button and a reason.

- [ ] **Step 3: Ask the user to tap Resume once**

Expected within the request deadline:

- History closes.
- The exact returned conversation becomes the active chat.
- Restored conversation context is visible.
- A corresponding Emacs agent buffer exists.
- No message needs to be sent; avoiding a follow-up keeps provider cost and transcript mutation minimal.

- [ ] **Step 4: Ask the user to resume the same transcript a second time**

Expected: Syzygy returns to the same live buffer. It must not create a duplicate buffer with a `<2>` suffix.

- [ ] **Step 5: Recheck that no resume operation remains pending**

```bash
set -euo pipefail
emacsclient --eval "
(if (boundp 'syzygy-recall--resume-operations)
    (hash-table-count syzygy-recall--resume-operations)
  0)"
```

Expected: `0` after the operation settles.

If the phone test fails, capture the exact visible error and sanitized server log evidence, then use `superpowers:systematic-debugging`. Do not immediately roll back solely because unrelated old live sessions remain absent.

No repository commit is required.

---

### Task 6: Execute Rollback Only if the Feature Deployment Fails

**Files:**
- Restore: `/Users/marcosandrade/.local/bin/acp-mobile`
- Read: `/Users/marcosandrade/.local/state/syzygy-deployments/pre-resume-d9a88b2/acp-mobile`
- Preserve: the live Elisp baseline captured in Task 1.

**Interfaces:**
- Consumes: Task 1’s exact binary and Elisp baselines.
- Produces: the pre-deployment production runtime without restarting Emacs or agent sessions.

- [ ] **Step 1: Ensure no resume operation is still active before rollback**

```bash
set -euo pipefail
emacsclient --eval "
(if (boundp 'syzygy-recall--resume-operations)
    (hash-table-count syzygy-recall--resume-operations)
  0)"
```

Expected: `0`. If nonzero, wait for the operation to settle or ask the user; do not kill the buffer or daemon.

- [ ] **Step 2: Atomically restore the exact saved binary**

```bash
set -euo pipefail
rollback_dir=/Users/marcosandrade/.local/state/syzygy-deployments/pre-resume-d9a88b2
test -x "$rollback_dir/acp-mobile"

install -m 0755 "$rollback_dir/acp-mobile" \
  /Users/marcosandrade/.local/bin/.acp-mobile.rollback.new

cmp -s "$rollback_dir/acp-mobile" \
  /Users/marcosandrade/.local/bin/.acp-mobile.rollback.new

mv -f /Users/marcosandrade/.local/bin/.acp-mobile.rollback.new \
  /Users/marcosandrade/.local/bin/acp-mobile

user_uid=$(id -u)
launchctl kickstart -k "gui/${user_uid}/com.marcosandrade.acp-mobile"
```

Expected: production returns to the binary captured before deployment.

- [ ] **Step 3: Verify the restored HTTP build**

```bash
set -euo pipefail
acp_auth=$(tr -d '\r\n' < /Users/marcosandrade/.acp-mobile/authkey)
sessions_json=

for attempt in $(seq 1 50); do
  if sessions_json=$(curl -fsS --max-time 2 -X POST \
      -H "Cookie: authkey=${acp_auth}" \
      http://127.0.0.1:8090/api/sessions); then
    break
  fi
  sleep 0.2
done

printf '%s' "$sessions_json" | jq -e '.version == "1277eedc"'
```

Expected for the documented baseline: build `1277eedc`.

- [ ] **Step 4: Preserve the recorded Elisp baseline**

Task 1 requires both feature functions and both strict-resume guards to be loaded before any mutation. Therefore rollback leaves that Elisp loaded, restoring the actual pre-deployment state. Do not load files from the dirty primary dotfiles checkout, remove advice, or restart the Emacs daemon; any of those actions could disturb unrelated user work or live sessions. If Task 1 observes a different Elisp baseline, the global precondition requires stopping before deployment and revising this rollback procedure with the user.

No repository commit is required.

---

### Task 7: Final Verification and Handoff

**Files:**
- Read: both feature worktrees and production runtime.
- Do not modify source files.

**Interfaces:**
- Consumes: successful phone acceptance or completed rollback.
- Produces: an evidence-based completion report and preserved source branches.

- [ ] **Step 1: Invoke `superpowers:verification-before-completion`**

Follow that skill before making any success claim.

- [ ] **Step 2: On success, rerun the concise production checks**

```bash
set -euo pipefail
go version -m /Users/marcosandrade/.local/bin/acp-mobile | \
  rg 'vcs.revision=d9a88b2aa24823f7f1784cc7ef2126e1fbdf5cc0'

acp_auth=$(tr -d '\r\n' < /Users/marcosandrade/.acp-mobile/authkey)

curl -fsS --max-time 10 -X POST \
  -H "Cookie: authkey=${acp_auth}" \
  http://127.0.0.1:8090/api/sessions | \
  jq -e '.version == "1fa32fc1"'

resume_code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' \
  -H "Cookie: authkey=${acp_auth}" \
  http://127.0.0.1:8090/api/resume-transcript)
test "$resume_code" = 405

test -z "$(git -C /Users/marcosandrade/src/acp-mobile/.worktrees/syzygy-resume-history status --porcelain)"
```

Expected: deployed revision `d9a88b2`, UI build `1fa32fc1`, registered resume handler, and a clean mobile worktree.

- [ ] **Step 3: Report exact evidence and remaining boundaries**

The final report must include:

- Whether deployment succeeded or was rolled back.
- Deployed and prior binary revisions/build IDs.
- Commands/tests rerun and their observed results.
- The durable rollback directory path.
- The user’s phone acceptance result.
- Confirmation that no branch was merged or pushed.
- Confirmation that no agent buffer was killed/resynced.
- A reminder that missing live session cards are a separate socket-discovery issue.
- A reminder that the live Elisp is loaded from the feature worktree and will not survive an Emacs restart until the user authorizes branch integration.

No repository commit is required from the executing agent unless it discovers and fixes a separately approved, test-reproduced defect.
