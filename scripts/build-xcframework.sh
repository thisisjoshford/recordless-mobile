#!/usr/bin/env bash
# Build recordless_core for iOS device + simulator, generate Swift bindings,
# and assemble ios/Frameworks/RecordlessCore.xcframework + ios/Generated/*.swift.
#
# Usage: scripts/build-xcframework.sh [--debug]
# Env:   IPHONEOS_DEPLOYMENT_TARGET (default 17.0)
#        RECORDLESS_TRIAL_URL  https:// base URL of the credit service
#                              (services/trial-keys); compiled into the core.
#                              Without it, activation codes are unavailable
#                              (an own `sk-` key still works).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PROFILE=release
CARGO_PROFILE_FLAG=(--release)
if [[ "${1:-}" == "--debug" ]]; then
  PROFILE=debug
  CARGO_PROFILE_FLAG=()
fi

CRATE=recordless_core
LIB="lib${CRATE}.a"
FFI_MODULE="${CRATE}FFI"
OUT_FW="$ROOT/ios/Frameworks/RecordlessCore.xcframework"
OUT_GEN="$ROOT/ios/Generated"
STAGE="$ROOT/target/xcframework-stage"

export PATH="/opt/homebrew/bin:$PATH"   # cmake
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"
command -v cmake >/dev/null || { echo "cmake not found" >&2; exit 1; }
command -v xcrun >/dev/null || { echo "Xcode command line tools not found" >&2; exit 1; }

build_target() {
  local target="$1" sdk="$2"
  echo "==> cargo build ${PROFILE} ${target} (${sdk})"
  # SDKROOT steers cc/cmake/bindgen at the right iOS SDK.
  SDKROOT="$(xcrun --sdk "$sdk" --show-sdk-path)" \
    cargo build -p "$CRATE" --lib --target "$target" "${CARGO_PROFILE_FLAG[@]}"
}

build_target aarch64-apple-ios iphoneos
build_target aarch64-apple-ios-sim iphonesimulator

DEVICE_LIB="$ROOT/target/aarch64-apple-ios/$PROFILE/$LIB"
SIM_LIB="$ROOT/target/aarch64-apple-ios-sim/$PROFILE/$LIB"

# Exactly one ggml must be in the archive: whisper-rs-sys's own (stock crate,
# Metal on). Nothing else may bring a second copy (e.g. a reintroduced
# llama.cpp), so a core ggml symbol must be defined exactly once.
for lib in "$DEVICE_LIB" "$SIM_LIB"; do
  n=$(nm -g "$lib" 2>/dev/null | grep -c ' T _ggml_init$' || true)
  if [[ "$n" != "1" ]]; then
    echo "error: expected exactly one ggml_init definition in $lib, found $n" >&2
    exit 1
  fi
done

# Native heap wiping (core/native/): whisper.cpp/ggml must be compiled with
# wipe_free.h force-included (no direct free/realloc), and the replacement
# operator new/delete must be in the archive. A stale whisper-rs-sys build
# (cargo does not track .cargo/config.toml [env]) fails here; fix with
# `cargo clean -p whisper-rs-sys --target <triple> --release`.
for lib in "$DEVICE_LIB" "$SIM_LIB"; do
  syms=$(nm -A -u "$lib" 2>/dev/null | grep -E '(ggml|whisper)[^:]*\.o: ' | awk '{print $NF}' || true)
  if grep -qxE '_(free|realloc)' <<<"$syms"; then
    echo "error: whisper.cpp/ggml in $lib call free/realloc directly (wipe_free.h not applied)" >&2
    exit 1
  fi
  if ! grep -qx '_recordless_wiping_free' <<<"$syms"; then
    echo "error: whisper.cpp/ggml in $lib do not call recordless_wiping_free" >&2
    exit 1
  fi
  defs=$(nm -A -g "$lib" 2>/dev/null | grep -E 'wipe\.o: ' || true)
  for op in __ZdlPv __ZdaPv __ZdlPvm __ZdlPvSt11align_val_t __Znwm __ZnwmSt11align_val_t; do
    if ! grep -q " T ${op}\$" <<<"$defs"; then
      echo "error: replacement ${op} missing from $lib" >&2
      exit 1
    fi
  done
done

echo "==> uniffi-bindgen (swift, library mode)"
rm -rf "$STAGE"
mkdir -p "$STAGE/bindings" "$STAGE/headers"
cargo run -q -p uniffi-bindgen -- generate \
  --library "$DEVICE_LIB" \
  --language swift \
  --out-dir "$STAGE/bindings"

cp "$STAGE/bindings/${FFI_MODULE}.h" "$STAGE/headers/"
# Module map named module.modulemap so Xcode picks it up from the xcframework.
# The link directives autolink the system libraries the static lib needs.
cat > "$STAGE/headers/module.modulemap" <<EOF
module ${FFI_MODULE} {
    header "${FFI_MODULE}.h"
    export *
    link "c++"
    link framework "Foundation"
    link framework "Metal"
    link framework "MetalKit"
    link framework "Accelerate"
    link framework "Security"
}
EOF

echo "==> xcodebuild -create-xcframework"
rm -rf "$OUT_FW"
mkdir -p "$(dirname "$OUT_FW")"
xcodebuild -create-xcframework \
  -library "$DEVICE_LIB" -headers "$STAGE/headers" \
  -library "$SIM_LIB" -headers "$STAGE/headers" \
  -output "$OUT_FW" >/dev/null

mkdir -p "$OUT_GEN"
rm -f "$OUT_GEN"/*.swift
cp "$STAGE/bindings/"*.swift "$OUT_GEN/"

echo "==> done"
du -sh "$OUT_FW"
ls -1 "$OUT_GEN"
