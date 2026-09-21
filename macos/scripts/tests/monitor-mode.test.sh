#!/usr/bin/env bash
# monitor-mode.test.sh — stub-harness regressions for monitor-mode.sh.
# m1ddc / betterdisplaycli / yabai / ssh / osascript are faked on PATH and
# every call is logged, so the script's decisions can be asserted without
# touching real monitors. HOME is redirected so the real state dir is safe.
#
#   ~/.dotfiles/macos/scripts/tests/monitor-mode.test.sh
set -u
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/monitor-mode.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat > "$T/bin/m1ddc" <<'STUB'
#!/usr/bin/env bash
# both displays enumerated Mac-side; center reads HDMI2 (18); writes succeed
case "$1 $2" in
  "display list") echo "[1] S2719DGF (0CDDE5CC-F566-4B56-85FD-48B8EA229946)"; echo "[3] S2719DGF (8C207E30-FF6D-4624-A998-F6D7962597F6)" ;;
  "display 8C207E30-FF6D-4624-A998-F6D7962597F6") [ "$3" = get ] && echo 18 ;;
esac
echo "m1ddc $*" >> "$HOME/calls.log"; exit 0
STUB
for s in betterdisplaycli osascript ssh; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "$HOME/calls.log"; exit 0\n' "$s" > "$T/bin/$s"
done
printf '#!/usr/bin/env bash\necho "yabai $*" >> "$HOME/calls.log"; echo "[]"; exit 0\n' > "$T/bin/yabai"
chmod +x "$T/bin/"*

export HOME="$T/home" PATH="$T/bin:$PATH"
S="$HOME/.local/state/monitor-mode"
fresh() { rm -rf "$HOME"; mkdir -p "$S"; echo "$1" > "$S/center"; echo "$2" > "$S/right"; }
fail=0
t() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; cat "$HOME/calls.log" 2>/dev/null; fail=1; fi; }

fresh mac work; "$SCRIPT" right work >/dev/null 2>&1
t "right work re-disconnects a re-enumerated display (dock replug, 2026-09-21)" \
  'grep -q -- "--uuid=0CDDE5CC-F566-4B56-85FD-48B8EA229946 --connected=off" "$HOME/calls.log"'

fresh mac work; "$SCRIPT" reset >/dev/null 2>&1
t "reset: DDCs both displays to the Mac input" \
  'grep -q "m1ddc display 8C207E30.* set input 18" "$HOME/calls.log" && grep -q "m1ddc display 0CDDE5CC.* set input 18" "$HOME/calls.log"'
t "reset: state files say mac" '[ "$(cat "$S/center")" = mac ] && [ "$(cat "$S/right")" = mac ]'
t "reset: never disconnects" '! grep -q -- "--connected=off" "$HOME/calls.log"'
t "reset: busy lock removed on exit" '[ ! -e "$S/busy" ]'

fresh mac work; "$SCRIPT" check >/dev/null 2>&1
t "check: notifies when right is back but state says work" \
  'grep -q "right monitor is back on the Mac but state says work. Press ctrl+alt+w" "$HOME/calls.log"'

fresh mac work; touch "$S/busy"; "$SCRIPT" check >/dev/null 2>&1
t "check: silent while a flip is in flight" '! grep -q "osascript" "$HOME/calls.log" 2>/dev/null'

fresh mac mac; "$SCRIPT" check >/dev/null 2>&1
t "check: silent when everything is on the Mac" '! grep -q "osascript" "$HOME/calls.log" 2>/dev/null'
exit $fail
