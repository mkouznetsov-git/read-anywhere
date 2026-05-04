#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELAY_DIR="$ROOT_DIR/server/rendezvous_relay"
HOST="${READANYWHERE_RELAY_HOST:-127.0.0.1}"
PORT="${READANYWHERE_RELAY_PORT:-8787}"

cd "$RELAY_DIR"

if [[ ! -d .venv ]]; then
  python3 -m venv .venv
fi

# shellcheck disable=SC1091
source .venv/bin/activate
python -m pip install --upgrade pip >/dev/null
pip install -r requirements.txt

echo "ReadAnywhere relay starting on http://$HOST:$PORT"
echo "Health check: http://$HOST:$PORT/health"
exec uvicorn main:app --host "$HOST" --port "$PORT"
