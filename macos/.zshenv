# ~/.zshenv — sourced by EVERY zsh invocation, including non-interactive
# SSH commands (`ssh mrx 'echo $MACHINE_ID'`), scripts, cron, launchd.
# Keep this file tiny — it runs constantly.

# Machine identity. Source of truth: ~/.config/machine-id (written by
# bootstrap.sh). Facts for agents: `whereami` or ~/.dotfiles/machines/<id>.md
export MACHINE_ID="$(cat "$HOME/.config/machine-id" 2>/dev/null || echo unknown)"

# Toolchain PATH for headless shells.  Interactive shells get this from
# .zshrc too, but `ssh host 'cmd'`, `zsh -c`, launchd and agents run neither
# .zshrc nor .zprofile, and were missing emacsclient, node and timeout —
# and libgccjit needs LIBRARY_PATH or Emacs native-comp fails to link.
if [[ -z "$HOMEBREW_PREFIX" && -x /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac
if [[ -z "$LIBRARY_PATH" && -d /opt/homebrew/opt/libgccjit/lib/gcc/current ]]; then
  export LIBRARY_PATH="/opt/homebrew/opt/libgccjit/lib/gcc/current:/opt/homebrew/opt/gcc/lib/gcc/current"
fi
