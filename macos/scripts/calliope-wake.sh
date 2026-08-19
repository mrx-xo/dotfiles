#!/usr/bin/env bash
# calliope-wake.sh — wake the CALLIOPE Boox Tab Ultra C's screen over the tailnet.
#
#   calliope-wake.sh          # adb connect + KEYCODE_WAKEUP, verify sshd
#   calliope-wake.sh emx      # wake + launch emx (live emacsclient tty) on the e-ink
#   calliope-wake.sh sleep    # opposite: put the screen to sleep
#
# HARD LIMIT: this is a screen-wake, not a power-on. BOOX kills the Wi-Fi
# radio when the screen sleeps off-charger, and there is no Wake-on-WLAN —
# an offline CALLIOPE cannot be woken remotely at all. Keep it on a charger
# (stay_on_while_plugged_in=7 → screen never sleeps → always on tailnet).
#
# adb-over-TCP must be armed once per tablet reboot, over USB:
#   adb -s B79B7A06 tcpip 5555
# (tcpip mode does not survive reboots on unrooted devices.)

set -euo pipefail

IP="100.64.109.111"   # tailnet; matches Host boox/calliope in ~/.ssh/config
ADB="$IP:5555"

notify() {
  osascript -e "display notification \"$1\" with title \"CALLIOPE\"" 2>/dev/null || true
}

if ! adb connect "$ADB" | grep -q connected; then
  notify "adb connect failed — tablet off Wi-Fi? (screen asleep off-charger)"
  echo "adb connect $ADB failed. If it just rebooted, re-arm over USB:" >&2
  echo "  adb -s B79B7A06 tcpip 5555" >&2
  exit 1
fi

if [ "${1:-}" = sleep ]; then
  adb -s "$ADB" shell input keyevent KEYCODE_SLEEP
  echo "CALLIOPE screen put to sleep"
  exit 0
fi

adb -s "$ADB" shell input keyevent KEYCODE_WAKEUP
echo "wake keyevent sent"

if [ "${1:-}" = emx ]; then
  # Clean slate both ends, then launch exactly one fresh emx session.
  # Anything running in old Termux sessions dies here (dumb-glass model).
  emacsclient --eval \
    "(dolist (f (frame-list)) (unless (display-graphic-p f) (delete-frame f t)))" \
    >/dev/null 2>&1 || true
  adb -s "$ADB" shell am force-stop com.termux   # kills sshd too; emx restarts it
  sleep 1
  # Termux RUN_COMMAND intent (needs allow-external-apps=true in
  # ~/.termux/termux.properties on the tablet, and a one-time
  # `pm grant com.android.shell com.termux.permission.RUN_COMMAND`;
  # both applied 2026-08-18). Must run BEFORE raising the activity —
  # an activity with no sessions auto-creates a bare bash one.
  adb -s "$ADB" shell am startservice --user 0 \
    -n com.termux/com.termux.app.RunCommandService \
    -a com.termux.RUN_COMMAND \
    --es com.termux.RUN_COMMAND_PATH '/data/data/com.termux/files/home/.shortcuts/emx'
  sleep 2
  # RUN_COMMAND starts the session but doesn't raise the window
  adb -s "$ADB" shell am start -n com.termux/com.termux.app.TermuxActivity
  notify "emx launched on the e-ink"
  echo "emx launched (old sessions/frames cleaned)"
  exit 0
fi

# sshd (Termux) up = fully usable for emx et al.
if nc -z -G 3 "$IP" 8022 2>/dev/null; then
  notify "CALLIOPE awake — sshd up"
  echo "CALLIOPE awake, ssh boox ready"
else
  notify "Screen woken but sshd down — tap the emx widget or run sshd in Termux"
  echo "screen awake but no sshd on :8022 (Termux not running? boot lag?)"
fi
