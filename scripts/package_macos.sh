#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/apps/flutter_client"
DIST_DIR="$ROOT_DIR/dist/macos"
APP_NAME="ReadAnywhere"
VERSION="${READ_ANYWHERE_VERSION:-0.1.0}"
BUILD_DEBUG_ARTIFACTS="${BUILD_DEBUG_ARTIFACTS:-false}"
DMG_NAME="ReadAnywhere-${VERSION}-macos-release.dmg"
PKG_NAME="ReadAnywhere-${VERSION}-macos-release.pkg"

export READ_ANYWHERE_PLATFORMS="macos"
"$ROOT_DIR/scripts/prepare_flutter_platforms.sh"

cd "$APP_DIR"

build_with_optional_define() {
  if [[ -n "${READANYWHERE_DEFAULT_RELAY_URL:-}" ]]; then
    flutter "$@" --dart-define="READANYWHERE_DEFAULT_RELAY_URL=${READANYWHERE_DEFAULT_RELAY_URL}"
  else
    flutter "$@"
  fi
}

echo "Building macOS release app..."
build_with_optional_define build macos --release

APP_PATH="$(find build/macos/Build/Products/Release -maxdepth 1 -name '*.app' -print -quit)"
if [[ -z "${APP_PATH:-}" || ! -d "$APP_PATH" ]]; then
  echo "Could not find built release .app bundle." >&2
  exit 1
fi

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

STAGE_ROOT="$(mktemp -d)"
trap 'rm -rf "$STAGE_ROOT"' EXIT
STAGED_APP="$STAGE_ROOT/$APP_NAME.app"
cp -R "$APP_PATH" "$STAGED_APP"

# Plain release .app zip, useful for quick testing.
ditto -c -k --keepParent "$STAGED_APP" "$DIST_DIR/ReadAnywhere-${VERSION}-macos-release-app.zip"

# Unsigned release PKG for local/internal testing. Public distribution should use Developer ID signing + notarization.
productbuild --component "$STAGED_APP" /Applications "$DIST_DIR/$PKG_NAME"

# Unsigned release DMG for local/internal testing.
DMG_ROOT="$STAGE_ROOT/dmg"
mkdir -p "$DMG_ROOT"
cp -R "$STAGED_APP" "$DMG_ROOT/$APP_NAME.app"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_ROOT" \
  -ov \
  -format UDZO \
  "$DIST_DIR/$DMG_NAME"

if [[ "$BUILD_DEBUG_ARTIFACTS" == "true" || "$BUILD_DEBUG_ARTIFACTS" == "1" ]]; then
  echo "Building optional macOS debug app zip..."
  build_with_optional_define build macos --debug
  DEBUG_APP_PATH="$(find build/macos/Build/Products/Debug -maxdepth 1 -name '*.app' -print -quit)"
  if [[ -n "${DEBUG_APP_PATH:-}" && -d "$DEBUG_APP_PATH" ]]; then
    DEBUG_STAGE="$STAGE_ROOT/${APP_NAME}-debug.app"
    cp -R "$DEBUG_APP_PATH" "$DEBUG_STAGE"
    ditto -c -k --keepParent "$DEBUG_STAGE" "$DIST_DIR/ReadAnywhere-${VERSION}-macos-debug-app.zip"
  fi
fi

(
  cd "$DIST_DIR"
  shasum -a 256 * > SHA256SUMS
)

echo "macOS artifacts:"
ls -lh "$DIST_DIR"
echo
echo "macOS artifact sizes:"
du -h "$DIST_DIR"/* | sort -h
