# SYZYGY Diff Review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a read-only, phone-first diff viewer for the latest turn initiated through SYZYGY and for the repository’s current staged, unstaged, and untracked changes.

**Architecture:** A new Go diff service captures the working tree before and after each phone-originated ACP prompt, stores the latest completed snapshot per session, and exposes both that immutable snapshot and a freshly computed repository review through one read-only HTTP endpoint. The existing vanilla HTML client renders the approved file list and wrapped diff reader, preserving scope, file, change, scroll position, and the line-number preference locally.

**Tech Stack:** Go 1.25, Git CLI, vanilla HTML/CSS/JavaScript, Node test runner, existing Chrome DevTools browser-test harness.

**Spec:** Approved Figma design in file `iUV2tD2yHjWE1sU5eEjcPb`: chat entry `58:200`, turn files `58:201`, repository files `58:203`, long-code reader `72:530`, gutter controls `79:1840`, context row `73:766`, removed row `73:826`, added row `73:1076`.

## Global Constraints

- The viewer never changes the working tree, Git index, or repository refs.
- `This turn` is available only for turns initiated through SYZYGY; other clients show `Snapshot unavailable` and never substitute the current repository diff.
- A completed turn snapshot is immutable even if the repository changes afterward; only the next completed SYZYGY turn replaces the session’s latest snapshot.
- `Before commit` is refreshed from the current repository and labels staged, unstaged, and untracked patches separately; a partially staged file appears in both staged and unstaged sections.
- Diff rows use one 24px line-number column: new-file numbers for context/additions and old-file numbers for removals. The 12px `+` / `-` marker remains visible when numbers are hidden.
- The `Hide numbers` preference persists across files, scopes, navigation, and reloads. Hiding it increases the code column from 301px to 329px at the 393px reference viewport.
- Code uses Iosevka Term Slab at 13px/18px, wraps within a row, and receives language-aware syntax colors while red/green row backgrounds and `+` / `-` markers remain redundant change cues.
- Every action has a minimum 44px touch target. File rows are full-width touch targets. The header and change navigation remain outside the scrolling diff viewport.
- Reuse the existing Gruvbox CSS variables and current single-file frontend. Add no runtime dependency and no generated asset.
- Preserve unrelated user work. Do not restart the main Emacs daemon.

## Review Focus

- Repositories with no commits yet must return a usable repository diff or a precise unavailable reason, not panic on `HEAD`.
- File names containing spaces, renames, deletions, binary files, and files lacking a final newline must not corrupt adjacent files or hunk line numbers.
- A partially staged file must produce two independently labeled patches; the unstaged patch must be relative to the index, not `HEAD`.
- Large output must stop at a fixed byte limit, mark the response truncated, and keep the JSON valid.
- A disconnect, cancellation, failed prompt, non-Git directory, or server restart during a turn must clean up the temporary capture and leave no false completed snapshot.

---

### Task 1: Parse and model unified diffs

**Files:**
- Create: `/Users/marcosandrade/src/acp-mobile/diff.go`
- Create: `/Users/marcosandrade/src/acp-mobile/diff_test.go`

**Interfaces:**
- Consumes: raw `git diff --no-color --no-ext-diff --unified=3` output plus a source label.
- Produces:

```go
type reviewLine struct {
    Kind string `json:"kind"` // context, added, removed, marker
    Old  int    `json:"old,omitempty"`
    New  int    `json:"new,omitempty"`
    Text string `json:"text"`
}

type reviewHunk struct {
    Header string       `json:"header"`
    Lines  []reviewLine `json:"lines"`
}

type reviewFile struct {
    Path       string       `json:"path"`
    OldPath    string       `json:"oldPath,omitempty"`
    Status     string       `json:"status"`
    Source     string       `json:"source"` // turn, staged, unstaged, untracked
    Added      int          `json:"added"`
    Removed    int          `json:"removed"`
    Binary     bool         `json:"binary,omitempty"`
    Hunks      []reviewHunk `json:"hunks,omitempty"`
}

type reviewResult struct {
    Scope       string       `json:"scope"`
    Repository  string       `json:"repository"`
    Branch      string       `json:"branch"`
    CapturedAt  time.Time    `json:"capturedAt"`
    Available   bool         `json:"available"`
    Pending     bool         `json:"pending,omitempty"`
    Reason      string       `json:"reason,omitempty"`
    Truncated   bool         `json:"truncated,omitempty"`
    Added       int          `json:"added"`
    Removed     int          `json:"removed"`
    Files       []reviewFile `json:"files"`
}

func parseUnifiedDiff(raw []byte, source string) ([]reviewFile, error)
```

- [ ] **Step 1: Write failing parser tests**

Add table-driven fixtures with literal expectations for context/add/remove numbering, a rename with spaces, deletion, `\\ No newline at end of file`, and `Binary files ... differ`. Each expected line number is written by hand.

- [ ] **Step 2: Verify the parser tests fail for the missing implementation**

Run: `cd /Users/marcosandrade/src/acp-mobile && go test ./... -run 'TestParseUnifiedDiff'`

Expected: build failure because `parseUnifiedDiff` and review types do not exist.

- [ ] **Step 3: Implement the minimal parser and summary accounting**

Parse `diff --git`, `---`/`+++`, and `@@ -old,count +new,count @@` boundaries. Increment old/new counters independently; additions consume only new, removals only old, context consumes both. Preserve code bytes as text and treat the no-newline record as a marker.

- [ ] **Step 4: Add a failing truncation test**

Feed a limit-aware reader more than `2 << 20` bytes and assert it returns valid partial data with `Truncated: true`, never a partial UTF-8 code point or malformed JSON.

- [ ] **Step 5: Implement bounded command output and rerun focused tests**

Run: `cd /Users/marcosandrade/src/acp-mobile && go test ./... -run 'TestParseUnifiedDiff|TestBoundedDiffOutput'`

Expected: PASS.

- [ ] **Step 6: Commit the parser slice**

```bash
git -C /Users/marcosandrade/src/acp-mobile add diff.go diff_test.go
git -C /Users/marcosandrade/src/acp-mobile commit -m "feat: parse reviewable git diffs"
```

### Task 2: Capture immutable turn snapshots and current repository state

**Files:**
- Modify: `/Users/marcosandrade/src/acp-mobile/diff.go`
- Modify: `/Users/marcosandrade/src/acp-mobile/diff_test.go`
- Modify: `/Users/marcosandrade/src/acp-mobile/main.go`

**Interfaces:**
- Consumes: a discovered live session PID or a phone `session/prompt` lifecycle already observed by `bridgeWebSocket`.
- Produces:

```go
type turnBaseline struct {
    SessionID string
    Root      string
    TempDir   string
    Tree      string
    StartedAt time.Time
}

func beginTurnReview(ctx context.Context, sessionID, socketPath string) (*turnBaseline, error)
func completeTurnReview(ctx context.Context, baseline *turnBaseline) (reviewResult, error)
func abortTurnReview(baseline *turnBaseline)
func repositoryReview(ctx context.Context, pid int) (reviewResult, error)
func handleDiffReview(w http.ResponseWriter, r *http.Request)
```

`GET /api/diff-review?scope=turn&sessionId=<id>` returns the latest saved snapshot or an explicit pending/unavailable state. `GET /api/diff-review?scope=repository&pid=<pid>` resolves the PID through the live socket catalogue and never accepts an arbitrary path.

- [ ] **Step 1: Write failing Git integration tests in temporary repositories**

Cover staged-only, unstaged-only, untracked, partially staged, rename, deletion, empty repository, non-Git directory, and a post-capture edit that must not alter the completed snapshot. Use real `git` commands against `t.TempDir()` repositories; do not mock Git output.

- [ ] **Step 2: Verify repository and snapshot tests fail**

Run: `cd /Users/marcosandrade/src/acp-mobile && go test ./... -run 'TestRepositoryReview|TestTurnReview'`

Expected: build failure because the review service does not exist.

- [ ] **Step 3: Implement read-only repository review**

Run staged diff against `HEAD`, unstaged diff against the index, and untracked files as `/dev/null` additions. Use `--no-color`, `--no-ext-diff`, `--unified=3`, and the fixed output limit. Resolve repository root and branch from Git. Return precise reasons for no Git repository and no changes.

- [ ] **Step 4: Implement temporary-object turn capture**

Create the baseline beneath `~/.acp-mobile/diff-captures/`. Use a temporary index and temporary object directory with the real repository object directory as an alternate: `git read-tree HEAD`, `git add -A`, `git write-tree`. At completion, write the after tree into the same temporary object database, diff the two trees, atomically save the parsed result beneath `~/.acp-mobile/turn-diffs/`, then remove the capture directory. This must not touch the real index or object database.

- [ ] **Step 5: Wire the ACP bridge lifecycle**

When `bridgeWebSocket` receives a live `session/prompt`, begin capture before forwarding it. When the matching JSON-RPC response arrives, complete capture asynchronously and then keep the saved result immutable. On disconnect, cancellation, prompt error, or shutdown, abort the baseline. Existing `phoneTurnStart`/`phoneTurnEnd` behavior remains unchanged.

- [ ] **Step 6: Add the read-only API route and handler tests**

Register `/api/diff-review`. Assert method validation, query validation, active-PID resolution, `Cache-Control: no-store`, pending state, unavailable state, and a complete structured response.

- [ ] **Step 7: Run focused and full backend tests**

Run: `cd /Users/marcosandrade/src/acp-mobile && go test ./... -run 'TestRepositoryReview|TestTurnReview|TestDiffReviewHandler|TestReconnect'`

Then: `cd /Users/marcosandrade/src/acp-mobile && go test ./...`

Expected: PASS with no failures.

- [ ] **Step 8: Commit the backend slice**

```bash
git -C /Users/marcosandrade/src/acp-mobile add diff.go diff_test.go main.go
git -C /Users/marcosandrade/src/acp-mobile commit -m "feat: capture turn and repository diffs"
```

### Task 3: Build the approved phone review flow

**Files:**
- Modify: `/Users/marcosandrade/src/acp-mobile/index.html`
- Modify: `/Users/marcosandrade/src/acp-mobile/index_test.mjs`
- Create: `/Users/marcosandrade/src/acp-mobile/diff_ui_test.go`

**Interfaces:**
- Consumes: `reviewResult` JSON from `/api/diff-review`.
- Produces these client entry points:

```javascript
const DIFF_LINE_NUMBERS_KEY = 'acp-diff-line-numbers';
function openDiffReview(scope) {}
function loadDiffReview(scope, options = {}) {}
function renderDiffFileList(result) {}
function openDiffFile(fileIndex, hunkIndex = 0) {}
function renderReviewLine(line, language) {}
function setDiffLineNumbers(visible) {}
function appendTurnReviewSummary() {}
```

- [ ] **Step 1: Write failing Node tests for rendering and state**

Extract the review block between stable source markers into the existing VM harness. Test literal behavior: one number per row, old number for removals, new number otherwise, `+`/`-` survives hidden numbers, unsafe code is escaped before highlighting, the local-storage default is shown, and the saved hidden preference restores.

- [ ] **Step 2: Verify the Node tests fail**

Run: `cd /Users/marcosandrade/src/acp-mobile && node --test index_test.mjs --test-name-pattern='diff review'`

Expected: FAIL because the review renderer and preference functions are absent.

- [ ] **Step 3: Add the review view and exact approved styling**

Add a hidden top-level review view with a 64px header, scope tabs, file list, fixed reader controls, 520px diff viewport at the reference size, and fixed change navigation. Use existing CSS variables. Rows use `display:flex; align-items:flex-start; gap:4px; padding:4px 8px`; number is `24px/12px/16px`, marker is `12px/13px/18px`, and code is `min-width:0; flex:1; white-space:pre-wrap; overflow-wrap:anywhere; font-size:13px; line-height:18px`.

- [ ] **Step 4: Implement safe syntax highlighting and file navigation**

Tokenize only after escaping source text. Support JavaScript/TypeScript, Go, Python, shell, Emacs Lisp, HTML/CSS, JSON, Markdown, and a plain-text fallback. Apply purple keywords, yellow callables, green strings, blue literals, and dim comments. Render every file and hunk returned by the server. Preserve scope, selected file, selected hunk, and per-file scroll position when returning to the list.

- [ ] **Step 5: Implement the line-number preference**

`Hide numbers` adds `.diff-numbers-hidden` to the review view, stores `false`, updates the accessible pressed state and label to `Show numbers`, and leaves markers in flow. The default code width at 393px is 301px with numbers and 329px without them.

- [ ] **Step 6: Wire both entry paths and unavailable states**

After a local prompt response with `stopReason`, append or update one `THIS TURN` summary card and poll pending capture briefly. Add `Before commit: review repository` above the composer. The turn tab shows a saved timestamp or `Snapshot unavailable`; repository refresh replaces data only after a successful response and otherwise leaves the reader intact with an error notice.

- [ ] **Step 7: Run Node tests**

Run: `cd /Users/marcosandrade/src/acp-mobile && node --test index_test.mjs`

Expected: PASS.

- [ ] **Step 8: Commit the client slice**

```bash
git -C /Users/marcosandrade/src/acp-mobile add index.html index_test.mjs
git -C /Users/marcosandrade/src/acp-mobile commit -m "feat: add phone diff review flow"
```

### Task 4: Prove phone behavior and finish documentation

**Files:**
- Modify: `/Users/marcosandrade/src/acp-mobile/diff_ui_test.go`
- Modify: `/Users/marcosandrade/src/acp-mobile/README.md`

**Interfaces:**
- Consumes: the real embedded page and deterministic `/api/diff-review` fixture responses.
- Produces: browser-level evidence at phone widths plus documented feature limits.

- [ ] **Step 1: Write failing browser tests against observable behavior**

At 393x852 and 320x700, serve a 152-line fixture. Assert file rows are at least 44px tall, the diff viewport scrolls independently, header and navigation stay fixed, long code wraps without horizontal overflow, hiding numbers increases code width while markers remain visible, the preference survives reload, staged/unstaged copies of one file remain separate, and Back restores the prior scroll position.

- [ ] **Step 2: Verify browser tests fail before any test-specific fixes**

Run: `cd /Users/marcosandrade/src/acp-mobile && go test ./... -run 'TestDiffReviewUI'`

Expected: FAIL on the first unmet geometry or interaction assertion.

- [ ] **Step 3: Make only behavior-driven fixes and rerun focused tests**

Run: `cd /Users/marcosandrade/src/acp-mobile && go test ./... -run 'TestDiffReviewUI'`

Expected: PASS.

- [ ] **Step 4: Document exact scope and failure behavior**

Add the diff viewer to README features. State that `This turn` covers SYZYGY-originated turns, `Before commit` includes every current repository source, snapshots store the latest completed phone turn per session, and binary/oversized/unavailable results are labeled rather than rendered as normal text.

- [ ] **Step 5: Run final verification**

```bash
cd /Users/marcosandrade/src/acp-mobile
gofmt -w diff.go diff_test.go diff_ui_test.go main.go
go test ./...
node --test index_test.mjs
go vet ./...
git diff --check
git status --short
```

Inspect fresh 393x852 screenshots for file list, numbered reader, hidden-number reader, and the 152-line long-code fixture. Confirm no horizontal page overflow and no clipped row text.

- [ ] **Step 6: Commit final tests and docs**

```bash
git -C /Users/marcosandrade/src/acp-mobile add diff_ui_test.go README.md
git -C /Users/marcosandrade/src/acp-mobile commit -m "test: verify mobile diff review"
```

## Plan Self-Review

- Spec coverage: both scopes, immutable turn semantics, staged/unstaged separation, long-code wrapping, syntax color, persistent single-column gutter, navigation, refresh, and unavailable states are assigned to tasks.
- Placeholder scan: no `TBD`, `TODO`, deferred implementation, or unnamed error handling remains.
- Type consistency: `reviewResult`, `reviewFile`, `reviewHunk`, and `reviewLine` are defined once in Task 1 and consumed unchanged by Tasks 2–4.
- Review focus coverage: empty repositories, path edge cases, partial staging, output limits, and interrupted captures each have an owning test step.
- Scope: one Go service and one existing frontend; no Emacs, acp-multiplex, staging, commit, or repository-write feature is introduced.
