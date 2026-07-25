#!/bin/bash
# agent-tmux-hook.sh — PreToolUse(Bash) rewrite for Phase 2 of
# docs/agent-terminal-prd.md (tmux interception).
#
# When ~/.claude/agent-tmux-enabled exists, rewrites tool_input.command to
#   agent-term-run.sh <base64-of-original-command>
# via the updatedInput hook output (schema live-verified 2026-07-25:
# hookSpecificOutput.updatedInput, no permissionDecision needed — the
# normal permission flow is preserved).
#
# Bypasses (no rewrite, hook stays silent):
#   - toggle flag absent
#   - run_in_background tool calls (background task machinery needs the
#     real process)
#   - commands driving tmux themselves (no inception)
#   - commands already wrapped (paranoia against double-wrapping)

set -u

FLAG="$HOME/.claude/agent-tmux-enabled"
[ -f "$FLAG" ] || exit 0

JQ="/opt/homebrew/bin/jq"
[ -x "$JQ" ] || exit 0

RUNNER="/Users/marcosandrade/.dotfiles/macos/scripts/agent-term-run.sh"

"$JQ" -c --arg runner "$RUNNER" '
  .tool_input as $ti |
  ($ti.command // "") as $cmd |
  if ($ti.run_in_background == true)
     or ($cmd | test("(^|[;&|(\\s])tmux(\\s|$)"))
     or ($cmd | contains("agent-term-run.sh"))
     or ($cmd == "")
  then empty
  else
    { hookSpecificOutput:
      { hookEventName: "PreToolUse",
        updatedInput: ($ti + { command: ($runner + " " + ($cmd | @base64)) }) } }
  end' 2>/dev/null

exit 0
