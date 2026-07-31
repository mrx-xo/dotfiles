#!/usr/bin/env bash
# vengeance-wake.sh — power on / wake VENGEANCE via Wake-on-LAN.
#
#   vengeance-wake.sh           # send magic packet, notify when SSH is up
#   vengeance-wake.sh <preset>  # ...then run monitor-mode.sh <preset> — any
#                               # preset that puts VENGEANCE on glass (game,
#                               # rsplit, split, ...) is a full summon
#
# PC: Realtek 5GbE onboard, MAC 34:5A:60:C0:95:87, 192.168.1.156.
# Windows side verified 2026-07-17: WakeOnMagicPacket enabled, Fast
# Startup disabled. Wake from full shutdown (S5) additionally needs
# the BIOS "Wake on LAN / Resume by PCI-E" toggle.

set -euo pipefail

MAC="34:5A:60:C0:95:87"

notify() {
  osascript -e "display notification \"$1\" with title \"VENGEANCE\"" || true
}

send_magic_packet() {
  python3 - "$MAC" <<'PY'
import socket, sys
mac = bytes.fromhex(sys.argv[1].replace(":", ""))
pkt = b"\xff" * 6 + mac * 16
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
for port in (7, 9):
    s.sendto(pkt, ("255.255.255.255", port))
    s.sendto(pkt, ("192.168.1.255", port))
s.close()
print("magic packet sent")
PY
}

# Fast path (CM v3): preset keys route here — if VENGEANCE is already
# up, skip the wake dance and go straight to the handover.
if ssh -o ConnectTimeout=2 -o BatchMode=yes vengeance "exit" 2>/dev/null; then
  if [ -n "${1:-}" ]; then
    ~/.dotfiles/macos/scripts/monitor-mode.sh "$1"
  else
    notify "VENGEANCE is already awake"
  fi
  exit 0
fi

send_magic_packet
notify "Magic packet sent — summoning..."

# Poll until SSH answers (boot from S5 can take a while)
for i in $(seq 1 45); do
  if ssh -o ConnectTimeout=2 -o BatchMode=yes vengeance "exit" 2>/dev/null; then
    notify "VENGEANCE is awake (${i}x2s)"
    if [ -n "${1:-}" ]; then
      sleep 2
      ~/.dotfiles/macos/scripts/monitor-mode.sh "$1"
    fi
    exit 0
  fi
  sleep 2
done

notify "No response after 90s — check BIOS WoL setting?"
exit 1
