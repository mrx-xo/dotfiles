#!/bin/bash
# -*- mode: sh -*-
# Create the Emacs daemon status item: the cacodemon (Emacs's own app icon)
# plus a label that narrates startup. Sits after the AI usage percentages.
# Emacs pushes progress through the emacs_status_update event; see
# macos/emacs/.emacs.d/lisp/mr-x-boot-status.el.

sketchybar --remove '/emacs_status.*/' 2>/dev/null

sketchybar --add item emacs_status left \
           --set emacs_status \
             icon="" \
             icon.width=22 \
             icon.padding_left=10 \
             icon.background.drawing=on \
             icon.background.image=app.org.gnu.Emacs \
             icon.background.image.scale=0.55 \
             label="" \
             label.drawing=off \
             label.padding_left=6 \
             label.padding_right=8 \
             label.max_chars=52 \
             popup.align=left \
             popup.background.color=0xf0000000 \
             popup.background.corner_radius=8 \
             popup.background.border_width=0 \
             script='bash ./plugins/emacs-status.sh' \
             update_freq=30 \
             updates=on

for row in total split slowest at; do
  sketchybar --add item "emacs_status.$row" popup.emacs_status \
             --set "emacs_status.$row" \
               icon.drawing=off \
               label.padding_left=10 \
               label.padding_right=10
done

sketchybar --add event emacs_status_update
sketchybar --subscribe emacs_status emacs_status_update mouse.clicked mouse.exited.global

sketchybar --trigger emacs_status_update
