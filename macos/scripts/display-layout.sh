#!/usr/bin/env bash
# display-layout.sh — remember & restore monitor ARRANGEMENT per display-set.
#
# macOS matches displays to its saved layout by connection fingerprint,
# which is flaky through adapters and disconnect/reconnect cycles
# (monitor-mode.sh does these constantly) — so positions randomly reset.
# This keeps our own profiles instead, keyed by WHICH displays are
# connected (sorted persistent screen ids): each unique set of monitors
# gets its own saved arrangement.
#
#   display-layout.sh save     # current arrangement becomes the profile
#                              # for the current display set (= override)
#   display-layout.sh apply    # restore the profile if arrangement drifted
#   display-layout.sh status   # current set + profile sync state
#   display-layout.sh list     # all saved profiles
#
# Auto-heal: hammerspoon's hs.screen.watcher runs `apply` (debounced) on
# every display change, so a scrambled arrangement snaps back in seconds.
# Applying is a no-op when current == saved, which also prevents the
# watcher-fires-on-our-own-apply loop from cycling.

set -euo pipefail

PROFILE_DIR="$HOME/.dotfiles/macos/display-layouts"
DP=/opt/homebrew/bin/displayplacer
LOG="$HOME/Library/Logs/display-layout.log"

listing=$("$DP" list)

# Sorted persistent ids of currently connected displays, joined with +
fingerprint=$(awk '/^Persistent screen id:/ {print $4}' <<<"$listing" | sort | paste -sd+ -)
# The restore one-liner displayplacer prints at the end of `list`
current=$(grep '^displayplacer ' <<<"$listing" | tail -1)
profile="$PROFILE_DIR/$fingerprint.txt"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >>"$LOG"; }

case "${1:-status}" in
  save)
    mkdir -p "$PROFILE_DIR"
    echo "$current" >"$profile"
    log "saved profile $fingerprint"
    echo "Saved arrangement for display set:"
    echo "  $fingerprint"
    echo "  -> $profile"
    ;;
  apply)
    if [[ ! -f "$profile" ]]; then
      log "apply: no profile for $fingerprint"
      echo "No saved profile for current display set ($fingerprint); run 'save' first."
      exit 0
    fi
    saved=$(<"$profile")
    if [[ "$current" == "$saved" ]]; then
      echo "Arrangement already matches saved profile."
      exit 0
    fi
    log "apply: restoring $fingerprint"
    eval "${saved/#displayplacer/$DP}"
    echo "Restored saved arrangement for $fingerprint."
    ;;
  status)
    echo "Current display set: $fingerprint"
    if [[ -f "$profile" ]]; then
      saved=$(<"$profile")
      [[ "$current" == "$saved" ]] && echo "Profile: saved, IN SYNC" || {
        echo "Profile: saved, DRIFTED"
        echo "  current: $current"
        echo "  saved:   $saved"
      }
    else
      echo "Profile: none saved (run 'save' while arrangement is correct)"
    fi
    ;;
  list)
    ls -1 "$PROFILE_DIR" 2>/dev/null || echo "No profiles saved yet."
    ;;
  *)
    echo "Usage: display-layout.sh [save|apply|status|list]" >&2
    exit 1
    ;;
esac
