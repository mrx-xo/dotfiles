# Agent Terminal — User Guide

Watch every Bash command your Claude agents run, live, in a real terminal —
and optionally type into the same shell they're using.

Three independent layers. Each works alone; they stack. PRD with full design
history: `docs/agent-terminal-prd.md`. Repeatable smoke tests:
`macos/scripts/agent-terminal-test.sh` (see [Testing](#testing)).

---

## TL;DR

```
SPC c v        toggle the observer buffer (always-on feed, read-only)
SPC c V        attach the tmux pane (watch/type, only useful when intercepting)
C-u SPC c V    toggle tmux interception on/off (takes effect next tool call)
```

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
(`tmux attach -t agent` from any terminal works too).

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

**Troubleshooting:** commands slow/hanging with the flag on → check for a
stuck wrapper (`pgrep -fl agent-term-run.sh`), stale lock
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
~/.dotfiles/macos/scripts/agent-terminal-test.sh --live   # + one real headless claude run
```

Covers: observer plumbing end-to-end (fake hook payloads → buffer), the tmux
wrapper's contract (output fidelity, exit codes, heredocs, cd/export
persistence, zsh-abort fast-fail, timeout, ANSI stripping, concurrency), the
rewrite hook's bypass rules, and the Phase 3 transform against live-probed
adapter payload shapes. Saves and restores your tmux flag state. Run it
before and after touching any of the moving parts; add a check when a new
bug teaches us something.

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

## Open items (also in todos.org)

- Interactive check: permission prompt should show the *original* command
  (not wrapper gibberish) while intercepting
- acp-mobile rendering sanity-check for terminal content
- MrX2: merge observer hooks into its settings.json
- Upstream PRs: acp.el capability flag + agent-shell terminal renderer
