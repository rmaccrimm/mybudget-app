#!/bin/sh
# Xcode build phase: build mybudget-server from ../server for the app's
# architectures, put it in Contents/MacOS, and sign it so it runs inside the
# app's sandbox (Config/Server.entitlements).
#
# Cargo's output goes under Xcode's build folder, never into server/, so app
# builds don't touch the implementer's lane.
set -eu

export PATH="$HOME/.cargo/bin:$PATH"
export CARGO_TARGET_DIR="$TARGET_TEMP_DIR/cargo"
MANIFEST="$SRCROOT/../server/Cargo.toml"

if [ ! -f "$MANIFEST" ]; then
  echo "error: $MANIFEST not found; run 'git submodule update --init' in the superproject." >&2
  exit 1
fi

if [ "$CONFIGURATION" = "Release" ]; then
  PROFILE=release
  set -- --release
else
  PROFILE=debug
  set --
fi

BINS=""
for ARCH in $ARCHS; do
  case "$ARCH" in
    arm64) TRIPLE=aarch64-apple-darwin ;;
    x86_64) TRIPLE=x86_64-apple-darwin ;;
    *) echo "error: no Rust target for architecture $ARCH" >&2; exit 1 ;;
  esac
  if ! cargo build --locked --manifest-path "$MANIFEST" --target "$TRIPLE" "$@"; then
    echo "error: cargo build for $TRIPLE failed (if the target is missing: rustup target add $TRIPLE)" >&2
    exit 1
  fi
  BINS="$BINS $CARGO_TARGET_DIR/$TRIPLE/$PROFILE/mybudget-server"
done

DEST="$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/mybudget-server"
mkdir -p "$(dirname "$DEST")"
# shellcheck disable=SC2086 # BINS is a list of paths without spaces.
lipo -create $BINS -output "$DEST"
codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --options runtime \
  --entitlements "$SRCROOT/Config/Server.entitlements" "$DEST"
