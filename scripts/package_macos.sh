#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/apps/flutter_client"
DIST_DIR="$ROOT_DIR/dist/macos"
APP_NAME="ReadAnywhere"
VERSION="${READ_ANYWHERE_VERSION:-0.1.0}"
DMG_NAME="ReadAnywhere-${VERSION}-macos.dmg"
PKG_NAME="ReadAnywhere-${VERSION}-macos.pkg"

"$ROOT_DIR/scripts/prepare_flutter_platforms.sh"

cd "$APP_DIR"
flutter build macos --release

APP_PATH="$(find build/macos/Build/Products/Release -maxdepth 1 -name '*.app' -print -quit)"
if [[ -z "${APP_PATH:-}" || ! -d "$APP_PATH" ]]; then
  echo "Could not find built .app bundle." >&2
  exit 1
fi

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

STAGE_ROOT="$(mktemp -d)"
trap 'rm -rf "$STAGE_ROOT"' EXIT
STAGED_APP="$STAGE_ROOT/$APP_NAME.app"
cp -R "$APP_PATH" "$STAGED_APP"

# Plain .app zip, useful for quick testing.
ditto -c -k --keepParent "$STAGED_APP" "$DIST_DIR/ReadAnywhere-${VERSION}-macos-app.zip"

# Unsigned PKG for local/internal testing. Public distribution should use Developer ID signing + notarization.
productbuild --component "$STAGED_APP" /Applications "$DIST_DIR/$PKG_NAME"

# Unsigned DMG for local/internal testing.
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

ls -lh "$DIST_DIR"
