#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIR="$(cd "$SCRIPT_DIR/../Source" && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/test.cpp" <<'EOF'
#include <cassert>
#include "SymphonyTimingProfile.h"

int main() {
    const TimingProfile p44 = TimingProfileForRate(44100.0);
    const TimingProfile p48 = TimingProfileForRate(48000.0);
    const TimingProfile p88 = TimingProfileForRate(88200.0);
    const TimingProfile p96 = TimingProfileForRate(96000.0);
    const TimingProfile p176 = TimingProfileForRate(176400.0);
    const TimingProfile p192 = TimingProfileForRate(192000.0);
    assert(p44.frameSize == 4 && p44.safetyOffset == 10 &&
           p44.inputConverterLatency == 29 && p44.outputConverterLatency == 29);
    assert(p48.frameSize == 4 && p48.safetyOffset == 10 &&
           p48.inputConverterLatency + p48.frameSize == 33 &&
           p48.outputConverterLatency + p48.frameSize == 33);
    assert(p88.frameSize == 8 && p88.safetyOffset == 20 &&
           p88.inputConverterLatency + p88.frameSize == 36 &&
           p88.outputConverterLatency + p88.frameSize == 36);
    assert(p96.frameSize == 8 && p96.safetyOffset == 20 &&
           p96.inputConverterLatency + p96.frameSize == 36 &&
           p96.outputConverterLatency + p96.frameSize == 36);
    assert(p176.frameSize == 32 && p176.safetyOffset == 32 &&
           p176.inputConverterLatency + p176.frameSize == 58 &&
           p176.outputConverterLatency + p176.frameSize == 59);
    assert(p192.frameSize == 32 && p192.safetyOffset == 32 &&
           p192.inputConverterLatency + p192.frameSize == 58 &&
           p192.outputConverterLatency + p192.frameSize == 59);
}
EOF

clang++ -std=c++17 -Wall -Wextra -Werror -I "$SOURCE_DIR" \
    "$TMP_DIR/test.cpp" -o "$TMP_DIR/test"
"$TMP_DIR/test"
echo "ThunderBridge High Performance timing tuples: PASS"

# The initial 44.1 kHz publication is the first point at which Core Audio can
# cache the timing tuple.  Keep the failure path fail-closed: it must tear down
# the partially started driver and return the setter error, rather than falling
# through to RegisterService with a partial tuple.
python3 - "$SOURCE_DIR/SymphonyThunderbridge.cpp" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text()
needle = "ApplyAudioTimingProfile(ivars->audioDevice, 44100.0)"
start = source.index(needle)
end = source.index("// Preferred stereo pair", start)
block = source[start:end]
assert "Stop(provider);" in block
assert "Stop(provider, SUPERDISPATCH)" not in block
assert "return timingResult;" in block
assert "goto skip_audio;" not in block
PY
echo "ThunderBridge initial timing publication failure gate: PASS"

# Startup must verify the initial FPGA period before any audio device can be
# published. A write-only initial frame setup could otherwise expose the 4/10
# profile even when the hardware clamped or ignored the requested period.
python3 - "$SOURCE_DIR/SymphonyThunderbridge.cpp" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text()
start = source.index("// ── 26. Set FPGA frame size")
end = source.index("// ── 27. Set up interrupt handler", start)
block = source[start:end]
assert "Initial FPGA ClkCtrl readback" in block
assert "frameReadback != initialFrameSize" in block
assert "refusing startup timing publication" in block
assert "goto start_failure;" in block
PY
echo "ThunderBridge initial FPGA frame readback fail-closed gate: PASS"

# Rate changes must stage the complete target tuple before DriverKit's nominal
# rate notification. Otherwise Core Audio can cache the prior rate's safety
# value (the historical 96 kHz 8/10 publication bug). Keep the rollback and
# post-transition reapply visible in the source as well.
python3 - "$SOURCE_DIR/SymphonyAudioDevice.cpp" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text()
start = source.index("kern_return_t SymphonyAudioDevice::HandleChangeSampleRate")
end = source.index("\n}", start) + 2
block = source[start:end]
pre = block.index("ApplyTimingTuple(this, in_sample_rate, &previousTuple)")
super_change = block.index("super::HandleChangeSampleRate(in_sample_rate)")
post = block.index("const kern_return_t postResult = ApplyTimingTuple(this, in_sample_rate, &previousTuple)")
assert pre < super_change < post
assert "ApplyTimingTuple(this, previousRate, &previousTuple)" in block
assert "return postResult;" in block
PY
echo "ThunderBridge rate-change tuple ordering and rollback gate: PASS"

# A rollback is only valid after all four values read back equal the saved
# tuple; setter return codes alone cannot prove that a framework clamp did not
# leave a mixed safety/latency state.
python3 - "$SOURCE_DIR/SymphonyAudioDevice.cpp" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text()
set_start = source.index("static kern_return_t SetTimingTuple")
set_end = source.index("static kern_return_t ApplyTimingTuple", set_start)
set_block = source[set_start:set_end]
assert "ReadTimingTuple(device)" in set_block
assert "TimingTuplesEqual" in set_block
apply_start = source.index("static kern_return_t ApplyTimingTuple")
apply_end = source.index("kern_return_t SymphonyAudioDevice::PerformDeviceConfigurationChange", apply_start)
apply_block = source[apply_start:apply_end]
assert "rollback readback mismatch" in apply_block
assert "return kIOReturnError;" in apply_block
PY
echo "ThunderBridge rollback readback gate: PASS"

# A successful ClkCtrl write is not proof that the FPGA accepted the requested
# period. On a rate transition, a frame readback mismatch must leave DMA stopped
# and outputs muted instead of restarting with a false Core Audio timing tuple.
python3 - "$SOURCE_DIR/SymphonyThunderbridge.cpp" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text()
needle = 'STLOG("StartDevice: FPGA ClkCtrl readback=0x%08x frame=%u expected=%u",'
start = source.index(needle)
end = source.index("// 5. Clear stale interrupt status", start)
block = source[start:end]
assert "frameReadback != profile.frameSize" in block
assert "rateOk = false;" in block
assert "leaving DMA stopped + outputs muted" in block
PY
echo "ThunderBridge FPGA frame readback fail-closed gate: PASS"

# Every post-PCI initialization failure must unwind through the lifecycle-safe
# Stop path. A fall-through to RegisterService() would publish a partial driver
# and return success after DMA, IRQ, or stream setup failed.
python3 - "$SOURCE_DIR/SymphonyThunderbridge.cpp" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text()
start = source.index("kern_return_t IMPL(SymphonyThunderbridge, Start)")
end = source.index("// ── Interrupt Handler", start)
block = source[start:end]
assert "goto skip_audio;" not in block
assert "goto skip_dma;" not in block
failure = block.index("start_failure:")
failure_block = block[failure:]
assert "Stop(provider);" in failure_block
return_index = failure_block.index("return ret;")
register_index = failure_block.index("RegisterService();")
assert return_index < register_index
PY
echo "ThunderBridge Start failure cleanup gate: PASS"
