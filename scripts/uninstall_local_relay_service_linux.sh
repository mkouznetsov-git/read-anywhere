#!/usr/bin/env bash
set -euo pipefail

systemctl --user disable --now readanywhere-relay.service >/dev/null 2>&1 || true
rm -f "$HOME/.config/systemd/user/readanywhere-relay.service"
systemctl --user daemon-reload >/dev/null 2>&1 || true
echo "Removed ReadAnywhere relay user service."
