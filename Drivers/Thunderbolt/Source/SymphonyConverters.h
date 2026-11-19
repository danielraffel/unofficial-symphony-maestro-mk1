// SymphonyConverters.h — what Apogee's software did for the older XLink
// converters (AD-16X, DA-16X, DD-16X, Rosetta 800/200) on a ThunderBridge or
// Symphony 64 PCIe card: how each unit is identified, which bus slots its
// channels occupy, what its channels are called and how much latency it adds.
//
// Plain header (no DriverKit types) so Scripts/test-converters.sh compiles it on
// the host, and the app's ConnectedUnit tests pin the same vectors.
//
// Evidence (og_source):
//   identity      symphonymk1/ext/Symphony64/SymphonyAPI/XLinkRegisters.h:256-295,
//                 409-450 (CONVERT_ROUTING_COMMANDS_TO_NEW_FORMAT, DEVICE_ROUTING_*);
//                 Driver/XLink.cpp:1449-1548 (routing, firmware major/minor)
//   placement     maestrolink/Software/SymphonyPCIeRoutingController.cpp:964-1210,
//                 1850-1910 (see ConverterHostMap)
//   names         maestrolink/Software/SymphonyPeripheralDevice.cpp:707-735 (prefix
//                 letter 'A' + the unit's index among all units), :823-878 (formats),
//                 SymphonyCard.cpp:828-866 ("N.A." for a host channel with nothing
//                 behind it)
//   streams       SymphonyPeripheralDevice.cpp:96-188 (channels per unit)
//   latency       SymphonyPeripheralDevice.cpp:1083-1150
#pragma once

#include <stdint.h>
#include <stdio.h>
#include <string.h>

// Routing byte: (XTD_INQUIRE & 0xF0) | (INQUIRE >> 4). Bits 0,1,4,5 are 8-channel
// input banks, bits 2,3,6,7 output banks. 0 = no unit.
static constexpr uint8_t kConverterRoutingRosetta = 0x05;   // Rosetta 800 (or 200)
static constexpr uint8_t kConverterRoutingAD      = 0x03;   // AD-16X
static constexpr uint8_t kConverterRoutingDA      = 0x0C;   // DA-16X
static constexpr uint8_t kConverterRoutingDD      = 0x0F;   // DD-16X, or AD/DA-16X in Advanced routing
static constexpr uint8_t kConverterRoutingSymphony = 0xFF;  // Symphony I/O (Sym2Sym)

static constexpr uint32_t kConverterMaxUnitsPerPort = 4;    // XLINK_MAX_DEVICES
static constexpr uint32_t kConverterChannelsPerPort = 32;   // MAX_SYMPHONY_CHANNELS_ON_BUS

static inline uint8_t ConverterRouting(uint8_t inquire, uint8_t xtd)
{
    return (uint8_t)((xtd & 0xF0) | (inquire >> 4));
}

// What a unit is, after the user's Device Type choice for the two ambiguous
// routings (the original's "Device Type" menu: m_fDD16XIsAD16, default true,
// and the R800/R200 choice, default R800).
enum ConverterKind : uint8_t {
    kConverterNone = 0,
    kConverterRosetta,      // 8 in, 8 out (Rosetta 800, or 200)
    kConverterAD16X,        // 16 in
    kConverterDA16X,        // 16 out
    kConverterDDAsAD,       // routing 0x0F treated as AD: 16 analog in, 16 digital out
    kConverterDDAsDA,       // routing 0x0F treated as DA: 16 digital in, 16 analog out
    kConverterUnknown,      // answered with banks we do not recognise
};

static inline ConverterKind ConverterKindForRouting(uint8_t routing, bool ddIsAD = true)
{
    switch (routing) {
    case kConverterRoutingRosetta: return kConverterRosetta;
    case kConverterRoutingAD:      return kConverterAD16X;
    case kConverterRoutingDA:      return kConverterDA16X;
    case kConverterRoutingDD:      return ddIsAD ? kConverterDDAsAD : kConverterDDAsDA;
    case 0:                        return kConverterNone;
    default:                       return kConverterUnknown;
    }
}

static inline void ConverterChannels(ConverterKind k, uint32_t *inputs, uint32_t *outputs)
{
    uint32_t i = 0, o = 0;
    switch (k) {
    case kConverterRosetta: i = 8;  o = 8;  break;
    case kConverterAD16X:   i = 16; o = 0;  break;
    case kConverterDA16X:   i = 0;  o = 16; break;
    case kConverterDDAsAD:
    case kConverterDDAsDA:  i = 16; o = 16; break;
    default: break;
    }
    *inputs = i; *outputs = o;
}

// Where each unit's channels go. Apogee's routing layer (maestrolink
// SymphonyPCIeRoutingController.cpp routeSymphonyHW :964-1210 and
// GetRoutedToSymphonyInputChannelPreRouting :1866-1910) did two things:
//   - the host (DAW) channels are packed per direction across the whole system,
//     port 1's units then port 2's, nearest first (default route source i -> host
//     channel i, :1850-1855);
//   - each unit channel is placed on a bus slot of its port from the channel
//     totals of the units before it on that port (pIn, pOut), with the offsets
//     Apogee found by experiment ("Symphony64 doesn't like having a 8 channel
//     interval between other 16 channel devices"):
//       input  slot = pIn + e, + 8 when the unit has 16 inputs and pIn == 8,
//                    else + pOut when pIn == 0 and pOut > 0 (a DA-16X first);
//       output slot = pOut + e, or 16 + e when the unit has 16 outputs and pOut
//                    == 8, else + 16 when the unit has 8 outputs, pOut == 0 and
//                    pIn == 16.
//   Apogee's comments note that DA,R800,R800 and AD,R800,R800 put the last
//   Rosetta in the wrong place; the rule is copied as shipped.
// A channel whose slot would fall outside the port's 32 is not routed.
struct ConverterChain {
    ConverterKind kind[2][kConverterMaxUnitsPerPort];   // [port][unit], nearest first
    uint32_t      count[2];                             // units per port (port 2: 0 unless 64 runs)
};

struct ConverterChannel {
    uint8_t valid;      // 1 when this host channel carries a unit channel
    uint8_t port;       // 0 or 1
    uint8_t slot;       // 0-31 on that port
    uint8_t unit;       // index over all units: port 1's first, then port 2's (prefix 'A' + unit)
    uint8_t element;    // 0-based channel within the unit
};

static constexpr uint32_t kConverterMaxHostChannels = 64;

// Fills map[0..63] for one direction; returns the number of host channels used.
static inline uint32_t ConverterHostMap(const ConverterChain &c, bool input, ConverterChannel *map)
{
    for (uint32_t h = 0; h < kConverterMaxHostChannels; h++) map[h] = ConverterChannel{};
    uint32_t host = 0, unitIndex = 0;
    for (uint32_t port = 0; port < 2; port++) {
        uint32_t pIn = 0, pOut = 0;
        const uint32_t n = c.count[port] < kConverterMaxUnitsPerPort ? c.count[port] : kConverterMaxUnitsPerPort;
        for (uint32_t u = 0; u < n; u++, unitIndex++) {
            uint32_t a = 0, d = 0;
            ConverterChannels(c.kind[port][u], &a, &d);
            const uint32_t count = input ? a : d;
            uint32_t base;
            if (input) {
                base = pIn;
                if (a == 16 && pIn == 8) base += 8;
                else if (pIn == 0 && pOut > 0) base += pOut;
            } else {
                base = pOut;
                if (d == 16 && pOut == 8) base = 16;
                else if (d == 8 && pOut == 0 && pIn == 16) base += 16;
            }
            for (uint32_t e = 0; e < count && host < kConverterMaxHostChannels; e++, host++) {
                const uint32_t slot = base + e;
                if (slot >= kConverterChannelsPerPort) continue;   // does not fit: host channel left unrouted
                map[host] = ConverterChannel{ 1, (uint8_t)port, (uint8_t)slot, (uint8_t)unitIndex, (uint8_t)e };
            }
            pIn += a;
            pOut += d;
        }
    }
    return host;
}

// The name of one of a unit's channels (n is 1-based within the unit), with the
// unit's prefix letter. Returns false when the unit has no channel of that kind.
static inline bool ConverterChannelName(ConverterKind k, bool input, char prefix, uint32_t n,
                                        char *buf, size_t size)
{
    const char *fmt = nullptr;
    switch (k) {
    case kConverterRosetta: fmt = input ? "%c In %u" : "%c Out %u"; break;
    case kConverterAD16X:   fmt = input ? "%c Line %u" : nullptr; break;
    case kConverterDA16X:   fmt = input ? nullptr : "%c Line %u"; break;
    case kConverterDDAsAD:  fmt = input ? "%c Line %u" : "%c Dig Out %u"; break;
    case kConverterDDAsDA:  fmt = input ? "%c Dig In %u" : "%c Line %u"; break;
    default: break;
    }
    if (!fmt || !buf || !size) return false;
    snprintf(buf, size, fmt, prefix, n);
    return true;
}

// The name of a host channel: the unit channel behind it, or "N.A.".
// firstPrefix: 'A' normally; 'B' when a Symphony I/O on port 1 is unit A and
// the converters are on port 2.
static inline void ConverterHostChannelName(const ConverterChain &c, bool input, uint32_t host,
                                            char *buf, size_t size, char firstPrefix = 'A')
{
    ConverterChannel map[kConverterMaxHostChannels];
    ConverterHostMap(c, input, map);
    if (host < kConverterMaxHostChannels && map[host].valid) {
        const ConverterChannel &m = map[host];
        uint32_t idx = m.unit, port = 0;
        if (idx >= c.count[0]) { idx -= c.count[0]; port = 1; }
        if (ConverterChannelName(c.kind[port][idx], input, (char)(firstPrefix + m.unit), m.element + 1u, buf, size))
            return;
    }
    snprintf(buf, size, "N.A.");
}

// Converter latency in samples (input or output), before the FPGA frame is
// added, as the original reported for the first unit on port 1.
static inline uint32_t ConverterLatency(ConverterKind k, uint32_t rateHz, bool input)
{
    const bool x1 = rateHz <= 48000, x2 = rateHz > 48000 && rateHz <= 96000;
    switch (k) {
    case kConverterRosetta:
        if (x1) return input ? 36 : 34;
        if (x2) return input ? 57 : 56;
        return input ? 100 : 99;
    case kConverterAD16X:
    case kConverterDA16X:
        if (x1) return input ? 36 : 35;
        if (x2) return input ? 25 : 24;
        return input ? 20 : 19;
    case kConverterDDAsAD:
    case kConverterDDAsDA:
        if (rateHz <= 44100) return input ? 36 : 35;
        if (x1) return input ? 36 : 34;
        if (x2) return input ? 24 : 23;
        return input ? 18 : 17;
    default:
        return 0;
    }
}

// X-Symphony firmware version of a unit: major = XTD_INQUIRE low nibble, minor =
// INQUIRE low nibble (XLink.cpp:1503-1548). 0.0 means unknown (no XTD reply).
// The original warned once below 2.7 (SymphonyController.cpp:35-40, 2605-2668).
static constexpr uint8_t kConverterMinFirmwareMajor = 2;
static constexpr uint8_t kConverterMinFirmwareMinor = 7;
static inline bool ConverterFirmwareOutOfDate(uint8_t major, uint8_t minor)
{
    if (major == 0 && minor == 0) return false;
    return major < kConverterMinFirmwareMajor ||
           (major == kConverterMinFirmwareMajor && minor < kConverterMinFirmwareMinor);
}

// Authentication (Symphony64 Driver/XLink.cpp:2846-2975, AUTHENTICATE_XLINK_DEVICES
// was defined in the shipped driver). The host sends AUTH_START, 16 bytes with
// AUTH_WRITE, then reads 16 bytes with AUTH_READ (data = byte index), and checks
// the unit's first 8 bytes against a function of the host's bytes 8-15, the
// unit's bytes 8-15 (bit-shuffled) and the unit's routing nibble. It is the host
// checking the unit is genuine; the unit does not depend on the result.
static constexpr uint8_t kXLinkCmdAuthStart = 0x06;
static constexpr uint8_t kXLinkCmdAuthWrite = 0x07;
static constexpr uint8_t kXLinkCmdAuthRead  = 0x08;
static constexpr uint32_t kConverterAuthBytes = 16;

// The 16 bytes the host sends. The original filled them from random(), which
// the driver never seeded (the same sequence every load); this keeps a fixed
// sequence as well, so the register traces stay reproducible.
static inline void ConverterAuthChallenge(uint32_t &state, uint8_t out[kConverterAuthBytes])
{
    for (uint32_t i = 0; i < kConverterAuthBytes; i++) {
        if ((i % 4) == 0) {   // one 32-bit draw per four bytes, like random() >> (i%4)*8
            state ^= state << 13; state ^= state >> 17; state ^= state << 5;
        }
        out[i] = (uint8_t)(state >> ((i % 4) * 8));
    }
}

// The device-info byte the original mixed in: DeviceInfoCached (XLink.cpp
// :1718-1733) = CONVERT_NEW_ROUTING_TO_OLDDEVICEINFO(routing, minor firmware)
// = ((routing & 0x0F) << 4) | (INQUIRE & 0x0F), passed to VerifyDataInDevice
// as a UInt8.
static inline uint8_t ConverterAuthDeviceInfo(uint8_t routing, uint8_t inquire)
{
    return (uint8_t)(((routing & 0x0F) << 4) | (inquire & 0x0F));
}

// VerifyDataInDevice (XLink.cpp:2846-2905). `info` is ConverterAuthDeviceInfo;
// the value mixed in (HostInfo) is it with its halves swapped.
static inline bool ConverterAuthVerify(const uint8_t out[kConverterAuthBytes],
                                       const uint8_t in[kConverterAuthBytes], uint8_t info)
{
    const uint8_t hostInfo = (uint8_t)(((info & 0x0F) << 4) | ((info & 0xF0) >> 4));
    uint8_t host[8], rnd[8], res[8];
    for (uint32_t i = 0; i < 8; i++) {
        const uint8_t b = in[i + 8];
        host[i] = out[i + 8];
        rnd[i] = (uint8_t)(((b & 0x80) >> 5) | ((b & 0x40) >> 6) | ((b & 0x20) << 2) | (b & 0x10) |
                           ((b & 0x08) >> 2) | ((b & 0x04) << 4) | ((b & 0x02) << 2) | ((b & 0x01) << 5));
    }
    res[0] = (rnd[0] & 0x80) ? (uint8_t)(host[1] ^ rnd[5]) : (uint8_t)~(host[1] ^ rnd[2]);
    res[1] = (rnd[1] & 0x40) ? (uint8_t)(host[3] ^ rnd[2]) : (uint8_t)~(host[3] ^ rnd[1]);
    res[2] = (rnd[2] & 0x20) ? (uint8_t)(host[5] ^ rnd[1]) : (uint8_t)~(host[5] ^ rnd[4]);
    res[3] = (rnd[3] & 0x10) ? (uint8_t)(host[7] ^ rnd[4]) : (uint8_t)~(host[7] ^ rnd[6]);
    res[4] = (rnd[4] & 0x08) ? (uint8_t)(hostInfo ^ rnd[6]) : (uint8_t)~(host[2] ^ rnd[7]);
    res[5] = (rnd[5] & 0x04) ? (uint8_t)(host[4] ^ rnd[7]) : (uint8_t)~(host[4] ^ rnd[0]);
    res[6] = (rnd[6] & 0x02) ? (uint8_t)(host[6] ^ rnd[0]) : (uint8_t)~(hostInfo ^ rnd[3]);
    res[7] = (rnd[7] & 0x01) ? (uint8_t)(host[0] ^ rnd[3]) : (uint8_t)~(host[0] ^ rnd[5]);
    for (uint32_t i = 0; i < 8; i++)
        if (res[i] != in[i]) return false;
    return true;
}

// What a genuine unit answers, for the host tests and the register-trace card:
// bytes 8-15 are the unit's own, bytes 0-7 follow from them. (Test helper; the
// driver never builds an answer.)
static inline void ConverterAuthExpectedAnswer(const uint8_t out[kConverterAuthBytes], uint8_t info,
                                               const uint8_t unitBytes[8], uint8_t in[kConverterAuthBytes])
{
    for (uint32_t i = 0; i < 8; i++) in[i + 8] = unitBytes[i];
    for (uint32_t i = 0; i < 8; i++) in[i] = 0;
    // Solve for bytes 0-7 by computing the expected result with them unset:
    // the result depends only on bytes 8-15, so one pass gives the answer.
    uint8_t probe[kConverterAuthBytes];
    for (uint32_t i = 0; i < kConverterAuthBytes; i++) probe[i] = in[i];
    const uint8_t hostInfo = (uint8_t)(((info & 0x0F) << 4) | ((info & 0xF0) >> 4));
    uint8_t host[8], rnd[8];
    for (uint32_t i = 0; i < 8; i++) {
        const uint8_t b = probe[i + 8];
        host[i] = out[i + 8];
        rnd[i] = (uint8_t)(((b & 0x80) >> 5) | ((b & 0x40) >> 6) | ((b & 0x20) << 2) | (b & 0x10) |
                           ((b & 0x08) >> 2) | ((b & 0x04) << 4) | ((b & 0x02) << 2) | ((b & 0x01) << 5));
    }
    in[0] = (rnd[0] & 0x80) ? (uint8_t)(host[1] ^ rnd[5]) : (uint8_t)~(host[1] ^ rnd[2]);
    in[1] = (rnd[1] & 0x40) ? (uint8_t)(host[3] ^ rnd[2]) : (uint8_t)~(host[3] ^ rnd[1]);
    in[2] = (rnd[2] & 0x20) ? (uint8_t)(host[5] ^ rnd[1]) : (uint8_t)~(host[5] ^ rnd[4]);
    in[3] = (rnd[3] & 0x10) ? (uint8_t)(host[7] ^ rnd[4]) : (uint8_t)~(host[7] ^ rnd[6]);
    in[4] = (rnd[4] & 0x08) ? (uint8_t)(hostInfo ^ rnd[6]) : (uint8_t)~(host[2] ^ rnd[7]);
    in[5] = (rnd[5] & 0x04) ? (uint8_t)(host[4] ^ rnd[7]) : (uint8_t)~(host[4] ^ rnd[0]);
    in[6] = (rnd[6] & 0x02) ? (uint8_t)(host[6] ^ rnd[0]) : (uint8_t)~(hostInfo ^ rnd[3]);
    in[7] = (rnd[7] & 0x01) ? (uint8_t)(host[0] ^ rnd[3]) : (uint8_t)~(host[0] ^ rnd[5]);
}
