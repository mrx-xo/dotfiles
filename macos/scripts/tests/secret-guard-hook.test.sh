#!/bin/bash
# secret-guard-hook.test.sh — table test for the PreToolUse secret guard.
# Usage: macos/scripts/tests/secret-guard-hook.test.sh
set -u
HOOK="$(cd "$(dirname "$0")/.." && pwd)/secret-guard-hook.sh"
fail=0; n=0
check() { # check <expected-exit> <tool_name> <field> <value>
  n=$((n+1))
  out=$(jq -cn --arg t "$2" --arg f "$3" --arg v "$4" '{tool_name:$t, tool_input:{($f):$v}}' | "$HOOK" 2>/dev/null; echo "rc=$?")
  rc=${out##*rc=}
  if [ "$rc" = "$1" ]; then echo "ok   $n [$1] $4"; else echo "FAIL $n want $1 got $rc: $4"; fail=1; fi
}
# --- must ALLOW (exit 0)
check 0 Bash command 'secret gemini-api-token | sed "s/^/GEMINI_API_KEY=/" > ~/.gemini/.env'
check 0 Bash command 'export DEEPSEEK_API_KEY=$(secret deepseek-api-key)'
check 0 Bash command 'secret --list'
check 0 Bash command 'secret --cache "Deepseek API Key"'
check 0 Bash command 'grep -n secret_key src/config.py'
check 0 Bash command 'cat services/karakeep/.env.example'
check 0 Bash command 'ls -la ~/.gemini/.env'
check 0 Bash command 'git secret reveal'
check 0 Read file_path '/Users/marcosandrade/home-lab/services/karakeep/.env.example'
check 0 Read file_path '/Users/marcosandrade/.dotfiles/macos/scripts/secret'
check 0 Bash command 'jq -e . ~/.codex/auth.json >/dev/null'
check 0 Bash command 'cat services/caddy/.env | wc -l'
check 0 Bash command 'cat ~/.ssh/id_ed25519.pub'
check 0 Bash command 'echo "$HOME"'
check 0 Bash command 'printenv PATH'
check 0 Bash command 'cat .env.example'
check 0 Read file_path '/Users/marcosandrade/.ssh/id_ed25519.pub'
check 0 Bash command 'curl -s --config <(printf "header = \"Authorization: token %s\"\n" "$(secret forgejo-api-token)") https://omphalos.io/api/v1/user'
check 0 Bash command 'printf "add-generic-password -a x -s y -U -w %s\n" "$(rbw get "Deepseek API Key")" | security -i'
# --- must DENY (exit 2)
check 2 Bash command 'secret deepseek-api-key'
check 2 Bash command 'secret gemini-api-token'
check 2 Bash command 'echo $(secret deepseek-api-key)'
check 2 Bash command 'cd /tmp; secret deepseek-api-key'
check 2 Bash command 'cat ~/.gemini/.env'
check 2 Bash command 'head -1 /Users/marcosandrade/.codex/auth.json'
check 2 Bash command 'jq . ~/.local/share/opencode/auth.json'
check 2 Bash command 'sed -n 1p services/caddy/.env'
check 2 Bash command 'security find-generic-password -s deepseek-api-key -w'
check 2 Bash command 'security dump-keychain -d'
check 2 Bash command 'rbw get "Deepseek API Key"'
check 2 Bash command 'ssh homelab cat services/caddy/.env'
check 2 Read file_path '/Users/marcosandrade/.gemini/.env'
check 2 Read file_path '/Users/marcosandrade/.codex/auth.json'
check 2 Read file_path '/Users/marcosandrade/home-lab/services/caddy/.env'
check 2 Bash command 'cat ".env"'
check 2 Bash command 'cat services/app/.env; echo done'
check 2 Bash command 'command cat ~/.codex/auth.json'
check 2 Bash command 'sudo cat /root/.config/krypt-fetch/env'
check 2 Bash command "ssh homelab 'cat services/caddy/.env'"
check 2 Bash command 'dd if=~/.gemini/.env'
check 2 Bash command 'cat .env.local'
check 2 Bash command 'cat ~/.ssh/id_ed25519'
check 2 Bash command 'cat ~/.aws/credentials'
check 2 Bash command 'secret deepseek-api-key 2>/dev/null'
check 2 Bash command 'secret deepseek-api-key; true >/tmp/status'
check 2 Bash command 'secret deepseek-api-key | cat'
check 2 Bash command 'echo "$(rbw get "Deepseek API Key")"'
check 2 Bash command 'security find-generic-password -s deepseek-api-key -g'
check 2 Bash command 'printenv GEMINI_API_KEY'
check 2 Bash command 'echo $DEEPSEEK_API_KEY'
check 2 Bash command 'echo "${GEMINI_API_KEY}"'
check 2 Read file_path '/Users/marcosandrade/.ssh/id_ed25519'
check 2 Read file_path '/Users/marcosandrade/.config/krypt-fetch/env'
check 2 Bash command 'printf "%s\n" "$(secret forgejo-api-token)"'
check 2 Bash command 'echo "$(secret forgejo-api-token)" | tee /tmp/x'
# --- other tools pass through
check 0 Edit file_path '/Users/marcosandrade/.gemini/.env'
echo; [ $fail = 0 ] && echo "all $n passed" || { echo "FAILURES"; exit 1; }
