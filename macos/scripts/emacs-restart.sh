#!/bin/bash
# Restart Emacs daemon and open a new client frame

EMACSCLIENT="/opt/homebrew/opt/emacs-plus@30/bin/emacsclient"
PLIST=~/Library/LaunchAgents/com.marcosandrade.emacsdaemon.plist

# Confirm before tearing the daemon down. skhd binds this to Cmd+Shift+R
# system-wide, and that chord is also "hard reload" in Chrome, so one stray
# press used to kill every agent-shell session. Default button is Cancel:
# Enter, Escape, and a 20s timeout all bail. Set EMACS_RESTART_NOCONFIRM=1
# to skip the dialog from scripts.
if [ -z "$EMACS_RESTART_NOCONFIRM" ]; then
    answer=$(osascript \
        -e 'try' \
        -e '  set r to display dialog "Restart the Emacs daemon?" with title "Emacs" buttons {"Cancel", "Restart"} default button "Cancel" cancel button "Cancel" with icon caution giving up after 20' \
        -e '  if gave up of r then return "timeout"' \
        -e '  return button returned of r' \
        -e 'on error' \
        -e '  return "cancel"' \
        -e 'end try' 2>/dev/null)
    if [ "$answer" != "Restart" ]; then
        echo "Restart cancelled ($answer)."
        exit 0
    fi
fi

echo "Checking for non-empty scratch buffers..."

# Check if there are non-empty scratch buffers and auto-save them
# This runs the save logic directly since kill-emacs-query-functions
# can't prompt interactively from a daemon without a frame
$EMACSCLIENT -e '(progn
  (let ((save-dir (expand-file-name "scratch-saves/" user-emacs-directory)))
    (unless (file-exists-p save-dir)
      (make-directory save-dir t))
    (dolist (buf (buffer-list))
      (when (and (string-match-p "\\*scratch\\*" (buffer-name buf))
                 (with-current-buffer buf
                   (and (> (buffer-size) 0)
                        (not (string-match-p "^# Clear your mind" (buffer-string))))))
        (with-current-buffer buf
          (write-file (expand-file-name
                       (format-time-string "scratch-%Y%m%d-%H%M%S.org")
                       save-dir))))))
  t)' 2>/dev/null

echo "Stopping Emacs daemon..."
$EMACSCLIENT -e '(kill-emacs)' 2>/dev/null || pkill -f "emacs.*daemon" 2>/dev/null

# kill-emacs exits 0, and KeepAlive/SuccessfulExit=false only restarts
# on non-zero exit — so launchd won't auto-restart. We must unload/load.
echo "Restarting via launchd..."
launchctl unload "$PLIST" 2>/dev/null
sleep 1
launchctl load "$PLIST"

echo "Waiting for daemon..."
MAX_ATTEMPTS=30
ATTEMPT=0

while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
    if $EMACSCLIENT -e '(+ 1 1)' &>/dev/null; then
        echo "Daemon ready."
        # Only open a frame if emacs-daemon-start.sh hasn't already
        if ! $EMACSCLIENT -e '(> (length (frame-list)) 1)' 2>/dev/null | grep -q t; then
            echo "Opening frame..."
            $EMACSCLIENT -c -n
        else
            echo "Frame already open."
        fi
        exit 0
    fi
    sleep 1
    ATTEMPT=$((ATTEMPT + 1))
done

echo "Daemon failed to start"
exit 1
