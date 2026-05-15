#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: scripts/deploy_relay_zip.sh /path/to/readarc_sprint.zip"
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZIP="$1"
SERVER="${READARC_RELAY_SERVER:-root@relay.readarc.ru}"
REMOTE_ZIP="${READARC_REMOTE_ZIP:-/tmp/readarc-update.zip}"
REMOTE_UPDATER="${READARC_REMOTE_UPDATER:-/tmp/readarc_update_relay.sh}"

if [[ ! -f "$ZIP" ]]; then
  echo "Archive not found: $ZIP"
  exit 2
fi

if [[ ! -f "$ROOT_DIR/scripts/readarc_update_relay.sh" ]]; then
  echo "Updater script not found: $ROOT_DIR/scripts/readarc_update_relay.sh"
  exit 2
fi

echo "Uploading $ZIP to $SERVER..."
scp "$ZIP" "$SERVER:$REMOTE_ZIP"
scp "$ROOT_DIR/scripts/readarc_update_relay.sh" "$SERVER:$REMOTE_UPDATER"

echo "Installing relay updater on $SERVER..."
ssh "$SERVER" "set -Eeuo pipefail; if command -v sudo >/dev/null 2>&1; then sudo install -m 0755 '$REMOTE_UPDATER' /usr/local/bin/readarc-update-relay; else install -m 0755 '$REMOTE_UPDATER' /usr/local/bin/readarc-update-relay; fi"

echo "Updating relay on $SERVER..."
ssh "$SERVER" "readarc-update-relay '$REMOTE_ZIP'"

echo
echo "Relay deployment finished."
