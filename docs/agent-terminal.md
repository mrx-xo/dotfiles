# Agent Terminal — User Guide

Watch every Bash command your Claude agents run, live, in a real terminal —
and optionally type into the same shell they're using.

Three independent layers. Each works alone; they stack. PRD with full design
history: `docs/agent-terminal-prd.md`. Repeatable smoke tests:
`macos/scripts/agent-terminal-test.sh` (see [Testing](#testing)).

---

## TL;DR

```
M-x agent-terminal-demo    the guided tour: opens BOTH views side by side and
                           runs real commands through the wrapper — watch them
                           type into the pane while the observer logs them.
                           Everything stays open; the pane is a real shell.

SPC c L        LIVE mode, one gesture: interception ON + observer + pane in
               bottom side windows. Again: everything OFF (tmux session survives).
C-u SPC c L    same, but popped into its own frame — its own OS window,
               tiled by yabai (throw it on another monitor/space)

SPC c v        toggle the observer buffer (always-on feed, read-only)
SPC c V        attach the tmux pane (watch/type, only useful when intercepting)
C-u SPC c V    toggle tmux interception on/off (takes effect next tool call)
```

`SPC c L` couples the machine-wide flag to the windows on purpose; the
granular toggles below still work independently (e.g. close the viewer
without stopping interception).

Layer 3 (ACP channel) has no keys — it's automatic for new agent-shell
sessions and only shows itself as `✗ exit N` badges on failed commands.

---

## Layer 1 — Observer buffer (always on)

**What:** read-only `*agent-terminal*` buffer showing every Bash command from
**every** Claude session on this machine — agent-shell, `claude` in ghostty,
headless runs. Command appears when execution starts, output when it finishes.

**Use:** `SPC c v` toggles it in a bottom side window. `M-x agent-terminal-clear`
wipes it. Sessions get dim `── 1a2b3c4d · ~/dir ──` separators; interleaved
output gets `↳ 1a2b3c4d:` attribution.

**How it works:**

```
any Claude session runs Bash
  → PreToolUse/PostToolUse hooks (~/.claude/settings.json, matcher "Bash")
  → macos/scripts/agent-terminal-hook.sh {pre|post}
      jq-distills the hook JSON, base64s it, backgrounds an emacsclient call
  → (agent-terminal--ingest "<b64>") in the daemon
  → lisp/agent-terminal.el renders into *agent-terminal*
```

Fire-and-forget: ~11ms overhead, a dead Emacs daemon can never block or fail
an agent's tool call.

**Enable / disable:** it's on wherever the two hook entries exist in
`~/.claude/settings.json` (`PreToolUse`/`PostToolUse`, matcher `Bash`).
That file is per-machine and untracked — **MrX2 needs the entries merged by
hand** to get the observer there. Remove the entries to kill the layer.

**Troubleshooting:** nothing appearing → is the daemon up, and is
`agent-terminal--ingest` defined (`emacsclient --eval "(fboundp
'agent-terminal--ingest)"`)? Raw hook payload debugging: `touch
~/.claude/agent-terminal-debug`, run a command, inspect
`/tmp/agent-terminal/last-{pre,post}.json`, remove the flag when done.

---

## Layer 2 — tmux interception (opt-in, "watch mode")

**What:** agent Bash commands *actually execute* inside tmux session `agent`.
You watch them get typed and run in a real PTY — live output, real colors —
and you can type into that same shell between the agent's commands (same cwd,
same env). The agent receives normal stdout + exit codes and notices nothing.

**Enable:** `C-u SPC c V` (or `M-x mr-x/agent-tmux-toggle`). Creates
`~/.claude/agent-tmux-enabled`; the PreToolUse hook starts rewriting from the
**next** tool call — no restarts. Same toggle turns it off; everything
reverts instantly.

**Watch:** `SPC c V` attaches a vterm to the session in a side window
(`tmux attach -t agent` from any terminal works too). Or skip the
piecemeal setup entirely: `SPC c L` flips the flag AND opens observer +
pane together; `C-u SPC c L` puts the pair in a dedicated frame instead
(found again at teardown via its `agent-terminal-live` frame parameter,
so renaming the frame can't orphan it).

> Frame-pop implementation note: on this daemon a fresh frame is born
> already split (persp/popper hooks run *inside* `make-frame`), so the
> code works from `frame-selected-window` with `ignore-window-parameters`
> bound — never `frame-root-window`, which is a dead internal parent
> window there. Full story: [Frame-pop bug ledger](#frame-pop-bug-ledger-2026-07-27).

**How it works:**

```
PreToolUse hook (agent-tmux-hook.sh) sees the flag file
  → rewrites tool_input.command via hookSpecificOutput.updatedInput to:
      agent-term-run.sh <base64-of-original-command>
  → the wrapper types it into tmux session "agent" between BEGIN/DONE
    sentinel markers, tails a pipe-pane capture until DONE, emits the
    slice (ANSI-stripped) as the tool result with the real exit code
```

Because it's one persistent login shell, `cd` and `export` genuinely persist
across the agent's commands — that's a feature, but also why you shouldn't
run two heavy agent sessions through it at once (calls serialize through a
lock; parallel tool calls queue).

**Auto-bypassed (runs direct, never intercepted):** `run_in_background`
tool calls, commands driving tmux themselves, already-wrapped commands, and
anything when tmux is unusable — a broken tmux can never break a tool call.

**Safety properties worth knowing:**
- Timeout (default 600s, env `AGENT_TERM_TIMEOUT`) sends C-c to the pane and
  returns rc 124 — it never re-runs the command (no double side effects).
- A hard-killed wrapper's lock gets stolen after ~3s; nested claude sessions
  detect the parent's lock and go direct instead of deadlocking.
- Shell parse/expansion aborts (zsh's `=word` expansion, unbalanced quotes)
  return fast with the shell's error, because the DONE sentinel types as its
  own line.

**Cost:** ~0.5–1s+ added latency per command (typing + capture + polling),
and the harness may background slower calls. Treat it as a mode you flip on
to watch a task, not an always-on.

**Troubleshooting:** commands slow/hanging with the flag on → first suspect
a pager waiting for keys in the pane (git especially — see
[Field bugs](#field-bugs--first-real-workload-2026-07-28)), then check for
a stuck wrapper (`pgrep -fl agent-term-run.sh`), stale lock
(`ls /tmp/agent-term/lock`), or a shell stuck at a continuation prompt in
the pane (attach and C-c it). Nuclear option: toggle off + `rm -rf
/tmp/agent-term/lock` + `tmux kill-session -t agent` (it recreates itself).

---

## Layer 3 — Native ACP terminal channel (automatic)

**What:** agent-shell sessions advertise the ACP `terminal_output` capability,
so the claude-agent-acp adapter sends Bash results through its first-class
terminal channel instead of pre-baked text. Our shim renders them as the same
```console blocks you're used to, **plus a `✗ exit N` badge on failures**
(stock agent-shell never showed exit codes). Protocol-clean, hook-free, works
through acp-multiplex; the basis for upstream PRs to acp.el and agent-shell.

**Enable/disable:** on by default via `agent-terminal-acp-capability` (defcustom
in `lisp/agent-terminal.el`). Applies to sessions **started after load** —
existing buffers keep whatever they initialized with.

```elisp
(setq agent-terminal-acp-capability nil)  ;; + new session = stock behavior
```

**Verify it's live:** enable traffic logging (`SPC c l l`), start a new
session, run a command, `SPC c l v` and search for `terminal_output` — the
outgoing initialize carries `"_meta":{"terminal_output":true}` and incoming
tool_call_updates carry `_meta.terminal_output`/`terminal_exit` payloads.

**Implementation:** two advices in `lisp/agent-terminal.el` —
`acp-make-initialize-request` (:filter-return, injects the capability) and
`agent-shell--on-notification` (:filter-args, rewrites terminal payloads to
text content). Both no-op for agents that never emit terminal content.

**Caveats:** output still arrives at command completion (adapter limitation —
liveness is Layer 2's job). Through acp-multiplex, the capability follows
whichever frontend initializes *first* (normally agent-shell, which spawns
it); acp-mobile then inherits terminal-flavored updates — sanity-check its
rendering before relying on it remotely (open item in todos.org).

---

## Testing

```bash
~/.dotfiles/macos/scripts/agent-terminal-test.sh          # offline suite, no tokens
~/.dotfiles/macos/scripts/agent-terminal-test.sh --emacs  # + UX suite in your RUNNING Emacs
~/.dotfiles/macos/scripts/agent-terminal-test.sh --live   # + one real headless claude run
```

Covers: observer plumbing end-to-end (fake hook payloads → buffer), the tmux
wrapper's contract (output fidelity, exit codes, heredocs, cd/export
persistence, zsh-abort fast-fail, timeout, ANSI stripping, concurrency), the
rewrite hook's bypass rules, and the Phase 3 transform against live-probed
adapter payload shapes. Saves and restores your tmux flag state. Run it
before and after touching any of the moving parts; add a check when a new
bug teaches us something.

The **UX layer** (`tests/agent-terminal-ux-tests.el`, `atux-*`) tests the
experience rather than the plumbing: `SPC c v` pops/closes a bottom side
window, prompt lines render with the right faces (❯/command/annotation),
session separators and ↳ attribution appear, oversized output shows the
truncation marker, ANSI becomes real colors, tail-follow sticks to the
bottom but never yanks you down while you're scrolled up reading history,
and the tmux toggle flips its flag. It runs headless in the default suite;
`--emacs` re-runs it inside your live daemon — windows visibly open and
close, and the vterm-attach test actually attaches to the tmux session.
That's the mode to use when hacking on the UX itself.

Full ERT config suite (includes the same Phase 3 gold-payload tests):

```bash
/opt/homebrew/opt/emacs-plus@30/bin/emacs --batch -l ~/.emacs.d/init.el \
  -l ~/.emacs.d/tests/config-tests.el -f ert-run-tests-batch-and-exit
```

---

## File map

- `macos/scripts/agent-terminal-hook.sh` — observer feed (hooks → emacsclient)
- `macos/scripts/agent-tmux-hook.sh` — PreToolUse rewrite (Layer 2)
- `macos/scripts/agent-term-run.sh` — the tmux wrapper (Layer 2)
- `macos/scripts/agent-terminal-test.sh` — smoke suite
- `macos/emacs/.emacs.d/lisp/agent-terminal.el` — buffer, toggles, ACP shims
- `macos/emacs/.emacs.d/tests/config-tests.el` — ERT coverage
- `~/.claude/settings.json` — hook wiring (per-machine, untracked)
- `~/.claude/agent-tmux-enabled` — Layer 2 toggle flag (runtime, untracked)
- `docs/agent-terminal-prd.md` — design history + receipts

## Frame-pop bug ledger (2026-07-27)

Building `C-u SPC c L` took three crashes, each teaching something about how
frames actually behave on this daemon. Kept here so the next frame-popping
feature doesn't rediscover them.

**Crash 1 — `delete-other-windows: Cannot make side window the only window`**
- Naive code: `select-frame-set-input-focus` → `delete-other-windows` →
  `switch-to-buffer`, all against the *implicit* selected window.
- Cause: `delete-other-windows` throws exactly this when the selected window
  is a *side* window — and popper's popup had selection at that moment.
- Lesson: during/after frame creation, never rely on `selected-window`.
  Operate on explicit window objects.

**Crash 2 — `ad-Advice-set-window-buffer: Wrong type argument: window-live-p, #<window N>`**
- First diagnosis (wrong): vterm creation between `split-window` and
  `set-window-buffer` killing the fresh split. Reordering buffer creation
  didn't fix it.
- Real cause, found by step-through probing: **`frame-root-window` was dead
  immediately after `make-frame`**. A fresh frame here is born with *2*
  windows — `after-make-frame-functions` (`persp-init-frame`, popper, font
  lambda, `select-frame`, `evil-init-esc`) run *inside* `make-frame` and
  split the frame before it returns — so the root window is an internal
  *parent* node, which is never live and can't take a buffer.
- Fix: start from `frame-selected-window` (always a live leaf), bind
  `ignore-window-parameters` to `t`, `delete-other-windows` to collapse the
  hook-made split (the binding lets it eat protected side windows), then
  split and set buffers on explicit handles.

**Side discovery — frames here never inherit the current buffer.**
Stock `make-frame` "displays the current buffer" (its docstring); on this
config `persp-init-frame` re-points every new frame at its own fresh
perspective's `*scratch*` before `make-frame` returns. Any code assuming
either behavior should test, not assume.

**Debugging pattern that cracked it:** wrap each layout step in
`condition-case` + a log list, eval via emacsclient, and assert
`window-live-p` after every operation — the failing step was unambiguous in
one run, after two rounds of plausible-but-wrong fixes shipped blind.

## Field bugs — first real workload (2026-07-28)

Interception's first sustained session surfaced a compound failure. A
yes/no question took ten minutes because every git command "froze". Two
bugs, the second caused by the first:

**Bug A — git hangs 600s: the pager thinks a human is watching.
✅ FIXED 2026-08-01** — taming now rides ahead of the BEGIN marker on
*every* typed command (idempotent, outside the captured slice), so it no
longer matters who created the session. Regression-tested: "pager tamed
in externally-created session" in the smoke suite.
- The tmux pane is a real PTY, so git sees a tty and pipes output through
  `less`, which waits forever for a keypress nobody will send. The wrapper
  times out at 600s, C-c's the pane, returns rc 124.
- The wrapper *does* type `export GIT_PAGER=cat PAGER=cat LESS=RF` — but
  **only in its session-creation branch** (`agent-term-run.sh:83-88`). When
  the session already exists — notably when the attach path created it
  (`SPC c V` / `SPC c L` → vterm runs `tmux new-session -A -s agent`, no
  taming) — the exports never happen and every pager-using command is a
  600s landmine.
- Note `LESS=RF` isn't full protection anyway (`F` only auto-quits on
  one-screen output); `GIT_PAGER=cat` is what matters for git.

**Bug B — sentinel eaten mid-flight: `printf` arrives as `intf`.**
- The DONE marker line is typed (queued into the PTY input buffer) while
  the command is still running. Normally the shell reads it after the
  command exits. But a command that *reads the terminal* — exactly what a
  waiting pager does — consumes the queued characters as input: ` pr` of
  ` printf` became less keystrokes, the shell got `intf …` → "command not
  found" → no DONE marker ever printed.
- Without the marker the wrapper can't tell the command finished, so the
  harness saw long-running calls and shoved them into background tasks
  with empty output. From the agent's seat: frozen git, then silence.
- Implication even after Bug A is fixed: **any** stdin-reading command
  (interactive prompt, `read`, an editor) can eat the sentinel. The
  parse-abort rationale for typing DONE on its own line (see wrapper
  comments) trades away exactly this robustness — a real fix needs the
  sentinel delivery to not sit in the input queue during execution
  (e.g. fold it into the same logical input line, or `tmux wait-for`).

## Design direction — readability first (noted 2026-08-01)

The observer's value ceiling is *discernment*: seeing commands means nothing
if you can't cleanly tell them apart, scroll back through history, and find
things. Bugs and layers come and go; this is the bar the buffer is held to:

- **Hierarchy**: commands pop, output recedes (dim/indent) — not one flat wall
- **Navigation**: fold each command, n/p jump between commands, imenu/occur
- **Outcome at a glance**: exit badge + duration on every entry
- **Session identity**: stable per-session color + human labels, not UUIDs
  (labeling work shared with the per-conversation view idea)
- **Two modes**: the clean reading view AND a raw feed — pretty rules are
  rendering-time only, so raw stays available as a toggle or twin buffer

Timestamps, dim descriptions, session separators, ↳ attribution, ANSI color,
and no-yank tail-follow already exist (pinned by atux- tests); new rendering
rules must grow matching tests.

## Open items (also in todos.org)

- **Fix Bug B**: sentinel delivery that survives stdin-reading commands
  (same-logical-line DONE, or tmux wait-for)
- Interactive check: permission prompt should show the *original* command
  (not wrapper gibberish) while intercepting
- acp-mobile rendering sanity-check for terminal content
- MrX2: merge observer hooks into its settings.json
- Upstream PRs: acp.el capability flag + agent-shell terminal renderer
