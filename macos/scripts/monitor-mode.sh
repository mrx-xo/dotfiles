#!/usr/bin/env bash
# monitor-mode.sh — point any monitor at any machine via DDC (BetterDisplay).
#
# Names, not positions or roles: monitors go by panel and machines by fleet
# name. ROMULUS and REMUS are the Dell S2719DGF twins (ROMULUS sits left in
# the normal layout; they swap places), LUPA is the portrait S2725HS, TIBER
# is the built-in display. POLLUX is MrX, NEMESIS is VENGEANCE, work is the
# work laptop (ROMULUS, REMUS and LUPA).
#
# Desk states (idempotent, CM v3 monitors layer): name what ROMULUS shows,
# then what REMUS shows; one name means both.
#   monitor-mode.sh nemesis         # both -> NEMESIS
#   monitor-mode.sh pollux          # both -> POLLUX
#   monitor-mode.sh pollux nemesis  # ROMULUS -> POLLUX, REMUS -> NEMESIS
#   monitor-mode.sh nemesis pollux  # ROMULUS -> NEMESIS, REMUS -> POLLUX
#   monitor-mode.sh pollux work     # ROMULUS -> POLLUX, REMUS -> work laptop
#                                  # LUPA also -> work; pollux/mac brings it home
#
# One display (mix & match freely):
#   monitor-mode.sh romulus pollux|nemesis|work
#   monitor-mode.sh remus   pollux|nemesis|work
#   monitor-mode.sh lupa    pollux|work
#   monitor-mode.sh toggle romulus|remus    # flip POLLUX <-> NEMESIS
#
# POLLUX on one Dell and nothing else, with everything still plugged in:
#   monitor-mode.sh solo romulus|remus      # drops the other Dell + LUPA from macOS
#   monitor-mode.sh solo off                # reconnects what solo dropped
# A dropped display keeps its input and its state file says off; any preset
# for a Dell brings it back, reset brings everything back. A Dell showing
# another machine is left alone. TIBER and Sidecar are never touched.
#
# One display dark, whichever machine it shows (one at a time):
#   monitor-mode.sh kill romulus|remus|lupa  # again to bring it back
# On POLLUX it is the same drop as solo. On NEMESIS the panel is disabled
# Windows-side (mon-only3/4 keep the other Dell; a dark-<panel> marker
# remembers it, any desk preset re-extends and clears it). Refuses either
# machine's last display, and a Dell that is showing the work laptop.
#
# Which way the Dells face (they turn around; LUPA stays put). NEMESIS only:
# with both Dells on it, left/right is re-arranged to match.
#   monitor-mode.sh flip            # normal (west) <-> flipped (east)
#   monitor-mode.sh flip normal|flipped
#
# KOMAX grammar (screen, then machine; docs/active/specs/2026-10-21-komax-desk-grammar-design.md):
#   monitor-mode.sh arm romulus|remus|nyx    # toggle a screen in the armed set (expires in 3s)
#   monitor-mode.sh fire pollux|nemesis|work [screens] # armed (or named) screens -> machine; none = both Dells
#   monitor-mode.sh disarm                   # clear the armed set
#   monitor-mode.sh armed                    # the armed set, fleet order
#   monitor-mode.sh nyx pollux|nemesis       # NYX: Sidecar display, or AIDOS remote (held)
#
# Diagnostics:
#   monitor-mode.sh status          # which machine each external display shows, NYX, facing
#   monitor-mode.sh hz              # real GDI refresh of NEMESIS displays (~25s)
#
# Escape hatch (ignores the state files; use when state got funky):
#   monitor-mode.sh reset           # reconnect + DDC all three -> POLLUX
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
# LUPA (S2725HS): HDMI1=17 -> POLLUX, HDMI2=18 -> work. No NEMESIS cable.

set -euo pipefail

ROMULUS="8C207E30-FF6D-4624-A998-F6D7962597F6"  # yabai display 3, left in the normal layout
REMUS="0CDDE5CC-F566-4B56-85FD-48B8EA229946"    # yabai display 4, right in the normal layout
LUPA="56FEF42D-88B7-46E3-9C9B-7746A0929EB7"     # portrait, POLLUX/work

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
ARMED="$STATE_DIR/armed"     # KOMAX grammar: screens named and waiting for a machine
ARMED_AT="$STATE_DIR/armed-at"  # stamp of the last press; the expiry compares it
ARM_SECONDS="${MONITOR_MODE_ARM_SECONDS:-3}"
SIDECAR_BIN="${SIDECAR_BIN:-$HOME/.local/bin/sidecar}"  # NYX: Sidecar (POLLUX) or AIDOS (NEMESIS)
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

input_for() {  # input_for <machine> <display>: LUPA's HDMI mapping is reversed
  if [ "${2:-}" = lupa ]; then
    case "$1" in
      pollux) echo 17 ;;
      work)   echo 18 ;;
      *) echo "unsupported machine for lupa: $1 (want pollux|work)" >&2; return 1 ;;
    esac
    return 0
  fi
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

ddc_set_input() {  # ddc_set_input <romulus|remus|lupa> <vcp-value>
  betterdisplaycli set --uuid="$(uuid_for "$1")" --ddc --vcp=inputSelect --value="$2" > /dev/null 2>&1
}

ddc_get_input() {  # ddc_get_input <romulus|remus|lupa> -> input value (low byte)
  local raw
  raw=$(betterdisplaycli get --uuid="$(uuid_for "$1")" --ddc --vcp=inputSelect 2>/dev/null) || return 1
  [[ "$raw" =~ ^[0-9]+$ ]] || return 1
  echo $((raw & 0xFF))
}

bd_connect() {  # bd_connect <romulus|remus|lupa> <on|off>
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

set_display() {  # set_display <romulus|remus|lupa> <pollux|nemesis|work>
  # DDC only reaches the display while the Mac-side connection is up,
  # so: ensure connected -> DDC-switch input -> disconnect unless the
  # target is POLLUX itself.
  # The Anker adapter throws transient DDC I/O errors — retry before
  # giving up, and never record state for a flip that didn't happen.
  local try cur input
  input=$(input_for "$2" "$1") || return 1
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
    if ddc_set_input "$1" "$input"; then
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

force_pollux() {  # force_pollux <romulus|remus|lupa>: ignore state, put it on POLLUX
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
    ddc_set_input "$1" "$(input_for pollux "$1")" && return 0
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
  # A dock replug can make a dropped display visible again. Clear the
  # saved off state, but preserve a manual change to the work input.
  [ "$(current_machine lupa)" != work ] || return 0
  set_display lupa pollux || return 1
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
  if [ "$(current_machine lupa)" = pollux ]; then drop_display lupa || true; fi
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
  cur=$(current_machine "$d")
  case "$cur" in
    off)
      set_display "$d" pollux || return 1
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
    nemesis)
      kill_nemesis "$d"
      ;;
    *)
      echo "$d is showing $cur; nothing to kill" >&2
      notify "$(label "$d") is showing $(label "$cur"); nothing to kill"
      return 1
      ;;
  esac
}

kill_nemesis() {  # kill_nemesis <romulus|remus>: dark on NEMESIS, or back if already dark
  # POLLUX cannot reach a Dell that shows NEMESIS (no DDC, not enumerated),
  # so the panel is disabled Windows-side instead: mon-only3 keeps ROMULUS
  # (display 3), mon-only4 keeps REMUS (display 4). Windows refuses to
  # disable its last display, so refuse that here, before any SSH.
  local d="$1" other task
  if [ "$d" = romulus ]; then other=remus; task=mon-only4; else other=romulus; task=mon-only3; fi
  if [ -e "$STATE_DIR/dark-$d" ]; then
    rm -f "$STATE_DIR/dark-$d"
    sync_windows
    notify "$(label "$d") back on NEMESIS"
    return 0
  fi
  if [ "$(current_machine "$other")" != nemesis ]; then
    echo "refused: $d is NEMESIS's last display" >&2
    notify "Refused: $(label "$d") is NEMESIS's last display"
    return 1
  fi
  if ! ssh -n -o ConnectTimeout=4 -o BatchMode=yes \
     -o ServerAliveInterval=5 -o ServerAliveCountMax=2 vengeance \
     "MSYS_NO_PATHCONV=1 schtasks /run /tn $task && MSYS_NO_PATHCONV=1 schtasks /run /tn mon-assert" \
     >"$STATE_DIR/windows-sync.log" 2>&1; then
    echo "NEMESIS $task failed; see $STATE_DIR/windows-sync.log" >&2
    notify "Kill failed: NEMESIS may be asleep or unreachable"
    return 1
  fi
  touch "$STATE_DIR/dark-$d"
  notify "$(label "$d") dark on NEMESIS"
}

check_drift() {  # notify when an away display is enumerated Mac-side again
  # A dock replug re-enumerates displays BetterDisplay had dropped. This
  # never switches anything (the remus state file can lie); it only tells
  # the user which key puts it back. Skipped while a preset is mid-flight,
  # since a flip connects the display before it disconnects it.
  [ -e "$BUSY" ] && return 0
  local d cur key
  for d in romulus remus lupa; do
    cur=$(current_machine "$d")
    # A readable Mac input does not clear the intent to keep LUPA off.
    if [ "$d" = lupa ] && [ "$cur" = pollux ] && [ "$(cat "$STATE_DIR/lupa" 2>/dev/null)" = off ]; then
      cur=off
    fi
    [ "$cur" != pollux ] && ddc_visible "$d" || continue
    if [ "$cur" = off ]; then
      notify "$(label "$d") is back on POLLUX but solo dropped it. Run solo again, or ctrl+alt+0 to reset."
      continue
    fi
    if [ "$d" = lupa ]; then
      notify "LUPA is back on POLLUX but state says $cur. Run mon lupa work, or ctrl+alt+0 to reset."
      continue
    fi
    case "$cur" in nemesis) key="ctrl+alt+$([ "$d" = romulus ] && echo 3 || echo 4)" ;;
                   *)  key="ctrl+alt+w" ;; esac
    notify "$(label "$d") is back on POLLUX but state says $cur. Press $key, or ctrl+alt+0 to reset."
  done
}

current_machine() {  # current_machine <romulus|remus|lupa> -> pollux|nemesis|work|off
  # romulus/lupa: live DDC read (authoritative, catches manual OSD changes),
  #          state file as fallback.
  # remus:   state file ONLY. The Anker adapter's DDC reads not only
  #         fail — they sometimes return garbage WITH exit 0, which
  #         must never be trusted.
  local val
  if [ "$1" != remus ] && val=$(ddc_get_input "$1"); then
    if [ "$1" = lupa ]; then
      case "$val" in
        17) echo pollux ;; 18) echo work ;;
        *) cat "$STATE_DIR/$1" 2>/dev/null || echo pollux ;;
      esac
    else
      case "$val" in
        $DP) echo nemesis ;; $HDMI_14) echo work ;; $HDMI_20) echo pollux ;;
        *) cat "$STATE_DIR/$1" 2>/dev/null || echo pollux ;;
      esac
    fi
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
  for d in romulus remus lupa; do
    printf '%s"%s":{"machine":"%s","claimedBy":"%s"}' "$sep" "$d" \
      "$(current_machine "$d")" "$(claim_get "$d" holder)"
    sep=","
  done
  printf '}\n'
}

# KOMAX grammar: screen, then machine. A screen press arms; a machine press
# fires at every armed screen. See docs/active/specs/2026-10-21-komax-desk-grammar-design.md.
armed_list() {  # armed screens in fleet order, one per line
  local s
  [ -s "$ARMED" ] || return 0
  for s in romulus remus nyx; do
    grep -qx "$s" "$ARMED" && echo "$s"
  done
  return 0
}

armed_clear() { rm -f "$ARMED" "$ARMED_AT"; }

armed_render() {  # sketchybar item komax_armed: names while armed, hidden otherwise
  command -v sketchybar >/dev/null 2>&1 || return 0
  local names
  names=$(armed_list | tr '[:lower:]' '[:upper:]' | paste -sd ' ' -)
  if [ -n "$names" ]; then
    sketchybar --set komax_armed label="$names" drawing=on >/dev/null 2>&1 || true
  else
    sketchybar --set komax_armed label="" drawing=off >/dev/null 2>&1 || true
  fi
}

arm_schedule_expiry() {  # clear the set ARM_SECONDS after the last press
  local stamp="$(date +%s).$RANDOM.$$"
  echo "$stamp" > "$ARMED_AT"
  (
    sleep "$ARM_SECONDS"
    if [ "$(cat "$ARMED_AT" 2>/dev/null)" = "$stamp" ]; then
      armed_clear; armed_render
    fi
  ) >/dev/null 2>&1 </dev/null &
  disown 2>/dev/null || true
}

arm_toggle() {  # arm_toggle <romulus|remus|nyx>: add, or remove if already armed
  if [ -s "$ARMED" ] && grep -qx "$1" "$ARMED"; then
    grep -vx "$1" "$ARMED" > "$ARMED.new" || true
    mv "$ARMED.new" "$ARMED"
    [ -s "$ARMED" ] || rm -f "$ARMED"
  else
    echo "$1" >> "$ARMED"
  fi
  armed_render
  if [ -s "$ARMED" ]; then arm_schedule_expiry; else rm -f "$ARMED_AT"; fi
}

nyx_set() {  # nyx_set <pollux|nemesis>: POLLUX = Sidecar connected, NEMESIS = AIDOS in front
  local out
  case "$1" in
    pollux)
      # The first connect right after a disconnect can time out on the iPad
      # side (SidecarErrorDeviceTimedOut, seen 2026-10-21); one retry lands it.
      out=$("$SIDECAR_BIN" release 2>&1) &&
        { out=$("$SIDECAR_BIN" connect 2>&1) || { sleep 3; out=$("$SIDECAR_BIN" connect 2>&1); }; } ;;
    nemesis) out=$("$SIDECAR_BIN" remote 2>&1) ;;
    *) return 1 ;;
  esac || {
    # Helper output can carry quotes and Lua tracebacks; osascript must never see them.
    out=$(printf '%s' "$out" | tr -d '"\\' | tr '\n' ' ' | cut -c1-160)
    notify "NYX: ${out:-sidecar helper failed}"; return 1
  }
  return 0
}

nyx_machine() {  # nyx_machine -> pollux|nemesis
  if "$SIDECAR_BIN" status 2>/dev/null | grep -q '^iPad connected'; then echo pollux; else echo nemesis; fi
}

fire() {  # fire <pollux|nemesis|work> [screens]: screens -> machine
  # The set is snapshotted and cleared BEFORE the lock (see the dispatcher):
  # a fire that waits behind another switch, or behind a VENGEANCE wake, must
  # act on what was armed when the key was pressed, not on what is left.
  local m="$1" set s rc=0 moved="" dells=0
  shift
  set="$*"
  if [ -z "$set" ]; then
    if [ "$m" = work ]; then notify "Work laptop: nothing armed"; return 0; fi
    set="romulus remus"
  fi
  for s in $set; do
    case "$s" in
      romulus)
        dells=1; set_display romulus "$m" && moved="$moved ROMULUS" || rc=1 ;;
      remus)
        dells=1
        if set_display remus "$m"; then
          moved="$moved REMUS"
          if [ "$m" = work ]; then
            set_display lupa work && moved="$moved LUPA" || rc=1
          elif [ "$m" = pollux ] && [ "$(current_machine lupa)" = work ]; then
            set_display lupa pollux && moved="$moved LUPA" || rc=1
          fi
        else rc=1; fi ;;
      nyx)
        case "$m" in
          pollux|nemesis) nyx_set "$m" && moved="$moved NYX" || rc=1 ;;
        esac ;;
    esac
  done
  [ -n "$moved" ] && notify "$(echo $moved | sed 's/ / + /g') -> $(label "$m")"
  # NYX alone never touches a Dell, so Windows has nothing to learn.
  if [ "$dells" = 1 ]; then sync_windows; maybe_restore; fi
  return $rc
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
  local extra=""
  if [ "$2" = work ]; then
    set_display lupa work
    extra=", LUPA -> work laptop"
  elif [ "$1" = pollux ] && [ "$2" = pollux ]; then
    set_display lupa pollux
    extra=", LUPA -> POLLUX"
  fi
  if [ "$1" = "$2" ]; then
    notify "ROMULUS + REMUS -> $(label "$1")$extra"
  else
    notify "ROMULUS -> $(label "$1"), REMUS -> $(label "$2")$extra"
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
  # The topology below is re-derived from scratch, so a NEMESIS-side kill
  # (see kill_nemesis) is over: any desk preset brings the panel back.
  rm -f "$STATE_DIR"/dark-*
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

# fire: snapshot the armed set now, before we might wait on the lock.
FIRE_SET=""
if [ "${1:-}" = fire ] && [ -n "${2:-}" ]; then
  if [ -n "${3:-}" ]; then FIRE_SET="${*:3}"; else FIRE_SET=$(armed_list | tr '\n' ' '); fi
  armed_clear; armed_render
fi

case "${1:-}" in
  status|check|displays|json|arm|armed|disarm|"") ;;
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
  romulus|remus|lupa|center|right|3|4)
    [ -n "${2:-}" ] || { echo "usage: $(basename "$0") $1 <pollux|nemesis|work>" >&2; exit 1; }
    if [ "$1" = lupa ]; then d=lupa; else d=$(display_name "$1"); fi
    m=$(machine_name "$2")
    set_display "$d" "$m" || exit 1
    notify "$(label "$d") -> $(label "$m")"
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
    force_pollux lupa || true
    notify "Reset: ROMULUS + REMUS + LUPA -> POLLUX (state cleared)"
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
  fire)
    case "${2:-}" in
      pollux|nemesis|work) fire "$2" $FIRE_SET || exit 1 ;;
      *) echo "usage: $(basename "$0") fire <pollux|nemesis|work> [romulus remus nyx]" >&2; exit 1 ;;
    esac
    ;;
  disarm)
    armed_clear; armed_render
    ;;
  nyx)
    case "${2:-}" in
      pollux|nemesis) nyx_set "$2" || exit 1; notify "NYX -> $(label "$2")" ;;
      *) echo "usage: $(basename "$0") nyx <pollux|nemesis>" >&2; exit 1 ;;
    esac
    ;;
  arm)
    case "${2:-}" in
      romulus|remus|nyx) arm_toggle "$2" ;;
      *) echo "usage: $(basename "$0") arm <romulus|remus|nyx>" >&2; exit 1 ;;
    esac
    ;;
  armed)
    armed_list
    ;;
  status)
    for d in romulus remus lupa; do
      if ddc_visible "$d"; then conn=connected; else conn=disconnected; fi
      [ -e "$STATE_DIR/dark-$d" ] && conn="$conn, dark on NEMESIS"
      printf '%-9s %s (%s)\n' "$d:" "$(current_machine "$d")" "$conn"
    done
    case "$("$SIDECAR_BIN" status 2>/dev/null)" in
      *"hold on"*) hold=on ;; *"hold off"*) hold=off ;; *) hold=unknown ;;
    esac
    printf '%-9s %s (hold %s)\n' "nyx:" "$(nyx_machine)" "${hold:-unknown}"
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
    sed -n '2,64p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
