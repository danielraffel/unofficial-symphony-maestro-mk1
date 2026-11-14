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
};

struct Port {
    enum Kind { Empty, Symphony, Converters } kind = Empty;
    std::vector<Unit> units;          // Converters: the chain, nearest first
    bool     answersVendor = true;    // Symphony: replies to vendor reads
    bool     ignoreRate = false;      // units do not follow SET_SAMPLE_RATE
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

    uint32_t status() const { return sticky | (present() ? 0u : kXLinkDataDownCurrent); }

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
        case kRegXLink1TX:
        case kRegXLink2TX:      *v = 0; break;               // never busy
        case kRegXLink1RX:      *v = port[0].readRX(); break;
        case kRegXLink2RX:      *v = port[1].readRX(); break;
        case kRegXLink1Status:  *v = port[0].status(); break;
        case kRegXLink2Status:  *v = port[1].status(); break;
        case kRegXLinkClocking: *v = clocking(); break;
        case kRegA2HCHA:        *v = reg[kRegA2HHBA] + (dmaOn ? 0x400 : 0); break;
        case kRegH2ACHA:        *v = reg[kRegH2AHBA] + (dmaOn ? 0x400 : 0); break;
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
    CHECK(c.count("H dma-prepare") == 3, "%s: %zu DMA mappings (want 3: A2H, H2A, meters)",
          o.name, c.count("H dma-prepare"));
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
#endif
    printf("[trace] %zu recorded accesses and events, %d check failure(s)\n", accesses, gFailures);
    return gFailures ? 1 : 0;
}
