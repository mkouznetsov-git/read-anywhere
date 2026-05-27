#!/usr/bin/env bash
set -euo pipefail

# Generates missing Flutter platform folders for this starter project.
# Safe to run repeatedly. It does not replace lib/, test/ or pubspec.yaml.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/apps/flutter_client"
ORG="${READARC_ORG:-com.readarc}"
PLATFORMS="${READARC_PLATFORMS:-android,macos}"

cd "$APP_DIR"

echo "Preparing Flutter platforms: $PLATFORMS"
flutter --version
flutter create --project-name readarc --org "$ORG" --platforms "$PLATFORMS" .

# Flutter 3.44 / Android Gradle Plugin dependency metadata now requires Android API 36
# for transitive AndroidX lifecycle artifacts used by picker plugins. The generated
# platform folder is recreated on CI, so normalize compileSdk immediately after
# flutter create and make the SDK platform available when sdkmanager exists.
if [[ "$PLATFORMS" == *android* ]]; then
  SDKMANAGER=""
  if [[ -n "${ANDROID_HOME:-}" && -x "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" ]]; then
    SDKMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
  elif [[ -n "${ANDROID_SDK_ROOT:-}" && -x "$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager" ]]; then
    SDKMANAGER="$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager"
  fi
  if [[ -n "$SDKMANAGER" ]]; then
    yes | "$SDKMANAGER" "platforms;android-36" >/dev/null || true
  fi

  ANDROID_APP_GRADLE_KTS="android/app/build.gradle.kts"
  if [[ -f "$ANDROID_APP_GRADLE_KTS" ]]; then
    python3 - <<'PY_ANDROID_COMPILE_SDK'
from pathlib import Path
p = Path('android/app/build.gradle.kts')
text = p.read_text()
text = text.replace('compileSdk = flutter.compileSdkVersion', 'compileSdk = 36')
p.write_text(text)
PY_ANDROID_COMPILE_SDK
  fi
fi

flutter pub get

# Flutter/Android plugins can pin their own compileSdk in Gradle files.
# Flutter 3.44 currently resolves flutter_plugin_android_lifecycle that requires
# Android API 36. Patching only android/app/build.gradle.kts is not enough:
# Gradle still checks plugin modules such as file_picker against their own
# compileSdk. Normalize Android plugin Gradle files from package_config after
# pub get, while keeping targetSdk/minSdk unchanged.
if [[ "$PLATFORMS" == *android* ]]; then
  python3 - <<'PY_ANDROID_PLUGIN_COMPILE_SDK'
import json
import re
from pathlib import Path
from urllib.parse import unquote, urlparse

project_dir = Path.cwd()
config_path = project_dir / '.dart_tool' / 'package_config.json'
if not config_path.exists():
    raise SystemExit(0)

config = json.loads(config_path.read_text())
patched = []

def package_root(root_uri: str) -> Path | None:
    if not root_uri:
        return None
    if root_uri.startswith('file://'):
        parsed = urlparse(root_uri)
        return Path(unquote(parsed.path))
    return (config_path.parent / root_uri).resolve()

patterns = [
    (re.compile(r'compileSdkVersion\s+(?:flutter\.compileSdkVersion|\d+)'), 'compileSdkVersion 36'),
    (re.compile(r'compileSdk\s*=\s*(?:flutter\.compileSdkVersion|\d+)'), 'compileSdk = 36'),
    (re.compile(r'compileSdk\s+(?:flutter\.compileSdkVersion|\d+)'), 'compileSdk 36'),
]

allowed_plugins = {'file_picker', 'flutter_plugin_android_lifecycle', 'qr_code_scanner_plus'}

for package in config.get('packages', []):
    package_name = package.get('name', '')
    if package_name not in allowed_plugins:
        continue
    root = package_root(package.get('rootUri', ''))
    if root is None:
        continue
    android_dir = root / 'android'
    if not android_dir.exists():
        continue
    for gradle_file in (android_dir / 'build.gradle', android_dir / 'build.gradle.kts'):
        if not gradle_file.exists():
            continue
        text = gradle_file.read_text()
        updated = text
        for pattern, replacement in patterns:
            updated = pattern.sub(replacement, updated)
        if updated != text:
            gradle_file.write_text(updated)
            patched.append(f"{package_name}:{gradle_file}")

if patched:
    print('ReadArc normalized Android plugin compileSdk to 36:')
    for item in patched:
        print(f'  - {item}')
PY_ANDROID_PLUGIN_COMPILE_SDK
fi

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

# Internal debug builds may use ws:// or http:// relay. Production builds must use HTTPS/WSS and avoid cleartext traffic.
if [[ -f "$ANDROID_MANIFEST" ]] && ! grep -q "usesCleartextTraffic" "$ANDROID_MANIFEST"; then
  perl -0pi -e 's#<application#<application android:usesCleartextTraffic="true"#' "$ANDROID_MANIFEST"
fi


# Stable internal Android release signing. This is a checked-in DEV key only for
# sideloadable snapshot builds, so Android can update ReadArc over a previous
# CI build without uninstalling. Replace it with a private production keystore
# before Play Store / public distribution.
DEV_KEY_SRC="$ROOT_DIR/assets/signing/readarc-dev-upload.jks"
DEV_KEY_DST="android/app/readarc-dev-upload.jks"
if [[ -f "$DEV_KEY_SRC" && -d "android/app" ]]; then
  cp "$DEV_KEY_SRC" "$DEV_KEY_DST"
fi

python3 - <<'PY_ANDROID_SIGNING'
from pathlib import Path

kts = Path('android/app/build.gradle.kts')
groovy = Path('android/app/build.gradle')

if kts.exists():
    p = kts
    text = p.read_text()
    if 'readarcDevRelease' not in text:
        text = text.replace('android {', '''android {
    signingConfigs {
        create("readarcDevRelease") {
            storeFile = file("readarc-dev-upload.jks")
            storePassword = "readarc-dev"
            keyAlias = "readarc-dev"
            keyPassword = "readarc-dev"
        }
    }
''', 1)
    text = text.replace('signingConfig = signingConfigs.getByName("debug")', 'signingConfig = signingConfigs.getByName("readarcDevRelease")')
    text = text.replace('signingConfig = signingConfigs.debug', 'signingConfig = signingConfigs.getByName("readarcDevRelease")')
    p.write_text(text)
elif groovy.exists():
    p = groovy
    text = p.read_text()
    if 'readarcDevRelease' not in text:
        text = text.replace('android {', '''android {
    signingConfigs {
        readarcDevRelease {
            storeFile file('readarc-dev-upload.jks')
            storePassword 'readarc-dev'
            keyAlias 'readarc-dev'
            keyPassword 'readarc-dev'
        }
    }
''', 1)
    text = text.replace('signingConfig signingConfigs.debug', 'signingConfig signingConfigs.readarcDevRelease')
    text = text.replace('signingConfig = signingConfigs.debug', 'signingConfig signingConfigs.readarcDevRelease')
    p.write_text(text)
PY_ANDROID_SIGNING

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
