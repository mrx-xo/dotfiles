#!/usr/bin/env bash
# monitor-mode.sh — point any monitor at any machine via DDC (BetterDisplay).
#
# Names, not positions or roles: monitors go by panel and machines by fleet
# name. ROMULUS and REMUS are the Dell S2719DGF twins (ROMULUS sits left in
# the normal layout; they swap places), LUPA is the portrait S2725HS, TIBER
# is the built-in display. POLLUX is MrX, NEMESIS is VENGEANCE, work is the
# work laptop (REMUS only).
#
# Desk states (idempotent, CM v3 monitors layer): name what ROMULUS shows,
# then what REMUS shows; one name means both.
#   monitor-mode.sh nemesis         # both -> NEMESIS
#   monitor-mode.sh pollux          # both -> POLLUX
#   monitor-mode.sh pollux nemesis  # ROMULUS -> POLLUX, REMUS -> NEMESIS
#   monitor-mode.sh nemesis pollux  # ROMULUS -> NEMESIS, REMUS -> POLLUX
#   monitor-mode.sh pollux work     # ROMULUS -> POLLUX, REMUS -> work laptop
#
# One display (mix & match freely):
#   monitor-mode.sh romulus pollux|nemesis
#   monitor-mode.sh remus   pollux|nemesis|work
#   monitor-mode.sh toggle romulus|remus    # flip POLLUX <-> NEMESIS
#
# POLLUX on one Dell and nothing else, with everything still plugged in:
#   monitor-mode.sh solo romulus|remus      # drops the other Dell + LUPA from macOS
#   monitor-mode.sh solo off                # reconnects what solo dropped
# A dropped display keeps its input and its state file says off; any preset
# for a Dell brings it back, reset brings everything back. A Dell showing
# another machine is left alone. TIBER and Sidecar are never touched.
#
# One display off POLLUX on its own (same drop as solo, one at a time):
#   monitor-mode.sh kill romulus|remus|lupa  # again to bring it back
# Refuses POLLUX's last display, and a Dell that is showing another machine.
#
# Which way the Dells face (they turn around; LUPA stays put). NEMESIS only:
# with both Dells on it, left/right is re-arranged to match.
#   monitor-mode.sh flip            # normal (west) <-> flipped (east)
#   monitor-mode.sh flip normal|flipped
#
# Diagnostics:
#   monitor-mode.sh status          # which machine each Dell shows, facing
#   monitor-mode.sh hz              # real GDI refresh of NEMESIS displays (~25s)
#
# Escape hatch (ignores the state files; use when state got funky):
#   monitor-mode.sh reset           # reconnect + DDC both -> POLLUX
#
# Sleep/wake every screen, whichever machine it is showing:
#   monitor-mode.sh displays sleep|wake
#
# Drift check (Hammerspoon runs it after every display change):
#   monitor-mode.sh check           # notify if an away display re-enumerated
#
# Kiosk claims (ONAR YouTube kiosks; holder = the machine asking):
#   monitor-mode.sh claim romulus|remus <holder> pollux|nemesis   # ok <prev> | busy <holder>
#   monitor-mode.sh release romulus|remus <holder>                # restored <m> | left <m>
#   monitor-mode.sh json            # {"romulus":{"machine":..,"claimedBy":..},..}
# Every switching action takes a lock ($STATE_DIR/lock.d), so ONAR, AIDOS
# and the macro pad take turns instead of half-switching a Dell.
#
# Old words still work (renamed 2026-09-29): game, mac, split, rsplit and
# work as desk states; mac/pc for machines; center|3 and right|4 for displays.
#
# Window layout survives round-trips: before the first pollux->away flip
# in an invocation, every window's display (by UUID) is snapshotted to
# the state dir; after a display comes back to POLLUX, windows that got
# shuffled onto surviving displays are moved home and BSP re-tiles.
# Most-recent-snapshot semantics: chained partial switches (split ->
# game) re-snapshot mid-shuffle, so restore targets the latest state,
# not the original one.
#
# Displays pinned by UUID so replug order can't break this.
# Verified 2026-07-17: DDC WRITES reach both monitors from the Mac at
# all times (even while a monitor displays another input). DDC READS
# only work on ROMULUS (direct dock HDMI); REMUS sits
# behind an Anker 310 USB-C->HDMI adapter that passes writes but
# blocks reads — so current-state comes from a state file for it.
#
# A display pointed at another machine is also DISCONNECTED from macOS
# (betterdisplaycli, needs BetterDisplay.app running + Pro) so the Mac
# has no phantom desktop for windows/mouse to land on. Verified
# 2026-07-22: connected=off truly drops it (yabai sees 3 displays);
# reconnect re-enumerates in ~4-10s; DDC can NOT address a display
# while it's disconnected — hence the connect-first ordering below.
#
# DDC goes through betterdisplaycli, not m1ddc, since 2026-09-29: m1ddc
# 1.2.0 segfaults on every call while a Sidecar display is attached, which
# left one Dell switched and the other not. BetterDisplay reads return the
# raw 16-bit VCP value (Dell: 0x11xx), so only the low byte is the input.
#
# S2719DGF VCP 60 input values: DP=15, HDMI1(1.4)=17, HDMI2(2.0)=18
# LUPA (S2725HS) is POLLUX-only for now — no NEMESIS cable run to it.

set -euo pipefail

ROMULUS="8C207E30-FF6D-4624-A998-F6D7962597F6"  # yabai display 3, left in the normal layout
REMUS="0CDDE5CC-F566-4B56-85FD-48B8EA229946"    # yabai display 4, right in the normal layout
LUPA="56FEF42D-88B7-46E3-9C9B-7746A0929EB7"     # portrait, POLLUX-only: on or off, never switched

DP=15       # NEMESIS
HDMI_14=17  # work laptop hub
HDMI_20=18  # POLLUX via dock

STATE_DIR="$HOME/.local/state/monitor-mode"
mkdir -p "$STATE_DIR"
# State files were named center/right before the 2026-09-29 rename.
[ -e "$STATE_DIR/center" ] && [ ! -e "$STATE_DIR/romulus" ] && mv "$STATE_DIR/center" "$STATE_DIR/romulus"
[ -e "$STATE_DIR/right" ]  && [ ! -e "$STATE_DIR/remus" ]   && mv "$STATE_DIR/right"  "$STATE_DIR/remus"
# ...and held mac/pc until machines took fleet names the same day.
for f in "$STATE_DIR/romulus" "$STATE_DIR/remus"; do
  [ -f "$f" ] || continue
  case "$(cat "$f")" in mac) echo pollux > "$f" ;; pc) echo nemesis > "$f" ;; esac
done

LAYOUT="$STATE_DIR/layout.json"
FACING="$STATE_DIR/facing"   # normal | flipped (see flip)
BUSY="$STATE_DIR/busy"      # exists while a flip is in flight (check_drift skips)
LOCK="$STATE_DIR/lock.d"     # mkdir lock: ONAR, AIDOS and the macro pad take turns
CLAIMS="$STATE_DIR/claims"   # claims/<display>: holder=, set=, restore=
LOCK_HELD=0
LAYOUT_SAVED=0     # snapshot at most once per invocation
RESTORE_PENDING="" # UUIDs flipped back to POLLUX this invocation

notify() {
  osascript -e "display notification \"$1\" with title \"Monitor Mode\"" || true
}

display_name() {  # normalize romulus|remus, legacy center|right, or yabai 3|4
  case "$1" in
    romulus|3|center) echo romulus ;;
    remus|4|right)    echo remus ;;
    *) echo "unknown display: $1 (want romulus|remus)" >&2; exit 1 ;;
  esac
}

uuid_for() {
  case "$1" in
    romulus) echo "$ROMULUS" ;;
    remus)   echo "$REMUS" ;;
    lupa)    echo "$LUPA" ;;
    *) echo "unknown display: $1 (want romulus|remus)" >&2; exit 1 ;;
  esac
}

input_for() {
  case "$1" in
    pollux)  echo $HDMI_20 ;;
    nemesis) echo $DP ;;
    work)    echo $HDMI_14 ;;
    *) echo "unknown machine: $1 (want pollux|nemesis|work)" >&2; exit 1 ;;
  esac
}

machine_name() {  # normalize pollux|nemesis|work, legacy mac|pc|vengeance
  case "$1" in
    pollux|mac)            echo pollux ;;
    nemesis|pc|vengeance)  echo nemesis ;;
    work)                  echo work ;;
    *) echo "unknown machine: $1 (want pollux|nemesis|work)" >&2; exit 1 ;;
  esac
}

label() {  # notification text for a display or machine name
  case "$1" in
    work) echo "work laptop" ;;
    *)    echo "$1" | tr '[:lower:]' '[:upper:]' ;;
  esac
}

ddc_set_input() {  # ddc_set_input <romulus|remus> <vcp-value>
  betterdisplaycli set --uuid="$(uuid_for "$1")" --ddc --vcp=inputSelect --value="$2" > /dev/null 2>&1
}

ddc_get_input() {  # ddc_get_input <romulus|remus> -> input value (low byte)
  local raw
  raw=$(betterdisplaycli get --uuid="$(uuid_for "$1")" --ddc --vcp=inputSelect 2>/dev/null) || return 1
  [[ "$raw" =~ ^[0-9]+$ ]] || return 1
  echo $((raw & 0xFF))
}

bd_connect() {  # bd_connect <romulus|remus> <on|off>
  betterdisplaycli set --uuid="$(uuid_for "$1")" --connected="$2" > /dev/null 2>&1
}

ddc_visible() {  # is the display enumerated Mac-side (online, DDC-addressable)?
  [[ "$(displayplacer list 2>/dev/null)" == *"$(uuid_for "$1")"* ]]
}

wait_ddc() {  # poll until a reconnected display re-enumerates (~4-10s typical)
  local i
  for i in $(seq 1 15); do
    ddc_visible "$1" && return 0
    sleep 1
  done
  return 1
}

wait_yabai() {  # yabai re-enumerates a few seconds after the display is online
  local i
  for i in $(seq 1 15); do
    yabai -m query --displays 2>/dev/null | grep -q "$1" && return 0
    sleep 1
  done
  return 1
}

save_layout() {  # snapshot window -> display-UUID map (indices shift on
                 # disconnect; UUIDs don't)
  local displays windows
  displays=$(yabai -m query --displays 2>/dev/null) || return 0
  windows=$(yabai -m query --windows 2>/dev/null) || return 0
  jq -n --argjson d "$displays" --argjson w "$windows" '
    ($d | map({(.index|tostring): .uuid}) | add) as $u
    | [ $w[] | {id, app, uuid: $u[.display|tostring]} ]' \
    > "$LAYOUT" 2>/dev/null || true
}

restore_layout() {  # move windows back; skips ones already home, gone,
                    # or belonging to a still-disconnected display
  [ -s "$LAYOUT" ] || return 0
  local displays windows moved=0 id idx
  displays=$(yabai -m query --displays 2>/dev/null) || return 0
  windows=$(yabai -m query --windows 2>/dev/null) || return 0
  while read -r id idx; do
    [ -n "$id" ] || continue
    yabai -m window "$id" --display "$idx" 2>/dev/null && moved=$((moved+1)) || true
  done < <(jq -r --argjson d "$displays" --argjson w "$windows" '
    ($d | map({(.uuid): .index}) | add) as $ix
    | ($w | map({(.id|tostring): .display}) | add) as $cur
    | .[]
    | select(.uuid != null and $ix[.uuid] != null)
    | select($cur[.id|tostring] != null and $cur[.id|tostring] != $ix[.uuid])
    | "\(.id) \($ix[.uuid])"' "$LAYOUT" 2>/dev/null)
  [ "$moved" -gt 0 ] && notify "Restored $moved windows" || true
}

maybe_restore() {
  [ -n "$RESTORE_PENDING" ] || return 0
  local u
  for u in $RESTORE_PENDING; do
    wait_yabai "$u" || notify "restore: display never appeared in yabai"
  done
  restore_layout
}

set_display() {  # set_display <romulus|remus> <pollux|nemesis|work>
  # DDC only reaches the display while the Mac-side connection is up,
  # so: ensure connected -> DDC-switch input -> disconnect unless the
  # target is POLLUX itself.
  # The Anker adapter throws transient DDC I/O errors — retry before
  # giving up, and never record state for a flip that didn't happen.
  local try cur
  cur=$(current_machine "$1")
  # Windows shuffle onto surviving displays the moment one disconnects —
  # snapshot before the first pollux->away flip, while everything is home.
  if [ "$cur" = pollux ] && [ "$2" != pollux ] && [ "$LAYOUT_SAVED" = 0 ]; then
    save_layout; LAYOUT_SAVED=1
  fi
  # Already there? Skip the connect/disconnect dance — this is what makes
  # the v3 preset keys idempotent (mash freely). Trusts the state file for
  # remus (manual OSD changes there can lie; press another preset to reset).
  # The Mac-side connection must match too: a dock replug re-enumerates a
  # display BetterDisplay had dropped, so an away target that is visible
  # again falls through and gets disconnected (2026-09-21).
  if [ "$cur" = "$2" ]; then
    if [ "$2" = pollux ]; then
      ddc_visible "$1" && return 0
    else
      ddc_visible "$1" || return 0
    fi
  fi
  if ! ddc_visible "$1"; then
    bd_connect "$1" on
    wait_ddc "$1" || { notify "FAILED: $1 never re-enumerated"; return 1; }
  fi
  for try in 1 2 3 4 5 6; do
    if ddc_set_input "$1" "$(input_for "$2")"; then
      echo "$2" > "$STATE_DIR/$1"
      # No phantom desktop: drop the display from macOS while it shows
      # another machine. (Its DDC becomes unreachable until reconnect.)
      if [ "$2" = pollux ]; then
        RESTORE_PENDING="$RESTORE_PENDING $(uuid_for "$1")"
      else
        bd_connect "$1" off
      fi
      return 0
    fi
    sleep 0.5
  done
  notify "FAILED: $1 -> $2 (DDC error x6)"
  return 1
}

force_pollux() {  # force_pollux <romulus|remus>: ignore state, put it on POLLUX
  # The reset path. Skips no step: reconnect if dropped, DDC to the POLLUX
  # input, record pollux. State is written even when DDC fails so the next
  # preset does the full dance instead of trusting a stale file.
  local try
  echo pollux > "$STATE_DIR/$1"
  if ! ddc_visible "$1"; then
    bd_connect "$1" on
    wait_ddc "$1" || { notify "reset: $1 never re-enumerated"; return 1; }
  fi
  RESTORE_PENDING="$RESTORE_PENDING $(uuid_for "$1")"
  for try in 1 2 3; do
    ddc_set_input "$1" "$HDMI_20" && return 0
    sleep 0.4
  done
  notify "reset: $(label "$1") -> POLLUX failed (DDC error x3)"
  return 1
}

drop_display() {  # drop_display <romulus|remus|lupa>: off POLLUX, input untouched
  # solo's half of set_display: the display goes dark instead of showing
  # another machine. State is only written for a drop that happened, so an
  # unplugged display is never "restored" later.
  ddc_visible "$1" || return 0
  if [ "$LAYOUT_SAVED" = 0 ]; then save_layout; LAYOUT_SAVED=1; fi
  bd_connect "$1" off || { notify "FAILED: $(label "$1") would not disconnect"; return 1; }
  echo off > "$STATE_DIR/$1"
}

lupa_on() {  # reconnect LUPA if solo dropped it
  [ "$(cat "$STATE_DIR/lupa" 2>/dev/null)" = off ] || return 0
  if ! ddc_visible lupa; then
    bd_connect lupa on
    wait_ddc lupa || { notify "FAILED: LUPA never re-enumerated"; return 1; }
    RESTORE_PENDING="$RESTORE_PENDING $LUPA"
  fi
  echo pollux > "$STATE_DIR/lupa"
}

solo() {  # solo <romulus|remus>: POLLUX on that Dell and nothing else
  local keep="$1" other
  if [ "$keep" = romulus ]; then other=remus; else other=romulus; fi
  # The kept Dell must be live first, so a failure never leaves POLLUX blind.
  set_display "$keep" pollux || return 1
  # The other Dell is dropped only while POLLUX is what it shows; one
  # pointed at another machine is already off the Mac and keeps its picture.
  if [ "$(current_machine "$other")" = pollux ]; then drop_display "$other" || true; fi
  drop_display lupa || true
  notify "Solo: POLLUX on $(label "$keep") only"
  sync_windows
  maybe_restore
}

solo_off() {  # reconnect whatever solo dropped
  local d
  for d in romulus remus; do
    if [ "$(current_machine "$d")" = off ]; then set_display "$d" pollux || true; fi
  done
  lupa_on || true
  notify "Solo off: displays back on POLLUX"
  sync_windows
  maybe_restore
}

kill_display() {  # kill_display <romulus|remus|lupa>: off POLLUX, or back if already off
  local d="$1" cur
  if [ "$d" = lupa ]; then
    # LUPA has no input to read: enumerated means on, whatever the file says.
    if ddc_visible lupa; then cur=pollux; else cur=$(cat "$STATE_DIR/lupa" 2>/dev/null || echo pollux); fi
  else
    cur=$(current_machine "$d")
  fi
  case "$cur" in
    off)
      if [ "$d" = lupa ]; then lupa_on || return 1; else set_display "$d" pollux || return 1; fi
      notify "$(label "$d") back on POLLUX"
      ;;
    pollux)
      if ! ddc_visible "$d"; then
        echo "$d is not connected to POLLUX" >&2
        notify "$(label "$d") is not connected to POLLUX"
        return 1
      fi
      if [ "$(displayplacer list 2>/dev/null | grep -c '^Persistent screen id:')" -le 1 ]; then
        echo "refused: $d is POLLUX's last display" >&2
        notify "Refused: $(label "$d") is POLLUX's last display"
        return 1
      fi
      drop_display "$d" || return 1
      notify "$(label "$d") off"
      ;;
    *)
      echo "$d is showing $cur; nothing to kill" >&2
      notify "$(label "$d") is showing $(label "$cur"); nothing to kill"
      return 1
      ;;
  esac
}

check_drift() {  # notify when an away display is enumerated Mac-side again
  # A dock replug re-enumerates displays BetterDisplay had dropped. This
  # never switches anything (the remus state file can lie); it only tells
  # the user which key puts it back. Skipped while a preset is mid-flight,
  # since a flip connects the display before it disconnects it.
  [ -e "$BUSY" ] && return 0
  local d cur key
  for d in romulus remus; do
    cur=$(current_machine "$d")
    [ "$cur" != pollux ] && ddc_visible "$d" || continue
    if [ "$cur" = off ]; then
      notify "$(label "$d") is back on POLLUX but solo dropped it. Run solo again, or ctrl+alt+0 to reset."
      continue
    fi
    case "$cur" in nemesis) key="ctrl+alt+$([ "$d" = romulus ] && echo 3 || echo 4)" ;;
                   *)  key="ctrl+alt+w" ;; esac
    notify "$(label "$d") is back on POLLUX but state says $cur. Press $key, or ctrl+alt+0 to reset."
  done
}

current_machine() {  # current_machine <romulus|remus> -> pollux|nemesis|work
  # romulus: live DDC read (authoritative, catches manual OSD changes),
  #          state file as fallback.
  # remus:   state file ONLY. The Anker adapter's DDC reads not only
  #         fail — they sometimes return garbage WITH exit 0, which
  #         must never be trusted.
  local val
  if [ "$1" = romulus ] && val=$(ddc_get_input "$1"); then
    case "$val" in
      $DP) echo nemesis ;; $HDMI_14) echo work ;; $HDMI_20) echo pollux ;;
      *) cat "$STATE_DIR/$1" 2>/dev/null || echo pollux ;;
    esac
  else
    cat "$STATE_DIR/$1" 2>/dev/null || echo pollux
  fi
}

acquire_lock() {  # wait for our turn; take over a lock whose owner died
  local i p tries="${MONITOR_MODE_LOCK_TRIES:-300}"
  for ((i = 0; i < tries; i++)); do
    if mkdir "$LOCK" 2>/dev/null; then
      echo $$ > "$LOCK/pid"; LOCK_HELD=1; return 0
    fi
    p=$(cat "$LOCK/pid" 2>/dev/null)
    if [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null; then
      rm -rf "$LOCK"; continue
    fi
    sleep 0.5
  done
  echo "monitor-mode: busy (another switch is running)" >&2
  return 1
}

claim_get() {  # claim_get <display> <key> -> value or empty (never fails: set -e)
  [ -f "$CLAIMS/$1" ] || return 0
  sed -n "s/^$2=//p" "$CLAIMS/$1"
}

claim_display() {  # claim_display <display> <holder> <machine>
  local held prev
  held=$(claim_get "$1" holder)
  if [ -n "$held" ] && [ "$held" != "$2" ]; then echo "busy $held"; return 3; fi
  prev=$(current_machine "$1")
  mkdir -p "$CLAIMS"
  printf 'holder=%s\nset=%s\nrestore=%s\n' "$2" "$3" "$prev" > "$CLAIMS/$1"
  if ! set_display "$1" "$3"; then rm -f "$CLAIMS/$1"; return 1; fi
  sync_windows
  maybe_restore
  echo "ok $prev"
}

release_display() {  # release_display <display> <holder>
  local held want restore now
  held=$(claim_get "$1" holder)
  if [ "$held" != "$2" ]; then echo "not-held ${held:-none}"; return 3; fi
  want=$(claim_get "$1" set); restore=$(claim_get "$1" restore)
  now=$(current_machine "$1")
  rm -f "$CLAIMS/$1"
  if [ "$now" = "$want" ] && [ -n "$restore" ] && [ "$restore" != "$want" ]; then
    set_display "$1" "$restore" || return 1
    sync_windows
    maybe_restore
    echo "restored $restore"
  else
    echo "left $now"
  fi
}

status_json() {
  local d sep=""
  printf '{'
  for d in romulus remus; do
    printf '%s"%s":{"machine":"%s","claimedBy":"%s"}' "$sep" "$d" \
      "$(current_machine "$d")" "$(claim_get "$d" holder)"
    sep=","
  done
  printf '}\n'
}

toggle_display() {  # toggle_display <romulus|remus>  (POLLUX <-> NEMESIS)
  if [ "$(current_machine "$1")" = nemesis ]; then
    set_display "$1" pollux && notify "$(label "$1") -> POLLUX"
  else
    set_display "$1" nemesis && notify "$(label "$1") -> NEMESIS"
  fi
}

facing() { cat "$FACING" 2>/dev/null || echo normal; }

flip() {  # flip [normal|flipped]: record which way the Dells face
  local want="${1:-}"
  case "$want" in
    normal|flipped) ;;
    "") [ "$(facing)" = flipped ] && want=normal || want=flipped ;;
    *) echo "usage: $(basename "$0") flip [normal|flipped]" >&2; exit 1 ;;
  esac
  echo "$want" > "$FACING"
  local c r
  c=$(current_machine romulus); r=$(current_machine remus)
  if [ "$c" = nemesis ] && [ "$r" = nemesis ]; then
    ssh -n -o ConnectTimeout=4 -o BatchMode=yes \
      -o ServerAliveInterval=5 -o ServerAliveCountMax=2 vengeance \
      "MSYS_NO_PATHCONV=1 schtasks /run /tn mon-layout-$want && MSYS_NO_PATHCONV=1 schtasks /run /tn mon-assert" \
      >"$STATE_DIR/windows-sync.log" 2>&1 \
      || notify "Layout sync failed; NEMESIS may be asleep or unreachable"
  fi
  if [ "$want" = flipped ]; then
    notify "Facing east: REMUS left, ROMULUS right"
  else
    notify "Facing west: ROMULUS left, REMUS right"
  fi
}

desk() {  # desk <romulus-machine> <remus-machine>: a full desk state
  set_display romulus "$1"; set_display remus "$2"
  if [ "$1" = "$2" ]; then
    notify "ROMULUS + REMUS -> $(label "$1")"
  else
    notify "ROMULUS -> $(label "$1"), REMUS -> $(label "$2")"
  fi
  sync_windows
  maybe_restore
}

sync_windows() {
  # Tell Windows which displays it actually has, so nothing launches on
  # a monitor that's showing another machine. Scheduled tasks on
  # NEMESIS (they must run in the desktop session): mon-extend uses
  # SetDisplayConfig via extend.ps1, mon-only3/4 disable via
  # MultiMonitorTool. Wait for SSH to submit the tasks: a detached SSH
  # process can die when Emacs closes the command's PTY on script exit.
  local c r task wake=""
  c=$(current_machine romulus); r=$(current_machine remus)
  if   [ "$c" = nemesis ] && [ "$r" = nemesis ]; then task=mon-extend
  elif [ "$r" = nemesis ];                       then task=mon-only4
  elif [ "$c" = nemesis ];                       then task=mon-only3
  else                                      task=mon-extend
  fi
  # both Dells on NEMESIS -> arrange them for the way they face
  # (mon-layout.ps1 waits for mon-extend's topology before moving anything)
  local layout=""
  if [ "$c" = nemesis ] && [ "$r" = nemesis ]; then
    layout=" && MSYS_NO_PATHCONV=1 schtasks /run /tn mon-layout-$(facing)"
  fi
  # anything pointing at NEMESIS -> also wake its display (mon-wake
  # jiggles the mouse + SetThreadExecutionState in the desktop session)
  if [ "$c" = nemesis ] || [ "$r" = nemesis ]; then
    wake=" && MSYS_NO_PATHCONV=1 schtasks /run /tn mon-wake"
  fi
  # mon-assert (assert-hz.ps1): topology changes reset displays to the EDID
  # default 59.95 Hz; this re-asserts 155 (multi-pass, so it wins the race
  # against the topology task's fallback)
  if ! ssh -n -o ConnectTimeout=4 -o BatchMode=yes \
     -o ServerAliveInterval=5 -o ServerAliveCountMax=2 vengeance \
     "MSYS_NO_PATHCONV=1 schtasks /run /tn $task$layout && MSYS_NO_PATHCONV=1 schtasks /run /tn mon-assert$wake" \
     >"$STATE_DIR/windows-sync.log" 2>&1; then
    echo "Windows sync failed ($task); see $STATE_DIR/windows-sync.log" >&2
    notify "Windows sync failed ($task); NEMESIS may be asleep or unreachable"
  fi
  # A failed Windows request must not prevent Mac window restoration.
  return 0
}

displays_power() {  # displays_power <sleep|wake>
  # POLLUX side always; NEMESIS too when any monitor is on its input,
  # since a display showing NEMESIS ignores POLLUX's sleep. mon-sleep /
  # mon-wake are desktop-session scheduled tasks (sleep.ps1 / wake.ps1).
  local c r
  c=$(current_machine romulus); r=$(current_machine remus)
  if [ "$c" = nemesis ] || [ "$r" = nemesis ]; then
    ssh -n -o ConnectTimeout=4 -o BatchMode=yes \
      -o ServerAliveInterval=5 -o ServerAliveCountMax=2 vengeance \
      "MSYS_NO_PATHCONV=1 schtasks /run /tn mon-$1" \
      >"$STATE_DIR/windows-sync.log" 2>&1 \
      || echo "NEMESIS mon-$1 failed; see $STATE_DIR/windows-sync.log" >&2
  fi
  if [ "$1" = sleep ]; then pmset displaysleepnow; else caffeinate -u -t 1; fi
}

case "${1:-}" in
  status|check|displays|json|"") ;;
  *)
    acquire_lock || exit 1
    touch "$BUSY"
    trap 'rm -f "$BUSY"; [ "$LOCK_HELD" = 1 ] && rm -rf "$LOCK"' EXIT
    ;;
esac

case "${1:-}" in
  # Legacy desk-state words, kept as aliases (muscle memory, old callers).
  game)   desk nemesis nemesis ;;
  mac)    desk pollux pollux ;;
  split)  desk pollux nemesis ;;
  rsplit) desk nemesis pollux ;;
  work)   desk pollux work ;;
  pollux|nemesis|pc|vengeance)
    m1=$(machine_name "$1"); m2=$(machine_name "${2:-$1}")
    desk "$m1" "$m2"
    ;;
  romulus|remus|center|right|3|4)
    [ -n "${2:-}" ] || { echo "usage: $(basename "$0") $1 <pollux|nemesis|work>" >&2; exit 1; }
    d=$(display_name "$1"); m=$(machine_name "$2")
    set_display "$d" "$m" && notify "$(label "$d") -> $(label "$m")"
    sync_windows
    maybe_restore
    ;;
  toggle)
    [ -n "${2:-}" ] || { echo "usage: $(basename "$0") toggle <romulus|remus>" >&2; exit 1; }
    toggle_display "$(display_name "$2")"
    sync_windows
    maybe_restore
    ;;
  solo)
    case "${2:-}" in
      off) solo_off ;;
      romulus|remus|center|right|3|4) solo "$(display_name "$2")" ;;
      *) echo "usage: $(basename "$0") solo <romulus|remus|off>" >&2; exit 1 ;;
    esac
    ;;
  kill)
    case "${2:-}" in
      lupa) d=lupa ;;
      romulus|remus|center|right|3|4) d=$(display_name "$2") ;;
      *) echo "usage: $(basename "$0") kill <romulus|remus|lupa>" >&2; exit 1 ;;
    esac
    kill_display "$d" || exit 1
    maybe_restore
    ;;
  flip)
    flip "${2:-}"
    ;;
  reset)
    force_pollux romulus || true; force_pollux remus || true
    lupa_on || true
    notify "Reset: ROMULUS + REMUS -> POLLUX (state cleared)"
    sync_windows
    maybe_restore
    ;;
  displays)
    case "${2:-}" in
      sleep|wake) displays_power "$2" ;;
      *) echo "usage: $(basename "$0") displays <sleep|wake>" >&2; exit 1 ;;
    esac
    ;;
  check)
    check_drift
    ;;
  claim)
    [ -n "${4:-}" ] || { echo "usage: $(basename "$0") claim <romulus|remus> <holder> <machine>" >&2; exit 1; }
    claim_display "$(display_name "$2")" "$3" "$(machine_name "$4")"
    ;;
  release)
    [ -n "${3:-}" ] || { echo "usage: $(basename "$0") release <romulus|remus> <holder>" >&2; exit 1; }
    release_display "$(display_name "$2")" "$3"
    ;;
  json)
    status_json
    ;;
  status)
    for d in romulus remus; do
      if ddc_visible "$d"; then conn=connected; else conn=disconnected; fi
      printf '%-9s %s (%s)\n' "$d:" "$(current_machine "$d")" "$conn"
    done
    if ddc_visible lupa; then conn=connected; else conn=disconnected; fi
    printf '%-9s %s (%s)\n' "lupa:" "$(cat "$STATE_DIR/lupa" 2>/dev/null || echo pollux)" "$conn"
    printf '%-9s %s\n' "facing:" "$(facing)"
    ;;
  hz)
    # Real per-display refresh on NEMESIS, read by GDI inside the desktop
    # session (hz-probe.ps1). Pass 1 is the true reading; later passes
    # re-assert 155 if it was low. ~25s.
    ssh -n -o ConnectTimeout=6 -o BatchMode=yes vengeance \
      'powershell -NoProfile -ExecutionPolicy Bypass -File C:/Tools/MultiMonitorTool/hz-probe.ps1' 2>/dev/null \
      || { echo "hz probe failed; NEMESIS asleep or unreachable" >&2; exit 1; }
    ;;
  *)
    sed -n '2,58p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
