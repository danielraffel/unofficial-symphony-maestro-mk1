#!/bin/bash
# Build the Apogee Symphony IO AudioServerPlugin
# Usage: ./build.sh [clean]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PLUGIN_DIR/build"

if [ "${1:-}" = "clean" ]; then
    echo "[ASP] Cleaning build directory..."
    rm -rf "$BUILD_DIR"
fi

echo "[ASP] Configuring CMake..."
# Pin the Makefile generator. A global CMAKE_GENERATOR=Ninja (set for other
# projects on the build hosts) breaks a fresh configure: libASPL declares its
# code-generation step with an empty BYPRODUCTS list, which Ninja 1.13 rejects
# ("_deps/libaspl-build is defined as an output multiple times"). Every
# release so far was built with Makefiles; keep it that way regardless of env.
unset CMAKE_GENERATOR
cmake -G "Unix Makefiles" -B "$BUILD_DIR" -S "$PLUGIN_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64

echo "[ASP] Building..."
cmake --build "$BUILD_DIR" --config Release -- -j$(sysctl -n hw.ncpu)

echo "[ASP] Build complete."
echo "[ASP] Driver bundle: $BUILD_DIR/ApogeeSymIO.driver/"

# Verify the bundle exists
if [ -d "$BUILD_DIR/ApogeeSymIO.driver" ]; then
    echo "[ASP] Bundle contents:"
    ls -la "$BUILD_DIR/ApogeeSymIO.driver/Contents/"
    echo "[ASP] Binary:"
    file "$BUILD_DIR/ApogeeSymIO.driver/Contents/MacOS/ApogeeSymIO" 2>/dev/null || true

    # Sign with Developer ID — required for coreaudiod to load the plugin.
    # HAL plugins loaded without a valid signature may be silently rejected on macOS 26.
    echo "[ASP] Signing driver bundle..."
    : "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY in the private build environment}"
    codesign --sign "$SIGNING_IDENTITY" \
        --force --deep \
        "$BUILD_DIR/ApogeeSymIO.driver"
    codesign -v "$BUILD_DIR/ApogeeSymIO.driver" && echo "[ASP] Signature OK"
else
    echo "[ASP] WARNING: Driver bundle not found at expected path"
    find "$BUILD_DIR" -name "ApogeeSymIO*" -type f 2>/dev/null
fi
