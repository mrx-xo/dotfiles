#!/usr/bin/env bash
# mrx2-pull.sh — git pull every repo on MrX2, from MrX.
#
#   mrx2-pull.sh             # pull them all, show what moved
#   mrx2-pull.sh --wake      # WoL first if MrX2 is asleep, then pull
#   mrx2-pull.sh --no-reload # skip the Emacs daemon reload described below
#
# Finds repos by scanning MrX2's home for directories containing .git, so a new
# clone over there gets picked up without editing this script.
#
# When a pull moves Emacs config (emacs.org, init.el, agent-shell-config.el, or
# anything under lisp/), MrX2's running daemon is still on the old code, so the
# commit you just pushed does nothing over there until something loads it. This
# re-loads init.el in place with emacsclient. It never restarts the daemon --
# that would kill MrX2's agent-shell conversations, which is exactly what the
# unattended-runs box is holding.
#
# Uses `git pull --ff-only`: if MrX2 has local commits or a diverged branch it
# stops and says so, instead of quietly making a merge commit on a machine you
# are not looking at. Uncommitted files are reported, never touched.
set -euo pipefail

HOST="mrx2"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WAKE=0
RELOAD=1
for arg in "$@"; do
  case "$arg" in
    --wake)      WAKE=1 ;;
    --no-reload) RELOAD=0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [[ "$WAKE" == 1 ]]; then
  if ! ssh -n -o ConnectTimeout=4 "$HOST" true 2>/dev/null; then
    echo "$HOST asleep, sending WoL..."
    "$HERE/mrx2-wake.sh"
  fi
fi

if ! ssh -n -o ConnectTimeout=6 "$HOST" true 2>/dev/null; then
  echo "$HOST unreachable. Try: $(basename "$0") --wake" >&2
  exit 1
fi

# Pulling on MrX2 only helps if MrX actually pushed. Say so before the ssh, or
# the report below reads "up to date" while the commits sit here unpushed.
for local in "$HOME/.dotfiles" "$HOME/home-lab"; do
  [ -d "$local/.git" ] || continue
  branch=$(git -C "$local" branch --show-current 2>/dev/null) || continue
  [ -n "$branch" ] || continue
  git -C "$local" rev-parse --verify -q "origin/$branch" >/dev/null || continue
  ahead=$(git -C "$local" rev-list --count "origin/$branch..HEAD")
  if [ "$ahead" != 0 ]; then
    echo "heads-up: $(basename "$local") on MrX has $ahead unpushed commit(s) on $branch"
  fi
done

# Runs on MrX2. Kept as a string so this stays a single file; %q-quoted below.
REMOTE='
set -u
found=0
emacs_moved=0
reload_emacs=@@RELOAD@@
for dir in "$HOME"/*/; do
  [ -d "$dir/.git" ] || continue
  found=1
  name=$(basename "$dir")
  cd "$dir" || continue

  dirty=$(git status --porcelain | wc -l | tr -d " ")
  before=$(git rev-parse --short HEAD)

  if ! out=$(git pull --ff-only 2>&1); then
    printf "%-12s FAILED\n" "$name"
    printf "%s\n" "$out" | sed "s/^/             /"
    [ "$dirty" != 0 ] && printf "             %s uncommitted file(s) here\n" "$dirty"
    continue
  fi

  after=$(git rev-parse --short HEAD)
  if [ "$before" = "$after" ]; then
    printf "%-12s up to date (%s)\n" "$name" "$after"
  else
    n=$(git rev-list --count "$before..$after")
    printf "%-12s %s -> %s (%s commit(s))\n" "$name" "$before" "$after" "$n"
    changed=$(git diff --name-only "$before..$after")
    printf "%s\n" "$changed" | sed "s/^/             /"
    case "$changed" in
      *emacs.org*|*init.el*|*agent-shell-config.el*|*.emacs.d/lisp/*)
        emacs_moved=1
        printf "             note: Emacs config moved - re-tangle on MrX2 if you edited emacs.org there\n" ;;
    esac
  fi
  [ "$dirty" != 0 ] && printf "             note: %s uncommitted file(s) local to MrX2\n" "$dirty"
done
[ "$found" = 0 ] && echo "no git repos found in \$HOME"

# Reload, never restart: the daemon is holding agent-shell conversations.
if [ "$emacs_moved" = 1 ] && [ "$reload_emacs" = 1 ]; then
  EC=/opt/homebrew/opt/emacs-plus@30/bin/emacsclient
  if [ ! -x "$EC" ]; then
    printf "%-12s skipped reload (no emacsclient at %s)\n" "emacs" "$EC"
  elif ! "$EC" --eval t >/dev/null 2>&1; then
    printf "%-12s skipped reload (daemon not running)\n" "emacs"
  elif out=$("$EC" --eval "(load-file (expand-file-name \"~/.emacs.d/init.el\"))" 2>&1); then
    printf "%-12s daemon reloaded init.el\n" "emacs"
  else
    printf "%-12s RELOAD FAILED\n" "emacs"
    printf "%s\n" "$out" | tail -5 | sed "s/^/             /"
  fi
fi
exit 0
'

REMOTE=${REMOTE//@@RELOAD@@/$RELOAD}

ssh -n "$HOST" "zsh -lc $(printf '%q' "$REMOTE")"
