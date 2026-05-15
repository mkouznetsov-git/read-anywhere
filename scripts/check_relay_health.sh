#!/usr/bin/env bash
set -euo pipefail

RELAY_URL="${1:-${READARC_RELAY_URL:-http://127.0.0.1:8787}}"
BASE="${RELAY_URL%/}"

echo "Checking $BASE/health"
curl --fail --show-error --silent "$BASE/health"
echo
