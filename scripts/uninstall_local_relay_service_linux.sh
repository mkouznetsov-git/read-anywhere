#!/usr/bin/env bash
set -euo pipefail

systemctl --user disable --now readarc-relay.service >/dev/null 2>&1 || true
rm -f "$HOME/.config/systemd/user/readarc-relay.service"
systemctl --user daemon-reload >/dev/null 2>&1 || true
echo "Removed ReadArc relay user service."
