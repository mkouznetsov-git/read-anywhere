#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_PLATFORM="${1:-all}"
ENGINE_MANIFEST="$ROOT_DIR/native/readarc_engines/djvu/Cargo.toml"
DIST_ROOT="$ROOT_DIR/native/readarc_engines/dist"

if ! command -v cargo >/dev/null 2>&1; then
  echo "Rust cargo not found; skipping embedded DJVU native engine build." >&2
  exit 2
fi

mkdir -p "$DIST_ROOT"

build_macos() {
  echo "Building embedded DJVU engine for macOS universal dylib..."
  mkdir -p "$DIST_ROOT/macos"

  # GitHub macOS runners can be Apple Silicon while real users may still run
  # Intel Macs. Build both slices and lipo them together so the embedded DJVU
  # engine loads on macOS x86_64 and arm64 instead of silently producing blank
  # pages on the opposite architecture.
  if command -v rustup >/dev/null 2>&1; then
    rustup target add x86_64-apple-darwin aarch64-apple-darwin >/dev/null
  fi

  local x64_src="$ROOT_DIR/native/readarc_engines/djvu/target/x86_64-apple-darwin/release/libreadarc_djvu_engine.dylib"
  local arm_src="$ROOT_DIR/native/readarc_engines/djvu/target/aarch64-apple-darwin/release/libreadarc_djvu_engine.dylib"
  local universal="$DIST_ROOT/macos/libreadarc_djvu_engine.dylib"

  cargo build --release --locked --manifest-path "$ENGINE_MANIFEST" --target x86_64-apple-darwin
  cargo build --release --locked --manifest-path "$ENGINE_MANIFEST" --target aarch64-apple-darwin

  if [[ -f "$x64_src" && -f "$arm_src" && "$(command -v lipo || true)" != "" ]]; then
    lipo -create -output "$universal" "$x64_src" "$arm_src"
  elif [[ -f "$x64_src" ]]; then
    cp "$x64_src" "$universal"
  elif [[ -f "$arm_src" ]]; then
    cp "$arm_src" "$universal"
  else
    echo "macOS DJVU engine was not produced for either architecture." >&2
    return 1
  fi

  file "$universal" || true
}

build_android() {
  echo "Building embedded DJVU engine for supported Android ABIs..."
  if ! command -v cargo-ndk >/dev/null 2>&1; then
    echo "cargo-ndk not found; install with: cargo install cargo-ndk --locked" >&2
    return 2
  fi
  mkdir -p "$DIST_ROOT/android"
  (
    cd "$ROOT_DIR/native/readarc_engines/djvu"
    cargo ndk \
      -t armeabi-v7a \
      -t arm64-v8a \
      -t x86_64 \
      -o "$DIST_ROOT/android" \
      build --release --locked
  )
  for abi in armeabi-v7a arm64-v8a x86_64; do
    if [[ ! -f "$DIST_ROOT/android/$abi/libreadarc_djvu_engine.so" ]]; then
      echo "Android DJVU engine was not produced for $abi." >&2
      return 1
    fi
  done
}

case "$TARGET_PLATFORM" in
  macos)
    build_macos
    ;;
  android)
    build_android
    ;;
  all)
    build_macos
    build_android
    ;;
  *)
    echo "Usage: $0 [macos|android|all]" >&2
    exit 64
    ;;
esac
