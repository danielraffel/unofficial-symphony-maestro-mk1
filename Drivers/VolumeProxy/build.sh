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

# Do not elevate privileges or replace root-owned outputs in a compile-only build.
if [ -f "$OUT" ] && [ ! -w "$OUT" ]; then
    echo "[VolumeProxy] Output is not writable; choose a clean user-owned checkout." >&2
    exit 1
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

echo "[VolumeProxy] Compile complete: $OUT"
echo "[VolumeProxy] Installer/build-installer.sh signs and packages this component."
