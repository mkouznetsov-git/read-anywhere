#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/apps/flutter_client"
DIST_DIR="$ROOT_DIR/dist/android"
VERSION="${READ_ANYWHERE_VERSION:-0.1.0}"
BUILD_DEBUG_ARTIFACTS="${BUILD_DEBUG_ARTIFACTS:-false}"

export READ_ANYWHERE_PLATFORMS="android"
"$ROOT_DIR/scripts/prepare_flutter_platforms.sh"

cd "$APP_DIR"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

build_with_optional_define() {
  if [[ -n "${READANYWHERE_DEFAULT_RELAY_URL:-}" ]]; then
    flutter "$@" --dart-define="READANYWHERE_DEFAULT_RELAY_URL=${READANYWHERE_DEFAULT_RELAY_URL}"
  else
    flutter "$@"
  fi
}

echo "Building Android release APKs split per ABI..."
build_with_optional_define build apk --release --split-per-abi

for apk in build/app/outputs/flutter-apk/*-release.apk; do
  [[ -f "$apk" ]] || continue
  base="$(basename "$apk")"
  case "$base" in
    app-arm64-v8a-release.apk)
      cp "$apk" "$DIST_DIR/ReadAnywhere-${VERSION}-android-arm64-v8a-release.apk"
      ;;
    app-armeabi-v7a-release.apk)
      cp "$apk" "$DIST_DIR/ReadAnywhere-${VERSION}-android-armeabi-v7a-release.apk"
      ;;
    app-x86_64-release.apk)
      cp "$apk" "$DIST_DIR/ReadAnywhere-${VERSION}-android-x86_64-release.apk"
      ;;
    *)
      cp "$apk" "$DIST_DIR/ReadAnywhere-${VERSION}-${base}"
      ;;
  esac
done

echo "Building Android release App Bundle..."
build_with_optional_define build appbundle --release
if [[ -f build/app/outputs/bundle/release/app-release.aab ]]; then
  cp build/app/outputs/bundle/release/app-release.aab "$DIST_DIR/ReadAnywhere-${VERSION}-android-release.aab"
fi

if [[ "$BUILD_DEBUG_ARTIFACTS" == "true" || "$BUILD_DEBUG_ARTIFACTS" == "1" ]]; then
  echo "Building optional Android debug APK..."
  build_with_optional_define build apk --debug
  cp build/app/outputs/flutter-apk/app-debug.apk "$DIST_DIR/ReadAnywhere-${VERSION}-android-debug.apk"
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
