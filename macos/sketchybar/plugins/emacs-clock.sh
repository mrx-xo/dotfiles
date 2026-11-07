#!/bin/bash
# -*- mode: sh -*-
# Emacs org-clock display plugin for sketchybar
# Shows the currently clocked-in task name and elapsed time

EMACSCLIENT="/opt/homebrew/opt/emacs-plus@31/bin/emacsclient"
GRUVBOX_YELLOW=0xFFfabd2f

# If pushed from Emacs via event vars, use those directly
if [ -n "$EMACS_CLOCK_TASK" ]; then
  if [ "$EMACS_CLOCK_TASK" = "__NONE__" ]; then
    sketchybar --set emacs_clock drawing=off
    exit 0
  fi

  LABEL="$EMACS_CLOCK_TASK"
  [ -n "$EMACS_CLOCK_TIME" ] && LABEL="$EMACS_CLOCK_TASK  $EMACS_CLOCK_TIME"

  sketchybar --set emacs_clock \
    drawing=on \
    "label=$LABEL"
  exit 0
fi

# Fallback: query Emacs directly
TASK=$($EMACSCLIENT --eval "(if (org-clocking-p) (substring-no-properties org-clock-heading) \"\")" 2>/dev/null | tr -d '"')

if [ -z "$TASK" ] || [ "$TASK" = "" ] || [ "$TASK" = "nil" ]; then
  sketchybar --set emacs_clock drawing=off
  exit 0
fi

ELAPSED=$($EMACSCLIENT --eval "(if (org-clocking-p) (org-duration-from-minutes (org-clock-get-clocked-time)) \"\")" 2>/dev/null | tr -d '"')

LABEL="$TASK"
[ -n "$ELAPSED" ] && [ "$ELAPSED" != "" ] && LABEL="$TASK  $ELAPSED"

sketchybar --set emacs_clock \
  drawing=on \
  "label=$LABEL"
