#!/bin/bash
# -*- mode: sh -*-
# Emacs daemon status: the cacodemon narrates startup, then goes quiet.
#
# States (pushed as EMACS_STATUS_STATE with EMACS_STATUS_LABEL):
#   starting  emacs-daemon-start.sh is launching the daemon
#   booting   Emacs is loading; the label says what it is on
#   ready     finished; the label flashes green, then hides
#   notready  the launcher gave up waiting; stays red until the next start
# With no state (routine/forced), it is a health check that never talks to
# Emacs: a frozen daemon must not hang the bar. It only asks whether the
# process exists, and shows a red cross when it does not.

ITEM="${NAME:-emacs_status}"
STATE_FILE="${EMACS_STATUS_STATE_FILE:-${TMPDIR:-/tmp}/sketchybar-emacs-status}"
SUMMARY="${EMACS_STATUS_SUMMARY:-$HOME/.emacs.d/var/boot-status.last}"
ALIVE_CMD="${EMACS_STATUS_ALIVE_CMD:-pgrep -qf -- --fg-daemon=server}"
FLASH_SECONDS="${EMACS_STATUS_FLASH_SECONDS:-8}"

YELLOW=0xFFfabd2f
GREEN=0xFFb8bb26
RED=0xFFfb4934

show() { # state color label
  printf '%s\n' "$1" > "$STATE_FILE"
  sketchybar --set "$ITEM" label.drawing=on label.color="$2" "label=$3"
}

quiet() {
  printf 'idle\n' > "$STATE_FILE"
  sketchybar --set "$ITEM" label.drawing=off
}

popup() {
  if [ -r "$SUMMARY" ]; then
    # shellcheck disable=SC1090
    . "$SUMMARY"
    sketchybar --set "$ITEM.total" "label=last boot ${EMACS_BOOT_TOTAL}s" \
               --set "$ITEM.split" "label=init ${EMACS_BOOT_INIT}s · packages ${EMACS_BOOT_PACKAGES}s" \
               --set "$ITEM.slowest" "label=slowest: ${EMACS_BOOT_SLOWEST:-n/a}" \
               --set "$ITEM.at" "label=at ${EMACS_BOOT_AT} · pid ${EMACS_BOOT_PID}"
  else
    sketchybar --set "$ITEM.total" "label=no boot recorded yet" \
               --set "$ITEM.split" drawing=off --set "$ITEM.slowest" drawing=off \
               --set "$ITEM.at" drawing=off
  fi
  sketchybar --set "$ITEM" popup.drawing=toggle
}

current=$(cat "$STATE_FILE" 2>/dev/null)

case "$SENDER" in
  mouse.clicked) popup; exit 0 ;;
  mouse.exited.global) sketchybar --set "$ITEM" popup.drawing=off; exit 0 ;;
esac

case "$EMACS_STATUS_STATE" in
  starting|booting) show booting "$YELLOW" "${EMACS_STATUS_LABEL:-starting}" ;;
  idle) quiet ;;
  notready) show notready "$RED" "${EMACS_STATUS_LABEL:-not ready}" ;;
  ready)
    stamp="ready $$"
    show "$stamp" "$GREEN" "${EMACS_STATUS_LABEL:-ready}"
    # Hide after the flash unless a newer state arrived meanwhile.
    ( sleep "$FLASH_SECONDS"
      [ "$(cat "$STATE_FILE" 2>/dev/null)" = "$stamp" ] && quiet ) &
    ;;
  *)
    if $ALIVE_CMD; then
      [ "$current" = down ] && quiet
    elif [ "$current" != notready ]; then
      show down "$RED" "✗"
    fi
    ;;
esac
