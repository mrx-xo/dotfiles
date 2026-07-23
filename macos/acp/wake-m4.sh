#!/bin/bash
# One-shot wake + open for the M4 agent workstation (R7.3,
# docs/prd-remote-agent-access.md). Run this from the MacBook Air.
#
# Wakes the M4 via the always-on home server (WoL relay over Tailscale),
# waits for boot + tailnet reconnect, then opens the acp-mobile UI.
#
# Prereqs on the home server: `wakeonlan` installed (verified 2026-07-22),
# SSH reachable as "homelab" (the fleet alias — see machines/home-lab.md).
set -euo pipefail

# M4 wired Ethernet (en8, USB 10/100/1G/2.5G LAN) — the interface holding
# the default route. Re-check with: networksetup -listallhardwareports
M4_MAC="98:fc:84:e9:ab:e7"
HOMESERVER="${HOMESERVER:-homelab}"
LINK_URL="${ACP_LINK_URL:-http://mrx.tail9179e0.ts.net:8090}"

ssh "$HOMESERVER" "wakeonlan $M4_MAC"
echo "Magic packet sent. Waiting for M4 to wake..."

for i in $(seq 1 30); do
  if curl -s -o /dev/null --max-time 2 "$LINK_URL"; then
    echo "M4 is up."
    open "$LINK_URL"
    exit 0
  fi
  sleep 2
done

echo "M4 did not come up within 60s. Check: ssh $HOMESERVER, tailscale status." >&2
exit 1
