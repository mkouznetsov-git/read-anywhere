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
python3 -m py_compile server/rendezvous_relay/main.py server/rendezvous_relay/relay_store.py

echo "-- Relay unit and real two-client integration tests"
PYTHONPATH="$ROOT_DIR/server/rendezvous_relay" \
  python3 -m unittest discover -s server/rendezvous_relay/tests -v 2>&1 | tee "$RESULTS_DIR/relay-test.log"

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
flutter pub get --enforce-lockfile

echo "-- Committed platform projects"
READARC_PLATFORMS=android,macos,ios bash "$ROOT_DIR/scripts/prepare_flutter_platforms.sh"

echo "-- Flutter analyzer"
set -o pipefail
dart format --output=none --set-exit-if-changed lib test integration_test 2>&1 | tee "$RESULTS_DIR/dart-format.log"
flutter analyze --fatal-warnings --fatal-infos 2>&1 | tee "$RESULTS_DIR/flutter-analyze.log"

echo "-- Flutter unit/widget/regression tests"
flutter test --reporter expanded 2>&1 | tee "$RESULTS_DIR/flutter-test.log"

echo "QUALITY_GATE_OK"
