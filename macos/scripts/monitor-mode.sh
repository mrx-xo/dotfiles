#!/usr/bin/env bash
# monitor-mode.sh — point any monitor at any machine via DDC (m1ddc).
#
# Presets:
#   monitor-mode.sh game            # center+right -> VENGEANCE
#   monitor-mode.sh mac             # center+right -> MrX
#   monitor-mode.sh work            # right -> work laptop
#
# Per-display (mix & match freely):
#   monitor-mode.sh center mac|pc
#   monitor-mode.sh right  mac|pc|work
#
# Toggles (flip a display between Mac <-> PC):
#   monitor-mode.sh toggle center
#   monitor-mode.sh toggle right
#
# Displays pinned by UUID so replug order can't break this.
# Verified 2026-07-17: DDC WRITES reach both monitors from the Mac at
# all times (even while a monitor displays another input). DDC READS
# only work on center (direct dock HDMI); the right monitor sits
# behind an Anker 310 USB-C->HDMI adapter that passes writes but
# blocks reads — so current-state comes from a state file for it.
#
# A display pointed at another machine is also DISCONNECTED from macOS
# (betterdisplaycli, needs BetterDisplay.app running + Pro) so the Mac
# has no phantom desktop for windows/mouse to land on. Verified
# 2026-07-22: connected=off truly drops it (yabai sees 3 displays);
# reconnect re-enumerates in ~4-10s; m1ddc can NOT address a display
# while it's disconnected — hence the connect-first ordering below.
#
# S2719DGF VCP 60 input values: DP=15, HDMI1(1.4)=17, HDMI2(2.0)=18
# Portrait (S2725HS) is Mac-only for now — no PC cable run to it.

set -euo pipefail

CENTER="8C207E30-FF6D-4624-A998-F6D7962597F6"  # yabai display 3, Main Left
RIGHT="0CDDE5CC-F566-4B56-85FD-48B8EA229946"   # yabai display 4, Main Right

DP=15       # VENGEANCE
HDMI_14=17  # work laptop hub
HDMI_20=18  # MrX via dock

STATE_DIR="$HOME/.local/state/monitor-mode"
mkdir -p "$STATE_DIR"

notify() {
  osascript -e "display notification \"$1\" with title \"Monitor Mode\"" || true
}

uuid_for() {
  case "$1" in
    center) echo "$CENTER" ;;
    right)  echo "$RIGHT" ;;
    *) echo "unknown display: $1 (want center|right)" >&2; exit 1 ;;
  esac
}

input_for() {
  case "$1" in
    mac)  echo $HDMI_20 ;;
    pc)   echo $DP ;;
    work) echo $HDMI_14 ;;
    *) echo "unknown machine: $1 (want mac|pc|work)" >&2; exit 1 ;;
  esac
}

bd_connect() {  # bd_connect <center|right> <on|off>
  betterdisplaycli set --uuid="$(uuid_for "$1")" --connected="$2" > /dev/null 2>&1
}

ddc_visible() {  # is the display enumerated Mac-side (addressable by m1ddc)?
  [[ "$(m1ddc display list 2>/dev/null)" == *"$(uuid_for "$1")"* ]]
}

wait_ddc() {  # poll until a reconnected display re-enumerates (~4-10s typical)
  local i
  for i in $(seq 1 15); do
    ddc_visible "$1" && return 0
    sleep 1
  done
  return 1
}

set_display() {  # set_display <center|right> <mac|pc|work>
  # DDC only reaches the display while the Mac-side connection is up,
  # so: ensure connected -> DDC-switch input -> disconnect unless the
  # target is the Mac itself.
  # The Anker adapter throws transient DDC I/O errors — retry before
  # giving up, and never record state for a flip that didn't happen.
  local try
  if ! ddc_visible "$1"; then
    bd_connect "$1" on
    wait_ddc "$1" || { notify "FAILED: $1 never re-enumerated"; return 1; }
  fi
  for try in 1 2 3; do
    if m1ddc display "$(uuid_for "$1")" set input "$(input_for "$2")" > /dev/null 2>&1; then
      echo "$2" > "$STATE_DIR/$1"
      # No phantom desktop: drop the display from macOS while it shows
      # another machine. (Its DDC becomes unreachable until reconnect.)
      [ "$2" = mac ] || bd_connect "$1" off
      return 0
    fi
    sleep 0.4
  done
  notify "FAILED: $1 -> $2 (DDC error x3)"
  return 1
}

current_machine() {  # current_machine <center|right> -> mac|pc|work
  # center: live DDC read (authoritative, catches manual OSD changes),
  #         state file as fallback.
  # right:  state file ONLY. The Anker adapter's DDC reads not only
  #         fail — they sometimes return garbage WITH exit 0, which
  #         must never be trusted.
  local val
  if [ "$1" = center ] && val=$(m1ddc display "$(uuid_for "$1")" get input 2>/dev/null); then
    case "$val" in
      $DP) echo pc ;; $HDMI_14) echo work ;; $HDMI_20) echo mac ;;
      *) cat "$STATE_DIR/$1" 2>/dev/null || echo mac ;;
    esac
  else
    cat "$STATE_DIR/$1" 2>/dev/null || echo mac
  fi
}

toggle_display() {  # toggle_display <center|right>  (Mac <-> PC)
  if [ "$(current_machine "$1")" = pc ]; then
    set_display "$1" mac; notify "$1 -> MrX"
  else
    set_display "$1" pc; notify "$1 -> VENGEANCE"
  fi
}

sync_windows() {
  # Tell Windows which displays it actually has, so nothing launches on
  # a monitor that's showing another machine. Scheduled tasks on
  # VENGEANCE (they must run in the desktop session): mon-extend uses
  # SetDisplayConfig via extend.ps1, mon-only3/4 disable via
  # MultiMonitorTool. Fire-and-forget: PC may be off/asleep.
  local c r task wake=""
  c=$(current_machine center); r=$(current_machine right)
  if   [ "$c" = pc ] && [ "$r" = pc ]; then task=mon-extend
  elif [ "$r" = pc ];                  then task=mon-only4
  elif [ "$c" = pc ];                  then task=mon-only3
  else                                      task=mon-extend
  fi
  # anything pointing at the PC -> also wake its display (mon-wake
  # jiggles the mouse + SetThreadExecutionState in the desktop session)
  if [ "$c" = pc ] || [ "$r" = pc ]; then
    wake=" & MSYS_NO_PATHCONV=1 schtasks /run /tn mon-wake"
  fi
  (ssh -o ConnectTimeout=4 -o BatchMode=yes vengeance \
     "MSYS_NO_PATHCONV=1 schtasks /run /tn $task$wake" >/dev/null 2>&1 &)
}

case "${1:-}" in
  game)
    set_display center pc; set_display right pc
    notify "Center + Right -> VENGEANCE"
    sync_windows
    ;;
  mac)
    set_display center mac; set_display right mac
    notify "Center + Right -> MrX"
    sync_windows
    ;;
  work)
    set_display right work
    notify "Right -> Work laptop"
    sync_windows
    ;;
  center|right)
    [ -n "${2:-}" ] || { echo "usage: $(basename "$0") $1 <mac|pc|work>" >&2; exit 1; }
    set_display "$1" "$2"
    notify "$1 -> $2"
    sync_windows
    ;;
  toggle)
    [ -n "${2:-}" ] || { echo "usage: $(basename "$0") toggle <center|right>" >&2; exit 1; }
    toggle_display "$2"
    sync_windows
    ;;
  status)
    for d in center right; do
      if ddc_visible "$d"; then conn=connected; else conn=disconnected; fi
      printf '%-7s %s (%s)\n' "$d:" "$(current_machine "$d")" "$conn"
    done
    ;;
  *)
    sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
