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
"$SCRIPT_DIR/emacs-daemon-run.sh" --server server --init-directory "$INIT_DIR" --emacs "$EMACS" --emacsclient "$EMACSCLIENT" --timeout "${EMACS_START_TIMEOUT:-120}" ${RUNTIME_ARGS[@]+"${RUNTIME_ARGS[@]}"}
if [[ -f /tmp/emacs-restore-session ]]; then
    echo "Restore flag found, skipping default frame"
else
    timeout 5 "$EMACSCLIENT" --socket-name=server -c -n
fi
