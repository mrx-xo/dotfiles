#!/bin/bash
# Hyper+number: move the summoned keymap, otherwise move the focused window.
set -u
case "${1:-}" in
  [1-5]) display_index=$1 ;;
  *) printf 'Usage: keymap-display.sh DISPLAY (1-5)\n' >&2; exit 2 ;;
esac

# hs can print extension-loading messages before our result. Match whole lines.
# -a prevents a launch dialog when Hammerspoon is stopped (exit status 75).
# An IPC timeout is ambiguous: the overlay may still be up, so do not fall
# through to moving the underlying application in that case.
hs_status=0
reply=$(hs -a -t 1 -c "print('keymap:' .. (keymapWidget and keymapWidget.moveToDisplay and keymapWidget.moveToDisplay($display_index) or 'inactive'))" </dev/null 2>/dev/null) || hs_status=$?
case "$hs_status" in
  0) ;;
  75) reply="keymap:inactive" ;;
  *) printf 'Keymap display routing unavailable; no application moved.\n' >&2; exit 1 ;;
esac
while IFS= read -r line; do
  case "$line" in
    keymap:moved) exec yabai -m display --focus "$display_index" ;;
    keymap:unavailable) exit 0 ;;
    keymap:inactive)
      yabai -m window --display "$display_index"
      exec yabai -m display --focus "$display_index"
      ;;
  esac
done <<< "$reply"

printf 'Keymap display routing returned no result; no application moved.\n' >&2
exit 1
