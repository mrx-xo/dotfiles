#!/usr/bin/env bash
# deploy.sh — push boox/ configs from the dotfiles repo to the tablet.
# Requires: tablet awake-ish, Termux sshd running (`ssh boox` must work).
# Idempotent; run after editing anything in boox/.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

echo "==> checking ssh boox"
ssh boox 'echo ok' >/dev/null

echo "==> termux config"
ssh boox 'mkdir -p ~/.termux ~/.emacs.d'
scp -q "$HERE/termux/termux.properties" "$HERE/termux/colors.properties" boox:.termux/
ssh boox 'termux-reload-settings 2>/dev/null || true'

echo "==> emacs init.el"
scp -q "$HERE/emacs/init.el" boox:.emacs.d/init.el

echo "==> done. First Emacs start will install evil from MELPA (one-time, slow)."
