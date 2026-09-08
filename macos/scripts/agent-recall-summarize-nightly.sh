#!/usr/bin/env bash
# Nightly transcript summarization for agent-recall.
#
# agent-shell appends to a transcript for as long as its conversation can be
# resumed -- days later included -- so there is no end-of-session event to hook.
# This runs at a time nothing is being typed and lets the summarizer's own idle
# rule decide what has settled: anything touched in the last 6 hours is left for
# tomorrow, and a summary older than its transcript is rewritten.
#
# Output is a plain TIMESTAMP.summary.md sidecar, which is the entire contract
# agent-recall reads. Nothing here touches Emacs.
set -euo pipefail

SUMMARIZER="$HOME/roaming/projects/agent-recall/scripts/summarize-transcripts.py"
LOG_DIR="$HOME/Library/Logs/agent-recall"
LOG="$LOG_DIR/summarize.log"
KEEP_LINES=2000

mkdir -p "$LOG_DIR"

# agent-recall is a local checkout under Syncthing-synced roaming, so on a fresh
# machine it can legitimately be missing. That is not an error worth alerting on.
if [[ ! -x "$SUMMARIZER" ]]; then
  printf '%s  skipped: no summarizer at %s\n' "$(date '+%F %T')" "$SUMMARIZER" >>"$LOG"
  exit 0
fi

{
  printf '\n===== %s =====\n' "$(date '+%F %T')"
  # System python3, not a PATH lookup: launchd's PATH is minimal and this must
  # not depend on which python happens to be installed.
  /usr/bin/python3 "$SUMMARIZER" --quiet --jobs 4 --idle-hours 6 2>&1 ||
    printf 'exit %s\n' "$?"
} >>"$LOG"

# A run appends about ten lines, so this only ever trims after a long time.
if [[ $(wc -l <"$LOG") -gt $KEEP_LINES ]]; then
  tail -n "$KEEP_LINES" "$LOG" >"$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi
