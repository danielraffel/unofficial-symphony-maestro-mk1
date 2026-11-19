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
# to 7 (9004) and then to 8 (from 9005), so the released driver-build (6) and retire
# (7) selectors keep their numbers. App and dext must agree.
grep -q 'private static let selectorReadPort2State: UInt32 = 8' "$APP_CLIENT"
grep -q '\[kSelectorReadPort2State\]' "$DIR/Source/SymphonyUserClient.cpp"
# The temporary port-source naming switch (selector 9) was removed before the
# first beta; neither side may bring it back.
if grep -n -e 'SetPort''SourceNames' "$APP_CLIENT" "$DIR/Source/"*; then
    echo "FAIL: the temporary port-source naming switch is back" >&2; exit 1
fi

# The build read is a user-client call, and those wait behind whatever the
# driver is doing for another call (seconds during a link recovery). The app
# refreshes it every two seconds, so it is never made on the main thread.
APP="$ROOT/Apps/Maestro/MaestroApp"
if grep -n 'servingDextBuild = (device as? ThunderboltDeviceConnection)?.servingDriverBuild()' "$APP"/*.swift; then
    echo "FAIL: the serving driver build is read on the main thread again" >&2; exit 1
fi
grep -q 'Task.detached(priority: .utility) { tb.servingDriverBuild() }' "$APP/Diagnostics.swift"
grep -q 'Task.detached(priority: .utility) { tb.servingDriverBuild() }' "$APP/AppState.swift"

BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$DIR/Info.plist")
cat > "$TMP/t.cpp" <<'CPP'
#include "SymphonyThunderbridgeShared.h"
#include <stdio.h>
static_assert(kSelectorReadDriverBuild == 6, "app asks selector 6");
static_assert(kSelectorRetireForUpgrade == 7, "7 is the released retire selector");
static_assert(kSelectorReadPort2State == 8, "app asks selector 8 for port 2");
static_assert(kSelectorReadUnitB == 11 && kSelectorCount == 12, "dispatch table covers selectors 0-11");
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
