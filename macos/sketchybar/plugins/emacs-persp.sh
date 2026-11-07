#!/bin/bash
# -*- mode: sh -*-
# Emacs perspective display plugin for sketchybar
# One slot item per perspective name — positions stay fixed,
# background highlight + brightness move to the active one

EMACSCLIENT="/opt/homebrew/opt/emacs-plus@31/bin/emacsclient"
WHITE=0xFFFFFFFF
DIM=0x60FFFFFF
HIGHLIGHT=0x00000000

hide_all() {
  sketchybar --set emacs_persp_pad_l drawing=off 2>/dev/null
  sketchybar --set emacs_persp_pad_r drawing=off 2>/dev/null
  for i in {1..10}; do
    sketchybar --set emacs_persp_slot.$i drawing=off 2>/dev/null
  done
}

# Get all Emacs windows, excluding scratchpads
EMACS_WINDOWS=$(yabai -m query --windows | jq '[.[] | select(.app == "Emacs" and .scratchpad == "")]' 2>/dev/null)
WINDOW_COUNT=$(echo "$EMACS_WINDOWS" | jq 'length' 2>/dev/null)

if [ -z "$WINDOW_COUNT" ] || [ "$WINDOW_COUNT" -eq 0 ]; then
  hide_all
  exit 0
fi

# Use focused Emacs window if available, otherwise first one
FOCUSED=$(yabai -m query --windows --window 2>/dev/null)
FOCUSED_APP=$(echo "$FOCUSED" | jq -r '.app' 2>/dev/null)

if [ "$FOCUSED_APP" = "Emacs" ]; then
  DISPLAY_IDX=$(echo "$FOCUSED" | jq -r '.display')
  TITLE=$(echo "$FOCUSED" | jq -r '.title')
else
  DISPLAY_IDX=$(echo "$EMACS_WINDOWS" | jq -r '.[0].display')
  TITLE=$(echo "$EMACS_WINDOWS" | jq -r '.[0].title')
fi

if [ -n "$EMACS_PERSP_NAME" ]; then
  ACTIVE="$EMACS_PERSP_NAME"
  ALL_CSV="$EMACS_PERSP_ALL"
else
  ACTIVE=$($EMACSCLIENT --eval "(persp-current-name)" 2>/dev/null | tr -d '"')
  ALL_CSV=$($EMACSCLIENT --eval "(when (fboundp 'persp-names) (mapconcat #'identity (persp-names) \",\"))" 2>/dev/null | tr -d '"')
  [ "$ACTIVE" = "nil" ] || [ -z "$ACTIVE" ] && ACTIVE="main"
fi

# Fill slots with perspective names — batch into a single sketchybar call
# (spacers included in the batch below)
IFS=',' read -ra NAMES <<< "$ALL_CSV"
COUNT=${#NAMES[@]}

BATCH_ARGS=()
for i in $(seq 1 10); do
  idx=$((i - 1))
  if [ $idx -lt $COUNT ]; then
    name="${NAMES[$idx]}"
    if [ "$name" = "$ACTIVE" ]; then
      color=0xFF000000
      bg=0xFFFFFFFF
      bg_drawing=on
    else
      color=$WHITE
      bg=0x00000000
      bg_drawing=off
    fi

    BATCH_ARGS+=(--set emacs_persp_slot.$i
      drawing=on
      display=$DISPLAY_IDX
      "label=$name"
      label.color=$color
      label.padding_left=6
      label.padding_right=6
      background.drawing=$bg_drawing
      background.color=$bg
      background.corner_radius=5
      background.height=20)
  else
    BATCH_ARGS+=(--set emacs_persp_slot.$i drawing=off)
  fi
done

sketchybar \
  --set emacs_persp_pad_l drawing=on display=$DISPLAY_IDX \
  --set emacs_persp_pad_r drawing=on display=$DISPLAY_IDX \
  "${BATCH_ARGS[@]}" 2>/dev/null
