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
  echo "Building embedded DJVU engine for macOS..."
  cargo build --release --manifest-path "$ENGINE_MANIFEST"
  mkdir -p "$DIST_ROOT/macos"
  local src="$ROOT_DIR/native/readarc_engines/djvu/target/release/libreadarc_djvu_engine.dylib"
  if [[ ! -f "$src" ]]; then
    echo "macOS DJVU engine was not produced: $src" >&2
    return 1
  fi
  cp "$src" "$DIST_ROOT/macos/libreadarc_djvu_engine.dylib"
}

build_android() {
  echo "Building embedded DJVU engine for Android arm64-v8a..."
  if ! command -v cargo-ndk >/dev/null 2>&1; then
    echo "cargo-ndk not found; install with: cargo install cargo-ndk --locked" >&2
    return 2
  fi
  mkdir -p "$DIST_ROOT/android"
  (
    cd "$ROOT_DIR/native/readarc_engines/djvu"
    cargo ndk \
      -t arm64-v8a \
      -o "$DIST_ROOT/android" \
      build --release
  )
  if [[ ! -f "$DIST_ROOT/android/arm64-v8a/libreadarc_djvu_engine.so" ]]; then
    echo "Android arm64 DJVU engine was not produced." >&2
    return 1
  fi
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
