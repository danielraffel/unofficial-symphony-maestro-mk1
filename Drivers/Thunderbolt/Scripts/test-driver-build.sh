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
APP_CLIENT="$ROOT/Apps/Maestro/MaestroDevice/DextUserClient.swift"
grep -q 'private static let selectorReadDriverBuild: UInt32 = 6' "$APP_CLIENT"
grep -q 'IOConnectCallStructMethod(conn, Self.selectorReadDriverBuild, nil, 0, p.baseAddress, &outSize)' "$APP_CLIENT"
# The two-port experiment's port-2 state read moved from 6 (exp64 9001-9003)
# to 7 so the released driver-build selector keeps 6. App and dext must agree.
grep -q 'private static let selectorReadPort2State: UInt32 = 7' "$APP_CLIENT"
grep -q '\[kSelectorReadPort2State\]' "$DIR/Source/SymphonyUserClient.cpp"

BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$DIR/Info.plist")
cat > "$TMP/t.cpp" <<'CPP'
#include "SymphonyThunderbridgeShared.h"
#include <stdio.h>
static_assert(kSelectorReadDriverBuild == 6, "app asks selector 6");
static_assert(kSelectorReadPort2State == 7, "app asks selector 7 for port 2");
static_assert(kSelectorCount == 8, "dispatch table covers both");
static_assert(sizeof(SymphonyDriverBuildOutput) == 8, "app reads two words");
// Different output sizes are what make an old/new mismatch fail safe: an exp64
// 9001-9003 dext answers selector 6 only with 64 bytes, so the app's 8-byte
// build read is rejected, and this dext rejects an old app's 64-byte read of 6.
static_assert(sizeof(SymphonyPort2StateOutput) == 64, "app reads sixteen words");
int main() { printf("%u\n", (unsigned)SYMPHONY_DEXT_BUILD); return 0; }
CPP
clang++ -std=c++17 -I "$DIR/Source" -DSYMPHONY_DEXT_BUILD="$BUILD" -o "$TMP/t" "$TMP/t.cpp"
test "$("$TMP/t")" = "$BUILD"
echo "Driver build reporting (build $BUILD): PASS"
