#!/usr/bin/env bash
# mon-voice-gate.test.sh — the forced-command gate for the HA voice key.
# Stubs monitor-mode.sh and keyboard-lights under a throwaway HOME and checks
# which commands pass, and to which script, by SSH_ORIGINAL_COMMAND.
set -u
GATE="$(cd "$(dirname "$0")/.." && pwd)/mon-voice-gate.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.dotfiles/macos/scripts" "$TMP/.local/state/monitor-mode"
for s in monitor-mode.sh keyboard-lights; do
  printf '#!/bin/bash\necho "%s $*" >> "$HOME/calls.log"\n' "$s" > "$TMP/.dotfiles/macos/scripts/$s"
  chmod +x "$TMP/.dotfiles/macos/scripts/$s"
done

pass=0; fail=0
check() {  # check <desc> <ssh command> <expected rc> <expected calls.log line or ->
  local desc="$1" cmd="$2" want_rc="$3" want_call="$4" rc
  rm -f "$TMP/calls.log"
  HOME="$TMP" SSH_ORIGINAL_COMMAND="$cmd" bash "$GATE" >/dev/null 2>&1; rc=$?
  local got_call; got_call=$(cat "$TMP/calls.log" 2>/dev/null || echo -)
  if [ "$rc" = "$want_rc" ] && [ "$got_call" = "$want_call" ]; then
    echo "PASS: $desc"; pass=$((pass+1))
  else
    echo "FAIL: $desc (rc $rc, calls: $got_call)"; fail=$((fail+1))
  fi
}

check "displays sleep still reaches monitor-mode" "displays sleep" 0 "monitor-mode.sh displays sleep"
check "keyboards off runs keyboard-lights off"   "keyboards off"  0 "keyboard-lights off"
check "keyboards on runs keyboard-lights on"     "keyboards on"   0 "keyboard-lights on"
check "keyboards bogus is refused"               "keyboards bogus" 1 -
check "keyboards off; id is refused"             "keyboards off; id" 1 -
check "empty command is refused"                 "" 1 -

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
