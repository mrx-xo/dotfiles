#!/usr/bin/env bash
# mrx2-wake.sh — wake the MrX2 MacBook Air via Wake-on-LAN.
#
#   mrx2-wake.sh          # LAN broadcast, poll ssh, notify
#   mrx2-wake.sh relay    # send via homelab instead (works from off-LAN,
#                         # e.g. over the tailnet when traveling)
#
# Air: Wi-Fi MAC 14:7f:ce:c8:9d:8a, usually 192.168.1.190 (DHCP).
# Verified 2026-07-22: woke in ~2s from a 30min battery sleep even with
# `womp 0` on battery (Apple sleep-proxy behavior). Caveats:
#   - womp is only *guaranteed* on AC (`pmset -g custom`); enable on battery
#     with: sudo pmset -b womp 1   (run on the Air)
#   - Deep standby/hibernate (hours asleep on battery) may not wake at all.
#   - Lid-closed wake lands in dark-wake: SSH works, no display.

set -euo pipefail

MAC="14:7f:ce:c8:9d:8a"

notify() {
  osascript -e "display notification \"$1\" with title \"MrX2\"" 2>/dev/null || true
}

send_magic_packet_local() {
  python3 - "$MAC" <<'PY'
import socket, sys
mac = bytes.fromhex(sys.argv[1].replace(":", ""))
pkt = b"\xff" * 6 + mac * 16
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
for port in (7, 9):
    s.sendto(pkt, ("255.255.255.255", port))
    s.sendto(pkt, ("192.168.1.255", port))
    s.sendto(pkt, ("192.168.1.190", port))
s.close()
print("magic packet sent (local broadcast)")
PY
}

send_magic_packet_relay() {
  ssh -o ConnectTimeout=5 homelab "wakeonlan $MAC"
  echo "magic packet sent (via homelab)"
}

if [ "${1:-}" = relay ]; then
  send_magic_packet_relay
else
  send_magic_packet_local
fi
notify "Magic packet sent — waking the Air..."

for i in $(seq 1 20); do
  if ssh -o ConnectTimeout=2 -o BatchMode=yes mrx2 "exit" 2>/dev/null; then
    notify "MrX2 is awake (${i}x2s)"
    echo "MrX2 awake after ~$((i*2))s"
    exit 0
  fi
  sleep 2
done

notify "No response after 40s — deep standby? Try: mrx2-wake.sh relay"
exit 1
