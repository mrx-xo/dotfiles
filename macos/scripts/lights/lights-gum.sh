#!/usr/bin/env bash
# lights-gum.sh — gum front-end for the VENGEANCE lights.
#
# A thin skin over `lightsctl`: it renders menus and shows status, but knows
# nothing about SSH or control files. Swap it for the Textual UI (or anything
# else) freely — they all speak the same lightsctl contract.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
CTL="$DIR/lightsctl"

command -v gum >/dev/null || { echo "needs gum: brew install gum"; exit 1; }

names() {  # names() effects|presets  -> one per line, from lightsctl list
  "$CTL" list --json | python3 -c "import json,sys;print('\n'.join(json.load(sys.stdin)['$1']))"
}

while true; do
  clear
  gum style --border rounded --padding "0 1" --margin "1 0" --border-foreground 213 "  VENGEANCE lights  "
  "$CTL" state
  echo
  choice=$(gum choose --header "what now?" \
    "🔌 wake VENGEANCE" "🔦 lights on" "🌑 lights off" "🗓 schedule" \
    "🎨 pick effect" "🎛  pick preset" "🎲 randomize" \
    "⟳ rotation on" "📌 pin current" "☀ brightness" "🧼 reset" "🔄 refresh" "✖ quit")
  case "$choice" in
    "🔌 wake VENGEANCE") "$CTL" wake --wait ;;
    "🔦 lights on")  "$CTL" on ;;
    "🌑 lights off") "$CTL" off ;;
    "🗓 schedule")   "$CTL" auto ;;
    "🎨 pick effect")
      name=$(names effects | gum choose --header "effect") || true
      [ -n "${name:-}" ] && "$CTL" set-effect "$name" ;;
    "🎛  pick preset")
      name=$(names presets | gum choose --header "preset") || true
      [ -n "${name:-}" ] && "$CTL" set-preset "$name" ;;
    "🎲 randomize")   "$CTL" random ;;
    "⟳ rotation on")  "$CTL" rotation on ;;
    "📌 pin current") "$CTL" rotation off ;;
    "☀ brightness")
      v=$(gum choose --header "brightness %" 100 75 50 25 10) || true
      [ -n "${v:-}" ] && "$CTL" brightness "$(python3 -c "print($v/100)")" ;;
    "🧼 reset")     "$CTL" reset ;;
    "🔄 refresh") : ;;
    "✖ quit"|"") clear; exit 0 ;;
  esac
  sleep 0.8
done
