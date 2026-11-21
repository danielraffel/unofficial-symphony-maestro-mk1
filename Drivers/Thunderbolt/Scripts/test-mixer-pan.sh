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

    // The driver keeps a Software Return balance on the same law (the app no
    // longer offers one and always writes centre). Center must be unity on
    // both sides, and full-left/full-right attenuate only the opposite side.
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
# 0.9.19: the Software Return strip has no pan (Apogee's had a stereo fader,
# solo and mute only). These checks pinned the pan knob before; they now pin
# its absence, and that the card's return pan is written centre.
grep -q "// No pan: Apogee's Software Return had a stereo fader, solo and mute." "$MIXER_VIEW"
grep -q 'showPan: false' "$MIXER_VIEW"
if grep -q 'writeSWReturnPan' "$MIXER_VIEW"; then
    echo "FAIL: MixerViews.swift still writes a Software Return pan" >&2; exit 1
fi
if grep -q 'showPan: true' "$MIXER_VIEW"; then
    echo "FAIL: a strip in MixerViews.swift still sets showPan: true explicitly" >&2; exit 1
fi
python3 - "$MIXER_VIEW" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text()
start = source.index("private func writeSoftwareReturnSource")
end = source.index("\n    }\n}\n\n/// Master meters observe only", start)
block = source[start:end]
# USB has its own branch (the Symphony's mixer strips 32/33, unit first, then
# the helper). Everything after its `else` is the ThunderBridge path, which
# must still mirror the persisted mute and solo into the card's
# software-return input, and put its pan at centre: source 0 there is the
# card's real host-playback return, so it is restored, never reset.
assert "if let xpcDev = usbDevice {" in block
usb_start = block.index("if let xpcDev = usbDevice {")
thunderbridge = block[block.index("\n        } else {", usb_start):]
assert "await centreSWReturnPanOnCard()" in thunderbridge
assert "await writeSWReturnMute(swReturnChannel.isMuted)" in thunderbridge
assert "await writeSWReturnSolo(swReturnChannel.isSoloed)" in thunderbridge
# The centre write is a pan of 0 on the return's own element, ThunderBridge only.
centre = source[source.index("private func centreSWReturnPanOnCard"):]
centre = centre[:centre.index("\n    }\n")]
assert "usbDevice == nil" in centre
assert "selector: .mixerChannelPan, element: swReturnElement" in centre
assert "value: .float64(0)" in centre
strip = source[source.index("private var swReturnStrip: some View {"):]
strip = strip[:strip.index("private var masterReadoutRow")]
assert "onPanChange" not in strip and "onBatchPan" not in strip and "onPanOptionClick" not in strip
PY
echo "ThunderBridge mixer pan invariants: PASS"
