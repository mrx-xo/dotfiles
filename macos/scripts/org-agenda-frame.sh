#!/bin/bash
# Dedicated org-agenda frame
# Opens Focus agenda view ("f") in a new emacsclient frame

EMACSCLIENT="/opt/homebrew/opt/emacs-plus@31/bin/emacsclient"

# If an agenda frame already exists, focus it instead of creating a new one
EXISTING=$(yabai -m query --windows | jq -r '.[] | select(.app == "Emacs" and (.title | contains("Agenda"))) | .id' | head -1)

if [[ -n "$EXISTING" ]]; then
    yabai -m window "$EXISTING" --focus
else
    $EMACSCLIENT --no-wait --create-frame --eval \
      '(progn
         (set-frame-parameter nil (quote title) "Agenda")
         (setq frame-title-format "Agenda")
         (org-agenda nil "f")
         (delete-other-windows)
         (set-window-dedicated-p (selected-window) t))'
fi
