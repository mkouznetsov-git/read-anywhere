#!/usr/bin/env bash
set -euo pipefail

PLIST="$HOME/Library/LaunchAgents/app.readanywhere.relay.plist"
launchctl unload "$PLIST" >/dev/null 2>&1 || true
rm -f "$PLIST"
echo "Removed ReadAnywhere relay LaunchAgent."
