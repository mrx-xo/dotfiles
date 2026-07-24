#!/bin/bash
# airdrop-inbox-mover.sh — route AirDropped images from ~/Downloads into ~/agent-inbox/
#
# Triggered by launchd WatchPaths on ~/Downloads (com.marx.airdrop-inbox.plist).
# Companion transport to agent-inbox-daemon.py (Telegram): both feed the same
# ~/agent-inbox/ directory that agent-shell-inbox.el watches while armed.
#
# A file qualifies iff:
#   - image extension (png/jpg/jpeg/webp/heic, any case)
#   - com.apple.quarantine names sharingd as the receiving agent — that's the
#     AirDrop daemon, so this deterministically excludes browser downloads
#   - quarantine timestamp (arrival time) within RECENT_SECS. NOT mtime:
#     AirDrop preserves the phone-side capture time, so a photo taken last
#     year arrives with a year-old mtime. The quarantine stamp is when it
#     actually landed on this Mac.
#
# HEIC converts to JPEG via sips (agent-shell-inbox-image-regexp and the
# Claude API only take png/jpg/webp); everything else moves via same-volume
# rename, so the Emacs watcher never sees a partial file. Filenames mirror
# agent-inbox-daemon.py: <utc-stamp>-<rand6><ext>, and .tmp- temps in the
# inbox get cleaned by that daemon's sweep if we ever crash mid-convert.

set -uo pipefail

DOWNLOADS="$HOME/Downloads"
INBOX="$HOME/agent-inbox"
LOG="$HOME/Library/Logs/agent-inbox/airdrop-mover.log"
RECENT_SECS=300

mkdir -p "$INBOX" "$(dirname "$LOG")"
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

now=$(date +%s)
shopt -s nullglob nocaseglob
for f in "$DOWNLOADS"/*.png "$DOWNLOADS"/*.jpg "$DOWNLOADS"/*.jpeg \
         "$DOWNLOADS"/*.webp "$DOWNLOADS"/*.heic; do
    q=$(xattr -p com.apple.quarantine "$f" 2>/dev/null) || continue
    IFS=';' read -r _flags qts agent _rest <<< "$q"
    [ "$agent" = "sharingd" ] || continue
    [[ "$qts" =~ ^[0-9a-fA-F]+$ ]] || continue
    (( now - 16#$qts <= RECENT_SECS )) || continue

    # Settle check: AirDrop should land whole, but skip anything still growing.
    # The next WatchPaths trigger (or the file's close) re-runs us anyway.
    s1=$(stat -f %z "$f" 2>/dev/null) || continue
    sleep 0.3
    s2=$(stat -f %z "$f" 2>/dev/null) || continue
    [ "$s1" = "$s2" ] || { log "skip (still writing): ${f##*/}"; continue; }

    stamp=$(date -u +%Y%m%d-%H%M%S)
    rand=$(uuidgen | tr -d '-' | cut -c1-6 | tr '[:upper:]' '[:lower:]')
    ext=$(echo ".${f##*.}" | tr '[:upper:]' '[:lower:]')
    if [ "$ext" = ".heic" ]; then
        tmp="$INBOX/.tmp-$rand.jpg"
        if sips -s format jpeg "$f" --out "$tmp" >/dev/null 2>&1; then
            mv "$tmp" "$INBOX/$stamp-$rand.jpg" && rm -f "$f"
            log "converted+moved ${f##*/} -> $stamp-$rand.jpg"
        else
            rm -f "$tmp"
            log "sips failed on ${f##*/}, leaving in Downloads"
        fi
    else
        mv "$f" "$INBOX/$stamp-$rand$ext" \
            && log "moved ${f##*/} -> $stamp-$rand$ext"
    fi
done
