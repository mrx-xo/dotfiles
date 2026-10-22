#!/bin/bash
# Drive the configured iPad's Sidecar session through the running Hammerspoon
# controller. connect/disconnect wait for the task to settle (the Lua side is
# asynchronous) so callers such as monitor-mode.sh get a real exit status.
#   SIDECAR_WAIT  seconds to wait for a connect/disconnect to settle (default 30)
#   HS_BIN        the hs CLI (tests stub it)
set -euo pipefail
HS="${HS_BIN:-/opt/homebrew/bin/hs}"
WAIT="${SIDECAR_WAIT:-30}"

hs_eval() {
  "$HS" -c "if not sidecar then error('Sidecar is not configured in Hammerspoon') end; $1"
}

settle() {  # poll lastResult until the task finishes; exit 1 with its text on failure
  local i r
  for ((i = 0; i < WAIT; i++)); do
    r=$(hs_eval 'print(sidecar.lastResult)')
    case "$r" in
      connecting|disconnecting|"waking iPad") sleep 1 ;;
      connected|disconnected|"already connected"|"not connected") echo "$r"; return 0 ;;
      *) echo "$r"; return 1 ;;
    esac
  done
  echo "Sidecar helper did not settle in ${WAIT}s"
  return 1
}

case "${1:-connect}" in
  connect|disconnect)
    hs_eval "print(sidecar:$1())" >/dev/null
    settle
    ;;
  hold|release)
    hs_eval "sidecar:$1(); print(sidecar:status())"
    ;;
  status)
    hs_eval 'print(sidecar:status())'
    ;;
  *) printf 'Usage: sidecar [connect|disconnect|hold|release|status]\n' >&2; exit 2 ;;
esac
