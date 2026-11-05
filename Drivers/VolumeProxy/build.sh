#!/bin/bash
# Build MaestroVolumeProxy — XPC bridge daemon for AudioServerPlugin sandbox.
#
# The AudioServerPlugin runs in a sandboxed helper process that blocks UNIX
# domain socket access. This daemon bridges XPC (allowed by the sandbox) to
# the Apogee daemon UNIX socket at /var/run/com.apogee.symphonyIOUSBDaemon/Socket.
#
# Usage: ./build.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/MaestroVolumeProxy.c"
BUILD_DIR="$SCRIPT_DIR/build"
OUT="$BUILD_DIR/MaestroVolumeProxy"

mkdir -p "$BUILD_DIR"

# Remove stale binary if it's owned by root (from previous sudo deploy)
if [ -f "$OUT" ] && [ ! -w "$OUT" ]; then
    echo "[VolumeProxy] Removing root-owned stale binary..."
    sudo rm -f "$OUT"
fi

echo "[VolumeProxy] Building MaestroVolumeProxy..."
clang -o "$OUT" "$SRC" \
    -I "$SCRIPT_DIR/../Shared" \
    -arch arm64 \
    -mmacosx-version-min=15.0 \
    -framework Foundation \
    -framework CoreAudio \
    -framework AudioToolbox \
    -framework IOKit \
    -Wall -Wextra -O2

echo "[VolumeProxy] Signing..."
: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY in the private build environment}"
codesign --sign "$SIGNING_IDENTITY" \
    --force \
    "$OUT"
codesign -v "$OUT" && echo "[VolumeProxy] Signature OK"

echo "[VolumeProxy] Build complete: $OUT"
echo "[VolumeProxy] Run install.sh (from AudioServerPlugin/Scripts/) to deploy."
