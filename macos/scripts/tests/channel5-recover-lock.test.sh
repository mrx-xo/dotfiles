#!/bin/bash
# The launcher archives a dead producer's .preparing lock before preparing a
# fresh briefing, and leaves a live producer's lock alone. External commands
# (yabai, node, npm, python3's recovery script) are stubbed; nothing launches.
set -euo pipefail
script="$(cd "$(dirname "$0")/.." && pwd)/channel5.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
app="$tmp/app"; data="$tmp/data"; bin="$tmp/bin"
mkdir -p "$app/preparation" "$data/sergio" "$bin"
touch "$app/prepare.mjs"
# Stand-in for ~/channel5/preparation/recover-lock.py: same contract, archives
# the lock only when owner.json names a dead PID.
cat > "$app/preparation/recover-lock.py" <<'PY'
import json, os, sys
from pathlib import Path
owner = Path(sys.argv[1]); lock = owner / '.preparing'
Path(os.environ['CALLS']).open('a').write('recover ' + str(owner) + '\n')
if lock.exists():
    pid = json.loads((lock / 'owner.json').read_text())['pid']
    try: os.kill(pid, 0)
    except ProcessLookupError: lock.rename(owner / '.abandoned-lock-test')
PY
for cmd in yabai npm agent-space-ensure; do
  printf '#!/bin/bash\necho "%s $*" >> "$CALLS"\n[ "$1" = -m ] && echo "[]"\nexit 0\n' "$cmd" > "$bin/$cmd"
done
# node: the spaces check (-e) passes; prepare.mjs records the call and returns a path.
cat > "$bin/node" <<'SH'
#!/bin/bash
echo "node $*" >> "$CALLS"
case "$1" in prepare.mjs) echo "$tmp_run";; esac
exit 0
SH
chmod +x "$bin"/*
export CALLS="$tmp/calls" CHANNEL5_CONFIG=/dev/null CHANNEL5_APP_DIR="$app" \
  CHANNEL5_DATA_DIR="$data" CHANNEL5_HA_URL=http://ha.test CHANNEL5_TOKEN_FILE="$tmp/token" tmp_run="$tmp/run.json"
echo tok > "$tmp/token"
fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. Dead owner: lock archived, then prepare runs.
mkdir "$data/sergio/.preparing"; echo '{"pid":999999,"started_at":"x"}' > "$data/sergio/.preparing/owner.json"
: > "$CALLS"; PATH="$bin:$PATH" bash "$script" --refresh >/dev/null
[ -d "$data/sergio/.abandoned-lock-test" ] || fail "dead lock was not archived"
grep -q "^recover $data/sergio$" "$CALLS" || fail "recovery not invoked on the sergio directory"
[ "$(grep -n -m1 '^recover' "$CALLS" | cut -d: -f1)" -lt "$(grep -n -m1 'prepare.mjs' "$CALLS" | cut -d: -f1)" ] || fail "recovery must run before prepare.mjs"
rm -r "$data/sergio/.abandoned-lock-test"

# 2. Live owner (this shell): lock untouched.
mkdir "$data/sergio/.preparing"; echo "{\"pid\":$$,\"started_at\":\"x\"}" > "$data/sergio/.preparing/owner.json"
: > "$CALLS"; PATH="$bin:$PATH" bash "$script" --refresh >/dev/null
[ -d "$data/sergio/.preparing" ] || fail "live lock was removed"

# 3. Without --refresh and no saved run, preparation still recovers first.
rm -r "$data/sergio/.preparing"
: > "$CALLS"; PATH="$bin:$PATH" bash "$script" >/dev/null
grep -q '^recover ' "$CALLS" || fail "recovery skipped on the fallback prepare path"
echo "PASS: channel5 launcher recovers a dead .preparing lock before preparing"
