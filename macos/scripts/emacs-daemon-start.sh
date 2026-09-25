#!/bin/bash
# Production startup delegates to the shared kill-free diagnostic launcher.
# Restart/shutdown authorization and lifecycle actions belong to the caller.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
EMACS="${EMACS:-/opt/homebrew/opt/emacs-plus@30/bin/emacs}"
EMACSCLIENT="${EMACSCLIENT:-/opt/homebrew/opt/emacs-plus@30/bin/emacsclient}"
INIT_DIR="${EMACS_CONFIG_SOURCE:-$HOME/.emacs.d}"
RUNTIME_ARGS=()
[[ -z "${EMACS_RUNTIME_DIRECTORY:-}" ]] || RUNTIME_ARGS=(--runtime-directory "$EMACS_RUNTIME_DIRECTORY")
# The sketchybar cacodemon (plugins/emacs-status.sh); Emacs takes over the
# narration once init.el starts. Never let the bar block or fail a launch.
# launchd re-runs this script while a daemon is already up (the launch is then
# refused), so stay silent when one exists or the bar blinks "starting".
bar() { pgrep -qf -- '--fg-daemon=server' && [[ "$1" == starting ]] && return 0
        command -v sketchybar >/dev/null && sketchybar --trigger emacs_status_update "EMACS_STATUS_STATE=$1" "EMACS_STATUS_LABEL=$2" >/dev/null 2>&1 || true; }
TIMEOUT="${EMACS_START_TIMEOUT:-120}"
bar starting "starting"
status=0
result=$("$SCRIPT_DIR/emacs-daemon-run.sh" --server server --init-directory "$INIT_DIR" --emacs "$EMACS" --emacsclient "$EMACSCLIENT" --timeout "$TIMEOUT" ${RUNTIME_ARGS[@]+"${RUNTIME_ARGS[@]}"}) || status=$?
if [[ -z "$result" ]]; then
    # Launch refused (a daemon already runs): nothing started, bar untouched.
    exit "$status"
fi
echo "$result"
if [[ "$result" != *'"status": "ready"'* ]]; then
    bar notready "not ready after ${TIMEOUT}s"
    exit "$(( status == 0 ? 1 : status ))"
fi
if [[ -f /tmp/emacs-restore-session ]]; then
    echo "Restore flag found, skipping default frame"
else
    timeout 5 "$EMACSCLIENT" --socket-name=server -c -n
fi
