#!/bin/bash
# -*- mode: sh -*-
# Create a pool of perspective slot items inside the shared left background
# Each perspective name gets its own slot so positions stay fixed

# Clean up old items
for i in {1..10}; do
  sketchybar --remove emacs_persp.$i 2>/dev/null
  sketchybar --remove emacs_persp_slot.$i 2>/dev/null
done
sketchybar --remove emacs_persp_pad_l 2>/dev/null
sketchybar --remove emacs_persp_pad_r 2>/dev/null
sketchybar --remove emacs_persp_group 2>/dev/null

WHITE=0xFFFFFFFF
DIM=0x60FFFFFF

# Left edge spacer for the perspective highlight
sketchybar --add item emacs_persp_pad_l left \
           --set emacs_persp_pad_l \
             drawing=off \
             icon.drawing=off \
             label=" " \
             label.padding_left=2 \
             label.padding_right=0 \
             background.drawing=off \
             width=6

# Create 10 slot items, all hidden
for i in $(seq 1 10); do
  sketchybar --add item emacs_persp_slot.$i left \
             --set emacs_persp_slot.$i \
               drawing=off \
               icon.drawing=off \
               label="" \
               label.color=$DIM \
               label.padding_left=6 \
               label.padding_right=6 \
               background.drawing=off \
               background.corner_radius=10 \
               background.height=22
done

# Right edge spacer
sketchybar --add item emacs_persp_pad_r left \
           --set emacs_persp_pad_r \
             drawing=off \
             icon.drawing=off \
             label=" " \
             label.padding_left=0 \
             label.padding_right=2 \
             background.drawing=off \
             width=6

# Event subscription on first slot
sketchybar --set emacs_persp_slot.1 \
  script='bash ./plugins/emacs-persp.sh' \
  updates=on
sketchybar --subscribe emacs_persp_slot.1 front_app_switched emacs_persp_update
