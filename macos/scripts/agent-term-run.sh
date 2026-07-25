#!/bin/bash
# agent-term-run.sh <base64-of-command> — Phase 2 of docs/agent-terminal-prd.md.
#
# Runs the agent's Bash command inside tmux session "agent" so a human can
# watch it execute (and type into the same shell between commands), while
# the agent receives normal stdout + exit code and notices nothing.
# Invoked via the PreToolUse updatedInput rewrite in agent-tmux-hook.sh;
# only active when ~/.claude/agent-tmux-enabled exists.
#
# Safety properties:
#   - tmux unusable (dead server, sandboxed session, missing binary) BEFORE
#     anything was typed → fall back to direct exec; the tool call succeeds.
#   - After the command was typed, NEVER fall back (double-execution risk);
#     a timeout sends C-c to the pane and reports what was captured.
#   - Concurrent invocations (parallel tool calls, multiple sessions) are
#     serialized through a PID-staleness lock.

set -u

SESSION=agent
LOGDIR=/tmp/agent-term
TIMEOUT="${AGENT_TERM_TIMEOUT:-600}"

B64="${1:-}"
CMD="$(printf '%s' "$B64" | base64 --decode 2>/dev/null)"
if [ -z "$CMD" ]; then
  echo "agent-term-run: empty or undecodable command payload" >&2
  exit 2
fi

direct() { exec /bin/zsh -c "$CMD"; }

TMUX_BIN="$(command -v tmux || true)"
[ -x "${TMUX_BIN:-}" ] || TMUX_BIN=/opt/homebrew/bin/tmux
[ -x "$TMUX_BIN" ] || direct

mkdir -p "$LOGDIR" 2>/dev/null || direct

# --- serialize: one command in the pane at a time -------------------------
# If the lock holder is our own ancestor (nested claude session: parent's
# wrapped command spawned us), waiting would deadlock until the timeout —
# run direct instead.
is_ancestor() {
  local p=$$
  while [ "$p" -gt 1 ]; do
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
    [ -z "$p" ] && return 1
    [ "$p" = "$1" ] && return 0
  done
  return 1
}

LOCK="$LOGDIR/lock"
waited=0
nopid=0
until mkdir "$LOCK" 2>/dev/null; do
  lockpid="$(cat "$LOCK/pid" 2>/dev/null || true)"
  if [ -n "$lockpid" ] && ! kill -0 "$lockpid" 2>/dev/null; then
    rm -rf "$LOCK" 2>/dev/null
    continue
  fi
  # Lock dir with no pid file: holder was hard-killed in the gap between
  # mkdir and pid write. Give it ~3s to appear, then steal.
  if [ -z "$lockpid" ]; then
    nopid=$((nopid + 1))
    if [ "$nopid" -gt 12 ]; then
      rm -rf "$LOCK" 2>/dev/null
      continue
    fi
  else
    nopid=0
  fi
  [ -n "$lockpid" ] && is_ancestor "$lockpid" && direct
  sleep 0.25
  waited=$((waited + 1))
  # Lock starved past the timeout → nothing was typed yet, safe to go direct.
  [ "$waited" -gt $((TIMEOUT * 4)) ] && direct
done
echo $$ >"$LOCK/pid"
trap 'rm -rf "$LOCK" 2>/dev/null' EXIT

# --- ensure the session exists -------------------------------------------
if ! "$TMUX_BIN" has-session -t "$SESSION" 2>/dev/null; then
  "$TMUX_BIN" new-session -d -s "$SESSION" 2>/dev/null || direct
  # Tame interactive traps in the agent's shell (pagers hang PTYs).
  "$TMUX_BIN" send-keys -t "$SESSION" -l -- " export GIT_PAGER=cat PAGER=cat LESS=RF" 2>/dev/null
  "$TMUX_BIN" send-keys -t "$SESSION" Enter 2>/dev/null
  sleep 0.3
fi

ID="$(date +%s)-$$"
LOG="$LOGDIR/$ID.log"
: >"$LOG"

# Capture the PTY stream (raw, ANSI and all — the human pane keeps colors).
"$TMUX_BIN" pipe-pane -t "$SESSION" "cat >> $LOG" 2>/dev/null || direct

# --- type it --------------------------------------------------------------
# Two inputs: (1) BEGIN marker + { CMD } compound, (2) DONE marker with rc
# on its OWN line. Separate lines matter: a zsh parse/expansion abort (e.g.
# `echo ===` dying on =-expansion) kills the whole first line, but the
# queued DONE line still executes — rc reflects the failure and we never
# hang. Markers are assembled by printf at *execution* time so echoed
# keystrokes never contain the literal marker strings; the DONE line's own
# echo lands inside the capture and is filtered below. Leading space keeps
# both out of shell history (hist_ignore_space).
TYPED=" printf '<<AGENT-%s:%s>>\\n' BEGIN $ID; { $CMD
}"
DONE_TYPED=" printf '<<AGENT-%s:%s:%s>>\\n' DONE $ID \$?"

if ! "$TMUX_BIN" send-keys -t "$SESSION" -l -- "$TYPED" 2>/dev/null; then
  "$TMUX_BIN" pipe-pane -t "$SESSION" 2>/dev/null
  direct
fi
"$TMUX_BIN" send-keys -t "$SESSION" Enter
"$TMUX_BIN" send-keys -t "$SESSION" -l -- "$DONE_TYPED" 2>/dev/null
"$TMUX_BIN" send-keys -t "$SESSION" Enter

# --- wait for the DONE sentinel ------------------------------------------
RC=""
deadline=$((SECONDS + TIMEOUT))
while [ "$SECONDS" -lt "$deadline" ]; do
  marker="$(tr -d '\r' <"$LOG" | grep -a -m1 -o "<<AGENT-DONE:$ID:[0-9]*>>" || true)"
  if [ -n "$marker" ]; then
    RC="${marker##*:}"
    RC="${RC%>>}"
    break
  fi
  sleep 0.2
done

"$TMUX_BIN" pipe-pane -t "$SESSION" 2>/dev/null # stop capture

if [ -z "$RC" ]; then
  # Timed out: command still running or shell stuck at a continuation
  # prompt. Abort it in the pane; do NOT re-run (side effects already
  # happened). Report what we saw.
  "$TMUX_BIN" send-keys -t "$SESSION" C-c 2>/dev/null
  RC=124
  TIMED_OUT=1
else
  TIMED_OUT=0
fi

# --- emit agent-facing output --------------------------------------------
# Slice between the markers, drop the echoed DONE-printf line, strip
# ANSI/OSC sequences and CRs for the agent; the human pane already saw the
# colorful version. If BEGIN never printed (parse/expansion abort before
# execution), fall back to the stripped log tail so the agent sees the
# shell's error instead of silence.
extract() {
  tr -d '\r' <"$LOG" | awk -v id="$ID" '
    index($0, "<<AGENT-DONE:" id ":") { exit }
    on && index($0, "printf '\''<<AGENT-") == 0 { print }
    index($0, "<<AGENT-BEGIN:" id ">>") { on = 1; seen = 1 }
    END { exit !seen }
  '
}
strip_ansi() {
  perl -pe 's/\e\[[0-9;?]*[ -\/]*[@-~]//g; s/\e\][^\a\e]*(?:\a|\e\\)//g; s/\e[@-_]//g'
}
set -o pipefail
if ! extract | strip_ansi; then
  echo "[agent-term: no output captured (shell parse/expansion abort?) — pane tail follows]"
  tr -d '\r' <"$LOG" | grep -av "<<AGENT-\|printf '<<AGENT-" | tail -5 | strip_ansi
fi

[ "$TIMED_OUT" -eq 1 ] && echo "[agent-term: timed out after ${TIMEOUT}s — aborted with C-c in tmux session '$SESSION']" >&2

rm -f "$LOG"
exit "$RC"
