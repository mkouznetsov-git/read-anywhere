#!/usr/bin/env bash
set -euo pipefail

PORT="${READANYWHERE_RELAY_PORT:-8787}"
HTTPS_PORT="${READANYWHERE_FUNNEL_HTTPS_PORT:-443}"
TARGET="${READANYWHERE_FUNNEL_TARGET:-localhost:${PORT}}"

find_tailscale() {
  if command -v tailscale >/dev/null 2>&1; then
    command -v tailscale
    return 0
  fi
  for candidate in \
    "/Applications/Tailscale.app/Contents/MacOS/Tailscale" \
    "/Applications/Tailscale.app/Contents/MacOS/tailscale"; do
    if [[ -x "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

TAILSCALE_BIN="$(find_tailscale || true)"
if [[ -z "$TAILSCALE_BIN" ]]; then
  cat >&2 <<MSG
tailscale CLI not found.

Install Tailscale for macOS from the Standalone installer:
  https://tailscale.com/download

After installation, sign in to Tailscale and run this script again.
MSG
  exit 1
fi

cat <<MSG
This will publish local ReadAnywhere relay port $PORT to the public internet using Tailscale Funnel.

Keep the local relay running in another terminal:
  ./scripts/run_local_relay.sh

This script will run:
  sudo "$TAILSCALE_BIN" funnel --https=$HTTPS_PORT $TARGET

Tailscale will print a public HTTPS URL like:
  https://your-device.your-tailnet.ts.net

Use that URL in ReadAnywhere → Синхронизация → Personal Hub / Tailscale Funnel.

MSG

exec sudo "$TAILSCALE_BIN" funnel --https="$HTTPS_PORT" "$TARGET"
