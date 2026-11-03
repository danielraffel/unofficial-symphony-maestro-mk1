#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIR="$(cd "$SCRIPT_DIR/../Source" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/../../../Apps/Maestro" && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/test.cpp" <<'EOF'
#include <cassert>
#include <cstdint>
#include "SymphonyCardMixerRouting.h"

int main() {
    assert(kThunderboltMixerSoftwareReturnCommand == 0xB4);
    assert(IsThunderboltSoftwareReturnSource(0));
    assert(IsThunderboltSoftwareReturnSource(7));
    assert(!IsThunderboltSoftwareReturnSource(8));
    assert(ThunderboltSoftwareReturnSlot(0, 0) == 64);
    assert(ThunderboltSoftwareReturnSlot(0, 1) == 65);
    assert(ThunderboltSoftwareReturnSlot(7, 0) == 78);
    assert(ThunderboltSoftwareReturnSlot(7, 1) == 79);
    assert(ThunderboltMixerReturnRegister(1, 0) == 0x2200);
    assert(ThunderboltMixerReturnRegister(1, 1) == 0x2204);
    assert(ThunderboltMixerReturnRegister(2, 0) == 0x2208);
    assert(ThunderboltMixerReturnRegister(2, 1) == 0x220c);
    assert(ThunderboltMixerPhysicalBase(1) == 0);
    assert(ThunderboltMixerPhysicalBase(2) == 2);
}
EOF

clang++ -std=c++17 -Wall -Wextra -Werror -I "$SOURCE_DIR" \
    "$TMP_DIR/test.cpp" -o "$TMP_DIR/test"
"$TMP_DIR/test"

# Routing UI must use the dext read selector on ThunderBridge. A write-only
# transport makes the matrix display cached/default state and hides failed
# writes, which was the failure mode reported for Thunderbolt.
grep -q 'readVendorCommand' "$APP_DIR/MaestroDevice/DextUserClient.swift"
grep -q 'case \.routing:' "$APP_DIR/MaestroDevice/ThunderboltDeviceConnection.swift"
grep -q 'kSelectorReadVendor' "$SOURCE_DIR/SymphonyUserClient.cpp"
grep -q 'ReadVendorCommand' "$SOURCE_DIR/SymphonyThunderbridge.cpp"
echo "ThunderBridge software-return route invariants: PASS"
