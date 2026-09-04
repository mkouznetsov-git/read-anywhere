#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/apps/flutter_client"

cd "$APP_DIR"
flutter --version
flutter pub get --enforce-lockfile
flutter test

# Relay smoke check: syntax must stay valid for CI packages.
if command -v python3 >/dev/null 2>&1; then
  cd "$ROOT_DIR"
  python3 -c 'from pathlib import Path; p = Path("server/rendezvous_relay/main.py"); compile(p.read_text(), str(p), "exec")'
fi


# Optional relay container smoke check for CI/local machines with Docker.
if command -v docker >/dev/null 2>&1; then
  cd "$ROOT_DIR"
  docker build -t readarc-relay:test server/rendezvous_relay
fi
