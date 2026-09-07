#!/usr/bin/env bash
# mrx2-pull.sh — git pull every repo on MrX2, from MrX.
#
#   mrx2-pull.sh            # pull them all, show what moved
#   mrx2-pull.sh --wake     # WoL first if MrX2 is asleep, then pull
#
# Finds repos by scanning MrX2's home for directories containing .git, so a new
# clone over there gets picked up without editing this script.
#
# Uses `git pull --ff-only`: if MrX2 has local commits or a diverged branch it
# stops and says so, instead of quietly making a merge commit on a machine you
# are not looking at. Uncommitted files are reported, never touched.
set -euo pipefail

HOST="mrx2"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${1:-}" == "--wake" ]]; then
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
      *emacs.org*|*init.el*|*agent-shell-config.el*)
        printf "             note: Emacs config moved - re-tangle on MrX2 if you edited emacs.org there\n" ;;
    esac
  fi
  [ "$dirty" != 0 ] && printf "             note: %s uncommitted file(s) local to MrX2\n" "$dirty"
done
[ "$found" = 0 ] && echo "no git repos found in \$HOME"
exit 0
'

ssh -n "$HOST" "zsh -lc $(printf '%q' "$REMOTE")"
