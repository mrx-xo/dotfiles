#!/bin/bash
# -*- mode: sh -*-
# Claude subscription quota indicator.
#
# Reads the same endpoint Claude Code's /usage command uses. The response
# carries a limits[] array in which exactly one entry is flagged is_active:
# the bucket currently binding you (5h session, weekly, or a per-model weekly
# cap). We show that one rather than inventing a "worst of" rule, and take its
# severity from the API rather than guessing thresholds.
#
# The OAuth token is short-lived, so it is re-read from the Keychain each run
# rather than cached. Verified to read silently from sketchybar's process.

NAME="${NAME:-claude_usage}"
CACHE_DIR="$HOME/.cache/sketchybar"
CACHE="$CACHE_DIR/claude-usage"

ORANGE=0xFFCC7B6E
RED=0xFFCE3A5B
WHITE=0xFFFFFFFF
DIM=0xFF888888

mkdir -p "$CACHE_DIR"

render() { # percent severity
  case "$2" in
    critical) color=$RED ;;
    warning)  color=$ORANGE ;;
    *)        color=$WHITE ;;
  esac
  [ "$1" = "--" ] && color=$DIM
  sketchybar --set "$NAME" \
    drawing=on \
    icon=":claude:" \
    label="${1}%" \
    label.color=$color
}

# Fall back to the last good reading rather than blanking the bar on a wifi
# blip. This item never hides: a machine that has never had a successful read
# shows a placeholder, so the pill keeps a stable width instead of jumping.
fallback() {
  if [ -s "$CACHE" ]; then
    render $(cat "$CACHE")
  else
    render "--" normal
  fi
  exit 0
}

TOKEN=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
        | python3 -c 'import sys,json; print(json.load(sys.stdin)["claudeAiOauth"]["accessToken"])' 2>/dev/null)
[ -z "$TOKEN" ] && fallback

RESP=$(curl -sS --max-time 5 https://api.anthropic.com/api/oauth/usage \
         -H "Authorization: Bearer $TOKEN" \
         -H "anthropic-beta: oauth-2025-04-20" 2>/dev/null)
[ -z "$RESP" ] && fallback

read -r PERCENT SEVERITY <<<"$(printf '%s' "$RESP" | python3 -c '
import sys, json
try:
    limits = json.load(sys.stdin).get("limits") or []
except Exception:
    sys.exit(1)
active = next((l for l in limits if l.get("is_active")), None)
# Nothing flagged active means nothing is binding yet; the highest bucket is
# still the honest number to show.
if active is None:
    active = max(limits, key=lambda l: l.get("percent") or 0, default=None)
if active is None:
    sys.exit(1)
print(int(round(active.get("percent") or 0)), active.get("severity") or "normal")
' 2>/dev/null)"

[ -z "$PERCENT" ] && fallback

printf '%s %s\n' "$PERCENT" "$SEVERITY" > "$CACHE"
render "$PERCENT" "$SEVERITY"
