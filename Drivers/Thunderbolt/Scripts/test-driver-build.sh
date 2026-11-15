#!/bin/bash
# The dext reports its own CFBundleVersion (kSelectorReadDriverBuild) so Device
# Info can name the build that serves the ThunderBridge. Checks that build.sh
# stamps the Info.plist number in, that the user client answers the selector,
# and that the app asks the same selector with the same output size.
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -f "$TMP/t" "$TMP/t.cpp"; rmdir "$TMP"' EXIT

grep -q 'Print :CFBundleVersion' "$DIR/Scripts/build.sh"
grep -q -- '-DSYMPHONY_DEXT_BUILD="$DEXT_BUILD"' "$DIR/Scripts/build.sh"
grep -q '\[kSelectorReadDriverBuild\]' "$DIR/Source/SymphonyUserClient.cpp"
grep -q 'output.build = (uint32_t)SYMPHONY_DEXT_BUILD' "$DIR/Source/SymphonyUserClient.cpp"
grep -q 'IOConnectCallStructMethod(conn, 6, nil, 0, p.baseAddress, &outSize)' \
    "$ROOT/Apps/Maestro/MaestroDevice/DextUserClient.swift"

BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$DIR/Info.plist")
cat > "$TMP/t.cpp" <<'CPP'
#include "SymphonyThunderbridgeShared.h"
#include <stdio.h>
static_assert(kSelectorReadDriverBuild == 6, "app asks selector 6");
static_assert(kSelectorCount == kSelectorReadDriverBuild + 1, "dispatch table covers it");
static_assert(sizeof(SymphonyDriverBuildOutput) == 8, "app reads two words");
int main() { printf("%u\n", (unsigned)SYMPHONY_DEXT_BUILD); return 0; }
CPP
clang++ -std=c++17 -I "$DIR/Source" -DSYMPHONY_DEXT_BUILD="$BUILD" -o "$TMP/t" "$TMP/t.cpp"
test "$("$TMP/t")" = "$BUILD"
echo "Driver build reporting (build $BUILD): PASS"
