#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIR="$(cd "$SCRIPT_DIR/../Source" && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/test.cpp" <<'EOF'
#include <cassert>
#include <cstdint>
#include "SymphonyMixerPan.h"

int main() {
    assert(SymphonyMixerPanAttenuation(0) == -48);
    assert(SymphonyMixerPanAttenuation(32) == -24);
    assert(SymphonyMixerPanAttenuation(64) == 0);
    assert(SymphonyMixerPanAttenuation(96) == 0);
    assert(SymphonyMixerPanAttenuation(128) == 0);
    for (int pan = 0; pan <= 128; ++pan) {
        const int left = SymphonyMixerPanAttenuation(static_cast<uint8_t>(128 - pan));
        const int right = SymphonyMixerPanAttenuation(static_cast<uint8_t>(pan));
        if (pan == 64) assert(left == 0 && right == 0);
        if (pan == 0) assert(left == 0 && right == -48);
        if (pan == 128) assert(left == -48 && right == 0);
    }

    // SW Return uses the same balance law while retaining independent side
    // faders. Center must be unity on both sides, and full-left/full-right
    // must attenuate only the opposite side.
    for (int pan = 0; pan <= 128; ++pan) {
        const int left = SymphonyMixerPanAttenuation(static_cast<uint8_t>(128 - pan));
        const int right = SymphonyMixerPanAttenuation(static_cast<uint8_t>(pan));
        if (pan == 64) assert(left == 0 && right == 0);
        if (pan == 0) assert(left == 0 && right == -48);
        if (pan == 128) assert(left == -48 && right == 0);
    }
}
EOF

clang++ -std=c++17 -Wall -Wextra -Werror -I "$SOURCE_DIR" \
    "$TMP_DIR/test.cpp" -o "$TMP_DIR/test"
"$TMP_DIR/test"
grep -q 'state.swReturnPanByte = (p0 > 128) ? 128 : p0' \
    "$SOURCE_DIR/SymphonyThunderbridge.cpp"
grep -q 'state.swReturnPanByte));' "$SOURCE_DIR/SymphonyThunderbridge.cpp"

MIXER_VIEW="$SCRIPT_DIR/../../../Apps/Maestro/MaestroApp/MixerViews.swift"
test -f "$MIXER_VIEW"
grep -q 'onPanChange: { pan in' "$MIXER_VIEW"
grep -q 'Task { await writeSWReturnPan(pan); saveMixerState() }' "$MIXER_VIEW"
grep -q 'showPan: true' "$MIXER_VIEW"
python3 - "$MIXER_VIEW" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text()
start = source.index("private func writeSoftwareReturnSource")
end = source.index("\n    }\n}\n\n/// A single mixer channel strip", start)
block = source[start:end]
assert "device is XPCDeviceConnection && source == 0" in block
assert "ThunderBridge source 0" in block
assert "await writeSWReturnPan(swReturnChannel.pan)" in block
assert "await writeSWReturnMute(swReturnChannel.isMuted)" in block
assert "await writeSWReturnSolo(swReturnChannel.isSoloed)" in block
PY
echo "ThunderBridge mixer pan invariants: PASS"
