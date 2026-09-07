#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/apps/flutter_client"
DIST_DIR="$ROOT_DIR/dist/android"
BASE_VERSION="${READARC_BASE_VERSION:-0.1.0}"
BUILD_NUMBER="${READARC_BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-}}"
if [[ -z "$BUILD_NUMBER" ]]; then
  BUILD_NUMBER="$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || echo 23)"
fi
if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "ERROR: Android build number must be numeric, got: $BUILD_NUMBER" >&2
  exit 1
fi

# Historical split-per-ABI packages used Flutter's automatic ABI_VERSION * 1000
# version-code adjustment. A user who installed one of those APKs cannot later
# install a universal APK with a small plain CI run number because Android sees
# it as a downgrade. Start a new sideload version-code epoch above every legacy
# ABI-adjusted code and force every APK/AAB flavor to use the same monotonic code.
ANDROID_VERSION_CODE_OFFSET="${READARC_ANDROID_VERSION_CODE_OFFSET:-10000}"
if [[ ! "$ANDROID_VERSION_CODE_OFFSET" =~ ^[0-9]+$ ]]; then
  echo "ERROR: READARC_ANDROID_VERSION_CODE_OFFSET must be numeric, got: $ANDROID_VERSION_CODE_OFFSET" >&2
  exit 1
fi
ANDROID_BUILD_NUMBER="${READARC_ANDROID_BUILD_NUMBER:-$((BUILD_NUMBER + ANDROID_VERSION_CODE_OFFSET))}"
if [[ ! "$ANDROID_BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "ERROR: Android version code must be numeric, got: $ANDROID_BUILD_NUMBER" >&2
  exit 1
fi

if [[ "${GITHUB_REF_NAME:-}" == v* ]]; then
  BUILD_NAME="${READARC_BUILD_NAME:-${GITHUB_REF_NAME#v}}"
  VERSION="${READARC_VERSION:-$BUILD_NAME}"
else
  BUILD_NAME="${READARC_BUILD_NAME:-$BASE_VERSION}"
  VERSION="${READARC_VERSION:-$BASE_VERSION-snapshot.$BUILD_NUMBER}"
fi
BUILD_DEBUG_ARTIFACTS="${BUILD_DEBUG_ARTIFACTS:-false}"
REQUIRE_RELEASE_SIGNING="${READARC_REQUIRE_RELEASE_SIGNING:-false}"
REQUIRE_NATIVE_ENGINES="${READARC_REQUIRE_NATIVE_ENGINES:-false}"

export READARC_PLATFORMS="android"
"$ROOT_DIR/scripts/prepare_flutter_platforms.sh"

cd "$APP_DIR"
if [[ "$REQUIRE_RELEASE_SIGNING" == "true" && ! -f android/key.properties ]]; then
  echo "ERROR: release publishing requires android/key.properties from protected CI secrets." >&2
  exit 1
fi
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# Build and bundle the embedded DJVU engine when the Rust Android toolchain is available.
# If it is missing, Flutter packages still build; DJVU pages will show an in-app diagnostic
# instead of using external tools.
if "$ROOT_DIR/scripts/build_native_engines.sh" android; then
  for abi in armeabi-v7a arm64-v8a x86_64; do
    mkdir -p "android/app/src/main/jniLibs/$abi"
    cp "$ROOT_DIR/native/readarc_engines/dist/android/$abi/libreadarc_djvu_engine.so" "android/app/src/main/jniLibs/$abi/libreadarc_djvu_engine.so"
  done
else
  if [[ "$REQUIRE_NATIVE_ENGINES" == "true" ]]; then
    echo "ERROR: verified packages require every embedded Android engine." >&2
    exit 1
  fi
  echo "Embedded DJVU Android engine was not bundled. Continuing build without external converters." >&2
fi

build_with_optional_define() {
  local relay_define="${READARC_DEFAULT_RELAY_URL:-https://relay.readarc.ru}"
  local args=("$@")
  if [[ -n "$relay_define" ]]; then
    args+=(--dart-define="READARC_DEFAULT_RELAY_URL=$relay_define")
  fi
  flutter "${args[@]}"
}

echo "Android versionName=$BUILD_NAME versionCode=$ANDROID_BUILD_NUMBER"
echo "Building Android universal release APK for simple sideload installation..."
build_with_optional_define build apk --release --build-name "$BUILD_NAME" --build-number "$ANDROID_BUILD_NUMBER"
if [[ -f build/app/outputs/flutter-apk/app-release.apk ]]; then
  cp build/app/outputs/flutter-apk/app-release.apk "$DIST_DIR/ReadArc-${VERSION}-android-universal-release.apk"
else
  echo "ERROR: universal release APK was not produced." >&2
  exit 1
fi

echo "Building Android release APKs split per ABI..."
build_with_optional_define build apk --release --build-name "$BUILD_NAME" --build-number "$ANDROID_BUILD_NUMBER" --split-per-abi -P force-version-code-ignoring-abi=true

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
    app-release.apk)
      # The universal APK from the previous build remains in Flutter's output
      # directory. It is already copied under the canonical universal name.
      ;;
    *)
      echo "ERROR: unexpected release APK output: $base" >&2
      exit 1
      ;;
  esac
done

echo "Building Android release App Bundle..."
build_with_optional_define build appbundle --release --build-name "$BUILD_NAME" --build-number "$ANDROID_BUILD_NUMBER"
if [[ -f build/app/outputs/bundle/release/app-release.aab ]]; then
  cp build/app/outputs/bundle/release/app-release.aab "$DIST_DIR/ReadArc-${VERSION}-android-release.aab"
else
  echo "ERROR: release App Bundle was not produced." >&2
  exit 1
fi

if [[ "$BUILD_DEBUG_ARTIFACTS" == "true" || "$BUILD_DEBUG_ARTIFACTS" == "1" ]]; then
  echo "Building optional Android debug APK..."
  build_with_optional_define build apk --debug --build-name "$BUILD_NAME" --build-number "$ANDROID_BUILD_NUMBER"
  cp build/app/outputs/flutter-apk/app-debug.apk "$DIST_DIR/ReadArc-${VERSION}-android-debug.apk"
fi

find_android_build_tool() {
  local tool="$1"
  local sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
  [[ -n "$sdk_root" && -d "$sdk_root/build-tools" ]] || return 1
  find "$sdk_root/build-tools" -type f -name "$tool" -perm -u+x 2>/dev/null | sort -V | tail -n 1
}

APKSIGNER="$(find_android_build_tool apksigner || true)"
ZIPALIGN="$(find_android_build_tool zipalign || true)"
if [[ -z "$APKSIGNER" || -z "$ZIPALIGN" ]]; then
  if [[ "$REQUIRE_RELEASE_SIGNING" == "true" ]]; then
    echo "ERROR: apksigner/zipalign are required to verify published Android APKs." >&2
    exit 1
  fi
  echo "WARNING: apksigner/zipalign unavailable; skipping local APK verification." >&2
else
  echo "Verifying final APK alignment and signatures..."
  for apk in "$DIST_DIR"/*.apk; do
    [[ -f "$apk" ]] || continue
    "$ZIPALIGN" -c -v 4 "$apk" >/dev/null
    "$APKSIGNER" verify --verbose --print-certs "$apk"
  done
fi

if command -v jarsigner >/dev/null 2>&1; then
  for aab in "$DIST_DIR"/*.aab; do
    [[ -f "$aab" ]] || continue
    jarsigner -verify "$aab" >/dev/null
  done
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
