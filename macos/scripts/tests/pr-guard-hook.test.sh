#!/bin/bash
# pr-guard-hook.test.sh — table test for the PreToolUse PR guard.
# Usage: macos/scripts/tests/pr-guard-hook.test.sh
set -u
HOOK="$(cd "$(dirname "$0")/.." && pwd)/pr-guard-hook.sh"
fail=0; n=0
check() { # check <expected-exit> <tool_name> <command>
  n=$((n+1))
  out=$(jq -cn --arg t "$2" --arg v "$3" '{tool_name:$t, tool_input:{command:$v}}' | "$HOOK" 2>/dev/null; echo "rc=$?")
  rc=${out##*rc=}
  if [ "$rc" = "$1" ]; then echo "ok   $n [$1] $3"; else echo "FAIL $n want $1 got $rc: $3"; fail=1; fi
}
# --- must ALLOW (exit 0)
check 0 Bash 'agent-pr open --handoff h.md --route r.json --title "x" --summary "y"'
check 0 Bash '~/.local/bin/agent-pr open --handoff h.md --route r.json'
check 0 Bash 'cd ~/src/x && agent-pr start "feature"'
check 0 Bash 'gh pr view 12 --json body'
check 0 Bash 'gh pr list'
check 0 Bash 'gh pr merge 12 --squash'
check 0 Bash 'gh pr review 12 --approve --body "lgtm"'
check 0 Bash 'gh pr comment 12 --body "note"'
check 0 Bash 'gh pr edit 12 --add-label bug'
check 0 Bash 'gh pr close 12'
check 0 Bash 'curl -s https://forge.example/api/v1/repos/o/r/pulls/1'
check 0 Bash 'curl -s "https://forge.example/api/v1/repos/o/r/pulls?state=open"'
check 0 Bash 'curl -s -X POST https://forge.example/api/v1/repos/o/r/pulls/1/merge -d "{}"'
check 0 Bash 'curl -s -X POST https://forge.example/api/v1/repos/o/r/pulls/1/reviews --data @review.json'
check 0 Bash 'curl -s -X PATCH https://forge.example/api/v1/repos/o/r/pulls/1 -d "{\"state\":\"closed\"}"'
check 0 Bash 'gh api repos/o/r/pulls/1/comments'
check 0 Bash 'grep -n "gh pr create" docs/notes.md'
check 0 Bash 'curl -s -X POST https://forge.example/api/v1/repos/o/r/pulls -d @b.json # agent-pr-bypass'
check 0 Read 'gh pr create'
# --- must DENY (exit 2)
check 2 Bash 'gh pr create --title x --body y'
check 2 Bash 'cd repo && gh pr create --fill'
check 2 Bash 'gh pr edit 12 --body "new body"'
check 2 Bash 'gh pr edit 12 --body-file b.md'
check 2 Bash 'gh pr edit 12 -F b.md'
check 2 Bash 'tea pr create --title x'
check 2 Bash 'tea pulls create --head feat'
check 2 Bash 'gh api repos/o/r/pulls -X POST -f title=x -f head=feat -f base=main'
check 2 Bash 'gh api --method PATCH repos/o/r/pulls/3 -f body=x'
check 2 Bash 'curl -s -X POST https://forge.example/api/v1/repos/o/r/pulls -d @pr.json'
check 2 Bash 'curl -s https://forge.example/api/v1/repos/o/r/pulls --data "{\"title\":\"x\"}"'
check 2 Bash 'curl -s -X PATCH https://forge.example/api/v1/repos/o/r/pulls/1 -d "{\"body\":\"x\"}"'
check 2 Bash 'curl -s --request POST "https://forge.example/api/v1/repos/o/r/pulls" --json @x.json'
[ $fail = 0 ] && echo "all $n passed"
exit $fail
