#!/usr/bin/env bash
# agent-session-handoff.sh — hand off a Claude / agent-shell conversation
# between fleet machines (MrX <-> MrX2) via the Syncthing'd ~/shared folder.
#
# A conversation lives entirely in its JSONL transcript at
#   ~/.claude/projects/<encoded-cwd>/<session-id>.jsonl
# agent-shell resumes from that file (M-x agent-shell-resume-session, or the
# dedicated `mr-x/agent-resume-handoff' / SPC c H), so moving the file — with
# paths rewritten for the target machine — is all it takes to continue a chat
# on the other Mac.
#
# Two path adjustments make it work across machines:
#   1. home differs   (/Users/marcosandrade vs /Users/MrX2)
#   2. the repo may sit at a different REAL path per machine — MrX2's
#      ~/.dotfiles is a symlink to ~/dotfiles. Claude Code names its projects
#      dir from the RESOLVED cwd (pwd -P), so import must resolve symlinks or
#      the transcript lands in a folder Claude never reads -> blank resume.
# Everything derives from the LOCAL $HOME, so the same script works either way.
#
# Usage:
#   agent-session-handoff.sh list [substr]      # local sessions (optionally filtered)
#   agent-session-handoff.sh export <id|substr>  # stage a session into ~/shared
#   agent-session-handoff.sh import <id|substr>  # pull a synced session into local ~/.claude
#   agent-session-handoff.sh inbox               # sessions waiting in ~/shared for this machine

set -euo pipefail

PROJECTS="$HOME/.claude/projects"
SHARED="$HOME/shared/agent-sessions"

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
  local src id cwd title
  src=$(find_local "$q")
  id=$(basename "$src" .jsonl)
  # pull the real cwd straight from the transcript (every message line carries it)
  cwd=$(grep -m1 -o '"cwd":"[^"]*"' "$src" | head -1 | sed 's/"cwd":"//;s/"$//') || true
  [ -n "$cwd" ] || die "no cwd in $src — not a resumable transcript (metadata stub?)"
  title=$(extract_title "$src")

  mkdir -p "$SHARED"
  cp "$src" "$SHARED/$id.jsonl"
  # meta is KEY=VALUE, parsed via meta_get (never sourced). TITLE may hold spaces.
  {
    printf 'SESSION_ID=%s\n' "$id"
    printf 'SRC_HOME=%s\n'   "$HOME"
    printf 'SRC_CWD=%s\n'    "$cwd"
    printf 'SRC_MACHINE=%s\n' "$(cat "$HOME/.config/machine-id" 2>/dev/null || hostname)"
    printf 'TITLE=%s\n'      "$title"
  } > "$SHARED/$id.meta"

  printf 'exported %s\n  title: %s\n  cwd:   %s\n  -> %s\n\nOn the other machine:  agent-session-handoff.sh import %s\n' \
    "$id" "${title:-(untitled)}" "$cwd" "$SHARED/$id.jsonl" "$id"
}

cmd_inbox() {
  [ -d "$SHARED" ] || { echo "(nothing in $SHARED)"; return; }
  local found=
  for m in "$SHARED"/*.meta; do
    [ -e "$m" ] || continue
    found=1
    printf '%s  from %-8s  %s\n' \
      "$(meta_get SESSION_ID "$m")" "$(meta_get SRC_MACHINE "$m")" \
      "$(meta_get TITLE "$m")"
  done
  [ -n "$found" ] || echo "(nothing in $SHARED)"
}

cmd_import() {
  local q="${1:-}"; [ -n "$q" ] || die "usage: import <id|substr>"
  local meta; meta=$(find "$SHARED" -name "*${q}*.meta" 2>/dev/null | head -1 || true)
  [ -n "$meta" ] || die "no synced session matching '$q' in $SHARED"

  local id src_home src_cwd
  id=$(meta_get SESSION_ID "$meta")
  src_home=$(meta_get SRC_HOME "$meta")
  src_cwd=$(meta_get SRC_CWD "$meta")
  [ -n "$id" ] && [ -n "$src_home" ] && [ -n "$src_cwd" ] || die "meta $meta is incomplete"
  local jsonl="$SHARED/$id.jsonl"
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

case "${1:-}" in
  list)   shift; cmd_list "${1:-}" ;;
  export) shift; cmd_export "${1:-}" ;;
  import) shift; cmd_import "${1:-}" ;;
  inbox)  cmd_inbox ;;
  *) die "usage: agent-session-handoff.sh {list|export|import|inbox} [id|substr]" ;;
esac
