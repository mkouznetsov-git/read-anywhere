#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/apps/flutter_client"

cd "$APP_DIR"
flutter --version
flutter pub get
flutter test

# Relay smoke check: syntax must stay valid for CI packages.
if command -v python3 >/dev/null 2>&1; then
  cd "$ROOT_DIR"
  python3 -m py_compile server/rendezvous_relay/main.py
fi
