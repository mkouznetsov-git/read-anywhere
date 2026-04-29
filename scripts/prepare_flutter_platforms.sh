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

# Friendly macOS app name.
if [[ -f macos/Runner/Info.plist ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleName Read anywhere" macos/Runner/Info.plist || true
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Read anywhere" macos/Runner/Info.plist || true
fi

# File picker / local file access entitlements for macOS sandbox builds.
for entitlements in macos/Runner/DebugProfile.entitlements macos/Runner/Release.entitlements; do
  if [[ -f "$entitlements" ]]; then
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.files.user-selected.read-only bool true" "$entitlements" 2>/dev/null || \
      /usr/libexec/PlistBuddy -c "Set :com.apple.security.files.user-selected.read-only true" "$entitlements" || true
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.files.user-selected.read-write bool true" "$entitlements" 2>/dev/null || \
      /usr/libexec/PlistBuddy -c "Set :com.apple.security.files.user-selected.read-write true" "$entitlements" || true
  fi
done

echo "Flutter platform preparation complete."
