#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
GHOSTTY_DIR="$REPO_ROOT/Vendor/ghostty"
OUTPUT_ROOT="$REPO_ROOT/Build/ghostty-vt"
PREFIX_DIR="$OUTPUT_ROOT/prefix"
XCFRAMEWORK_DIR="$PREFIX_DIR/lib/ghostty-vt.xcframework"
DIRECT_LIB_PATH="$PREFIX_DIR/lib/libghostty-vt.a"
PREBUILT_ROOT="$REPO_ROOT/Vendor/ghostty-prebuilt"
EXPECTED_ZIG_VERSION="0.15.2"
CAN_BUILD_FROM_SOURCE=1
BUILD_SKIP_REASON=""

if [[ -n "${ZIG:-}" ]]; then
  ZIG_BIN="$ZIG"
elif command -v brew >/dev/null 2>&1 && [[ -x "$(brew --prefix zig@0.15 2>/dev/null)/bin/zig" ]]; then
  ZIG_BIN="$(brew --prefix zig@0.15)/bin/zig"
else
  ZIG_BIN=$(command -v zig || true)
fi

if [[ -z "${ZIG_BIN:-}" ]] || [[ ! -x "$ZIG_BIN" ]]; then
  CAN_BUILD_FROM_SOURCE=0
  BUILD_SKIP_REASON="Missing Zig $EXPECTED_ZIG_VERSION."
  ZIG_VERSION="missing"
else
  ZIG_VERSION=$("$ZIG_BIN" version)
  if [[ "$ZIG_VERSION" != "$EXPECTED_ZIG_VERSION" ]]; then
    CAN_BUILD_FROM_SOURCE=0
    BUILD_SKIP_REASON="Unsupported Zig version: $ZIG_VERSION. Expected $EXPECTED_ZIG_VERSION."
  fi
fi

if [[ ! -d "$GHOSTTY_DIR" ]]; then
  CAN_BUILD_FROM_SOURCE=0
  BUILD_SKIP_REASON="Missing Ghostty source at $GHOSTTY_DIR."
fi

mkdir -p "$OUTPUT_ROOT"

OPTIMIZE=Debug
if [[ "${CONFIGURATION:-Debug}" != "Debug" ]]; then
  OPTIMIZE=ReleaseFast
fi

PLATFORM_NAME_VALUE="${PLATFORM_NAME:-iphonesimulator}"
case "$PLATFORM_NAME_VALUE" in
  iphoneos)
    SLICE_DIR="ios-arm64"
    TARGET_DIR="$OUTPUT_ROOT/iphoneos"
    PREBUILT_LIB="$PREBUILT_ROOT/iphoneos/libghostty-vt.a"
    BUILD_TARGET="aarch64-ios"
    BUILD_CPU=""
    ;;
  iphonesimulator)
    SLICE_DIR="ios-arm64-simulator"
    TARGET_DIR="$OUTPUT_ROOT/iphonesimulator"
    PREBUILT_LIB="$PREBUILT_ROOT/iphonesimulator/libghostty-vt.a"
    BUILD_TARGET="aarch64-ios-simulator"
    BUILD_CPU="apple_a17"
    ;;
  *)
    echo "Unsupported platform: $PLATFORM_NAME_VALUE" >&2
    exit 1
    ;;
esac

STAMP_FILE="$TARGET_DIR/build.stamp"
SOURCE_REV=$(git -C "$GHOSTTY_DIR" rev-parse HEAD 2>/dev/null || echo "unknown")
SCRIPT_HASH=$(shasum "$0" | awk '{print $1}')
FINGERPRINT=$ZIG_VERSION-$SOURCE_REV-$OPTIMIZE-$SLICE_DIR-$BUILD_TARGET-${BUILD_CPU:-generic}-$SCRIPT_HASH

if [[ -f "$STAMP_FILE" ]] && [[ -f "$TARGET_DIR/libghostty-vt.a" ]] && [[ "$(cat "$STAMP_FILE")" == "$FINGERPRINT" ]]; then
  exit 0
fi

rm -rf "$PREFIX_DIR" "$TARGET_DIR"
mkdir -p "$TARGET_DIR"
ZIG_LOG="$TARGET_DIR/zig-build.log"

if [[ "$CAN_BUILD_FROM_SOURCE" == "1" ]]; then
  BUILD_ARGS=(
    build
    -Demit-lib-vt=true
    -Doptimize="$OPTIMIZE"
    -Dtarget="$BUILD_TARGET"
    --prefix "$PREFIX_DIR"
  )
  if [[ -n "$BUILD_CPU" ]]; then
    BUILD_ARGS+=(-Dcpu="$BUILD_CPU")
  fi

  if (
    cd "$GHOSTTY_DIR"
    env -i \
      HOME="${HOME:-$REPO_ROOT}" \
      PATH="$(dirname "$ZIG_BIN"):/usr/bin:/bin:/usr/sbin:/sbin" \
      TMPDIR="${TMPDIR:-/tmp}" \
      DEVELOPER_DIR="${DEVELOPER_DIR:-}" \
      "$ZIG_BIN" "${BUILD_ARGS[@]}"
  ) >"$ZIG_LOG" 2>&1; then
    if [[ -f "$DIRECT_LIB_PATH" ]]; then
      cp "$DIRECT_LIB_PATH" "$TARGET_DIR/libghostty-vt.a"
      printf '%s' "$FINGERPRINT" > "$STAMP_FILE"
      exit 0
    fi

    if [[ -f "$XCFRAMEWORK_DIR/$SLICE_DIR/libghostty-vt.a" ]]; then
      cp "$XCFRAMEWORK_DIR/$SLICE_DIR/libghostty-vt.a" "$TARGET_DIR/libghostty-vt.a"
      printf '%s' "$FINGERPRINT" > "$STAMP_FILE"
      exit 0
    fi

    echo "Expected Ghostty VT library output not found in $PREFIX_DIR/lib" >&2
    exit 1
  fi
fi

if [[ ! -f "$PREBUILT_LIB" ]]; then
  if [[ -f "$ZIG_LOG" ]]; then
    cat "$ZIG_LOG" >&2
  fi
  if [[ -n "$BUILD_SKIP_REASON" ]]; then
    echo "$BUILD_SKIP_REASON" >&2
  fi
  echo "Ghostty VT build failed and no prebuilt fallback exists at $PREBUILT_LIB" >&2
  exit 1
fi

if [[ -n "$BUILD_SKIP_REASON" ]]; then
  echo "$BUILD_SKIP_REASON" >&2
fi
echo "Using prebuilt Ghostty VT archive for $PLATFORM_NAME_VALUE." >&2
cp "$PREBUILT_LIB" "$TARGET_DIR/libghostty-vt.a"
printf '%s' "$FINGERPRINT-prebuilt" > "$STAMP_FILE"
