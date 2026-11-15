// SymphonyChannelNames.h — the names Apogee's daemon gave each Symphony I/O
// channel, for the ThunderBridge driver to publish to Core Audio.
//
// Plain header (no DriverKit types) so Scripts/test-channel-names.sh compiles
// it on the host and checks the same table the app's CardLayout tests pin.
//
// The original published per-channel names (kAudioObjectPropertyElementName)
// for every host channel of the Symphony card: the name of the hardware
// channel the host channel is routed from (inputs) or to (outputs), "N.A."
// when there is none (og_source/maestrolink/Software/SymphonyCard.cpp:828-866,
// SymphonyCardStream.cpp:219-236). Each hardware channel's name follows the
// board, the rate, the optical format and S/PDIF Coax Replaces:
//   - analog: "Line n" (SymphonyIO_Stream.cpp:636-660)
//   - AES: "AES n" at every rate (AESIn_SymphonyIO_Stream.cpp:165-190)
//   - optical (OpticalIn_SymphonyIO_Stream.cpp:166-234,
//     OpticalOut_SymphonyIO_Stream.cpp:170-232,
//     Optical2x6Module_SymphonyIO_Streams.h):
//       176.4 kHz and up: "N.A."
//       S/PDIF: "SPDIF Opt n" for the first two channels of each 8-channel
//               input port / of the output stream, else "N.A."
//       88.2/96 kHz: "SMUX n" for the channels SMUX carries (all, or the
//               first four on the 2x6), else "N.A."
//       44.1/48 kHz: "ADAT n"
//   - an input pair the board's coax replaces: "SPDIF Cx n"
//     (SymphonyIO_IOBoard.cpp:1312-1349)
// Numbers continue from slot 1's channels of the same kind. Every name of a
// real board channel starts with the unit's one-letter peripheral prefix,
// "A Line 1", "A N.A." (`"%c Line %d"`, `"%c N.A."` with GetPrefix(), e.g.
// SymphonyIO_Stream.cpp:655, OpticalIn_SymphonyIO_Stream.cpp:194-225,
// SymphonyIO_IOBoard.cpp:1327); the letter is kept in the unit (vendor command
// 0x37, SymphonyIO.cpp:1245-1258) and anything outside A-Z there means "not
// assigned yet", which the daemon replaced with its default, "A" for the first
// unit. A host channel with no board channel behind it is a bare "N.A."
// (SymphonyCardStream.cpp:219-236).
#pragma once

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "SymphonyOptionBoard.h"

struct SymphonyNamingState {
    uint8_t  boardType[2];      // SymphonyIOOptionBoardType per slot
    bool     opticalIsSPDIF[2]; // optical format per slot (true = S/PDIF)
    uint8_t  coaxReplace[2];    // S/PDIF Coax Replaces wire value per slot, 0 = Off
    bool     boardKnown[2];     // the slot's type was read from the unit
    uint32_t sampleRate;        // Hz; 0 = unknown, named as 44.1/48 kHz
    uint8_t  prefix;            // peripheral prefix byte read from / written to the unit (0x37)
};

// The prefix letter names carry: the unit's byte when it is a letter A-Z,
// else "A", the daemon's default for the first unit.
static constexpr uint8_t kSymphonyCmdPrefix = 0x37;
static inline bool SymphonyIsPrefixLetter(uint8_t raw) { return raw >= 'A' && raw <= 'Z'; }
static inline char SymphonyPrefixLetter(uint8_t raw)
{
    return SymphonyIsPrefixLetter(raw) ? (char)raw : 'A';
}

// Per-board channel layout, matching the app's IOCardType counts.
struct SymphonyBoardLayout {
    uint8_t analog;   // analog channels
    uint8_t aes;      // AES channels (after analog)
    uint8_t optical;  // optical channels (after AES)
    bool    coax;     // has the S/PDIF coax pair
};

static inline SymphonyBoardLayout SymphonyBoardChannels(uint8_t type, bool isInput)
{
    switch (type) {
    case kSIOOptionBoard_AnalogAES:    return {8, 8, 0, true};
    case kSIOOptionBoard_Optical:      return {8, 0, 8, true};
    case kSIOOptionBoard_AnalogAD16:   return isInput ? SymphonyBoardLayout{16, 0, 0, true}
                                                      : SymphonyBoardLayout{0, 0, 16, true};
    case kSIOOptionBoard_AnalogDA16:   return isInput ? SymphonyBoardLayout{0, 0, 16, true}
                                                      : SymphonyBoardLayout{16, 0, 0, true};
    case kSIOOptionBoard_AnalogADDA16: return {16, 0, 0, true};
    case kSIOOptionBoard_TwoBySix:     return isInput ? SymphonyBoardLayout{2, 2, 8, true}
                                                      : SymphonyBoardLayout{6, 2, 8, true};
    default:                           return {0, 0, 0, false};   // empty, 8MicPre
    }
}

static constexpr const char *kSymphonyChannelNotApplicable = "N.A.";

// Name of channel `ch` (0..15) of board `board` (0/1). Returns false when the
// board has no such channel; `out` then holds "N.A.".
static inline bool SymphonyBoardChannelName(const SymphonyNamingState &s, bool isInput,
                                            unsigned board, unsigned ch,
                                            char *out, size_t len)
{
    snprintf(out, len, "%s", kSymphonyChannelNotApplicable);
    if (board > 1 || ch > 15) return false;
    const SymphonyBoardLayout b = SymphonyBoardChannels(s.boardType[board], isInput);
    if (ch >= (unsigned)(b.analog + b.aes + b.optical)) return false;
    const SymphonyBoardLayout prev = board == 1
        ? SymphonyBoardChannels(s.boardType[0], isInput) : SymphonyBoardLayout{0, 0, 0, false};

    // An input pair the coax replaces: board channels (wire - 1) * 2 and + 1.
    const unsigned wire = s.coaxReplace[board];
    if (isInput && b.coax && wire >= 1 && wire <= 8) {
        const unsigned left = (wire - 1) * 2;
        if (ch == left || ch == left + 1) {
            snprintf(out, len, "SPDIF Cx %u", (prev.coax ? 2u : 0u) + 1 + ch - left);
            return true;
        }
    }
    if (ch < b.analog) {
        snprintf(out, len, "Line %u", prev.analog + ch + 1);
        return true;
    }
    if (ch < (unsigned)(b.analog + b.aes)) {
        snprintf(out, len, "AES %u", prev.aes + ch - b.analog + 1);
        return true;
    }
    const unsigned n = ch - b.analog - b.aes + 1;   // 1-based optical channel
    const uint32_t rate = s.sampleRate ? s.sampleRate : 48000;
    if (rate >= 176400) return true;                 // "N.A."
    if (s.opticalIsSPDIF[board]) {
        const unsigned period = isInput ? 8 : (b.optical ? b.optical : 1);
        if ((n - 1) % period >= 2) return true;      // "N.A."
        snprintf(out, len, "SPDIF Opt %u", n % 8 + 2 * (n / 8) + prev.optical / 4);
        return true;
    }
    if (rate > 48000) {
        const unsigned smux = s.boardType[board] == kSIOOptionBoard_TwoBySix ? b.optical / 2 : b.optical;
        if (n - 1 >= smux) return true;              // "N.A."
        snprintf(out, len, "SMUX %u", prev.optical + n);
        return true;
    }
    snprintf(out, len, "ADAT %u", prev.optical + n);
    return true;
}

// Name of host INPUT channel `hostChannel` (0..31) whose Symphony routing
// source byte is `source` (the [dest, src] pairs of AudioRouting 0x31 for
// dest P2P 0xC0 + n). Board sources are IOBoard0 32-47 and IOBoard1 48-63;
// "None" (236) is a bare "N.A." as the original's unrouted channel. Any other source
// (a mixer bus, playback) returns false and gets no name of its own, and so
// does a board whose type has not been read: with no Symphony answering (the
// unit is off, or an older converter is on the cable) nothing is known about
// the channel, and Core Audio's own default name stays.
static constexpr uint8_t kSymphonyRoutingSourceIOBoard0 = 32;
static constexpr uint8_t kSymphonyRoutingSourceIOBoard1 = 48;
static constexpr uint8_t kSymphonyRoutingSourceNone     = 236;
static constexpr uint8_t kSymphonyRoutingDestP2P0       = 0xC0;

static inline bool SymphonyHostInputName(const SymphonyNamingState &s, uint8_t source,
                                         char *out, size_t len)
{
    if (source == kSymphonyRoutingSourceNone) {
        snprintf(out, len, "%s", kSymphonyChannelNotApplicable);
        return true;
    }
    if (source >= kSymphonyRoutingSourceIOBoard0 && source < kSymphonyRoutingSourceIOBoard0 + 32) {
        const unsigned board = (source - kSymphonyRoutingSourceIOBoard0) / 16;
        const unsigned ch = (source - kSymphonyRoutingSourceIOBoard0) % 16;
        if (!s.boardKnown[board]) {
            if (len) out[0] = 0;
            return false;
        }
        // A channel the board has gets the prefix, "A N.A." included; one it
        // does not have (an empty slot, past the card's inputs) is bare "N.A.".
        char base[24];
        if (SymphonyBoardChannelName(s, true, board, ch, base, sizeof(base)))
            snprintf(out, len, "%c %s", SymphonyPrefixLetter(s.prefix), base);
        else
            snprintf(out, len, "%s", kSymphonyChannelNotApplicable);
        return true;
    }
    if (len) out[0] = 0;
    return false;
}

// The capture table the driver programs at link configuration: which board
// channel feeds each of the 32 host inputs (P2P 0xC0 + n). The original laid
// the Mac's inputs out card by card at each card's real channel count (plugs
// per stream, sorted by board then start channel:
// SymphonyPCIeRoutingController.cpp:200-217, 849-866; NonCAStreamObject.cpp:
// 326-384; SymphonyIO_IOBoard.cpp:180-197). Every card has 16 inputs except
// the 2x6 (2 Line + 2 AES + 8 optical = 12), so slot 2 starts at host input 13
// behind a 2x6 and at 17 behind anything else.
//
// Two cases keep the fixed 16 where the original would have packed:
//   - slot 1's type was not read (no Symphony answering): nothing is known;
//   - slot 1 read as empty or Mic Pre (no inputs of its own): the original
//     would put slot 2 at host input 1, but that setup works here today with
//     slot 2 at 17-32, and moving it would move a working setup's inputs.
// Host inputs past slot 2's 16 are left on "None" (236), so none of them keeps
// an earlier table's route.
static inline unsigned SymphonySlot2InputBase(uint8_t slot1Type, bool slot1Known)
{
    if (!slot1Known) return 16;
    const SymphonyBoardLayout b = SymphonyBoardChannels(slot1Type, true);
    const unsigned n = (unsigned)(b.analog + b.aes + b.optical);
    return (n == 0 || n > 16) ? 16 : n;
}

static inline uint8_t SymphonyCaptureSource(uint8_t slot1Type, bool slot1Known, unsigned hostInput)
{
    const unsigned base = SymphonySlot2InputBase(slot1Type, slot1Known);
    if (hostInput < base) return (uint8_t)(kSymphonyRoutingSourceIOBoard0 + hostInput);
    if (hostInput < base + 16 && hostInput < 32)
        return (uint8_t)(kSymphonyRoutingSourceIOBoard1 + (hostInput - base));
    return kSymphonyRoutingSourceNone;
}

// Record the P2P input routes found in an AudioRouting (0x31) payload of
// [dest, src] pairs. Returns true when any host input's source changed.
static inline bool SymphonyNoteInputRoutes(uint8_t inputSource[32],
                                           const uint8_t *payload, uint16_t len)
{
    bool changed = false;
    if (!payload) return false;
    for (uint16_t i = 0; i + 1 < len; i += 2) {
        const uint8_t dest = payload[i];
        if (dest < kSymphonyRoutingDestP2P0 || dest >= kSymphonyRoutingDestP2P0 + 32) continue;
        uint8_t &slot = inputSource[dest - kSymphonyRoutingDestP2P0];
        if (slot != payload[i + 1]) { slot = payload[i + 1]; changed = true; }
    }
    return changed;
}

