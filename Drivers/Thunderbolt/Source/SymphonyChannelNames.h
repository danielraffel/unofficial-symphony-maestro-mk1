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
//
// This driver names host inputs after the board channel routed to them, as
// the original did, and host outputs after the board output at the same
// position in the unit's host channel order (analog first since dext 150),
// which the original did not (see SymphonyHostOutputName).
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

// The rate the names follow, in Hz, from Core Audio's nominal rate: the rate
// clients see and the next stream start programs. The driver keeps it in step
// with every nominal change (SymphonyAudioDevice::HandleChangeSampleRate), not
// only with a stream start's rate change, so a rate set while nothing runs IO
// still renames the optical channels. 0 (named as 44.1/48 kHz) when unknown.
static inline uint32_t SymphonyNamingRateHz(double nominalRate)
{
    return (nominalRate > 0.0 && nominalRate < 1000000.0) ? (uint32_t)(nominalRate + 0.5) : 0;
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

// ── The unit's host channel order (dext 150) ─────────────────────────────────
// The driver programs the unit's routing layer (vendor AudioRouting 0x31) so
// the Mac sees the unit's channels analog first, as Apogee's original did:
// every analog channel of slot 1 (board 0), then every analog channel of
// slot 2 (board 1), then slot 1's digital channels, then slot 2's, each
// board's digital channels in board channel order (AES before optical).
//
// Evidence (og_source/symphonymk1/ext/maestrolink/Software):
//   - SymphonyIO_Stream.cpp:138-185, SymphonyIO_Stream::operator<: a stream
//     of another type sorts after any analog stream
//     (ENABLE_DIGITAL_INPUT_OUPTUT_ORDERING is never defined); streams of the
//     same type, and AES against optical, fall through to
//     NonCAStreamObject::operator< (NonCAStreamObject.cpp:326-384): board
//     index (SymphonyIO_IOBoard.cpp:180-197), then start channel;
//   - SymphonyPCIeRoutingController.cpp:376-389 keeps the plugs sorted that
//     way, and ResetRouting (:849-952) routes host channel n to sorted
//     hardware plug n, inputs and outputs alike;
//   - SymphonyIO_IOBoard.cpp:1473-1475 (NumberPrecedingChannelsInUnit): the
//     unit's streams are ordered analog, AES, then optical, which is also each
//     board's own channel layout (SymphonyBoardChannels).
// It is the order of the USB default table (SymphonyIODefaultRouting in the
// app, SymphonyIOUSBAudioRoutingController.cpp:623-812) and of the app's
// routing grid columns (CardLayout.routingColumns).
//
// Builds up to 149 laid the inputs out card by card (slot 1's channels, then
// slot 2's: SymphonyCardByCardCaptureSource) and the outputs by position
// (XLink n to board n / 16, channel n % 16). Their comment said the original
// did the same; it had missed SymphonyIO_Stream::operator<.
//
// An empty slot and an 8MicPre contribute no channels (SymphonyBoardChannels
// returns none for them). When either slot's type was not read, or reads as a
// value this code does not know (above kSIOOptionBoard_TwoBySix), nothing is
// known about where the analog channels end, and the driver keeps the tables
// builds up to 149 programmed: capture card by card from slot 1's type,
// playback by position. The app's copies (SymphonyIODefaultRouting
// .thunderboltInputRoutes/.thunderboltOutputRoutes with order .analogFirst)
// fall back the same way when a slot is nil, and
// Scripts/golden/host-channel-order.txt pins both for every pair.

static constexpr uint8_t kSymphonyRoutingSourceXLink0 = 0x00;   // XLink RX 0 (host playback)
static constexpr uint8_t kSymphonyRoutingDestIOBoard0 = 32;     // board 0 output 0
static constexpr uint8_t kSymphonyRoutingDestIOBoard1 = 48;     // board 1 output 0

// Whether `type` is a SymphonyIOOptionBoardType this code knows the channels of.
static inline bool SymphonyBoardTypeRecognised(uint8_t type)
{
    return type <= kSIOOptionBoard_TwoBySix;
}

// Whether the analog-first order applies: both slots read, both of a known kind.
static inline bool SymphonyAnalogFirstApplies(const uint8_t type[2], const bool known[2])
{
    return known[0] && known[1] &&
           SymphonyBoardTypeRecognised(type[0]) && SymphonyBoardTypeRecognised(type[1]);
}

struct SymphonyBoardChannelRef {
    uint8_t board;   // 0 = slot 1, 1 = slot 2
    uint8_t ch;      // channel on the board, 0-15
};

// The board channels in host order (see above), for inputs or outputs.
// Returns how many there are (at most 32); `out` gets one entry each.
static inline unsigned SymphonyHostChannelOrder(const uint8_t type[2], bool isInput,
                                                SymphonyBoardChannelRef out[32])
{
    unsigned n = 0;
    const SymphonyBoardLayout b[2] = { SymphonyBoardChannels(type[0], isInput),
                                       SymphonyBoardChannels(type[1], isInput) };
    for (uint8_t board = 0; board < 2; board++)              // analog, slot 1 then slot 2
        for (uint8_t ch = 0; ch < b[board].analog && n < 32; ch++)
            out[n++] = { board, ch };
    for (uint8_t board = 0; board < 2; board++) {            // digital, slot 1 then slot 2
        const unsigned total = (unsigned)(b[board].analog + b[board].aes + b[board].optical);
        for (unsigned ch = b[board].analog; ch < total && ch < 16 && n < 32; ch++)
            out[n++] = { board, (uint8_t)ch };
    }
    return n;
}

// ── Builds up to 149 (and the fallback when a type is unknown) ──
// The capture table card by card: host input n from slot 1 channel n, then
// slot 2's channels from where slot 1's real inputs end (12 behind a 2x6, 16
// otherwise), the fixed 16 + 16 when slot 1's type was not read or slot 1 has
// no inputs of its own (empty, 8MicPre). Host inputs past slot 2's 16: None.
static inline unsigned SymphonyCardByCardSlot2InputBase(uint8_t slot1Type, bool slot1Known)
{
    if (!slot1Known) return 16;
    const SymphonyBoardLayout b = SymphonyBoardChannels(slot1Type, true);
    const unsigned n = (unsigned)(b.analog + b.aes + b.optical);
    return (n == 0 || n > 16) ? 16 : n;
}

static inline uint8_t SymphonyCardByCardCaptureSource(uint8_t slot1Type, bool slot1Known, unsigned hostInput)
{
    const unsigned base = SymphonyCardByCardSlot2InputBase(slot1Type, slot1Known);
    if (hostInput < base) return (uint8_t)(kSymphonyRoutingSourceIOBoard0 + hostInput);
    if (hostInput < base + 16 && hostInput < 32)
        return (uint8_t)(kSymphonyRoutingSourceIOBoard1 + (hostInput - base));
    return kSymphonyRoutingSourceNone;
}

// ── The tables the driver programs ──
// The capture table (P2P 0xC0 + n, step 19b-2 and ConfigureUnitB): host input
// n from the n-th board input in host order, None (236) past the unit's real
// inputs, so no host input keeps an earlier table's route. Card by card when
// a type is unknown (above).
static inline uint8_t SymphonyCaptureSource(const uint8_t type[2], const bool known[2], unsigned hostInput)
{
    if (!SymphonyAnalogFirstApplies(type, known))
        return SymphonyCardByCardCaptureSource(type[0], known[0] && SymphonyBoardTypeRecognised(type[0]),
                                               hostInput);
    SymphonyBoardChannelRef order[32];
    const unsigned count = SymphonyHostChannelOrder(type, true, order);
    if (hostInput >= count) return kSymphonyRoutingSourceNone;
    return (uint8_t)(kSymphonyRoutingSourceIOBoard0 + order[hostInput].board * 16 + order[hostInput].ch);
}

// The playback table (steps 19b-1 / 19b-1b and ConfigureUnitB): the source
// of board `board` output `ch`. The n-th board output in host order plays
// XLink n (which the card's default route feeds from host playback n, step
// 21b); a board output with no host channel behind it (an empty slot, past a
// card's outputs) plays None. By position (XLink board * 16 + ch) when a type
// is unknown, as builds up to 149 did for every unit.
static inline uint8_t SymphonyPlaybackSource(const uint8_t type[2], const bool known[2],
                                             unsigned board, unsigned ch)
{
    if (board > 1 || ch > 15) return kSymphonyRoutingSourceNone;
    if (!SymphonyAnalogFirstApplies(type, known))
        return (uint8_t)(kSymphonyRoutingSourceXLink0 + board * 16 + ch);
    SymphonyBoardChannelRef order[32];
    const unsigned count = SymphonyHostChannelOrder(type, false, order);
    for (unsigned n = 0; n < count; n++)
        if (order[n].board == board && order[n].ch == ch)
            return (uint8_t)(kSymphonyRoutingSourceXLink0 + n);
    return kSymphonyRoutingSourceNone;
}

// The board output Mac (host) OUTPUT `hostOutput` (0-based) plays through
// when nothing has re-routed it, by the table above: the n-th board output in
// host order, or by position (board n / 16, channel n % 16) when a type is
// unknown. Returns false past the 32, and past the unit's real outputs when
// the order applies (no board output behind it).
static inline bool SymphonyHostOutputBoardChannel(const uint8_t type[2], const bool known[2],
                                                  unsigned hostOutput, unsigned *board, unsigned *ch)
{
    if (hostOutput >= 32) return false;
    if (!SymphonyAnalogFirstApplies(type, known)) {
        *board = hostOutput / 16;
        *ch = hostOutput % 16;
        return true;
    }
    SymphonyBoardChannelRef order[32];
    if (hostOutput >= SymphonyHostChannelOrder(type, false, order)) return false;
    *board = order[hostOutput].board;
    *ch = order[hostOutput].ch;
    return true;
}

// Name of host OUTPUT channel `hostOutput` (0..31). A deliberate departure
// from the original, which renamed each host output after the hardware
// channel it was routed to (SymphonyCard.cpp:850-862), "N.A." when it reached
// none: Mac outputs keep fixed names from their position (owner decision,
// 2026-11-23), the name of the board output the driver's own table plays
// them through (SymphonyHostOutputBoardChannel), which since dext 150 is the
// n-th board output in host order, so the names read analog first. With the
// prefix letter, "A N.A." included, as the Output tab names that output. They
// do not follow the card's output routes or mixer. A host output with no
// board output behind it (an empty slot, past the unit's outputs) is a bare
// "N.A."; one whose board was never read, or a channel past the 32, gets no
// name (returns false).
static inline bool SymphonyHostOutputName(const SymphonyNamingState &s, unsigned hostOutput,
                                          char *out, size_t len)
{
    unsigned board = 0, ch = 0;
    if (hostOutput >= 32) {
        if (len) out[0] = 0;
        return false;
    }
    if (!SymphonyHostOutputBoardChannel(s.boardType, s.boardKnown, hostOutput, &board, &ch)) {
        snprintf(out, len, "%s", kSymphonyChannelNotApplicable);   // past the unit's outputs
        return true;
    }
    if (!s.boardKnown[board]) {
        if (len) out[0] = 0;
        return false;
    }
    char base[24];
    if (SymphonyBoardChannelName(s, false, board, ch, base, sizeof(base)))
        snprintf(out, len, "%c %s", SymphonyPrefixLetter(s.prefix), base);
    else
        snprintf(out, len, "%s", kSymphonyChannelNotApplicable);
    return true;
}

// The 8MicPre channel (0-7) behind a capture source, for ResolveMicPreRoute.
// The 8MicPre (slot 2 only, MicPreChannelsForSlots) puts its preamps in front
// of slot 1's analog inputs 1-8 (SymphonyIO.cpp:955-961,
// SymphonyIO_IOBoard.cpp:606-627, SymphonyIOBoard_MicPre8ch.cpp:337-361), so a
// host input reaches MicPre channel c only when its capture source is board 0
// channel c and that channel is one of slot 1's analog inputs, not an AES or
// optical channel (a 2x6 has 2 analog inputs, an A16 OP none) and not a pair
// S/PDIF Coax Replaces has taken. When slot 1's type is not known, any board 0
// channel 1-8 is taken as analog, as before dext 150.
static inline bool SymphonyMicPreChannelForSource(uint8_t source, uint8_t board0Type, bool board0Known,
                                                  uint8_t coaxReplace, uint32_t *channel)
{
    if (source < kSymphonyRoutingSourceIOBoard0 || source >= kSymphonyRoutingSourceIOBoard0 + 8)
        return false;
    const uint32_t c = (uint32_t)(source - kSymphonyRoutingSourceIOBoard0);
    const bool typed = board0Known && SymphonyBoardTypeRecognised(board0Type);
    const SymphonyBoardLayout b = SymphonyBoardChannels(typed ? board0Type : kSIOOptionBoard_None, true);
    if (typed && c >= b.analog) return false;
    if (b.coax && coaxReplace >= 1 && coaxReplace <= 8 && c / 2 == (uint32_t)(coaxReplace - 1))
        return false;
    *channel = c;
    return true;
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

