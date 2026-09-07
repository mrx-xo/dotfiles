#!/bin/bash
# secret-guard-hook.sh — Claude Code PreToolUse guard against secrets entering
# the transcript. Layer 5 of ~/docs/agent-fleet-ops.md section 3. Convention-only
# elsewhere; enforced here for Bash and Read.
#
# Denies (exit 2 + reason on stderr):
#   - bare `secret <name>` / `rbw get <name>` whose stdout is not captured with
#     $(...) or redirected to a file within the same command segment
#   - echo/printf of a $(secret ...) / $(rbw get ...) capture
#   - printing key files (~/.gemini/.env, codex/opencode auth, *.env, .env.local,
#     ~/.config/<x>/env, .aws/credentials, .netrc, SSH private keys) with a
#     reading command, locally, via sudo/command, or over ssh
#   - `security ... -w|-g`, `security dump-keychain -d`
#   - printenv/echo of variables named *KEY*, *TOKEN*, *SECRET*, *PASS*
# Allows everything else silently (exit 0). Never prints tool input.
# Known gaps (accepted; the threat model is accidental leakage, not evasion):
# variable laundering (v=$(secret x); echo "$v"), heredoc text that merely
# mentions these words, symlinked key files, `env`/`set` dumps.
# Tests: macos/scripts/tests/secret-guard-hook.test.sh
set -u
JQ=$(command -v jq 2>/dev/null || echo /opt/homebrew/bin/jq)
[ -x "$JQ" ] || exit 0
input=$(cat)
tool=$(printf '%s' "$input" | "$JQ" -r '.tool_name // ""')
deny() { echo "secret-guard: blocked ($1). Secrets only flow through a redirect or \$(...); never print key files." >&2; exit 2; }

# A path that ends a token: whitespace, quote, ; ) | & or end of string.
END='([[:space:]"'"'"';)|&]|$)'
KEYFILES="(\.gemini/\.env|\.codex/auth\.json|opencode/auth\.json|\.restic-b2\.env|\.aws/credentials|\.netrc$END|\.ssh/id_[A-Za-z0-9_]+$END|\.config/[^[:space:]/]+/env$END|(^|[/[:space:]\"'])\.env(\.local|\.production|\.secrets?)?$END|/[A-Za-z0-9_.-]+\.env(\.local|\.production|\.secrets?)?$END)"
PREFIX='((command|sudo|exec|nice|time)[[:space:]]+)*'
READERS="(^|[;&|(][[:space:]]*|ssh[[:space:]]+[^[:space:]]+[[:space:]]+)$PREFIX(cat|less|more|head|tail|bat|sed|awk|grep|rg|jq|strings|xxd|od|base64|tac|nl|cut|dd|python3?|perl|ruby|node)[[:space:]]"

case "$tool" in
  Bash)
    cmd=$(printf '%s' "$input" | "$JQ" -r '.tool_input.command // ""')
    # unquoted: quotes removed so `cat ".env"` and ssh 'cat .env' match like the bare form
    unquoted=$(printf '%s' "$cmd" | tr -d '"'"'")
    # stripped: $(secret ...) / $(rbw get ...) captures removed so they are not
    # mistaken for a bare invocation (the "(" would look like a command start)
    stripped=$(printf '%s' "$unquoted" | sed -E 's/\$\([[:space:]]*(secret|rbw[[:space:]]+get)[^)]*\)//g')
    # noredir: redirect targets removed so `... > ~/.gemini/.env` is not a "read"
    noredir=$(printf '%s' "$unquoted" | sed -E 's/>+[[:space:]]*[^[:space:]]+//g')

    # bare secret / rbw get: judged per command segment (split on ; && ||),
    # and only a stdout redirect counts (2>/dev/null does not)
    while IFS= read -r seg; do
      if printf '%s' "$seg" | grep -Eq "(^|[|(])[[:space:]]*$PREFIX(secret|rbw[[:space:]]+get)[[:space:]]+[A-Za-z0-9]"; then
        printf '%s' "$seg" | grep -Eq '(secret|rbw[[:space:]]+get)[[:space:]]+.*(^|[^2&])>' || deny "bare secret"
      fi
    done < <(printf '%s\n' "$stripped" | sed -E 's/(&&|\|\|)/;/g' | tr ';' '\n')

    # captured, then printed: echo $(secret X) / printf ... $(rbw get X).
    # Exempt: process substitution `<(printf ... $(secret X))` (a private pipe read
    # by curl --config etc., the recommended way to pass a credential) and
    # `printf ... $(rbw get X) | security -i` (how secret --cache stores items).
    nosubst=$(printf '%s' "$unquoted" | sed -E 's/<\([^)]*\)[^)]*\)//g; s/(echo|printf)[^;&|]*\|[[:space:]]*security[[:space:]]//g')
    printf '%s' "$nosubst" | grep -Eq '(echo|printf)[^;&|]*\$\([[:space:]]*(secret|rbw[[:space:]]+get)' && deny "echoed secret"
    printf '%s' "$unquoted" | grep -Eq 'security[[:space:]]+(find|dump)-(generic|internet)-password.*[[:space:]]-[wg]([[:space:]]|$)' && deny "security -w/-g"
    printf '%s' "$unquoted" | grep -Eq 'security[[:space:]]+dump-keychain.*[[:space:]]-d([[:space:]]|$)' && deny "keychain dump"
    printf '%s' "$unquoted" | grep -Eq '(^|[;&|(][[:space:]]*)printenv[[:space:]]+[A-Za-z_]*(KEY|TOKEN|SECRET|PASS)' && deny "printenv secret"
    printf '%s' "$unquoted" | grep -Eq '(^|[;&|(][[:space:]]*)echo[[:space:]]+\$\{?[A-Za-z_]*(KEY|TOKEN|SECRET|PASS)' && deny "echoed secret variable"

    # key file read: a reading command and a key file path in the same command,
    # unless stdout is discarded or reduced to a count/hash
    if printf '%s' "$unquoted" | grep -Eq "$READERS" && printf '%s' "$noredir" | grep -Eq "$KEYFILES"; then
      printf '%s' "$unquoted" | grep -Eq '>[[:space:]]*/dev/null|\|[[:space:]]*(wc|md5|md5sum|shasum|sha256sum)([[:space:]]|$)' || deny "key file read"
    fi
    ;;
  Read)
    path=$(printf '%s' "$input" | "$JQ" -r '.tool_input.file_path // ""')
    case "$path" in
      *.env.example|*.pub) ;;
      */.gemini/.env|*/.codex/auth.json|*/opencode/auth.json|*.env|*.env.local|*.env.production|*.env.secret|*.env.secrets|*/.aws/credentials|*/.netrc|*/.ssh/id_*|*/.config/*/env|*/.restic-b2.env) deny "key file read" ;;
    esac
    ;;
esac
exit 0
