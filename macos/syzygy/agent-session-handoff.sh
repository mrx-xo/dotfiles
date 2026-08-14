#!/usr/bin/env bash
# agent-session-handoff.sh — hand off / sync agent-shell conversations between
# fleet machines (MrX <-> MrX2), with home-lab as an always-on hub.
#
# A conversation lives entirely in its JSONL transcript at
#   ~/.claude/projects/<encoded-cwd>/<session-id>.jsonl
# agent-shell resumes from that file (mr-x/agent-resume-handoff, SPC c H), so
# moving it — with paths rewritten for the target machine — continues the chat
# on the other Mac.
#
# Two path adjustments make resume work across machines:
#   1. home differs   (/Users/marcosandrade vs /Users/MrX2)
#   2. the repo may sit at a different REAL path per machine — MrX2's
#      ~/.dotfiles is a symlink to ~/dotfiles. Claude Code names its projects
#      dir from the RESOLVED cwd (pwd -P), so import must resolve symlinks or
#      the transcript lands where Claude never reads -> blank resume.
# Everything derives from the LOCAL $HOME, so the same script works either way.
#
# Transports:
#   - `export'/`import' : one-off, via the Syncthing'd ~/shared (peer to peer).
#   - `sync'            : bidirectional, via home-lab. Pushes YOUR sessions from
#                         the last RECENT_DAYS, pulls everyone else's. home-lab
#                         is a dumb blob store (runs no code), namespaced by
#                         machine so rsync --delete can prune safely.
# The receiving side (SPC c H) hides handoffs whose project cwd doesn't exist
# locally, so a chat from a project you don't have here simply won't show up
# (and reappears on its own if you ever set that project up).
#
# Usage:
#   agent-session-handoff.sh sync                # push recent local + pull hub
#   agent-session-handoff.sh sync-all            # prod peers over ssh, then sync
#   agent-session-handoff.sh list [substr]       # local sessions (optionally filtered)
#   agent-session-handoff.sh export <id|substr>  # stage one session into ~/shared
#   agent-session-handoff.sh import <id|substr>  # place a staged session into ~/.claude
#   agent-session-handoff.sh inbox               # sessions staged for this machine

set -euo pipefail

PROJECTS="$HOME/.claude/projects"
SHARED="$HOME/shared/agent-sessions"                # manual export path (Syncthing peer-to-peer)
STAGING="$HOME/.local/share/agent-session-handoff"  # sync path (non-synced local mirror of the hub)
MACHINE="$(cat "$HOME/.config/machine-id" 2>/dev/null || hostname)"

# home-lab hub — dumb rsync target for `sync', namespaced by machine.
REMOTE_HOST="homelab"
REMOTE_DIR="agent-sessions"   # ~/agent-sessions on the hub
RECENT_DAYS=7                 # only sessions touched this recently get synced

# fleet peers to prod during `sync-all' — space-separated ssh hosts (see
# ~/.ssh/config). Each is asked to run its own `sync' (push to hub) before we
# pull, so their latest chats are on the hub by the time we list. Overridable:
#   SYZYGY_PEERS="mrx vengeance" agent-session-handoff.sh sync-all
PEERS="${SYZYGY_PEERS:-mrx}"
REMOTE_SCRIPT='~/.dotfiles/macos/syzygy/agent-session-handoff.sh'

die() { printf 'agent-session-handoff: %s\n' "$*" >&2; exit 1; }

# say — one-line progress to stderr. stderr is unbuffered, so each line streams
# out immediately (stdout to a pipe would block-buffer and arrive all at once);
# the Emacs picker's process filter relays these to the minibuffer live.
say() { printf '%s\n' "$*" >&2; }

# encode a cwd the way Claude Code names its projects dir: /  and  .  -> -
encode_cwd() { printf '%s' "$1" | sed 's#[/.]#-#g'; }

# read one KEY's value from a meta file WITHOUT sourcing it (values may hold
# spaces / shell metacharacters — sourcing would be unsafe and lossy).
meta_get() { sed -n "s/^$1=//p" "$2" | head -1; }

# derive a short human label from a transcript (ai-title > agent name > first
# real user prompt), for the handoff picker.
extract_title() {
  python3 - "$1" <<'PY' 2>/dev/null || true
import json, sys
title = first = None
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        o = json.loads(line)
    except Exception:
        continue
    t = o.get("type")
    if t == "ai-title" and o.get("aiTitle"):
        title = o["aiTitle"]; break
    if t == "agent-name" and o.get("agentName") and not title:
        title = o["agentName"]
    if t == "user" and first is None and not o.get("isMeta"):
        c = (o.get("message") or {}).get("content")
        s = None
        if isinstance(c, str):
            s = c
        elif isinstance(c, list):
            for p in c:
                if isinstance(p, dict) and p.get("type") == "text":
                    s = p.get("text"); break
        if s and not s.lstrip().startswith("<"):
            first = s
print(" ".join((title or first or "").split())[:80])
PY
}

# Stage a transcript (jsonl + KEY=VALUE meta) into DEST. Echoes the session id.
# Returns non-zero without staging for metadata stubs that carry no cwd.
stage_session() {
  local src="$1" dest="$2" id cwd title
  id=$(basename "$src" .jsonl)
  cwd=$(grep -m1 -o '"cwd":"[^"]*"' "$src" | head -1 | sed 's/"cwd":"//;s/"$//') || true
  [ -n "$cwd" ] || return 1
  title=$(extract_title "$src")
  mkdir -p "$dest"
  # -p keeps the transcript's mtime (rsync -a carries it through the hub), so
  # the SPC c H picker can show real conversation recency, not stage time.
  cp -p "$src" "$dest/$id.jsonl"
  {
    printf 'SESSION_ID=%s\n'  "$id"
    printf 'SRC_HOME=%s\n'    "$HOME"
    printf 'SRC_CWD=%s\n'     "$cwd"
    printf 'SRC_MACHINE=%s\n' "$MACHINE"
    printf 'TITLE=%s\n'       "$title"
  } > "$dest/$id.meta"
  printf '%s' "$id"
}

# find a local transcript by exact id or substring; echo its full path
find_local() {
  local q="$1" matches
  matches=$(find "$PROJECTS" -name '*.jsonl' -path "*${q}*" 2>/dev/null || true)
  [ -n "$matches" ] || die "no local session matching '$q'"
  if [ "$(printf '%s\n' "$matches" | wc -l)" -gt 1 ]; then
    printf 'multiple matches for %s:\n' "$q" >&2
    printf '%s\n' "$matches" | sed 's#.*/##;s/\.jsonl$//' >&2
    die "narrow the substring"
  fi
  printf '%s' "$matches"
}

cmd_list() {
  local filter="${1:-}"
  find "$PROJECTS" -name '*.jsonl' 2>/dev/null | while read -r f; do
    local id proj mtime
    id=$(basename "$f" .jsonl)
    proj=$(basename "$(dirname "$f")")
    [ -n "$filter" ] && [[ "$id$proj" != *"$filter"* ]] && continue
    mtime=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$f" 2>/dev/null || echo '?')
    printf '%s  %s  %s\n' "$mtime" "$id" "$proj"
  done | sort -r
}

cmd_export() {
  local q="${1:-}"; [ -n "$q" ] || die "usage: export <id|substr>"
  local src id
  src=$(find_local "$q")
  id=$(stage_session "$src" "$SHARED") \
    || die "no cwd in $src — not a resumable transcript (metadata stub?)"
  printf 'exported %s\n  -> %s\n\nOn the other machine:  agent-session-handoff.sh import %s\n' \
    "$id" "$SHARED/$id.jsonl" "$id"
}

cmd_inbox() {
  local found= m
  while IFS= read -r m; do
    [ -e "$m" ] || continue
    found=1
    printf '%s  from %-8s  %s\n' \
      "$(meta_get SESSION_ID "$m")" "$(meta_get SRC_MACHINE "$m")" \
      "$(meta_get TITLE "$m")"
  done < <(find "$SHARED" "$STAGING" -name '*.meta' 2>/dev/null)
  [ -n "$found" ] || echo "(nothing staged — run: agent-session-handoff.sh sync)"
}

# append_handoff_note TRANSCRIPT SRC_MACHINE TGT_MACHINE SRC_CWD TGT_CWD SID
# Add a single `isMeta' user record telling the resumed agent it was handed off
# (from -> to, path rewrite) and where to read up: the project's CLAUDE.md /
# README and macos/syzygy/README.md. isMeta means it's context the agent sees
# but isn't a prompt to answer.  Idempotent: any prior handoff note is dropped
# first, so a chat bounced across several machines carries exactly one (current)
# note, not a pile.  Threads off the last record's uuid so the log stays a chain.
append_handoff_note() {
  python3 - "$@" <<'PY' 2>/dev/null || true
import json, sys, uuid, datetime
path, src_m, tgt_m, src_cwd, tgt_cwd, sid = sys.argv[1:7]
MARK = "<handoff-context>"
recs = []
for line in open(path):
    line = line.strip()
    if not line:
        continue
    try:
        o = json.loads(line)
    except Exception:
        continue
    # drop a previous handoff note (idempotent re-import / multi-hop)
    if o.get("isMeta") and isinstance(o.get("message"), dict) \
       and isinstance(o["message"].get("content"), str) \
       and MARK in o["message"]["content"]:
        continue
    recs.append(o)
parent = git = ver = None
for o in recs:
    if o.get("uuid"):
        parent = o["uuid"]
    git = o.get("gitBranch", git)
    ver = o.get("version", ver)
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
note = (f"{MARK}\n"
        f"This agent-shell conversation was handed off from {src_m} to {tgt_m} "
        f"on {now[:10]} via syzygy (macos/syzygy/agent-session-handoff.sh). "
        f"Its transcript paths were rewritten for this machine "
        f"({src_cwd} -> {tgt_cwd}), so earlier turns may reference the source "
        f"layout. If machine- or repo-specific context matters, read up in the "
        f"project's CLAUDE.md and README plus macos/syzygy/README.md; otherwise "
        f"just continue where the conversation left off.\n</handoff-context>")
rec = {"parentUuid": parent, "isSidechain": False, "type": "user",
       "message": {"role": "user", "content": note}, "isMeta": True,
       "uuid": str(uuid.uuid4()), "timestamp": now,
       "userType": "external", "cwd": tgt_cwd, "sessionId": sid}
if git is not None: rec["gitBranch"] = git
if ver is not None: rec["version"] = ver
recs.append(rec)
with open(path, "w") as f:
    for o in recs:
        f.write(json.dumps(o) + "\n")
PY
}

cmd_import() {
  local q="${1:-}"; [ -n "$q" ] || die "usage: import <id|substr>"
  local dirs=()
  [ -d "$SHARED" ] && dirs+=("$SHARED")
  [ -d "$STAGING" ] && dirs+=("$STAGING")
  [ ${#dirs[@]} -gt 0 ] || die "no staged sessions (run: sync)"
  local meta; meta=$(find "${dirs[@]}" -name "*${q}*.meta" 2>/dev/null | head -1 || true)
  [ -n "$meta" ] || die "no staged session matching '$q'"

  local id src_home src_cwd src_mach
  id=$(meta_get SESSION_ID "$meta")
  src_home=$(meta_get SRC_HOME "$meta")
  src_cwd=$(meta_get SRC_CWD "$meta")
  src_mach=$(meta_get SRC_MACHINE "$meta")
  [ -n "$id" ] && [ -n "$src_home" ] && [ -n "$src_cwd" ] || die "meta $meta is incomplete"
  local jsonl; jsonl="$(dirname "$meta")/$id.jsonl"
  [ -f "$jsonl" ] || die "meta found but transcript missing: $jsonl"

  # translate home prefix, then resolve symlinks the way Claude Code will
  local tgt_raw tgt_cwd tgt_enc dest
  tgt_raw="${src_cwd/#$src_home/$HOME}"
  tgt_cwd="$( (cd "$tgt_raw" 2>/dev/null && pwd -P) || echo "$tgt_raw" )"
  tgt_enc=$(encode_cwd "$tgt_cwd")
  dest="$PROJECTS/$tgt_enc"
  mkdir -p "$dest"
  # rewrite paths inside: the specific project path first (handles .dotfiles ->
  # dotfiles), then any remaining home refs.
  sed -e "s#${src_cwd}#${tgt_cwd}#g" -e "s#${src_home}#${HOME}#g" \
    "$jsonl" > "$dest/$id.jsonl"
  # prime the resumed agent with a note about the handoff + where to read up
  append_handoff_note "$dest/$id.jsonl" "${src_mach:-another machine}" \
    "$MACHINE" "$src_cwd" "$tgt_cwd" "$id"

  printf 'imported %s\n  local cwd: %s\n  -> %s\n\nResume:\n  1. Open agent-shell with default-directory = %s\n  2. M-x agent-shell-resume-session  ->  %s   (or SPC c H)\n' \
    "$id" "$tgt_cwd" "$dest/$id.jsonl" "$tgt_cwd" "$id"
}

cmd_sync() {
  command -v rsync >/dev/null 2>&1 || die "rsync not found"
  # 1. push — stage this machine's recent sessions, mirror our namespace to the
  #    hub. -maxdepth 2 / -not -name 'agent-*' skips subagent + sidechain files.
  local outbox n=0 f
  outbox=$(mktemp -d)
  say "Gathering ${MACHINE}'s recent chats…"
  while IFS= read -r f; do
    stage_session "$f" "$outbox" >/dev/null 2>&1 && n=$((n + 1)) || true
  done < <(find "$PROJECTS" -maxdepth 2 -name '*.jsonl' -not -name 'agent-*' \
                -mtime -"$RECENT_DAYS" 2>/dev/null)
  say "Pushing ${n} chat(s) to ${REMOTE_HOST}…"
  ssh "$REMOTE_HOST" "mkdir -p '$REMOTE_DIR/$MACHINE'" \
    || { rm -rf "$outbox"; die "cannot reach hub ($REMOTE_HOST)"; }
  rsync -az --delete "$outbox/" "$REMOTE_HOST:$REMOTE_DIR/$MACHINE/"
  rm -rf "$outbox"
  # 2. pull — mirror the whole hub store into local (non-synced) staging.
  say "Pulling the fleet's chats into ${MACHINE}…"
  mkdir -p "$STAGING"
  rsync -az --delete "$REMOTE_HOST:$REMOTE_DIR/" "$STAGING/"
  say "Sync complete — ${n} pushed, hub pulled."
  printf 'sync: pushed %d recent session(s) as "%s"; pulled hub -> %s\n' \
    "$n" "$MACHINE" "$STAGING"
}

# `sync-all' — the "true" bidirectional sync. SSH into each peer and run its own
# `sync' (so it pushes its recent chats to the hub), then run our local `sync'
# to pull the freshened hub down. A sleeping / unreachable peer is warned about
# and skipped, never fatal: you still get your own + whatever's already on the
# hub. BatchMode keeps it non-interactive; ConnectTimeout keeps a dead box from
# hanging the picker.
cmd_sync_all() {
  local h
  for h in $PEERS; do
    say "SSHing into ${h}…"
    if ssh -o BatchMode=yes -o ConnectTimeout=8 "$h" "$REMOTE_SCRIPT sync" \
         >/dev/null 2>&1; then
      say "  ${h} pushed its chats to ${REMOTE_HOST}."
    else
      say "  ${h} unreachable — skipped."
    fi
  done
  cmd_sync
}

case "${1:-}" in
  sync)     cmd_sync ;;
  sync-all) cmd_sync_all ;;
  list)     shift; cmd_list "${1:-}" ;;
  export)   shift; cmd_export "${1:-}" ;;
  import)   shift; cmd_import "${1:-}" ;;
  inbox)    cmd_inbox ;;
  *) die "usage: agent-session-handoff.sh {sync|sync-all|list|export|import|inbox} [id|substr]" ;;
esac
