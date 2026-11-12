#!/bin/bash
# pr-guard-hook.sh — PreToolUse guard: agents open and edit pull requests only
# through `agent-pr`, which writes the review handoff, records the authoring
# session and marks its transcript (~/skills/review-handoff/SKILL.md).
# Wired for Claude Code (~/.claude/settings.json) and Codex
# (~/.codex/hooks.json, installed and trusted by wire-agent-instructions.sh),
# the same wire format as secret-guard-hook.sh.
#
# Denies (exit 2 + reason on stderr) Bash commands that:
#   - create a PR: gh pr create, gh api POST .../pulls, tea pr/pulls create,
#     curl POST to .../pulls (an explicit POST, or --data without -X)
#   - rewrite a PR body: gh pr edit --body/-b/--body-file/-F, a PATCH to
#     .../pulls/N whose command mentions body
# Allows merges, reviews, comments, closing, and anything run through agent-pr.
# Escape hatch, only when Marcos explicitly asks for a raw PR command: put
# `# agent-pr-bypass` in the command.  Threat model: habit, not evasion.
# Tests: macos/scripts/tests/pr-guard-hook.test.sh
set -u
JQ=$(command -v jq 2>/dev/null || echo /opt/homebrew/bin/jq)
[ -x "$JQ" ] || exit 0
input=$(cat)
[ "$(printf '%s' "$input" | "$JQ" -r '.tool_name // ""')" = Bash ] || exit 0
cmd=$(printf '%s' "$input" | "$JQ" -r '.tool_input.command // ""')
case "$cmd" in *agent-pr-bypass*) exit 0 ;; esac
u=$(printf '%s' "$cmd" | tr -d '"'"'")
deny() {
  echo "pr-guard: blocked ($1). Open or update PRs with \`agent-pr open\` so the review handoff, session record and transcript marks are written; see ~/skills/review-handoff/SKILL.md." >&2
  exit 2
}
# Commands that run agent-pr itself are fine, whatever else they mention.
printf '%s' "$u" | grep -Eq '(^|[;&|(/[:space:]])agent-pr([[:space:]]|$)' && exit 0

S='(^|[;&|(][[:space:]]*)'
printf '%s' "$u" | grep -Eq "${S}gh[[:space:]]+pr[[:space:]]+create" && deny "gh pr create"
printf '%s' "$u" | grep -Eq "${S}gh[[:space:]]+pr[[:space:]]+edit.*[[:space:]](--body|--body-file|-b|-F)([[:space:]=]|$)" && deny "gh pr edit body"
printf '%s' "$u" | grep -Eq "${S}tea[[:space:]]+(pr|prs|pull|pulls)[[:space:]]+(create|c)([[:space:]]|$)" && deny "tea pr create"

PULLS='/pulls([?[:space:]]|$)'
PULL_N='/pulls/[0-9]+([?[:space:]]|$)'
if printf '%s' "$u" | grep -Eq "${S}gh[[:space:]]+api[[:space:]]"; then
  printf '%s' "$u" | grep -Eq "$PULLS" && printf '%s' "$u" | grep -Eq '(-X|--method)[[:space:]]*POST' && deny "gh api create PR"
  printf '%s' "$u" | grep -Eq "$PULL_N" && printf '%s' "$u" | grep -Eq '(-X|--method)[[:space:]]*PATCH' \
    && printf '%s' "$u" | grep -Eq '(^|[^A-Za-z])body' && deny "gh api PR body edit"
fi
if printf '%s' "$u" | grep -Eq "${S}curl[[:space:]]"; then
  if printf '%s' "$u" | grep -Eq "$PULLS"; then
    printf '%s' "$u" | grep -Eq '(-X|--request)[[:space:]]*POST' && deny "curl create PR"
    printf '%s' "$u" | grep -Eq '(-X|--request)[[:space:]]*[A-Z]+' \
      || { printf '%s' "$u" | grep -Eq '[[:space:]](-d|--data[a-z-]*|--json|-F|--form)([[:space:]=]|$)' && deny "curl create PR"; }
  fi
  printf '%s' "$u" | grep -Eq "$PULL_N" && printf '%s' "$u" | grep -Eq '(-X|--request)[[:space:]]*PATCH' \
    && printf '%s' "$u" | grep -Eq '(^|[^A-Za-z])body' && deny "curl PR body edit"
fi
exit 0
