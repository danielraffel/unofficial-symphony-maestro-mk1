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
static_assert(kSelectorCount > kSelectorReadDriverBuild, "dispatch table covers it");
static_assert(sizeof(SymphonyDriverBuildOutput) == 8, "app reads two words");
int main() { printf("%u\n", (unsigned)SYMPHONY_DEXT_BUILD); return 0; }
CPP
clang++ -std=c++17 -I "$DIR/Source" -DSYMPHONY_DEXT_BUILD="$BUILD" -o "$TMP/t" "$TMP/t.cpp"
test "$("$TMP/t")" = "$BUILD"
echo "Driver build reporting (build $BUILD): PASS"
