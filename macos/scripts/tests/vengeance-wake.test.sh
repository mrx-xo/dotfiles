#!/usr/bin/env bash
# vengeance-wake.test.sh — stub-harness regressions for vengeance-wake.sh.
# ssh / python3 / osascript are faked on PATH and logged; monitor-mode.sh is
# a stub whose "armed" output is controlled by $HOME/armed-stub.
#   ~/.dotfiles/macos/scripts/tests/vengeance-wake.test.sh
set -u
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/vengeance-wake.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
for s in osascript python3; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "$HOME/calls.log"; exit 0\n' "$s" > "$T/bin/$s"
done
# VENGEANCE asleep: every ssh fails
printf '#!/usr/bin/env bash\necho "ssh $*" >> "$HOME/calls.log"; exit 255\n' > "$T/bin/ssh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/sleep"
cat > "$T/bin/monitor-mode.sh" <<'STUB'
#!/usr/bin/env bash
echo "monitor-mode $*" >> "$HOME/calls.log"
[ "$1" = armed ] && cat "$HOME/armed-stub" 2>/dev/null
exit 0
STUB
chmod +x "$T/bin/"*
fail=0
run() { rm -f "$T/calls.log"; HOME="$T" PATH="$T/bin:/usr/bin:/bin" MONITOR_MODE_SH="$T/bin/monitor-mode.sh" bash "$SCRIPT" "$@" >/dev/null 2>&1; }
check() { if grep -q "$2" "$T/calls.log" 2>/dev/null; then r=0; else r=1; fi; [ "$r" = "$3" ] && echo "PASS: $1" || { echo "FAIL: $1"; cat "$T/calls.log"; fail=1; }; }

printf 'nyx\n' > "$T/armed-stub"
run fire nemesis
check "only NYX armed: no magic packet" "python3" 1
check "only NYX armed: fire goes straight to monitor-mode" "monitor-mode fire nemesis" 0

printf 'romulus\nnyx\n' > "$T/armed-stub"
run fire nemesis
check "a Dell armed while asleep: magic packet sent" "python3" 0

: > "$T/armed-stub"
run fire nemesis
check "nothing armed means both Dells: magic packet sent" "python3" 0
exit $fail
