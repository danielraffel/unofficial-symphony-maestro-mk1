#!/bin/bash
# Host test for SymphonyChannelNames.h: the per-channel names the driver
# publishes to Core Audio. The table matches the app's CardLayout tests
# (ChannelNamingTests), which pin the same names to Apogee's daemon.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIR="$(cd "$SCRIPT_DIR/../Source" && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/test.cpp" <<'CPP'
#include <cassert>
#include <cstdio>
#include <cstring>
#include "SymphonyChannelNames.h"

static int failures = 0;

static void expectName(const SymphonyNamingState &s, bool in, unsigned board, unsigned ch,
                       const char *want, int line)
{
    char got[32];
    SymphonyBoardChannelName(s, in, board, ch, got, sizeof(got));
    if (strcmp(got, want) != 0) {
        fprintf(stderr, "line %d: board %u ch %u %s: got \"%s\", want \"%s\"\n",
                line, board, ch, in ? "in" : "out", got, want);
        failures++;
    }
}
#define NAME(s, in, b, c, want) expectName(s, in, b, c, want, __LINE__)

static SymphonyNamingState state(uint8_t t0, uint8_t t1, uint32_t rate = 0,
                                 bool spdif0 = false, bool spdif1 = false,
                                 uint8_t cx0 = 0, uint8_t cx1 = 0)
{
    SymphonyNamingState s = {};
    s.boardType[0] = t0; s.boardType[1] = t1;
    s.boardKnown[0] = s.boardKnown[1] = true;   // both slots' types were read
    s.opticalIsSPDIF[0] = spdif0; s.opticalIsSPDIF[1] = spdif1;
    s.coaxReplace[0] = cx0; s.coaxReplace[1] = cx1;
    s.sampleRate = rate;
    return s;
}

int main() {
    // 8x8 Optical: Line 1-8 then ADAT / SMUX / N.A. by rate.
    auto opt48 = state(kSIOOptionBoard_Optical, kSIOOptionBoard_None, 48000);
    NAME(opt48, true, 0, 0, "Line 1");
    NAME(opt48, true, 0, 8, "ADAT 1");
    NAME(opt48, false, 0, 15, "ADAT 8");
    auto opt96 = state(kSIOOptionBoard_Optical, kSIOOptionBoard_None, 96000);
    NAME(opt96, true, 0, 15, "SMUX 8");
    auto opt192 = state(kSIOOptionBoard_Optical, kSIOOptionBoard_None, 192000);
    NAME(opt192, true, 0, 8, "N.A.");
    NAME(opt192, true, 0, 7, "Line 8");
    // Unknown rate names as 44.1/48 kHz.
    NAME(state(kSIOOptionBoard_Optical, 0), true, 0, 8, "ADAT 1");

    // S/PDIF format.
    auto optSPDIF = state(kSIOOptionBoard_Optical, 0, 44100, true);
    NAME(optSPDIF, true, 0, 8, "SPDIF Opt 1");
    NAME(optSPDIF, true, 0, 9, "SPDIF Opt 2");
    NAME(optSPDIF, true, 0, 10, "N.A.");
    NAME(state(kSIOOptionBoard_Optical, 0, 176400, true), true, 0, 8, "N.A.");
    // A16 OP inputs: channels 1-2 and 9-10 of the 16.
    auto da16 = state(kSIOOptionBoard_AnalogDA16, 0, 48000, true);
    NAME(da16, true, 0, 0, "SPDIF Opt 1");
    NAME(da16, true, 0, 8, "SPDIF Opt 3");
    NAME(da16, true, 0, 9, "SPDIF Opt 4");
    NAME(da16, true, 0, 2, "N.A.");
    NAME(da16, false, 0, 0, "Line 1");
    // A16 IP outputs: only the first pair (outputs test against all 16).
    auto ad16 = state(kSIOOptionBoard_AnalogAD16, 0, 48000, true);
    NAME(ad16, false, 0, 1, "SPDIF Opt 2");
    NAME(ad16, false, 0, 8, "N.A.");
    NAME(ad16, true, 0, 15, "Line 16");

    // 2x6: one optical port, so four SMUX channels at 96k; AES at every rate.
    auto twoBySix96 = state(kSIOOptionBoard_TwoBySix, 0, 96000);
    NAME(twoBySix96, true, 0, 1, "Line 2");
    NAME(twoBySix96, true, 0, 2, "AES 1");
    NAME(twoBySix96, true, 0, 4, "SMUX 1");
    NAME(twoBySix96, true, 0, 7, "SMUX 4");
    NAME(twoBySix96, true, 0, 8, "N.A.");
    NAME(twoBySix96, false, 0, 6, "AES 1");
    NAME(state(kSIOOptionBoard_TwoBySix, 0, 192000), false, 0, 7, "AES 2");
    NAME(state(kSIOOptionBoard_TwoBySix, 0, 48000), true, 0, 12, "N.A.");   // past the 12 inputs

    // Slot 2 numbers on from slot 1, per kind.
    auto twoOpt = state(kSIOOptionBoard_Optical, kSIOOptionBoard_Optical, 48000);
    NAME(twoOpt, true, 1, 0, "Line 9");
    NAME(twoOpt, true, 1, 8, "ADAT 9");
    NAME(state(kSIOOptionBoard_Optical, kSIOOptionBoard_Optical, 48000, false, true),
         true, 1, 8, "SPDIF Opt 3");
    // Owner's unit: combo (AES position) + A16 IP.
    auto owner = state(kSIOOptionBoard_AnalogAES, kSIOOptionBoard_AnalogAD16, 48000);
    NAME(owner, true, 0, 8, "AES 1");
    NAME(owner, true, 1, 0, "Line 9");
    NAME(owner, false, 1, 0, "ADAT 1");     // AES board has no optical outputs
    NAME(owner, false, 0, 15, "AES 8");

    // Coax Replaces renames the replaced input pair, never an output.
    auto cxAES = state(kSIOOptionBoard_AnalogAES, kSIOOptionBoard_AnalogAD16, 48000, false, false, 5, 1);
    NAME(cxAES, true, 0, 8, "SPDIF Cx 1");
    NAME(cxAES, true, 0, 9, "SPDIF Cx 2");
    NAME(cxAES, true, 0, 10, "AES 3");
    NAME(cxAES, false, 0, 8, "AES 1");
    NAME(cxAES, true, 1, 0, "SPDIF Cx 3");
    NAME(cxAES, true, 1, 1, "SPDIF Cx 4");
    NAME(state(kSIOOptionBoard_TwoBySix, 0, 48000, false, false, 3), true, 0, 4, "SPDIF Cx 1");

    // Empty slot and 8MicPre have no channels.
    NAME(state(kSIOOptionBoard_Optical, kSIOOptionBoard_MicPre8), true, 1, 0, "N.A.");
    char buf[32];
    assert(!SymphonyBoardChannelName(state(0, 0), true, 0, 0, buf, sizeof(buf)));

    // Host inputs follow the capture route: P2P n <- source byte.
    assert(SymphonyHostInputName(owner, 32 + 8, buf, sizeof(buf)) && !strcmp(buf, "A AES 1"));
    assert(SymphonyHostInputName(owner, 48 + 3, buf, sizeof(buf)) && !strcmp(buf, "A Line 12"));
    assert(SymphonyHostInputName(owner, kSymphonyRoutingSourceNone, buf, sizeof(buf)) && !strcmp(buf, "N.A."));
    assert(!SymphonyHostInputName(owner, 64, buf, sizeof(buf)));   // a mixer bus: no name of its own

    // The original named an unrouted or empty channel "N.A."
    // (SymphonyCardStream.cpp:219-236): a slot read as empty is that.
    auto single = state(kSIOOptionBoard_AnalogADDA16, kSIOOptionBoard_None, 48000);
    assert(SymphonyHostInputName(single, 32 + 15, buf, sizeof(buf)) && !strcmp(buf, "A Line 16"));
    assert(SymphonyHostInputName(single, 48, buf, sizeof(buf)) && !strcmp(buf, "N.A."));
    // A slot whose type was never read (no Symphony answering: the unit is
    // off, or an older converter is on the cable) gets no name at all, so
    // Core Audio keeps its own instead of 32 channels called "N.A.".
    auto unread = state(0, 0, 48000);
    unread.boardKnown[0] = unread.boardKnown[1] = false;
    for (unsigned src = 32; src < 64; src++) {
        strcpy(buf, "stale");
        assert(!SymphonyHostInputName(unread, (uint8_t)src, buf, sizeof(buf)) && buf[0] == 0);
    }
    // One slot read, the other not: only the read one is named.
    auto half = state(kSIOOptionBoard_Optical, 0, 48000);
    half.boardKnown[1] = false;
    assert(SymphonyHostInputName(half, 32, buf, sizeof(buf)) && !strcmp(buf, "A Line 1"));
    assert(!SymphonyHostInputName(half, 48, buf, sizeof(buf)));

    // Peripheral prefix (0x37): every real board channel starts with the
    // unit's letter, "A N.A." included; no channel behind it is bare "N.A.".
    // The user's unit: 8x8 on optical with S/PDIF in slot 1, A16 IP in slot 2.
    auto user = state(kSIOOptionBoard_Optical, kSIOOptionBoard_AnalogAD16, 48000, true);
    assert(SymphonyHostInputName(user, 32 + 8, buf, sizeof(buf)) && !strcmp(buf, "A SPDIF Opt 1"));
    assert(SymphonyHostInputName(user, 32 + 10, buf, sizeof(buf)) && !strcmp(buf, "A N.A."));
    assert(SymphonyHostInputName(user, 48 + 15, buf, sizeof(buf)) && !strcmp(buf, "A Line 24"));
    assert(SymphonyHostInputName(user, kSymphonyRoutingSourceNone, buf, sizeof(buf)) && !strcmp(buf, "N.A."));
    user.prefix = 'C';
    assert(SymphonyHostInputName(user, 32, buf, sizeof(buf)) && !strcmp(buf, "C Line 1"));
    assert(SymphonyHostInputName(single, 48, buf, sizeof(buf)) && !strcmp(buf, "N.A."));   // empty slot: no letter
    user.prefix = 0xFF;   // never assigned on the unit: the daemon's default
    assert(SymphonyHostInputName(user, 32, buf, sizeof(buf)) && !strcmp(buf, "A Line 1"));
    assert(SymphonyIsPrefixLetter('A') && SymphonyIsPrefixLetter('Z'));
    assert(!SymphonyIsPrefixLetter('a') && !SymphonyIsPrefixLetter('@') && !SymphonyIsPrefixLetter('['));
    assert(SymphonyPrefixLetter(0) == 'A' && SymphonyPrefixLetter('Q') == 'Q');

    // Session Replaces / Mirrors go back only to the type of card they were
    // chosen for: the same wire value names another pair on another card.
    static_assert(ReplaysCoaxSettings(true, kSIOOptionBoard_Optical, kSIOOptionBoard_Optical), "same card");
    static_assert(!ReplaysCoaxSettings(true, kSIOOptionBoard_AnalogADDA16, kSIOOptionBoard_Optical), "card swapped");
    static_assert(!ReplaysCoaxSettings(true, kSIOOptionBoard_AnalogAES, kSIOOptionBoard_Optical), "DIG I/O switch moved");
    static_assert(!ReplaysCoaxSettings(false, kSIOOptionBoard_Optical, kSIOOptionBoard_Optical), "type not read");
    static_assert(!ReplaysCoaxSettings(true, kSIOOptionBoard_None, kSIOOptionBoard_None), "nothing set this session");

    // AudioRouting payloads: only P2P destinations are noted.
    uint8_t sources[32];
    for (int n = 0; n < 32; n++) sources[n] = (uint8_t)(32 + n);
    const uint8_t toOutputs[] = { 32, 0, 33, 1 };          // board outputs: ignored
    assert(!SymphonyNoteInputRoutes(sources, toOutputs, sizeof(toOutputs)));
    const uint8_t swap[] = { 0xC0, 33, 0xC1, 32, 0xC2, 34 }; // P2P 0/1 swapped, P2P 2 unchanged
    assert(SymphonyNoteInputRoutes(sources, swap, sizeof(swap)));
    assert(sources[0] == 33 && sources[1] == 32 && sources[2] == 34);
    const uint8_t odd[] = { 0xC3 };                       // a lone byte is not a pair
    assert(!SymphonyNoteInputRoutes(sources, odd, sizeof(odd)));

    // Capture table, card by card (SymphonyCaptureSource): slot 2 starts
    // where slot 1's real inputs end. Per slot-1 case:
    struct { uint8_t type; bool known; unsigned base; } bases[] = {
        { kSIOOptionBoard_None,         false, 16 },   // not read: fixed 16 + 16
        { kSIOOptionBoard_None,         true,  16 },   // empty: kept at 16 (works today)
        { kSIOOptionBoard_MicPre8,      true,  16 },
        { kSIOOptionBoard_AnalogAES,    true,  16 },
        { kSIOOptionBoard_Optical,      true,  16 },
        { kSIOOptionBoard_AnalogAD16,   true,  16 },
        { kSIOOptionBoard_AnalogDA16,   true,  16 },
        { kSIOOptionBoard_AnalogADDA16, true,  16 },
        { kSIOOptionBoard_TwoBySix,     true,  12 },
    };
    for (const auto &c : bases) {
        assert(SymphonySlot2InputBase(c.type, c.known) == c.base);
        for (unsigned n = 0; n < 32; n++) {
            const uint8_t want = n < c.base ? (uint8_t)(32 + n)
                               : n < c.base + 16 ? (uint8_t)(48 + n - c.base)
                               : kSymphonyRoutingSourceNone;
            assert(SymphonyCaptureSource(c.type, c.known, n) == want);
        }
    }

    // Register trace: the Symphony is off at Start, so the table goes out (or
    // is assumed) as 16 + 16; on link recovery the types are read (2x6 + A16
    // IP) and the table changes mid-session. The dext sends two 0x31 requests
    // of 16 [dest, src] pairs (step 19b-2); the unit keeps every destination
    // it is not sent, so all 32 must be in them.
    {
        uint8_t unit[32];                          // the Symphony's P2P sources
        uint8_t tracked[32];                       // the dext's inputRouteSource
        auto configure = [&](uint8_t t0, bool k0) {
            for (int half = 0; half < 2; half++) {
                uint8_t payload[32];
                for (int n = 0; n < 16; n++) {
                    const unsigned host = (unsigned)(half * 16 + n);
                    payload[n * 2] = (uint8_t)(kSymphonyRoutingDestP2P0 + host);
                    payload[n * 2 + 1] = SymphonyCaptureSource(t0, k0, host);
                }
                for (int i = 0; i < 32; i += 2) unit[payload[i] - kSymphonyRoutingDestP2P0] = payload[i + 1];
            }
            for (unsigned n = 0; n < 32; n++) tracked[n] = SymphonyCaptureSource(t0, k0, n);
        };
        configure(kSIOOptionBoard_None, false);    // Start, nothing read
        assert(unit[16] == 48 && unit[31] == 63);
        configure(kSIOOptionBoard_TwoBySix, true); // link recovery, types read
        assert(!memcmp(unit, tracked, sizeof(unit)));
        assert(unit[11] == 43 && unit[12] == 48 && unit[27] == 63);
        for (int n = 28; n < 32; n++) assert(unit[n] == kSymphonyRoutingSourceNone);   // no stale 16 + 16 routes
        auto pack = state(kSIOOptionBoard_TwoBySix, kSIOOptionBoard_AnalogAD16, 48000);
        assert(SymphonyHostInputName(pack, tracked[11], buf, sizeof(buf)) && !strcmp(buf, "A ADAT 8"));
        assert(SymphonyHostInputName(pack, tracked[12], buf, sizeof(buf)) && !strcmp(buf, "A Line 3"));
        assert(SymphonyHostInputName(pack, tracked[27], buf, sizeof(buf)) && !strcmp(buf, "A Line 18"));
        assert(SymphonyHostInputName(pack, tracked[28], buf, sizeof(buf)) && !strcmp(buf, "N.A."));
        // Back to an 8x8 (card swapped while off): 16 + 16 again, nothing left over.
        configure(kSIOOptionBoard_Optical, true);
        assert(unit[12] == 44 && unit[16] == 48 && unit[31] == 63);
    }

    if (failures) { fprintf(stderr, "%d channel-name failures\n", failures); return 1; }
    return 0;
}
CPP

clang++ -std=c++17 -Wall -Wextra -Werror -I "$SOURCE_DIR" "$TMP_DIR/test.cpp" -o "$TMP_DIR/test"
"$TMP_DIR/test"

# The driver publishes them and republishes on the events that rename channels.
grep -q 'SetElementName(n + 1, IOUserAudioObjectPropertyScope::Input' "$SOURCE_DIR/SymphonyThunderbridge.cpp"
for hook in 'hardware now at' 'RequestOpticalFormat: board=%u fmt=%u' 'namesChanged' 'kSIOCmd_SPDIFCoaxReplaceInput && value < 2' 'command == kSymphonyCmdPrefix && payload && payloadLen == 1' 's.prefix = __atomic_load_n(&ivars->namingPrefix'; do
    grep -q "$hook" "$SOURCE_DIR/SymphonyThunderbridge.cpp"
done
echo "ThunderBridge channel names: PASS"

# A link recovery re-sends this session's optical format, Replaces and
# Mirrors instead of resetting the optical ports to ADAT.
grep -q 'pendingOpticalFmt\[b\], __ATOMIC_ACQUIRE) ? 1 : 0' "$SOURCE_DIR/SymphonyThunderbridge.cpp"
grep -q 'kSIOCmd_SPDIFCoaxMirrorOutput, b, &mirror, 1, txSeq' "$SOURCE_DIR/SymphonyThunderbridge.cpp"
grep -q 'sessionCoaxMirror\[value\], payload\[0\]' "$SOURCE_DIR/SymphonyThunderbridge.cpp"
if grep -q 'adatMode' "$SOURCE_DIR/SymphonyThunderbridge.cpp"; then
    echo "FAIL: the link configuration still forces ADAT" >&2; exit 1
fi
# ... and Replaces / Mirrors only to the card type they were chosen for.
python3 - "$SOURCE_DIR/SymphonyThunderbridge.cpp" <<'PY'
import sys
from pathlib import Path
src = Path(sys.argv[1]).read_text()
boot = src[src.index("19b-0c. Set optical format"):src.index("19b-1. Playback routing")]
gate = boot.index("ReplaysCoaxSettings(slotTypeOK[b], slotType[b], setFor)")
assert gate < boot.index("kSIOCmd_SPDIFCoaxReplaceInput, b, &replace")
assert gate < boot.index("kSIOCmd_SPDIFCoaxMirrorOutput, b, &mirror")
assert src.count("NoteCoaxBoardType(ivars, value);") == 3   # 0x35 write, 0x36 write, 0x35 read
# A channel is renamed only when its name changes, and an unread slot is not named.
publish = src[src.index("static void PublishChannelNames"):src.index("static void ScheduleChannelNames")]
assert "s.boardKnown[b] = ivars->optionBoardTypeValid[b];" in publish
assert publish.index("strncmp(name, ivars->publishedInputName[n]") < publish.index("SetElementName(")
# The capture table is laid out from slot 1's type read in the same link
# configuration (Start and link recovery both run ConfigureSymphonyLink), all
# 32 destinations through SymphonyCaptureSource, and the tracked sources
# follow the table actually sent.
link = src[src.index("static bool ConfigureSymphonyLink"):src.index("// ── Status LED: link OK")]
read = link.index("kSIOCmd_OptionBoardType")
cap = link.index("19b-2. Capture")
assert read < cap
capture = link[cap:link.index("19b-3. Mute mixer")]
assert "SymphonyCaptureSource(slot1Type, slot1Known, host)" in capture
assert "for (int half = 0; half < 2; half++)" in capture and "for (int n = 0; n < 16; n++)" in capture
assert "kSIOSrc_IOBoard0Ch0 + n" not in capture and "kSIOSrc_IOBoard1Ch0 + n" not in capture
assert capture.index("SendVendorRequest") < capture.index("ResetInputRouteSources(ivars, slot1Type, slot1Known);")
assert link.index("ResetInputRouteSources(ivars, kSIOOptionBoard_None, false);") < read
assert src.count("ConfigureSymphonyLink(ivars,") == 2
# The prefix is read where the board types are, at Start and on link recovery.
assert src.count("ReadNamingPrefix(ivars, ivars->runtimeTxSeq);") == 2
PY
echo "ThunderBridge session digital settings replay: PASS"
