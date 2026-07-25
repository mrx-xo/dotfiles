#!/bin/bash
# Restart Emacs daemon with full session restore
# Saves: buffers, window splits, frame geometry, yabai space assignments
# Restores everything after daemon restart
#
# Usage:
#   emacs-restart-restore.sh              # full restart + restore
#   emacs-restart-restore.sh save         # only save state (no restart)
#   emacs-restart-restore.sh restore      # only restore from saved state
#   emacs-restart-restore.sh save-yabai   # only save yabai window state
#   emacs-restart-restore.sh save-emacs   # only save emacs session state
#   emacs-restart-restore.sh restore-yabai # only restore yabai space assignments

EMACSCLIENT="/opt/homebrew/opt/emacs-plus@30/bin/emacsclient"
PLIST=~/Library/LaunchAgents/com.marcosandrade.emacsdaemon.plist
# Lives in ~/.emacs.d (not /tmp) so it survives a reboot; overridable so
# crash recovery can point it at the crash-state copy.
YABAI_STATE="${YABAI_STATE:-$HOME/.emacs.d/yabai-state.json}"
RESTORE_FLAG="/tmp/emacs-restore-session"

# ── Helpers ──

log() { echo "[$1] $2"; }

save_yabai() {
    log "YABAI" "Querying window state..."
    local state
    state=$(yabai -m query --windows 2>/dev/null | jq '[.[] | select(.app == "Emacs") | {id: .id, space: .space, display: .display, title: .title}]' 2>/dev/null)

    if [ -z "$state" ] || [ "$state" = "[]" ]; then
        log "YABAI" "No Emacs windows found"
        return 1
    fi

    echo "$state" > "$YABAI_STATE"
    local count
    count=$(echo "$state" | jq 'length')
    log "YABAI" "Saved $count windows:"
    echo "$state" | jq -r '.[] | "         \(.title) → space \(.space), display \(.display)"'
}

save_emacs() {
    log "EMACS" "Saving session state..."
    local result
    result=$($EMACSCLIENT -e '(mr-x/save-session-state)' 2>/dev/null)
    log "EMACS" "$result"

    # Log what's actually in the state file
    local state_file
    state_file=$($EMACSCLIENT -e 'mr-x/session-file' 2>/dev/null | tr -d '"')
    if [ -f "$state_file" ]; then
        local size
        size=$(wc -c < "$state_file" | tr -d ' ')
        log "EMACS" "State file: $state_file ($size bytes)"

        # Show frame details — use mapconcat to print one line per frame
        $EMACSCLIENT -e '(mr-x/session-state-summary)' 2>/dev/null | sed 's/^"//;s/"$//' | sed 's/\\n/\n/g' | while IFS= read -r line; do
            [ -n "$line" ] && echo "         $line"
        done
    fi
}

save_scratch() {
    log "SCRATCH" "Saving non-empty scratch buffers..."
    local result
    result=$($EMACSCLIENT -e '(progn
      (let ((save-dir (expand-file-name "scratch-saves/" user-emacs-directory))
            (saved nil))
        (unless (file-exists-p save-dir)
          (make-directory save-dir t))
        (dolist (buf (buffer-list))
          (when (and (string-match-p "\\*scratch\\*" (buffer-name buf))
                     (with-current-buffer buf
                       (and (> (buffer-size) 0)
                            (not (string-match-p "^# Clear your mind" (buffer-string))))))
            (with-current-buffer buf
              (let ((f (expand-file-name
                        (format-time-string "scratch-%Y%m%d-%H%M%S.org")
                        save-dir)))
                (write-file f)
                (push f saved)))))
        (if saved
            (format "Saved %d scratch buffer(s)" (length saved))
          "No scratch buffers to save")))' 2>/dev/null)
    log "SCRATCH" "$result"
}

kill_daemon() {
    log "DAEMON" "Stopping Emacs daemon..."
    $EMACSCLIENT -e '(kill-emacs)' 2>/dev/null
    # Give it a moment to die gracefully
    sleep 1
    # Verify it's dead
    if pgrep -f "emacs.*daemon" >/dev/null 2>&1; then
        log "DAEMON" "Still alive, force killing..."
        pkill -9 -f "emacs.*daemon" 2>/dev/null
        sleep 1
    fi
    log "DAEMON" "Stopped"
}

start_daemon() {
    # Set flag so emacs-daemon-start.sh skips its default frame
    touch /tmp/emacs-restore-session

    log "DAEMON" "Restarting via launchd..."
    launchctl unload "$PLIST" 2>/dev/null
    sleep 1
    launchctl load "$PLIST"

    log "DAEMON" "Waiting for daemon..."
    local attempt=0
    while [ $attempt -lt 30 ]; do
        if $EMACSCLIENT -e '(+ 1 1)' &>/dev/null; then
            log "DAEMON" "Ready"
            return 0
        fi
        sleep 1
        attempt=$((attempt + 1))
    done

    log "DAEMON" "FAILED to start after 30s"
    rm -f /tmp/emacs-restore-session
    return 1
}

restore_emacs() {
    log "EMACS" "Restoring session..."

    # Close the default frame that daemon-start may have created
    $EMACSCLIENT -e '(let ((frames (filtered-frame-list
                            (lambda (f)
                              (and (frame-visible-p f)
                                   (not (string= "F1" (frame-parameter f (quote name)))))))))
      (when (and (= (length frames) 1)
                 (string= "*scratch*" (buffer-name (window-buffer (frame-selected-window (car frames))))))
        (delete-frame (car frames))))' 2>/dev/null

    local result
    result=$($EMACSCLIENT -e '(mr-x/restore-session-state)' 2>/dev/null)
    log "EMACS" "$result"
}

restore_yabai() {
    if [ ! -f "$YABAI_STATE" ]; then
        log "YABAI" "No saved state file found at $YABAI_STATE"
        return 1
    fi

    log "YABAI" "Restoring space assignments..."

    # Match by creation order (window ID ascending) — titles change across
    # daemon restarts (Emacs auto-numbers as "Emacs #N"), so we sort both
    # lists by ID and pair them by index. mr-x/restore-session-state creates
    # frames in the same order they were saved, so IDs line up.
    local old_windows new_windows old_count new_count
    old_windows=$(cat "$YABAI_STATE" | jq 'sort_by(.id)')
    old_count=$(echo "$old_windows" | jq 'length')

    # YABAI_EXCLUDE: comma-separated window ids to ignore — e.g. a splash
    # frame that already existed when crash recovery kicked off a restore.
    new_windows=$(yabai -m query --windows 2>/dev/null \
        | jq --arg exclude "${YABAI_EXCLUDE:-}" \
             '[.[] | select(.app == "Emacs")
                   | select((.id | tostring) as $i | ($exclude | split(",") | index($i)) | not)]
              | sort_by(.id) | map({id: .id, title: .title, space: .space})')
    new_count=$(echo "$new_windows" | jq 'length')

    log "YABAI" "Saved: $old_count windows, Current: $new_count windows"

    if [ "$old_count" != "$new_count" ]; then
        log "YABAI" "WARNING: count mismatch — will pair what we can by order"
    fi

    local pair_count=$old_count
    [ "$new_count" -lt "$old_count" ] && pair_count=$new_count

    local moved=0
    for i in $(seq 0 $((pair_count - 1))); do
        local old_title old_space new_id new_title
        old_title=$(echo "$old_windows" | jq -r ".[$i].title")
        old_space=$(echo "$old_windows" | jq -r ".[$i].space")
        new_id=$(echo "$new_windows" | jq -r ".[$i].id")
        new_title=$(echo "$new_windows" | jq -r ".[$i].title")

        log "YABAI" "  [#$((i+1))] '$new_title' (id=$new_id) → space $old_space  (was: '$old_title')"
        if yabai -m window "$new_id" --space "$old_space" 2>/dev/null; then
            moved=$((moved + 1))
        fi
    done

    log "YABAI" "Done: $moved moved"
    rm -f "$YABAI_STATE"
    rm -f /tmp/emacs-restore-session
}

# ── Main ──

case "${1:-full}" in
    save)
        save_yabai
        save_emacs
        save_scratch
        echo ""
        log "DONE" "State saved. Run '$0 restore' after daemon restart."
        ;;
    save-yabai)
        save_yabai
        ;;
    save-emacs)
        save_emacs
        ;;
    restore)
        restore_emacs
        sleep 1
        restore_yabai
        echo ""
        log "DONE" "Session restored"
        ;;
    restore-yabai)
        restore_yabai
        ;;
    full)
        echo "═══ EMACS RESTART WITH SESSION RESTORE ═══"
        echo ""

        # Save everything
        save_yabai
        echo ""
        save_emacs
        echo ""
        save_scratch
        echo ""

        # Kill and restart
        kill_daemon
        start_daemon || exit 1
        echo ""

        # Restore everything
        restore_emacs
        sleep 1
        restore_yabai
        echo ""

        rm -f /tmp/emacs-restore-session
        log "DONE" "Full restart + restore complete"
        ;;
    *)
        echo "Usage: $0 [save|save-yabai|save-emacs|restore|restore-yabai|full]"
        exit 1
        ;;
esac
