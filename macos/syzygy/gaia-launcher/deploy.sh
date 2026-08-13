#!/bin/bash
# Deploy the SYZYGY launcher to GAIA (homelab). Idempotent — rerun after
# editing syzygy-launcher.py to push + restart.
set -euo pipefail
cd "$(dirname "$0")"

HOST="${1:-homelab}"

scp syzygy-launcher.py syzygy-launcher.service "$HOST":/tmp/
ssh "$HOST" '
  set -e
  sudo mkdir -p /opt/syzygy
  sudo mv /tmp/syzygy-launcher.py /opt/syzygy/syzygy-launcher.py
  sudo mv /tmp/syzygy-launcher.service /etc/systemd/system/syzygy-launcher.service
  sudo systemctl daemon-reload
  sudo systemctl enable --now syzygy-launcher
  sudo systemctl restart syzygy-launcher
  sleep 1
  systemctl is-active syzygy-launcher
'
echo "deployed. launcher: http://$(ssh "$HOST" tailscale ip -4):8091/"
