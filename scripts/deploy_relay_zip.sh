#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: scripts/deploy_relay_zip.sh /path/to/readarc_sprint.zip"
  exit 2
fi

ZIP="$1"
SERVER="${READARC_RELAY_SERVER:-root@relay.readarc.ru}"
REMOTE_ZIP="${READARC_REMOTE_ZIP:-/tmp/readarc-update.zip}"

if [[ ! -f "$ZIP" ]]; then
  echo "Archive not found: $ZIP"
  exit 2
fi

echo "Uploading $ZIP to $SERVER..."
scp "$ZIP" "$SERVER:$REMOTE_ZIP"

echo "Updating relay on $SERVER..."
ssh "$SERVER" "readarc-update-relay $REMOTE_ZIP"

echo
echo "Relay deployment finished."
