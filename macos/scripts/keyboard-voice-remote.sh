#!/usr/bin/env bash
# Trigger one fixed task in the Windows interactive session. No retry: a
# timeout may occur after the toggle arrived, and retrying could undo it.
set -euo pipefail
export PATH="$PATH:/opt/homebrew/bin"

if [ "$#" -ne 0 ]; then
  echo 'usage: keyboard-voice-remote.sh' >&2
  exit 2
fi
config="$HOME/.config/keyboard-voice/ssh-host"
if [ ! -s "$config" ]; then
  echo "Configure the Windows SSH alias in $config" >&2
  exit 2
fi
voice_host=$(cat "$config")
if [[ ! "$voice_host" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo 'Invalid ssh-host: expected one SSH alias, without options or spaces' >&2
  exit 2
fi
exec timeout 8 ssh -n -o BatchMode=yes -o ConnectTimeout=3 \
  -o ServerAliveInterval=2 -o ServerAliveCountMax=1 "$voice_host" \
  'MSYS_NO_PATHCONV=1 schtasks.exe /run /tn keyboard-voice-toggle'
