// SymphonyThunderbridge.cpp — DriverKit driver for Apogee ThunderBridge
// Phase T0-T7: Opens PCIe device, maps BAR0, validates FPGA, configures XLink,
// allocates DMA buffers, programs FPGA DMA registers, starts audio DMA,
// and publishes IOUserAudioDevice with 32-channel input/output streams.
//
// Ported from legacy kext: Symphony64Card::initHardware(), StartDMA(), StopDMA()
// Reference: og_source/symphonymk1/ext/Symphony64/Driver/Symphony64Card.cpp

#include <os/log.h>

#include <DriverKit/IOLib.h>
#include <time.h>
#include <DriverKit/IOBufferMemoryDescriptor.h>
#include <DriverKit/IODMACommand.h>
#include <DriverKit/IOInterruptDispatchSource.h>
#include <DriverKit/IOMemoryDescriptor.h>
#include <DriverKit/IOMemoryMap.h>
#include <DriverKit/IOTimerDispatchSource.h>
#include <DriverKit/OSCollections.h>
#include <PCIDriverKit/IOPCIDevice.h>

// AudioDriverKit — IOUserAudioDevice, IOUserAudioStream, timestamps
#include <AudioDriverKit/AudioDriverKit.h>

// Generated headers from .iig files
#include "SymphonyThunderbridge.h"
#include "SymphonyAudioDevice.h"
#include "SymphonyUserClient.h"
#include "SymphonyClockSelectorControl.h"
#include "SymphonyPhantomControl.h"
#include "SymphonyMicGainControl.h"
#include "SymphonyOpticalControl.h"
#include "SymphonyThunderbridgeShared.h"

// FPGA register map
#include "Sym64Registers.h"
#include "SymphonyTimingProfile.h"
#include "SymphonyMixerPan.h"
#include "SymphonyCardMixerRouting.h"

// ── Logging ─────────────────────────────────────────────────────────────────
// DriverKit only provides os_log with OS_LOG_TYPE_DEFAULT — no os_log_error.

#define LOG_PREFIX "SymphonyTB"
#define STLOG(fmt, ...) os_log(OS_LOG_DEFAULT, LOG_PREFIX ": " fmt, ##__VA_ARGS__)
#define STERR(fmt, ...) os_log(OS_LOG_DEFAULT, LOG_PREFIX " ERROR: " fmt, ##__VA_ARGS__)

// ── Real-time debug gate (M4) ───────────────────────────────────────────────
// The audio IO operation handler and interrupt handler run on real-time-ish
// audio paths where os_log() (which can allocate/serialize) and speculative DMA
// sample reads are unsafe: they can stall the RT thread and cause dropouts.
// SYMPHONY_RT_DEBUG gates ALL such diagnostics. It MUST default OFF; only define
// it to 1 for a hardware bring-up build. When off, the RT path performs no
// logging, no allocation, and no blocking.
#ifndef SYMPHONY_RT_DEBUG
#define SYMPHONY_RT_DEBUG 0
#endif

// ── Private Instance Variables ──────────────────────────────────────────────

struct ThunderboltMixerState {
    // SW Return + Master both feed the stereo return slots for one logical
    // mixer. Each logical mixer has an independent copy of these controls.
    uint8_t swReturnLeftByte;
    uint8_t swReturnRightByte;
    uint8_t masterLeftByte;
    uint8_t masterRightByte;
    uint8_t swReturnPanByte;
    bool swReturnMuted;
    bool masterMuted;
    bool swReturnSoloed;
    uint8_t inputByte[32];
    uint8_t inputPanByte[32];
    bool inputMuted[32];
    bool inputSoloed[32];
};

struct SymphonyThunderbridge_IVars {
    IOPCIDevice *pciDevice;
    uint8_t      barMemoryIndex;
    // Card-mixer state (Thunderbolt). SW-Return + Master both drive the mixer's
    // return coefficient (host-playback level). Level bytes are dB+48 (0..48;
    // 48=0 dB), held so mute/unmute restores them. The base channel IDs (1000
    // and 2000) set both sides; the side IDs below preserve independent L/R
    // faders when the UI unlinks a stereo strip.
    ThunderboltMixerState mixer[2];
    uint8_t      mixerSwReturnSource[2];
    uint64_t     barSize;
    uint32_t     fpgaVersion;
    uint32_t     hardwareVersion;
    uint64_t     serialNumber;
    bool         isMaster;
    bool         isLegacyPCIe2100;

    // DMA buffers and commands (FPGA-facing, wired for PCIe DMA)
    IOBufferMemoryDescriptor *a2hBuffer;    // Audio-to-Host (capture) DMA buffer
    IOBufferMemoryDescriptor *h2aBuffer;    // Host-to-Audio (playback) DMA buffer
    IODMACommand             *a2hDMA;       // DMA mapping for A2H
    IODMACommand             *h2aDMA;       // DMA mapping for H2A
    uint64_t                  a2hPhysAddr;  // Device-visible physical address for A2H
    uint64_t                  h2aPhysAddr;  // Device-visible physical address for H2A

    // Stream buffers (CoreAudio-facing, NOT DMA-wired)
    // After PrepareForDMA(), DMA buffers may not be mappable by coreaudiod.
    // Separate stream buffers are mapped by CoreAudio, and we copy in IOOpHandler.
    IOBufferMemoryDescriptor *a2hStreamBuffer;  // CoreAudio reads capture data here
    IOBufferMemoryDescriptor *h2aStreamBuffer;  // CoreAudio writes playback data here
    IOMemoryMap              *a2hDMAMap;         // CPU mapping of DMA capture buffer
    IOMemoryMap              *h2aDMAMap;         // CPU mapping of DMA playback buffer
    IOMemoryMap              *a2hStreamMap;      // CPU mapping of stream capture buffer
    IOMemoryMap              *h2aStreamMap;      // CPU mapping of stream playback buffer

    // Meter DMA: the card FPGA continuously DMAs 256 meter words (peak in bits
    // [31:24], over in bit 1) into this bus-master buffer at ~10 Hz. CPU-mapped so
    // the IOUserClient read selector can memcpy the latest values. Requires FPGA>=20.
    IOBufferMemoryDescriptor *meterBuffer;
    IODMACommand             *meterDMA;
    IOMemoryMap              *meterMap;
    uint64_t                  meterPhysAddr;     // device-visible 32-bit addr → kRegMeterHBA
    uint32_t                 *meterWords;        // meterMap->GetAddress(), 256 words
    bool                      meterDMAActive;    // allocated + programmed (fpgaVersion>=20)

    // Interrupt handling
    IOInterruptDispatchSource *interruptSource;
    IODispatchQueue           *interruptQueue;
    uint64_t                   interruptCount;
    bool                       dmaRunning;

    // XLink TX serialization (C2/H1).
    // ALL XLink TX register traffic (MSG_BYTE vendor frames + SetSampleRate) is
    // funneled through this ONE serial queue so multi-byte SimpleMessageProtocol
    // frames never interleave and runtimeTxSeq is never raced. The IRQ handler
    // dispatches volume/mute writes here ASYNC and returns immediately — it must
    // never IOSleep on the interrupt queue. Matches the legacy IOCommandGate that
    // serialized all register access (Symphony64Card.cpp:445-497).
    // Lifetime note (#2): xlinkQueue is created in Start() and released ONLY in
    // free() — never in Stop(). Keeping it alive until the driver object is
    // destroyed means any late user-client SendVendorCommand or queued rate-change
    // transaction can always safely DispatchSync on it, observe the shutdown/stopping
    // flags inside the serialized block, and return WITHOUT touching a closed
    // pciDevice. Releasing it in Stop() would let a caller dispatch through a stale
    // queue pointer during teardown.
    IODispatchQueue           *xlinkQueue;
    bool                       txShutdown;   // atomic — set at Stop(): blocks new TX enqueues
    // Lifecycle-safety gate (#1). Set (RELEASE) at the very top of Stop() and read
    // (ACQUIRE) by the StartDevice rate-change transaction. Once set, an in-progress
    // or queued rate change ABORTS instead of restarting DMA / unmuting — so teardown
    // (which releases DMA mappings + closes PCI) can never race a DMA restart. All
    // access is via __atomic_* intrinsics.
    bool                       stopping;

    // Hardware reachability gate (dext 112 — see PCIEndpointPresent/HardwareReachable).
    // providerPowerOff: set by SetPowerState(Off/Low), cleared by SetPowerState(On).
    // hwSuspended: the fast, IRQ-safe "no BAR access" flag. Set whenever the
    // provider powers down or the endpoint stops answering in config space;
    // cleared only by HardwareReachable() once it answers again. Both atomic.
    bool                       providerPowerOff;
    bool                       hwSuspended;
    bool                       suspendedByProbe;   // the current suspend came from an unanswering endpoint, not from power-down
    // AudioDriverKit — CoreAudio device and streams (PT-07)
    IOUserAudioDevice *audioDevice;
    IOUserAudioStream *inputStream;   // A2H (capture): FPGA → host
    IOUserAudioStream *outputStream;  // H2A (playback): host → FPGA
    bool               ioRunning;
    uint64_t           zeroTimestampSampleTime;

    // Volume/mute controls (for macOS volume HUD)
    IOUserAudioLevelControl   *outputVolumeControl;
    IOUserAudioBooleanControl *outputMuteControl;

    // Data source selector controls ("Source: Port 1: 32ch" dropdown)
    // Data source selectors removed — single-port device doesn't need them.
    // Re-add when Port 2 (dual Symphony IO) is implemented.
    float     lastVolumeDb;
    bool      lastMuteState;
    // Core Audio's single output volume/mute control follows the legacy
    // monitor target.  0 = speakers, 1 = Headphone 1 (Line mode).
    uint8_t   monitorOutputTarget;
    // Per-monitor state behind the single Core Audio volume/mute control.
    // Line mode selects HP1, while speaker modes select the speaker pair.
    uint8_t   speakerAttenuation;
    bool      speakerMute;
    uint8_t   hp1Attenuation;
    bool      hp1Mute;

    // Clock source selector control ('clck') — entitlement-free AudioDriverKit control.
    // coreaudiod drives it through the normal audio-HAL property path (the SAME channel
    // as volume/mute), NOT an IOUserClient, so it is unaffected by the userclient-access
    // block. Unlike volume/mute, a SELECTOR control does NOT reflect coreaudiod's write
    // through GetCurrentSelectedValues, so polling it from the IRQ never observes a
    // change (IOUserAudioSelectorControl.h:186-207). Instead the concrete control is a
    // SymphonyClockSelectorControl whose HandleChangeSelectedValues override PUSHES the
    // user's selection into RequestClockSource(), which sends ClockMode (0x50) on the
    // serial xlinkQueue using the same generation+CAS coalescing discipline as
    // volume/mute (the drain never blocks a real-time queue).
    IOUserAudioSelectorControl *clockSourceControl;
    uint32_t  pendingClockSource;   // latest source to write (producer=control queue, consumer=XLink)
    uint32_t  pendingClockGen;      // bumped on each new selection
    bool      clockTxScheduled;     // a clock drain block is scheduled or in-flight

    // ── Phantom power ('phan') + mic gain ('vlme'/Input) — per mic channel ────
    // These are per-mic-channel controls of the 8-channel MicPre8 option board.
    // numMicChannels is 0 unless a MicPre8 is POSITIVELY detected — the base
    // Symphony IO MKI ships with ZERO mic preamps, and the dext cannot yet read
    // the fitted option board (needs an XLink RX/response path — see Start()), so
    // per the "never guess a channel count" rule we default to 0 and publish
    // nothing. The subclass + send machinery below is fully wired and dormant
    // (loop count 0) until board detection sets numMicChannels = 8.
    //
    // Each per-channel control PUSHes its change into RequestPhantom/RequestMicGain,
    // which coalesce + async-send PhantomPower(0xC6)/MicGain(0xC3) on the serial
    // xlinkQueue using the SAME generation+CAS discipline as volume/mute/clock.
    // Coalescing state is parallel arrays indexed by channel — one independent
    // lane per channel — so each channel's latest value is never lost and every
    // lane's drain block serializes on the shared xlinkQueue (MSG_BYTE frames
    // never interleave; the invariant at the top of this struct holds per lane).
    uint32_t  numMicChannels;                       // 0 unless MicPre8 detected
    SymphonyPhantomControl *phantomControl[8];      // per-channel phantom ('phan')
    SymphonyMicGainControl *micGainControl[8];      // per-channel gain ('vlme'/Input)
    uint8_t   pendingPhantom[8];      uint32_t pendingPhantomGen[8];  bool phantomTxScheduled[8];
    uint8_t   pendingMicGain[8];      uint32_t pendingMicGainGen[8];  bool micGainTxScheduled[8];

    // ── Optical output format ('dsrc') — per fitted OPTICAL option board ──────
    // DataSourceControl selector on the Output scope, element = board+1,
    // exactly the legacy per-port 'AEof' layout (Port1=elem1/Port2=elem2 —
    // APAudioManagedObject.m:1596-1604). numOpticalBoards is 0/1/2, set at Start()
    // by reading OptionBoardType (0xA1) for board 0 and board 1 — a control is
    // published ONLY for a board that POSITIVELY reads Optical (==3), same
    // never-guess discipline as numMicChannels. Each SymphonyOpticalControl PUSHes
    // its change into RequestOpticalFormat, which coalesces + async-sends
    // OpticalFormat (0x34) per-board on the serial xlinkQueue using the SAME
    // generation+CAS discipline as volume/mute/clock/phantom (one lane per board).
    uint32_t  numOpticalBoards;                     // 0/1/2, from OptionBoardType(0),(1)

    // Raw OptionBoardType (0xA1) result per slot, captured by the same Start() loop
    // that decides numOpticalBoards. Kept so the app can learn which cards are
    // fitted over Thunderbolt (kSelectorReadBoardTypes) — over USB it reads 0xA1
    // itself through the proxy, but the TB path has no EP0 of its own and the dext
    // is the only thing that ever talks to the card. `valid` distinguishes "read
    // failed" from "slot reports empty": guessing between those silences real
    // outputs, so the app must be able to tell them apart.
    uint8_t   optionBoardType[2];
    bool      optionBoardTypeValid[2];
    SymphonyOpticalControl *opticalControl[2];      // per-board ('dsrc'), element = board+1
    uint8_t   pendingOpticalFmt[2];   uint32_t pendingOpticalGen[2];  bool opticalTxScheduled[2];

    // C2: control-write coalescing. The IRQ handler updates the latest target and,
    // only if a drain block is not already scheduled/in-flight, enqueues ONE drain
    // block on the serial xlinkQueue. The drain reads the current target and applies
    // it. A burst of volume/mute changes therefore collapses to at most one in-flight
    // plus one pending write → queue depth stays O(1), no unbounded control latency.
    // #4: cross-queue coalescing. Producer = IRQ queue, consumer = XLink queue.
    // All fields are accessed with __atomic_* intrinsics. Each producer bumps a
    // generation counter (RELEASE) after publishing the value; the drain snapshots
    // the generation, sends, clears 'scheduled' (RELEASE), then re-reads the
    // generation (ACQUIRE) — if it advanced, a value arrived mid-send and the drain
    // re-arms via a CAS on 'scheduled'. This makes lost-update and stale-scheduled
    // races impossible without confining the producer to the (blocking-unsafe) IRQ.
    uint8_t   pendingAtten;        // latest speaker attenuation to write (0..64)
    uint32_t  pendingVolumeGen;    // bumped by IRQ on each new attenuation
    bool      volumeTxScheduled;   // a volume drain block is scheduled or in-flight
    bool      pendingMuteState;    // latest mute state to write
    uint32_t  pendingMuteGen;      // bumped by IRQ on each new mute state
    bool      muteTxScheduled;     // a mute drain block is scheduled or in-flight
    double    lastSampleRate;  // Last SUCCESSFULLY programmed hardware sample rate
    double    xlinkRate;       // Rate actually broadcast to the XLink units (updated on
                               // every successful SetSampleRate broadcast, even if the
                               // subsequent lock/verify then failed). The DDS-rollback
                               // reference on a failed rate change — NOT lastSampleRate,
                               // which lags after a post-broadcast failure (Codex round 4).
    uint8_t   runtimeTxSeq;   // XLink message sequence for runtime commands
    uint8_t   symphonyAddr;   // XLink device address (1 for first Symphony IO)

    // In-place Symphony link recovery (see MaybeRecoverSymphonyLink).
    bool      symphonyLinkConfigured; // a Symphony answered and was configured (Start or recovery)
    bool      linkRecoveryNeedsIORestart; // set by a successful recovery; consumed by the next live probe
    uint32_t  consecutiveProbeFailures;   // failed live reads since the last success
    bool      linkFaultSeen;              // a probe saw the Symphony clock absent since the last success
    bool      linkRecoveryInFlight;   // atomic — a bus re-init block is queued/running
    uint32_t  linkRecoveryCooldown;   // failed probes to skip before the next attempt
    uint32_t  linkRecoveryCount;      // successful in-place recoveries since Start()
    uint32_t  lastLoggedNoClockReg;   // last XLinkClocking value logged while waiting

    // Vendor command custom property (AudioDriverKit path — no IOUserClient needed)
    IOUserAudioCustomProperty *vendorProperty;
    uint32_t vendorCmdSerial;   // Tracks which command was last processed

    // Diagnostic: IO operation handler call count
    uint64_t  ioOpCount;

    // Zero timestamp anchor: first IRQ after StartDevice delivers (0, hostTime)
    bool      firstTimestampAfterStart;

    // ── dext 113: driver-owned link watch (replaces the app's 1 Hz 0x51 probe) ──
    // See LinkWatchTimerOccurred. All fields below are touched on xlinkQueue except
    // where noted; the cross-queue ones are accessed with __atomic_* only.
    IOTimerDispatchSource *linkWatchTimer;     // on xlinkQueue; cancelled first in Stop()
    IODispatchQueue       *defaultQueue;       // for RequestDeviceConfigurationChange (never from xlinkQueue)
    uint64_t  audioWrapCount;          // atomic; A2H wraps delivered while IO ran (IRQ queue)
    uint64_t  lastWrapCountSeen;       // watch-local
    bool      linkClockPresent;        // watch-local: last decided XLink RX1 clock state
    uint32_t  linkState;               // atomic; kLinkState* for ReadLinkState
    uint32_t  lastWatchClockReg;       // watch-local: last kRegXLinkClocking sample
    uint64_t  linkWatchTicks;          // watch-local
    bool      linkNeedsRevalidation;   // atomic; set by SetPowerState(On), consumed by the watch
    bool      wakeFoundEndpointAbsent; // atomic; SetPowerState(On) saw no endpoint (tunnel lost)
    // dext 115: shadow of the card output routing table the app wrote through
    // kThunderboltCardOutputRouteCommand, replayed by ReprogramCardAfterReset.
    uint32_t  cardOutputRoute[32];
    bool      cardOutputRouteSet[32];
    // dext 116: whether the app has ever written mixer N's state (0xB0–0xB3).
    // Until it has, a re-init must write Start()'s unity defaults, not the
    // all-zero cached state (which silenced outputs 1-2 after wake, 12:18).
    bool      mixerStateValid[2];
    // dext 117: last registers the watch sampled + re-init count, for ReadLinkState.
    uint32_t  lastWatchGcsr;
    uint32_t  lastWatchXlinkStatus;
    uint32_t  cardReinitCount;
    // dext 119: configuration-change decision after a recovery is made on WHERE the
    // current IO run started relative to the DMA restart, not on what was true when
    // the recovery began (the wake tick and Core Audio's StartIO race either way).
    uint64_t  startDeviceSerial;        // ++ on every StartDevice (IO thread)
    uint64_t  reinitStartSerial;        // startDeviceSerial at the last card re-init
    bool      anchorPendingAtReinit;    // firstTimestampAfterStart at the last re-init
    bool      reinitSinceLastDecision;  // a re-init ran during this recovery
    bool      unmuteOnNextStart;        // card stays muted through an IO gap; StartDevice unmutes
};

// ── Helpers ─────────────────────────────────────────────────────────────────
// DriverKit MemoryRead32/Write32 return void. Reads write 0xFFFFFFFF on error.

static void ReadRegister(IOPCIDevice *dev, uint8_t memIndex,
                         uint64_t offset, uint32_t *value)
{
    dev->MemoryRead32(memIndex, offset, value);
}

static void WriteRegister(IOPCIDevice *dev, uint8_t memIndex,
                          uint64_t offset, uint32_t value)
{
    dev->MemoryWrite32(memIndex, offset, value);
}

// Read-modify-write: clears bits in ClearValues, then sets bits in SetValues.
// IMPORTANT: Clear-then-set order so SET wins when setBits and clearBits overlap.
// The legacy ModifyRegister (Symphony64Card.cpp:490) uses set-then-clear, which
// silently zeroes any field where the set value overlaps the clear mask. This
// affects DDS rate, clock source, frame size, and DMA channel count — all get
// written as 0 in the legacy code. Fixing the order here ensures correct values.
static void ModifyRegister(IOPCIDevice *dev, uint8_t memIndex,
                           uint64_t offset, uint32_t setBits, uint32_t clearBits)
{
    uint32_t val = 0;
    dev->MemoryRead32(memIndex, offset, &val);
    val &= ~clearBits;
    val |= setBits;
    dev->MemoryWrite32(memIndex, offset, val);
}

// ── Endpoint reachability (dext 112) ─────────────────────────────────────────
// A ThunderBridge behind a Thunderbolt tunnel can lose power without the PCI
// nub being terminated first: a unit power-cycled while the Mac sleeps still
// has its BAR window mapped into this process at wake, and on Apple Silicon a
// LOAD from that window with the endpoint gone is not "0xFFFFFFFF" — it is an
// uncorrectable "LLC Bus error ... acc_cifl2c_cmd_rd_ld" and the KERNEL PANICS
// (field report 2026-10-23: FAR = BAR0+0x3C = kRegXLink1RX, the first read of
// ReadVendorRequest, issued by the app's 1 Hz health probe in the same second
// the Mac woke). Config-space reads go through the kernel's PCI bridge driver
// and come back all-ones when the link is down, so they are the safe presence
// test (IOPCIFamily's own checkLink() does the same). MemSpace must be set too:
// a unit that re-powered on the same nub has a reset PCI config, and decoding
// a BAR with Memory Space disabled is the same fatal load.
static bool PCIEndpointPresent(IOPCIDevice *dev)
{
    uint32_t id = 0xFFFFFFFFu;
    dev->ConfigurationRead32(0x00, &id);
    const uint16_t vendor = (uint16_t)(id & 0xFFFF);
    const uint16_t device = (uint16_t)((id >> 16) & 0xFFFF);
    if (vendor != kApogeeVendorID ||
        (device != kThunderBridgeDeviceID && device != kSymphonyPCIeDeviceID))
        return false;
    uint16_t cmd = 0;
    dev->ConfigurationRead16(0x04, &cmd);
    return (cmd & 0x0002) != 0;   // Memory Space Enable
}

// True when BAR access is allowed right now. Maintains hwSuspended: sets it
// when the provider is powering down or the endpoint has stopped answering,
// clears it once the endpoint answers again with the provider on — so a wake
// whose SetPowerState(On) arrived before the tunnel came back self-heals on
// the next probe. Costs two kernel round-trips; never call it from the IRQ
// queue (that path reads hwSuspended only).
static bool HardwareReachable(SymphonyThunderbridge_IVars *ivars)
{
    if (!ivars || !ivars->pciDevice) return false;
    if (__atomic_load_n(&ivars->stopping, __ATOMIC_ACQUIRE)) return false;
    if (__atomic_load_n(&ivars->providerPowerOff, __ATOMIC_ACQUIRE)) {
        __atomic_store_n(&ivars->hwSuspended, true, __ATOMIC_RELEASE);
        return false;
    }
    if (!PCIEndpointPresent(ivars->pciDevice)) {
        ivars->suspendedByProbe = true;
        if (!__atomic_exchange_n(&ivars->hwSuspended, true, __ATOMIC_ACQ_REL))
            STLOG("Endpoint not answering in PCI config space — BAR access suspended");
        return false;
    }
    if (__atomic_load_n(&ivars->hwSuspended, __ATOMIC_ACQUIRE)) {
        __atomic_store_n(&ivars->hwSuspended, false, __ATOMIC_SEQ_CST);
        // Dekker check (review item 1): SetPowerState(Off) may have stored
        // providerPowerOff=true, hwSuspended=true between our load at the top and
        // the clear above. Both sides use SEQ_CST so this store→load pair cannot
        // reorder: either we see its providerPowerOff and re-suspend here, or our
        // clear is ordered before its hwSuspended=true store and loses.
        if (__atomic_load_n(&ivars->providerPowerOff, __ATOMIC_SEQ_CST)) {
            __atomic_store_n(&ivars->hwSuspended, true, __ATOMIC_SEQ_CST);
            return false;
        }
        // Resume. While suspended the IRQ handler returned without acknowledging
        // kRegIntStatus, so clear it now (a posted write on an endpoint we just
        // proved present) so the FPGA re-raises MSI on the next wrap, and ask the
        // next live probe to re-anchor Core Audio's timestamps (same mechanism as
        // the in-place link recovery).
        WriteRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegIntStatus, 0xFFFFFFFF);
        // Re-anchor ONLY when the suspend came from an endpoint that stopped
        // answering (review pass 2, item 4). On an ordinary sleep/wake the HAL
        // already issues StartIO → StartDevice → fresh anchor; asking for a
        // configuration change as well would add a redundant IO restart and an
        // audible dropout on every wake.
        if (ivars->suspendedByProbe && ivars->symphonyLinkConfigured)
            ivars->linkRecoveryNeedsIORestart = true;
        ivars->suspendedByProbe = false;
        STLOG("Endpoint answering again — BAR access resumed (IRQ status cleared)");
    }
    return true;
}

// Admission check for every block on the serial xlinkQueue (and the rate
// transaction) that touches the card. Replaces the former
// txShutdown/stopping/pciDevice triple with the same checks plus reachability.
static bool XLinkTxAdmissible(SymphonyThunderbridge_IVars *ivars)
{
    if (!ivars) return false;
    if (__atomic_load_n(&ivars->txShutdown, __ATOMIC_ACQUIRE) ||
        __atomic_load_n(&ivars->stopping, __ATOMIC_ACQUIRE) ||
        !ivars->pciDevice)
        return false;
    return HardwareReachable(ivars);
}

// Stop()-time variant: 'stopping' is already set, so ask only whether the
// endpoint is still there to receive the mute/DMA-off/IRQ-mask teardown writes
// (ModifyRegister is a read-modify-write — a read on a vanished unit is fatal).
static bool EndpointPresentForTeardown(SymphonyThunderbridge_IVars *ivars)
{
    if (!ivars || !ivars->pciDevice) return false;
    if (__atomic_load_n(&ivars->providerPowerOff, __ATOMIC_ACQUIRE)) return false;
    // Deliberately NOT short-circuited on hwSuspended (review item 2): a stale
    // suspend (wake with no app running to re-probe) must not make Stop() skip
    // the DMA-off/IRQ-mask writes on a unit that is in fact alive — that reopens
    // the DART-fault window step 10b exists to close. Config space decides.
    if (!PCIEndpointPresent(ivars->pciDevice)) {
        ivars->suspendedByProbe = true;
        __atomic_store_n(&ivars->hwSuspended, true, __ATOMIC_RELEASE);
        return false;
    }
    return true;
}

// ── XLink Command Protocol ─────────────────────────────────────────────────
// XLink TX register command format (XLinkRegisters.h:84-103, XLink.cpp:2263-2280):
//   bit[23]     = Sym2Sym transmit indicator (0 for normal)
//   bit[22..17] = target device address (0 = broadcast to all)
//   bit[16..9]  = command code
//   bit[8..1]   = command data
//   bit[0]      = 0 (valid command indicator)

static constexpr uint32_t kXLinkCmdBusyBit        = 0x80000000;
// XLINK_CMD_RX_EMPTY (XLinkRegisters.h:74). Same bit as the TX busy bit but on the
// RX register (kRegXLink1RX): set ⇒ the RX FIFO is empty. Read/response path.
static constexpr uint32_t kXLinkCmdRxEmpty         = 0x80000000;
static constexpr uint8_t  kXLinkCmdAddrAll         = 0x00;  // Broadcast
static constexpr uint8_t  kXLinkCmdSetAddr         = 0x01;
static constexpr uint8_t  kXLinkCmdPassCommands    = 0x02;
static constexpr uint8_t  kXLinkCmdSetSampleRate   = 0x03;
static constexpr uint8_t  kXLinkCmdSetExtLock      = 0x04;
static constexpr uint8_t  kXLinkCmdUnmute          = 0x0A;
static constexpr uint8_t  kXLinkCmdMsgByte         = 0x10;  // Multi-byte message transport

// Sample rate codes (XLinkRegisters.h:220-225)
static constexpr uint8_t  kXLinkSRate44100         = 0x04;
static constexpr uint8_t  kXLinkSRate48000         = 0x00;
static constexpr uint8_t  kXLinkSRate88200         = 0x05;
static constexpr uint8_t  kXLinkSRate96000         = 0x01;
static constexpr uint8_t  kXLinkSRate176400        = 0x06;
static constexpr uint8_t  kXLinkSRate192000        = 0x02;

static kern_return_t FirstTimingFailure(kern_return_t a, kern_return_t b,
                                        kern_return_t c, kern_return_t d)
{
    if (a != kIOReturnSuccess) return a;
    if (b != kIOReturnSuccess) return b;
    if (c != kIOReturnSuccess) return c;
    return d;
}

static kern_return_t ApplyAudioTimingProfile(IOUserAudioDevice *audioDevice, double rate)
{
    if (!audioDevice) return kIOReturnBadArgument;
    const TimingProfile profile = TimingProfileForRate(rate);
    const kern_return_t inputSafety = audioDevice->SetInputSafetyOffset(profile.safetyOffset);
    const kern_return_t outputSafety = audioDevice->SetOutputSafetyOffset(profile.safetyOffset);
    const uint32_t inputLatencyFrames = profile.inputConverterLatency + profile.frameSize;
    const uint32_t outputLatencyFrames = profile.outputConverterLatency + profile.frameSize;
    const kern_return_t inputLatency = audioDevice->SetInputLatency(inputLatencyFrames);
    const kern_return_t outputLatency = audioDevice->SetOutputLatency(outputLatencyFrames);
    const uint32_t readbackInputSafety = audioDevice->GetInputSafetyOffset();
    const uint32_t readbackOutputSafety = audioDevice->GetOutputSafetyOffset();
    const uint32_t readbackInputLatency = audioDevice->GetInputLatency();
    const uint32_t readbackOutputLatency = audioDevice->GetOutputLatency();
    const bool readbackMatches =
        readbackInputSafety == profile.safetyOffset &&
        readbackOutputSafety == profile.safetyOffset &&
        readbackInputLatency == inputLatencyFrames &&
        readbackOutputLatency == outputLatencyFrames;
    STLOG("Timing profile %.0f Hz: frame=%u safety=(%u,%u) publishedLatency=(%u,%u) setters=(0x%x,0x%x,0x%x,0x%x) readback safety=(%u,%u) latency=(%u,%u)",
          rate, profile.frameSize, profile.safetyOffset, profile.safetyOffset,
          inputLatencyFrames, outputLatencyFrames,
          inputSafety, outputSafety, inputLatency, outputLatency,
          readbackInputSafety, readbackOutputSafety,
          readbackInputLatency, readbackOutputLatency);
    const kern_return_t setterResult =
        FirstTimingFailure(inputSafety, outputSafety, inputLatency, outputLatency);
    if (setterResult != kIOReturnSuccess) return setterResult;
    if (!readbackMatches) {
        STERR("Timing profile %.0f Hz readback mismatch — refusing publication", rate);
        return kIOReturnError;
    }
    return kIOReturnSuccess;
}

// Clock source (Sym64Registers.h:282-287)
// Custom IOUserAudioDevice configuration-change action: the XLink link was
// re-established in place after a Symphony power cycle. The host stops IO,
// calls PerformDeviceConfigurationChange, then restarts IO through
// StartDevice(), which resets the zero-timestamp anchor. Without this the
// anchor keeps the pre-outage sample time while host time has jumped by the
// whole outage, and the HAL audibly re-syncs every few seconds ("CD skip").
// Legacy equivalent: ThreadXLink forcing a full sample-rate re-apply after
// BusInit() (XLink.cpp:270-283). Value is private to the driver ('LNKR').
static constexpr uint64_t kSymphonyConfigChangeLinkRecovered = 0x4C4E4B52ULL;
// Consecutive failed probes with the clock present before a link that never
// went through NO_CLOCK is treated as genuinely stuck and re-initialized.
static constexpr uint32_t kLinkRecoveryStuckProbes = 5;

static constexpr uint32_t kSampleSourceNone        = 0x00000000;
static constexpr uint32_t kSampleSourceXLink1      = 0x00000100;
static constexpr uint32_t kSampleSourceMask        = 0x00000F00;

// ── Symphony IO Vendor Commands ──────────────────────────────────────────
// SymphonyIOVendorSpecific.h — commands sent via the XLink control message pipe.

static constexpr uint8_t kSIOCmd_SpeakerMode          = 0x25;  // 1 byte: 2=stereo
static constexpr uint8_t kSIOCmd_SpeakerVolume        = 0x26;  // 1 byte: attenuation in dB
static constexpr uint8_t kSIOCmd_SpeakerMute          = 0x27;  // 1 byte: 0=unmuted, 1=muted
static constexpr uint8_t kSIOCmd_ActiveSpeakerSet     = 0xE9;  // 1 byte: A=bit0, B=bit1, C=bit2
static constexpr uint8_t kSIOCmd_HeadphoneVolume      = 0x23;  // 1 byte: nValue=HP index, attenuation in dB
static constexpr uint8_t kSIOCmd_HeadphoneMute        = 0x24;  // 1 byte: nValue=HP index, 0=unmuted, 1=muted
static constexpr uint8_t kSIOCmd_AudioRouting          = 0x31;  // N×2 bytes: [dest, src] pairs
static constexpr uint8_t kSIOCmd_OpticalFormat         = 0x34;  // 1 byte: 0=ADAT/SMUX, 1=SPDIF. nValue=board index (0 or 1).
static constexpr uint8_t kSIOCmd_ClockMode             = 0x50;  // 4 bytes: clock source config
static constexpr uint8_t kSIOCmd_MixerFaderLevel       = 0xB0;  // 1 byte: dB+48 (0..48). nValue=(mixer<<16)|channel.
static constexpr uint8_t kSIOCmd_MixerInputPan         = 0xB1;  // 1 byte: (pan+1)*64 (0..128). nValue=(mixer<<16)|channel.
static constexpr uint8_t kSIOCmd_MixerInputSolo        = 0xB2;  // 1 byte: 0=off, 1=solo. nValue=(mixer<<16)|channel.
static constexpr uint8_t kSIOCmd_MixerInputMute        = 0xB3;  // 1 byte: 0=unmuted, 1=muted. nValue=(mixer<<16)|channel.
static constexpr uint16_t kMixerChSwReturn             = 1000;  // app SW-Return strip channel id (kSymphonyIOMixerChannelID_SoftwareReturnInput)
static constexpr uint16_t kMixerChMaster              = 2000;  // app Master strip channel id (kSymphonyIOMixerChannelID_MasterOutput)
static constexpr uint16_t kMixerChSwReturnLeft        = 0x1001;
static constexpr uint16_t kMixerChSwReturnRight       = 0x1002;
static constexpr uint16_t kMixerChMasterLeft          = 0x2001;
static constexpr uint16_t kMixerChMasterRight         = 0x2002;
static constexpr uint8_t kSIOCmd_MicGain               = 0xC3;  // 1 byte: gain 0..85. nValue=0-based mic channel.
static constexpr uint8_t kSIOCmd_PhantomPower          = 0xC6;  // 1 byte: 0=off, 1=on. nValue=0-based mic channel.
static constexpr uint8_t kSIOCmd_ResetDefaultRouting   = 0xC2;  // no payload
static constexpr uint8_t kSIOCmd_PreferenceLoadLock    = 0xDD;  // 1 byte: 1=lock/mute, 0=unlock

// Read-only vendor commands (request/RESPONSE, bmRequestType 0xC0 → ReadVendorRequest).
static constexpr uint8_t kSIOCmd_OptionBoardType       = 0xA1;  // read 1 byte. nValue: 0=primary, 1=secondary. Returns SymphonyIOOptionBoardType.
static constexpr uint8_t kSIOCmd_ClockRateAndLock      = 0x51;  // read 5 bytes: [0]=lock(0/1), [1..4]=uint32 BE measured rate Hz (clk[1]=MSB).

// SymphonyIOOptionBoardType (SymphonyIOVendorSpecific.h:805-812). MicPre8 == the
// 8-channel mic-preamp option board; every other value has ZERO mic-pre channels.
static constexpr uint8_t kSIOOptionBoard_None     = 0;
static constexpr uint8_t kSIOOptionBoard_MicPre8  = 1;
// Option-board types with a selectable optical format. AD16/DA16 and 2x6 also
// expose optical I/O even though they are not reported as the legacy type-3
// Optical board. The format command is direction-agnostic on the wire.
static constexpr uint8_t kSIOOptionBoard_Optical  = 3;
static constexpr uint8_t kSIOOptionBoard_AnalogAES = 2;
static constexpr uint8_t kSIOOptionBoard_AnalogAD16 = 4;
static constexpr uint8_t kSIOOptionBoard_AnalogDA16 = 5;
static constexpr uint8_t kSIOOptionBoard_TwoBySix = 7;

static constexpr bool BoardHasOpticalFormat(uint8_t boardType)
{
    return boardType == kSIOOptionBoard_AnalogAES ||
           boardType == kSIOOptionBoard_Optical ||
           boardType == kSIOOptionBoard_AnalogAD16 ||
           boardType == kSIOOptionBoard_AnalogDA16 ||
           boardType == kSIOOptionBoard_TwoBySix;
}

// MicPre8 option board (SymphonyIOVendorSpecific.h:1060-1064). 8 mic channels,
// gain 0..85 dB. Present ONLY when the MicPre8 option board is fitted — the base
// Symphony IO MKI has ZERO mic preamps, so numMicChannels stays 0 (see Start()).
static constexpr uint32_t kMicPre8NumChannels = 8;
static constexpr float    kMicGainMinDb       = 0.0f;
static constexpr float    kMicGainMaxDb       = 85.0f;

// ── Symphony IO Routing Constants ────────────────────────────────────────
// SymphonyIORouting.h — destination and source addresses for the Symphony IO
// internal crosspoint router. These route audio WITHIN the Symphony IO (not
// on the ThunderBridge FPGA, which has its own routing registers).

// Destinations: where audio goes TO on the Symphony IO
static constexpr uint8_t kSIODest_XLinkCh0       = 0x00;  // XLink TX ch 0 (NOT used for capture — use P2P instead)
static constexpr uint8_t kSIODest_IOBoard0Ch0    = 0x20;  // IOBoard 0 DAC ch 0 (analog out 1)
static constexpr uint8_t kSIODest_IOBoard1Ch0    = 0x30;  // IOBoard 1 DAC ch 0 (analog out 17)
static constexpr uint8_t kSIODest_P2PCh0         = 0xC0;  // P2P ch 0 — abstract host interface (capture → ThunderBridge via XLink)
static constexpr uint8_t kSIODest_Mix0SWReturnL  = 0xE4;  // Mixer0 AppInput Ch0 (SW Return Left)
static constexpr uint8_t kSIODest_Mix0SWReturnR  = 0xE5;  // Mixer0 AppInput Ch1 (SW Return Right)

// Sources: where audio comes FROM on the Symphony IO
static constexpr uint8_t kSIOSrc_XLinkCh0        = 0x00;  // XLink RX ch 0 (from ThunderBridge playback)
static constexpr uint8_t kSIOSrc_IOBoard0Ch0     = 0x20;  // IOBoard 0 ADC ch 0 (analog in 1)
static constexpr uint8_t kSIOSrc_IOBoard1Ch0     = 0x30;  // IOBoard 1 ADC ch 0 (analog in 17)
static constexpr uint8_t kSIOSrc_Mix0OutL        = 0x40;  // Mixer0 Output Ch0 (Master Left)
static constexpr uint8_t kSIOSrc_Mix0OutR        = 0x41;  // Mixer0 Output Ch1 (Master Right)
static constexpr uint8_t kSIOSrc_P2PCh0          = 0xC0;  // P2P ch 0 — abstract host interface (from ThunderBridge playback via XLink)
static constexpr uint8_t kSIOSrc_None            = 0xEC;  // Digital silence (null route)

// ── CRC8 (polynomial 0x8380) ────────────────────────────────────────────
// Matches Crc8.cpp in og_source — used by SimpleMessageProtocol framing.

static uint8_t ComputeCRC8(const uint8_t *data, uint32_t len)
{
    uint8_t crc = 0;
    for (uint32_t i = 0; i < len; i++) {
        uint16_t nData = (uint16_t)((crc ^ data[i]) << 8);
        for (int bit = 0; bit < 8; bit++) {
            if (nData & 0x8000)
                nData ^= 0x8380;
            nData <<= 1;
        }
        crc = (uint8_t)(nData >> 8);
    }
    return crc;
}

// Send an XLink command via the TX register.
// Returns true if the command was sent (busy bit cleared within timeout).
static bool SendXLinkCommand(IOPCIDevice *dev, uint8_t memIndex,
                              uint8_t addr, uint8_t cmd, uint8_t data)
{
    // Wait for TX busy bit to clear (max 100ms)
    for (int i = 0; i < 100; i++) {
        uint32_t txReg = 0;
        dev->MemoryRead32(memIndex, kRegXLink1TX, &txReg);
        if (!(txReg & kXLinkCmdBusyBit))
            goto send;
        IOSleep(1);
    }
    return false;  // Timeout

send:
    // Format: [sym2sym:1][addr:6][cmd:8][data:8][valid:1] — all shifted left 1, bit0=0
    uint32_t val = 0;               // sym2sym = 0
    val <<= 6;
    val |= (addr & 0x3F);
    val <<= 8;
    val |= cmd;
    val <<= 8;
    val |= data;
    val <<= 1;
    val &= 0xFFFFFE;                // Ensure bit 0 = 0 (valid)

    // Regular commands (UNMUTE, SetAddr, etc.) are written twice (legacy XLink.cpp:2281-2283).
    // MSG_BYTE commands are written ONCE (legacy SendMessageBytes XLink.cpp:1610).
    // Double-writing MSG_BYTE corrupts SimpleMessageProtocol framing on the receiver.
    dev->MemoryWrite32(memIndex, kRegXLink1TX, val);
    if (cmd != kXLinkCmdMsgByte)
        dev->MemoryWrite32(memIndex, kRegXLink1TX, val);
    return true;
}

// ── Symphony IO Control Protocol ──────────────────────────────────────────
// Three-layer protocol for sending vendor commands to the Symphony IO:
//
// Layer 3: Control Protocol request (USB-like struct serialization)
//   [bmRequestType:1][bRequest:1][nValue:4 LE][wLength:2 LE][data:0-64]
//
// Layer 2: SimpleMessage framing (og_source SimpleMessageProtocol.cpp)
//   [0x80:1][size:1][txSeq:1][control_data:N][CRC8:1]
//
// Layer 1: XLink MSG_BYTE transport — each byte sent via XLINK_CMD_MSG_BYTE (0x10)
//   using SendXLinkCommand(dev, memIdx, addr, 0x10, byte)

// Send a vendor write command to a device on the XLink bus.
// This implements the full SimpleControlProtocolSymphony stack from the legacy daemon.
// Returns true if all bytes were transmitted successfully.
static bool SendVendorRequest(IOPCIDevice *dev, uint8_t memIndex,
                              uint8_t xlinkAddr, uint8_t command,
                              uint32_t value, const uint8_t *payload, uint16_t payloadLen,
                              uint8_t &txSequence)
{
    // ── Layer 3: Serialize control protocol request ──────────────────────
    // Matches SimpleControlProtocolRequestSerializeOut() in og_source.
    // bmRequestType = 0x40 = vendor OUT to device (matches SMCPmakebmRequestType)
    uint8_t controlData[80];
    uint32_t controlLen = 0;

    controlData[controlLen++] = 0x40;                            // bmRequestType: vendor OUT
    controlData[controlLen++] = command;                         // bRequest
    controlData[controlLen++] = (uint8_t)((value >>  0) & 0xFF); // nValue LE byte 0
    controlData[controlLen++] = (uint8_t)((value >>  8) & 0xFF); // nValue LE byte 1
    controlData[controlLen++] = (uint8_t)((value >> 16) & 0xFF); // nValue LE byte 2
    controlData[controlLen++] = (uint8_t)((value >> 24) & 0xFF); // nValue LE byte 3
    controlData[controlLen++] = (uint8_t)((payloadLen >> 0) & 0xFF); // wLength LE byte 0
    controlData[controlLen++] = (uint8_t)((payloadLen >> 8) & 0xFF); // wLength LE byte 1
    // Append data payload (for write requests only)
    for (uint16_t i = 0; i < payloadLen; i++)
        controlData[controlLen++] = payload[i];

    // ── Layer 2: SimpleMessage framing ───────────────────────────────────
    // Matches SimpleMessageProtocol::SendMessage() in og_source.
    // Request message: [0x80][size][txSeq][data...][CRC8]
    uint8_t message[88];
    uint32_t msgLen = 0;

    message[msgLen++] = 0x80;                    // MessageType_Request
    message[msgLen++] = (uint8_t)controlLen;     // data size
    message[msgLen++] = txSequence++;            // TX sequence number
    for (uint32_t i = 0; i < controlLen; i++)
        message[msgLen++] = controlData[i];
    // CRC8 covers all bytes so far (type + size + seq + data)
    message[msgLen] = ComputeCRC8(message, msgLen);
    msgLen++;

    // ── Layer 1: XLink MSG_BYTE transport ────────────────────────────────
    // Matches XLink::SendMessageBytes() — each byte via XLINK_CMD_MSG_BYTE.
    for (uint32_t i = 0; i < msgLen; i++) {
        if (!SendXLinkCommand(dev, memIndex, xlinkAddr,
                               kXLinkCmdMsgByte, message[i])) {
            STERR("VendorRequest: MSG_BYTE timeout at byte %u/%u (cmd=0x%02x)",
                  i, msgLen, command);
            return false;
        }
    }

    STLOG("VendorRequest: sent cmd=0x%02x, %u payload bytes, %u total MSG_BYTE frames",
          command, payloadLen, msgLen);
    return true;
}

// ── XLink RX / SimpleMessageProtocol Response path ───────────────────────────
// The read half of a vendor request/response transaction. A READ is the SAME
// MSG_BYTE request frame as a write, but with bmRequestType = 0xC0 (vendor IN)
// instead of 0x40; the device then streams a Response frame back through the
// XLink1 RX register (kRegXLink1RX). We drain that FIFO, extract the data byte
// from each MSG_BYTE word, and reassemble the Response frame.
//
// Response frame (SimpleMessageProtocol.cpp:349-365, receiver :90-262):
//   [0xC3][size][txSeq][reqMsgID][data × size][CRC8]   — 4 header bytes.
// (A request frame has only 3 header bytes; a Response inserts an extra
// reqMsgID byte between the sequence byte and the data.) CRC8 covers
// type+size+txSeq+reqMsgID+data and is compared against the trailing byte.

// Pop one 24-bit word from the XLink1 RX FIFO.
// ThunderBridge 3-access sequence (legacy XLink::RX_FIFO_ReadHW, XLink.cpp:2143-2191):
//   read #1 (probe) → if RX_EMPTY, done → write 0 (pop/advance) → read #2 (the word).
// Returns true and *outWord when a word was popped; false when the FIFO is empty.
static bool ReadXLinkRXWord(IOPCIDevice *dev, uint8_t memIndex, uint32_t *outWord)
{
    uint32_t data = 0;
    dev->MemoryRead32(memIndex, kRegXLink1RX, &data);    // read #1: probe
    if (data & kXLinkCmdRxEmpty)
        return false;                                     // FIFO empty
    dev->MemoryWrite32(memIndex, kRegXLink1RX, 0);        // pop / advance FIFO
    dev->MemoryRead32(memIndex, kRegXLink1RX, &data);     // read #2: the actual word
    data &= ~kXLinkCmdRxEmpty;
    *outWord = data;
    return true;
}

// Byte-at-a-time reassembler for a SimpleMessageProtocol Response frame.
// Mirrors DriverProcessIncomingData()'s 0xC3 state machine. Feed it the
// XLINK_DATA_DATA byte of each MSG_BYTE RX word; feed() returns true once a
// complete, CRC-valid frame has arrived, leaving the control payload in buf[0..size).
struct SmpResponseParser {
    enum State { Sync, Size, Seq, ReqId, Data, Crc };
    State    state = Sync;
    uint8_t  buf[80];              // reassembled control payload (data × size)
    uint8_t  size = 0;
    uint8_t  idx  = 0;
    uint8_t  crcBuf[80];          // bytes the CRC covers: type+size+seq+reqId+data
    uint8_t  crcLen = 0;

    bool feed(uint8_t b) {
        switch (state) {
        case Sync:
            if (b != 0xC3) return false;              // resync on start byte 0xC3
            crcLen = 0; crcBuf[crcLen++] = b; state = Size; break;
        case Size:
            if (b > 64) { state = Sync; return false; }  // MaxDataSize guard
            size = b; idx = 0; crcBuf[crcLen++] = b; state = Seq; break;
        case Seq:
            crcBuf[crcLen++] = b; state = ReqId; break;   // device txSeq (value ignored)
        case ReqId:
            crcBuf[crcLen++] = b; state = size ? Data : Crc; break;  // response-only byte
        case Data:
            buf[idx++] = b; crcBuf[crcLen++] = b;
            if (idx >= size) state = Crc;
            break;
        case Crc: {
            bool ok = (b == ComputeCRC8(crcBuf, crcLen));
            state = Sync;
            return ok;
        }
        }
        return false;
    }
};

// Issue a vendor READ (bmRequestType 0xC0) and collect the Response payload.
// Sends the request as MSG_BYTE frames (like SendVendorRequest but IN direction),
// then polls kRegXLink1RX with a BOUNDED timeout (~200 ms, mirroring the legacy
// SYMPHONYIO_GET_TIMEOUT_MSEC and WaitForLock's IOSleep-poll pattern), reassembles
// the Response frame, verifies CRC8, and copies wLength data bytes (which begin at
// control-payload offset 8, right after the 8-byte control header) into outData.
//
// Runs at Start()/board-detect time on the XLink init path — NOT the IRQ queue —
// so the bounded IOSleep polling here is acceptable (same as WaitForLock).
// Returns true on a verified response; false on TX failure or timeout.
static bool ReadVendorRequest(IOPCIDevice *dev, uint8_t memIndex,
                              uint8_t xlinkAddr, uint8_t command,
                              uint32_t value, uint8_t *outData, uint16_t outLen,
                              uint8_t &txSequence)
{
    // ── Layer 3: control request, bmRequestType = 0xC0 (vendor IN / read) ──
    // The legacy SerializeOut tests bit 0 (ReadMask 0x01), not the direction bit 7,
    // so 0xC0 still appends wLength payload bytes; the device ignores them on a read.
    // We append wLength ZERO bytes so size/CRC match what the firmware expects.
    uint8_t  controlData[80];
    uint32_t controlLen = 0;
    controlData[controlLen++] = 0xC0;                            // bmRequestType: vendor IN
    controlData[controlLen++] = command;                         // bRequest
    controlData[controlLen++] = (uint8_t)((value >>  0) & 0xFF); // nValue LE
    controlData[controlLen++] = (uint8_t)((value >>  8) & 0xFF);
    controlData[controlLen++] = (uint8_t)((value >> 16) & 0xFF);
    controlData[controlLen++] = (uint8_t)((value >> 24) & 0xFF);
    controlData[controlLen++] = (uint8_t)((outLen   >> 0) & 0xFF); // wLength LE
    controlData[controlLen++] = (uint8_t)((outLen   >> 8) & 0xFF);
    for (uint16_t i = 0; i < outLen; i++)
        controlData[controlLen++] = 0;                           // read: don't-care payload

    // ── Layer 2: request frame [0x80][size][txSeq][control...][CRC8] ──
    uint8_t  message[88];
    uint32_t msgLen = 0;
    message[msgLen++] = 0x80;                    // MessageType_Request
    message[msgLen++] = (uint8_t)controlLen;     // data size
    message[msgLen++] = txSequence++;            // TX sequence number
    for (uint32_t i = 0; i < controlLen; i++)
        message[msgLen++] = controlData[i];
    message[msgLen] = ComputeCRC8(message, msgLen);
    msgLen++;

    // Drain any stale RX words before issuing the request.
    {
        uint32_t junk = 0;
        while (ReadXLinkRXWord(dev, memIndex, &junk)) { /* discard */ }
    }

    // ── Layer 1: send each byte via MSG_BYTE ──
    for (uint32_t i = 0; i < msgLen; i++) {
        if (!SendXLinkCommand(dev, memIndex, xlinkAddr,
                               kXLinkCmdMsgByte, message[i])) {
            STERR("ReadVendorRequest: MSG_BYTE timeout at byte %u/%u (cmd=0x%02x)",
                  i, msgLen, command);
            return false;
        }
    }
    STLOG("ReadVendorRequest: sent READ cmd=0x%02x nValue=%u wLength=%u (%u MSG_BYTE frames)",
          command, value, outLen, msgLen);

    // ── Poll RX up to 200 ms; feed MSG_BYTE data bytes into the parser ──
    SmpResponseParser parser;
    for (int ms = 0; ms < 200; ms++) {
        uint32_t word = 0;
        while (ReadXLinkRXWord(dev, memIndex, &word)) {
            uint8_t cmdField = (uint8_t)((word >> 9) & 0xFF);   // XLINK_DATA_CMD
            if (cmdField != kXLinkCmdMsgByte)
                continue;                                        // ignore non-message words
            uint8_t rxByte = (uint8_t)((word >> 1) & 0xFF);      // XLINK_DATA_DATA
            if (parser.feed(rxByte)) {
                // Frame complete + CRC OK. Control payload layout:
                //   [bmReqType][bReq][nValue:4][wLength:2][data...] — data at offset 8.
                STLOG("ReadVendorRequest: cmd=0x%02x RESPONSE ok, size=%u, "
                      "raw[0..3]=%02x %02x %02x %02x",
                      command, parser.size,
                      parser.size > 0 ? parser.buf[0] : 0,
                      parser.size > 1 ? parser.buf[1] : 0,
                      parser.size > 2 ? parser.buf[2] : 0,
                      parser.size > 3 ? parser.buf[3] : 0);
                if (parser.size < (uint8_t)(8u + outLen)) {
                    STERR("ReadVendorRequest: cmd=0x%02x short payload (size=%u < %u)",
                          command, parser.size, 8u + outLen);
                    return false;
                }
                for (uint16_t i = 0; i < outLen; i++)
                    outData[i] = parser.buf[8 + i];
                return true;
            }
        }
        IOSleep(1);
    }
    STERR("ReadVendorRequest: cmd=0x%02x TIMEOUT (no valid response in 200 ms)", command);
    return false;
}

// ── Sample Rate Change ──────────────────────────────────────────────────────
// Maps a CoreAudio sample rate (double) to an XLink rate code.
// Returns 0xFF if the rate is unsupported.

static uint8_t SampleRateToXLinkCode(double rate)
{
    if (rate >= 44000.0 && rate <= 44200.0) return kXLinkSRate44100;
    if (rate >= 47900.0 && rate <= 48100.0) return kXLinkSRate48000;
    if (rate >= 88100.0 && rate <= 88300.0) return kXLinkSRate88200;
    if (rate >= 95900.0 && rate <= 96100.0) return kXLinkSRate96000;
    if (rate >= 176300.0 && rate <= 176500.0) return kXLinkSRate176400;
    if (rate >= 191900.0 && rate <= 192100.0) return kXLinkSRate192000;
    return 0xFF;
}

// Maps a sample rate (Hz) to the expected XLinkClocking register detection bit.
static uint32_t SampleRateToClockDetectBit(double rate)
{
    if (rate >= 44000.0 && rate <= 44200.0) return kXLinkSRDetect1_44100;
    if (rate >= 47900.0 && rate <= 48100.0) return kXLinkSRDetect1_48000;
    if (rate >= 88100.0 && rate <= 88300.0) return kXLinkSRDetect1_88200;
    if (rate >= 95900.0 && rate <= 96100.0) return kXLinkSRDetect1_96000;
    if (rate >= 176300.0 && rate <= 176500.0) return kXLinkSRDetect1_176400;
    if (rate >= 191900.0 && rate <= 192100.0) return kXLinkSRDetect1_192000;
    return 0;
}

// Maps a sample rate to the GCSR DDS (Direct Digital Synthesizer) register value.
// Legacy: XLink.cpp:920-947 — SetDDSSampleRate().
// The DDS provides the FPGA's internal clock reference. Must be set to match the
// actual sample rate when the ThunderBridge receives its clock from Symphony IO (Sym2Sym).
static uint32_t SampleRateToDDS(double rate)
{
    if (rate >= 44000.0 && rate <= 44200.0) return kGCSR_DDS_44100;
    if (rate >= 47900.0 && rate <= 48100.0) return kGCSR_DDS_48000;
    if (rate >= 88100.0 && rate <= 88300.0) return kGCSR_DDS_88200;
    if (rate >= 95900.0 && rate <= 96100.0) return kGCSR_DDS_96000;
    if (rate >= 176300.0 && rate <= 176500.0) return kGCSR_DDS_176400;
    if (rate >= 191900.0 && rate <= 192100.0) return kGCSR_DDS_192000;
    return kGCSR_DDS_Off;
}

// Set the FPGA DDS rate in GCSR bits[15:13].
// Legacy: XLink::SetDDSSampleRate() — called before every SetSampleRate().
// Uses explicit read-modify-write to also preserve write-only DMA channel bits[5:0].
static void SetDDSSampleRate(IOPCIDevice *dev, uint8_t memIndex, double rate)
{
    uint32_t ddsValue = SampleRateToDDS(rate);
    // Must use explicit RMW to re-assert write-only DMA channel count bits
    uint32_t gcsr = 0;
    ReadRegister(dev, memIndex, kRegGCSR, &gcsr);
    gcsr &= ~(kGCSR_DDSMask | kGCSR_DMAMask);  // Clear DDS + DMA fields
    gcsr |= ddsValue;                            // Set new DDS rate
    gcsr |= (kGCSR_DMAOutSize32 | kGCSR_DMAInSize32);  // Re-assert DMA ch count
    WriteRegister(dev, memIndex, kRegGCSR, gcsr);
    STLOG("DDS rate set to %.0f Hz (GCSR DDS=0x%04x, GCSR=0x%08x)", rate, ddsValue, gcsr);
}

// WaitForLock: checks DataSlipSticky for stability.
// Legacy: XLink.cpp:2529 — 5 checks × 50ms = 250ms per pass, max passes = timeout/250.
// Returns true if 250ms of clean (no-slip) samples observed.
static bool WaitForLock(IOPCIDevice *dev, uint8_t memIndex, int timeoutMs)
{
    int maxPasses = timeoutMs / 250;
    if (maxPasses < 1) maxPasses = 1;

    WriteRegister(dev, memIndex, kRegXLink1Status, kXLinkDataSlipSticky);
    for (int pass = 0; pass < maxPasses; pass++) {
        bool slipFree = true;
        for (int i = 0; i < 5; i++) {
            IOSleep(50);
            uint32_t status = 0;
            ReadRegister(dev, memIndex, kRegXLink1Status, &status);
            if (status & kXLinkDataSlipSticky) {
                slipFree = false;
                WriteRegister(dev, memIndex, kRegXLink1Status, kXLinkDataSlipSticky);
                break;
            }
        }
        if (slipFree) {
            STLOG("WaitForLock: locked after %d passes (%d ms)", pass + 1, (pass + 1) * 250);
            return true;
        }
    }
    return false;
}

// Read the actual detected clock rate from the XLink Clocking register.
// Returns the detected rate in Hz, or 0 if no clock / unrecognized.
// Legacy: XLink.cpp:2763 — reads SM_REG_XLINK_CLOCKING, decodes SR1 bits.
static uint32_t GetActualClockRate(IOPCIDevice *dev, uint8_t memIndex)
{
    uint32_t clockReg = 0;
    ReadRegister(dev, memIndex, kRegXLinkClocking, &clockReg);

    // Check if RX1 clock is present
    if (!(clockReg & kXLinkRX1ClockDetect))
        return 0;

    switch (clockReg & kXLinkSR1Mask) {
        case kXLinkSRDetect1_44100:  return 44100;
        case kXLinkSRDetect1_48000:  return 48000;
        case kXLinkSRDetect1_88200:  return 88200;
        case kXLinkSRDetect1_96000:  return 96000;
        case kXLinkSRDetect1_176400: return 176400;
        case kXLinkSRDetect1_192000: return 192000;
        default: return 0;
    }
}

// Change the hardware sample rate. Called from StartDevice when CoreAudio
// requests a new rate. IO is already stopped by the host when this runs.
//
// Full legacy sequence (XLink.cpp:963-1155):
//   1. Send SetSampleRate to all devices on the XLink bus
//   2. WaitForLock (up to 5 seconds — PLL needs time, especially at 4x rates)
//   3. 250ms settle time for clocks to stabilize
//   4. Verify actual clock rate matches requested (poll up to 3 seconds)
//   5. Second WaitForLock for final stability confirmation
// outCommandIssued (may be null): set false if we return before the XLink
// SET_SAMPLE_RATE command was actually broadcast (unsupported rate, or TX-busy
// timeout — DDS changed but XLink NOT told), true once it has been broadcast (so a
// later lock/verify failure leaves DDS and XLink both at newRate = consistent). The
// caller uses this to decide whether to roll DDS back to the old rate on failure.
static bool ChangeSampleRate(IOPCIDevice *dev, uint8_t memIndex, double newRate,
                             bool *outCommandIssued)
{
    if (outCommandIssued) *outCommandIssued = false;

    uint8_t rateCode = SampleRateToXLinkCode(newRate);
    if (rateCode == 0xFF) {
        STERR("ChangeSampleRate: unsupported rate %.0f", newRate);
        return false;   // command not issued; DDS untouched
    }

    STLOG("ChangeSampleRate: %.0f Hz (XLink code 0x%02x)", newRate, rateCode);

    // 0. Set DDS rate FIRST (legacy: SetDDSSampleRate before SetSampleRate)
    // The DDS provides the FPGA's internal clock reference and must match the
    // sample rate for the FPGA's TDM timing to align with the XLink data.
    SetDDSSampleRate(dev, memIndex, newRate);

    // 1. Send SetSampleRate to all devices on the bus
    if (!SendXLinkCommand(dev, memIndex, kXLinkCmdAddrAll,
                           kXLinkCmdSetSampleRate, rateCode)) {
        // TX-busy timeout: DDS is now at newRate but the XLink units were NOT told —
        // caller must roll DDS back to keep DDS and XLink consistent.
        STERR("ChangeSampleRate: XLink SET_SAMPLE_RATE timeout (command NOT issued)");
        return false;
    }
    if (outCommandIssued) *outCommandIssued = true;   // XLink now at newRate

    // 2. WaitForLock — single lock pass (H3).
    // This whole routine runs SYNCHRONOUSLY inside the HAL StartDevice() call, so
    // coreaudiod is blocked until it returns. The legacy 5000ms x2 + 250ms settle +
    // 3000ms verify (~13s worst case) risks coreaudiod abandoning the device before
    // the driver finishes. H3 collapses this to a single lock pass (dropping the
    // redundant 250ms settle and the second 5s stability pass), which reclaims most
    // of the worst-case time on its own.
    //
    // The per-pass ceiling stays at the legacy 5000ms (WAIT_FOR_LOCK_AFTER_SRATE_CHANGE,
    // XLink.cpp:33,1001,1029,1059,1087 — NOT WAIT_FOR_LOCK_MED=2000ms, which legacy
    // used only for other, non-srate-change paths). At 176.4/192kHz (4x) the PLL needs
    // longer to settle; while it settles the DataSlipSticky bit trips every pass, so the
    // first clean 250ms pass can be delayed well past 2000ms. Shrinking the ceiling to
    // 2000ms would time out on that legitimate 4x settling and fail an otherwise-good
    // rate change, so we keep the full legacy 5000ms budget. WaitForLock returns as soon
    // as it observes one clean 250ms pass — the timeout is only the failure ceiling — so
    // the common (locks quickly) path still returns after ~250ms regardless.
    if (!WaitForLock(dev, memIndex, 5000)) {
        STERR("ChangeSampleRate: WaitForLock TIMEOUT after rate command");
        return false;
    }

    // 3. (Settle sleep removed — H3.) WaitForLock above already required 250ms of
    // slip-free samples before returning, so the clocks are already stable; the
    // verify loop below additionally tolerates the detected rate not being present
    // yet (it polls). The legacy IOSleep(250) here was redundant with both.

    // 4. Verify actual clock rate matches. FATAL on mismatch (#3): the legacy
    // driver treats a rate mismatch as fatal (XLink.cpp:1044-1053 returns FALSE).
    // A mismatch means the hardware is NOT clocking at the requested rate — running
    // DMA against a mismatched clock produces garbled/misaligned audio, so the
    // caller must keep DMA stopped and outputs muted rather than proceed.
    uint32_t expectedRate = (uint32_t)newRate;
    bool rateMatched = false;
    for (int i = 0; i < 100; i++) {  // 100 × 10ms = 1 second max
        uint32_t actualRate = GetActualClockRate(dev, memIndex);
        if (actualRate == expectedRate) {
            rateMatched = true;
            STLOG("ChangeSampleRate: rate verified — actual=%u Hz (after %d ms)",
                  actualRate, (i + 1) * 10);
            break;
        }
        IOSleep(10);
    }
    if (!rateMatched) {
        uint32_t actualRate = GetActualClockRate(dev, memIndex);
        STERR("ChangeSampleRate: rate mismatch — expected %u, actual %u Hz (FATAL)",
              expectedRate, actualRate);
        return false;
    }

    // 5. Final stability / verified-lock check (#3). PR3's H3 removed this second
    // pass; it is reinstated because the legacy driver requires a clean lock AFTER
    // the rate is confirmed before it trusts the clock (XLink.cpp:1056-1060 returns
    // FALSE if this fails). Without it, a link that momentarily reads the right rate
    // but has not actually stabilized would be accepted, and DMA would start against
    // an unstable clock. WaitForLock returns as soon as it observes one clean 250ms
    // pass, so the common case still returns quickly; the 5000ms ceiling is only the
    // failure bound (kept for 4x PLL settling margin, same rationale as step 2).
    if (!WaitForLock(dev, memIndex, 5000)) {
        STERR("ChangeSampleRate: final stability lock FAILED (FATAL)");
        return false;
    }

    STLOG("ChangeSampleRate: complete — %.0f Hz (locked + rate-verified + stable)", newRate);
    return true;
}

// ── DMA Helper Functions ───────────────────────────────────────────────────

// Allocate a DMA buffer and get its device-visible physical address.
// Returns kIOReturnSuccess and fills physAddr, or error on failure.
static kern_return_t AllocateDMABuffer(
    IOService *driver,
    IOPCIDevice *pciDevice,
    uint64_t size,
    uint64_t direction,  // kIOMemoryDirectionInOut for zero-copy AudioDriverKit
    IOBufferMemoryDescriptor **outBuffer,
    IODMACommand **outDMA,
    uint64_t *outPhysAddr)
{
    kern_return_t ret;

    // 1. Allocate buffer
    IOBufferMemoryDescriptor *buffer = nullptr;
    ret = IOBufferMemoryDescriptor::Create(
        direction, size, 0, &buffer);
    if (ret != kIOReturnSuccess || !buffer) {
        STERR("DMA: IOBufferMemoryDescriptor::Create failed: 0x%x", ret);
        return ret;
    }

    // 2. Set valid length
    ret = buffer->SetLength(size);
    if (ret != kIOReturnSuccess) {
        STERR("DMA: SetLength(%llu) failed: 0x%x", size, ret);
        OSSafeReleaseNULL(buffer);
        return ret;
    }

    // 3. Create DMA command for 32-bit addresses (FPGA is 32-bit PCIe device)
    IODMACommandSpecification spec = {};
    spec.options = kIODMACommandSpecificationNoOptions;
    spec.maxAddressBits = 32;

    IODMACommand *dmaCmd = nullptr;
    ret = IODMACommand::Create(pciDevice, kIODMACommandCreateNoOptions,
                                &spec, &dmaCmd);
    if (ret != kIOReturnSuccess || !dmaCmd) {
        STERR("DMA: IODMACommand::Create failed: 0x%x", ret);
        OSSafeReleaseNULL(buffer);
        return ret;
    }

    // 4. Prepare for DMA — get device-visible physical addresses
    uint64_t flags = 0;
    uint32_t segCount = 32;
    IOAddressSegment segments[32] = {};

    ret = dmaCmd->PrepareForDMA(
        kIODMACommandPrepareForDMANoOptions,
        buffer, 0, 0,  // offset=0, length=0 means entire buffer
        &flags, &segCount, segments);
    if (ret != kIOReturnSuccess) {
        STERR("DMA: PrepareForDMA failed: 0x%x", ret);
        OSSafeReleaseNULL(dmaCmd);
        OSSafeReleaseNULL(buffer);
        return ret;
    }

    // 5. Verify single contiguous segment (FPGA has single base address register)
    if (segCount != 1) {
        STERR("DMA: Expected 1 segment, got %u — FPGA needs contiguous DMA", segCount);
        for (uint32_t i = 0; i < segCount && i < 4; i++) {
            STLOG("  segment[%u]: addr=0x%llx len=%llu",
                  i, segments[i].address, segments[i].length);
        }
        dmaCmd->CompleteDMA(kIODMACommandCompleteDMANoOptions);
        OSSafeReleaseNULL(dmaCmd);
        OSSafeReleaseNULL(buffer);
        return kIOReturnNoMemory;
    }

    *outBuffer = buffer;
    *outDMA = dmaCmd;
    *outPhysAddr = segments[0].address;

    STLOG("DMA: Allocated %llu bytes, physAddr=0x%llx, dir=%s",
          size, segments[0].address,
          (direction == kIOMemoryDirectionIn) ? "A2H(capture)" : "H2A(playback)");

    return kIOReturnSuccess;
}

// ── Symphony link configuration ─────────────────────────────────────────────
// Steps 12–19b of the original Start() sequence: reset the XLink bus, detect
// the Symphony's clock, enumerate it (SET_ADDR / PASS_COMMANDS), set the
// sample rate, unmute, then replay the Symphony's own monitor / clock /
// routing configuration over the vendor message pipe. Extracted so the
// in-place recovery path (MaybeRecoverSymphonyLink) runs the identical
// sequence a cable replug would run through Start(). This is what the legacy
// driver did: its XLink thread classified a powered-off unit as NO_CLOCK, set
// ForceReconfigure(), and re-ran BusInit() in place once the clock returned
// (og_source/symphonymk1/ext/Symphony64/Driver/XLink.cpp:123-128, 253-283).
//
// Returns false when no Symphony clock is detected (unit powered off or PC-32
// cable absent). Uses bounded IOSleep polling: XLink init / serialized
// xlinkQueue path only — never the IRQ queue.
struct SymphonyLinkInitResult {
    bool    lineMonitor;
    uint8_t monitorAttenuation;
    bool    monitorMute;
    uint8_t speakerAttenuation;
    bool    speakerMute;
    uint8_t hp1Attenuation;
    bool    hp1Mute;
};

static bool ConfigureSymphonyLink(SymphonyThunderbridge_IVars *ivars, double rate,
                                  SymphonyLinkInitResult *out)
{
    uint8_t rateCode = SampleRateToXLinkCode(rate);
    if (rateCode == 0xFF) {
        rateCode = kXLinkSRate44100;
        rate = 44100.0;
    }

    // ── 12. Reset XLink bus ─────────────────────────────────────────────
    // Legacy BusInit() (XLink.cpp:483-689):
    //   1. ResetBus — clear status + send reset command
    //   2. SetWCMaster(0, false) — SET_EXT_LOCK to addr 1, data=0 + WaitForLock
    //   3. Enumerate: SET_ADDR, PASS_COMMANDS per device
    //   4. SetWCMaster again after enumeration
    //   5. Set sample rate + WaitForLock
    //   6. Unmute

    // 12a. Clear status registers + reset
    WriteRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegXLink1Status, 0xFFFFFFFF);
    WriteRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegXLink1TX, kXLinkResetCmd);
    STLOG("XLink bus 1 reset");

    // ── 13. Set clock source to XLink1 ─────────────────────────────────
    // Legacy: XLink.cpp SetClockingSource() — FPGA derives clock from XLink 1.

    ModifyRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegClkCtrl,
                   kSampleSourceXLink1, kSampleSourceMask);
    STLOG("Clock source set to XLink1");

    // ── 14. Poll for XLink clock detection ─────────────────────────────
    // Legacy: XLinkClockDetected() reads 5 times for consistency.
    // Need RX clock + sample rate bits present.

    IOSleep(200);  // Give XLink time to detect clock after reset
    uint32_t xlinkClk = 0;
    bool rxClockDetected = false;
    for (int poll = 0; poll < 10; poll++) {
        ReadRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegXLinkClocking, &xlinkClk);
        rxClockDetected = (xlinkClk & kXLinkRX1ClockDetect) != 0;
        if (rxClockDetected)
            break;
        IOSleep(50);
    }
    bool sampleRateDetected = (xlinkClk & kXLinkSR1Mask) != 0;
    STLOG("XLink clock detect: reg=0x%08x, RX1_clock=%u, SR_bits=0x%02x",
          xlinkClk, rxClockDetected, xlinkClk & kXLinkSR1Mask);

    if (!rxClockDetected || !sampleRateDetected) {
        STLOG("XLink: No Symphony IO detected — check PC-32 cable");
        // Set LED to alternating red/green to indicate clocking problem
        if (!ivars->isLegacyPCIe2100 && ivars->hardwareVersion >= kThunderBridgeHWRevWithRGBLeds) {
            uint32_t flash = 0xFFF000;  // Half cycle green, half red
            WriteRegister(ivars->pciDevice, ivars->barMemoryIndex,
                          kRegPort0GreenCtl, (flash << 8) | 0x0F);
            WriteRegister(ivars->pciDevice, ivars->barMemoryIndex,
                          kRegPort0RedCtl, ((~flash & 0xFFFFFF) << 8) | 0x0F);
            WriteRegister(ivars->pciDevice, ivars->barMemoryIndex,
                          kRegPort0BlueCtl, 0);
        }
        return false;
    }
    STLOG("XLink: Symphony IO detected on port 1!");

    // ── 15. SetWCMaster (pre-enumeration) ─────────────────────────────
    // Legacy BusInit:532 — SetWCMaster(0, false) = SetExtLock(0, addr=1, ext=0)
    // Internal clock: send to addr 1 (first device), data=0.
    // NOTE: Bus reset resets clocking back to default, so must re-send.

    if (!SendXLinkCommand(ivars->pciDevice, ivars->barMemoryIndex,
                           1, kXLinkCmdSetExtLock, 0)) {
        STERR("XLink: SET_EXT_LOCK(addr=1, int) timeout");
    } else {
        STLOG("XLink: SET_EXT_LOCK(addr=1, internal clock)");
    }

    // WaitForLock — poll for no DataLinkSlip over 250ms (5 × 50ms)
    // Legacy: XLink.cpp:2529-2627. Check DATA_SLIP_STICKY bit.
    IOSleep(50);
    WriteRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegXLink1Status,
                  kXLinkDataSlipSticky);  // Clear sticky
    bool locked = false;
    for (int pass = 0; pass < 3; pass++) {
        bool slipFree = true;
        for (int i = 0; i < 5; i++) {
            IOSleep(50);
            uint32_t status = 0;
            ReadRegister(ivars->pciDevice, ivars->barMemoryIndex,
                         kRegXLink1Status, &status);
            if (status & kXLinkDataSlipSticky) {
                slipFree = false;
                // Clear the sticky bit and retry
                WriteRegister(ivars->pciDevice, ivars->barMemoryIndex,
                              kRegXLink1Status, kXLinkDataSlipSticky);
                break;
            }
        }
        if (slipFree) {
            locked = true;
            break;
        }
        STLOG("XLink: WaitForLock pass %d: data slip, retrying", pass);
    }
    STLOG("XLink: WaitForLock (pre-enum): %s", locked ? "LOCKED" : "TIMEOUT");

    // ── 16. Enumerate: assign address, pass commands ──────────────────
    // Legacy BusInit:601-654. Assign addr 1, enable pass-through.

    if (!SendXLinkCommand(ivars->pciDevice, ivars->barMemoryIndex,
                           kXLinkCmdAddrAll, kXLinkCmdSetAddr, 1)) {
        STERR("XLink: SET_ADDR command timeout");
    } else {
        STLOG("XLink: SET_ADDR(1) sent — device assigned address 1");
    }
    IOSleep(10);

    if (!SendXLinkCommand(ivars->pciDevice, ivars->barMemoryIndex,
                           1, kXLinkCmdPassCommands, 1)) {
        STERR("XLink: PASS_COMMANDS timeout");
    } else {
        STLOG("XLink: PASS_COMMANDS enabled on device 1");
    }
    IOSleep(10);

    // ── 17. SetWCMaster (post-enumeration) ────────────────────────────
    // Legacy BusInit:672 — calls SetWCMaster again after enumeration.
    // "Ensure clocking is set correctly (if fExternalWC==FALSE, it won't
    //  work until AFTER enumeration)"

    if (!SendXLinkCommand(ivars->pciDevice, ivars->barMemoryIndex,
                           1, kXLinkCmdSetExtLock, 0)) {
        STERR("XLink: SET_EXT_LOCK(post-enum) timeout");
    } else {
        STLOG("XLink: SET_EXT_LOCK(post-enum, addr=1, internal)");
    }

    // WaitForLock again
    IOSleep(50);
    WriteRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegXLink1Status,
                  kXLinkDataSlipSticky);
    locked = false;
    for (int pass = 0; pass < 3; pass++) {
        bool slipFree = true;
        for (int i = 0; i < 5; i++) {
            IOSleep(50);
            uint32_t status = 0;
            ReadRegister(ivars->pciDevice, ivars->barMemoryIndex,
                         kRegXLink1Status, &status);
            if (status & kXLinkDataSlipSticky) {
                slipFree = false;
                WriteRegister(ivars->pciDevice, ivars->barMemoryIndex,
                              kRegXLink1Status, kXLinkDataSlipSticky);
                break;
            }
        }
        if (slipFree) {
            locked = true;
            break;
        }
        STLOG("XLink: WaitForLock pass %d (post-enum): data slip, retrying", pass);
    }
    STLOG("XLink: WaitForLock (post-enum): %s", locked ? "LOCKED" : "TIMEOUT");

    // ── 18. Set sample rate ──────────────────────────────────────────
    // Legacy: SetDDSSampleRate() first, then SetSampleRate() sends to ADDR_ALL.

    // Set DDS first (legacy: SetDDSSampleRate before SetSampleRate). Start()
    // passes 44100; in-place recovery passes the rate the units last ran at.
    SetDDSSampleRate(ivars->pciDevice, ivars->barMemoryIndex, rate);

    if (!SendXLinkCommand(ivars->pciDevice, ivars->barMemoryIndex,
                           kXLinkCmdAddrAll, kXLinkCmdSetSampleRate, rateCode)) {
        STERR("XLink: SET_SAMPLE_RATE timeout");
    } else {
        STLOG("XLink: SET_SAMPLE_RATE(%u) sent", (uint32_t)(rate + 0.5));
    }

    // WaitForLock after sample rate change
    IOSleep(100);
    WriteRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegXLink1Status,
                  kXLinkDataSlipSticky);
    locked = false;
    for (int pass = 0; pass < 5; pass++) {
        bool slipFree = true;
        for (int i = 0; i < 5; i++) {
            IOSleep(50);
            uint32_t status = 0;
            ReadRegister(ivars->pciDevice, ivars->barMemoryIndex,
                         kRegXLink1Status, &status);
            if (status & kXLinkDataSlipSticky) {
                slipFree = false;
                WriteRegister(ivars->pciDevice, ivars->barMemoryIndex,
                              kRegXLink1Status, kXLinkDataSlipSticky);
                break;
            }
        }
        if (slipFree) {
            locked = true;
            break;
        }
        STLOG("XLink: WaitForLock pass %d (post-srate): data slip, retrying", pass);
    }
    STLOG("XLink: WaitForLock (post-srate): %s", locked ? "LOCKED" : "TIMEOUT");

    // ── 19. Unmute ──────────────────────────────────────────────────
    // Legacy: SetDeviceMute(bus, addr, false) → UNMUTE, data=0x80

    if (!SendXLinkCommand(ivars->pciDevice, ivars->barMemoryIndex,
                           kXLinkCmdAddrAll, kXLinkCmdUnmute, 0x80)) {
        STERR("XLink: UNMUTE timeout");
    } else {
        STLOG("XLink: UNMUTE sent (global unmute)");
    }
    IOSleep(50);

    // ── 19b. Configure Symphony IO speaker + routing ────────────────
    // The ThunderBridge FPGA routing (steps 21b/21c) moves audio between DMA
    // and the XLink bus. But the Symphony IO has its OWN internal crosspoint
    // router and analog output controls that must be separately configured
    // via vendor commands sent over the XLink control message pipe.

    STLOG("SymphonyIO: ══════ BEGIN SPEAKER + ROUTING CONFIG ══════");
    {
        uint8_t txSeq = 0;  // Message sequence counter
        const uint8_t symphonyAddr = 1;  // Device address assigned in enumeration

        // Preserve the Symphony IO's stored monitor state across a PCIe
        // reconnect.  The legacy ApplySettingsToHardware path re-read and
        // replayed these values; resetting to stereo/20 dB/unmuted here made
        // a power-cycle appear to change the user's output configuration.
        uint8_t startupMode = 2;       // Stereo fallback
        uint8_t startupVolume = 20;    // 20 dB attenuation fallback
        uint8_t startupMute = 0;       // unmuted fallback
        uint8_t startupActiveSet = 1;  // speaker set A fallback
        uint8_t startupHP1Volume = 20; // 20 dB attenuation fallback
        uint8_t startupHP1Mute = 0;    // unmuted fallback
        uint8_t startupHP2Volume = 20; // 20 dB attenuation fallback
        uint8_t startupHP2Mute = 0;    // unmuted fallback
        uint8_t readback = 0;
        if (ReadVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                              symphonyAddr, kSIOCmd_SpeakerMode, 0,
                              &readback, 1, txSeq)) {
            startupMode = readback;
        }
        if (ReadVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                              symphonyAddr, kSIOCmd_SpeakerVolume, 0,
                              &readback, 1, txSeq)) {
            startupVolume = (readback > 64) ? 64 : readback;
        }
        if (ReadVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                              symphonyAddr, kSIOCmd_SpeakerMute, 0,
                              &readback, 1, txSeq)) {
            startupMute = readback ? 1 : 0;
        }
        if (ReadVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                              symphonyAddr, kSIOCmd_ActiveSpeakerSet, 0,
                              &readback, 1, txSeq)) {
            startupActiveSet = readback & 0x07;
            if (startupActiveSet == 0) startupActiveSet = 1;
        }
        if (ReadVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                              symphonyAddr, kSIOCmd_HeadphoneVolume, 0,
                              &readback, 1, txSeq)) {
            startupHP1Volume = (readback > 64) ? 64 : readback;
        }
        if (ReadVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                              symphonyAddr, kSIOCmd_HeadphoneMute, 0,
                              &readback, 1, txSeq)) {
            startupHP1Mute = readback ? 1 : 0;
        }
        if (ReadVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                              symphonyAddr, kSIOCmd_HeadphoneVolume, 1,
                              &readback, 1, txSeq)) {
            startupHP2Volume = (readback > 64) ? 64 : readback;
        }
        if (ReadVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                              symphonyAddr, kSIOCmd_HeadphoneMute, 1,
                              &readback, 1, txSeq)) {
            startupHP2Mute = readback ? 1 : 0;
        }
        STLOG("SymphonyIO: restored monitor state mode=%u speakerVolume=%u speakerMute=%u "
              "hp1Volume=%u hp1Mute=%u hp2Volume=%u hp2Mute=%u activeSet=0x%02x",
              startupMode, startupVolume, startupMute, startupHP1Volume,
              startupHP1Mute, startupHP2Volume, startupHP2Mute, startupActiveSet);
        out->lineMonitor = startupMode == 0;
        out->speakerAttenuation = startupVolume;
        out->speakerMute = (startupMute != 0 || startupVolume >= 64);
        out->hp1Attenuation = startupHP1Volume;
        out->hp1Mute = (startupHP1Mute != 0 || startupHP1Volume >= 64);
        out->monitorAttenuation = out->lineMonitor
            ? ((startupHP1Volume > 64) ? 64 : startupHP1Volume)
            : startupVolume;
        out->monitorMute = out->lineMonitor
            ? (startupHP1Mute != 0 || startupHP1Volume >= 64)
            : (startupMute != 0 || startupVolume >= 64);

        // ── 19b-0a. PreferenceLoadLock(true) — mute XMOS while configuring ──
        // Legacy: ApplySettingsToHardware() locks before any routing changes.
        // Without this, the XMOS may apply partial routing and produce glitches.
        // Without the final unlock (step 19b-4), XMOS stays muted = total silence.
        // Evidence: MaestroVolumeProxy.c:783-786 configure_fpga_routing() step 1.
        {
            uint8_t lock = 1;
            bool ok = SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                         symphonyAddr, kSIOCmd_PreferenceLoadLock,
                                         0, &lock, 1, txSeq);
            STLOG("SymphonyIO: PreferenceLoadLock(LOCK): %s", ok ? "OK" : "FAILED");
            IOSleep(10);
        }

        // ── 19b-0b. Speaker settings ──────────────────────────────────
        // Set analog output configuration: stereo mode, 20 dB attenuation,
        // unmuted. Matches the USB proxy's defaults (MaestroVolumeProxy.c).
        {
            uint8_t mode = startupMode;
            bool ok = SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                         symphonyAddr, kSIOCmd_SpeakerMode,
                                         0, &mode, 1, txSeq);
            STLOG("SymphonyIO: SpeakerMode(mode=%u): %s", mode, ok ? "OK" : "FAILED");
            if (ok) {
                __atomic_store_n(&ivars->monitorOutputTarget,
                                 mode == 0 ? static_cast<uint8_t>(1)
                                           : static_cast<uint8_t>(0),
                                 __ATOMIC_RELEASE);
            }
            IOSleep(10);

            uint8_t vol = startupVolume;
            ok = SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                    symphonyAddr, kSIOCmd_SpeakerVolume,
                                    0, &vol, 1, txSeq);
            STLOG("SymphonyIO: SpeakerVolume(atten=%u dB): %s", vol, ok ? "OK" : "FAILED");
            IOSleep(10);

            uint8_t mute = startupMute;
            ok = SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                    symphonyAddr, kSIOCmd_SpeakerMute,
                                    0, &mute, 1, txSeq);
            STLOG("SymphonyIO: SpeakerMute(unmuted): %s", ok ? "OK" : "FAILED");
            IOSleep(10);

            // Legacy ApplySettingsToHardware replays the active speaker-set
            // mask after the output mode.  The default is set A; omitting
            // this write leaves multi-set modes dependent on stale hardware
            // state after a reconnect.
            uint8_t activeSet = startupActiveSet;
            ok = SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                   symphonyAddr, kSIOCmd_ActiveSpeakerSet,
                                   0, &activeSet, 1, txSeq);
            STLOG("SymphonyIO: ActiveSpeakerSet(mask=0x%02x): %s",
                  activeSet, ok ? "OK" : "FAILED");
            IOSleep(10);

            // The legacy ApplySettingsToHardware path also replays both
            // headphone controls during reconnect.  Keep HP2 in sync even
            // when it is not the currently selected Core Audio monitor.
            uint8_t hp1Volume = startupHP1Volume;
            ok = SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                   symphonyAddr, kSIOCmd_HeadphoneVolume,
                                   0, &hp1Volume, 1, txSeq);
            STLOG("SymphonyIO: HeadphoneVolume(HP1 atten=%u): %s",
                  hp1Volume, ok ? "OK" : "FAILED");
            IOSleep(10);

            uint8_t hp1Mute = startupHP1Mute;
            ok = SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                   symphonyAddr, kSIOCmd_HeadphoneMute,
                                   0, &hp1Mute, 1, txSeq);
            STLOG("SymphonyIO: HeadphoneMute(HP1=%u): %s",
                  hp1Mute, ok ? "OK" : "FAILED");
            IOSleep(10);

            uint8_t hp2Volume = startupHP2Volume;
            ok = SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                   symphonyAddr, kSIOCmd_HeadphoneVolume,
                                   1, &hp2Volume, 1, txSeq);
            STLOG("SymphonyIO: HeadphoneVolume(HP2 atten=%u): %s",
                  hp2Volume, ok ? "OK" : "FAILED");
            IOSleep(10);

            uint8_t hp2Mute = startupHP2Mute;
            ok = SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                   symphonyAddr, kSIOCmd_HeadphoneMute,
                                   1, &hp2Mute, 1, txSeq);
            STLOG("SymphonyIO: HeadphoneMute(HP2=%u): %s",
                  hp2Mute, ok ? "OK" : "FAILED");
            IOSleep(10);
        }

        // ── 19b-0b2. Clock mode: Internal, Master ──────────────────────
        // Tell the XMOS processor to use Internal clock in Master mode.
        // Without this, the XMOS doesn't know it's the clock master and
        // ADAT optical framing, capture clocking, and some routing may
        // fail silently. The USB proxy sends this at boot (step 3).
        // cmd 0x50: 4 bytes [source, master, loopSync, boardClockSrc]
        //   source: 1=Internal, 2=WordClock, 3=LoopSync, 4=IOBoard1, 5=IOBoard2
        //   master: 0=Slave, 1=Master
        //   loopSync: 0=off, 1=on
        //   boardClockSrc: 0=SPDIFCoax, 1=Optical1-2, etc.
        // Evidence: MaestroVolumeProxy.c:811-818 configure_fpga_routing() step 3.
        {
            uint8_t clockData[4] = { 0x01, 0x01, 0x00, 0x00 };  // Internal, Master
            bool ok = SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                         symphonyAddr, kSIOCmd_ClockMode,
                                         0, clockData, sizeof(clockData), txSeq);
            STLOG("SymphonyIO: ClockMode(Internal, Master): %s", ok ? "OK" : "FAILED");
            IOSleep(10);
        }

        // ── 19b-0c. Set optical format to ADAT/SMUX on both IOBoards ──
        // The ADAT optical port needs its frame generator configured.
        // cmd 0x34: nValue = board index (0 or 1), data = 0 for ADAT/SMUX.
        // Harmless if a board slot is empty.
        // Evidence: MaestroVolumeProxy.c:821-835 configure_fpga_routing() step 3a.
        {
            uint8_t adatMode = 0;  // SymphonyIOOpticalFormat_ADAT_SMUX
            bool ok0 = SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                          symphonyAddr, kSIOCmd_OpticalFormat,
                                          0, &adatMode, 1, txSeq);
            IOSleep(10);
            bool ok1 = SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                          symphonyAddr, kSIOCmd_OpticalFormat,
                                          1, &adatMode, 1, txSeq);
            STLOG("SymphonyIO: OpticalFormat(ADAT/SMUX): board0=%s, board1=%s",
                  ok0 ? "OK" : "FAILED", ok1 ? "OK" : "FAILED");
            IOSleep(10);
        }

        // ── 19b-1. Playback routing: XLink → IOBoard0 (direct) ─────
        // Route XLink ch0-15 directly to IOBoard0 DAC ch0-15.
        // IOBoard0 layout: ch0-7 = Analog 1-8 (Line), ch8-15 = ADAT 1-8 (Optical).
        // NOTE: an attempt to route ch0/1 through Mixer0 (XLink→SW Return→DAC) went
        // silent on hardware — the mixer's SW Return input (0xE4) does not accept an
        // XLink (0x00) source; the USB proxy feeds it from P2P (0xC0). Reverted to
        // direct here; the through-mixer path needs the P2P source (see next round).
        {
            uint8_t playbackRoutes[32];
            for (int n = 0; n < 16; n++) {
                playbackRoutes[n * 2]     = (uint8_t)(kSIODest_IOBoard0Ch0 + n);
                playbackRoutes[n * 2 + 1] = (uint8_t)(kSIOSrc_XLinkCh0 + n);
            }
            bool ok = SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                         symphonyAddr, kSIOCmd_AudioRouting,
                                         0, playbackRoutes, sizeof(playbackRoutes), txSeq);
            STLOG("SymphonyIO: Playback routing (XLink 0-15 → IOBoard0 ch0-15): %s",
                  ok ? "OK" : "FAILED");
            IOSleep(20);
        }

        // ── 19b-1b. Playback routing: XLink → IOBoard1 (dual) ──────
        // Route XLink ch16-31 to IOBoard1 ch0-15. A Symphony I/O occupies 32
        // channels on its XLink port (MAX_SYMPHONY_CHANNELS_ON_BUS) and the
        // legacy PCIe routing controller addresses board 1 outputs as port
        // channels 16-31 (SymphonyPCIeRoutingController.cpp routeSymphonyHW:
        // nDest = board channel + preceding channels), so the card-side output
        // routing (kThunderboltCardOutputRouteCommand) can only reach board 1
        // through XLink TX 16-31. Builds ≤110 mirrored XLink 0-15 onto both
        // boards, which made board 1 unaddressable. Matches the USB default
        // table (board 1 ← playback 17-32). Harmless if IOBoard1 is empty.
        {
            uint8_t io1Routes[32];
            for (int n = 0; n < 16; n++) {
                io1Routes[n * 2]     = (uint8_t)(kSIODest_IOBoard1Ch0 + n);
                io1Routes[n * 2 + 1] = (uint8_t)(kSIOSrc_XLinkCh0 + 16 + n);
            }
            bool ok = SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                         symphonyAddr, kSIOCmd_AudioRouting,
                                         0, io1Routes, sizeof(io1Routes), txSeq);
            STLOG("SymphonyIO: Playback routing (XLink 16-31 → IOBoard1 ch0-15): %s",
                  ok ? "OK" : "FAILED");
            IOSleep(20);
        }

        // ── 19b-2. Capture: IOBoard0 ADC 0-15 → P2P ch 0-15 ────────
        // Route hardware inputs to P2P (Peer-to-Peer) destinations.
        // P2P (0xC0+) is the XMOS abstract host interface — the XMOS firmware
        // routes P2P traffic to the active transport (XLink for Thunderbolt,
        // USB for USB mode). Using XLink destinations (0x00+) does NOT work
        // because XLink 0x00 as destination refers to the XLink control channel,
        // not the audio data path. P2P is what the legacy PCIe routing controller
        // used (SymphonyIOUSBAudioRoutingController.cpp:111, SymphonyIORouting.h:330).
        // IOBoard0: ch0-7 = Analog 1-8 (Line/Mic), ch8-15 = ADAT 1-8 (Optical).
        {
            uint8_t captureRoutes[32];
            for (int n = 0; n < 16; n++) {
                captureRoutes[n * 2]     = (uint8_t)(kSIODest_P2PCh0 + n);
                captureRoutes[n * 2 + 1] = (uint8_t)(kSIOSrc_IOBoard0Ch0 + n);
            }
            bool ok = SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                         symphonyAddr, kSIOCmd_AudioRouting,
                                         0, captureRoutes, sizeof(captureRoutes), txSeq);
            STLOG("SymphonyIO: Capture routing (IOBoard0 ADC 0-15 → P2P 0-15): %s",
                  ok ? "OK" : "FAILED");
            IOSleep(20);
        }

        // ── 19b-2b. Capture: IOBoard1 ADC 0-15 → P2P ch 16-31 ────
        // Route IOBoard1 inputs to P2P channels 16-31 (maps to DMA channels 16-31).
        // Harmless if IOBoard1 slot is empty.
        {
            uint8_t capture1Routes[32];
            for (int n = 0; n < 16; n++) {
                capture1Routes[n * 2]     = (uint8_t)(kSIODest_P2PCh0 + 16 + n);
                capture1Routes[n * 2 + 1] = (uint8_t)(kSIOSrc_IOBoard1Ch0 + n);
            }
            bool ok = SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                         symphonyAddr, kSIOCmd_AudioRouting,
                                         0, capture1Routes, sizeof(capture1Routes), txSeq);
            STLOG("SymphonyIO: Capture routing (IOBoard1 ADC 0-15 → P2P 16-31): %s",
                  ok ? "OK" : "FAILED");
            IOSleep(20);
        }

        // ── 19b-3. Mute mixer hardware inputs (DAW mode) ────────────
        // XMOS firmware boots with all mixer inputs at 0dB/unmuted, so
        // hardware inputs pass through: IOBoard→Mixer→DAC by default.
        // In DAW mode, mute all 32 HW inputs on Mixer0 so only the
        // SW Return (XLink/DMA playback) is heard via direct routing.
        // cmd 0xB3: nValue = (mixer<<16)|channel, data = 1 (muted).
        // Evidence: MaestroVolumeProxy.c:889-911 configure_fpga_routing() step 4c.
        {
            int muteOk = 0, muteFail = 0;
            for (uint16_t ch = 0; ch < 32; ch++) {
                uint32_t nValue = ((uint32_t)0 << 16) | (uint32_t)ch;  // Mixer 0, channel ch
                uint8_t muteVal = 1;  // muted
                bool ok = SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                             symphonyAddr, kSIOCmd_MixerInputMute,
                                             nValue, &muteVal, 1, txSeq);
                if (ok) muteOk++; else muteFail++;
            }
            STLOG("SymphonyIO: Mixer0 HW inputs muted (DAW mode): %d OK, %d failed",
                  muteOk, muteFail);
            IOSleep(20);
        }

        // ── 19b-4. PreferenceLoadLock(false) — unlock XMOS, audio can flow ──
        // CRITICAL: Without this unlock, the XMOS stays muted and NO audio
        // reaches the DAC even though XLink frames arrive.
        // Evidence: MaestroVolumeProxy.c:921-926 configure_fpga_routing() step 5.
        {
            uint8_t unlock = 0;
            bool ok = SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                         symphonyAddr, kSIOCmd_PreferenceLoadLock,
                                         0, &unlock, 1, txSeq);
            STLOG("SymphonyIO: PreferenceLoadLock(UNLOCK): %s — %s",
                  ok ? "OK" : "FAILED",
                  ok ? "audio should flow" : "XMOS STILL MUTED!");
            IOSleep(10);
        }

        STLOG("SymphonyIO: ══════ ROUTING CONFIG COMPLETE (txSeq=%u) ══════", txSeq);
    }


    return true;
}

// ── Status LED: link OK ─────────────────────────────────────────────────────
// Legacy: UpdateStatusLEDs() at Symphony64Card.cpp:2164-2201.
// Solid green = no clocking problem. Alternating red/green = problem.
// Green pattern: 0xFFFFFF00 | brightness (all 24 bits on = solid)
static void IndicateLinkOK(SymphonyThunderbridge_IVars *ivars)
{
    // Set GCSR LED bits: Port 1 on (green), Port 2 off.
    // ThunderBridge GCSR LED mapping (Sym64Registers.h:153-163):
    //   bit 11 (0x800) = Port 1 flash    bit 10 (0x400) = Port 1 off
    //   bit  9 (0x200) = Port 2 flash    bit  8 (0x100) = Port 2 off
    // "On" = neither flash nor off. "Off" = off bit set.
    {
        uint32_t setBits = kGCSR_ClockOKSolid;  // 0x100 = Port 2 OFF
        uint32_t clrBits = kGCSR_MasterLEDFlash  // 0x800 clear Port 1 flash
                         | kGCSR_MasterLEDSolid   // 0x400 clear Port 1 off
                         | kGCSR_ClockOKFlash;     // 0x200 clear Port 2 flash
        ModifyRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegGCSR,
                       setBits, clrBits);
        STLOG("GCSR LED bits: Port 1 on, Port 2 off");
    }

    if (!ivars->isLegacyPCIe2100 && ivars->hardwareVersion >= kThunderBridgeHWRevWithRGBLeds) {
        uint8_t brightness = 0x0F;
        // Port 1: solid green (connected, configured)
        WriteRegister(ivars->pciDevice, ivars->barMemoryIndex,
                      kRegPort0GreenCtl, 0xFFFFFF00 | brightness);
        WriteRegister(ivars->pciDevice, ivars->barMemoryIndex,
                      kRegPort0RedCtl, 0);
        WriteRegister(ivars->pciDevice, ivars->barMemoryIndex,
                      kRegPort0BlueCtl, 0);
        // Port 2: off (not in use — legacy sets off when !m_fSecondPortInUse)
        WriteRegister(ivars->pciDevice, ivars->barMemoryIndex,
                      kRegPort1GreenCtl, 0);
        WriteRegister(ivars->pciDevice, ivars->barMemoryIndex,
                      kRegPort1RedCtl, 0);
        WriteRegister(ivars->pciDevice, ivars->barMemoryIndex,
                      kRegPort1BlueCtl, 0);
        STLOG("LED: Port 1 solid green, Port 2 off (RGB)");
    }

}

// ── In-place Symphony link recovery ─────────────────────────────────────────
// Called from ReadTimingHealth() each time the live ClockRateAndLock read
// fails (the app probes once per second). A Symphony that was power-cycled
// with the ThunderBridge cable left in never answers again on its own: its
// XLink side needs the SET_ADDR / PASS_COMMANDS / rate / unmute handshake
// that Start() performs, and Start() only runs on a PCI re-match (cable
// replug). This re-runs that handshake in place, on the serialized xlinkQueue,
// without self-terminating the IOService, replacing the PCI provider,
// releasing queues, or touching system-extension activation (the constraints
// recorded in Docs/Thunderbolt-completion-plan.md, 2026-10-11).
//
// Gate (legacy NO_CLOCK): the card must see the Symphony's RX clock and a
// detected sample rate on three consecutive reads. A powered-off unit never
// passes, so the failed probe stays cheap (≤40 ms) while the unit is off.
// ── dext 113: link watch ────────────────────────────────────────────────────
// Replaces the app's 1 Hz ClockRateAndLock probe with a driver-owned watch that
// follows Apple's model (the OS owns presence; the driver re-initializes on power
// transitions). Steady-state cost: zero bus traffic while audio runs (A2H wraps
// prove the XLink sample clock), one presence check + one register read every
// 5 s when idle, 2 s while the Symphony is off so power-on is caught quickly.
enum : uint32_t {
    kLinkStateUnknown    = 0,
    kLinkStateUp         = 1,
    kLinkStateDown       = 2,
    kLinkStateRecovering = 3,
};
static constexpr uint64_t kLinkWatchFastNs   =  2000000000ull;   // down / recovering
static constexpr uint64_t kLinkWatchIdleNs   =  5000000000ull;   // up, IO idle
static constexpr uint64_t kLinkWatchStreamNs = 10000000000ull;   // up, audio wraps flowing
static constexpr uint64_t kLinkWatchWakeNs =  100000000ull;   // first tick after SetPowerState(On)

static void ArmLinkWatch(SymphonyThunderbridge_IVars *ivars, uint64_t delayNs)
{
    if (!ivars || !ivars->linkWatchTimer) return;
    if (__atomic_load_n(&ivars->stopping, __ATOMIC_ACQUIRE)) return;   // never re-arm past Stop()
    const uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    ivars->linkWatchTimer->WakeAtTime(kIOTimerClockMonotonicRaw, now + delayNs, delayNs / 10);
}

static bool LinkRecoveryAborted(SymphonyThunderbridge_IVars *ivars)
{
    return __atomic_load_n(&ivars->stopping, __ATOMIC_ACQUIRE) ||
           __atomic_load_n(&ivars->txShutdown, __ATOMIC_ACQUIRE) ||
           __atomic_load_n(&ivars->providerPowerOff, __ATOMIC_ACQUIRE) ||
           __atomic_load_n(&ivars->hwSuspended, __ATOMIC_ACQUIRE);
}

// Ask Core Audio to re-evaluate the device. Must never run on xlinkQueue (the
// perform path syncs onto it). `self` is retained across the hop so the block
// cannot outlive the service.
static void RequestIORestartFromDefaultQueue(SymphonyThunderbridge_IVars *ivars,
                                             SymphonyThunderbridge *self, const char *why)
{
    if (!ivars || !ivars->defaultQueue || !self) return;
    self->retain();
    ivars->defaultQueue->DispatchAsync(^{
        if (!__atomic_load_n(&ivars->stopping, __ATOMIC_ACQUIRE) && ivars->audioDevice) {
            const bool ioRunning = __atomic_load_n(&ivars->ioRunning, __ATOMIC_ACQUIRE);
            kern_return_t rc = ivars->audioDevice->RequestDeviceConfigurationChange(
                kSymphonyConfigChangeLinkRecovered, nullptr);
            STLOG("Link watch: requested Core Audio configuration change (%s, ioRunning=%u, 0x%x)",
                  why, ioRunning ? 1u : 0u, rc);
        }
        self->release();
    });
}

static void RecomputeCardMixer(SymphonyThunderbridge_IVars *iv, IOPCIDevice *dev, uint8_t mi,
                               uint16_t mixerID);

// ── dext 115: card re-initialization after a PCI power cycle ────────────────
// Sleep puts the ThunderBridge in D3. On wake the kernel restores PCI config
// space, the driver instance survives (no Start()), but the FPGA's own registers
// are back at power-on defaults: 2026-10-27 12:06 the control register read
// 0x4a1b where a running card reads 0x2db8011b — DMA enables, byte order,
// interrupt mask, DMA buffer addresses, routing and mixer coefficients all gone.
// The XLink re-lock alone then yields a Symphony that answers commands while
// Core Audio waits forever for wrap interrupts (silence, no meters, "Connected").
// Fingerprint the control register and re-program everything Start() programs,
// from the retained host state (the DMA buffers still exist in host memory).
static bool CardLostConfiguration(SymphonyThunderbridge_IVars *ivars, uint32_t *outGcsr)
{
    uint32_t gcsr = 0;
    ReadRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegGCSR, &gcsr);
    if (outGcsr) *outGcsr = gcsr;
    if (gcsr == 0xFFFFFFFFu) return false;   // endpoint gone — HardwareReachable's problem, not a reset
    const bool swapOK = (gcsr & kGCSR_SwapToLE) == kGCSR_SwapToLE;
    const bool chOK   = (gcsr & kGCSR_DMAMask) == (kGCSR_DMAOutSize32 | kGCSR_DMAInSize32);
    const uint32_t dmaBits = kGCSR_A2HDMAEnable | kGCSR_H2ADMAEnable;
    const bool dmaOK  = !ivars->dmaRunning || (gcsr & dmaBits) == dmaBits;
    return !(swapOK && chOK && dmaOK);
}

// dext 119: the card DMAs the playback buffer continuously; whenever Core Audio
// is not writing it (IO stopped, an IO gap around a configuration change, the
// first moments after a DMA restart) its last contents loop on the outputs.
// dext 120: the buffer is mapped cache-inhibited for DMA; a CPU memset on it
// faults (EXC_ARM_DA_ALIGN in __bzero — dext 119 crashed in StopDevice at every
// sleep entry, which is what tore the device down). Zero it through the DMA
// command's zero operation, the same call Start() uses.
static void ZeroPlaybackDMABuffer(SymphonyThunderbridge_IVars *ivars, const char *why)
{
    if (!ivars || !ivars->h2aDMA) return;
    if (__atomic_load_n(&ivars->stopping, __ATOMIC_ACQUIRE)) return;
    ivars->h2aDMA->PerformOperation(kIODMACommandPerformOperationOptionZero, 0, kDMABufferSize, 0, nullptr);
    STLOG("Playback DMA buffer zeroed (%s)", why);
}

// Runs ON xlinkQueue (no rate transaction can interleave). Mirrors Start()
// steps 10–29b in order; the XLink re-lock (ConfigureSymphonyLink) follows.
static void ReprogramCardAfterReset(SymphonyThunderbridge_IVars *ivars, uint32_t gcsrSeen)
{
    IOPCIDevice *dev = ivars->pciDevice;
    const uint8_t mi = ivars->barMemoryIndex;
    ivars->cardReinitCount++;
    ivars->reinitStartSerial       = ivars->startDeviceSerial;
    ivars->anchorPendingAtReinit   = ivars->firstTimestampAfterStart;
    ivars->reinitSinceLastDecision = true;
    ZeroPlaybackDMABuffer(ivars, "card re-init");
    STLOG("Card re-init #%u: GCSR=0x%08x lost its programmed state — re-programming IRQ, DMA, "
          "routing, mixer", ivars->cardReinitCount, gcsrSeen);
    // Quiet first: no interrupts, no DMA, clear latched status.
    WriteRegister(dev, mi, kRegIntMask, 0);
    WriteRegister(dev, mi, kRegIntStatus, 0xFFFFFFFF);
    WriteRegister(dev, mi, kRegRxStatusErr, 0xFFFFFFFF);
    WriteRegister(dev, mi, kRegGCSR, kGCSR_SwapToLE);
    ModifyRegister(dev, mi, kRegXLinkClocking, kXLinkClockEnable1, 0);
    // Routing tables: the app's card output routes where known, Start()'s
    // defaults elsewhere; input routing is always the default.
    for (uint32_t n = 0; n < kMaxChannelsPerPort; n++) {
        const uint32_t def = ((n < 2) ? (kTDM_Mixer0Out + n) : (kTDM_PCIOut0 + n)) | kRoutingEnable;
        WriteRegister(dev, mi, kRegOutputRouting + n * 4,
                      ivars->cardOutputRouteSet[n] ? ivars->cardOutputRoute[n] : def);
        WriteRegister(dev, mi, kRegInputRouting + n * 4, (kTDM_XLinkRX0 + n) | kRoutingEnable);
    }
    // Meter DMA registers (buffer retained).
    if (ivars->meterDMAActive) {
        WriteRegister(dev, mi, kRegMeterTimer, kMeterTimerValue);
        WriteRegister(dev, mi, kRegMeterHBA, (uint32_t)ivars->meterPhysAddr);
    }
    // Audio DMA registers (buffers retained).
    {
        const uint32_t bufSizeWords = (uint32_t)(kDMABufferSize / (kAudioBitDepth / 8));
        WriteRegister(dev, mi, kRegA2HBUFSIZE, bufSizeWords);
        WriteRegister(dev, mi, kRegH2ABUFSIZE, bufSizeWords);
        WriteRegister(dev, mi, kRegA2HHBA, (uint32_t)ivars->a2hPhysAddr);
        WriteRegister(dev, mi, kRegH2AHBA, (uint32_t)ivars->h2aPhysAddr);
        WriteRegister(dev, mi, kRegA2H2BUFSIZE, 0);
        WriteRegister(dev, mi, kRegH2A2BUFSIZE, 0);
        WriteRegister(dev, mi, kRegA2H2HBA, 0);
        WriteRegister(dev, mi, kRegH2A2HBA, 0);
    }
    // Channel count and the frame size for the rate the units run at.
    ModifyRegister(dev, mi, kRegGCSR, kGCSR_DMAOutSize32 | kGCSR_DMAInSize32, kGCSR_DMAMask);
    ModifyRegister(dev, mi, kRegGCSR2, kGCSR2_DMAOutSize32 | kGCSR2_DMAInSize32, kGCSR2_DMAMask);
    {
        const double rate = ivars->xlinkRate > 0.0
            ? ivars->xlinkRate
            : (ivars->audioDevice ? ivars->audioDevice->GetSampleRate() : 44100.0);
        const uint32_t frame = FPGAFrameSizeForRate(rate);
        ModifyRegister(dev, mi, kRegClkCtrl,
                       ((frame - 1) << kClkCtrl_FrameShift) & kClkCtrl_FrameMask, kClkCtrl_FrameMask);
    }
    // Card mixer: clear the coefficient table (Start() step), restore each
    // mixer's software-return source registers from the cached selection, then
    // either replay the app's state or, if the app never touched that mixer,
    // Start()'s unity defaults (dext 116: zero coefficients silenced outputs 1-2).
    for (uint64_t off = 0; off < 0x1000; off += 4)
        WriteRegister(dev, mi, kRegMixerCoeff + off, 0);
    WriteRegister(dev, mi, kRegMixerControl, 0);
    for (uint16_t mixerID = 1; mixerID <= 2; mixerID++) {
        const uint8_t source = ivars->mixerSwReturnSource[mixerID - 1];
        for (uint8_t side = 0; side < 2; side++)
            WriteRegister(dev, mi, ThunderboltMixerReturnRegister(mixerID, side),
                          ThunderboltSoftwareReturnSlot(source, side) | kRoutingEnable);
        if (ivars->mixerStateValid[mixerID - 1]) {
            RecomputeCardMixer(ivars, dev, mi, mixerID);
        } else {
            const uint32_t bank = (mixerID == 1) ? 0 : 2;
            WriteRegister(dev, mi, MixerCoefOffset(bank,     128), kMixerUnityCoeff);
            WriteRegister(dev, mi, MixerCoefOffset(bank + 1, 129), kMixerUnityCoeff);
        }
    }
    STLOG("Card re-init: mixer 1 %s, mixer 2 %s (SW Return sources %u/%u)",
          ivars->mixerStateValid[0] ? "replayed from app state" : "unity defaults",
          ivars->mixerStateValid[1] ? "replayed from app state" : "unity defaults",
          ivars->mixerSwReturnSource[0], ivars->mixerSwReturnSource[1]);
    // Interrupts, then DMA start, then unmute (Start() steps 27–29b).
    WriteRegister(dev, mi, kRegIntStatus, 0xFFFFFFFF);
    WriteRegister(dev, mi, kRegIntMask, 0);
    WriteRegister(dev, mi, kRegIntMask, kInt_A2HWrap);
    {
        uint32_t gcsr = 0;
        ReadRegister(dev, mi, kRegGCSR, &gcsr);
        gcsr = (gcsr & ~kGCSR_DMAMask) | (kGCSR_DMAOutSize32 | kGCSR_DMAInSize32);
        gcsr |= kGCSR_OnlyMasterDMA;
        WriteRegister(dev, mi, kRegGCSR, gcsr);
        gcsr &= ~(kGCSR_A2HDMAEnable | kGCSR_H2ADMAEnable |
                  kGCSR_A2HTrigSelect | kGCSR_H2ATrigSelect |
                  kGCSR_MeterDMAEnable | kGCSR_MeterTrigSelect);
        WriteRegister(dev, mi, kRegGCSR, gcsr);
        gcsr |= kGCSR_A2HTrigSelect | kGCSR_H2ATrigSelect;
        if (ivars->meterDMAActive) gcsr |= kGCSR_MeterTrigSelect;
        WriteRegister(dev, mi, kRegGCSR, gcsr);
        gcsr |= kGCSR_A2HDMAEnable | kGCSR_H2ADMAEnable;
        if (ivars->meterDMAActive) gcsr |= kGCSR_MeterDMAEnable;
        WriteRegister(dev, mi, kRegGCSR, gcsr);
        ivars->dmaRunning = true;
        // dext 118: stay MUTED here. Start() unmutes only after the XLink lock;
        // until ConfigureSymphonyLink has re-locked the bus the DMA stream is
        // clocked by a bus mid-reset, and with Core Audio IO continuing through
        // the recovery (dext 117) those samples would otherwise reach the
        // Symphony's outputs. RunLinkRecoveryOnQueue unmutes after a successful
        // re-lock; a failed re-lock leaves the card muted until the next attempt.
        ModifyRegister(dev, mi, kRegClkCtrl, 0,
                       kClkCtrl_Unmute | kClkCtrl_InputUnmute | kClkCtrl_OutputUnmute);
        uint32_t verify = 0;
        ReadRegister(dev, mi, kRegGCSR, &verify);
        STLOG("Card re-init: DMA restarted, card muted until the XLink re-lock completes (GCSR=0x%08x)", verify);
    }
}

// The recovery body shared by the link watch and the (now on-demand) probe path.
// Runs ON xlinkQueue. Clears linkRecoveryInFlight when done.
static void RunLinkRecoveryOnQueue(SymphonyThunderbridge_IVars *ivars, SymphonyThunderbridge *self)
{
    if (!XLinkTxAdmissible(ivars)) {
        __atomic_store_n(&ivars->linkRecoveryInFlight, false, __ATOMIC_RELEASE);
        return;
    }
    ivars->reinitSinceLastDecision = false;
    {
        uint32_t gcsr = 0;
        if (CardLostConfiguration(ivars, &gcsr)) ReprogramCardAfterReset(ivars, gcsr);
    }
    // Re-enumerate at the rate the units last ran at so Core Audio's
    // stream format and the hardware agree without a rate change.
    double rate = ivars->xlinkRate > 0.0
        ? ivars->xlinkRate
        : (ivars->audioDevice ? ivars->audioDevice->GetSampleRate() : 44100.0);
    SymphonyLinkInitResult restored = {};
    bool ok = ConfigureSymphonyLink(ivars, rate, &restored);
    // Abort checks between phases (review item 3): a power-down or a vanished
    // endpoint mid-recovery must not replay state or restart IO.
    if (ok && LinkRecoveryAborted(ivars)) {
        STLOG("Link recovery: aborted after bus init (power-down or endpoint gone)");
        ok = false;
    }
    if (ok) {
        ivars->runtimeTxSeq = 0;   // the unit restarted its message sequence with it
        ivars->linkRecoveryCount++;
        ivars->symphonyLinkConfigured = true;
        // ConfigureSymphonyLink replayed the unit's stored boot monitor
        // values. The HAL controls and the dext's cached session state
        // still hold what the user set, so push those to the hardware;
        // otherwise the slider and the unit disagree until the next change.
        {
            uint8_t spkAtten = __atomic_load_n(&ivars->speakerAttenuation, __ATOMIC_ACQUIRE);
            uint8_t spkMute  = __atomic_load_n(&ivars->speakerMute, __ATOMIC_ACQUIRE) ? 1 : 0;
            uint8_t hpAtten  = __atomic_load_n(&ivars->hp1Attenuation, __ATOMIC_ACQUIRE);
            uint8_t hpMute   = __atomic_load_n(&ivars->hp1Mute, __ATOMIC_ACQUIRE) ? 1 : 0;
            SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex, ivars->symphonyAddr,
                              kSIOCmd_SpeakerVolume, 0, &spkAtten, 1, ivars->runtimeTxSeq);
            SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex, ivars->symphonyAddr,
                              kSIOCmd_SpeakerMute, 0, &spkMute, 1, ivars->runtimeTxSeq);
            SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex, ivars->symphonyAddr,
                              kSIOCmd_HeadphoneVolume, 0, &hpAtten, 1, ivars->runtimeTxSeq);
            SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex, ivars->symphonyAddr,
                              kSIOCmd_HeadphoneMute, 0, &hpMute, 1, ivars->runtimeTxSeq);
            STLOG("Link recovery: replayed session monitor state (speaker atten=%u mute=%u, "
                  "HP1 atten=%u mute=%u)", spkAtten, spkMute, hpAtten, hpMute);
        }
        // Start() may have run with no Symphony at all, in which case the
        // option-board types were never read. Refresh them so the app's
        // card detection (kSelectorReadBoardTypes) answers from hardware.
        for (uint32_t b = 0; b < 2; b++) {
            uint8_t bt = 0;
            bool okb = ReadVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                         ivars->symphonyAddr, kSIOCmd_OptionBoardType,
                                         b, &bt, 1, ivars->runtimeTxSeq);
            ivars->optionBoardType[b]     = okb ? bt : 0;
            ivars->optionBoardTypeValid[b] = okb;
        }
        if (!LinkRecoveryAborted(ivars)) IndicateLinkOK(ivars);
        STLOG("Link recovery: Symphony re-enumerated and configured at %u Hz "
              "(recovery #%u, monitor=%s atten=%u)",
              (uint32_t)(rate + 0.5), ivars->linkRecoveryCount,
              restored.lineMonitor ? "HP1" : "speakers", restored.monitorAttenuation);
        ivars->linkClockPresent = true;
        __atomic_store_n(&ivars->linkState, kLinkStateUp, __ATOMIC_RELEASE);
        // The dext owns the IO restart (review item 5): clients refused by StartDevice
        // while the link was down, and a running IO whose anchor is stale, both need
        // the host to re-evaluate the device. Issued from the default queue: the
        // perform path barriers onto xlinkQueue, which we are on right now.
        // dext 117: a configuration change makes AVAudioEngine clients stop and
        // wait for the user (Apple: the engine "stops, uninitializes itself and
        // issues the notification"). On an ordinary wake it is not needed: Core
        // Audio already restarted IO and the first wrap IRQ after the re-init is
        // the anchor, exactly as on a normal start. Keep it when IO is not running
        // (clients refused while the link was down need a retry) or when IRQs had
        // already flowed on this start (the DMA restart made that anchor stale).
        // dext 119: the IO contract is intact — no configuration change — when a
        // card re-init ran during this recovery and the current IO run either
        // started AFTER the DMA restart (its first wrap IRQ was the anchor) or had
        // started before it but was still waiting for its first IRQ (same thing).
        // Which of the two happens is a race between the wake tick and Core
        // Audio's StartIO; both are handled. Otherwise (IO not running, a
        // Symphony free-run recovery with IRQs on a stale anchor) request the
        // change — and keep the card muted with a zeroed buffer across the IO gap
        // so nothing stale loops; the next StartDevice unmutes.
        const bool ioRunningNow = __atomic_load_n(&ivars->ioRunning, __ATOMIC_ACQUIRE);
        const bool reinitRan    = ivars->reinitSinceLastDecision;
        ivars->reinitSinceLastDecision = false;
        const bool ioStartedAfterReinit = reinitRan && ivars->startDeviceSerial != ivars->reinitStartSerial;
        const bool anchorFreshAtReinit  = reinitRan && ivars->anchorPendingAtReinit;
        if (ioRunningNow && reinitRan && (ioStartedAfterReinit || anchorFreshAtReinit)) {
            IOSleep(10);
            ModifyRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegClkCtrl,
                           kClkCtrl_Unmute | kClkCtrl_InputUnmute | kClkCtrl_OutputUnmute, 0);
            STLOG("Link recovery: IO running on an anchor taken after the DMA restart "
                  "(ioStartedAfter=%u anchorFresh=%u) — card unmuted, no configuration change "
                  "(playback continues)", ioStartedAfterReinit ? 1u : 0u, anchorFreshAtReinit ? 1u : 0u);
        } else {
            ModifyRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegClkCtrl, 0,
                           kClkCtrl_Unmute | kClkCtrl_InputUnmute | kClkCtrl_OutputUnmute);
            ZeroPlaybackDMABuffer(ivars, "IO gap around configuration change");
            ivars->unmuteOnNextStart = true;
            STLOG("Link recovery: requesting configuration change (ioRunning=%u reinit=%u) — card muted "
                  "until the next StartDevice", ioRunningNow ? 1u : 0u, reinitRan ? 1u : 0u);
            RequestIORestartFromDefaultQueue(ivars, self, "link recovered");
        }
    } else {
        STLOG("Link recovery: bus init did not complete — the link watch retries on its next tick");
        // Make the next tick treat clock presence as a fresh up-edge so it retries.
        ivars->linkClockPresent = false;
        __atomic_store_n(&ivars->linkState, kLinkStateDown, __ATOMIC_RELEASE);
    }
    __atomic_store_n(&ivars->linkRecoveryInFlight, false, __ATOMIC_RELEASE);
}

static void MaybeRecoverSymphonyLink(SymphonyThunderbridge_IVars *ivars, SymphonyThunderbridge *self)
{
    if (!ivars || !ivars->pciDevice || !ivars->xlinkQueue) return;
    if (!HardwareReachable(ivars)) return;   // dext 112: XLinkClocking read below is a BAR load
    if (__atomic_load_n(&ivars->linkRecoveryInFlight, __ATOMIC_ACQUIRE)) return;
    if (ivars->linkRecoveryCooldown > 0) {
        ivars->linkRecoveryCooldown--;
        return;
    }

    // dext 112 (review item 3): the three clock-detect loads run on the serial
    // xlinkQueue — the queue SetPowerState(Off) drains — not on the caller's
    // thread. We are on the user-client thread here (ReadTimingHealth, outside
    // its own DispatchSync), so this sync hop cannot nest.
    __block uint32_t clk = 0;
    __block bool clockPresent = false;
    ivars->xlinkQueue->DispatchSync(^{
        if (!XLinkTxAdmissible(ivars)) return;
        for (int i = 0; i < 3; i++) {
            ReadRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegXLinkClocking, &clk);
            if (!(clk & kXLinkRX1ClockDetect) || !(clk & kXLinkSR1Mask)) return;
            if (i < 2) IOSleep(20);
        }
        clockPresent = true;
    });
    if (!clockPresent) {
        ivars->linkFaultSeen = true;   // the legacy NO_CLOCK state: the "was down" edge
        if (clk != ivars->lastLoggedNoClockReg) {
            ivars->lastLoggedNoClockReg = clk;
            STLOG("Link recovery: no Symphony clock yet (XLinkClocking=0x%08x) — waiting",
                  clk);
        }
        return;
    }
    ivars->lastLoggedNoClockReg = 0;
    // The legacy driver only reconfigured on the NO_CLOCK → clock transition.
    // A single failed vendor read on a powered, configured unit (busy
    // firmware, one lost message) must not reset a working link: that would
    // replay default mutes and routing and restart IO. Require that a probe
    // saw the clock absent since the last success, or that the link has been
    // unresponsive for several consecutive probes with the clock present.
    if (!ivars->linkFaultSeen && ivars->consecutiveProbeFailures < kLinkRecoveryStuckProbes) {
        if (ivars->consecutiveProbeFailures == 1) {
            STLOG("Link recovery: vendor read failed with clock present (XLinkClocking=0x%08x) "
                  "— transient, not re-initializing", clk);
        }
        return;
    }
    ivars->linkRecoveryCooldown = 4;   // ≥4 failed probes (~4 s) between attempts
    __atomic_store_n(&ivars->linkRecoveryInFlight, true, __ATOMIC_RELEASE);
    __atomic_store_n(&ivars->linkState, kLinkStateRecovering, __ATOMIC_RELEASE);
    STLOG("Link recovery: Symphony clock present (XLinkClocking=0x%08x) but no vendor "
          "response — re-running XLink bus init in place", clk);
    self->retain();
    ivars->xlinkQueue->DispatchAsync(^{
        RunLinkRecoveryOnQueue(ivars, self);
        self->release();
    });
}

// The link watch tick. Runs on xlinkQueue (the timer was created on it), so it
// serializes with every vendor transaction, the rate transaction, and the
// recovery body. Decision order: (1) past Stop() → do nothing, never re-arm;
// (2) powering down / endpoint vanished → no BAR access, re-arm; (3) audio wraps
// advancing → link proven, no bus traffic; (4) otherwise the dext-112 presence
// proof followed by ONE register read of the card's XLink clock-detect bit.
void IMPL(SymphonyThunderbridge, LinkWatchTimerOccurred)
{
    if (!ivars) return;
    if (__atomic_load_n(&ivars->stopping, __ATOMIC_ACQUIRE) ||
        __atomic_load_n(&ivars->txShutdown, __ATOMIC_ACQUIRE)) return;
    ivars->linkWatchTicks++;
    uint64_t next = kLinkWatchFastNs;
    do {
        if (__atomic_load_n(&ivars->providerPowerOff, __ATOMIC_ACQUIRE)) break;
        if (__atomic_load_n(&ivars->hwSuspended, __ATOMIC_ACQUIRE)) {
            // Suspended by a failed presence check: HardwareReachable is the only
            // thing that may clear it (two config-space reads, no BAR load). If it
            // does, the next tick takes the normal path.
            (void)HardwareReachable(ivars);
            break;
        }
        // A resume after an endpoint-absent suspend (HardwareReachable sets
        // linkRecoveryNeedsIORestart) is treated like a wake: revalidate the link.
        const bool revalidate = __atomic_load_n(&ivars->linkNeedsRevalidation, __ATOMIC_ACQUIRE)
                             || ivars->linkRecoveryNeedsIORestart;
        const bool ioRunning  = __atomic_load_n(&ivars->ioRunning, __ATOMIC_ACQUIRE);
        const uint64_t wraps  = __atomic_load_n(&ivars->audioWrapCount, __ATOMIC_ACQUIRE);
        const bool wrapsFlowing = ioRunning && wraps != ivars->lastWrapCountSeen;
        ivars->lastWrapCountSeen = wraps;
        // dext 114: audio wraps prove the IRQ/DMA path, NOT the Symphony. Bench
        // 2026-10-27: with the Symphony switched off the card kept delivering A2H
        // wraps (it free-runs on its DDS) and the UI stayed Connected. Wraps only
        // stretch the sampling interval (10 s while streaming); the clock-detect
        // read below always decides.
        // The dext-112 presence proof stays in front of every BAR load.
        if (!HardwareReachable(ivars)) break;
        uint32_t clk = 0;
        ReadRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegXLinkClocking, &clk);
        if (clk == 0xFFFFFFFFu) {
            // The endpoint stopped answering between the config-space proof and
            // this load: suspend exactly as a failed presence check would.
            ivars->suspendedByProbe = true;
            __atomic_store_n(&ivars->hwSuspended, true, __ATOMIC_RELEASE);
            STLOG("Link watch: BAR read returned all-ones — BAR access suspended");
            break;
        }
        ivars->lastWatchClockReg = clk;
        bool present = (clk & kXLinkRX1ClockDetect) != 0;   // SR bits are advisory (settle ~700 ms after a rate change)
        if (present && !ivars->linkClockPresent) {
            // Debounce the up edge the way the recovery's own check does.
            IOSleep(20);
            uint32_t clk2 = 0;
            ReadRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegXLinkClocking, &clk2);
            present = (clk2 != 0xFFFFFFFFu) && (clk2 & kXLinkRX1ClockDetect) != 0;
            if (clk2 != 0xFFFFFFFFu) { ivars->lastWatchClockReg = clk2; clk = clk2; }
        }
        const bool was = ivars->linkClockPresent;
        ivars->linkClockPresent = present;
        if (!present) {
            if (was || __atomic_load_n(&ivars->linkState, __ATOMIC_ACQUIRE) != kLinkStateDown)
                STLOG("Link watch: no Symphony clock (XLinkClocking=0x%08x) — link down", clk);
            ivars->linkFaultSeen = true;   // the legacy NO_CLOCK edge: recovery runs when it returns
            __atomic_store_n(&ivars->linkNeedsRevalidation, false, __ATOMIC_RELEASE);
            __atomic_store_n(&ivars->wakeFoundEndpointAbsent, false, __ATOMIC_RELEASE);
            __atomic_store_n(&ivars->linkState, kLinkStateDown, __ATOMIC_RELEASE);
            break;
        }
        bool needRecovery = !was || !ivars->symphonyLinkConfigured;
        {
            // dext 115: a card that lost its programmed state (D3 power cycle)
            // answers in config space and on XLink but has no DMA/IRQ/routing.
            uint32_t gcsrNow = 0;
            const bool lost = CardLostConfiguration(ivars, &gcsrNow);
            ivars->lastWatchGcsr = gcsrNow;
            if (lost) {
                STLOG("Link watch: card lost its programmed state (GCSR=0x%08x) — re-initializing", gcsrNow);
                needRecovery = true;
            }
        }
        // dext 114: the card latches "link was down" in XLink1Status (write-1-to-
        // clear; Start()/ConfigureSymphonyLink clear all of them). If the Symphony
        // dropped and came back between two samples, these bits are the only
        // trace of it — and an unconfigured Symphony is exactly the silent
        // "everything looks connected" state. Only the DOWN bits are used: the
        // slip bits set during ordinary rate changes and would cause spurious
        // re-locks. Cleared here so the trigger is edge-shaped.
        {
            constexpr uint32_t kDataDownSticky = 0x00000010u;   // pci2k5_sys.h data-down sticky
            constexpr uint32_t kDownStickyMask = kXLinkRX18DownSticky | kDataDownSticky;
            uint32_t xs = 0;
            ReadRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegXLink1Status, &xs);
            ivars->lastWatchXlinkStatus = xs;
            if (xs != 0xFFFFFFFFu && (xs & kDownStickyMask) != 0) {
                STLOG("Link watch: XLink down-sticky bits set (status=0x%08x) — the Symphony link "
                      "dropped between samples; re-locking", xs);
                WriteRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegXLink1Status,
                              xs & kDownStickyMask);
                needRecovery = true;
            }
        }
        if (revalidate) {
            __atomic_store_n(&ivars->linkNeedsRevalidation, false, __ATOMIC_RELEASE);
            ivars->linkRecoveryNeedsIORestart = false;
            const bool tunnelWasAbsent = __atomic_load_n(&ivars->wakeFoundEndpointAbsent, __ATOMIC_ACQUIRE);
            __atomic_store_n(&ivars->wakeFoundEndpointAbsent, false, __ATOMIC_RELEASE);
            // Wake revalidation (Apple's reference driver re-initializes on the
            // power-on transition). Bus mastering is re-asserted ONLY here — never
            // from the steady-state path, which could race IOPCIFamily's pause
            // handling of a pause-compatible device.
            uint16_t cmd = 0;
            ivars->pciDevice->ConfigurationRead16(0x04, &cmd);
            if (cmd != 0xFFFF && (cmd & 0x0006) != 0x0006) {
                ivars->pciDevice->ConfigurationWrite16(0x04, (uint16_t)(cmd | 0x0006));
                STLOG("Link watch: wake revalidation re-enabled MemSpace+BusMaster (was 0x%04x)", cmd);
                needRecovery = true;
            }
            uint32_t xs = 0;
            ReadRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegXLink1Status, &xs);
            const uint32_t faultMask = kXLinkDataDownCurrent | kXLinkDataSlipCurrent | kXLinkDataSlipSticky;
            if (xs == 0xFFFFFFFFu || (xs & faultMask) != 0 || tunnelWasAbsent) needRecovery = true;
            STLOG("Link watch: wake revalidation XLink1Status=0x%08x clocking=0x%08x tunnelWasAbsent=%u → %s",
                  xs, clk, tunnelWasAbsent ? 1u : 0u, needRecovery ? "re-lock + IO restart" : "clean");
        }
        if (needRecovery) {
            if (!__atomic_load_n(&ivars->linkRecoveryInFlight, __ATOMIC_ACQUIRE)) {
                __atomic_store_n(&ivars->linkRecoveryInFlight, true, __ATOMIC_RELEASE);
                __atomic_store_n(&ivars->linkState, kLinkStateRecovering, __ATOMIC_RELEASE);
                STLOG("Link watch: Symphony clock present (XLinkClocking=0x%08x) — re-running XLink bus init", clk);
                this->retain();
                SymphonyThunderbridge *self = this;
                ivars->xlinkQueue->DispatchAsync(^{
                    RunLinkRecoveryOnQueue(ivars, self);
                    self->release();
                });
            }
            break;
        }
        __atomic_store_n(&ivars->linkState, kLinkStateUp, __ATOMIC_RELEASE);
        next = wrapsFlowing ? kLinkWatchStreamNs : kLinkWatchIdleNs;
    } while (false);
    ArmLinkWatch(ivars, next);
}

// ── ReadLinkState (dext 113) ─────────────────────────────────────────────────
// The app's presence/liveness read. Reads ivars only — NO bus access — so the
// app may call it as often as it likes without putting traffic on the tunnel.
kern_return_t SymphonyThunderbridge::ReadLinkState(uint32_t *outWords)
{
    if (!ivars || !outWords) return kIOReturnBadArgument;
    const uint64_t irq   = __atomic_load_n(&ivars->interruptCount, __ATOMIC_ACQUIRE);
    const uint64_t wraps = __atomic_load_n(&ivars->audioWrapCount, __ATOMIC_ACQUIRE);
    outWords[0]  = 0;
    outWords[1]  = __atomic_load_n(&ivars->linkState, __ATOMIC_ACQUIRE);
    outWords[2]  = ivars->linkClockPresent ? 1u : 0u;
    outWords[3]  = __atomic_load_n(&ivars->ioRunning, __ATOMIC_ACQUIRE) ? 1u : 0u;
    outWords[4]  = (uint32_t)(irq & 0xFFFFFFFFu);
    outWords[5]  = (uint32_t)(irq >> 32);
    outWords[6]  = (uint32_t)ivars->linkRecoveryCount;
    outWords[7]  = __atomic_load_n(&ivars->hwSuspended, __ATOMIC_ACQUIRE) ? 1u : 0u;
    outWords[8]  = ivars->symphonyLinkConfigured ? 1u : 0u;
    outWords[9]  = ivars->lastWatchClockReg;
    outWords[10] = (uint32_t)(ivars->linkWatchTicks & 0xFFFFFFFFu);
    outWords[11] = (uint32_t)(wraps & 0xFFFFFFFFu);
    outWords[12] = ivars->lastWatchGcsr;          // dext 117
    outWords[13] = ivars->lastWatchXlinkStatus;
    outWords[14] = ivars->cardReinitCount;
    outWords[15] = 0;
    return kIOReturnSuccess;
}

// ── Lifecycle ───────────────────────────────────────────────────────────────

bool SymphonyThunderbridge::init()
{
    if (!super::init()) {
        return false;
    }
    ivars = IONewZero(SymphonyThunderbridge_IVars, 1);
    if (!ivars) {
        return false;
    }
    STLOG("init()");
    return true;
}

void SymphonyThunderbridge::free()
{
    STLOG("free()");
    if (ivars) {
        // Interrupt source and queue are released in Stop()'s Cancel completion.
        // OSSafeReleaseNULL is safe on nullptr (no-op if already released).
        OSSafeReleaseNULL(ivars->interruptSource);
        OSSafeReleaseNULL(ivars->interruptQueue);
        // #2: free() is the ONLY place the XLink queue is released. Stop() keeps it
        // alive (it merely drains it) so a late user-client SendVendorCommand or a
        // queued rate transaction can always DispatchSync onto a live queue and
        // observe the shutdown flags. By the time free() runs the object is being
        // destroyed — no caller can reach the queue — so releasing it here is safe.
        OSSafeReleaseNULL(ivars->linkWatchTimer);   // normally released in Stop()'s cancel completion
        OSSafeReleaseNULL(ivars->defaultQueue);
        OSSafeReleaseNULL(ivars->xlinkQueue);
        IOSafeDeleteNULL(ivars, SymphonyThunderbridge_IVars, 1);
    }
    super::free();
}

kern_return_t IMPL(SymphonyThunderbridge, Start)
{
    kern_return_t ret;
    // Must be declared before the lifecycle error-path gotos below.
    const uint32_t initialFrameSize = FPGAFrameSizeForRate(44100.0);
    // Restored monitor state is read during XLink setup and reused when the
    // AudioDriverKit controls are created later in Start(). Keep these outside
    // the setup scope so the HAL controls start on the same target and value.
    bool initialLineMonitor = false;
    uint8_t initialMonitorAttenuation = 20;
    bool initialMonitorMute = false;
    uint8_t initialSpeakerAttenuation = 20;
    bool initialSpeakerMute = false;
    uint8_t initialHP1Attenuation = 20;
    bool initialHP1Mute = false;

    STLOG("Start() — Apogee ThunderBridge DriverKit driver");

    ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) {
        STERR("super::Start failed: 0x%x", ret);
        return ret;
    }

    // ── 1. Get the PCIe device provider ─────────────────────────────────────

    ivars->pciDevice = OSDynamicCast(IOPCIDevice, provider);
    if (!ivars->pciDevice) {
        STERR("Provider is not an IOPCIDevice");
        Stop(provider, SUPERDISPATCH);
        return kIOReturnUnsupported;
    }
    ivars->pciDevice->retain();

    // ── 2. Open a session to the PCIe device ────────────────────────────────

    ret = ivars->pciDevice->Open(this, 0);
    if (ret != kIOReturnSuccess) {
        STERR("IOPCIDevice::Open failed: 0x%x", ret);
        // M6: Open failed — no session to Close, but we retained pciDevice above.
        // Release it before unwinding super so the retain does not leak. (Start()
        // returning failure means our own Stop() teardown never runs.)
        OSSafeReleaseNULL(ivars->pciDevice);
        Stop(provider, SUPERDISPATCH);
        return ret;
    }
    STLOG("PCIe device opened");

    uint32_t pciID = 0;
    // ConfigurationRead32 is a void DriverKit API; invalid/unmapped config space
    // reads are reported as 0xFFFFFFFF. Treat any non-Apogee or unsupported device
    // ID as a hard failure rather than falling through to ThunderBridge behavior.
    ivars->pciDevice->ConfigurationRead32(0x00, &pciID);
    const uint16_t pciVendor = (uint16_t)(pciID & 0xFFFF);
    const uint16_t pciDevice = (uint16_t)((pciID >> 16) & 0xFFFF);
    const bool supportedPCIeID = pciVendor == kApogeeVendorID &&
        (pciDevice == kThunderBridgeDeviceID || pciDevice == kSymphonyPCIeDeviceID);
    if (pciID == 0xFFFFFFFFu || !supportedPCIeID) {
        STERR("Unsupported or unreadable PCI identity: raw=0x%08x vendor=0x%04x device=0x%04x",
              pciID, pciVendor, pciDevice);
        ivars->pciDevice->Close(this, 0);
        OSSafeReleaseNULL(ivars->pciDevice);
        Stop(provider, SUPERDISPATCH);
        return kIOReturnUnsupported;
    }
    ivars->isLegacyPCIe2100 = (pciVendor == kApogeeVendorID && pciDevice == kSymphonyPCIeDeviceID);
    STLOG("PCI identity: vendor=0x%04x device=0x%04x (%s)", pciVendor, pciDevice,
          ivars->isLegacyPCIe2100 ? "legacy PCIe 2100" : "ThunderBridge 2200");

    // ── 2a. Explicitly enable Memory Space + Bus Master in PCI Command reg ──
    // Legacy kext calls setMemoryEnable(true) + setBusMasterEnable(true)
    // (SymphonyBaseCard.cpp:109, Symphony64Card.cpp:125).
    // DriverKit Open() may not set these. Without Memory Space Enable,
    // BAR MMIO reads return 0xFFFFFFFF.

    {
        uint16_t cmdReg = 0;
        ivars->pciDevice->ConfigurationRead16(0x04, &cmdReg);
        STLOG("PCI Command register before: 0x%04x (MemSpace=%u, BusMaster=%u)",
              cmdReg, (cmdReg >> 1) & 1, (cmdReg >> 2) & 1);

        uint16_t needed = cmdReg | 0x0006; // bit1=MemSpace, bit2=BusMaster
        if (needed != cmdReg) {
            ivars->pciDevice->ConfigurationWrite16(0x04, needed);
            STLOG("PCI Command register: enabled MemSpace + BusMaster → 0x%04x", needed);

            // Re-read to confirm
            uint16_t verify = 0;
            ivars->pciDevice->ConfigurationRead16(0x04, &verify);
            STLOG("PCI Command register after: 0x%04x", verify);
        } else {
            STLOG("PCI Command register: MemSpace + BusMaster already enabled");
        }
    }

    // ── 2b. Quiesce FPGA from any previous session ─────────────────────────
    // If the previous dext process was killed (pkill, crash, or kernel panic)
    // without calling Stop(), the FPGA continues DMA and fires interrupts into
    // freed memory. Disable everything BEFORE we set up our interrupt handler
    // or allocate DMA buffers. This prevents crash loops on restart.
    {
        // We need BAR info first to use MemoryWrite32. Get it temporarily.
        uint8_t tmpMemIdx = 0;
        uint64_t tmpSize = 0;
        uint8_t tmpType = 0;
        ret = ivars->pciDevice->GetBARInfo(0, &tmpMemIdx, &tmpSize, &tmpType);
        if (ret == kIOReturnSuccess && tmpSize > 0) {
            // Disable all interrupts
            ivars->pciDevice->MemoryWrite32(tmpMemIdx, kRegIntMask, 0);
            // Clear pending interrupt status
            ivars->pciDevice->MemoryWrite32(tmpMemIdx, kRegIntStatus, 0xFFFFFFFF);
            // Disable DMA enable bits in GCSR
            uint32_t gcsr = 0;
            ivars->pciDevice->MemoryRead32(tmpMemIdx, kRegGCSR, &gcsr);
            gcsr &= ~kGCSR_DMAEnableMask;
            ivars->pciDevice->MemoryWrite32(tmpMemIdx, kRegGCSR, gcsr);
            // Disable DMA enable bits in GCSR2 (Port 2)
            uint32_t gcsr2 = 0;
            ivars->pciDevice->MemoryRead32(tmpMemIdx, kRegGCSR2, &gcsr2);
            gcsr2 &= ~kGCSR2_DMAEnableMask;
            ivars->pciDevice->MemoryWrite32(tmpMemIdx, kRegGCSR2, gcsr2);
            IOSleep(5);  // Let FPGA settle
            STLOG("Start: FPGA quiesced (DMA+IRQ disabled — dirty-state protection)");
        }
    }

    // ── 3. Get BAR0 info (FPGA MMIO space) ──────────────────────────────────

    uint8_t barIndex = 0;  // BAR0
    uint64_t barSize = 0;
    uint8_t barType = 0;

    ret = ivars->pciDevice->GetBARInfo(barIndex, &ivars->barMemoryIndex,
                                        &barSize, &barType);
    if (ret != kIOReturnSuccess) {
        STERR("GetBARInfo failed for BAR0: 0x%x", ret);
        // M6: close the PCIe session we opened and release our retain before
        // unwinding super — Start() failure means our Stop() teardown never runs.
        ivars->pciDevice->Close(this, 0);
        OSSafeReleaseNULL(ivars->pciDevice);
        Stop(provider, SUPERDISPATCH);
        return ret;
    }
    ivars->barSize = barSize;
    STLOG("BAR0 mapped: memoryIndex=%u, size=%llu bytes, type=%u",
          ivars->barMemoryIndex, barSize, barType);

    // ── 4. Scratch register test (verify FPGA MMIO works) ───────────────────
    // Legacy: 100 retries × 10ms = 1 second timeout. (Symphony64Card.cpp:130)
    // Each iteration writes 0xDEADBEEF then reads back.

    uint32_t scratchValue = 0;
    bool scratchOK = false;
    int nTimeout = 100;

    while (!scratchOK && nTimeout > 0) {
        WriteRegister(ivars->pciDevice, ivars->barMemoryIndex,
                      kRegScratch, kScratchTestPattern);
        IOSleep(10);
        ReadRegister(ivars->pciDevice, ivars->barMemoryIndex,
                     kRegScratch, &scratchValue);
        if (scratchValue == kScratchTestPattern) {
            scratchOK = true;
        }
        nTimeout--;
    }

    if (!scratchOK) {
        // Don't fail-stop — continue running for diagnostics.
        // FPGA may need Symphony mode, power cycling, or XLink connection.
        STERR("Scratch register test FAILED after 100 retries: wrote 0x%x, read 0x%x",
              kScratchTestPattern, scratchValue);
        STERR("FPGA not responding — check: (1) Symphony IO powered on, "
              "(2) Symphony mode (not Standalone), (3) ThunderBridge cable/link");

        // Dump diagnostic registers even though scratch failed
        uint32_t diag = 0;
        ReadRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegIDReg, &diag);
        STLOG("  Diagnostic: IDREG=0x%08x", diag);
        ReadRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegGCSR, &diag);
        STLOG("  Diagnostic: GCSR=0x%08x", diag);
        ReadRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegClkCtrl, &diag);
        STLOG("  Diagnostic: ClkCtrl=0x%08x", diag);
        ReadRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegFlash, &diag);
        STLOG("  Diagnostic: Flash=0x%08x", diag);

        // Still register service — allows re-probing without uninstall
        RegisterService();
        return kIOReturnSuccess;
    }
    STLOG("Scratch register test PASSED (0xDEADBEEF round-trip OK, %d retries)",
          100 - nTimeout);

    // ── 5. Read board ID register ───────────────────────────────────────────
    // Legacy: Symphony64Card.cpp:138-143

    uint32_t idReg = 0;
    ReadRegister(ivars->pciDevice, ivars->barMemoryIndex,
                 kRegIDReg, &idReg);
    if (idReg == 0xFFFFFFFF) {
        STERR("ID register read failed (returned 0xFFFFFFFF)");
        // M6: close the PCIe session and release our retain before unwinding super.
        ivars->pciDevice->Close(this, 0);
        OSSafeReleaseNULL(ivars->pciDevice);
        Stop(provider, SUPERDISPATCH);
        return kIOReturnDeviceError;
    }

    ivars->fpgaVersion = GetFPGAVersion(idReg);
    ivars->hardwareVersion = GetHardwareVersion(idReg);
    ivars->isMaster = IsBoardMaster(idReg);

    STLOG("Board ID: 0x%08x", idReg);
    STLOG("  FPGA version:     %u (0x%02x)", ivars->fpgaVersion, ivars->fpgaVersion);
    STLOG("  Hardware version:  %u", ivars->hardwareVersion);
    STLOG("  Board role:        %s", ivars->isMaster ? "MASTER" : "SLAVE");

    if (ivars->fpgaVersion < kMinimumFPGAVersion) {
        STERR("FPGA version %u < minimum %u — hardware too old",
              ivars->fpgaVersion, kMinimumFPGAVersion);
        // M6: close the PCIe session and release our retain before unwinding super.
        ivars->pciDevice->Close(this, 0);
        OSSafeReleaseNULL(ivars->pciDevice);
        Stop(provider, SUPERDISPATCH);
        return kIOReturnUnsupported;
    }

    // ── 6. Read device DNA (serial number) ──────────────────────────────────
    // Legacy: Symphony64Card.cpp:158-162

    uint32_t dnaUpper = 0, dnaLower = 0;
    ReadRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegDNAUpper, &dnaUpper);
    ReadRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegDNALower, &dnaLower);
    ivars->serialNumber = ((uint64_t)dnaUpper << 32) | dnaLower;
    STLOG("  Serial number:     0x%016llx", ivars->serialNumber);

    // ── 7. Read XLink status ────────────────────────────────────────────────

    uint32_t xlink1Status = 0, xlink2Status = 0;
    ReadRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegXLink1Status, &xlink1Status);
    ReadRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegXLink2Status, &xlink2Status);
    STLOG("  XLink 1 status:    0x%08x", xlink1Status);
    STLOG("  XLink 2 status:    0x%08x", xlink2Status);

    // ── 8. Read flash status ────────────────────────────────────────────────

    uint32_t flashStatus = 0;
    ReadRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegFlash, &flashStatus);
    bool isGoldenImage = (flashStatus & kFlashUpdateGolden) != 0;
    STLOG("  Flash status:      0x%08x (%s image)", flashStatus,
          isGoldenImage ? "GOLDEN" : "user");

    // ── 9. Clear RX status errors ──────────────────────────────────────────
    // Legacy: Symphony64Card.cpp:196

    WriteRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegRxStatusErr, 0xFFFFFFFF);

    // ── 10. Configure GCSR (endianness) ──────────────────────────────────
    // AHND/HAND = "Non-Default" endianness. FPGA native TDM is Big Endian (PPC era).
    //   AHND/HAND=0: DMA data in FPGA native order (Big Endian)
    //   AHND/HAND=1: DMA data in non-default order (Little Endian — for Intel/ARM hosts)
    // Apple Silicon = LE, so MUST set AHND|HAND to get LE SInt32 in DMA buffers.
    //
    // Legacy: Symphony64Card.cpp:192 — ThunderBridge uses SInt32 DMA with AHND|HAND.
    // NO float conversion (AHCN/HACN) — CoreAudio does Float32↔SInt32 internally.
    // Evidence: Audio MIDI Setup on Intel Mac shows "32ch-32bit Integer", not Float.
    // Legacy clipOutputSamples uses IOAF_Float32ToNativeInt32() for CPU conversion.
    WriteRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegGCSR, kGCSR_SwapToLE);
    STLOG("GCSR configured: SInt32 DMA, byte-swap to LE (AHND|HAND), no float conv (0x%08x)",
          kGCSR_SwapToLE);

    // ── 11. Enable XLink port 1 ─────────────────────────────────────────
    // Legacy: setCardEnabled() at Symphony64Card.cpp:2258 enables XLink clocking.
    // This allows the ThunderBridge to detect Symphony IO on PC-32.

    ModifyRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegXLinkClocking,
                   kXLinkClockEnable1, 0);
    STLOG("XLink port 1 enabled (XLINK_CLOCKING_ENABLE_1)");

    SymphonyLinkInitResult linkInit = {};
    ivars->symphonyLinkConfigured = ConfigureSymphonyLink(ivars, 44100.0, &linkInit);
    if (ivars->symphonyLinkConfigured) {
        initialLineMonitor        = linkInit.lineMonitor;
        initialMonitorAttenuation = linkInit.monitorAttenuation;
        initialMonitorMute        = linkInit.monitorMute;
        initialSpeakerAttenuation = linkInit.speakerAttenuation;
        initialSpeakerMute        = linkInit.speakerMute;
        initialHP1Attenuation     = linkInit.hp1Attenuation;
        initialHP1Mute            = linkInit.hp1Mute;
    } else {
        // No Symphony clock (unit off or PC-32 cable absent). The legacy
        // driver still published its audio engine in this state and let its
        // XLink thread configure the unit when the clock appeared. Do the
        // same: continue with the card-side setup and publish the audio
        // device, so Maestro's 1 Hz health probe reaches ReadTimingHealth()
        // and MaybeRecoverSymphonyLink() can run the bus init in place once
        // the Symphony is powered on. Until then the LED keeps the legacy
        // red/green "no clock" pattern and the app presents Symphony as
        // disconnected. (Before build 108 this path returned here with no
        // audio device, so a Symphony powered on after the dext needed a
        // cable replug.)
        STLOG("XLink: continuing without a Symphony — audio device will be published; "
              "link recovery runs from the health probe");
    }

    // ── 20. Re-read status after full config ────────────────────────
    {
        uint32_t xlink1Post = 0, xlinkClkPost = 0;
        ReadRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegXLink1Status, &xlink1Post);
        ReadRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegXLinkClocking, &xlinkClkPost);
        STLOG("XLink 1 status (post-config): 0x%08x", xlink1Post);
        STLOG("XLink clocking (post-config): 0x%08x", xlinkClkPost);
        STLOG("  DataSlipSticky=%u DataSlipCurrent=%u DataDownCurrent=%u SlaveMode=%u",
              (xlink1Post & kXLinkDataSlipSticky) ? 1 : 0,
              (xlink1Post >> 19) & 1,  // DATA_SLIP_CURRENT = bit 19
              (xlink1Post >> 14) & 1,  // DATA_DOWN_CURRENT = bit 14
              (xlink1Post >> 20) & 1); // SLAVE_MODE = bit 20
    }

    // ── 21. Set LED to green — only once a Symphony is actually configured ──
    if (ivars->symphonyLinkConfigured) IndicateLinkOK(ivars);

    // ══════════════════════════════════════════════════════════════════════════
    // ── Routing & Mixer Initialization ────────────────────────────────────────
    // Legacy: XLink::XLink() calls Sym64Routing::init() + Mixer::init()
    // Must be done BEFORE DMA starts so audio has a path to the outputs.
    // ══════════════════════════════════════════════════════════════════════════

    // ── 21b. Output routing: map H2A DMA channels → XLink TX outputs ──────
    // Legacy: Sym64Routing::init() at Sym64Routing.cpp:299-322
    // Each output route: XLink out[n] ← TDM slot (PCI_OUT0 + n), enabled.
    // This is the critical step — without it, DMA playback data never
    // reaches the XLink bus (and thus never reaches the Symphony IO DACs).

    for (uint32_t n = 0; n < kMaxChannelsPerPort; n++) {
        // Main stereo ch0/1 come from the card Mixer 0 output (TDM slots 128/129)
        // so the app's mixer (SW-return fader/mute/master) affects the speakers.
        // ch2-31 stay direct PCI_OUT (host playback straight to XLink TX). The mixer
        // is set up + fed host playback below (step 21d-2); at unity it passes audio
        // unchanged. Evidence: original Sym64Routing.cpp:249-254 routes MIXER0..3_OUT
        // to outputs; SymphonyPCIeRoutingController.cpp:1164 (ThunderBridge=Sym64 default).
        uint32_t src = (n < 2) ? (kTDM_Mixer0Out + n) : (kTDM_PCIOut0 + n);
        WriteRegister(ivars->pciDevice, ivars->barMemoryIndex,
                      kRegOutputRouting + n * 4,
                      src | kRoutingEnable);
    }
    STLOG("Output routing: ch0/1 ← Mixer0/1 out (128/129), ch2-%u ← PCI_OUT (enabled)",
          kMaxChannelsPerPort - 1);

    // ── 21c. Input routing: map XLink RX inputs → A2H DMA channels ────────
    // Legacy: Sym64Routing::init() — 1:1 mapping of XLink RX to PCI input.
    // Needed for capture (recording from Symphony IO ADCs).

    for (uint32_t n = 0; n < kMaxChannelsPerPort; n++) {
        WriteRegister(ivars->pciDevice, ivars->barMemoryIndex,
                      kRegInputRouting + n * 4,
                      (kTDM_XLinkRX0 + n) | kRoutingEnable);
    }
    STLOG("Input routing: %u channels mapped (XLink RX → PCI_IN, enabled)",
          kMaxChannelsPerPort);

    // ── 21d. Clear mixer coefficients ─────────────────────────────────────
    // Legacy: Mixer::init() — zero all coefficients, select table LOW.
    // Not required for basic playback (routing bypasses mixer) but prevents
    // stale mixer state from previous sessions.

    for (uint64_t off = 0; off < 0x1000; off += 4) {
        WriteRegister(ivars->pciDevice, ivars->barMemoryIndex,
                      kRegMixerCoeff + off, 0);
    }
    WriteRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegMixerControl, 0);
    STLOG("Mixer: coefficients cleared, table LOW selected");

    // ── 21d-2. Card mixer: route host playback ch0/1 into Mixer0 return @ unity ──
    // The ThunderBridge card FPGA has a low-latency mixer: 64 fixed inputs (XLink RX
    // hardware inputs) + one RETURN per mixer (must be a PCI_OUT host-playback slot),
    // emitting TDM slot 128+m. Physical mixers: 0=A-L, 1=A-R. We feed host playback
    // (PCI_OUT0/1) into Mixer0(L)/Mixer1(R) returns at unity, so main-stereo playback
    // flows host → card mixer → XLink → Symphony IO DAC (output routing above sends
    // slots 128/129 to XLink ch0/1). The 32 fixed inputs stay muted (coeffs cleared).
    //
    // This replaces the IO-unit-mixer (0x31/0xE4) approach, which is USB-only and was
    // silent on Thunderbolt. Evidence (original Apogee source): Sym64Mixer.cpp (return
    // must be PCI_OUT, :269), SymphonyPCIeCardMixer.cpp (RouteReturn/ReturnLevel), and
    // the register audit in Docs/thunderbolt-learnings.md.
    {
        // Route PCI_OUT0/1 (host playback L/R) → Mixer0/1 return input
        // (kRegMixerRouting + m*4 = (slot & 0xFF) | ENABLE; slot must be 64..127)
        WriteRegister(ivars->pciDevice, ivars->barMemoryIndex,
                      ThunderboltMixerReturnRegister(1, 0),
                      ThunderboltSoftwareReturnSlot(0, 0) | kRoutingEnable); // 0x140
        WriteRegister(ivars->pciDevice, ivars->barMemoryIndex,
                      ThunderboltMixerReturnRegister(1, 1),
                      ThunderboltSoftwareReturnSlot(0, 1) | kRoutingEnable); // 0x141
        // Return-level coefficients to unity (return slot = 128+m):
        //   MixerCoefOffset(0,128) = 0x4400 (L), MixerCoefOffset(1,129) = 0x4C08 (R)
        WriteRegister(ivars->pciDevice, ivars->barMemoryIndex,
                      MixerCoefOffset(0, 128), kMixerUnityCoeff);
        WriteRegister(ivars->pciDevice, ivars->barMemoryIndex,
                      MixerCoefOffset(1, 129), kMixerUnityCoeff);
        // Mixer 2 is the second physical stereo mixer on the card. Keep its
        // host-playback return and unity coefficients initialized separately;
        // otherwise its first control write aliases Mixer 1's state.
        WriteRegister(ivars->pciDevice, ivars->barMemoryIndex,
                      ThunderboltMixerReturnRegister(2, 0),
                      ThunderboltSoftwareReturnSlot(0, 0) | kRoutingEnable);
        WriteRegister(ivars->pciDevice, ivars->barMemoryIndex,
                      ThunderboltMixerReturnRegister(2, 1),
                      ThunderboltSoftwareReturnSlot(0, 1) | kRoutingEnable);
        WriteRegister(ivars->pciDevice, ivars->barMemoryIndex,
                      MixerCoefOffset(2, 128), kMixerUnityCoeff);
        WriteRegister(ivars->pciDevice, ivars->barMemoryIndex,
                      MixerCoefOffset(3, 129), kMixerUnityCoeff);
        ivars->mixerSwReturnSource[0] = 0;
        ivars->mixerSwReturnSource[1] = 0;
        STLOG("Card mixer: host PCI_OUT0/1 → Mixer0/1 return @ unity (0x%08x); out → XLink ch0/1",
              kMixerUnityCoeff);
    }

    // ── 21e. Ensure GCSR2 port 1 is enabled ───────────────────────────────
    // Legacy: setCardEnabled() clears DisablePort1. Bit may be stale.

    ModifyRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegGCSR2,
                   0, kGCSR2_DisablePort1);
    STLOG("GCSR2: Port 1 enabled (DisablePort1 cleared)");

    // NOTE: ClkCtrl unmute moved to AFTER DMA start (step 29b).
    // Legacy: performAudioEngineStart() unmutes AFTER StartDMA() + 10ms delay.
    // Unmuting before DMA can cause the FPGA to output garbage to XLink.

    // ── 21f. Routing diagnostic readbacks ────────────────────────────────
    // Verify routing registers were written. ClkCtrl unmute=0 here (set after DMA).
    {
        uint32_t outRoute0 = 0, outRoute1 = 0, outRoute31 = 0;
        ReadRegister(ivars->pciDevice, ivars->barMemoryIndex,
                     kRegOutputRouting + 0 * 4, &outRoute0);
        ReadRegister(ivars->pciDevice, ivars->barMemoryIndex,
                     kRegOutputRouting + 1 * 4, &outRoute1);
        ReadRegister(ivars->pciDevice, ivars->barMemoryIndex,
                     kRegOutputRouting + 31 * 4, &outRoute31);
        STLOG("Routing verify: OutRoute[0]=0x%03x (expect 0x%03x), [1]=0x%03x, [31]=0x%03x",
              outRoute0, (kTDM_PCIOut0 + 0) | kRoutingEnable,
              outRoute1, outRoute31);

        uint32_t inRoute0 = 0, inRoute31 = 0;
        ReadRegister(ivars->pciDevice, ivars->barMemoryIndex,
                     kRegInputRouting + 0 * 4, &inRoute0);
        ReadRegister(ivars->pciDevice, ivars->barMemoryIndex,
                     kRegInputRouting + 31 * 4, &inRoute31);
        STLOG("Routing verify: InRoute[0]=0x%03x (expect 0x%03x), [31]=0x%03x",
              inRoute0, (kTDM_XLinkRX0 + 0) | kRoutingEnable, inRoute31);

        uint32_t clkCtrl = 0, gcsr2 = 0;
        ReadRegister(ivars->pciDevice, ivars->barMemoryIndex,
                     kRegClkCtrl, &clkCtrl);
        ReadRegister(ivars->pciDevice, ivars->barMemoryIndex,
                     kRegGCSR2, &gcsr2);
        STLOG("Routing verify: ClkCtrl=0x%08x (unmute=%u,%u,%u), GCSR2=0x%08x (port1_disabled=%u)",
              clkCtrl,
              (clkCtrl & kClkCtrl_Unmute) ? 1 : 0,
              (clkCtrl & kClkCtrl_InputUnmute) ? 1 : 0,
              (clkCtrl & kClkCtrl_OutputUnmute) ? 1 : 0,
              gcsr2,
              (gcsr2 & kGCSR2_DisablePort1) ? 1 : 0);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // ── PT-06: DMA Buffer Allocation + FPGA Programming ─────────────────────
    // Legacy: SymphonyBaseCard::initIOBuffers() + Symphony64Card::cmdSetBuffers()
    // ══════════════════════════════════════════════════════════════════════════

    // ── 22. Allocate DMA buffers ────────────────────────────────────────
    // A2H (Audio-to-Host) = capture: FPGA writes audio data into host memory.
    // H2A (Host-to-Audio) = playback: Host writes audio data, FPGA reads it.
    // Buffer size: 8192 frames × 32 channels × 4 bytes = 1MB per direction.

    STLOG("DMA: Allocating buffers (%llu bytes each)...", kDMABufferSize);

    // Use kIOMemoryDirectionInOut for both buffers — CoreAudio HAL needs
    // read/write access to map them as stream ring buffers (zero-copy).
    // Apple AudioDriverKit samples use InOut for both directions.
    ret = AllocateDMABuffer(this, ivars->pciDevice, kDMABufferSize,
                            kIOMemoryDirectionInOut,
                            &ivars->a2hBuffer, &ivars->a2hDMA,
                            &ivars->a2hPhysAddr);
    if (ret != kIOReturnSuccess) {
        STERR("DMA: A2H buffer allocation failed: 0x%x", ret);
        // DMA setup is required for a published audio device; unwind the
        // partially initialized PCI/XLink state instead of registering a
        // degraded service.
        goto start_failure;
    }

    ret = AllocateDMABuffer(this, ivars->pciDevice, kDMABufferSize,
                            kIOMemoryDirectionInOut,
                            &ivars->h2aBuffer, &ivars->h2aDMA,
                            &ivars->h2aPhysAddr);
    if (ret != kIOReturnSuccess) {
        STERR("DMA: H2A buffer allocation failed: 0x%x", ret);
        goto start_failure;
    }

    // ── 23. Zero DMA buffers ────────────────────────────────────────────
    // Use IODMACommand::PerformOperation to zero the device-visible buffers.

    ivars->a2hDMA->PerformOperation(
        kIODMACommandPerformOperationOptionZero, 0, kDMABufferSize, 0, nullptr);
    ivars->h2aDMA->PerformOperation(
        kIODMACommandPerformOperationOptionZero, 0, kDMABufferSize, 0, nullptr);
    STLOG("DMA: Buffers zeroed");

    // ── 23a. Allocate SEPARATE stream buffers for CoreAudio ─────────────
    // After PrepareForDMA(), the DMA buffers are wired through IOMMU/DART for
    // PCIe device access. The CoreAudio HAL (coreaudiod) runs in a DIFFERENT
    // process and may not be able to map DMA-wired buffers. Using separate
    // non-DMA buffers for CoreAudio and copying in the IOOpHandler solves this.

    ret = IOBufferMemoryDescriptor::Create(
        kIOMemoryDirectionInOut, kDMABufferSize, 0, &ivars->a2hStreamBuffer);
    if (ret != kIOReturnSuccess || !ivars->a2hStreamBuffer) {
        STERR("DMA: A2H stream buffer alloc failed: 0x%x", ret);
        goto start_failure;
    }
    ivars->a2hStreamBuffer->SetLength(kDMABufferSize);

    ret = IOBufferMemoryDescriptor::Create(
        kIOMemoryDirectionInOut, kDMABufferSize, 0, &ivars->h2aStreamBuffer);
    if (ret != kIOReturnSuccess || !ivars->h2aStreamBuffer) {
        STERR("DMA: H2A stream buffer alloc failed: 0x%x", ret);
        goto start_failure;
    }
    ivars->h2aStreamBuffer->SetLength(kDMABufferSize);

    // Map DMA buffers for CPU access with CACHE-INHIBIT mode.
    // ARM64 Apple Silicon: CPU cache is NOT coherent with PCIe device reads/writes.
    // Default (write-back) cache mode causes memcpy data to sit in CPU cache while
    // the FPGA reads stale physical memory. Cache-inhibit forces every CPU write to
    // go directly to DRAM, ensuring the PCIe device sees fresh data immediately.
    // H2A (playback): CPU writes → device reads → inhibit ensures device sees writes
    // A2H (capture):  device writes → CPU reads → inhibit ensures CPU sees device writes
    ret = ivars->a2hBuffer->CreateMapping(
        kIOMemoryMapCacheModeInhibit, 0, 0, 0, 0, &ivars->a2hDMAMap);
    if (ret != kIOReturnSuccess) {
        STERR("DMA: A2H DMA buffer map failed: 0x%x", ret);
        goto start_failure;
    }
    ret = ivars->h2aBuffer->CreateMapping(
        kIOMemoryMapCacheModeInhibit, 0, 0, 0, 0, &ivars->h2aDMAMap);
    if (ret != kIOReturnSuccess) {
        STERR("DMA: H2A DMA buffer map failed: 0x%x", ret);
        goto start_failure;
    }

    // Stream buffers use default cache mode — only accessed by CPU (CoreAudio + IOOpHandler)
    ret = ivars->a2hStreamBuffer->CreateMapping(0, 0, 0, 0, 0, &ivars->a2hStreamMap);
    if (ret != kIOReturnSuccess) {
        STERR("DMA: A2H stream buffer map failed: 0x%x", ret);
        goto start_failure;
    }
    ret = ivars->h2aStreamBuffer->CreateMapping(0, 0, 0, 0, 0, &ivars->h2aStreamMap);
    if (ret != kIOReturnSuccess) {
        STERR("DMA: H2A stream buffer map failed: 0x%x", ret);
        goto start_failure;
    }

    STLOG("DMA: Stream buffers allocated, DMA buffers mapped CACHE-INHIBIT, stream buffers mapped default");

    // ── 24m. Meter DMA buffer (card FPGA continuously DMAs 256 meter words) ──
    // Allocate a 1 KB bus-master buffer (InOut, like A2H so CreateMapping + CPU reads
    // work), CPU-map it cache-inhibit, and program the meter timer + host base address.
    // Meter DMA is ENABLED later in the StartDMA rising-edge sequence (meterDMAActive).
    // Non-fatal: audio continues if any step fails.
    //
    // IMPORTANT: no FPGA-version gate on ThunderBridge. The legacy FPGA>=20 metering
    // disable (Symphony64Card.cpp:165) is wrapped in `#ifndef THUNDERBRIDGE` — it applies
    // ONLY to the old Symphony64 PCIe card. On ThunderBridge m_fRunMeterDMA stays TRUE at
    // any FPGA version, so meter DMA runs unconditionally here (this dev unit is FPGA v17).
    ivars->meterDMAActive = false;
    ivars->meterWords = nullptr;
    // TEMPORARILY DISABLED (2026-07-15) — meter DMA corrupts the audio clock.
    // The card FPGA meter DMA is TIMER-triggered (~64 Hz, kMeterTimerValue=12800) and
    // raises the SHARED FPGA interrupt. InterruptOccurred() treats EVERY interrupt as an
    // audio A2H buffer wrap: it advances zeroTimestampSampleTime by count*kNumSampleFrames
    // (8192) and clears all IntStatus bits, with NO way to tell a meter IRQ from an audio
    // wrap. With metering on, ~64 meter IRQs/sec each add 8192 frames to the reported clock,
    // so CoreAudio derives ~64*8192 ≈ 527 kHz (~11x real 48 kHz). Logic rejects that
    // ("Sample Rate 5xx,xxx recognized — check conflict") and the meter buffer reads
    // full-scale garbage. Light CoreAudio clients (Spotify/browser) tolerated it; Logic
    // hard-validates the clock, so ADAT/Logic broke the moment metering shipped (v48).
    // Re-enable ONLY after InterruptOccurred distinguishes meter IRQs from audio wraps
    // (read IntStatus, advance the audio clock only on the A2H-wrap bit), or the meter
    // trigger is changed to not raise the audio IRQ. See Docs/thunderbolt-learnings.md.
    static constexpr bool kMeterDMAEnabled = true;
    if (kMeterDMAEnabled && (!ivars->isLegacyPCIe2100 || ivars->fpgaVersion >= 20)) {
        kern_return_t mret = AllocateDMABuffer(this, ivars->pciDevice, kMeterBufferBytes,
                                               kIOMemoryDirectionInOut,
                                               &ivars->meterBuffer, &ivars->meterDMA,
                                               &ivars->meterPhysAddr);
        if (mret == kIOReturnSuccess) {
            ivars->meterDMA->PerformOperation(
                kIODMACommandPerformOperationOptionZero, 0, kMeterBufferBytes, 0, nullptr);
            mret = ivars->meterBuffer->CreateMapping(
                kIOMemoryMapCacheModeInhibit, 0, 0, 0, 0, &ivars->meterMap);
            if (mret == kIOReturnSuccess) {
                ivars->meterWords = (uint32_t *)ivars->meterMap->GetAddress();
                WriteRegister(ivars->pciDevice, ivars->barMemoryIndex,
                              kRegMeterTimer, kMeterTimerValue);
                WriteRegister(ivars->pciDevice, ivars->barMemoryIndex,
                              kRegMeterHBA, (uint32_t)ivars->meterPhysAddr);
                ivars->meterDMAActive = true;
                STLOG("Meter DMA: buffer io=0x%llx timer=%u mapped — ready (FPGA v%u)",
                      ivars->meterPhysAddr, (uint32_t)kMeterTimerValue, ivars->fpgaVersion);
            } else {
                STERR("Meter DMA: CreateMapping failed 0x%x — metering off", mret);
            }
        } else {
            STERR("Meter DMA: buffer alloc failed 0x%x — metering off", mret);
        }
    }

    // ── 24. Program FPGA DMA registers ──────────────────────────────────
    // Legacy: Symphony64Card::cmdSetBuffers() (Symphony64Card.cpp:1358-1410)
    // Buffer size is in 32-bit WORDS (not bytes): bufBytes / 4
    // Base addresses are device-visible physical addresses from IODMACommand.

    {
        uint32_t bufSizeWords = (uint32_t)(kDMABufferSize / (kAudioBitDepth / 8));
        STLOG("DMA: Programming FPGA registers: bufSize=%u words, A2H_HBA=0x%08x, H2A_HBA=0x%08x",
              bufSizeWords, (uint32_t)ivars->a2hPhysAddr, (uint32_t)ivars->h2aPhysAddr);

        // Port 1 buffer sizes
        WriteRegister(ivars->pciDevice, ivars->barMemoryIndex,
                      kRegA2HBUFSIZE, bufSizeWords);
        WriteRegister(ivars->pciDevice, ivars->barMemoryIndex,
                      kRegH2ABUFSIZE, bufSizeWords);

        // Port 1 base addresses (32-bit — FPGA is 32-bit DMA)
        WriteRegister(ivars->pciDevice, ivars->barMemoryIndex,
                      kRegA2HHBA, (uint32_t)ivars->a2hPhysAddr);
        WriteRegister(ivars->pciDevice, ivars->barMemoryIndex,
                      kRegH2AHBA, (uint32_t)ivars->h2aPhysAddr);

        // Port 2 — disabled (no second port in use)
        WriteRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegA2H2BUFSIZE, 0);
        WriteRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegH2A2BUFSIZE, 0);
        WriteRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegA2H2HBA, 0);
        WriteRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegH2A2HBA, 0);

        // Verify readback
        uint32_t verifyA2H = 0, verifyH2A = 0, verifyBufSz = 0;
        ReadRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegA2HHBA, &verifyA2H);
        ReadRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegH2AHBA, &verifyH2A);
        ReadRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegH2ABUFSIZE, &verifyBufSz);
        STLOG("DMA: Verify: A2H_HBA=0x%08x, H2A_HBA=0x%08x, BufSize=%u",
              verifyA2H, verifyH2A, verifyBufSz);

        if (verifyA2H != (uint32_t)ivars->a2hPhysAddr ||
            verifyH2A != (uint32_t)ivars->h2aPhysAddr) {
            STERR("DMA: Register readback mismatch!");
        }
    }

    // ── 25. Set DMA channel count (GCSR + GCSR2) ────────────────────────
    // Legacy: setNumDMAChannels() writes to BOTH registers:
    //   Port 1 → GCSR bits[5:0],  Port 2 → GCSR2 bits[5:0]
    // ThunderBridge uses Port 1, so GCSR is the critical one.

    ModifyRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegGCSR,
                   kGCSR_DMAOutSize32 | kGCSR_DMAInSize32,
                   kGCSR_DMAMask);
    ModifyRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegGCSR2,
                   kGCSR2_DMAOutSize32 | kGCSR2_DMAInSize32,
                   kGCSR2_DMAMask);
    // Readback diagnostic — check if GCSR DMA bits stick
    {
        uint32_t gcsrCheck = 0;
        ReadRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegGCSR, &gcsrCheck);
        STLOG("DMA: Channel count set to 32 in/out (GCSR=0x%08x, bits[5:0]=0x%02x%s)",
              gcsrCheck, gcsrCheck & 0x3F,
              (gcsrCheck & 0x3F) == 0x1B ? " OK" : " *** MISSING — bits may be write-only ***");
    }

    // ── 26. Set FPGA frame size ─────────────────────────────────────────
    // Legacy: StartDMA() — ModifyRegister(SM_REG_CLKCTRL, frame<<SHIFT, MASK)
    // Select the legacy Standard or High Performance frame size for the
    // initial 44.1 kHz clock.  High Performance is the historical default for
    // Symphony 64/ThunderBridge and uses a 4-sample FPGA frame at 44.1/48 kHz.
    ModifyRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegClkCtrl,
                   ((initialFrameSize - 1) << kClkCtrl_FrameShift) & kClkCtrl_FrameMask,
                   kClkCtrl_FrameMask);
    STLOG("DMA: Frame size set to %u samples (%s profile)", initialFrameSize,
          kUseHighPerformanceProfile ? "High Performance" : "Standard");

    // Do not publish the initial 44.1 kHz timing tuple against an FPGA period
    // that the hardware rejected or clamped. The rate-change path performs the
    // same check later; startup must fail closed as well or Core Audio can cache
    // a false 4-frame high-performance latency profile.
    {
        uint32_t clkCtrlReadback = 0;
        ReadRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegClkCtrl,
                     &clkCtrlReadback);
        const uint32_t frameReadback =
            ((clkCtrlReadback & kClkCtrl_FrameMask) >> kClkCtrl_FrameShift) + 1;
        STLOG("DMA: Initial FPGA ClkCtrl readback=0x%08x frame=%u expected=%u",
              clkCtrlReadback, frameReadback, initialFrameSize);
        if (frameReadback != initialFrameSize) {
            STERR("DMA: Initial FPGA frame readback mismatch (got=%u expected=%u) — "
                  "refusing startup timing publication", frameReadback, initialFrameSize);
            ret = kIOReturnError;
            goto start_failure;
        }
    }

    // ── 27. Set up interrupt handler ────────────────────────────────────
    // Legacy: SymphonyBaseAudioEngine::initInterrupts() + EnableInterruptsInHardware()
    // DriverKit: IOInterruptDispatchSource delivers MSI interrupts to a queue handler.

    {
        // Create dispatch queue for interrupt handler
        ret = IODispatchQueue::Create("com.danielraffel.thunderbridge.irq",
                                       0, 0, &ivars->interruptQueue);
        if (ret != kIOReturnSuccess) {
            STERR("DMA: IODispatchQueue::Create failed: 0x%x", ret);
            goto start_failure;
        }

        // Create the serial XLink TX queue (C2/H1). All runtime vendor writes
        // and rate-change SetSampleRate commands are dispatched here so they
        // never run on the IRQ queue and never interleave with each other.
        ret = IODispatchQueue::Create("com.danielraffel.thunderbridge.xlink",
                                       0, 0, &ivars->xlinkQueue);
        if (ret != kIOReturnSuccess) {
            STERR("DMA: XLink IODispatchQueue::Create failed: 0x%x", ret);
            goto start_failure;
        }

        // dext 113: the link watch timer lives on the serial XLink queue so its
        // ticks serialize with vendor traffic, the rate transaction and recovery.
        ret = IOTimerDispatchSource::Create(ivars->xlinkQueue, &ivars->linkWatchTimer);
        if (ret != kIOReturnSuccess) {
            STERR("Link watch: IOTimerDispatchSource::Create failed: 0x%x", ret);
            goto start_failure;
        }
        {
            OSAction *watchAction = nullptr;
            ret = CreateActionLinkWatchTimerOccurred(0, &watchAction);
            if (ret != kIOReturnSuccess || !watchAction) {
                STERR("Link watch: CreateActionLinkWatchTimerOccurred failed: 0x%x", ret);
                goto start_failure;
            }
            ret = ivars->linkWatchTimer->SetHandler(watchAction);
            OSSafeReleaseNULL(watchAction);
            if (ret != kIOReturnSuccess) {
                STERR("Link watch: SetHandler failed: 0x%x", ret);
                goto start_failure;
            }
        }
        ret = CopyDispatchQueue(kIOServiceDefaultQueueName, &ivars->defaultQueue);
        if (ret != kIOReturnSuccess || !ivars->defaultQueue) {
            STERR("Link watch: CopyDispatchQueue(Default) failed: 0x%x", ret);
            goto start_failure;
        }

        // Create interrupt dispatch source on MSI index 0
        ret = IOInterruptDispatchSource::Create(
            ivars->pciDevice, 0, ivars->interruptQueue,
            &ivars->interruptSource);
        if (ret != kIOReturnSuccess) {
            STERR("DMA: IOInterruptDispatchSource::Create failed: 0x%x (MSI not available?)", ret);
            goto start_failure;
        }

        // Create OSAction for the InterruptOccurred callback
        OSAction *irqAction = nullptr;
        ret = CreateActionInterruptOccurred(0, &irqAction);
        if (ret != kIOReturnSuccess || !irqAction) {
            STERR("DMA: CreateActionInterruptOccurred failed: 0x%x", ret);
            goto start_failure;
        }

        ret = ivars->interruptSource->SetHandler(irqAction);
        OSSafeReleaseNULL(irqAction);
        if (ret != kIOReturnSuccess) {
            STERR("DMA: SetHandler failed: 0x%x", ret);
            goto start_failure;
        }

        // Enable the interrupt source
        ret = ivars->interruptSource->SetEnableWithCompletion(true, nullptr);
        if (ret != kIOReturnSuccess) {
            STERR("DMA: SetEnableWithCompletion(true) failed: 0x%x", ret);
            goto start_failure;
        }

        STLOG("DMA: Interrupt handler installed (MSI index 0)");
    }

    // ── 28. Enable FPGA interrupt mask ──────────────────────────────────
    // Legacy: EnableInterruptsInHardware(true) — only enables A2H wrap (port 1)
    // Clear all status first, then set mask.

    WriteRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegIntStatus, 0xFFFFFFFF);
    WriteRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegIntMask, 0);
    WriteRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegIntMask, kInt_A2HWrap);
    STLOG("DMA: Interrupt mask set to A2H wrap (0x%08x)", kInt_A2HWrap);

    // ── 29. Start DMA ───────────────────────────────────────────────────
    // Legacy: Symphony64Card::StartDMA(fInput=true, fOutput=true, fMeters=false)
    // Sequence: clear enable bits (rising edge required), set trigger-select,
    //           write GCSR, then set enable bits, write GCSR again.

    {
        uint32_t gcsr = 0;
        ReadRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegGCSR, &gcsr);

        // Re-assert DMA channel count — GCSR bits[5:0] may be write-only
        // (read back as 0), so every GCSR write must include them.
        gcsr = (gcsr & ~kGCSR_DMAMask) | (kGCSR_DMAOutSize32 | kGCSR_DMAInSize32);

        // This is the only master DMA (no slave cards)
        gcsr |= kGCSR_OnlyMasterDMA;
        WriteRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegGCSR, gcsr);

        // Step 1: Clear all DMA enable + trigger-select bits (force rising edge)
        gcsr &= ~(kGCSR_A2HDMAEnable | kGCSR_H2ADMAEnable |
                   kGCSR_A2HTrigSelect | kGCSR_H2ATrigSelect |
                   kGCSR_MeterDMAEnable | kGCSR_MeterTrigSelect);
        WriteRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegGCSR, gcsr);

        // Step 2: Set trigger-select bits (A2H + H2A + meters if active)
        gcsr |= kGCSR_A2HTrigSelect;  // A2H (capture) trigger select
        gcsr &= ~kGCSR_A2HDMAEnable;  // Keep enable off for now
        gcsr |= kGCSR_H2ATrigSelect;  // H2A (playback) trigger select
        gcsr &= ~kGCSR_H2ADMAEnable;  // Keep enable off for now
        if (ivars->meterDMAActive)    // meter DMA = timer-triggered (legacy fMeters=true)
            gcsr |= kGCSR_MeterTrigSelect;
        WriteRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegGCSR, gcsr);

        // Step 3: Set DMA enable bits (triggers DMA start on rising edge)
        gcsr |= kGCSR_A2HDMAEnable;
        gcsr |= kGCSR_H2ADMAEnable;
        if (ivars->meterDMAActive)
            gcsr |= kGCSR_MeterDMAEnable;
        WriteRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegGCSR, gcsr);

        ivars->dmaRunning = true;
        STLOG("DMA: Started (A2H + H2A%s). GCSR=0x%08x",
              ivars->meterDMAActive ? " + Meters" : "", gcsr);
    }

    // ── 30. Verify DMA is running ───────────────────────────────────────
    // Read CHA (current host address) registers. If DMA is running, CHA
    // should advance from the HBA (base address).

    IOSleep(100);  // Give DMA a few frames to run
    {
        uint32_t a2hCHA = 0, h2aCHA = 0;
        ReadRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegA2HCHA, &a2hCHA);
        ReadRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegH2ACHA, &h2aCHA);

        uint32_t a2hOffset = a2hCHA - (uint32_t)ivars->a2hPhysAddr;
        uint32_t h2aOffset = h2aCHA - (uint32_t)ivars->h2aPhysAddr;

        STLOG("DMA verify: A2H_CHA=0x%08x (offset=%u), H2A_CHA=0x%08x (offset=%u)",
              a2hCHA, a2hOffset, h2aCHA, h2aOffset);

        if (a2hCHA == (uint32_t)ivars->a2hPhysAddr && h2aCHA == (uint32_t)ivars->h2aPhysAddr) {
            STLOG("DMA: CHA not advancing — DMA may not be running (check GCSR bits)");
        } else {
            STLOG("DMA: CHA advancing — DMA is RUNNING!");
        }

        // Read interrupt status to see if any DMA events fired
        uint32_t intStatus = 0;
        ReadRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegIntStatus, &intStatus);
        STLOG("DMA: IntStatus=0x%08x (A2HWrap=%u H2AWrap=%u Overflow=%u Underflow=%u)",
              intStatus,
              (intStatus & kInt_A2HWrap) ? 1 : 0,
              (intStatus & kInt_H2AWrap) ? 1 : 0,
              (intStatus & kInt_HostBufOverflow) ? 1 : 0,
              (intStatus & kInt_AudioBufUnderflow) ? 1 : 0);
    }

    // ── 30b. Unmute AFTER DMA is running ────────────────────────────────
    // Legacy: performAudioEngineStart() unmutes AFTER StartDMA() + delay.
    // Sequence: start DMA → wait for buffers to fill → unmute.
    // Without DMA running, unmuting can cause the FPGA to output stale/garbage
    // data to the XLink bus, confusing the Symphony IO.

    IOSleep(10);  // Legacy: IOSleep(10) between StartDMA and unmute
    ModifyRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegClkCtrl,
                   kClkCtrl_Unmute | kClkCtrl_InputUnmute | kClkCtrl_OutputUnmute,
                   0);
    STLOG("ClkCtrl: unmuted AFTER DMA start (global + input + output = 0x70000000)");

    // Verify ClkCtrl readback
    {
        uint32_t clkVerify = 0;
        ReadRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegClkCtrl, &clkVerify);
        STLOG("ClkCtrl verify: 0x%08x (unmute=%u, inUnmute=%u, outUnmute=%u)",
              clkVerify,
              (clkVerify & kClkCtrl_Unmute) ? 1 : 0,
              (clkVerify & kClkCtrl_InputUnmute) ? 1 : 0,
              (clkVerify & kClkCtrl_OutputUnmute) ? 1 : 0);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // ── PT-07: AudioDriverKit Integration ────────────────────────────────────
    // Create IOUserAudioDevice with 32ch input/output streams backed by the
    // DMA buffers. This publishes the hardware as a CoreAudio device.
    // Zero-copy: stream ring buffers ARE the DMA buffers.
    // ══════════════════════════════════════════════════════════════════════════

    // ── 31. Create IOUserAudioDevice ─────────────────────────────────────

    {
        // Build unique device UID from serial number
        char uidStr[128];
        snprintf(uidStr, sizeof(uidStr), "SymphonyThunderbridge-%016llx",
                 ivars->serialNumber);
        OSString *deviceUID = OSString::withCString(uidStr);
        OSString *modelUID  = OSString::withCString("SymphonyIO-MKI");
        OSString *mfrUID    = OSString::withCString("Apogee");

        if (!deviceUID || !modelUID || !mfrUID) {
            STERR("Audio: Failed to create UID strings");
            OSSafeReleaseNULL(deviceUID);
            OSSafeReleaseNULL(modelUID);
            OSSafeReleaseNULL(mfrUID);
            goto start_failure;
        }

        auto *customDevice = OSTypeAlloc(SymphonyAudioDevice);
        if (!customDevice || !customDevice->init(
                this,                   // IOUserAudioDriver
                false,                  // no prewarming support
                deviceUID,
                modelUID,
                mfrUID,
                kNumSampleFrames)) {   // zero timestamp period = 8192 frames
            OSSafeReleaseNULL(customDevice);
            customDevice = nullptr;
        }
        OSSharedPtr<IOUserAudioDevice> device(customDevice, OSNoRetain);

        OSSafeReleaseNULL(deviceUID);
        OSSafeReleaseNULL(modelUID);
        OSSafeReleaseNULL(mfrUID);

        if (!device) {
            STERR("Audio: SymphonyAudioDevice::init failed");
            goto start_failure;
        }

        // Retain raw pointer for IVars (OSSharedPtr will release the Create reference)
        ivars->audioDevice = device.get();
        ivars->audioDevice->retain();

        STLOG("Audio: Device created (UID=%s, ZTS period=%u)", uidStr, kNumSampleFrames);
    }

    // ── 32. Configure device properties ──────────────────────────────────

    {
        // Sample rates — all 6 standard rates supported at 32 channels.
        // Legacy driver (Symphony64Card) uses 32ch DMA at ALL rates (no channel reduction).
        // XLink bus carries 32ch at all tiers — channel reduction only applies to
        // I/O peripherals (ADAT/optical), not the PCIe DMA transport.
        double sampleRates[] = { 44100.0, 48000.0, 88200.0, 96000.0, 176400.0, 192000.0 };
        ivars->audioDevice->SetAvailableSampleRates(sampleRates, 6);
        ivars->audioDevice->SetSampleRate(44100.0);
        ivars->lastSampleRate = 44100.0;
        ivars->xlinkRate      = 44100.0;   // hardware boots configured at 44.1k

        // Transport type
        ivars->audioDevice->SetTransportType(
            IOUserAudioTransportType::Thunderbolt);

        // Device capabilities
        ivars->audioDevice->SetCanBeDefaultInputDevice(true);
        ivars->audioDevice->SetCanBeDefaultOutputDevice(true);
        ivars->audioDevice->SetCanBeDefaultSystemOutputDevice(true);

        // Safety offsets and reported hardware latency follow the legacy
        // performance tables.  These are intentionally separate: High
        // Performance uses a 4-frame FPGA period but a 10-frame safety offset
        // at 44.1/48 kHz.
        // Device timing — publish one complete profile tuple, rather than
        // allowing frame and safety values to drift independently.
        const kern_return_t timingResult =
            ApplyAudioTimingProfile(ivars->audioDevice, 44100.0);
        if (timingResult != kIOReturnSuccess) {
            // Do not publish an audio device with a partially applied timing
            // tuple.  The first rate publication is just as important as a
            // later rate change: Core Audio would otherwise cache whichever
            // safety or latency setter happened to succeed.
            STERR("Audio: initial timing profile publication failed: 0x%x — "
                  "leaving audio device unpublished", timingResult);
            // Start() failures do not invoke the normal framework Stop path.
            // Explicitly enter our teardown path before returning so DMA,
            // interrupts, queues, and the PCI session cannot remain active.
            const kern_return_t stopResult = Stop(provider);
            if (stopResult != kIOReturnSuccess) {
                STERR("Audio: initial timing failure teardown returned 0x%x", stopResult);
            }
            return timingResult;
        }

        // Preferred stereo pair (channels 1-2)
        ivars->audioDevice->SetPreferredChannelsForStereo(1, 2);

        STLOG("Audio: Device configured (44.1-192kHz, Thunderbolt, 32ch, %s profile)",
              kUseHighPerformanceProfile ? "High Performance" : "Standard");
    }

    // ── 33. Create stream format descriptor ──────────────────────────────
    // 32-channel interleaved SInt32, matching the FPGA DMA format.
    // Legacy: SymphonyDrivers.h:129-138 — SInt32, packed, LE.
    // The FPGA does SInt32 DMA with AHND/HAND byte-swap to LE (no float conversion).
    // CoreAudio handles Float32↔SInt32 conversion internally (like clipOutputSamples).
    // Evidence: Audio MIDI Setup on Intel Mac shows "32ch-32bit Integer".
    // Flags: kAudioFormatFlagIsSignedInteger(0x4) | kAudioFormatFlagIsPacked(0x8) = 0xC

    {
        IOUserAudioStreamBasicDescription baseFormat = {};
        baseFormat.mSampleRate      = 44100.0;
        baseFormat.mFormatID        = IOUserAudioFormatID::LinearPCM;
        baseFormat.mFormatFlags     = (IOUserAudioFormatFlags)(0x4 | 0x8);  // SInt32 packed LE
        baseFormat.mBytesPerPacket  = kMaxChannelsPerPort * (kAudioBitDepth / 8);  // 128
        baseFormat.mFramesPerPacket = 1;
        baseFormat.mBytesPerFrame   = kMaxChannelsPerPort * (kAudioBitDepth / 8);  // 128
        baseFormat.mChannelsPerFrame = kMaxChannelsPerPort;                         // 32
        baseFormat.mBitsPerChannel  = kAudioBitDepth;                              // 32
        baseFormat.mReserved        = 0;

        // One format descriptor per supported rate — same 32ch SInt32 layout, different rate.
        IOUserAudioStreamBasicDescription formats[6];
        double rates[] = { 44100.0, 48000.0, 88200.0, 96000.0, 176400.0, 192000.0 };
        for (int i = 0; i < 6; i++) {
            formats[i] = baseFormat;
            formats[i].mSampleRate = rates[i];
        }

        // ── 34. Create input stream (capture: A2H) ──────────────────────
        // Uses SEPARATE stream buffer — CoreAudio maps this, IOOpHandler copies DMA→stream.
        // (DMA-wired buffers may not be mappable by coreaudiod process.)

        auto inStream = IOUserAudioStream::Create(
            this,
            IOUserAudioStreamDirection::Input,
            ivars->a2hStreamBuffer);  // Separate buffer CoreAudio can map

        if (!inStream) {
            STERR("Audio: Failed to create input stream");
            goto start_failure;
        }

        ivars->inputStream = inStream.get();
        ivars->inputStream->retain();

        ivars->inputStream->SetAvailableStreamFormats(formats, 6);
        ivars->inputStream->SetCurrentStreamFormat(&formats[0]);
        ivars->inputStream->SetTerminalType(
            IOUserAudioStreamTerminalType::Line);
        ivars->inputStream->SetStartingChannel(1);

        STLOG("Audio: Input stream created (32ch SInt32, 6 formats 44.1-192kHz, stream buffer)");

        // ── 35. Create output stream (playback: H2A) ────────────────────
        // Uses SEPARATE stream buffer — CoreAudio maps this, IOOpHandler copies stream→DMA.

        auto outStream = IOUserAudioStream::Create(
            this,
            IOUserAudioStreamDirection::Output,
            ivars->h2aStreamBuffer);  // Separate buffer CoreAudio can map

        if (!outStream) {
            STERR("Audio: Failed to create output stream");
            goto start_failure;
        }

        ivars->outputStream = outStream.get();
        ivars->outputStream->retain();

        ivars->outputStream->SetAvailableStreamFormats(formats, 6);
        ivars->outputStream->SetCurrentStreamFormat(&formats[0]);
        ivars->outputStream->SetTerminalType(
            IOUserAudioStreamTerminalType::Line);
        ivars->outputStream->SetStartingChannel(1);

        STLOG("Audio: Output stream created (32ch SInt32, 6 formats 44.1-192kHz, stream buffer)");

        // ── 36. Add streams to device ────────────────────────────────────

        ret = ivars->audioDevice->AddStream(ivars->inputStream);
        if (ret != kIOReturnSuccess) {
            STERR("Audio: AddStream(input) failed: 0x%x", ret);
            goto start_failure;
        }

        ret = ivars->audioDevice->AddStream(ivars->outputStream);
        if (ret != kIOReturnSuccess) {
            STERR("Audio: AddStream(output) failed: 0x%x", ret);
            goto start_failure;
        }

        STLOG("Audio: Streams added to device");

        // ── 36b. Add volume and mute controls ────────────────────────────
        // Enables macOS volume HUD (volume keys + slider). Without these,
        // the volume slider is greyed out and the device is full-blast only.
        // Range: -64 to 0 dB (matching Symphony IO hardware: 0-64 dB atten).
        // Volume changes sent to hardware via SpeakerVolume XLink command.

        {
            IOUserAudioLevelControlRange dbRange = { -64.0f, 0.0f };
            const float initialMonitorDb = -static_cast<float>(initialMonitorAttenuation);
            auto volumeCtrl = IOUserAudioLevelControl::Create(
                this, true, initialMonitorDb, dbRange,
                IOUserAudioObjectPropertyElementMain,
                IOUserAudioObjectPropertyScope::Output,
                IOUserAudioClassID::VolumeControl);

            if (volumeCtrl) {
                ivars->outputVolumeControl = volumeCtrl.get();
                ivars->outputVolumeControl->retain();
                ret = ivars->audioDevice->AddControl(ivars->outputVolumeControl);
                if (ret != kIOReturnSuccess) {
                    STERR("Audio: AddControl(volume) failed: 0x%x", ret);
                } else {
                    STLOG("Audio: Output volume control added (-64..0 dB, init=%.1f, target=%s)",
                          initialMonitorDb, initialLineMonitor ? "HP1" : "speakers");
                }
            } else {
                STERR("Audio: IOUserAudioLevelControl::Create failed");
            }

            auto muteCtrl = IOUserAudioBooleanControl::Create(
                this, true, initialMonitorMute,
                IOUserAudioObjectPropertyElementMain,
                IOUserAudioObjectPropertyScope::Output,
                IOUserAudioClassID::MuteControl);

            if (muteCtrl) {
                ivars->outputMuteControl = muteCtrl.get();
                ivars->outputMuteControl->retain();
                ret = ivars->audioDevice->AddControl(ivars->outputMuteControl);
                if (ret != kIOReturnSuccess) {
                    STERR("Audio: AddControl(mute) failed: 0x%x", ret);
                } else {
                    STLOG("Audio: Output mute control added");
                }
            } else {
                STERR("Audio: IOUserAudioBooleanControl::Create failed");
            }

            ivars->lastVolumeDb = initialMonitorDb;
            ivars->lastMuteState = initialMonitorMute;
            // Preserve the restored mode selected above.  Resetting this to speakers
            // here makes a persisted Line mode send subsequent Core Audio volume/mute
            // changes to the wrong hardware target after reconnect.
            ivars->monitorOutputTarget = initialLineMonitor ? 1 : 0;
            ivars->speakerAttenuation = initialSpeakerAttenuation;
            ivars->speakerMute = initialSpeakerMute;
            ivars->hp1Attenuation = initialHP1Attenuation;
            ivars->hp1Mute = initialHP1Mute;
            ivars->runtimeTxSeq = 0;
            ivars->symphonyAddr = 1;  // First Symphony IO on XLink bus (assigned during enum)
            for (int mixer = 0; mixer < 2; mixer++) {
                auto &state = ivars->mixer[mixer];
                state.swReturnLeftByte = 48;   // 0 dB (unity)
                state.swReturnRightByte = 48;
                state.masterLeftByte = 48;     // 0 dB
                state.masterRightByte = 48;
                state.swReturnPanByte = 64;    // center
                state.swReturnMuted = false;
                state.masterMuted = false;
                state.swReturnSoloed = false;
                ivars->mixerSwReturnSource[mixer] = 0;
                for (int c = 0; c < 32; c++) {
                    state.inputByte[c] = 48;      // 0 dB when unmuted
                    state.inputPanByte[c] = 64;   // center
                    state.inputMuted[c] = true;   // inputs start muted
                    state.inputSoloed[c] = false;
                }
            }
        }

        // ── 36c. Clock source selector control ('clck') ──────────────────
        // Entitlement-free: coreaudiod reads/writes this through the normal audio-HAL
        // property path (the SAME channel that already drives volume/mute with SIP on
        // and NO IOUserClient) — so it is unaffected by the userclient-access block.
        // Five legacy sources: SymphonyIOClockSource (SymphonyIOVendorSpecific.h:857-865)
        //   Internal=1, WordClock=2, LoopSync=3, IOBoard1=4, IOBoard2=5.
        // We instantiate the SymphonyClockSelectorControl subclass (NOT the stock
        // Create()) so its HandleChangeSelectedValues override PUSHES the user's
        // selection into RequestClockSource(), which sends ClockMode (0x50) on the
        // serial xlinkQueue. A stock selector can't be observed via polling.
        {
            SymphonyClockSelectorControl* clockCtrl =
                OSTypeAlloc(SymphonyClockSelectorControl);   // +1
            if (clockCtrl && clockCtrl->init(
                    this, true,
                    IOUserAudioObjectPropertyElementMain,
                    // GLOBAL scope: clock source is a device-wide property. Audio MIDI
                    // Setup's "Clock Source" header queries kAudioDevicePropertyClockSource
                    // on the GLOBAL scope, so a control on Output scope shows only static
                    // "Internal" with no selector (confirmed on hardware, v32). Global
                    // surfaces the 5-value dropdown.
                    IOUserAudioObjectPropertyScope::Global,
                    IOUserAudioClassID::ClockSourceControl)) {
                IOUserAudioSelectorValueDescription clockValues[5] = {
                    { 1, OSSharedPtr<OSString>(OSString::withCString("Internal"),    OSNoRetain) },
                    { 2, OSSharedPtr<OSString>(OSString::withCString("Word Clock"),  OSNoRetain) },
                    { 3, OSSharedPtr<OSString>(OSString::withCString("Loop Sync"),   OSNoRetain) },
                    { 4, OSSharedPtr<OSString>(OSString::withCString("I/O Board 1"), OSNoRetain) },
                    { 5, OSSharedPtr<OSString>(OSString::withCString("I/O Board 2"), OSNoRetain) },
                };
                clockCtrl->AddControlValueDescriptions(clockValues, 5);
                IOUserAudioSelectorValue initSel = 1;  // Internal — matches boot ClockMode
                clockCtrl->SetCurrentSelectedValues(&initSel, 1);
                clockCtrl->SetDriver(this);  // back-pointer for the push callback

                ret = ivars->audioDevice->AddControl(clockCtrl);  // framework retains
                if (ret != kIOReturnSuccess) {
                    STERR("Audio: AddControl(clock source) failed: 0x%x", ret);
                } else {
                    ivars->clockSourceControl = clockCtrl;
                    ivars->clockSourceControl->retain();  // our tracked ref (balanced in teardown)
                    STLOG("Audio: Clock source selector added (Internal/WordClock/LoopSync/IOBoard1/2)");
                }
            } else {
                STERR("Audio: SymphonyClockSelectorControl alloc/init failed");
            }
            OSSafeReleaseNULL(clockCtrl);  // drop the OSTypeAlloc +1; ivar ref keeps it alive
        }

        // ── 36c-2. Optical output format ('dsrc') — per fitted OPTICAL board ─────
        // DataSourceControl selector, Output scope, element = board+1 (the
        // legacy per-port 'AEof' layout: Port1=elem1/Port2=elem2 —
        // APAudioManagedObject.m:1596-1604). Entitlement-free: coreaudiod drives it
        // over the SAME audio-HAL property path as volume/mute/clock (no
        // IOUserClient), so it is unaffected by the userclient-access block. Two
        // formats: 0=ADAT/SMUX (boot default, :1477), 1=S/PDIF.
        //
        // WHY DataSource, not DataDestination: AudioDataDestinationControl is, per
        // Apple's AudioHardware.h (kAudioDevicePropertyPlayThruDestination), "only
        // available through kAudioDevicePropertyScopePlayThrough" — it would NOT
        // surface as a queryable property on the Output scope, so the app could never
        // drive it. DataSourceControl maps to kAudioDevicePropertyDataSource, which is
        // per-scope/per-element (valid on Output) and is the popup Audio MIDI Setup
        // actually renders — exactly how ClockSourceControl→kAudioDevicePropertyClockSource
        // already works here.
        //
        // Board-gated (never-guess): read OptionBoardType (0xA1) for board 0 AND
        // board 1 and publish a control ONLY for a board that POSITIVELY reads
        // an optical-capable board type. On None/other/read-failure → publish nothing for that
        // board (fail-safe, same discipline as numMicChannels). The boot path
        // (:1471-1488) blindly 0x34's both slots because that's harmless on an
        // empty slot, but a CONTROL must reflect real hardware. Runs on the XLink
        // init path, so ReadVendorRequest's bounded IOSleep polling is safe here.
        ivars->numOpticalBoards = 0;
        for (uint32_t b = 0; b < 2; b++) {
            uint8_t bt = kSIOOptionBoard_None;
            bool ok = ReadVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                        ivars->symphonyAddr, kSIOCmd_OptionBoardType,
                                        /*nValue=board*/ b, &bt, /*wLength*/1,
                                        ivars->runtimeTxSeq);
            ivars->optionBoardType[b]      = ok ? bt : 0;
            ivars->optionBoardTypeValid[b]  = ok;
            if (!ok || !BoardHasOpticalFormat(bt)) {
                STLOG("SymphonyIO: OptionBoardType(board%u)=%u → no optical control",
                      b, ok ? bt : 0);
                continue;
            }
            SymphonyOpticalControl* oc = OSTypeAlloc(SymphonyOpticalControl);   // +1
            if (oc && oc->init(this, /*settable*/true,
                    (IOUserAudioObjectPropertyElement)(b + 1),   // element 1/2
                    IOUserAudioObjectPropertyScope::Output,
                    IOUserAudioClassID::DataSourceControl)) {   // 'dsrc'
                IOUserAudioSelectorValueDescription opticalValues[2] = {
                    { 0, OSSharedPtr<OSString>(OSString::withCString("ADAT/SMUX"), OSNoRetain) },
                    { 1, OSSharedPtr<OSString>(OSString::withCString("S/PDIF"),    OSNoRetain) },
                };
                oc->AddControlValueDescriptions(opticalValues, 2);
                IOUserAudioSelectorValue initSel = 0;   // ADAT/SMUX — matches boot (:1477)
                oc->SetCurrentSelectedValues(&initSel, 1);
                oc->SetBoard(b);         // 0-based wire board index (nValue)
                oc->SetDriver(this);     // back-pointer for the push callback
                ret = ivars->audioDevice->AddControl(oc);   // framework retains
                if (ret == kIOReturnSuccess) {
                    ivars->opticalControl[b] = oc;
                    ivars->opticalControl[b]->retain();     // tracked ref (balanced in teardown)
                    ivars->numOpticalBoards++;
                    STLOG("Audio: Optical format selector added (board%u, element %u)", b, b + 1);
                } else {
                    STERR("Audio: AddControl(optical board%u) failed: 0x%x", b, ret);
                }
            } else {
                STERR("Audio: SymphonyOpticalControl alloc/init failed (board%u)", b);
            }
            OSSafeReleaseNULL(oc);   // drop the OSTypeAlloc +1; ivar ref keeps it alive
        }
        if (ivars->numOpticalBoards > 0)
            STLOG("Audio: Optical format controls added (%u board%s)",
                  ivars->numOpticalBoards, ivars->numOpticalBoards == 1 ? "" : "s");

        // ── 36d. Phantom power ('phan') + mic gain ('vlme'/Input) — board-gated ──
        // Per-mic-channel controls of the 8-channel MicPre8 option board. The base
        // Symphony IO MKI ships with ZERO mic preamps; those 8 channels exist ONLY
        // when a MicPre8 board is fitted (SymphonyIOVendorSpecific.h:1060-1064).
        //
        // The subclass + send machinery below is fully wired (SymphonyPhantomControl,
        // SymphonyMicGainControl, RequestPhantom, RequestMicGain — each an
        // entitlement-free AudioDriverKit control driven over the SAME audio-HAL
        // property path as volume/mute/clock, no IOUserClient). It is dormant until a
        // MicPre8 is POSITIVELY detected.
        //
        // Board-detect via OptionBoardType (0xA1), a request/RESPONSE transaction
        // over XLink (legacy SymphonyIOControl.cpp:1214-1236 getPrimaryBoardType,
        // nValue=0/primary, wLength=1). ReadVendorRequest issues the 0xC0 read and
        // reassembles the SimpleMessageProtocol Response frame. The returned byte is a
        // SymphonyIOOptionBoardType; MicPre8 (==1) is the ONLY value with mic preamps.
        // On read failure/timeout → 0 (fail-safe: publish nothing). This runs on the
        // XLink init path (not the IRQ queue), so ReadVendorRequest's bounded IOSleep
        // polling is safe here (same pattern as WaitForLock earlier in Start()).
        {
            uint8_t boardType = kSIOOptionBoard_None;
            bool ok = ReadVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                        ivars->symphonyAddr, kSIOCmd_OptionBoardType,
                                        /*nValue=primary*/0, &boardType, /*wLength*/1,
                                        ivars->runtimeTxSeq);
            if (ok) {
                ivars->numMicChannels =
                    (boardType == kSIOOptionBoard_MicPre8) ? kMicPre8NumChannels : 0;
                STLOG("SymphonyIO: OptionBoardType(primary) = %u (%s) → numMicChannels=%u",
                      boardType,
                      boardType == kSIOOptionBoard_MicPre8 ? "MicPre8" : "other/none",
                      ivars->numMicChannels);
            } else {
                ivars->numMicChannels = 0;   // fail-safe on read failure/timeout
                STLOG("SymphonyIO: OptionBoardType read failed/timeout → numMicChannels=0 (no mic controls)");
            }
        }

        // Best-effort clock lock/rate readback (ClockRateAndLock, 0x51 — read-only,
        // wLength=5: [0]=lock 0/1, [1..4]=uint32 BE measured rate). Proof-point toward
        // clock-status readback; NEVER blocks Start on it. LE decode; sanity-check
        // against the register-based GetActualClockRate on first hardware run.
        {
            uint8_t clk[5] = { 0, 0, 0, 0, 0 };
            bool ok = ReadVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                        ivars->symphonyAddr, kSIOCmd_ClockRateAndLock,
                                        /*nValue*/0, clk, /*wLength*/5,
                                        ivars->runtimeTxSeq);
            if (ok) {
                bool     clkLocked = (clk[0] != 0);
                // BIG-endian: legacy getExternalClockStatus builds the rate as
                // acData[1]<<24 | acData[2]<<16 | acData[3]<<8 | acData[4] (clk[1] is the MSB) —
                // SymphonyIOControl.cpp:1067-1090. Decoding LE would byte-swap (48000 → 0x0000BB80
                // reversed = 2159869952). Log-only, but keep the cross-check meaningful.
                uint32_t rateHz = ((uint32_t)clk[1] << 24)
                                | ((uint32_t)clk[2] << 16)
                                | ((uint32_t)clk[3] << 8)
                                |  (uint32_t)clk[4];
                STLOG("SymphonyIO: ClockRateAndLock — %s, measured %u Hz (register-based=%u Hz)",
                      clkLocked ? "LOCKED" : "no-lock", rateHz,
                      GetActualClockRate(ivars->pciDevice, ivars->barMemoryIndex));
            } else {
                STLOG("SymphonyIO: ClockRateAndLock read failed/timeout (best-effort, ignored)");
            }
        }

        for (uint32_t ch = 0; ch < ivars->numMicChannels; ch++) {   // 0 ⇒ publishes nothing
            // Phantom power ('phan') on Input scope, per-channel element = ch+1
            // (element 0 = Main/master; per-channel elements are 1-based even though
            // the WIRE channel index is 0-based — SetChannel(ch) carries the wire index).
            SymphonyPhantomControl* ph = OSTypeAlloc(SymphonyPhantomControl);   // +1
            if (ph && ph->init(this, /*settable*/true, /*initial*/false,
                    (IOUserAudioObjectPropertyElement)(ch + 1),
                    IOUserAudioObjectPropertyScope::Input,
                    IOUserAudioClassID::PhantomPowerControl)) {   // 'phan'
                ph->SetChannel(ch);      // 0-based wire channel
                ph->SetDriver(this);     // back-pointer for the push callback
                ret = ivars->audioDevice->AddControl(ph);   // framework retains
                if (ret != kIOReturnSuccess) {
                    STERR("Audio: AddControl(phantom ch%u) failed: 0x%x", ch, ret);
                } else {
                    ivars->phantomControl[ch] = ph;
                    ivars->phantomControl[ch]->retain();   // tracked ref (balanced in teardown)
                }
            } else {
                STERR("Audio: SymphonyPhantomControl alloc/init failed (ch%u)", ch);
            }
            OSSafeReleaseNULL(ph);   // drop the OSTypeAlloc +1; ivar ref keeps it alive

            // Mic gain ('vlme') on Input scope, 0..85 dB range.
            SymphonyMicGainControl* g = OSTypeAlloc(SymphonyMicGainControl);   // +1
            IOUserAudioLevelControlRange gainRange = { kMicGainMinDb, kMicGainMaxDb };
            if (g && g->init(this, /*settable*/true, /*init*/kMicGainMinDb, gainRange,
                    (IOUserAudioObjectPropertyElement)(ch + 1),
                    IOUserAudioObjectPropertyScope::Input,
                    IOUserAudioClassID::VolumeControl)) {   // gain stage on Input ('vlme')
                g->SetChannel(ch);
                g->SetDriver(this);
                ret = ivars->audioDevice->AddControl(g);
                if (ret != kIOReturnSuccess) {
                    STERR("Audio: AddControl(mic gain ch%u) failed: 0x%x", ch, ret);
                } else {
                    ivars->micGainControl[ch] = g;
                    ivars->micGainControl[ch]->retain();
                }
            } else {
                STERR("Audio: SymphonyMicGainControl alloc/init failed (ch%u)", ch);
            }
            OSSafeReleaseNULL(g);
        }
        if (ivars->numMicChannels > 0)
            STLOG("Audio: MicPre8 phantom+gain controls added (%u channels)",
                  ivars->numMicChannels);

        // ── 37. Set IO operation handler ─────────────────────────────────
        // Copy between CoreAudio stream buffers and FPGA DMA buffers.
        // WriteEnd (playback): CoreAudio wrote to stream buf → copy to DMA buf.
        // BeginRead (capture): copy DMA buf → stream buf before CoreAudio reads.
        //
        // Ring buffer layout: kNumSampleFrames frames × kMaxChannelsPerPort channels × 4 bytes
        // The sample_time wraps around the ring buffer via modulo.

        {
            // Pre-compute mapped addresses for use in the real-time block
            uint8_t *a2hDMABase    = (uint8_t *)ivars->a2hDMAMap->GetAddress();
            uint8_t *h2aDMABase    = (uint8_t *)ivars->h2aDMAMap->GetAddress();
            uint8_t *a2hStreamBase = (uint8_t *)ivars->a2hStreamMap->GetAddress();
            uint8_t *h2aStreamBase = (uint8_t *)ivars->h2aStreamMap->GetAddress();

            STLOG("IOOpHandler: DMA maps: a2h=%p h2a=%p, Stream maps: a2h=%p h2a=%p",
                  (void *)a2hDMABase, (void *)h2aDMABase,
                  (void *)a2hStreamBase, (void *)h2aStreamBase);

            constexpr uint32_t kBytesPerFrame = kMaxChannelsPerPort * (kAudioBitDepth / 8);  // 128
            constexpr uint32_t kRingBytes = kNumSampleFrames * kBytesPerFrame;               // 1MB

            ret = ivars->audioDevice->SetIOOperationHandler(
                ^kern_return_t(IOUserAudioObjectID in_device,
                               IOUserAudioIOOperation in_io_operation,
                               uint32_t in_io_buffer_frame_size,
                               uint64_t in_sample_time,
                               uint64_t in_host_time) {

                    uint32_t frameOffset = (uint32_t)(in_sample_time % kNumSampleFrames);
                    uint32_t byteOffset  = frameOffset * kBytesPerFrame;
                    uint32_t byteCount   = in_io_buffer_frame_size * kBytesPerFrame;

                    // Safety clamp: prevent overrun if host passes unexpected frame count
                    if (byteCount > kRingBytes) byteCount = kRingBytes;

                    if (in_io_operation == IOUserAudioIOOperationWriteEnd) {
                        // Playback: CoreAudio wrote to stream buffer → copy to DMA buffer
                        // Handle ring buffer wrap-around
                        if (byteOffset + byteCount <= kRingBytes) {
                            memcpy(h2aDMABase + byteOffset,
                                   h2aStreamBase + byteOffset,
                                   byteCount);
                        } else {
                            uint32_t firstPart = kRingBytes - byteOffset;
                            memcpy(h2aDMABase + byteOffset,
                                   h2aStreamBase + byteOffset,
                                   firstPart);
                            memcpy(h2aDMABase,
                                   h2aStreamBase,
                                   byteCount - firstPart);
                        }
                    } else if (in_io_operation == IOUserAudioIOOperationBeginRead) {
                        // Capture: copy DMA buffer → stream buffer before CoreAudio reads
                        if (byteOffset + byteCount <= kRingBytes) {
                            memcpy(a2hStreamBase + byteOffset,
                                   a2hDMABase + byteOffset,
                                   byteCount);
                        } else {
                            uint32_t firstPart = kRingBytes - byteOffset;
                            memcpy(a2hStreamBase + byteOffset,
                                   a2hDMABase + byteOffset,
                                   firstPart);
                            memcpy(a2hStreamBase,
                                   a2hDMABase,
                                   byteCount - firstPart);
                        }
                    }

                    // Diagnostic logging — first calls + periodic (STLOG is RT-unsafe).
                    // M4: gated behind SYMPHONY_RT_DEBUG (default OFF). When off, the
                    // RT path does the memcpy above and returns — no counter, no
                    // speculative DMA sample reads, no os_log, no allocation, no block.
#if SYMPHONY_RT_DEBUG
                    ivars->ioOpCount++;
                    bool shouldLog = (ivars->ioOpCount <= 10)
                                   || ((ivars->ioOpCount & 0x3FF) == 0);  // every 1024 ops
                    if (shouldLog) {
                        if (in_io_operation == IOUserAudioIOOperationBeginRead) {
                            // Capture diagnostics: show A2H DMA buffer content
                            int32_t *a2hDmaSamples = (int32_t *)(a2hDMABase + byteOffset);
                            int32_t *a2hStrSamples = (int32_t *)(a2hStreamBase + byteOffset);
                            // Check if DMA buffer has any non-zero data (first 8 samples)
                            bool hasData = false;
                            for (int i = 0; i < 8 && !hasData; i++)
                                hasData = (a2hDmaSamples[i] != 0);
                            STLOG("IOOpHandler CAPTURE: op=%u #%llu frameSize=%u sampleTime=%llu "
                                  "dma[0..3]=0x%08x,0x%08x,0x%08x,0x%08x %s",
                                  (uint32_t)in_io_operation, ivars->ioOpCount,
                                  in_io_buffer_frame_size, in_sample_time,
                                  (uint32_t)a2hDmaSamples[0], (uint32_t)a2hDmaSamples[1],
                                  (uint32_t)a2hDmaSamples[2], (uint32_t)a2hDmaSamples[3],
                                  hasData ? "HAS DATA" : "*** ALL ZEROS ***");
                        } else {
                            int32_t *streamSamples = (int32_t *)(h2aStreamBase + byteOffset);
                            int32_t *dmaSamples    = (int32_t *)(h2aDMABase + byteOffset);
                            STLOG("IOOpHandler PLAYBACK: op=%u #%llu frameSize=%u sampleTime=%llu "
                                  "stream[0..1]=0x%08x,0x%08x dma[0..1]=0x%08x,0x%08x",
                                  (uint32_t)in_io_operation, ivars->ioOpCount,
                                  in_io_buffer_frame_size, in_sample_time,
                                  (uint32_t)streamSamples[0], (uint32_t)streamSamples[1],
                                  (uint32_t)dmaSamples[0], (uint32_t)dmaSamples[1]);
                        }
                    }
#endif  // SYMPHONY_RT_DEBUG

                    return kIOReturnSuccess;
                });
        }
        if (ret != kIOReturnSuccess) {
            STERR("Audio: SetIOOperationHandler failed: 0x%x", ret);
        }

        // ── 38. Vendor command custom property (BEFORE publish) ─────────
        // Must be added before AddObject() so CoreAudio includes it in the
        // device's property enumeration. Adding after publish → 'what' error.
        {
            IOUserAudioObjectPropertyAddress propAddr = {
                .mSelector = kSymphonyVendorCommandSelector,  // 'SYVC'
                .mScope    = IOUserAudioObjectPropertyScope::Global,
                .mElement  = IOUserAudioObjectPropertyElementMain,
            };

            auto vendorProp = IOUserAudioCustomProperty::Create(
                this, propAddr, true,  // settable
                IOUserAudioCustomPropertyDataType::None,       // no qualifier
                IOUserAudioCustomPropertyDataType::Dictionary);// data = plist (wraps raw bytes)

            if (vendorProp) {
                // NOTE: Do NOT call SetQualifierAndDataValue here.
                // AudioDriverKit's IOUserAudioCustomProperty has internal bugs:
                // - Without initial value: framework crashes on first SetPropertyData
                //   (SetQualifierAndDataValue dereferences NULL at 0x10)
                // - With initial value: IRQ handler's GetCustomPropertyValueWithQualifier
                //   returns a freed/corrupted object → SIGSEGV at 0x10 in release
                // Custom property approach abandoned for vendor commands.
                // TODO: Use IOUserClient directly for vendor command transport.

                ret = ivars->audioDevice->AddCustomProperty(vendorProp.get());
                if (ret == kIOReturnSuccess) {
                    // Phase 7 leak fix: AddCustomProperty RETAINS (does not take ownership —
                    // header: "reference count will be incremented"). The old code did
                    // vendorProp.detach() and discarded the returned pointer, ABANDONING the
                    // Create() +1 without ever releasing it. Because the property was Create()d
                    // with `this` (the driver) as owner, that leaked reference pinned the driver
                    // forever → the driver's refcount never reached zero → free() never ran → the
                    // dext process lingered as an orphan on every unplug/upgrade (the wedge).
                    // Capture the Create() reference into the ivar so Stop() can balance it.
                    // (Verified at the AudioDriverKit machine-code level: AddCustomProperty adds
                    // TWO framework refs — the device's custom-property array + the driver's object
                    // map — and RemoveCustomProperty drops both; OSSafeReleaseNULL then drops this
                    // Create ref, bringing the property to zero so it stops retaining the driver.)
                    ivars->vendorProperty = vendorProp.detach();
                    STLOG("Audio: Vendor command property 'SYVC' added (tracked for teardown)");
                } else {
                    STERR("Audio: AddCustomProperty failed: 0x%x", ret);
                }
            } else {
                STERR("Audio: IOUserAudioCustomProperty::Create failed");
            }
        }

        // ── 39. Add device to driver and set transport type ──────────────

        ret = AddObject(ivars->audioDevice);
        if (ret != kIOReturnSuccess) {
            STERR("Audio: AddObject(device) failed: 0x%x", ret);
            goto start_failure;
        }

        SetTransportType(IOUserAudioTransportType::Thunderbolt);

        // Display name — must be set after AddObject so CoreAudio sees it
        OSString *deviceName = OSString::withCString("Symphony I/O: ThunderBridge");
        if (deviceName) {
            ivars->audioDevice->SetName(deviceName);
            OSSafeReleaseNULL(deviceName);
        }

        STLOG("Audio: Device published to CoreAudio (32ch SInt32 in + 32ch SInt32 out, 44.1-192kHz, Thunderbolt)");
    }

    goto start_success;

start_failure:
    // Any failure after the PCI session or DMA setup must unwind through the
    // same lifecycle-safe Stop path. Registering a partially initialized
    // driver as success leaves stale DMA/IRQ state and makes reconnects fragile.
    if (ret == kIOReturnSuccess) {
        ret = kIOReturnError;
    }
    STERR("Start() initialization failed — tearing down before returning 0x%x", ret);
    {
        const kern_return_t stopResult = Stop(provider);
        if (stopResult != kIOReturnSuccess) {
            STERR("Start() failure teardown returned 0x%x", stopResult);
        }
    }
    return ret;

start_success:
    // ── Done ────────────────────────────────────────────────────────────────

    // dext 113: seed the link watch from Start()'s own result and arm it.
    ivars->linkClockPresent = ivars->symphonyLinkConfigured;
    __atomic_store_n(&ivars->linkState,
                     ivars->symphonyLinkConfigured ? kLinkStateUp : kLinkStateDown, __ATOMIC_RELEASE);
    ArmLinkWatch(ivars, kLinkWatchFastNs);

    STLOG("Start() complete — ThunderBridge FPGA communication validated");
    STLOG("  Gate T1 PASSED: FPGA ID read OK, scratch round-trip OK");
    if (ivars->dmaRunning) {
        STLOG("  PT-06 DMA: RUNNING (A2H + H2A, 32ch, 44100Hz, 1MB buffers)");
    }
    if (ivars->audioDevice) {
        STLOG("  PT-07 Audio: IOUserAudioDevice published (32ch in/out, Thunderbolt)");
    }

    ret = RegisterService();
    if (ret != kIOReturnSuccess) {
        STERR("RegisterService failed: 0x%x", ret);
    }

    return kIOReturnSuccess;
}

// ── Interrupt Handler ───────────────────────────────────────────────────────
// Called by IOInterruptDispatchSource when MSI interrupt fires (A2H DMA wrap).
// Legacy: Symphony64Card::interruptService() — takeTimeStamp + clear INTSTATUS.
// In DriverKit this runs at normal thread level (not primary interrupt context).
// PT-07: delivers zero timestamps to CoreAudio for clock recovery.

void IMPL(SymphonyThunderbridge, InterruptOccurred)
{
    ivars->interruptCount++;

    // dext 112: no BAR access while the provider is powering down or the
    // endpoint is not answering (see PCIEndpointPresent). The status read below
    // would be a fatal load on a vanished unit. Flag-only here — RT path.
    if (__atomic_load_n(&ivars->hwSuspended, __ATOMIC_ACQUIRE) ||
        __atomic_load_n(&ivars->providerPowerOff, __ATOMIC_ACQUIRE)) return;

    // ── METERING FIX — read interrupt status BEFORE clearing it (do NOT remove) ──
    // This read is REQUIRED for the card meter DMA to coexist with audio. Without it, the
    // blind write-clear below lets the meter interrupt condition re-assert at the ~64 Hz
    // meter-timer rate; those coalesce into the audio-wrap handler (count≈11), inflating the
    // reported sample clock to ~527 kHz and breaking ADAT/DAWs (Logic rejects the rate).
    // Reading the status first acknowledges the condition so metering runs with the audio
    // clock correct at 48 kHz. Hardware-validated 2026-07-15 (Logic + ADAT + Silent Way,
    // meters live). See Docs/thunderbolt-learnings.md "METERING FIX FOUND".
    uint32_t intStatusAck = 0;
    ReadRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegIntStatus, &intStatusAck);
    // Meter timer interrupts share the MSI line with audio on this FPGA.  A
    // callback caused only by the meter must not advance the audio clock: it
    // has no corresponding A2H ring-wrap period.  Keep the status snapshot
    // before the clear so coalesced audio+meter callbacks still timestamp the
    // audio wrap represented by `count`.
    const bool hasAudioWrap = (intStatusAck & kInt_A2HWrap) != 0;

    // Clear all interrupt status bits (legacy clears with 0xFFFFFFFF)
    WriteRegister(ivars->pciDevice, ivars->barMemoryIndex,
                  kRegIntStatus, 0xFFFFFFFF);

    // PT-07: Deliver zero timestamp to CoreAudio when IO is running.
    // Each A2H wrap = kNumSampleFrames (8192) samples have been transferred.
    // The 'time' parameter from IOInterruptDispatchSource is mach_absolute_time
    // of the interrupt — use as host_time for clock recovery.
    //
    // Safety: snapshot ioRunning and audioDevice to avoid race with Stop().
    // Stop() sets ioRunning=false and waits before releasing audioDevice,
    // but an extra check here prevents use-after-free if timing is tight.
    // M2: ACQUIRE load pairs with the RELEASE store in StartDevice — observing
    // ioRunning==true guarantees the anchor payload (firstTimestampAfterStart,
    // zeroTimestampSampleTime) it reads below is the fresh post-Start state.
    if (hasAudioWrap && __atomic_load_n(&ivars->ioRunning, __ATOMIC_ACQUIRE)) {
        // dext 113: the link watch treats advancing audio wraps as proof of a live
        // XLink sample clock (meter-timer interrupts share the MSI and must not count).
        __atomic_fetch_add(&ivars->audioWrapCount, 1, __ATOMIC_RELAXED);
        IOUserAudioDevice *dev = ivars->audioDevice;
        if (dev) {
            if (ivars->firstTimestampAfterStart) {
                // Anchor: first timestamp after StartDevice.
                // Legacy kext: takeTimeStamp(false) → sample_time paired with the
                // current mach_absolute_time. This establishes the clock relationship
                // for the HAL. Without this anchor, HAL can't sync and aborts IO.
                //
                // C1/#5: 'count' is the number of hardware A2H wraps this callback
                // represents (≥1; >1 when IRQs coalesced before the first upcall).
                // 'time' is the mach_absolute_time of the LAST of those wraps, so
                // anchoring at sampleTime 0 while pairing it with the last wrap's
                // host time would leave the CoreAudio timeline permanently
                // (count-1)*kNumSampleFrames behind. Anchor at (count-1) periods so
                // sampleTime accounts for every wrap 'time' already includes.
                ivars->firstTimestampAfterStart = false;
                uint64_t firstWraps = (count > 0) ? (count - 1) : 0;
                ivars->zeroTimestampSampleTime = firstWraps * kNumSampleFrames;
                dev->UpdateCurrentZeroTimestamp(
                    ivars->zeroTimestampSampleTime, time);
            } else {
                // C1: IOInterruptDispatchSource's 'count' is the number of hardware
                // interrupts SINCE THE LAST CALLBACK (already the coalesced delta —
                // xnu resets ivars->count to 0 on every InterruptOccurred upcall), not
                // a cumulative total. Each A2H wrap = kNumSampleFrames transferred, and
                // the legacy kext took exactly one timestamp per hardware IRQ
                // (Symphony64Card.cpp:388-403). So advance by count buffers directly:
                // count==1 in the normal non-coalescing case, ≥2 only when IRQs merged.
                ivars->zeroTimestampSampleTime += count * kNumSampleFrames;
                dev->UpdateCurrentZeroTimestamp(
                    ivars->zeroTimestampSampleTime, time);
            }
        }
    }

    // ── Volume/mute change tracking ─────────────────────────────────
    // Poll the CoreAudio volume control each interrupt (≈186ms at 44100/8192).
    // When the user adjusts the macOS volume HUD, hand the new value off to the
    // serial XLink queue. C2: SendVendorRequest busy-waits IOSleep(1) up to 100ms
    // per MSG_BYTE frame (>1s for a full frame); running that HERE would stall the
    // interrupt queue for seconds → dropouts and (with C1) permanent clock slip.
    // Dispatch ASYNC and return promptly — the IRQ handler must never block.
    // #4: txShutdown is read with an ACQUIRE atomic load (it is stored with RELEASE
    // in Stop). The coalescing state (pendingAtten/pendingMuteState + generation +
    // scheduled) is written HERE on the IRQ queue and read/cleared on the XLink
    // queue, so every access uses __atomic_* intrinsics with a generation+CAS drain
    // protocol: the producer publishes the value (RELAXED), bumps a generation
    // counter (RELEASE), then CAS-arms the 'scheduled' flag; the drain snapshots the
    // generation, sends, releases 'scheduled', and re-reads the generation — if it
    // advanced, a newer value arrived mid-send and the drain re-arms. This makes a
    // lost update or a stuck scheduled==true impossible.
    IODispatchQueue *txq = ivars->xlinkQueue;
    bool txDown = __atomic_load_n(&ivars->txShutdown, __ATOMIC_ACQUIRE);
    if (txq && !txDown && ivars->outputVolumeControl) {
        float db = ivars->outputVolumeControl->GetDecibelValue();
        float diff = db - ivars->lastVolumeDb;
        if (diff > 0.5f || diff < -0.5f) {
            ivars->lastVolumeDb = db;   // IRQ-queue-only scalar (single writer)
            // Map macOS dB (negative) to hardware attenuation (positive), clamp to 0..64
            float atten = -db;
            if (atten < 0.0f) atten = 0.0f;
            if (atten > 64.0f) atten = 64.0f;
            uint8_t attenuation = (uint8_t)atten;
            uint8_t activeTarget = __atomic_load_n(&ivars->monitorOutputTarget,
                                                   __ATOMIC_ACQUIRE);
            if (activeTarget == 1)
                __atomic_store_n(&ivars->hp1Attenuation, attenuation, __ATOMIC_RELEASE);
            else
                __atomic_store_n(&ivars->speakerAttenuation, attenuation, __ATOMIC_RELEASE);
            __atomic_store_n(&ivars->pendingAtten, attenuation, __ATOMIC_RELAXED);
            __atomic_fetch_add(&ivars->pendingVolumeGen, 1, __ATOMIC_RELEASE);
            bool expected = false;
            if (__atomic_compare_exchange_n(&ivars->volumeTxScheduled, &expected, true,
                                            false, __ATOMIC_ACQ_REL, __ATOMIC_RELAXED)) {
                txq->DispatchAsync(^{
                    for (;;) {
                        uint32_t gen = __atomic_load_n(&ivars->pendingVolumeGen, __ATOMIC_ACQUIRE);
                        uint8_t b = __atomic_load_n(&ivars->pendingAtten, __ATOMIC_RELAXED);
                        if (XLinkTxAdmissible(ivars)) {
                            const uint8_t target = __atomic_load_n(&ivars->monitorOutputTarget,
                                                                    __ATOMIC_ACQUIRE);
                            const uint8_t command = target == 1 ? kSIOCmd_HeadphoneVolume
                                                                 : kSIOCmd_SpeakerVolume;
                            SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                              ivars->symphonyAddr, command, 0,
                                              &b, 1, ivars->runtimeTxSeq);
                        }
                        __atomic_store_n(&ivars->volumeTxScheduled, false, __ATOMIC_RELEASE);
                        // Re-arm only if a newer value arrived AND no producer beat us to it.
                        if (__atomic_load_n(&ivars->pendingVolumeGen, __ATOMIC_ACQUIRE) == gen)
                            break;
                        bool exp2 = false;
                        if (!__atomic_compare_exchange_n(&ivars->volumeTxScheduled, &exp2, true,
                                                         false, __ATOMIC_ACQ_REL, __ATOMIC_RELAXED))
                            break;
                    }
                });
            }
#if SYMPHONY_RT_DEBUG
            STLOG("Volume changed: %.1f dB → SpeakerVolume(%u) [coalesced]", db, (unsigned)atten);
#endif
        }
    }
    if (txq && !txDown && ivars->outputMuteControl) {
        bool muted = ivars->outputMuteControl->GetControlValue();
        if (muted != ivars->lastMuteState) {
            ivars->lastMuteState = muted;   // IRQ-queue-only scalar (single writer)
            uint8_t activeTarget = __atomic_load_n(&ivars->monitorOutputTarget,
                                                   __ATOMIC_ACQUIRE);
            if (activeTarget == 1)
                __atomic_store_n(&ivars->hp1Mute, muted, __ATOMIC_RELEASE);
            else
                __atomic_store_n(&ivars->speakerMute, muted, __ATOMIC_RELEASE);
            __atomic_store_n(&ivars->pendingMuteState, muted, __ATOMIC_RELAXED);
            __atomic_fetch_add(&ivars->pendingMuteGen, 1, __ATOMIC_RELEASE);
            bool expected = false;
            if (__atomic_compare_exchange_n(&ivars->muteTxScheduled, &expected, true,
                                            false, __ATOMIC_ACQ_REL, __ATOMIC_RELAXED)) {
                txq->DispatchAsync(^{
                    for (;;) {
                        uint32_t gen = __atomic_load_n(&ivars->pendingMuteGen, __ATOMIC_ACQUIRE);
                        uint8_t b = __atomic_load_n(&ivars->pendingMuteState, __ATOMIC_RELAXED) ? 1 : 0;
                        if (XLinkTxAdmissible(ivars)) {
                            const uint8_t target = __atomic_load_n(&ivars->monitorOutputTarget,
                                                                    __ATOMIC_ACQUIRE);
                            const uint8_t command = target == 1 ? kSIOCmd_HeadphoneMute
                                                                 : kSIOCmd_SpeakerMute;
                            SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                              ivars->symphonyAddr, command, 0,
                                              &b, 1, ivars->runtimeTxSeq);
                        }
                        __atomic_store_n(&ivars->muteTxScheduled, false, __ATOMIC_RELEASE);
                        if (__atomic_load_n(&ivars->pendingMuteGen, __ATOMIC_ACQUIRE) == gen)
                            break;
                        bool exp2 = false;
                        if (!__atomic_compare_exchange_n(&ivars->muteTxScheduled, &exp2, true,
                                                         false, __ATOMIC_ACQ_REL, __ATOMIC_RELAXED))
                            break;
                    }
                });
            }
#if SYMPHONY_RT_DEBUG
            STLOG("Mute changed: %s [coalesced]", muted ? "MUTED" : "UNMUTED");
#endif
        }
    }

    // ── Clock source change: PUSHED, not polled ─────────────────────
    // A SELECTOR control does not reflect coreaudiod's write through
    // GetCurrentSelectedValues, so there is nothing to poll here. The user's
    // selection arrives via SymphonyClockSelectorControl::HandleChangeSelectedValues
    // → RequestClockSource(), which coalesces + async-sends ClockMode on xlinkQueue
    // using the same generation+CAS discipline as volume/mute above.

    // ── Vendor command dispatch (DISABLED) ──────────────────────────
    // Custom property polling disabled due to AudioDriverKit framework bugs:
    // GetCustomPropertyValueWithQualifier returns corrupted objects → SIGSEGV.
    // Vendor commands will be implemented via IOUserClient (PT-13 next phase).
    // Volume/mute controls above still work via AudioDriverKit control objects.

    // M4/#6: The periodic diagnostic block below runs on the serial IRQ queue and
    // does many speculative MMIO/DMA reads plus os_log() calls — all RT-unsafe. Gate
    // the ENTIRE block behind SYMPHONY_RT_DEBUG (default OFF) so the production IRQ
    // path performs only the timestamp delivery + volume/mute coalescing above.
#if SYMPHONY_RT_DEBUG
    // Log periodically (every 256 interrupts ≈ every ~47 seconds at 44100/8192)
    if ((ivars->interruptCount & 0xFF) == 1) {
        uint32_t a2hCHA = 0, h2aCHA = 0;
        ReadRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegA2HCHA, &a2hCHA);
        ReadRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegH2ACHA, &h2aCHA);
        uint32_t position = (a2hCHA - (uint32_t)ivars->a2hPhysAddr)
                          / (kMaxChannelsPerPort * (kAudioBitDepth / 8));
        STLOG("IRQ #%llu: A2H pos=%u/%u frames, ioRunning=%u, sampleTime=%llu, ioOps=%llu",
              ivars->interruptCount, position, kNumSampleFrames,
              __atomic_load_n(&ivars->ioRunning, __ATOMIC_RELAXED),  // M2: keep atomic-consistent (diagnostic)
              ivars->zeroTimestampSampleTime, ivars->ioOpCount);
        STLOG("  H2A_CHA=0x%08x (offset=%u)", h2aCHA,
              h2aCHA - (uint32_t)ivars->h2aPhysAddr);

        // Read FPGA output sample memory — shows what's being sent to XLink
        // kRegSampleOut1Base = 0xC000, each channel is 4 bytes
        uint32_t sampleOut0 = 0, sampleOut1 = 0;
        ReadRegister(ivars->pciDevice, ivars->barMemoryIndex,
                     kRegSampleOut1Base + 0, &sampleOut0);
        ReadRegister(ivars->pciDevice, ivars->barMemoryIndex,
                     kRegSampleOut1Base + 4, &sampleOut1);
        STLOG("  SampleOut[0]=0x%08x SampleOut[1]=0x%08x%s",
              sampleOut0, sampleOut1,
              (sampleOut0 == 0 && sampleOut1 == 0) ? " *** ALL ZEROS ***" : "");

        // Read FPGA input sample memory — shows what's arriving FROM XLink (capture)
        // kRegSampleIn1Base = 0x8000, each channel is 4 bytes
        uint32_t sampleIn0 = 0, sampleIn1 = 0, sampleIn2 = 0, sampleIn3 = 0;
        ReadRegister(ivars->pciDevice, ivars->barMemoryIndex,
                     kRegSampleIn1Base + 0, &sampleIn0);
        ReadRegister(ivars->pciDevice, ivars->barMemoryIndex,
                     kRegSampleIn1Base + 4, &sampleIn1);
        ReadRegister(ivars->pciDevice, ivars->barMemoryIndex,
                     kRegSampleIn1Base + 8, &sampleIn2);
        ReadRegister(ivars->pciDevice, ivars->barMemoryIndex,
                     kRegSampleIn1Base + 12, &sampleIn3);
        STLOG("  SampleIn[0..3]=0x%08x,0x%08x,0x%08x,0x%08x%s",
              sampleIn0, sampleIn1, sampleIn2, sampleIn3,
              (sampleIn0 == 0 && sampleIn1 == 0 && sampleIn2 == 0 && sampleIn3 == 0)
                  ? " *** NO INPUT DATA ***" : " HAS INPUT");

        // Read A2H DMA buffer directly to check if capture data is being written
        if (ivars->a2hDMAMap) {
            int32_t *a2hBuf = (int32_t *)ivars->a2hDMAMap->GetAddress();
            uint32_t framePos = (a2hCHA - (uint32_t)ivars->a2hPhysAddr)
                              / (kMaxChannelsPerPort * (kAudioBitDepth / 8));
            // Read samples from a position slightly behind the DMA write pointer
            uint32_t checkFrame = (framePos > 64) ? (framePos - 64) : 0;
            uint32_t checkIdx = checkFrame * kMaxChannelsPerPort;
            STLOG("  A2H DMA buf @frame %u: [0..3]=0x%08x,0x%08x,0x%08x,0x%08x%s",
                  checkFrame,
                  (uint32_t)a2hBuf[checkIdx], (uint32_t)a2hBuf[checkIdx+1],
                  (uint32_t)a2hBuf[checkIdx+2], (uint32_t)a2hBuf[checkIdx+3],
                  (a2hBuf[checkIdx] == 0 && a2hBuf[checkIdx+1] == 0)
                      ? " *** CAPTURE DMA EMPTY ***" : " HAS CAPTURE DATA");
        }

        // XLink status: check for data slip (garbling indicator)
        uint32_t xlinkStat = 0, xlinkClk = 0, gcsrDiag = 0;
        ReadRegister(ivars->pciDevice, ivars->barMemoryIndex,
                     kRegXLink1Status, &xlinkStat);
        ReadRegister(ivars->pciDevice, ivars->barMemoryIndex,
                     kRegXLinkClocking, &xlinkClk);
        ReadRegister(ivars->pciDevice, ivars->barMemoryIndex,
                     kRegGCSR, &gcsrDiag);
        STLOG("  XLink1Status=0x%08x (slip=%u) Clocking=0x%08x GCSR=0x%08x (DDS=0x%x)",
              xlinkStat, (xlinkStat & kXLinkDataSlipSticky) ? 1 : 0,
              xlinkClk, gcsrDiag, (gcsrDiag & kGCSR_DDSMask));
    }
#endif  // SYMPHONY_RT_DEBUG
}

// ── StartDevice (AudioDriverKit) ────────────────────────────────────────────
// Called by CoreAudio host when a client opens the audio device for IO.
// Also called after sample rate changes (host stops IO, changes rate, restarts).
// Resets zero timestamp and starts delivering timestamps from interrupts.

kern_return_t SymphonyThunderbridge::StartDevice(
    IOUserAudioObjectID in_object_id,
    IOUserAudioStartStopFlags in_flags)
{
    STLOG("StartDevice: objectID=%u flags=%llu",
          in_object_id, (uint64_t)in_flags);

    // Legacy performAudioEngineStart() reported NOT READY until the XLink
    // bus was configured. The device is published even without a Symphony
    // (build 108+); refusing IO here keeps a clockless device from running
    // an IO cycle that never gets timestamps. The in-place recovery requests
    // a configuration change once the unit answers.
    if (!ivars->symphonyLinkConfigured) {
        STLOG("StartDevice: Symphony link not configured yet — refusing IO start (NOT READY)");
        return kIOReturnNotReady;
    }
    // dext 112: the rate transaction and the first IRQ both load from the BAR.
    if (!HardwareReachable(ivars)) {
        STLOG("StartDevice: endpoint unreachable (powering down or not answering) — NOT READY");
        return kIOReturnNotReady;
    }

    // ── Handle sample rate change ───────────────────────────────────
    // When the user changes rate in Audio MIDI Setup, CoreAudio:
    //   1. Stops IO → our StopDevice() fires
    //   2. Calls HandleChangeSampleRate() on the stock device → SetSampleRate()
    //   3. Restarts IO → this StartDevice() fires
    // We detect the rate mismatch and reprogram the hardware.
    if (ivars->audioDevice) {
        double requestedRate = ivars->audioDevice->GetSampleRate();
        if (requestedRate != ivars->lastSampleRate) {
            STLOG("StartDevice: sample rate changed %.0f → %.0f, reprogramming hardware",
                  ivars->lastSampleRate, requestedRate);

            // #1: Abort early if a Stop has already begun. Stop() sets 'stopping'
            // (RELEASE) before it tears anything down; if we observe it here we must
            // not touch the hardware at all — Stop owns mute + DMA-stop + teardown.
            if (__atomic_load_n(&ivars->stopping, __ATOMIC_ACQUIRE)) {
                STERR("StartDevice: stop in progress — aborting rate change");
                return kIOReturnOffline;
            }

            // ── Full rate-change transaction, SERIALIZED on the XLink queue (#1) ──
            // The ENTIRE transaction — mute, stop DMA, XLink rate change, restart
            // DMA, unmute — runs inside ONE serial-queue block. This is the fix for
            // the Stop-vs-StartDevice race: Stop()'s teardown drains this same queue
            // (a synchronous barrier) BEFORE it releases the DMA mappings and closes
            // PCI, so the whole transaction is guaranteed to run either entirely
            // before teardown (with a valid pciDevice + live DMA mappings) or not at
            // all. Previously only the XLink SetSampleRate ran on the queue while the
            // DMA restart + unmute ran on this thread AFTER the barrier returned —
            // that could restart DMA / MMIO after Close()/buffer-release.
            //
            // Legacy kext: performAudioEngineStop() → StopDMA() → rate change →
            //              performAudioEngineStart() → StartDMA() → unmute.
            // Without stopping DMA, the FPGA PLL clock jump misaligns the DMA engine
            // at large rate changes (1x→4x): garbled audio at 176.4/192 kHz.
            //
            // StartDevice runs on the AudioDriverKit control thread (never the XLink
            // queue), so DispatchSync is deadlock-free and preserves the synchronous
            // success/failure status the host expects.
            // Roll DDS back to the rate the XLink units are ACTUALLY at (xlinkRate),
            // not lastSampleRate (which lags after a post-broadcast failure). Fixes the
            // sequential-failure mismatch Codex round 4 found.
            const double oldXlinkRate = ivars->xlinkRate;
            __block bool rateOk   = false;
            __block bool aborted  = false;

            void (^rateTxn)(void) = ^{
                // Re-check under serialization. If Stop began after our early check
                // (or the device is already closed), abort WITHOUT restarting DMA or
                // unmuting — leave the hardware for Stop() to finish tearing down.
                if (!XLinkTxAdmissible(ivars)) {
                    aborted = true;
                    STERR("StartDevice: stop began or endpoint unreachable mid-transaction — aborting");
                    return;
                }

                // 1. Mute FPGA outputs (legacy: MuteOutputs before StopDMA)
                ModifyRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegClkCtrl,
                               0, kClkCtrl_Unmute | kClkCtrl_InputUnmute | kClkCtrl_OutputUnmute);

                // 2. Stop DMA (clear enable + trigger bits, re-assert write-only ch count)
                {
                    uint32_t gcsr = 0;
                    ReadRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegGCSR, &gcsr);
                    gcsr = (gcsr & ~kGCSR_DMAMask) | (kGCSR_DMAOutSize32 | kGCSR_DMAInSize32);
                    gcsr &= ~(kGCSR_A2HDMAEnable | kGCSR_H2ADMAEnable |
                               kGCSR_A2HTrigSelect | kGCSR_H2ATrigSelect |
                               kGCSR_MeterDMAEnable | kGCSR_MeterTrigSelect);
                    WriteRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegGCSR, gcsr);
                    STLOG("StartDevice: DMA stopped for rate change (GCSR=0x%08x)", gcsr);
                }
                IOSleep(10);  // Let last DMA transfer complete

                // 3. Change sample rate via XLink (full lock/verify/lock sequence).
                bool cmdIssued = false;
                rateOk = ChangeSampleRate(ivars->pciDevice,
                                          ivars->barMemoryIndex, requestedRate, &cmdIssued);

                // If the SetSampleRate command was actually broadcast, the XLink units are
                // now at requestedRate — record that as the true hardware XLink rate BEFORE
                // any early return, regardless of whether the subsequent lock/verify passed.
                // This keeps xlinkRate accurate across a sequence of post-broadcast failures
                // (Codex round 4).
                if (cmdIssued) {
                    ivars->xlinkRate = requestedRate;
                }

                // #3 (Codex rounds 2-4): On ANY rate-change failure, keep DMA STOPPED and
                // outputs MUTED, and return an error — NEVER restart DMA / unmute against a
                // mismatched or unstable clock. Keep DDS and the XLink units CONSISTENT:
                //   - command WAS broadcast (cmdIssued): XLink and DDS are both at requestedRate
                //     (ChangeSampleRate set DDS, then broadcast) — already consistent, no rollback.
                //   - command NOT issued (unsupported rate or TX-busy timeout): XLink is still at
                //     its prior rate (oldXlinkRate), but DDS may have been moved to requestedRate —
                //     roll DDS back to oldXlinkRate so DDS matches the un-changed XLink units.
                // Either way the device is muted/stopped/offline until the next StartDevice
                // performs a full clean reconfiguration.
                if (!rateOk) {
                    if (!cmdIssued) {
                        SetDDSSampleRate(ivars->pciDevice, ivars->barMemoryIndex, oldXlinkRate);
                    }
                    STERR("StartDevice: rate change FAILED (cmdIssued=%d) — DMA stopped, outputs "
                          "muted, DDS+XLink consistent (offline pending reinit)", cmdIssued);
                    return;
                }

                // 4. Reprogram ClkCtrl frame size (legacy does this in every
                // StartDMA).  The legacy High Performance profile changes the
                // FPGA period with sample-rate tier: 4, 8, then 32 frames.
                const TimingProfile profile = TimingProfileForRate(requestedRate);
                ModifyRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegClkCtrl,
                               ((profile.frameSize - 1) << kClkCtrl_FrameShift) & kClkCtrl_FrameMask,
                               kClkCtrl_FrameMask);
                const kern_return_t timingResult =
                    ApplyAudioTimingProfile(ivars->audioDevice, requestedRate);
                if (timingResult != kIOReturnSuccess) {
                    // Do not restart DMA or unmute with a partially published
                    // Core Audio timing tuple.  The device stays stopped and
                    // muted so the host can retry or tear it down safely.
                    STERR("StartDevice: timing profile publication failed: 0x%x — "
                          "leaving DMA stopped + outputs muted", timingResult);
                    rateOk = false;
                    return;
                }
                uint32_t clkCtrlReadback = 0;
                ReadRegister(ivars->pciDevice, ivars->barMemoryIndex,
                             kRegClkCtrl, &clkCtrlReadback);
                const uint32_t frameReadback =
                    ((clkCtrlReadback & kClkCtrl_FrameMask) >> kClkCtrl_FrameShift) + 1;
                STLOG("StartDevice: FPGA frame size set to %u samples (%s profile)",
                      profile.frameSize, kUseHighPerformanceProfile ? "High Performance" : "Standard");
                STLOG("StartDevice: FPGA ClkCtrl readback=0x%08x frame=%u expected=%u",
                      clkCtrlReadback, frameReadback, profile.frameSize);
                if (frameReadback != profile.frameSize) {
                    // Do not restart DMA against a hardware period that differs
                    // from the profile used for Core Audio's published timing.
                    // A setter can succeed while the FPGA rejects or clamps the
                    // frame field, leaving the host timing tuple inconsistent.
                    // Keep the device muted and stopped so the next start can
                    // retry a clean configuration instead of publishing a false
                    // low-latency rate.
                    STERR("StartDevice: FPGA frame readback mismatch (got=%u expected=%u) — "
                          "leaving DMA stopped + outputs muted", frameReadback, profile.frameSize);
                    rateOk = false;
                    return;
                }

                // 5. Clear stale interrupt status before restarting DMA
                WriteRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegIntStatus, 0xFFFFFFFF);

                // #1: FINAL stopping re-check before we RE-ENABLE DMA + unmute.
                // ChangeSampleRate above can run for many seconds (FPGA PLL relock +
                // stability wait). Stop() may have set 'stopping' (RELEASE) during that
                // window — AFTER the entry re-check at 2559 already passed. If we
                // restarted DMA now, the cancel-handler barrier (which waits for THIS
                // in-flight transaction) would then CompleteDMA()/unmap buffers the FPGA
                // master engine is actively DMAing to → DART/IOMMU fault on a
                // still-present device. Aborting HERE (before the DMA re-enable) leaves the
                // hardware where step 1 (muted) + step 2 (DMA stopped) already put it. This
                // check narrows the window but is NOT sufficient on its own: a stop that
                // arrives between this check and the DMA re-enable below would still leave
                // DMA on — which is exactly why Stop()'s teardown ALSO re-clears the GCSR
                // DMA-enable bits after its drain barrier (belt and suspenders). rateOk may
                // already be true (ChangeSampleRate succeeded), but 'aborted' is checked
                // first by the caller and returns offline.
                if (__atomic_load_n(&ivars->stopping, __ATOMIC_ACQUIRE) ||
                    !ivars->pciDevice) {
                    aborted = true;
                    STERR("StartDevice: stop began during rate change — leaving DMA "
                          "stopped + muted for teardown");
                    return;
                }

                // 6. Restart DMA (same sequence as Start() step 29)
                {
                    uint32_t gcsr = 0;
                    ReadRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegGCSR, &gcsr);
                    gcsr = (gcsr & ~kGCSR_DMAMask) | (kGCSR_DMAOutSize32 | kGCSR_DMAInSize32);
                    gcsr |= kGCSR_OnlyMasterDMA;
                    WriteRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegGCSR, gcsr);

                    gcsr &= ~(kGCSR_A2HDMAEnable | kGCSR_H2ADMAEnable |
                               kGCSR_A2HTrigSelect | kGCSR_H2ATrigSelect |
                               kGCSR_MeterDMAEnable | kGCSR_MeterTrigSelect);
                    WriteRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegGCSR, gcsr);

                    gcsr |= kGCSR_A2HTrigSelect | kGCSR_H2ATrigSelect;
                    if (ivars->meterDMAActive) gcsr |= kGCSR_MeterTrigSelect;
                    WriteRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegGCSR, gcsr);

                    gcsr |= kGCSR_A2HDMAEnable | kGCSR_H2ADMAEnable;
                    if (ivars->meterDMAActive) gcsr |= kGCSR_MeterDMAEnable;
                    WriteRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegGCSR, gcsr);
                    STLOG("StartDevice: DMA restarted (GCSR=0x%08x%s)", gcsr,
                          ivars->meterDMAActive ? " +Meters" : "");
                }

                // 7. Unmute after DMA is running (legacy: unmute AFTER StartDMA + delay)
                IOSleep(10);
                ModifyRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegClkCtrl,
                               kClkCtrl_Unmute | kClkCtrl_InputUnmute | kClkCtrl_OutputUnmute, 0);
                STLOG("StartDevice: unmuted after rate change to %.0f Hz", requestedRate);
            };

            IODispatchQueue *rateQ = ivars->xlinkQueue;
            if (rateQ) {
                rateQ->DispatchSync(rateTxn);
            } else {
                // No serial queue (DMA/interrupt setup failed). No concurrent TX
                // source exists in that degraded state, so run inline.
                rateTxn();
            }

            if (aborted) {
                return kIOReturnOffline;
            }
            if (!rateOk) {
                // #3: propagate failure — hardware is muted with DMA stopped.
                return kIOReturnIOError;
            }
            ivars->lastSampleRate = requestedRate;
            STLOG("StartDevice: hardware now at %.0f Hz", requestedRate);
        }
    }

    // Clear stale zero timestamp — HAL needs a fresh anchor pair.
    // Apple sample: UpdateCurrentZeroTimestamp(0, 0) in StartIO to clear old state.
    // Without this, HAL sees stale (sampleTime, hostTime) from previous IO session
    // and can't sync its clock → aborts IO immediately.
    if (ivars->audioDevice) {
        ivars->audioDevice->UpdateCurrentZeroTimestamp(0, 0);
    }

    // First IRQ after StartDevice will deliver anchor: (0, mach_absolute_time).
    // Legacy kext: takeTimeStamp(false) on first interrupt = sample_time stays at 0.
    // Subsequent IRQs increment by kNumSampleFrames.
    ivars->zeroTimestampSampleTime = 0;
    ivars->firstTimestampAfterStart = true;
    ivars->startDeviceSerial++;   // dext 119
    ivars->ioOpCount = 0;  // Reset diagnostic counter
    // M2: ioRunning is the publication gate between this thread (the AudioDriverKit
    // control queue) and the IRQ queue. Store it with RELEASE so the anchor payload
    // written just above (zeroTimestampSampleTime, firstTimestampAfterStart) is
    // guaranteed visible to any IRQ callback that observes ioRunning==true via its
    // ACQUIRE load — the handler can never pair "running" with a stale anchor.
    __atomic_store_n(&ivars->ioRunning, true, __ATOMIC_RELEASE);

    // Call super to update IO state — enables IOOperationHandler dispatch pipeline.
    kern_return_t ret = super::StartDevice(in_object_id, in_flags);
    if (ret != kIOReturnSuccess) {
        STERR("StartDevice: super::StartDevice failed: 0x%x", ret);
        __atomic_store_n(&ivars->ioRunning, false, __ATOMIC_RELEASE);  // M2
        return ret;
    }

    STLOG("StartDevice: IO started at %.0f Hz, timestamps will flow from next A2H wrap IRQ",
          ivars->lastSampleRate);
    if (ivars->unmuteOnNextStart) {
        // dext 119: a recovery requested a configuration change and left the card
        // muted so the IO gap played silence, not the stale DMA buffer. IO is back:
        // start from a zeroed buffer and unmute.
        ivars->unmuteOnNextStart = false;
        ZeroPlaybackDMABuffer(ivars, "IO restarted after recovery");
        IOSleep(10);
        ModifyRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegClkCtrl,
                       kClkCtrl_Unmute | kClkCtrl_InputUnmute | kClkCtrl_OutputUnmute, 0);
        STLOG("StartDevice: card unmuted after recovery");
    }
    return kIOReturnSuccess;
}

// ── StopDevice (AudioDriverKit) ─────────────────────────────────────────────
// Called by CoreAudio host when all clients close the audio device.
// Stops delivering timestamps. DMA continues running (free-running mode).

kern_return_t SymphonyThunderbridge::StopDevice(
    IOUserAudioObjectID in_object_id,
    IOUserAudioStartStopFlags in_flags)
{
    STLOG("StopDevice: objectID=%u flags=%llu (total IRQs=%llu, sampleTime=%llu)",
          in_object_id, (uint64_t)in_flags,
          ivars->interruptCount, ivars->zeroTimestampSampleTime);

    // M2: RELEASE store so the IRQ queue promptly observes ioRunning==false and
    // stops touching audioDevice/anchor state before teardown proceeds.
    __atomic_store_n(&ivars->ioRunning, false, __ATOMIC_RELEASE);
    // dext 119: DMA keeps running while IO is stopped; without this the last
    // buffer loops on the outputs (the "looping glitch" heard across a recovery's
    // IO gap). Silence instead.
    if (!__atomic_load_n(&ivars->stopping, __ATOMIC_ACQUIRE))
        ZeroPlaybackDMABuffer(ivars, "IO stopped");

    // Call super to update IO state
    return super::StopDevice(in_object_id, in_flags);
}

// ── Stop ────────────────────────────────────────────────────────────────────

kern_return_t IMPL(SymphonyThunderbridge, Stop)
{
    STLOG("Stop()");

    if (ivars) {
        // ── 1. Enter the 'stopping' lifecycle state FIRST (#1), stop IO timestamp
        //    delivery, and block any new XLink TX enqueues (#2/C2/H1).
        //    'stopping' (RELEASE) is observed by the StartDevice rate-change
        //    transaction (ACQUIRE): once set, an in-progress or queued rate change
        //    ABORTS instead of restarting DMA / unmuting, so the teardown below can
        //    release DMA mappings + close PCI without racing a DMA restart. The
        //    XLink queue is NOT released here — it stays alive until free() (#2) so a
        //    late user-client SendVendorCommand always dispatches onto a live queue,
        //    observes txShutdown inside the serialized block, and returns without
        //    touching a closed pciDevice.
        __atomic_store_n(&ivars->stopping, true, __ATOMIC_RELEASE);
        __atomic_store_n(&ivars->ioRunning, false, __ATOMIC_RELEASE);  // M2
        __atomic_store_n(&ivars->txShutdown, true, __ATOMIC_RELEASE);

        // dext 113: stop the link watch before anything else is torn down. Its
        // handler checks 'stopping' first and never re-arms past it; Cancel with a
        // completion (Cancel(nullptr) faults — see step 7) and release the source
        // there, holding the service alive until the completion has run.
        if (ivars->linkWatchTimer) {
            auto *selfForTimer = this;
            selfForTimer->retain();
            auto *ivTimer = ivars;
            ivars->linkWatchTimer->Cancel(^{
                OSSafeReleaseNULL(ivTimer->linkWatchTimer);
                selfForTimer->release();
            });
        }

        // dext 112: Stop() runs for a unit that vanished (cable pull, power loss)
        // as well as for a clean teardown. The register steps below are reads
        // (ModifyRegister) as well as writes; on a vanished endpoint a read is a
        // fatal bus error. Decide once here, re-check once more after the drain
        // barrier, and skip the hardware steps when the unit is not there —
        // every resource release below still runs.
        const bool hwPresent = EndpointPresentForTeardown(ivars);
        if (!hwPresent) {
            STLOG("Stop: endpoint not reachable — skipping register teardown (resources still released)");
        }

        // ── 2. Mute FPGA audio path (legacy: MuteOutputs before StopDMA)
        if (hwPresent) {
            ModifyRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegClkCtrl,
                           0,  // clear these bits = mute
                           kClkCtrl_Unmute | kClkCtrl_InputUnmute | kClkCtrl_OutputUnmute);
            STLOG("Stop: FPGA muted (ClkCtrl unmute bits cleared)");
        }

        // ── 3. Zero DMA buffers so last DMA'd frames are silence
        if (ivars->a2hDMA) {
            ivars->a2hDMA->PerformOperation(
                kIODMACommandPerformOperationOptionZero, 0, kDMABufferSize, 0, nullptr);
        }
        if (ivars->h2aDMA) {
            ivars->h2aDMA->PerformOperation(
                kIODMACommandPerformOperationOptionZero, 0, kDMABufferSize, 0, nullptr);
        }

        // ── 4. Wait for FPGA to DMA the zeroed/muted data (legacy: IOSleep(100))
        IOSleep(100);

        // dext 112: re-decide after the settle — the unit can vanish during it.
        const bool hwStillPresent = hwPresent && EndpointPresentForTeardown(ivars);

        // ── 5. Disable hardware interrupt mask (stops new MSIs)
        if (hwStillPresent) {
            WriteRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegIntMask, 0);
            WriteRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegIntStatus, 0xFFFFFFFF);
        }

        // ── 6. Stop DMA (clear enable + trigger-select bits)
        if (ivars->dmaRunning && hwStillPresent) {
            ModifyRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegGCSR,
                           0, kGCSR_DMAEnableMask);
            ModifyRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegGCSR2,
                           0, kGCSR2_DMAEnableMask);
            ivars->dmaRunning = false;
            STLOG("Stop: DMA stopped, interrupts disabled. Total IRQs: %llu",
                  ivars->interruptCount);
        }

        // ── 7. Cancel interrupt source with completion handler.
        //    Per Apple's DriverKit samples (NullDriver, SimpleAudioDriver):
        //    - Cancel(handler) → handler fires after all callbacks finish
        //    - Release source, queue, and all remaining resources IN the handler
        //    - Call super::Stop() from the handler, NOT before
        //    Cancel(nullptr) → SIGSEGV at 0x10 (confirmed v17-v22).
        if (ivars->interruptSource) {
            // Retain provider for use in the cancel completion block
            provider->retain();
            auto *self = this;
            self->retain();
            auto *iv = ivars;

            ivars->interruptSource->Cancel(^{
                // ── 8. Release interrupt source and queue (safe — all callbacks done)
                OSSafeReleaseNULL(iv->interruptSource);
                OSSafeReleaseNULL(iv->interruptQueue);

                // ── 9. Remove and release AudioDriverKit objects
                //    Phase 7: EVERY Add* must have its matching Remove* here, BEFORE releasing
                //    our ivar refs — each child (stream/control/property) was Create()d with
                //    `this` as owner and Add* RETAINS it, so a missing Remove* leaves the child
                //    (and thus the driver it retains) alive → free() never runs → orphan process.
                //    Remove children from the device first, then RemoveObject(device) (inverse of
                //    Start's add order), while audioDevice is still valid.
                if (iv->audioDevice) {
                    if (iv->inputStream)  iv->audioDevice->RemoveStream(iv->inputStream);
                    if (iv->outputStream) iv->audioDevice->RemoveStream(iv->outputStream);
                    if (iv->outputVolumeControl) iv->audioDevice->RemoveControl(iv->outputVolumeControl);
                    if (iv->outputMuteControl)   iv->audioDevice->RemoveControl(iv->outputMuteControl);
                    if (iv->clockSourceControl)  iv->audioDevice->RemoveControl(iv->clockSourceControl);
                    // Optical: loop the full 2 unconditionally — never-created slots
                    // are nullptr, so the guard makes it a no-op.
                    for (uint32_t b = 0; b < 2; b++)
                        if (iv->opticalControl[b]) iv->audioDevice->RemoveControl(iv->opticalControl[b]);
                    // Phantom + mic-gain: loop the full 8 unconditionally — released/
                    // never-created slots are nullptr, so the guard makes it a no-op.
                    for (uint32_t ch = 0; ch < 8; ch++) {
                        if (iv->phantomControl[ch]) iv->audioDevice->RemoveControl(iv->phantomControl[ch]);
                        if (iv->micGainControl[ch]) iv->audioDevice->RemoveControl(iv->micGainControl[ch]);
                    }
                    if (iv->vendorProperty)      iv->audioDevice->RemoveCustomProperty(iv->vendorProperty);
                    self->RemoveObject(iv->audioDevice);
                }
                OSSafeReleaseNULL(iv->vendorProperty);
                OSSafeReleaseNULL(iv->outputVolumeControl);
                OSSafeReleaseNULL(iv->outputMuteControl);
                OSSafeReleaseNULL(iv->clockSourceControl);
                for (uint32_t b = 0; b < 2; b++)
                    OSSafeReleaseNULL(iv->opticalControl[b]);
                for (uint32_t ch = 0; ch < 8; ch++) {
                    OSSafeReleaseNULL(iv->phantomControl[ch]);
                    OSSafeReleaseNULL(iv->micGainControl[ch]);
                }
                OSSafeReleaseNULL(iv->inputStream);
                OSSafeReleaseNULL(iv->outputStream);
                OSSafeReleaseNULL(iv->audioDevice);

                // ── 10. Drain the serial XLink queue BEFORE releasing DMA mappings
                //    or closing PCI (#1/#2). The interrupt source is fully cancelled
                //    by now, so no new IRQ TX work can be enqueued; 'stopping' and
                //    'txShutdown' are set, so a StartDevice rate transaction aborts
                //    and a late user SendVendorCommand returns without touching PCI.
                //    This synchronous barrier waits for any STILL-IN-FLIGHT work on
                //    the queue — an in-progress rate-change transaction (which does
                //    DMA restart + MMIO) or a volume/mute drain — to FINISH before we
                //    complete/unmap the DMA buffers below. That is what guarantees no
                //    DMA restart / MMIO runs after CompleteDMA()/Close(). The queue
                //    itself is NOT released here — free() owns that (#2).
                if (iv->xlinkQueue) {
                    iv->xlinkQueue->DispatchSync(^{});   // barrier: flush pending TX + rate txn
                }

                // ── 10b. Re-clear DMA-enable bits AFTER the drain barrier (#1, Codex round 2).
                //    Step 6 above cleared DMA, but a rate transaction that had already passed
                //    its 'stopping' check can re-enable DMA (its check and the enable are not
                //    atomic w.r.t. this clear). The barrier waits for that transaction to
                //    finish, so re-clearing HERE makes the FPGA DMA engine definitively OFF
                //    before CompleteDMA()/unmap — closing the DART-fault window.
                if (EndpointPresentForTeardown(iv)) {
                    ModifyRegister(iv->pciDevice, iv->barMemoryIndex, kRegGCSR,
                                   0, kGCSR_DMAEnableMask);
                    ModifyRegister(iv->pciDevice, iv->barMemoryIndex, kRegGCSR2,
                                   0, kGCSR2_DMAEnableMask);
                }

                // ── 11. Complete and release DMA commands (unmaps IOMMU)
                if (iv->a2hDMA) {
                    iv->a2hDMA->CompleteDMA(kIODMACommandCompleteDMANoOptions);
                    OSSafeReleaseNULL(iv->a2hDMA);
                }
                if (iv->h2aDMA) {
                    iv->h2aDMA->CompleteDMA(kIODMACommandCompleteDMANoOptions);
                    OSSafeReleaseNULL(iv->h2aDMA);
                }
                // Meter DMA: the FPGA writes this buffer every ~100 ms. Stop reads and
                // free it here (GCSR meter bits already cleared above) so the device can
                // never write freed memory / DART-fault.
                iv->meterDMAActive = false;
                iv->meterWords = nullptr;
                if (iv->meterDMA) {
                    iv->meterDMA->CompleteDMA(kIODMACommandCompleteDMANoOptions);
                    OSSafeReleaseNULL(iv->meterDMA);
                }

                // ── 11b. Release memory maps, stream buffers, and DMA buffers
                OSSafeReleaseNULL(iv->a2hDMAMap);
                OSSafeReleaseNULL(iv->h2aDMAMap);
                OSSafeReleaseNULL(iv->a2hStreamMap);
                OSSafeReleaseNULL(iv->h2aStreamMap);
                OSSafeReleaseNULL(iv->a2hStreamBuffer);
                OSSafeReleaseNULL(iv->h2aStreamBuffer);
                OSSafeReleaseNULL(iv->a2hBuffer);
                OSSafeReleaseNULL(iv->h2aBuffer);
                OSSafeReleaseNULL(iv->meterMap);
                OSSafeReleaseNULL(iv->meterBuffer);

                // ── 12. Close PCIe device
                if (iv->pciDevice) {
                    iv->pciDevice->Close(self, 0);
                    OSSafeReleaseNULL(iv->pciDevice);
                }

                STLOG("Stop: Teardown complete (from cancel handler)");

                // ── 13. Call super::Stop from cancel completion
                //    (Apple NullDriver/SimpleAudioDriver pattern)
                self->Stop(provider, SUPERDISPATCH);
                provider->release();
                self->release();
            });

            // Cancel dispatched — return now. super::Stop called from handler.
            return kIOReturnSuccess;
        }

        // Fallback: no interrupt source — release everything synchronously
        if (ivars->audioDevice) {
            // Phase 7: symmetric teardown — every Add* balanced by its Remove* (see cancel-handler
            // path above). Missing Remove* leaves a child alive that retains the driver → orphan.
            if (ivars->inputStream)  ivars->audioDevice->RemoveStream(ivars->inputStream);
            if (ivars->outputStream) ivars->audioDevice->RemoveStream(ivars->outputStream);
            if (ivars->outputVolumeControl) ivars->audioDevice->RemoveControl(ivars->outputVolumeControl);
            if (ivars->outputMuteControl)   ivars->audioDevice->RemoveControl(ivars->outputMuteControl);
            if (ivars->clockSourceControl)  ivars->audioDevice->RemoveControl(ivars->clockSourceControl);
            // Optical: loop the full 2 unconditionally — never-created slots are
            // nullptr, so the guard makes it a no-op.
            for (uint32_t b = 0; b < 2; b++)
                if (ivars->opticalControl[b]) ivars->audioDevice->RemoveControl(ivars->opticalControl[b]);
            // Phantom + mic-gain: loop the full 8 unconditionally — released/
            // never-created slots are nullptr, so the guard makes it a no-op.
            for (uint32_t ch = 0; ch < 8; ch++) {
                if (ivars->phantomControl[ch]) ivars->audioDevice->RemoveControl(ivars->phantomControl[ch]);
                if (ivars->micGainControl[ch]) ivars->audioDevice->RemoveControl(ivars->micGainControl[ch]);
            }
            if (ivars->vendorProperty)      ivars->audioDevice->RemoveCustomProperty(ivars->vendorProperty);
            RemoveObject(ivars->audioDevice);
        }
        OSSafeReleaseNULL(ivars->vendorProperty);
        OSSafeReleaseNULL(ivars->outputVolumeControl);
        OSSafeReleaseNULL(ivars->outputMuteControl);
        OSSafeReleaseNULL(ivars->clockSourceControl);
        for (uint32_t b = 0; b < 2; b++)
            OSSafeReleaseNULL(ivars->opticalControl[b]);
        for (uint32_t ch = 0; ch < 8; ch++) {
            OSSafeReleaseNULL(ivars->phantomControl[ch]);
            OSSafeReleaseNULL(ivars->micGainControl[ch]);
        }
        OSSafeReleaseNULL(ivars->inputStream);
        OSSafeReleaseNULL(ivars->outputStream);
        OSSafeReleaseNULL(ivars->audioDevice);
        // Drain the XLink queue BEFORE completing/unmapping DMA and closing PCI
        // (#1/#2). Waits for any in-flight rate transaction / vendor write to finish
        // so none of them runs against released DMA mappings or a closed device. The
        // queue is NOT released here — free() owns that (#2).
        if (ivars->xlinkQueue) {
            ivars->xlinkQueue->DispatchSync(^{});   // barrier: flush pending TX + rate txn
        }
        // Re-clear DMA-enable AFTER the drain barrier (#1, Codex round 2) — a rate
        // transaction that passed its 'stopping' check may have re-enabled DMA after the
        // earlier clear; the barrier waited for it, so clearing again makes DMA off before unmap.
        if (EndpointPresentForTeardown(ivars)) {
            ModifyRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegGCSR,
                           0, kGCSR_DMAEnableMask);
            ModifyRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegGCSR2,
                           0, kGCSR2_DMAEnableMask);
        }
        if (ivars->a2hDMA) {
            ivars->a2hDMA->CompleteDMA(kIODMACommandCompleteDMANoOptions);
            OSSafeReleaseNULL(ivars->a2hDMA);
        }
        if (ivars->h2aDMA) {
            ivars->h2aDMA->CompleteDMA(kIODMACommandCompleteDMANoOptions);
            OSSafeReleaseNULL(ivars->h2aDMA);
        }
        ivars->meterDMAActive = false;
        ivars->meterWords = nullptr;
        if (ivars->meterDMA) {
            ivars->meterDMA->CompleteDMA(kIODMACommandCompleteDMANoOptions);
            OSSafeReleaseNULL(ivars->meterDMA);
        }
        OSSafeReleaseNULL(ivars->a2hDMAMap);
        OSSafeReleaseNULL(ivars->h2aDMAMap);
        OSSafeReleaseNULL(ivars->a2hStreamMap);
        OSSafeReleaseNULL(ivars->h2aStreamMap);
        OSSafeReleaseNULL(ivars->a2hStreamBuffer);
        OSSafeReleaseNULL(ivars->h2aStreamBuffer);
        OSSafeReleaseNULL(ivars->a2hBuffer);
        OSSafeReleaseNULL(ivars->h2aBuffer);
        OSSafeReleaseNULL(ivars->meterMap);
        OSSafeReleaseNULL(ivars->meterBuffer);
        if (ivars->pciDevice) {
            ivars->pciDevice->Close(this, 0);
            OSSafeReleaseNULL(ivars->pciDevice);
        }
        STLOG("Stop: Teardown complete (no interrupt source)");
    }

    return Stop(provider, SUPERDISPATCH);
}

// ── NewUserClient ────────────────────────────────────────────────────────────
// Called by the kernel when an app calls IOServiceOpen() on our IOService.
// Creates a SymphonyUserClient for vendor command dispatch (mic gain, phantom,
// routing, clock, etc.) from the Maestro app.

// ── SetPowerState (dext 112) ─────────────────────────────────────────────────
// DriverKit notifies a matched service of its provider's power transitions.
// Off/Low precedes system sleep: the Thunderbolt tunnel goes down and the unit
// may lose power while we are asleep. Suspend every BAR access first and drain
// the XLink queue so no vendor transaction straddles the power-down, THEN tell
// super (the documented order: "make itself safe for the new state before
// passing the call to super"). On: the nub is powered, but the endpoint may be
// gone or not yet re-tunnelled — resume only if it answers in config space;
// otherwise stay suspended and let the 1 Hz health probe resume us when it does.
kern_return_t IMPL(SymphonyThunderbridge, SetPowerState)
{
    const bool on = (powerFlags & kIOServicePowerCapabilityOn) != 0;
    STLOG("SetPowerState: flags=0x%08x → %s", powerFlags, on ? "ON" : "OFF/LOW");
    if (ivars) {
        if (!on) {
            // SEQ_CST pairs with the Dekker re-check in HardwareReachable().
            __atomic_store_n(&ivars->providerPowerOff, true, __ATOMIC_SEQ_CST);
            __atomic_store_n(&ivars->hwSuspended, true, __ATOMIC_SEQ_CST);
            // Drain both queues that issue BAR loads so nothing is mid-flight when
            // we ack: the IRQ handler (status read) and the XLink queue (vendor
            // traffic, rate transaction, recovery, health snapshot). Cycle-free:
            // the IRQ handler only DispatchAsyncs onto xlinkQueue and nothing on
            // either queue syncs back to this (default) queue — Stop() relies on
            // the same fact. Once 'stopping' is set, Stop() — which runs on this
            // same queue, so the check is race-free against its Cancel handler
            // releasing the queues — owns the drain and the teardown.
            if (!__atomic_load_n(&ivars->stopping, __ATOMIC_ACQUIRE)) {
                if (ivars->interruptQueue) ivars->interruptQueue->DispatchSync(^{});
                if (ivars->xlinkQueue)     ivars->xlinkQueue->DispatchSync(^{});
            }
            STLOG("SetPowerState: BAR access suspended for provider power-down");
        } else {
            __atomic_store_n(&ivars->providerPowerOff, false, __ATOMIC_SEQ_CST);
            if (HardwareReachable(ivars)) {
                STLOG("SetPowerState: endpoint present after power-on — BAR access resumed");
            } else {
                STLOG("SetPowerState: endpoint not answering after power-on — staying suspended "
                      "(the link watch resumes it, or the nub terminates)");
            }
            // dext 113: the first watch tick after power-on revalidates the link
            // (bus master, XLink data-path bits) and re-locks + restarts IO if the
            // tunnel was lost or the card shows a fault. A clean ordinary wake does
            // nothing audible.
            __atomic_store_n(&ivars->wakeFoundEndpointAbsent,
                             __atomic_load_n(&ivars->hwSuspended, __ATOMIC_ACQUIRE), __ATOMIC_RELEASE);
            __atomic_store_n(&ivars->linkNeedsRevalidation, true, __ATOMIC_RELEASE);
            ArmLinkWatch(ivars, kLinkWatchWakeNs);
        }
    }
    return SetPowerState(powerFlags, SUPERDISPATCH);
}

kern_return_t IMPL(SymphonyThunderbridge, NewUserClient)
{
    // H4: Intercept ONLY our custom vendor-command client type. AudioDriverKit's
    // own coreaudiod connection also arrives through NewUserClient (and may use
    // type 0, the standard convention); hijacking type 0 would hand coreaudiod a
    // SymphonyUserClient instead of the audio client → silently broken audio
    // registration. Everything that is not kSymphonyUserClientType must go to the
    // superclass (IOUserAudioDriver) so it can build its own client.
    if (type != kSymphonyUserClientType) {
        STLOG("NewUserClient: type 0x%x → super (AudioDriverKit)", type);
        return NewUserClient(type, userClient, SUPERDISPATCH);
    }

    // Create() takes the name of a PROPERTY KEY in this service's Info.plist
    // personality, not the class name. That key's dict supplies IOClass /
    // IOUserClass for the object being created. Passing the class name here
    // returns kIOReturnBadArgument (0xe00002c2).
    IOService *client = nullptr;
    kern_return_t ret = Create(this, "IOUserClientProperties", &client);
    if (ret != kIOReturnSuccess || !client) {
        STERR("NewUserClient: Create failed 0x%x", ret);
        return ret;
    }

    auto *uc = OSDynamicCast(SymphonyUserClient, client);
    if (!uc) {
        STERR("NewUserClient: cast failed");
        client->release();
        return kIOReturnError;
    }

    uc->SetDriver(this);
    *userClient = uc;
    STLOG("NewUserClient: SymphonyUserClient created for app");
    return kIOReturnSuccess;
}

// Card-mixer gain table: index = app fader byte (dB+48, 0..48 → -48..0 dB) →
// card coefficient (top-16 gain, /4 for 12 dB headroom). index 48 = 0 dB = unity
// (0x20000000); index 0 = -48 dB. Precomputed (dext has no pow()): matches
// ConvertMixerGaindB(dB) = ((int)(pow(10,dB/20)/4 * 0x8000) & 0xFFFF) << 16.
static const uint32_t kMixerGainTable[49] = {
    0x00210000, 0x00250000, 0x00290000, 0x002e0000, 0x00340000, 0x003a0000,
    0x00410000, 0x00490000, 0x00520000, 0x005c0000, 0x00670000, 0x00740000,
    0x00820000, 0x00920000, 0x00a30000, 0x00b70000, 0x00ce0000, 0x00e70000,
    0x01030000, 0x01230000, 0x01460000, 0x016e0000, 0x019b0000, 0x01cd0000,
    0x02050000, 0x02440000, 0x028b0000, 0x02da0000, 0x03330000, 0x03970000,
    0x04070000, 0x04850000, 0x05120000, 0x05b10000, 0x06630000, 0x072a0000,
    0x080a0000, 0x09050000, 0x0a1f0000, 0x0b5b0000, 0x0cbd0000, 0x0e4b0000,
    0x100a0000, 0x11ff0000, 0x14310000, 0x16a70000, 0x196b0000, 0x1c850000,
    0x20000000,
};



// Write one card-mixer stereo coefficient pair (L/R) for a level+pan+play state.
// lvl is a dB+48 byte (0..48); pan (pan+1)*64; play=false → muted (coeff 0).
static void WriteMixerCoefPair(IOPCIDevice *dev, uint8_t mi,
                               uint64_t offL, uint64_t offR,
                               int lvl, uint8_t pan, bool play)
{
    uint32_t cL, cR;
    if (!play) {
        cL = cR = kMixerMuteCoeff;
    } else {
        int lB = lvl + SymphonyMixerPanAttenuation(static_cast<uint8_t>(128 - pan));
        int rB = lvl + SymphonyMixerPanAttenuation(pan);
        if (lB < 0) lB = 0; else if (lB > 48) lB = 48;
        if (rB < 0) rB = 0; else if (rB > 48) rB = 48;
        cL = kMixerGainTable[lB];
        cR = kMixerGainTable[rB];
    }
    WriteRegister(dev, mi, offL, cL);
    WriteRegister(dev, mi, offR, cR);
}

// Recompute + write ALL card-mixer coefficients from the current app state.
// Handles solo globally (if anything is soloed, non-soloed sources are muted).
// The RETURN (SW-Return + Master combined) drives slots 128/129; the 32 fixed
// inputs drive slots 0..31. Called after any 0xB0-0xB3 mixer command on TB.
static void RecomputeCardMixer(SymphonyThunderbridge_IVars *iv,
                               IOPCIDevice *dev, uint8_t mi,
                               uint16_t mixerID)
{
    // Kept as a separate helper for the two physical stereo mixers. The
    // logical IDs exposed by Maestro are 1 and 2; each occupies two FPGA
    // coefficient banks (0/1 and 2/3 respectively).
    if (mixerID < 1 || mixerID > 2) return;
    ThunderboltMixerState &state = iv->mixer[mixerID - 1];
    const uint32_t physicalBase = ThunderboltMixerPhysicalBase(mixerID);
    bool anySolo = state.swReturnSoloed;
    for (int c = 0; c < 32 && !anySolo; c++)
        if (state.inputSoloed[c]) anySolo = true;

    bool rplay = !state.swReturnMuted && !state.masterMuted &&
                 (!anySolo || state.swReturnSoloed);
    // Return = SW-Return + Master (dB add), with independent stereo levels.
    // SW Return is a stereo route with separate left/right faders. Apply the
    // same unity-at-center balance law as the hardware input strips so the
    // pan control changes the return without introducing the old 5 dB center
    // drop. The side faders remain independent before the balance law.
    int swLeft = (int)state.swReturnLeftByte;
    int swRight = (int)state.swReturnRightByte;
    int returnLeft = swLeft + (int)state.masterLeftByte - 48
                   + SymphonyMixerPanAttenuation(
                         static_cast<uint8_t>(128 - state.swReturnPanByte));
    int returnRight = swRight + (int)state.masterRightByte - 48
                    + SymphonyMixerPanAttenuation(state.swReturnPanByte);
    uint32_t returnCoefL = kMixerMuteCoeff;
    uint32_t returnCoefR = kMixerMuteCoeff;
    if (rplay) {
        if (returnLeft < 0) returnLeft = 0; else if (returnLeft > 48) returnLeft = 48;
        if (returnRight < 0) returnRight = 0; else if (returnRight > 48) returnRight = 48;
        returnCoefL = kMixerGainTable[returnLeft];
        returnCoefR = kMixerGainTable[returnRight];
    }
    WriteRegister(dev, mi, MixerCoefOffset(physicalBase, 128), returnCoefL);
    WriteRegister(dev, mi, MixerCoefOffset(physicalBase + 1, 129), returnCoefR);

    // Fixed hardware inputs 0..31.
    for (int c = 0; c < 32; c++) {
        bool play = !state.inputMuted[c] &&
                    (!anySolo || state.inputSoloed[c]);
        WriteMixerCoefPair(dev, mi, MixerCoefOffset(physicalBase, c),
                           MixerCoefOffset(physicalBase + 1, c),
                           (int)state.inputByte[c], state.inputPanByte[c], play);
    }
}

// ── SendVendorCommand ───────────────────────────────────────────────────────
// Public wrapper around the static SendVendorRequest() for vendor commands.
// Called by SymphonyUserClient::ExternalMethod.

kern_return_t SymphonyThunderbridge::SendVendorCommand(
    uint8_t         command,
    uint32_t        value,
    const uint8_t  *payload,
    uint16_t        payloadLen)
{
    if (!ivars) {
        STERR("SendVendorCommand: no ivars");
        return kIOReturnNotReady;
    }

    // #2: The admission checks (shutdown + pciDevice validity) MUST run INSIDE the
    // serial XLink queue block, not before it. Doing them outside races Stop(): the
    // caller could pass a non-null pciDevice / txShutdown==false, get preempted while
    // Stop() drains the queue and closes+releases pciDevice, then resume and dispatch
    // through a stale device. Running the checks inside the serialized block means
    // this call is ordered against Stop()'s drain barrier — it either runs entirely
    // before teardown (valid device) or, if teardown began first, observes
    // txShutdown/stopping/!pciDevice and returns WITHOUT touching PCI. The XLink
    // queue is guaranteed live (released only in free(), #2). There is NO non-queue
    // fallback: if the queue does not exist, DMA/interrupt setup never completed and
    // no XLink TX is possible.
    IODispatchQueue *q = ivars->xlinkQueue;
    if (!q) {
        STERR("SendVendorCommand: no XLink queue (setup incomplete)");
        return kIOReturnNotReady;
    }

    __block kern_return_t result = kIOReturnNotReady;
    q->DispatchSync(^{
        if (!XLinkTxAdmissible(ivars)) {
            STERR("SendVendorCommand: TX shut down / stopping — not sending");
            result = kIOReturnNotReady;
            return;
        }

        // AEsR parity: select the host playback pair feeding a card mixer
        // software return. The original PCIe implementation advanced
        // PCI_OUT0 by two slots per source ID. This is a card-FPGA route, so it
        // must not be forwarded to the Symphony IO 0x31 command.
        if (command == kThunderboltMixerSoftwareReturnCommand &&
            payload && payloadLen == 1) {
            uint16_t mixerID = (uint16_t)(value >> 16);
            uint16_t element = (uint16_t)(value & 0xFFFF);
            uint8_t source = payload[0];
            if (element == 0 && mixerID >= 1 && mixerID <= 2 &&
                IsThunderboltSoftwareReturnSource(source)) {
                for (uint8_t side = 0; side < 2; side++) {
                    WriteRegister(
                        ivars->pciDevice, ivars->barMemoryIndex,
                        ThunderboltMixerReturnRegister(mixerID, side),
                        ThunderboltSoftwareReturnSlot(source, side) | kRoutingEnable);
                }
                ivars->mixerSwReturnSource[mixerID - 1] = source;
                STLOG("Card mixer: mixer %u SW Return source=%u (PCI_OUT%u/%u)",
                      mixerID, source,
                      ThunderboltSoftwareReturnSlot(source, 0),
                      ThunderboltSoftwareReturnSlot(source, 1));
                result = kIOReturnSuccess;
                return;
            }
            result = kIOReturnBadArgument;
            return;
        }

        // ── Thunderbolt mixer control → CARD FPGA coefficients (not the IO unit) ──
        // The app's mixer strips — SW Return (ch 1000), Master (ch 2000), and the 32
        // hardware-input strips (ch 0..31) — send 0xB0 fader / 0xB1 pan / 0xB2 solo /
        // 0xB3 mute. On Thunderbolt these drive the CARD FPGA mixer coefficients, NOT
        // the USB-only IO-unit mixer. Update the held state and recompute ALL coeffs
        // (RecomputeCardMixer handles solo globally + SW-Return/Master combine + pan).
        // Mixer 1 and Mixer 2 map to the card's physical mixer banks 0/1 and
        // 2/3 respectively. value=(mixerID<<16)|channel.
        if (command == kThunderboltCardOutputRouteCommand) {
            if (!payload || payloadLen != 3 ||
                payload[0] >= kThunderboltCardOutputChannels) {
                STERR("Card output route: bad request payload=%u ch=%u",
                      payloadLen, payload ? payload[0] : 0xFF);
                result = kIOReturnBadArgument;
                return;
            }
            const uint8_t channel = payload[0];
            const uint8_t slot    = payload[1];
            const bool    enabled = payload[2] != 0;
            WriteRegister(ivars->pciDevice, ivars->barMemoryIndex,
                          ThunderboltCardOutputRouteRegister(channel),
                          ThunderboltCardOutputRouteWord(slot, enabled));
            ivars->cardOutputRoute[channel]    = ThunderboltCardOutputRouteWord(slot, enabled);
            ivars->cardOutputRouteSet[channel] = true;
            STLOG("Card output route: XLink TX %u ← TDM slot %u (%s)",
                  channel, slot, enabled ? "enabled" : "disabled");
            result = kIOReturnSuccess;
            return;
        }

        {
            uint16_t ch = (uint16_t)(value & 0xFFFF);
            uint16_t mixerID = (uint16_t)(value >> 16);
            bool isMixerCmd = (command == kSIOCmd_MixerFaderLevel ||
                               command == kSIOCmd_MixerInputPan  ||
                               command == kSIOCmd_MixerInputSolo ||
                               command == kSIOCmd_MixerInputMute);
            bool isMixerCh = (ch == kMixerChSwReturn || ch == kMixerChMaster ||
                              ch == kMixerChSwReturnLeft || ch == kMixerChSwReturnRight ||
                              ch == kMixerChMasterLeft || ch == kMixerChMasterRight ||
                              ch < 32);
            if ((mixerID == 1 || mixerID == 2) && isMixerCmd && isMixerCh && payload && payloadLen >= 1) {
                ThunderboltMixerState &state = ivars->mixer[mixerID - 1];
                uint8_t p0 = payload[0];
                if (ch == kMixerChSwReturn) {
                    if      (command == kSIOCmd_MixerFaderLevel) {
                        state.swReturnLeftByte = (p0 > 48) ? 48 : p0;
                        state.swReturnRightByte = (p0 > 48) ? 48 : p0;
                    }
                    else if (command == kSIOCmd_MixerInputPan)
                        state.swReturnPanByte = (p0 > 128) ? 128 : p0;
                    else if (command == kSIOCmd_MixerInputSolo)  state.swReturnSoloed  = (p0 != 0);
                    else                                         state.swReturnMuted   = (p0 != 0);
                } else if (ch == kMixerChMaster) {
                    if      (command == kSIOCmd_MixerFaderLevel) {
                        state.masterLeftByte = (p0 > 48) ? 48 : p0;
                        state.masterRightByte = (p0 > 48) ? 48 : p0;
                    }
                    else if (command == kSIOCmd_MixerInputMute)  state.masterMuted = (p0 != 0);
                    // Master pan/solo not applicable.
                } else if (ch == kMixerChSwReturnLeft || ch == kMixerChSwReturnRight) {
                    if (command == kSIOCmd_MixerFaderLevel) {
                        uint8_t level = (p0 > 48) ? 48 : p0;
                        if (ch == kMixerChSwReturnLeft) state.swReturnLeftByte = level;
                        else state.swReturnRightByte = level;
                    }
                } else if (ch == kMixerChMasterLeft || ch == kMixerChMasterRight) {
                    if (command == kSIOCmd_MixerFaderLevel) {
                        uint8_t level = (p0 > 48) ? 48 : p0;
                        if (ch == kMixerChMasterLeft) state.masterLeftByte = level;
                        else state.masterRightByte = level;
                    }
                } else { // hardware-input strip 0..31
                    if      (command == kSIOCmd_MixerFaderLevel) state.inputByte[ch]    = (p0 > 48) ? 48 : p0;
                    else if (command == kSIOCmd_MixerInputPan)   state.inputPanByte[ch] = (p0 > 128) ? 128 : p0;
                    else if (command == kSIOCmd_MixerInputSolo)  state.inputSoloed[ch]  = (p0 != 0);
                    else                                         state.inputMuted[ch]   = (p0 != 0);
                }
                // Recompute only the selected physical stereo mixer; the two
                // logical banks must remain independent like the legacy PCIe
                // driver.
                ivars->mixerStateValid[mixerID - 1] = true;
                RecomputeCardMixer(ivars, ivars->pciDevice,
                                   ivars->barMemoryIndex, mixerID);
                STLOG("Card mixer: mixer=%u ch=%u cmd=0x%02x val=%u → recomputed",
                      mixerID, ch, command, p0);
                result = kIOReturnSuccess;
                return;
            }
        }

        bool ok = SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                    ivars->symphonyAddr, command, value,
                                    payload, payloadLen, ivars->runtimeTxSeq);
        if (!ok) {
            STERR("SendVendorCommand: failed cmd=0x%02x value=0x%08x payload=%u",
                  command, value, payloadLen);
            result = kIOReturnIOError;
            return;
        }
        // Legacy SymphonyIO::UpdateMainOutputChannelMode makes Line (mode 0)
        // an HP1 monitor target.  The HAL exposes one volume/mute control, so
        // remember that target only after the hardware mode write succeeds;
        // subsequent coalesced HAL writes then use 0x23/0x24 for HP1.
        if (command == kSIOCmd_SpeakerMode && payload && payloadLen >= 1) {
            const uint8_t target = payload[0] == 0 ? static_cast<uint8_t>(1)
                                                   : static_cast<uint8_t>(0);
            __atomic_store_n(&ivars->monitorOutputTarget, target, __ATOMIC_RELEASE);

            // The legacy driver publishes the newly selected monitor's
            // volume/mute immediately when Line/Stereo changes.  Keep the
            // single HAL control aligned with that target so the UI and the
            // next keyboard-volume event cannot carry the previous output's
            // value into the new destination.
            const uint8_t attenuation = target == 1
                ? __atomic_load_n(&ivars->hp1Attenuation, __ATOMIC_ACQUIRE)
                : __atomic_load_n(&ivars->speakerAttenuation, __ATOMIC_ACQUIRE);
            const bool muted = target == 1
                ? __atomic_load_n(&ivars->hp1Mute, __ATOMIC_ACQUIRE)
                : __atomic_load_n(&ivars->speakerMute, __ATOMIC_ACQUIRE);
            if (ivars->outputVolumeControl)
                ivars->outputVolumeControl->SetDecibelValue(-static_cast<float>(attenuation));
            if (ivars->outputMuteControl)
                ivars->outputMuteControl->SetControlValue(muted);
            STLOG("Monitor target: mode=%u target=%s", payload[0],
                  payload[0] == 0 ? "HP1" : "speakers");
        }
        result = kIOReturnSuccess;
    });
    return result;
}

// ── ReadVendorCommand ────────────────────────────────────────────────────────
// Serialized counterpart to SendVendorCommand. The XLink request/response
// transaction must share the same queue as writes so a readback cannot race a
// pending routing or mixer command.
kern_return_t SymphonyThunderbridge::ReadVendorCommand(
    uint8_t command, uint32_t value, uint8_t *outPayload, uint16_t responseLen)
{
    if (!ivars || !outPayload || responseLen == 0 || responseLen > 64)
        return kIOReturnBadArgument;
    IODispatchQueue *q = ivars->xlinkQueue;
    if (!q) return kIOReturnNotReady;

    __block kern_return_t result = kIOReturnNotReady;
    uint8_t responseBuffer[64] = {};
    uint8_t *response = responseBuffer;
    q->DispatchSync(^{
        if (!XLinkTxAdmissible(ivars)) {
            result = kIOReturnNotReady;
            return;
        }
        if (ReadVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                              ivars->symphonyAddr, command, value,
                              response, responseLen, ivars->runtimeTxSeq)) {
            result = kIOReturnSuccess;
        } else {
            result = kIOReturnIOError;
        }
    });
    if (result == kIOReturnSuccess)
        for (uint16_t i = 0; i < responseLen; i++) outPayload[i] = response[i];
    return result;
}

// ── ReadMeterBuffer ──────────────────────────────────────────────────────────
// Snapshot the card FPGA meter DMA buffer (256 words) into outWords. Plain read of
// the CPU-mapped, device-written buffer — no XLink, no queue. Guarded against
// teardown: `stopping` is set and meterDMAActive/meterWords are cleared before the
// buffer is released, so we bail early. (Hardening note: a torn read across the
// exact teardown window is possible; snapshot the pointer to bound it.)
kern_return_t SymphonyThunderbridge::ReadMeterBuffer(uint32_t *outWords)
{
    if (!ivars || !outWords) return kIOReturnBadArgument;
    if (__atomic_load_n(&ivars->stopping, __ATOMIC_ACQUIRE)) return kIOReturnNotReady;
    // Metering requires FPGA >= 20 (FIRMWARE_SUPPORTS_METERING). On older firmware the
    // meter DMA engine is absent, so meterDMAActive stays false and we report NotReady;
    // the app falls back to software input metering.
    if (!ivars->meterDMAActive) return kIOReturnNotReady;
    const volatile uint32_t *w = ivars->meterWords;
    if (!w) return kIOReturnNotReady;

    // The FPGA updates this buffer asynchronously. A single memcpy can cross
    // the timer-triggered DMA write and expose a mixed frame to the app. Take
    // two immediate snapshots and publish only a coherent one; the app keeps
    // its last valid levels when the DMA is mid-update.
    uint32_t first[kMeterBufferWords];
    uint32_t second[kMeterBufferWords];
    for (uint32_t attempt = 0; attempt < 3; ++attempt) {
        for (uint32_t i = 0; i < kMeterBufferWords; i++) first[i] = w[i];
        for (uint32_t i = 0; i < kMeterBufferWords; i++) second[i] = w[i];

        bool identical = true;
        for (uint32_t i = 0; i < kMeterBufferWords; i++) {
            if (first[i] != second[i]) {
                identical = false;
                break;
            }
        }
        if (identical) {
            for (uint32_t i = 0; i < kMeterBufferWords; i++) outWords[i] = second[i];
            return kIOReturnSuccess;
        }
    }

    STLOG("ReadMeterBuffer: DMA snapshot changed during three reads; holding last valid meter frame");
    return kIOReturnNotReady;
}

// ── ReadBoardTypes ───────────────────────────────────────────────────────────
// Hand back the OptionBoardType (0xA1) result captured for each slot during Start().
// No XLink traffic: re-reading here would put a blocking request/response transaction
// on the caller's queue for a value that cannot change while the unit is powered.
kern_return_t SymphonyThunderbridge::ReadBoardTypes(uint8_t *outTypes, uint8_t *outValid)
{
    if (!ivars || !outTypes || !outValid) return kIOReturnBadArgument;
    for (uint32_t b = 0; b < 2; b++) {
        outTypes[b] = ivars->optionBoardType[b];
        outValid[b] = ivars->optionBoardTypeValid[b] ? 1 : 0;
    }
    return kIOReturnSuccess;
}

// ── ReadTimingHealth ────────────────────────────────────────────────────────
// Read-only diagnostic snapshot for the controlled timing-profile study.
kern_return_t SymphonyThunderbridge::ReadTimingHealth(uint32_t *outWords)
{
    if (!ivars || !outWords) return kIOReturnBadArgument;
    if (__atomic_load_n(&ivars->stopping, __ATOMIC_ACQUIRE) || !ivars->pciDevice)
        return kIOReturnNotReady;
    // dext 112: the first thing ReadVendorRequest does is LOAD kRegXLink1RX.
    // Prove the endpoint is there in config space before any BAR access
    // (this probe is what panicked a sleeping Mac whose unit lost power).
    if (!HardwareReachable(ivars)) return kIOReturnNotReady;

    // A PCI service and its DMA/register window can remain alive after the
    // downstream Symphony loses power. Make this selector a real endpoint
    // health read by issuing the original read-only ClockRateAndLock command
    // on the same serialized XLink queue used by all vendor traffic. This
    // prevents the app from promoting stale timing registers or meter memory
    // to a live device state. The read is bounded by ReadVendorRequest's
    // existing 200 ms timeout and is outside the realtime audio path.
    __block bool live = false;
    __block uint32_t clkCtrl = 0, intStatus = 0, xlinkStatus = 0, gcsr = 0;
    IODispatchQueue *q = ivars->xlinkQueue;
    if (!q) return kIOReturnNotReady;
    q->DispatchSync(^{
        if (!XLinkTxAdmissible(ivars)) {
            return;
        }
        uint8_t clockData[5] = {};
        live = ReadVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                 ivars->symphonyAddr, kSIOCmd_ClockRateAndLock,
                                 0, clockData, sizeof(clockData),
                                 ivars->runtimeTxSeq);
        if (!live) return;
        // dext 112 (review item 3): the register snapshot is BAR loads too. Take
        // it HERE, on the queue the SetPowerState(Off) barrier drains, never on
        // the caller's thread after the block has returned.
        ReadRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegClkCtrl, &clkCtrl);
        ReadRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegIntStatus, &intStatus);
        ReadRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegXLink1Status, &xlinkStatus);
        ReadRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegGCSR, &gcsr);
    });
    if (!live) {
        // The Symphony did not answer. If the card can see its clock again
        // after it was gone, it was power-cycled with the cable in: run the
        // legacy BusInit recovery in place so the next probe can succeed.
        ivars->consecutiveProbeFailures++;
        MaybeRecoverSymphonyLink(ivars, this);
        return kIOReturnIOError;
    }
    ivars->consecutiveProbeFailures = 0;
    ivars->linkFaultSeen = false;

    if (ivars->linkRecoveryNeedsIORestart) {
        // First live answer after an in-place recovery. Re-anchor Core Audio
        // by requesting a configuration change (host: StopIO → Perform… →
        // StartIO → our StartDevice resets the zero-timestamp anchor). Issued
        // here, on the user-client thread, never from the xlinkQueue block.
        ivars->linkRecoveryNeedsIORestart = false;
        if (ivars->audioDevice) {
            // Requested even when no IO is running: the host re-evaluates the
            // device, and clients that were refused while the link was down
            // (StartDevice → kIOReturnNotReady) see a device configuration
            // change rather than silence.
            const bool ioRunning = __atomic_load_n(&ivars->ioRunning, __ATOMIC_ACQUIRE);
            kern_return_t rc = ivars->audioDevice->RequestDeviceConfigurationChange(
                kSymphonyConfigChangeLinkRecovered, nullptr);
            STLOG("Link recovery: requested Core Audio configuration change to re-anchor timestamps "
                  "(ioRunning=%u, 0x%x)", ioRunning ? 1u : 0u, rc);
        }
    }

    // The vendor response can remain buffered in the bridge after the
    // downstream unit powers off. Reject that stale response when the live
    // XLink state says the data link is currently down or slipping. These are
    // current-state bits, unlike the sticky error bits above, so a prior
    // transient does not permanently poison a healthy connection.
    if (xlinkStatus & (kXLinkDataDownCurrent | kXLinkDataSlipCurrent)) {
        STLOG("ReadTimingHealth: downstream XLink not live (status=0x%08x)", xlinkStatus);
        return kIOReturnIOError;
    }

    const double rate = ivars->audioDevice ? ivars->audioDevice->GetSampleRate() : 0.0;
    const TimingProfile profile = TimingProfileForRate(rate);
    const uint32_t frameReadback =
        ((clkCtrl & kClkCtrl_FrameMask) >> kClkCtrl_FrameShift) + 1;

    outWords[0] = 0;
    outWords[1] = clkCtrl;
    outWords[2] = intStatus;
    outWords[3] = xlinkStatus;
    outWords[4] = gcsr;
    outWords[5] = frameReadback;
    outWords[6] = profile.frameSize;
    outWords[7] = rate > 0.0 ? (uint32_t)(rate + 0.5) : 0;
    outWords[8] = ivars->audioDevice ? ivars->audioDevice->GetInputLatency() : 0;
    outWords[9] = ivars->audioDevice ? ivars->audioDevice->GetOutputLatency() : 0;
    outWords[10] = ivars->audioDevice ? ivars->audioDevice->GetInputSafetyOffset() : 0;
    outWords[11] = ivars->audioDevice ? ivars->audioDevice->GetOutputSafetyOffset() : 0;
    return kIOReturnSuccess;
}

// ── RequestClockSource ───────────────────────────────────────────────────────
// Push a clock-source selection (1..5) to the Symphony IO via ClockMode (0x50).
// Called by SymphonyClockSelectorControl::HandleChangeSelectedValues on the
// control's own work queue (neither the IRQ nor the XLink queue). Reuses the
// generation+CAS coalescing atomics and dispatches ONE drain block on the serial
// xlinkQueue — SendVendorRequest busy-waits per MSG_BYTE frame (>1s worst case),
// so it must never run on the caller's queue. A burst of selections collapses to
// at most one in-flight plus one pending write.
kern_return_t SymphonyThunderbridge::RequestClockSource(uint32_t source)
{
    if (!ivars) {
        STERR("RequestClockSource: no ivars");
        return kIOReturnNotReady;
    }
    IODispatchQueue *txq = ivars->xlinkQueue;
    if (!txq) {
        STERR("RequestClockSource: no XLink queue (setup incomplete)");
        return kIOReturnNotReady;
    }
    if (__atomic_load_n(&ivars->txShutdown, __ATOMIC_ACQUIRE)) {
        STERR("RequestClockSource: TX shut down — not sending");
        return kIOReturnNotReady;
    }

    __atomic_store_n(&ivars->pendingClockSource, source, __ATOMIC_RELAXED);
    __atomic_fetch_add(&ivars->pendingClockGen, 1, __ATOMIC_RELEASE);
    bool expected = false;
    if (__atomic_compare_exchange_n(&ivars->clockTxScheduled, &expected, true,
                                    false, __ATOMIC_ACQ_REL, __ATOMIC_RELAXED)) {
        txq->DispatchAsync(^{
            for (;;) {
                uint32_t gen = __atomic_load_n(&ivars->pendingClockGen, __ATOMIC_ACQUIRE);
                uint32_t src = __atomic_load_n(&ivars->pendingClockSource, __ATOMIC_RELAXED);
                if (XLinkTxAdmissible(ivars)) {
                    // ClockMode 0x50: [source, master, loopSync, boardClockSrc].
                    // LoopSync(3) ⇒ slave + loopSync on; all others ⇒ master, loopSync
                    // off. boardClockSrc left 0. (SymphonyIOVendorSpecific.h:222-247;
                    // boot sends {1,1,0,0} = Internal, Master.)
                    uint8_t clockData[4] = {
                        (uint8_t)src,
                        (uint8_t)(src == 3 ? 0 : 1),
                        (uint8_t)(src == 3 ? 1 : 0),
                        0
                    };
                    SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                      ivars->symphonyAddr, kSIOCmd_ClockMode, 0,
                                      clockData, sizeof(clockData), ivars->runtimeTxSeq);
                }
                __atomic_store_n(&ivars->clockTxScheduled, false, __ATOMIC_RELEASE);
                // Re-arm only if a newer selection arrived AND no producer beat us to it.
                if (__atomic_load_n(&ivars->pendingClockGen, __ATOMIC_ACQUIRE) == gen)
                    break;
                bool exp2 = false;
                if (!__atomic_compare_exchange_n(&ivars->clockTxScheduled, &exp2, true,
                                                 false, __ATOMIC_ACQ_REL, __ATOMIC_RELAXED))
                    break;
            }
        });
    }
    STLOG("RequestClockSource: source=%u [coalesced]", source);
    return kIOReturnSuccess;
}

// ── RequestOpticalFormat — per-optical-board push sender ─────────────────────
// Push an optical output format (0=ADAT/SMUX, 1=S/PDIF) for a 0-based option
// board to the Symphony IO via OpticalFormat (0x34). Called by
// SymphonyOpticalControl::HandleChangeSelectedValues on the control's own work
// queue. Mirrors RequestClockSource exactly, but keeps an independent coalescing
// lane per board (parallel arrays indexed by board). SendVendorRequest busy-waits
// per MSG_BYTE frame, so it must never run on the caller's queue — only inside the
// drain block on the serial xlinkQueue.
kern_return_t SymphonyThunderbridge::RequestOpticalFormat(uint32_t board, uint32_t fmt)
{
    if (!ivars || board >= 2) return kIOReturnBadArgument;
    IODispatchQueue *txq = ivars->xlinkQueue;
    if (!txq) {
        STERR("RequestOpticalFormat: no XLink queue (setup incomplete)");
        return kIOReturnNotReady;
    }
    if (__atomic_load_n(&ivars->txShutdown, __ATOMIC_ACQUIRE)) {
        STERR("RequestOpticalFormat: TX shut down — not sending");
        return kIOReturnNotReady;
    }
    const uint32_t b = board;
    __atomic_store_n(&ivars->pendingOpticalFmt[b], (uint8_t)(fmt ? 1 : 0), __ATOMIC_RELAXED);
    __atomic_fetch_add(&ivars->pendingOpticalGen[b], 1, __ATOMIC_RELEASE);
    bool expected = false;
    if (__atomic_compare_exchange_n(&ivars->opticalTxScheduled[b], &expected, true,
                                    false, __ATOMIC_ACQ_REL, __ATOMIC_RELAXED)) {
        txq->DispatchAsync(^{
            for (;;) {
                uint32_t gen = __atomic_load_n(&ivars->pendingOpticalGen[b], __ATOMIC_ACQUIRE);
                uint8_t  val = __atomic_load_n(&ivars->pendingOpticalFmt[b], __ATOMIC_RELAXED);
                if (XLinkTxAdmissible(ivars)) {
                    uint8_t pData = val;   // 0=ADAT/SMUX, 1=S/PDIF
                    SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                      ivars->symphonyAddr, kSIOCmd_OpticalFormat,
                                      b /*nValue = 0-based board index*/,
                                      &pData, 1, ivars->runtimeTxSeq);
                }
                __atomic_store_n(&ivars->opticalTxScheduled[b], false, __ATOMIC_RELEASE);
                if (__atomic_load_n(&ivars->pendingOpticalGen[b], __ATOMIC_ACQUIRE) == gen)
                    break;
                bool exp2 = false;
                if (!__atomic_compare_exchange_n(&ivars->opticalTxScheduled[b], &exp2, true,
                                                 false, __ATOMIC_ACQ_REL, __ATOMIC_RELAXED))
                    break;
            }
        });
    }
    STLOG("RequestOpticalFormat: board=%u fmt=%u [coalesced]", b, fmt ? 1 : 0);
    return kIOReturnSuccess;
}

// ── RequestPhantom / RequestMicGain — per-mic-channel push senders ───────────
// Mirror RequestClockSource exactly, but keep an independent coalescing lane per
// channel (parallel arrays indexed by ch). Each lane dispatches its own drain on
// the shared serial xlinkQueue, so channels never lose each other's latest value
// and all XLink TX still serializes (MSG_BYTE frames never interleave). Never
// call SendVendorRequest from the control/IRQ queue — only from the drain block.

kern_return_t SymphonyThunderbridge::RequestPhantom(uint32_t channel, bool on)
{
    if (!ivars || channel >= kMicPre8NumChannels) return kIOReturnBadArgument;
    IODispatchQueue *txq = ivars->xlinkQueue;
    if (!txq) {
        STERR("RequestPhantom: no XLink queue (setup incomplete)");
        return kIOReturnNotReady;
    }
    if (__atomic_load_n(&ivars->txShutdown, __ATOMIC_ACQUIRE)) {
        STERR("RequestPhantom: TX shut down — not sending");
        return kIOReturnNotReady;
    }
    const uint32_t ch = channel;
    __atomic_store_n(&ivars->pendingPhantom[ch], on ? 1 : 0, __ATOMIC_RELAXED);
    __atomic_fetch_add(&ivars->pendingPhantomGen[ch], 1, __ATOMIC_RELEASE);
    bool expected = false;
    if (__atomic_compare_exchange_n(&ivars->phantomTxScheduled[ch], &expected, true,
                                    false, __ATOMIC_ACQ_REL, __ATOMIC_RELAXED)) {
        txq->DispatchAsync(^{
            for (;;) {
                uint32_t gen = __atomic_load_n(&ivars->pendingPhantomGen[ch], __ATOMIC_ACQUIRE);
                uint8_t  val = __atomic_load_n(&ivars->pendingPhantom[ch], __ATOMIC_RELAXED);
                if (XLinkTxAdmissible(ivars)) {
                    uint8_t pData = val;   // 1=on, 0=off
                    SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                      ivars->symphonyAddr, kSIOCmd_PhantomPower,
                                      ch /*nValue = 0-based channel*/,
                                      &pData, 1, ivars->runtimeTxSeq);
                }
                __atomic_store_n(&ivars->phantomTxScheduled[ch], false, __ATOMIC_RELEASE);
                if (__atomic_load_n(&ivars->pendingPhantomGen[ch], __ATOMIC_ACQUIRE) == gen)
                    break;
                bool exp2 = false;
                if (!__atomic_compare_exchange_n(&ivars->phantomTxScheduled[ch], &exp2, true,
                                                 false, __ATOMIC_ACQ_REL, __ATOMIC_RELAXED))
                    break;
            }
        });
    }
    STLOG("RequestPhantom: ch=%u on=%d [coalesced]", ch, on ? 1 : 0);
    return kIOReturnSuccess;
}

kern_return_t SymphonyThunderbridge::RequestMicGain(uint32_t channel, float decibels)
{
    if (!ivars || channel >= kMicPre8NumChannels) return kIOReturnBadArgument;
    IODispatchQueue *txq = ivars->xlinkQueue;
    if (!txq) {
        STERR("RequestMicGain: no XLink queue (setup incomplete)");
        return kIOReturnNotReady;
    }
    if (__atomic_load_n(&ivars->txShutdown, __ATOMIC_ACQUIRE)) {
        STERR("RequestMicGain: TX shut down — not sending");
        return kIOReturnNotReady;
    }
    const uint32_t ch = channel;
    // Clamp + quantize to the MicPre8 0..85 dB byte range before publishing.
    float clamped = decibels;
    if (clamped < kMicGainMinDb) clamped = kMicGainMinDb;
    if (clamped > kMicGainMaxDb) clamped = kMicGainMaxDb;
    uint8_t gainByte = (uint8_t)(clamped + 0.5f);   // round to nearest dB
    __atomic_store_n(&ivars->pendingMicGain[ch], gainByte, __ATOMIC_RELAXED);
    __atomic_fetch_add(&ivars->pendingMicGainGen[ch], 1, __ATOMIC_RELEASE);
    bool expected = false;
    if (__atomic_compare_exchange_n(&ivars->micGainTxScheduled[ch], &expected, true,
                                    false, __ATOMIC_ACQ_REL, __ATOMIC_RELAXED)) {
        txq->DispatchAsync(^{
            for (;;) {
                uint32_t gen = __atomic_load_n(&ivars->pendingMicGainGen[ch], __ATOMIC_ACQUIRE);
                uint8_t  val = __atomic_load_n(&ivars->pendingMicGain[ch], __ATOMIC_RELAXED);
                if (XLinkTxAdmissible(ivars)) {
                    uint8_t pData = val;   // gain 0..85
                    SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                      ivars->symphonyAddr, kSIOCmd_MicGain,
                                      ch /*nValue = 0-based channel*/,
                                      &pData, 1, ivars->runtimeTxSeq);
                }
                __atomic_store_n(&ivars->micGainTxScheduled[ch], false, __ATOMIC_RELEASE);
                if (__atomic_load_n(&ivars->pendingMicGainGen[ch], __ATOMIC_ACQUIRE) == gen)
                    break;
                bool exp2 = false;
                if (!__atomic_compare_exchange_n(&ivars->micGainTxScheduled[ch], &exp2, true,
                                                 false, __ATOMIC_ACQ_REL, __ATOMIC_RELAXED))
                    break;
            }
        });
    }
    STLOG("RequestMicGain: ch=%u gain=%u [coalesced]", ch, gainByte);
    return kIOReturnSuccess;
}
