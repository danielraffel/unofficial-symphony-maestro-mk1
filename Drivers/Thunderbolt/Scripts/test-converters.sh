#!/bin/bash
# Host test for SymphonyConverters.h: identity, placement (host channel -> port
# slot, as Apogee's routing layer shipped it), channel names, latency and the
# firmware check for the older XLink converters. The app's ConnectedUnit tests
# use the same chains.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIR="$(cd "$SCRIPT_DIR/../Source" && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/test.cpp" <<'CPP'
#include <cstdio>
#include <cstring>
#include <initializer_list>
#include "SymphonyConverters.h"

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { fprintf(stderr, "line %d: ", __LINE__); \
    fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); failures++; } } while (0)

static ConverterChain chain(std::initializer_list<ConverterKind> p1, std::initializer_list<ConverterKind> p2 = {})
{
    ConverterChain c = {};
    for (auto k : p1) c.kind[0][c.count[0]++] = k;
    for (auto k : p2) c.kind[1][c.count[1]++] = k;
    return c;
}
// host channel (1-based) -> "port:slot" (1-based), "-" when unrouted
static void slot(const ConverterChain &c, bool in, uint32_t host1, const char *want, int line)
{
    ConverterChannel map[kConverterMaxHostChannels];
    ConverterHostMap(c, in, map);
    char got[16];
    const ConverterChannel &m = map[host1 - 1];
    if (m.valid) snprintf(got, sizeof(got), "%u:%u", m.port + 1u, m.slot + 1u); else snprintf(got, sizeof(got), "-");
    if (strcmp(got, want)) { fprintf(stderr, "line %d: host %s %u got %s want %s\n", line, in ? "in" : "out", host1, got, want); failures++; }
}
#define SLOT(c, in, h, w) slot(c, in, h, w, __LINE__)
static void name(const ConverterChain &c, bool in, uint32_t host1, const char *want, int line)
{
    char got[32];
    ConverterHostChannelName(c, in, host1 - 1, got, sizeof(got));
    if (strcmp(got, want)) { fprintf(stderr, "line %d: host %s %u got \"%s\" want \"%s\"\n", line, in ? "in" : "out", host1, got, want); failures++; }
}
#define NAME(c, in, h, w) name(c, in, h, w, __LINE__)
static const ConverterKind R = kConverterRosetta, AD = kConverterAD16X, DA = kConverterDA16X, DD = kConverterDDAsAD;

int main()
{
    // Identity: routing = (XTD & 0xF0) | (INQUIRE >> 4)
    CHECK(ConverterRouting(0x37, 0x02) == kConverterRoutingAD, "AD routing");
    CHECK(ConverterRouting(0xC5, 0x00) == kConverterRoutingDA, "DA routing");
    CHECK(ConverterRouting(0xF0, 0xF1) == kConverterRoutingSymphony, "Symphony routing");
    CHECK(ConverterKindForRouting(0x0F) == kConverterDDAsAD, "DD defaults to AD, as the original");
    CHECK(ConverterKindForRouting(0x0F, false) == kConverterDDAsDA, "DD as DA");
    CHECK(ConverterKindForRouting(0x05) == kConverterRosetta, "Rosetta");
    CHECK(ConverterKindForRouting(0x09) == kConverterUnknown, "unknown banks");

    // Placement (routing layer as shipped). Host channels packed; slots per port.
    { auto c = chain({AD, AD, DA, DA});
      SLOT(c, true, 1, "1:1");  SLOT(c, true, 17, "1:17"); SLOT(c, true, 32, "1:32"); SLOT(c, true, 33, "-");
      SLOT(c, false, 1, "1:1"); SLOT(c, false, 17, "1:17");
      NAME(c, true, 1, "A Line 1"); NAME(c, true, 17, "B Line 1");
      NAME(c, false, 1, "C Line 1"); NAME(c, false, 32, "D Line 16"); NAME(c, true, 33, "N.A."); }
    { auto c = chain({R, AD});            // Rosetta then a 16-channel unit: AD starts at slot 17
      SLOT(c, true, 8, "1:8"); SLOT(c, true, 9, "1:17"); SLOT(c, true, 24, "1:32");
      SLOT(c, false, 8, "1:8"); SLOT(c, false, 9, "-");
      NAME(c, true, 9, "B Line 1"); NAME(c, false, 8, "A Out 8"); NAME(c, false, 9, "N.A."); }
    { auto c = chain({DA, R});            // DA first: the Rosetta's inputs and outputs start at 17
      SLOT(c, true, 1, "1:17"); SLOT(c, false, 16, "1:16"); SLOT(c, false, 17, "1:17");
      NAME(c, true, 1, "B In 1"); NAME(c, false, 17, "B Out 1"); }
    { auto c = chain({AD, R});            // Rosetta after an AD: outputs also at 17
      SLOT(c, true, 17, "1:17"); SLOT(c, false, 1, "1:17"); }
    { auto c = chain({DA, AD});           // AD after a DA: inputs at 17 ("DA16 first" case)
      SLOT(c, true, 1, "1:17"); SLOT(c, true, 16, "1:32"); SLOT(c, false, 1, "1:1"); }
    { auto c = chain({AD, DA});           // DA after an AD: outputs stay at 1
      SLOT(c, true, 1, "1:1"); SLOT(c, false, 1, "1:1"); }
    { auto c = chain({R, DD});
      SLOT(c, true, 9, "1:17"); SLOT(c, false, 9, "1:17"); NAME(c, false, 9, "B Dig Out 1"); }
    { auto c = chain({R, R, AD});
      SLOT(c, true, 9, "1:9"); SLOT(c, true, 17, "1:17"); }
    { auto c = chain({DA, R, R});         // as shipped (Apogee noted the last Rosetta is wrong)
      SLOT(c, true, 1, "1:17"); SLOT(c, true, 9, "1:9"); SLOT(c, false, 25, "1:25"); }
    { auto c = chain({AD, AD, AD});       // the third AD does not fit in 32
      SLOT(c, true, 33, "-"); }
    { auto c = chain({AD, DA}, {AD, DA}); // two ports: port 2 packs after port 1
      SLOT(c, true, 16, "1:16"); SLOT(c, true, 17, "2:1"); SLOT(c, false, 17, "2:1");
      NAME(c, true, 17, "C Line 1"); NAME(c, false, 17, "D Line 1"); }
    { auto c = chain({AD, AD, DA, DA}, {AD, AD, DA, DA});   // eight units: 64 in, 64 out
      SLOT(c, true, 64, "2:32"); SLOT(c, false, 33, "2:1");
      NAME(c, true, 33, "E Line 1"); NAME(c, false, 64, "H Line 16"); }
    { auto c = chain({kConverterDDAsDA});
      NAME(c, true, 3, "A Dig In 3"); NAME(c, false, 3, "A Line 3"); }

    // Latency
    CHECK(ConverterLatency(R, 48000, true) == 36 && ConverterLatency(R, 48000, false) == 34, "R 48k");
    CHECK(ConverterLatency(R, 192000, false) == 99, "R 192k out");
    CHECK(ConverterLatency(AD, 96000, true) == 25, "AD 96k in");
    CHECK(ConverterLatency(DA, 176400, false) == 19, "DA 176.4k out");
    CHECK(ConverterLatency(DD, 44100, false) == 35, "DD 44.1 out");
    CHECK(ConverterLatency(DD, 48000, false) == 34, "DD 48 out");
    CHECK(ConverterLatency(kConverterDDAsDA, 88200, true) == 24, "DD 88.2 in");

    // Firmware
    CHECK(!ConverterFirmwareOutOfDate(0, 0), "unknown is not out of date");
    CHECK(ConverterFirmwareOutOfDate(2, 6), "2.6 out of date");
    CHECK(!ConverterFirmwareOutOfDate(2, 7), "2.7 ok");
    CHECK(ConverterFirmwareOutOfDate(1, 15), "1.F out of date");
    CHECK(!ConverterFirmwareOutOfDate(3, 0), "3.0 ok");

    // Authentication: a genuine answer verifies with the unit's device info,
    // which carries its minor firmware (INQUIRE low nibble); the wrong minor,
    // the wrong routing or one wrong byte does not.
    { uint32_t st = 0x12345678u; uint8_t out[16], in[16]; const uint8_t unit[8] = {1, 2, 3, 4, 0x55, 0xAA, 7, 0x80};
      const uint8_t inquire = 0x37;   // AD-16X, minor firmware 7
      const uint8_t info = ConverterAuthDeviceInfo(kConverterRoutingAD, inquire);
      CHECK(info == 0x37, "device info 0x%02x (want routing nibble 3, minor 7)", info);
      CHECK(ConverterAuthDeviceInfo(kConverterRoutingRosetta, 0x5A) == 0x5A, "Rosetta minor 10");
      ConverterAuthChallenge(st, out);
      ConverterAuthExpectedAnswer(out, info, unit, in);
      CHECK(ConverterAuthVerify(out, in, info), "genuine answer verifies");
      int wrongMinorAccepted = 0, wrongRoutingAccepted = 0;
      for (uint32_t k = 0; k < 2000; k++) {   // over many challenges the mixed-in byte must matter
          uint8_t o[16], a[16]; ConverterAuthChallenge(st, o);
          ConverterAuthExpectedAnswer(o, info, unit, a);
          if (!ConverterAuthVerify(o, a, info)) { CHECK(false, "genuine answer %u rejected", k); break; }
          if (ConverterAuthVerify(o, a, ConverterAuthDeviceInfo(kConverterRoutingAD, 0x30))) wrongMinorAccepted++;
          if (ConverterAuthVerify(o, a, ConverterAuthDeviceInfo(kConverterRoutingDA, inquire))) wrongRoutingAccepted++;
      }
      CHECK(wrongMinorAccepted < 2000, "the minor firmware never affects the check");
      CHECK(wrongRoutingAccepted < 2000, "the routing never affects the check");
      in[3] ^= 1; CHECK(!ConverterAuthVerify(out, in, info), "a wrong byte fails");
      uint32_t st2 = 0x12345678u; uint8_t out2[16]; ConverterAuthChallenge(st2, out2);
      CHECK(memcmp(out, out2, 16) == 0, "challenge sequence is reproducible"); }

    if (failures) { fprintf(stderr, "%d failure(s)\n", failures); return 1; }
    printf("[PASS] converter identity, placement, names, latency, firmware\n");
    return 0;
}
CPP

clang++ -std=c++17 -Wall -Wextra -Werror -I"$SOURCE_DIR" "$TMP_DIR/test.cpp" -o "$TMP_DIR/test"
"$TMP_DIR/test"
