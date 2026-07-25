#!/bin/bash
# agent-terminal-hook.sh — feed Claude Code Bash tool calls into Emacs.
# Phase 1 of docs/agent-terminal-prd.md (observer buffer).
#
# Wired from ~/.claude/settings.json:
#   PreToolUse  (matcher "Bash") → agent-terminal-hook.sh pre
#   PostToolUse (matcher "Bash") → agent-terminal-hook.sh post
#
# Reads the hook JSON on stdin, distills it to a small JSON payload,
# base64s it, and evals (agent-terminal--ingest "…") in the Emacs daemon.
# Fire-and-forget: a dead daemon or slow Emacs must never block or fail
# the agent's tool call.

set -u

PHASE="${1:-pre}"
INPUT="$(cat)"

# Schema verification aid: touch ~/.claude/agent-terminal-debug to dump the
# raw hook JSON for inspection (jq . /tmp/agent-terminal/last-*.json).
if [ -f "$HOME/.claude/agent-terminal-debug" ]; then
  mkdir -p /tmp/agent-terminal
  printf '%s' "$INPUT" >"/tmp/agent-terminal/last-${PHASE}.json"
fi

JQ="/opt/homebrew/bin/jq"
EMACSCLIENT="$(command -v emacsclient || echo /opt/homebrew/bin/emacsclient)"
[ -x "$JQ" ] || exit 0

# Distill to {phase, session, cwd, command, description, output, interrupted}.
# Output is truncated jq-side so the payload can never blow up ARG_MAX;
# finer display truncation happens in agent-terminal.el.
PAYLOAD="$(printf '%s' "$INPUT" | "$JQ" -c --arg phase "$PHASE" '
  ((.tool_response.stdout // .tool_response.output // "")
   + (if (.tool_response.stderr // "") != ""
      then "\n" + .tool_response.stderr else "" end)) as $out |
  {
    phase: $phase,
    session: (.session_id // ""),
    cwd: (.cwd // ""),
    command: (.tool_input.command // ""),
    description: (.tool_input.description // ""),
    output: (if ($out | length) > 60000
             then $out[:60000] + "\n[… truncated by hook]"
             else $out end),
    interrupted: (.tool_response.interrupted // false)
  }' 2>/dev/null | base64 | tr -d '\n')"

[ -n "$PAYLOAD" ] || exit 0

("$EMACSCLIENT" --eval \
  "(when (fboundp 'agent-terminal--ingest) (agent-terminal--ingest \"$PAYLOAD\"))" \
  >/dev/null 2>&1 || true) &

exit 0
