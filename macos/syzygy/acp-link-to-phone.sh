#!/bin/bash
# Text yourself the acp-mobile link via the agent-inbox Telegram bot.
# For when the phone's home-screen icon goes stale (key rotation, cookie
# loss) and you need a fresh tappable URL — no QR codes, no typing.
#
# Reuses the agent-inbox secrets: bot token in the login Keychain
# (service "agent-inbox-token"), chat id in ~/.config/agent-inbox/env.
#
# Usage: acp-link-to-phone.sh            # this machine's link
#        acp-link-to-phone.sh vengeance  # another box's link over ssh
#        acp-link-to-phone.sh /path/to/link
set -euo pipefail

LABEL="agent-shell mobile link"
if [[ $# -eq 0 ]]; then
  LINK_FILE="$HOME/.acp-mobile/link"
elif [[ -r "$1" ]]; then
  LINK_FILE="$1"
else
  # ssh host: Windows boxes keep the file under %USERPROFILE%, Macs under $HOME;
  # both are "~" for the remote shell.
  LINK_FILE=$(mktemp)
  trap 'rm -f "$LINK_FILE"' EXIT
  ssh -n "$1" 'cat ~/.acp-mobile/link' | tr -d '\r' > "$LINK_FILE"
  LABEL="agent-shell mobile link ($1)"
fi
[[ -s "$LINK_FILE" ]] || { echo "no link at $LINK_FILE — is acp-mobile set up?" >&2; exit 1; }

TOKEN=$(security find-generic-password -s agent-inbox-token -w)
source "$HOME/.config/agent-inbox/env"

curl -sf -m 10 "https://api.telegram.org/bot${TOKEN}/sendMessage" \
  --data-urlencode "chat_id=${TELEGRAM_ALLOWED_CHAT_ID}" \
  --data-urlencode "text=$LABEL: $(cat "$LINK_FILE")" \
  > /dev/null
echo "link sent to Telegram"
