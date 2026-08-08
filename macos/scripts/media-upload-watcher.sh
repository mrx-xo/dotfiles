#!/usr/bin/env bash
# media-upload-watcher.sh — non-interactive immich-up for the iCloud inbox
#
# Watches (via launchd WatchPaths) the iCloud Drive folder "media-upload".
# Anything dropped there from the phone (Files app / share sheet) gets:
#   1. videos → scp to the private Jellyfin uploads dir on homelab
#   2. everything → immich-go upload to the private Immich (mrz vault)
#   3. on success → moved to ~/media-upload-archive (leaves iCloud, so the
#      inbox stays empty and phone/iCloud storage is freed; local copy kept)
#
# Mirrors the upload behavior of roaming/projects/home-lab/scripts/immich-up
# (same server, key, flags, Jellyfin dir) minus the gum prompts.
# API key comes from ~/.config/immich-up/env (IMMICH_KEY_MRZ), never here.
set -euo pipefail

INBOX="$HOME/Library/Mobile Documents/com~apple~CloudDocs/media-upload"
ARCHIVE="$HOME/media-upload-archive"
# NOT the Caddy URL (https://mrx-photos.andrade-lab.com): macOS Local Network
# privacy silently denies homebrew binaries LAN access under launchd ("no route
# to host"), with no prompt for background agents. The tailscale IP rides utun,
# which isn't "local network", so immich-go gets through — and it's WG-encrypted.
SERVER="http://100.80.97.50:2284"
JELLY_DIR="/mnt/hgst/my-media/backup-backups/uploads"
LOGDIR="$HOME/Library/Logs/media-upload"

mkdir -p "$INBOX" "$ARCHIVE" "$LOGDIR"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }

# single-flight: WatchPaths fires on every touch, including our own moves.
# mkdir is the atomic primitive (no flock on macOS); a lockdir older than
# 2h is a crashed run — reclaim it rather than wedging the watcher forever.
LOCKDIR="$LOGDIR/watcher.lockdir"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
    if [[ -n $(find "$LOGDIR" -maxdepth 1 -name watcher.lockdir -mmin +120) ]]; then
        log "reclaiming stale lock"
        rmdir "$LOCKDIR" 2>/dev/null || true
        mkdir "$LOCKDIR" 2>/dev/null || exit 0
    else
        log "another run in progress — exiting"
        exit 0
    fi
fi
trap 'rmdir "$LOCKDIR"' EXIT

CONF="$HOME/.config/immich-up/env"
[[ -f "$CONF" ]] || { log "missing $CONF"; exit 1; }
# shellcheck source=/dev/null
source "$CONF"
[[ -n "${IMMICH_KEY_MRZ:-}" ]] || { log "IMMICH_KEY_MRZ not set in $CONF"; exit 1; }

media_find() {
    find "$INBOX" -type f ! -name '.*' \( \
        -iname '*.jpg'  -o -iname '*.jpeg' -o -iname '*.png'  -o -iname '*.gif'  \
        -o -iname '*.heic' -o -iname '*.webp' -o -iname '*.tif' -o -iname '*.tiff' \
        -o -iname '*.dng'  -o -iname '*.bmp' \
        -o -iname '*.mov'  -o -iname '*.mp4' -o -iname '*.m4v' -o -iname '*.avi'  \
        -o -iname '*.mkv'  -o -iname '*.3gp' -o -iname '*.wmv' \) "$@"
}

video_find() {
    find "$INBOX" -type f ! -name '.*' \( \
        -iname '*.mov' -o -iname '*.mp4' -o -iname '*.m4v' -o -iname '*.avi' \
        -o -iname '*.mkv' -o -iname '*.3gp' -o -iname '*.wmv' \) "$@"
}

# nothing here at all (no media, no undownloaded placeholders) → done
if [[ -z $(media_find | head -1) && -z $(find "$INBOX" -name '*.icloud' | head -1) ]]; then
    log "inbox empty — nothing to do"
    exit 0
fi

# ── wait for iCloud to finish delivering ─────────────────────────────
# Two kinds of not-ready files: ".name.icloud" placeholders, and dataless
# files that keep their real name and full logical size but have 0 allocated
# blocks (%b) until fileproviderd materializes them — reading those gets
# EDEADLK ("Resource deadlock avoided"). Poll until no placeholders, no
# dataless files, and two consecutive name/size/blocks snapshots match.
# Give up after ~30 min (huge video on slow uplink) and try again next fire.
dataless_count() {
    media_find -exec stat -f '%z %b' {} + 2>/dev/null \
        | awk '$1 > 0 && $2 == 0' | wc -l | tr -d ' '
}
brctl download "$INBOX" 2>/dev/null || true
prev=""
for _ in $(seq 1 180); do
    placeholders=$(find "$INBOX" -name '*.icloud' | wc -l | tr -d ' ')
    snap=$(media_find -exec stat -f '%N %z %b' {} + 2>/dev/null | sort)
    if [[ "$placeholders" == 0 && $(dataless_count) == 0 && "$snap" == "$prev" ]]; then
        break
    fi
    prev="$snap"
    brctl download "$INBOX" 2>/dev/null || true
    sleep 10
done

# timed out with content still missing: don't upload half-downloaded files.
# Touch a hidden marker — that dirties the watched dir, so launchd fires us
# again and the wait resumes, indefinitely, with no manual re-kick needed.
if [[ $(dataless_count) != 0 ]]; then
    log "iCloud still downloading $(dataless_count) file(s) after 30 min — rescheduling"
    # rm+recreate, not plain touch: WatchPaths only fires on directory-entry
    # changes, and updating an existing file's mtime isn't one
    rm -f "$INBOX/.icloud-retry"
    touch "$INBOX/.icloud-retry"
    exit 0
fi
rm -f "$INBOX/.icloud-retry"

count=$(media_find | wc -l | tr -d ' ')
if [[ "$count" == 0 ]]; then
    log "inbox empty — nothing to do"
    exit 0
fi
log "processing $count file(s)"

# ── 1. videos → private Jellyfin ─────────────────────────────────────
vidcount=$(video_find | wc -l | tr -d ' ')
if [[ "$vidcount" -gt 0 ]]; then
    log "[1/2] copying $vidcount video(s) → homelab:$JELLY_DIR"
    ssh -o BatchMode=yes homelab "mkdir -p $(printf %q "$JELLY_DIR")"
    video_find -print0 | while IFS= read -r -d '' f; do
        scp -o BatchMode=yes -p "$f" "homelab:$JELLY_DIR/"
    done
    log "jellyfin copy done"
fi

# ── 2. everything → private Immich ───────────────────────────────────
log "[2/2] uploading to Immich ($SERVER)"
immich-go upload from-folder -s "$SERVER" -k "$IMMICH_KEY_MRZ" \
    --pause-immich-jobs=false --on-errors continue \
    --exclude-extensions .xmp,.aae,.pak,.pdn \
    --no-ui "$INBOX"
log "immich upload done"

# ── 3. archive (evicts from iCloud, keeps local copy) ────────────────
stamp=$(date '+%Y-%m-%d')
mkdir -p "$ARCHIVE/$stamp"
media_find -print0 | while IFS= read -r -d '' f; do
    mv "$f" "$ARCHIVE/$stamp/"
done
# sweep sidecars/leftovers immich-go consumed but we don't archive by name
find "$INBOX" -type f -name '.DS_Store' -delete 2>/dev/null || true
log "archived to $ARCHIVE/$stamp — inbox clear"
