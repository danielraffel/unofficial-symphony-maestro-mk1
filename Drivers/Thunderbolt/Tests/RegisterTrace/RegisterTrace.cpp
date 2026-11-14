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
#include "SymphonyThunderbridgeShared.h"

#include <cstdarg>

// The app-facing layouts: the existing link-state reply must keep its size, and
// the new port-2 reply is a separate 16-word struct.
static_assert(sizeof(SymphonyLinkStateOutput) == 64, "ReadLinkState layout changed");
#ifdef TRACE_HAVE_PORT2
static_assert(sizeof(SymphonyPort2StateOutput) == 64, "ReadPort2State is 16 words");
static_assert(offsetof(SymphonyPort2StateOutput, unit) == 7 * sizeof(uint32_t), "unit[] at word 7");
static_assert(kSelectorReadLinkState == 5 && kSelectorReadPort2State == 6, "selector numbers");
#endif

HostBackend *gHostBackend = nullptr;
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
};

struct Port {
    enum Kind { Empty, Symphony, Converters } kind = Empty;
    std::vector<Unit> units;          // Converters: the chain, nearest first
    bool     answersVendor = true;    // Symphony: replies to vendor reads
    bool     ignoreRate = false;      // units do not follow SET_SAMPLE_RATE
    bool     txBusy = false;          // TX register reports busy (commands time out)
    uint32_t slipReads = 0;           // the next N status reads report a data slip
    uint8_t  rateCode = 0x04;         // 44.1 kHz
    uint32_t sticky = 0;              // status sticky bits (write 1 to clear)
    std::deque<uint32_t> rx;
    bool     hasLatch = false;
    uint32_t latch = 0;
    bool     dupArmed = false;
    uint32_t lastTx = 0;
    std::vector<uint8_t> frame;       // Symphony: request frame being received
    uint8_t  devSeq = 0;
    std::map<uint64_t, std::vector<uint8_t>> stored;   // Symphony: written values
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

    uint32_t readRX() {
        if (hasLatch) { hasLatch = false; return latch; }
        if (rx.empty()) return 0x80000000u;
        return rx.front();
    }
    void writeRX() {
        if (rx.empty()) return;
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
            stored[((uint64_t)cmd << 32) | nValue] = std::vector<uint8_t>(c + 8, c + 8 + len);
            return;
        }
        if (c[0] != 0xC0) return;
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
            Unit *u = addr ? reachable(addr) : firstNotPassing();
            if (u) reply(addr, cmd, cmd == 0x05 ? u->inquire : u->xtd);
            break;
        }
        case 0x09:
            if (Unit *u = addr ? reachable(addr) : nullptr)
                if (u->answersPhase) reply(addr, cmd, u->phase);
            break;
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
    uint16_t pciCommand = 0;
    uint32_t idReg = 0x11000021;       // FPGA v17, hardware rev 1, master
    uint32_t intPending = 0;
    bool     endpointPresent = true;
    bool     jamBusy = false;          // the jam register reports a jam in progress
    bool     dropPort2Addresses = false;   // the card does not keep A2H2/H2A2 HBA
    uint64_t nextDMA = 0x10000000;
    std::vector<std::string> lines;

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
        if (port[1].present()) v |= kXLinkRX2ClockDetect | (port[1].detectBit() << 16);
        return v;
    }

    void MemRead32(uint8_t, uint64_t off, uint32_t *v) override {
        const bool dmaOn = (reg[kRegGCSR] & (kGCSR_A2HDMAEnable | kGCSR_H2ADMAEnable)) != 0;
        switch (off) {
        case kRegIDReg:         *v = idReg; break;
        case kRegIntStatus:     *v = intPending; break;
        case kRegXLink1TX:      *v = port[0].txBusy ? 0x80000000u : 0; break;   // busy only when a test says so
        case kRegXLink2TX:      *v = port[1].txBusy ? 0x80000000u : 0; break;
        case kRegXLink1RX:      *v = port[0].readRX(); break;
        case kRegXLink2RX:      *v = port[1].readRX(); break;
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
        switch (off) {
        case kRegIntStatus:     intPending &= ~v; break;
        case kRegXLink1TX:      port[0].writeTX(v); break;
        case kRegXLink2TX:      port[1].writeTX(v); break;
        case kRegXLink1RX:      port[0].writeRX(); break;
        case kRegXLink2RX:      port[1].writeRX(); break;
        case kRegXLink1Status:  port[0].sticky &= ~v; break;
        case kRegXLink2Status:  port[1].sticky &= ~v; break;
        case kRegA2H2HBA:
        case kRegH2A2HBA:       reg[off] = dropPort2Addresses ? 0 : v; break;
        default:                reg[off] = v; break;
        }
    }

    void Sleep(uint64_t ms) override { line("S %llu", (unsigned long long)ms); }
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
    bool        shortFlow = false;        // Start, StartDevice, link watch, Stop only
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
    if (!o.lateSymphony) Attach(card.port[0], o.port1);
    if (!o.latePort2) Attach(card.port[1], o.port2);
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
    return v;
}

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

// Things that must hold in two-port mode during Stage 1, checked on the raw
// trace: the port is switched on the way the original did it, and nothing that
// carries audio on port 2 is touched.
static void CheckStage1(const Options &o, Run &r, bool expectUnits)
{
    FakeCard &c = r.card;
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
    for (auto &l : c.lines)
        if (l.compare(0, 16, "H stream-format ") == 0)
            CHECK(l.find("channels=32 ") != std::string::npos, "%s: stream format changed: %s", o.name, l.c_str());
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
    // Port 2 never gets an unmute command in Stage 1 (cmd 0x0A, broadcast).
    char unmute[40];
    snprintf(unmute, sizeof(unmute), "W 0x%06llx 0x%08x", (unsigned long long)kRegXLink2TX,
             (uint32_t)((0x0Au << 9) | (0x80u << 1)));
    CHECK(c.count(unmute) == 0, "%s: port 2 was unmuted", o.name);

    bool enabled2 = false, cleared2 = false;
    for (auto &l : c.lines) {
        unsigned long long off = 0;
        unsigned val = 0;
        if (sscanf(l.c_str(), "W 0x%llx 0x%x", &off, &val) != 2) continue;
        if (off == kRegXLinkClocking && (val & kXLinkClockEnable2) && (val & kXLinkClockEnable1)) enabled2 = true;
    }
    cleared2 = (c.reg[kRegGCSR2] & (kGCSR2_DisablePort1 | kGCSR2_DisablePort2)) == 0;
    CHECK(enabled2, "%s: XLINK_CLOCKING_ENABLE_2 never written", o.name);
    CHECK(cleared2, "%s: SM_MISC2_DISABLE_PORT2 still set (GCSR2=0x%08x)", o.name, c.reg[kRegGCSR2]);
    CHECK((c.reg[kRegXLinkClocking] & kXLinkClockEnable2) != 0, "%s: port 2 clocking not enabled at the end", o.name);

    Port2State s = ReadPort2(r);
    CHECK(s.w[1] == 2, "%s: ReadPort2State portCount=%u", o.name, s.w[1]);
    CHECK((s.w[2] & 1u) != 0, "%s: port 2 probe did not run (flags=0x%x)", o.name, s.w[2]);
    if (expectUnits) {
        CHECK((s.w[2] & 2u) != 0, "%s: port 2 clock not reported (flags=0x%x)", o.name, s.w[2]);
        CHECK(s.w[6] == 2, "%s: port 2 units=%u (want 2)", o.name, s.w[6]);
        CHECK((s.w[7] & 0xFF) == 0x30 && (s.w[8] & 0xFF) == 0xC0,
              "%s: port 2 unit words 0x%08x 0x%08x", o.name, s.w[7], s.w[8]);
    } else {
        CHECK((s.w[2] & 2u) == 0 && s.w[6] == 0, "%s: port 2 reported units with nothing attached", o.name);
        CHECK(c.port[1].commandsSeen == 0, "%s: commands sent on port 2 with no clock there", o.name);
    }
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

// The device's rate changes reach port 2 when a unit was found there, in the
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

    // Port 2 slips through the whole before-step wait (2000 ms budget = 8
    // passes, each broken by its first slipping read): it is not told first,
    // but is still told after port 1 and follows.
    c.port[1].slipReads = 8;
    {
        auto [rc, mark] = change("two-port rate change to 192000, port 2 slipping beforehand", 192000.0);
        changes++;
        CHECK(rc == kIOReturnSuccess, "%s: slipping port 2 failed the change (0x%x)", o.name, rc);
        CHECK(c.port[0].rateCode == 0x02 && c.port[1].rateCode == 0x02,
              "%s: after early slip ports at 0x%02x / 0x%02x (want both 192k)", o.name,
              c.port[0].rateCode, c.port[1].rateCode);
        CHECK(FirstRateCommand(c, mark, tx1) < FirstRateCommand(c, mark, tx2),
              "%s: slipping port 2 was told before port 1", o.name);
        Port2State s = ReadPort2(r);
        CHECK((s.w[2] & kSymphonyPort2FlagRateFailed) == 0 && s.w[12] == 192000 && s.w[13] == changes,
              "%s: recovered port-2 change not reported (flags 0x%x rate %u)", o.name, s.w[2], s.w[12]);
    }
    // Port 2 never stops slipping: the change still succeeds, the port-2
    // failure is reported, and the port-2 waits stay within their budget.
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
        auto [rc, mark] = change("two-port rate change to 48000 after the slip", 48000.0);
        changes++;
        const uint64_t ms = sleptMs(mark);
        CHECK(rc == kIOReturnSuccess && c.port[1].rateCode == 0x00, "%s: change after slip failed", o.name);
        Port2State s = ReadPort2(r);
        CHECK((s.w[2] & kSymphonyPort2FlagRateFailed) == 0 && s.w[12] == 48000,
              "%s: flag not cleared after a good change (0x%x)", o.name, s.w[2]);
        CHECK(ms < 2500, "%s: healthy two-port rate change slept %llu ms", o.name, (unsigned long long)ms);
    }

    CheckStage1(o, r, true);

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
        CHECK(s.w[13] == changes && s.w[6] == 0, "%s: rate change counted with port 2 gone (%u)", o.name, s.w[13]);
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
static size_t Select(Run &r, uint32_t value, const char *phase, bool ioRunning = false)
{
    FakeCard &c = r.card;
    c.phase(phase);
    const size_t mark = c.lines.size();
    const uint32_t before = gHostAudio.configChangeRequests;
    kern_return_t rc = r.drv->RequestPortMode(value);
    CHECK(rc == kIOReturnSuccess, "%s: RequestPortMode(%u) returned 0x%x", phase, value, rc);
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
    for (uint32_t n = 32; n < 64; n++) {
        CHECK(c.reg[kRegInputRouting + n * 4] == (n | 0x100), "%s: input route %u = 0x%03x", what, n, c.reg[kRegInputRouting + n * 4]);
        CHECK(c.reg[kRegOutputRouting + n * 4] == ((64 + n) | 0x100), "%s: output route %u = 0x%03x", what, n,
              c.reg[kRegOutputRouting + n * 4]);
    }
    CHECK(c.reg[kRegIntMask] == kInt_A2HWrap, "%s: interrupt mask 0x%08x (port-1 wrap only)", what, c.reg[kRegIntMask]);
    // Original's order: every step reaches GCSR2 (port 2) before GCSR (port 1).
    // Find the last GCSR2 write that sets both enables and the next GCSR write.
    size_t p2 = SIZE_MAX, p1 = SIZE_MAX, ts2 = SIZE_MAX, ts1 = SIZE_MAX;
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
            if ((val & (run | ts)) == ts) ts1 = i;
            if ((val & (run | ts)) == (run | ts)) p1 = i;
        }
    }
    CHECK(ts2 != SIZE_MAX && ts1 != SIZE_MAX && ts2 < ts1, "%s: trigger-selects not written to GCSR2 before GCSR", what);
    CHECK(p2 != SIZE_MAX && p1 != SIZE_MAX && p2 < p1 && ts1 < p2, "%s: enables not written to GCSR2 before GCSR", what);
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
}

// Run the two-port IO handler over a block that wraps the end of the ring and
// check where every sample went.
static void CheckIOHandler(const char *what, uint32_t channels)
{
    auto handler = (IOOperationHandler)gHostAudio.ioHandler;
    CHECK(handler != nullptr && gHostAudio.buffers.size() >= 7, "%s: no IO handler or buffers", what);
    if (!handler || gHostAudio.buffers.size() < 7) return;
    int32_t *a2h1 = (int32_t *)gHostAudio.buffers[0]->mem_, *h2a1 = (int32_t *)gHostAudio.buffers[1]->mem_;
    int32_t *in = (int32_t *)gHostAudio.buffers[2]->mem_, *out = (int32_t *)gHostAudio.buffers[3]->mem_;
    int32_t *a2h2 = (int32_t *)gHostAudio.buffers[5]->mem_, *h2a2 = (int32_t *)gHostAudio.buffers[6]->mem_;
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

// p2-audio-enable: the selector, 32 -> 64 -> 32, and a request that is refused.
static void RunAudioEnable(const Options &o, Run &r)
{
    FakeCard &c = r.card;
    CHECK(gHostAudio.portSources.size() == 2, "%s: %zu port selectors published (want 2)", o.name, gHostAudio.portSources.size());
    for (auto *sel : gHostAudio.portSources) {
        CHECK(sel->names.size() == 2 && sel->names[0] == "Port 1: 32ch" && sel->names[1] == "Port 1-2: 64ch",
              "%s: selector entries are not the original's two names", o.name);
        CHECK(sel->selected == 0, "%s: selector does not start at Port 1: 32ch", o.name);
    }
    CheckPublished("at start", 32);
    CheckPort1Alone("at start", r);
    CheckIOHandler("32 channels at start", 32);

    // The entry already selected: no configuration change, no card access.
    {
        const uint32_t before = gHostAudio.configChangeRequests;
        const size_t mark = Select(r, 0, "select Port 1: 32ch again");
        CHECK(gHostAudio.configChangeRequests == before, "%s: re-selecting 32 asked for a configuration change", o.name);
        CHECK(CountAccess(c, mark, 'W', kRegGCSR) == 0, "%s: re-selecting 32 wrote GCSR", o.name);
    }

    size_t mark = Select(r, 1, "select Port 1-2: 64ch");
    CheckBothPortsRunning("after selecting 64", r, mark);
    CheckPublished("after selecting 64", 64);
    {
        // Port 2 told the rate, then phase read from both of its converters and
        // the jam written, then each unit unmuted.
        CHECK(RateCommands(c, mark, kRegXLink2TX) == std::vector<uint8_t>({ 0x04, 0x04 }) ||
              RateCommands(c, mark, kRegXLink2TX).size() == 2, "%s: port 2 not told the rate before carrying audio", o.name);
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
    r.drv->StopDevice(1, IOUserAudioStartStopFlags::None);

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
    size_t writes = 0;
    for (size_t i = mark; i < c.lines.size(); i++) {
        unsigned long long off = 0;
        unsigned val = 0;
        if (sscanf(c.lines[i].c_str(), "W 0x%llx 0x%x", &off, &val) == 2 && off != kRegIntStatus) writes++;
    }
    CHECK(writes == 0, "%s: a refused request wrote %zu registers", o.name, writes);
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
        CHECK(gHostAudio.configChangeRequests == 1, "%s: %s asked for a configuration change", o.name, name);
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
        // and the handler must keep working.
        CheckIOHandler("64-channel streams while the card is at 32", 64);
        c.phase("configuration change after the fallback");
        HostPerformConfigChange(r, false);
        CheckPublished("after the fallback", 32);
        CheckIOHandler("32 channels after the fallback", 32);
    }

    // Sleep with an FPGA reset while 64 is running: back at 32 afterwards.
    mark = Select(r, 1, "select 64 at 48000");
    CheckBothPortsRunning("64 at 48000", r, mark);
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
        CheckPublished("after the card reset", 32);
    }
    mark = Select(r, 1, "select 64 after the card reset");
    CheckBothPortsRunning("64 after the card reset", r, mark);
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

    c.phase("port 2 chain switched off in mid-stream");
    const Port saved = c.port[1];
    c.port[1] = Port();
    Irq(r, 1);                                   // port 1's interrupts keep coming
    const uint32_t before = gHostAudio.configChangeRequests;
    mark = c.lines.size();
    drv->LinkWatchTimerOccurred(nullptr, 0);     // the watch notices within its 2 s interval
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
    drv->LinkWatchTimerOccurred(nullptr, 0);
    HostPump();
    CheckPort1Alone("after port 2 came back, before selecting", r);
    mark = Select(r, 1, "select Port 1-2: 64ch after port 2 came back");
    CheckBothPortsRunning("after port 2 came back", r, mark);
    CheckPublished("after port 2 came back", 64);
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

int main(int argc, char **argv)
{
    std::string outDir;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--out") && i + 1 < argc) outDir = argv[++i];
        else if (!strcmp(argv[i], "--verbose")) gVerbose = true;
        else { fprintf(stderr, "usage: %s --out <dir> [--verbose]\n", argv[0]); return 2; }
    }
    if (outDir.empty()) { fprintf(stderr, "--out <dir> is required\n"); return 2; }

    size_t accesses = 0;
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
#ifdef TRACE_HAVE_PORT2
    for (const Options &o : TwoPortScenarios()) {
        Run r;
        RunScenario(o, r);
        CheckStage1(o, r, o.port2 != Port::Empty);
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
