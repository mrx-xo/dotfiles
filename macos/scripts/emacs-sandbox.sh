#!/bin/bash
# Launch isolated sandbox Emacs (daemon mode)
# Your real Emacs session is completely untouched
#
# Usage:
#   emacs-sandbox.sh          # Ensure daemon is running, spawn a frame
#   emacs-sandbox.sh --restart # Kill daemon, restart, spawn a frame
#   emacs-sandbox.sh --fresh  # Nuke sandbox, resync from main config, restart daemon
#   emacs-sandbox.sh --test   # Spawn frame and auto-run test environment
#   emacs-sandbox.sh --kill   # Stop the sandbox daemon

SANDBOX_DIR="$HOME/.emacs-sandbox"
EMACS="/opt/homebrew/opt/emacs-plus@30/bin/emacs"
SOCKET_NAME="sandbox"
AUTO_TEST=""
KILL_DAEMON=""
FRESH=""
RESTART=""

# Handle flags
for arg in "$@"; do
    case $arg in
        --fresh)   FRESH="yes" ;;
        --test)    AUTO_TEST="yes" ;;
        --kill)    KILL_DAEMON="yes" ;;
        --restart) RESTART="yes" ;;
    esac
done

# Check if sandbox daemon is running
daemon_running() {
    emacsclient --socket-name="$SOCKET_NAME" --eval "t" &>/dev/null
}

# Save which display the sandbox window is on (match by PID)
save_display() {
    if daemon_running; then
        local pid
        pid=$(emacsclient --socket-name="$SOCKET_NAME" --eval "(emacs-pid)" 2>/dev/null | tr -d '"')
        if [[ -n "$pid" ]]; then
            yabai -m query --windows | jq -r \
                ".[] | select(.app == \"Emacs\" and .pid == $pid) | .display" \
                | head -1 > /tmp/emacs-sandbox-display
        fi
    fi
}

# Move the sandbox window back to its saved display (match by PID)
restore_display() {
    if [[ -f /tmp/emacs-sandbox-display ]]; then
        DISPLAY_IDX=$(cat /tmp/emacs-sandbox-display)
        if [[ -n "$DISPLAY_IDX" ]]; then
            sleep 0.5
            local pid
            pid=$(emacsclient --socket-name="$SOCKET_NAME" --eval "(emacs-pid)" 2>/dev/null | tr -d '"')
            if [[ -n "$pid" ]]; then
                WID=$(yabai -m query --windows | jq -r \
                    ".[] | select(.app == \"Emacs\" and .pid == $pid) | .id" | head -1)
                [[ -n "$WID" ]] && yabai -m window "$WID" --display "$DISPLAY_IDX" && yabai -m window "$WID" --focus
            fi
        fi
        rm /tmp/emacs-sandbox-display
    fi
}

# Stop the daemon gracefully
kill_daemon() {
    if daemon_running; then
        echo "Stopping sandbox daemon..."
        emacsclient --socket-name="$SOCKET_NAME" --eval "(kill-emacs)" 2>/dev/null
        sleep 0.3
    fi
}

# --kill: just stop and exit
if [[ -n "$KILL_DAEMON" ]]; then
    kill_daemon
    echo "Sandbox daemon stopped."
    exit 0
fi

# --restart: kill daemon, then continue to restart + spawn
if [[ -n "$RESTART" ]]; then
    save_display
    kill_daemon
fi

# --fresh: nuke everything and rebuild
if [[ -n "$FRESH" ]]; then
    echo "Nuking sandbox and resyncing from main config..."
    save_display
    kill_daemon
    rm -rf "$SANDBOX_DIR"
fi

# Create sandbox dir if it doesn't exist
if [[ ! -d "$SANDBOX_DIR" ]]; then
    echo "Creating sandbox from current config..."
    cp -r ~/.emacs.d "$SANDBOX_DIR"

    # 1. Enable title bar (comment out undecorated-round)
    sed -i '' "s/(add-to-list 'default-frame-alist '(undecorated-round . t))/;; SANDBOX: (add-to-list 'default-frame-alist '(undecorated-round . t))/" "$SANDBOX_DIR/early-init.el"

    # 2. Create sandbox indicator file
    cat > "$SANDBOX_DIR/sandbox-indicator.el" << 'EOF'
;;; sandbox-indicator.el --- Visual indicator for sandbox Emacs -*- lexical-binding: t; -*-

;; Title bar shows SANDBOX
(setq frame-title-format '("SANDBOX - " "%b"))

;; Doom modeline custom segment
(with-eval-after-load 'doom-modeline
  (doom-modeline-def-segment sandbox
    "Sandbox indicator segment."
    (propertize " SANDBOX " 'face '(:background "#ff6b6b" :foreground "white" :weight bold)))

  (doom-modeline-def-modeline 'main
    '(bar workspace-name window-number sandbox modals matches follow buffer-info remote-host buffer-position word-count parrot selection-info)
    '(compilation objed-state misc-info persp-name battery grip irc mu4e gnus github debug repl lsp minor-modes input-method indent-info buffer-encoding major-mode process vcs check time)))

(message "Running in SANDBOX mode - your real config is safe!")

(provide 'sandbox-indicator)
;;; sandbox-indicator.el ends here
EOF

    # 3. Add loader to init.el
    echo '' >> "$SANDBOX_DIR/init.el"
    echo ';; Sandbox visual indicator' >> "$SANDBOX_DIR/init.el"
    echo '(load (expand-file-name "sandbox-indicator.el" user-emacs-directory) t)' >> "$SANDBOX_DIR/init.el"
    # tab-lab: major-pane styling playground (C-c l to build the scene).
    # The file rides along in the .emacs.d copy; only sandbox init loads it.
    echo ';; Sandbox tab-lab (major-pane styling playground)' >> "$SANDBOX_DIR/init.el"
    echo '(load (expand-file-name "sandbox/tab-lab.el" user-emacs-directory) t)' >> "$SANDBOX_DIR/init.el"

    echo "Sandbox created with visual indicators."
fi

# Start daemon if not already running
if ! daemon_running; then
    echo "Starting sandbox daemon..."
    $EMACS --daemon="$SOCKET_NAME" --init-directory "$SANDBOX_DIR"
    echo "Sandbox daemon started."
else
    echo "Sandbox daemon already running."
fi

# Spawn a frame
echo "Spawning sandbox frame..."
if [[ -n "$AUTO_TEST" ]]; then
    emacsclient --socket-name="$SOCKET_NAME" -c -n \
        --eval "(run-with-timer 1 nil #'mr-x/sandbox-test-env)"
else
    emacsclient --socket-name="$SOCKET_NAME" -c -n
fi

restore_display
