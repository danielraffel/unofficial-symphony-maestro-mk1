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
// Numbers continue from slot 1's channels of the same kind. The one-letter
// unit prefix the daemon put in front is not reproduced.
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
};

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
// "None" (236) is "N.A." as the original's unrouted channel. Any other source
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
        SymphonyBoardChannelName(s, true, board, ch, out, len);
        return true;
    }
    if (len) out[0] = 0;
    return false;
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
