#!/usr/bin/env bash
set -euo pipefail

PORT="${READANYWHERE_RELAY_PORT:-8787}"
HTTPS_PORT="${READANYWHERE_FUNNEL_HTTPS_PORT:-443}"

if ! command -v tailscale >/dev/null 2>&1; then
  echo "tailscale CLI not found. Install Tailscale first: https://tailscale.com/download" >&2
  exit 1
fi

cat <<MSG
This will publish local ReadAnywhere relay port $PORT to the public internet using Tailscale Funnel.
Keep the local relay running in another terminal:

  ./scripts/run_local_relay.sh

Then this command starts Funnel:

  sudo tailscale funnel --https=$HTTPS_PORT $PORT

MSG

exec sudo tailscale funnel --https="$HTTPS_PORT" "$PORT"
