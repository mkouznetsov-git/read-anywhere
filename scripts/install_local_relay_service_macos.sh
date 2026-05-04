#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLIST="$HOME/Library/LaunchAgents/app.readanywhere.relay.plist"
LOG_DIR="$HOME/Library/Logs/ReadAnywhere"
mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIR"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>app.readanywhere.relay</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$ROOT_DIR/scripts/run_local_relay.sh</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>READANYWHERE_RELAY_HOST</key>
    <string>127.0.0.1</string>
    <key>READANYWHERE_RELAY_PORT</key>
    <string>8787</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/relay.out.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/relay.err.log</string>
</dict>
</plist>
PLIST

launchctl unload "$PLIST" >/dev/null 2>&1 || true
launchctl load "$PLIST"

echo "Installed and started LaunchAgent: $PLIST"
echo "Logs: $LOG_DIR/relay.out.log and $LOG_DIR/relay.err.log"
echo "Health check: curl http://127.0.0.1:8787/health"
