#!/bin/bash
# Default mode validates the measurement assertions without accessing audio.
# --run-live explicitly opts into bounded playback through installed hardware.
set -euo pipefail
ASP_TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
ASP_TEST_MODE="${1:---self-test}"
if [[ $# -gt 1 ]] || [[ "$ASP_TEST_MODE" != --self-test && "$ASP_TEST_MODE" != --run-live && "$ASP_TEST_MODE" != --help ]]; then
    echo "Usage: $0 [--self-test | --run-live | --help]" >&2
    exit 2
fi
ASP_LIVE_TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$ASP_LIVE_TEST_TMP"' EXIT
xcrun clang -std=c11 -fblocks -Wall -Wextra -Werror -O2 \
    "$ASP_TEST_DIR/Tests/LivePlaybackTests.c" \
    -framework AudioToolbox -framework CoreAudio -framework CoreFoundation \
    -o "$ASP_LIVE_TEST_TMP/live-playback-tests"
"$ASP_LIVE_TEST_TMP/live-playback-tests" "$ASP_TEST_MODE"
