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

die() { printf 'agent-session-handoff: %s\n' "$*" >&2; exit 1; }

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
  cp "$src" "$dest/$id.jsonl"
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

cmd_import() {
  local q="${1:-}"; [ -n "$q" ] || die "usage: import <id|substr>"
  local dirs=()
  [ -d "$SHARED" ] && dirs+=("$SHARED")
  [ -d "$STAGING" ] && dirs+=("$STAGING")
  [ ${#dirs[@]} -gt 0 ] || die "no staged sessions (run: sync)"
  local meta; meta=$(find "${dirs[@]}" -name "*${q}*.meta" 2>/dev/null | head -1 || true)
  [ -n "$meta" ] || die "no staged session matching '$q'"

  local id src_home src_cwd
  id=$(meta_get SESSION_ID "$meta")
  src_home=$(meta_get SRC_HOME "$meta")
  src_cwd=$(meta_get SRC_CWD "$meta")
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

  printf 'imported %s\n  local cwd: %s\n  -> %s\n\nResume:\n  1. Open agent-shell with default-directory = %s\n  2. M-x agent-shell-resume-session  ->  %s   (or SPC c H)\n' \
    "$id" "$tgt_cwd" "$dest/$id.jsonl" "$tgt_cwd" "$id"
}

cmd_sync() {
  command -v rsync >/dev/null 2>&1 || die "rsync not found"
  # 1. push — stage this machine's recent sessions, mirror our namespace to the
  #    hub. -maxdepth 2 / -not -name 'agent-*' skips subagent + sidechain files.
  local outbox n=0 f
  outbox=$(mktemp -d)
  while IFS= read -r f; do
    stage_session "$f" "$outbox" >/dev/null 2>&1 && n=$((n + 1)) || true
  done < <(find "$PROJECTS" -maxdepth 2 -name '*.jsonl' -not -name 'agent-*' \
                -mtime -"$RECENT_DAYS" 2>/dev/null)
  ssh "$REMOTE_HOST" "mkdir -p '$REMOTE_DIR/$MACHINE'" \
    || { rm -rf "$outbox"; die "cannot reach hub ($REMOTE_HOST)"; }
  rsync -az --delete "$outbox/" "$REMOTE_HOST:$REMOTE_DIR/$MACHINE/"
  rm -rf "$outbox"
  # 2. pull — mirror the whole hub store into local (non-synced) staging.
  mkdir -p "$STAGING"
  rsync -az --delete "$REMOTE_HOST:$REMOTE_DIR/" "$STAGING/"
  printf 'sync: pushed %d recent session(s) as "%s"; pulled hub -> %s\n' \
    "$n" "$MACHINE" "$STAGING"
}

case "${1:-}" in
  sync)   cmd_sync ;;
  list)   shift; cmd_list "${1:-}" ;;
  export) shift; cmd_export "${1:-}" ;;
  import) shift; cmd_import "${1:-}" ;;
  inbox)  cmd_inbox ;;
  *) die "usage: agent-session-handoff.sh {sync|list|export|import|inbox} [id|substr]" ;;
esac
