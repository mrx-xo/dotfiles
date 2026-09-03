#!/bin/bash
# -*- mode: sh -*-
# Claude subscription quota indicator.
#
# Reads the same endpoint Claude Code's /usage command uses. The label shows
# the 5-hour session and all-model weekly windows, followed by the Fable weekly
# limit when the server reports one. The trailing pipe separates Claude from
# the adjacent Codex item.
#
# The OAuth token is short-lived, so it is re-read from the Keychain each run
# rather than cached. Verified to read silently from sketchybar's process.

NAME="${NAME:-claude_usage}"
FABLE_NAME="${FABLE_NAME:-fable_usage}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="$HOME/.cache/sketchybar"
CACHE="$CACHE_DIR/claude-usage"
DESKTOP_HISTORY="$HOME/Library/Application Support/Claude/plan-usage-history.json"

ORANGE=0xFFCC7B6E
RED=0xFFCE3A5B
WHITE=0xFFFFFFFF
DIM=0xFF888888

mkdir -p "$CACHE_DIR"

render() { # primary_label fable_label severity
  case "$3" in
    critical) color=$RED ;;
    warning)  color=$ORANGE ;;
    *)        color=$WHITE ;;
  esac
  [ "$1" = "--% · --% |" ] && color=$DIM
  sketchybar --set "$NAME" \
    drawing=on \
    icon=":claude:" \
    label="$1" \
    label.color=$color
  if [ -n "$2" ] && [ "$2" != "-" ]; then
    sketchybar --set "$FABLE_NAME" drawing=on label="$2" label.color=$color
  else
    sketchybar --set "$FABLE_NAME" drawing=off
  fi
}

# Fall back to the last good reading rather than blanking the bar on a wifi
# blip. This item never hides: a machine that has never had a successful read
# shows a placeholder, so the pill keeps a stable width instead of jumping.
fallback() {
  if [ -s "$CACHE" ]; then
    IFS=$'\t' read -r version primary_label fable_label severity < "$CACHE"
    if [ "$version" = "v3" ] && [ -n "$primary_label" ] \
       && [ -n "$fable_label" ] && [ -n "$severity" ]; then
      render "$primary_label" "$fable_label" "$severity"
      exit 0
    fi
  fi
  if [ -s "$DESKTOP_HISTORY" ]; then
    parsed=$(python3 "$SCRIPT_DIR/claude_usage.py" --history \
             < "$DESKTOP_HISTORY" 2>/dev/null)
    if [ -n "$parsed" ]; then
      IFS=$'\t' read -r primary_label fable_label severity <<< "$parsed"
      render "$primary_label" "$fable_label" "$severity"
      exit 0
    fi
  fi
  render "--% · --% |" - normal
  exit 0
}

TOKEN=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
        | python3 -c 'import sys,json; print(json.load(sys.stdin)["claudeAiOauth"]["accessToken"])' 2>/dev/null)
[ -z "$TOKEN" ] && fallback

RESP=$(curl -sS --max-time 5 https://api.anthropic.com/api/oauth/usage \
         -H "Authorization: Bearer $TOKEN" \
         -H "anthropic-beta: oauth-2025-04-20" 2>/dev/null)
[ -z "$RESP" ] && fallback

PARSED=$(printf '%s' "$RESP" | python3 "$SCRIPT_DIR/claude_usage.py" 2>/dev/null)
[ -z "$PARSED" ] && fallback

IFS=$'\t' read -r PRIMARY_LABEL FABLE_LABEL SEVERITY <<< "$PARSED"
[ -z "$PRIMARY_LABEL" ] && fallback

printf 'v3\t%s\t%s\t%s\n' \
  "$PRIMARY_LABEL" "$FABLE_LABEL" "$SEVERITY" > "$CACHE"
render "$PRIMARY_LABEL" "$FABLE_LABEL" "$SEVERITY"
