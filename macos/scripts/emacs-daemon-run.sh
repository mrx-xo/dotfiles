#!/bin/bash
# Shared, kill-free startup path.  All identity and log setup is explicit.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/emacs-daemon-run.py" "$@"
