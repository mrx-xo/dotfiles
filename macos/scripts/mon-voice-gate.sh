#!/usr/bin/env bash
# mon-voice-gate.sh — forced command for the HA voice-assistant SSH key.
#
# Home Assistant (script.set_monitor_mode, called by the voice LLM) sshes in
# with a dedicated key whose authorized_keys entry pins command= to this gate.
# Only whitelisted monitor-mode.sh invocations pass; anything else is refused,
# so the key is useless as a general shell.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"  # m1ddc, betterdisplaycli

cmd="${SSH_ORIGINAL_COMMAND:-}"
echo "$(date '+%F %T') gate: '$cmd'" >> "$HOME/.local/state/monitor-mode/voice.log"

case "$cmd" in
  displays\ sleep|displays\ wake) set -- $cmd ;;
  reset|status) set -- $cmd ;;
  # desk states: what ROMULUS shows, then what REMUS shows
  pollux|nemesis) set -- $cmd ;;
  pollux\ nemesis|nemesis\ pollux|pollux\ work) set -- $cmd ;;
  romulus\ pollux|romulus\ nemesis) set -- $cmd ;;
  remus\ pollux|remus\ nemesis|remus\ work) set -- $cmd ;;
  toggle\ romulus|toggle\ remus) set -- $cmd ;;
  *)
    echo "mon-voice-gate: refused: '$cmd'" >&2
    exit 1
    ;;
esac

exec "$HOME/.dotfiles/macos/scripts/monitor-mode.sh" "$@"
