#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/apps/flutter_client"
RESULTS_DIR="$ROOT_DIR/test-results"
mkdir -p "$RESULTS_DIR"

cd "$ROOT_DIR"

echo "== ReadArc quality gate =="
echo "Repository: $ROOT_DIR"

echo "-- Shell syntax"
while IFS= read -r script; do
  bash -n "$script"
done < <(find scripts -maxdepth 1 -type f -name '*.sh' -print | sort)

echo "-- Relay syntax"
python3 -m py_compile server/rendezvous_relay/main.py

echo "-- Legacy naming guard"
ACTIVE_PATHS=(
  apps/flutter_client/lib
  apps/flutter_client/pubspec.yaml
  scripts/prepare_flutter_platforms.sh
  scripts/package_android.sh
  scripts/package_macos.sh
  scripts/build_native_engines.sh
  server
)
if grep -RInE 'ReadAnywhere|Read Anywhere|readanywhere|read-anywhere|read_anywhere|READANYWHERE' \
  "${ACTIVE_PATHS[@]}" --exclude-dir=.dart_tool; then
  echo "ERROR: legacy product naming is forbidden in active ReadArc code." >&2
  exit 1
fi

echo "-- Flutter dependencies"
cd "$APP_DIR"
flutter --version
flutter pub get

echo "-- Flutter analyzer"
set -o pipefail
flutter analyze --no-fatal-warnings --no-fatal-infos 2>&1 | tee "$RESULTS_DIR/flutter-analyze.log"

echo "-- Flutter unit/widget/regression tests"
flutter test --reporter expanded 2>&1 | tee "$RESULTS_DIR/flutter-test.log"

echo "QUALITY_GATE_OK"
