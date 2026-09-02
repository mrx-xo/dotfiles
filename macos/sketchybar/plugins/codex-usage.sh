#!/bin/bash
# -*- mode: sh -*-
# Codex subscription quota indicator.
#
# Codex has no usage API, but the CLI records its rate limits into the session
# rollout log on every turn, so we read the newest record it wrote. That value
# is only as fresh as the last Codex turn, which is fine: the percentage only
# rises when Codex is used, so a stale reading is still true. The one failure
# mode is the window rolling over, which resets_at detects.
#
# This item never hides. A missing reading is a display problem, not a reason
# to make the pill jump around, so we fall back to the last cached value and
# finally to a placeholder. Readings older than STALE_AFTER are dimmed.

NAME="${NAME:-codex_usage}"
SESSIONS="$HOME/.codex/sessions"
CACHE_DIR="$HOME/.cache/sketchybar"
CACHE="$CACHE_DIR/codex-usage"

LOOKBACK_DAYS=14      # calendar dirs to search for a usable record
MAX_FILES=10          # newest rollout logs to grep before giving up
STALE_AFTER=$((24 * 3600))

ORANGE=0xFFCC7B6E
RED=0xFFCE3A5B
WHITE=0xFFFFFFFF
DIM=0xFF888888

mkdir -p "$CACHE_DIR"

render() { # percent reading_epoch
  local pct="$1" ts="$2" color

  if [ "$pct" = "--" ]; then
    color=$DIM
  elif [ "$pct" -ge 90 ]; then
    color=$RED
  elif [ "$pct" -ge 70 ]; then
    color=$ORANGE
  elif [ -n "$ts" ] && [ "$ts" -gt 0 ] && [ $(( $(date +%s) - ts )) -gt $STALE_AFTER ]; then
    # Dim only while the number is unremarkable; a real warning outranks
    # "this reading is a day old", since usage can only have gone up since.
    color=$DIM
  else
    color=$WHITE
  fi

  sketchybar --set "$NAME" drawing=on icon=":openai:" label="${pct}%" label.color=$color
}

use_cache_or_placeholder() {
  if [ -s "$CACHE" ]; then
    render $(cat "$CACHE")
  else
    render "--" 0
  fi
  exit 0
}

# Newest rollout logs across the lookback window. The newest file is not
# necessarily the right one: a session that has not taken a turn yet carries
# no rate_limits record, so walk back until one does.
candidates=$(
  for d in $(seq 0 $LOOKBACK_DAYS); do
    dir="$SESSIONS/$(date -v-${d}d '+%Y/%m/%d')"
    [ -d "$dir" ] && find "$dir" -name 'rollout-*.jsonl' -type f -exec stat -f '%m %N' {} + 2>/dev/null
  done | sort -rn | head -$MAX_FILES
)
[ -z "$candidates" ] && use_cache_or_placeholder

PERCENT=""; RESETS=0; READING_TS=0
while read -r mtime file; do
  [ -n "$file" ] || continue
  line=$(grep '"rate_limits"' "$file" 2>/dev/null | tail -1)
  [ -n "$line" ] || continue
  read -r p r <<<"$(printf '%s' "$line" | python3 -c '
import sys, json
found = []
def walk(o):
    if isinstance(o, dict):
        if isinstance(o.get("rate_limits"), dict):
            found.append(o["rate_limits"])
        for v in o.values():
            walk(v)
    elif isinstance(o, list):
        for v in o:
            walk(v)
try:
    walk(json.loads(sys.stdin.readline()))
except Exception:
    pass
w = (found[-1].get("primary") if found else None) or {}
print(int(round(w.get("used_percent", -1))), int(w.get("resets_at", 0)))
' 2>/dev/null)"
  if [ -n "$p" ] && [ "$p" -ge 0 ] 2>/dev/null; then
    PERCENT="$p"; RESETS="$r"; READING_TS="$mtime"
    break
  fi
done <<< "$candidates"

[ -z "$PERCENT" ] && use_cache_or_placeholder

# Window rolled over since that turn, so the recorded usage no longer applies.
if [ "$RESETS" -gt 0 ] && [ "$(date +%s)" -gt "$RESETS" ]; then
  PERCENT=0
  READING_TS=$(date +%s)
fi

printf '%s %s\n' "$PERCENT" "$READING_TS" > "$CACHE"
render "$PERCENT" "$READING_TS"
