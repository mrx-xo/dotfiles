# ~/.zshenv — sourced by EVERY zsh invocation, including non-interactive
# SSH commands (`ssh mrx 'echo $MACHINE_ID'`), scripts, cron, launchd.
# Keep this file tiny — it runs constantly.

# Machine identity. Source of truth: ~/.config/machine-id (written by
# bootstrap.sh). Facts for agents: `whereami` or ~/.dotfiles/machines/<id>.md
export MACHINE_ID="$(cat "$HOME/.config/machine-id" 2>/dev/null || echo unknown)"
