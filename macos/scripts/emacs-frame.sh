#!/bin/bash
# Open a frame on the main daemon, starting it through the diagnostic launcher
# when none answers.  Bound to Cmd+Shift+E.  Never an empty alternate editor: that
# spawns a bare `emacs --daemon` with no run directory, so a later crash is
# neither captured nor bundled (2026-10-27).  A launch refused because one is
# already in progress falls back to waiting for it.
set -u
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
EMACSCLIENT="${EMACSCLIENT:-/opt/homebrew/opt/emacs-plus@31/bin/emacsclient}"
CLIENT=("$EMACSCLIENT" --socket-name=server --alternate-editor=false)
if timeout 5 "${CLIENT[@]}" --eval t >/dev/null 2>&1; then
    exec "${CLIENT[@]}" -c -n
fi
"$SCRIPT_DIR/emacs-daemon-start.sh" && exit 0
exec "$SCRIPT_DIR/emacsclient-frame.sh"
