#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/apps/flutter_client"
DIST_DIR="$ROOT_DIR/dist/android"
VERSION="${READ_ANYWHERE_VERSION:-0.1.0}"

export READ_ANYWHERE_PLATFORMS="android"
"$ROOT_DIR/scripts/prepare_flutter_platforms.sh"

cd "$APP_DIR"
DART_DEFINES=()
if [[ -n "${READANYWHERE_DEFAULT_RELAY_URL:-}" ]]; then
  DART_DEFINES+=("--dart-define=READANYWHERE_DEFAULT_RELAY_URL=${READANYWHERE_DEFAULT_RELAY_URL}")
fi

flutter build apk --debug "${DART_DEFINES[@]}"

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
cp build/app/outputs/flutter-apk/app-debug.apk "$DIST_DIR/ReadAnywhere-${VERSION}-debug.apk"

# Release APK/AAB need a real keystore for distribution. If signing files are configured,
# uncomment these commands or run them manually:
# flutter build apk --release
# flutter build appbundle --release

ls -lh "$DIST_DIR"
