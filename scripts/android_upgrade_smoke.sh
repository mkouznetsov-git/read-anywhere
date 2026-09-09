#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 OLD_APK NEW_APK [REPORT_FILE]" >&2
  exit 2
fi

OLD_APK="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
NEW_APK="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
REPORT_FILE="${3:-android-upgrade-smoke.txt}"
PACKAGE_ID="com.readarc.readarc"
SENTINEL="readarc-upgrade-data-preserved"

for apk in "$OLD_APK" "$NEW_APK"; do
  if [[ ! -f "$apk" ]]; then
    echo "ERROR: APK not found: $apk" >&2
    exit 1
  fi
done

find_android_tool() {
  local tool="$1"
  local sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
  [[ -n "$sdk_root" && -d "$sdk_root" ]] || return 1
  find "$sdk_root" -type f -name "$tool" -perm -u+x 2>/dev/null | sort -V | tail -n 1
}

APKSIGNER="$(find_android_tool apksigner || true)"
AAPT="$(find_android_tool aapt || true)"
if [[ -z "$APKSIGNER" || -z "$AAPT" ]]; then
  echo "ERROR: apksigner and aapt are required for the Android upgrade smoke test." >&2
  exit 1
fi
if ! command -v adb >/dev/null 2>&1; then
  echo "ERROR: adb is required for the Android upgrade smoke test." >&2
  exit 1
fi

apk_package() {
  "$AAPT" dump badging "$1" | sed -n "s/^package: name='\([^']*\)'.*/\1/p" | head -n 1
}

apk_version_code() {
  "$AAPT" dump badging "$1" | sed -n "s/^package: .* versionCode='\([^']*\)'.*/\1/p" | head -n 1
}

apk_fingerprint() {
  "$APKSIGNER" verify --print-certs "$1" |
    sed -n 's/^Signer #1 certificate SHA-256 digest: //p' |
    head -n 1
}

ORIGINAL_OLD_FINGERPRINT="$(apk_fingerprint "$OLD_APK")"
ORIGINAL_NEW_FINGERPRINT="$(apk_fingerprint "$NEW_APK")"
MAX_OLD_VERSION_CODE=0
OLD_RELEASE_COUNT=0
for old_release_apk in "$(dirname "$OLD_APK")"/*-android-*-release.apk; do
  [[ -f "$old_release_apk" ]] || continue
  old_release_package="$(apk_package "$old_release_apk")"
  old_release_version="$(apk_version_code "$old_release_apk")"
  old_release_fingerprint="$(apk_fingerprint "$old_release_apk")"
  if [[ "$old_release_package" != "$PACKAGE_ID" ]]; then
    echo "ERROR: previous release applicationId changed in $(basename "$old_release_apk"): $old_release_package" >&2
    exit 1
  fi
  if [[ ! "$old_release_version" =~ ^[0-9]+$ ]]; then
    echo "ERROR: previous release has a non-numeric versionCode: $(basename "$old_release_apk")" >&2
    exit 1
  fi
  if [[ "$old_release_fingerprint" != "$ORIGINAL_OLD_FINGERPRINT" ]]; then
    echo "ERROR: previous release APK certificates are inconsistent." >&2
    exit 1
  fi
  if (( old_release_version > MAX_OLD_VERSION_CODE )); then
    MAX_OLD_VERSION_CODE="$old_release_version"
  fi
  OLD_RELEASE_COUNT=$((OLD_RELEASE_COUNT + 1))
done
if (( OLD_RELEASE_COUNT < 4 )); then
  echo "ERROR: expected universal and three ABI APKs from the previous release; found $OLD_RELEASE_COUNT." >&2
  exit 1
fi
TEST_OLD_APK="$OLD_APK"
TEST_NEW_APK="$NEW_APK"
TEMP_DIRECTORY="$(mktemp -d)"

cleanup() {
  adb shell am force-stop "$PACKAGE_ID" >/dev/null 2>&1 || true
  adb uninstall "$PACKAGE_ID" >/dev/null 2>&1 || true
  if [[ -d "$TEMP_DIRECTORY" ]]; then
    rm -rf "$TEMP_DIRECTORY"
  fi
}
trap cleanup EXIT

# Pull-request jobs cannot receive the production signing key safely. They
# re-sign copies of the already-verified old/new APKs with one ephemeral key so
# the exact package contents, version ordering and adb upgrade semantics are
# still exercised. Main uses the untouched production-signed APKs.
if [[ "${READARC_RESIGN_UPGRADE_FIXTURES:-false}" == "true" ]]; then
  keytool -genkeypair \
    -keystore "$TEMP_DIRECTORY/upgrade-smoke.jks" \
    -storepass readarc-ci-only \
    -keypass readarc-ci-only \
    -alias readarc-ci \
    -keyalg RSA \
    -keysize 2048 \
    -validity 2 \
    -dname 'CN=ReadArc CI upgrade smoke' >/dev/null 2>&1
  "$APKSIGNER" sign \
    --ks "$TEMP_DIRECTORY/upgrade-smoke.jks" \
    --ks-key-alias readarc-ci \
    --ks-pass pass:readarc-ci-only \
    --key-pass pass:readarc-ci-only \
    --out "$TEMP_DIRECTORY/old.apk" \
    "$OLD_APK"
  "$APKSIGNER" sign \
    --ks "$TEMP_DIRECTORY/upgrade-smoke.jks" \
    --ks-key-alias readarc-ci \
    --ks-pass pass:readarc-ci-only \
    --key-pass pass:readarc-ci-only \
    --out "$TEMP_DIRECTORY/new.apk" \
    "$NEW_APK"
  TEST_OLD_APK="$TEMP_DIRECTORY/old.apk"
  TEST_NEW_APK="$TEMP_DIRECTORY/new.apk"
fi

for apk in "$TEST_OLD_APK" "$TEST_NEW_APK"; do
  "$APKSIGNER" verify --verbose --print-certs "$apk" >/dev/null
done

OLD_PACKAGE="$(apk_package "$TEST_OLD_APK")"
NEW_PACKAGE="$(apk_package "$TEST_NEW_APK")"
OLD_VERSION_CODE="$(apk_version_code "$TEST_OLD_APK")"
NEW_VERSION_CODE="$(apk_version_code "$TEST_NEW_APK")"
OLD_FINGERPRINT="$(apk_fingerprint "$TEST_OLD_APK")"
NEW_FINGERPRINT="$(apk_fingerprint "$TEST_NEW_APK")"

if [[ "$OLD_PACKAGE" != "$PACKAGE_ID" || "$NEW_PACKAGE" != "$PACKAGE_ID" ]]; then
  echo "ERROR: applicationId changed: old=$OLD_PACKAGE new=$NEW_PACKAGE" >&2
  exit 1
fi
if [[ ! "$OLD_VERSION_CODE" =~ ^[0-9]+$ || ! "$NEW_VERSION_CODE" =~ ^[0-9]+$ ]]; then
  echo "ERROR: non-numeric APK versionCode: old=$OLD_VERSION_CODE new=$NEW_VERSION_CODE" >&2
  exit 1
fi
if (( NEW_VERSION_CODE <= OLD_VERSION_CODE )); then
  echo "ERROR: versionCode is not monotonic: old=$OLD_VERSION_CODE new=$NEW_VERSION_CODE" >&2
  exit 1
fi
if (( NEW_VERSION_CODE <= MAX_OLD_VERSION_CODE )); then
  echo "ERROR: new universal versionCode=$NEW_VERSION_CODE is not above every previous split APK; max=$MAX_OLD_VERSION_CODE" >&2
  exit 1
fi
if [[ -z "$OLD_FINGERPRINT" || "$OLD_FINGERPRINT" != "$NEW_FINGERPRINT" ]]; then
  echo "ERROR: signing certificate mismatch: old=$OLD_FINGERPRINT new=$NEW_FINGERPRINT" >&2
  exit 1
fi

adb wait-for-device
adb install -r "$TEST_OLD_APK"
adb shell am start -W -n "$PACKAGE_ID/.MainActivity" | tee /tmp/readarc-old-launch.txt
grep -q 'Status: ok' /tmp/readarc-old-launch.txt
for attempt in {1..100}; do
  if adb shell "run-as $PACKAGE_ID test -s app_flutter/ReadArc/manifest.json"; then
    break
  fi
  sleep 0.2
done
adb exec-out run-as "$PACKAGE_ID" cat app_flutter/ReadArc/manifest.json > "$TEMP_DIRECTORY/old-manifest.json"
python3 - "$TEMP_DIRECTORY/old-manifest.json" <<'PY'
import json
import pathlib
import sys

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert manifest['accountId']
assert manifest['deviceId']
assert isinstance(manifest['books'], list)
assert isinstance(manifest['trustedDevices'], list)
PY
adb shell am force-stop "$PACKAGE_ID"
adb shell "run-as $PACKAGE_ID sh -c 'mkdir -p files && printf %s $SENTINEL > files/upgrade-sentinel'"
if [[ "$(adb shell "run-as $PACKAGE_ID cat files/upgrade-sentinel" | tr -d '\r')" != "$SENTINEL" ]]; then
  echo "ERROR: could not create application-data sentinel before upgrade." >&2
  exit 1
fi

adb install -r "$TEST_NEW_APK" | tee /tmp/readarc-adb-upgrade.txt
grep -q '^Success$' /tmp/readarc-adb-upgrade.txt
if [[ "$(adb shell "run-as $PACKAGE_ID cat files/upgrade-sentinel" | tr -d '\r')" != "$SENTINEL" ]]; then
  echo "ERROR: application data was lost during adb install -r." >&2
  exit 1
fi
adb shell am start -W -n "$PACKAGE_ID/.MainActivity" | tee /tmp/readarc-new-launch.txt
grep -q 'Status: ok' /tmp/readarc-new-launch.txt
for attempt in {1..75}; do
  adb shell uiautomator dump /sdcard/readarc-window.xml >/dev/null 2>&1 || true
  adb exec-out cat /sdcard/readarc-window.xml > "$TEMP_DIRECTORY/window.xml" 2>/dev/null || true
  if grep -q 'Не удалось загрузить библиотеку' "$TEMP_DIRECTORY/window.xml"; then
    echo "ERROR: ReadArc displayed a library load error after package upgrade." >&2
    exit 1
  fi
  if grep -q 'Библиотека пока пуста' "$TEMP_DIRECTORY/window.xml"; then
    break
  fi
  sleep 0.2
done
if ! grep -q 'Библиотека пока пуста' "$TEMP_DIRECTORY/window.xml"; then
  echo "ERROR: ReadArc did not finish loading its preserved library after package upgrade." >&2
  exit 1
fi
for attempt in {1..100}; do
  if adb shell "run-as $PACKAGE_ID test -s app_flutter/ReadArc/manifest.json"; then
    break
  fi
  sleep 0.2
done
adb exec-out run-as "$PACKAGE_ID" cat app_flutter/ReadArc/manifest.json > "$TEMP_DIRECTORY/new-manifest.json"
python3 - "$TEMP_DIRECTORY/old-manifest.json" "$TEMP_DIRECTORY/new-manifest.json" <<'PY'
import json
import pathlib
import sys

old = json.loads(pathlib.Path(sys.argv[1]).read_text())
new = json.loads(pathlib.Path(sys.argv[2]).read_text())
assert new['accountId'] == old['accountId']
assert new['deviceId'] == old['deviceId']
assert {book['id'] for book in new['books']} == {book['id'] for book in old['books']}
assert {device['deviceId'] for device in new['trustedDevices']} == {
    device['deviceId'] for device in old['trustedDevices']
}
PY

mkdir -p "$(dirname "$REPORT_FILE")"
{
  echo "ANDROID_UPGRADE_SMOKE_OK"
  echo "package=$PACKAGE_ID"
  echo "oldVersionCode=$OLD_VERSION_CODE"
  echo "maxPreviousReleaseVersionCode=$MAX_OLD_VERSION_CODE"
  echo "newVersionCode=$NEW_VERSION_CODE"
  echo "originalOldCertificateSha256=$ORIGINAL_OLD_FINGERPRINT"
  echo "originalNewCertificateSha256=$ORIGINAL_NEW_FINGERPRINT"
  echo "testedCertificateSha256=$NEW_FINGERPRINT"
  echo "resignedFixtures=${READARC_RESIGN_UPGRADE_FIXTURES:-false}"
  echo "dataPreserved=true"
  echo "accountAndDeviceIdentityPreserved=true"
  echo "launchAfterUpgrade=true"
} | tee "$REPORT_FILE"
