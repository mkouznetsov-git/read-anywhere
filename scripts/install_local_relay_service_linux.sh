#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICE_DIR="$HOME/.config/systemd/user"
SERVICE_FILE="$SERVICE_DIR/readarc-relay.service"
mkdir -p "$SERVICE_DIR"

cat > "$SERVICE_FILE" <<SERVICE
[Unit]
Description=ReadArc local relay
After=network-online.target

[Service]
Type=simple
WorkingDirectory=$ROOT_DIR
Environment=READANYWHERE_RELAY_HOST=0.0.0.0
Environment=READANYWHERE_RELAY_PORT=8787
ExecStart=/bin/bash $ROOT_DIR/scripts/run_local_relay.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
SERVICE

systemctl --user daemon-reload
systemctl --user enable --now readarc-relay.service

echo "Installed and started user service: readarc-relay.service"
echo "Status: systemctl --user status readarc-relay.service"
echo "Health check: curl http://127.0.0.1:8787/health"
