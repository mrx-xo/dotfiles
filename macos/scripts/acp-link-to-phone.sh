#!/bin/bash
# Text yourself the acp-mobile link via the agent-inbox Telegram bot.
# For when the phone's home-screen icon goes stale (key rotation, cookie
# loss) and you need a fresh tappable URL — no QR codes, no typing.
#
# Reuses the agent-inbox secrets: bot token in the login Keychain
# (service "agent-inbox-token"), chat id in ~/.config/agent-inbox/env.
set -euo pipefail

LINK_FILE="$HOME/.acp-mobile/link"
[[ -r "$LINK_FILE" ]] || { echo "no $LINK_FILE — is acp-mobile set up?" >&2; exit 1; }

TOKEN=$(security find-generic-password -s agent-inbox-token -w)
source "$HOME/.config/agent-inbox/env"

curl -sf -m 10 "https://api.telegram.org/bot${TOKEN}/sendMessage" \
  --data-urlencode "chat_id=${TELEGRAM_ALLOWED_CHAT_ID}" \
  --data-urlencode "text=agent-shell mobile link: $(cat "$LINK_FILE")" \
  > /dev/null
echo "link sent to Telegram"
