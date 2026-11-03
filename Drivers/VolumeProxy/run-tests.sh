#!/bin/bash
# Runs production render code against synthetic buffers; never starts the daemon.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
clang -std=c11 -arch arm64 -mmacosx-version-min=15.0 \
    -I "$DIR/../Shared" "$DIR/MaestroVolumeProxyTests.c" \
    -framework Foundation -framework CoreAudio -framework AudioToolbox -framework IOKit \
    -Wall -Wextra -O2 -o "$TMP/proxy-tests"
"$TMP/proxy-tests"
