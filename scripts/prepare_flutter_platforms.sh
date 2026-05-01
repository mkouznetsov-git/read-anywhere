#!/usr/bin/env bash
set -euo pipefail

# Generates missing Flutter platform folders for this starter project.
# Safe to run repeatedly. It does not replace lib/, test/ or pubspec.yaml.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/apps/flutter_client"
ORG="${READ_ANYWHERE_ORG:-com.readanywhere}"
PLATFORMS="${READ_ANYWHERE_PLATFORMS:-android,macos}"

cd "$APP_DIR"

echo "Preparing Flutter platforms: $PLATFORMS"
flutter --version
flutter create --project-name read_anywhere --org "$ORG" --platforms "$PLATFORMS" .
flutter pub get

# Android needs explicit Internet permission for WebSocket sync.
ANDROID_MANIFEST="android/app/src/main/AndroidManifest.xml"
if [[ -f "$ANDROID_MANIFEST" ]] && ! grep -q "android.permission.INTERNET" "$ANDROID_MANIFEST"; then
  perl -0pi -e 's#<manifest([^>]*)>#<manifest$1>\n    <uses-permission android:name="android.permission.INTERNET" />#' "$ANDROID_MANIFEST"
fi


# Friendly Android launcher name.
if [[ -f "$ANDROID_MANIFEST" ]]; then
  perl -0pi -e 's#android:label="[^"]*"#android:label="ReadAnywhere"#' "$ANDROID_MANIFEST"
fi

# Debug MVP may use ws:// or http:// relay. Production should use HTTPS/WSS and remove cleartext.
if [[ -f "$ANDROID_MANIFEST" ]] && ! grep -q "usesCleartextTraffic" "$ANDROID_MANIFEST"; then
  perl -0pi -e 's#<application#<application android:usesCleartextTraffic="true"#' "$ANDROID_MANIFEST"
fi

# Friendly macOS app name.
if [[ -f macos/Runner/Info.plist && -x /usr/libexec/PlistBuddy ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleName ReadAnywhere" macos/Runner/Info.plist || true
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ReadAnywhere" macos/Runner/Info.plist || true
fi


# Friendly macOS product name for generated .app bundles.
MACOS_APPINFO="macos/Runner/Configs/AppInfo.xcconfig"
if [[ -f "$MACOS_APPINFO" ]]; then
  perl -0pi -e 's#PRODUCT_NAME = .*#PRODUCT_NAME = ReadAnywhere#' "$MACOS_APPINFO"
fi

# File picker / local file access and outgoing network entitlement for macOS sandbox builds.
for entitlements in macos/Runner/DebugProfile.entitlements macos/Runner/Release.entitlements; do
  if [[ -f "$entitlements" && -x /usr/libexec/PlistBuddy ]]; then
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.files.user-selected.read-only bool true" "$entitlements" 2>/dev/null || \
      /usr/libexec/PlistBuddy -c "Set :com.apple.security.files.user-selected.read-only true" "$entitlements" || true
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.files.user-selected.read-write bool true" "$entitlements" 2>/dev/null || \
      /usr/libexec/PlistBuddy -c "Set :com.apple.security.files.user-selected.read-write true" "$entitlements" || true
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.network.client bool true" "$entitlements" 2>/dev/null || \
      /usr/libexec/PlistBuddy -c "Set :com.apple.security.network.client true" "$entitlements" || true
  fi
done

echo "Flutter platform preparation complete."
