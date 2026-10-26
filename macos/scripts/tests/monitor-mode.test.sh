#!/usr/bin/env bash
# monitor-mode.test.sh — stub-harness regressions for monitor-mode.sh.
# betterdisplaycli / displayplacer / yabai / ssh / osascript are faked on PATH and
# every call is logged, so the script's decisions can be asserted without
# touching real monitors. HOME is redirected so the real state dir is safe.
#
#   ~/.dotfiles/macos/scripts/tests/monitor-mode.test.sh
set -u
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/monitor-mode.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat > "$T/bin/betterdisplaycli" <<'STUB'
#!/usr/bin/env bash
# DDC writes succeed; romulus reads HDMI2 as BetterDisplay's raw value
# (0x1112 -> low byte 18). A display showing another machine is
# disconnected Mac-side, so its reads fail.
echo "betterdisplaycli $*" >> "$HOME/calls.log"
if [ "$1" = get ] && [[ "$*" == *"--uuid=8C207E30-FF6D-4624-A998-F6D7962597F6"* ]] && [[ "$*" == *"--ddc"* ]]; then
  [ -e "$HOME/romulus-away" ] && { echo Failed.; exit 1; }
  echo 4370
fi
exit 0
STUB
cat > "$T/bin/displayplacer" <<'STUB'
#!/usr/bin/env bash
# both Dells online Mac-side
echo "Persistent screen id: 0CDDE5CC-F566-4B56-85FD-48B8EA229946"
echo "Persistent screen id: 8C207E30-FF6D-4624-A998-F6D7962597F6"
STUB
for s in osascript ssh; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "$HOME/calls.log"; exit 0\n' "$s" > "$T/bin/$s"
done
printf '#!/usr/bin/env bash\necho "yabai $*" >> "$HOME/calls.log"; echo "[]"; exit 0\n' > "$T/bin/yabai"
chmod +x "$T/bin/"*

export HOME="$T/home" PATH="$T/bin:$PATH"
S="$HOME/.local/state/monitor-mode"
fresh() { rm -rf "$HOME"; mkdir -p "$S"; echo "$1" > "$S/romulus"; echo "$2" > "$S/remus"; }
fail=0
t() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; cat "$HOME/calls.log" 2>/dev/null; fail=1; fi; }

fresh pollux work; "$SCRIPT" remus work >/dev/null 2>&1
t "remus work re-disconnects a re-enumerated display (dock replug, 2026-09-21)" \
  'grep -q -- "--uuid=0CDDE5CC-F566-4B56-85FD-48B8EA229946 --connected=off" "$HOME/calls.log"'

fresh pollux work; "$SCRIPT" reset >/dev/null 2>&1
t "reset: DDCs both displays to the POLLUX input" \
  'grep -q "set --uuid=8C207E30.* --ddc --vcp=inputSelect --value=18" "$HOME/calls.log" && grep -q "set --uuid=0CDDE5CC.* --ddc --vcp=inputSelect --value=18" "$HOME/calls.log"'
t "reset: state files say pollux" '[ "$(cat "$S/romulus")" = pollux ] && [ "$(cat "$S/remus")" = pollux ]'
t "reset: never disconnects" '! grep -q -- "--connected=off" "$HOME/calls.log"'
t "reset: busy lock removed on exit" '[ ! -e "$S/busy" ]'

fresh pollux work; "$SCRIPT" check >/dev/null 2>&1
t "check: notifies when remus is back but state says work" \
  'grep -q "REMUS is back on POLLUX but state says work. Press ctrl+alt+w" "$HOME/calls.log"'

fresh pollux work; touch "$S/busy"; "$SCRIPT" check >/dev/null 2>&1
t "check: silent while a flip is in flight" '! grep -q "osascript" "$HOME/calls.log" 2>/dev/null'

fresh pollux pollux; "$SCRIPT" check >/dev/null 2>&1
t "check: silent when everything is on POLLUX" '! grep -q "osascript" "$HOME/calls.log" 2>/dev/null'
rm -rf "$HOME"; mkdir -p "$S"; echo nemesis > "$S/center"; echo work > "$S/right"
"$SCRIPT" status >/dev/null 2>&1
t "legacy center/right state files migrate to romulus/remus (2026-09-29 rename)" \
  '[ "$(cat "$S/romulus")" = nemesis ] && [ "$(cat "$S/remus")" = work ] && [ ! -e "$S/center" ]'

fresh mac pc; "$SCRIPT" status >/dev/null 2>&1
t "legacy mac/pc state contents migrate to pollux/nemesis" \
  '[ "$(cat "$S/romulus")" = pollux ] && [ "$(cat "$S/remus")" = nemesis ]'

fresh pollux pollux; "$SCRIPT" pollux nemesis >/dev/null 2>&1
t "pollux nemesis: ROMULUS stays on POLLUX, REMUS -> NEMESIS (DP)" \
  'grep -q "set --uuid=0CDDE5CC.* --ddc --vcp=inputSelect --value=15" "$HOME/calls.log" && [ "$(cat "$S/remus")" = nemesis ] && [ "$(cat "$S/romulus")" = pollux ]'
t "pollux nemesis: notification names both panels and machines" \
  'grep -q "ROMULUS -> POLLUX, REMUS -> NEMESIS" "$HOME/calls.log"'

fresh pollux pollux; "$SCRIPT" nemesis >/dev/null 2>&1
t "nemesis alone: both panels -> NEMESIS" \
  '[ "$(cat "$S/romulus")" = nemesis ] && [ "$(cat "$S/remus")" = nemesis ]'

fresh pollux pollux; "$SCRIPT" game >/dev/null 2>&1
t "legacy game still means both -> NEMESIS" \
  '[ "$(cat "$S/romulus")" = nemesis ] && [ "$(cat "$S/remus")" = nemesis ]'

fresh pollux pollux; "$SCRIPT" 4 pc >/dev/null 2>&1
t "legacy 4 pc still means REMUS -> NEMESIS" '[ "$(cat "$S/remus")" = nemesis ]'

fresh pollux pollux; "$SCRIPT" pollux bogus >/dev/null 2>&1
t "unknown machine name is refused before any DDC write" '! grep -q -- "--ddc" "$HOME/calls.log" 2>/dev/null'

fresh pollux pollux; "$SCRIPT" flip >/dev/null 2>&1
t "flip: normal -> flipped, and no SSH while the Dells are on POLLUX" \
  '[ "$(cat "$S/facing")" = flipped ] && ! grep -q "^ssh" "$HOME/calls.log" 2>/dev/null'
"$SCRIPT" flip >/dev/null 2>&1
t "flip again: back to normal" '[ "$(cat "$S/facing")" = normal ]'

fresh nemesis nemesis; touch "$HOME/romulus-away"; echo normal > "$S/facing"; "$SCRIPT" flip >/dev/null 2>&1
t "flip with both Dells on NEMESIS runs mon-layout-flipped then mon-assert" \
  'grep -q "schtasks /run /tn mon-layout-flipped && .*mon-assert" "$HOME/calls.log"'

fresh pollux pollux; touch "$HOME/romulus-away"; echo flipped > "$S/facing"; "$SCRIPT" nemesis >/dev/null 2>&1
t "desk nemesis chains mon-extend, the current layout, then mon-assert" \
  'grep -q "mon-extend && .*mon-layout-flipped && .*mon-assert" "$HOME/calls.log"'

fresh pollux pollux; "$SCRIPT" pollux nemesis >/dev/null 2>&1
t "one Dell on NEMESIS: no layout task" '! grep -q "mon-layout" "$HOME/calls.log"'

fresh pollux pollux; printf '#!/usr/bin/env bash\nexit 139\n' > "$T/bin/m1ddc"; chmod +x "$T/bin/m1ddc"
"$SCRIPT" nemesis >/dev/null 2>&1
t "a crashing m1ddc (Sidecar attached) no longer matters: both Dells switch" \
  '[ "$(cat "$S/romulus")" = nemesis ] && [ "$(cat "$S/remus")" = nemesis ]'
exit $fail
