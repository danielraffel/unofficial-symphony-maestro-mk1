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
#include "SymphonyCardMixerRouting.h"
#include "SymphonyThunderbridgeShared.h"
#ifdef TRACE_HAVE_CONVERTER_PARITY
#include "SymphonyConverters.h"
#endif

#include <cstdarg>
#include <algorithm>
#include <functional>

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
static_assert(kSelectorSetMonitorDevice == 12 && kSelectorCount == 14, "monitor selector (12), Loop Sync (13)");
#endif
static_assert(sizeof(SymphonyConverterStateOutput) == 112 && sizeof(SymphonyConverterConfigInput) == 8, "converter struct sizes");
#endif
#endif

HostBackend *gHostBackend = nullptr;
int gHostTerminateCalls = 0;
int gHostLocksHeld = 0;
HostAudioRegistry gHostAudio;
std::deque<HostBlock> gHostCompletions;
static std::vector<std::deque<HostBlock> *> gQueues;
static bool gVerbose = false;
static int gFailures = 0;

void HostNoteBuffer(IOBufferMemoryDescriptor *b) { gHostAudio.buffers.push_back(b); }

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
    uint8_t  symphonyInquire = 0;     // Symphony: INQUIRE reply byte (0 = none)
    bool     symphonyProbeAnswered = false;
    bool     ignoreRate = false;      // units do not follow SET_SAMPLE_RATE
    bool     txBusy = false;          // TX register reports busy (commands time out)
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
    std::vector<uint8_t> vendorReads;
    uint64_t commandsSeen = 0;        // anything written to the TX register

    bool present() const { return kind != Empty; }

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
            stored[((uint64_t)cmd << 32) | nValue] = std::vector<uint8_t>(c + 8, c + 8 + len);
            return;
        }
        if (c[0] != 0xC0) return;
        vendorReads.push_back(cmd);
        if (dropVendorReads) { dropVendorReads--; return; }
        std::vector<uint8_t> out = { 0xC3, (uint8_t)(8 + len), devSeq++, f[2] };
        out.insert(out.end(), c, c + 8);
        auto v = vendorValue(cmd, nValue, len);
        out.insert(out.end(), v.begin(), v.end());
        out.push_back(Crc8(out.data(), out.size()));
        for (uint8_t byte : out) reply(1, 0x10, byte);
    }

    void writeTX(uint32_t val) {
        commandsSeen++;
        if (val == kXLinkResetCmd) {
            for (auto &u : units) { u.addr = 0; u.passing = false; }
            frame.clear();
            dupArmed = false;
            symphonyProbeAnswered = false;
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
        case kRegXLink1TX:      *v = port[0].txBusy ? 0x80000000u : 0; break;   // busy only when a test says so
        case kRegXLink2TX:      *v = port[1].txBusy ? 0x80000000u : 0; break;
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
    bool        shortFlow = false;        // Start, StartDevice, link watch, Stop only
    uint32_t    dropVendorReads = 0;      // port 1 Symphony: first N vendor reads unanswered
    uint32_t    dropPort2VendorReads = 0; // port 2 Symphony: first N vendor reads unanswered
    uint8_t     symphonyInquire = 0;      // port 1 Symphony: INQUIRE reply (0 = none)
    std::vector<Unit> port1Units;         // converters on port 1 other than the default AD,DA
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
        card.port[0].stored[(uint64_t(0x60) << 32) | 0x80000001u] = {4};
        card.port[0].stored[(uint64_t(0x60) << 32) | 0x80000002u] = {0xFF}; // invalid/unknown type
    }
    if (!o.latePort2) Attach(card.port[1], o.port2);
    if (o.port2 == Port::Symphony) card.port[1].symphonyInquire = 0xFF;
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

    card.phase("StartDevice");
    kern_return_t sd = drv->StartDevice(1, IOUserAudioStartStopFlags::None);
    CHECK(configured ? sd == kIOReturnSuccess : sd == kIOReturnNotReady,
          "%s: StartDevice returned 0x%x", o.name, sd);

    if (configured && !o.shortFlow) {
        card.phase("interrupts while running");
        Irq(r, 1);
        Irq(r, 2);
        if (gHostAudio.volume) gHostAudio.volume->SetDecibelValue(-31.0f);
        Irq(r, 1);
        if (gHostAudio.mute) gHostAudio.mute->SetControlValue(true);
        Irq(r, 1);
        HostPump();
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
        { uint8_t p = 40; drv->SendVendorCommand(0xB0, (1u << 16) | 1000, &p, 1); }
        { uint8_t p = 0;  drv->SendVendorCommand(0xB3, (2u << 16) | 4, &p, 1); }
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

static void PressVolume(Run &r, float db)
{
    gHostAudio.volume->SetDecibelValue(db);
    Irq(r, 1);
    HostPump();
}

static void PressMute(Run &r, bool muted)
{
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
    PressVolume(r, -21.0f);
    CHECK(StoredVendor(r, 0x26) == 21, "%s: fallback volume did not reach unit A", o.name);
    CHECK(StoredVendorPort(r, 0x26) == 0xFF, "%s: fallback rewrote unit B unexpectedly", o.name);
    Finish(o, r);
}
#endif

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
        CHECK(Mixer1Return(r) == 0x00e70000, "%s: -31 dB gives 0x%08x", o.name, Mixer1Return(r));
        PressMute(r, true);
        CHECK(Mixer1Return(r) == kMixerMuteCoeff, "%s: mute gives 0x%08x", o.name, Mixer1Return(r));
        PressMute(r, false);
        CHECK(Mixer1Return(r) == 0x00e70000, "%s: unmute gives 0x%08x", o.name, Mixer1Return(r));
        CHECK(StoredVendor(r, 0x26) == 0xFF, "%s: a converter was sent SpeakerVolume", o.name);

        // 3. A card reset keeps the trim.
        r.card.phase("FPGA reset");
        r.drv->SetPowerState(kIOServicePowerCapabilityOff);
        r.card.powerCycleFPGA();
        r.drv->SetPowerState(kIOServicePowerCapabilityOn);
        r.drv->LinkWatchTimerOccurred(nullptr, 0); HostPump();
        r.drv->LinkWatchTimerOccurred(nullptr, 0); HostPump();
        CHECK(Mixer1Return(r) == 0x00e70000, "%s: after a card reset 0x%08x", o.name, Mixer1Return(r));

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
static void CheckPort1Alone(const char *what, Run &r, bool expectRunning = true)
{
    FakeCard &c = r.card;
    const uint32_t gcsr = c.reg[kRegGCSR], gcsr2 = c.reg[kRegGCSR2];
    if (expectRunning) {
        CHECK((gcsr & (kGCSR_A2HDMAEnable | kGCSR_H2ADMAEnable)) == (kGCSR_A2HDMAEnable | kGCSR_H2ADMAEnable),
              "%s: port 1 DMA not running (GCSR=0x%08x)", what, gcsr);
        CHECK((c.reg[kRegClkCtrl] & 0x70000000u) == 0x70000000u, "%s: card left muted (ClkCtrl=0x%08x)", what, c.reg[kRegClkCtrl]);
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
    drv->SetPowerState(kIOServicePowerCapabilityOn);
    drv->LinkWatchTimerOccurred(nullptr, 0);
    HostPump();
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
// The fake card has an Optical card in slot 2: host output 25 is its first
// optical output.
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
    CHECK(LastElementName(card, 0, "out", 25) == "A N.A.", "%s: output 25 at 176.4k is \"%s\"", name,
          LastElementName(card, 0, "out", 25).c_str());
    drv->StopDevice(1, IOUserAudioStartStopFlags::None);
    HostPump();

    card.phase("nominal rate 48 kHz, no stream start");
    size_t mark = card.lines.size();
    gHostAudio.device->SetSampleRate(48000.0);
    SymphonyNoteNominalSampleRate(gHostAudio.device, 48000.0);
    HostPump();
    CHECK(LastElementName(card, mark, "out", 25) == "A ADAT 1", "%s: output 25 after 48k nominal is \"%s\"", name,
          LastElementName(card, mark, "out", 25).c_str());

    card.phase("the same nominal rate again renames nothing");
    mark = card.lines.size();
    SymphonyNoteNominalSampleRate(gHostAudio.device, 48000.0);
    HostPump();
    CHECK(LastElementName(card, mark, "out", 25).empty(), "%s: repeated nominal rate renamed output 25", name);

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
        CHECK(change(1) != kIOReturnSuccess, "Loop Sync: accepted at 32");
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
        CHECK(change(1) != kIOReturnSuccess, "Loop Sync: accepted after leaving 64");
        Select(r, 1, "Loop Sync: re-enter 64");
        CHECK(clock(1, {1,1,1,0}) && clock(0, {3,0,1,0}), "Loop Sync: lost B master on re-entry");
        gHostAudio.device->SetSampleRate(48000.0);
        CHECK(r.drv->StartDevice(1, IOUserAudioStartStopFlags::None) == kIOReturnSuccess,
              "Loop Sync: rate change with B master failed");
        CHECK(clock(1, {1,1,1,0}) && clock(0, {3,0,1,0}), "Loop Sync: rate change lost topology");
        // A missing master B takes the existing port-loss path back to A alone.
        r.card.port[1].kind = Port::Empty;
        r.drv->LinkWatchTimerOccurred(nullptr, 0); HostPump();
        CHECK(change(0) != kIOReturnSuccess, "Loop Sync: master loss left controls admitted");

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
        CHECK(r.drv->LoopSyncConfig(1, 2, out) != kIOReturnSuccess, "Loop Sync: non-Symphony accepted");
        CHECK(a == r.card.port[0].vendorWrites.size() && b == r.card.port[1].vendorWrites.size(),
              "Loop Sync: clock sent to converter/missing unit");
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

// B10: assertions only, so the shipped lifecycle goldens remain immutable.
static void RunPreampHostRoutes()
{
    Options o; o.name = "B10 preamp host routes"; o.shortFlow = true;
    o.micPreInstrument = true; o.portCountProperty = 2; o.port2 = Port::Symphony;
    Run r; RunScenario(o, r);
    auto *drv = r.drv;
    auto &a = r.card.port[0].stored;
    auto &b = r.card.port[1].stored;
    const uint64_t phantom = uint64_t(0xC6) << 32;
    const uint64_t mic = uint64_t(0xC3) << 32;
    auto route = [&](uint8_t host, uint8_t rx) {
        uint8_t pl[] = {host, rx, 1};
        return drv->SendVendorCommand(0xB6, 0, pl, sizeof(pl));
    };
    CHECK(route(0, 32) == kIOReturnBadArgument, "B10: B route refused at 32");
    b[(uint64_t(0xA1) << 32) | 0] = {6};
    b[(uint64_t(0xA1) << 32) | 1] = {1};
    drv->StopDevice(1, IOUserAudioStartStopFlags::None);
    Select(r, 1, "B10 select 64");
    uint8_t type[] = {3, 127};
    CHECK(drv->SendVendorCommand(0x20, 0x80000000u, type, 2, 1) == kIOReturnSuccess,
          "B10: B Mic type tracked");
    CHECK(route(0, 32) == kIOReturnSuccess, "B10: B routed to host 1");
    a.erase(phantom); a.erase(mic); b.erase(phantom); b.erase(mic);
    CHECK(drv->RequestPhantom(0, true) == kIOReturnSuccess && drv->RequestMicGain(0, 44) == kIOReturnSuccess,
          "B10: host 1 accepts B preamp writes");
    HostPump();
    CHECK(b[phantom] == std::vector<uint8_t>({1}) && b[mic] == std::vector<uint8_t>({44}) &&
          !a.count(phantom) && !a.count(mic), "B10: host 1 writes B over port 2 only");
    CHECK(route(8, 0) == kIOReturnSuccess, "B10: A routed to host 9");
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
    const size_t mark = r.card.lines.size();
    CHECK(drv->RequestPhantom(0, false) == kIOReturnNotReady &&
          drv->RequestMicGain(0, 12) == kIOReturnNotReady, "B10: digital route refuses phantom and gain");
    HostPump();
    CHECK(Commands(r.card, mark, kRegXLink1TX, 0x10).empty() &&
          Commands(r.card, mark, kRegXLink2TX, 0x10).empty(), "B10: digital refusal sends nothing");
    r.card.port[1].kind = Port::Empty;
    drv->LinkWatchTimerOccurred(nullptr, 0); HostPump();
    const size_t removed = r.card.lines.size();
    CHECK(drv->RequestPhantom(1, false) == kIOReturnSuccess &&
          drv->RequestMicGain(1, 13) == kIOReturnSuccess, "B10: removed B falls back to saved A route");
    HostPump();
    CHECK(!Commands(r.card, removed, kRegXLink1TX, 0x10).empty() &&
          Commands(r.card, removed, kRegXLink2TX, 0x10).empty(), "B10: removal targets A after 64→32 fallback");
    Finish(o, r);
}

int main(int argc, char **argv)
{
    std::string outDir;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--out") && i + 1 < argc) outDir = argv[++i];
        else if (!strcmp(argv[i], "--verbose")) gVerbose = true;
        else { fprintf(stderr, "usage: %s --out <dir> [--verbose]\n", argv[0]); return 2; }
    }
    if (outDir.empty()) { fprintf(stderr, "--out <dir> is required\n"); return 2; }

    RunSymphonyCardInputRoutes();
    RunPreampHostRoutes();

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
#ifdef TRACE_HAVE_CONVERTER_VOLUME
    RunVolumeKeyChecks();
#endif
#if defined(TRACE_HAVE_PORT2_AUDIO) && defined(kSelectorSetMonitorDevice)
    RunMonitorDeviceChecks();
#endif
#ifdef TRACE_HAVE_CONVERTER_PARITY
    RunConverterParityChecks();
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
                CHECK(dev && dev->portModeDriver == nullptr, "%s: single-port device has a port-mode driver", o.name);
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
                    CHECK((s.w[2] & 2u) != 0 && s.w[6] == 1 && (s.w[7] & 0xFF) == 0xFF,
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
            CHECK(r.card.reg[MixerCoefOffset(0, 63)] == kMixerUnityCoeff,
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
