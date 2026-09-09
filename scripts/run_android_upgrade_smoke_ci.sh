#!/usr/bin/env bash
set -euo pipefail

mkdir -p test-results
mapfile -t old_apks < <(find previous-release -maxdepth 1 -type f -name '*-android-universal-release.apk')
mapfile -t new_apks < <(find dist/android -maxdepth 1 -type f -name '*-android-universal-release.apk')
if [[ ${#old_apks[@]} -ne 1 || ${#new_apks[@]} -ne 1 ]]; then
  echo "ERROR: expected exactly one old and one new universal APK; old=${#old_apks[@]} new=${#new_apks[@]}." >&2
  exit 1
fi

bash scripts/android_upgrade_smoke.sh \
  "${old_apks[0]}" \
  "${new_apks[0]}" \
  test-results/android-upgrade-smoke.txt
