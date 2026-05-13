#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/apps/flutter_client"
DIST_DIR="$ROOT_DIR/dist/android"
BASE_VERSION="${READARC_BASE_VERSION:-${READ_ANYWHERE_BASE_VERSION:-0.1.0}}"
BUILD_NUMBER="${READARC_BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-}}"
if [[ -z "$BUILD_NUMBER" ]]; then
  BUILD_NUMBER="$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || echo 23)"
fi
if [[ "${GITHUB_REF_NAME:-}" == v* ]]; then
  BUILD_NAME="${READARC_BUILD_NAME:-${GITHUB_REF_NAME#v}}"
  VERSION="${READARC_VERSION:-$BUILD_NAME}"
else
  BUILD_NAME="${READARC_BUILD_NAME:-$BASE_VERSION}"
  VERSION="${READARC_VERSION:-$BASE_VERSION-snapshot.$BUILD_NUMBER}"
fi
BUILD_DEBUG_ARTIFACTS="${BUILD_DEBUG_ARTIFACTS:-false}"

export READARC_PLATFORMS="android"
"$ROOT_DIR/scripts/prepare_flutter_platforms.sh"

cd "$APP_DIR"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

build_with_optional_define() {
  local relay_define="${READARC_DEFAULT_RELAY_URL:-${READANYWHERE_DEFAULT_RELAY_URL:-https://relay.readarc.ru}}"
  local args=("$@")
  if [[ -n "$relay_define" ]]; then
    args+=(--dart-define="READARC_DEFAULT_RELAY_URL=$relay_define")
    args+=(--dart-define="READANYWHERE_DEFAULT_RELAY_URL=$relay_define")
  fi
  flutter "${args[@]}"
}

echo "Building Android universal release APK for simple sideload installation..."
build_with_optional_define build apk --release --build-name "$BUILD_NAME" --build-number "$BUILD_NUMBER"
if [[ -f build/app/outputs/flutter-apk/app-release.apk ]]; then
  cp build/app/outputs/flutter-apk/app-release.apk "$DIST_DIR/ReadArc-${VERSION}-android-universal-release.apk"
fi

echo "Building Android release APKs split per ABI..."
build_with_optional_define build apk --release --build-name "$BUILD_NAME" --build-number "$BUILD_NUMBER" --split-per-abi

for apk in build/app/outputs/flutter-apk/*-release.apk; do
  [[ -f "$apk" ]] || continue
  base="$(basename "$apk")"
  case "$base" in
    app-arm64-v8a-release.apk)
      cp "$apk" "$DIST_DIR/ReadArc-${VERSION}-android-arm64-v8a-release.apk"
      ;;
    app-armeabi-v7a-release.apk)
      cp "$apk" "$DIST_DIR/ReadArc-${VERSION}-android-armeabi-v7a-release.apk"
      ;;
    app-x86_64-release.apk)
      cp "$apk" "$DIST_DIR/ReadArc-${VERSION}-android-x86_64-release.apk"
      ;;
    *)
      cp "$apk" "$DIST_DIR/ReadArc-${VERSION}-${base}"
      ;;
  esac
done

echo "Building Android release App Bundle..."
build_with_optional_define build appbundle --release --build-name "$BUILD_NAME" --build-number "$BUILD_NUMBER"
if [[ -f build/app/outputs/bundle/release/app-release.aab ]]; then
  cp build/app/outputs/bundle/release/app-release.aab "$DIST_DIR/ReadArc-${VERSION}-android-release.aab"
fi

if [[ "$BUILD_DEBUG_ARTIFACTS" == "true" || "$BUILD_DEBUG_ARTIFACTS" == "1" ]]; then
  echo "Building optional Android debug APK..."
  build_with_optional_define build apk --debug --build-name "$BUILD_NAME" --build-number "$BUILD_NUMBER"
  cp build/app/outputs/flutter-apk/app-debug.apk "$DIST_DIR/ReadArc-${VERSION}-android-debug.apk"
fi

(
  cd "$DIST_DIR"
  shasum -a 256 * > SHA256SUMS
)

echo "Android artifacts:"
ls -lh "$DIST_DIR"
echo
echo "Android artifact sizes:"
du -h "$DIST_DIR"/* | sort -h
