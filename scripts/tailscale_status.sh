#!/usr/bin/env bash
set -euo pipefail

if ! command -v tailscale >/dev/null 2>&1; then
  echo "tailscale CLI not found."
  exit 1
fi

tailscale status --self

echo
cat <<'MSG'
If Funnel is running, copy the HTTPS URL shown by Tailscale, for example:
  https://your-device.your-tailnet.ts.net

Paste it in ReadAnywhere:
  Синхронизация → Relay endpoint → Personal Hub / Tailscale Funnel
MSG
