#!/usr/bin/env bash
# Restart sketchybar after the display arrangement settles.
#
# Called from yabai's display_added / display_removed / display_moved signals.
# A replug, Sidecar connect, or rearrangement fires several of these within a
# second, and sketchybar's in-process display table goes stale: it kept the
# main display twice (one entry with DirectDisplayID 0), pinned a bar to
# the frame it had before the move, and dropped the other displays entirely
# (seen 2026-10-23, sketchybar 2.22.1). The bar then draws across the middle
# of the portrait display.
#
# `sketchybar --reload` only re-runs sketchybarrc; it does not rebuild that
# display table, so it cannot fix this. Only a process restart does.
# `launchctl kickstart -k` kills and relaunches the same launchd job in place,
# which is faster than `brew services restart` and keeps the service managed.
#
# Each call bumps a token and waits; only the last call in a burst restarts.

token_file="${TMPDIR:-/tmp}/sketchybar-display-reload.token"
token="$$-$RANDOM-$(date +%s)"
echo "$token" > "$token_file"

sleep "${SKETCHYBAR_RELOAD_DELAY:-2}"

[[ "$(cat "$token_file" 2>/dev/null)" == "$token" ]] || exit 0

# Homebrew renamed its service labels from homebrew.mxcl.<name> to
# sh.brew.<name>. Probe both so the restart
# does not silently degrade to a --reload (which was the case on 2026-10-23:
# Sidecar connected, label lookup failed, bar stayed on the stale table).
label=""
for candidate in sh.brew.sketchybar homebrew.mxcl.sketchybar; do
  if launchctl print "gui/$(id -u)/$candidate" >/dev/null 2>&1; then
    label="$candidate"
    break
  fi
done

if [[ -n "$label" ]]; then
  launchctl kickstart -k "gui/$(id -u)/$label"
else
  # Not under launchd (manual run): reload configuration as a fallback.
  # This does not repair a stale display table; manually restart that process.
  sketchybar --reload
fi
