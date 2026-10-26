#!/usr/bin/env bash
# sidecar.test.sh — sidecar.sh must wait for the Hammerspoon task to finish
# and exit non-zero when it fails. hs is stubbed: lastResult stays "connecting"
# for two polls, then becomes $HOME/hs-final.
set -u
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/sidecar.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat > "$T/bin/hs" <<'STUB'
#!/usr/bin/env bash
echo "hs $*" >> "$HOME/calls.log"
case "$*" in
  *lastResult*)
    n=$(cat "$HOME/polls" 2>/dev/null || echo 0); echo $((n+1)) > "$HOME/polls"
    if [ "$n" -lt 2 ]; then echo "connecting"; else cat "$HOME/hs-final"; fi ;;
  *"sidecar:connect()"*) echo "connecting" ;;
  *"sidecar:disconnect()"*) echo "disconnecting" ;;
  *"sidecar:status()"*) echo "iPad connected; auto-connect on; last result: idle; hold off" ;;
  *) echo "" ;;
esac
STUB
chmod +x "$T/bin/hs"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/sleep"; chmod +x "$T/bin/sleep"
fail=0
run() { rm -f "$T/calls.log" "$T/polls"; HOME="$T" PATH="$T/bin:/usr/bin:/bin" HS_BIN="$T/bin/hs" bash "$SCRIPT" "$@" > "$T/out" 2>&1; echo $? > "$T/rc"; }
check() { [ "$(cat "$T/rc")" = "$2" ] && echo "PASS: $1" || { echo "FAIL: $1 (rc $(cat "$T/rc"))"; cat "$T/out"; fail=1; }; }

echo connected > "$T/hs-final"
run connect
check "connect waits for the task and exits 0 on connected" 0
[ "$(cat "$T/polls")" -ge 3 ] && echo "PASS: connect polled lastResult until it settled" || { echo "FAIL: did not poll"; fail=1; }

echo 'Error Domain=SidecarErrorDomain Code=-201 "SidecarErrorDeviceTimedOut"' > "$T/hs-final"
run connect
check "connect exits 1 when the task fails" 1
grep -q "SidecarErrorDeviceTimedOut" "$T/out" && echo "PASS: failure text reaches the caller" || { echo "FAIL: no failure text"; fail=1; }

echo disconnected > "$T/hs-final"
run disconnect
check "disconnect waits and exits 0 on disconnected" 0

run status
check "status is a plain print" 0
exit $fail
