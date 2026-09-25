#!/usr/bin/env bash
# tangle-emacs-org.sh — regenerate init.el + agent-shell-config.el from emacs.org
#
# For edits made OUTSIDE Emacs (agents, scripts, git merges), where the
# after-save auto-tangle hook never fired.  Editing inside Emacs needs none
# of this — saving emacs.org auto-tangles.
#
# Why not `emacs --batch -l org -f org-babel-tangle`?  Two bugs:
#   1. -f runs before any file is visited → "Wrong type argument: stringp, nil"
#   2. batch `-l org` uses the BUILT-IN org, whose tangle output differs
#      byte-wise from the Elpaca org the daemon uses → the ERT test
#      config-test-tangled-output-in-sync fails on hash mismatch.
#
# So: prefer the running daemon (canonical env).  Fallback loads the full
# init.el so Elpaca's org does the tangling.
set -euo pipefail

# Resolve beside this script so an isolated worktree tangles its own config.
ORG="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../emacs/.emacs.d" && pwd)/emacs.org"
EMACS="/opt/homebrew/opt/emacs-plus@30/bin/emacs"
# Full path + explicit socket: a bare `emacsclient` is missing from any shell
# without /opt/homebrew/bin (ssh, launchd), which used to read as "daemon not
# running" and silently took the batch path.  The daemon is started with
# --fg-daemon=server, so name the socket the same way emacs-daemon-start.sh does.
# Allow isolated testing without evaluating anything in the main daemon.
EMACSCLIENT="/opt/homebrew/opt/emacs-plus@30/bin/emacsclient --socket-name=${TANGLE_EMACS_SOCKET:-server}"

if $EMACSCLIENT --eval t >/dev/null 2>&1; then
  result=$($EMACSCLIENT --eval "(let ((buf (find-buffer-visiting \"$ORG\")))
    (if (and buf (buffer-modified-p buf))
        :unsaved-buffer
      (with-current-buffer (or buf (find-file-noselect \"$ORG\"))
        (revert-buffer :ignore-auto :noconfirm)
        (length (org-babel-tangle)))))")
  if [ "$result" = ":unsaved-buffer" ]; then
    echo "ABORT: emacs.org has unsaved changes in the running Emacs — save it there first (which auto-tangles anyway)." >&2
    exit 1
  fi
  echo "Tangled via daemon: $result files written."
else
  echo "Daemon not running — batch tangling with full init.el (Elpaca org)..."
  "$EMACS" --batch -l "$HOME/.emacs.d/init.el" \
    --eval "(org-babel-tangle-file \"$ORG\")" 2>/dev/null
  echo "Tangled via batch."
fi
