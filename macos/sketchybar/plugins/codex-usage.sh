#!/bin/bash
# -*- mode: sh -*-
# Codex subscription quota indicator.
#
# Codex has no usage API, but the CLI records its rate limits on every turn
# into the session rollout log. We tail the newest one. That reading is only
# as fresh as the last Codex turn, which is fine: the percentage only rises
# when Codex is used, so a stale value is still correct. The one failure mode
# is the window rolling over, which resets_at lets us detect.

NAME="${NAME:-codex_usage}"
SESSIONS="$HOME/.codex/sessions"

ORANGE=0xFFCC7B6E
RED=0xFFCE3A5B
WHITE=0xFFFFFFFF

# Newest rollout log, searching back over the quota window (7 days) only.
# A full find over ~28k files works but is wasteful at update_freq=60.
newest=""
for d in $(seq 0 7); do
  dir="$SESSIONS/$(date -v-${d}d '+%Y/%m/%d')"
  [ -d "$dir" ] || continue
  newest=$(find "$dir" -name 'rollout-*.jsonl' -type f -exec stat -f '%m %N' {} + 2>/dev/null \
           | sort -rn | head -1 | cut -d' ' -f2-)
  [ -n "$newest" ] && break
done

# No Codex use in the last 7 days means the weekly window has fully reset.
if [ -z "$newest" ]; then
  sketchybar --set "$NAME" drawing=off
  exit 0
fi

read -r PERCENT RESETS <<<"$(
  grep '"rate_limits"' "$newest" | tail -1 | python3 -c '
import sys, json
found = []
def walk(o):
    if isinstance(o, dict):
        rl = o.get("rate_limits")
        if isinstance(rl, dict):
            found.append(rl)
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

[ -z "$PERCENT" ] && PERCENT=-1
if [ "$PERCENT" -lt 0 ]; then
  sketchybar --set "$NAME" drawing=off
  exit 0
fi

# Window rolled over since the last recorded turn: the logged value is stale
# in the only way that matters, so the real usage is zero.
if [ -n "$RESETS" ] && [ "$RESETS" -gt 0 ] && [ "$(date +%s)" -gt "$RESETS" ]; then
  PERCENT=0
fi

# Codex sends no severity field, unlike Claude, so derive one.
if   [ "$PERCENT" -ge 90 ]; then COLOR=$RED
elif [ "$PERCENT" -ge 70 ]; then COLOR=$ORANGE
else                             COLOR=$WHITE
fi

sketchybar --set "$NAME" \
  drawing=on \
  icon=":openai:" \
  label="${PERCENT}%" \
  label.color=$COLOR
