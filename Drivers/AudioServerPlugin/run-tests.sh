#!/bin/bash
# Build the production factory harness against the already-configured libASPL.
set -euo pipefail
ASP_DIR="$(cd "$(dirname "$0")" && pwd)"
ASP_BUILD_DIR="$ASP_DIR/build"
if [[ ! -f "$ASP_BUILD_DIR/_deps/libaspl-build/libASPL.a" ]]; then
    echo "Build the AudioServerPlugin first with $ASP_DIR/Scripts/build.sh" >&2
    exit 1
fi
ASP_TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$ASP_TEST_TMP"' EXIT
clang++ -std=c++17 -fblocks -arch arm64 -mmacosx-version-min=14.0 \
    -I "$ASP_BUILD_DIR/_deps/libaspl-src/include" \
    -I "$ASP_BUILD_DIR/_deps/libaspl-src/src" -I "$ASP_DIR/../Shared" \
    "$ASP_DIR/Tests/PreferredOutputLayoutTests.cpp" \
    "$ASP_BUILD_DIR/_deps/libaspl-build/libASPL.a" \
    -framework CoreAudio -framework CoreFoundation -framework IOKit \
    -o "$ASP_TEST_TMP/preferred-output-layout"
"$ASP_TEST_TMP/preferred-output-layout"
"$ASP_DIR/run-live-tests.sh" --self-test
