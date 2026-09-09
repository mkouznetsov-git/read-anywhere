#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 MACOS_APP_ZIP [REPORT_FILE]" >&2
  exit 2
fi

APP_ZIP="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
REPORT_FILE="${2:-macos-package-upgrade-smoke.txt}"
BUNDLE_ID="com.readarc.readarc"
CONTAINER_ROOT="${HOME:?}/Library/Containers/$BUNDLE_ID"
LIBRARY_DIRECTORY="$CONTAINER_ROOT/Data/Documents/ReadArc"
MANIFEST_FILE="$LIBRARY_DIRECTORY/manifest.json"
TEMP_DIRECTORY="$(mktemp -d)"
APP_PID=""

if [[ ! -f "$APP_ZIP" ]]; then
  echo "ERROR: macOS app archive not found: $APP_ZIP" >&2
  exit 1
fi
case "$CONTAINER_ROOT" in
  */Library/Containers/com.readarc.readarc) ;;
  *) echo "ERROR: refusing unexpected container path: $CONTAINER_ROOT" >&2; exit 1 ;;
esac

cleanup() {
  if [[ -n "$APP_PID" ]]; then
    kill "$APP_PID" >/dev/null 2>&1 || true
    wait "$APP_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$TEMP_DIRECTORY"
}
trap cleanup EXIT

ditto -x -k "$APP_ZIP" "$TEMP_DIRECTORY"
APP_PATH="$(find "$TEMP_DIRECTORY" -maxdepth 1 -type d -name 'ReadArc.app' -print -quit)"
if [[ -z "$APP_PATH" ]]; then
  echo "ERROR: ReadArc.app is missing from $APP_ZIP" >&2
  exit 1
fi
codesign --verify --deep --strict "$APP_PATH"
EXECUTABLE="$APP_PATH/Contents/MacOS/ReadArc"
if [[ ! -x "$EXECUTABLE" ]]; then
  echo "ERROR: packaged ReadArc executable is missing." >&2
  exit 1
fi

clear_readarc_state() {
  rm -rf "$CONTAINER_ROOT"
  security delete-generic-password -s flutter_secure_storage_service -a readarc.accountEncryptionKey >/dev/null 2>&1 || true
  security delete-generic-password -s flutter_secure_storage_service -a readarc.deviceSigningPrivateKey >/dev/null 2>&1 || true
}

start_app() {
  local log_file="$1"
  "$EXECUTABLE" >"$log_file" 2>&1 &
  APP_PID="$!"
}

stop_app() {
  if [[ -n "$APP_PID" ]]; then
    kill "$APP_PID" >/dev/null 2>&1 || true
    wait "$APP_PID" >/dev/null 2>&1 || true
    APP_PID=""
  fi
}

wait_for_manifest() {
  local mode="$1"
  local log_file="$2"
  local attempt
  for attempt in {1..100}; do
    if [[ -f "$MANIFEST_FILE" ]] && python3 - "$MANIFEST_FILE" "$mode" <<'PY'
import json
import pathlib
import sys

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text())
mode = sys.argv[2]
assert manifest['schemaVersion'] == 3
assert 'accountEncryptionKey' not in manifest
assert 'deviceSigningPrivateKey' not in manifest
if mode == 'legacy':
    assert manifest['accountId'] == 'legacy-account'
    assert manifest['deviceId'] == 'legacy-device'
    assert manifest['deviceName'] == 'Legacy Mac'
    assert manifest['deviceSigningPublicKey'] == 'legacy-public'
    assert {item['deviceId'] for item in manifest['trustedDevices']} == {'legacy-device', 'paired-device'}
    assert len(manifest['books']) == 1
    book = manifest['books'][0]
    assert book['id'] == 'legacy-book'
    assert book['title'] == 'Preserved legacy book'
    assert book['progressPercent'] == 64
    assert book['currentLocator'] == 'paragraph:42'
    assert book['progressRevision']['counter'] == 7
    assert len(book['bookmarks']) == 1
    assert book['bookmarks'][0]['id'] == 'legacy-bookmark'
    assert book['bookmarks'][0]['note'] == 'Migration must retain this note'
PY
    then
      if ! kill -0 "$APP_PID" >/dev/null 2>&1; then
        echo "ERROR: packaged ReadArc exited during $mode launch." >&2
        cat "$log_file" >&2
        return 1
      fi
      if grep -q 'TimeoutException\|Не удалось загрузить библиотеку' "$log_file"; then
        echo "ERROR: packaged ReadArc logged a library startup failure during $mode launch." >&2
        cat "$log_file" >&2
        return 1
      fi
      return 0
    fi
    sleep 0.2
  done
  echo "ERROR: packaged ReadArc did not complete $mode library startup." >&2
  cat "$log_file" >&2
  return 1
}

clear_readarc_state
start_app "$TEMP_DIRECTORY/clean-launch.log"
wait_for_manifest clean "$TEMP_DIRECTORY/clean-launch.log"
stop_app

clear_readarc_state
mkdir -p "$LIBRARY_DIRECTORY/books"
printf '%s' 'preserved book payload' > "$LIBRARY_DIRECTORY/books/legacy.txt"
python3 - "$MANIFEST_FILE" "$LIBRARY_DIRECTORY/books/legacy.txt" <<'PY'
import json
import pathlib
import sys

manifest_path = pathlib.Path(sys.argv[1])
book_path = sys.argv[2]
manifest = {
    'accountId': 'legacy-account',
    'accountEncryptionKey': 'legacy-account-secret',
    'deviceId': 'legacy-device',
    'deviceName': 'Legacy Mac',
    'deviceSigningPublicKey': 'legacy-public',
    'deviceSigningPrivateKey': 'legacy-device-secret',
    'updatedAt': '2026-01-01T00:00:00.000Z',
    'trustedDevices': [
        {'deviceId': 'legacy-device', 'name': 'Legacy Mac', 'role': 'owner'},
        {'deviceId': 'paired-device', 'name': 'Paired phone', 'role': 'device'},
    ],
    'books': [{
        'id': 'legacy-book',
        'title': 'Preserved legacy book',
        'fileName': 'legacy.txt',
        'format': 'txt',
        'sizeBytes': 22,
        'contentSha256': 'legacy-sha256',
        'localPath': book_path,
        'addedAt': '2026-01-01T00:00:00.000Z',
        'updatedAt': '2026-01-02T00:00:00.000Z',
        'progressPercent': 64,
        'currentLocator': 'paragraph:42',
        'progressVersion': 7,
        'updatedByDeviceId': 'legacy-device',
        'availableOnDeviceIds': ['legacy-device'],
        'bookmarks': [{
            'id': 'legacy-bookmark',
            'bookId': 'legacy-book',
            'label': 'Preserved bookmark',
            'locator': 'paragraph:42',
            'note': 'Migration must retain this note',
            'createdAt': '2026-01-01T00:00:00.000Z',
            'updatedAt': '2026-01-01T00:00:00.000Z',
        }],
    }],
}
manifest_path.write_text(json.dumps(manifest))
PY
LEGACY_SOURCE_SHA256="$(shasum -a 256 "$MANIFEST_FILE" | awk '{print $1}')"
start_app "$TEMP_DIRECTORY/legacy-upgrade.log"
wait_for_manifest legacy "$TEMP_DIRECTORY/legacy-upgrade.log"
stop_app

if [[ "$(cat "$LIBRARY_DIRECTORY/books/legacy.txt")" != 'preserved book payload' ]]; then
  echo "ERROR: packaged macOS upgrade did not preserve the book file." >&2
  exit 1
fi
BACKUP_COUNT="$(find "$LIBRARY_DIRECTORY/manifest_backups" -type f -name 'manifest_*.json' 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$BACKUP_COUNT" == "0" ]]; then
  echo "ERROR: packaged macOS upgrade did not retain a verified manifest backup." >&2
  exit 1
fi

mkdir -p "$(dirname "$REPORT_FILE")"
{
  echo "MACOS_PACKAGE_UPGRADE_SMOKE_OK"
  echo "bundleId=$BUNDLE_ID"
  echo "cleanLaunch=true"
  echo "legacySchemaV1ToV2ToV3=true"
  echo "booksProgressBookmarksPairingPreserved=true"
  echo "bookFilePreserved=true"
  echo "legacySourceSha256=$LEGACY_SOURCE_SHA256"
  echo "verifiedBackupCount=$BACKUP_COUNT"
  echo "startupTimeout=false"
} | tee "$REPORT_FILE"
