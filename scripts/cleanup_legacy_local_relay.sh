#!/usr/bin/env bash
set -Eeuo pipefail

APPLY=false
if [[ "${1:-}" == "--apply" ]]; then
  APPLY=true
elif [[ "${1:-}" != "" ]]; then
  echo "Usage: scripts/cleanup_legacy_local_relay.sh [--apply]"
  exit 2
fi

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"
FILES_TO_REMOVE=(
  "scripts/run_local_relay.sh"
  "scripts/tailscale_start_funnel.sh"
  "scripts/tailscale_status.sh"
  "scripts/install_local_relay_service_macos.sh"
  "scripts/uninstall_local_relay_service_macos.sh"
  "scripts/install_local_relay_service_linux.sh"
  "scripts/uninstall_local_relay_service_linux.sh"
)
for file in "${FILES_TO_REMOVE[@]}"; do
  if [[ -e "$file" ]]; then
    if [[ "$APPLY" == "true" ]]; then
      git rm -f "$file" 2>/dev/null || rm -f "$file"
    else
      echo "[dry-run] remove $file"
    fi
  fi
done
if [[ "$APPLY" == "true" ]]; then
  echo "Legacy local relay scripts removed."
else
  echo "Dry-run completed. Use --apply to remove files."
fi
