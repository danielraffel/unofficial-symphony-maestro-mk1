// RegisterTrace.cpp — runs the real SymphonyThunderbridge driver source against
// a simulated card and writes, per scenario, the ordered list of everything the
// driver did to the hardware: every BAR read and write (offset, value), every
// PCI config access, every sleep between them, and the host resources it took
// (DMA mappings, stream formats). run-tests.sh compares those lists with the
// ones recorded from the unmodified driver.
//
// The simulated card is deliberately simple and fully deterministic. It is not
// a model of the FPGA; it answers just enough (scratch round trip, XLink clock
// detect, a Symphony I/O that answers vendor reads, converters that answer
// INQUIRE) for the driver to walk its real code paths.
//
// Build flag TRACE_HAVE_PORT2: the driver under test has the SymphonyPortCount
// personality property and ReadPort2State (experiment/64ch-port2). Without it
// only the single-port scenarios are built, so the same file also runs against
// an older driver source (run-tests.sh --against <ref>).
// Build flag TRACE_HAVE_PORT2_AUDIO: it also has stage 2 (the port selector and
// audio on port 2).

#include "HostDriverKit.h"
#include "SymphonyThunderbridge.h"
#include "Sym64Registers.h"
#include "SymphonyMixerCoef.h"
#include "SymphonyCardMixerRouting.h"
#include "SymphonyThunderbridgeShared.h"
#ifdef kSelectorReadChannelOrder
#include "SymphonyChannelNames.h"
#endif
#ifdef TRACE_HAVE_CONVERTER_PARITY
#include "SymphonyConverters.h"
#endif

#include <set>
#include <cstdarg>
#include <algorithm>
#include <functional>
#include <thread>
#include <chrono>

// The app-facing layouts: the existing link-state reply must keep its size, and
// the new port-2 reply is a separate 16-word struct.
static_assert(sizeof(SymphonyLinkStateOutput) == 64, "ReadLinkState layout changed");
#ifdef TRACE_HAVE_PORT2
static_assert(sizeof(SymphonyPort2StateOutput) == 64, "ReadPort2State is 16 words");
#if defined(TRACE_HAVE_UNITB)
static_assert(sizeof(SymphonyUnitBStateOutput) == 40, "Unit B state is 40 bytes");
static_assert(sizeof(SymphonyVendorCommandInput) == 78 && offsetof(SymphonyVendorCommandInput, port) == 5,
              "vendor port byte is packed at offset 5");
#endif
static_assert(offsetof(SymphonyPort2StateOutput, unit) == 7 * sizeof(uint32_t), "unit[] at word 7");
static_assert(kSelectorReadLinkState == 5 && kSelectorReadDriverBuild == 6 && kSelectorRetireForUpgrade == 7 && kSelectorReadPort2State == 8, "selector numbers");
#ifdef TRACE_HAVE_CONVERTER_PARITY
static_assert(kSelectorReadConverters == 9 && kSelectorSetConverterConfig == 10 && kSelectorReadUnitB == 11 && kSelectorCount >= 12, "converter/unit-B selectors");
#ifdef kSelectorSetMonitorDevice
static_assert(kSelectorSetMonitorDevice == 12 && kSelectorLoopSync == 13, "existing selectors unchanged");
#ifdef kSelectorPublishMicGain
#ifdef kSelectorSetMonitorOutput
#if defined(kSelectorReadChannelOrder)
static_assert(kSelectorVBus == 16 && kSelectorReadChannelOrder == 17 && kSelectorCount == 18 &&
              sizeof(SymphonyChannelOrderOutput) == 24, "channel order is the 18th selector");
#elif defined(kSelectorVBus)
static_assert(kSelectorCount == 17, "VBus is the 17th selector");
#else
static_assert(kSelectorCount == 16, "selector count before VBus");
#endif
static_assert(kSelectorPublishMicGain == 14 && kSelectorSetMonitorOutput == 15 &&
              sizeof(SymphonyObservedGainInput) == 24 && sizeof(SymphonyMonitorOutputInput) == 12,
              "host gain observation ABI v1; monitor output is selector 15, three words");
#else
static_assert(kSelectorPublishMicGain == 14 && kSelectorCount == 15 &&
              sizeof(SymphonyObservedGainInput) == 24, "host gain observation ABI v1");
#endif
#else
static_assert(kSelectorCount == 14, "baseline selector count");
#endif
#endif
static_assert(sizeof(SymphonyConverterStateOutput) == 112 && sizeof(SymphonyConverterConfigInput) == 8, "converter struct sizes");
#endif
#endif

HostBackend *gHostBackend = nullptr;
int gHostTerminateCalls = 0;
int gHostLocksHeld = 0;
uint64_t gHostMicPreClockOffsetNs = 0;
uint64_t gHostStartupOutputHoldNs = 0;
HostAudioRegistry gHostAudio;
std::deque<HostBlock> gHostCompletions;
static std::vector<std::deque<HostBlock> *> gQueues;
bool gHostDispatchSyncDrain = true;
static bool gVerbose = false;
static int gFailures = 0;

void HostNoteBuffer(IOBufferMemoryDescriptor *b) { gHostAudio.buffers.push_back(b); }
static std::set<const void *> gLiveBuffers;
void HostBufferBorn(IOBufferMemoryDescriptor *b) { gLiveBuffers.insert(b); }
void HostBufferDied(IOBufferMemoryDescriptor *b) { gLiveBuffers.erase(b); }
static bool HostBufferAlive(const void *b) { return gLiveBuffers.count(b) != 0; }

void HostLog(const char *fmt, ...)
{
    if (!gVerbose) return;
    va_list ap;
    va_start(ap, fmt);
    fputs("    # ", stderr);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
}

void HostDefer(std::deque<HostBlock> *queue, HostBlock b)
{
    bool known = false;
    for (auto *q : gQueues) known = known || (q == queue);
    if (!known) gQueues.push_back(queue);
    queue->push_back(Block_copy(b));
}

void HostDrain(std::deque<HostBlock> *queue)
{
    while (!queue->empty()) {
        HostBlock b = queue->front();
        queue->pop_front();
        b();
        Block_release(b);
    }
}

void HostPump()
{
    for (bool ran = true; ran;) {
        ran = false;
        for (size_t i = 0; i < gQueues.size(); i++) {
            if (!gQueues[i]->empty()) { HostDrain(gQueues[i]); ran = true; }
        }
    }
}

#define CHECK(cond, ...) do { if (!(cond)) { gFailures++; fprintf(stderr, "FAIL: " __VA_ARGS__); fputc('\n', stderr); } } while (0)

// ── CRC8, as the Symphony's message protocol uses it ────────────────────────
static uint8_t Crc8(const uint8_t *data, size_t len)
{
    uint8_t crc = 0;
    for (size_t i = 0; i < len; i++) {
        uint16_t n = (uint16_t)((crc ^ data[i]) << 8);
        for (int bit = 0; bit < 8; bit++) {
            if (n & 0x8000) n ^= 0x8380;
            n <<= 1;
        }
        crc = (uint8_t)(n >> 8);
    }
    return crc;
}

// ── Simulated XLink port ────────────────────────────────────────────────────
struct Unit {
    uint8_t inquire;
    uint8_t xtd;
    uint8_t addr = 0;
    bool    passing = false;
    uint8_t phase = 0x20;             // reply to XLINK_CMD_WCLK_PHASE (0x09)
    bool    answersPhase = true;
    uint32_t unmutes = 0;             // UNMUTE (0x0A, data 0x80) commands addressed to it
    uint8_t  authOut[16] = {};        // AUTH_WRITE bytes since AUTH_START
    uint32_t authIdx = 0;
    bool     authGenuine = true;      // answers AUTH_READ like a real Apogee unit
    uint32_t authStarts = 0;
};

struct Port {
    enum Kind { Empty, Symphony, Converters } kind = Empty;
    std::vector<Unit> units;          // Converters: the chain, nearest first
    bool     answersVendor = true;    // Symphony: replies to vendor reads
    uint32_t dropVendorReads = 0;     // Symphony: the next N vendor reads get no reply
    // Reply matching (D2): frames sent ahead of the next reply, as a late
    // answer to an earlier read would arrive (command, nValue, data length).
    struct StaleReply { uint8_t cmd; uint32_t nValue; uint16_t len; };
    std::vector<StaleReply> staleReplies;
    bool noEcho = false;              // replies do not echo the request's command and nValue
    // As the firmware does in Line (speaker mode 0): a speaker level or mute
    // read answers 0, a speaker level written is ignored, and the level kept
    // aside comes back when Line ends.
    bool lineFirmware = false;
    uint8_t  symphonyInquire = 0;     // Symphony: INQUIRE reply byte (0 = none)
    bool     symphonyProbeAnswered = false;
    // A Symphony I/O as an XLink unit (port 2, "unit B"), from field report
    // 6F64285E (2026-11-20, two Symphony I/Os with one 16-channel card each):
    // it answers INQUIRE 0xF8 and XTD_INQUIRE 0x02 (the banks of a DD-16X),
    // passes the authentication, and reports its phase. symphonyType is its
    // XLINK_DEVICE_TYPE answer (0x20, og SymphonyCommon.h:228); 0 keeps the
    // older one-answer model above (port 1 scenarios).
    uint8_t  symphonyType = 0;
    uint8_t  symphonyXtd = 0;
    uint8_t  symAddr = 0;
    bool     symPassing = false;
    bool     unitsHoldAddress = false;// converters: keep address and pass-through over a bus reset (hypothetical)
    bool     symHoldsAddress = false; // keeps address and pass-through over a bus reset (the field behaviour)
    uint8_t  symAuthOut[16] = {};
    uint32_t symAuthIdx = 0;
    uint32_t symTypeQueries = 0;      // DEVICE_TYPE queries it answered at its address
    bool     ignoreRate = false;      // units do not follow SET_SAMPLE_RATE
    bool     txBusy = false;          // TX register reports busy (commands time out)
    long     busyAfterWrites = -1;    // TX goes busy once this many vendor writes have arrived
    uint32_t slipReads = 0;           // the next N status reads report a data slip
    uint8_t  rateCode = 0x04;         // 44.1 kHz
    uint32_t sticky = 0;              // status sticky bits (write 1 to clear)
    std::deque<uint32_t> rx;
    bool     hasLatch = false;
    uint32_t latch = 0;
    uint32_t lastPopped = 0;          // PCIe card only: see readRX
    bool     dupArmed = false;
    uint32_t lastTx = 0;
    std::vector<uint8_t> frame;       // Symphony: request frame being received
    uint8_t  devSeq = 0;
    std::map<uint64_t, std::vector<uint8_t>> stored;   // Symphony: written values
    std::vector<uint8_t> vendorWrites;                // command IDs, for fault-path assertions
    // dext 150 (selector 17 checks; no golden uses these): every AudioRouting
    // (0x31) payload received, in order (stored keeps only the last, as every
    // 0x31 has nValue 0); the next OptionBoardType (0xA1) reads, one entry
    // each: -1 no reply (the read fails), -2 the usual answer, else that type;
    // and a write that fails: the (failWriteSkip + 1)-th write of command
    // failWriteCmd goes busy at its command byte for one byte's whole wait, so
    // the driver's send fails there, and the unit drops the partial frame.
    std::vector<std::vector<uint8_t>> routingWrites;
    std::deque<int> boardTypeScript;
    uint8_t  failWriteCmd = 0;
    uint32_t failWriteSkip = 0;
    uint32_t busyPolls = 0;
    std::vector<uint8_t> vendorReads;
    std::vector<uint8_t> clockModes;                  // source byte of every ClockMode (0x50) written
    uint64_t commandsSeen = 0;        // anything written to the TX register

    bool present() const { return kind != Empty; }
    bool busy() const {
        return txBusy || busyPolls || (busyAfterWrites >= 0 && (long)vendorWrites.size() >= busyAfterWrites);
    }

    uint32_t detectBit() const {
        switch (rateCode) {
        case 0x04: return 0x01;   // 44.1
        case 0x00: return 0x02;   // 48
        case 0x05: return 0x04;   // 88.2
        case 0x01: return 0x08;   // 96
        case 0x06: return 0x10;   // 176.4
        case 0x02: return 0x20;   // 192
        }
        return 0;
    }

    uint32_t status() {
        uint32_t slip = 0;
        if (slipReads) { slipReads--; slip = kXLinkDataSlipSticky; }
        return sticky | slip | (present() ? 0u : kXLinkDataDownCurrent);
    }

    // ThunderBridge (2200): a read shows whether a word is waiting, a write
    // takes it, and the next read returns it (the original's THUNDERBRIDGE
    // XLink::RX_FIFO_ReadHW).
    //
    // PCIe card (2100): a read returns the waiting word itself and a write
    // moves on to the next one (the original's other RX_FIFO_ReadHW: "Older
    // PCIe cards needed a write after the FIFO read"). When nothing is waiting
    // the register is modelled as still holding the last word, with the empty
    // bit set. That part is an inference, not from the source: it is what
    // makes the ThunderBridge order lose the first byte of a vendor reply yet
    // still see a one-word INQUIRE reply, which is the field report of
    // 2026-11-15 (a 16x16 Symphony I/O on this card shown as "DD-16X").
    uint32_t readRX(bool pcieOrder) {
        if (pcieOrder) return rx.empty() ? (0x80000000u | lastPopped) : rx.front();
        if (hasLatch) { hasLatch = false; return latch; }
        if (rx.empty()) return 0x80000000u;
        return rx.front();
    }
    void writeRX(bool pcieOrder) {
        if (rx.empty()) return;
        if (pcieOrder) { lastPopped = rx.front(); rx.pop_front(); return; }
        latch = rx.front();
        rx.pop_front();
        hasLatch = true;
    }

    void reply(uint8_t addr, uint8_t cmd, uint8_t data) {
        rx.push_back((9u << 24) | ((uint32_t)addr << 17) | ((uint32_t)cmd << 9) | ((uint32_t)data << 1));
    }

    Unit *firstNotPassing() {
        for (auto &u : units) if (!u.passing) return &u;
        return nullptr;
    }
    Unit *reachable(uint8_t addr) {
        for (auto &u : units) {
            if (u.addr == addr) return &u;
            if (!u.passing) return nullptr;
        }
        return nullptr;
    }

    std::vector<uint8_t> vendorValue(uint8_t cmd, uint32_t nValue, uint16_t len) {
        auto it = stored.find(((uint64_t)cmd << 32) | nValue);
        std::vector<uint8_t> v;
        if (lineFirmware && (cmd == 0x26 || cmd == 0x27)) {
            auto m = stored.find((uint64_t)0x25 << 32);
            if (m != stored.end() && !m->second.empty() && m->second[0] == 0) {
                v.assign(len, 0);
                return v;
            }
        }
        if (it != stored.end()) v = it->second;
        else switch (cmd) {
        case 0x25: v = { 2 }; break;                       // SpeakerMode: stereo
        case 0x26: v = { 12 }; break;                      // SpeakerVolume
        case 0x27: v = { 0 }; break;                       // SpeakerMute
        case 0xE9: v = { 1 }; break;                       // ActiveSpeakerSet
        case 0x23: v = { (uint8_t)(nValue ? 30 : 18) }; break;   // HeadphoneVolume
        case 0x24: v = { 0 }; break;                       // HeadphoneMute
        case 0xA1: v = { (uint8_t)(nValue ? 3 : 1) }; break;     // board 0 MicPre8, board 1 Optical
        case 0x51: {                                        // ClockRateAndLock
            static const uint32_t hz[] = { 48000, 96000, 192000, 0, 44100, 88200, 176400 };
            uint32_t r = hz[rateCode % 7];
            v = { 1, (uint8_t)(r >> 24), (uint8_t)(r >> 16), (uint8_t)(r >> 8), (uint8_t)r };
            break;
        }
        default: break;
        }
        v.resize(len, 0);
        return v;
    }

    void vendorFrameByte(uint8_t b) {
        if (frame.empty() && b != 0x80) return;
        frame.push_back(b);
        if (failWriteCmd && frame.size() == 5 && frame[3] == 0x40 && frame[4] == failWriteCmd) {
            if (failWriteSkip) failWriteSkip--;
            else { failWriteCmd = 0; frame.clear(); busyPolls = 100; return; }   // SendXLinkCommandOn waits 100 polls
        }
        if (frame.size() < 2) return;
        const size_t want = 3 + frame[1] + 1;
        if (frame.size() < want) return;
        std::vector<uint8_t> f;
        f.swap(frame);
        if (Crc8(f.data(), f.size() - 1) != f.back() || f[1] < 8) return;
        const uint8_t *c = &f[3];
        const uint8_t  cmd = c[1];
        const uint32_t nValue = c[2] | (c[3] << 8) | (c[4] << 16) | ((uint32_t)c[5] << 24);
        const uint16_t len = (uint16_t)(c[6] | (c[7] << 8));
        if (c[0] == 0x40) {
            vendorWrites.push_back(cmd);
            if (lineFirmware && (cmd == 0x26 || cmd == 0x27)) {
                auto m = stored.find((uint64_t)0x25 << 32);
                if (m != stored.end() && !m->second.empty() && m->second[0] == 0) return;
            }
            if (cmd == 0x50 && len >= 1) clockModes.push_back(c[8]);
            if (cmd == 0x31) routingWrites.emplace_back(c + 8, c + 8 + len);
            stored[((uint64_t)cmd << 32) | nValue] = std::vector<uint8_t>(c + 8, c + 8 + len);
            return;
        }
        if (c[0] != 0xC0) return;
        vendorReads.push_back(cmd);
        if (dropVendorReads) { dropVendorReads--; return; }
        int scriptedType = -2;
        if (cmd == 0xA1 && !boardTypeScript.empty()) {
            scriptedType = boardTypeScript.front();
            boardTypeScript.pop_front();
            if (scriptedType == -1) return;
        }
        for (const StaleReply &st : staleReplies) {
            std::vector<uint8_t> o = { 0xC3, (uint8_t)(8 + st.len), devSeq++, f[2],
                0x01, st.cmd, (uint8_t)st.nValue, (uint8_t)(st.nValue >> 8),
                (uint8_t)(st.nValue >> 16), (uint8_t)(st.nValue >> 24),
                (uint8_t)st.len, (uint8_t)(st.len >> 8) };
            for (uint16_t i = 0; i < st.len; i++) o.push_back(0xEE);
            o.push_back(Crc8(o.data(), o.size()));
            for (uint8_t byte : o) reply(1, 0x10, byte);
        }
        staleReplies.clear();
        std::vector<uint8_t> out = { 0xC3, (uint8_t)(8 + len), devSeq++, f[2] };
        out.insert(out.end(), c, c + 8);
        if (noEcho) { out[5] = 0x00; out[6] = out[7] = out[8] = out[9] = 0x00; }
        auto v = vendorValue(cmd, nValue, len);
        if (scriptedType >= 0 && !v.empty()) v[0] = (uint8_t)scriptedType;
        out.insert(out.end(), v.begin(), v.end());
        out.push_back(Crc8(out.data(), out.size()));
        for (uint8_t byte : out) reply(1, 0x10, byte);
    }

    void writeTX(uint32_t val) {
        commandsSeen++;
        if (val == kXLinkResetCmd) {
            if (!unitsHoldAddress) for (auto &u : units) { u.addr = 0; u.passing = false; }
            frame.clear();
            dupArmed = false;
            symphonyProbeAnswered = false;
            if (!symHoldsAddress) { symAddr = 0; symPassing = false; }
            return;
        }
        const uint8_t addr = (uint8_t)((val >> 17) & 0x3F);
        const uint8_t cmd  = (uint8_t)((val >> 9) & 0xFF);
        const uint8_t data = (uint8_t)((val >> 1) & 0xFF);
        if (cmd == 0x10) {
            dupArmed = false;
            if (kind == Symphony && answersVendor && addr == 1) vendorFrameByte(data);
            return;
        }
        // Every other command is written twice; the units see one command.
        if (dupArmed && val == lastTx) { dupArmed = false; return; }
        dupArmed = true;
        lastTx = val;
        if (!present()) return;
        if (kind == Symphony && symphonyType) {
            // Hears the broadcast address until told to pass commands on, and
            // its own address always.
            const bool hears = addr ? (addr == symAddr) : !symPassing;
            switch (cmd) {
            case 0x03: if (!ignoreRate) rateCode = data; break;
            case 0x01: if (addr == 0 && !symPassing) symAddr = data; break;
            case 0x02: if (addr && addr == symAddr) symPassing = (data != 0); break;
            case 0x05: if (hears) reply(addr, cmd, symphonyInquire); break;
            case 0x0B: if (hears) reply(addr, cmd, symphonyXtd); break;
            case 0x0C: if (hears) { reply(addr, cmd, symphonyType); if (addr) symTypeQueries++; } break;
            case 0x09: if (addr && addr == symAddr) reply(addr, cmd, 0x20); break;
#ifdef TRACE_HAVE_CONVERTER_PARITY
            case 0x06: if (addr && addr == symAddr) symAuthIdx = 0; break;
            case 0x07: if (addr && addr == symAddr && symAuthIdx < 16) symAuthOut[symAuthIdx++] = data; break;
            case 0x08:
                if (addr && addr == symAddr) {
                    static const uint8_t own[8] = { 0x31, 0x7C, 0x02, 0xE5, 0x48, 0x9B, 0x60, 0xD7 };
                    uint8_t in[16];
                    ConverterAuthExpectedAnswer(symAuthOut, ConverterAuthDeviceInfo(ConverterRouting(symphonyInquire, symphonyXtd), symphonyInquire), own, in);
                    if (data < 16) reply(addr, cmd, in[data]);
                }
                break;
#endif
            default: break;
            }
            return;
        }
        switch (cmd) {
        case 0x03:
            if (!ignoreRate) rateCode = data;
            break;
        case 0x01:
            if (Unit *u = firstNotPassing()) u->addr = data;
            break;
        case 0x02:
            if (Unit *u = reachable(addr)) u->passing = (data != 0);
            break;
        case 0x05:
        case 0x0B: {
            if (kind == Symphony) {
                if (symphonyInquire && (cmd == 0x05 || cmd == 0x0B) && !symphonyProbeAnswered) {
                    reply(addr, cmd, symphonyInquire);
                    if (cmd == 0x0B) symphonyProbeAnswered = true;
                }
                break;
            }
            Unit *u = addr ? reachable(addr) : firstNotPassing();
            if (u) reply(addr, cmd, cmd == 0x05 ? u->inquire : u->xtd);
            break;
        }
        case 0x09:
            if (Unit *u = addr ? reachable(addr) : nullptr)
                if (u->answersPhase) reply(addr, cmd, u->phase);
            break;
#ifdef TRACE_HAVE_CONVERTER_PARITY
        case 0x06:
            if (Unit *u = addr ? reachable(addr) : nullptr) { u->authIdx = 0; u->authStarts++; }
            break;
        case 0x07:
            if (Unit *u = addr ? reachable(addr) : nullptr) if (u->authIdx < 16) u->authOut[u->authIdx++] = data;
            break;
        case 0x08:
            if (Unit *u = addr ? reachable(addr) : nullptr) {
                static const uint8_t own[8] = { 0x5A, 0x13, 0xC4, 0x7E, 0x21, 0x99, 0x0F, 0xB2 };
                uint8_t in[16];
                ConverterAuthExpectedAnswer(u->authOut, ConverterAuthDeviceInfo(ConverterRouting(u->inquire, u->xtd), u->inquire), own, in);
                if (!u->authGenuine) in[0] ^= 0x01;
                if (data < 16) reply(addr, cmd, in[data]);
            }
            break;
#endif
        case 0x0A:
            if (addr == 0) { for (auto &u : units) if (data & 0x80) u.unmutes++; }
            else if (Unit *u = reachable(addr)) { if (data & 0x80) u->unmutes++; }
            break;
        default: break;
        }
    }
};

// ── Simulated card + recorder ───────────────────────────────────────────────
struct FakeCard : HostBackend {
    std::map<uint64_t, uint32_t> reg;
    Port     port[2];
    uint16_t pciDeviceID = kThunderBridgeDeviceID;
    // The Symphony 64 PCIe card reads its receive registers in a different
    // order from the ThunderBridge (Port::readRX).
    bool pcieOrder() const { return pciDeviceID == kSymphonyPCIeDeviceID; }
    uint16_t pciCommand = 0;
    uint32_t idReg = 0x11000021;       // FPGA v17, hardware rev 1, master
    uint32_t intPending = 0;
    bool     endpointPresent = true;
    bool     jamBusy = false;          // the jam register reports a jam in progress
    bool     dropPort2Addresses = false;   // the card does not keep A2H2/H2A2 HBA
    // Two-port scenarios: port 2's receive clock is seen only while the port is
    // enabled (GCSR2 DisablePort2 clear, XLINK_CLOCKING_ENABLE_2 set), and only
    // from the 4th clocking read after that, so a probe that does not wait for
    // it, or runs with the port disabled, finds nothing. How long real units
    // take is not known; this only makes the order observable.
    bool     gatePort2 = false;
    uint32_t port2ClockReads = 0;
    uint64_t port2TxWhileDisabled = 0;    // TX writes to a disabled port 2
    bool port2Enabled() {
        return (reg[kRegGCSR2] & kGCSR2_DisablePort2) == 0 && (reg[kRegXLinkClocking] & kXLinkClockEnable2) != 0;
    }
    uint64_t nextDMA = 0x10000000;
    std::vector<std::string> lines;
    std::function<void(unsigned, uint8_t)> onVendorWrite;

    void line(const char *fmt, ...) {
        char buf[160];
        va_list ap;
        va_start(ap, fmt);
        vsnprintf(buf, sizeof(buf), fmt, ap);
        va_end(ap);
        lines.push_back(buf);
        if (gVerbose) fprintf(stderr, "%s\n", buf);
    }
    void phase(const char *name) { line("-- %s", name); }

    // An FPGA power cycle (D3 across sleep): registers back to power-on values.
    void powerCycleFPGA() {
        reg.clear();
        reg[kRegGCSR] = 0x00004a1b;
        intPending = 0;
    }

    void ConfigRead32(uint64_t off, uint32_t *v) override {
        *v = !endpointPresent ? 0xFFFFFFFFu
           : (off == 0x00 ? (((uint32_t)pciDeviceID << 16) | kApogeeVendorID) : 0u);
        line("CR32 0x%02llx 0x%08x", (unsigned long long)off, *v);
    }
    void ConfigRead16(uint64_t off, uint16_t *v) override {
        *v = !endpointPresent ? (uint16_t)0xFFFF : (off == 0x04 ? pciCommand : (uint16_t)0);
        line("CR16 0x%02llx 0x%04x", (unsigned long long)off, *v);
    }
    void ConfigWrite16(uint64_t off, uint16_t v) override {
        if (off == 0x04) pciCommand = v;
        line("CW16 0x%02llx 0x%04x", (unsigned long long)off, v);
    }

    uint32_t clocking() {
        uint32_t v = reg[kRegXLinkClocking] & (kXLinkClockEnable1 | kXLinkClockEnable2);
        if (port[0].present()) v |= kXLinkRX1ClockDetect | port[0].detectBit();
        bool port2Clock = port[1].present();
        if (gatePort2) {
            if (!port2Enabled()) port2ClockReads = 0;
            else port2ClockReads++;
            port2Clock = port2Clock && port2ClockReads > 3;
        }
        if (port2Clock) v |= kXLinkRX2ClockDetect | (port[1].detectBit() << 16);
        return v;
    }

    void MemRead32(uint8_t, uint64_t off, uint32_t *v) override {
        const bool dmaOn = (reg[kRegGCSR] & (kGCSR_A2HDMAEnable | kGCSR_H2ADMAEnable)) != 0;
        switch (off) {
        case kRegIDReg:         *v = idReg; break;
        case kRegIntStatus:     *v = intPending; break;
        case kRegXLink1TX:      *v = port[0].busy() ? 0x80000000u : 0; if (port[0].busyPolls) port[0].busyPolls--; break;   // busy only when a test says so
        case kRegXLink2TX:      *v = port[1].busy() ? 0x80000000u : 0; if (port[1].busyPolls) port[1].busyPolls--; break;
        case kRegXLink1RX:      *v = port[0].readRX(pcieOrder()); break;
        case kRegXLink2RX:      *v = port[1].readRX(pcieOrder()); break;
        case kRegXLink1Status:  *v = port[0].status(); break;
        case kRegXLink2Status:  *v = port[1].status(); break;
        case kRegXLinkClocking: *v = clocking(); break;
        case kRegA2HCHA:        *v = reg[kRegA2HHBA] + (dmaOn ? 0x400 : 0); break;
        case kRegH2ACHA:        *v = reg[kRegH2AHBA] + (dmaOn ? 0x400 : 0); break;
        case kRegJam:           *v = jamBusy ? 0x00000100u : 0u; break;
        case kRegDNAUpper:      *v = 0x00005359; break;
        case kRegDNALower:      *v = 0x4D504831; break;
        default:                *v = reg[off]; break;
        }
        if (!endpointPresent) *v = 0xFFFFFFFFu;
        line("R 0x%06llx 0x%08x", (unsigned long long)off, *v);
    }

    void MemWrite32(uint8_t, uint64_t off, uint32_t v) override {
        line("W 0x%06llx 0x%08x", (unsigned long long)off, v);
        if (!endpointPresent) return;
        const unsigned p = off == kRegXLink2TX ? 1 : 0;
        const auto writesBefore = port[p].vendorWrites.size();
        switch (off) {
        case kRegIntStatus:     intPending &= ~v; break;
        case kRegXLink1TX:      port[0].writeTX(v); break;
        case kRegXLink2TX:
            if (gatePort2 && !port2Enabled()) port2TxWhileDisabled++;
            port[1].writeTX(v);
            break;
        case kRegXLink1RX:      port[0].writeRX(pcieOrder()); break;
        case kRegXLink2RX:      port[1].writeRX(pcieOrder()); break;
        case kRegXLink1Status:  port[0].sticky &= ~v; break;
        case kRegXLink2Status:  port[1].sticky &= ~v; break;
        case kRegA2H2HBA:
        case kRegH2A2HBA:       reg[off] = dropPort2Addresses ? 0 : v; break;
        default:                reg[off] = v; break;
        }
        if (onVendorWrite && port[p].vendorWrites.size() != writesBefore)
            onVendorWrite(p, port[p].vendorWrites.back());
    }

    // A scenario can have something happen while the driver sleeps (a
    // power-down arriving in the middle of a wait). Called after the sleep is
    // recorded; cleared by the callee when it has fired.
    std::function<void()> onSleep;
    void Sleep(uint64_t ms) override {
        line("S %llu", (unsigned long long)ms);
        if (onSleep) { auto f = onSleep; f(); }
    }
    void HostEvent(const std::string &what) override { line("H %s", what.c_str()); }
    uint64_t NextDMAAddress(uint64_t size) override {
        uint64_t a = nextDMA;
        nextDMA += (size + 0xFFFFF) & ~0xFFFFFull;
        return a;
    }

    // Counting helpers for the assertions.
    size_t count(const std::string &prefix) const {
        size_t n = 0;
        for (auto &l : lines) if (l.compare(0, prefix.size(), prefix) == 0) n++;
        return n;
    }
    bool wrote(uint64_t off, uint32_t value) const {
        char buf[64];
        snprintf(buf, sizeof(buf), "W 0x%06llx 0x%08x", (unsigned long long)off, value);
        for (auto &l : lines) if (l == buf) return true;
        return false;
    }
    size_t touched(uint64_t off) const {
        char r[32], w[32];
        snprintf(r, sizeof(r), "R 0x%06llx ", (unsigned long long)off);
        snprintf(w, sizeof(w), "W 0x%06llx ", (unsigned long long)off);
        return count(r) + count(w);
    }
};

// ── Lossless trace compaction ───────────────────────────────────────────────
// Three rules, all reversible, so equal compacted files mean equal traces:
//   "W* <first>..<last> <value> n=<N>"  N writes of one value at offsets +4 apart
//   "<read> | W <reg> each of n=<N>: v1 v2 …"  N times: that read, then one write
//   "<line> xN" / "<line A> | <line B> xN"  N repeats of one line or one pair
static std::vector<std::string> Compact(const std::vector<std::string> &in)
{
    std::vector<std::string> a;
    for (size_t i = 0; i < in.size();) {
        unsigned long long off = 0, off2 = 0;
        unsigned val = 0, val2 = 0;
        size_t n = 1;
        if (sscanf(in[i].c_str(), "W 0x%llx 0x%x", &off, &val) == 2) {
            while (i + n < in.size() &&
                   sscanf(in[i + n].c_str(), "W 0x%llx 0x%x", &off2, &val2) == 2 &&
                   off2 == off + 4 * n && val2 == val)
                n++;
        }
        // A message frame: the same read (TX not busy) before each of a run
        // of writes to one register.
        size_t pairs = 0;
        std::string values;
        if (in[i].compare(0, 2, "R ") == 0) {
            while (i + 2 * pairs + 1 < in.size() && in[i + 2 * pairs] == in[i] &&
                   sscanf(in[i + 2 * pairs + 1].c_str(), "W 0x%llx 0x%x", &off2, &val2) == 2 &&
                   (pairs == 0 ? (off = off2, true) : off2 == off)) {
                char v[16];
                snprintf(v, sizeof(v), " %08x", val2);
                values += v;
                pairs++;
            }
        }
        if (pairs >= 3) {
            char buf[64];
            snprintf(buf, sizeof(buf), " | W 0x%06llx each of n=%zu:", off, pairs);
            a.push_back(in[i] + buf + values);
            i += 2 * pairs;
        } else if (n >= 4) {
            char buf[96];
            snprintf(buf, sizeof(buf), "W* 0x%06llx..0x%06llx 0x%08x n=%zu", off, off + 4 * (n - 1), val, n);
            a.push_back(buf);
            i += n;
        } else {
            a.push_back(in[i]);
            i++;
        }
    }
    std::vector<std::string> out;
    for (size_t i = 0; i < a.size();) {
        size_t n1 = 1;
        while (i + n1 < a.size() && a[i + n1] == a[i]) n1++;
        size_t n2 = 1;
        if (i + 1 < a.size() && a[i + 1] != a[i])
            while (i + 2 * n2 + 1 < a.size() && a[i + 2 * n2] == a[i] && a[i + 2 * n2 + 1] == a[i + 1]) n2++;
        if (n2 >= 2 && 2 * n2 > n1) {
            out.push_back(a[i] + " | " + a[i + 1] + " x" + std::to_string(n2));
            i += 2 * n2;
        } else if (n1 >= 2) {
            out.push_back(a[i] + " x" + std::to_string(n1));
            i += n1;
        } else {
            out.push_back(a[i]);
            i++;
        }
    }
    return out;
}

// ── Scenarios ───────────────────────────────────────────────────────────────
struct Options {
    const char *name;
    Port::Kind  port1 = Port::Symphony;
    Port::Kind  port2 = Port::Empty;
    bool        legacy2100 = false;
    bool        dirtyRegisters = false;   // previous session left DMA running
    bool        unplugBeforeStop = false;
    int         portCountProperty = -1;   // -1: key absent
    const char *portCountString = nullptr;
    bool        lateSymphony = false;     // port 1 unit appears after Start
    bool        latePort2 = false;        // port 2 chain appears after Start
    bool        micPreInstrument = false; // fitted MicPre, channel 1 initially Instrument
    bool        micPreSwitches = false;   // with micPreInstrument: MicPre 1 polarity on, MicPre 2 high-pass on
    bool        shortFlow = false;        // Start, StartDevice, link watch, Stop only
    bool        noIoStart = false;        // with shortFlow: Start only, no StartDevice (Core Audio
                                          // has not started IO yet)
    uint32_t    dropVendorReads = 0;      // port 1 Symphony: first N vendor reads unanswered
    uint32_t    dropPort2VendorReads = 0; // port 2 Symphony: first N vendor reads unanswered
    bool        port2OneCard = false;     // port 2 Symphony: one 16-channel card (INQUIRE 0xF8, XTD 0x02)
    bool        port2HoldsAddress = false;// port 2 Symphony: keeps its address over a bus reset
    uint8_t     symphonyInquire = 0;      // port 1 Symphony: INQUIRE reply (0 = none)
    std::vector<Unit> port1Units;         // converters on port 1 other than the default AD,DA
    std::vector<Unit> port2Units;         // converters on port 2 other than the default AD,DA
    int         slotType[2] = { -1, -1 }; // port 1 Symphony: 0xA1 answers (-1: the fake's default)
    std::deque<int> boardTypeScript;      // port 1 Symphony: Port::boardTypeScript from Start
};

static void Attach(Port &p, Port::Kind kind)
{
    p = Port();
    p.kind = kind;
    if (kind == Port::Converters) {
        // An AD-16X style unit followed by a DA-16X style unit. The INQUIRE
        // bytes are placeholders with the channel nibble set; the real values
        // are what the hardware test is meant to report.
        p.units.push_back({ 0x30, 0x00 });
        p.units.push_back({ 0xC0, 0x00 });
    }
}

static const uint64_t kIrqTime = 0x1000;
// Longer than the driver's settle window (kHALMicPreSettleNs, 5 s).
static const uint64_t kKeyPressAfterSettleNs = 6000000000ull;

struct Run {
    FakeCard card;
    SymphonyThunderbridge *drv = nullptr;
    IOPCIDevice *pci = nullptr;
    kern_return_t startResult = kIOReturnError;
};

static void Irq(Run &r, uint64_t count)
{
    r.card.intPending |= kInt_A2HWrap;
    r.drv->InterruptOccurred(nullptr, count, kIrqTime);
}

static void RunScenario(const Options &o, Run &r)
{
    FakeCard &card = r.card;
    gHostBackend = &card;
    gHostAudio = HostAudioRegistry();
    gQueues.clear();
    gHostCompletions.clear();

    if (o.portCountProperty >= 0) card.personalityNumbers["SymphonyPortCount"] = (uint64_t)o.portCountProperty;
    if (o.portCountString) card.personalityStrings["SymphonyPortCount"] = o.portCountString;
    if (o.legacy2100) card.pciDeviceID = kSymphonyPCIeDeviceID;
    card.gatePort2 = o.portCountProperty == 2;
    if (!o.lateSymphony) Attach(card.port[0], o.port1);
    if (!o.port1Units.empty() && o.port1 == Port::Converters) card.port[0].units = o.port1Units;
    card.port[0].dropVendorReads = o.dropVendorReads;
    card.port[0].symphonyInquire = o.symphonyInquire;
    if (o.micPreInstrument) {
        card.port[0].stored[(uint64_t(0xA1) << 32) | 0] = {6};
        card.port[0].stored[(uint64_t(0xA1) << 32) | 1] = {1};
        card.port[0].stored[(uint64_t(0x60) << 32) | 0x80000000u] = {3}; // Mic
        card.port[0].stored[(uint64_t(0x60) << 32) | 0x80000001u] = {4};
        card.port[0].stored[(uint64_t(0x60) << 32) | 0x80000002u] = {0xFF}; // invalid/unknown type
        if (o.micPreSwitches) {
            card.port[0].stored[(uint64_t(0xC5) << 32) | 0] = {1};
            card.port[0].stored[(uint64_t(0xCA) << 32) | 1] = {1};
        }
    }
    for (uint32_t b = 0; b < 2; b++)
        if (o.slotType[b] >= 0) card.port[0].stored[(uint64_t(0xA1) << 32) | b] = { (uint8_t)o.slotType[b] };
    card.port[0].boardTypeScript = o.boardTypeScript;
    if (!o.latePort2) Attach(card.port[1], o.port2);
    if (!o.latePort2 && o.port2 == Port::Converters && !o.port2Units.empty()) card.port[1].units = o.port2Units;
    if (o.port2 == Port::Symphony) {
        // Two cards: all eight banks. One card: what report 6F64285E showed.
        card.port[1].symphonyInquire = o.port2OneCard ? 0xF8 : 0xF8;
        card.port[1].symphonyXtd     = o.port2OneCard ? 0x02 : 0xF2;
        card.port[1].symphonyType    = 0x20;
        card.port[1].symHoldsAddress = o.port2HoldsAddress;
    }
    card.port[1].dropVendorReads = o.dropPort2VendorReads;
    if (o.dirtyRegisters) {
        card.reg[kRegGCSR]  = 0x2db8011b;
        card.reg[kRegGCSR2] = 0x05a0301b;   // DMA bits + both port-disable bits stale
        card.reg[kRegIntMask] = kInt_A2HWrap;
        card.intPending = kInt_A2HWrap;
        card.port[0].sticky = 0x00000231;
        card.port[1].sticky = 0x00000231;
    }

    card.line("== %s", o.name);
    r.pci = new IOPCIDevice;
    r.drv = new SymphonyThunderbridge;
    SymphonyThunderbridge *drv = r.drv;

    card.phase("init + Start");
    drv->init();
    r.startResult = drv->Start(r.pci);
    card.phase("after Start: queued work");
    HostPump();

    const bool configured = !o.lateSymphony && o.port1 != Port::Empty;

    if (o.shortFlow && o.noIoStart) return;
    card.phase("StartDevice");
    kern_return_t sd = drv->StartDevice(1, IOUserAudioStartStopFlags::None);
    CHECK(configured ? sd == kIOReturnSuccess : sd == kIOReturnNotReady,
          "%s: StartDevice returned 0x%x", o.name, sd);

    if (configured && !o.shortFlow) {
        card.phase("interrupts while running");
        Irq(r, 1);
        Irq(r, 2);
        // The recorded key presses happen after the settle window in which the
        // driver takes a control value for coreaudiod's restore and sends
        // nothing (dext 142). Only these presses are moved: the clock is put
        // back, so everything else in the flow is timed as it was recorded.
        gHostMicPreClockOffsetNs += kKeyPressAfterSettleNs;
        if (gHostAudio.volume) gHostAudio.volume->SetDecibelValue(-31.0f);
        Irq(r, 1);
        HostPump();
        CHECK((card.reg[kRegClkCtrl] & 0x70000000u) == 0x70000000u,
              "%s: first Core Audio volume set did not release output (ClkCtrl=0x%08x)",
              o.name, card.reg[kRegClkCtrl]);
        if (gHostAudio.mute) gHostAudio.mute->SetControlValue(true);
        Irq(r, 1);
        HostPump();
        gHostMicPreClockOffsetNs -= kKeyPressAfterSettleNs;
        card.intPending |= kInt_MeterTrigger;      // meter-only interrupt: no audio wrap
        drv->InterruptOccurred(nullptr, 1, kIrqTime);

        card.phase("StopDevice");
        drv->StopDevice(1, IOUserAudioStartStopFlags::None);

        static const double rates[] = { 96000.0, 192000.0, 88200.0, 176400.0, 48000.0, 44100.0 };
        for (double rate : rates) {
            char name[64];
            snprintf(name, sizeof(name), "rate change to %.0f", rate);
            card.phase(name);
            gHostAudio.device->SetSampleRate(rate);
            kern_return_t rc = drv->StartDevice(1, IOUserAudioStartStopFlags::None);
            CHECK(rc == kIOReturnSuccess, "%s: %s returned 0x%x", o.name, name, rc);
            Irq(r, 1);
            drv->StopDevice(1, IOUserAudioStartStopFlags::None);
        }

        card.phase("rate change the units do not follow");
        card.port[0].ignoreRate = true;
        gHostAudio.device->SetSampleRate(96000.0);
        kern_return_t rc = drv->StartDevice(1, IOUserAudioStartStopFlags::None);
        CHECK(rc == kIOReturnIOError, "%s: failed rate change returned 0x%x", o.name, rc);
        card.port[0].ignoreRate = false;
        card.phase("rate change retried");
        rc = drv->StartDevice(1, IOUserAudioStartStopFlags::None);
        CHECK(rc == kIOReturnSuccess, "%s: retried rate change returned 0x%x", o.name, rc);

        card.phase("app commands");
        { uint8_t p = 3;  drv->SendVendorCommand(0xB4, (1u << 16), &p, 1); }
        { uint8_t p[3] = { 5, 70, 1 }; drv->SendVendorCommand(0xB5, 0, p, 3); }
#ifdef kSymphonyMixerInstanceWords
        // D5: a fresh instance reports a nonce and no app mixer state; reading
        // it is host only. B4 (source) is not mixer state; B0-B3 set it per mixer.
        uint32_t mixerInstance[4] = {};
        const size_t instanceMark = card.lines.size();
        CHECK(drv->ReadMixerInstance(mixerInstance) == kIOReturnSuccess &&
              mixerInstance[0] == kSymphonyMixerInstanceMagic &&
              (mixerInstance[2] || mixerInstance[3]) && mixerInstance[1] == 0,
              "%s: fresh instance reports a nonce and no app mixer state", o.name);
        CHECK(card.lines.size() == instanceMark, "%s: mixer instance read has no bus traffic", o.name);
        const uint32_t nonceLo = mixerInstance[2], nonceHi = mixerInstance[3];
#endif
        { uint8_t p = 40; drv->SendVendorCommand(0xB0, (1u << 16) | 1000, &p, 1); }
#ifdef kSymphonyMixerInstanceWords
        drv->ReadMixerInstance(mixerInstance);
        CHECK(mixerInstance[1] == kSymphonyMixerInstanceMixer1Valid,
              "%s: mixer 1 command marks mixer 1 only", o.name);
#endif
        { uint8_t p = 0;  drv->SendVendorCommand(0xB3, (2u << 16) | 4, &p, 1); }
#ifdef kSymphonyMixerInstanceWords
        drv->ReadMixerInstance(mixerInstance);
        CHECK(mixerInstance[1] == (kSymphonyMixerInstanceMixer1Valid | kSymphonyMixerInstanceMixer2Valid) &&
              mixerInstance[2] == nonceLo && mixerInstance[3] == nonceHi,
              "%s: both mixers marked, nonce unchanged", o.name);
#endif
        { uint8_t p = 0;  drv->SendVendorCommand(0x25, 0, &p, 1); }
        { uint8_t p = 50; drv->SendVendorCommand(0xC3, 2, &p, 1); }
        { uint8_t out[4] = {}; drv->ReadVendorCommand(0xA1, 1, out, 1); }
        { uint32_t w[16] = {}; drv->ReadTimingHealth(w); }
        { uint32_t w[16] = {}; drv->ReadLinkState(w); }
        { uint32_t w[kMeterBufferWords] = {}; drv->ReadMeterBuffer(w); }
        drv->RequestClockSource(2);
        drv->RequestOpticalFormat(1, 1);
        drv->RequestPhantom(0, true);
        drv->RequestMicGain(1, 30.0f);
        HostPump();
    }

    card.phase("link watch tick");
    drv->LinkWatchTimerOccurred(nullptr, 0);
    HostPump();

    if (o.lateSymphony) {
        card.phase("port 1 unit powered on");
        Attach(card.port[0], o.port1);
        drv->LinkWatchTimerOccurred(nullptr, 0);
        HostPump();
        card.phase("StartDevice after recovery");
        drv->StartDevice(1, IOUserAudioStartStopFlags::None);
        Irq(r, 1);
    }
    if (o.latePort2) {
        card.phase("port 2 chain powered on");
        Attach(card.port[1], o.port2);
        drv->LinkWatchTimerOccurred(nullptr, 0);
        HostPump();
        drv->LinkWatchTimerOccurred(nullptr, 0);
        HostPump();
    }

    if (o.shortFlow) return;

    card.phase("sleep, then wake with the card intact");
    drv->SetPowerState(kIOServicePowerCapabilityOff);
    drv->SetPowerState(kIOServicePowerCapabilityOn);
    drv->LinkWatchTimerOccurred(nullptr, 0);
    HostPump();

    card.phase("sleep, then wake with the FPGA reset");
    drv->SetPowerState(kIOServicePowerCapabilityOff);
    card.powerCycleFPGA();
    drv->SetPowerState(kIOServicePowerCapabilityOn);
    drv->LinkWatchTimerOccurred(nullptr, 0);
    HostPump();
    drv->LinkWatchTimerOccurred(nullptr, 0);
    HostPump();

    if (configured && o.port1 == Port::Symphony) {
        card.phase("port 1 unit power-cycled");
        Port saved = card.port[0];
        card.port[0] = Port();
        drv->LinkWatchTimerOccurred(nullptr, 0);
        HostPump();
        card.port[0] = saved;
        drv->LinkWatchTimerOccurred(nullptr, 0);
        HostPump();

        card.phase("unit stops answering the health probe");
        card.port[0].answersVendor = false;
        for (int i = 0; i < 7; i++) { uint32_t w[16] = {}; drv->ReadTimingHealth(w); }
        card.port[0].answersVendor = true;
        HostPump();
        for (int i = 0; i < 6; i++) { uint32_t w[16] = {}; drv->ReadTimingHealth(w); HostPump(); }
    }
}

static void Finish(const Options &o, Run &r)
{
    FakeCard &card = r.card;
    if (o.unplugBeforeStop) {
        card.phase("cable pulled");
        card.endpointPresent = false;
    }
    card.phase("Stop");
    r.drv->Stop(r.pci);
    HostPump();
    card.phase("after Stop");
    r.drv->release();
    r.pci->release();
    r.drv = nullptr;
    gHostBackend = nullptr;
}


static std::vector<std::string> Trace(const Options &o)
{
    Run r;
    RunScenario(o, r);
    Finish(o, r);
    return r.card.lines;
}

static bool WriteFile(const std::string &dir, const char *name, const std::vector<std::string> &lines)
{
    std::string path = dir + "/" + name + ".trace";
    FILE *f = fopen(path.c_str(), "w");
    if (!f) { fprintf(stderr, "cannot write %s\n", path.c_str()); return false; }
    for (auto &l : Compact(lines)) fprintf(f, "%s\n", l.c_str());
    fclose(f);
    return true;
}

// ── Volume keys on a cable of converters only ──────────────────────────────
// Not traces: explicit checks of where the Core Audio volume and mute go.
// A Symphony I/O must always get SpeakerVolume/SpeakerMute; converters get a
// trim on card mixer 1 (return slots 128/129 while the app has sent no mixer
// state), and nothing else may change.
#ifdef TRACE_HAVE_CONVERTER_VOLUME
static uint32_t Mixer1Return(Run &r) { return r.card.reg[MixerCoefOffset(0, 128)]; }

// A key pressed by a person: after the settle window (see RunScenario), and
// after the driver has looked at the controls once since it was armed.
static void PressVolume(Run &r, float db)
{
    gHostMicPreClockOffsetNs += kKeyPressAfterSettleNs;
    Irq(r, 1);
    HostPump();
    gHostAudio.volume->SetDecibelValue(db);
    Irq(r, 1);
    HostPump();
    gHostMicPreClockOffsetNs -= kKeyPressAfterSettleNs;
}

static void PressMute(Run &r, bool muted)
{
    gHostMicPreClockOffsetNs += kKeyPressAfterSettleNs;
    Irq(r, 1);
    HostPump();
    gHostAudio.mute->SetControlValue(muted);
    Irq(r, 1);
    HostPump();
    gHostMicPreClockOffsetNs -= kKeyPressAfterSettleNs;
}

// A control value that arrives inside the settle window: coreaudiod putting
// back what it saved.
static void RestoreByCoreAudio(Run &r, float db, bool muted)
{
    gHostAudio.volume->SetDecibelValue(db);
    gHostAudio.mute->SetControlValue(muted);
    Irq(r, 1);
    HostPump();
}

static bool LinkSaysConverterKeys(Run &r)
{
    uint32_t w[16] = {};
    r.drv->ReadLinkState(w);
    return (w[15] & 0x10000000u) != 0;
}

static uint8_t StoredVendor(Run &r, uint8_t cmd)
{
    auto it = r.card.port[0].stored.find((uint64_t)cmd << 32);
    return (it == r.card.port[0].stored.end() || it->second.empty()) ? 0xFF : it->second[0];
}

static uint8_t StoredVendorPort(Run &r, uint8_t cmd, uint32_t value = 0)
{
    auto it = r.card.port[1].stored.find((uint64_t)cmd << 32 | value);
    return (it == r.card.port[1].stored.end() || it->second.empty()) ? 0xFF : it->second[0];
}

#if defined(TRACE_HAVE_PORT2_AUDIO) && defined(kSelectorSetMonitorDevice)
static size_t Select(Run &r, uint32_t value, const char *phase, bool ioRunning);
static void RunMonitorDeviceChecks()
{
    Options o; o.name = "monitor device: unit B and fallback"; o.port2 = Port::Symphony;
    o.portCountProperty = 2; o.shortFlow = true;
    Run r;
    RunScenario(o, r);
    Select(r, 1, "select 64 for monitor device", false);
    uint8_t quiet = 55;
    CHECK(r.drv->SendVendorCommand(0x26, 0, &quiet, 1, 1) == kIOReturnSuccess, "seed B");
    CHECK(r.drv->SetMonitorDevice(1) == kIOReturnSuccess, "select quiet B");
    Irq(r, 1); HostPump();
    CHECK(StoredVendorPort(r, 0x26) == 55, "positive control: B must start at -55");
    uint8_t stereo = 1;
    CHECK(r.drv->SendVendorCommand(0x25, 0, &stereo, 1) == kIOReturnSuccess, "A speaker mode");
    CHECK(gHostAudio.volume->GetDecibelValue() == -55.0f, "43 dB regression: A mode published into B HAL");
    Irq(r, 1); HostPump();
    CHECK(StoredVendorPort(r, 0x26) == 55, "43 dB regression: interrupt raised B from -55 to -12");
    uint8_t aLevel = 24;
    CHECK(r.drv->SendVendorCommand(0x26, 0, &aLevel, 1) == kIOReturnSuccess, "physical A UI/knob write");
    Irq(r, 1); HostPump();
    CHECK(gHostAudio.volume->GetDecibelValue() == -55.0f, "A physical write touched B HAL");
    CHECK(StoredVendorPort(r, 0x26) == 55, "A physical write touched B hardware");
    // A knob observations update A's cache without any echo, even with B selected.
    r.card.port[0].stored[(uint64_t(0x28) << 32) | 1] = {0,0,172,68,1,0,0,2,2,29,1,0};
    uint8_t observation[12] = {};
    CHECK(r.drv->ReadVendorCommand(0x28, 1, observation, 12) == kIOReturnSuccess, "A knob observation");
    Irq(r, 1); HostPump();
    CHECK(StoredVendor(r, 0x26) == 24, "front panel observation echoed a hardware write");
    CHECK(StoredVendorPort(r, 0x26) == 55, "A knob raised B");
    CHECK(gHostAudio.volume->GetDecibelValue() == -55.0f, "A knob published into B HAL");
    CHECK(r.drv->SetMonitorDevice(0) == kIOReturnSuccess, "select A");
    CHECK(gHostAudio.volume->GetDecibelValue() == -29.0f, "A selection must restore A cache");
    Irq(r, 1); HostPump();
    CHECK(gHostAudio.mute->GetControlValue(), "A mute observation not restored");
    // A pending IRQ sample is consumed for A before B selection, never retargeted.
    gHostMicPreClockOffsetNs += kKeyPressAfterSettleNs;   // a person's key press
    gHostAudio.volume->SetDecibelValue(-30.0f);
    gHostAudio.mute->SetControlValue(false);
    Irq(r, 1);
    CHECK(r.drv->SetMonitorDevice(1) == kIOReturnSuccess, "reselect B");
    HostPump();
    gHostMicPreClockOffsetNs -= kKeyPressAfterSettleNs;
    CHECK(StoredVendorPort(r, 0x26) == 55, "pending A sample retargeted B");
    CHECK(StoredVendor(r, 0x26) == 30, "pending A volume did not stay with A");
    CHECK(StoredVendor(r, 0x27) == 0, "pending A mute did not stay with A");
    CHECK(!gHostAudio.mute->GetControlValue(), "selection must restore B mute");
    r.card.port[0].stored.erase((uint64_t)0x26 << 32);
    r.card.port[1].stored.erase((uint64_t)0x26 << 32);
    CHECK(r.drv->SetMonitorDevice(1) == kIOReturnSuccess, "%s: selecting unit B failed", o.name);
    PressVolume(r, -33.0f);
    CHECK(StoredVendorPort(r, 0x26) == 33, "%s: volume did not reach unit B speaker target", o.name);
    CHECK(StoredVendor(r, 0x26) == 0xFF, "%s: unit A received unit B volume", o.name);
    r.card.port[1] = Port();
    r.card.port[1].stored.erase((uint64_t)0x26 << 32);
    r.card.port[0].stored.erase((uint64_t)0x26 << 32);
    r.drv->LinkWatchTimerOccurred(nullptr, 0);
    HostPump();
    CHECK(gHostAudio.volume->GetDecibelValue() == -30.0f, "B loss must restore A real value");
    Irq(r, 1); HostPump();
    CHECK(StoredVendor(r, 0x26) == 0xFF, "fallback must not echo stale B attenuation to A");
    PressVolume(r, -21.0f);
    CHECK(StoredVendor(r, 0x26) == 21, "%s: fallback volume did not reach unit A", o.name);
    CHECK(StoredVendorPort(r, 0x26) == 0xFF, "%s: fallback rewrote unit B unexpectedly", o.name);
    uint8_t hp = 44, line = 0;
    CHECK(r.drv->SendVendorCommand(0x23, 0, &hp, 1) == kIOReturnSuccess, "seed A HP1");
    CHECK(gHostAudio.volume->GetDecibelValue() == -21.0f, "nonselected HP1 changed speaker HAL");
    CHECK(r.drv->SendVendorCommand(0x25, 0, &line, 1) == kIOReturnSuccess, "select A Line");
    // No output has been chosen by the app here: the keys follow the mode,
    // Headphone 1 in Line (dext 142 as before).
    CHECK(gHostAudio.volume->GetDecibelValue() == -44.0f, "Line mode failed to restore HP1");
    Irq(r, 1); HostPump();
    CHECK(StoredVendor(r, 0x26) == 21, "Line transition overwrote speakers");
    CHECK(StoredVendor(r, 0x23) == 44, "Line transition overwrote HP1");
    CHECK(r.drv->SendVendorCommand(0x25, 0, &stereo, 1) == kIOReturnSuccess, "restore A speakers");
    CHECK(gHostAudio.volume->GetDecibelValue() == -21.0f, "Stereo failed to restore speaker level");
    Finish(o, r);
}
#endif

// dext 140: a clock source chosen since Start() is what a later set-up sends
// (wake, an FPGA reset, a power-cycled unit, a failed health probe), as the
// original re-applied its saved source (SymphonyIO.cpp:4660-4695). The first
// set-up sends Internal.
void SymphonySyncHardwareRate(IOUserAudioDevice *device, double rate, uint64_t changeAction, const char *why);

static void RunClockReapplyChecks()
{
    {
        Options o; o.name = "clock: Word Clock survives every re-initialisation";
        Run r; RunScenario(o, r);   // the full flow selects source 2, then sleeps, resets and recovers
        auto it = r.card.port[0].stored.find((uint64_t)0x50 << 32);
        const bool ok = it != r.card.port[0].stored.end() && it->second.size() == 4 &&
                        it->second[0] == 2 && it->second[1] == 1;
        CHECK(ok, "%s: the unit's last ClockMode is source %u (want Word Clock, master)", o.name,
              it == r.card.port[0].stored.end() || it->second.empty() ? 0xFFu : it->second[0]);
        // Internal was sent exactly once: by the first set-up.
        size_t internal = 0, word = 0;
        for (size_t i = 0; i + 0 < r.card.port[0].clockModes.size(); i++)
            (r.card.port[0].clockModes[i] == 1 ? internal : word)++;
        CHECK(internal == 1 && word >= 2, "%s: ClockMode sent Internal %zu time(s), other %zu (want 1, several)",
              o.name, internal, word);
        Finish(o, r);
    }
    // Cold start (issue 31): Core Audio restores Word Clock while the hardware
    // is at 44.1 kHz; the first rate change must send the source again, at the
    // new rate. Internal sends nothing extra.
    for (uint32_t source : { 2u, 1u }) {
        Options o; o.name = source == 2 ? "clock: Word Clock sent again after the first rate change"
                                        : "clock: Internal is not sent again after a rate change";
        o.shortFlow = true;
        Run r; RunScenario(o, r);
        r.drv->StopDevice(1, IOUserAudioStartStopFlags::None);
        r.drv->RequestClockSource(source); HostPump();
        r.card.port[0].clockModes.clear();
        gHostAudio.device->SetSampleRate(96000.0);
        r.drv->StartDevice(1, IOUserAudioStartStopFlags::None);
        HostPump();
        const auto &sent = r.card.port[0].clockModes;
        if (source == 2)
            CHECK(sent.size() == 1 && sent[0] == 2, "%s: %zu ClockMode message(s) after the rate change", o.name, sent.size());
        else
            CHECK(sent.empty(), "%s: %zu ClockMode message(s) after the rate change", o.name, sent.size());
        r.drv->StopDevice(1, IOUserAudioStartStopFlags::None);
        Finish(o, r);
    }
    // dext 141 (issue 31, second report): a rate set with no IO start reaches
    // the hardware at once, as the original's performFormatChange did, and
    // the external clock source follows it. The IO start after it has nothing
    // left to do. With IO running nothing is touched.
    {
        Options o; o.name = "clock: a rate set with audio idle reaches the unit, Word Clock after it";
        o.shortFlow = true;
        Run r; RunScenario(o, r);
        r.drv->RequestClockSource(2); HostPump();
        const uint8_t before = r.card.port[0].rateCode;
        r.card.port[0].clockModes.clear();
        gHostAudio.device->SetSampleRate(48000.0);
        SymphonySyncHardwareRate(gHostAudio.device, 48000.0, 0, "test, IO running");
        HostPump();
        CHECK(r.card.port[0].rateCode == before && r.card.port[0].clockModes.empty(),
              "%s: hardware touched while IO was running", o.name);
        r.drv->StopDevice(1, IOUserAudioStartStopFlags::None);
        // A host configuration change (any action but the driver's own) does nothing.
        SymphonySyncHardwareRate(gHostAudio.device, 0.0, 3, "test, host change");
        HostPump();
        CHECK(r.card.port[0].rateCode == before && r.card.port[0].clockModes.empty(),
              "%s: hardware touched on a host configuration change", o.name);
        // The driver's "link recovered" change applies the device's rate.
        SymphonySyncHardwareRate(gHostAudio.device, 0.0, 0x4C4E4B52ULL, "test, link recovered");
        HostPump();
        const auto &sent = r.card.port[0].clockModes;
        CHECK(r.card.port[0].rateCode != before, "%s: the unit's rate code stayed 0x%02x", o.name, before);
        CHECK(sent.size() == 1 && sent[0] == 2, "%s: %zu ClockMode message(s) after the idle rate change", o.name, sent.size());
        const uint8_t after = r.card.port[0].rateCode;
        r.drv->StartDevice(1, IOUserAudioStartStopFlags::None);
        HostPump();
        CHECK(r.card.port[0].clockModes.size() == 1 && r.card.port[0].rateCode == after,
              "%s: the IO start changed the rate or sent the clock again", o.name);
        r.drv->StopDevice(1, IOUserAudioStartStopFlags::None);
        Finish(o, r);
    }
    {
        Options o; o.name = "clock: nothing chosen stays Internal"; o.shortFlow = true;
        Run r; RunScenario(o, r);
        // The short flow selects nothing. Choose Internal and recover:
        // Internal is what is re-applied.
        r.drv->RequestClockSource(1); HostPump();
        Port saved = r.card.port[0];
        r.card.port[0] = Port();
        r.drv->LinkWatchTimerOccurred(nullptr, 0); HostPump();
        r.card.port[0] = saved;
        r.card.port[0].clockModes.clear();
        r.drv->LinkWatchTimerOccurred(nullptr, 0); HostPump();
        CHECK(!r.card.port[0].clockModes.empty() && r.card.port[0].clockModes.back() == 1,
              "%s: recovery sent source %u", o.name,
              r.card.port[0].clockModes.empty() ? 0xFFu : r.card.port[0].clockModes.back());
        Finish(o, r);
    }
}

static void RunVolumeKeyChecks()
{
    // 1. A Symphony I/O that misses its first answer and replies to INQUIRE
    //    like a DA-16X: the later reads answer, so it stays a Symphony.
    {
        Options o; o.name = "volume keys: Symphony, first read lost"; o.shortFlow = true;
        Run r;
        o.dropVendorReads = 1;
        o.symphonyInquire = 0xC0;
        RunScenario(o, r);
        const uint32_t before = Mixer1Return(r);
        PressVolume(r, -31.0f);
        PressMute(r, true);
        CHECK(StoredVendor(r, 0x26) == 31, "%s: SpeakerVolume %u (want 31)", o.name, StoredVendor(r, 0x26));
        CHECK(StoredVendor(r, 0x27) == 1, "%s: SpeakerMute %u (want 1)", o.name, StoredVendor(r, 0x27));
        CHECK(Mixer1Return(r) == before, "%s: mixer 1 changed 0x%08x -> 0x%08x", o.name, before, Mixer1Return(r));
        CHECK(!LinkSaysConverterKeys(r), "%s: link state reports converter volume keys", o.name);
        Finish(o, r);
    }
    // 1b. A Symphony I/O that answers no vendor read at all during bring-up
    //     but answers INQUIRE with 0xF (what the original's routing 0xFF looks
    //     like without its XTD half, the same nibble as a DD-16X): never a
    //     converter, the keys still reach it.
    {
        Options o; o.name = "volume keys: Symphony, every read lost, INQUIRE 0xF"; o.shortFlow = true;
        Run r;
        o.dropVendorReads = 8;
        o.symphonyInquire = 0xF0;
        RunScenario(o, r);
        CHECK(!LinkSaysConverterKeys(r), "%s: link state reports converter volume keys", o.name);
#ifdef kSelectorSetMonitorOutput
        // dext 142: while its levels cannot be read, a key sends nothing.
        {
            r.card.port[0].dropVendorReads = 1;
            const size_t writes = r.card.port[0].vendorWrites.size();
            PressVolume(r, -31.0f);
            CHECK(r.card.port[0].vendorWrites.size() == writes && gHostAudio.volume->GetDecibelValue() == -20.0f,
                  "%s: a level was sent to a unit whose level could not be read", o.name);
            r.card.port[0].dropVendorReads = 0;
        }
        // dext 142: its levels were never read, so the first key is not sent:
        // the levels are read and the control shows the unit's (20: the
        // bring-up wrote its fallback when no read answered, as before).
        PressVolume(r, -31.0f);
        CHECK(StoredVendor(r, 0x26) == 20 && gHostAudio.volume->GetDecibelValue() == -20.0f,
              "%s: a level was sent before the unit's was read (%u, control %.1f)", o.name,
              StoredVendor(r, 0x26), gHostAudio.volume->GetDecibelValue());
#endif
        PressVolume(r, -31.0f);
        CHECK(StoredVendor(r, 0x26) == 31, "%s: SpeakerVolume %u (want 31)", o.name, StoredVendor(r, 0x26));
        CHECK(Mixer1Return(r) == kMixerUnityCoeff, "%s: mixer 1 trimmed (0x%08x)", o.name, Mixer1Return(r));
        Finish(o, r);
    }
    // 1c. Converters powered on after Start(): the control is at the -20 dB
    //     fallback, and the trim takes that level rather than jumping to 0 dB.
    {
        Options o; o.name = "volume keys: converters powered on late"; o.port1 = Port::Converters;
        o.lateSymphony = true; o.shortFlow = true;
        Run r;
        RunScenario(o, r);
        CHECK(LinkSaysConverterKeys(r), "%s: link state does not report converter volume keys", o.name);
        CHECK(gHostAudio.volume && gHostAudio.volume->GetDecibelValue() == -20.0f,
              "%s: control at %.1f dB (want -20, unchanged)", o.name,
              gHostAudio.volume ? gHostAudio.volume->GetDecibelValue() : 99.0f);
        CHECK(Mixer1Return(r) == 0x03330000, "%s: mixer 1 return 0x%08x (want -20 dB, 0x03330000)", o.name, Mixer1Return(r));
        // The app's speaker-mode command (Reset Defaults, presets) must not move it.
        { uint8_t m = 2; r.drv->SendVendorCommand(0x25, 0, &m, 1); }
        HostPump();
        CHECK(gHostAudio.volume->GetDecibelValue() == -20.0f, "%s: speaker mode moved the control to %.1f dB",
              o.name, gHostAudio.volume->GetDecibelValue());
        Finish(o, r);
    }
    // 2. Converters only: the control starts at 0 dB, every 4 dB key step is a
    //    distinct, lower level down to -64 dB, and mute silences mixer 1.
    {
        Options o; o.name = "volume keys: converters"; o.port1 = Port::Converters; o.shortFlow = true;
        Run r;
        RunScenario(o, r);
        CHECK(gHostAudio.volume && gHostAudio.volume->GetDecibelValue() == 0.0f,
              "%s: control starts at %.1f dB (want 0)", o.name,
              gHostAudio.volume ? gHostAudio.volume->GetDecibelValue() : 99.0f);
        CHECK(Mixer1Return(r) == kMixerUnityCoeff, "%s: mixer 1 return 0x%08x before any key", o.name, Mixer1Return(r));
        CHECK(LinkSaysConverterKeys(r), "%s: link state does not report converter volume keys", o.name);
        uint32_t last = Mixer1Return(r);
        for (int db = -4; db >= -64; db -= 4) {
            PressVolume(r, (float)db);
            const uint32_t c = Mixer1Return(r);
            CHECK(c != kMixerMuteCoeff && c < last, "%s: %d dB gives 0x%08x (previous 0x%08x)", o.name, db, c, last);
            last = c;
        }
        PressVolume(r, -31.0f);
        CHECK(Mixer1Return(r) == SymphonyMixerCoef(-31, 128) /* 0x00e60000: the original's truncation; the old table rounded to 0x00e7 */, "%s: -31 dB gives 0x%08x", o.name, Mixer1Return(r));
        PressMute(r, true);
        CHECK(Mixer1Return(r) == kMixerMuteCoeff, "%s: mute gives 0x%08x", o.name, Mixer1Return(r));
        PressMute(r, false);
        CHECK(Mixer1Return(r) == SymphonyMixerCoef(-31, 128) /* 0x00e60000: the original's truncation; the old table rounded to 0x00e7 */, "%s: unmute gives 0x%08x", o.name, Mixer1Return(r));
        CHECK(StoredVendor(r, 0x26) == 0xFF, "%s: a converter was sent SpeakerVolume", o.name);

        // 3. A card reset keeps the trim.
        r.card.phase("FPGA reset");
        r.drv->SetPowerState(kIOServicePowerCapabilityOff);
        r.card.powerCycleFPGA();
        r.drv->SetPowerState(kIOServicePowerCapabilityOn);
        r.drv->LinkWatchTimerOccurred(nullptr, 0); HostPump();
        r.drv->LinkWatchTimerOccurred(nullptr, 0); HostPump();
        CHECK(Mixer1Return(r) == SymphonyMixerCoef(-31, 128) /* 0x00e60000: the original's truncation; the old table rounded to 0x00e7 */, "%s: after a card reset 0x%08x", o.name, Mixer1Return(r));

        // 4. The converters are replaced by a Symphony I/O: the trim goes and
        //    the keys reach the Symphony again.
        r.card.phase("converters replaced by a Symphony");
        r.card.port[0] = Port();
        r.drv->LinkWatchTimerOccurred(nullptr, 0); HostPump();
        Attach(r.card.port[0], Port::Symphony);
        r.drv->LinkWatchTimerOccurred(nullptr, 0); HostPump();
        r.drv->StartDevice(1, IOUserAudioStartStopFlags::None);
        CHECK(Mixer1Return(r) == kMixerUnityCoeff, "%s: trim left on a Symphony (0x%08x)", o.name, Mixer1Return(r));
        CHECK(!LinkSaysConverterKeys(r), "%s: link state still reports converter keys after the swap", o.name);
        // The control and the replay take the Symphony's stored level (12 dB
        // in the fake), not the converter trim, so its speakers do not jump.
        CHECK(gHostAudio.volume->GetDecibelValue() == -12.0f, "%s: control at %.1f dB after the swap (want -12)",
              o.name, gHostAudio.volume->GetDecibelValue());
        CHECK(StoredVendor(r, 0x26) == 12, "%s: recovery sent SpeakerVolume %u (want 12)", o.name, StoredVendor(r, 0x26));
        PressVolume(r, -20.0f);
        CHECK(StoredVendor(r, 0x26) == 20, "%s: Symphony SpeakerVolume %u after the swap (want 20)",
              o.name, StoredVendor(r, 0x26));
        Finish(o, r);
    }
}

#ifdef kSelectorSetMonitorOutput
// ── dext 142: the keys' output is the app's choice ("Audio Output") ────────
// Speakers by default; Headphone 1 or 2 only when chosen; with Speakers chosen
// in Line mode nothing is written; converters: the card mixer level or None.
static uint8_t StoredOn(Run &r, unsigned port, uint8_t cmd, uint32_t value = 0)
{
    auto it = r.card.port[port].stored.find(((uint64_t)cmd << 32) | value);
    return (it == r.card.port[port].stored.end() || it->second.empty()) ? 0xFF : it->second[0];
}

static void ResetCardAndRecover(Run &r)
{
    r.card.phase("FPGA reset");
    r.drv->SetPowerState(kIOServicePowerCapabilityOff);
    r.card.powerCycleFPGA();
    r.drv->SetPowerState(kIOServicePowerCapabilityOn);
    r.drv->LinkWatchTimerOccurred(nullptr, 0); HostPump();
    r.drv->LinkWatchTimerOccurred(nullptr, 0); HostPump();
}

// dext 152: Core Audio restoring the clock source or an optical format the
// unit already took on this link is not sent again; a different value is,
// and so is anything after a path that does not record what it sent. A link
// recovery sends both again (its own configuration step).
static size_t OpticalWrites(const Run &r, size_t from)
{
    size_t n = 0;
    const auto &w = r.card.port[0].vendorWrites;
    for (size_t i = from; i < w.size(); i++) if (w[i] == 0x34) n++;
    return n;
}

static void RunSameValueChecks()
{
    Options o; o.name = "same value: ClockMode and optical format not sent again"; o.shortFlow = true;
    Run r; RunScenario(o, r);
    auto &clock = r.card.port[0].clockModes;
    clock.clear();
    size_t mark = r.card.port[0].vendorWrites.size();
    // Start sent Internal and ADAT/SMUX: Core Audio's restore of them is not sent.
    r.drv->RequestClockSource(1); HostPump();
    r.drv->RequestClockSource(1); HostPump();
    r.drv->RequestOpticalFormat(1, 0); HostPump();
    r.drv->RequestOpticalFormat(0, 0); HostPump();
    CHECK(clock.empty() && OpticalWrites(r, mark) == 0,
          "%s: %zu ClockMode, %zu OpticalFormat sent for values the unit has", o.name, clock.size(), OpticalWrites(r, mark));
    // A change is sent once; the same again is not.
    r.drv->RequestClockSource(2); HostPump();
    r.drv->RequestClockSource(2); HostPump();
    r.drv->RequestOpticalFormat(1, 1); HostPump();
    r.drv->RequestOpticalFormat(1, 1); HostPump();
    CHECK(clock.size() == 1 && clock[0] == 2 && OpticalWrites(r, mark) == 1,
          "%s: change: %zu ClockMode, %zu OpticalFormat (want 1, 1)", o.name, clock.size(), OpticalWrites(r, mark));
    r.drv->RequestClockSource(1); HostPump();
    CHECK(clock.size() == 2 && clock[1] == 1, "%s: back to Internal not sent (%zu)", o.name, clock.size());
    // An optical format sent on the vendor path is not known: the next
    // request is sent.
    { uint8_t p = 0; r.drv->SendVendorCommand(0x34, 1, &p, 1); }
    mark = r.card.port[0].vendorWrites.size();
    r.drv->RequestOpticalFormat(1, 0); HostPump();
    CHECK(OpticalWrites(r, mark) == 1, "%s: optical after a vendor-path send: %zu sent (want 1)", o.name, OpticalWrites(r, mark));
    // A ClockMode sent on the vendor path is recorded as sent.
    clock.clear();
    { uint8_t p[4] = { 2, 1, 0, 0 }; r.drv->SendVendorCommand(0x50, 0, p, 4); }
    r.drv->RequestClockSource(2); HostPump();
    CHECK(clock.size() == 1, "%s: Word Clock after the vendor path's Word Clock: %zu ClockMode (want 1)", o.name, clock.size());
    // A link recovery: the configuration sends the clock and the format
    // again, and records them.
    clock.clear();
    mark = r.card.port[0].vendorWrites.size();
    ResetCardAndRecover(r);
    CHECK(!clock.empty() && clock.back() == 2 && OpticalWrites(r, mark) >= 1,
          "%s: recovery: %zu ClockMode (last %u), %zu OpticalFormat (want the clock and the format sent)", o.name,
          clock.size(), clock.empty() ? 0xFFu : clock.back(), OpticalWrites(r, mark));
    const size_t afterRecovery = clock.size();
    mark = r.card.port[0].vendorWrites.size();
    r.drv->RequestClockSource(2); HostPump();
    r.drv->RequestOpticalFormat(1, 0); HostPump();
    CHECK(clock.size() == afterRecovery && OpticalWrites(r, mark) == 0,
          "%s: after recovery the same values were sent again (%zu ClockMode, %zu OpticalFormat)", o.name,
          clock.size() - afterRecovery, OpticalWrites(r, mark));
    Finish(o, r);
}

static float ShownDb() { return gHostAudio.volume->GetDecibelValue(); }

// Every card output channel direct, none on a mixer output slot. exact: channel
// n plays software output n. Otherwise (converters, whose routing layer places
// the units and leaves unused entries disabled) every enabled entry plays a
// software output.
static void CheckOutputsDirect(const char *what, Run &r, uint32_t channels, bool exact)
{
    uint32_t enabled = 0;
    for (uint32_t n = 0; n < channels; n++) {
        const uint32_t word = r.card.reg[kRegOutputRouting + n * 4];
        const uint32_t slot = word & 0xFFu;
        if (!(word & kRoutingEnable)) continue;
        enabled++;
        CHECK(slot >= kTDM_PCIOut0 && slot < kTDM_PCIOut0 + 64,
              "%s: output %u is not fed from a software output (0x%03x)", what, n, word);
        CHECK(slot < kTDM_Mixer0Out, "%s: output %u is on a mixer (0x%03x)", what, n, word);
    }
    CHECK(enabled > 0, "%s: no output is enabled", what);
    for (uint32_t n = 0; n < channels; n++) {
        const uint32_t word = r.card.reg[kRegOutputRouting + n * 4];
        if (exact) CHECK(word == ((kTDM_PCIOut0 + n) | kRoutingEnable), "%s: output %u = 0x%03x (want 0x%03x)",
                         what, n, word, (kTDM_PCIOut0 + n) | kRoutingEnable);
    }
}

static bool Sent(Run &r, unsigned port, uint8_t cmd)
{
    auto &w = r.card.port[port].vendorWrites;
    return std::find(w.begin(), w.end(), cmd) != w.end();
}

#ifdef TRACE_HAVE_USERCLIENT
// Selector 15 as the app calls it: through SymphonyUserClient::ExternalMethod.
static kern_return_t CallMonitorOutputRaw(Run &r, const void *bytes, size_t length, uint64_t selector = kSelectorSetMonitorOutput)
{
    auto *client = new SymphonyUserClient;
    client->init();
    client->SetDriver(r.drv);
    IOUserClientMethodArguments arguments;
    arguments.selector = selector;
    arguments.structureInput = length ? OSData::withBytes(bytes, length) : nullptr;
    const kern_return_t result = client->ExternalMethod(selector, &arguments, nullptr, nullptr, nullptr);
    if (arguments.structureInput) arguments.structureInput->release();
    if (arguments.structureOutput) arguments.structureOutput->release();
    client->release();
    return result;
}

static kern_return_t CallMonitorOutput(Run &r, uint32_t unit, uint32_t output, uint32_t magic = kSymphonyUCMagic)
{
    const SymphonyMonitorOutputInput input = { magic, unit, output };
    return CallMonitorOutputRaw(r, &input, sizeof(input));
}

static void CheckMonitorOutputSelector(const char *name, Run &r)
{
    const float before = ShownDb();
    const size_t writes = r.card.port[0].vendorWrites.size();
    const uint32_t words[4] = { kSymphonyUCMagic, 0, kSymphonyMonitorOutputHP1, 0 };
    CHECK(CallMonitorOutputRaw(r, words, 8) == kIOReturnBadArgument, "%s: selector 15 took an 8-byte input", name);
    CHECK(CallMonitorOutputRaw(r, words, 16) == kIOReturnBadArgument, "%s: selector 15 took a 16-byte input", name);
    CHECK(CallMonitorOutputRaw(r, nullptr, 0) == kIOReturnBadArgument, "%s: selector 15 took no input", name);
    CHECK(CallMonitorOutput(r, 0, kSymphonyMonitorOutputHP1, 0x12345678u) == kIOReturnBadArgument, "%s: selector 15 took a bad magic", name);
    CHECK(CallMonitorOutput(r, 2, kSymphonyMonitorOutputHP1) == kIOReturnBadArgument, "%s: selector 15 took unit 2", name);
    CHECK(CallMonitorOutput(r, 0, 4) == kIOReturnBadArgument, "%s: selector 15 took output 4", name);
    CHECK(CallMonitorOutput(r, 0, kSymphonyMonitorOutputNone) == kIOReturnBadArgument, "%s: selector 15 took None for a Symphony I/O", name);
    CHECK(CallMonitorOutput(r, 1, kSymphonyMonitorOutputHP1) == kIOReturnNotReady, "%s: selector 15 took unit B at 32 channels", name);
    CHECK(CallMonitorOutputRaw(r, words, 12, kSelectorCount) == kIOReturnBadArgument, "%s: a selector past the table was taken", name);
    CHECK(ShownDb() == before && r.card.port[0].vendorWrites.size() == writes, "%s: a refused selector 15 call changed something", name);
    // A valid call reaches the driver: Headphone 1 (18 in the fake), and back.
    CHECK(CallMonitorOutput(r, 0, kSymphonyMonitorOutputHP1) == kIOReturnSuccess, "%s: selector 15 refused Headphone 1", name);
    CHECK(ShownDb() == -18.0f, "%s: selector 15 did not reach the driver (control %.1f, want -18)", name, ShownDb());
    CHECK(CallMonitorOutput(r, 0, kSymphonyMonitorOutputSpeakers) == kIOReturnSuccess, "%s: selector 15 refused Speakers", name);
    CHECK(ShownDb() == before, "%s: selector 15 did not go back to the speakers (%.1f)", name, ShownDb());
}
#endif

// A speaker or headphone level or mute Maestro writes through the driver is
// kept as written and survives a link recovery (the review of 0.9.23 found a
// dangling else that dropped the speaker mute and derived the headphone mute
// from its level).
static void RunAppMonitorWriteRecoveryChecks()
{
    {
        Options o; o.name = "app monitor writes: speaker mute"; o.shortFlow = true;
        Run r; RunScenario(o, r);
        uint8_t one = 1;
        CHECK(r.drv->SendVendorCommand(0x27, 0, &one, 1) == kIOReturnSuccess, "%s: send", o.name);
        CHECK(gHostAudio.mute->GetControlValue(), "%s: the Mac's mute control does not show the app's speaker mute", o.name);
        ResetCardAndRecover(r);
        CHECK(StoredOn(r, 0, 0x27) == 1, "%s: a link recovery unmuted the speakers (0x27=%u)", o.name, StoredOn(r, 0, 0x27));
    }
    {
        Options o; o.name = "app monitor writes: headphone level"; o.shortFlow = true;
        Run r; RunScenario(o, r);
        CHECK(r.drv->SetMonitorOutput(0, kSymphonyMonitorOutputHP1) == kIOReturnSuccess, "%s: HP1 refused", o.name);
        uint8_t lvl = 30;
        CHECK(r.drv->SendVendorCommand(0x23, 0, &lvl, 1) == kIOReturnSuccess, "%s: send", o.name);
        CHECK(!gHostAudio.mute->GetControlValue(), "%s: a headphone level showed as muted", o.name);
        ResetCardAndRecover(r);
        CHECK(StoredOn(r, 0, 0x24, 0) == 0, "%s: a link recovery muted Headphone 1 (0x24=%u)", o.name, StoredOn(r, 0, 0x24, 0));
    }
    {
        Options o; o.name = "app monitor writes: muted headphone at full level"; o.shortFlow = true;
        Run r; RunScenario(o, r);
        uint8_t one = 1, zero = 0;
        CHECK(r.drv->SendVendorCommand(0x24, 0, &one, 1) == kIOReturnSuccess, "%s: mute", o.name);
        CHECK(r.drv->SendVendorCommand(0x23, 0, &zero, 1) == kIOReturnSuccess, "%s: level", o.name);
        ResetCardAndRecover(r);
        CHECK(StoredOn(r, 0, 0x24, 0) == 1 && StoredOn(r, 0, 0x23, 0) == 0,
              "%s: after recovery Headphone 1 mute=%u level=%u (want muted at 0)", o.name, StoredOn(r, 0, 0x24, 0), StoredOn(r, 0, 0x23, 0));
    }
}

static void RunMonitorOutputChecks()
{
    // 1. One Symphony I/O.
    {
        Options o; o.name = "audio output: unit A"; o.shortFlow = true;
        Run r;
        RunScenario(o, r);
        // The start-up table: direct, and no unit mixer strip muted.
        CheckOutputsDirect("Symphony I/O on port 1, after Start", r, 32, true);
        CHECK(!Sent(r, 0, 0xB3), "%s: Start still mutes the unit's mixer inputs (0xB3)", o.name);
        // Default: the speakers.
        PressVolume(r, -31.0f); PressMute(r, true);
        CHECK(StoredOn(r, 0, 0x26) == 31 && StoredOn(r, 0, 0x27) == 1, "%s: default output is not the speakers (%u/%u)",
              o.name, StoredOn(r, 0, 0x26), StoredOn(r, 0, 0x27));
        PressMute(r, false);
#ifdef TRACE_HAVE_USERCLIENT
        CheckMonitorOutputSelector(o.name, r);
#endif
        // Refusals.
        CHECK(r.drv->SetMonitorOutput(0, kSymphonyMonitorOutputNone) == kIOReturnBadArgument, "%s: None accepted for a Symphony I/O", o.name);
        CHECK(r.drv->SetMonitorOutput(0, 4) == kIOReturnBadArgument, "%s: output 4 accepted", o.name);
        CHECK(r.drv->SetMonitorOutput(2, kSymphonyMonitorOutputHP1) == kIOReturnBadArgument, "%s: unit 2 accepted", o.name);
        CHECK(r.drv->SetMonitorOutput(1, kSymphonyMonitorOutputHP1) == kIOReturnNotReady, "%s: unit B accepted at 32 channels", o.name);
        CHECK(ShownDb() == -31.0f, "%s: a refused choice moved the control (%.1f)", o.name, ShownDb());
        // Headphone 1: the control shows its level (18 in the fake), and the
        // keys reach 0x23/0x24 with index 0 only.
        CHECK(r.drv->SetMonitorOutput(0, kSymphonyMonitorOutputHP1) == kIOReturnSuccess, "%s: HP1 refused", o.name);
        CHECK(ShownDb() == -18.0f && !gHostAudio.mute->GetControlValue(), "%s: HP1 chosen, control at %.1f (want -18)", o.name, ShownDb());
        Irq(r, 1); HostPump();
        CHECK(StoredOn(r, 0, 0x26) == 31 && StoredOn(r, 0, 0x23, 0) == 18, "%s: choosing HP1 wrote a level", o.name);
        PressVolume(r, -40.0f); PressMute(r, true);
        CHECK(StoredOn(r, 0, 0x23, 0) == 40 && StoredOn(r, 0, 0x24, 0) == 1, "%s: HP1 keys gave %u/%u (want 40/1)",
              o.name, StoredOn(r, 0, 0x23, 0), StoredOn(r, 0, 0x24, 0));
        CHECK(StoredOn(r, 0, 0x26) == 31 && StoredOn(r, 0, 0x27) == 0, "%s: HP1 keys moved the speakers", o.name);
        CHECK(StoredOn(r, 0, 0x23, 1) == 30 && StoredOn(r, 0, 0x24, 1) == 0, "%s: HP1 keys moved HP2", o.name);
        // Headphone 2: its level (30 in the fake), index 1.
        CHECK(r.drv->SetMonitorOutput(0, kSymphonyMonitorOutputHP2) == kIOReturnSuccess, "%s: HP2 refused", o.name);
        CHECK(ShownDb() == -30.0f && !gHostAudio.mute->GetControlValue(), "%s: HP2 chosen, control at %.1f (want -30)", o.name, ShownDb());
        PressVolume(r, -41.0f); PressMute(r, true);
        CHECK(StoredOn(r, 0, 0x23, 1) == 41 && StoredOn(r, 0, 0x24, 1) == 1, "%s: HP2 keys gave %u/%u (want 41/1)",
              o.name, StoredOn(r, 0, 0x23, 1), StoredOn(r, 0, 0x24, 1));
        CHECK(StoredOn(r, 0, 0x23, 0) == 40 && StoredOn(r, 0, 0x26) == 31, "%s: HP2 keys moved HP1 or the speakers", o.name);
        PressMute(r, false);
        // A level set elsewhere (Maestro's knob) shows when it is the chosen output only.
        uint8_t level = 50;
        CHECK(r.drv->SendVendorCommand(0x23, 1, &level, 1) == kIOReturnSuccess, "%s: HP2 knob", o.name);
        CHECK(ShownDb() == -50.0f, "%s: an HP2 level set elsewhere is not shown (%.1f)", o.name, ShownDb());
        level = 9;
        CHECK(r.drv->SendVendorCommand(0x23, 0, &level, 1) == kIOReturnSuccess, "%s: HP1 knob", o.name);
        CHECK(r.drv->SendVendorCommand(0x26, 0, &level, 1) == kIOReturnSuccess, "%s: speaker knob", o.name);
        CHECK(ShownDb() == -50.0f, "%s: another output's level moved the control (%.1f)", o.name, ShownDb());
        Irq(r, 1); HostPump();
        CHECK(StoredOn(r, 0, 0x23, 1) == 50, "%s: showing a level echoed a write", o.name);
        // The front panel turning Headphone 2 (selection 1).
        r.card.port[0].stored[(uint64_t(0x28) << 32) | 1] = {0,0,172,68,1,0,0,1,1,37,1,0};
        uint8_t observation[12] = {};
        CHECK(r.drv->ReadVendorCommand(0x28, 1, observation, 12) == kIOReturnSuccess, "%s: front panel read", o.name);
        CHECK(ShownDb() == -37.0f, "%s: a front-panel HP2 level is not shown (%.1f)", o.name, ShownDb());
        Irq(r, 1); HostPump();
        CHECK(StoredOn(r, 0, 0x23, 1) == 50, "%s: a front-panel observation was echoed to the unit", o.name);
        // A card reset and the link recovery keep the output. Headphone 2's
        // level is taken from the unit as it comes back (52 here, as if it
        // were another unit or had been turned on its front panel while the
        // link was down); the driver's older 37 is neither shown nor sent.
        r.card.port[0].stored[((uint64_t)0x23 << 32) | 1] = { 52 };
        ResetCardAndRecover(r);
        CheckOutputsDirect("Symphony I/O on port 1, after a card re-init", r, 32, true);
        CHECK(!Sent(r, 0, 0xB3), "%s: the re-init mutes the unit's mixer inputs (0xB3)", o.name);
        CHECK(StoredOn(r, 0, 0x23, 1) == 52, "%s: recovery sent the unit an HP2 level it did not have (%u, want 52)", o.name, StoredOn(r, 0, 0x23, 1));
        CHECK(ShownDb() == -52.0f, "%s: control at %.1f after recovery (want -52)", o.name, ShownDb());
        r.drv->StartDevice(1, IOUserAudioStartStopFlags::None);
        // A louder value coreaudiod puts back right after the recovery is not
        // sent; a mute that is on is.
        RestoreByCoreAudio(r, -6.0f, true);
        CHECK(StoredOn(r, 0, 0x23, 1) == 52 && ShownDb() == -52.0f,
              "%s: a restored louder value reached HP2 after recovery (%u, control %.1f)", o.name,
              StoredOn(r, 0, 0x23, 1), ShownDb());
        CHECK(StoredOn(r, 0, 0x24, 1) == 1 && gHostAudio.mute->GetControlValue(), "%s: mute on was dropped in the settle window", o.name);
        PressMute(r, false);
        PressVolume(r, -44.0f);
        CHECK(StoredOn(r, 0, 0x23, 1) == 44, "%s: the output was not kept over a re-init (HP2 %u)", o.name, StoredOn(r, 0, 0x23, 1));
        // Line mode with Speakers chosen: nothing is written, and the controls
        // go back to what they showed (-20 dB, the speaker's mute).
        CHECK(r.drv->SetMonitorOutput(0, kSymphonyMonitorOutputSpeakers) == kIOReturnSuccess, "%s: speakers refused", o.name);
        CHECK(ShownDb() == -9.0f, "%s: speakers chosen, control at %.1f (want -9)", o.name, ShownDb());
        uint8_t line = 0, stereo = 2;
        CHECK(r.drv->SendVendorCommand(0x25, 0, &line, 1) == kIOReturnSuccess, "%s: Line", o.name);
        CHECK(ShownDb() == -20.0f, "%s: Line with Speakers chosen reads %.1f (want -20)", o.name, ShownDb());
        Irq(r, 1); HostPump();
        const uint64_t seen = r.card.port[0].commandsSeen;
        const size_t writes = r.card.port[0].vendorWrites.size();
        PressVolume(r, -5.0f);
        PressVolume(r, -60.0f);
        CHECK(r.card.port[0].commandsSeen == seen && r.card.port[0].vendorWrites.size() == writes,
              "%s: a volume key in Line with Speakers chosen wrote to the unit (%llu commands)", o.name,
              (unsigned long long)(r.card.port[0].commandsSeen - seen));
        CHECK(StoredOn(r, 0, 0x26) == 9 && StoredOn(r, 0, 0x23, 0) == 9 && StoredOn(r, 0, 0x23, 1) == 44,
              "%s: Line with Speakers chosen moved a level", o.name);
        CHECK(ShownDb() == -20.0f, "%s: the volume control was not put back (%.1f)", o.name, ShownDb());
        // The mute key still reaches the speaker mute, and only it.
        const uint8_t hpMutes[2] = { StoredOn(r, 0, 0x24, 0), StoredOn(r, 0, 0x24, 1) };
        PressMute(r, true);
        CHECK(StoredOn(r, 0, 0x27) == 1 && gHostAudio.mute->GetControlValue(), "%s: mute in Line did not reach the speaker mute (%u)",
              o.name, StoredOn(r, 0, 0x27));
        CHECK(r.card.port[0].vendorWrites.size() == writes + 1 && r.card.port[0].vendorWrites.back() == 0x27,
              "%s: mute in Line wrote something other than one speaker mute", o.name);
        CHECK(StoredOn(r, 0, 0x24, 0) == hpMutes[0] && StoredOn(r, 0, 0x24, 1) == hpMutes[1], "%s: mute in Line reached a headphone", o.name);
        PressMute(r, false);
        CHECK(StoredOn(r, 0, 0x27) == 0, "%s: unmute in Line did not reach the speaker mute", o.name);
        // A headphone chosen in Line mode is moved.
        CHECK(r.drv->SetMonitorOutput(0, kSymphonyMonitorOutputHP1) == kIOReturnSuccess, "%s: HP1 in Line refused", o.name);
        CHECK(ShownDb() == -9.0f, "%s: HP1 in Line reads %.1f (want -9)", o.name, ShownDb());
        PressVolume(r, -22.0f);
        CHECK(StoredOn(r, 0, 0x23, 0) == 22 && StoredOn(r, 0, 0x26) == 9, "%s: HP1 in Line gave %u", o.name, StoredOn(r, 0, 0x23, 0));
        // Leaving Line: the speakers are movable again once chosen.
        CHECK(r.drv->SendVendorCommand(0x25, 0, &stereo, 1) == kIOReturnSuccess, "%s: Stereo", o.name);
        CHECK(ShownDb() == -22.0f, "%s: leaving Line changed the output (%.1f)", o.name, ShownDb());
        CHECK(r.drv->SetMonitorOutput(0, kSymphonyMonitorOutputSpeakers) == kIOReturnSuccess, "%s: speakers refused", o.name);
        PressVolume(r, -15.0f);
        CHECK(StoredOn(r, 0, 0x26) == 15, "%s: speakers after Line gave %u", o.name, StoredOn(r, 0, 0x26));
        Finish(o, r);
    }
    // 1b. A unit in Line mode when the link comes up, and no choice from the
    //     app in this driver instance: the keys move Headphone 1, as builds
    //     up to 141 did and as the original's state is after Line was set.
    {
        Options o; o.name = "audio output: Line before the app chose"; o.shortFlow = true;
        Run r;
        RunScenario(o, r);
        // The harness has no hook before Start(), so put the unit in Line and
        // run the set-up again, as after a power cycle.
        r.card.port[0].stored[(uint64_t)0x25 << 32] = { 0 };
        ResetCardAndRecover(r);
        r.drv->StartDevice(1, IOUserAudioStartStopFlags::None);
        CHECK(ShownDb() == -18.0f, "%s: control at %.1f (want Headphone 1's -18)", o.name, ShownDb());
        PressVolume(r, -50.0f); PressMute(r, true);
        CHECK(StoredOn(r, 0, 0x23, 0) == 50 && StoredOn(r, 0, 0x24, 0) == 1, "%s: the keys did not move Headphone 1 (%u/%u)",
              o.name, StoredOn(r, 0, 0x23, 0), StoredOn(r, 0, 0x24, 0));
        CHECK(StoredOn(r, 0, 0x26) == 12 && StoredOn(r, 0, 0x27) == 0, "%s: the keys moved the speakers in Line mode", o.name);
        PressMute(r, false);
        // An app that does not know selector 15 sets Stereo: the speakers again.
        uint8_t stereo = 2, line = 0;
        CHECK(r.drv->SendVendorCommand(0x25, 0, &stereo, 1) == kIOReturnSuccess, "%s: Stereo", o.name);
        CHECK(ShownDb() == -12.0f, "%s: Stereo without a choice shows %.1f (want the speakers' -12)", o.name, ShownDb());
        // Once the app has chosen, the mode no longer changes the output.
        CHECK(r.drv->SetMonitorOutput(0, kSymphonyMonitorOutputSpeakers) == kIOReturnSuccess, "%s: speakers refused", o.name);
        CHECK(r.drv->SendVendorCommand(0x25, 0, &line, 1) == kIOReturnSuccess, "%s: Line", o.name);
        CHECK(ShownDb() == -20.0f, "%s: Line with Speakers chosen reads %.1f (want -20)", o.name, ShownDb());
        const size_t writes = r.card.port[0].vendorWrites.size();
        PressVolume(r, -40.0f);
        CHECK(r.card.port[0].vendorWrites.size() == writes && StoredOn(r, 0, 0x23, 0) == 50,
              "%s: a volume key wrote with Speakers chosen in Line mode", o.name);
        // The choice outlives a recovery in the same driver instance.
        ResetCardAndRecover(r);
        r.drv->StartDevice(1, IOUserAudioStartStopFlags::None);
        CHECK(ShownDb() == -20.0f, "%s: the app's choice was lost over a recovery (%.1f)", o.name, ShownDb());
        Finish(o, r);
    }
    // 1c. coreaudiod putting a saved slider value back after the driver
    //     started (or after a wake, or when it reconnects) writes nothing: the
    //     control goes back to the output's level. A key pressed later is sent.
    {
        Options o; o.name = "audio output: restored slider"; o.shortFlow = true;
        Run r;
        RunScenario(o, r);
        const size_t writes = r.card.port[0].vendorWrites.size();
        // Louder than the unit (12 in the fake), and an unmute of a muted
        // output, are put back.
        RestoreByCoreAudio(r, -3.0f, false);
        CHECK(r.card.port[0].vendorWrites.size() == writes, "%s: a restored value was written to the unit after Start (%zu writes)",
              o.name, r.card.port[0].vendorWrites.size() - writes);
        CHECK(StoredOn(r, 0, 0x26) == 12 && StoredOn(r, 0, 0x27) == 0 && StoredOn(r, 0, 0x23, 0) == 18 && StoredOn(r, 0, 0x23, 1) == 30,
              "%s: a restored value changed a level", o.name);
        CHECK(ShownDb() == -12.0f && !gHostAudio.mute->GetControlValue(), "%s: the controls were not put back to the speakers' (%.1f)", o.name, ShownDb());
        // Towards quiet is honoured at once, inside the window: a lower level
        // and mute on.
        RestoreByCoreAudio(r, -40.0f, true);
        CHECK(StoredOn(r, 0, 0x26) == 40 && StoredOn(r, 0, 0x27) == 1, "%s: turning down or muting inside the window was dropped (%u/%u)",
              o.name, StoredOn(r, 0, 0x26), StoredOn(r, 0, 0x27));
        // Unmute and louder inside the window: put back.
        RestoreByCoreAudio(r, -20.0f, false);
        CHECK(StoredOn(r, 0, 0x26) == 40 && StoredOn(r, 0, 0x27) == 1 && ShownDb() == -40.0f && gHostAudio.mute->GetControlValue(),
              "%s: unmute or louder inside the window was sent (%u/%u)", o.name, StoredOn(r, 0, 0x26), StoredOn(r, 0, 0x27));
        PressVolume(r, -31.0f); PressMute(r, true);
        CHECK(StoredOn(r, 0, 0x26) == 31 && StoredOn(r, 0, 0x27) == 1, "%s: a key pressed after the window was not sent (%u/%u)",
              o.name, StoredOn(r, 0, 0x26), StoredOn(r, 0, 0x27));
        PressMute(r, false);
        // No interrupt runs while the window is open (the hardware suspended,
        // or the PCIe card before IO starts): the value that arrived meanwhile
        // is still not sent by the first interrupt after it, however late.
        ResetCardAndRecover(r);
        r.drv->StartDevice(1, IOUserAudioStartStopFlags::None);
        {
            const size_t before = r.card.port[0].vendorWrites.size();
            gHostAudio.volume->SetDecibelValue(-3.0f);
            gHostMicPreClockOffsetNs += kKeyPressAfterSettleNs;   // the window lapses unseen, for good
            Irq(r, 1); HostPump();
            CHECK(r.card.port[0].vendorWrites.size() == before && StoredOn(r, 0, 0x26) == 31 && ShownDb() == -31.0f,
                  "%s: the first look at the controls after a lapsed window sent a restored value (%u, control %.1f)",
                  o.name, StoredOn(r, 0, 0x26), ShownDb());
            gHostAudio.volume->SetDecibelValue(-5.0f);
            Irq(r, 1); HostPump();
            CHECK(StoredOn(r, 0, 0x26) == 5, "%s: a change after that was not sent (%u)", o.name, StoredOn(r, 0, 0x26));
            PressVolume(r, -12.0f);
        }
        // With a headphone chosen, after a wake with an FPGA reset.
        CHECK(r.drv->SetMonitorOutput(0, kSymphonyMonitorOutputHP1) == kIOReturnSuccess, "%s: HP1 refused", o.name);
        ResetCardAndRecover(r);
        r.drv->StartDevice(1, IOUserAudioStartStopFlags::None);
        const size_t after = r.card.port[0].vendorWrites.size();
        RestoreByCoreAudio(r, -2.0f, false);
        CHECK(r.card.port[0].vendorWrites.size() == after && StoredOn(r, 0, 0x23, 0) == 18 && ShownDb() == -18.0f,
              "%s: a restored value reached Headphone 1 after a wake (%u, control %.1f)", o.name, StoredOn(r, 0, 0x23, 0), ShownDb());
        PressVolume(r, -25.0f);
        CHECK(StoredOn(r, 0, 0x23, 0) == 25, "%s: Headphone 1 key after the window gave %u", o.name, StoredOn(r, 0, 0x23, 0));
        Finish(o, r);
    }
    // 1d. A unit switched on after the Mac started: no level is shown or sent
    //     that was not read from it. Headphone 2 was chosen while it was off.
    {
        Options o; o.name = "audio output: unit powered on late"; o.port1 = Port::Empty; o.shortFlow = true;
        Run r;
        RunScenario(o, r);
        CHECK(r.drv->SetMonitorOutput(0, kSymphonyMonitorOutputHP2) == kIOReturnSuccess, "%s: HP2 refused with no unit", o.name);
        Attach(r.card.port[0], Port::Symphony);
        r.drv->LinkWatchTimerOccurred(nullptr, 0); HostPump();
        r.drv->LinkWatchTimerOccurred(nullptr, 0); HostPump();
        r.drv->StartDevice(1, IOUserAudioStartStopFlags::None);
        CHECK(ShownDb() == -30.0f, "%s: HP2 shows %.1f (want the unit's -30, not the -20 fallback)", o.name, ShownDb());
        CHECK(StoredOn(r, 0, 0x26) == 12 && StoredOn(r, 0, 0x23, 0) == 18 && StoredOn(r, 0, 0x23, 1) == 30,
              "%s: the unit was sent a fallback level (%u/%u/%u, want 12/18/30)", o.name,
              StoredOn(r, 0, 0x26), StoredOn(r, 0, 0x23, 0), StoredOn(r, 0, 0x23, 1));
        PressVolume(r, -32.0f);
        CHECK(StoredOn(r, 0, 0x23, 1) == 32, "%s: HP2 key gave %u (want 32)", o.name, StoredOn(r, 0, 0x23, 1));
        // The unit is swapped for another whose Headphone 2 is at 55.
        r.card.port[0] = Port();
        r.drv->LinkWatchTimerOccurred(nullptr, 0); HostPump();
        Attach(r.card.port[0], Port::Symphony);
        r.card.port[0].stored[((uint64_t)0x23 << 32) | 1] = { 55 };
        r.drv->LinkWatchTimerOccurred(nullptr, 0); HostPump();
        r.drv->StartDevice(1, IOUserAudioStartStopFlags::None);
        CHECK(ShownDb() == -55.0f && StoredOn(r, 0, 0x23, 1) == 55, "%s: after a unit swap HP2 shows %.1f and the unit has %u (want 55)",
              o.name, ShownDb(), StoredOn(r, 0, 0x23, 1));
        // Choosing an output reads its level from the unit.
        r.card.port[0].stored[((uint64_t)0x23 << 32) | 0] = { 41 };
        CHECK(r.drv->SetMonitorOutput(0, kSymphonyMonitorOutputHP1) == kIOReturnSuccess, "%s: HP1 refused", o.name);
        CHECK(ShownDb() == -41.0f, "%s: a chosen output shows %.1f (want the unit's -41)", o.name, ShownDb());
        // A choice whose level cannot be read is refused and changes nothing.
        r.card.port[0].dropVendorReads = 2;
        CHECK(r.drv->SetMonitorOutput(0, kSymphonyMonitorOutputSpeakers) == kIOReturnIOError, "%s: a choice was taken without its level", o.name);
        CHECK(ShownDb() == -41.0f, "%s: a refused choice moved the control", o.name);
        Finish(o, r);
    }
    // 2. The original PCIe card: the same table.
    {
        Options o; o.name = "direct defaults: PCIe card"; o.legacy2100 = true; o.shortFlow = true;
        Run r;
        RunScenario(o, r);
        CheckOutputsDirect("PCIe card, after Start", r, 32, true);
        CHECK(!Sent(r, 0, 0xB3), "%s: Start mutes the unit's mixer inputs", o.name);
        ResetCardAndRecover(r);
        CheckOutputsDirect("PCIe card, after a card re-init", r, 32, true);
        Finish(o, r);
    }
    // 3. The app's routes and mixer state are still replayed by a re-init.
    {
        Options o; o.name = "direct defaults: app routes replayed"; o.shortFlow = true;
        Run r;
        RunScenario(o, r);
        const uint8_t route[3] = { 4, (uint8_t)kTDM_Mixer0Out, 1 };
        CHECK(r.drv->SendVendorCommand(kThunderboltCardOutputRouteCommand, 0, route, 3) == kIOReturnSuccess, "%s: route", o.name);
        ResetCardAndRecover(r);
        CHECK(r.card.reg[kRegOutputRouting + 4 * 4] == ThunderboltCardOutputRouteWord((uint8_t)kTDM_Mixer0Out, true),
              "%s: the app's route was not replayed (0x%03x)", o.name, r.card.reg[kRegOutputRouting + 4 * 4]);
        for (uint32_t n = 0; n < 32; n++)
            if (n != 4) CHECK(r.card.reg[kRegOutputRouting + n * 4] == ((kTDM_PCIOut0 + n) | kRoutingEnable),
                              "%s: output %u = 0x%03x after the re-init", o.name, n, r.card.reg[kRegOutputRouting + n * 4]);
        CHECK(r.card.reg[MixerCoefOffset(0, 128)] == kMixerUnityCoeff && r.card.reg[MixerCoefOffset(0, 0)] == 0,
              "%s: mixer 1 defaults changed (return 0x%08x, input 0x%08x)", o.name,
              r.card.reg[MixerCoefOffset(0, 128)], r.card.reg[MixerCoefOffset(0, 0)]);
        Finish(o, r);
    }
    // 4. Converters only: the card mixer level, or None.
    {
        Options o; o.name = "audio output: converters"; o.port1 = Port::Converters; o.shortFlow = true;
        Run r;
        RunScenario(o, r);
        CheckOutputsDirect("converters, after Start", r, 32, false);
        CHECK(r.drv->SetMonitorOutput(0, kSymphonyMonitorOutputHP1) == kIOReturnUnsupported, "%s: HP1 accepted on converters", o.name);
        CHECK(r.drv->SetMonitorOutput(0, kSymphonyMonitorOutputHP2) == kIOReturnUnsupported, "%s: HP2 accepted on converters", o.name);
#ifdef TRACE_HAVE_USERCLIENT
        CHECK(CallMonitorOutput(r, 0, kSymphonyMonitorOutputHP1) == kIOReturnUnsupported, "%s: selector 15 took HP1 on converters", o.name);
        CHECK(CallMonitorOutput(r, 0, kSymphonyMonitorOutputHP2) == kIOReturnUnsupported, "%s: selector 15 took HP2 on converters", o.name);
        CHECK(CallMonitorOutput(r, 1, kSymphonyMonitorOutputSpeakers) == kIOReturnUnsupported, "%s: selector 15 took unit B on converters", o.name);
        CHECK(CallMonitorOutput(r, 0, kSymphonyMonitorOutputNone, 0x12345678u) == kIOReturnBadArgument, "%s: selector 15 took a bad magic", o.name);
        CHECK(Mixer1Return(r) == kMixerUnityCoeff, "%s: a refused selector 15 call trimmed the mixer", o.name);
#endif
        PressVolume(r, -31.0f); PressMute(r, true);
        CHECK(Mixer1Return(r) == kMixerMuteCoeff, "%s: mute gives 0x%08x", o.name, Mixer1Return(r));
        // None: the trim is back at 0 dB, unmuted, and the keys do nothing.
        CHECK(r.drv->SetMonitorOutput(0, kSymphonyMonitorOutputNone) == kIOReturnSuccess, "%s: None refused", o.name);
        CHECK(Mixer1Return(r) == kMixerUnityCoeff, "%s: None left the trim on (0x%08x)", o.name, Mixer1Return(r));
        CHECK(ShownDb() == 0.0f && !gHostAudio.mute->GetControlValue(), "%s: None shows %.1f dB", o.name, ShownDb());
        PressVolume(r, -40.0f); PressMute(r, true);
        CHECK(Mixer1Return(r) == kMixerUnityCoeff, "%s: the keys trimmed with None chosen (0x%08x)", o.name, Mixer1Return(r));
        CHECK(ShownDb() == 0.0f && !gHostAudio.mute->GetControlValue(), "%s: None, controls not put back (%.1f)", o.name, ShownDb());
        CHECK(StoredOn(r, 0, 0x26) == 0xFF && StoredOn(r, 0, 0x23) == 0xFF, "%s: a converter was sent a level", o.name);
        ResetCardAndRecover(r);
        CheckOutputsDirect("converters, after a card re-init", r, 32, false);
        CHECK(Mixer1Return(r) == kMixerUnityCoeff, "%s: None lost over a card reset (0x%08x)", o.name, Mixer1Return(r));
        r.drv->StartDevice(1, IOUserAudioStartStopFlags::None);
        PressVolume(r, -12.0f);
        CHECK(Mixer1Return(r) == kMixerUnityCoeff, "%s: the keys trimmed after a reset with None chosen", o.name);
        // The card mixer level again: the keys trim from 0 dB.
        CHECK(r.drv->SetMonitorOutput(0, kSymphonyMonitorOutputSpeakers) == kIOReturnSuccess, "%s: level refused", o.name);
        CHECK(Mixer1Return(r) == kMixerUnityCoeff && ShownDb() == 0.0f, "%s: choosing the level changed it", o.name);
        PressVolume(r, -31.0f);
        CHECK(Mixer1Return(r) == SymphonyMixerCoef(-31, 128) /* 0x00e60000: the original's truncation; the old table rounded to 0x00e7 */, "%s: -31 dB gives 0x%08x", o.name, Mixer1Return(r));
        Finish(o, r);
    }
#ifdef TRACE_HAVE_PORT2_AUDIO
    // 5. Two units at 64 channels: each has its own output.
    {
        Options o; o.name = "audio output: unit B"; o.port2 = Port::Symphony;
        o.portCountProperty = 2; o.shortFlow = true;
        Run r;
        RunScenario(o, r);
        Select(r, 1, "select 64 for audio output", false);
        CheckOutputsDirect("two units at 64 channels", r, 64, true);
        CHECK(!Sent(r, 0, 0xB3) && !Sent(r, 1, 0xB3), "%s: a unit's mixer inputs are muted at set-up", o.name);
        // Unit B's choice is kept while unit A owns the controls.
        CHECK(r.drv->SetMonitorOutput(1, kSymphonyMonitorOutputHP1) == kIOReturnSuccess, "%s: B HP1 refused", o.name);
        CHECK(ShownDb() == -12.0f, "%s: unit B's choice moved unit A's control (%.1f)", o.name, ShownDb());
        PressVolume(r, -25.0f);
        CHECK(StoredOn(r, 0, 0x26) == 25 && StoredOn(r, 1, 0x23, 0) == 0xFF, "%s: unit A keys went elsewhere", o.name);
        // Unit B selected: its Headphone 1 (18 in the fake).
        CHECK(r.drv->SetMonitorDevice(1) == kIOReturnSuccess, "%s: select B", o.name);
        CHECK(ShownDb() == -18.0f, "%s: B HP1 shows %.1f (want -18)", o.name, ShownDb());
        PressVolume(r, -27.0f); PressMute(r, true);
        CHECK(StoredOn(r, 1, 0x23, 0) == 27 && StoredOn(r, 1, 0x24, 0) == 1, "%s: B HP1 keys gave %u/%u",
              o.name, StoredOn(r, 1, 0x23, 0), StoredOn(r, 1, 0x24, 0));
        CHECK(StoredOn(r, 1, 0x26) == 0xFF && StoredOn(r, 0, 0x23, 0) == 18 && StoredOn(r, 0, 0x26) == 25,
              "%s: B HP1 keys reached another output", o.name);
        PressMute(r, false);
        // Unit B's Headphone 2: read from the unit when chosen (30 in the fake).
        CHECK(r.drv->SetMonitorOutput(1, kSymphonyMonitorOutputHP2) == kIOReturnSuccess, "%s: B HP2 refused", o.name);
        CHECK(ShownDb() == -30.0f, "%s: B HP2 shows %.1f (want -30)", o.name, ShownDb());
        PressVolume(r, -28.0f); PressMute(r, true);
        CHECK(StoredOn(r, 1, 0x23, 1) == 28 && StoredOn(r, 1, 0x24, 1) == 1, "%s: B HP2 keys gave %u/%u",
              o.name, StoredOn(r, 1, 0x23, 1), StoredOn(r, 1, 0x24, 1));
        CHECK(StoredOn(r, 1, 0x23, 0) == 27 && StoredOn(r, 0, 0x23, 1) == 30, "%s: B HP2 keys reached another output", o.name);
        PressMute(r, false);
        // Unit B's speakers: its level (12 in the fake), 0x26/0x27 on port 2.
        CHECK(r.drv->SetMonitorOutput(1, kSymphonyMonitorOutputSpeakers) == kIOReturnSuccess, "%s: B speakers refused", o.name);
        CHECK(ShownDb() == -12.0f, "%s: B speakers show %.1f (want -12)", o.name, ShownDb());
        PressVolume(r, -29.0f); PressMute(r, true);
        CHECK(StoredOn(r, 1, 0x26) == 29 && StoredOn(r, 1, 0x27) == 1, "%s: B speaker keys gave %u/%u (want 29/1)",
              o.name, StoredOn(r, 1, 0x26), StoredOn(r, 1, 0x27));
        CHECK(StoredOn(r, 0, 0x26) == 25 && StoredOn(r, 0, 0x27) == 0 && StoredOn(r, 1, 0x23, 1) == 28,
              "%s: B speaker keys reached another output", o.name);
        PressMute(r, false);
        // Unit B in Line with Speakers chosen: nothing reaches either unit.
        uint8_t line = 0;
        CHECK(r.drv->SendVendorCommand(0x25, 0, &line, 1, 1) == kIOReturnSuccess, "%s: B Line", o.name);
        CHECK(ShownDb() == -20.0f, "%s: B Line with Speakers chosen reads %.1f", o.name, ShownDb());
        Irq(r, 1); HostPump();
        const size_t a = r.card.port[0].vendorWrites.size(), b = r.card.port[1].vendorWrites.size();
        PressVolume(r, -3.0f);
        CHECK(r.card.port[0].vendorWrites.size() == a && r.card.port[1].vendorWrites.size() == b,
              "%s: a volume key in B Line with Speakers chosen wrote to a unit", o.name);
        CHECK(ShownDb() == -20.0f, "%s: B Line, volume control not put back", o.name);
        PressMute(r, true);
        CHECK(r.card.port[0].vendorWrites.size() == a && r.card.port[1].vendorWrites.size() == b + 1 &&
              StoredOn(r, 1, 0x27) == 1, "%s: mute in B Line is not unit B's speaker mute", o.name);
        PressMute(r, false);
        // Back to unit A: its own output (the speakers), its own level.
        CHECK(r.drv->SetMonitorDevice(0) == kIOReturnSuccess, "%s: select A", o.name);
        CHECK(ShownDb() == -25.0f, "%s: unit A shows %.1f (want -25)", o.name, ShownDb());
        CHECK(r.drv->SetMonitorOutput(0, kSymphonyMonitorOutputHP2) == kIOReturnSuccess, "%s: A HP2 refused", o.name);
        PressVolume(r, -35.0f);
        CHECK(StoredOn(r, 0, 0x23, 1) == 35 && StoredOn(r, 1, 0x23, 1) == 28, "%s: A HP2 keys gave %u", o.name, StoredOn(r, 0, 0x23, 1));
        // A card reset while 64 channels ran: the card comes back on port 1
        // alone, every output direct, and no unit's mixer inputs are muted.
        r.card.port[0].vendorWrites.clear();
        r.card.port[1].vendorWrites.clear();
        ResetCardAndRecover(r);
        CheckOutputsDirect("two units, after a card re-init", r, 32, true);
        CHECK(!Sent(r, 0, 0xB3) && !Sent(r, 1, 0xB3), "%s: a re-init mutes a unit's mixer inputs", o.name);
        Finish(o, r);
    }
    // 5b. Unit B owned the controls and its set-up fails when 64 channels
    //     start again: the controls are unit A's, at unit A's level, and the
    //     next key steps unit A from there. (The hand-back happens in
    //     LeaveTwoUnit; ConfigureUnitB's own, for a failed set-up, cannot be
    //     reached on its own from here.)
    {
        Options o; o.name = "audio output: unit B lost at set-up"; o.port2 = Port::Symphony;
        o.portCountProperty = 2; o.shortFlow = true;
        Run r;
        RunScenario(o, r);
        Select(r, 1, "select 64 before losing unit B's set-up", false);
        uint8_t quiet = 55;
        CHECK(r.drv->SendVendorCommand(0x26, 0, &quiet, 1, 1) == kIOReturnSuccess, "%s: seed B", o.name);
        CHECK(r.drv->SetMonitorDevice(1) == kIOReturnSuccess, "%s: select B", o.name);
        CHECK(ShownDb() == -55.0f, "%s: B shows %.1f", o.name, ShownDb());
        Select(r, 0, "back to 32", false);
        CHECK(r.drv->SetMonitorDevice(1) == kIOReturnNotReady, "%s: B selectable at 32", o.name);
        r.card.port[1].dropVendorReads = 1;
        Select(r, 1, "select 64 with unit B's set-up failing", false);
        SymphonyUnitBStateOutput st = {};
        r.drv->ReadUnitBState(reinterpret_cast<uint32_t *>(&st));
        CHECK(st.present == 0, "%s: unit B configured although a read failed", o.name);
        CHECK(ShownDb() == -12.0f, "%s: the controls show %.1f (want unit A's -12)", o.name, ShownDb());
        PressVolume(r, -14.0f);
        CHECK(StoredOn(r, 0, 0x26) == 14 && StoredOn(r, 1, 0x26) == 55, "%s: the key did not move unit A (%u)", o.name, StoredOn(r, 0, 0x26));
        Finish(o, r);
    }
    // 6. A Symphony I/O with converters on port 2, and converters on both
    //    ports: no output on a mixer after Start.
    {
        Options o; o.name = "direct defaults: Symphony plus converters"; o.port2 = Port::Converters;
        o.portCountProperty = 2; o.shortFlow = true;
        Run r;
        RunScenario(o, r);
        CheckOutputsDirect("Symphony I/O plus converters, after Start", r, 32, true);
        Select(r, 1, "select 64 with converters on port 2", false);
        CheckOutputsDirect("Symphony I/O plus converters at 64", r, 64, false);
        Finish(o, r);
    }
#endif
}
#endif
#endif

// The single-port scenarios. Their traces are the contract: they must not
// change while the port-2 experiment is off.
static std::vector<Options> SinglePortScenarios()
{
    std::vector<Options> v;
    { Options o; o.name = "p1-symphony"; o.dirtyRegisters = true; v.push_back(o); }
    { Options o; o.name = "p1-symphony-port2-cabled"; o.port2 = Port::Converters; o.shortFlow = true; v.push_back(o); }
    { Options o; o.name = "p1-no-unit-then-power-on"; o.lateSymphony = true; v.push_back(o); }
    { Options o; o.name = "p1-nothing-attached"; o.port1 = Port::Empty; o.unplugBeforeStop = true; v.push_back(o); }
    { Options o; o.name = "p1-converters"; o.port1 = Port::Converters; o.port2 = Port::Converters; v.push_back(o); }
    { Options o; o.name = "p1-legacy-2100"; o.legacy2100 = true; o.shortFlow = true; v.push_back(o); }
    // dext 130: the PCIe card through the full flow, so the expansion write in
    // the card re-init after an FPGA reset is pinned too.
    { Options o; o.name = "p1-legacy-2100-full"; o.legacy2100 = true; v.push_back(o); }
    // dext 150 review m1: the fake's default rig has its 8MicPre in slot 1,
    // where it has no preamps to offer (MicPreChannelsForSlots), so since the
    // analog-first tables no other golden has a mic gain or phantom write
    // reaching the unit. This one is a 16x16 with the 8MicPre in slot 2
    // (MicPre 1 Mic, 2 Instrument, 3 unknown), through the full flow.
    { Options o; o.name = "p1-symphony-micpre"; o.micPreInstrument = true; v.push_back(o); }
    return v;
}

// The shipped two-port personality at 32 channels must never use unit B.
// Evidence: og_source/symphonymk1/ext/Symphony64/Driver/Symphony64Card.cpp:2258
// and og_source/symphonymk1/ext/Symphony64/Driver/XLink.cpp:888.
// Check raw accesses, including teardown, rather than just the final state.
static void CheckTwoPort32(const Options &o, const FakeCard &c)
{
    CHECK(c.count("H dma-prepare") == 5, "%s: expected both port DMA pairs plus meters", o.name);
    CHECK(c.reg.at(kRegGCSR2) & kGCSR2_DisablePort2, "%s: port 2 not disabled at end", o.name);
    CHECK(c.port[1].commandsSeen == 0 && c.port[1].stored.empty(),
          "%s: unit-B traffic at 32 channels", o.name);
    bool firstGCSR2Write = true;
    for (const auto &l : c.lines) {
        unsigned long long off = 0;
        unsigned val = 0;
        char kind = 0;
        if (sscanf(l.c_str(), "%c 0x%llx 0x%x", &kind, &off, &val) != 3) continue;
        if (kind == 'W' && off == kRegGCSR2) {
            // Initial DMA quiesce preserves the reset value (zero on a clean
            // card). Every later write must keep the configured port disabled.
            CHECK((firstGCSR2Write && val == 0) || (val & kGCSR2_DisablePort2),
                  "%s: DisablePort2 cleared: %s", o.name, l.c_str());
            firstGCSR2Write = false;
        }
        if (kind == 'W' && off == kRegXLink2TX)
            CHECK(false, "%s: XLink2 TX traffic: %s", o.name, l.c_str());
        // Start/re-init explicitly clear these registers today. No DMA address
        // or buffer size may be programmed; zero clears are baseline behaviour.
        if (kind == 'W' && (off == kRegA2H2HBA || off == kRegH2A2HBA ||
                            off == kRegA2H2BUFSIZE || off == kRegH2A2BUFSIZE))
            CHECK(val == 0, "%s: port-2 DMA programmed: %s", o.name, l.c_str());
    }
}

#ifdef TRACE_HAVE_RETIRE
// ── Retire for upgrade (kSelectorRetireForUpgrade) ──────────────────────────
// The serving copy is asked to step aside so the copy macOS registered can take
// the device. RetireForUpgrade only calls Terminate(0); DriverKit then calls
// Stop(), which the test does next, as the kernel would. These pin that the
// request itself touches nothing, is refused for a bad replacement build, calls
// Terminate once, and that the ordinary Stop() that follows leaves the card
// muted with DMA and interrupts off, every DMA mapping completed, and nothing
// reachable afterwards: every user-client entry called after Stop() returns
// without a single bus access. With IO idle, and with IO running and a volume
// write still queued on the XLink queue (Stop() drains it before the audio
// objects are released).

// Bus accesses (BAR and PCI config) recorded since `mark`.
static size_t BusAccessesSince(const FakeCard &c, size_t mark)
{
    size_t n = 0;
    for (size_t i = mark; i < c.lines.size(); i++) {
        const std::string &l = c.lines[i];
        if (l.compare(0, 2, "R ") == 0 || l.compare(0, 2, "W ") == 0 ||
            l.compare(0, 2, "CR") == 0 || l.compare(0, 2, "CW") == 0) n++;
    }
    return n;
}

static void RunRetire(const char *name, bool streaming, const std::string &outDir, size_t &accesses, bool &ok, bool twoPort = false)
{
    Options o; o.name = name; o.shortFlow = true;
    if (twoPort) o.portCountProperty = 2;
    Run r;
    RunScenario(o, r);
    FakeCard &card = r.card;
    SymphonyThunderbridge *drv = r.drv;
    if (streaming) {
        card.phase("streaming, a volume change queued on the XLink queue");
        Irq(r, 1);
        Irq(r, 2);
        if (gHostAudio.volume) gHostAudio.volume->SetDecibelValue(-20.0f);
        Irq(r, 1);   // queues the volume write; not pumped, so it is in flight at Stop()
        size_t queued = 0;
        for (auto *q : gQueues) if (q != &gHostCompletions) queued += q->size();
        CHECK(queued > 0, "%s: no XLink work queued before the retire (the test proves nothing)", name);
    } else {
        card.phase("IO stopped");
        drv->StopDevice(1, IOUserAudioStartStopFlags::None);
        HostPump();
    }
    {
        uint32_t w[16] = {};
        drv->ReadLinkState(w);
        CHECK((w[3] != 0) == streaming, "%s: ioRunning %u before retire", name, w[3]);
    }

    card.phase("retire refused: replacement is this build, or 0");
    const size_t mark = card.lines.size();
    const int before = gHostTerminateCalls;
    CHECK(drv->RetireForUpgrade((uint32_t)SYMPHONY_DEXT_BUILD) == kIOReturnBadArgument, "%s: retire for own build accepted", name);
    CHECK(drv->RetireForUpgrade(0) == kIOReturnBadArgument, "%s: retire for build 0 accepted", name);
    CHECK(gHostTerminateCalls == before, "%s: a refused retire called Terminate", name);

    card.phase("retire for the next build, asked twice");
    CHECK(drv->RetireForUpgrade((uint32_t)SYMPHONY_DEXT_BUILD + 1) == kIOReturnSuccess, "%s: retire refused", name);
    CHECK(drv->RetireForUpgrade((uint32_t)SYMPHONY_DEXT_BUILD + 1) == kIOReturnSuccess, "%s: second retire failed", name);
    CHECK(gHostTerminateCalls == before + 1, "%s: Terminate called %d times (want 1)", name, gHostTerminateCalls - before);
    CHECK(BusAccessesSince(card, mark) == 0, "%s: the retire request touched the card", name);

    card.phase("Stop (from the termination)");
    drv->Stop(r.pci);
    HostPump();
    CHECK((card.reg[kRegGCSR] & kGCSR_DMAEnableMask) == 0 && (card.reg[kRegGCSR2] & kGCSR2_DMAEnableMask) == 0,
          "%s: DMA still enabled after Stop", name);
    CHECK(card.reg[kRegIntMask] == 0, "%s: interrupts still unmasked after Stop", name);
    CHECK((card.reg[kRegClkCtrl] & (kClkCtrl_Unmute | kClkCtrl_InputUnmute | kClkCtrl_OutputUnmute)) == 0,
          "%s: FPGA not muted after Stop", name);
    CHECK(card.count("H dma-complete") == (twoPort ? 5 : 3), "%s: %zu DMA mappings completed at Stop", name,
          card.count("H dma-complete"));

    card.phase("user-client calls after Stop");
    const size_t after = card.lines.size();
    {
        uint8_t p = 3;
        CHECK(drv->SendVendorCommand(0x25, 0, &p, 1) == kIOReturnNotReady, "%s: vendor write after Stop", name);
        uint8_t out[4] = {};
        CHECK(drv->ReadVendorCommand(0xA1, 1, out, 1) == kIOReturnNotReady, "%s: vendor read after Stop", name);
        uint32_t w[16] = {};
        CHECK(drv->ReadTimingHealth(w) == kIOReturnNotReady, "%s: timing health after Stop", name);
        drv->ReadLinkState(w);
        uint8_t types[2], valid[2];
        drv->ReadBoardTypes(types, valid);
        uint32_t m[kMeterBufferWords] = {};
        CHECK(drv->ReadMeterBuffer(m) == kIOReturnNotReady, "%s: meters after Stop", name);
        CHECK(drv->RetireForUpgrade((uint32_t)SYMPHONY_DEXT_BUILD + 1) == kIOReturnSuccess, "%s: retire after Stop", name);
        drv->RequestClockSource(2);
        drv->RequestMicGain(1, 30.0f);
        HostPump();
    }
    CHECK(BusAccessesSince(card, after) == 0, "%s: %zu bus accesses after Stop", name, BusAccessesSince(card, after));
    CHECK(gHostTerminateCalls == before + 1, "%s: Terminate called again after Stop", name);
    card.phase("after Stop");
    r.drv->release();
    r.pci->release();
    r.drv = nullptr;
    gHostBackend = nullptr;
    if (twoPort) CheckTwoPort32(o, card);
    accesses += card.lines.size();
    if (!WriteFile(outDir, name, card.lines)) ok = false;
}
#endif

#ifdef TRACE_HAVE_PORT2
struct Port2State {
    uint32_t w[16];
};

static Port2State ReadPort2(Run &r)
{
    Port2State s = {};
    kern_return_t rc = r.drv->ReadPort2State(s.w);
    CHECK(rc == kIOReturnSuccess, "ReadPort2State returned 0x%x", rc);
    return s;
}

// Things that must hold in two-port mode while "Port 1: 32ch" is selected,
// checked on the raw trace from line `from` on: as the original at 32
// channels (setCardEnabled(true, 1): both clock enables set, SetNumPorts(1):
// DisablePort2 set; BusInit skips the disabled bus), port 2 is never probed,
// never sent a command and never given audio.
static void CheckAt32(const Options &o, Run &r, size_t from = 0)
{
    FakeCard &c = r.card;
    // The whole-session checks (Start allocated nothing for port 2 and
    // published 32 channels) only for a session that never left 32.
    if (from == 0) {
#ifdef TRACE_HAVE_PORT2_AUDIO
        // Stage 2 allocates the port-2 buffer pair at Start; it is not programmed
        // into the card (the register checks below) until 64 is selected.
        CHECK(c.count("H dma-prepare") == 5, "%s: %zu DMA mappings (want 5: A2H, H2A, meters, A2H2, H2A2)",
              o.name, c.count("H dma-prepare"));
#else
        CHECK(c.count("H dma-prepare") == 3, "%s: %zu DMA mappings (want 3: A2H, H2A, meters)",
              o.name, c.count("H dma-prepare"));
#endif
        CHECK(c.count("H stream-create") == 2, "%s: %zu streams (want 2)", o.name, c.count("H stream-create"));
        for (auto &l : c.lines) {
            if (l.compare(0, 16, "H stream-format ") == 0)
                CHECK(l.find("channels=32 ") != std::string::npos, "%s: stream format changed: %s", o.name, l.c_str());
            // The streams are created on the same 1 MB buffers as with one port.
            if (l.compare(0, 16, "H stream-create ") == 0)
                CHECK(l.find("buffer=1048576") != std::string::npos, "%s: stream buffer size changed: %s", o.name, l.c_str());
            CHECK(l.compare(0, 16, "H stream-buffer ") != 0, "%s: a stream buffer was swapped: %s", o.name, l.c_str());
        }
        for (uint64_t off : { kRegA2H2BUFSIZE, kRegH2A2BUFSIZE, kRegA2H2HBA, kRegH2A2HBA }) {
            char w[32];
            snprintf(w, sizeof(w), "W 0x%06llx ", (unsigned long long)off);
            for (auto &l : c.lines)
                if (l.compare(0, strlen(w), w) == 0)
                    CHECK(l == std::string(w) + "0x00000000", "%s: port-2 DMA register programmed: %s", o.name, l.c_str());
        }
        // No routing entry beyond the 32 port-1 channels.
        for (auto &l : c.lines) {
            unsigned long long off = 0;
            unsigned val = 0;
            if (sscanf(l.c_str(), "W 0x%llx 0x%x", &off, &val) != 2) continue;
            const bool in2  = off >= kRegInputRouting + 32 * 4 && off < kRegInputRouting + 64 * 4;
            const bool out2 = off >= kRegOutputRouting + 32 * 4 && off < kRegOutputRouting + 64 * 4;
            CHECK(!in2 && !out2, "%s: port-2 routing written: %s", o.name, l.c_str());
            if (off == kRegGCSR2)
                CHECK((val & kGCSR2_DMAEnableMask) == 0, "%s: port-2 DMA enabled: %s", o.name, l.c_str());
            if (off == kRegIntMask)
                CHECK((val & ~kInt_A2HWrap) == 0, "%s: extra interrupt enabled: %s", o.name, l.c_str());
        }
    }
    // No access at all to port 2's XLink registers, no command reaches it.
    size_t port2Access = 0;
    for (size_t i = from; i < c.lines.size(); i++) {
        unsigned long long off = 0;
        unsigned val = 0;
        char kind = 0;
        if (sscanf(c.lines[i].c_str(), "%c 0x%llx 0x%x", &kind, &off, &val) != 3 || (kind != 'R' && kind != 'W'))
            continue;
        // The one-port driver's start-up status snapshot reads XLink2Status
        // too; a read of the status register alone is not a probe.
        if (off == kRegXLink2TX || off == kRegXLink2RX || (off == kRegXLink2Status && kind == 'W')) port2Access++;
    }
    CHECK(port2Access == 0, "%s: %zu accesses to port 2's XLink registers at 32 channels", o.name, port2Access);
    CHECK(c.port2TxWhileDisabled == 0, "%s: commands written to port 2 while it was disabled", o.name);
    if (from == 0)
        CHECK(c.port[1].commandsSeen == 0, "%s: port 2 was sent commands at 32 channels", o.name);

    bool enabled2 = false;
    for (auto &l : c.lines) {
        unsigned long long off = 0;
        unsigned val = 0;
        if (sscanf(l.c_str(), "W 0x%llx 0x%x", &off, &val) != 2) continue;
        if (off == kRegXLinkClocking && (val & kXLinkClockEnable2) && (val & kXLinkClockEnable1)) enabled2 = true;
    }
    CHECK(enabled2, "%s: XLINK_CLOCKING_ENABLE_2 never written (the original set both)", o.name);
    // Port 2 disabled (or the card reset and not yet re-programmed, which
    // leaves port 2 off as well).
    CHECK(!c.port2Enabled(), "%s: port 2 enabled at 32 channels (GCSR2=0x%08x, XLinkClocking=0x%08x)",
          o.name, c.reg[kRegGCSR2], c.reg[kRegXLinkClocking]);

    Port2State s = ReadPort2(r);
    CHECK(s.w[1] == 2, "%s: ReadPort2State portCount=%u", o.name, s.w[1]);
    if (from == 0)
        CHECK((s.w[2] & 1u) == 0 && s.w[6] == 0 && s.w[11] == 0,
              "%s: port 2 probed at 32 channels (flags=0x%x units=%u probes=%u)", o.name, s.w[2], s.w[6], s.w[11]);
    // The existing link-state words are untouched by the new selector.
    uint32_t link[16] = {};
    r.drv->ReadLinkState(link);
    CHECK(link[0] == 0, "%s: ReadLinkState word 0 changed", o.name);
}

// SET_SAMPLE_RATE (cmd 0x03, broadcast) writes on a TX register from line
// `from` on: their data bytes, in order.
static std::vector<uint8_t> RateCommands(const FakeCard &c, size_t from, uint64_t tx)
{
    std::vector<uint8_t> out;
    for (size_t i = from; i < c.lines.size(); i++) {
        unsigned long long off = 0;
        unsigned val = 0;
        if (sscanf(c.lines[i].c_str(), "W 0x%llx 0x%x", &off, &val) != 2 || off != tx) continue;
        if (((val >> 9) & 0xFF) == 0x03 && ((val >> 17) & 0x3F) == 0) out.push_back((uint8_t)((val >> 1) & 0xFF));
    }
    return out;
}

static size_t FirstRateCommand(const FakeCard &c, size_t from, uint64_t tx)
{
    for (size_t i = from; i < c.lines.size(); i++) {
        unsigned long long off = 0;
        unsigned val = 0;
        if (sscanf(c.lines[i].c_str(), "W 0x%llx 0x%x", &off, &val) == 2 && off == tx &&
            ((val >> 9) & 0xFF) == 0x03)
            return i;
    }
    return SIZE_MAX;
}

static uint8_t RateCode(double rate)
{
    switch ((uint32_t)rate) {
    case 44100: return 0x04;  case 48000: return 0x00;  case 88200: return 0x05;
    case 96000: return 0x01;  case 176400: return 0x06; case 192000: return 0x02;
    }
    return 0xFF;
}

#ifdef TRACE_HAVE_PORT2_AUDIO
static size_t Select(Run &r, uint32_t value, const char *phase, bool ioRunning = false);
#endif

// At 32 channels a device rate change leaves port 2 alone, as the original
// sent rates only to enabled buses. With 64 selected they reach port 2 when a
// unit was found there, in the
// original's order (port 2 told first, then port 1 changed and verified, then
// port 2 again and verified), and a port-2 failure does not fail port 1.
static void RunPort2RateChange(const Options &o, Run &r)
{
    FakeCard &c = r.card;
    SymphonyThunderbridge *drv = r.drv;
    const uint64_t tx1 = kRegXLink1TX, tx2 = kRegXLink2TX;

    auto change = [&](const char *phase, double rate) {
        c.phase(phase);
        const size_t mark = c.lines.size();
        gHostAudio.device->SetSampleRate(rate);
        kern_return_t rc = drv->StartDevice(1, IOUserAudioStartStopFlags::None);
        Irq(r, 1);
        drv->StopDevice(1, IOUserAudioStartStopFlags::None);
        return std::make_pair(rc, mark);
    };

    // "Port 1: 32ch": port 2 is disabled and is told nothing.
    {
        auto [rc, mark] = change("rate change to 48000 at 32 channels", 48000.0);
        CHECK(rc == kIOReturnSuccess, "%s: rate change at 32 returned 0x%x", o.name, rc);
        CHECK(FirstRateCommand(c, mark, tx2) == SIZE_MAX && c.port[1].commandsSeen == 0,
              "%s: port 2 was told a rate at 32 channels", o.name);
        CheckAt32(o, r);
        auto [rc2, mark2] = change("rate change back to 44100 at 32 channels", 44100.0);
        (void)rc2; (void)mark2;
        CheckAt32(o, r);
    }
#ifdef TRACE_HAVE_PORT2_AUDIO
    // A port-2 failure during a rate change at 64 sends the driver back to
    // 32 channels (stage 2): select 64 again before the next case.
#define ENSURE64(after) ensure64(after)
    auto ensure64 = [&](const char *after) {
        Port2State s = ReadPort2(r);
        if (s.w[14] & kSymphonyPort2AudioActive) return false;
        char phase[96];
        snprintf(phase, sizeof(phase), "select Port 1-2: 64ch again (%s)", after);
        Select(r, 1, phase);
        CHECK(ReadPort2(r).w[14] & kSymphonyPort2AudioActive, "%s: 64 not running again after %s", o.name, after);
        return true;
    };
    Select(r, 1, "select Port 1-2: 64ch");
#else
#define ENSURE64(after) false
#endif
    {
        Port2State s = ReadPort2(r);
        CHECK((s.w[14] & kSymphonyPort2AudioActive) != 0 && s.w[6] == 2 && s.w[11] == 1,
              "%s: 64 not running after the select (audio 0x%08x units %u probes %u)", o.name, s.w[14], s.w[6], s.w[11]);
    }
    static const double rates[] = { 96000.0, 192000.0, 44100.0 };
    uint32_t changes = 0;
    for (double rate : rates) {
        char name[64];
        snprintf(name, sizeof(name), "two-port rate change to %.0f", rate);
        auto [rc, mark] = change(name, rate);
        changes++;
        const uint8_t code = RateCode(rate);
        CHECK(rc == kIOReturnSuccess, "%s: %s returned 0x%x", o.name, name, rc);
        CHECK(c.port[0].rateCode == code && c.port[1].rateCode == code,
              "%s: %s left port 1 at 0x%02x, port 2 at 0x%02x (want 0x%02x)", o.name, name,
              c.port[0].rateCode, c.port[1].rateCode, code);
        // Port 2 first, then port 1, then port 2 again (XLink.cpp:991-1063).
        auto r2 = RateCommands(c, mark, tx2), r1 = RateCommands(c, mark, tx1);
        CHECK(r2.size() == 4 && r1.size() == 2, "%s: %s: %zu port-2 and %zu port-1 rate writes (want 4, 2)",
              o.name, name, r2.size(), r1.size());
        for (uint8_t d : r2) CHECK(d == code, "%s: %s: port 2 sent rate 0x%02x", o.name, name, d);
        CHECK(FirstRateCommand(c, mark, tx2) < FirstRateCommand(c, mark, tx1),
              "%s: %s: port 1 was told before port 2", o.name, name);
        Port2State s = ReadPort2(r);
        CHECK((s.w[2] & kSymphonyPort2FlagRateFailed) == 0, "%s: %s: rate-failed flag set (0x%x)", o.name, name, s.w[2]);
        CHECK(s.w[12] == (uint32_t)rate && s.w[13] == changes, "%s: %s: ReadPort2State rate %u, changes %u",
              o.name, name, s.w[12], s.w[13]);
        CHECK(s.w[6] == 2, "%s: %s: port 2 units %u after the change", o.name, name, s.w[6]);
    }

    // Port 2's units do not follow: port 1's change still succeeds, port 2's
    // failure is reported.
    c.port[1].ignoreRate = true;
    {
        auto [rc, mark] = change("two-port rate change to 48000, port 2 does not follow", 48000.0);
        changes++;
        (void)mark;
        CHECK(rc == kIOReturnSuccess, "%s: port-2 failure failed the device rate change (0x%x)", o.name, rc);
        CHECK(c.port[0].rateCode == 0x00 && c.port[1].rateCode == 0x04,
              "%s: ports at 0x%02x / 0x%02x after port 2 ignored the rate", o.name, c.port[0].rateCode, c.port[1].rateCode);
        Port2State s = ReadPort2(r);
        CHECK((s.w[2] & kSymphonyPort2FlagRateFailed) != 0 && s.w[12] == 0 && s.w[13] == changes,
              "%s: port-2 rate failure not reported (flags 0x%x rate %u changes %u)", o.name, s.w[2], s.w[12], s.w[13]);
    }
    c.port[1].ignoreRate = false;
    // Port 2 did not follow at 64: the driver went back to 32 on its own.
    CHECK(ENSURE64("port 2 did not follow a rate change"), "%s: still at 64 after port 2 did not follow", o.name);

    // Port 1's TX is busy after port 2 was told: port 1 stays at 48k, the
    // change fails, DDS goes back, and port 2 is put back to 48k as well.
    c.port[0].txBusy = true;
    {
        auto [rc, mark] = change("two-port rate change to 88200, port 1 TX busy", 88200.0);
        changes++;
        CHECK(rc == kIOReturnIOError, "%s: rate change with port 1 busy returned 0x%x", o.name, rc);
        auto r2 = RateCommands(c, mark, tx2);
        CHECK(r2.size() == 4 && r2[0] == 0x05 && r2[2] == 0x00,
              "%s: port 2 not told 88.2k then put back to 48k (%zu writes)", o.name, r2.size());
        CHECK(c.port[0].rateCode == 0x00 && c.port[1].rateCode == 0x00,
              "%s: ports at 0x%02x / 0x%02x after the failed change (want both 48k)", o.name,
              c.port[0].rateCode, c.port[1].rateCode);
        Port2State s = ReadPort2(r);
        CHECK((s.w[2] & kSymphonyPort2FlagRateFailed) != 0 && s.w[12] == 0 && s.w[13] == changes,
              "%s: failed change not reported (flags 0x%x rate %u)", o.name, s.w[2], s.w[12]);
    }
    c.port[0].txBusy = false;
    ENSURE64("port 1 TX busy");
    {
        c.phase("two-port rate change retried");
        drv->StartDevice(1, IOUserAudioStartStopFlags::None);
        changes++;
        CHECK(c.port[0].rateCode == 0x05 && c.port[1].rateCode == 0x05,
              "%s: retry left ports at 0x%02x / 0x%02x", o.name, c.port[0].rateCode, c.port[1].rateCode);
        Port2State s = ReadPort2(r);
        CHECK((s.w[2] & kSymphonyPort2FlagRateFailed) == 0 && s.w[12] == 88200 && s.w[13] == changes,
              "%s: retry not reported (flags 0x%x rate %u)", o.name, s.w[2], s.w[12]);
        Irq(r, 1);
        drv->StopDevice(1, IOUserAudioStartStopFlags::None);
    }

    // Sum of the sleeps from line `from` on: time spent inside StartDevice.
    auto sleptMs = [&](size_t from) {
        uint64_t ms = 0;
        for (size_t i = from; i < c.lines.size(); i++) {
            unsigned long long v = 0;
            if (sscanf(c.lines[i].c_str(), "S %llu", &v) == 1) ms += v;
        }
        return ms;
    };

    // Port 2's original 5000 ms rate-change wait tolerates this slip and it is
    // still told before port 1, as XLink::SetSampleRate required.
    ENSURE64("the retry");
    c.port[1].slipReads = 8;
    {
        auto [rc, mark] = change("two-port rate change to 192000, port 2 slipping beforehand", 192000.0);
        changes++;
        CHECK(rc == kIOReturnSuccess, "%s: slipping port 2 failed the change (0x%x)", o.name, rc);
        CHECK(c.port[0].rateCode == 0x02 && c.port[1].rateCode == 0x02,
              "%s: after early slip ports at 0x%02x / 0x%02x (want both 192k)", o.name,
              c.port[0].rateCode, c.port[1].rateCode);
        CHECK(FirstRateCommand(c, mark, tx2) < FirstRateCommand(c, mark, tx1),
              "%s: slipping port 2 was not told first", o.name);
        Port2State s = ReadPort2(r);
        CHECK((s.w[2] & kSymphonyPort2FlagRateFailed) == 0 && s.w[12] == 192000 && s.w[13] == changes,
              "%s: recovered port-2 change not reported (flags 0x%x rate %u)", o.name, s.w[2], s.w[12]);
    }
    // Port 2 never stops slipping: the change still succeeds, the port-2
    // failure is reported, and the port-2 waits stay within their budget.
    ENSURE64("port 2 slipping beforehand");
    c.port[1].slipReads = 1000000;
    {
        auto [rc, mark] = change("two-port rate change to 44100, port 2 always slipping", 44100.0);
        changes++;
        const uint64_t ms = sleptMs(mark);
        c.port[1].slipReads = 0;
        CHECK(rc == kIOReturnSuccess, "%s: always-slipping port 2 failed the change (0x%x)", o.name, rc);
        Port2State s = ReadPort2(r);
        CHECK((s.w[2] & kSymphonyPort2FlagRateFailed) != 0 && s.w[12] == 0 && s.w[13] == changes,
              "%s: slipping port 2 not reported (flags 0x%x rate %u)", o.name, s.w[2], s.w[12]);
        CHECK(ms < 3000, "%s: rate change with port 2 slipping slept %llu ms", o.name, (unsigned long long)ms);
    }
    // Healthy again: next change succeeds on both ports and clears the flag.
    {
        CHECK(ENSURE64("port 2 always slipping"), "%s: still at 64 after port 2 never locked", o.name);
        auto [rc, mark] = change("two-port rate change to 48000 after the slip", 48000.0);
        changes++;
        const uint64_t ms = sleptMs(mark);
        CHECK(rc == kIOReturnSuccess && c.port[1].rateCode == 0x00, "%s: change after slip failed", o.name);
        Port2State s = ReadPort2(r);
        CHECK((s.w[2] & kSymphonyPort2FlagRateFailed) == 0 && s.w[12] == 48000,
              "%s: flag not cleared after a good change (0x%x)", o.name, s.w[2]);
        CHECK(ms < 2500, "%s: healthy two-port rate change slept %llu ms", o.name, (unsigned long long)ms);
    }

    {
        Port2State s = ReadPort2(r);
        CHECK(s.w[6] == 2, "%s: port 2 units %u before it is switched off", o.name, s.w[6]);
    }
    ENSURE64("the good change");

    // Port 2's chain switched off before the link watch noticed: the driver
    // checks port 2's clock itself and sends nothing there.
    c.port[1] = Port();
    {
        auto [rc, mark] = change("two-port rate change to 96000, port 2 switched off", 96000.0);
        changes++;
        CHECK(rc == kIOReturnSuccess, "%s: rate change with port 2 off returned 0x%x", o.name, rc);
        CHECK(RateCommands(c, mark, tx2).empty(), "%s: commands sent on port 2 with no clock there", o.name);
        Port2State s = ReadPort2(r);
        CHECK((s.w[2] & kSymphonyPort2FlagRateFailed) != 0 && s.w[13] == changes,
              "%s: unsent port-2 change not reported (flags 0x%x)", o.name, s.w[2]);
    }
    // Once the watch has seen it go, rate changes leave port 2 alone entirely.
    c.phase("link watch tick: port 2 gone");
    drv->LinkWatchTimerOccurred(nullptr, 0);
    HostPump();
    {
        auto [rc, mark] = change("rate change to 48000 with port 2 empty", 48000.0);
        CHECK(rc == kIOReturnSuccess, "%s: rate change after port 2 went returned 0x%x", o.name, rc);
        CHECK(FirstRateCommand(c, mark, tx2) == SIZE_MAX,
              "%s: port 2 told a rate after it was reported gone", o.name);
        Port2State s = ReadPort2(r);
        CHECK(s.w[13] == changes && s.w[6] == 0, "%s: rate change counted with port 2 gone (%u changes, %u units)",
              o.name, s.w[13], s.w[6]);
        CHECK(!c.port2Enabled(), "%s: port 2 left enabled after the driver went back to 32", o.name);
    }
}

#ifdef TRACE_HAVE_PORT2_AUDIO
// ── Stage 2: the port selector and audio on port 2 ──────────────────────────
static const uint32_t kAudioCapable = kSymphonyPort2AudioCapable, kAudioActive = kSymphonyPort2AudioActive;

static uint32_t AudioReason(const Port2State &s)
{
    return (s.w[14] & kSymphonyPort2AudioReasonMask) >> kSymphonyPort2AudioReasonShift;
}

// What Core Audio does with a configuration change: stop IO if it runs, let the
// device perform the change, start IO again. Returns StartDevice's result.
static kern_return_t HostPerformConfigChange(Run &r, bool ioWasRunning)
{
    if (ioWasRunning) r.drv->StopDevice(1, IOUserAudioStartStopFlags::None);
    r.drv->PerformPortModeChange();
#ifdef kSelectorVBus
    r.drv->PerformVBusChange();   // SymphonyAudioDevice::PerformDeviceConfigurationChange calls both
#endif
    kern_return_t rc = kIOReturnSuccess;
    if (ioWasRunning) {
        rc = r.drv->StartDevice(1, IOUserAudioStartStopFlags::None);
        Irq(r, 1);
    }
    return rc;
}

// The user picks an entry in Audio MIDI Setup (or Sound settings, or Maestro):
// Core Audio sets the selector, the driver asks for a configuration change, and
// Core Audio performs it. Returns the line the request started at.
static size_t Select(Run &r, uint32_t value, const char *phase, bool ioRunning)
{
    FakeCard &c = r.card;
    c.phase(phase);
    const size_t mark = c.lines.size();
    const uint32_t before = gHostAudio.configChangeRequests;
    // SymphonyPortSourceControl::HandleChangeSelectedValues: the selector that
    // was changed (the output one here) sets itself, then tells the driver. The
    // driver must bring the input selector along.
    if (gHostAudio.portSources.size() == 2) gHostAudio.portSources[1]->selected = value;
    const uint32_t inputSetsBefore = gHostAudio.portSources.empty() ? 0 : gHostAudio.portSources[0]->sets;
    kern_return_t rc = r.drv->RequestPortMode(value);
    CHECK(rc == kIOReturnSuccess, "%s: RequestPortMode(%u) returned 0x%x", phase, value, rc);
    // The request itself touches no other AudioDriverKit object.
    CHECK(gHostAudio.portSources.empty() || gHostAudio.portSources[0]->sets == inputSetsBefore,
          "%s: RequestPortMode set a selector from the control's handler", phase);
    // The request itself must not touch the card.
    for (size_t i = mark; i < c.lines.size(); i++)
        CHECK(c.lines[i].compare(0, 2, "R ") != 0 && c.lines[i].compare(0, 2, "W ") != 0,
              "%s: RequestPortMode touched the card: %s", phase, c.lines[i].c_str());
    HostPump();
    if (gHostAudio.configChangeRequests != before) {
        CHECK(gHostAudio.lastConfigChangeAction == 0x504F5254ull, "%s: configuration change action 0x%llx",
              phase, (unsigned long long)gHostAudio.lastConfigChangeAction);
        HostPerformConfigChange(r, ioRunning);
    }
    return mark;
}

static uint32_t StreamChannels(bool input)
{
    IOUserAudioStream *st = input ? gHostAudio.inStream : gHostAudio.outStream;
    return st ? st->current.mChannelsPerFrame : 0;
}

// Index of the first write of `value` to `off` at or after line `from`.
static size_t FindWrite(const FakeCard &c, size_t from, uint64_t off, uint32_t value)
{
    char buf[64];
    snprintf(buf, sizeof(buf), "W 0x%06llx 0x%08x", (unsigned long long)off, value);
    for (size_t i = from; i < c.lines.size(); i++) if (c.lines[i] == buf) return i;
    return SIZE_MAX;
}

static size_t CountAccess(const FakeCard &c, size_t from, char kind, uint64_t off)
{
    char buf[32];
    snprintf(buf, sizeof(buf), "%c 0x%06llx ", kind, (unsigned long long)off);
    size_t n = 0;
    for (size_t i = from; i < c.lines.size(); i++) if (c.lines[i].compare(0, strlen(buf), buf) == 0) n++;
    return n;
}

// Commands with code `cmd` written on a TX register from line `from`: one entry
// per command (each is written twice), as (address << 8) | data.
static std::vector<uint32_t> Commands(const FakeCard &c, size_t from, uint64_t tx, uint8_t cmd)
{
    std::vector<uint32_t> out;
    std::string last;
    for (size_t i = from; i < c.lines.size(); i++) {
        unsigned long long off = 0;
        unsigned val = 0;
        if (sscanf(c.lines[i].c_str(), "W 0x%llx 0x%x", &off, &val) != 2 || off != tx) { continue; }
        if (((val >> 9) & 0xFF) != cmd) { last.clear(); continue; }
        if (c.lines[i] == last) { last.clear(); continue; }   // the second write of the pair
        last = c.lines[i];
        out.push_back((((val >> 17) & 0x3F) << 8) | ((val >> 1) & 0xFF));
    }
    return out;
}

// The card is running both ports the way the original programmed them.
static void CheckBothPortsRunning(const char *what, Run &r, size_t mark)
{
    FakeCard &c = r.card;
    const uint32_t gcsr = c.reg[kRegGCSR], gcsr2 = c.reg[kRegGCSR2];
    CHECK((gcsr & (kGCSR_A2HDMAEnable | kGCSR_H2ADMAEnable)) == (kGCSR_A2HDMAEnable | kGCSR_H2ADMAEnable),
          "%s: port 1 DMA not running (GCSR=0x%08x)", what, gcsr);
    CHECK((gcsr2 & kGCSR2_DMAEnableMask) == kGCSR2_DMAEnableMask, "%s: port 2 DMA not running (GCSR2=0x%08x)", what, gcsr2);
    CHECK((gcsr2 & kGCSR2_DMAMask) == 0x1B, "%s: GCSR2 channel size bits 0x%02x", what, gcsr2 & kGCSR2_DMAMask);
    CHECK((gcsr2 & (kGCSR2_DisablePort1 | kGCSR2_DisablePort2)) == 0, "%s: a port is disabled in GCSR2", what);
    CHECK((c.reg[kRegClkCtrl] & 0x70000000u) == 0x70000000u, "%s: card left muted (ClkCtrl=0x%08x)", what, c.reg[kRegClkCtrl]);
    CHECK(c.reg[kRegA2H2BUFSIZE] == 0x40000 && c.reg[kRegH2A2BUFSIZE] == 0x40000,
          "%s: port-2 buffer sizes 0x%x / 0x%x", what, c.reg[kRegA2H2BUFSIZE], c.reg[kRegH2A2BUFSIZE]);
    CHECK(c.reg[kRegA2H2HBA] == 0x10300000 && c.reg[kRegH2A2HBA] == 0x10400000,
          "%s: port-2 buffer addresses 0x%08x / 0x%08x", what, c.reg[kRegA2H2HBA], c.reg[kRegH2A2HBA]);
    CHECK(c.reg[kRegA2HHBA] == 0x10000000 && c.reg[kRegH2AHBA] == 0x10100000, "%s: port-1 buffer addresses changed", what);
    // Port 2's entries: identity for a Symphony I/O; for converters (dext 131)
    // the routing layer's placement after port 1's 32 (SymphonyConverters.h),
    // with host channels and slots that carry nothing disabled.
    uint32_t wantIn[64] = {}, wantOut[64] = {};
    for (uint32_t n = 32; n < 64; n++) { wantIn[n] = n | 0x100; wantOut[n] = (64 + n) | 0x100; }
    // Host channels are packed across both ports: with converters on port 1
    // too, port 2's follow port 1's units, else they follow the Symphony I/O's 32.
    uint32_t checkFrom = 32;
#ifdef TRACE_HAVE_CONVERTER_PARITY
    bool p2conv = c.port[1].kind == Port::Converters && !c.port[1].units.empty();
    for (const Unit &u : c.port[1].units)
        if (ConverterRouting(u.inquire, u.xtd) == kConverterRoutingSymphony) p2conv = false;
    if (p2conv) {
        const bool p1conv = c.port[0].kind == Port::Converters;
        ConverterChain chain = {};
        if (p1conv)
            for (const Unit &u : c.port[0].units)
                chain.kind[0][chain.count[0]++] = ConverterKindForRouting(ConverterRouting(u.inquire, u.xtd));
        for (const Unit &u : c.port[1].units)
            chain.kind[1][chain.count[1]++] = ConverterKindForRouting(ConverterRouting(u.inquire, u.xtd));
        ConverterChannel inMap[kConverterMaxHostChannels], outMap[kConverterMaxHostChannels];
        ConverterHostMap(chain, true, inMap);
        ConverterHostMap(chain, false, outMap);
        const uint32_t base = p1conv ? 0 : 32;
        checkFrom = p1conv ? 0 : 32;
        for (uint32_t n = checkFrom; n < 64; n++) { wantIn[n] = 0; wantOut[n] = 0; }
        for (uint32_t h = 0; h + base < 64; h++) {
            const uint32_t host = h + base;
            if (inMap[h].valid) wantIn[host] = (inMap[h].port * 32 + inMap[h].slot) | 0x100;
            if (outMap[h].valid)
                wantOut[outMap[h].port * 32 + outMap[h].slot] = (64 + host) | 0x100;
        }
    }
#endif
    for (uint32_t n = checkFrom; n < 64; n++) {
        CHECK(c.reg[kRegInputRouting + n * 4] == wantIn[n], "%s: input route %u = 0x%03x (want 0x%03x)", what, n,
              c.reg[kRegInputRouting + n * 4], wantIn[n]);
        CHECK(c.reg[kRegOutputRouting + n * 4] == wantOut[n], "%s: output route %u = 0x%03x (want 0x%03x)", what, n,
              c.reg[kRegOutputRouting + n * 4], wantOut[n]);
    }
    CHECK(c.reg[kRegIntMask] == kInt_A2HWrap, "%s: interrupt mask 0x%08x (port-1 wrap only)", what, c.reg[kRegIntMask]);
    // Original's order: every step reaches GCSR2 (port 2) before GCSR (port 1).
    // Find the last GCSR2 write that sets both enables and the next GCSR write.
    size_t p2 = SIZE_MAX, p1 = SIZE_MAX, ts2 = SIZE_MAX, ts1 = SIZE_MAX;
    std::vector<size_t> gcsrCandidates;
    for (size_t i = mark; i < c.lines.size(); i++) {
        unsigned long long off = 0;
        unsigned val = 0;
        if (sscanf(c.lines[i].c_str(), "W 0x%llx 0x%x", &off, &val) != 2) continue;
        if (off == kRegGCSR2) {
            if ((val & kGCSR2_DMAEnableMask) == (kGCSR2_A2HTrigSelect | kGCSR2_H2ATrigSelect)) ts2 = i;
            if ((val & kGCSR2_DMAEnableMask) == kGCSR2_DMAEnableMask) p2 = i;
        }
        if (off == kRegGCSR) {
            const uint32_t run = kGCSR_A2HDMAEnable | kGCSR_H2ADMAEnable, ts = kGCSR_A2HTrigSelect | kGCSR_H2ATrigSelect;
            if ((val & (run | ts)) == ts || (val & (run | ts)) == (run | ts))
                gcsrCandidates.push_back(i);
        }
    }
    for (size_t i : gcsrCandidates) {
        unsigned long long off = 0; unsigned val = 0;
        if (sscanf(c.lines[i].c_str(), "W 0x%llx 0x%x", &off, &val) != 2) continue;
        const uint32_t run = kGCSR_A2HDMAEnable | kGCSR_H2ADMAEnable;
        const uint32_t ts = kGCSR_A2HTrigSelect | kGCSR_H2ATrigSelect;
        if (ts1 == SIZE_MAX && i > ts2 && (val & (run | ts)) == ts) ts1 = i;
        if (p1 == SIZE_MAX && i > ts2 && (val & (run | ts)) == (run | ts)) p1 = i;
    }
    if (mark != c.lines.size()) {
        CHECK(ts2 != SIZE_MAX && ts1 != SIZE_MAX && ts2 < ts1, "%s: trigger-selects not written to GCSR2 before GCSR", what);
        CHECK(p2 != SIZE_MAX && p1 != SIZE_MAX && p2 < p1 && ts1 < p2, "%s: enables not written to GCSR2 before GCSR", what);
    }
    Port2State s = ReadPort2(r);
    CHECK((s.w[14] & (kAudioCapable | kAudioActive)) == (kAudioCapable | kAudioActive), "%s: audio word 0x%08x", what, s.w[14]);
    CHECK((s.w[14] & (kSymphonyPort2AudioRefused | kSymphonyPort2AudioFellBack)) == 0 && AudioReason(s) == 0,
          "%s: refusal/fallback still reported (0x%08x)", what, s.w[14]);
}

// The card is running port 1 alone, as the driver has always left it.
static void CheckPort1Alone(const char *what, Run &r, bool expectRunning = true,
                            bool expectOutputUnmuted = true)
{
    FakeCard &c = r.card;
    const uint32_t gcsr = c.reg[kRegGCSR], gcsr2 = c.reg[kRegGCSR2];
    if (expectRunning) {
        CHECK((gcsr & (kGCSR_A2HDMAEnable | kGCSR_H2ADMAEnable)) == (kGCSR_A2HDMAEnable | kGCSR_H2ADMAEnable),
              "%s: port 1 DMA not running (GCSR=0x%08x)", what, gcsr);
        const uint32_t outputBits = c.reg[kRegClkCtrl] & 0x70000000u;
        CHECK(expectOutputUnmuted ? outputBits == 0x70000000u : outputBits == 0x60000000u,
              "%s: card output mute state 0x%08x", what, outputBits);
    }
    CHECK((gcsr2 & kGCSR2_DMAEnableMask) == 0, "%s: port 2 DMA still on (GCSR2=0x%08x)", what, gcsr2);
    // Port 2 itself is disabled again at 32 (the original's SetNumPorts(1)).
    CHECK(!c.port2Enabled(), "%s: port 2 still enabled at 32 (GCSR2=0x%08x)", what, gcsr2);
    for (uint64_t off : { kRegA2H2BUFSIZE, kRegH2A2BUFSIZE, kRegA2H2HBA, kRegH2A2HBA })
        CHECK(c.reg[off] == 0, "%s: port-2 buffer register 0x%02llx = 0x%08x", what, (unsigned long long)off, c.reg[off]);
    for (uint32_t n = 32; n < 64; n++)
        CHECK((c.reg[kRegInputRouting + n * 4] & 0x100) == 0 && (c.reg[kRegOutputRouting + n * 4] & 0x100) == 0,
              "%s: port-2 route %u still enabled", what, n);
    CHECK(c.reg[kRegA2HHBA] == 0x10000000 && c.reg[kRegH2AHBA] == 0x10100000 &&
          c.reg[kRegA2HBUFSIZE] == 0x40000 && c.reg[kRegH2ABUFSIZE] == 0x40000, "%s: port-1 buffer registers changed", what);
    for (uint32_t n = 2; n < 32; n++)
        CHECK(c.reg[kRegInputRouting + n * 4] == (n | 0x100) && c.reg[kRegOutputRouting + n * 4] == ((64 + n) | 0x100),
              "%s: port-1 route %u changed", what, n);
    Port2State s = ReadPort2(r);
    CHECK((s.w[14] & kAudioActive) == 0, "%s: audio word still says 64 is running (0x%08x)", what, s.w[14]);
}

static void CheckPublished(const char *what, uint32_t channels)
{
    CHECK(StreamChannels(true) == channels && StreamChannels(false) == channels,
          "%s: streams are %u in / %u out (want %u)", what, StreamChannels(true), StreamChannels(false), channels);
    CHECK(gHostAudio.portSources.size() == 2, "%s: %zu port selectors (want 2)", what, gHostAudio.portSources.size());
    for (auto *sel : gHostAudio.portSources)
        CHECK(sel->selected == (channels == 64 ? 1u : 0u), "%s: a selector shows %u", what, sel->selected);
    // Each stream's buffer is exactly one ring of the format in effect.
    for (IOUserAudioStream *st : { gHostAudio.inStream, gHostAudio.outStream })
        CHECK(st && st->memory && st->memory->size_ == (uint64_t)kNumSampleFrames * channels * 4,
              "%s: stream buffer is %llu bytes for %u channels", what,
              (unsigned long long)(st && st->memory ? st->memory->size_ : 0), channels);
    CHECK(gHostLocksHeld == 0, "%s: a lock is still held", what);
}

// Run the two-port IO handler over a block that wraps the end of the ring and
// check where every sample went.
static void CheckIOHandler(const char *what, uint32_t channels)
{
    auto handler = (IOOperationHandler)gHostAudio.ioHandler;
    // Creation order: A2H, H2A, 32-ch in/out stream buffers, meters, A2H2, H2A2,
    // 64-ch in/out stream buffers.
    CHECK(handler != nullptr && gHostAudio.buffers.size() >= 9, "%s: no IO handler or buffers", what);
    if (!handler || gHostAudio.buffers.size() < 9) return;
    int32_t *a2h1 = (int32_t *)gHostAudio.buffers[0]->mem_, *h2a1 = (int32_t *)gHostAudio.buffers[1]->mem_;
    int32_t *in = (int32_t *)gHostAudio.buffers[channels == 64 ? 7 : 2]->mem_;
    int32_t *out = (int32_t *)gHostAudio.buffers[channels == 64 ? 8 : 3]->mem_;
    int32_t *a2h2 = (int32_t *)gHostAudio.buffers[5]->mem_, *h2a2 = (int32_t *)gHostAudio.buffers[6]->mem_;
    // The handler must be using the buffer the stream has been given.
    CHECK(gHostAudio.inStream->memory == gHostAudio.buffers[channels == 64 ? 7 : 2] &&
          gHostAudio.outStream->memory == gHostAudio.buffers[channels == 64 ? 8 : 3],
          "%s: the streams are not on the %u-channel buffers", what, channels);
    const uint32_t ring = kNumSampleFrames, frames = 512, start = ring - 200;
    auto frameAt = [&](uint32_t n) { return (start + n) % ring; };
    auto tag = [](uint32_t frame, uint32_t ch, uint32_t salt) { return (int32_t)((salt << 28) | (frame << 8) | ch); };
    memset(h2a1, 0, ring * 128); memset(h2a2, 0, ring * 128);
    memset(in, 0, (size_t)ring * channels * 4);
    for (uint32_t n = 0; n < frames; n++)
        for (uint32_t ch = 0; ch < channels; ch++) out[(size_t)frameAt(n) * channels + ch] = tag(frameAt(n), ch, 1);
    for (uint32_t n = 0; n < frames; n++)
        for (uint32_t ch = 0; ch < 32; ch++) {
            a2h1[(size_t)frameAt(n) * 32 + ch] = tag(frameAt(n), ch, 2);
            a2h2[(size_t)frameAt(n) * 32 + ch] = tag(frameAt(n), 32 + ch, 2);
        }
    handler(1, IOUserAudioIOOperationWriteEnd, frames, (uint64_t)ring * 7 + start, 0);
    handler(1, IOUserAudioIOOperationBeginRead, frames, (uint64_t)ring * 7 + start, 0);
    uint32_t bad = 0;
    for (uint32_t n = 0; n < frames; n++) {
        const uint32_t f = frameAt(n);
        for (uint32_t ch = 0; ch < 32; ch++) {
            if (h2a1[(size_t)f * 32 + ch] != tag(f, ch, 1)) bad++;
            if (in[(size_t)f * channels + ch] != tag(f, ch, 2)) bad++;
            if (channels == 64) {
                if (h2a2[(size_t)f * 32 + ch] != tag(f, 32 + ch, 1)) bad++;
                if (in[(size_t)f * 64 + 32 + ch] != tag(f, 32 + ch, 2)) bad++;
            } else if (h2a2[(size_t)f * 32 + ch] != 0) bad++;   // 32 channels: port 2's buffer untouched
        }
    }
    // Nothing outside the block was written.
    const uint32_t outside = (start + frames) % ring + 3;
    if (h2a1[(size_t)outside * 32] != 0 || h2a2[(size_t)outside * 32] != 0 || in[(size_t)outside * channels] != 0) bad++;
    CHECK(bad == 0, "%s: IO handler misplaced %u samples at %u channels", what, bad, channels);
}

// Both port selectors show the two fixed entries, "Symphony I/O: ThunderBridge"
// and "Symphony I/O: ThunderBridge 64", with their values and order, and keep
// the selection. (The temporary naming switch that could rename them was
// removed before the first beta.)
static void CheckPortSourceNames(const Options &o, uint32_t selected, const char *when)
{
    CHECK(gHostAudio.portSources.size() == 2, "%s (%s): %zu port selectors", o.name, when, gHostAudio.portSources.size());
    for (auto *sel : gHostAudio.portSources)
        CHECK(sel->values.size() == 2 && sel->names.size() == 2 &&
              sel->values[0] == kSymphonyPortSourcePort1 && sel->values[1] == kSymphonyPortSourcePorts1And2 &&
              sel->names[0] == kSymphonyPortSourceName32 && sel->names[1] == kSymphonyPortSourceName64 &&
              sel->selected == selected,
              "%s (%s): port selector entries or selection wrong", o.name, when);
}

// p2-audio-enable: the selector, 32 -> 64 -> 32, and a request that is refused.
static void RunAudioEnable(const Options &o, Run &r)
{
    FakeCard &c = r.card;
    CHECK(gHostAudio.portSources.size() == 2, "%s: %zu port selectors published (want 2)", o.name, gHostAudio.portSources.size());
    for (auto *sel : gHostAudio.portSources) {
        CHECK(sel->names.size() == 2 && sel->names[0] == kSymphonyPortSourceName32 && sel->names[1] == kSymphonyPortSourceName64,
              "%s: selector entries are not the two names", o.name);
        CHECK(sel->selected == 0, "%s: selector does not start at the 32-channel entry", o.name);
    }
    CheckPublished("at start", 32);
    CheckPort1Alone("at start", r);
    CheckIOHandler("32 channels at start", 32);
    CheckPortSourceNames(o, kSymphonyPortSourcePort1, "at 32 channels");

    // The entry already selected: no configuration change, no card access.
    {
        const uint32_t before = gHostAudio.configChangeRequests;
        const size_t mark = Select(r, 0, "select Port 1: 32ch again");
        CHECK(gHostAudio.configChangeRequests == before, "%s: re-selecting 32 asked for a configuration change", o.name);
        CHECK(CountAccess(c, mark, 'W', kRegGCSR) == 0, "%s: re-selecting 32 wrote GCSR", o.name);
    }

    size_t mark = Select(r, 1, "select Port 1-2: 64ch");
    CheckBothPortsRunning("after selecting 64", r, mark);
    CHECK((c.reg[kRegGCSR] & (kGCSR_ClockOKFlash | kGCSR_ClockOKSolid)) == 0,
          "%s: active port-2 GCSR LED is not on", o.name);
    CHECK(c.reg[kRegPort1GreenCtl] == 0xFFFFFF0F && c.reg[kRegPort1RedCtl] == 0 && c.reg[kRegPort1BlueCtl] == 0,
          "%s: active port-2 RGB LED is not solid green", o.name);
    CheckPublished("after selecting 64", 64);
    CheckPortSourceNames(o, kSymphonyPortSourcePorts1And2, "at 64 channels");
    {
        // Port 2 enabled, then probed (bus reset, the rate to all, units
        // addressed, the rate again), then told the rate and verified, then
        // phase read from both of its converters and the jam written, then
        // each unit unmuted. Three rate commands (each is written to the
        // register twice), all the current rate.
        CHECK(RateCommands(c, mark, kRegXLink2TX) == std::vector<uint8_t>({ 0x04, 0x04, 0x04, 0x04, 0x04, 0x04 }),
              "%s: port 2 not told the current rate by the probe and the switch (%zu rate writes)", o.name,
              RateCommands(c, mark, kRegXLink2TX).size());
        size_t firstPort2 = SIZE_MAX, cleared = SIZE_MAX;
        for (size_t i = mark; i < c.lines.size(); i++) {
            unsigned long long off = 0;
            unsigned val = 0;
            if (sscanf(c.lines[i].c_str(), "W 0x%llx 0x%x", &off, &val) != 2) continue;
            if (off == kRegGCSR2 && (val & kGCSR2_DisablePort2) == 0 && cleared == SIZE_MAX) cleared = i;
            if ((off == kRegXLink2TX || off == kRegXLink2Status) && firstPort2 == SIZE_MAX) firstPort2 = i;
        }
        CHECK(cleared != SIZE_MAX && firstPort2 != SIZE_MAX && cleared < firstPort2,
              "%s: port 2 was talked to before it was enabled", o.name);
        CHECK(ReadPort2(r).w[11] == 1, "%s: port 2 probed %u times by the first select (want 1)", o.name, ReadPort2(r).w[11]);
        CHECK(FirstRateCommand(c, mark, kRegXLink2TX) < FindWrite(c, mark, kRegA2H2HBA, 0x10300000),
              "%s: port-2 buffers programmed before port 2 was told the rate", o.name);
        auto phases = Commands(c, mark, kRegXLink2TX, 0x09);
        CHECK(phases == std::vector<uint32_t>({ 0x0100, 0x0200 }), "%s: %zu phase queries on port 2 (want units 1 and 2)", o.name, phases.size());
        CHECK(Commands(c, mark, kRegXLink1TX, 0x09).empty(), "%s: a Symphony I/O on port 1 was asked its phase", o.name);
        // Both units report 0x20: jam = 0x20 - 5.
        CHECK(FindWrite(c, mark, kRegJam, 0x1B) != SIZE_MAX, "%s: jam 0x1B not written", o.name);
        auto unmutes = Commands(c, mark, kRegXLink2TX, 0x0A);
        CHECK(unmutes == std::vector<uint32_t>({ 0x0180, 0x0280 }), "%s: port 2 units not unmuted one by one", o.name);
        CHECK(c.port[1].units[0].unmutes == 1 && c.port[1].units[1].unmutes == 1, "%s: port-2 units did not see the unmute", o.name);
        Port2State s = ReadPort2(r);
        CHECK((s.w[14] & kSymphonyPort2AudioPhaseAligned) && !(s.w[14] & kSymphonyPort2AudioPhaseFailed) &&
              (s.w[14] & kSymphonyPort2AudioPublished64), "%s: audio word 0x%08x after enable", o.name, s.w[14]);
        CHECK(s.w[15] == (0x80000000u | 0x1B | (2u << 8) | (0x20u << 16)), "%s: phase word 0x%08x", o.name, s.w[15]);
        CHECK((s.w[14] >> 16) == 1, "%s: mode change count %u", o.name, s.w[14] >> 16);
        // Port 1's units were sent nothing at all by the switch.
        CHECK(CountAccess(c, mark, 'W', kRegXLink1TX) == 0, "%s: the switch sent commands on port 1", o.name);
    }
    CheckIOHandler("64 channels", 64);

    // IO runs; wraps are timestamped from the port-1 interrupt as before.
    c.phase("IO at 64 channels");
    CHECK(r.drv->StartDevice(1, IOUserAudioStartStopFlags::None) == kIOReturnSuccess, "%s: StartDevice at 64 failed", o.name);
    Irq(r, 1);
    Irq(r, 1);
    r.drv->LinkWatchTimerOccurred(nullptr, 0);
    HostPump();
    CheckBothPortsRunning("after a link watch tick at 64", r, mark);

    mark = Select(r, 0, "select Port 1: 32ch", /*ioRunning*/true);
    CheckPort1Alone("after selecting 32", r);
    CheckPublished("after selecting 32", 32);
    CheckIOHandler("32 channels after 64", 32);
    CHECK(CountAccess(c, mark, 'W', kRegXLink2TX) == 0 && CountAccess(c, mark, 'W', kRegXLink1TX) == 0,
          "%s: switching back to 32 sent XLink commands", o.name);
    CHECK((c.reg[kRegGCSR2] & kGCSR2_DisablePort2) != 0, "%s: port 2 left enabled after going back to 32", o.name);
    CHECK((c.reg[kRegGCSR] & kGCSR_ClockOKSolid) != 0 && (c.reg[kRegGCSR] & kGCSR_ClockOKFlash) == 0,
          "%s: disabled port-2 GCSR LED is not off", o.name);
    CHECK(c.reg[kRegPort1GreenCtl] == 0 && c.reg[kRegPort1RedCtl] == 0 && c.reg[kRegPort1BlueCtl] == 0,
          "%s: disabled port-2 RGB LED is not off", o.name);
    r.drv->StopDevice(1, IOUserAudioStartStopFlags::None);
    // Back at 32 a rate change leaves port 2 alone, though its units are known.
    {
        c.phase("rate change to 48000 back at 32 channels");
        const size_t m = c.lines.size();
        gHostAudio.device->SetSampleRate(48000.0);
        CHECK(r.drv->StartDevice(1, IOUserAudioStartStopFlags::None) == kIOReturnSuccess, "%s: rate change at 32 failed", o.name);
        Irq(r, 1);
        r.drv->StopDevice(1, IOUserAudioStartStopFlags::None);
        CHECK(CountAccess(c, m, 'W', kRegXLink2TX) == 0 && CountAccess(c, m, 'R', kRegXLink2Status) == 0,
              "%s: port 2 was told a rate at 32 channels after 64", o.name);
        CHECK(c.port2TxWhileDisabled == 0, "%s: commands written to a disabled port 2", o.name);
        gHostAudio.device->SetSampleRate(44100.0);
        r.drv->StartDevice(1, IOUserAudioStartStopFlags::None);
        Irq(r, 1);
        r.drv->StopDevice(1, IOUserAudioStartStopFlags::None);
    }

    // The card does not keep the port-2 buffer addresses: refused, port 1 back.
    c.dropPort2Addresses = true;
    mark = Select(r, 1, "select 64: card drops the port-2 buffer addresses");
    c.dropPort2Addresses = false;
    CheckPort1Alone("after the address readback failed", r);
    CheckPublished("after the address readback failed", 32);
    {
        Port2State s = ReadPort2(r);
        CHECK((s.w[14] & kSymphonyPort2AudioRefused) && AudioReason(s) == kSymphonyPort2ReasonRegisters,
              "%s: readback failure not reported (0x%08x)", o.name, s.w[14]);
    }

    // Port 2 does not lock at the current rate: refused, port 1 back.
    c.port[1].slipReads = 1000000;
    mark = Select(r, 1, "select 64: port 2 never locks");
    c.port[1].slipReads = 0;
    CheckPort1Alone("after port 2 did not lock", r);
    CheckPublished("after port 2 did not lock", 32);
    {
        Port2State s = ReadPort2(r);
        CHECK((s.w[14] & kSymphonyPort2AudioRefused) && AudioReason(s) == kSymphonyPort2ReasonRateNotLocked,
              "%s: lock failure not reported (0x%08x)", o.name, s.w[14]);
        CHECK(CountAccess(c, mark, 'W', kRegA2H2HBA) == 0, "%s: port-2 buffers programmed although port 2 did not lock", o.name);
    }

    // And it still works afterwards; Stop then runs with both ports on.
    mark = Select(r, 1, "select Port 1-2: 64ch again");
    CheckBothPortsRunning("second enable", r, mark);
    CheckPublished("second enable", 64);
}

// H: a fresh instance keeps only the output gate muted while Core Audio
// restores its controls and, dext 151, its saved rate. A control set alone no
// longer releases it: the gate opens once a control was set AND Core Audio's
// rate is on the hardware, or at the bounded timeout. Link recovery is covered
// by the existing full lifecycle traces and must not arm this gate.
void SymphonySyncHardwareRate(IOUserAudioDevice *device, double rate, uint64_t changeAction, const char *why);

// Whether a ClkCtrl write from line `from` set the output unmute bit.
static bool OutputUnmuteWritten(const FakeCard &c, size_t from, size_t to)
{
    for (size_t i = from; i < to && i < c.lines.size(); i++) {
        unsigned long long off = 0;
        unsigned val = 0;
        if (sscanf(c.lines[i].c_str(), "W 0x%llx 0x%x", &off, &val) == 2 &&
            off == kRegClkCtrl && (val & kClkCtrl_OutputUnmute)) return true;
    }
    return false;
}

// One rate transaction from line `from`: the 48 kHz rate code alone on the
// bus, and the DDS moved to 48 kHz once.
static void CheckOneRateProgramAt48k(const char *what, const FakeCard &c, size_t from)
{
    const std::vector<uint8_t> sent = RateCommands(c, from, kRegXLink1TX);
    bool all48 = !sent.empty();
    for (uint8_t v : sent) if (v != 0x00) all48 = false;
    CHECK(all48 && c.port[0].rateCode == 0x00,
          "H: %s: Core Audio's 48 kHz not programmed alone (%zu rate writes, unit code 0x%02x)",
          what, sent.size(), c.port[0].rateCode);
    size_t ddsTo48 = 0;
    uint32_t lastDds = 0xFFFFFFFFu;
    for (size_t i = from; i < c.lines.size(); i++) {
        unsigned long long off = 0;
        unsigned val = 0;
        if (sscanf(c.lines[i].c_str(), "W 0x%llx 0x%x", &off, &val) != 2 || off != kRegGCSR) continue;
        const uint32_t dds = val & kGCSR_DDSMask;
        if (dds == kGCSR_DDS_48000 && lastDds != kGCSR_DDS_48000) ddsTo48++;
        lastDds = dds;
    }
    CHECK(ddsTo48 == 1, "H: %s: DDS set to 48 kHz %zu times for Core Audio's one rate (want 1)", what, ddsTo48);
}

static uint32_t OutputGate(const FakeCard &c) { return c.reg.at(kRegClkCtrl) & 0x70000000u; }

static void RunStartupOutputMuteChecks()
{
    gHostStartupOutputHoldNs = 3000000000ull;
    struct Restore { ~Restore() { gHostStartupOutputHoldNs = 0; } } restore;
    Options o; o.name = "startup output mute"; o.shortFlow = true;
    o.port1 = Port::Symphony;
    Run r;
    RunScenario(o, r);
    CHECK(OutputGate(r.card) == 0x60000000u,
          "H: fresh instance left output unmuted (ClkCtrl=0x%08x)", r.card.reg[kRegClkCtrl]);
    CHECK(!OutputUnmuteWritten(r.card, 0, r.card.lines.size()),
          "H: a fresh instance wrote the output unmute during Start");
    Finish(o, r);

    // Core Audio has not started IO in the cases below.
    Options idle = o; idle.noIoStart = true;
    // dext 152: the gate opens a short grace after the rate settles; it no
    // longer waits for a Core Audio control to change. A tick of the link
    // watch queues the release on xlinkQueue; HostPump runs it.
    auto tick = [](Run &r) { r.drv->LinkWatchTimerOccurred(nullptr, 0); HostPump(); };
    auto pastGrace = [] { std::this_thread::sleep_for(std::chrono::milliseconds(450)); };
    auto speakerMute = [](const FakeCard &c) {
        auto it = c.port[0].stored.find((uint64_t)0x27 << 32);
        return it != c.port[0].stored.end() && !it->second.empty() ? (int)it->second[0] : -1;
    };

    // Fresh start at 44.1 kHz; Core Audio restores the mute, then its saved
    // 48 kHz. The gate stays closed after the control set (the hardware is
    // still at Start's 44.1 kHz), the 48 kHz is programmed exactly once, the
    // mute is on the unit, and the output opens only after the grace.
    Run muted;
    RunScenario(idle, muted);
    const size_t startMark = muted.card.lines.size();
    CHECK(muted.card.port[0].rateCode == 0x04 && !RateCommands(muted.card, 0, kRegXLink1TX).empty(),
          "H: Start did not leave the unit at 44.1 kHz (code 0x%02x)", muted.card.port[0].rateCode);
    gHostAudio.mute->SetControlValue(true);
    Irq(muted, 1);
    HostPump();
    tick(muted);
    CHECK(OutputGate(muted.card) == 0x60000000u,
          "H: output released after the control set, before Core Audio's rate (ClkCtrl=0x%08x)",
          muted.card.reg[kRegClkCtrl]);
    const size_t rateMark = muted.card.lines.size();
    CHECK(RateCommands(muted.card, startMark, kRegXLink1TX).empty(),
          "H: a rate was programmed between Start and Core Audio's rate set");
    gHostAudio.device->SetSampleRate(48000.0);
    SymphonySyncHardwareRate(gHostAudio.device, 48000.0, 0, "test, Core Audio restores 48 kHz");
    HostPump();
    CheckOneRateProgramAt48k("control then rate", muted.card, rateMark);
    tick(muted);
    CHECK(OutputGate(muted.card) == 0x60000000u,
          "H: control then rate: output released within the grace (ClkCtrl=0x%08x)", muted.card.reg[kRegClkCtrl]);
    const size_t graceMark = muted.card.lines.size();
    pastGrace();
    tick(muted);
    CHECK(!OutputUnmuteWritten(muted.card, 0, graceMark),
          "H: the output unmute was written before the grace after Core Audio's rate");
    CHECK(OutputGate(muted.card) == 0x70000000u && speakerMute(muted.card) == 1,
          "H: control then rate: ClkCtrl=0x%08x, unit speaker mute %d after the grace (want released, muted)",
          muted.card.reg[kRegClkCtrl], speakerMute(muted.card));
    Finish(idle, muted);

    // The rate first, then Core Audio's mute within the grace: the mute is
    // on the unit before the outputs open.
    Run rateFirst;
    RunScenario(idle, rateFirst);
    const size_t rfMark = rateFirst.card.lines.size();
    gHostAudio.device->SetSampleRate(48000.0);
    SymphonySyncHardwareRate(gHostAudio.device, 48000.0, 0, "test, Core Audio restores 48 kHz");
    HostPump();
    CheckOneRateProgramAt48k("rate then control", rateFirst.card, rfMark);
    gHostAudio.mute->SetControlValue(true);
    Irq(rateFirst, 1);
    HostPump();
    tick(rateFirst);
    CHECK(OutputGate(rateFirst.card) == 0x60000000u && speakerMute(rateFirst.card) == 1,
          "H: mute within the grace: ClkCtrl=0x%08x, unit speaker mute %d (want held, muted)",
          rateFirst.card.reg[kRegClkCtrl], speakerMute(rateFirst.card));
    pastGrace();
    tick(rateFirst);
    CHECK(OutputGate(rateFirst.card) == 0x70000000u && speakerMute(rateFirst.card) == 1,
          "H: mute within the grace: ClkCtrl=0x%08x, unit speaker mute %d after it (want released, muted)",
          rateFirst.card.reg[kRegClkCtrl], speakerMute(rateFirst.card));
    Finish(idle, rateFirst);

    // The rate and no control change at all (Core Audio restores the values
    // the controls already show): released after the grace, not at 3 s.
    Run noControl;
    RunScenario(idle, noControl);
    gHostAudio.device->SetSampleRate(48000.0);
    SymphonySyncHardwareRate(gHostAudio.device, 48000.0, 0, "test, Core Audio restores 48 kHz");
    HostPump();
    tick(noControl);
    CHECK(OutputGate(noControl.card) == 0x60000000u,
          "H: rate, no control: output released within the grace (ClkCtrl=0x%08x)", noControl.card.reg[kRegClkCtrl]);
    pastGrace();
    tick(noControl);
    CHECK(OutputGate(noControl.card) == 0x70000000u,
          "H: rate, no control: output not released after the grace (ClkCtrl=0x%08x)", noControl.card.reg[kRegClkCtrl]);
    Finish(idle, noControl);

    // Core Audio sets the rate the hardware already runs at: nothing is
    // reprogrammed, and the gate opens after the grace, not at the deadline.
    Run same;
    RunScenario(idle, same);
    const size_t sameMark = same.card.lines.size();
    SymphonySyncHardwareRate(gHostAudio.device, 44100.0, 0, "test, Core Audio sets 44.1 kHz");
    HostPump();
    pastGrace();
    tick(same);
    CHECK(RateCommands(same.card, sameMark, kRegXLink1TX).empty() && OutputGate(same.card) == 0x70000000u,
          "H: same rate: %zu rate writes, ClkCtrl=0x%08x (want none, released)",
          RateCommands(same.card, sameMark, kRegXLink1TX).size(), same.card.reg[kRegClkCtrl]);
    Finish(idle, same);

    // A DAW starts IO before Core Audio sets any rate (a saved 44.1 kHz is
    // never set). The IO start can come before Core Audio has restored its
    // controls, so it does not count as the rate settling for the gate: the
    // gate keeps the 3 s deadline (dext 152, second fix), with no reprogram.
    // A later 48 kHz is one rate transaction that mutes the card's outputs
    // for its length.
    Run daw;
    RunScenario(idle, daw);
    const size_t dawMark = daw.card.lines.size();
    daw.drv->StartDevice(1, IOUserAudioStartStopFlags::None);
    HostPump();
    pastGrace();
    tick(daw);
    CHECK(OutputGate(daw.card) == 0x60000000u,
          "H: DAW: output released within the grace after an IO start (ClkCtrl=0x%08x, want held to 3 s)",
          daw.card.reg[kRegClkCtrl]);
    std::this_thread::sleep_for(std::chrono::milliseconds(2700));
    tick(daw);
    CHECK(OutputGate(daw.card) == 0x70000000u && RateCommands(daw.card, dawMark, kRegXLink1TX).empty(),
          "H: DAW: ClkCtrl=0x%08x, %zu rate writes after the IO start (want released at 3 s, none)",
          daw.card.reg[kRegClkCtrl], RateCommands(daw.card, dawMark, kRegXLink1TX).size());
    daw.drv->StopDevice(1, IOUserAudioStartStopFlags::None);
    HostPump();
    const size_t dawRate = daw.card.lines.size();
    gHostAudio.device->SetSampleRate(48000.0);
    SymphonySyncHardwareRate(gHostAudio.device, 48000.0, 0, "test, 48 kHz after the DAW");
    HostPump();
    CheckOneRateProgramAt48k("DAW, then 48 kHz", daw.card, dawRate);
    {
        // The transaction's first ClkCtrl write mutes the outputs.
        bool mutedFirst = false;
        for (size_t i = dawRate; i < daw.card.lines.size(); i++) {
            unsigned long long off = 0;
            unsigned val = 0;
            if (sscanf(daw.card.lines[i].c_str(), "W 0x%llx 0x%x", &off, &val) == 2 && off == kRegClkCtrl) {
                mutedFirst = (val & kClkCtrl_OutputUnmute) == 0;
                break;
            }
        }
        CHECK(mutedFirst && OutputGate(daw.card) == 0x70000000u,
              "H: DAW, then 48 kHz: outputs not muted for the change or not open after (ClkCtrl=0x%08x)",
              daw.card.reg[kRegClkCtrl]);
    }
    Finish(idle, daw);

    // Core Audio restores mute on, but no interrupt runs the monitor poll
    // before the gate opens (IO not started yet). The release samples the
    // controls itself: the speaker mute reaches the unit before the output
    // unmute. Line index of the first speaker-mute write vs the first
    // ClkCtrl write with the output unmute bit.
    auto checkMuteBeforeUnmute = [&](const char *what, Run &r, size_t from, size_t muteLine) {
        size_t unmuteLine = SIZE_MAX;
        for (size_t i = from; i < r.card.lines.size() && unmuteLine == SIZE_MAX; i++)
            if (OutputUnmuteWritten(r.card, i, i + 1)) unmuteLine = i;
        CHECK(unmuteLine != SIZE_MAX && OutputGate(r.card) == 0x70000000u,
              "H: %s: outputs not released (ClkCtrl=0x%08x)", what, r.card.reg[kRegClkCtrl]);
        CHECK(muteLine != SIZE_MAX && muteLine < unmuteLine && speakerMute(r.card) == 1,
              "H: %s: speaker mute line %zu, output unmute line %zu, unit mute %d (want the mute first, on)",
              what, muteLine, unmuteLine, speakerMute(r.card));
    };
    {
        Run noIrq;
        RunScenario(idle, noIrq);
        size_t muteLine = SIZE_MAX;
        noIrq.card.onVendorWrite = [&](unsigned p, uint8_t cmd) {
            if (p == 0 && cmd == 0x27 && muteLine == SIZE_MAX) muteLine = noIrq.card.lines.size();
        };
        const size_t mark = noIrq.card.lines.size();
        gHostAudio.mute->SetControlValue(true);
        gHostAudio.device->SetSampleRate(48000.0);
        SymphonySyncHardwareRate(gHostAudio.device, 48000.0, 0, "test, Core Audio restores 48 kHz");
        HostPump();
        pastGrace();
        tick(noIrq);
        checkMuteBeforeUnmute("mute, rate, no interrupt", noIrq, mark, muteLine);
        noIrq.card.onVendorWrite = nullptr;
        Finish(idle, noIrq);
    }
    // The same with the unit's levels never read at bring-up (every read
    // lost): the poll's rules alone would drop the restored mute (the level
    // read shows the unit's mute off, or with reads still lost the mute is
    // put back). A mute on is never louder, so the release sends it anyway.
    for (int stillLost = 0; stillLost < 2; stillLost++) {
        Options lost = idle; lost.dropVendorReads = 8; lost.symphonyInquire = 0xF0;
        Run r;
        RunScenario(lost, r);
        size_t muteLine = SIZE_MAX;
        r.card.onVendorWrite = [&](unsigned p, uint8_t cmd) {
            if (p == 0 && cmd == 0x27 && muteLine == SIZE_MAX) muteLine = r.card.lines.size();
        };
        const size_t mark = r.card.lines.size();
        gHostAudio.mute->SetControlValue(true);
        gHostAudio.device->SetSampleRate(48000.0);
        SymphonySyncHardwareRate(gHostAudio.device, 48000.0, 0, "test, Core Audio restores 48 kHz");
        HostPump();
        pastGrace();
        if (stillLost) r.card.port[0].dropVendorReads = 3;
        tick(r);
        r.card.port[0].dropVendorReads = 0;
        checkMuteBeforeUnmute(stillLost ? "mute, levels unknown, reads still lost"
                                        : "mute, levels unknown, read at release", r, mark, muteLine);
        CHECK(gHostAudio.mute->GetControlValue(),
              "H: levels unknown (%d): the Mac's mute was turned off by the release", stillLost);
        r.card.onVendorWrite = nullptr;
        Finish(lost, r);
    }
    {
        // The same with IO started at the hardware's rate: held to the 3 s
        // deadline, and the mute Core Audio set meanwhile is applied first.
        Run ioStart;
        RunScenario(idle, ioStart);
        size_t muteLine = SIZE_MAX;
        ioStart.card.onVendorWrite = [&](unsigned p, uint8_t cmd) {
            if (p == 0 && cmd == 0x27 && muteLine == SIZE_MAX) muteLine = ioStart.card.lines.size();
        };
        const size_t mark = ioStart.card.lines.size();
        ioStart.drv->StartDevice(1, IOUserAudioStartStopFlags::None);
        HostPump();
        pastGrace();
        tick(ioStart);
        CHECK(OutputGate(ioStart.card) == 0x60000000u,
              "H: IO start: output released within the grace (ClkCtrl=0x%08x, want held to 3 s)",
              ioStart.card.reg[kRegClkCtrl]);
        gHostAudio.mute->SetControlValue(true);   // Core Audio's restore, after the IO start
        std::this_thread::sleep_for(std::chrono::milliseconds(2700));
        tick(ioStart);
        checkMuteBeforeUnmute("IO start, then mute, no interrupt", ioStart, mark, muteLine);
        ioStart.card.onVendorWrite = nullptr;
        ioStart.drv->StopDevice(1, IOUserAudioStartStopFlags::None);
        HostPump();
        Finish(idle, ioStart);
    }

    // Timeout: Core Audio sets no rate and no control, and starts no IO. The
    // unit keeps Start's 44.1 kHz, nothing reprograms it, and the output
    // opens at 3 s, as before dext 151.
    Run timeout;
    RunScenario(idle, timeout);
    const size_t timeoutMark = timeout.card.lines.size();
    tick(timeout);
    CHECK(OutputGate(timeout.card) == 0x60000000u,
          "H: timeout: output released before the deadline (ClkCtrl=0x%08x)", timeout.card.reg[kRegClkCtrl]);
    std::this_thread::sleep_for(std::chrono::milliseconds(3100));
    tick(timeout);
    CHECK(OutputGate(timeout.card) == 0x70000000u,
          "H: output did not release after the 3 s timeout (ClkCtrl=0x%08x)", timeout.card.reg[kRegClkCtrl]);
    CHECK(timeout.card.port[0].rateCode == 0x04 && RateCommands(timeout.card, timeoutMark, kRegXLink1TX).empty(),
          "H: timeout: unit code 0x%02x, %zu rate writes after Start (want 44.1 kHz, none)",
          timeout.card.port[0].rateCode, RateCommands(timeout.card, timeoutMark, kRegXLink1TX).size());
    Finish(idle, timeout);
}

// p2-audio-refused: nothing on port 2. Choosing 64 (in Audio MIDI Setup or by
// accident in Sound settings) must leave the device exactly as it was.
static void RunAudioRefused(const Options &o, Run &r)
{
    FakeCard &c = r.card;
    c.phase("IO running at 32 channels");
    r.drv->StartDevice(1, IOUserAudioStartStopFlags::None);
    Irq(r, 1);
    const std::map<uint64_t, uint32_t> before = c.reg;
    const size_t mark = Select(r, 1, "select Port 1-2: 64ch with nothing on port 2", /*ioRunning*/true);
    // Port 2 is enabled to be looked at, found empty within the probe's
    // clock wait, and disabled again: the only writes are the enable bits.
    size_t writes = 0;
    uint64_t sleptMs = 0;
    for (size_t i = mark; i < c.lines.size(); i++) {
        unsigned long long off = 0;
        unsigned val = 0;
        if (sscanf(c.lines[i].c_str(), "W 0x%llx 0x%x", &off, &val) == 2 && off != kRegIntStatus) {
            CHECK(off == kRegGCSR2 || off == kRegXLinkClocking, "%s: a refused request wrote 0x%llx", o.name, off);
            writes++;
        }
        if (sscanf(c.lines[i].c_str(), "S %llu", &off) == 1) sleptMs += off;
    }
    CHECK(writes == 3, "%s: a refused request wrote %zu registers (want the 3 port-2 enable writes)", o.name, writes);
    CHECK(sleptMs <= 2100, "%s: looking at an empty port 2 took %llu ms", o.name, (unsigned long long)sleptMs);
    CHECK(c.reg == before, "%s: a refused request changed the card's registers", o.name);
    CHECK(c.port[1].commandsSeen == 0, "%s: a refused request sent commands on port 2", o.name);
    CheckPort1Alone("after the refusal", r);
    CheckPublished("after the refusal", 32);
    Port2State s = ReadPort2(r);
    CHECK((s.w[14] & kSymphonyPort2AudioRefused) && AudioReason(s) == kSymphonyPort2ReasonNoUnit &&
          (s.w[14] >> 16) == 0, "%s: refusal not reported (0x%08x)", o.name, s.w[14]);
    Irq(r, 1);
    r.drv->StopDevice(1, IOUserAudioStartStopFlags::None);
}

// p2-audio-late-chain: a chain switched on at port 2 while "Port 1: 32ch" is
// selected is not looked at (the original's thread ignored a disabled bus);
// choosing 64 afterwards finds it.
static void RunAudioLateChain(const Options &o, Run &r)
{
    FakeCard &c = r.card;
    c.phase("port 2 chain powered on at 32 channels");
    const size_t mark = c.lines.size();
    Attach(c.port[1], Port::Converters);
    for (int i = 0; i < 3; i++) {
        r.drv->LinkWatchTimerOccurred(nullptr, 0);
        HostPump();
    }
    CheckAt32(o, r, mark);
    CHECK(c.port[1].commandsSeen == 0 && ReadPort2(r).w[11] == 0, "%s: the new chain was probed at 32", o.name);
    const size_t sel = Select(r, 1, "select Port 1-2: 64ch");
    CheckBothPortsRunning("after selecting 64 with the late chain", r, sel);
    CheckPublished("after selecting 64 with the late chain", 64);
    Port2State s = ReadPort2(r);
    CHECK(s.w[6] == 2 && s.w[11] == 1, "%s: late chain units %u probes %u", o.name, s.w[6], s.w[11]);
}

// p2-audio-sleep-mid-select: the Mac goes to sleep while port 2 is being looked
// at for a switch to 64, and wakes with the card's registers intact. The
// switch gives up without another write, leaving port 2 enabled; the first
// link-watch tick after the wake must disable it again, as every other way
// back to 32 does (the wake re-initialization does not run: nothing was lost).
static void RunAudioSleepMidSelect(const Options &o, Run &r)
{
    FakeCard &c = r.card;
    SymphonyThunderbridge *drv = r.drv;
    c.phase("IO running at 32 channels");
    drv->StartDevice(1, IOUserAudioStartStopFlags::None);
    Irq(r, 1);
    CHECK((c.reg[kRegGCSR2] & kGCSR2_DisablePort2) != 0, "%s: port 2 not disabled at 32 to begin with", o.name);
    const uint32_t reinitsBefore = (uint32_t)c.count("W 0x000000 0x00000001");
    int sleeps = 0;
    c.onSleep = [&] {
        if (++sleeps != 2) return;            // during the probe's clock wait
        c.onSleep = nullptr;
        c.phase("power-down arrives while port 2 is looked at");
        drv->SetPowerState(kIOServicePowerCapabilityOff);
    };
    const size_t mark = Select(r, 1, "select Port 1-2: 64ch, sleep begins during the probe", /*ioRunning*/true);
    CHECK(c.onSleep == nullptr, "%s: the power-down never arrived (the probe did not wait)", o.name);
    CHECK((c.reg[kRegGCSR2] & kGCSR2_DisablePort2) == 0,
          "%s: the abandoned switch disabled port 2 itself (it must write nothing after a power-down began)", o.name);
    CHECK(CountAccess(c, mark, 'W', kRegA2H2HBA) == 0 && (c.reg[kRegGCSR2] & kGCSR2_DMAEnableMask) == 0,
          "%s: port 2 was programmed although the switch was abandoned", o.name);
    {
        Port2State s = ReadPort2(r);
        CHECK((s.w[14] & kSymphonyPort2AudioRefused) && AudioReason(s) == kSymphonyPort2ReasonUnreachable,
              "%s: abandoned switch not reported (0x%08x)", o.name, s.w[14]);
    }
    CheckPublished("after the abandoned switch", 32);

    c.phase("wake with the card intact");
    const size_t wake = c.lines.size();
    uint32_t wakeState[16] = {};
    drv->ReadLinkState(wakeState);
    CHECK(wakeState[1] != 1, "%s: sleeping link reported up", o.name);
    drv->SetPowerState(kIOServicePowerCapabilityOn);
    drv->ReadLinkState(wakeState);
    CHECK(wakeState[1] != 1, "%s: wake reported up before link revalidation", o.name);
    drv->LinkWatchTimerOccurred(nullptr, 0);
    HostPump();
    drv->ReadLinkState(wakeState);
    CHECK(wakeState[1] == 1, "%s: validated clean wake did not report up", o.name);
    CHECK((c.reg[kRegGCSR2] & kGCSR2_DisablePort2) != 0,
          "%s: port 2 still enabled at 32 channels after the wake (GCSR2=0x%08x)", o.name, c.reg[kRegGCSR2]);
    CHECK((c.reg[kRegGCSR2] & kGCSR2_DisablePort1) == 0, "%s: port 1 disabled by the clean-up", o.name);
    CHECK(c.count("W 0x000000 0x00000001") == reinitsBefore, "%s: the card was re-initialized on a wake that kept its registers", o.name);
    CHECK(c.port[1].commandsSeen == 0, "%s: commands were sent on port 2", o.name);
    // Once: later ticks at 32 write nothing to GCSR2.
    const size_t after = c.lines.size();
    for (int i = 0; i < 2; i++) { drv->LinkWatchTimerOccurred(nullptr, 0); HostPump(); }
    CHECK(CountAccess(c, after, 'W', kRegGCSR2) == 0, "%s: the link watch keeps writing GCSR2 at 32 channels", o.name);
    CHECK(CountAccess(c, wake, 'W', kRegGCSR2) == 1, "%s: %zu GCSR2 writes after the wake (want the one disable)",
          o.name, CountAccess(c, wake, 'W', kRegGCSR2));
    CheckPort1Alone("after the wake", r);
    Irq(r, 1);
    drv->StopDevice(1, IOUserAudioStartStopFlags::None);
}

// p2-audio-phase: the original's phase alignment, converters on both ports.
static void RunAudioPhase(const Options &o, Run &r)
{
    FakeCard &c = r.card;
    auto setPhases = [&](uint8_t a, uint8_t b, uint8_t x, uint8_t y) {
        c.port[0].units[0].phase = a; c.port[0].units[1].phase = b;
        c.port[1].units[0].phase = x; c.port[1].units[1].phase = y;
    };
    auto cycle = [&](const char *name, uint32_t wantJam, bool wantWritten, uint32_t wantUnits) {
        const size_t mark = Select(r, 1, name);
        Port2State s = ReadPort2(r);
        const size_t jams = CountAccess(c, mark, 'W', kRegJam);
        if (wantWritten) {
            CHECK(jams == 1 && FindWrite(c, mark, kRegJam, wantJam) != SIZE_MAX, "%s: jam 0x%02x not written exactly once (%zu writes)", name, wantJam, jams);
            CHECK((s.w[14] & kSymphonyPort2AudioPhaseAligned) && !(s.w[14] & kSymphonyPort2AudioPhaseFailed),
                  "%s: alignment not reported (0x%08x)", name, s.w[14]);
            CHECK((s.w[15] & 0xFF) == wantJam, "%s: phase word 0x%08x", name, s.w[15]);
        } else {
            CHECK(jams == 0, "%s: jam written although the alignment failed", name);
            CHECK(!(s.w[14] & kSymphonyPort2AudioPhaseAligned) && (s.w[14] & kSymphonyPort2AudioPhaseFailed),
                  "%s: failed alignment not reported (0x%08x)", name, s.w[14]);
        }
        CHECK(((s.w[15] >> 8) & 0xFF) == wantUnits, "%s: %u units measured (want %u)", name, (s.w[15] >> 8) & 0xFF, wantUnits);
        // A failed alignment does not stop the switch (difference from the original).
        CheckBothPortsRunning(name, r, mark);
        // The jam is written while the card is muted and both engines are off.
        const size_t jamAt = FindWrite(c, mark, kRegJam, wantJam);
        if (wantWritten && jamAt != SIZE_MAX) {
            size_t firstEnable = SIZE_MAX;
            for (size_t i = mark; i < c.lines.size() && firstEnable == SIZE_MAX; i++) {
                unsigned long long off = 0;
                unsigned val = 0;
                if (sscanf(c.lines[i].c_str(), "W 0x%llx 0x%x", &off, &val) == 2 && off == kRegGCSR2 &&
                    (val & (kGCSR2_A2HDMAEnable | kGCSR2_H2ADMAEnable)))
                    firstEnable = i;
            }
            CHECK(jamAt < firstEnable, "%s: jam written after the engines were started", name);
        }
        Select(r, 0, "back to 32");
        return mark;
    };

    // Port 1 first, then port 2; the base moves when a unit is more than 0x30 away.
    setPhases(0x10, 0x12, 0x50, 0x52);
    size_t mark = cycle("phases 10 12 | 50 52", 0x4B, true, 4);
    CHECK(Commands(c, mark, kRegXLink1TX, 0x09) == std::vector<uint32_t>({ 0x0100, 0x0200 }) &&
          Commands(c, mark, kRegXLink2TX, 0x09) == std::vector<uint32_t>({ 0x0100, 0x0200 }),
          "%s: phase not asked of each converter on each port", o.name);
    {
        // Port 1's two queries come before port 2's.
        size_t first2 = SIZE_MAX, last1 = 0;
        for (size_t i = mark; i < c.lines.size(); i++) {
            unsigned long long off = 0;
            unsigned val = 0;
            if (sscanf(c.lines[i].c_str(), "W 0x%llx 0x%x", &off, &val) != 2 || ((val >> 9) & 0xFF) != 0x09) continue;
            if (off == kRegXLink1TX) last1 = i;
            if (off == kRegXLink2TX && first2 == SIZE_MAX) first2 = i;
        }
        CHECK(last1 < first2, "%s: port 2 asked its phase before port 1", o.name);
    }
    // All within the window of the first: the first unit's phase decides.
    setPhases(0x20, 0x30, 0x40, 0x50);
    cycle("phases 20 30 | 40 50", 0x1B, true, 4);
    // A unit at phase 0 and a result of "no adjustment" (0xFF): the original wrote 0.
    setPhases(0x00, 0x40, 0x04, 0x06);
    cycle("phases 00 40 | 04 06", 0x00, true, 4);
    // Wrap-around: 0xF0 then 0x05 is 0x15 away, inside the window.
    setPhases(0xF0, 0x05, 0xF8, 0x10);
    cycle("phases F0 05 | F8 10", 0xEB, true, 4);
    // A port-2 unit does not answer: nothing is written, the switch still happens.
    setPhases(0x10, 0x12, 0x50, 0x52);
    c.port[1].units[1].answersPhase = false;
    cycle("port 2 unit 2 does not answer", 0, false, 3);
    c.port[1].units[1].answersPhase = true;
    // A jam is still in progress: not written.
    c.jamBusy = true;
    cycle("jam busy", 0, false, 4);
    c.jamBusy = false;
    // A 32-channel (Symphony-type) unit on port 2 is not asked; port 1's are.
    c.phase("port 2 re-identified as one 32-channel unit");
    {
        Port fresh;
        fresh.kind = Port::Converters;
        fresh.units.push_back({ 0xF0, 0xF0 });
        fresh.units[0].phase = 0x77;
        c.port[1] = Port();                      // clock gone...
        r.drv->LinkWatchTimerOccurred(nullptr, 0);
        HostPump();
        c.port[1] = fresh;                       // ...and back as a different unit
        r.drv->LinkWatchTimerOccurred(nullptr, 0);
        HostPump();
    }
    c.port[0].units[0].phase = 0x33;
    c.port[0].units[1].phase = 0x35;
    mark = cycle("port 2 is a 32-channel unit", 0x2E, true, 2);
    CHECK(Commands(c, mark, kRegXLink2TX, 0x09).empty(), "%s: a 32-channel unit on port 2 was asked its phase", o.name);
}

// p2-audio-switch: 32 <-> 64 with rate changes in between.
static void RunAudioSwitch(const Options &o, Run &r)
{
    FakeCard &c = r.card;
    SymphonyThunderbridge *drv = r.drv;
    auto rateChange = [&](const char *phase, double rate) {
        c.phase(phase);
        const size_t mark = c.lines.size();
        gHostAudio.device->SetSampleRate(rate);
        kern_return_t rc = drv->StartDevice(1, IOUserAudioStartStopFlags::None);
        Irq(r, 1);
        drv->StopDevice(1, IOUserAudioStartStopFlags::None);
        HostPump();
        return std::make_pair(rc, mark);
    };

    // A rate change at 32, then switch: port 2 is enabled at the new rate.
    { auto [rc, mark] = rateChange("rate change to 96000 at 32 channels", 96000.0);
      (void)mark; CHECK(rc == kIOReturnSuccess, "%s: rate change at 32 failed", o.name);
      CheckPort1Alone("rate change at 32", r); }
    size_t mark = Select(r, 1, "select 64 at 96000");
    CheckBothPortsRunning("64 at 96000", r, mark);
    CheckPublished("64 at 96000", 64);
    CHECK(gHostAudio.inStream->current.mSampleRate == 96000.0 && gHostAudio.inStream->current.mBytesPerFrame == 256,
          "%s: 64-channel format is %.0f Hz, %u bytes per frame", o.name,
          gHostAudio.inStream->current.mSampleRate, gHostAudio.inStream->current.mBytesPerFrame);

    const uint32_t requestsAt64 = gHostAudio.configChangeRequests;
    // Rate changes at 64: both engines stop and restart, port 2 first; the
    // phase is aligned again; both ports end at the new rate.
    for (double rate : { 192000.0, 44100.0 }) {
        char name[64];
        snprintf(name, sizeof(name), "rate change to %.0f at 64 channels", rate);
        auto [rc, m] = rateChange(name, rate);
        CHECK(rc == kIOReturnSuccess, "%s: %s returned 0x%x", o.name, name, rc);
        CHECK(c.port[0].rateCode == RateCode(rate) && c.port[1].rateCode == RateCode(rate), "%s: %s: ports at 0x%02x / 0x%02x",
              o.name, name, c.port[0].rateCode, c.port[1].rateCode);
        CheckBothPortsRunning(name, r, m);
        CHECK(CountAccess(c, m, 'W', kRegJam) == 1, "%s: %s: phase not aligned once", o.name, name);
        // Port 2's engine was stopped before any rate command went out.
        size_t stop2 = SIZE_MAX;
        for (size_t i = m; i < c.lines.size() && stop2 == SIZE_MAX; i++) {
            unsigned long long off = 0;
            unsigned val = 0;
            if (sscanf(c.lines[i].c_str(), "W 0x%llx 0x%x", &off, &val) == 2 && off == kRegGCSR2 &&
                (val & kGCSR2_DMAEnableMask) == 0)
                stop2 = i;
        }
        CHECK(stop2 < FirstRateCommand(c, m, kRegXLink2TX) && stop2 < FirstRateCommand(c, m, kRegXLink1TX),
              "%s: %s: port 2 DMA not stopped before the rate commands", o.name, name);
        CheckPublished(name, 64);
        CHECK(gHostAudio.configChangeRequests == requestsAt64, "%s: %s asked for a configuration change", o.name, name);
    }
    CheckIOHandler("64 channels after rate changes", 64);

    // Port 1 fails a rate change at 64: everything stays stopped and muted, as
    // with one port; the retry brings both ports back.
    c.port[0].ignoreRate = true;
    { auto [rc, m] = rateChange("rate change to 88200 at 64, port 1 does not follow", 88200.0);
      (void)m; CHECK(rc == kIOReturnIOError, "%s: failed rate change at 64 returned 0x%x", o.name, rc);
      CHECK((c.reg[kRegGCSR] & (kGCSR_A2HDMAEnable | kGCSR_H2ADMAEnable)) == 0 && (c.reg[kRegGCSR2] & kGCSR2_DMAEnableMask) == 0,
            "%s: an engine is running after a failed rate change", o.name);
      CHECK((c.reg[kRegClkCtrl] & 0x70000000u) == 0, "%s: unmuted after a failed rate change", o.name); }
    // While it is in that state, switching to 32 must not start port 1 either.
    mark = Select(r, 0, "select 32 while stopped after the failed rate change");
    CHECK((c.reg[kRegGCSR] & (kGCSR_A2HDMAEnable | kGCSR_H2ADMAEnable)) == 0 && (c.reg[kRegClkCtrl] & 0x70000000u) == 0,
          "%s: switching to 32 restarted a card that was stopped for a failed rate change", o.name);
    CheckPort1Alone("32 selected while stopped", r, /*expectRunning*/false);
    CheckPublished("32 selected while stopped", 32);
    // ...and 64 is refused until the rate change has been retried.
    mark = Select(r, 1, "select 64 while stopped after the failed rate change");
    CheckPublished("64 refused while stopped", 32);
    { Port2State s = ReadPort2(r);
      CHECK((s.w[14] & kSymphonyPort2AudioRefused) && AudioReason(s) == kSymphonyPort2ReasonUnreachable,
            "%s: refusal while stopped not reported (0x%08x)", o.name, s.w[14]);
      CHECK((c.reg[kRegGCSR] & (kGCSR_A2HDMAEnable | kGCSR_H2ADMAEnable)) == 0, "%s: refused enable started port 1", o.name); }
    c.port[0].ignoreRate = false;
    { auto [rc, m] = rateChange("rate change to 88200 retried", 88200.0);
      (void)m; CHECK(rc == kIOReturnSuccess, "%s: retried rate change failed 0x%x", o.name, rc);
      CheckPort1Alone("after the retried rate change", r); }
    mark = Select(r, 1, "select 64 at 88200");
    CheckBothPortsRunning("64 at 88200", r, mark);

    // Port 2 does not follow a rate change at 64: port 1 changes and carries
    // on alone, the streams go back to 32 channels.
    c.port[1].ignoreRate = true;
    {
        const uint32_t before = gHostAudio.configChangeRequests;
        auto [rc, m] = rateChange("rate change to 48000 at 64, port 2 does not follow", 48000.0);
        (void)m;
        c.port[1].ignoreRate = false;
        CHECK(rc == kIOReturnSuccess, "%s: port 2 not following failed the device rate change (0x%x)", o.name, rc);
        CHECK(c.port[0].rateCode == 0x00, "%s: port 1 not at 48000", o.name);
        CheckPort1Alone("port 2 did not follow the rate", r);
        CHECK(gHostAudio.configChangeRequests == before + 1 && gHostAudio.lastConfigChangeAction == 0x504F5254ull,
              "%s: no configuration change asked for after the fallback", o.name);
        Port2State s = ReadPort2(r);
        CHECK((s.w[14] & kSymphonyPort2AudioFellBack) && AudioReason(s) == kSymphonyPort2ReasonRateChange,
              "%s: fallback not reported (0x%08x)", o.name, s.w[14]);
        // Until Core Audio performs the change the streams are still 64 wide
        // and the handler must keep working. The remembered 64 request retries
        // when the card is able to bring port 2 back.
        CheckIOHandler("64-channel streams while the card is at 32", 64);
        c.phase("configuration change after the fallback");
        const size_t retryMark = c.lines.size();
        HostPerformConfigChange(r, false);
        CheckPublished("after the automatic retry", 64);
        CheckBothPortsRunning("64 after the automatic retry", r, retryMark);
    }

    // A fallback's configuration change is still pending when the user asks
    // for 64 again: the request must not be lost to the fallback's bookkeeping.
    mark = Select(r, 1, "select 64 at 48000 (first)");
    CheckBothPortsRunning("64 at 48000 (first)", r, c.lines.size());
    c.port[1].ignoreRate = true;
    { auto [rc, m] = rateChange("rate change to 96000 at 64, port 2 does not follow (again)", 96000.0);
      (void)m; (void)rc; }
    c.port[1].ignoreRate = false;
    CheckPort1Alone("second rate fallback", r);
    {
        c.phase("select 64 before the fallback's configuration change is performed");
        gHostAudio.portSources[1]->selected = 1;
        CHECK(drv->RequestPortMode(1) == kIOReturnSuccess, "%s: request during a pending fallback refused", o.name);
        HostPump();
        const size_t m = c.lines.size();
        HostPerformConfigChange(r, false);
        CheckBothPortsRunning("64 requested during a pending fallback", r, m);
        CheckPublished("64 requested during a pending fallback", 64);
        CHECK(c.port[1].rateCode == 0x01, "%s: port 2 not brought to 96000", o.name);
        // The second (now redundant) configuration change changes nothing.
        const size_t m2 = c.lines.size();
        HostPerformConfigChange(r, false);
        CHECK(CountAccess(c, m2, 'W', kRegGCSR) == 0 && CountAccess(c, m2, 'W', kRegGCSR2) == 0,
              "%s: a redundant configuration change touched the DMA engines", o.name);
        CheckPublished("after the redundant configuration change", 64);
    }
    { auto [rc, m] = rateChange("rate change to 48000 at 64", 48000.0);
      CHECK(rc == kIOReturnSuccess, "%s: rate change back to 48000 failed", o.name);
      CheckBothPortsRunning("64 at 48000 after the rate change", r, m); }

    // Sleep with an FPGA reset while 64 is running: back at 32 afterwards.
    c.phase("sleep at 64, wake with the FPGA reset");
    drv->SetPowerState(kIOServicePowerCapabilityOff);
    c.powerCycleFPGA();
    drv->SetPowerState(kIOServicePowerCapabilityOn);
    drv->LinkWatchTimerOccurred(nullptr, 0);
    HostPump();
    drv->LinkWatchTimerOccurred(nullptr, 0);
    HostPump();
    {
        Port2State s = ReadPort2(r);
        CHECK(!(s.w[14] & kAudioActive) && (s.w[14] & kSymphonyPort2AudioFellBack) && AudioReason(s) == kSymphonyPort2ReasonCardReset,
              "%s: card reset at 64 not reported (0x%08x)", o.name, s.w[14]);
        CHECK((c.reg[kRegGCSR2] & kGCSR2_DMAEnableMask) == 0 && c.reg[kRegA2H2HBA] == 0, "%s: port 2 programmed after the card reset", o.name);
        CHECK((c.reg[kRegGCSR] & (kGCSR_A2HDMAEnable | kGCSR_H2ADMAEnable)) != 0, "%s: port 1 not running after the card reset", o.name);
        HostPerformConfigChange(r, false);
        CheckPublished("after the card reset automatic retry", 64);
    }
    mark = Select(r, 1, "select 64 after the card reset");
    CheckBothPortsRunning("64 after the card reset", r, c.lines.size());
    CheckPublished("64 after the card reset", 64);
    // Stop runs with both ports on (Finish).
}

// p2-audio-port2-vanishes: the port-2 chain goes away in mid-stream.
static void RunAudioPort2Vanishes(const Options &o, Run &r)
{
    FakeCard &c = r.card;
    SymphonyThunderbridge *drv = r.drv;
    size_t mark = Select(r, 1, "select Port 1-2: 64ch");
    CheckBothPortsRunning("before port 2 goes", r, mark);
    c.phase("IO running at 64 channels");
    CHECK(drv->StartDevice(1, IOUserAudioStartStopFlags::None) == kIOReturnSuccess, "%s: StartDevice failed", o.name);
    Irq(r, 1);
    Irq(r, 1);

    CheckIOHandler("64 channels before port 2 goes", 64);   // leaves audio in port 2's buffers
    c.phase("port 2 chain switched off in mid-stream");
    const Port saved = c.port[1];
    c.port[1] = Port();
    Irq(r, 1);                                   // port 1's interrupts keep coming
    const uint32_t before = gHostAudio.configChangeRequests;
    mark = c.lines.size();
    drv->LinkWatchTimerOccurred(nullptr, 0);     // the watch notices within its 2 s interval
    CHECK((c.reg[kRegGCSR] & (kGCSR_ClockOKFlash | kGCSR_ClockOKSolid)) == kGCSR_ClockOKFlash,
          "%s: port-2 clock fault did not flash the GCSR LED (GCSR=0x%08x)", o.name, c.reg[kRegGCSR]);
    CHECK(c.reg[kRegPort1GreenCtl] == 0x000FFF0F && c.reg[kRegPort1RedCtl] == 0xFFF0000F && c.reg[kRegPort1BlueCtl] == 0,
          "%s: port-2 clock fault did not write the RGB red/green flash (R=0x%08x G=0x%08x)", o.name, c.reg[kRegPort1RedCtl], c.reg[kRegPort1GreenCtl]);
    CheckPort1Alone("after the watch saw port 2 go", r);
    CHECK(CountAccess(c, mark, 'W', kRegXLink2TX) == 0, "%s: commands sent to a port with no clock", o.name);
    CHECK(CountAccess(c, mark, 'W', kRegXLink1TX) == 0, "%s: the fallback sent commands on port 1", o.name);
    {
        uint64_t ms = 0;
        for (size_t i = mark; i < c.lines.size(); i++) {
            unsigned long long v = 0;
            if (sscanf(c.lines[i].c_str(), "S %llu", &v) == 1) ms += v;
        }
        CHECK(ms <= 150, "%s: the fallback kept the XLink queue for %llu ms", o.name, (unsigned long long)ms);
    }
    {
        // Port 2's capture and playback buffers were silenced, so the 64-wide
        // IO that continues until the configuration change replays nothing.
        const unsigned char *a2h2 = (const unsigned char *)gHostAudio.buffers[5]->mem_;
        const unsigned char *h2a2 = (const unsigned char *)gHostAudio.buffers[6]->mem_;
        size_t nonzero = 0;
        for (size_t i = 0; i < kDMABufferSize; i++) nonzero += (a2h2[i] != 0) + (h2a2[i] != 0);
        CHECK(nonzero == 0, "%s: %zu stale bytes left in port 2's buffers after the fallback", o.name, nonzero);
    }
    Port2State s = ReadPort2(r);
    CHECK((s.w[14] & kSymphonyPort2AudioFellBack) && AudioReason(s) == kSymphonyPort2ReasonClockGone && s.w[6] == 0,
          "%s: fallback not reported (audio 0x%08x, units %u)", o.name, s.w[14], s.w[6]);
    // Core Audio has not performed the change yet: IO still runs 64-wide.
    CheckIOHandler("64-channel streams while the card is at 32", 64);
    Irq(r, 1);
    HostPump();
    CHECK(gHostAudio.configChangeRequests == before + 1 && gHostAudio.lastConfigChangeAction == 0x504F5254ull,
          "%s: no configuration change asked for (%u requests)", o.name, gHostAudio.configChangeRequests - before);
    c.phase("configuration change after the fallback");
    CHECK(HostPerformConfigChange(r, true) == kIOReturnSuccess, "%s: IO did not restart after the fallback", o.name);
    CheckPublished("after the fallback", 32);
    CheckPort1Alone("after the configuration change", r);
    CheckIOHandler("32 channels after the fallback", 32);

    // Port 1 is not wedged: interrupts, a rate change, the link watch.
    c.phase("port 1 carries on");
    Irq(r, 1);
    drv->StopDevice(1, IOUserAudioStartStopFlags::None);
    gHostAudio.device->SetSampleRate(96000.0);
    CHECK(drv->StartDevice(1, IOUserAudioStartStopFlags::None) == kIOReturnSuccess, "%s: port-1 rate change failed after the fallback", o.name);
    Irq(r, 1);
    CHECK(c.port[0].rateCode == 0x01, "%s: port 1 not at 96000", o.name);
    drv->LinkWatchTimerOccurred(nullptr, 0);
    HostPump();
    CheckPort1Alone("after a rate change with port 2 gone", r);
    // Asking for 64 now is refused without touching the card.
    mark = Select(r, 1, "select 64 with port 2 gone", /*ioRunning*/true);
    CheckPublished("64 refused with port 2 gone", 32);
    s = ReadPort2(r);
    CHECK((s.w[14] & kSymphonyPort2AudioRefused) && AudioReason(s) == kSymphonyPort2ReasonNoUnit, "%s: refusal not reported", o.name);
    drv->StopDevice(1, IOUserAudioStartStopFlags::None);

    // The chain comes back: found by the watch, and 64 can be selected again.
    c.phase("port 2 chain switched on again");
    c.port[1] = saved;
    for (auto &u : c.port[1].units) { u.addr = 0; u.passing = false; }
    const uint32_t requestsBeforeReturn = gHostAudio.configChangeRequests;
    drv->LinkWatchTimerOccurred(nullptr, 0);
    HostPump();
    CHECK(gHostAudio.configChangeRequests == requestsBeforeReturn + 1,
          "%s: a returned port-2 unit did not request the remembered 64-channel configuration", o.name);
    mark = c.lines.size();
    CHECK(HostPerformConfigChange(r, false) == kIOReturnSuccess,
          "%s: automatic 64-channel retry after port-2 return failed", o.name);
    CheckBothPortsRunning("after port 2 came back automatically", r, mark);
    CheckPublished("after port 2 came back automatically", 64);
    CHECK(c.port[1].rateCode == 0x01, "%s: port 2 not brought to 96000", o.name);

    // Gone again with IO stopped, and the cable pulled before Stop.
    c.phase("port 2 goes again, IO stopped");
    c.port[1] = Port();
    drv->LinkWatchTimerOccurred(nullptr, 0);
    HostPump();
    CheckPort1Alone("second fallback", r);
    HostPerformConfigChange(r, false);
    CheckPublished("second fallback", 32);
}
#endif   // TRACE_HAVE_PORT2_AUDIO

static std::vector<Options> TwoPortScenarios()
{
    std::vector<Options> v;
    { Options o; o.name = "p2-symphony-plus-converters"; o.port2 = Port::Converters; o.portCountProperty = 2;
      o.dirtyRegisters = true; v.push_back(o); }
#ifdef TRACE_HAVE_UNITB_MIXER
    { Options o; o.name = "p2-symphony-plus-symphony"; o.port2 = Port::Symphony; o.portCountProperty = 2;
      o.shortFlow = true; v.push_back(o); }
#endif
    { Options o; o.name = "p2-port2-empty"; o.portCountProperty = 2; o.shortFlow = true; v.push_back(o); }
    { Options o; o.name = "p2-converters-both-ports"; o.port1 = Port::Converters; o.port2 = Port::Converters;
      o.portCountProperty = 2; v.push_back(o); }
    { Options o; o.name = "p2-port2-powered-on-late"; o.port2 = Port::Converters; o.latePort2 = true;
      o.portCountProperty = 2; o.shortFlow = true; v.push_back(o); }
    { Options o; o.name = "p2-port1-empty"; o.port1 = Port::Empty; o.port2 = Port::Converters;
      o.portCountProperty = 2; v.push_back(o); }
    return v;
}
#endif

// Defined in the driver source: what SymphonyAudioDevice::HandleChangeSampleRate
// calls once Core Audio has accepted a nominal rate.
void SymphonyNoteNominalSampleRate(IOUserAudioDevice *device, double rate);

// The last name published for one host channel since `from`, "" if none.
static std::string LastElementName(const FakeCard &c, size_t from, const char *dir, unsigned ch)
{
    char key[64];
    snprintf(key, sizeof(key), "element-name dir=%s ch=%u name=", dir, ch);
    std::string found;
    for (size_t i = from; i < c.lines.size(); i++) {
        const size_t at = c.lines[i].find(key);
        if (at != std::string::npos) found = c.lines[i].substr(at + strlen(key));
    }
    return found;
}

// Channel names follow Core Audio's nominal rate, not only a stream start's
// rate change. Seen on hardware after a replug: coreaudiod restored the saved
// 176.4 kHz, a stream start ran there (every optical channel "N.A."), then the
// nominal rate became 48 kHz with no stream start and nothing renamed them.
// The fake card has an Optical card in slot 2 and an 8MicPre (no outputs) in
// slot 1: analog first (dext 150), host output 9 is its first optical output
// (host output 25 while the outputs went by position, up to dext 149).
static void RunNominalRateNames()
{
    const char *name = "nominal-rate-names";
    Options o; o.name = name; o.shortFlow = true;
    Run r;
    RunScenario(o, r);
    FakeCard &card = r.card;
    SymphonyThunderbridge *drv = r.drv;
    CHECK(r.startResult == kIOReturnSuccess && gHostAudio.device, "%s: Start failed", name);
    if (r.startResult != kIOReturnSuccess || !gHostAudio.device) { Finish(o, r); return; }

    card.phase("stream start at the restored 176.4 kHz");
    drv->StopDevice(1, IOUserAudioStartStopFlags::None);
    gHostAudio.device->SetSampleRate(176400.0);
    CHECK(drv->StartDevice(1, IOUserAudioStartStopFlags::None) == kIOReturnSuccess, "%s: StartDevice at 176.4k failed", name);
    HostPump();
    CHECK(LastElementName(card, 0, "out", 9) == "A N.A.", "%s: output 9 at 176.4k is \"%s\"", name,
          LastElementName(card, 0, "out", 9).c_str());
    drv->StopDevice(1, IOUserAudioStartStopFlags::None);
    HostPump();

    card.phase("nominal rate 48 kHz, no stream start");
    size_t mark = card.lines.size();
    gHostAudio.device->SetSampleRate(48000.0);
    SymphonyNoteNominalSampleRate(gHostAudio.device, 48000.0);
    HostPump();
    CHECK(LastElementName(card, mark, "out", 9) == "A ADAT 1", "%s: output 9 after 48k nominal is \"%s\"", name,
          LastElementName(card, mark, "out", 9).c_str());

    card.phase("the same nominal rate again renames nothing");
    mark = card.lines.size();
    SymphonyNoteNominalSampleRate(gHostAudio.device, 48000.0);
    HostPump();
    CHECK(LastElementName(card, mark, "out", 9).empty(), "%s: repeated nominal rate renamed output 9", name);

    // After Stop the hook is gone: a late rate change touches nothing.
    card.phase("Stop");
    IOUserAudioDevice *dev = gHostAudio.device;
    dev->retain();
    drv->Stop(r.pci);
    HostPump();
    mark = card.lines.size();
    SymphonyNoteNominalSampleRate(dev, 176400.0);
    HostPump();
    CHECK(card.lines.size() == mark, "%s: nominal rate after Stop reached the driver", name);
    dev->release();
    drv->release();
    r.pci->release();
    gHostBackend = nullptr;
}

#ifdef TRACE_HAVE_CONVERTER_PARITY
// ── dext 131: converters as the original ran them ───────────────────────────
static SymphonyConverterStateOutput ConvState(Run &r)
{
    SymphonyConverterStateOutput o = {};
    r.drv->ReadConverterState(reinterpret_cast<uint32_t *>(&o));
    return o;
}
static Unit U(uint8_t inquire, uint8_t xtd = 0) { Unit u; u.inquire = inquire; u.xtd = xtd; return u; }
// The first line after which the driver treats port 1 as converters: unit 1's
// AUTH_START, sent once every Symphony I/O read of the bring-up has gone
// unanswered (those reads are how a converter is told apart from a Symphony
// I/O that lost one read; units 2-4 are authenticated earlier, during discovery).
static std::string VendorMessagePhase(const FakeCard &c, size_t from)
{
    for (size_t i = from; i < c.lines.size(); i++) {
        unsigned long long off = 0; unsigned val = 0;
        if (sscanf(c.lines[i].c_str(), "W 0x%llx 0x%x", &off, &val) == 2 && off == kRegXLink1TX && ((val >> 9) & 0xFF) == 0x10) {
            for (size_t j = i; j-- > 0;) if (c.lines[j].rfind("-- ", 0) == 0) return c.lines[j];
            return "(start)";
        }
    }
    return "";
}
static size_t AfterIdentification(const FakeCard &c)
{
    for (size_t i = 0; i < c.lines.size(); i++) {
        unsigned long long off = 0; unsigned val = 0;
        if (sscanf(c.lines[i].c_str(), "W 0x%llx 0x%x", &off, &val) == 2 && off == kRegXLink1TX &&
            ((val >> 9) & 0xFF) == 0x06 && ((val >> 17) & 0x3F) == 1)
            return i;
    }
    return c.lines.size();
}

static void RunConverterParityChecks()
{
    // 1. Four units on port 1 (AD, AD, DA, DA): every unit found, addressed,
    //    authenticated; no Symphony I/O vendor message; per-unit unmute; the
    //    routing layer's placement; AD latency; DAW names.
    {
        Options o; o.name = "converters: AD,AD,DA,DA on port 1"; o.port1 = Port::Converters; o.shortFlow = true;
        o.port1Units = { U(0x37, 0x02), U(0x37, 0x02), U(0xC7, 0x02), U(0xC7, 0x02) };
        Run r;
        RunScenario(o, r);
        FakeCard &c = r.card;
        const SymphonyConverterStateOutput st = ConvState(r);
        CHECK(st.flags & kSymphonyConvPort1Converters, "%s: port 1 not identified as converters (flags 0x%x)", o.name, st.flags);
        CHECK(st.unitCount[0] == 4, "%s: %u units (want 4)", o.name, st.unitCount[0]);
        for (uint32_t u = 0; u < 4; u++) {
            const uint32_t w = st.unit[0][u];
            CHECK((w & kSymphonyConvUnitAddressed) && (w & kSymphonyConvUnitAuthRan) && (w & kSymphonyConvUnitAuthOK),
                  "%s: unit %u word 0x%08x (want addressed + authenticated)", o.name, u + 1, w);
            CHECK(c.port[0].units[u].unmutes >= 1, "%s: unit %u never unmuted by address", o.name, u + 1);
            CHECK(c.port[0].units[u].authStarts >= 1, "%s: unit %u never authenticated", o.name, u + 1);
        }
        CHECK(AfterIdentification(c) < c.lines.size(), "%s: never authenticated", o.name);
        {
            const size_t from = AfterIdentification(c);
            std::string where;
            for (size_t i = from; i < c.lines.size() && where.empty(); i++) {
                unsigned long long off = 0; unsigned val = 0;
                if (sscanf(c.lines[i].c_str(), "W 0x%llx 0x%x", &off, &val) == 2 && off == kRegXLink1TX && ((val >> 9) & 0xFF) == 0x10) {
                    for (size_t j = i; j-- > 0;) if (c.lines[j].rfind("-- ", 0) == 0) { where = c.lines[j]; break; }
                    if (where.empty()) where = "(start)";
                }
            }
            CHECK(where.empty(), "%s: a Symphony I/O vendor message went to converters (phase %s)", o.name, where.c_str());
        }
        CHECK(st.hostInputs == 32 && st.hostOutputs == 32, "%s: host %u in / %u out (want 32/32)", o.name, st.hostInputs, st.hostOutputs);
        for (uint32_t n = 0; n < 32; n++) {
            CHECK(c.reg[kRegInputRouting + n * 4] == (n | 0x100), "%s: input route %u = 0x%03x", o.name, n, c.reg[kRegInputRouting + n * 4]);
            const uint32_t wantOut = (64 + n) | 0x100;   // direct, as the original's default
            CHECK(c.reg[kRegOutputRouting + n * 4] == wantOut, "%s: output route %u = 0x%03x", o.name, n, c.reg[kRegOutputRouting + n * 4]);
        }
        CHECK(st.latencyIn == 36 && st.latencyOut == 35, "%s: latency %u/%u (want AD 36/35 at 44.1 kHz)", o.name, st.latencyIn, st.latencyOut);
        CHECK(r.card.port[0].units[3].addr == 4, "%s: unit 4 has address %u", o.name, r.card.port[0].units[3].addr);
        Finish(o, r);
    }
    // 2. A Rosetta then an AD-16X: the AD's inputs sit on slots 17-32 and
    //    reach host inputs 9-24; host 25-32 and the Rosetta's empty slots carry nothing.
    {
        Options o; o.name = "converters: Rosetta then AD"; o.port1 = Port::Converters; o.shortFlow = true;
        o.port1Units = { U(0x57, 0x02), U(0x37, 0x02) };
        Run r;
        RunScenario(o, r);
        FakeCard &c = r.card;
        CHECK(c.reg[kRegInputRouting + 7 * 4] == (7 | 0x100), "%s: host 8 <- 0x%03x", o.name, c.reg[kRegInputRouting + 7 * 4]);
        CHECK(c.reg[kRegInputRouting + 8 * 4] == (16 | 0x100), "%s: host 9 <- 0x%03x (want slot 17)", o.name, c.reg[kRegInputRouting + 8 * 4]);
        CHECK(c.reg[kRegInputRouting + 23 * 4] == (31 | 0x100), "%s: host 24 <- 0x%03x", o.name, c.reg[kRegInputRouting + 23 * 4]);
        CHECK(c.reg[kRegInputRouting + 24 * 4] == 0, "%s: host 25 routed (0x%03x)", o.name, c.reg[kRegInputRouting + 24 * 4]);
        CHECK(c.reg[kRegOutputRouting + 8 * 4] == 0, "%s: output slot 9 routed (0x%03x)", o.name, c.reg[kRegOutputRouting + 8 * 4]);
        const SymphonyConverterStateOutput st = ConvState(r);
        CHECK(st.latencyIn == 36 && st.latencyOut == 34, "%s: latency %u/%u (want Rosetta 36/34)", o.name, st.latencyIn, st.latencyOut);
        Finish(o, r);
    }
    // 3. A Symphony I/O that loses its vendor reads and answers INQUIRE 0xF:
    //    nothing converter-specific reaches it.
    {
        Options o; o.name = "converters: ambiguous Symphony gets none of it"; o.shortFlow = true;
        o.dropVendorReads = 8; o.symphonyInquire = 0xF0;
        Run r;
        RunScenario(o, r);
        FakeCard &c = r.card;
        CHECK(Commands(c, 0, kRegXLink1TX, 0x06).empty(), "%s: AUTH_START sent to a Symphony I/O", o.name);
        CHECK(Commands(c, 0, kRegXLink1TX, 0x0C).empty(), "%s: DEVICE_TYPE sent to a Symphony I/O", o.name);
        CHECK(ConvState(r).flags == 0, "%s: converter flags 0x%x on a Symphony I/O", o.name, ConvState(r).flags);
        Finish(o, r);
    }
    // 3b. The review's case: a Symphony I/O that loses its first read and
    //     answers INQUIRE like a DA-16X answers the later reads, so it is never
    //     configured as converters and gets its Symphony set-up.
    {
        Options o; o.name = "converters: Symphony losing one read stays a Symphony"; o.shortFlow = true;
        o.dropVendorReads = 1; o.symphonyInquire = 0xC0;
        Run r;
        RunScenario(o, r);
        CHECK(!(ConvState(r).flags & kSymphonyConvPort1Converters), "%s: identified as converters (flags 0x%x)",
              o.name, ConvState(r).flags);
        uint32_t link[16] = {};
        r.drv->ReadLinkState(link);
        CHECK(link[15] == 0, "%s: provisional converter probe word leaked after a Symphony read (0x%08x)",
              o.name, link[15]);
        // Never configured as converters at any point: unit 1 is never
        // authenticated (that happens only once it is taken for a converter).
        CHECK(AfterIdentification(r.card) == r.card.lines.size(), "%s: unit 1 was configured as a converter", o.name);
        Finish(o, r);
    }
    // 3c. Converters on both ports: 64 channels and back to 32, then a rate
    //     change. Port 2's units are still listed but port 2 is off; the
    //     alignment must look at port 1 only and still write the jam (the
    //     original aligned enabled ports only).
#ifdef TRACE_HAVE_PORT2_AUDIO
    {
        Options o; o.name = "converters: 64 then 32, then a rate change"; o.port1 = Port::Converters;
        o.port2 = Port::Converters; o.portCountProperty = 2; o.shortFlow = true;
        Run r;
        RunScenario(o, r);
        FakeCard &c = r.card;
        r.drv->StopDevice(1, IOUserAudioStartStopFlags::None);
        Select(r, 1, "converters: select 64");
        Select(r, 0, "converters: back to 32");
        c.phase("rate change at 32 after 64");
        const size_t mark = c.lines.size();
        gHostAudio.device->SetSampleRate(48000.0);
        CHECK(r.drv->StartDevice(1, IOUserAudioStartStopFlags::None) == kIOReturnSuccess, "%s: rate change failed", o.name);
        CHECK(CountAccess(c, mark, 'W', kRegJam) == 1, "%s: jam not written after going back to 32 (%zu writes)",
              o.name, CountAccess(c, mark, 'W', kRegJam));
        CHECK(Commands(c, mark, kRegXLink2TX, 0x09).empty(), "%s: port 2 asked its phase while off", o.name);
        Finish(o, r);
    }
#endif
    // 3d. A DD-16X (routing 0x0F with an XTD reply) after an AD-16X: still converters.
    {
        Options o; o.name = "converters: AD then DD"; o.port1 = Port::Converters; o.shortFlow = true;
        o.port1Units = { U(0x37, 0x02), U(0xF7, 0x02) };
        Run r;
        RunScenario(o, r);
        const SymphonyConverterStateOutput st = ConvState(r);
        CHECK((st.flags & kSymphonyConvPort1Converters) && st.unitCount[0] == 2, "%s: flags 0x%x units %u",
              o.name, st.flags, st.unitCount[0]);
        CHECK((st.unit[0][1] & kSymphonyConvUnitAuthOK), "%s: DD unit not authenticated (0x%08x)", o.name, st.unit[0][1]);
        Finish(o, r);
    }
    // 3e. Routing edited in Maestro (the original's routing pages): a host input
    //     from any converter input, a converter output from any source; kept
    //     across a card reset; Reset Routing goes back to the placement. A
    //     Symphony I/O card input routes are checked separately below.
    {
        Options o; o.name = "converters: routing edits"; o.port1 = Port::Converters; o.shortFlow = true;
        o.port1Units = { U(0x37, 0x02), U(0x37, 0x02), U(0xC7, 0x02), U(0xC7, 0x02) };
        Run r;
        RunScenario(o, r);
        FakeCard &c = r.card;
        { uint8_t pl[3] = { 0, 20, 1 }; CHECK(r.drv->SendVendorCommand(0xB6, 0, pl, 3) == kIOReturnSuccess, "%s: input route refused", o.name); }
        { uint8_t pl[3] = { 16, 64 + 3, 1 }; CHECK(r.drv->SendVendorCommand(0xB5, 0, pl, 3) == kIOReturnSuccess, "%s: output route refused", o.name); }
        HostPump();
        CHECK(c.reg[kRegInputRouting] == (20 | 0x100), "%s: host input 1 <- 0x%03x (want slot 21)", o.name, c.reg[kRegInputRouting]);
        CHECK(c.reg[kRegOutputRouting + 16 * 4] == (67 | 0x100), "%s: TX 17 <- 0x%03x", o.name, c.reg[kRegOutputRouting + 16 * 4]);
        c.phase("FPGA reset with routes edited");
        r.drv->SetPowerState(kIOServicePowerCapabilityOff);
        c.powerCycleFPGA();
        r.drv->SetPowerState(kIOServicePowerCapabilityOn);
        r.drv->LinkWatchTimerOccurred(nullptr, 0); HostPump();
        r.drv->LinkWatchTimerOccurred(nullptr, 0); HostPump();
        CHECK(c.reg[kRegInputRouting] == (20 | 0x100), "%s: edit lost after a card reset (0x%03x)", o.name, c.reg[kRegInputRouting]);
        CHECK(r.drv->SendVendorCommand(0xB7, 0, nullptr, 0) == kIOReturnSuccess, "%s: reset refused", o.name);
        HostPump();
        CHECK(c.reg[kRegInputRouting] == (0 | 0x100) && c.reg[kRegOutputRouting + 16 * 4] == (64 + 16 | 0x100),
              "%s: Reset Routing left 0x%03x / 0x%03x", o.name, c.reg[kRegInputRouting], c.reg[kRegOutputRouting + 16 * 4]);
        { uint8_t pl[3] = { 40, 3, 1 }; CHECK(r.drv->SendVendorCommand(0xB6, 0, pl, 3) == kIOReturnBadArgument, "%s: a port-2 entry accepted at 32 channels", o.name); }
        Finish(o, r);
    }
    // 3f. A unit that stops reporting its phase on port 1: the chain is
    //     re-initialised (the original: a command error -> ForceReconfigure).
    {
        Options o; o.name = "converters: unit stops reporting its phase"; o.port1 = Port::Converters; o.shortFlow = true;
        Run r;
        RunScenario(o, r);
        FakeCard &c = r.card;
        c.port[0].units[1].answersPhase = false;
        const size_t mark = c.lines.size();
        r.drv->LinkWatchTimerOccurred(nullptr, 0); HostPump();
        CHECK(!Commands(c, mark, kRegXLink1TX, 0x01).empty(), "%s: the chain was not re-initialised (no SET_ADDR)", o.name);
        Finish(o, r);
    }
    // 3g. The units never lock at bring-up: no per-unit UNMUTE (kept muted),
    //     and the health check re-initialises.
    {
        Options o; o.name = "converters: the rate never locks"; o.port1 = Port::Converters; o.shortFlow = true;
        Run r;
        RunScenario(o, r);
        FakeCard &c = r.card;
        c.port[0].slipReads = 1000000;   // every lock wait sees a slip from now on
        const size_t mark = c.lines.size();
        r.drv->SetConverterConfig(kSymphonyConvConfigClockExternal);   // a full re-initialisation
        HostPump();
        bool unitUnmute = false;
        for (uint32_t v : Commands(c, mark, kRegXLink1TX, 0x0A)) if ((v >> 8) != 0) unitUnmute = true;
        CHECK(!unitUnmute, "%s: units unmuted although the rate never locked", o.name);
        c.port[0].slipReads = 0;
        const size_t mark2 = c.lines.size();
        r.drv->LinkWatchTimerOccurred(nullptr, 0); HostPump();
        CHECK(!Commands(c, mark2, kRegXLink1TX, 0x01).empty(), "%s: no new attempt once the link is clean", o.name);
        Finish(o, r);
    }
#ifdef TRACE_HAVE_PORT2_AUDIO
    // 3h. A Symphony I/O on port 1, converters on port 2 at 64 channels: port
    //     2's units are health-checked too.
    {
        Options o; o.name = "converters: port 2 behind a Symphony"; o.port2 = Port::Converters;
        o.portCountProperty = 2; o.shortFlow = true;
        Run r;
        RunScenario(o, r);
        FakeCard &c = r.card;
        r.drv->StopDevice(1, IOUserAudioStartStopFlags::None);
        Select(r, 1, "converters: select 64 behind a Symphony");
        c.port[1].units[0].phase = 0x40;
        r.drv->LinkWatchTimerOccurred(nullptr, 0); HostPump();
        CHECK(ConvState(r).phaseErrors >= 1, "%s: port 2 phase not checked", o.name);
        Finish(o, r);
    }
#endif
#ifdef TRACE_HAVE_UNITB_CONFIG
    // B9: the original clock topology, independently of measured lock.
    {
        Options o; o.name = "Loop Sync topology"; o.port2 = Port::Symphony;
        o.portCountProperty = 2; o.shortFlow = true;
        Run r; RunScenario(o, r);
        auto change = [&](uint32_t config) {
#ifdef kSelectorLoopSync
            uint32_t out[6] = {};
            return r.drv->LoopSyncConfig(1, config, out);
#else
            return kIOReturnUnsupported;
#endif
        };
        // B7 (0.11.18): with one unit configured Loop Sync is unit A's output
        // only; turning it off at 32 sends unit A's clock with byte 2 = 0.
        CHECK(change(1) == kIOReturnSuccess, "Loop Sync: one unit at 32");
        r.drv->StopDevice(1, IOUserAudioStartStopFlags::None);
        Select(r, 1, "Loop Sync: select 64");
        auto clock = [&](unsigned port, std::vector<uint8_t> want) {
            return r.card.port[port].stored[(uint64_t)0x50 << 32] == want;
        };
        std::vector<unsigned> order;
        r.card.onVendorWrite = [&](unsigned p, uint8_t cmd) { if (cmd == 0x50) order.push_back(p); };
        CHECK(change(1) == kIOReturnSuccess, "Loop Sync: off rejected");
        CHECK(clock(0, {1,1,0,0}) && clock(1, {2,1,0,0}), "Loop Sync: off bytes");
        CHECK(order == std::vector<unsigned>({0,1}), "Loop Sync: off master-first order");
        order.clear();
        CHECK(change(2) == kIOReturnSuccess, "Loop Sync: master B rejected");
        CHECK(order == std::vector<unsigned>({1,0}), "Loop Sync: B master-first order");
        order.clear();
        CHECK(clock(1, {1,1,1,0}) && clock(0, {3,0,1,0}), "Loop Sync: master B bytes");
        CHECK(change(0) == kIOReturnSuccess, "Loop Sync: master A rejected");
        CHECK(clock(0, {1,1,1,0}) && clock(1, {3,0,1,0}), "Loop Sync: master A bytes");
        CHECK(order == std::vector<unsigned>({0,1}), "Loop Sync: A master-first order");
#ifdef kSelectorLoopSync
        static_assert(sizeof(SymphonyLoopSyncInput) == 16 && sizeof(SymphonyLoopSyncOutput) == 24, "Loop Sync v1 ABI");
        SymphonyLoopSyncInput input = {kSymphonyUCMagic, 1, 1, 2};
        CHECK(SymphonyLoopSyncInputValid(&input), "Loop Sync: valid v1 input refused");
        input.version = 0;
        CHECK(!SymphonyLoopSyncInputValid(&input), "Loop Sync: unknown version accepted");
        input.version = 1; input.operation = 2;
        CHECK(!SymphonyLoopSyncInputValid(&input), "Loop Sync: unknown operation accepted");
        input.operation = 1; input.config = 4;
        CHECK(!SymphonyLoopSyncInputValid(&input), "Loop Sync: unknown config accepted");
        input.config = 0; input.magic = 0;
        CHECK(!SymphonyLoopSyncInputValid(&input), "Loop Sync: bad magic accepted");
        CHECK(!SymphonyLoopSyncInputValid(nullptr), "Loop Sync: missing input accepted");
        // No BNC loop is not proof of a different role: unlocked/unknown are separate.
        r.card.port[1].stored[(uint64_t)0x51 << 32] = {0,0,0,0,0};
        uint32_t status[6] = {};
        CHECK(r.drv->LoopSyncConfig(0, 0, status) == kIOReturnSuccess && status[1] == 1 && status[3] == 1,
              "Loop Sync: configured slave incorrectly implies lock");
        r.card.port[1].stored[(uint64_t)0x51 << 32] = {255,0,0,0,0};
        CHECK(r.drv->LoopSyncConfig(0, 0, status) == kIOReturnSuccess && status[3] == 0,
              "Loop Sync: malformed lock byte accepted");
        r.card.port[1].dropVendorReads = 1;
        CHECK(r.drv->LoopSyncConfig(0, 0, status) == kIOReturnSuccess && status[3] == 0,
              "Loop Sync: failed clock read incorrectly implies lock");
        r.card.port[1].stored.erase((uint64_t)0x51 << 32);
        // Fail each write; a failed master must never be followed by a slave write.
        for (unsigned failingPort : {1u, 0u}) {
            order.clear();
            r.card.port[failingPort].txBusy = true;
            CHECK(change(2) == kIOReturnIOError, "Loop Sync: failed write accepted");
            r.card.port[failingPort].txBusy = false;
            CHECK(order == (failingPort == 1 ? std::vector<unsigned>{} : std::vector<unsigned>{1}),
                  "Loop Sync: wrong partial sequence");
            uint32_t state[6] = {};
            CHECK(r.drv->LoopSyncConfig(0, 0, state) == kIOReturnSuccess && state[1] == 0,
                  "Loop Sync: partial change reported valid");
            CHECK(change(0) == kIOReturnSuccess, "Loop Sync: retry failed");
        }
        // Disappearance between the master and slave: stop before the second write.
        order.clear();
        r.card.onVendorWrite = [&](unsigned p, uint8_t cmd) {
            if (cmd == 0x50) { order.push_back(p); r.card.endpointPresent = false; }
        };
        CHECK(change(2) != kIOReturnSuccess, "Loop Sync: endpoint loss accepted");
        CHECK(order == std::vector<unsigned>{1}, "Loop Sync: wrote after endpoint loss");
        r.card.endpointPresent = true;
        r.card.onVendorWrite = nullptr;
        CHECK(change(2) == kIOReturnSuccess, "Loop Sync: reconnect retry failed");
        // On/off does not discard the selected master; off still makes A master.
        CHECK(change(3) == kIOReturnSuccess && clock(0, {1,1,0,0}) && clock(1, {2,1,0,0}),
              "Loop Sync: off after B master");
        CHECK(change(2) == kIOReturnSuccess, "Loop Sync: re-enable B master");
        Select(r, 0, "Loop Sync: leave 64");
        CHECK(clock(0, {1,1,0,0}), "Loop Sync: A not restored on leaving 64");
        CHECK(change(1) == kIOReturnSuccess && clock(0, {1,1,0,0}),
              "Loop Sync: one unit after leaving 64 (B7: unit A's output off)");
        Select(r, 1, "Loop Sync: re-enter 64");
        CHECK(clock(1, {1,1,1,0}) && clock(0, {3,0,1,0}), "Loop Sync: lost B master on re-entry");
        gHostAudio.device->SetSampleRate(48000.0);
        CHECK(r.drv->StartDevice(1, IOUserAudioStartStopFlags::None) == kIOReturnSuccess,
              "Loop Sync: rate change with B master failed");
        CHECK(clock(1, {1,1,1,0}) && clock(0, {3,0,1,0}), "Loop Sync: rate change lost topology");
        // A missing master B takes the existing port-loss path back to A alone.
        r.card.port[1].kind = Port::Empty;
        r.drv->LinkWatchTimerOccurred(nullptr, 0); HostPump();
        // Unit B gone: back to one unit, where only unit A's output is set (B7).
        CHECK(change(0) == kIOReturnSuccess && r.card.port[1].vendorWrites.empty() == r.card.port[1].vendorWrites.empty(),
              "Loop Sync: one unit after master loss");

#endif
        r.card.onVendorWrite = nullptr;
        Finish(o, r);
    }
#ifdef kSelectorLoopSync
    for (auto kind : {Port::Converters, Port::Empty}) {
        Options o; o.name = "Loop Sync: no second Symphony"; o.port2 = kind;
        o.portCountProperty = 2; o.shortFlow = true;
        Run r; RunScenario(o, r);
        r.drv->StopDevice(1, IOUserAudioStartStopFlags::None);
        Select(r, 1, "Loop Sync: rejected topology");
        const auto a = r.card.port[0].vendorWrites.size(), b = r.card.port[1].vendorWrites.size();
        uint32_t out[6] = {};
        // B7: one Symphony I/O: only unit A's Loop Sync output changes, and
        // nothing is sent to port 2.
        CHECK(r.drv->LoopSyncConfig(1, 2, out) == kIOReturnSuccess, "Loop Sync: one unit refused");
        CHECK(r.card.port[0].vendorWrites.size() == a + 1 && b == r.card.port[1].vendorWrites.size(),
              "Loop Sync: one unit must write unit A's clock once and nothing on port 2");
        CHECK(r.card.port[0].stored[(uint64_t)0x50 << 32] == std::vector<uint8_t>({1,1,1,0}),
              "Loop Sync: one unit on gives unit A {1,1,1,0}");
        Finish(o, r);
    }
#endif
    // 3i. Two Symphony I/Os: selecting 64 configures unit B over XLink 2
    //     (Word Clock slave, routing, unlock), and nothing goes to it at 32.
    {
        Options o; o.name = "unit B: configured at 64"; o.port2 = Port::Symphony;
        o.portCountProperty = 2; o.shortFlow = true;
        Run r;
        RunScenario(o, r);
        FakeCard &c = r.card;
        CHECK(Commands(c, 0, kRegXLink2TX, 0x10).empty(), "%s: a vendor message went to unit B at 32 channels", o.name);
        SymphonyUnitBStateOutput st = {};
        r.drv->ReadUnitBState(reinterpret_cast<uint32_t *>(&st));
        CHECK(st.present == 0, "%s: unit B present at 32 channels", o.name);
        r.drv->StopDevice(1, IOUserAudioStartStopFlags::None);
        const size_t mark = c.lines.size();
        Select(r, 1, "unit B: select 64");
        CHECK(!Commands(c, mark, kRegXLink2TX, 0x10).empty(), "%s: no vendor message to unit B at 64", o.name);
        r.drv->ReadUnitBState(reinterpret_cast<uint32_t *>(&st));
        CHECK(st.present == 1 && st.clockSource == 3, "%s: unit B present=%u clock=%u (want 1, Loop Sync)",
              o.name, st.present, st.clockSource);
        // Review fixes: unit A's clock from the app (a card input) keeps its
        // Loop Sync output on; Loop Sync as unit A's source is refused.
        {
            const size_t m2 = c.lines.size();
            uint8_t board[4] = { 0x04, 0x01, 0x00, 0x02 };   // IOBoard 1 input, master
            CHECK(r.drv->SendVendorCommand(0x50, 0, board, 4) == kIOReturnSuccess, "%s: card-input clock refused", o.name);
            HostPump();
            CHECK(!Commands(c, m2, kRegXLink1TX, 0x10).empty(), "%s: the card-input clock was not sent", o.name);
            uint8_t loop[4] = { 0x03, 0x00, 0x01, 0x00 };
            CHECK(r.drv->SendVendorCommand(0x50, 0, loop, 4) == kIOReturnUnsupported, "%s: Loop Sync for unit A accepted at 64", o.name);
        }
        Select(r, 0, "unit B: back to 32");
        r.drv->ReadUnitBState(reinterpret_cast<uint32_t *>(&st));
        CHECK(st.present == 0, "%s: unit B still marked present at 32", o.name);
        // Back at 32: Loop Sync is fine for unit A again; a stray card-mixer
        // command for strip 40 is refused, never sent to unit A.
        {
            const size_t m3 = c.lines.size();
            uint8_t level = 40;
            CHECK(r.drv->SendVendorCommand(0xB0, (1u << 16) | 40u, &level, 1) == kIOReturnBadArgument,
                  "%s: mixer strip 40 accepted at 32", o.name);
            HostPump();
            CHECK(Commands(c, m3, kRegXLink1TX, 0x10).empty(), "%s: strip 40 went to unit A as a vendor message", o.name);
        }
        Finish(o, r);
    }
    // A failed mandatory read must leave unit B unconfigured, while the
    // SetPeripheralReady-style unlock/read-back is still attempted.
    {
        Options o; o.name = "unit B: failed setup still unlocks"; o.port2 = Port::Symphony;
        o.portCountProperty = 2; o.shortFlow = true; o.dropPort2VendorReads = 1;
        Run r;
        RunScenario(o, r);
        Select(r, 1, "unit B: select 64 with a failed board read");
        SymphonyUnitBStateOutput st = {};
        r.drv->ReadUnitBState(reinterpret_cast<uint32_t *>(&st));
        CHECK(st.present == 0, "%s: failed mandatory read still configured unit B", o.name);
        CHECK(st.setupFlags != 0, "%s: failed mandatory read had no setup reason", o.name);
        uint8_t inputRoute[] = {0, 32, 1};
        const size_t routeMark = r.card.lines.size();
        CHECK(r.drv->SendVendorCommand(0xB6, 0, inputRoute, sizeof(inputRoute)) == kIOReturnBadArgument,
              "B1b: unconfigured B cannot source host 1 even at 64");
        inputRoute[0] = 32; inputRoute[1] = 0;
        CHECK(r.drv->SendVendorCommand(0xB6, 0, inputRoute, sizeof(inputRoute)) == kIOReturnBadArgument,
              "B1b: unconfigured B cannot authorize host 33");
        for (size_t i = routeMark; i < r.card.lines.size(); i++)
            CHECK(r.card.lines[i].compare(0, 2, "W ") != 0, "B1b: unconfigured B route wrote hardware");
        CHECK(std::find(r.card.port[1].vendorWrites.begin(), r.card.port[1].vendorWrites.end(), 0xDD) != r.card.port[1].vendorWrites.end(),
              "%s: unlock write was not attempted", o.name);
        CHECK(std::find(r.card.port[1].vendorReads.begin(), r.card.port[1].vendorReads.end(), 0xDD) != r.card.port[1].vendorReads.end(),
              "%s: unlock read-back was not attempted", o.name);
        Finish(o, r);
    }
#ifdef kSymphonyPort2UnitTypeOK
    // Field report 6F64285E (2026-11-20): a Symphony I/O with one 16-channel
    // card on port 2 answers INQUIRE 0xF8 / XTD_INQUIRE 0x02, the banks of a
    // DD-16X. Its XLINK_DEVICE_TYPE answer makes it unit B, as in the original
    // (kSymphonyIO_XLinkDeviceType), never a converter.
    {
        Options o; o.name = "unit B: one-card Symphony I/O is not a DD-16X"; o.port2 = Port::Symphony;
        o.port2OneCard = true; o.portCountProperty = 2; o.shortFlow = true;
        Run r;
        RunScenario(o, r);
        FakeCard &c = r.card;
        r.drv->StopDevice(1, IOUserAudioStartStopFlags::None);
        const size_t mark = c.lines.size();
        Select(r, 1, "one-card unit B: select 64");
        const Port2State s = ReadPort2(r);
        CHECK((s.w[14] & kSymphonyPort2AudioActive) != 0, "%s: 64 channels not running (audio 0x%x)", o.name, s.w[14]);
        CHECK(s.w[6] == 1 && (s.w[7] & 0xFFFF) == 0x02F8 && (s.w[7] & kSymphonyPort2UnitTypeOK) &&
              (s.w[7] >> kSymphonyPort2UnitTypeShift) == 0x20,
              "%s: unit word 0x%08x (want INQUIRE 0xF8, XTD 0x02, type 0x20)", o.name, s.w[7]);
        CHECK(c.port[1].symTypeQueries >= 1, "%s: DEVICE_TYPE was not asked at the unit's address", o.name);
        SymphonyUnitBStateOutput st = {};
        r.drv->ReadUnitBState(reinterpret_cast<uint32_t *>(&st));
        CHECK(st.present == 1 && st.clockSource == 3, "%s: unit B present=%u clock=%u setup=0x%x (want 1, Loop Sync)",
              o.name, st.present, st.clockSource, st.setupFlags);
        CHECK(!Commands(c, mark, kRegXLink2TX, 0x10).empty(), "%s: no vendor message to unit B", o.name);
        SymphonyConverterStateOutput conv = {};
        r.drv->ReadConverterState(reinterpret_cast<uint32_t *>(&conv));
        CHECK((conv.flags & kSymphonyConvPort2Converters) == 0, "%s: reported as converters (flags 0x%x)", o.name, conv.flags);
        Finish(o, r);
    }
    // The same report: once found and addressed, the unit never answered the
    // broadcast address again (every later probe said "no unit", 64 channels
    // were refused and the driver went round in circles). It still answers at
    // address 1, so it must be found there: 64, back to 32, and 64 again.
    for (bool oneCard : { true, false }) {
        Options o; o.name = oneCard ? "unit B: one-card unit keeps its address" : "unit B: two-card unit keeps its address";
        o.port2 = Port::Symphony; o.port2OneCard = oneCard; o.port2HoldsAddress = true;
        o.portCountProperty = 2; o.shortFlow = true;
        Run r;
        RunScenario(o, r);
        r.drv->StopDevice(1, IOUserAudioStartStopFlags::None);
        SymphonyUnitBStateOutput st = {};
        for (int pass = 0; pass < 3; pass++) {
            Select(r, 1, "kept address: select 64");
            const Port2State s = ReadPort2(r);
            r.drv->ReadUnitBState(reinterpret_cast<uint32_t *>(&st));
            CHECK((s.w[14] & kSymphonyPort2AudioActive) != 0 && s.w[6] == 1 && st.present == 1,
                  "%s: pass %d: audio 0x%x units %u unit B present %u (word 0x%08x)", o.name, pass, s.w[14], s.w[6], st.present, s.w[7]);
            CHECK(pass == 0 || (s.w[7] & kSymphonyPort2UnitKeptAddress), "%s: pass %d: not found at its kept address (0x%08x)", o.name, pass, s.w[7]);
            Select(r, 0, "kept address: back to 32");
        }
        Finish(o, r);
    }
    // A converter chain that kept its addresses is not taken at address 1
    // (it would be found one unit short): refused, as before this change.
    {
        Options o; o.name = "unit B: converters that keep their addresses are not half-found"; o.port2 = Port::Converters;
        o.portCountProperty = 2; o.shortFlow = true;
        Run r;
        RunScenario(o, r);
        r.drv->StopDevice(1, IOUserAudioStartStopFlags::None);
        r.card.port[1].unitsHoldAddress = true;
        Select(r, 1, "kept converters: select 64");
        Port2State s = ReadPort2(r);
        CHECK((s.w[14] & kSymphonyPort2AudioActive) != 0 && s.w[6] == 2, "%s: first select: audio 0x%x units %u", o.name, s.w[14], s.w[6]);
        Select(r, 0, "kept converters: back to 32");
        Select(r, 1, "kept converters: select 64 again");
        s = ReadPort2(r);
        CHECK((s.w[14] & kSymphonyPort2AudioActive) == 0 && s.w[6] == 0, "%s: second select: audio 0x%x units %u (want refused, none)",
              o.name, s.w[14], s.w[6]);
        Finish(o, r);
    }
    // With unit B set up, unit A's ClockMode belongs to the Loop Sync logic:
    // a rate change at 64 sends unit A no ClockMode of its own (the recorded
    // bytes would switch its Loop Sync output off under unit B).
    {
        Options o; o.name = "clock: no re-send to unit A after a rate change while unit B follows it";
        o.port2 = Port::Symphony; o.portCountProperty = 2; o.shortFlow = true;
        Run r;
        RunScenario(o, r);
        r.drv->StopDevice(1, IOUserAudioStartStopFlags::None);
        r.drv->RequestClockSource(2); HostPump();
        Select(r, 1, "clock at 64: select 64");
        SymphonyUnitBStateOutput st = {};
        r.drv->ReadUnitBState(reinterpret_cast<uint32_t *>(&st));
        CHECK(st.present == 1, "%s: unit B not set up", o.name);
        r.card.port[0].clockModes.clear();
        gHostAudio.device->SetSampleRate(96000.0);
        r.drv->StartDevice(1, IOUserAudioStartStopFlags::None);
        HostPump();
        CHECK(r.card.port[0].clockModes.empty(), "%s: %zu ClockMode message(s) to unit A",
              o.name, r.card.port[0].clockModes.size());
        r.drv->StopDevice(1, IOUserAudioStartStopFlags::None);
        Finish(o, r);
    }
    // A real DD-16X (no DEVICE_TYPE answer) stays a converter.
    {
        Options o; o.name = "unit B: a DD-16X stays a converter"; o.port2 = Port::Converters;
        o.portCountProperty = 2; o.shortFlow = true;
        o.port2Units = { { 0xF8, 0x02 } };
        Run r;
        RunScenario(o, r);
        r.drv->StopDevice(1, IOUserAudioStartStopFlags::None);
        Select(r, 1, "DD-16X: select 64");
        const Port2State s = ReadPort2(r);
        SymphonyUnitBStateOutput st = {};
        r.drv->ReadUnitBState(reinterpret_cast<uint32_t *>(&st));
        SymphonyConverterStateOutput conv = {};
        r.drv->ReadConverterState(reinterpret_cast<uint32_t *>(&conv));
        CHECK((s.w[14] & kSymphonyPort2AudioActive) != 0 && st.present == 0 && (conv.flags & kSymphonyConvPort2Converters) != 0 &&
              (s.w[7] & kSymphonyPort2UnitTypeOK) == 0,
              "%s: audio 0x%x unit B present %u conv flags 0x%x word 0x%08x", o.name, s.w[14], st.present, conv.flags, s.w[7]);
        CHECK(r.card.port[1].vendorWrites.empty() && r.card.port[1].vendorReads.empty(), "%s: Symphony vendor traffic to a DD-16X", o.name);
        Finish(o, r);
    }
#endif
#endif
    // 4. A unit whose authentication does not verify is reported and kept.
    {
        Options o; o.name = "converters: failed authentication is reported"; o.port1 = Port::Converters; o.shortFlow = true;
        o.port1Units = { U(0x37, 0x02), U(0xC7, 0x02) };
        o.port1Units[1].authGenuine = false;
        Run r;
        RunScenario(o, r);
        const SymphonyConverterStateOutput st = ConvState(r);
        CHECK(st.unitCount[0] == 2, "%s: %u units (want 2, the failing one kept)", o.name, st.unitCount[0]);
        CHECK((st.unit[0][1] & kSymphonyConvUnitAuthRan) && !(st.unit[0][1] & kSymphonyConvUnitAuthOK),
              "%s: unit 2 word 0x%08x (want ran, not verified)", o.name, st.unit[0][1]);
        CHECK(st.hostOutputs == 16, "%s: the failing DA's outputs not placed (%u)", o.name, st.hostOutputs);
        Finish(o, r);
    }
    // 5. Health: a unit drifts out of the 0x01-0x2F window while audio runs.
    //    The watch only reads (no jam under running DMA), marks the recovery,
    //    and the next StartDevice runs the rate transaction with the alignment.
    {
        Options o; o.name = "converters: phase out of window"; o.port1 = Port::Converters; o.shortFlow = true;
        Run r;
        RunScenario(o, r);
        FakeCard &c = r.card;
        c.phase("unit 2 out of phase");
        c.port[0].units[1].phase = 0x40;
        size_t mark = c.lines.size();
        r.drv->LinkWatchTimerOccurred(nullptr, 0); HostPump();
        SymphonyConverterStateOutput st = ConvState(r);
        CHECK(st.phaseErrors >= 1, "%s: no phase error counted", o.name);
        CHECK(st.flags & kSymphonyConvRecoveryPending, "%s: no recovery pending (flags 0x%x)", o.name, st.flags);
        CHECK(CountAccess(c, mark, 'W', kRegJam) == 0, "%s: jam written from the watch", o.name);
        c.port[0].units[1].phase = 0x20;
        c.phase("controlled restart");
        r.drv->StopDevice(1, IOUserAudioStartStopFlags::None);
        mark = c.lines.size();
        CHECK(r.drv->StartDevice(1, IOUserAudioStartStopFlags::None) == kIOReturnSuccess, "%s: restart failed", o.name);
        CHECK(FindWrite(c, mark, kRegJam, 0x1B) != SIZE_MAX, "%s: alignment not written in the restart", o.name);
        st = ConvState(r);
        CHECK(!(st.flags & kSymphonyConvRecoveryPending), "%s: recovery still pending", o.name);
        Finish(o, r);
    }
    // 6. Health: a unit added at the end while running re-runs the bus init.
    {
        Options o; o.name = "converters: unit added"; o.port1 = Port::Converters; o.shortFlow = true;
        Run r;
        RunScenario(o, r);
        FakeCard &c = r.card;
        c.phase("a third unit at the end");
        c.port[0].units.push_back(U(0x37, 0x02));
        r.drv->LinkWatchTimerOccurred(nullptr, 0); HostPump();
        r.drv->LinkWatchTimerOccurred(nullptr, 0); HostPump();
        CHECK(ConvState(r).unitCount[0] == 3, "%s: %u units after the add (want 3)", o.name, ConvState(r).unitCount[0]);
        Finish(o, r);
    }
    // 7. External word clock: SET_EXT_LOCK to every unit with data 1, never a
    //    Symphony ClockMode; the Core Audio clock selector maps onto it too.
    {
        Options o; o.name = "converters: external word clock"; o.port1 = Port::Converters; o.shortFlow = true;
        Run r;
        RunScenario(o, r);
        FakeCard &c = r.card;
        size_t mark = c.lines.size();
        CHECK(r.drv->SetConverterConfig(kSymphonyConvConfigClockExternal) == kIOReturnSuccess, "%s: config refused", o.name);
        HostPump();
        bool ext = false;
        for (uint32_t v : Commands(c, mark, kRegXLink1TX, 0x04)) if (v == 0x0001) ext = true;   // addr 0, data 1
        CHECK(ext, "%s: SET_EXT_LOCK(broadcast, 1) not sent", o.name);
        CHECK(ConvState(r).flags & kSymphonyConvClockExternal, "%s: flags 0x%x", o.name, ConvState(r).flags);
        mark = c.lines.size();
        r.drv->RequestClockSource(1);   // Internal from Audio MIDI Setup
        HostPump();
        bool internal = false;
        for (uint32_t v : Commands(c, mark, kRegXLink1TX, 0x04)) if (v == 0x0100) internal = true;   // addr 1, data 0
        CHECK(internal, "%s: Internal did not send SET_EXT_LOCK(1, 0)", o.name);
        CHECK(VendorMessagePhase(c, AfterIdentification(c)).empty(), "%s: a vendor message went to converters (phase %s)",
              o.name, VendorMessagePhase(c, AfterIdentification(c)).c_str());
        Finish(o, r);
    }
    // 8. Device Type: a 0x0F unit used as a DA-16X puts its analog channels on
    //    the outputs; the state reports the choice.
    {
        Options o; o.name = "converters: Device Type"; o.port1 = Port::Converters; o.shortFlow = true;
        o.port1Units = { U(0xF7, 0x02) };
        Run r;
        RunScenario(o, r);
        r.drv->SetConverterConfig(1u << kSymphonyConvConfigDDAsDAShift);
        HostPump();
        CHECK(ConvState(r).unit[0][0] & kSymphonyConvUnitTypeIsDA, "%s: Device Type not reported", o.name);
        Finish(o, r);
    }
}
#endif

// B1b: card routes select an RX port independently of the host destination.
// Separate from frozen startup traces: only these explicit commands add writes.
static void RunSymphonyCardInputRoutes()
{
    for (bool legacy : {false, true}) for (bool two : {false, true}) {
        Options o; o.name = "B1b card input routes"; o.shortFlow = true; o.legacy2100 = legacy; o.micPreInstrument = true;
        o.portCountProperty = 2; o.port2 = two ? Port::Symphony : Port::Empty;
        Run r; RunScenario(o, r);
        auto route = [&](uint8_t host, uint8_t rx, uint8_t enable = 1) {
            uint8_t pl[] = {host, rx, enable};
            auto rc = r.drv->SendVendorCommand(0xB6, 0, pl, sizeof(pl));
            HostPump(); return rc;
        };
        auto &c = r.card;
        CHECK(route(0, 32) == kIOReturnBadArgument, "B1b: port 2 source refused at 32");
        CHECK(route(32, 0) == kIOReturnBadArgument, "B1b: host 33 refused at 32");
        CHECK(route(0, 1) == kIOReturnSuccess, "B1b: A input to host 1");
        CHECK(c.reg[kRegInputRouting] == 0x101, "B1b: RX 1 written");
        CHECK(LastElementName(c, 0, "in", 1) == LastElementName(c, 0, "in", 2), "B1b: names follow A route");
        if (two) {
            // Real audio boards on both units; the generic fixture's type 1
            // is a MicPre companion with no independent audio channels.
            c.port[1].stored[(uint64_t(0xA1) << 32) | 0] = {6};
            c.port[1].stored[(uint64_t(0xA1) << 32) | 1] = {1};
            r.drv->StopDevice(1, IOUserAudioStartStopFlags::None);
            Select(r, 1, "B1b select 64");
            HostPump();
            const auto nameA = LastElementName(c, 0, "in", 2);
            const auto nameB = LastElementName(c, 0, "in", 33);
            CHECK(!nameA.empty() && !nameB.empty() && nameA != nameB, "B1b: distinct source names available (A=%s B=%s)", nameA.c_str(), nameB.c_str());
            const size_t mark = c.lines.size();
            CHECK(route(32, 1) == kIOReturnSuccess, "B1b: A input to host 33");
            CHECK(route(0, 32) == kIOReturnSuccess, "B1b: B input to host 1");
            CHECK(route(1, 32) == kIOReturnSuccess, "B1b: duplicate B input");
            CHECK(c.reg[kRegInputRouting + 32 * 4] == 0x101 && c.reg[kRegInputRouting] == 0x120 &&
                  c.reg[kRegInputRouting + 4] == 0x120, "B1b: independent source/destination words");
            CHECK(LastElementName(c, mark, "in", 33) == nameA && LastElementName(c, mark, "in", 1) == nameB &&
                  LastElementName(c, mark, "in", 2) == nameB, "B1b: cross-port and duplicate names");
            CHECK(Commands(c, mark, kRegXLink1TX, 0x10).empty() && Commands(c, mark, kRegXLink2TX, 0x10).empty(),
                  "B1b: card commands never forwarded to peripherals");
            const auto bNext = LastElementName(c, 0, "in", 34);
            uint8_t p2p[] = {192, 33}; // unit B P2P 0 <- board input 2
            CHECK(r.drv->SendVendorCommand(0x31, 0, p2p, sizeof(p2p), 1) == kIOReturnSuccess,
                  "B1b: unit B capture edit accepted");
            HostPump();
            CHECK(!bNext.empty() && LastElementName(c, mark, "in", 1) == bNext &&
                  LastElementName(c, mark, "in", 2) == bNext, "B1b: names compose B P2P and card routes (want=%s got=%s)", bNext.c_str(), LastElementName(c, mark, "in", 1).c_str());
        }
        const size_t refused = c.lines.size();
        CHECK(r.drv->SendVendorCommand(0xB6, 0, nullptr, 0) == kIOReturnBadArgument,
              "B1b: missing payload refused");
        for (size_t i = refused; i < c.lines.size(); i++)
            CHECK(c.lines[i].compare(0, 2, "W ") != 0, "B1b: refused route wrote hardware");
        CHECK(route(0, 64) == kIOReturnBadArgument && route(64, 0) == kIOReturnBadArgument,
              "B1b: out-of-range refused");
        CHECK(route(0, 0, 0) == kIOReturnSuccess && c.reg[kRegInputRouting] == 0, "B1b: disable input");
        const uint32_t outputBeforeReset = c.reg[kRegOutputRouting];
        CHECK(r.drv->SendVendorCommand(0xB7, 0, nullptr, 0) == kIOReturnSuccess, "B1b: reset accepted");
        CHECK(c.reg[kRegOutputRouting] == outputBeforeReset, "B1b: Symphony input reset preserves outputs");
        HostPump();
        for (uint32_t n = 0; n < (two ? 64u : 32u); n++)
            CHECK(c.reg[kRegInputRouting + n * 4] == (0x100 | n), "B1b: reset input %u", n);
        if (two) {
            Select(r, 0, "B1b back to 32");
            CHECK(route(0, 32) == kIOReturnBadArgument, "B1b: source B refused after leaving 64");
        }
        Finish(o, r);
    }
    Options o; o.name = "B1b absent Symphony"; o.shortFlow = true; o.port1 = Port::Empty;
    Run r; RunScenario(o, r);
    uint8_t pl[] = {0, 0, 1};
    const size_t mark = r.card.lines.size();
    CHECK(r.drv->SendVendorCommand(0xB6, 0, pl, sizeof(pl)) == kIOReturnNotReady,
          "B1b: no source on port 1 refused");
    for (size_t i = mark; i < r.card.lines.size(); i++)
        CHECK(r.card.lines[i].compare(0, 2, "W ") != 0, "B1b: no-source route wrote hardware");
    Finish(o, r);
}

// HAL MicPre writes are refused for kHALMicPreSettleNs after Start, wake and
// a device configuration change (coreaudiod's restore). Step past it.
static void PastMicPreSettle()
{
    gHostMicPreClockOffsetNs += 6000000000ull;
}

// B10: assertions only, so the shipped lifecycle goldens remain immutable.
static void RunPreampHostRoutes()
{
    Options o; o.name = "B10 preamp host routes"; o.shortFlow = true;
    o.micPreInstrument = true; o.portCountProperty = 2; o.port2 = Port::Symphony;
    Run r; RunScenario(o, r);
    PastMicPreSettle();
    auto *drv = r.drv;
    auto &a = r.card.port[0].stored;
    auto &b = r.card.port[1].stored;
    const uint64_t phantom = uint64_t(0xC6) << 32;
    const uint64_t mic = uint64_t(0xC3) << 32;
    auto route = [&](uint8_t host, uint8_t rx) {
        uint8_t pl[] = {host, rx, 1};
        return drv->SendVendorCommand(0xB6, 0, pl, sizeof(pl));
    };
    // HAL phantom ON needs a channel known to be in Mic mode (original:
    // SymphonyIOBoard_MicPre8ch.cpp:683-691). ch1 is Instrument, ch2 unknown.
    a.erase(phantom); a.erase(phantom | 1); a.erase(phantom | 2);
    CHECK(drv->RequestPhantom(1, true) == kIOReturnNotPermitted, "P1: phantom ON refused on Instrument");
    CHECK(drv->RequestPhantom(2, true) == kIOReturnNotPermitted, "P1: phantom ON refused on unknown type");
    CHECK(drv->RequestPhantom(2, false) == kIOReturnSuccess, "P1: phantom OFF allowed on unknown type");
    HostPump();
    CHECK(!a.count(phantom | 1) && a[phantom | 2] == std::vector<uint8_t>({0}), "P1: only the OFF reached the unit");
    a.erase(phantom);
    CHECK(drv->RequestPhantom(0, true) == kIOReturnSuccess, "P1: phantom ON accepted on Mic");
    HostPump();
    CHECK(a[phantom] == std::vector<uint8_t>({1}), "P1: Mic channel phantom ON sent");

    CHECK(route(0, 32) == kIOReturnBadArgument, "B10: B route refused at 32");
#ifdef kSelectorPublishMicGain
    CHECK(drv->PublishObservedMicGain(1, 0, 0, 42) == kIOReturnNotReady,
          "M13: B observation refused at 32");
    SymphonyObservedGainInput input = {kSymphonyUCMagic, 1, 1, 0, 0, 42};
    CHECK(SymphonyObservedGainInputValid(&input), "M13: valid ABI input");
    input.version = 2;
    CHECK(!SymphonyObservedGainInputValid(&input), "M13: unknown ABI version rejected");
    input.version = 1; input.magic = 0;
    CHECK(!SymphonyObservedGainInputValid(&input), "M13: wrong magic rejected");
#endif
    b[(uint64_t(0xA1) << 32) | 0] = {6};
    b[(uint64_t(0xA1) << 32) | 1] = {1};
    drv->StopDevice(1, IOUserAudioStartStopFlags::None);
    Select(r, 1, "B10 select 64");
    PastMicPreSettle();
    uint8_t type[] = {3, 127};
    CHECK(drv->SendVendorCommand(0x20, 0x80000000u, type, 2, 1) == kIOReturnSuccess,
          "B10: B Mic type tracked");
    CHECK(route(0, 32) == kIOReturnSuccess, "B10: B routed to host 1");
    a.erase(phantom); a.erase(mic); b.erase(phantom); b.erase(mic);
    // P-2: host 1 maps to B0, host 9 to A0. ON never creates an OFF receipt.
#ifdef kSymphonyPhantomObservationWords
    uint32_t observed[32] = {};
    drv->ReadPhantomObservations(observed);
    CHECK(observed[0] == 0 && observed[16] == 0, "P2: external ON grants no receipt");
    CHECK(drv->RequestPhantom(0, false) == kIOReturnSuccess, "P2: queue routed OFF");
    HostPump();
    const size_t observationMark = r.card.lines.size();
    drv->ReadPhantomObservations(observed);
    CHECK((observed[16] || observed[17]) && !observed[0] && !observed[1],
          "P2: routed OFF recorded for B0 only");
    CHECK(r.card.lines.size() == observationMark, "P2: reading observations has no bus traffic");
    uint32_t beforeInvalid[32]; memcpy(beforeInvalid, observed, sizeof(observed));
    drv->RequestPhantom(64, false);
    drv->ReadPhantomObservations(observed);
    CHECK(memcmp(beforeInvalid, observed, sizeof(observed)) == 0, "P2: unmapped element records nothing");
#endif
    CHECK(drv->RequestPhantom(0, true) == kIOReturnSuccess && drv->RequestMicGain(0, 44) == kIOReturnSuccess,
          "B10: host 1 accepts B preamp writes");
    HostPump();
    CHECK(b[phantom] == std::vector<uint8_t>({1}) && b[mic] == std::vector<uint8_t>({44}) &&
          !a.count(phantom) && !a.count(mic), "B10: host 1 writes B over port 2 only");
#ifdef kSymphonyPhantomObservationWords
    drv->ReadPhantomObservations(observed);
    CHECK(memcmp(beforeInvalid, observed, sizeof(observed)) == 0, "P2: ON does not change OFF receipts");
    uint8_t phantomOn[] = {1};
    CHECK(drv->SendVendorCommand(0xC6, 0, phantomOn, sizeof(phantomOn), 1) == kIOReturnSuccess,
          "P2: Maestro ON accepted on B0");
    drv->ReadPhantomObservations(observed);
    CHECK(observed[16] == 0 && observed[17] == 0,
          "P2: later Maestro ON clears the older unread B0 OFF receipt");
#endif

    // B11: admission is not permission to use a stale physical route.  Change
    // the host route while each XLink lane is queued; phantom ON and gain are
    // dropped; phantom OFF still reaches the admitted channel (safe direction);
    // nothing touches the newly selected A unit.
    CHECK(route(0, 32) == kIOReturnSuccess, "B11: restore B route for stale-route checks");
    const size_t staleOnMark = r.card.lines.size();
    CHECK(drv->RequestPhantom(0, true) == kIOReturnSuccess, "B11: queue phantom ON");
    gHostDispatchSyncDrain = false;
    CHECK(route(0, 0) == kIOReturnSuccess, "B11: change route before phantom ON drains");
    gHostDispatchSyncDrain = true;
    HostPump();
    CHECK(Commands(r.card, staleOnMark, kRegXLink1TX, 0x10).empty() &&
          Commands(r.card, staleOnMark, kRegXLink2TX, 0x10).empty(),
          "B11: stale phantom ON sends nothing");

    CHECK(route(0, 32) == kIOReturnSuccess, "B11: restore B route for phantom OFF");
    const size_t staleOffMark = r.card.lines.size();
    CHECK(drv->RequestPhantom(0, false) == kIOReturnSuccess, "B11: queue phantom OFF");
    gHostDispatchSyncDrain = false;
    CHECK(route(0, 0) == kIOReturnSuccess, "B11: change route before phantom OFF drains");
    gHostDispatchSyncDrain = true;
    HostPump();
    CHECK(Commands(r.card, staleOffMark, kRegXLink1TX, 0x10).empty() &&
          !Commands(r.card, staleOffMark, kRegXLink2TX, 0x10).empty() &&
          b[phantom] == std::vector<uint8_t>({0}),
          "B11: phantom OFF still reaches the admitted B channel, never the new A route");

    CHECK(route(0, 32) == kIOReturnSuccess, "B11: restore B route for stale gain");
    const size_t staleGainMark = r.card.lines.size();
    CHECK(drv->RequestMicGain(0, 52) == kIOReturnSuccess, "B11: queue gain");
    gHostDispatchSyncDrain = false;
    CHECK(route(0, 0) == kIOReturnSuccess, "B11: change route before gain drains");
    gHostDispatchSyncDrain = true;
    HostPump();
    CHECK(Commands(r.card, staleGainMark, kRegXLink1TX, 0x10).empty() &&
          Commands(r.card, staleGainMark, kRegXLink2TX, 0x10).empty(),
          "B11: stale gain sends nothing");

    // The unchanged-route path remains the existing positive control above.
    CHECK(route(0, 32) == kIOReturnSuccess, "B11: restore B route for unchanged control");
    const size_t unchangedMark = r.card.lines.size();
    CHECK(drv->RequestMicGain(0, 53) == kIOReturnSuccess, "B11: queue unchanged gain");
    HostPump();
    CHECK(!Commands(r.card, unchangedMark, kRegXLink2TX, 0x10).empty() &&
          b[mic] == std::vector<uint8_t>({53}),
          "B11: unchanged route still sends B gain");

    CHECK(route(8, 0) == kIOReturnSuccess, "B10: A routed to host 9");
#ifdef kSymphonyPhantomObservationWords
    drv->ReadPhantomObservations(observed);
    const uint32_t bReceiptBeforeRemappedA = observed[16];
    const uint32_t bReceiptBeforeRemappedAHi = observed[17];
    CHECK(drv->RequestPhantom(8, false) == kIOReturnSuccess, "P2: queue remapped A OFF");
    HostPump();
    drv->ReadPhantomObservations(observed);
    CHECK((observed[0] || observed[1]) && observed[16] == bReceiptBeforeRemappedA && observed[17] == bReceiptBeforeRemappedAHi,
          "P2: remapped A OFF leaves B receipt unchanged");
#endif
    CHECK(drv->RequestPhantom(8, true) == kIOReturnSuccess && drv->RequestMicGain(8, 33) == kIOReturnSuccess,
          "B10: host 9 accepts A preamp writes");
    HostPump();
    CHECK(a[phantom] == std::vector<uint8_t>({1}) && a[mic] == std::vector<uint8_t>({33}),
          "B10: host 9 writes A preamp 1");
    CHECK(route(1, 32) == kIOReturnSuccess, "B10: duplicate B route");
    drv->RequestMicGain(0, 45); drv->RequestMicGain(1, 46); HostPump();
    CHECK(b[mic] == std::vector<uint8_t>({46}) &&
          gHostAudio.micGains.at(0)->GetDecibelValue() == 46 &&
          gHostAudio.micGains.at(1)->GetDecibelValue() == 46,
          "B10: duplicates coalesce and both HAL controls publish B gain");
#ifdef kSelectorPublishMicGain
    // Major 13: observations publish through both route layers, to aliases,
    // without enqueueing hardware writes. The positive control above wrote 46.
    HostPump();
    const size_t bObservedMark = r.card.lines.size();
    CHECK(drv->PublishObservedMicGain(1, 0, 0, 51) == kIOReturnSuccess,
          "M13: accept B observed gain");
    CHECK(gHostAudio.micGains.at(0)->GetDecibelValue() == 51 &&
          gHostAudio.micGains.at(1)->GetDecibelValue() == 51,
          "M13: B observed gain reaches routed HAL aliases");
    HostPump();
    CHECK(r.card.lines.size() == bObservedMark, "M13: B observation performs no bus IO");
    CHECK(route(2, 0) == kIOReturnSuccess, "M13: route A preamp to host 3");
    HostPump();
    const size_t aObservedMark = r.card.lines.size();
    CHECK(drv->PublishObservedMicGain(0, 0, 0, 29) == kIOReturnSuccess &&
          gHostAudio.micGains.at(2)->GetDecibelValue() == 29,
          "M13: A observed gain reaches remapped HAL input");
    HostPump();
    CHECK(a[mic] == std::vector<uint8_t>({33}) && b[mic] == std::vector<uint8_t>({46}),
          "M13: observations never echo gain to hardware");
    CHECK(r.card.lines.size() == aObservedMark, "M13: publication performs no bus IO");
    CHECK(drv->PublishObservedMicGain(1, 0, 1, 20) == kIOReturnNotReady,
          "M13: stale stage refused");
    CHECK(drv->PublishObservedMicGain(2, 0, 0, 20) == kIOReturnBadArgument &&
          drv->PublishObservedMicGain(0, 8, 0, 20) == kIOReturnBadArgument &&
          drv->PublishObservedMicGain(0, 0, 1, 66) == kIOReturnBadArgument,
          "M13: malformed observations refused");
#endif
    drv->RequestMicGain(0, 47); drv->RequestMicGain(8, 34); HostPump();
    CHECK(b[mic] == std::vector<uint8_t>({47}) && a[mic] == std::vector<uint8_t>({34}),
          "B10: pending A and B gains remain independent");
    type[0] = 4;
    drv->SendVendorCommand(0x20, 0x80000000u, type, 2, 1);
    drv->RequestMicGain(0, 99); HostPump();
    CHECK(b[uint64_t(0xC4) << 32] == std::vector<uint8_t>({65}) &&
          a[mic] == std::vector<uint8_t>({34}), "B10: B Instrument uses C4 and clamps independently");
    // Digital AES source replaces host 1, through the peripheral P2P table.
    CHECK(route(0, 0) == kIOReturnSuccess, "B10: host 1 returns to A RX0");
    uint8_t digital[] = {192, 40};
    CHECK(drv->SendVendorCommand(0x31, 0, digital, sizeof(digital)) == kIOReturnSuccess,
          "B10: digital source replaces preamp");
#ifdef kSymphonyPhantomObservationWords
    drv->ReadPhantomObservations(beforeInvalid);
#endif
    const size_t mark = r.card.lines.size();
    CHECK(drv->RequestPhantom(0, false) == kIOReturnNotReady &&
          drv->RequestMicGain(0, 12) == kIOReturnNotReady, "B10: digital route refuses phantom and gain");
#ifdef kSymphonyPhantomObservationWords
    drv->ReadPhantomObservations(observed);
    CHECK(memcmp(beforeInvalid, observed, sizeof(observed)) == 0, "P2: digital element records nothing");
#endif
    HostPump();
    CHECK(Commands(r.card, mark, kRegXLink1TX, 0x10).empty() &&
          Commands(r.card, mark, kRegXLink2TX, 0x10).empty(), "B10: digital refusal sends nothing");
    r.card.port[1].kind = Port::Empty;
    drv->LinkWatchTimerOccurred(nullptr, 0); HostPump();
    const size_t removed = r.card.lines.size();
#ifdef kSelectorPublishMicGain
    CHECK(drv->PublishObservedMicGain(1, 0, 1, 42) == kIOReturnNotReady,
          "M13: observation refuses removed B");
#endif
    CHECK(drv->RequestPhantom(1, false) == kIOReturnSuccess &&
          drv->RequestMicGain(1, 13) == kIOReturnSuccess, "B10: removed B falls back to saved A route");
    HostPump();
    CHECK(!Commands(r.card, removed, kRegXLink1TX, 0x10).empty() &&
          Commands(r.card, removed, kRegXLink2TX, 0x10).empty(), "B10: removal targets A after 64→32 fallback");
#ifdef kSymphonyPhantomObservationWords
    // An admitted OFF whose MSG_BYTE send times out must not manufacture a
    // receipt: the app may clear saved authority only for a confirmed send.
    uint32_t beforeFailedSend[32];
    drv->ReadPhantomObservations(beforeFailedSend);
    r.card.port[0].txBusy = true;
    CHECK(drv->RequestPhantom(1, false) == kIOReturnSuccess, "P2: admitted OFF queued before TX failure");
    HostPump();
    r.card.port[0].txBusy = false;
    drv->ReadPhantomObservations(observed);
    CHECK(memcmp(beforeFailedSend, observed, sizeof(observed)) == 0,
          "P2: failed admitted OFF leaves receipt unchanged");
#endif
    Finish(o, r);
}

#ifdef TRACE_HAVE_MIC_PRE_DAW
// B12: the DAW-facing MicPre controls (polarity, high-pass, input type).
// Assertions only: the one golden with a usable 8MicPre (p1-symphony-micpre,
// dext 150) never edits these controls, so the traces stay as they are. The
// controls' own sources are compiled here (run-tests.sh), so
// their HandleChange paths are the real ones.
static std::vector<uint8_t> WritesSince(const Port &p, size_t mark)
{
    return std::vector<uint8_t>(p.vendorWrites.begin() + (long)mark, p.vendorWrites.end());
}

static size_t ReadsSince(const Port &p, size_t mark, uint8_t cmd)
{
    return (size_t)std::count(p.vendorReads.begin() + (long)mark, p.vendorReads.end(), cmd);
}

static void RunMicPreDAWControls()
{
    Options o; o.name = "B12 MicPre DAW controls"; o.shortFlow = true;
    o.micPreInstrument = true; o.micPreSwitches = true;
    o.portCountProperty = 2; o.port2 = Port::Symphony;
    Run r; RunScenario(o, r);
    auto *drv = r.drv;
    Port &pa = r.card.port[0];
    Port &pb = r.card.port[1];
    auto &a = pa.stored;
    auto &b = pb.stored;
    auto key = [](uint8_t cmd, uint32_t value) { return (uint64_t(cmd) << 32) | value; };
    auto route = [&](uint8_t host, uint8_t rx) {
        uint8_t pl[] = {host, rx, 1};
        return drv->SendVendorCommand(0xB6, 0, pl, sizeof(pl));
    };
    auto &phases = gHostAudio.micPrePhases;
    auto &hpfs = gHostAudio.micPreHighPasses;
    auto &types = gHostAudio.micPreInputTypes;
    auto &phantoms = gHostAudio.phantoms;
    CHECK(phases.size() == 8 && hpfs.size() == 8 && types.size() == 8 && phantoms.size() == 8,
          "B12: one polarity, high-pass and type control per MicPre input");
    if (phases.size() != 8 || hpfs.size() != 8 || types.size() != 8 || phantoms.size() != 8) { Finish(o, r); return; }
    const IOUserAudioSelectorValue plus4 = 0, minus10 = 1, variable = 2, mic = 3, instrument = 4;
    const IOUserAudioSelectorValue on = 1, off = 0;

    // N1: right after Start, a coreaudiod restore cannot change the MicPre.
    size_t settle = pa.vendorWrites.size();
    auto refusedWhileSettling = [&](const char *when) {
        settle = pa.vendorWrites.size();
        CHECK(types[0]->HandleChangeSelectedValues(&plus4, 1) == kIOReturnNotPermitted &&
              phases[0]->HandleChangeControlValue(false) == kIOReturnNotPermitted &&
              hpfs[0]->HandleChangeSelectedValues(&on, 1) == kIOReturnNotPermitted &&
              drv->RequestPhantom(0, true) == kIOReturnNotPermitted,
              "B12: type, polarity, high-pass and phantom ON refused just after %s", when);
        CHECK(drv->RequestPhantom(0, false) == kIOReturnSuccess, "B12: phantom OFF still allowed after %s", when);
        HostPump();
        CHECK(WritesSince(pa, settle) == std::vector<uint8_t>({0xC6}) && types[0]->selected == mic &&
              phases[0]->GetControlValue() && hpfs[0]->selected == 0,
              "B12: only the OFF went out after %s; controls keep the real values", when);
        PastMicPreSettle();
    };
    refusedWhileSettling("Start");

    // Finding 1: a line-level control ('nlvl') with the original's IDs.
    CHECK(types[0]->classID == IOUserAudioClassID::LineLevelControl &&
          hpfs[0]->classID == IOUserAudioClassID::HighPassFilterControl &&
          phases[0]->classID == IOUserAudioClassID::PhaseInvertControl,
          "B12: type is a LineLevelControl, high-pass and polarity their own classes");
    CHECK(types[0]->values == std::vector<IOUserAudioSelectorValue>({0, 1, 2, 3, 4}) &&
          types[0]->names[0] == "+4 dBu" && types[0]->names[2] == "Variable" &&
          types[0]->names[4] == "Instrument" &&
          types[4]->values == std::vector<IOUserAudioSelectorValue>({0, 1, 2, 3}),
          "B12: IDs +4, -10, Variable, Mic, Instrument; Instrument on MicPre 1-4 only");
    CHECK(types[0]->selected == mic && types[1]->selected == instrument && types[3]->selected == variable,
          "B12: types start from the 0x60 read");
    // Finding 8: polarity and high-pass start from the unit (OG:2205-2223).
    CHECK(phases[0]->GetControlValue() && !phases[1]->GetControlValue() &&
          hpfs[0]->selected == 0 && hpfs[1]->selected == 1,
          "B12: polarity and high-pass start from the unit's 0xC5/0xCA reads");
    CHECK(ReadsSince(pa, 0, 0xC5) == 8 && ReadsSince(pa, 0, 0xCA) == 8,
          "B12: one polarity and one high-pass read per MicPre channel");

    // Finding 4: a change shows only after the unit took it.
    size_t w = pa.vendorWrites.size();
    CHECK(phases[0]->HandleChangeControlValue(false) == kIOReturnSuccess && phases[0]->GetControlValue(),
          "B12: polarity not published before the send");
    HostPump();
    CHECK(!phases[0]->GetControlValue() && a[key(0xC5, 0)] == std::vector<uint8_t>({0}) &&
          WritesSince(pa, w) == std::vector<uint8_t>({0xC5}),
          "B12: polarity published after 0xC5 reached MicPre 1");
    // Coalesced: a burst sends the latest value once.
    w = pa.vendorWrites.size();
    hpfs[0]->HandleChangeSelectedValues(&on, 1);
    hpfs[0]->HandleChangeSelectedValues(&off, 1);
    hpfs[0]->HandleChangeSelectedValues(&on, 1);
    CHECK(hpfs[0]->selected == 0, "B12: high-pass not published before the send");
    HostPump();
    CHECK(WritesSince(pa, w) == std::vector<uint8_t>({0xCA}) && a[key(0xCA, 0)] == std::vector<uint8_t>({1}) &&
          hpfs[0]->selected == 1, "B12: three high-pass changes coalesce into one 0xCA");
    // A failed send publishes nothing new.
    pa.txBusy = true;
    CHECK(phases[0]->HandleChangeControlValue(true) == kIOReturnSuccess, "B12: polarity queued before TX failure");
    HostPump();
    pa.txBusy = false;
    CHECK(!phases[0]->GetControlValue() && a[key(0xC5, 0)] == std::vector<uint8_t>({0}),
          "B12: failed 0xC5 keeps the real value");
    // Finding 8: refused on a known line type (MicPre 4 reads Variable).
    w = pa.vendorWrites.size();
    CHECK(phases[3]->HandleChangeControlValue(true) == kIOReturnNotPermitted &&
          hpfs[3]->HandleChangeSelectedValues(&on, 1) == kIOReturnNotPermitted,
          "B12: polarity and high-pass refused on a line type");
    HostPump();
    CHECK(WritesSince(pa, w).empty() && !phases[3]->GetControlValue() && hpfs[3]->selected == 0,
          "B12: a refused switch sends and publishes nothing");
    CHECK(phases[2]->HandleChangeControlValue(true) == kIOReturnSuccess, "B12: unknown type does not refuse polarity");
    HostPump();
    CHECK(phases[2]->GetControlValue() && a[key(0xC5, 2)] == std::vector<uint8_t>({1}),
          "B12: polarity on an unknown type reaches the unit");

    // One selector-5 layout: receipts 16-47, MIXS 48-51, edits 52-99.
#ifdef kSymphonyMixerInstanceWords
    CHECK(kSymphonyMixerInstanceWords == kSymphonyPhantomObservationWords + 4 &&
          kSymphonyMicPreEditOffset == kSymphonyMixerInstanceWords &&
          kSymphonyMicPreEditWords == kSymphonyMicPreEditOffset + 16 * 3,
          "B12: edits follow the D5 mixer instance in a 100-word read");
#endif
    // Finding 5/10: host-originated edits recorded per physical channel.
    uint32_t edits[48] = {};
    const size_t readMark = r.card.lines.size();
    drv->ReadMicPreEdits(edits);
    CHECK(r.card.lines.size() == readMark, "B12: reading edits has no bus traffic");
    CHECK((edits[0] || edits[1]) &&
#ifdef kMicPreStatePhantomKnown
          // dext 153: the OFF sent in the Start settle window is in the
          // record too, and the driver now knows A1's phantom (off).
          edits[2] == (kMicPreEditPhaseValid | kMicPreEditHighPass | kMicPreEditHighPassValid |
                       kMicPreEditPhantomValid | kMicPreStatePhantomKnown) &&
#else
          edits[2] == (kMicPreEditPhaseValid | kMicPreEditHighPass | kMicPreEditHighPassValid) &&
#endif
          (edits[8] & (kMicPreEditPhase | kMicPreEditPhaseValid)) == (kMicPreEditPhase | kMicPreEditPhaseValid) &&
          edits[9 * 3] == 0 && edits[9 * 3 + 2] == 0,
          "B12: A1 and A3 HAL edits recorded, cumulative per channel; others empty");
    uint8_t one[] = {1};
    const uint32_t stampLo = edits[0], stampHi = edits[1];
    CHECK(drv->SendVendorCommand(0xCA, 0, one, 1) == kIOReturnSuccess, "B12: Maestro high-pass write");
    drv->ReadMicPreEdits(edits);
    CHECK(edits[0] == stampLo && edits[1] == stampHi && !(edits[2] & kMicPreEditHighPassValid) &&
          (edits[2] & kMicPreEditPhaseValid), "B12: a Maestro write clears only its field, the stamp stays");
    // V1: a DAW burst on one channel (as a session recall sends) all survives
    // until the app reads it.
    phases[2]->HandleChangeControlValue(false);
    hpfs[2]->HandleChangeSelectedValues(&on, 1);
    CHECK(drv->RequestMicGain(2, 30) == kIOReturnSuccess, "B12: burst gain queued");
    HostPump();
    drv->ReadMicPreEdits(edits);
    CHECK((edits[8] & (kMicPreEditPhase | kMicPreEditPhaseValid | kMicPreEditHighPass | kMicPreEditHighPassValid |
                       kMicPreEditGainValid)) ==
              (kMicPreEditPhaseValid | kMicPreEditHighPass | kMicPreEditHighPassValid | kMicPreEditGainValid) &&
          ((edits[8] & kMicPreEditGainMask) >> kMicPreEditGainShift) == 30,
          "B12: polarity, high-pass and gain of one burst are all in the record");
    CHECK(drv->RequestMicGain(0, 40) == kIOReturnSuccess, "B12: DAW gain queued");
    HostPump();
    drv->ReadMicPreEdits(edits);
    CHECK((edits[2] & kMicPreEditGainValid) && ((edits[2] & kMicPreEditGainMask) >> kMicPreEditGainShift) == 40 &&
          !(edits[2] & kMicPreEditGainInstrument), "B12: DAW gain recorded with its stage");
    // N2: DAW 60 dB, the front panel then 20 dB, then a DAW polarity toggle:
    // the record must not hand the app 60 again.
    CHECK(drv->RequestMicGain(0, 60) == kIOReturnSuccess, "B12: DAW gain 60");
    HostPump();
    CHECK(drv->PublishObservedMicGain(0, 0, 0, 20) == kIOReturnSuccess, "B12: front panel gain 20");
    drv->ReadMicPreEdits(edits);
    CHECK(!(edits[2] & kMicPreEditGainValid), "B12: a front-panel gain clears the unread DAW gain");
    phases[0]->HandleChangeControlValue(true);
    HostPump();
    drv->ReadMicPreEdits(edits);
    CHECK(!(edits[2] & kMicPreEditGainValid) &&
          (edits[2] & (kMicPreEditPhase | kMicPreEditPhaseValid)) == (kMicPreEditPhase | kMicPreEditPhaseValid),
          "B12: the later polarity stamp carries polarity, never the older 60 dB");
    phases[0]->HandleChangeControlValue(false);
    HostPump();
    CHECK(drv->RequestMicGain(0, 40) == kIOReturnSuccess, "B12: DAW gain back to 40");
    HostPump();

    // Finding 3: Mic -> +4 with phantom on and an insert held.
    a[key(0xC8, 2)] = {0x01};   // insert 3 holds MicPre 1
    phantoms[0]->SetControlValue(true);
    w = pa.vendorWrites.size();
    size_t reads = pa.vendorReads.size();
    // 0.9.28: an accepted type is shown at once, as the original stored it
    // before the hardware write (SymphonyIOBoard_MicPre8ch.cpp:401), so a DAW
    // reading it back straight away sees its own choice.
    const uint32_t typeSets = types[0]->sets;
    CHECK(types[0]->HandleChangeSelectedValues(&plus4, 1) == kIOReturnSuccess && types[0]->selected == plus4 &&
              types[0]->sets == typeSets + 1 && WritesSince(pa, w).empty(),
          "B12: type published at once, before the send");
    HostPump();
    CHECK(WritesSince(pa, w) == std::vector<uint8_t>({0xC6, 0xC8, 0xC9, 0x20}),
          "B12: Mic -> +4 sends phantom OFF, insert release, insert return OFF, then the type");
    CHECK(a[key(0xC6, 0)] == std::vector<uint8_t>({0}) && a[key(0xC8, 2)] == std::vector<uint8_t>({0}) &&
          a[key(0xC9, 0)] == std::vector<uint8_t>({0}) &&
          a[key(0x20, 0x80000000u)] == std::vector<uint8_t>({1, 127}),
          "B12: OFF payloads, released mask, +4 with trim left alone (none known)");
    CHECK(ReadsSince(pa, reads, 0xC8) == 8, "B12: insert slots Maestro never wrote are read once");
    CHECK(types[0]->selected == plus4 && !phantoms[0]->GetControlValue(),
          "B12: type and phantom controls published after the sends");
    // Finding 2: the OFF leaves the same receipt as RequestPhantom's.
    uint32_t observed[32] = {};
    drv->ReadPhantomObservations(observed);
    CHECK((observed[0] || observed[1]) && !observed[2] && !observed[3] && !observed[16],
          "B12: type-change phantom OFF stamps the A1 receipt only");
    drv->ReadMicPreEdits(edits);
    CHECK((edits[2] & (kMicPreEditTypeValid | kMicPreEditTypeMask)) == (kMicPreEditTypeValid | 1u),
          "B12: the HAL type is recorded as wire +4");

    // Line -> line: no OFFs; Maestro's trim in the new type's encoding.
    uint8_t maestroPlus4[] = {1, 15};   // +4 dBu, trim +1.5 dB
    CHECK(drv->SendVendorCommand(0x20, 0x80000000u, maestroPlus4, 2) == kIOReturnSuccess, "B12: Maestro +4 with trim");
    drv->ReadMicPreEdits(edits);
    CHECK(!(edits[2] & kMicPreEditTypeValid), "B12: Maestro's type write clears the HAL type edit");
    w = pa.vendorWrites.size();
    types[0]->HandleChangeSelectedValues(&variable, 1);
    HostPump();
    CHECK(WritesSince(pa, w) == std::vector<uint8_t>({0x20}) &&
          a[key(0x20, 0x80000000u)] == std::vector<uint8_t>({0, 3}),
          "B12: +4 -> Variable sends only the type, trim 1.5 dB in 0.5 dB steps");
    w = pa.vendorWrites.size();
    types[0]->HandleChangeSelectedValues(&minus10, 1);
    HostPump();
    CHECK(WritesSince(pa, w) == std::vector<uint8_t>({0x20}) &&
          a[key(0x20, 0x80000000u)] == std::vector<uint8_t>({2, 15}),
          "B12: Variable -> -10 sends the stored trim in 0.1 dB steps");
    // Line -> Mic: type, stored gain for the stage (OG:472-482), group Off (OG:513-521).
    w = pa.vendorWrites.size();
    types[0]->HandleChangeSelectedValues(&mic, 1);
    HostPump();
    CHECK(WritesSince(pa, w) == std::vector<uint8_t>({0x20, 0xC3, 0xC7}) &&
          a[key(0x20, 0x80000000u)] == std::vector<uint8_t>({3, 127}) &&
          a[key(0xC3, 0)] == std::vector<uint8_t>({40}) && a[key(0xC7, 0)] == std::vector<uint8_t>({0}),
          "B12: -10 -> Mic sends the type, the stored Mic gain, then group Off");

    // Finding 9: a HAL Mic does not authorise HAL +48V straight away.
    CHECK(drv->RequestPhantom(0, true) == kIOReturnNotPermitted,
          "B12: phantom ON refused right after a HAL Mic (coreaudiod restore burst)");
    gHostMicPreClockOffsetNs += 3000000000ull;
    a.erase(key(0xC6, 0));
    CHECK(drv->RequestPhantom(0, true) == kIOReturnSuccess, "B12: phantom ON accepted after the arm delay");
    HostPump();
    CHECK(a[key(0xC6, 0)] == std::vector<uint8_t>({1}), "B12: a DAW user can turn +48V on after choosing Mic");

#ifdef kMicPreStatePhantomKnown
    // 0.9.28 (dext 153): one phantom state per channel, set only when the
    // unit took a 0xC6, shown (display only) on every host input routed to
    // the channel, from either side (SymphonyIOBoard_MicPre8ch.cpp:693-718).
    {
        const uint32_t phantomBits = kMicPreEditPhantom | kMicPreEditPhantomValid |
                                     kMicPreStatePhantom | kMicPreStatePhantomKnown;
        drv->ReadMicPreEdits(edits);
        CHECK((edits[2] & phantomBits) == phantomBits && phantoms[0]->GetControlValue(),
              "B12: a HAL phantom ON the unit took: in A1's record, the driver's state, shown on host 1");
        CHECK(route(4, 0) == kIOReturnSuccess && phantoms[4]->GetControlValue(),
              "B12: host 5 routed to MicPre 1 shows its phantom");
        const bool otherBefore = phantoms[1]->GetControlValue();
        const uint32_t otherPubs = phantoms[1]->valuePublications;
        // Maestro's own 0xC6: shown to every routed host, the HAL edit dropped.
        const uint8_t phantomOff[] = {0}, phantomOnByte[] = {1};
        size_t pw = pa.vendorWrites.size();
        CHECK(drv->SendVendorCommand(0xC6, 0, phantomOff, 1) == kIOReturnSuccess &&
              !phantoms[0]->GetControlValue() && !phantoms[4]->GetControlValue(),
              "B12: Maestro's phantom OFF {0} clears 48V on both inputs routed to MicPre 1");
        drv->ReadMicPreEdits(edits);
        CHECK((edits[2] & phantomBits) == kMicPreStatePhantomKnown,
              "B12: Maestro's 0xC6 clears the HAL phantom edit; the state is known off");
        CHECK(drv->SendVendorCommand(0xC6, 0, phantomOnByte, 1) == kIOReturnSuccess &&
              phantoms[0]->GetControlValue() && phantoms[4]->GetControlValue() &&
              phantoms[1]->GetControlValue() == otherBefore && phantoms[1]->valuePublications == otherPubs,
              "B12: Maestro's phantom ON lights only the inputs routed to MicPre 1");
        CHECK(WritesSince(pa, pw) == std::vector<uint8_t>({0xC6, 0xC6}),
              "B12: publishing phantom sends nothing more");
        drv->ReadMicPreEdits(edits);
        CHECK((edits[2] & phantomBits) == (kMicPreStatePhantom | kMicPreStatePhantomKnown),
              "B12: a Maestro ON is the driver's state, never a HAL edit");
        // A failed Maestro send publishes nothing and keeps the state.
        uint32_t pubs0 = phantoms[0]->valuePublications, pubs4 = phantoms[4]->valuePublications;
        pa.txBusy = true;
        CHECK(drv->SendVendorCommand(0xC6, 0, phantomOff, 1) != kIOReturnSuccess, "B12: Maestro OFF fails to send");
        pa.txBusy = false;
        drv->ReadMicPreEdits(edits);
        CHECK(phantoms[0]->valuePublications == pubs0 && phantoms[4]->valuePublications == pubs4 &&
              phantoms[0]->GetControlValue() && (edits[2] & kMicPreStatePhantom),
              "B12: a failed Maestro 0xC6 publishes nothing and the state stays ON");
        // Maestro's ON over a channel known not to be Mic (MicPre 2 is
        // Instrument) is not kept: the unit ignores it (original :684-691).
        CHECK(drv->SendVendorCommand(0xC6, 1, phantomOnByte, 1) == kIOReturnSuccess &&
              phantoms[1]->valuePublications == otherPubs, "B12: Maestro ON on an Instrument channel is not shown");
        drv->ReadMicPreEdits(edits);
        CHECK(!(edits[5] & (kMicPreStatePhantom | kMicPreStatePhantomKnown)),
              "B12: ... nor kept as the channel's state");
        CHECK(route(4, 4) == kIOReturnSuccess, "B12: host 5 back on MicPre 5");

        // HAL requests that do not reach the unit stamp nothing and show
        // the real state again.
        CHECK(drv->SendVendorCommand(0xC6, 0, phantomOff, 1) == kIOReturnSuccess, "B12: Maestro OFF, A1 known off");
        drv->ReadMicPreEdits(edits);
        uint32_t lo = edits[0], hi = edits[1];
        // ON on a non-Mic channel, refused at admission.
        pw = pa.vendorWrites.size();
        phantoms[1]->SetControlValue(true);   // what the DAW showed
        CHECK(drv->RequestPhantom(1, true) == kIOReturnNotPermitted, "B12: HAL phantom ON on Instrument refused");
        HostPump();
        drv->ReadMicPreEdits(edits);
        CHECK(WritesSince(pa, pw).empty() && !(edits[5] & (kMicPreEditPhantomValid | kMicPreStatePhantomKnown)),
              "B12: a refused ON sends and records nothing");
        // A coreaudiod-style restore of ON just after a wake and after
        // coreaudiod connects: refused, and host 1 shows OFF again.
        auto coreaudiodRestore = [&](const char *when) {
            pw = pa.vendorWrites.size();
            phantoms[0]->SetControlValue(true);
            CHECK(drv->RequestPhantom(0, true) == kIOReturnNotPermitted,
                  "B12: phantom ON refused in the settle window after %s", when);
            HostPump();
            drv->ReadMicPreEdits(edits);
            CHECK(WritesSince(pa, pw).empty() && !phantoms[0]->GetControlValue() &&
                      edits[0] == lo && edits[1] == hi && !(edits[2] & kMicPreEditPhantomValid),
                  "B12: the refused ON after %s sends nothing, records nothing, shows OFF again", when);
            PastMicPreSettle();
        };
        drv->SetPowerState(kIOServicePowerCapabilityOn);
        coreaudiodRestore("a wake");
        IOUserClient *caClient = nullptr;
        drv->NewUserClient(0, &caClient);
        coreaudiodRestore("coreaudiod connects");
        // Dropped in the drain: host 1 moved to MicPre 2 before it ran.
        CHECK(drv->SendVendorCommand(0xC6, 1, phantomOff, 1) == kIOReturnSuccess, "B12: MicPre 2 known off");
        pw = pa.vendorWrites.size();
        phantoms[0]->SetControlValue(true);
        CHECK(drv->RequestPhantom(0, true) == kIOReturnSuccess, "B12: HAL ON queued");
        gHostDispatchSyncDrain = false;
        CHECK(route(0, 1) == kIOReturnSuccess, "B12: host 1 to MicPre 2 before the ON drains");
        gHostDispatchSyncDrain = true;
        HostPump();
        drv->ReadMicPreEdits(edits);
        CHECK(WritesSince(pa, pw).empty() && !phantoms[0]->GetControlValue() &&
                  edits[0] == lo && edits[1] == hi && !(edits[2] & kMicPreEditPhantomValid),
              "B12: a dropped ON sends and records nothing; host 1 shows MicPre 2's phantom");
        CHECK(route(0, 0) == kIOReturnSuccess && !phantoms[0]->GetControlValue(), "B12: host 1 back on MicPre 1 (off)");
        // A failed send.
        pw = pa.vendorWrites.size();
        phantoms[0]->SetControlValue(true);
        pa.txBusy = true;
        CHECK(drv->RequestPhantom(0, true) == kIOReturnSuccess, "B12: HAL ON queued before TX failure");
        HostPump();
        pa.txBusy = false;
        drv->ReadMicPreEdits(edits);
        CHECK(!phantoms[0]->GetControlValue() && edits[0] == lo && edits[1] == hi &&
                  (edits[2] & phantomBits) == kMicPreStatePhantomKnown,
              "B12: a failed ON send records nothing and shows the real OFF again");
        // A HAL OFF that the unit took is recorded too.
        CHECK(drv->RequestPhantom(0, true) == kIOReturnSuccess, "B12: HAL ON again");
        HostPump();
        CHECK(drv->RequestPhantom(0, false) == kIOReturnSuccess, "B12: HAL OFF");
        HostPump();
        drv->ReadMicPreEdits(edits);
        CHECK((edits[2] & phantomBits) == (kMicPreEditPhantomValid | kMicPreStatePhantomKnown) &&
                  !phantoms[0]->GetControlValue() && (edits[0] != lo || edits[1] != hi),
              "B12: a HAL OFF the unit took is in the record");
        CHECK(drv->RequestPhantom(0, true) == kIOReturnSuccess, "B12: HAL ON for the tests below");
        HostPump();
    }
#endif
    w = pa.vendorWrites.size();
    drv->ReadMicPreEdits(edits);
    const uint32_t micLo = edits[0], micHi = edits[1];
    types[0]->HandleChangeSelectedValues(&mic, 1);
    HostPump();
    drv->ReadMicPreEdits(edits);
    CHECK(WritesSince(pa, w).empty() && edits[0] == micLo && edits[1] == micHi && types[0]->selected == mic,
          "B12: a HAL set of the same type sends nothing and records no edit (N8)");
    CHECK(drv->RequestPhantom(0, true) == kIOReturnNotPermitted, "B12: every HAL Mic restarts the arm delay");
    // N4: Maestro replaying that Mic (over a channel already in Mic) keeps the delay.
    uint8_t maestroMic[] = {3, 127};
    uint8_t maestroLine[] = {1, 127};
    CHECK(drv->SendVendorCommand(0x20, 0x80000000u, maestroMic, 2) == kIOReturnSuccess &&
          drv->RequestPhantom(0, true) == kIOReturnNotPermitted,
          "B12: Maestro's Mic over a HAL Mic does not cut the arm delay short");
    CHECK(drv->SendVendorCommand(0x20, 0x80000000u, maestroLine, 2) == kIOReturnSuccess &&
          drv->SendVendorCommand(0x20, 0x80000000u, maestroMic, 2) == kIOReturnSuccess &&
          drv->RequestPhantom(0, true) == kIOReturnSuccess,
          "B12: a Mic Maestro sets from another type authorises phantom ON at once, as before");
    HostPump();

    // Mic -> Instrument: phantom OFF first, no insert change, group Off.
#ifdef kMicPreStatePhantomKnown
    CHECK(phantoms[0]->GetControlValue(), "B12: host 1 shows 48V on before the type change");
#endif
    w = pa.vendorWrites.size();
    types[0]->HandleChangeSelectedValues(&instrument, 1);
    HostPump();
#ifdef kMicPreStatePhantomKnown
    drv->ReadMicPreEdits(edits);
    CHECK(!phantoms[0]->GetControlValue() &&
              (edits[2] & (kMicPreEditPhantom | kMicPreEditPhantomValid | kMicPreStatePhantom |
                           kMicPreStatePhantomKnown)) == (kMicPreEditPhantomValid | kMicPreStatePhantomKnown),
          "B12: the type change's phantom OFF is shown and recorded as OFF");
#endif
    CHECK(WritesSince(pa, w) == std::vector<uint8_t>({0xC6, 0x20, 0xC7}) &&
          a[key(0x20, 0x80000000u)] == std::vector<uint8_t>({4, 127}),
          "B12: Mic -> Instrument: phantom OFF, type, group Off (no Instrument gain known)");
    // Unknown type (MicPre 3) -> +4: both OFFs, as if it were Mic.
    w = pa.vendorWrites.size();
    types[2]->HandleChangeSelectedValues(&plus4, 1);
    HostPump();
    CHECK(WritesSince(pa, w) == std::vector<uint8_t>({0xC6, 0xC9, 0x20}) &&
          a[key(0xC6, 2)] == std::vector<uint8_t>({0}),
          "B12: an unknown type gets phantom and insert return OFF before the type");
    // A failed OFF stops the change (MicPre 1 is Instrument; to Variable).
    pa.txBusy = true;
    w = pa.vendorWrites.size();
    types[0]->HandleChangeSelectedValues(&mic, 1);   // Instrument -> Mic: no OFF, but the type fails
    CHECK(types[0]->selected == mic, "B12: the requested type shows before the send");
    HostPump();
    pa.txBusy = false;
    CHECK(WritesSince(pa, w).empty() && types[0]->selected == instrument,
          "B12: failed 0x20 republishes the real type");
    CHECK(drv->SendVendorCommand(0x20, 0x80000000u, maestroMic, 2) == kIOReturnSuccess, "B12: Maestro back to Mic");
    pa.txBusy = true;
    w = pa.vendorWrites.size();
    types[0]->HandleChangeSelectedValues(&plus4, 1);
    CHECK(types[0]->selected == plus4, "B12: +4 shows before its phantom OFF is sent");
    HostPump();
    pa.txBusy = false;
    CHECK(WritesSince(pa, w).empty() && types[0]->selected == mic &&
          drv->RequestPhantom(0, true) == kIOReturnSuccess,
          "B12: failed phantom OFF: no type change, channel still Mic");
    HostPump();

    // Stale route: the request was for MicPre 1; host 1 now reaches MicPre 2.
    w = pa.vendorWrites.size();
    types[0]->HandleChangeSelectedValues(&plus4, 1);
    CHECK(types[0]->selected == plus4, "B12: stale-route request shows at once");
    gHostDispatchSyncDrain = false;
    CHECK(route(0, 1) == kIOReturnSuccess, "B12: route host 1 to MicPre 2 before the type drains");
    gHostDispatchSyncDrain = true;
    HostPump();
    CHECK(WritesSince(pa, w).empty() && types[0]->selected == instrument,
          "B12: stale type sends nothing; host 1 shows the channel it now reaches");
    CHECK(route(0, 0) == kIOReturnSuccess && types[0]->selected == mic, "B12: host 1 back on MicPre 1");
    // N5: a unit routing edit (P2P 0 <- MicPre 2) re-targets host 1 at once.
    uint8_t p2pTo2[] = {192, 33}, p2pTo1[] = {192, 32};
    CHECK(drv->SendVendorCommand(0x31, 0, p2pTo2, sizeof(p2pTo2)) == kIOReturnSuccess &&
          types[0]->selected == instrument,
          "B12: after a unit routing edit host 1 shows MicPre 2's type");
    CHECK(drv->SendVendorCommand(0x31, 0, p2pTo1, sizeof(p2pTo1)) == kIOReturnSuccess &&
          types[0]->selected == mic, "B12: routing back shows MicPre 1 again");
    // N8: 0x20 fails after the insert was released: the record says so.
    const uint8_t insert6[] = {0x01};
    CHECK(drv->SendVendorCommand(0xC8, 5, insert6, 1) == kIOReturnSuccess,
          "B12: Maestro assigns insert 6 to MicPre 1");
    w = pa.vendorWrites.size();
    pa.busyAfterWrites = (long)w + 3;   // phantom OFF, insert release, return OFF go out; 0x20 does not
    types[0]->HandleChangeSelectedValues(&plus4, 1);
    HostPump();
    pa.busyAfterWrites = -1;
    drv->ReadMicPreEdits(edits);
    CHECK(WritesSince(pa, w) == std::vector<uint8_t>({0xC6, 0xC8, 0xC9}) && types[0]->selected == mic &&
          (edits[2] & kMicPreEditInsertOff) && !(edits[2] & kMicPreEditTypeValid),
          "B12: a failed 0x20 after the insert release is reported (insert off, type unchanged)");
    // V1: the insert-off bit stays until Maestro writes the insert itself.
    phases[0]->HandleChangeControlValue(false);
    HostPump();
    drv->ReadMicPreEdits(edits);
    CHECK(edits[2] & kMicPreEditInsertOff, "B12: insert-off survives a later DAW edit");
    const uint8_t returnOff[] = {0};
    CHECK(drv->SendVendorCommand(0xC9, 0, returnOff, 1) == kIOReturnSuccess, "B12: Maestro insert return write");
    drv->ReadMicPreEdits(edits);
    CHECK(!(edits[2] & kMicPreEditInsertOff), "B12: Maestro's 0xC9 clears insert-off");
    // Instrument choice follows the route (finding 10).
    CHECK(route(4, 0) == kIOReturnSuccess && types[4]->values.size() == 5 &&
          types[4]->HandleChangeSelectedValues(&instrument, 1) == kIOReturnSuccess,
          "B12: host 5 routed to MicPre 1 offers and accepts Instrument");
    CHECK(route(4, 4) == kIOReturnSuccess && types[4]->values.size() == 4 &&
          types[4]->HandleChangeSelectedValues(&instrument, 1) == kIOReturnBadArgument,
          "B12: host 5 back on MicPre 5 drops Instrument");
    HostPump();

    // Unit B: host 1 routed to B MicPre 1 writes port 2 only.
    b[key(0xA1, 0)] = {6};
    b[key(0xA1, 1)] = {1};
    drv->StopDevice(1, IOUserAudioStartStopFlags::None);
    {
        // N1: the port-mode configuration change re-arms the settle window
        // when it ENDS, not only when it is requested: the port-2 probe and
        // ConfigureUnitB can take seconds before coreaudiod re-reads the
        // controls (0.9.10 final review, finding 5).
        r.card.phase("B12 select 64");
        if (gHostAudio.portSources.size() == 2) gHostAudio.portSources[1]->selected = 1;
        const uint32_t before = gHostAudio.configChangeRequests;
        CHECK(drv->RequestPortMode(1) == kIOReturnSuccess, "B12: 64 channels requested");
        HostPump();
        CHECK(gHostAudio.configChangeRequests != before, "B12: 64 channels asks for a configuration change");
        PastMicPreSettle();   // the request's window runs out before the change is performed
        HostPerformConfigChange(r, false);
    }
    CHECK(types[0]->HandleChangeSelectedValues(&plus4, 1) == kIOReturnNotPermitted,
          "B12: type refused just after the port-mode configuration change ends");
    PastMicPreSettle();
    CHECK(drv->SendVendorCommand(0x20, 0x80000000u, maestroMic, 2, 1) == kIOReturnSuccess &&
          route(0, 32) == kIOReturnSuccess, "B12: B MicPre 1 in Mic, routed to host 1");
    drv->ReadMicPreEdits(edits);
    const uint32_t aLo = edits[0], aHi = edits[1];
    size_t wa = pa.vendorWrites.size(), wb = pb.vendorWrites.size();
    phases[0]->HandleChangeControlValue(true);
    HostPump();
    CHECK(WritesSince(pb, wb) == std::vector<uint8_t>({0xC5}) && WritesSince(pa, wa).empty() &&
          b[key(0xC5, 0)] == std::vector<uint8_t>({1}) && phases[0]->GetControlValue(),
          "B12: B polarity over port 2 only, published to host 1");
    drv->ReadMicPreEdits(edits);
    CHECK((edits[24] || edits[25]) && (edits[26] & kMicPreEditPhaseValid) && (edits[26] & kMicPreEditPhase) &&
          edits[0] == aLo && edits[1] == aHi, "B12: B edit recorded as B1, A1 untouched");
    drv->ReadPhantomObservations(observed);
    const uint32_t aReceipt = observed[0];
    wa = pa.vendorWrites.size(); wb = pb.vendorWrites.size();
    types[0]->HandleChangeSelectedValues(&plus4, 1);
    HostPump();
    CHECK(WritesSince(pb, wb) == std::vector<uint8_t>({0xC6, 0xC9, 0x20}) && WritesSince(pa, wa).empty(),
          "B12: B Mic -> +4 OFFs then type on port 2 only");
    drv->ReadPhantomObservations(observed);
    CHECK((observed[16] || observed[17]) && observed[0] == aReceipt, "B12: B OFF stamps the B1 receipt");
    // Stale B route: the request is dropped when host 1 moves back to A.
    wa = pa.vendorWrites.size(); wb = pb.vendorWrites.size();
    types[0]->HandleChangeSelectedValues(&mic, 1);
    gHostDispatchSyncDrain = false;
    CHECK(route(0, 0) == kIOReturnSuccess, "B12: host 1 back to A before the B type drains");
    gHostDispatchSyncDrain = true;
    HostPump();
    CHECK(WritesSince(pb, wb).empty() && WritesSince(pa, wa).empty(), "B12: stale B type sends nothing anywhere");
    // N6: unit B set up again (possibly another unit): its records and caches go.
    b[key(0xC8, 0)] = {0x01};
    pb.vendorReads.clear();
    drv->StopDevice(1, IOUserAudioStartStopFlags::None);
    Select(r, 0, "B12 back to 32");
    Select(r, 1, "B12 64 again");
    PastMicPreSettle();
    drv->ReadMicPreEdits(edits);
    CHECK(edits[24] == 0 && edits[25] == 0 && edits[26] == 0, "B12: B records cleared on reconfiguration");
    CHECK(drv->SendVendorCommand(0x20, 0x80000000u, maestroMic, 2, 1) == kIOReturnSuccess &&
          route(0, 32) == kIOReturnSuccess, "B12: B MicPre 1 in Mic again");
    wb = pb.vendorWrites.size();
    reads = pb.vendorReads.size();
    types[0]->HandleChangeSelectedValues(&plus4, 1);
    HostPump();
    CHECK(ReadsSince(pb, reads, 0xC8) == 8 && b[key(0xC8, 0)] == std::vector<uint8_t>({0}),
          "B12: B insert table read again from the new unit, not from the cache");
    // N1: a wake re-arms the settle window.
    drv->SetPowerState(kIOServicePowerCapabilityOn);
    CHECK(phases[0]->HandleChangeControlValue(true) == kIOReturnNotPermitted,
          "B12: polarity refused just after a wake");
    PastMicPreSettle();
    // V3: so does coreaudiod connecting (cold boot, coreaudiod restart).
    IOUserClient *client = nullptr;
    drv->NewUserClient(0, &client);
    CHECK(types[0]->HandleChangeSelectedValues(&plus4, 1) == kIOReturnNotPermitted,
          "B12: type refused just after coreaudiod connects");
    PastMicPreSettle();

    // V4: unit A comes back from a link recovery as a unit whose MicPre 1 is
    // Variable. Before: MicPre 1 was a HAL Mic, armed, with an unread edit.
    drv->StopDevice(1, IOUserAudioStartStopFlags::None);
    Select(r, 0, "B12 back to 32 for the recovery");
    PastMicPreSettle();
    CHECK(route(0, 0) == kIOReturnSuccess, "B12: host 1 on A MicPre 1");
    types[0]->HandleChangeSelectedValues(&mic, 1);
    HostPump();
    gHostMicPreClockOffsetNs += 3000000000ull;
    phases[0]->HandleChangeControlValue(true);
    HostPump();
    drv->ReadMicPreEdits(edits);
    const uint32_t unreadLo = edits[0], unreadHi = edits[1], unreadFields = edits[2];
    CHECK(unreadLo || unreadHi, "B12: an unread A1 edit before the recovery");
    pa = Port();
    drv->LinkWatchTimerOccurred(nullptr, 0); HostPump();
    Attach(pa, Port::Symphony);          // the new unit reads Variable (0) everywhere
    // ... and is the same kind of rig, a 16x16 with the 8MicPre in slot 2.
    // Since dext 150 the recovery lays the capture table out from the types
    // it reads, and MicPre routes need slot 1's analog inputs behind them;
    // the fake's default types (8MicPre in slot 1, 8x8 in slot 2) have none.
    pa.stored[key(0xA1, 0)] = {6};
    pa.stored[key(0xA1, 1)] = {1};
    pa.stored[key(0x60, 0x80000001u)] = {0xFF};   // except MicPre 2, whose read is invalid
    drv->LinkWatchTimerOccurred(nullptr, 0); HostPump();
    PastMicPreSettle();
    CHECK(ReadsSince(pa, 0, 0x60) >= 1, "B12: the MicPre types are read again after the recovery");
    CHECK(drv->RequestPhantom(0, true) == kIOReturnNotPermitted && types[0]->selected == variable,
          "B12: after the recovery a cached Mic does not admit HAL phantom ON");
    drv->ReadMicPreEdits(edits);
#ifdef kMicPreStatePhantomKnown
    // The phantom state bits are the driver's knowledge of the unit, not
    // edits: after a recovery (maybe another unit) the state is unknown.
    const uint32_t stateBits = kMicPreStatePhantom | kMicPreStatePhantomKnown;
    CHECK(edits[0] == unreadLo && edits[1] == unreadHi &&
              (edits[2] & ~stateBits) == (unreadFields & ~stateBits),
          "B12: a link recovery keeps the unread DAW edits");
    CHECK((unreadFields & kMicPreStatePhantomKnown) && !(edits[2] & stateBits),
          "B12: a link recovery forgets the phantom state of the unit that was there");
#else
    CHECK(edits[0] == unreadLo && edits[1] == unreadHi && edits[2] == unreadFields,
          "B12: a link recovery keeps the unread DAW edits");
#endif
    // W2: MicPre 2's type is unknown after the recovery. A DAW gain, then a
    // front-panel gain the driver cannot place on a stage: the DAW gain bit
    // must still go, or the stale gain comes back to the app (N2).
    CHECK(drv->RequestMicGain(1, 50) == kIOReturnSuccess, "B12: DAW gain on the unknown-type MicPre 2");
    HostPump();
    drv->ReadMicPreEdits(edits);
    CHECK((edits[3 + 2] & kMicPreEditGainValid) && pa.stored[key(0xC3, 1)] == std::vector<uint8_t>({50}),
          "B12: DAW gain on an unknown type goes to the Mic stage and is recorded");
    drv->PublishObservedMicGain(0, 1, 0, 20);
    drv->ReadMicPreEdits(edits);
    CHECK(!(edits[3 + 2] & kMicPreEditGainValid),
          "B12: a front-panel gain clears the DAW gain bit even with the type unknown");
    Finish(o, r);
}
#endif

#if defined(kSelectorVBus) && defined(TRACE_HAVE_USERCLIENT) && defined(TRACE_HAVE_PORT2_AUDIO)
// ── dext 143: VBus ──────────────────────────────────────────────────────────
// Assertions only: VBus writes no register, so there is no trace to record,
// and every existing golden trace is produced with VBus off.
static_assert(kSelectorVBus == 16 && (kSelectorCount == 17 || kSelectorCount == 18) && sizeof(SymphonyVBusInput) == 12 &&
              sizeof(SymphonyVBusStateOutput) == 16, "VBus is selector 16: three words in, four out");

static kern_return_t CallVBusRaw(Run &r, const void *bytes, size_t length, SymphonyVBusStateOutput *out = nullptr,
                                 uint64_t selector = kSelectorVBus, uint64_t outputSize = sizeof(SymphonyVBusStateOutput))
{
    auto *client = new SymphonyUserClient;
    client->init();
    client->SetDriver(r.drv);
    IOUserClientMethodArguments arguments;
    arguments.selector = selector;
    arguments.structureInput = length ? OSData::withBytes(bytes, length) : nullptr;
    arguments.structureOutputMaximumSize = outputSize;   // the app asks for the four state words
    const kern_return_t result = client->ExternalMethod(selector, &arguments, nullptr, nullptr, nullptr);
    if (out && arguments.structureOutput && arguments.structureOutput->getLength() == sizeof(*out))
        memcpy(out, arguments.structureOutput->getBytesNoCopy(), sizeof(*out));
    if (arguments.structureInput) arguments.structureInput->release();
    if (arguments.structureOutput) arguments.structureOutput->release();
    client->release();
    return result;
}

static kern_return_t CallVBus(Run &r, uint32_t operation, uint32_t channels, SymphonyVBusStateOutput *out = nullptr,
                              uint32_t magic = kSymphonyUCMagic)
{
    const SymphonyVBusInput input = { magic, operation, channels };
    return CallVBusRaw(r, &input, sizeof(input), out);
}

static SymphonyVBusStateOutput VBusState(Run &r)
{
    SymphonyVBusStateOutput s = { 99, 99, 99, 99 };
    CHECK(CallVBus(r, kSymphonyVBusOperationRead, 0, &s) == kIOReturnSuccess, "VBus: the state could not be read");
    return s;
}

// Lines since `mark` that are an access to the card, its configuration space
// or a DMA mapping.
static size_t CardAccessesSince(const FakeCard &c, size_t mark)
{
    size_t n = 0;
    for (size_t i = mark; i < c.lines.size(); i++) {
        const std::string &l = c.lines[i];
        if (l.compare(0, 2, "R ") == 0 || l.compare(0, 2, "W ") == 0 || l.compare(0, 2, "CR") == 0 ||
            l.compare(0, 2, "CW") == 0 || l.find("dma") != std::string::npos) n++;
    }
    return n;
}

// The app asks for a size; Core Audio performs the configuration change.
// With IO stopped, nothing between the request and the end of the change may
// touch the card (with IO running the stop and the start do, as for any
// configuration change). Returns the line the request started at.
static size_t VBusSet(const char *what, Run &r, uint32_t channels, bool ioRunning = false, bool expectChange = true)
{
    FakeCard &c = r.card;
    const size_t mark = c.lines.size();
    const uint32_t before = gHostAudio.configChangeRequests;
    SymphonyVBusStateOutput s = {};
    const kern_return_t rc = CallVBus(r, kSymphonyVBusOperationSet, channels, &s);
    CHECK(rc == kIOReturnSuccess, "%s: selector 16 refused %u channels (0x%x)", what, channels, rc);
    CHECK(s.requested == channels, "%s: the request reads back as %u (want %u)", what, s.requested, channels);
    HostPump();
    CHECK(CardAccessesSince(c, mark) == 0, "%s: asking for %u VBus channels touched the card", what, channels);
    CHECK((gHostAudio.configChangeRequests != before) == expectChange,
          "%s: %u configuration change request(s) for %u channels", what,
          gHostAudio.configChangeRequests - before, channels);
    if (gHostAudio.configChangeRequests != before) {
        CHECK(gHostAudio.lastConfigChangeAction == 0x56425553ull, "%s: configuration change action 0x%llx",
              what, (unsigned long long)gHostAudio.lastConfigChangeAction);
        const size_t perform = c.lines.size();
        HostPerformConfigChange(r, ioRunning);
        HostPump();
        if (!ioRunning)
            CHECK(CardAccessesSince(c, perform) == 0, "%s: publishing %u VBus channels touched the card", what, channels);
    }
    CHECK(gHostLocksHeld == 0, "%s: a lock is still held", what);
    return mark;
}

static IOUserAudioStream *VBusStream(bool input)
{
    for (size_t i = 2; i < gHostAudio.deviceStreams.size(); i++)
        if (gHostAudio.deviceStreams[i]->isInput() == input) return gHostAudio.deviceStreams[i];
    return nullptr;
}

// What the device publishes: `hw` hardware channels on the two hardware
// streams, exactly as without VBus, and `channels` VBus channels after them.
static void CheckVBusPublished(const char *what, Run &r, uint32_t channels, uint32_t hw)
{
    const SymphonyVBusStateOutput s = VBusState(r);
    CHECK(s.published == channels && s.requested == channels && s.flags == 0 &&
          s.firstChannel == (channels ? hw + 1 : 0),
          "%s: state published=%u requested=%u first=%u flags=0x%x (want %u after %u)", what,
          s.published, s.requested, s.firstChannel, s.flags, channels, hw);
    CHECK(gHostAudio.deviceStreams.size() == (channels ? 4u : 2u), "%s: %zu streams on the device", what,
          gHostAudio.deviceStreams.size());
    // The hardware streams are the first two, with their own format and buffer.
    CHECK(gHostAudio.deviceStreams.size() >= 2 && gHostAudio.deviceStreams[0] == gHostAudio.inStream &&
          gHostAudio.deviceStreams[1] == gHostAudio.outStream, "%s: the hardware streams are not first", what);
    for (IOUserAudioStream *st : { gHostAudio.inStream, gHostAudio.outStream }) {
        CHECK(st && st->current.mChannelsPerFrame == hw && st->current.mBytesPerFrame == hw * 4 &&
              st->current.mFormatFlags == (IOUserAudioFormatFlags)(0x4 | 0x8) && st->startingChannel == 1 &&
              st->memory && st->memory->size_ == (uint64_t)kNumSampleFrames * hw * 4,
              "%s: a hardware stream changed (%u channels, flags 0x%x, first channel %u)", what,
              st ? st->current.mChannelsPerFrame : 0, st ? (unsigned)st->current.mFormatFlags : 0,
              st ? st->startingChannel : 0);
    }
    if (!channels) {
        CHECK(VBusStream(true) == nullptr && VBusStream(false) == nullptr, "%s: a VBus stream is still published", what);
        return;
    }
    for (bool input : { false, true }) {
        IOUserAudioStream *st = VBusStream(input);
        CHECK(st != nullptr, "%s: no VBus %s stream", what, input ? "input" : "output");
        if (!st) continue;
        CHECK(st->current.mChannelsPerFrame == channels && st->current.mBytesPerFrame == channels * 4 &&
              st->current.mBytesPerPacket == channels * 4 && st->current.mFramesPerPacket == 1 &&
              st->current.mBitsPerChannel == 32 && st->current.mFormatFlags == (IOUserAudioFormatFlags)(0x1 | 0x8) &&
              st->current.mSampleRate == gHostAudio.device->GetSampleRate() && st->formatCount == 6,
              "%s: VBus %s format is %u channels, %u bytes/frame, %u bits, flags 0x%x, %.0f Hz, %u formats", what,
              input ? "input" : "output", st->current.mChannelsPerFrame, st->current.mBytesPerFrame,
              st->current.mBitsPerChannel, (unsigned)st->current.mFormatFlags, st->current.mSampleRate, st->formatCount);
        CHECK(st->startingChannel == hw + 1, "%s: VBus %s starts at channel %u (want %u)", what,
              input ? "input" : "output", st->startingChannel, hw + 1);
        CHECK(st->name == "VBus channels", "%s: VBus stream is named \"%s\"", what, st->name.c_str());
        // Exactly one ring of the format, and not a hardware stream's buffer.
        CHECK(st->memory && st->memory->size_ == (uint64_t)kNumSampleFrames * channels * 4 &&
              st->memory != gHostAudio.inStream->memory && st->memory != gHostAudio.outStream->memory,
              "%s: VBus %s buffer is %llu bytes", what, input ? "input" : "output",
              (unsigned long long)(st->memory ? st->memory->size_ : 0));
    }
    CHECK(VBusStream(true) && VBusStream(false) && VBusStream(true)->memory != VBusStream(false)->memory,
          "%s: the VBus streams share a buffer", what);
}

// The names the device has now (the last one set for each channel; a name
// that does not change is not set again): "VBout k" / "VBin k" at hw + k.
static void CheckVBusNames(const char *what, Run &r, size_t, uint32_t channels, uint32_t hw)
{
    const size_t mark = 0;
    for (uint32_t k = 1; k <= channels; k++) {
        char in[24], out[24];
        snprintf(in, sizeof(in), "VBin %u", k);
        snprintf(out, sizeof(out), "VBout %u", k);
        const std::string gotIn = LastElementName(r.card, mark, "in", hw + k);
        const std::string gotOut = LastElementName(r.card, mark, "out", hw + k);
        CHECK(gotIn == in && gotOut == out, "%s: channel %u is named \"%s\" / \"%s\" (want %s / %s)", what, hw + k,
              gotIn.c_str(), gotOut.c_str(), in, out);
    }
    // Nothing past the last VBus channel was named.
    CHECK(LastElementName(r.card, mark, "in", hw + channels + 1).find("VB") == std::string::npos &&
          LastElementName(r.card, mark, "out", hw + channels + 1).find("VB") == std::string::npos,
          "%s: a channel past the VBus channels has a VBus name", what);
}

static float VBusTag(uint64_t time, uint32_t ch) { return (float)((time % 100000) * 64 + ch) + 0.25f; }

struct VBusBuffers {
    float *out = nullptr, *in = nullptr;
    uint32_t channels = 0;
    IOOperationHandler handler = nullptr;
    VBusBuffers() {
        handler = (IOOperationHandler)gHostAudio.ioHandler;
        if (VBusStream(false) && VBusStream(true)) {
            out = (float *)VBusStream(false)->memory->mem_;
            in = (float *)VBusStream(true)->memory->mem_;
            channels = VBusStream(false)->current.mChannelsPerFrame;
        }
    }
    float &o(uint64_t t, uint32_t ch) { return out[(size_t)(t % kNumSampleFrames) * channels + ch]; }
    float &i(uint64_t t, uint32_t ch) { return in[(size_t)(t % kNumSampleFrames) * channels + ch]; }
    // An application plays `frames` frames at sample time `t`.
    void play(uint64_t t, uint32_t frames) {
        for (uint32_t n = 0; n < frames; n++)
            for (uint32_t ch = 0; ch < channels; ch++) o(t + n, ch) = VBusTag(t + n, ch);
        handler(1, IOUserAudioIOOperationWriteEnd, frames, t, 0);
    }
    // Stale memory everywhere: what a missing clear would let through.
    void poison() {
        for (size_t n = 0; n < (size_t)kNumSampleFrames * channels; n++) { out[n] = -7.5f; in[n] = -9.5f; }
    }
    void poisonInput() { for (size_t n = 0; n < (size_t)kNumSampleFrames * channels; n++) in[n] = -9.5f; }
    // An application records [t, t + frames): the count of samples that are
    // not the tag where [from, to) was played and not silence elsewhere.
    uint32_t record(uint64_t t, uint32_t frames, uint64_t from, uint64_t to) {
        handler(1, IOUserAudioIOOperationBeginRead, frames, t, 0);
        uint32_t bad = 0;
        for (uint32_t n = 0; n < frames; n++)
            for (uint32_t ch = 0; ch < channels; ch++) {
                const float want = (t + n >= from && t + n < to) ? VBusTag(t + n, ch) : 0.0f;
                const float got = i(t + n, ch);
                if (memcmp(&want, &got, sizeof(float)) != 0) bad++;
            }
        return bad;
    }
};

// The loopback in the IO handler, and the hardware copy next to it.
static void CheckVBusLoopback(const char *what, Run &r, uint32_t channels, uint32_t hw)
{
    VBusBuffers v;
    CHECK(v.handler && v.out && v.in && v.channels == channels, "%s: no IO handler or VBus buffers", what);
    if (!v.handler || !v.out || !v.in || v.channels != channels) return;
    const uint64_t ring = kNumSampleFrames;
    r.drv->StopDevice(1, IOUserAudioStartStopFlags::None);   // a fresh session: nothing written yet

    // Nothing has played: silence, whatever the memory holds.
    v.poison();
    CHECK(v.record(ring * 3 + 100, 512, 0, 0) == 0, "%s: VBus inputs are not silent when nothing plays", what);

    // Hardware buffers, to see that VBus leaves them alone. Creation order:
    // A2H, H2A, the 32-channel in/out stream buffers (see CheckIOHandler).
    const bool both = hw == 64;
    int32_t *a2h = (int32_t *)gHostAudio.buffers[0]->mem_, *h2a = (int32_t *)gHostAudio.buffers[1]->mem_;
    int32_t *hwIn = (int32_t *)gHostAudio.inStream->memory->mem_, *hwOut = (int32_t *)gHostAudio.outStream->memory->mem_;
    const uint64_t t = ring * 9 - 200;   // wraps the end of the ring
    const uint32_t frames = 512;
    memset(h2a, 0, ring * 128);
    memset(hwIn, 0, (size_t)ring * hw * 4);
    for (uint32_t n = 0; n < frames; n++)
        for (uint32_t ch = 0; ch < 32; ch++) {
            hwOut[(size_t)((t + n) % ring) * hw + ch] = (int32_t)(0x10000000u | (((t + n) % ring) << 8) | ch);
            a2h[(size_t)((t + n) % ring) * 32 + ch] = (int32_t)(0x20000000u | (((t + n) % ring) << 8) | ch);
        }
    v.poisonInput();
    v.play(t, frames);
    // Sample-accurate, bit-exact, channel k to channel k, across the wrap.
    CHECK(v.record(t, frames, t, t + frames) == 0, "%s: what was played to the VBus outputs is not what is recorded", what);
    // The output buffer itself is not altered by the read.
    uint32_t bad = 0;
    for (uint32_t n = 0; n < frames; n++)
        for (uint32_t ch = 0; ch < channels; ch++) if (v.o(t + n, ch) != VBusTag(t + n, ch)) bad++;
    CHECK(bad == 0, "%s: reading the VBus inputs changed the VBus output buffer", what);
    // Hardware: channels 1-32 went to and came from port 1's DMA buffers.
    bad = 0;
    for (uint32_t n = 0; n < frames; n++) {
        const uint32_t f = (uint32_t)((t + n) % ring);
        for (uint32_t ch = 0; ch < 32; ch++) {
            if (h2a[(size_t)f * 32 + ch] != (int32_t)(0x10000000u | (f << 8) | ch)) bad++;
            if (hwIn[(size_t)f * hw + ch] != (int32_t)(0x20000000u | (f << 8) | ch)) bad++;
        }
    }
    CHECK(bad == 0, "%s: the hardware channels were not copied as without VBus (%u samples)", what, bad);
    (void)both;

    // A read that starts before and ends after what was played: silence on
    // both sides, although the buffers hold other memory there.
    v.poisonInput();
    CHECK(v.record(t - 100, frames + 200, t, t + frames) == 0, "%s: a read past what was played is not silence", what);

    // One lap later nothing new was played: the same ring positions must not
    // be heard again.
    v.poisonInput();
    CHECK(v.record(t + ring, frames, 0, 0) == 0, "%s: audio is repeated one ring later", what);

    // A gap in what the host wrote is silence, not the previous lap.
    const uint64_t g = ring * 20 + 64;
    v.poison();
    v.play(g, 100);
    v.play(g + 300, 100);
    {
        v.handler(1, IOUserAudioIOOperationBeginRead, 400, g, 0);
        uint32_t wrong = 0;
        for (uint32_t n = 0; n < 400; n++)
            for (uint32_t ch = 0; ch < channels; ch++) {
                const bool played = n < 100 || n >= 300;
                const float want = played ? VBusTag(g + n, ch) : 0.0f;
                if (v.i(g + n, ch) != want) wrong++;
            }
        CHECK(wrong == 0, "%s: a gap between two writes is not silence (%u samples)", what, wrong);
    }

    // More than a ring played without a pause: a sample time whose position
    // has since been written again for a later time, or cleared for the next
    // cycle, is silence, not the later audio; the rest of the newest ring is
    // still read exactly.
    {
        const uint64_t l = ring * 24;
        for (uint64_t at = l; at < l + ring + 2048; at += 1024) v.play(at, 1024);
        v.poisonInput();
        CHECK(v.record(l, 512, 0, 0) == 0 && v.record(l + 2048, 1024, 0, 0) == 0,
              "%s: a sample time overwritten a ring later is not silence", what);
        CHECK(v.record(l + 3072, 1024, l + 3072, l + ring + 2048) == 0 &&
              v.record(l + ring + 1024, 1024, l + 3072, l + ring + 2048) == 0,
              "%s: the newest ring of VBus audio is not read back exactly", what);
        // The host reports cycles it did not write (WriteEnd, the buffer left
        // as it was, which here still holds the audio of a ring ago): silence.
        const uint64_t e = l + ring + 2048;
        for (uint32_t k = 0; k < 4; k++) v.handler(1, IOUserAudioIOOperationWriteEnd, 512, e + k * 512, 0);
        v.poisonInput();
        CHECK(v.record(e, 4 * 512, 0, 0) == 0, "%s: a cycle the host did not write is not silence on VBin", what);
        // And playing again after them is read exactly.
        v.play(e + 4 * 512, 512);
        CHECK(v.record(e + 4 * 512, 512, e + 4 * 512, e + 5 * 512) == 0,
              "%s: audio after cycles the host did not write is not read back", what);
    }

    // IO stops and starts again: nothing of the last session is recorded.
    v.play(ring * 30, 256);
    r.drv->StopDevice(1, IOUserAudioStartStopFlags::None);
    v.poisonInput();
    CHECK(v.record(ring * 30, 256, 0, 0) == 0, "%s: audio from before IO stopped is recorded after it", what);
    // The same when only a start is seen (the sample time begins at 0 again).
    v.play(100, 256);
    CHECK(r.drv->StartDevice(1, IOUserAudioStartStopFlags::None) == kIOReturnSuccess, "%s: IO did not start", what);
    v.poison();
    CHECK(v.record(100, 256, 0, 0) == 0, "%s: audio from before IO started is recorded after it", what);
    r.drv->StopDevice(1, IOUserAudioStartStopFlags::None);
    // A previous session's audio is still in the output ring; IO starts, and
    // the host's first cycles are reported without being written: silence.
    // Both rings are silence from the moment IO starts.
    v.play(100, 256);
    r.drv->StopDevice(1, IOUserAudioStartStopFlags::None);
    v.poisonInput();
    CHECK(r.drv->StartDevice(1, IOUserAudioStartStopFlags::None) == kIOReturnSuccess, "%s: IO did not start", what);
    bad = 0;
    for (size_t n = 0; n < (size_t)ring * channels; n++) if (v.out[n] != 0.0f || v.in[n] != 0.0f) bad++;
    CHECK(bad == 0, "%s: the VBus rings are not silence when IO starts (%u samples)", what, bad);
    v.handler(1, IOUserAudioIOOperationWriteEnd, 256, 100, 0);
    v.poisonInput();
    CHECK(v.record(100, 256, 0, 0) == 0, "%s: a previous IO session's audio reappears after StartDevice", what);
    r.drv->StopDevice(1, IOUserAudioStartStopFlags::None);
}

static void CheckVBusSelector(const char *name, Run &r)
{
    const SymphonyVBusStateOutput before = VBusState(r);
    const uint32_t requests = gHostAudio.configChangeRequests;
    const size_t streams = gHostAudio.deviceStreams.size();
    const size_t mark = r.card.lines.size();
    const uint32_t words[4] = { kSymphonyUCMagic, kSymphonyVBusOperationSet, 8, 0 };
    CHECK(CallVBusRaw(r, words, 8) == kIOReturnBadArgument, "%s: selector 16 took an 8-byte input", name);
    CHECK(CallVBusRaw(r, words, 16) == kIOReturnBadArgument, "%s: selector 16 took a 16-byte input", name);
    CHECK(CallVBusRaw(r, nullptr, 0) == kIOReturnBadArgument, "%s: selector 16 took no input", name);
    CHECK(CallVBus(r, kSymphonyVBusOperationSet, 8, nullptr, 0x12345678u) == kIOReturnBadArgument,
          "%s: selector 16 took a bad magic", name);
    CHECK(CallVBus(r, 2, 8) == kIOReturnBadArgument, "%s: selector 16 took operation 2", name);
    CHECK(CallVBusRaw(r, words, 12, nullptr, kSelectorVBus, 0) == kIOReturnBadArgument &&
          CallVBusRaw(r, words, 12, nullptr, kSelectorVBus, 12) == kIOReturnBadArgument,
          "%s: selector 16 took a wrong output size", name);
    for (uint32_t n : { 1u, 3u, 6u, 12u, 24u, 33u, 65u, 80u, 96u, 128u, 0xFFFFFFFFu })
        CHECK(CallVBus(r, kSymphonyVBusOperationSet, n) == kIOReturnBadArgument, "%s: selector 16 took %u channels", name, n);
    CHECK(CallVBusRaw(r, words, 12, nullptr, kSelectorCount) == kIOReturnBadArgument, "%s: a selector past the table was taken", name);
    HostPump();
    const SymphonyVBusStateOutput after = VBusState(r);
    CHECK(memcmp(&before, &after, sizeof(before)) == 0 && gHostAudio.configChangeRequests == requests &&
          gHostAudio.deviceStreams.size() == streams && CardAccessesSince(r.card, mark) == 0,
          "%s: a refused selector 16 call changed something", name);
    for (uint32_t n : { 0u, 2u, 4u, 8u, 16u, 32u, 48u, 64u })
        CHECK(SymphonyVBusChannelsValid(n), "%s: %u channels is not offered", name, n);
}

static void RunVBusChecks()
{
    static const uint32_t sizes[] = { 2, 4, 8, 16, 32, 48, 64 };
    struct { const char *name; Port::Kind port1; bool legacy; int portCount; } setups[] = {
        { "VBus, Symphony I/O, one-port build", Port::Symphony, false, -1 },
        { "VBus, Symphony I/O, two-port build at 32", Port::Symphony, false, 2 },
        { "VBus, converters", Port::Converters, false, 2 },
        { "VBus, Symphony 64 PCIe card", Port::Symphony, true, 2 },
    };
    for (auto &setup : setups) {
        Options o; o.name = setup.name; o.shortFlow = true; o.port1 = setup.port1;
        o.legacy2100 = setup.legacy; o.portCountProperty = setup.portCount;
        Run r;
        RunScenario(o, r);
        // Off by default: the device is as without VBus, and the IO handler
        // does the hardware copy only.
        CheckVBusPublished(o.name, r, 0, 32);
        CHECK(r.card.count("H device-add-stream") == 2, "%s: %zu streams added at Start (want 2)", o.name,
              r.card.count("H device-add-stream"));
        CheckVBusSelector(o.name, r);
        // None while none is published: nothing to do.
        VBusSet(o.name, r, 0, false, /*expectChange*/false);
        for (uint32_t n : sizes) {
            char what[96];
            snprintf(what, sizeof(what), "%s, %u channels", o.name, n);
            const size_t mark = VBusSet(what, r, n);
            CheckVBusPublished(what, r, n, 32);
            CheckVBusNames(what, r, mark, n, 32);
            r.drv->StartDevice(1, IOUserAudioStartStopFlags::None);
            Irq(r, 1);
            CheckVBusLoopback(what, r, n, 32);
            // The same size again: no configuration change.
            VBusSet(what, r, n, false, /*expectChange*/false);
        }
        const void *old64[2] = {}, *old8[2] = {};
        const size_t liveAt64 = gLiveBuffers.size();   // 64 in use, 48 retired
        // 64 -> 8 with a client streaming: the old pair is gone, the new
        // buffers are silent, and what was played at 64 is not recorded at 8.
        {
            r.drv->StartDevice(1, IOUserAudioStartStopFlags::None);
            Irq(r, 1);
            VBusBuffers big;
            old64[0] = VBusStream(false)->memory; old64[1] = VBusStream(true)->memory;
            const uint64_t t = (uint64_t)kNumSampleFrames * 40 + 10;
            big.play(t, 300);
            const uint32_t removed = gHostAudio.streamsRemoved;
            const size_t mark = VBusSet("VBus 64 -> 8 while streaming", r, 8, /*ioRunning*/true);
            CHECK(gHostAudio.streamsRemoved == removed + 2, "%s: the 64-channel pair was not removed (%u)", o.name,
                  gHostAudio.streamsRemoved - removed);
            CheckVBusPublished("VBus 64 -> 8 while streaming", r, 8, 32);
            CheckVBusNames("VBus 64 -> 8 while streaming", r, mark, 8, 32);
            for (uint32_t ch : { 41u, 49u, 96u }) {   // VBus channels 9, 17 and 64 are gone
                CHECK(LastElementName(r.card, 0, "in", ch) == "(none)" && LastElementName(r.card, 0, "out", ch) == "(none)",
                      "%s: channel %u kept its VBus name after 64 -> 8", o.name, ch);
            }
            // The 64-channel buffers are retired, not freed: an IO callback
            // that was still running on them cannot touch freed memory. The
            // generation before them (48 channels) is gone: one is kept.
            CHECK(HostBufferAlive(old64[0]) && HostBufferAlive(old64[1]),
                  "%s: the replaced VBus buffers were freed inside the configuration change", o.name);
            CHECK(gLiveBuffers.size() == liveAt64, "%s: %zu buffers alive after 64 -> 8 (want %zu: one retired generation)",
                  o.name, gLiveBuffers.size(), liveAt64);
            old8[0] = VBusStream(false)->memory; old8[1] = VBusStream(true)->memory;
            big.handler(1, IOUserAudioIOOperationBeginRead, 64, t, 0);   // the new generation is what IO uses
            VBusBuffers small;
            uint32_t nonzero = 0;
            for (size_t n = 0; n < (size_t)kNumSampleFrames * 8; n++) if (small.out[n] != 0.0f || small.in[n] != 0.0f) nonzero++;
            CHECK(nonzero == 0, "%s: the new VBus buffers are not silent (%u samples)", o.name, nonzero);
            small.poison();
            CHECK(small.record(t, 300, 0, 0) == 0, "%s: audio played before the size change is recorded after it", o.name);
            CheckVBusLoopback("VBus 8 after 64", r, 8, 32);
        }
        // A rate change's own configuration change leaves VBus alone, and the
        // card is recovered with VBus on.
        {
            const uint32_t removed = gHostAudio.streamsRemoved;
            const size_t added = r.card.count("H device-add-stream");
            HostPerformConfigChange(r, false);
            const uint32_t requests = gHostAudio.configChangeRequests;
            ResetCardAndRecover(r);
            if (gHostAudio.configChangeRequests != requests) HostPerformConfigChange(r, false);
            HostPump();
            r.drv->SetPowerState(kIOServicePowerCapabilityOff);   // sleep
            r.drv->SetPowerState(kIOServicePowerCapabilityOn);    // wake
            r.drv->LinkWatchTimerOccurred(nullptr, 0); HostPump();
            r.drv->LinkWatchTimerOccurred(nullptr, 0); HostPump();
            HostPerformConfigChange(r, false);
            HostPump();
            CHECK(gHostAudio.streamsRemoved == removed && r.card.count("H device-add-stream") == added,
                  "%s: a recovery or a wake republished the VBus streams", o.name);
            CheckVBusPublished("VBus after a card reset and a wake", r, 8, 32);
            if (r.drv->StartDevice(1, IOUserAudioStartStopFlags::None) == kIOReturnSuccess) {
                Irq(r, 1);
                CheckVBusLoopback("VBus after a card reset and a wake", r, 8, 32);
            } else {
                CHECK(false, "%s: IO did not start after the recovery", o.name);
            }
        }
        // Disabled mid-session: the pair and its names are gone and the IO
        // handler does the hardware copy alone.
        {
            r.drv->StartDevice(1, IOUserAudioStartStopFlags::None);
            Irq(r, 1);
            const size_t mark = VBusSet("VBus off while streaming", r, 0, /*ioRunning*/true);
            CheckVBusPublished("VBus off while streaming", r, 0, 32);
            // One change later the 64-channel buffers are freed, and the
            // 8-channel ones are the retired generation.
            CHECK(!HostBufferAlive(old64[0]) && !HostBufferAlive(old64[1]),
                  "%s: buffers retired two changes ago are still alive", o.name);
            CHECK(HostBufferAlive(old8[0]) && HostBufferAlive(old8[1]),
                  "%s: the buffers just replaced were freed at once", o.name);
            for (uint32_t ch = 33; ch <= 40; ch++)
                CHECK(LastElementName(r.card, 0, "in", ch) == "(none)" && LastElementName(r.card, 0, "out", ch) == "(none)",
                      "%s: channel %u kept its VBus name after VBus was turned off", o.name, ch);
            auto handler = (IOOperationHandler)gHostAudio.ioHandler;
            int32_t *h2a = (int32_t *)gHostAudio.buffers[1]->mem_, *hwOut = (int32_t *)gHostAudio.outStream->memory->mem_;
            hwOut[5 * 32 + 3] = 0x1234500;
            handler(1, IOUserAudioIOOperationWriteEnd, 64, (uint64_t)kNumSampleFrames * 50, 0);
            handler(1, IOUserAudioIOOperationBeginRead, 64, (uint64_t)kNumSampleFrames * 50, 0);
            CHECK(h2a[5 * 32 + 3] == 0x1234500, "%s: the hardware copy stopped when VBus was turned off", o.name);
        }
        // A size that cannot be published leaves the device without VBus and says so.
        for (int succeed : { 0, 1 }) {   // the output stream is refused, then the input stream
            const size_t liveBefore = gLiveBuffers.size();
            gHostAudio.failAddStreamAfter = succeed;
            SymphonyVBusStateOutput s = {};
            CHECK(CallVBus(r, kSymphonyVBusOperationSet, 16, &s) == kIOReturnSuccess, "%s: 16 refused", o.name);
            HostPump();
            HostPerformConfigChange(r, true);
            s = VBusState(r);
            CHECK(s.published == 0 && s.requested == 0 && (s.flags & kSymphonyVBusFlagPublishFailed) &&
                  gHostAudio.deviceStreams.size() == 2 && gHostLocksHeld == 0,
                  "%s: a failed publication left published=%u requested=%u flags=0x%x streams=%zu", o.name,
                  s.published, s.requested, s.flags, gHostAudio.deviceStreams.size());
            CHECK(gLiveBuffers.size() == liveBefore, "%s: a failed publication left %zu buffers (was %zu)", o.name,
                  gLiveBuffers.size(), liveBefore);
            HostPerformConfigChange(r, true);   // and is not tried again by itself
            CHECK(VBusState(r).published == 0, "%s: a failed size was published by a later configuration change", o.name);
        }
        // Teardown with VBus on.
        VBusSet("VBus 16 before Stop", r, 16, /*ioRunning*/true);
        CheckVBusPublished("VBus 16 before Stop", r, 16, 32);
        const void *last16[2] = { VBusStream(false)->memory, VBusStream(true)->memory };
        const uint32_t underLock = gHostAudio.streamsRemovedUnderLock;
        const uint32_t removedBefore = gHostAudio.streamsRemoved;
        const size_t stop = r.card.lines.size();
        Finish(o, r);
        CHECK(gHostAudio.deviceStreams.empty(), "%s: %zu stream(s) still on the device after Stop", o.name,
              gHostAudio.deviceStreams.size());
        // Stop() takes the VBus streams off the device before it takes the
        // publish lock, like the hardware streams, and frees every VBus
        // buffer, the retired generation included.
        CHECK(gHostAudio.streamsRemoved == removedBefore + 4 && gHostAudio.streamsRemovedUnderLock == underLock,
              "%s: Stop removed %u streams, %u of them while holding the publish lock", o.name,
              gHostAudio.streamsRemoved - removedBefore, gHostAudio.streamsRemovedUnderLock - underLock);
        CHECK(!HostBufferAlive(old8[0]) && !HostBufferAlive(old8[1]) &&
              !HostBufferAlive(last16[0]) && !HostBufferAlive(last16[1]),
              "%s: a VBus buffer is still alive after Stop", o.name);
        CHECK(gHostLocksHeld == 0, "%s: a lock is still held after Stop", o.name);
        (void)stop;
    }

    // Ports 32 <-> 64 with VBus on: the VBus channels follow the hardware
    // channels (33-40, then 65-72, then 33-40 again).
    for (Port::Kind port2 : { Port::Converters, Port::Symphony }) {
        Options o; o.name = port2 == Port::Symphony ? "VBus with two Symphony I/Os" : "VBus with converters on port 2";
        o.shortFlow = true; o.port2 = port2; o.portCountProperty = 2;
        Run r;
        RunScenario(o, r);
        r.drv->StartDevice(1, IOUserAudioStartStopFlags::None);
        Irq(r, 1);
        VBusSet(o.name, r, 8, /*ioRunning*/true);
        CheckVBusPublished(o.name, r, 8, 32);
        // Played after the last StopDevice the driver saw: the move itself
        // must clear it (it is at other channels afterwards).
        r.drv->StopDevice(1, IOUserAudioStartStopFlags::None);
        {
            VBusBuffers v;
            v.play((uint64_t)kNumSampleFrames * 4, 128);
        }
        const uint32_t removed = gHostAudio.streamsRemoved;
        size_t mark = Select(r, 1, "VBus on: select Port 1-2: 64ch", /*ioRunning*/false);
        HostPump();
        CheckPublished("VBus on at 64", 64);
        CheckVBusPublished("VBus on at 64", r, 8, 64);
        CheckVBusNames("VBus on at 64", r, mark, 8, 64);
        CHECK(gHostAudio.streamsRemoved == removed, "%s: the port change replaced the VBus streams", o.name);
        for (uint32_t ch = 33; ch <= 40; ch++)
            CHECK(LastElementName(r.card, 0, "in", ch).find("VB") == std::string::npos &&
                  LastElementName(r.card, 0, "out", ch).find("VB") == std::string::npos &&
                  !LastElementName(r.card, 0, "out", ch).empty(),
                  "%s: channel %u still has a VBus name at 64 (\"%s\")", o.name, ch,
                  LastElementName(r.card, 0, "out", ch).c_str());
        {
            VBusBuffers v;
            v.poisonInput();
            CHECK(v.record((uint64_t)kNumSampleFrames * 4, 128, 0, 0) == 0,
                  "%s: audio played before the port change is recorded after it", o.name);
        }
        r.drv->StartDevice(1, IOUserAudioStartStopFlags::None);
        Irq(r, 1);
        CheckIOHandler("VBus on at 64", 64);   // the 64-channel hardware copy, unchanged
        CheckVBusLoopback("VBus on at 64", r, 8, 64);
        // A size change at 64.
        r.drv->StartDevice(1, IOUserAudioStartStopFlags::None);
        Irq(r, 1);
        mark = VBusSet("VBus 8 -> 64 at 64", r, 64, /*ioRunning*/true);
        CheckVBusPublished("VBus 64 at 64", r, 64, 64);
        CheckVBusNames("VBus 64 at 64", r, mark, 64, 64);
        CheckVBusLoopback("VBus 64 at 64", r, 64, 64);
        r.drv->StartDevice(1, IOUserAudioStartStopFlags::None);
        Irq(r, 1);
        VBusSet("VBus 64 -> 8 at 64", r, 8, /*ioRunning*/true);
        mark = Select(r, 0, "VBus on: select Port 1: 32ch", /*ioRunning*/true);
        HostPump();
        CheckPublished("VBus on, back at 32", 32);
        CheckVBusPublished("VBus on, back at 32", r, 8, 32);
        CheckVBusNames("VBus on, back at 32", r, mark, 8, 32);
        for (uint32_t ch = 65; ch <= 72; ch++)
            CHECK(LastElementName(r.card, 0, "in", ch) == "(none)" && LastElementName(r.card, 0, "out", ch) == "(none)",
                  "%s: channel %u kept its VBus name back at 32", o.name, ch);
        CheckIOHandler("VBus on, back at 32", 32);
        CheckVBusLoopback("VBus on, back at 32", r, 8, 32);
        Finish(o, r);
        CHECK(gHostAudio.deviceStreams.empty() && gHostLocksHeld == 0, "%s: teardown left a stream or a lock", o.name);
    }
}
#endif

// D1 + D2: replies up to 80 bytes, and each reply taken only for its own read.
static void RunReplyMatching()
{
    Options o; o.name = "reply matching"; o.shortFlow = true;
    Run r;
    RunScenario(o, r);
    auto &unit = r.card.port[0];
    // A 64-byte read (a 72-byte reply frame) is accepted and returns its bytes.
    std::vector<uint8_t> meters(64);
    for (int i = 0; i < 64; i++) meters[i] = (uint8_t)(i + 1);
    unit.stored[(uint64_t(0x30) << 32) | 1] = meters;
    uint8_t out[64] = {};
    CHECK(r.drv->ReadVendorCommand(0x30, 1, out, 64) == kIOReturnSuccess, "D1: 64-byte read accepted");
    CHECK(!memcmp(out, meters.data(), 64), "D1: 64-byte read returns the unit's bytes");
    // A late 72-byte meter reply arriving while a 12-byte 0x28 read waits is
    // skipped, and the 0x28 reply that follows is taken.
    std::vector<uint8_t> panel = {0,0,172,68,1,0,0,2,2,29,1,0};
    unit.stored[(uint64_t(0x28) << 32) | 1] = panel;
    unit.staleReplies.push_back({0x30, 1, 64});
    uint8_t obs[12] = {};
    CHECK(r.drv->ReadVendorCommand(0x28, 1, obs, 12) == kIOReturnSuccess, "D2: 0x28 read after a stale meter reply");
    CHECK(!memcmp(obs, panel.data(), 12), "D2: the stale meter reply was not taken for 0x28");
    // nValue is matched for 0x30: a group-0 reply is not the answer to group 1.
    unit.staleReplies.push_back({0x30, 0, 64});
    memset(out, 0, sizeof(out));
    CHECK(r.drv->ReadVendorCommand(0x30, 1, out, 64) == kIOReturnSuccess, "D2: 0x30 group 1 after a group 0 reply");
    CHECK(!memcmp(out, meters.data(), 64), "D2: group 0's reply was not taken for group 1");
    // ...and for the headphones: HP 0's reply is not HP 1's.
    unit.stored[(uint64_t(0x23) << 32) | 1] = {33};
    unit.staleReplies.push_back({0x23, 0, 1});
    uint8_t hp = 0;
    CHECK(r.drv->ReadVendorCommand(0x23, 1, &hp, 1) == kIOReturnSuccess && hp == 33, "D2: HP 1 level not taken from HP 0's reply");
    // A command outside the table takes a reply with another nValue.
    unit.stored[(uint64_t(0xE9) << 32) | 0] = {2};
    unit.noEcho = false;
    uint8_t set = 0;
    CHECK(r.drv->ReadVendorCommand(0xE9, 0, &set, 1) == kIOReturnSuccess && set == 2, "D2: plain read still works");
    // A unit that does not echo its request: three timeouts, then the old rule.
    unit.noEcho = true;
    for (int i = 0; i < 3; i++) {
        uint8_t v = 0;
        CHECK(r.drv->ReadVendorCommand(0x37, 0, &v, 1) != kIOReturnSuccess, "D2: a non-echoing reply is not taken (%d)", i);
    }
    uint8_t v = 0;
    CHECK(r.drv->ReadVendorCommand(0x37, 0, &v, 1) == kIOReturnSuccess, "D2: after three timeouts the command falls back");
    unit.noEcho = false;
}

// D5 (A1, driver part): a speaker level read in Line is never taken or sent.
static void RunLineSpeakerLevel()
{
    Options o; o.name = "Line speaker level"; o.shortFlow = true;
    Run r;
    RunScenario(o, r);
    auto &unit = r.card.port[0];
    unit.lineFirmware = true;
    unit.stored[(uint64_t)0x26 << 32] = {35};   // the speakers' own level: -35 dB
    unit.stored[(uint64_t)0x27 << 32] = {0};
    uint8_t line = 0, stereo = 2;
    CHECK(r.drv->SendVendorCommand(0x25, 0, &line, 1) == kIOReturnSuccess, "D5: Line");
    // A link recovery in Line sends no speaker level or mute.
    const size_t writes = unit.vendorWrites.size();
    Port saved = unit;
    r.card.port[0] = Port();
    r.drv->LinkWatchTimerOccurred(nullptr, 0); HostPump();
    r.card.port[0] = saved;
    r.drv->LinkWatchTimerOccurred(nullptr, 0); HostPump();
    bool speakerSent = false;
    for (size_t i = writes; i < r.card.port[0].vendorWrites.size(); i++)
        if (r.card.port[0].vendorWrites[i] == 0x26 || r.card.port[0].vendorWrites[i] == 0x27) speakerSent = true;
    CHECK(!speakerSent, "D5: a link recovery in Line sent a speaker level or mute");
    // Leaving Line: the speakers' level is the unit's own, not the 0 read in Line.
    CHECK(r.drv->SendVendorCommand(0x25, 0, &stereo, 1) == kIOReturnSuccess, "D5: Stereo");
    HostPump();
    CHECK(StoredVendor(r, 0x26) == 35, "D5: the speakers' level after Line is %u (want 35)", StoredVendor(r, 0x26));
}

// B2-B5: the card mixer's gain as the original computed it.
static void RunMixerMaths()
{
    // The app's channel ids (SymphonyThunderbridge.cpp kMixerChSwReturn / kMixerChMaster).
    const uint16_t kMixerChSwReturn = 1000, kMixerChMaster = 2000;
    Options o; o.name = "mixer maths"; o.shortFlow = true;
    Run r;
    RunScenario(o, r);
    auto send = [&](uint8_t cmd, uint16_t ch, uint8_t v) {
        r.drv->SendVendorCommand(cmd, (1u << 16) | ch, &v, 1);
    };
    auto L = [&](int c) { return r.card.reg[MixerCoefOffset(0, c)]; };
    auto R = [&](int c) { return r.card.reg[MixerCoefOffset(1, c)]; };
    const uint32_t retL = MixerCoefOffset(0, 128), retR = MixerCoefOffset(1, 129);
    send(0xB3, 0, 0);                 // strip 1 unmuted
    send(0xB1, 0, 64);                // centred
    send(0xB0, 0, 48);                // 0 dB
    send(0xB0, kMixerChMaster, 48);   // Master 0 dB
    send(0xB0, kMixerChSwReturn, 48); // Software Return 0 dB
    CHECK(L(0) == 0x16A00000u && R(0) == 0x16A00000u, "B4: centred strip -3.01 dB per side (0x%08x 0x%08x)", L(0), R(0));
    CHECK(r.card.reg[retL] == 0x20000000u, "return at unity (0x%08x)", r.card.reg[retL]);
    send(0xB1, 0, 0);                 // hard left
    CHECK(L(0) == 0x20000000u && R(0) == 0, "B4: hard left: 0 dB left, right off (0x%08x 0x%08x)", L(0), R(0));
    send(0xB1, 0, 64);
    send(0xB0, kMixerChMaster, 36);   // Master -12 dB
    CHECK(L(0) == SymphonyMixerCoef(-12, 64), "B2: Master turns the inputs down (0x%08x)", L(0));
    CHECK(r.card.reg[retL] == SymphonyMixerCoef(-12, 128), "B2: and the return (0x%08x)", r.card.reg[retL]);
    send(0xB0, kMixerChMaster, 54);   // Master +6
    send(0xB0, 0, 54);                // strip +6
    CHECK(L(0) == SymphonyMixerCoef(12, 64) && L(0) != SymphonyMixerCoef(0, 64),
          "B3: +6 on strip and Master plays +12 (0x%08x)", L(0));
    send(0xB0, 0, 0);                 // fader at the bottom
    CHECK(L(0) == 0 && R(0) == 0, "B5: a fader at the bottom is off (0x%08x)", L(0));
    send(0xB0, 0, 48);
    send(0xB0, kMixerChMaster, 0);    // Master at the bottom
    CHECK(L(0) == 0 && r.card.reg[retL] == 0 && r.card.reg[retR] == 0, "B5: Master at the bottom silences inputs and return");
    send(0xB0, kMixerChMaster, 48);
    send(0xB3, kMixerChMaster, 1);    // Master mute (ours)
    CHECK(L(0) == 0 && R(0) == 0 && r.card.reg[retL] == 0, "Q7: Master mute silences inputs too");
    send(0xB3, kMixerChMaster, 0);
    send(0xB1, kMixerChSwReturn, 0);  // a return pan byte changes nothing
    CHECK(r.card.reg[retL] == 0x20000000u && r.card.reg[retR] == 0x20000000u, "the return has no pan");
}

#ifdef kSelectorReadChannelOrder
// ── dext 150: the applied host channel order (selector 17) ──────────────────
// Review M1: unit A's tables are built from the 0xA1 read at step 19b, and
// Start and link recovery read the types again afterwards (optionBoardType,
// ReadBoardTypes). When one of those reads fails and the other answers, the
// names must still describe the tables programmed; both follow the latch
// selector 17 reports. Review m5: a configuration with a failed 0x31 send
// keeps the previous latch, and the names with it. Unit B is latched at its
// set-up and None otherwise. Assertions only: in every recorded trace both
// reads answer the same types, and there nothing changes.
static SymphonyChannelOrderOutput ChannelOrder(Run &r)
{
    SymphonyChannelOrderOutput o = {};
    CHECK(r.drv->ReadChannelOrder(reinterpret_cast<uint32_t *>(&o)) == kIOReturnSuccess, "ReadChannelOrder failed");
    return o;
}

// The four 0x31 payloads a unit's configuration sends for these types:
// playback board 0, playback board 1, capture P2P 0-15, capture P2P 16-31.
static std::vector<std::vector<uint8_t>> ExpectedRouting(const uint8_t type[2], const bool known[2])
{
    std::vector<std::vector<uint8_t>> v;
    for (unsigned board = 0; board < 2; board++) {
        std::vector<uint8_t> w;
        for (unsigned n = 0; n < 16; n++) {
            w.push_back((uint8_t)((board ? kSymphonyRoutingDestIOBoard1 : kSymphonyRoutingDestIOBoard0) + n));
            w.push_back(SymphonyPlaybackSource(type, known, board, n));
        }
        v.push_back(w);
    }
    for (unsigned half = 0; half < 2; half++) {
        std::vector<uint8_t> w;
        for (unsigned n = 0; n < 16; n++) {
            w.push_back((uint8_t)(kSymphonyRoutingDestP2P0 + half * 16 + n));
            w.push_back(SymphonyCaptureSource(type, known, half * 16 + n));
        }
        v.push_back(w);
    }
    return v;
}

static std::string NameNow(const FakeCard &c, const char *dir, unsigned ch)
{
    const std::string n = LastElementName(c, 0, dir, ch);
    return n == "(none)" ? std::string() : n;
}

// Selector 17's answer for one unit agrees with itself and with what the
// driver did: the order follows from the types; the unit's last four 0x31
// payloads (when `tables`) are the ones those types build; and each of its
// 32 input and output names is what those types name (44.1 kHz ADAT, no
// Replaces, the unit's prefix letter).
static void CheckOrderAgrees(Run &r, unsigned unit, const char *what, bool tables, char prefix)
{
    const SymphonyChannelOrderOutput o = ChannelOrder(r);
    const SymphonyChannelOrderUnit &u = o.unit[unit];
    const uint8_t type[2] = { u.boardType[0], u.boardType[1] };
    const bool known[2] = { u.boardKnown[0] != 0, u.boardKnown[1] != 0 };
    CHECK(o.status == 0, "%s: status %u", what, o.status);
    CHECK(u.order == (SymphonyAnalogFirstApplies(type, known) ? kSymphonyChannelOrderAnalogFirst
                                                              : kSymphonyChannelOrderCardByCard),
          "%s: order %u does not follow from types %u/%u known %u/%u", what, u.order, type[0], type[1],
          known[0], known[1]);
    if (tables) {
        const auto &w = r.card.port[unit].routingWrites;
        const auto want = ExpectedRouting(type, known);
        CHECK(w.size() >= 4 && std::equal(want.begin(), want.end(), w.end() - 4),
              "%s: the last four 0x31 payloads are not the tables of types %u/%u known %u/%u (%zu sent)",
              what, type[0], type[1], known[0], known[1], w.size());
    }
    SymphonyNamingState s = {};
    for (unsigned b = 0; b < 2; b++) { s.boardType[b] = type[b]; s.boardKnown[b] = known[b]; }
    s.sampleRate = 44100;
    s.prefix = (uint8_t)prefix;
    for (unsigned n = 0; n < 32; n++) {
        const unsigned ch = unit * 32 + n + 1;
        char want[24] = {};
        if (!SymphonyHostOutputName(s, n, want, sizeof(want))) want[0] = 0;
        CHECK(NameNow(r.card, "out", ch) == want, "%s: output %u is \"%s\", its table entry is \"%s\"",
              what, ch, NameNow(r.card, "out", ch).c_str(), want);
        if (!SymphonyHostInputName(s, SymphonyCaptureSource(type, known, n), want, sizeof(want))) want[0] = 0;
        CHECK(NameNow(r.card, "in", ch) == want, "%s: input %u is \"%s\", its table entry is \"%s\"",
              what, ch, NameNow(r.card, "in", ch).c_str(), want);
    }
}

static size_t BoardTypeReads(const Port &p)
{
    return (size_t)std::count(p.vendorReads.begin(), p.vendorReads.end(), (uint8_t)0xA1);
}

// The unit on port 1 is switched off and on again (link recovery), with the
// 0xA1 reads and 0x31 failure given, and `edit` applied to it first.
static void PowerCycleUnitA(Run &r, std::deque<int> script, uint8_t failCmd = 0, uint32_t failSkip = 0,
                            const std::function<void(Port &)> &edit = nullptr)
{
    Port saved = r.card.port[0];
    r.card.port[0] = Port();
    r.drv->LinkWatchTimerOccurred(nullptr, 0);
    HostPump();
    if (edit) edit(saved);
    saved.boardTypeScript = script;
    saved.failWriteCmd = failCmd;
    saved.failWriteSkip = failSkip;
    saved.routingWrites.clear();
    saved.vendorReads.clear();
    r.card.port[0] = saved;
    r.drv->LinkWatchTimerOccurred(nullptr, 0);
    HostPump();
}

static void RunChannelOrderChecks()
{
    const char *name = "channel order";
    Options o; o.name = "channel order (two 8x8s)"; o.shortFlow = true;
    o.slotType[0] = kSIOOptionBoard_Optical; o.slotType[1] = kSIOOptionBoard_Optical;
    // Step 19b reads slot 1, then slot 2's read goes unanswered; Start's own
    // reads afterwards answer both.
    o.boardTypeScript = { -2, -1 };
    Run r;
    RunScenario(o, r);
    uint8_t fitted[2] = {}, fittedValid[2] = {};
    r.drv->ReadBoardTypes(fitted, fittedValid);
    SymphonyChannelOrderOutput sel = ChannelOrder(r);
    CHECK(r.card.port[0].boardTypeScript.empty() && BoardTypeReads(r.card.port[0]) == 4,
          "%s: Start made %zu 0xA1 reads (want 19b's two, then Start's two)", name, BoardTypeReads(r.card.port[0]));
    // The two reads disagree: the tables saw slot 2 unread, the app sees it.
    CHECK(fittedValid[0] && fittedValid[1] && fitted[1] == kSIOOptionBoard_Optical,
          "%s: Start's own read of slot 2 did not answer", name);
    CHECK(sel.unit[0].order == kSymphonyChannelOrderCardByCard && sel.unit[0].boardKnown[0] == 1 &&
          sel.unit[0].boardKnown[1] == 0 && sel.unit[0].boardType[0] == kSIOOptionBoard_Optical &&
          sel.unit[0].boardType[1] == 0,
          "%s: selector 17 after a failed 19b read: order %u types %u/%u known %u/%u", name, sel.unit[0].order,
          sel.unit[0].boardType[0], sel.unit[0].boardType[1], sel.unit[0].boardKnown[0], sel.unit[0].boardKnown[1]);
    CHECK(sel.unit[1].order == kSymphonyChannelOrderNone && sel.generation != 0,
          "%s: unit B %u, generation %u after Start", name, sel.unit[1].order, sel.generation);
    CheckOrderAgrees(r, 0, "channel order: 19b's read of slot 2 failed", true, 'A');
    // The finding itself: by position, host outputs 9-16 play slot 1's ADAT.
    CHECK(NameNow(r.card, "out", 9) == "A ADAT 1" && NameNow(r.card, "out", 17).empty(),
          "%s: outputs 9/17 are \"%s\"/\"%s\" (want \"A ADAT 1\" and no name)", name,
          NameNow(r.card, "out", 9).c_str(), NameNow(r.card, "out", 17).c_str());
    uint32_t generation = sel.generation;

    // The reverse: the recovery's 19b reads answer, its later read of slot 2 does not.
    PowerCycleUnitA(r, { -2, -2, -2, -1 });
    r.drv->ReadBoardTypes(fitted, fittedValid);
    sel = ChannelOrder(r);
    CHECK(r.card.port[0].boardTypeScript.empty() && BoardTypeReads(r.card.port[0]) == 4,
          "%s: the recovery made %zu 0xA1 reads", name, BoardTypeReads(r.card.port[0]));
    CHECK(fittedValid[0] && !fittedValid[1], "%s: the recovery's own read of slot 2 answered", name);
    CHECK(sel.unit[0].order == kSymphonyChannelOrderAnalogFirst && sel.unit[0].boardKnown[1] == 1 &&
          sel.unit[0].boardType[1] == kSIOOptionBoard_Optical && sel.generation == generation + 1,
          "%s: recovery with both 19b reads: order %u, generation %u (was %u)", name, sel.unit[0].order,
          sel.generation, generation);
    CheckOrderAgrees(r, 0, "channel order: the recovery's own read of slot 2 failed", true, 'A');
    CHECK(NameNow(r.card, "out", 9) == "A Line 9" && NameNow(r.card, "out", 17) == "A ADAT 1",
          "%s: analog first, outputs 9/17 are \"%s\"/\"%s\"", name,
          NameNow(r.card, "out", 9).c_str(), NameNow(r.card, "out", 17).c_str());
    generation = sel.generation;

    // The same types again: nothing moves.
    PowerCycleUnitA(r, {});
    sel = ChannelOrder(r);
    CHECK(sel.generation == generation && sel.unit[0].order == kSymphonyChannelOrderAnalogFirst,
          "%s: the same types moved the generation (%u, was %u)", name, sel.generation, generation);
    CHECK(r.card.port[0].routingWrites.size() == 4, "%s: the recovery sent %zu 0x31", name,
          r.card.port[0].routingWrites.size());

    // m5: slot 2 is now a 16x16, and the first capture send (the third 0x31)
    // fails. The previous order, types and names stand.
    auto sixteen = [](Port &p) { p.stored[(uint64_t(0xA1) << 32) | 1] = { kSIOOptionBoard_AnalogADDA16 }; };
    PowerCycleUnitA(r, {}, 0x31, 2, sixteen);
    r.drv->ReadBoardTypes(fitted, fittedValid);
    sel = ChannelOrder(r);
    CHECK(r.card.port[0].routingWrites.size() == 3 && r.card.port[0].failWriteCmd == 0,
          "%s: the failing 0x31 went out (%zu received)", name, r.card.port[0].routingWrites.size());
    CHECK(fittedValid[1] && fitted[1] == kSIOOptionBoard_AnalogADDA16, "%s: the 16x16 was not read", name);
    CHECK(sel.generation == generation && sel.unit[0].order == kSymphonyChannelOrderAnalogFirst &&
          sel.unit[0].boardType[1] == kSIOOptionBoard_Optical,
          "%s: a failed 0x31 latched types %u/%u (generation %u, was %u)", name, sel.unit[0].boardType[0],
          sel.unit[0].boardType[1], sel.generation, generation);
    CheckOrderAgrees(r, 0, "channel order: a 0x31 send failed", false, 'A');
    // With the 16x16 latched, host output and input 17 would be "A Line 17".
    CHECK(NameNow(r.card, "out", 17) == "A ADAT 1" && NameNow(r.card, "in", 17) == "A ADAT 1",
          "%s: after the failed send output/input 17 are \"%s\"/\"%s\"", name,
          NameNow(r.card, "out", 17).c_str(), NameNow(r.card, "in", 17).c_str());

    // The next configuration with every send out latches the 16x16.
    PowerCycleUnitA(r, {});
    sel = ChannelOrder(r);
    CHECK(sel.generation == generation + 1 && sel.unit[0].order == kSymphonyChannelOrderAnalogFirst &&
          sel.unit[0].boardType[1] == kSIOOptionBoard_AnalogADDA16,
          "%s: the good configuration after the failure: types %u/%u generation %u (was %u)", name,
          sel.unit[0].boardType[0], sel.unit[0].boardType[1], sel.generation, generation);
    CheckOrderAgrees(r, 0, "channel order: the configuration after the failure", true, 'A');
    CHECK(NameNow(r.card, "out", 17) == "A Line 17" && NameNow(r.card, "in", 17) == "A Line 17",
          "%s: with the 16x16 output/input 17 are \"%s\"/\"%s\"", name,
          NameNow(r.card, "out", 17).c_str(), NameNow(r.card, "in", 17).c_str());
#ifdef TRACE_HAVE_USERCLIENT
    // Selector 17 through the user client: no input, exactly six words out,
    // the same answer as the driver's; nothing reaches the card.
    {
        const size_t mark = r.card.lines.size();
        auto call = [&](const void *in, size_t inLength, uint64_t outSize, SymphonyChannelOrderOutput *out) {
            auto *client = new SymphonyUserClient;
            client->init();
            client->SetDriver(r.drv);
            IOUserClientMethodArguments arguments;
            arguments.selector = kSelectorReadChannelOrder;
            arguments.structureInput = inLength ? OSData::withBytes(in, inLength) : nullptr;
            arguments.structureOutputMaximumSize = outSize;
            const kern_return_t result = client->ExternalMethod(kSelectorReadChannelOrder, &arguments, nullptr, nullptr, nullptr);
            if (out && arguments.structureOutput && arguments.structureOutput->getLength() == sizeof(*out))
                memcpy(out, arguments.structureOutput->getBytesNoCopy(), sizeof(*out));
            if (arguments.structureInput) arguments.structureInput->release();
            if (arguments.structureOutput) arguments.structureOutput->release();
            client->release();
            return result;
        };
        SymphonyChannelOrderOutput viaClient = {};
        memset(&viaClient, 0xEE, sizeof(viaClient));
        const SymphonyChannelOrderOutput direct = ChannelOrder(r);
        CHECK(call(nullptr, 0, sizeof(SymphonyChannelOrderOutput), &viaClient) == kIOReturnSuccess &&
              memcmp(&viaClient, &direct, sizeof(direct)) == 0, "%s: selector 17 answered differently", name);
        const uint32_t word = kSymphonyUCMagic;
        CHECK(call(&word, sizeof(word), sizeof(SymphonyChannelOrderOutput), nullptr) == kIOReturnBadArgument,
              "%s: selector 17 took an input", name);
        CHECK(call(nullptr, 0, 16, nullptr) == kIOReturnBadArgument && call(nullptr, 0, 40, nullptr) == kIOReturnBadArgument,
              "%s: selector 17 took a wrong output size", name);
        CHECK(CardAccessesSince(r.card, mark) == 0, "%s: selector 17 touched the card", name);
    }
#endif
    Finish(o, r);

    // A cable of converters on port 1: no unit A tables.
    {
        Options c; c.name = "channel order (converters)"; c.port1 = Port::Converters; c.shortFlow = true;
        Run rc;
        RunScenario(c, rc);
        const SymphonyChannelOrderOutput co = ChannelOrder(rc);
        CHECK(co.unit[0].order == kSymphonyChannelOrderNone && co.unit[1].order == kSymphonyChannelOrderNone &&
              co.generation == 0, "%s: converters on port 1 report order %u/%u generation %u", name,
              co.unit[0].order, co.unit[1].order, co.generation);
        Finish(c, rc);
    }

#if defined(TRACE_HAVE_PORT2_AUDIO) && defined(TRACE_HAVE_UNITB_CONFIG)
    // Unit B: None at 32, its own types once set up at 64, None again at 32;
    // a set-up whose 0x31 send fails stays None.
    {
        Options b; b.name = "channel order (unit B)"; b.port2 = Port::Symphony; b.portCountProperty = 2;
        b.shortFlow = true;
        Run rb;
        RunScenario(b, rb);
        rb.drv->StopDevice(1, IOUserAudioStartStopFlags::None);
        SymphonyChannelOrderOutput bo = ChannelOrder(rb);
        CHECK(bo.unit[1].order == kSymphonyChannelOrderNone, "%s: unit B order %u at 32", name, bo.unit[1].order);
        const uint32_t g0 = bo.generation;
        Select(rb, 1, "channel order: unit B at 64");
        HostPump();   // the names Perform queued
        bo = ChannelOrder(rb);
        SymphonyUnitBStateOutput st = {};
        rb.drv->ReadUnitBState(reinterpret_cast<uint32_t *>(&st));
        CHECK(st.present == 1 && bo.generation == g0 + 1 &&
              bo.unit[1].order == kSymphonyChannelOrderAnalogFirst &&
              bo.unit[1].boardType[0] == st.boardType[0] && bo.unit[1].boardType[1] == st.boardType[1] &&
              bo.unit[1].boardKnown[0] == 1 && bo.unit[1].boardKnown[1] == 1,
              "%s: unit B at 64: present %u order %u types %u/%u generation %u (was %u)", name, st.present,
              bo.unit[1].order, bo.unit[1].boardType[0], bo.unit[1].boardType[1], bo.generation, g0);
        CheckOrderAgrees(rb, 1, "channel order: unit B", true, 'B');
        CheckOrderAgrees(rb, 0, "channel order: unit A beside unit B", true, 'A');
        Select(rb, 0, "channel order: back to 32");
        HostPump();   // the names Perform queued
        bo = ChannelOrder(rb);
        CHECK(bo.unit[1].order == kSymphonyChannelOrderNone && bo.unit[1].boardKnown[0] == 0 &&
              bo.generation == g0 + 2, "%s: unit B back at 32: order %u generation %u", name,
              bo.unit[1].order, bo.generation);
        rb.card.port[1].failWriteCmd = 0x31;
        rb.card.port[1].failWriteSkip = 3;   // unit B's second capture send
        Select(rb, 1, "channel order: unit B whose capture send fails");
        HostPump();   // the names Perform queued
        rb.drv->ReadUnitBState(reinterpret_cast<uint32_t *>(&st));
        bo = ChannelOrder(rb);
        CHECK(rb.card.port[1].failWriteCmd == 0 && st.present == 0 &&
              bo.unit[1].order == kSymphonyChannelOrderNone && bo.generation == g0 + 2,
              "%s: unit B with a failed 0x31: present %u order %u generation %u", name, st.present,
              bo.unit[1].order, bo.generation);
        Finish(b, rb);
    }
#endif
}
#endif

int main(int argc, char **argv)
{
    std::string outDir;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--out") && i + 1 < argc) outDir = argv[++i];
        else if (!strcmp(argv[i], "--verbose")) gVerbose = true;
        else { fprintf(stderr, "usage: %s --out <dir> [--verbose]\n", argv[0]); return 2; }
    }
    if (outDir.empty()) { fprintf(stderr, "--out <dir> is required\n"); return 2; }

    RunReplyMatching();
    RunLineSpeakerLevel();
    RunMixerMaths();
    RunSymphonyCardInputRoutes();
    RunPreampHostRoutes();
    RunStartupOutputMuteChecks();
    RunSameValueChecks();
#ifdef TRACE_HAVE_MIC_PRE_DAW
    RunMicPreDAWControls();
#endif

    // A1: exercise new gain behaviour separately from the frozen p1 traces.
    for (bool legacy : {false, true}) {
        Options o; o.name = "instrument-gain checks"; o.shortFlow = true; o.micPreInstrument = true;
        o.legacy2100 = legacy;
        o.port2 = Port::Symphony; o.portCountProperty = 2;
        Run r;
        RunScenario(o, r);
        auto *drv = r.drv;
        auto &a = r.card.port[0].stored;
        // Unknown type -> Mic, as drivers before 132 did (the gain never goes dead).
        CHECK(drv->RequestMicGain(2, 40.0f) == kIOReturnSuccess, "unknown input type is treated as Mic");
        auto *control = gHostAudio.micGains.at(1);
        CHECK(control->range_.mMaximum == 85, "fixed SDK range must allow a later Mic 85");
        control->HandleChangeDecibelValue(80);
        HostPump();
        CHECK(control->GetDecibelValue() == 65, "HAL Instrument value is clamped and published");
        uint8_t halType[2] = {3, 127};
        drv->SendVendorCommand(0x20, 0x80000001u, halType, 2);
        control->HandleChangeDecibelValue(80);
        HostPump();
        CHECK(control->GetDecibelValue() == 80, "HAL Mic accepts 80");
        halType[0] = 4;
        const auto publications = control->valuePublications;
        drv->SendVendorCommand(0x20, 0x80000001u, halType, 2);
        CHECK(control->GetDecibelValue() == 65 && control->valuePublications > publications,
              "type switch restores Instrument value through notifying setter");
        uint8_t appGain = 20;
        drv->SendVendorCommand(0xC4, 1, &appGain, 1);
        CHECK(control->GetDecibelValue() == 20, "app Instrument gain publishes HAL value");
        appGain = 80;
        drv->SendVendorCommand(0xC3, 1, &appGain, 1);
        CHECK(control->GetDecibelValue() == 20, "inactive Mic stage does not move Instrument HAL value");
        halType[0] = 3;
        drv->SendVendorCommand(0x20, 0x80000001u, halType, 2);
        CHECK(control->GetDecibelValue() == 80, "type switch restores independent Mic gain");
        halType[0] = 4;
        drv->SendVendorCommand(0x20, 0x80000001u, halType, 2);
        CHECK(control->GetDecibelValue() == 20, "Mic-Instrument-Mic round trip preserves both stages");
        CHECK(gHostAudio.micGains.at(2)->HandleChangeDecibelValue(40) == kIOReturnSuccess,
              "HAL unknown type is treated as Mic");
        CHECK(gHostAudio.micGains.at(2)->GetDecibelValue() == 0, "refused gain does not change HAL value");
        const auto beforeFailure = control->valuePublications;
        r.card.port[0].txBusy = true;
        halType[0] = 3;
        CHECK(drv->SendVendorCommand(0x20, 0x80000001u, halType, 2) == kIOReturnIOError,
              "failed type write reports failure");
        appGain = 40;
        CHECK(drv->SendVendorCommand(0xC4, 1, &appGain, 1) == kIOReturnIOError,
              "failed app gain write reports failure");
        control->HandleChangeDecibelValue(50);
        HostPump();
        CHECK(control->GetDecibelValue() == 20 && control->valuePublications == beforeFailure,
              "failed type and gain writes do not publish unaccepted state");
        r.card.port[0].txBusy = false;
        control->HandleChangeDecibelValue(85);
        HostPump();
        CHECK(control->GetDecibelValue() == 65 &&
              a[(uint64_t(0xC4) << 32) | 1] == std::vector<uint8_t>({65}),
              "HAL Instrument request above 65 dB is clamped, sent and published");
        CHECK(control->HandleChangeDecibelValue(__builtin_nanf("")) == kIOReturnBadArgument,
              "HAL rejects NaN");
        CHECK(control->GetDecibelValue() == 65, "NaN does not corrupt HAL value");
        a.erase((uint64_t(0xC3) << 32) | 1);
        const uint64_t mic = (uint64_t(0xC3) << 32) | 1;
        const uint64_t inst = (uint64_t(0xC4) << 32) | 1;
        drv->RequestMicGain(1, 40.0f);
        HostPump();
        CHECK(a[inst] == std::vector<uint8_t>({40}), "initial Instrument type read uses C4");
        uint8_t type[2] = {4, 127};
        CHECK(drv->SendVendorCommand(0x20, 0x80000001u, type, 2) == kIOReturnSuccess, "set Instrument type");
        drv->RequestMicGain(1, 90.0f);
        HostPump();
        CHECK(a[inst] == std::vector<uint8_t>({65}), "Instrument DAW gain must use C4 and clamp to 65");
        CHECK(a.count(mic) == 0, "Instrument DAW gain must not write C3");
        type[0] = 3;
        drv->SendVendorCommand(0x20, 1, type, 2); // output type must not change input gain
        drv->RequestMicGain(1, 55.0f);
        HostPump();
        CHECK(a[inst] == std::vector<uint8_t>({55}), "output type leaves input Instrument stage alone");
        drv->SendVendorCommand(0x20, 0x80000001u, type, 2);
        drv->RequestMicGain(1, 99.0f);
        HostPump();
        CHECK(a[mic] == std::vector<uint8_t>({85}), "Mic DAW gain must use C3 and clamp to 85");
        type[0] = 4;
        drv->SendVendorCommand(0x20, 0x80000001u, type, 2);
        drv->RequestMicGain(1, -9.0f);
        HostPump();
        CHECK(a[inst] == std::vector<uint8_t>({0}), "Instrument lower clamp");
#ifdef TRACE_HAVE_PORT2_AUDIO
        uint8_t gain = 42;
        CHECK(drv->SendVendorCommand(0xC4, 1, &gain, 1, 1) == kIOReturnNotReady,
              "unit B gain refused at 32");
        Select(r, 1, "gain checks at 64");
        CHECK(drv->SendVendorCommand(0xC4, 1, &gain, 1, 1) == kIOReturnSuccess, "unit B Instrument gain");
        CHECK(r.card.port[1].stored[inst] == std::vector<uint8_t>({42}), "C4 reaches unit B");
        CHECK(control->GetDecibelValue() == 0, "unit B gain does not move unit A HAL control");
        type[0] = 3;
        drv->SendVendorCommand(0x20, 0x80000001u, type, 2, 1);
        CHECK(control->GetDecibelValue() == 0, "unit B type does not move unit A HAL control");
        drv->RequestMicGain(1, 50.0f);
        HostPump();
        CHECK(a[inst] == std::vector<uint8_t>({50}), "unit B type must not change unit A gain stage");
        CHECK(a[mic] == std::vector<uint8_t>({85}), "unit A Mic stage preserved");
#endif
        Finish(o, r);
    }

    RunNominalRateNames();
#ifdef kSelectorReadChannelOrder
    RunChannelOrderChecks();
#endif
#ifdef TRACE_HAVE_CONVERTER_VOLUME
    RunVolumeKeyChecks();
    RunClockReapplyChecks();
#endif
#if defined(TRACE_HAVE_PORT2_AUDIO) && defined(kSelectorSetMonitorDevice)
    RunMonitorDeviceChecks();
#endif
#if defined(TRACE_HAVE_CONVERTER_VOLUME) && defined(kSelectorSetMonitorOutput)
    RunMonitorOutputChecks();
    RunAppMonitorWriteRecoveryChecks();
#endif
#ifdef TRACE_HAVE_CONVERTER_PARITY
    RunConverterParityChecks();
#endif
#if defined(kSelectorVBus) && defined(TRACE_HAVE_USERCLIENT) && defined(TRACE_HAVE_PORT2_AUDIO)
    RunVBusChecks();
#endif

    size_t accesses = 0;
#ifdef TRACE_HAVE_PORT2_AUDIO
    // Reuse p1's exact full lifecycle; only the personality key differs.
    // p2-32 goldens: dev source db23f3929fb99847b7e2476fb5b65b23b1fa78aa.
    // No intended driver/register changes relative to that source.
    {
        Options o = SinglePortScenarios().front();
        o.name = "p2-32-symphony";
        o.portCountProperty = 2;
        Run r;
        RunScenario(o, r);
        CheckAt32(o, r);
        Finish(o, r);
        CheckTwoPort32(o, r.card);
        accesses += r.card.lines.size();
        if (!WriteFile(outDir, o.name, r.card.lines)) return 2;
    }
#endif
    // Review m1: the 8MicPre golden really carries a preamp write from the
    // app commands to the unit: RequestMicGain(1, 30) on MicPre 2, which is
    // in Instrument, as InstrumentGain (0xC4) 30 for channel 1. (Its
    // RequestPhantom(0, on) comes inside the settle window after Start and is
    // refused, so the golden pins that no +48V goes out then.)
    for (const Options &o : SinglePortScenarios()) {
        if (strcmp(o.name, "p1-symphony-micpre") != 0) continue;
        Run r;
        RunScenario(o, r);
        const Port &p = r.card.port[0];
        const auto gain = p.stored.find(((uint64_t)0xC4 << 32) | 1);
        CHECK(std::count(p.vendorWrites.begin(), p.vendorWrites.end(), (uint8_t)0xC4) == 1 &&
              gain != p.stored.end() && gain->second == std::vector<uint8_t>({30}),
              "%s: RequestMicGain(1, 30) did not reach MicPre 2", o.name);
        CHECK(std::count(p.vendorWrites.begin(), p.vendorWrites.end(), (uint8_t)0xC6) == 0,
              "%s: phantom went out inside the settle window", o.name);
        Finish(o, r);
    }
    for (const Options &o : SinglePortScenarios()) {
        std::vector<std::string> base = Trace(o);
        accesses += base.size();
        if (!WriteFile(outDir, o.name, base)) return 2;
        CHECK(Compact(base).size() > 50, "%s: trace suspiciously short", o.name);
#ifdef TRACE_HAVE_PORT2
        // Every way of NOT asking for two ports must give the identical trace:
        // key present and 1, out of range, or not a number.
        struct { int number; const char *string; const char *what; } variants[] = {
            { 1, nullptr, "SymphonyPortCount=1" },
            { 0, nullptr, "SymphonyPortCount=0" },
            { 3, nullptr, "SymphonyPortCount=3" },
            { -1, "2", "SymphonyPortCount=\"2\" (a string)" },
        };
        for (auto &v : variants) {
            Options alt = o;
            alt.portCountProperty = v.number;
            alt.portCountString = v.string;
            std::vector<std::string> t = Trace(alt);
            CHECK(t == base, "%s: trace differs with %s", o.name, v.what);
        }
        // And nothing on port 2 beyond what the unmodified driver already does.
        {
            Run r;
            RunScenario(o, r);
            CHECK(r.card.port[1].commandsSeen == 0, "%s: single-port mode sent commands on port 2", o.name);
            CHECK(r.card.touched(kRegXLink2TX) == 0 && r.card.touched(kRegXLink2RX) == 0,
                  "%s: single-port mode touched the port-2 XLink registers", o.name);
            CHECK((r.card.reg[kRegXLinkClocking] & kXLinkClockEnable2) == 0,
                  "%s: single-port mode enabled port-2 clocking", o.name);
            Port2State s = ReadPort2(r);
            CHECK(s.w[1] == 1 && s.w[2] == 0 && s.w[6] == 0,
                  "%s: ReadPort2State not empty in single-port mode", o.name);
#ifdef TRACE_HAVE_PORT2_AUDIO
            // Stage 2 in single-port mode: no selector, no second buffer pair,
            // and the entry points refuse without touching the card.
            CHECK(gHostAudio.portSources.empty(), "%s: single-port mode published a port selector", o.name);
            CHECK(s.w[14] == 0 && s.w[15] == 0, "%s: stage-2 words not zero in single-port mode", o.name);
            if (r.startResult == kIOReturnSuccess && gHostAudio.device) {
                auto *dev = dynamic_cast<SymphonyAudioDevice *>(gHostAudio.device);
#ifdef kSelectorVBus
                // dext 143: every build's device calls back into the driver on
                // a configuration change, for VBus. The port entry points
                // still refuse or do nothing with one port (checked below).
                CHECK(dev && dev->portModeDriver == r.drv, "%s: single-port device has no configuration-change hook", o.name);
#else
                CHECK(dev && dev->portModeDriver == nullptr, "%s: single-port device has a port-mode driver", o.name);
#endif
            CHECK(gHostAudio.buffers.size() <= 5, "%s: %zu buffers with one port (want at most 5)", o.name, gHostAudio.buffers.size());
                const size_t mark = r.card.lines.size();
                const uint32_t requests = gHostAudio.configChangeRequests;
                CHECK(r.drv->RequestPortMode(1) == kIOReturnUnsupported, "%s: RequestPortMode accepted with one port", o.name);
                CHECK(r.drv->PerformPortModeChange() == kIOReturnSuccess, "%s: PerformPortModeChange failed with one port", o.name);
                HostPump();
                CHECK(r.card.lines.size() == mark && gHostAudio.configChangeRequests == requests,
                      "%s: the port-selection entry points did something with one port", o.name);
                for (auto &l : r.card.lines)
                    if (l.compare(0, 16, "H stream-create ") == 0)
                        CHECK(l.find("buffer=1048576") != std::string::npos, "%s: stream buffer size changed: %s", o.name, l.c_str());
            }
#endif
            Finish(o, r);
        }
#endif
    }
#ifdef TRACE_HAVE_PCIE_RX
    // The Symphony 64 PCIe card (2100) reads its receive register in the
    // original's order for that card: read (that is the word), then write 0.
    // The ThunderBridge order (read, write 0, read again) on this card lost
    // the start of every vendor reply, so a Symphony I/O was never recognised
    // and was shown as one of the older converters (field report 2026-11-15).
    {
        Options o; o.name = "p1-legacy-2100 (receive order)"; o.legacy2100 = true; o.shortFlow = true;
        Run r;
        RunScenario(o, r);
        uint32_t w[16] = {};
        r.drv->ReadLinkState(w);
        CHECK(w[15] == 0, "%s: the Symphony I/O was not recognised (unit probe word 0x%08x)", o.name, w[15]);
        size_t words = 0;
        const std::vector<std::string> &l = r.card.lines;
        for (size_t i = 0; i < l.size(); i++) {
            unsigned reg = 0, val = 0;
            const bool read  = sscanf(l[i].c_str(), "R 0x%x 0x%x", &reg, &val) == 2;
            const bool write = !read && sscanf(l[i].c_str(), "W 0x%x 0x%x", &reg, &val) == 2;
            if (reg != kRegXLink1RX && reg != kRegXLink2RX) continue;
            if (read && !(val & 0x80000000u)) {
                words++;
                unsigned nreg = 0, nval = 1;
                const bool popped = i + 1 < l.size()
                    && sscanf(l[i + 1].c_str(), "W 0x%x 0x%x", &nreg, &nval) == 2 && nreg == reg && nval == 0;
                CHECK(popped, "%s: a received word was not followed by the write that moves on (line %zu: %s)",
                      o.name, i, l[i].c_str());
            }
            if (write) {
                unsigned preg = 0, pval = 0x80000000u;
                const bool afterWord = i > 0
                    && sscanf(l[i - 1].c_str(), "R 0x%x 0x%x", &preg, &pval) == 2 && preg == reg && !(pval & 0x80000000u);
                CHECK(afterWord, "%s: a write to the receive register did not follow a received word (line %zu)", o.name, i);
            }
        }
        CHECK(words > 0, "%s: nothing was received (the test proves nothing)", o.name);
        Finish(o, r);
    }
#endif
#ifdef TRACE_HAVE_RETIRE
    {
        bool ok = true;
        RunRetire("p1-retire-idle", false, outDir, accesses, ok);
        RunRetire("p1-retire-streaming", true, outDir, accesses, ok);
#ifdef TRACE_HAVE_PORT2_AUDIO
        RunRetire("p2-32-retire-idle", false, outDir, accesses, ok, true);
        RunRetire("p2-32-retire-streaming", true, outDir, accesses, ok, true);
#endif
        if (!ok) return 2;
    }
#endif
#ifdef TRACE_HAVE_PORT2
    for (const Options &o : TwoPortScenarios()) {
        Run r;
        RunScenario(o, r);
        CheckAt32(o, r);
#ifdef TRACE_HAVE_PORT2_AUDIO
        // Port 2 is looked at only now, when 64 is chosen.
        Select(r, 1, "select Port 1-2: 64ch after the 32-channel flow");
        {
            Port2State s = ReadPort2(r);
            CHECK((s.w[2] & 1u) != 0 && s.w[11] == 1, "%s: selecting 64 did not probe port 2 once (flags 0x%x, %u probes)",
                  o.name, s.w[2], s.w[11]);
            if (o.port2 != Port::Empty) {
                if (o.port2 == Port::Symphony)
                    CHECK((s.w[2] & 2u) != 0 && s.w[6] == 1 && (((s.w[7] >> 8) & 0xF0) | ((s.w[7] & 0xF0) >> 4)) == 0xFF,
                          "%s: Symphony unit B not found on selecting 64 (flags 0x%x, %u units)", o.name, s.w[2], s.w[6]);
                else
                    CHECK((s.w[2] & 2u) != 0 && s.w[6] == 2 && (s.w[7] & 0xFF) == 0x30 && (s.w[8] & 0xFF) == 0xC0,
                          "%s: port 2 units not found on selecting 64 (flags 0x%x, %u units)", o.name, s.w[2], s.w[6]);
            } else {
                CHECK((s.w[14] & kSymphonyPort2AudioRefused) && AudioReason(s) == kSymphonyPort2ReasonNoUnit,
                      "%s: 64 with nothing on port 2 not refused (0x%08x)", o.name, s.w[14]);
                CHECK((r.card.reg[kRegGCSR2] & kGCSR2_DisablePort2) != 0, "%s: port 2 left enabled after the refusal", o.name);
            }
        }
#ifdef TRACE_HAVE_UNITB_MIXER
        if (o.port2 == Port::Symphony) {
            uint8_t level = 48;
            CHECK(r.drv->SendVendorCommand(0xB0, (1u << 16) | 63, &level, 1) == kIOReturnSuccess,
                  "%s: unit-B mixer channel 63 rejected at 64", o.name);
            uint8_t unmute = 0;
            r.drv->SendVendorCommand(0xB3, (1u << 16) | 63, &unmute, 1);
            // A centred strip at 0 dB: -3.01 dB per side, the original's
            // equal-power pan law (SymphonyPCIeCardMixer.cpp:1364-1430).
            CHECK(r.card.reg[MixerCoefOffset(0, 63)] == SymphonyMixerCoef(0, 64),
                  "%s: unit-B mixer channel 63 coefficient 0x%08x", o.name,
                  r.card.reg[MixerCoefOffset(0, 63)]);
            uint8_t source = 31;
            CHECK(r.drv->SendVendorCommand(0xB4, (1u << 16), &source, 1) == kIOReturnSuccess,
                  "%s: software-return source 31 rejected at 64", o.name);
            CHECK(r.card.reg[ThunderboltMixerReturnRegister(1, 0)] == (126u | kRoutingEnable) &&
                  r.card.reg[ThunderboltMixerReturnRegister(1, 1)] == (127u | kRoutingEnable),
                  "%s: software-return source 31 mapped incorrectly", o.name);
            uint8_t route[3] = { 63, 127, 1 };
            CHECK(r.drv->SendVendorCommand(0xB5, 0, route, 3) == kIOReturnSuccess,
                  "%s: unit-B card output 63 rejected at 64", o.name);
            CHECK(r.card.reg[kRegOutputRouting + 63 * 4] == (127u | kRoutingEnable),
                  "%s: unit-B output route 63 not written", o.name);
        }
#endif
        const size_t back = Select(r, 0, "select Port 1: 32ch again");
        CheckAt32(o, r, back);
#ifdef TRACE_HAVE_UNITB_MIXER
        if (o.port2 == Port::Symphony) {
            uint8_t route[3] = { 63, 127, 1 };
            CHECK(r.drv->SendVendorCommand(0xB5, 0, route, 3) == kIOReturnBadArgument,
                  "%s: unit-B output route 63 accepted at 32", o.name);
        }
#endif
#endif
        Finish(o, r);
        accesses += r.card.lines.size();
        if (!WriteFile(outDir, o.name, r.card.lines)) return 2;
    }
    {
        Options o; o.name = "p2-rate-change"; o.port2 = Port::Converters; o.portCountProperty = 2;
        o.shortFlow = true;
        Run r;
        RunScenario(o, r);
        RunPort2RateChange(o, r);
        Finish(o, r);
        accesses += r.card.lines.size();
        if (!WriteFile(outDir, o.name, r.card.lines)) return 2;
    }
#ifdef TRACE_HAVE_PORT2_AUDIO
    {
        struct { const char *name; Port::Kind port1, port2; void (*run)(const Options &, Run &); bool unplug; } audio[] = {
            { "p2-audio-enable", Port::Symphony, Port::Converters, RunAudioEnable, false },
            { "p2-audio-refused", Port::Symphony, Port::Empty, RunAudioRefused, false },
            { "p2-audio-late-chain", Port::Symphony, Port::Empty, RunAudioLateChain, false },
            { "p2-audio-sleep-mid-select", Port::Symphony, Port::Empty, RunAudioSleepMidSelect, false },
            { "p2-audio-phase", Port::Converters, Port::Converters, RunAudioPhase, false },
            { "p2-audio-switch", Port::Symphony, Port::Converters, RunAudioSwitch, false },
            { "p2-audio-port2-vanishes", Port::Symphony, Port::Converters, RunAudioPort2Vanishes, true },
        };
        for (auto &a : audio) {
            Options o; o.name = a.name; o.port1 = a.port1; o.port2 = a.port2; o.portCountProperty = 2;
            o.shortFlow = true; o.unplugBeforeStop = a.unplug;
            Run r;
            RunScenario(o, r);
            a.run(o, r);
            Finish(o, r);
            // After Stop every DMA mapping is completed, port 2's included.
            CHECK(r.card.count("H dma-complete") == 5, "%s: %zu DMA mappings completed at Stop (want 5)", o.name,
                  r.card.count("H dma-complete"));
            if (!a.unplug)
                CHECK((r.card.reg[kRegGCSR2] & kGCSR2_DMAEnableMask) == 0 &&
                      (r.card.reg[kRegGCSR] & (kGCSR_A2HDMAEnable | kGCSR_H2ADMAEnable)) == 0,
                      "%s: a DMA engine is still on after Stop", o.name);
            accesses += r.card.lines.size();
            if (!WriteFile(outDir, o.name, r.card.lines)) return 2;
        }
    }
#endif
    // One port, with a unit cabled to port 2: rate changes never go there.
    {
        Options o; o.name = "p1-rate-change-port2-cabled"; o.port2 = Port::Converters; o.shortFlow = true;
        Run r;
        RunScenario(o, r);
        for (double rate : { 96000.0, 44100.0 }) {
            gHostAudio.device->SetSampleRate(rate);
            CHECK(r.drv->StartDevice(1, IOUserAudioStartStopFlags::None) == kIOReturnSuccess,
                  "%s: rate change failed", o.name);
            r.drv->StopDevice(1, IOUserAudioStartStopFlags::None);
        }
        CHECK(r.card.port[1].commandsSeen == 0 && r.card.touched(kRegXLink2TX) == 0,
              "%s: one-port rate change touched port 2", o.name);
        Port2State s = ReadPort2(r);
        CHECK(s.w[12] == 0 && s.w[13] == 0, "%s: one-port build reported a port-2 rate change", o.name);
        Finish(o, r);
    }
#endif
    printf("[trace] %zu recorded accesses and events, %d check failure(s)\n", accesses, gFailures);
    return gFailures ? 1 : 0;
}
