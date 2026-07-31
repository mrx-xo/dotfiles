#!/usr/bin/env bash
# boox-mirror.sh — live-mirror the BOOX Tab Ultra C onto the Mac (scrcpy).
#
# GOTCHA (verified 2026-07-29): the Tab Ultra C's Qualcomm hardware encoder
# (OMX.qcom.video.encoder.avc) fails with MediaCodec error 0xfffffff4 on this
# firmware (D60_SMT_V02). The software encoder works at full res (1860x2480).
# Do NOT drop the --video-encoder flag.
#
# Transport: prefers USB; falls back to Wi-Fi adb (tablet static-ish LAN IP).
# Wi-Fi adb does not survive tablet reboots — replug USB once and run
# `adb tcpip 5555` to re-arm it (or just use the cable).
set -euo pipefail

BOOX_IP="192.168.1.107"
COMMON=(
  --video-codec=h264
  --video-encoder=c2.android.avc.encoder
  --max-fps=30
  --window-title="BOOX Tab Ultra C"
)

# USB first: a bare serial (no colon) in `adb devices` means a cable is attached
if adb devices | awk 'NR>1 && $2=="device" && $1 !~ /:/ {found=1} END {exit !found}'; then
  exec scrcpy -d "${COMMON[@]}" "$@"
fi

# Wi-Fi fallback
adb connect "$BOOX_IP:5555" >/dev/null 2>&1 || true
exec scrcpy -e "${COMMON[@]}" "$@"
