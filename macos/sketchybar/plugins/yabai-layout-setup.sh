#!/bin/bash
# -*- mode: sh -*-

# This script dynamically creates layout indicators for each connected display

# First, remove all existing yabai_layout items (up to 10 displays should be enough)
for i in {1..10}; do
  sketchybar --remove yabai_layout.$i 2>/dev/null
done

# Get all connected displays
DISPLAYS=$(yabai -m query --displays | jq -r '.[].index')

# Create a layout indicator for each display
for display_index in $DISPLAYS; do
  sketchybar --add item yabai_layout.$display_index left \
             --set yabai_layout.$display_index \
               display=$display_index \
               script='bash ./plugins/yabai-layout-display.sh' \
               updates=on
  
  # Subscribe to events
  sketchybar --subscribe yabai_layout.$display_index layout_change space_change
done

# Bracket for shared pill background
sketchybar --add bracket yabai_layout_group '/yabai_layout\..*/'       \
           --set yabai_layout_group background.color=0xbf000000        \
                                    background.corner_radius=10        \
                                    background.height=25

# These items are removed and re-added above on every display change, which
# lands them at the end of the bar and pushes the layout pill to the right of
# anything added after it in sketchybarrc. Put them back on the left of the
# AI-usage pill.
if sketchybar --query claude_usage >/dev/null 2>&1; then
  for display_index in $DISPLAYS; do
    sketchybar --move yabai_layout.$display_index before claude_usage
  done
fi

# Pin the app-title (center) item to the portrait display only: the
# MacBook notch and the light bar across both landscape externals all
# sit in the middle of the bar, so the center region stays empty there.
# Portrait is found by shape (h > w), not arrangement-id — ids shuffle
# on display replug.
PORTRAIT=$(sketchybar --query displays | jq '[.[] | select(.frame.h > .frame.w)][0]."arrangement-id" // empty')
if [ -n "$PORTRAIT" ]; then
  sketchybar --set title display=$PORTRAIT drawing=on
else
  sketchybar --set title drawing=off
fi

# Initial update to set the icons
sketchybar --update