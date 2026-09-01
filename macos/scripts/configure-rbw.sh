#!/bin/bash

set -euo pipefail

RBW_EMAIL="m00r0@proton.me"
RBW_BASE_URL="https://home-lab.tail9179e0.ts.net:8443"

RBW_BIN="$(command -v rbw || true)"
if [ -z "$RBW_BIN" ]; then
    echo "rbw not found; install it from macos/Brewfile first" >&2
    exit 1
fi

PINENTRY_BIN="$(command -v pinentry-mac || true)"
if [ -z "$PINENTRY_BIN" ]; then
    echo "pinentry-mac not found; install it from macos/Brewfile first" >&2
    exit 1
fi

"$RBW_BIN" config set email "$RBW_EMAIL"
"$RBW_BIN" config set base_url "$RBW_BASE_URL"
"$RBW_BIN" config set pinentry "$PINENTRY_BIN"

echo "Configured rbw for $RBW_EMAIL at $RBW_BASE_URL"
