#!/bin/bash
# Connect the configured iPad through the running Hammerspoon controller.
set -euo pipefail
case "${1:-connect}" in
  connect|status)
    exec /opt/homebrew/bin/hs -c \
      "if not sidecar then error('Sidecar is not configured in Hammerspoon') end; print(sidecar:${1:-connect}())"
    ;;
  *) printf 'Usage: sidecar [connect|status]\n' >&2; exit 2 ;;
esac
