#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELAY_DIR="$ROOT_DIR/server/rendezvous_relay"
# Personal Hub must be reachable from other devices on the LAN. For a strictly
# local-only relay run: READANYWHERE_RELAY_HOST=127.0.0.1 ./scripts/run_local_relay.sh
HOST="${READANYWHERE_RELAY_HOST:-0.0.0.0}"
PORT="${READANYWHERE_RELAY_PORT:-8787}"

find_lan_ip() {
  if command -v ip >/dev/null 2>&1; then
    ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}'
    return 0
  fi
  if command -v route >/dev/null 2>&1 && command -v ipconfig >/dev/null 2>&1; then
    local iface
    iface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
    if [[ -n "${iface:-}" ]]; then
      ipconfig getifaddr "$iface" 2>/dev/null || true
      return 0
    fi
  fi
  hostname -I 2>/dev/null | awk '{print $1}' || true
}

cd "$RELAY_DIR"

if [[ ! -d .venv ]]; then
  python3 -m venv .venv
fi

# shellcheck disable=SC1091
source .venv/bin/activate
python -m pip install --upgrade pip >/dev/null
pip install -r requirements.txt

LAN_IP="$(find_lan_ip | head -n 1)"

echo "ReadArc relay starting"
echo "  Bind address: $HOST"
echo "  Port:         $PORT"
echo
echo "Health checks:"
echo "  Same computer: http://127.0.0.1:$PORT/health"
if [[ -n "${LAN_IP:-}" ]]; then
  echo "  LAN devices:   http://$LAN_IP:$PORT/health"
fi
if [[ "$HOST" == "0.0.0.0" ]]; then
  echo
echo "Note: relay is reachable from your local network while this script is running."
fi

echo
exec uvicorn main:app --host "$HOST" --port "$PORT"
