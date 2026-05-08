#!/usr/bin/env bash
set -euo pipefail

# Generates missing Flutter platform folders for this starter project.
# Safe to run repeatedly. It does not replace lib/, test/ or pubspec.yaml.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/apps/flutter_client"
ORG="${READARC_ORG:-com.readarc}"
PLATFORMS="${READARC_PLATFORMS:-${READ_ANYWHERE_PLATFORMS:-android,macos}}"

cd "$APP_DIR"

echo "Preparing Flutter platforms: $PLATFORMS"
flutter --version
flutter create --project-name readarc --org "$ORG" --platforms "$PLATFORMS" .
flutter pub get

# Android needs explicit Internet permission for WebSocket sync and camera permission for QR pairing scan.
ANDROID_MANIFEST="android/app/src/main/AndroidManifest.xml"
if [[ -f "$ANDROID_MANIFEST" ]] && ! grep -q "android.permission.INTERNET" "$ANDROID_MANIFEST"; then
  perl -0pi -e 's#<manifest([^>]*)>#<manifest$1>\n    <uses-permission android:name="android.permission.INTERNET" />#' "$ANDROID_MANIFEST"
fi
if [[ -f "$ANDROID_MANIFEST" ]] && ! grep -q "android.permission.CAMERA" "$ANDROID_MANIFEST"; then
  perl -0pi -e 's#<manifest([^>]*)>#<manifest$1>\n    <uses-permission android:name="android.permission.CAMERA" />#' "$ANDROID_MANIFEST"
fi


# Friendly Android launcher name.
if [[ -f "$ANDROID_MANIFEST" ]]; then
  perl -0pi -e 's#android:label="[^"]*"#android:label="ReadArc"#' "$ANDROID_MANIFEST"
fi

# Debug MVP may use ws:// or http:// relay. Production should use HTTPS/WSS and remove cleartext.
if [[ -f "$ANDROID_MANIFEST" ]] && ! grep -q "usesCleartextTraffic" "$ANDROID_MANIFEST"; then
  perl -0pi -e 's#<application#<application android:usesCleartextTraffic="true"#' "$ANDROID_MANIFEST"
fi

# Friendly macOS app name.
if [[ -f macos/Runner/Info.plist && -x /usr/libexec/PlistBuddy ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleName ReadArc" macos/Runner/Info.plist 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :CFBundleName string ReadArc" macos/Runner/Info.plist || true
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ReadArc" macos/Runner/Info.plist 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string ReadArc" macos/Runner/Info.plist || true
fi


# Friendly macOS product name for generated .app bundles.
MACOS_APPINFO="macos/Runner/Configs/AppInfo.xcconfig"
if [[ -f "$MACOS_APPINFO" ]]; then
  perl -0pi -e 's#PRODUCT_NAME = .*#PRODUCT_NAME = ReadArc#' "$MACOS_APPINFO"
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
    # Personal Hub direct file endpoint accepts incoming HTTP connections on LAN/Tailscale.
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.network.server bool true" "$entitlements" 2>/dev/null || \
      /usr/libexec/PlistBuddy -c "Set :com.apple.security.network.server true" "$entitlements" || true
  fi
done


# iOS camera usage string for future QR pairing builds.
IOS_PLIST="ios/Runner/Info.plist"
if [[ -f "$IOS_PLIST" && -x /usr/libexec/PlistBuddy ]]; then
  /usr/libexec/PlistBuddy -c "Add :NSCameraUsageDescription string ReadArc uses the camera to scan pairing QR codes." "$IOS_PLIST" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :NSCameraUsageDescription ReadArc uses the camera to scan pairing QR codes." "$IOS_PLIST" || true
fi



# ReadArc custom app icon. flutter create regenerates platform folders, so copy
# the committed icon set after platform generation.
ICON_ROOT="$ROOT_DIR/assets/app_icon"
if [[ -d "$ICON_ROOT/android" ]]; then
  for density in mdpi hdpi xhdpi xxhdpi xxxhdpi; do
    src="$ICON_ROOT/android/ic_launcher_${density}.png"
    dst="android/app/src/main/res/mipmap-${density}/ic_launcher.png"
    if [[ -f "$src" && -d "$(dirname "$dst")" ]]; then
      cp "$src" "$dst"
    fi
  done
fi

if [[ -d "$ICON_ROOT/macos" ]]; then
  MACOS_ICON_SET="macos/Runner/Assets.xcassets/AppIcon.appiconset"
  if [[ -d "$MACOS_ICON_SET" ]]; then
    for size in 16 32 64 128 256 512 1024; do
      src="$ICON_ROOT/macos/app_icon_${size}.png"
      dst="$MACOS_ICON_SET/app_icon_${size}.png"
      if [[ -f "$src" ]]; then
        cp "$src" "$dst"
      fi
    done
  fi
fi

echo "Flutter platform preparation complete."
