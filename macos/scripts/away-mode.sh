#!/usr/bin/env bash
# away-mode.sh — make MrX safely reachable while away, and undo it later.
#
#   away on       preflight, snapshot settings, disable auto-install updates,
#                 battery sleep -> 0, print the access recipes
#   away off      restore everything from the snapshot
#   away status   on/off + preflight
#   away dark     desk lights off + displays to sleep (HA script.sleep_desk);
#                 also as `away on --dark`. Cosmetic only: the Mac stays awake.
#
# Snapshot lives in ~/.config/away-mode/state. Design:
#   ~/home-lab/docs/superpowers/specs/2026-09-04-away-mode-design.md
#
# Why the update toggle: FileVault is on. An auto-installed macOS update
# reboots to the FileVault screen and nothing user-level (Emacs daemon,
# acp-mobile, Tailscale) comes back until someone types the password.

set -u

STATE_DIR="${AWAY_STATE_DIR:-$HOME/.config/away-mode}"
STATE="$STATE_DIR/state"
EMACSCLIENT=/opt/homebrew/opt/emacs-plus@30/bin/emacsclient
SU_PLIST=/Library/Preferences/com.apple.SoftwareUpdate
COMMERCE_PLIST=/Library/Preferences/com.apple.commerce
HOMELAB_TS=100.80.97.50
MRX2_TS=100.84.72.38
ACP_PORT=8090

HA_URL=https://home.andrade-lab.com
HA_TOKEN_FILE="$HOME/.config/gaia/ha-token.txt"

force=0; dark=0
for a in "$@"; do
  [ "$a" = "--force" ] && force=1
  [ "$a" = "--dark" ] && dark=1
done
cmd="${1:-status}"

ok()   { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; failures=$((failures + 1)); }
warn() { printf '  warn  %s\n' "$*"; }

ts_json() { tailscale status --json 2>/dev/null; }

preflight() {
  failures=0
  echo "Preflight:"
  local js; js=$(ts_json) || { fail "tailscale CLI not answering"; return 1; }

  local self_ip self_online self_expiry
  read -r self_ip self_online self_expiry < <(python3 - "$js" <<'PY'
import json, sys
d = json.loads(sys.argv[1]); s = d["Self"]
print(s["TailscaleIPs"][0], s["Online"], s.get("KeyExpiry") or "none")
PY
)
  if [ "$self_online" = "True" ]; then ok "tailscale online as $self_ip"; else fail "tailscale offline"; fi
  if [ "$self_expiry" = "none" ]; then ok "tailscale key expiry disabled"; else fail "tailscale key expires $self_expiry (disable in admin console)"; fi

  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://$self_ip:$ACP_PORT/" 2>/dev/null || echo 000)
  if [ "$code" != "000" ]; then ok "acp-mobile answering on $self_ip:$ACP_PORT (http $code)"; else fail "acp-mobile not answering on $self_ip:$ACP_PORT"; fi

  if "$EMACSCLIENT" --eval '(emacs-pid)' >/dev/null 2>&1; then ok "emacs daemon answers"; else fail "emacs daemon not answering"; fi

  if nc -z -G 2 127.0.0.1 22 >/dev/null 2>&1; then ok "sshd listening on :22"; else fail "sshd not listening (System Settings > General > Sharing > Remote Login)"; fi

  if pmset -g batt | grep -q "AC Power"; then ok "charger connected"; else fail "on battery power"; fi

  local peer_state
  for peer in "homelab:$HOMELAB_TS" "mrx2:$MRX2_TS"; do
    local name=${peer%%:*} ip=${peer##*:}
    peer_state=$(python3 - "$js" "$ip" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
for p in d["Peer"].values():
    if sys.argv[2] in p["TailscaleIPs"]:
        print("online" if p["Online"] else "offline"); break
else:
    print("missing")
PY
)
    if [ "$peer_state" = "online" ]; then ok "$name online on tailnet ($ip)"; else fail "$name $peer_state on tailnet ($ip)"; fi
  done

  if ssh -o BatchMode=yes -o ConnectTimeout=5 homelab 'crontab -l 2>/dev/null | grep -q mrx-watchdog' 2>/dev/null; then
    ok "homelab mrx-watchdog cron installed"
  else
    warn "homelab mrx-watchdog cron not found (services/mrx-watchdog/deploy.sh in home-lab)"
  fi

  local auto_install; auto_install=$(defaults read $SU_PLIST AutomaticallyInstallMacOSUpdates 2>/dev/null || echo "?")
  local bat_sleep; bat_sleep=$(battery_sleep)
  echo "Settings: auto-install macOS updates=$auto_install  battery sleep=${bat_sleep}min"
  [ "$failures" -eq 0 ]
}

battery_sleep() {
  pmset -g custom | awk '/^Battery Power:/{b=1} /^AC Power:/{b=0} b && $1=="sleep"{print $2}'
}

read_default() { defaults read "$1" "$2" 2>/dev/null || echo 1; }

print_recipes() {
  echo
  echo "Reach MrX from away:"
  echo "  agent-shell (phone/Air browser):"
  if [ -r "$HOME/.acp-mobile/link" ]; then
    local link; link=$(cat "$HOME/.acp-mobile/link")
    echo "    $link"
    echo "    $(echo "$link" | sed -E "s#http://[^:/]+#http://$(tailscale ip -4 2>/dev/null)#")   (IP form: works without MagicDNS)"
  else echo "    (no ~/.acp-mobile/link file)"; fi
  echo "  terminal from MrX2:        ssh mrx"
  echo "  emacs from MrX2:           ssh -t mrx zsh -lic 'emacsclient -t'"
  echo "  homelab from anywhere:     ssh homelab   (or https://*.andrade-lab.com via the subnet route)"
}

do_on() {
  if [ -f "$STATE" ]; then
    echo "away mode already ON since $(sed -n 's/^at=//p' "$STATE")"; preflight; print_recipes; return
  fi
  if ! preflight; then
    if [ "$force" -eq 1 ]; then echo "preflight failed, continuing (--force)"; else echo "preflight failed; fix it or re-run with --force"; return 1; fi
  fi
  sudo -v || return 1
  mkdir -p "$STATE_DIR"
  {
    echo "at=$(date '+%Y-%m-%d %H:%M')"
    echo "AutomaticallyInstallMacOSUpdates=$(read_default $SU_PLIST AutomaticallyInstallMacOSUpdates)"
    echo "CriticalUpdateInstall=$(read_default $SU_PLIST CriticalUpdateInstall)"
    echo "AutoUpdate=$(read_default $COMMERCE_PLIST AutoUpdate)"
    echo "battery_sleep=$(battery_sleep)"
  } > "$STATE"
  sudo defaults write $SU_PLIST AutomaticallyInstallMacOSUpdates -bool false
  sudo defaults write $SU_PLIST CriticalUpdateInstall -bool false
  sudo defaults write $COMMERCE_PLIST AutoUpdate -bool false
  sudo pmset -b sleep 0
  echo
  echo "away mode ON: auto-install updates off, battery sleep 0. Snapshot in $STATE"
  print_recipes
  [ "$dark" -eq 1 ] && { echo; do_dark; }
}

do_dark() {
  # Same path as saying "good night": lights off, monitor light bars off,
  # displays to sleep. Nothing here affects sleep/network/remote access.
  [ -r "$HA_TOKEN_FILE" ] || { echo "dark: no HA token at $HA_TOKEN_FILE"; return 1; }
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -X POST \
    -H "Authorization: Bearer $(cat "$HA_TOKEN_FILE")" -H "Content-Type: application/json" \
    "$HA_URL/api/services/script/turn_on" -d '{"entity_id":"script.sleep_desk"}')
  if [ "$code" = "200" ]; then echo "dark: desk lights off, displays sleeping (script.sleep_desk)"; else echo "dark: HA call failed (http $code)"; return 1; fi
}

do_off() {
  if [ ! -f "$STATE" ]; then echo "away mode is not on (no $STATE)"; return 0; fi
  sudo -v || return 1
  local v
  v=$(sed -n 's/^AutomaticallyInstallMacOSUpdates=//p' "$STATE"); sudo defaults write $SU_PLIST AutomaticallyInstallMacOSUpdates -bool "$([ "$v" = 1 ] && echo true || echo false)"
  v=$(sed -n 's/^CriticalUpdateInstall=//p' "$STATE");           sudo defaults write $SU_PLIST CriticalUpdateInstall -bool "$([ "$v" = 1 ] && echo true || echo false)"
  v=$(sed -n 's/^AutoUpdate=//p' "$STATE");                      sudo defaults write $COMMERCE_PLIST AutoUpdate -bool "$([ "$v" = 1 ] && echo true || echo false)"
  v=$(sed -n 's/^battery_sleep=//p' "$STATE");                   sudo pmset -b sleep "${v:-5}"
  rm -f "$STATE"
  echo "away mode OFF: restored auto-install updates and battery sleep=${v:-5}"
}

do_status() {
  if [ -f "$STATE" ]; then echo "away mode: ON since $(sed -n 's/^at=//p' "$STATE")"; else echo "away mode: off"; fi
  preflight
}

case "$cmd" in
  on) do_on ;;
  off) do_off ;;
  dark) do_dark ;;
  status|--force|--dark) do_status ;;
  *) echo "usage: away-mode.sh on|off|status|dark [--force] [--dark]"; exit 2 ;;
esac
