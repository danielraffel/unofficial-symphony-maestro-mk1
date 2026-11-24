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
#include "SymphonyPhaseControl.h"
#include "SymphonyHighPassControl.h"
#include "SymphonyInputTypeControl.h"
#include "SymphonyOpticalControl.h"
#include "SymphonyPortSourceControl.h"
#include "SymphonyThunderbridgeShared.h"

// FPGA register map
#include "Sym64Registers.h"
#include "SymphonyTimingProfile.h"
#include "SymphonyMixerCoef.h"
#include "SymphonyChannelNames.h"
#include "SymphonyCardMixerRouting.h"
#include "SymphonyOptionBoard.h"
#include "SymphonyRetire.h"
#include "SymphonyConverters.h"

// ── Logging ─────────────────────────────────────────────────────────────────
// DriverKit only provides os_log with OS_LOG_TYPE_DEFAULT — no os_log_error.

#define LOG_PREFIX "SymphonyTB"
// Text arguments are %{public}s: os_log hides plain %s as <private>, which made
// every command result ("OK"/"FAILED") unreadable in a tester's diagnostics.
// Anything derived from a serial number stays %{private}s.
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
    uint8_t inputByte[64];
    uint8_t inputPanByte[64];
    bool inputMuted[64];
    bool inputSoloed[64];
};

// One coalescing lane per physical MicPre channel for each DAW-facing control
// (polarity, high-pass, input type), like the phantom and gain lanes: a burst
// of changes sends only the latest value, and the host channel it came from is
// kept so a route change before the send drops it.
struct MicPreLane {
    uint8_t  value;
    uint8_t  host;
    uint32_t gen;
    bool     scheduled;
};
enum : uint32_t { kMicPreLanePhase = 0, kMicPreLaneHighPass = 1, kMicPreLaneType = 2 };

// The clock used for the HAL Mic arm delay (finding 9). The host test injects
// its own so it can step past the delay without sleeping.
#ifndef SYMPHONY_STARTUP_OUTPUT_HOLD_NS
// How long a fresh instance keeps the card's outputs muted while Core Audio
// restores its saved mute and volume (0 = no hold; the test harness sets it).
#define SYMPHONY_STARTUP_OUTPUT_HOLD_NS() 3000000000ull
#endif
#ifndef SYMPHONY_MICPRE_NOW_NS
#define SYMPHONY_MICPRE_NOW_NS() clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
#endif

// VBus (dext 143): one generation of the loopback: the two VBus stream
// buffers of one size, their mappings, and what the IO handler needs. A
// generation's channels, buffers and pointers never change after it is made;
// the IO handler reaches it through one atomic pointer load
// (SymphonyThunderbridge_IVars::vbusIO, null while VBus is off), so a callback
// always works on one consistent set. [validStart, validEnd) is the span of
// sample times the host has written to the VBus output and that is still in
// the ring; the IO thread alone reads and writes it while IO runs.
struct SymphonyVBusIO {
    uint32_t  channels;
    uint8_t  *out;           // kNumSampleFrames frames of `channels` Float32 samples
    uint8_t  *in;
    uint64_t  validStart;
    uint64_t  validEnd;
    IOBufferMemoryDescriptor *outBuffer;   // exactly one ring of the format
    IOBufferMemoryDescriptor *inBuffer;
    IOMemoryMap              *outMap;
    IOMemoryMap              *inMap;
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
    // Set (CAS) by RetireForUpgrade so a repeated request does not call
    // Terminate twice. Atomic.
    bool                       retireRequested;

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

    // Data source selector controls (the "Source" menu: kSymphonyPortSourceName32 / 64)
    // Data source selectors removed — single-port device doesn't need them.
    // Re-add when Port 2 (dual Symphony IO) is implemented.
    float     lastVolumeDb;
    bool      lastMuteState;
    // Which output Core Audio's single output volume/mute control moves: the
    // app's "Audio Output" choice (kSymphonyMonitorOutputSpeakers/HP1/HP2,
    // selector 15), Speakers until the app says otherwise, as the original
    // (og_source/symphonymk1/ext/maestrolink/Software/SymphonyIO.cpp:131).
    // Nothing changes it but the app: with Speakers chosen and the speaker
    // mode Off (Line) the control does nothing (SymphonyIO.cpp:2345-2351).
    // (The original changed its own choice to Headphone 1 when the user set
    // the mode to Off, SymphonyIO.cpp:6142-6168, and left it there afterwards;
    // Maestro does the same and sends the choice. Builds up to 141 followed
    // the mode both ways here.)
    uint8_t   monitorOutputTarget;
    bool      lineMode;               // unit A's speaker mode is Off (Line)
    // The app has chosen a unit's output in this driver instance (selector
    // 15). Until it has, the output follows the unit's speaker mode as builds
    // up to 141 did, and as the original's state is after the user set Line
    // (SymphonyIO.cpp:6142-6168): Headphone 1 in Line mode, else the speakers.
    // So the keys keep working in Line mode before Maestro runs, and under a
    // Maestro that does not know selector 15.
    bool      monitorOutputChosen[2];
    // Unit A's speaker, HP1 and HP2 levels and mutes below were read from the
    // unit, or set, in this driver instance. False after a Start() that found
    // no Symphony I/O: they are then fallbacks, never sent or shown as levels.
    bool      monitorLevelsKnown;
    // Unit A's speaker level and mute are known: read outside Line, or set in
    // this driver instance. In Line the unit answers a speaker read with 0
    // (firmware: the level is kept aside until Line ends) and ignores a level
    // written there, so a reading taken in Line is never the speakers' level.
    bool      speakerLevelKnown;
    // Per-monitor state behind the single Core Audio volume/mute control.
    uint8_t   speakerAttenuation;
    bool      speakerMute;
    uint8_t   hp1Attenuation;
    bool      hp1Mute;
    uint8_t   hp2Attenuation;
    bool      hp2Mute;
    // Which configured Symphony I/O owns the single HAL volume/mute control.
    // Unit A is the default and is the only possible target at 32 channels.
    bool      monitorDeviceB;
    uint8_t   unitBMonitorOutputTarget;
    bool      unitBLineMode;
    uint8_t   unitBSpeakerAttenuation;
    bool      unitBSpeakerMute;
    uint8_t   unitBHP1Attenuation;
    bool      unitBHP1Mute;
    uint8_t   unitBHP2Attenuation;
    bool      unitBHP2Mute;
    bool      monitorKnobChanging[2];
    uint8_t   monitorMuteAll[2];

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
    // which coalesce + async-send PhantomPower(0xC6)/MicGain(0xC3)/InstrumentGain(0xC4) on the serial
    // xlinkQueue using the SAME generation+CAS discipline as volume/mute/clock.
    // Coalescing state is parallel arrays indexed by channel — one independent
    // lane per channel — so each channel's latest value is never lost and every
    // lane's drain block serializes on the shared xlinkQueue (MSG_BYTE frames
    // never interleave; the invariant at the top of this struct holds per lane).
    uint32_t  numMicChannels;                       // 0 unless MicPre8 detected
    // Physical A0..7, B0..7; host-only OFF receipts. These are volatile dext
    // memory: an OFF made while Maestro is closed is lost if the dext restarts
    // before the app reads it. That is the remaining fail-safe gap.
    uint64_t halPhantomOff[16];
    SymphonyPhantomControl *phantomControl[8];      // per-channel phantom ('phan')
    SymphonyMicGainControl *micGainControl[8];      // per-channel gain ('vlme'/Input)
    SymphonyPhaseControl *phaseControl[8];
    SymphonyHighPassControl *highPassControl[8];
    SymphonyInputTypeControl *inputTypeControl[8];
    uint8_t   pendingPhantom[2][8];   uint32_t pendingPhantomGen[2][8]; bool phantomTxScheduled[2][8];
    uint8_t   pendingPhantomHost[2][8]; bool pendingPhantomTypeKnown[2][8]; bool pendingPhantomInstrument[2][8];
    uint8_t   pendingMicGain[2][2][8]; uint32_t pendingMicGainGen[2][2][8]; bool micGainTxScheduled[2][2][8];
    uint8_t   pendingMicGainHost[2][2][8]; bool pendingMicGainTypeKnown[2][2][8]; bool pendingMicGainInstrument[2][2][8];
    bool preampRoutingEdited;
    bool unitBMicPreTypeKnown[8];
    bool unitBMicPreInstrument[8];
    uint8_t unitBMicPreGain[2][8];
    bool unitBMicPreGainKnown[2][8];
    uint8_t   micPreGain[2][8];       // successfully sent gains, owned by xlinkQueue
    bool      micPreGainKnown[2][8];
    bool      micPreInstrument[8];    // atomic type for unit A's HAL controls
    bool      micPreTypeKnown[8];     // a failed read must not guess Mic
    bool      micPreMic[8];           // known type is Mic (3): HAL phantom ON needs it
    bool      micPrePhase[2][8];
    bool      micPreHighPass[2][8];
    uint8_t   micPreType[2][8];
    // Start-up reads (0xC5/0xCA, as the original's RecallSettingsFromHardware,
    // og_source/maestrolink/Software/SymphonyIOBoard_MicPre8ch.cpp:2205-2223)
    // or a value that was sent since.
    bool      micPrePhaseKnown[2][8];
    bool      micPreHighPassKnown[2][8];
    // The trim Maestro last sent with 0x20 for a line type, in 0.1 dB, so a
    // HAL type change can send it in the new type's encoding (the original
    // sent its stored per-channel trim, AnalogIn_SymphonyIO_Stream.cpp:383-393).
    int16_t   micPreTrimTenths[2][8];
    bool      micPreTrimKnown[2][8];
    // Insert assignment table (0xC8: nValue = insert, payload = channel mask),
    // from Maestro's writes or a read when it is needed.
    uint8_t   micPreInsertMask[2][8];
    bool      micPreInsertMaskKnown[2][8];
    // When the HAL itself put a channel in Mic (0 = Mic came from the unit's
    // 0x60 read or from Maestro). HAL phantom ON waits kHALMicArmNs after it.
    uint64_t  halMicTypeStamp[2][8];
    // HAL type, polarity, high-pass and phantom ON are refused until this
    // time (SYMPHONY_MICPRE_NOW_NS), see kHALMicPreSettleNs.
    uint64_t  halMicPreSettleUntil;
    // Counts the times the settle window was armed, and the count the last
    // completed pass over the volume and mute controls began under. While
    // they differ no pass has looked at the controls since the window was
    // armed: the next one takes their values for coreaudiod's restore however
    // late it runs (interrupts stop while the hardware is suspended, and on
    // the PCIe card until IO starts, so the window can lapse unseen). Atomic.
    uint32_t  monitorSettleArms;
    uint32_t  monitorPolledArm;
    MicPreLane micPreLane[3][2][8];
    // Host-originated edits per physical channel (A0..7, B0..7), for the app:
    // a stamp that moves on each HAL edit and the fields it set (kMicPreEdit*).
    // A Maestro write of a field clears that field's bit; the stamp stays.
    uint64_t  halMicPreEditStamp[16];
    uint32_t  halMicPreEdit[16];
    uint8_t   inputTypeChoices[8];    // entries the type selector offers (4 or 5)
    bool      unitBMicPreMic[8];
    // Separate pending lanes bind each value to its stage across a type switch.
    // Evidence: og_source/maestrolink/Software/SymphonyIOBoard_MicPre8ch.cpp:186-330.

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

    // C2: bounded control work. The IRQ enqueues at most one HAL sample;
    // xlinkQueue owns monitor values and writes. A publication invalidates
    // samples queued for the old target. New HUD changes during a send are
    // sampled on the next IRQ, without blocking the audio interrupt queue.
    bool      monitorPollScheduled;
    uint32_t  monitorGeneration;
    // A fresh driver instance keeps the card's output path muted while
    // Core Audio restores its published monitor controls. Input remains live.
    // This is only armed by Start(), never by in-place link recovery.
    bool      startupOutputMuteHeld;
    uint64_t  startupOutputMuteDeadlineNs;
    // dext 151: Start() programs 44.1 kHz and Core Audio puts back the
    // device's saved rate about a second and a half later. The output gate
    // waits for that. dext 152: it opens a short grace after the hardware
    // runs at Core Audio's rate (kStartupRateGraceNs, time for Core Audio's
    // restored mute to land first), or at the deadline when no rate
    // settles. startupReleaseAtNs is 0 until the rate settles. Armed with
    // the gate, by Start() only; set on any thread, read on xlinkQueue.
    bool      startupRatePending;
    uint64_t  startupReleaseAtNs;
    double    lastSampleRate;  // Last SUCCESSFULLY programmed hardware sample rate
    uint32_t  namingSampleRate; // Hz the channel names follow: Core Audio's nominal rate
                               // (SymphonyNamingRateHz), updated on every HandleChangeSampleRate
    double    idleRateFailed;  // dext 141: the rate an idle rate sync last failed at (0 = none);
                               // not tried again with no IO start until the rate changes
    double    xlinkRate;       // Rate actually broadcast to the XLink units (updated on
                               // every successful SetSampleRate broadcast, even if the
                               // subsequent lock/verify then failed). The DDS-rollback
                               // reference on a failed rate change — NOT lastSampleRate,
                               // which lags after a post-broadcast failure (Codex round 4).
    uint8_t   runtimeTxSeq;   // XLink message sequence for runtime commands
    uint8_t   runtimeTxSeq2;  // independent sequence for unit B on XLink2
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
    uint32_t  unitProbeWord;           // dext 121: identification of a non-Symphony unit, 0 if not probed
    // Volume keys on a cable of converters only (no Symphony I/O). The converters
    // have no monitor outputs, so the single Core Audio volume/mute control trims
    // card mixer 1 instead of sending Symphony speaker commands. See
    // ClassifyVolumeTarget. All four are touched only in Start() before the
    // controls exist or on xlinkQueue; converterVolumeKeys is atomic.
    bool      symphonyAnsweredSinceStart; // latch: a Symphony vendor read succeeded once
    bool      converterVolumeKeys;        // keys drive the mixer-1 trim, not 0x26/0x27
    uint8_t   converterTrimAtten;         // 0..64 dB, from the volume control
    bool      converterTrimMuted;         // from the mute control
    // The app chose "None" for the keys on converters (selector 15, output 0):
    // the trim stays at 0 dB, unmuted, and the controls do nothing.
    bool      converterKeysOff;
    // dext 131: the older XLink converters, as Apogee's driver ran them
    // (SymphonyConverters.h). Written on xlinkQueue (or in Start() before the
    // queue runs); convConfig, convFlags and convRecoveryPending are atomic, the
    // rest are read by ReadConverterState as a best-effort snapshot.
    IOLock   *convLock;                // guards convPort1/convUnitCount/convUnit for readers off xlinkQueue
    bool      convPort1;               // port 1 positively identified as converters (atomic)
    uint32_t  convUnitCount[2];        // units per port (port 2 from the port-2 probe)
    uint32_t  convUnit[2][4];          // kSymphonyConvUnit* words, nearest first
    uint32_t  convPhase[2];            // last WCLK_PHASE byte per unit
    uint32_t  convConfig;              // atomic; SymphonyConverterConfigInput.config
    uint32_t  convFlags;               // atomic; kSymphonyConv*
    uint32_t  convHealthTicks;
    uint32_t  convPhaseErrors;
    uint32_t  convUnlocks;
    uint32_t  convRecoveries;
    uint32_t  convLatencyIn;           // 0 = the Symphony I/O table applies
    uint32_t  convLatencyOut;
    uint32_t  convHostIn;
    uint32_t  convHostOut;
    uint32_t  convAuthState;           // challenge generator state (fixed seed, like random())
    bool      convRecoveryPending;     // atomic; a recovery waits for a controlled restart
    bool      port2On;                 // xlinkQueue; GCSR2 has port 2 enabled (SetPort2Enabled)
    // The user's converter routes (0xB5/0xB6 with converters), kept on top of
    // the default placement and replayed by ApplyConverterRouting. Cleared by
    // 0xB7 and whenever the chain of units changes. xlinkQueue only.
    uint32_t  convOutRoute[64];        // by XLink TX slot: register word
    uint32_t  convInRoute[64];         // by host input: register word
    uint64_t  convOutRouteSet;         // bit n: convOutRoute[n] chosen by the user
    uint64_t  convInRouteSet;
    uint32_t  convRouteChain[2][4];    // the units the routes were chosen for
    bool      convRateUnlocked;        // xlinkQueue; bring-up rate set did not lock (units muted)
    uint64_t  convLastRecoveryNs;      // watch-local
    uint32_t  convFailedRecoveries;    // watch-local; recoveries since the last healthy check
    uint32_t  lastWatchClockReg;       // watch-local: last kRegXLinkClocking sample
    uint64_t  linkWatchTicks;          // watch-local
    bool      linkNeedsRevalidation;   // atomic; set by SetPowerState(On), consumed by the watch
    // A3: the card mixers were silenced for sleep and are put back at wake
    // (xlinkQueue only).
    bool      mixersSilencedForSleep;
    bool      wakeFoundEndpointAbsent; // atomic; SetPowerState(On) saw no endpoint (tunnel lost)
    // dext 115: shadow of the card output routing table the app wrote through
    // kThunderboltCardOutputRouteCommand, replayed by ReprogramCardAfterReset.
    uint32_t  cardOutputRoute[64];
    bool      cardOutputRouteSet[64];
    // dext 116: whether the app has ever written mixer N's state (0xB0–0xB3).
    // Until it has, a re-init must write Start()'s unity defaults, not the
    // all-zero cached state (which silenced outputs 1-2 after wake, 12:18).
    bool      mixerStateValid[2];
    // D5: identifies this driver instance for the app (ReadMixerInstance).
    // Set once in init(); never touches a register.
    uint64_t  startNonce;
    // dext 117: last registers the watch sampled + re-init count, for ReadLinkState.
    uint32_t  lastWatchGcsr;
    uint32_t  lastWatchXlinkStatus;
    uint32_t  cardReinitCount;
    // dext 127: diagnostics only (logged, never acted on). What macOS reported
    // for interrupt indexes 0-3 at Start() (kIOInterruptType*, ~0 = the call
    // failed), and the counters at the moment IO started, so the link watch can
    // say once per start whether audio wraps arrived. No register access.
    uint64_t  irqTypeAtStart[4];
    uint32_t  irqIndexUsed;            // dext 128: the interrupt index the source was created on
    // dext 130, Symphony 64 PCIe card: the expansion register as read before and
    // after Start() writes it, the expansion clock register, and what the DMA
    // check found (logged, and repeated by the start-up summary).
    uint32_t  expansionBefore;
    uint32_t  expansionAfter;
    uint32_t  expansionClk;
    bool      dmaVerifiedRunning;      // CHA moved within Start()'s check (any card)
    uint32_t  dmaCheckA2HOffset1s;     // PCIe card: A2H offset 1 s after DMA start
    uint32_t  dmaCheckIntStatus1s;     // PCIe card: IntStatus 1 s after DMA start
    uint32_t  dmaCheckMeterWritten;    // PCIe card: meter words the card overwrote (of 256)
    uint16_t  pciStatusAtStart;        // PCI config Status (0x06) after the DMA check
    uint64_t  startSummaryLoggedNs;    // CLOCK_MONOTONIC_RAW of the last start-up summary
    uint64_t  ioStartIrq;              // set in StartDevice before ioRunning=true
    uint64_t  ioStartWraps;
    uint64_t  ioStartWatchTick;
    uint32_t  ioStartReported;         // atomic; 0 = the watch has not reported this start yet
    // Per-channel Core Audio names (SymphonyChannelNames.h). inputRouteSource[n]
    // is the Symphony routing source feeding host input n (P2P n), tracked from
    // the AudioRouting (0x31) writes this driver sends; coaxReplace from the
    // S/PDIF Coax Replaces (0x35) writes and reads. Written on xlinkQueue,
    // read on the default queue, both with __atomic_*.
    uint8_t   inputRouteSource[32];
    uint8_t   unitBInputRouteSource[32];
    uint32_t  cardInputRoute[64]; // actual FPGA input words, for host names; atomic across queues
    uint8_t   namingCoaxReplace[2];
    uint8_t   sessionCoaxMirror[2];   // last Mirrors (0x36) sent, 0 = none this session
    uint8_t   sessionCoaxBoardType[2]; // the slot's card type those two belong to, 0 = none
    // 128 = 64 hardware channels + up to 64 VBus channels (dext 143).
    char      publishedInputName[128][20]; // what Core Audio has now; "" = no name set
    char      publishedOutputName[128][20]; // same, for the host outputs (33-64: converters on port 2 only)
    uint8_t   namingPrefix;               // unit's peripheral prefix byte (0x37); not A-Z = "A"
    uint8_t   unitBBoardType[2];
    bool      unitBBoardValid[2];
    uint8_t   unitBPrefix;
    uint8_t   unitBClockSource;
    uint32_t  unitBSetupFlags;
    uint32_t  unitBTxErrors;
    uint32_t  unitBGeneration;
    bool      unitBConfigured;
    // dext 150 (kSelectorReadChannelOrder): per unit ([0] A, [1] B) the host
    // channel order its routing tables (0x31) were last programmed with and
    // the board types they were built from, packed in one word so a reader
    // never sees a torn pair (PackChannelOrder). Latched only when every 0x31
    // send of that configuration succeeded (unit A at step 19b, unit B at the
    // end of ConfigureUnitB); 0 (kSymphonyChannelOrderNone) before that, for
    // unit B whenever it is not configured, and for unit A while port 1
    // carries converters. The channel names are built from these, never from
    // optionBoardType / unitBBoardType directly, so names and tables cannot
    // disagree. channelOrderGeneration moves when either word changes.
    // __atomic_* on both: written on xlinkQueue (or in Start), read on the
    // default queue and by the user client.
    uint32_t  channelOrderLatch[2];
    uint32_t  channelOrderGeneration;
    // Default enabled: og_source/maestrolink/Software/SymphonyController.cpp:2708.
    uint32_t  loopSyncConfig; // xlinkQueue only, default 0 = enabled, master A
    // B7: Loop Sync output with one unit, as the app last applied it in this
    // driver session (LoopSyncConfig). Starts off: the choice is saved in the
    // app, and a driver default of on would override an unticked box at every
    // boot until Maestro connected.
    bool      oneUnitLoopSync;
    bool      loopSyncValid;
    uint8_t   unitBMasterClock[4];
    bool      unitBMasterClockKnown;
    // dext 131 review: the last full ClockMode (0x50) sent to unit A on any
    // path, so entering or leaving two-unit mode only changes its Loop Sync
    // output byte and never the user's source. xlinkQueue only.
    uint8_t   unitAClock[4];
    bool      unitAClockKnown;
    // dext 152: the exact ClockMode bytes and optical formats unit A accepted
    // on this link configuration, so the Core Audio selectors' restore of the
    // same values is not sent again (RequestClockSource,
    // RequestOpticalFormat). Not unitAClock: that keeps the user's choice
    // across recoveries and is not always the bytes sent. Forgotten at every
    // link configuration (Start, recovery), at Stop, and by any ClockMode
    // path that does not record what it sent. xlinkQueue only.
    uint8_t   unitAClockSent[4];
    bool      unitAClockSentKnown;
    uint8_t   opticalSent[2];
    bool      opticalSentKnown[2];
    bool      clockSkipLogged;
    bool      opticalSkipLogged;
    uint8_t   unitBOptical[2];         // unit B's optical format per slot (names 33-64)
    uint8_t   unitBCoaxReplace[2];     // unit B's S/PDIF Coax Replaces per slot (names 33-64)

    // ── EXPERIMENT (64ch, stage 1): second XLink port, discovery only ───────
    // portCount is 1 unless the matched personality carries SymphonyPortCount=2
    // (read once in Start()). Every released build leaves the key out, so every
    // released build runs with 1 and none of the port-2 code below executes;
    // Drivers/Thunderbolt/run-tests.sh proves the register sequence is then
    // unchanged. With 2, Start() switches port 2 on and identifies what is
    // cabled to it. No port-2 DMA, stream or routing exists yet.
    // The port2* fields are written on the Start()/xlinkQueue path and read by
    // ReadPort2State (flags last, atomically, so a reader never sees a unit
    // list newer than the flags that describe it).
    uint32_t  portCount;
    uint32_t  port2Flags;            // atomic; kSymphonyPort2Flag*
    uint32_t  port2XlinkStatus;      // kRegXLink2Status at the last probe
    uint32_t  port2Clocking;         // kRegXLinkClocking at the last probe
    uint32_t  port2Gcsr2;            // kRegGCSR2 at the last probe
    uint32_t  port2UnitCount;
    uint32_t  port2Unit[4];          // kSymphonyPort2Unit* per unit, nearest first
    uint32_t  port2ProbeCount;
    // Rate changes sent to port 2 (StartDevice, on xlinkQueue). port2RateHz is
    // the rate port 2's units last locked to and reported after a rate change,
    // 0 if the last one did not get that far (or none has run since the probe).
    uint32_t  port2RateHz;
    uint32_t  port2RateChanges;

    // ── EXPERIMENT (64ch, stage 2): audio on port 2 ─────────────────────────
    // All of it is used only when portCount == 2 (every pointer stays null and
    // every number 0 otherwise). See "audio on port 2" further down.
    // The second DMA buffer pair (og SetupMemoryForSecondPort), allocated at
    // Start() and programmed into the card only while 64 channels are selected.
    IOBufferMemoryDescriptor *a2h2Buffer;
    IOBufferMemoryDescriptor *h2a2Buffer;
    IODMACommand             *a2h2DMA;
    IODMACommand             *h2a2DMA;
    uint64_t                  a2h2PhysAddr;
    uint64_t                  h2a2PhysAddr;
    IOMemoryMap              *a2h2DMAMap;
    IOMemoryMap              *h2a2DMAMap;
    // Core Audio stream buffers for 64-channel frames (8192 x 256 bytes). The
    // streams are created on the usual 32-channel buffers, exactly as in a
    // one-port build, and are given these with SetIOMemoryDescriptor only while
    // 64 channels are selected, so the buffer always fits the format exactly.
    IOBufferMemoryDescriptor *a2hStream64Buffer;
    IOBufferMemoryDescriptor *h2aStream64Buffer;
    IOMemoryMap              *a2hStream64Map;
    IOMemoryMap              *h2aStream64Map;
    bool      port2AudioReady;       // all of the above exist and are mapped
    // Guards the AudioDriverKit objects PerformPortModeChange and
    // RequestPortMode use (streams, device, selectors) against Stop()'s
    // teardown releasing them on another queue. Allocated in two-port builds
    // only; released in free().
    IOLock   *portPublishLock;
    bool      portSelectorsStale;    // atomic: a selector may not show the card's mode
    // 32 or 64. portMode: what the CARD is running; written on xlinkQueue only.
    // ioChannels: channels per frame of the streams' current format; written in
    // PerformPortModeChange (IO stopped), read by the IO handler.
    // requestedPortMode: what the selector last asked for. All three atomic.
    uint32_t  portMode;
    uint32_t  ioChannels;
    uint32_t  requestedPortMode;
    uint32_t  port2AudioFlags;       // atomic; outcome + reason bits of kSymphonyPort2Audio*
    uint32_t  port2ModeChanges;      // 32<->64 changes of the card since Start()
    bool      port2ClockingProblem;  // port-2 LED state, xlinkQueue only
    bool      port2ResumeUnitSeen;   // a returned unit has been observed for the saved 64 request
    uint64_t  port2ResumeProbeNs;    // xlinkQueue; last time port 2 was switched on just to look
    uint32_t  port2ResumeProbes;     // xlinkQueue; active looks since the 64 request (stop after 20)
    // EnablePort2Audio gave up because a stop or power-down began after it had
    // enabled port 2, and wrote nothing more. The next link-watch tick that
    // reaches the card at 32 channels disables port 2 again. xlinkQueue only.
    bool      port2DisablePending;
    uint32_t  port2PhaseWord;        // kSymphonyPort2Phase*, the last alignment
    SymphonyPortSourceControl *portSourceControl[2];   // [0] input, [1] output

    // ── VBus (dext 143): see "VBus" further down ────────────────────────────
    // Everything is null/0 until a size is first requested: a driver that is
    // never asked for VBus allocates nothing and publishes nothing for it.
    // The streams are created, replaced and released in PerformVBusChange
    // (IO stopped) and in Stop()'s teardown, under portPublishLock.
    // vbusIO is the generation in use (atomic; null = off). vbusRetired is
    // the one generation it replaced: its memory stays mapped until the NEXT
    // change, or Stop(), so an IO callback that was still running when a
    // change swapped the pointer never touches freed memory. Never more than
    // one retired generation.
    IOUserAudioStream        *vbusOutStream;
    IOUserAudioStream        *vbusInStream;
    SymphonyVBusIO           *vbusIO;
    SymphonyVBusIO           *vbusRetired;
    uint32_t  vbusRequested;   // atomic: the size last asked for (selector 16)
    uint32_t  vbusPublished;   // atomic: the size of the streams on the device, 0 = none
    uint32_t  vbusBase;        // atomic: hardware channels before VBus channel 1 (32 or 64)
    uint32_t  vbusFlags;       // atomic: kSymphonyVBusFlag*
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
// Unit identification, sent by the original driver to every unit on the bus
// during enumeration (XLinkRegisters.h XLINK_CMD_INQUIRE / XLINK_CMD_XTD_INQUIRE;
// Driver/XLink.cpp DeviceRoutingInquire :1449-1500). The INQUIRE reply's high
// nibble says which channel banks the unit has, which is how the original told
// the older converters apart: 0x3 AD-16X, 0xC DA-16X, 0xF DD-16X, 0x5 Rosetta 800.
static constexpr uint8_t  kXLinkCmdInquire         = 0x05;
static constexpr uint8_t  kXLinkCmdXtdInquire      = 0x0B;
static constexpr uint8_t  kXLinkCmdDeviceType      = 0x0C;   // XLINK_DEVICE_TYPE (XLinkRegisters.h:481)
static constexpr uint8_t  kXLinkMaxDevices         = 4;     // XLINK_MAX_DEVICES
// ReadLinkState word 15 layout (dext 121+): bits 0-7 unit 1 INQUIRE reply,
// bits 8-15 unit 1 XTD_INQUIRE reply, bits 16-27 the bank nibbles of units 2,
// 3 and 4 (zero = none), bits 29-31 the flags below.
static constexpr uint32_t kUnitProbeRan            = 0x80000000;
static constexpr uint32_t kUnitProbeInquireOK      = 0x40000000;
static constexpr uint32_t kUnitProbeXtdOK          = 0x20000000;
// Bit 28 (dext 126+): the volume keys trim card mixer 1 because the cable has
// converters only (ClassifyVolumeTarget). Set only in ReadLinkState's copy.
static constexpr uint32_t kUnitProbeConverterVolumeKeys = 0x10000000;

// Whether a probe word describes a cable of converters only, for the volume
// keys. The original's device routing is (XTD_INQUIRE & 0xF0) | (INQUIRE >> 4)
// (XLinkRegisters.h CONVERT_ROUTING_COMMANDS_TO_NEW_FORMAT): 0x03 AD-16X,
// 0x05 Rosetta 800, 0x0C DA-16X, 0x0F DD-16X, and 0xFF for a Symphony I/O.
// Older converters do not answer XTD_INQUIRE (XLink.cpp DeviceRoutingInquire:
// "Failing here is normal"). So:
//   - INQUIRE nibble 0x3, 0x5 or 0xC cannot be a Symphony I/O, provided an XTD
//     reply, if any, has a zero high nibble;
//   - 0xF is a DD-16X only when XTD answered with a zero high nibble; with no
//     XTD reply it could be a Symphony I/O whose reply was lost, so it is not
//     counted (a DD-16X that does not answer XTD keeps today's behaviour);
//   - chained units (bits 16-27, zero = none) carry only the INQUIRE nibble, so
//     each must be 0x3, 0x5 or 0xC; anything else keeps the Symphony behaviour.
static constexpr bool UnitProbeIsConvertersOnly(uint32_t probe)
{
    if (!(probe & kUnitProbeInquireOK)) return false;
    const uint32_t first = (probe >> 4) & 0xF;
    const bool xtdOK = (probe & kUnitProbeXtdOK) != 0;
    const uint32_t xtdHigh = (probe >> 12) & 0xF;
    if (xtdOK && xtdHigh != 0) return false;
    if (first == 0xF) {
        if (!xtdOK) return false;
    } else if (first != 0x3 && first != 0x5 && first != 0xC) {
        return false;
    }
    for (uint32_t i = 0; i < 3; i++) {
        const uint32_t n = (probe >> (16 + 4 * i)) & 0xF;
        if (n == 0) break;
        if (n != 0x3 && n != 0x5 && n != 0xC) return false;
    }
    return true;
}
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

// convIn/convOut: dext 131, the converters' own latency (ConverterLatencyFor)
// in place of the Symphony I/O figures; 0/0 keeps the table.
static kern_return_t ApplyAudioTimingProfile(IOUserAudioDevice *audioDevice, double rate,
                                             uint32_t convIn = 0, uint32_t convOut = 0)
{
    if (!audioDevice) return kIOReturnBadArgument;
    TimingProfile profile = TimingProfileForRate(rate);
    if (convIn || convOut) {
        profile.inputConverterLatency = convIn;
        profile.outputConverterLatency = convOut;
    }
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
// What the volume control reads with Speakers chosen in Line mode: the
// original's fixed 20 dB attenuation (SymphonyIO.cpp:3145-3152).
static constexpr uint8_t kLineModeSpeakerReading      = 20;
static constexpr uint8_t kSIOCmd_HeadphoneVolume      = 0x23;  // 1 byte: nValue=HP index, attenuation in dB
static constexpr uint8_t kSIOCmd_HeadphoneMute        = 0x24;  // 1 byte: nValue=HP index, 0=unmuted, 1=muted
static constexpr uint8_t kSIOCmd_AudioRouting          = 0x31;  // N×2 bytes: [dest, src] pairs
static constexpr uint8_t kSIOCmd_OpticalFormat         = 0x34;  // 1 byte: 0=ADAT/SMUX, 1=SPDIF. nValue=board index (0 or 1).
static constexpr uint8_t kSIOCmd_SPDIFCoaxReplaceInput = 0x35; // 1 byte: SymphonyIOBoardSPDIFCoaxReplace (0 Off, 1-8 pair). nValue=board index.
static constexpr uint8_t kSIOCmd_SPDIFCoaxMirrorOutput = 0x36; // 1 byte: pair 1-8 mirrored by the coax output. nValue=board index.
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
static constexpr uint8_t kSIOCmd_InstrumentGain        = 0xC4;  // 1 byte: gain 0..65. nValue=0-based mic channel.
static constexpr uint8_t kSIOCmd_CurrentAnalogInputType = 0x60;
// CoreAudio's selector IDs are ordered +4, -10, Variable, Mic, Instrument;
// Symphony's 0x20 wire enum is Variable, +4, -10, Mic, Instrument.
static constexpr uint8_t CoreInputTypeToWire(uint32_t type)
{
    return type == 0 ? 1 : type == 1 ? 2 : type == 2 ? 0 : static_cast<uint8_t>(type);
}
static constexpr uint8_t WireInputTypeToCore(uint8_t type)
{
    return type == 1 ? 0 : type == 2 ? 1 : type == 0 ? 2 : type;
}
static constexpr uint8_t kSIOCmd_AnalogReferenceLevel  = 0x20;  // payload[0] = wire input type.
// MicPre8 per-channel commands (og_source/maestrolink/Software/SymphonyIO/
// SymphonyIOVendorSpecific.h:412-439). 0xC8's nValue is the INSERT and its
// payload the channel mask (SymphonyIOBoard_MicPre8ch.cpp:1790-1808).
static constexpr uint8_t kSIOCmd_PhaseInverse          = 0xC5;
static constexpr uint8_t kSIOCmd_ChannelGroup          = 0xC7;
static constexpr uint8_t kSIOCmd_Insert                = 0xC8;
static constexpr uint8_t kSIOCmd_InsertEnable          = 0xC9;
static constexpr uint8_t kSIOCmd_HighPassFilter        = 0xCA;
static constexpr uint8_t kSIOTrimDoNotSet              = 127;   // DO_NOT_SET_TRIM_VALUE, SymphonyIOVendorSpecific.h:10
// A Mic type set through the HAL authorises HAL phantom ON only after this
// long. coreaudiod restores saved control values in one burst when a device
// appears (the original refused coreaudiod for type, polarity, phantom and
// high-pass: og_source/maestrolink/Software/SymphonyIOBoard_MicPre8ch.cpp:
// 386-387,629-630,674-675,727-728); a person who picks Mic in a DAW and then
// clicks +48V takes longer than this. A DriverKit control is not told which
// process set it, so time is the only signal left to tell the two apart.
static constexpr uint64_t kHALMicArmNs = 2000000000ull;
// The original refused coreaudiod outright for all four MicPre properties
// (type, polarity, phantom, high-pass; same lines as above): its "(broken)
// store/recall". A DriverKit control is not told which process set it, so
// the driver refuses HAL writes of those four (phantom OFF excepted) for this
// long after the controls appear to coreaudiod: driver Start, wake, and every
// device configuration change (port mode, link recovery). coreaudiod replays
// saved values in a burst as it (re)reads the device; 5 s covers that burst
// with room to spare, and a person editing a DAW in the first seconds after
// a wake just clicks again. Gain is not in the window: coreaudiod's gain
// recall arrives as a scalar change, which already only stores the value
// (SymphonyMicGainControl.cpp; the original refused it at MicPre8ch.cpp:787-809).
static constexpr uint64_t kHALMicPreSettleNs = 5000000000ull;
// Defined with the MicPre request code below; Start and ConfigureUnitB use them.
static void ReadMicPreSwitches(SymphonyThunderbridge_IVars *iv, uint32_t port, uint32_t ch);
static uint8_t MicPreTypeChoicesForHost(SymphonyThunderbridge_IVars *iv, uint32_t host);
static void FillMicPreTypeDescriptions(IOUserAudioSelectorValueDescription (&out)[5]);
static void PublishAllMicPreControls(SymphonyThunderbridge_IVars *iv);
static void ClearHalMicPreEdit(SymphonyThunderbridge_IVars *iv, uint32_t port, uint32_t ch, uint32_t validBit);
static void RecordMicPreTrim(SymphonyThunderbridge_IVars *iv, uint32_t port, uint32_t ch,
                             uint8_t type, uint8_t byte);
static void ArmMicPreSettle(SymphonyThunderbridge_IVars *iv);
static bool MicPreSettling(SymphonyThunderbridge_IVars *iv);
static bool MicPreTypeKnownOn(SymphonyThunderbridge_IVars *iv, uint32_t port, uint32_t ch);
static void ResetMicPreUnitCaches(SymphonyThunderbridge_IVars *iv, uint32_t port, bool clearEdits);
static void RereadMicPreTypesA(SymphonyThunderbridge_IVars *iv);
static constexpr uint8_t kSIOCmd_PhantomPower          = 0xC6;  // 1 byte: 0=off, 1=on. nValue=0-based mic channel.
static constexpr uint8_t kSIOCmd_ResetDefaultRouting   = 0xC2;  // no payload
static constexpr uint8_t kSIOCmd_PreferenceLoadLock    = 0xDD;  // 1 byte: 1=lock/mute, 0=unlock

// Read-only vendor commands (request/RESPONSE, bmRequestType 0xC0 → ReadVendorRequest).
static constexpr uint8_t kSIOCmd_OptionBoardType       = 0xA1;  // read 1 byte. nValue: 0=primary, 1=secondary. Returns SymphonyIOOptionBoardType.
static constexpr uint8_t kSIOCmd_ClockRateAndLock      = 0x51;  // read 5 bytes: [0]=lock(0/1), [1..4]=uint32 BE measured rate Hz (clk[1]=MSB).

// Option-board types and BoardHasOpticalFormat / BootSendsOpticalFormat live in
// SymphonyOptionBoard.h so the host-side test can compile them.

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
// SymphonyChannelNames.h builds the routing tables with its own copies.
static_assert(kSIOSrc_None == kSymphonyRoutingSourceNone && kSIOSrc_XLinkCh0 == kSymphonyRoutingSourceXLink0 &&
              kSIOSrc_IOBoard0Ch0 == kSymphonyRoutingSourceIOBoard0 && kSIOSrc_IOBoard1Ch0 == kSymphonyRoutingSourceIOBoard1 &&
              kSIODest_IOBoard0Ch0 == kSymphonyRoutingDestIOBoard0 && kSIODest_IOBoard1Ch0 == kSymphonyRoutingDestIOBoard1 &&
              kSIODest_P2PCh0 == kSymphonyRoutingDestP2P0, "routing bytes match SymphonyChannelNames.h");

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

// Send an XLink command via a port's TX register (txRegister is kRegXLink1TX
// or, in the two-port experiment only, kRegXLink2TX).
// Returns true if the command was sent (busy bit cleared within timeout).
static bool SendXLinkCommandOn(IOPCIDevice *dev, uint8_t memIndex, uint64_t txRegister,
                               uint8_t addr, uint8_t cmd, uint8_t data)
{
    // Wait for TX busy bit to clear (max 100ms)
    for (int i = 0; i < 100; i++) {
        uint32_t txReg = 0;
        dev->MemoryRead32(memIndex, txRegister, &txReg);
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
    dev->MemoryWrite32(memIndex, txRegister, val);
    if (cmd != kXLinkCmdMsgByte)
        dev->MemoryWrite32(memIndex, txRegister, val);
    return true;
}

// Port 1. Everything the driver did before the two-port experiment goes
// through here.
static bool SendXLinkCommand(IOPCIDevice *dev, uint8_t memIndex,
                              uint8_t addr, uint8_t cmd, uint8_t data)
{
    return SendXLinkCommandOn(dev, memIndex, kRegXLink1TX, addr, cmd, data);
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
static bool SendVendorRequestOn(IOPCIDevice *dev, uint8_t memIndex,
                              uint64_t txRegister,
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
        if (!SendXLinkCommandOn(dev, memIndex, txRegister, xlinkAddr,
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

static bool SendVendorRequest(IOPCIDevice *dev, uint8_t memIndex,
                              uint8_t xlinkAddr, uint8_t command,
                              uint32_t value, const uint8_t *payload, uint16_t payloadLen,
                              uint8_t &txSequence)
{
    return SendVendorRequestOn(dev, memIndex, kRegXLink1TX, xlinkAddr, command, value,
                               payload, payloadLen, txSequence);
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

// Pop one 24-bit word from a port's RX FIFO (rxRegister is kRegXLink1RX or, in
// the two-port experiment only, kRegXLink2RX).
//
// The original driver has two versions of this routine, chosen at build time
// (legacy XLink::RX_FIFO_ReadHW, XLink.cpp:2142-2226):
//
//   ThunderBridge (2200):  read (probe) -> if RX_EMPTY, done -> write 0 ->
//                          read again: that second read is the word.
//   Symphony 64 PCIe card (2100, pcieOrder):  read: that IS the word -> if
//                          RX_EMPTY, done -> write 0 ("Older PCIe cards needed
//                          a write after the FIFO read").
//
// Before this the ThunderBridge order was used on both. On the PCIe card a
// Symphony I/O then never answered a vendor read, so it was taken for one of
// the older converters (field report 2026-11-15: a 16x16 Symphony I/O shown as
// "DD-16X"). pcieOrder is the card this driver instance attached to
// (ivars->isLegacyPCIe2100), passed per call: two cards of different kinds can
// be attached at once.
// Returns true and *outWord when a word was popped; false when the FIFO is empty.
static bool ReadXLinkRXWordOn(IOPCIDevice *dev, uint8_t memIndex, uint64_t rxRegister,
                              bool pcieOrder, uint32_t *outWord)
{
    uint32_t data = 0;
    dev->MemoryRead32(memIndex, rxRegister, &data);       // read #1
    if (data & kXLinkCmdRxEmpty)
        return false;                                     // FIFO empty
    if (pcieOrder) {
        dev->MemoryWrite32(memIndex, rxRegister, 0);      // advance the FIFO
        *outWord = data;                                  // read #1 was the word
        return true;
    }
    dev->MemoryWrite32(memIndex, rxRegister, 0);          // pop / advance FIFO
    dev->MemoryRead32(memIndex, rxRegister, &data);       // read #2: the actual word
    data &= ~kXLinkCmdRxEmpty;
    *outWord = data;
    return true;
}

// Port 1.
static bool ReadXLinkRXWord(IOPCIDevice *dev, uint8_t memIndex, bool pcieOrder,
                            uint32_t *outWord)
{
    return ReadXLinkRXWordOn(dev, memIndex, kRegXLink1RX, pcieOrder, outWord);
}

// Send one identification command to a unit and wait briefly for its one-byte
// reply. A reply is accepted on the same terms as the original's
// XLink::WaitForRXData (Driver/XLink.cpp): command slot 9, the unit's address
// and the command all match (XLINK_DATA_SLOT/ADDR/CMD/DATA, SymphonyCommon.h
// :258-264). Any other word is skipped, not taken as an answer.
// Returns false on a TX timeout or when nothing answered within 20 ms. The
// original waited 5 ms for INQUIRE and 2 ms for XTD_INQUIRE; this is a little
// more patient and still bounded.
static bool XLinkInquireOn(IOPCIDevice *dev, uint8_t memIndex,
                           uint64_t txRegister, uint64_t rxRegister,
                           uint8_t addr, uint8_t cmd, uint8_t *outReply,
                           bool pcieOrder)
{
    if (!SendXLinkCommandOn(dev, memIndex, txRegister, addr, cmd, 0))
        return false;
    for (int ms = 0; ms < 20; ms++) {
        uint32_t word = 0;
        while (ReadXLinkRXWordOn(dev, memIndex, rxRegister, pcieOrder, &word)) {
            const uint8_t slot    = (uint8_t)((word & 0x0F000000u) >> 24);
            const uint8_t rxAddr  = (uint8_t)((word & 0x007E0000u) >> 17);
            const uint8_t rxCmd   = (uint8_t)((word & 0x0001FE00u) >> 9);
            if (slot != 9 || rxAddr != addr || rxCmd != cmd)
                continue;
            *outReply = (uint8_t)((word & 0x000001FEu) >> 1);
            return true;
        }
        IOSleep(1);
    }
    return false;
}

// Port 1.
static bool XLinkInquire(IOPCIDevice *dev, uint8_t memIndex, uint8_t addr,
                         uint8_t cmd, uint8_t *outReply, bool pcieOrder)
{
    return XLinkInquireOn(dev, memIndex, kRegXLink1TX, kRegXLink1RX, addr, cmd, outReply,
                          pcieOrder);
}

// Byte-at-a-time reassembler for a SimpleMessageProtocol Response frame.
// Mirrors DriverProcessIncomingData()'s 0xC3 state machine. Feed it the
// XLINK_DATA_DATA byte of each MSG_BYTE RX word; feed() returns true once a
// complete, CRC-valid frame has arrived, leaving the control payload in buf[0..size).
struct SmpResponseParser {
    enum State { Sync, Size, Seq, ReqId, Data, Crc };
    State    state = Sync;
    // The original protocol's limit is 80 data bytes
    // (eSimpleMessageProtocol_MaxDataSize, SimpleMessageProtocol.h:19); a
    // 64-byte read answers with 8 + 64 = 72.
    static constexpr uint8_t kMaxData = 80;
    uint8_t  buf[kMaxData];        // reassembled control payload (data × size)
    uint8_t  size = 0;
    uint8_t  idx  = 0;
    uint8_t  crcBuf[kMaxData + 4]; // bytes the CRC covers: type+size+seq+reqId+data
    uint8_t  crcLen = 0;

    bool feed(uint8_t b) {
        switch (state) {
        case Sync:
            if (b != 0xC3) return false;              // resync on start byte 0xC3
            crcLen = 0; crcBuf[crcLen++] = b; state = Size; break;
        case Size:
            if (b > kMaxData) { state = Sync; return false; }  // MaxDataSize guard
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

// Which reply belongs to which read. The unit answers a read with the request
// packet itself, data filled in (firmware SymphonyIOCommandPacket.cpp:56-60,
// 83-96): byte 1 is the command, bytes 2-5 the request's nValue. Every read
// is matched on the command; the reads below, where two different nValues are
// in use and a wrong answer would be believed, also on nValue:
//   0x30 meter group (0 input, 1 output, 2 mixer), 0x23 / 0x24 headphone 0 / 1
//   level and mute, 0xA1 slot 0 / 1, 0x60 channel.
// A command whose reads time out three times in a row after skipping a
// CRC-valid frame (firmware that does not echo its request) falls back to the
// first valid frame for the rest of this driver session.
static bool ReplyMatchesValue(uint8_t command)
{
    return command == 0x30 || command == 0x23 || command == 0x24
        || command == 0xA1 || command == 0x60;
}
static uint8_t  sReplySkipTimeouts[256];
static bool     sReplyMatchFallback[256];
static uint32_t sReplySkippedFrames;

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
static bool ReadVendorRequestOn(IOPCIDevice *dev, uint8_t memIndex,
                              uint64_t txRegister, uint64_t rxRegister,
                              uint8_t xlinkAddr, uint8_t command,
                              uint32_t value, uint8_t *outData, uint16_t outLen,
                              uint8_t &txSequence, bool pcieOrder)
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
        while (ReadXLinkRXWordOn(dev, memIndex, rxRegister, pcieOrder, &junk)) { /* discard */ }
    }

    // ── Layer 1: send each byte via MSG_BYTE ──
    for (uint32_t i = 0; i < msgLen; i++) {
        if (!SendXLinkCommandOn(dev, memIndex, txRegister, xlinkAddr,
                               kXLinkCmdMsgByte, message[i])) {
            STERR("ReadVendorRequest: MSG_BYTE timeout at byte %u/%u (cmd=0x%02x)",
                  i, msgLen, command);
            return false;
        }
    }
    // The app polls 0x30 for meters several times a second: no success lines
    // for it. Every error and timeout line stays.
    if (command != 0x30)
        STLOG("ReadVendorRequest: sent READ cmd=0x%02x nValue=%u wLength=%u (%u MSG_BYTE frames)",
              command, value, outLen, msgLen);

    // ── Poll RX up to 200 ms; feed MSG_BYTE data bytes into the parser ──
    SmpResponseParser parser;
    const bool fallback = sReplyMatchFallback[command];
    uint32_t skipped = 0;
    for (int ms = 0; ms < 200; ms++) {
        uint32_t word = 0;
        while (ReadXLinkRXWordOn(dev, memIndex, rxRegister, pcieOrder, &word)) {
            uint8_t cmdField = (uint8_t)((word >> 9) & 0xFF);   // XLINK_DATA_CMD
            if (cmdField != kXLinkCmdMsgByte)
                continue;                                        // ignore non-message words
            uint8_t rxByte = (uint8_t)((word >> 1) & 0xFF);      // XLINK_DATA_DATA
            if (parser.feed(rxByte)) {
                // Frame complete + CRC OK. Control payload layout:
                //   [bmReqType][bReq][nValue:4][wLength:2][data...] — data at offset 8.
                if (!fallback) {
                    bool mine = parser.size >= 2 && parser.buf[1] == command;
                    if (mine && ReplyMatchesValue(command)) {
                        mine = parser.size >= 6
                            && parser.buf[2] == (uint8_t)(value >>  0)
                            && parser.buf[3] == (uint8_t)(value >>  8)
                            && parser.buf[4] == (uint8_t)(value >> 16)
                            && parser.buf[5] == (uint8_t)(value >> 24);
                    }
                    if (!mine) {
                        // Another read's answer, arriving late: not this one.
                        skipped++;
                        if ((sReplySkippedFrames++ % 100u) == 0)
                            STLOG("ReadVendorRequest: skipped a reply for cmd=0x%02x while "
                                  "reading cmd=0x%02x (%u skipped so far)",
                                  parser.size >= 2 ? parser.buf[1] : 0, command,
                                  sReplySkippedFrames);
                        continue;
                    }
                }
                sReplySkipTimeouts[command] = 0;
                if (command != 0x30)
                    STLOG("ReadVendorRequest: cmd=0x%02x RESPONSE ok, size=%u, "
                          "raw[0..3]=%02x %02x %02x %02x",
                          command, parser.size,
                          parser.size > 0 ? parser.buf[0] : 0,
                          parser.size > 1 ? parser.buf[1] : 0,
                          parser.size > 2 ? parser.buf[2] : 0,
                          parser.size > 3 ? parser.buf[3] : 0);
                if ((unsigned)parser.size < 8u + (unsigned)outLen) {
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
    if (skipped > 0 && !fallback && ++sReplySkipTimeouts[command] >= 3) {
        sReplyMatchFallback[command] = true;
        STERR("ReadVendorRequest: cmd=0x%02x timed out 3 times after skipping replies; "
              "taking the first valid reply for this command from now on", command);
    }
    STERR("ReadVendorRequest: cmd=0x%02x TIMEOUT (no valid response in 200 ms, %u skipped)",
          command, skipped);
    return false;
}

static bool ReadVendorRequest(IOPCIDevice *dev, uint8_t memIndex,
                              uint8_t xlinkAddr, uint8_t command,
                              uint32_t value, uint8_t *outData, uint16_t outLen,
                              uint8_t &txSequence, bool pcieOrder)
{
    return ReadVendorRequestOn(dev, memIndex, kRegXLink1TX, kRegXLink1RX, xlinkAddr,
                               command, value, outData, outLen, txSequence, pcieOrder);
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
// dext 130: on the Symphony 64 PCIe card the DDS is turned off, as the
// original's SetDDSSampleRate does whenever it is not clocking the bus itself
// (m_afClockingInSym2Sym, set only when no XLink clock arrives: XLink.cpp:919-947,
// 2977-2988). A Symphony I/O clocks the bus, so the original runs with DDS off.
// On the ThunderBridge these bits do not hold (GCSR reads back without them), so
// it keeps this driver's behaviour; on the PCIe card they hold.
static void SetDDSSampleRate(IOPCIDevice *dev, uint8_t memIndex, double rate, bool legacyPCIe = false)
{
    uint32_t ddsValue = legacyPCIe ? kGCSR_DDS_Off : SampleRateToDDS(rate);
    // Must use explicit RMW to re-assert write-only DMA channel count bits
    uint32_t gcsr = 0;
    ReadRegister(dev, memIndex, kRegGCSR, &gcsr);
    gcsr &= ~(kGCSR_DDSMask | kGCSR_DMAMask);  // Clear DDS + DMA fields
    gcsr |= ddsValue;                            // Set new DDS rate
    gcsr |= (kGCSR_DMAOutSize32 | kGCSR_DMAInSize32);  // Re-assert DMA ch count
    WriteRegister(dev, memIndex, kRegGCSR, gcsr);
    STLOG("DDS rate set to %.0f Hz (GCSR DDS=0x%04x%{public}s, GCSR=0x%08x)", rate, ddsValue,
          legacyPCIe ? ", off on the PCIe card" : "", gcsr);
}

static void AlignXLinkPhase(SymphonyThunderbridge_IVars *ivars);  // below

// dext 130: the frame-sync pulse the original sends every card after each rate
// set (syncComponents -> CMD_SYNC -> SampleClock::Synchronise: set
// SAMPLE_FRAME_USE_EXTERNAL in CLKCTRL, 2 ms, clear; SampleClock.cpp:46-55,
// SymphonyBaseAudioEngine.cpp:2007-2031 and 2088, "align the slave frame
// interrupts to the master"). Symphony 64 PCIe card only.
static void PulseFrameSyncLegacyPCIe(IOPCIDevice *dev, uint8_t memIndex, const char *where)
{
    uint32_t before = 0, after = 0;
    ReadRegister(dev, memIndex, kRegClkCtrl, &before);
    ModifyRegister(dev, memIndex, kRegClkCtrl, kClkCtrl_UseExternal, 0);
    IOSleep(2);
    ModifyRegister(dev, memIndex, kRegClkCtrl, 0, kClkCtrl_UseExternal);
    ReadRegister(dev, memIndex, kRegClkCtrl, &after);
    STLOG("PCIe card: frame sync pulse (CLKCTRL bit 31, 2 ms) after %{public}s; CLKCTRL 0x%08x -> 0x%08x",
          where, before, after);
}

// WaitForLock: checks DataSlipSticky for stability.
// Legacy: XLink.cpp:2529 — 5 checks × 50ms = 250ms per pass, max passes = timeout/250.
// Returns true if 250ms of clean (no-slip) samples observed.
// statusRegister is kRegXLink1Status, or kRegXLink2Status in the two-port
// experiment only (port-2 rate change).
static bool WaitForLockOn(IOPCIDevice *dev, uint8_t memIndex, uint64_t statusRegister,
                          int timeoutMs)
{
    int maxPasses = timeoutMs / 250;
    if (maxPasses < 1) maxPasses = 1;

    WriteRegister(dev, memIndex, statusRegister, kXLinkDataSlipSticky);
    for (int pass = 0; pass < maxPasses; pass++) {
        bool slipFree = true;
        for (int i = 0; i < 5; i++) {
            IOSleep(50);
            uint32_t status = 0;
            ReadRegister(dev, memIndex, statusRegister, &status);
            if (status & kXLinkDataSlipSticky) {
                slipFree = false;
                WriteRegister(dev, memIndex, statusRegister, kXLinkDataSlipSticky);
                break;
            }
        }
        if (slipFree) {
            STLOG("WaitForLock(port %d): locked after %d passes (%d ms)",
                  statusRegister == kRegXLink1Status ? 1 : 2, pass + 1, (pass + 1) * 250);
            return true;
        }
    }
    return false;
}

// Port 1. Everything the driver did before the two-port experiment.
static bool WaitForLock(IOPCIDevice *dev, uint8_t memIndex, int timeoutMs)
{
    return WaitForLockOn(dev, memIndex, kRegXLink1Status, timeoutMs);
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

// ── EXPERIMENT (64ch): sample-rate change on port 2 ─────────────────────────
// Used only when ivars->portCount == 2 and the port-2 probe found a unit; the
// caller passes a null Port2RateChange otherwise and none of this runs.
//
// The original's XLink::SetSampleRate (og_source/symphonymk1/ext/Symphony64/
// Driver/XLink.cpp:963-1160), for every bus that is enabled and has a clock
// (XLinkClockDetected, :2631, up to five reads of XLINK_CLOCKING):
//   a. port 2 FIRST: WaitForLock(bus 2, data link only, 5000 ms), then
//      SET_SAMPLE_RATE to the broadcast address on bus 2 (:991-1012);
//   b. then each bus in turn, port 1 first: SET_SAMPLE_RATE (broadcast),
//      WaitForLock, settle, wait for the detected rate to match, WaitForLock
//      (:1014-1063).
// DDS was set before all of it (XLinkThread :323-328). Port 2 gets no UNMUTE in
// Stage 1. The original returned FALSE for the whole change if port 2 failed;
// here port 2 carries no audio yet, so a port-2 failure is recorded for
// ReadPort2State and logged but does not fail the device's rate change.
//
// Deliberate differences from the original, all because this runs inside
// StartDevice (coreaudiod waits on it) and port 2 carries no audio:
//   - each port-2 lock wait is capped at kPort2LockBudgetMs, not 5000 ms, and
//     port 2's after-step is skipped if a stop has begun;
//   - no 250 ms settle, 1 s (not 3 s) for the rate to show, as on port 1;
//   - no phase alignment on port 2 (og :1079-1150: GetWCLKPhase per unit and
//     the shared ShiftPhase). Must be added before port 2 carries audio.
//   - if port 2 slipped before the change and was not told first, it is still
//     told after port 1 (the original would have failed the change and
//     retried it on its next pass, og :353-358).
static constexpr int kPort2LockShortMs = 1000;
static constexpr int kPort2LockMediumMs = 2000;
static constexpr int kPort2LockWordClockMs = 5000;
static constexpr int kPort2LockRateChangeMs = 5000;
// Clock polls (50 ms each) after port 2 is enabled for "Port 1-2: 64ch".
static constexpr int kPort2ClockPollsOnSelect = 40;

struct Port2RateChange {
    SymphonyThunderbridge_IVars *ivars = nullptr;   // for the stop check
    bool attempted = false;   // ChangeSampleRate reached the port-2 step
    bool clock     = false;   // port 2 had a unit clock at the start
    bool sentNew   = false;   // SET_SAMPLE_RATE(new) went out on port 2
    bool ok        = false;   // port 2 locked and reported the new rate
    uint32_t detectedHz = 0;  // what port 2's receiver reported at the end
};

// Port 2's detected rate (SR2 bits: the port-1 detect bits, sixteen up),
// or 0 if its receive clock or rate is not there. Legacy GetActualClockRate
// for the secondary port (XLink.cpp:2763-2825).
static uint32_t GetActualClockRatePort2(IOPCIDevice *dev, uint8_t memIndex)
{
    uint32_t clockReg = 0;
    ReadRegister(dev, memIndex, kRegXLinkClocking, &clockReg);
    if (!(clockReg & kXLinkRX2ClockDetect))
        return 0;
    switch ((clockReg & kXLinkSR2Mask) >> 16) {
        case kXLinkSRDetect1_44100:  return 44100;
        case kXLinkSRDetect1_48000:  return 48000;
        case kXLinkSRDetect1_88200:  return 88200;
        case kXLinkSRDetect1_96000:  return 96000;
        case kXLinkSRDetect1_176400: return 176400;
        case kXLinkSRDetect1_192000: return 192000;
        default: return 0;
    }
}

// Step a: before port 1 is told. Legacy XLinkClockDetected(bus 2) + the
// pre-send WaitForLock + SET_SAMPLE_RATE.
static void Port2RateBefore(IOPCIDevice *dev, uint8_t mi, double newRate, uint8_t rateCode,
                            Port2RateChange *p2)
{
    p2->attempted = true;
    bool clock = false;
    uint32_t clk = 0;
    for (int n = 0; n < 5 && !clock; n++) {
        ReadRegister(dev, mi, kRegXLinkClocking, &clk);
        clock = (clk & kXLinkRX2ClockDetect) != 0 && (clk & kXLinkSR2Mask) != 0;
    }
    if (!clock) {
        STLOG("ChangeSampleRate: port 2 has no unit clock now (XLinkClocking=0x%08x) — "
              "nothing sent on port 2", clk);
        return;
    }
    p2->clock = true;
    if (!WaitForLockOn(dev, mi, kRegXLink2Status, kPort2LockRateChangeMs)) {
        STERR("ChangeSampleRate: port 2 data link slipping before the change — "
              "port 2 will be told after port 1 instead");
        return;
    }
    if (!SendXLinkCommandOn(dev, mi, kRegXLink2TX, kXLinkCmdAddrAll,
                            kXLinkCmdSetSampleRate, rateCode)) {
        STERR("ChangeSampleRate: port 2 SET_SAMPLE_RATE timeout (not sent)");
        return;
    }
    p2->sentNew = true;
    STLOG("ChangeSampleRate: port 2 told %.0f Hz (before port 1)", newRate);
}

// Step b for port 2, after port 1 has locked and verified. Same shape as the
// port-1 sequence in ChangeSampleRate (lock, rate check, lock).
static void Port2RateAfter(IOPCIDevice *dev, uint8_t mi, double newRate, uint8_t rateCode,
                           Port2RateChange *p2)
{
    if (p2->ivars && !XLinkTxAdmissible(p2->ivars)) {
        STERR("ChangeSampleRate: stop began or endpoint gone — port 2 step skipped");
        return;
    }
    if (!SendXLinkCommandOn(dev, mi, kRegXLink2TX, kXLinkCmdAddrAll,
                            kXLinkCmdSetSampleRate, rateCode)) {
        STERR("ChangeSampleRate: port 2 SET_SAMPLE_RATE (second) timeout");
        return;
    }
    p2->sentNew = true;
    if (!WaitForLockOn(dev, mi, kRegXLink2Status, kPort2LockRateChangeMs)) {
        STERR("ChangeSampleRate: port 2 did not lock after the rate command");
        return;
    }
    const uint32_t expected = (uint32_t)newRate;
    uint32_t actual = 0;
    bool matched = false;
    for (int i = 0; i < 100; i++) {   // 100 × 10 ms, as port 1
        actual = GetActualClockRatePort2(dev, mi);
        if (actual == expected) { matched = true; break; }
        IOSleep(10);
    }
    p2->detectedHz = actual;
    if (!matched) {
        STERR("ChangeSampleRate: port 2 rate mismatch — expected %u, port 2 reports %u Hz",
              expected, actual);
        return;
    }
    if (!WaitForLockOn(dev, mi, kRegXLink2Status, kPort2LockRateChangeMs)) {
        STERR("ChangeSampleRate: port 2 final stability lock failed");
        return;
    }
    p2->ok = true;
    STLOG("ChangeSampleRate: port 2 at %u Hz (locked + rate-verified + stable)", actual);
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
// port2 (EXPERIMENT): null with one port, and then nothing below touches port 2.
static bool ChangeSampleRate(IOPCIDevice *dev, uint8_t memIndex, double newRate,
                             bool *outCommandIssued, Port2RateChange *port2 = nullptr,
                             bool legacyPCIe = false)
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
    SetDDSSampleRate(dev, memIndex, newRate, legacyPCIe);

    // EXPERIMENT: the original told port 2 first (XLink.cpp:991-1012).
    if (port2) Port2RateBefore(dev, memIndex, newRate, rateCode, port2);

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

    // EXPERIMENT: then port 2, as the original's per-bus loop did (bus 2
    // after bus 1). Not fatal in Stage 1; see Port2RateChange.
    if (port2 && port2->clock) Port2RateAfter(dev, memIndex, newRate, rateCode, port2);

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

    STLOG("DMA: Allocated %llu bytes, physAddr=0x%llx, dir=%{public}s",
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
// B7: with one unit, unit A's Loop Sync output byte follows the app's choice
// for this driver session (as a master; a Loop Sync slave keeps its 1).
static void ApplyOneUnitLoopSyncByte(const SymphonyThunderbridge_IVars *ivars, uint8_t bytes[4])
{
    if (ivars->unitBConfigured || ivars->convPort1 || bytes[0] == 3 || bytes[1] != 1) return;
    bytes[2] = ivars->oneUnitLoopSync ? 1 : 0;
}

// dext 152: what unit A holds after a ClockMode send (see unitAClockSent).
static void NoteUnitAClockSent(SymphonyThunderbridge_IVars *ivars, const uint8_t bytes[4], bool ok)
{
    if (ok) memcpy(ivars->unitAClockSent, bytes, 4);
    ivars->unitAClockSentKnown = ok;
}

static void ForgetSentClockAndOptical(SymphonyThunderbridge_IVars *ivars)
{
    ivars->unitAClockSentKnown = false;
    ivars->opticalSentKnown[0] = ivars->opticalSentKnown[1] = false;
    ivars->clockSkipLogged = ivars->opticalSkipLogged = false;
}

static void SilenceCardMixersForSleep(SymphonyThunderbridge_IVars *ivars);   // below
static void RestoreCardMixersAfterSleep(SymphonyThunderbridge_IVars *ivars); // below

struct SymphonyLinkInitResult {
    bool    lineMonitor;
    uint8_t monitorAttenuation;
    bool    monitorMute;
    uint8_t speakerAttenuation;
    bool    speakerMute;
    uint8_t hp1Attenuation;
    bool    hp1Mute;
    uint8_t hp2Attenuation;
    bool    hp2Mute;
    // As read from the unit (the fields above fold "64 dB" into the mute).
    bool    levelsRead;          // a Symphony vendor read answered in this set-up
    bool    speakerLevelRead;    // speakerAttenuation/Mute are the speakers' own (not a Line reading)
    bool    speakerMuteRaw;
    bool    hp1MuteRaw;
    bool    hp2MuteRaw;
};

static void ResetInputRouteSources(SymphonyThunderbridge_IVars *ivars,
                                   const uint8_t slotType[2], const bool slotKnown[2]);

// ── dext 150: the host channel order each unit was programmed with ──────────
// (kSelectorReadChannelOrder, SymphonyChannelOrderOutput.) One word per unit
// in channelOrderLatch: bits 0-7 the order (kSymphonyChannelOrder*), 8-15 and
// 16-23 slot 1's and slot 2's board type (0 when not read), bit 24 / 25 their
// known flags. 0 is kSymphonyChannelOrderNone with nothing known. The order
// follows from the types exactly as the tables do (SymphonyAnalogFirstApplies),
// so a latched word always describes tables SymphonyCaptureSource /
// SymphonyPlaybackSource build from its own types.
static uint32_t PackChannelOrder(const uint8_t type[2], const bool known[2])
{
    const uint8_t t[2] = { known[0] ? type[0] : (uint8_t)0, known[1] ? type[1] : (uint8_t)0 };
    const bool k[2] = { known[0], known[1] };
    const uint32_t order = SymphonyAnalogFirstApplies(t, k) ? kSymphonyChannelOrderAnalogFirst
                                                            : kSymphonyChannelOrderCardByCard;
    return order | ((uint32_t)t[0] << 8) | ((uint32_t)t[1] << 16) |
           (k[0] ? 1u << 24 : 0u) | (k[1] ? 1u << 25 : 0u);
}

static uint32_t UnpackChannelOrder(uint32_t word, uint8_t type[2], bool known[2])
{
    type[0] = (uint8_t)(word >> 8);
    type[1] = (uint8_t)(word >> 16);
    known[0] = (word & (1u << 24)) != 0;
    known[1] = (word & (1u << 25)) != 0;
    return word & 0xFFu;
}

// The order, types and known flags unit `unit`'s tables were last built from.
static uint32_t LatchedChannelOrder(SymphonyThunderbridge_IVars *ivars, uint32_t unit,
                                    uint8_t type[2], bool known[2])
{
    return UnpackChannelOrder(__atomic_load_n(&ivars->channelOrderLatch[unit & 1], __ATOMIC_ACQUIRE),
                              type, known);
}

// Latch a unit's word (0 = None); the generation moves only on a change.
static void LatchChannelOrder(SymphonyThunderbridge_IVars *ivars, uint32_t unit, uint32_t word)
{
    if (__atomic_exchange_n(&ivars->channelOrderLatch[unit & 1], word, __ATOMIC_ACQ_REL) != word)
        __atomic_add_fetch(&ivars->channelOrderGeneration, 1u, __ATOMIC_ACQ_REL);
}

static void RecomputeCardMixer(SymphonyThunderbridge_IVars *iv,
                               IOPCIDevice *dev, uint8_t mi,
                               uint16_t mixerID);
static void ApplyConverterTrim(SymphonyThunderbridge_IVars *ivars);

// Decide, once per bus init, whether the volume keys drive the converter trim.
// All three must hold, so a Symphony I/O can never take this path:
//   1. unit 1 and every unit after it named themselves as a known converter
//      (UnitProbeIsConvertersOnly; the probe only runs when 0x25 got no answer);
//   2. no Symphony vendor read answered during this bus init;
//   3. no Symphony vendor read has answered since Start() (a latch, so a unit
//      that once answered is never reclassified by a later missed read).
// Leaving converter mode puts the trim back to 0 dB, unmuted, on the card.
// Runs in Start() or on xlinkQueue. Returns the new mode.
static bool ClassifyVolumeTarget(SymphonyThunderbridge_IVars *ivars, bool vendorAnswered,
                                 const SymphonyLinkInitResult *symphony)
{
    if (vendorAnswered) {
        ivars->symphonyAnsweredSinceStart = true;
        // A successful Symphony read is authoritative even when the initial
        // probe timed out and produced a converter-looking INQUIRE word.
        // Clear that provisional word on every recovery path, not only the
        // startup branch that explicitly found convCandidate.
        ivars->unitProbeWord = 0;
    }
    const bool converters = !ivars->symphonyAnsweredSinceStart &&
                            (UnitProbeIsConvertersOnly(ivars->unitProbeWord) || __atomic_load_n(&ivars->convPort1, __ATOMIC_ACQUIRE));
    const bool was = __atomic_load_n(&ivars->converterVolumeKeys, __ATOMIC_ACQUIRE);
    if (was && !converters) {
        __atomic_store_n(&ivars->converterVolumeKeys, false, __ATOMIC_RELEASE);
        ivars->converterTrimAtten = 0;
        ivars->converterTrimMuted = false;
        ApplyConverterTrim(ivars);
        // While the keys trimmed the mixer, the session monitor values and the
        // HAL control followed the trim. Take the Symphony's own stored values
        // (just read back) so link recovery's replay and the next key press do
        // not send it the trim level (0 dB attenuation would be full volume).
        if (symphony->speakerLevelRead) {
            __atomic_store_n(&ivars->speakerAttenuation, symphony->speakerAttenuation, __ATOMIC_RELEASE);
            __atomic_store_n(&ivars->speakerMute, symphony->speakerMute, __ATOMIC_RELEASE);
        }
        ivars->speakerLevelKnown = symphony->speakerLevelRead;
        __atomic_store_n(&ivars->hp1Attenuation, symphony->hp1Attenuation, __ATOMIC_RELEASE);
        __atomic_store_n(&ivars->hp1Mute, symphony->hp1Mute, __ATOMIC_RELEASE);
        ivars->hp2Attenuation = symphony->hp2Attenuation;
        ivars->hp2Mute = symphony->hp2Mute;
        ivars->monitorLevelsKnown = symphony->levelsRead;
        if (ivars->outputVolumeControl)
            ivars->outputVolumeControl->SetDecibelValue(-static_cast<float>(symphony->monitorAttenuation));
        if (ivars->outputMuteControl)
            ivars->outputMuteControl->SetControlValue(symphony->monitorMute);
        STLOG("Volume keys: Symphony I/O behaviour (converter trim cleared; monitor atten=%u mute=%u)",
              symphony->monitorAttenuation, symphony->monitorMute ? 1 : 0);
    } else if (!was && converters) {
        // Converters found after the controls exist (powered on after Start(),
        // or a recovery): keep the level macOS already shows rather than
        // jumping to 0 dB. In Start() the controls do not exist yet and the
        // trim starts at 0 dB, where the control is then created.
        if (ivars->outputVolumeControl) {
            float db = ivars->outputVolumeControl->GetDecibelValue();
            if (db > 0.0f) db = 0.0f;
            if (db < -64.0f) db = -64.0f;
            ivars->converterTrimAtten = (uint8_t)(-db);
        }
        if (ivars->outputMuteControl)
            ivars->converterTrimMuted = ivars->outputMuteControl->GetControlValue();
        if (ivars->converterKeysOff) {
            // "None": no trim, and the controls show that.
            ivars->converterTrimAtten = 0;
            ivars->converterTrimMuted = false;
            if (ivars->outputVolumeControl) ivars->outputVolumeControl->SetDecibelValue(0.0f);
            if (ivars->outputMuteControl) ivars->outputMuteControl->SetControlValue(false);
        }
        __atomic_store_n(&ivars->converterVolumeKeys, true, __ATOMIC_RELEASE);
        STLOG("Volume keys: converters only, keys trim card mixer 1 (atten=%u mute=%u)",
              ivars->converterTrimAtten, ivars->converterTrimMuted ? 1 : 0);
    }
    return converters;
}

// ── dext 131: the older XLink converters ─────────────────────────────────────
// Apogee's driver ran AD-16X, DA-16X, DD-16X and Rosetta 800/200 units on
// either port (Symphony64 Driver/XLink.cpp BusInit :483-689, SetSampleRate
// :995-1150, EnableDeviceRouting :1862-1877, CheckLinkStatus/FrequencyStatus
// :1995-2512) and its daemon placed and named their channels
// (maestrolink SymphonyPCIeRoutingController.cpp, SymphonyPeripheralDevice.cpp).
// The rules are in SymphonyConverters.h. Everything here runs only once port 1
// has been positively identified as converters (convPort1), so a Symphony I/O
// never sees any of it.

// Converter state is written on xlinkQueue and read from other queues (channel
// names, the audio device's latency, the user client, StartDevice): every
// write goes through ConvSetPort under convLock, and readers off the queue
// take a copy under the same lock (ConvSnapshot) or read convPort1 atomically.
struct ConvSnapshotData {
    bool     port1;
    uint32_t count[2];
    uint32_t unit[2][4];
};
static bool ConvPort1(const SymphonyThunderbridge_IVars *ivars)
{
    return __atomic_load_n(&ivars->convPort1, __ATOMIC_ACQUIRE);
}
static void ConvSetPort(SymphonyThunderbridge_IVars *ivars, uint32_t port, bool present,
                        uint32_t count, const uint32_t *units)
{
    if (ivars->convLock) IOLockLock(ivars->convLock);
    // A different chain on this port: the user's routes were for other units.
    bool changed = ivars->convUnitCount[port] != (present ? count : 0);
    for (uint32_t u = 0; u < 4 && !changed; u++)
        if (ConverterRouting((uint8_t)(ivars->convUnit[port][u] & 0xFF), (uint8_t)(ivars->convUnit[port][u] >> 8))
            != ((present && units) ? ConverterRouting((uint8_t)(units[u] & 0xFF), (uint8_t)(units[u] >> 8)) : 0))
            changed = true;
    if (changed && (ivars->convOutRouteSet || ivars->convInRouteSet)) {
        ivars->convOutRouteSet = 0;
        ivars->convInRouteSet = 0;
        STLOG("Converter routing: the units changed — your converter routes are back to the default placement");
    }
    ivars->convUnitCount[port] = present ? count : 0;
    for (uint32_t u = 0; u < 4; u++) ivars->convUnit[port][u] = (present && units) ? units[u] : 0;
    if (port == 0) __atomic_store_n(&ivars->convPort1, present, __ATOMIC_RELEASE);
    if (ivars->convLock) IOLockUnlock(ivars->convLock);
}
static void ConvSnapshot(const SymphonyThunderbridge_IVars *ivars, ConvSnapshotData &d)
{
    if (ivars->convLock) IOLockLock(ivars->convLock);
    d.port1 = ivars->convPort1;
    for (uint32_t p = 0; p < 2; p++) {
        d.count[p] = ivars->convUnitCount[p];
        for (uint32_t u = 0; u < 4; u++) d.unit[p][u] = ivars->convUnit[p][u];
    }
    if (ivars->convLock) IOLockUnlock(ivars->convLock);
}

// A query that carries a data byte (AUTH_READ takes the byte index), else like
// XLinkInquireOn.
static bool XLinkQueryOn(IOPCIDevice *dev, uint8_t memIndex, uint64_t txRegister, uint64_t rxRegister,
                         uint8_t addr, uint8_t cmd, uint8_t data, uint8_t *outReply, bool pcieOrder)
{
    if (!SendXLinkCommandOn(dev, memIndex, txRegister, addr, cmd, data))
        return false;
    for (int ms = 0; ms < 20; ms++) {
        uint32_t word = 0;
        while (ReadXLinkRXWordOn(dev, memIndex, rxRegister, pcieOrder, &word)) {
            const uint8_t slot   = (uint8_t)((word & 0x0F000000u) >> 24);
            const uint8_t rxAddr = (uint8_t)((word & 0x007E0000u) >> 17);
            const uint8_t rxCmd  = (uint8_t)((word & 0x0001FE00u) >> 9);
            if (slot != 9 || rxAddr != addr || rxCmd != cmd)
                continue;
            *outReply = (uint8_t)((word & 0x000001FEu) >> 1);
            return true;
        }
        IOSleep(1);
    }
    return false;
}

// AuthenticateDevice (XLink.cpp:2922-2970): AUTH_START, 16 x AUTH_WRITE, 16 x
// AUTH_READ, then VerifyDataInDevice. The original refused a unit that failed
// (bus reset, BusInit fails, :635-650). This driver runs the same exchange and
// reports the result (kSymphonyConvUnitAuthRan/AuthOK) but refuses nothing: the
// check only protects the host, and a mistake here would lock out real units.
static uint32_t AuthenticateConverter(SymphonyThunderbridge_IVars *ivars, uint64_t tx, uint64_t rx,
                                      uint8_t addr, uint8_t routing, uint8_t inquire, int port)
{
    IOPCIDevice *dev = ivars->pciDevice;
    const uint8_t mi = ivars->barMemoryIndex;
    if (ivars->convAuthState == 0) ivars->convAuthState = 0x2545F491u;
    uint8_t out[kConverterAuthBytes], in[kConverterAuthBytes] = {};
    ConverterAuthChallenge(ivars->convAuthState, out);
    bool ok = SendXLinkCommandOn(dev, mi, tx, addr, kXLinkCmdAuthStart, 0);
    for (uint32_t i = 0; ok && i < kConverterAuthBytes; i++)
        ok = SendXLinkCommandOn(dev, mi, tx, addr, kXLinkCmdAuthWrite, out[i]);
    for (uint32_t i = 0; ok && i < kConverterAuthBytes; i++)
        ok = XLinkQueryOn(dev, mi, tx, rx, addr, kXLinkCmdAuthRead, (uint8_t)i, &in[i], ivars->isLegacyPCIe2100);
    const bool verified = ok && ConverterAuthVerify(out, in, ConverterAuthDeviceInfo(routing, inquire));
    STLOG("Converter: port %d unit %u authentication %{public}s", port, addr,
          !ok ? "did not complete" : verified ? "verified" : "FAILED (reported, unit kept)");
    return kSymphonyConvUnitAuthRan | (verified ? kSymphonyConvUnitAuthOK : 0u);
}

static uint8_t ConverterUnitRouting(uint32_t word)
{
    const uint8_t inquire = (uint8_t)(word & kSymphonyConvUnitInquireMask);
    const uint8_t xtd = (word & kSymphonyConvUnitXtdOK) ? (uint8_t)(word >> kSymphonyConvUnitXtdShift) : 0;
    return ConverterRouting(inquire, xtd);
}

// Every unit a known converter, from its own INQUIRE and XTD_INQUIRE answers
// (the original accepted any routing other than 0, XLink.cpp:601-660; a
// Symphony I/O is 0xFF). 0x0F (DD-16X, or an AD/DA-16X in Advanced routing)
// only with an XTD reply, since without one it looks like a Symphony I/O
// whose XTD answer was lost.
static bool UnitsAreConverters(const uint32_t *units, uint32_t count)
{
    if (count == 0) return false;
    for (uint32_t u = 0; u < count; u++) {
        const uint32_t w = units[u];
        if (!(w & kSymphonyConvUnitInquireOK)) return false;
        const uint8_t r = ConverterUnitRouting(w);
        if (r == kConverterRoutingRosetta || r == kConverterRoutingAD || r == kConverterRoutingDA) continue;
        if (r == kConverterRoutingDD && (w & kSymphonyConvUnitXtdOK)) continue;
        return false;
    }
    return true;
}

// The chain the placement and names follow: port 1's converters, and port 2's
// while 64 channels run with converters there. Device Type comes from the
// app's choice (convConfig).
static void BuildConverterChain(SymphonyThunderbridge_IVars *ivars, ConverterChain &c)
{
    c = ConverterChain{};
    const uint32_t config = __atomic_load_n(&ivars->convConfig, __ATOMIC_ACQUIRE);
    const uint32_t flags = __atomic_load_n(&ivars->convFlags, __ATOMIC_ACQUIRE);
    ConvSnapshotData d;
    ConvSnapshot(ivars, d);
    for (uint32_t port = 0; port < 2; port++) {
        if (port == 0 && !d.port1) continue;
        if (port == 1 && !(flags & kSymphonyConvPort2Converters)) continue;
        for (uint32_t u = 0; u < d.count[port] && u < kConverterMaxUnitsPerPort; u++) {
            const bool ddAsDA = (config >> (kSymphonyConvConfigDDAsDAShift + port * 4 + u)) & 1u;
            c.kind[port][c.count[port]++] = ConverterKindForRouting(ConverterUnitRouting(d.unit[port][u]), !ddAsDA);
        }
    }
}

// Keep Symphony naming tied to card input writes, including topology resets.
static void WriteCardInputRoute(SymphonyThunderbridge_IVars *iv, uint32_t host, uint32_t word)
{
    WriteRegister(iv->pciDevice, iv->barMemoryIndex, kRegInputRouting + host * 4, word);
    __atomic_store_n(&iv->cardInputRoute[host], word, __ATOMIC_RELEASE);
}

// Card routing for converters (routeSymphonyHW): host input h <- XLink RX of its
// unit channel's slot, XLink TX slot <- host output h (direct, as the original's
// default; mixers go nowhere until routed). Host channels and slots with
// nothing behind them are left disabled. With converters on port 1, port 1's
// entries are written, and port 2's while 64 channels run with converters
// there. With a Symphony I/O on port 1 and converters on port 2 (the mix
// Apogee supported), only port 2's entries are written, its host channels
// following the Symphony I/O's 32. A Symphony I/O alone never reaches this.
static void ApplyConverterRouting(SymphonyThunderbridge_IVars *ivars, const char *why)
{
    const bool port2 = (__atomic_load_n(&ivars->convFlags, __ATOMIC_ACQUIRE) & kSymphonyConvPort2Converters) != 0;
    if (!ivars->convPort1 && !port2) return;
    IOPCIDevice *dev = ivars->pciDevice;
    const uint8_t mi = ivars->barMemoryIndex;
    ConverterChain c;
    BuildConverterChain(ivars, c);
    const uint32_t hostBase = ivars->convPort1 ? 0 : kConverterChannelsPerPort;
    const uint32_t first = ivars->convPort1 ? 0 : kConverterChannelsPerPort;
    const uint32_t last = port2 ? 2 * kConverterChannelsPerPort : kConverterChannelsPerPort;
    ConverterChannel inMap[kConverterMaxHostChannels], outMap[kConverterMaxHostChannels];
    const uint32_t hostIn = ConverterHostMap(c, true, inMap);
    const uint32_t hostOut = ConverterHostMap(c, false, outMap);
    uint32_t inSrc[64] = {}, outSrc[64] = {};   // by host input / by XLink TX slot; 0 = disabled
    for (uint32_t h = 0; h < kConverterMaxHostChannels; h++) {
        const uint32_t host = h + hostBase;
        if (host >= 64) break;
        if (inMap[h].valid)
            inSrc[host] = (kTDM_XLinkRX0 + inMap[h].port * kConverterChannelsPerPort + inMap[h].slot) | kRoutingEnable;
        if (outMap[h].valid) {
            const uint32_t xl = outMap[h].port * kConverterChannelsPerPort + outMap[h].slot;
            // Every DAW output straight to its converter output, as the
            // original's default (ResetRouting cleared both mixers), so nothing
            // in the card mixer changes what the DAW plays. A mixer reaches an
            // output only when the user routes it there (0xB5).
            outSrc[xl] = (kTDM_PCIOut0 + host) | kRoutingEnable;
        }
    }
    // The user's routes (Maestro's routing pages) on top of the default.
    uint32_t edited = 0;
    for (uint32_t n = first; n < last; n++) {
        if (ivars->convInRouteSet & (1ull << n)) { inSrc[n] = ivars->convInRoute[n]; edited++; }
        if (ivars->convOutRouteSet & (1ull << n)) { outSrc[n] = ivars->convOutRoute[n]; edited++; }
    }
    for (uint32_t n = first; n < last; n++) {
        WriteCardInputRoute(ivars, n, inSrc[n]);
        WriteRegister(dev, mi, kRegOutputRouting + n * 4, outSrc[n]);
    }
    if (edited) STLOG("Converter routing: %u route(s) chosen in Maestro kept", edited);
    ivars->convHostIn = hostIn;
    ivars->convHostOut = hostOut;
    __atomic_or_fetch(&ivars->convFlags, kSymphonyConvRoutingApplied, __ATOMIC_RELEASE);
    STLOG("Converter routing (%{public}s): %u host input(s), %u host output(s) placed, entries %u-%u",
          why, hostIn, hostOut, first, last - 1);
}

// Converter latency (SymphonyPeripheralDevice::Latency), from the first unit of
// port 1 as the daemon took it. 0/0 when port 1 is not converters.
static void ConverterLatencyFor(SymphonyThunderbridge_IVars *ivars, double rate, uint32_t *in, uint32_t *out)
{
    *in = *out = 0;
    if (!ivars || !ConvPort1(ivars)) return;
    ConverterChain c;
    BuildConverterChain(ivars, c);
    if (c.count[0] == 0) return;
    *in = ConverterLatency(c.kind[0][0], (uint32_t)(rate + 0.5), true);
    *out = ConverterLatency(c.kind[0][0], (uint32_t)(rate + 0.5), false);
}

// Word clock of the first unit (SetWCMaster, XLink.cpp:1263-1270): Internal =
// SET_EXT_LOCK(addr 1, 0), External = SET_EXT_LOCK(broadcast, 1).
static void ApplyConverterWordClock(SymphonyThunderbridge_IVars *ivars)
{
    const bool external = (__atomic_load_n(&ivars->convConfig, __ATOMIC_ACQUIRE) & kSymphonyConvConfigClockExternal) != 0;
    const bool ok = external
        ? SendXLinkCommand(ivars->pciDevice, ivars->barMemoryIndex, kXLinkCmdAddrAll, kXLinkCmdSetExtLock, 1)
        : SendXLinkCommand(ivars->pciDevice, ivars->barMemoryIndex, 1, kXLinkCmdSetExtLock, 0);
    // SetExtLock waits for lock afterwards (XLink.cpp:1213).
    WaitForLock(ivars->pciDevice, ivars->barMemoryIndex, 5000);
    if (external) __atomic_or_fetch(&ivars->convFlags, kSymphonyConvClockExternal, __ATOMIC_RELEASE);
    else __atomic_and_fetch(&ivars->convFlags, ~kSymphonyConvClockExternal, __ATOMIC_RELEASE);
    STLOG("Converter: word clock %{public}s%{public}s", external ? "external" : "internal",
          ok ? "" : " (command timed out)");
}

// The part of SetSampleRate the converters need after their chain is known:
// the rate to every unit, wait for lock, check the card's measured rate, then
// the phase alignment (only with DMA stopped, as AlignXLinkPhase requires; with
// DMA running the recovery waits for a controlled restart) and, on the PCIe
// card, the frame-sync pulse.
static bool ConverterRateAndPhase(SymphonyThunderbridge_IVars *ivars, double rate, uint8_t rateCode,
                                  const char *why)
{
    IOPCIDevice *dev = ivars->pciDevice;
    const uint8_t mi = ivars->barMemoryIndex;
    SendXLinkCommand(dev, mi, kXLinkCmdAddrAll, kXLinkCmdSetSampleRate, rateCode);
    const bool locked = WaitForLock(dev, mi, 5000);   // WAIT_FOR_LOCK_AFTER_SRATE_CHANGE scale
    const uint32_t actual = GetActualClockRate(dev, mi);
    STLOG("Converter: rate %u Hz (%{public}s): data link %{public}s, card measures %u Hz",
          (uint32_t)(rate + 0.5), why, locked ? "LOCKED" : "still slipping", actual);
    if (!ivars->dmaRunning) {
        AlignXLinkPhase(ivars);
        if (ivars->isLegacyPCIe2100)
            PulseFrameSyncLegacyPCIe(dev, mi, "converter rate set");
        __atomic_store_n(&ivars->convRecoveryPending, false, __ATOMIC_RELEASE);
        __atomic_and_fetch(&ivars->convFlags, ~kSymphonyConvRecoveryPending, __ATOMIC_RELEASE);
    } else {
        __atomic_store_n(&ivars->convRecoveryPending, true, __ATOMIC_RELEASE);
        __atomic_or_fetch(&ivars->convFlags, kSymphonyConvRecoveryPending, __ATOMIC_RELEASE);
        STLOG("Converter: phase alignment waits for a controlled restart (audio is running)");
    }
    return locked;
}

// EnableDeviceRouting's UNMUTE to each unit by address (XLink.cpp:1873-1876).
static void UnmuteConverterUnits(SymphonyThunderbridge_IVars *ivars, uint64_t tx, uint32_t count)
{
    for (uint8_t addr = 1; addr <= count && addr <= kXLinkMaxDevices; addr++)
        if (!SendXLinkCommandOn(ivars->pciDevice, ivars->barMemoryIndex, tx, addr, kXLinkCmdUnmute, 0x80))
            STERR("Converter: UNMUTE to unit %u timed out", addr);
}

static bool ConfigureSymphonyLink(SymphonyThunderbridge_IVars *ivars, double rate,
                                  SymphonyLinkInitResult *out)
{
    // The unit may have been power-cycled or replaced: nothing is known to
    // be on it until this configuration sends it.
    ForgetSentClockAndOptical(ivars);
    // The capture routes below put every host input back on its board
    // channel (step 19b-2). Until then the tracked sources are the table the
    // driver last programmed into unit A (channelOrderLatch: the fixed
    // 16 + 16 before any configuration succeeded), so an app edit of the
    // capture routes is forgotten here as before, and a configuration that
    // fails before or at 19b leaves sources, names and selector 17 on the
    // same, previous, table. The coax replacement is the unit's, read back
    // by the app.
    {
        uint8_t latchedType[2];
        bool latchedKnown[2];
        LatchedChannelOrder(ivars, 0, latchedType, latchedKnown);
        ResetInputRouteSources(ivars, latchedType, latchedKnown);
    }
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

    // dext 131: converters already identified (a re-initialisation) take the
    // user's word clock here too, as BusInit's SetWCMaster(0, fExternalWC).
    if (ivars->convPort1 &&
        (__atomic_load_n(&ivars->convConfig, __ATOMIC_ACQUIRE) & kSymphonyConvConfigClockExternal)) {
        SendXLinkCommand(ivars->pciDevice, ivars->barMemoryIndex, kXLinkCmdAddrAll, kXLinkCmdSetExtLock, 1);
        STLOG("XLink: SET_EXT_LOCK(broadcast, external) — converters, external word clock");
    } else if (!SendXLinkCommand(ivars->pciDevice, ivars->barMemoryIndex,
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
    STLOG("XLink: WaitForLock (pre-enum): %{public}s", locked ? "LOCKED" : "TIMEOUT");

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

    if (ivars->convPort1 &&
        (__atomic_load_n(&ivars->convConfig, __ATOMIC_ACQUIRE) & kSymphonyConvConfigClockExternal)) {
        SendXLinkCommand(ivars->pciDevice, ivars->barMemoryIndex, kXLinkCmdAddrAll, kXLinkCmdSetExtLock, 1);
    } else if (!SendXLinkCommand(ivars->pciDevice, ivars->barMemoryIndex,
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
    STLOG("XLink: WaitForLock (post-enum): %{public}s", locked ? "LOCKED" : "TIMEOUT");

    // ── 18. Set sample rate ──────────────────────────────────────────
    // Legacy: SetDDSSampleRate() first, then SetSampleRate() sends to ADDR_ALL.

    // Set DDS first (legacy: SetDDSSampleRate before SetSampleRate). Start()
    // passes 44100; in-place recovery passes the rate the units last ran at.
    // dext 151: the rest of Start runs on the link at this rate, so it is not
    // deferred; Start's output gate instead stays closed until Core Audio's
    // saved rate is on the hardware (MaybeReleaseStartupOutputMute).
    SetDDSSampleRate(ivars->pciDevice, ivars->barMemoryIndex, rate, ivars->isLegacyPCIe2100);

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
    STLOG("XLink: WaitForLock (post-srate): %{public}s", locked ? "LOCKED" : "TIMEOUT");
    if (ivars->isLegacyPCIe2100 && locked) {
        // Original order after a rate set: phase jam, then frame sync. The jam is
        // written only while DMA is stopped and the card muted (Start()), as
        // AlignXLinkPhase requires; recovery with DMA running only pulses.
        if (!ivars->dmaRunning) AlignXLinkPhase(ivars);
        PulseFrameSyncLegacyPCIe(ivars->pciDevice, ivars->barMemoryIndex, "link sample-rate set");
    }

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
        // Each slot's card type, read at step 19b-0c; step 19b-2 lays the
        // capture table out from slot 1's.
        uint8_t slotType[2] = { kSIOOptionBoard_None, kSIOOptionBoard_None };
        bool slotTypeOK[2] = { false, false };

        // Preserve the Symphony IO's stored monitor state across a PCIe
        // reconnect.  The legacy ApplySettingsToHardware path re-read and
        // replayed these values; resetting to stereo/20 dB/unmuted here made
        // a power-cycle appear to change the user's output configuration.
        uint8_t startupMode = 2;       // Stereo fallback
        uint8_t startupVolume = 20;    // 20 dB attenuation fallback
        uint8_t startupMute = 0;       // unmuted fallback
        bool    speakerVolumeRead = false, speakerMuteRead = false;
        uint8_t startupActiveSet = 1;  // speaker set A fallback
        uint8_t startupHP1Volume = 20; // 20 dB attenuation fallback
        uint8_t startupHP1Mute = 0;    // unmuted fallback
        uint8_t startupHP2Volume = 20; // 20 dB attenuation fallback
        uint8_t startupHP2Mute = 0;    // unmuted fallback
        uint8_t readback = 0;
        bool vendorAnswered = false;   // any Symphony vendor read below answered
        // dext 131: converters found by the probe below. They are configured
        // only after every Symphony I/O read in this block has also gone
        // unanswered (a Symphony I/O that loses one read and answers INQUIRE
        // like a converter answers the later ones and stays a Symphony I/O).
        bool convCandidate = false;
        bool knownChain = false;       // the same converters as before (re-initialisation)
        uint32_t convCandidateUnits[kXLinkMaxDevices] = {};
        uint32_t convCandidateCount = 0;
        // A chain already identified as converters (re-initialisation): ask unit
        // 1 what it is first, as BusInit did. Still the same converter: no
        // Symphony I/O read at all. Anything else (a Symphony I/O swapped in
        // answers 0xFF) takes the usual path below.
        bool sameUnit1 = false;
        if (ivars->convPort1 && ivars->convUnitCount[0] > 0) {
            uint8_t i1 = 0, x1 = 0;
            const bool iOK = XLinkInquire(ivars->pciDevice, ivars->barMemoryIndex, symphonyAddr,
                                          kXLinkCmdInquire, &i1, ivars->isLegacyPCIe2100);
            const bool xOK = XLinkInquire(ivars->pciDevice, ivars->barMemoryIndex, symphonyAddr,
                                          kXLinkCmdXtdInquire, &x1, ivars->isLegacyPCIe2100);
            const uint32_t w = ivars->convUnit[0][0];
            sameUnit1 = iOK && ConverterRouting(i1, xOK ? x1 : 0) == ConverterUnitRouting(w) &&
                        ConverterUnitRouting(w) != kConverterRoutingSymphony;
        }
        if (!sameUnit1 && ReadVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                              symphonyAddr, kSIOCmd_SpeakerMode, 0,
                              &readback, 1, txSeq,
        ivars->isLegacyPCIe2100)) {
            vendorAnswered = true;
            startupMode = readback;
            // A Symphony I/O. Cleared here and not before the read, so the app
            // never sees the answer vanish for the length of a re-init.
            ivars->unitProbeWord = 0;
            if (ivars->convPort1) {
                ConvSetPort(ivars, 0, false, 0, nullptr);
                __atomic_and_fetch(&ivars->convFlags, ~(kSymphonyConvPort1Converters | kSymphonyConvRoutingApplied), __ATOMIC_RELEASE);
            }
        } else {
            // The unit did not answer a Symphony I/O vendor read. It may be one
            // of the older converters Apogee's driver also supported on this
            // cable (AD-16X, DA-16X, DD-16X, Rosetta 800), which do not speak
            // that protocol. Ask it what it is, the way the original did, and
            // publish the answer for the app. This only reports: nothing else
            // about the bring-up below changes yet. A Symphony I/O that answers
            // never reaches this branch.
            uint8_t inquire = 0, xtd = 0;
            uint32_t probe = kUnitProbeRan;
            if (XLinkInquire(ivars->pciDevice, ivars->barMemoryIndex,
                             symphonyAddr, kXLinkCmdInquire, &inquire,
        ivars->isLegacyPCIe2100))
                probe |= kUnitProbeInquireOK | inquire;
            if (XLinkInquire(ivars->pciDevice, ivars->barMemoryIndex,
                             symphonyAddr, kXLinkCmdXtdInquire, &xtd,
        ivars->isLegacyPCIe2100))
                probe |= kUnitProbeXtdOK | ((uint32_t)xtd << 8);
            STLOG("Unit probe: no Symphony I/O answer; INQUIRE %{public}s 0x%02x, XTD_INQUIRE %{public}s 0x%02x",
                  (probe & kUnitProbeInquireOK) ? "replied" : "no reply", inquire,
                  (probe & kUnitProbeXtdOK) ? "replied" : "no reply", xtd);

            // Converters were normally chained (an AD-16X feeding a DA-16X, and
            // so on). The original found each further unit the way it found the
            // first (Driver/XLink.cpp BusInit :596-660): once a unit passes
            // commands on, ask the broadcast address what is next (routing:
            // INQUIRE + XTD_INQUIRE; firmware: XTD_INQUIRE, INQUIRE; DEVICE_TYPE),
            // stop at a unit with no channels, else SET_ADDR, DEVICE_TYPE at the
            // new address, authenticate (AuthenticateConverter) and PASS_COMMANDS.
            // Up to four units (XLINK_MAX_DEVICES). Unit 1 was addressed above,
            // so this continues from address 2, and only when unit 1 identified
            // itself as one of the older converters.
            uint32_t units[kXLinkMaxDevices] = {};
            units[0] = (probe & kUnitProbeInquireOK ? (kSymphonyConvUnitInquireOK | inquire) : 0)
                     | (probe & kUnitProbeXtdOK ? (kSymphonyConvUnitXtdOK | ((uint32_t)xtd << kSymphonyConvUnitXtdShift)) : 0)
                     | kSymphonyConvUnitAddressed;
            uint32_t unitCount = (probe & kUnitProbeInquireOK) ? 1 : 0;
            // The rest of BusInit's per-unit sequence (firmware, DEVICE_TYPE,
            // authentication) only when unit 1 itself identifies as a converter;
            // anything else gets the plain walk it always had.
            const bool unit1Converter = !ivars->symphonyAnsweredSinceStart && UnitsAreConverters(units, 1);
            if ((probe & kUnitProbeInquireOK) && (inquire >> 4) != 0) {
                for (uint8_t addr = 2; addr <= kXLinkMaxDevices; addr++) {
                    uint8_t next = 0, nextXtd = 0, scratch = 0;
                    if (!XLinkInquire(ivars->pciDevice, ivars->barMemoryIndex,
                                      kXLinkCmdAddrAll, kXLinkCmdInquire, &next,
        ivars->isLegacyPCIe2100)
                        || (next >> 4) == 0) {
                        STLOG("Unit probe: no further unit after address %u", addr - 1);
                        break;
                    }
                    bool nextXtdOK = false;
                    if (unit1Converter) {
                        nextXtdOK = XLinkInquire(ivars->pciDevice, ivars->barMemoryIndex,
                                                 kXLinkCmdAddrAll, kXLinkCmdXtdInquire, &nextXtd,
                                                 ivars->isLegacyPCIe2100);
                        XLinkInquire(ivars->pciDevice, ivars->barMemoryIndex, kXLinkCmdAddrAll,
                                     kXLinkCmdXtdInquire, &scratch, ivars->isLegacyPCIe2100);   // major firmware
                        XLinkInquire(ivars->pciDevice, ivars->barMemoryIndex, kXLinkCmdAddrAll,
                                     kXLinkCmdInquire, &scratch, ivars->isLegacyPCIe2100);      // minor firmware
                        XLinkInquire(ivars->pciDevice, ivars->barMemoryIndex, kXLinkCmdAddrAll,
                                     kXLinkCmdDeviceType, &scratch, ivars->isLegacyPCIe2100);
                    }
                    if (!SendXLinkCommand(ivars->pciDevice, ivars->barMemoryIndex,
                                          kXLinkCmdAddrAll, kXLinkCmdSetAddr, addr)) {
                        STERR("Unit probe: could not address unit %u", addr);
                        break;
                    }
                    uint32_t word = kSymphonyConvUnitInquireOK | next
                                  | (nextXtdOK ? (kSymphonyConvUnitXtdOK | ((uint32_t)nextXtd << kSymphonyConvUnitXtdShift)) : 0);
                    if (unit1Converter) {
                        XLinkInquire(ivars->pciDevice, ivars->barMemoryIndex, addr,
                                     kXLinkCmdDeviceType, &scratch, ivars->isLegacyPCIe2100);
                        word |= AuthenticateConverter(ivars, kRegXLink1TX, kRegXLink1RX, addr,
                                                      ConverterUnitRouting(word), next, 1);
                    }
                    if (!SendXLinkCommand(ivars->pciDevice, ivars->barMemoryIndex,
                                          addr, kXLinkCmdPassCommands, 1)) {
                        STERR("Unit probe: could not address unit %u", addr);
                        units[unitCount++] = word;
                        break;
                    }
                    IOSleep(5);
                    units[unitCount++] = word | kSymphonyConvUnitAddressed;
                    probe |= (uint32_t)(next >> 4) << (16 + 4 * (addr - 2));
                    STLOG("Unit probe: unit %u INQUIRE 0x%02x XTD_INQUIRE %{public}s 0x%02x, addressed",
                          addr, next, nextXtdOK ? "replied" : "no reply", nextXtd);
                }
            }
            ivars->unitProbeWord = probe;
            for (uint32_t n = 0; n < kMaxChannelsPerPort; n += 8) {
                uint32_t r[8] = {};
                for (uint32_t k = 0; k < 8; k++)
                    ivars->pciDevice->MemoryRead32(ivars->barMemoryIndex,
                                                   kRegOutputRouting + (n + k) * 4, &r[k]);
                STLOG("Unit probe: output routes %u-%u: %03x %03x %03x %03x %03x %03x %03x %03x",
                      n, n + 7, r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7]);
            }

            // Converters only, positively: never a Symphony I/O since Start(),
            // the probe word names known converters only, and unit 1 answers
            // INQUIRE the same way a second time. Anything less keeps the
            // Symphony I/O behaviour below, and nothing converter-specific is sent.
            uint8_t again = 0;
            const bool stable = (probe & kUnitProbeInquireOK) &&
                XLinkInquire(ivars->pciDevice, ivars->barMemoryIndex, symphonyAddr,
                             kXLinkCmdInquire, &again, ivars->isLegacyPCIe2100) && again == inquire;
            if (!ivars->symphonyAnsweredSinceStart && UnitsAreConverters(units, unitCount) && stable) {
                convCandidate = true;
                convCandidateCount = unitCount;
                for (uint32_t u = 0; u < kXLinkMaxDevices; u++) convCandidateUnits[u] = units[u];
                // Re-initialising a chain already identified as these same units
                // (word clock change, recovery): the first read above already
                // went unanswered, so the rest of the Symphony reads are skipped,
                // as the original sent none to converters.
                if (ivars->convPort1 && ivars->convUnitCount[0] == unitCount) {
                    knownChain = true;
                    for (uint32_t u = 0; u < unitCount; u++)
                        if (ConverterUnitRouting(ivars->convUnit[0][u]) != ConverterUnitRouting(units[u])) knownChain = false;
                }
            }
            if (!convCandidate && ivars->convPort1) {
                STLOG("Converter: port 1 no longer identifies as converters; Symphony I/O behaviour");
                ConvSetPort(ivars, 0, false, 0, nullptr);
                __atomic_and_fetch(&ivars->convFlags, ~(kSymphonyConvPort1Converters | kSymphonyConvRoutingApplied), __ATOMIC_RELEASE);
            }
        }
        if (!knownChain && ReadVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                              symphonyAddr, kSIOCmd_SpeakerVolume, 0,
                              &readback, 1, txSeq,
        ivars->isLegacyPCIe2100)) {
            vendorAnswered = true;
            startupVolume = (readback > 64) ? 64 : readback;
            speakerVolumeRead = true;
        }
        if (!knownChain && ReadVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                              symphonyAddr, kSIOCmd_SpeakerMute, 0,
                              &readback, 1, txSeq,
        ivars->isLegacyPCIe2100)) {
            vendorAnswered = true;
            startupMute = readback ? 1 : 0;
            speakerMuteRead = true;
        }
        // In Line the readings above are the unit's 0, not the speakers'
        // level: keep what this driver instance already knew, else nothing.
        bool speakerLevelRead = speakerVolumeRead && speakerMuteRead;
        if (startupMode == 0) {
            speakerLevelRead = ivars->speakerLevelKnown;
            if (ivars->speakerLevelKnown) {
                startupVolume = __atomic_load_n(&ivars->speakerAttenuation, __ATOMIC_ACQUIRE);
                startupMute = __atomic_load_n(&ivars->speakerMute, __ATOMIC_ACQUIRE) ? 1 : 0;
            } else {
                startupVolume = 20;
                startupMute = 0;
            }
        }
        if (!knownChain && ReadVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                              symphonyAddr, kSIOCmd_ActiveSpeakerSet, 0,
                              &readback, 1, txSeq,
        ivars->isLegacyPCIe2100)) {
            vendorAnswered = true;
            startupActiveSet = readback & 0x07;
            if (startupActiveSet == 0) startupActiveSet = 1;
        }
        if (!knownChain && ReadVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                              symphonyAddr, kSIOCmd_HeadphoneVolume, 0,
                              &readback, 1, txSeq,
        ivars->isLegacyPCIe2100)) {
            vendorAnswered = true;
            startupHP1Volume = (readback > 64) ? 64 : readback;
        }
        if (!knownChain && ReadVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                              symphonyAddr, kSIOCmd_HeadphoneMute, 0,
                              &readback, 1, txSeq,
        ivars->isLegacyPCIe2100)) {
            vendorAnswered = true;
            startupHP1Mute = readback ? 1 : 0;
        }
        if (!knownChain && ReadVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                              symphonyAddr, kSIOCmd_HeadphoneVolume, 1,
                              &readback, 1, txSeq,
        ivars->isLegacyPCIe2100)) {
            vendorAnswered = true;
            startupHP2Volume = (readback > 64) ? 64 : readback;
        }
        if (!knownChain && ReadVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                              symphonyAddr, kSIOCmd_HeadphoneMute, 1,
                              &readback, 1, txSeq,
        ivars->isLegacyPCIe2100)) {
            vendorAnswered = true;
            startupHP2Mute = readback ? 1 : 0;
        }
        STLOG("SymphonyIO: restored monitor state mode=%u speakerVolume=%u speakerMute=%u "
              "hp1Volume=%u hp1Mute=%u hp2Volume=%u hp2Mute=%u activeSet=0x%02x",
              startupMode, startupVolume, startupMute, startupHP1Volume,
              startupHP1Mute, startupHP2Volume, startupHP2Mute, startupActiveSet);
        if (convCandidate && !vendorAnswered && !ivars->symphonyAnsweredSinceStart) {
            uint32_t units[kXLinkMaxDevices];
            for (uint32_t u = 0; u < kXLinkMaxDevices; u++) units[u] = convCandidateUnits[u];
            const uint32_t unitCount = convCandidateCount;

            {
                uint8_t type1 = 0;   // BusInit asks every unit its DEVICE_TYPE at its address
                XLinkInquire(ivars->pciDevice, ivars->barMemoryIndex, 1, kXLinkCmdDeviceType, &type1,
                             ivars->isLegacyPCIe2100);
            }
            units[0] |= AuthenticateConverter(ivars, kRegXLink1TX, kRegXLink1RX, 1,
                                              ConverterUnitRouting(units[0]),
                                              (uint8_t)(units[0] & kSymphonyConvUnitInquireMask), 1);
            ConvSetPort(ivars, 0, true, unitCount, units);
            __atomic_or_fetch(&ivars->convFlags, kSymphonyConvPort1Converters, __ATOMIC_RELEASE);
            STLOG("Converter: port 1 carries %u converter unit(s); Symphony I/O set-up skipped", unitCount);
            // No Symphony I/O on port 1, so no unit A tables (selector 17
            // reports None) and the tracked sources go back to the fixed
            // 16 + 16 a later Symphony I/O starts from.
            LatchChannelOrder(ivars, 0, 0);
            {
                uint8_t noneType[2];
                bool noneKnown[2];
                UnpackChannelOrder(0, noneType, noneKnown);
                ResetInputRouteSources(ivars, noneType, noneKnown);
            }
            // A Symphony I/O's clock choice does not outlive the unit: one
            // plugged in after these converters starts on Internal again.
            ivars->unitAClockKnown = false;
            // SetWCMaster after enumeration, the rate set with lock, actual
            // rate and phase, EnableDeviceRouting's per-unit unmute, and the
            // routing layer's placement.
            ApplyConverterWordClock(ivars);
            if (ConverterRateAndPhase(ivars, rate, rateCode, "after enumeration")) {
                UnmuteConverterUnits(ivars, kRegXLink1TX, unitCount);
                ivars->convRateUnlocked = false;
            } else {
                // The original kept the outputs muted (kMUTEDeviceNotConfigured)
                // and tried the rate set again until the units locked. The units
                // stay muted here and the health check re-initialises the chain.
                ivars->convRateUnlocked = true;
                STERR("Converter: the units did not lock to %u Hz — kept muted, will try again",
                      (uint32_t)(rate + 0.5));
            }
            ApplyConverterRouting(ivars, "link configured");
            // No Symphony I/O vendor traffic to a converter (the original sent
            // its messages to Symphony I/O units only). Monitor state: the
            // converter trim (ClassifyVolumeTarget).
            out->lineMonitor = false;
            out->speakerAttenuation = startupVolume;
            out->speakerMute = startupMute != 0;
            out->hp1Attenuation = startupHP1Volume;
            out->hp1Mute = startupHP1Mute != 0;
            out->hp2Attenuation = startupHP2Volume;
            out->hp2Mute = startupHP2Mute != 0;
            out->monitorAttenuation = startupVolume;
            out->monitorMute = startupMute != 0;
            if (ClassifyVolumeTarget(ivars, false, out)) {
                out->monitorAttenuation = ivars->converterTrimAtten;
                out->monitorMute = ivars->converterTrimMuted;
            }
            return true;
        } else if (convCandidate || ivars->convPort1) {
            STLOG("Converter: a Symphony I/O read answered after the probe — Symphony I/O behaviour");
            // The probe is only provisional.  Once any Symphony vendor read
            // answers, never publish the converter word from the earlier
            // timeout/INQUIRE race (the app decodes this word independently
            // of the converter-state selector).
            ivars->unitProbeWord = 0;
            ConvSetPort(ivars, 0, false, 0, nullptr);
            __atomic_and_fetch(&ivars->convFlags, ~(kSymphonyConvPort1Converters | kSymphonyConvRoutingApplied), __ATOMIC_RELEASE);
        }
        out->lineMonitor = startupMode == 0;
        out->speakerAttenuation = startupVolume;
        out->speakerMute = (startupMute != 0 || startupVolume >= 64);
        out->hp1Attenuation = startupHP1Volume;
        out->hp1Mute = (startupHP1Mute != 0 || startupHP1Volume >= 64);
        out->hp2Attenuation = startupHP2Volume;
        out->hp2Mute = (startupHP2Mute != 0 || startupHP2Volume >= 64);
        out->levelsRead = vendorAnswered;
        out->speakerLevelRead = speakerLevelRead;
        out->speakerMuteRaw = startupMute != 0;
        out->hp1MuteRaw = startupHP1Mute != 0;
        out->hp2MuteRaw = startupHP2Mute != 0;
        // What the volume control shows: the app's Audio Output choice, or,
        // until the app has chosen in this driver instance, Headphone 1 in
        // Line mode and the speakers otherwise (monitorOutputChosen). With
        // Speakers chosen in Line mode the control reads the original's fixed
        // -20 dB (SymphonyIO.cpp:3145-3152) and the volume keys do nothing.
        if (!ivars->monitorOutputChosen[0])
            ivars->monitorOutputTarget = out->lineMonitor ? kSymphonyMonitorOutputHP1 : kSymphonyMonitorOutputSpeakers;
        switch (ivars->monitorOutputTarget) {
        case kSymphonyMonitorOutputHP1:
            out->monitorAttenuation = out->hp1Attenuation;
            out->monitorMute = out->hp1Mute;
            break;
        case kSymphonyMonitorOutputHP2:
            out->monitorAttenuation = out->hp2Attenuation;
            out->monitorMute = out->hp2Mute;
            break;
        default:
            out->monitorAttenuation = out->lineMonitor ? kLineModeSpeakerReading : startupVolume;
            out->monitorMute = out->speakerMute;
            break;
        }

        // Where the volume keys go. On a cable of converters only, the single
        // Core Audio volume/mute control becomes a trim on card mixer 1 and
        // starts from that trim (0 dB the first time), not from the -20 dB
        // fallback above. Anything else keeps the Symphony I/O behaviour.
        if (ClassifyVolumeTarget(ivars, vendorAnswered, out)) {
            out->lineMonitor = false;
            out->monitorAttenuation = ivars->converterTrimAtten;
            out->monitorMute = ivars->converterTrimMuted;
        }

        // ── 19b-0a. PreferenceLoadLock(true) — mute XMOS while configuring ──
        // Legacy: ApplySettingsToHardware() locks before any routing changes.
        // Without this, the XMOS may apply partial routing and produce glitches.
        // Without the final unlock (step 19b-4), XMOS stays muted = total silence.
        // Evidence: MaestroVolumeProxy.c:783-786 configure_fpga_routing() step 1.
        //
        // dext 152, log only: on the first configuration of this driver
        // instance (Start, or the unit's first appearance after it), whether
        // the unit already holds a preference lock before the driver's own.
        // Groundwork for telling a replug from a power cycle; nothing
        // depends on it.
        if (ivars->linkRecoveryCount == 0 && !ivars->symphonyLinkConfigured) {
            uint8_t locked = 0xFF;
            const bool read = ReadVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                                symphonyAddr, kSIOCmd_PreferenceLoadLock,
                                                0, &locked, 1, txSeq, ivars->isLegacyPCIe2100);
            if (read) STLOG("SymphonyIO: unit found locked=%u at start", locked);
            else STLOG("SymphonyIO: unit lock state at start not read");
        }
        {
            uint8_t lock = 1;
            bool ok = SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                         symphonyAddr, kSIOCmd_PreferenceLoadLock,
                                         0, &lock, 1, txSeq);
            STLOG("SymphonyIO: PreferenceLoadLock(LOCK): %{public}s", ok ? "OK" : "FAILED");
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
            STLOG("SymphonyIO: SpeakerMode(mode=%u): %{public}s", mode, ok ? "OK" : "FAILED");
            if (ok) __atomic_store_n(&ivars->lineMode, mode == 0, __ATOMIC_RELEASE);
            IOSleep(10);

            // No speaker level is sent in Line: the unit ignores it there,
            // and the value would be the unit's 0. Outside Line the bring-up
            // sends what it read, or its fallback when nothing answered, as
            // before.
            if (startupMode != 0) {
                uint8_t vol = startupVolume;
                ok = SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                        symphonyAddr, kSIOCmd_SpeakerVolume,
                                        0, &vol, 1, txSeq);
                STLOG("SymphonyIO: SpeakerVolume(atten=%u dB): %{public}s", vol, ok ? "OK" : "FAILED");
                IOSleep(10);

                uint8_t mute = startupMute;
                ok = SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                        symphonyAddr, kSIOCmd_SpeakerMute,
                                        0, &mute, 1, txSeq);
                STLOG("SymphonyIO: SpeakerMute(unmuted): %{public}s", ok ? "OK" : "FAILED");
                IOSleep(10);
            } else {
                STLOG("SymphonyIO: speaker level not sent (Line)");
            }

            // Legacy ApplySettingsToHardware replays the active speaker-set
            // mask after the output mode.  The default is set A; omitting
            // this write leaves multi-set modes dependent on stale hardware
            // state after a reconnect.
            uint8_t activeSet = startupActiveSet;
            ok = SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                   symphonyAddr, kSIOCmd_ActiveSpeakerSet,
                                   0, &activeSet, 1, txSeq);
            STLOG("SymphonyIO: ActiveSpeakerSet(mask=0x%02x): %{public}s",
                  activeSet, ok ? "OK" : "FAILED");
            IOSleep(10);

            // The legacy ApplySettingsToHardware path also replays both
            // headphone controls during reconnect.  Keep HP2 in sync even
            // when it is not the currently selected Core Audio monitor.
            uint8_t hp1Volume = startupHP1Volume;
            ok = SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                   symphonyAddr, kSIOCmd_HeadphoneVolume,
                                   0, &hp1Volume, 1, txSeq);
            STLOG("SymphonyIO: HeadphoneVolume(HP1 atten=%u): %{public}s",
                  hp1Volume, ok ? "OK" : "FAILED");
            IOSleep(10);

            uint8_t hp1Mute = startupHP1Mute;
            ok = SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                   symphonyAddr, kSIOCmd_HeadphoneMute,
                                   0, &hp1Mute, 1, txSeq);
            STLOG("SymphonyIO: HeadphoneMute(HP1=%u): %{public}s",
                  hp1Mute, ok ? "OK" : "FAILED");
            IOSleep(10);

            uint8_t hp2Volume = startupHP2Volume;
            ok = SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                   symphonyAddr, kSIOCmd_HeadphoneVolume,
                                   1, &hp2Volume, 1, txSeq);
            STLOG("SymphonyIO: HeadphoneVolume(HP2 atten=%u): %{public}s",
                  hp2Volume, ok ? "OK" : "FAILED");
            IOSleep(10);

            uint8_t hp2Mute = startupHP2Mute;
            ok = SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                   symphonyAddr, kSIOCmd_HeadphoneMute,
                                   1, &hp2Mute, 1, txSeq);
            STLOG("SymphonyIO: HeadphoneMute(HP2=%u): %{public}s",
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
        // dext 140: when this set-up runs again in the same session (link
        // recovery, wake, a card reset), the clock source chosen since Start()
        // is sent, not Internal: the original applied the saved source in this
        // same step every time (SymphonyIO::ApplySettingsToHardware ->
        // SetClockSource(m_nCurrentClockSourceID, true), SymphonyIO.cpp:4660-4695).
        // Before, a recovery put the unit on Internal while the Clock Source
        // menu still read Word Clock. The first set-up after Start() knows no
        // choice yet and sends Internal, as before; Core Audio then restores
        // the saved source through the selector.
        {
            uint8_t clockData[4] = { 0x01, 0x01, 0x00, 0x00 };  // Internal, Master
            const bool chosen = ivars->unitAClockKnown && ivars->unitAClock[0] >= 1 && ivars->unitAClock[0] <= 5;
            if (chosen) memcpy(clockData, ivars->unitAClock, 4);
            ApplyOneUnitLoopSyncByte(ivars, clockData);
            bool ok = SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                         symphonyAddr, kSIOCmd_ClockMode,
                                         0, clockData, sizeof(clockData), txSeq);
            memcpy(ivars->unitAClock, clockData, 4);   // dext 131: unit A's last ClockMode
            ivars->unitAClockKnown = true;
            NoteUnitAClockSent(ivars, clockData, ok);
            if (chosen && clockData[0] != 1)
                STLOG("SymphonyIO: ClockMode(source %u, master %u, loop sync %u) re-applied: %{public}s",
                      clockData[0], clockData[1], clockData[2], ok ? "OK" : "FAILED");
            else
                STLOG("SymphonyIO: ClockMode(Internal, Master): %{public}s", ok ? "OK" : "FAILED");
            IOSleep(10);
        }

        // ── 19b-0c. Set optical format to ADAT/SMUX on both IOBoards ──
        // The ADAT optical port needs its frame generator configured.
        // cmd 0x34: nValue = board index (0 or 1), data = 0 for ADAT/SMUX.
        // Harmless if a board slot is empty.
        // Evidence: MaestroVolumeProxy.c:821-835 configure_fpga_routing() step 3a.
        //
        // Not sent to an AES board. The original never sent an optical format
        // to one and the firmware does nothing with it
        // (og_source/symphonymk1/ext/SymphonyIO/Software/XMOS/SymphonyIO/src/
        // Bulldog/MAL/MainController/AudioManager/SymphonyIOAudioManager.cpp:257-290;
        // see SymphonyOptionBoard.h). The slot's type is read first (0xA1, the
        // same bounded read Start() and link recovery use); if that read fails
        // the send goes out as before.
        //
        // The format sent is the one chosen through the driver's optical
        // control this session (ADAT/SMUX, 0, until one is chosen), so a link
        // recovery puts back what the user had, as the daemon re-applied its
        // saved settings (SymphonyIO_IOBoard.cpp:527-566,
        // OpticalIn_SymphonyIO_Stream.cpp:387-396). Across a driver restart the
        // app replays the Mac's saved formats after it connects.
        {
            const char* result[2] = { "skipped", "skipped" };
            for (uint32_t b = 0; b < 2; b++) {
                uint8_t bt = kSIOOptionBoard_None;
                bool typeOK = ReadVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                                symphonyAddr, kSIOCmd_OptionBoardType,
                                                b, &bt, 1, txSeq,
        ivars->isLegacyPCIe2100);
                slotType[b] = bt;
                slotTypeOK[b] = typeOK;
                if (!BootSendsOpticalFormat(typeOK, bt)) {
                    STLOG("SymphonyIO: OpticalFormat board%u skipped (AES board, type %u)",
                          b, bt);
                    continue;
                }
                uint8_t format = __atomic_load_n(&ivars->pendingOpticalFmt[b], __ATOMIC_ACQUIRE) ? 1 : 0;
                bool ok = SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                            symphonyAddr, kSIOCmd_OpticalFormat,
                                            b, &format, 1, txSeq);
                result[b] = ok ? (format ? "OK (SPDIF)" : "OK (ADAT/SMUX)") : "FAILED";
                ivars->opticalSent[b] = format;
                ivars->opticalSentKnown[b] = ok;
                IOSleep(10);
            }
            STLOG("SymphonyIO: OpticalFormat: board0=%{public}s, board1=%{public}s", result[0], result[1]);
            // S/PDIF Coax Replaces and Mirrors written this session, likewise
            // (the firmware starts at Off / Analog 1-2, SymphonyIOStateData.cpp:127-131).
            // Only to the type of card they were chosen for: after a card
            // swap the same number names a different pair, so they are
            // dropped and the new card keeps the firmware's defaults.
            for (uint32_t b = 0; b < 2; b++) {
                uint8_t setFor = __atomic_load_n(&ivars->sessionCoaxBoardType[b], __ATOMIC_ACQUIRE);
                if (!ReplaysCoaxSettings(slotTypeOK[b], slotType[b], setFor)) {
                    if (slotTypeOK[b] && setFor != kSIOOptionBoard_None) {
                        __atomic_store_n(&ivars->namingCoaxReplace[b], (uint8_t)0, __ATOMIC_RELEASE);
                        __atomic_store_n(&ivars->sessionCoaxMirror[b], (uint8_t)0, __ATOMIC_RELEASE);
                        __atomic_store_n(&ivars->sessionCoaxBoardType[b], (uint8_t)0, __ATOMIC_RELEASE);
                        STLOG("SymphonyIO: S/PDIF Coax board%u not replayed (card type %u, was %u)",
                              b, slotType[b], setFor);
                    }
                    continue;
                }
                uint8_t replace = __atomic_load_n(&ivars->namingCoaxReplace[b], __ATOMIC_ACQUIRE);
                uint8_t mirror = __atomic_load_n(&ivars->sessionCoaxMirror[b], __ATOMIC_ACQUIRE);
                if (replace >= 1 && replace <= 8)
                    SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex, symphonyAddr,
                                      kSIOCmd_SPDIFCoaxReplaceInput, b, &replace, 1, txSeq);
                if (mirror >= 1 && mirror <= 8)
                    SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex, symphonyAddr,
                                      kSIOCmd_SPDIFCoaxMirrorOutput, b, &mirror, 1, txSeq);
            }
        }

        // ── 19b-1. Playback routing: XLink → board outputs, analog first ──
        // dext 150: the n-th board output in the unit's host channel order
        // (every analog output of slot 1, then of slot 2, then slot 1's
        // digital outputs, then slot 2's: SymphonyHostChannelOrder,
        // SymphonyChannelNames.h) plays XLink n, which the card feeds from
        // host playback n (step 21b), as the original's ResetRouting routed
        // software output n to sorted hardware plug n
        // (og_source/symphonymk1/ext/maestrolink/Software/
        // SymphonyPCIeRoutingController.cpp:849-952, SymphonyIO_Stream.cpp:
        // 138-185). A board output with no host channel behind it plays None.
        // While either slot's type is unknown the table stays by position
        // (XLink 0-15 → slot 1's outputs, 16-31 → slot 2's), as builds up to
        // 149 programmed it for every unit (SymphonyPlaybackSource).
        // Every output is fed directly from XLink. An attempt to route ch0/1
        // through Mixer0 (XLink→SW Return→DAC) went silent on hardware — the
        // mixer's SW Return input (0xE4) does not accept an XLink (0x00)
        // source; the USB proxy feeds it from P2P (0xC0).
        //
        // ── 19b-1b. Board 1's outputs in their own 0x31 request ──────
        // A Symphony I/O occupies 32 channels on its XLink port
        // (MAX_SYMPHONY_CHANNELS_ON_BUS), so XLink 0-31 reach both boards
        // between them. Builds ≤110 mirrored XLink 0-15 onto both boards,
        // which made board 1 unaddressable.
        // Whether every 0x31 send of 19b-1, 19b-1b, 19b-2 and 19b-2b went
        // out; only then is the new order latched (after 19b-2b).
        bool routingSent = true;
        {
            for (uint32_t board = 0; board < 2; board++) {
                uint8_t playbackRoutes[32];
                for (int n = 0; n < 16; n++) {
                    playbackRoutes[n * 2]     = (uint8_t)((board ? kSIODest_IOBoard1Ch0 : kSIODest_IOBoard0Ch0) + n);
                    playbackRoutes[n * 2 + 1] = SymphonyPlaybackSource(slotType, slotTypeOK, board, (unsigned)n);
                }
                bool ok = SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                             symphonyAddr, kSIOCmd_AudioRouting,
                                             0, playbackRoutes, sizeof(playbackRoutes), txSeq);
                routingSent = routingSent && ok;
                STLOG("SymphonyIO: Playback routing (board %u outputs, %{public}s): %{public}s", board,
                      SymphonyAnalogFirstApplies(slotType, slotTypeOK) ? "analog first" : "by position",
                      ok ? "OK" : "FAILED");
                IOSleep(20);
            }
        }

        // ── 19b-2. Capture: board inputs → P2P ch 0-31, analog first ──
        // Route hardware inputs to P2P (Peer-to-Peer) destinations.
        // P2P (0xC0+) is the XMOS abstract host interface — the XMOS firmware
        // routes P2P traffic to the active transport (XLink for Thunderbolt,
        // USB for USB mode). Using XLink destinations (0x00+) does NOT work
        // because XLink 0x00 as destination refers to the XLink control channel,
        // not the audio data path. P2P is what the legacy PCIe routing controller
        // used (SymphonyIOUSBAudioRoutingController.cpp:111, SymphonyIORouting.h:330).
        //
        // dext 150: host input n ← the n-th board input in the unit's host
        // channel order, None past the unit's real inputs (SymphonyCaptureSource,
        // SymphonyChannelNames.h); card by card from slot 1's type while either
        // slot's type is unknown, as builds up to 149 did. All 32 destinations
        // are written each time, the unused tail as None, so a table from an
        // earlier configuration (e.g. 16 + 16 at a Start with the Symphony off,
        // then the types read on link recovery) leaves nothing behind.
        // ── 19b-2b. Second half (P2P 16-31) in its own 0x31 request ──────
        {
            for (int half = 0; half < 2; half++) {
                uint8_t captureRoutes[32];
                for (int n = 0; n < 16; n++) {
                    const unsigned host = (unsigned)(half * 16 + n);
                    captureRoutes[n * 2]     = (uint8_t)(kSIODest_P2PCh0 + host);
                    captureRoutes[n * 2 + 1] = SymphonyCaptureSource(slotType, slotTypeOK, host);
                }
                bool ok = SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                             symphonyAddr, kSIOCmd_AudioRouting,
                                             0, captureRoutes, sizeof(captureRoutes), txSeq);
                routingSent = routingSent && ok;
                STLOG("SymphonyIO: Capture routing (P2P %d-%d, %{public}s): %{public}s",
                      half * 16, half * 16 + 15,
                      SymphonyAnalogFirstApplies(slotType, slotTypeOK) ? "analog first" : "card by card",
                      ok ? "OK" : "FAILED");
                IOSleep(20);
            }
            // dext 150: latch the order and types these four sends built
            // (selector 17; the channel names are published from them), but
            // only when all four went out. After a failed send the unit's
            // tables are not known to be the new ones, so the previous latch
            // stands, and the tracked sources stay those of the previous
            // table to match it. Sources first, then the latch: a names pass
            // that runs in between sees the new sources with the previous
            // types once, and the republish after the configuration
            // (Start, link recovery) puts it right.
            const uint32_t applied = routingSent
                ? PackChannelOrder(slotType, slotTypeOK)
                : __atomic_load_n(&ivars->channelOrderLatch[0], __ATOMIC_ACQUIRE);
            uint8_t appliedType[2];
            bool appliedKnown[2];
            UnpackChannelOrder(applied, appliedType, appliedKnown);
            ResetInputRouteSources(ivars, appliedType, appliedKnown);
            LatchChannelOrder(ivars, 0, applied);
            if (!routingSent)
                STERR("SymphonyIO: a routing (0x31) send failed; names and selector 17 keep the previous order (%u)",
                      applied & 0xFFu);
        }

        // ── 19b-3. (dext 142) No mixer strip of the unit is muted here ──
        // Builds up to 141 muted the unit's 32 mixer-1 inputs at this point,
        // a leftover of the removed Input Monitoring mode. Every unit output
        // is fed directly from its XLink channel (19b-1, 19b-1b), as the
        // firmware's own default (og_source/symphonymk1/ext/SymphonyIO/
        // Software/XMOS/SymphonyIO/src/XMOS/XCore/Core3/MainFPGAThread/
        // SymphonyIOAudioRouteManager/SymphonyIOAudioRouteManager.cpp:226-439:
        // outputs and both headphones from the host link, the unit's mixers
        // fed only in the USB and Standalone images), and the original sent
        // the unit's mixer nothing in this step
        // (SymphonyIO::ApplySettingsToHardware, og_source/symphonymk1/ext/
        // maestrolink/Software/SymphonyIO.cpp:4660-4735).

        // ── 19b-4. PreferenceLoadLock(false) — unlock XMOS, audio can flow ──
        // CRITICAL: Without this unlock, the XMOS stays muted and NO audio
        // reaches the DAC even though XLink frames arrive.
        // Evidence: MaestroVolumeProxy.c:921-926 configure_fpga_routing() step 5.
        {
            uint8_t unlock = 0;
            bool ok = SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                         symphonyAddr, kSIOCmd_PreferenceLoadLock,
                                         0, &unlock, 1, txSeq);
            STLOG("SymphonyIO: PreferenceLoadLock(UNLOCK): %{public}s — %{public}s",
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
static void UpdateStatusLEDs(SymphonyThunderbridge_IVars *ivars,
                             bool port2AudioActive, bool port2ClockingProblem)
{
    // Set GCSR LED bits. Port 2 is lit only while its DMA carries audio;
    // a clocking problem flashes it, and a disabled port is off.
    // ThunderBridge GCSR LED mapping (Sym64Registers.h:153-163):
    //   bit 11 (0x800) = Port 1 flash    bit 10 (0x400) = Port 1 off
    //   bit  9 (0x200) = Port 2 flash    bit  8 (0x100) = Port 2 off
    // "On" = neither flash nor off. "Off" = off bit set.
    {
        uint32_t setBits = 0;
        uint32_t clrBits = kGCSR_MasterLEDFlash | kGCSR_MasterLEDSolid |
                           kGCSR_ClockOKFlash | kGCSR_ClockOKSolid;
        if (!port2AudioActive && !port2ClockingProblem) setBits |= kGCSR_ClockOKSolid;
        if (port2ClockingProblem) setBits |= kGCSR_ClockOKFlash;
        ModifyRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegGCSR,
                       setBits, clrBits);
        STLOG("GCSR LED bits: Port 1 on, Port 2 %s%s",
              port2ClockingProblem ? "clocking problem" : (port2AudioActive ? "on" : "off"),
              port2ClockingProblem ? " (flash)" : "");
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
        uint32_t p2Green = 0, p2Red = 0;
        if (port2ClockingProblem) {
            const uint32_t flash = 0xFFF000;
            p2Green = ((~flash & 0xFFFFFFu) << 8) | brightness;
            p2Red = (flash << 8) | brightness;
        } else if (port2AudioActive) {
            p2Green = 0xFFFFFF00u | brightness;
        }
        WriteRegister(ivars->pciDevice, ivars->barMemoryIndex,
                      kRegPort1GreenCtl, p2Green);
        WriteRegister(ivars->pciDevice, ivars->barMemoryIndex,
                      kRegPort1RedCtl, p2Red);
        WriteRegister(ivars->pciDevice, ivars->barMemoryIndex,
                      kRegPort1BlueCtl, 0);
        STLOG("LED: Port 1 solid green, Port 2 %s (RGB)",
              port2ClockingProblem ? "red/green flash" : (port2AudioActive ? "solid green" : "off"));
    }

}

static void IndicateLinkOK(SymphonyThunderbridge_IVars *ivars)
{
    UpdateStatusLEDs(ivars,
                     ivars->portCount == 2 &&
                         __atomic_load_n(&ivars->portMode, __ATOMIC_ACQUIRE) == 64,
                     ivars->portCount == 2 && ivars->port2ClockingProblem);
}

// ══════════════════════════════════════════════════════════════════════════
// ── EXPERIMENT (64ch, stage 1): second XLink port, discovery only ──────────
// Everything in this section runs only when ivars->portCount == 2, which needs
// SymphonyPortCount=2 in the matched personality. No released build has it.
//
// What the original did for two ports (og_source/symphonymk1/ext/Symphony64):
//   Symphony64Card::setCardEnabled (Driver/Symphony64Card.cpp:2249-2262) sets
//     XLINK_CLOCKING_ENABLE_1|XLINK_CLOCKING_ENABLE_2, then
//   XLink::SetNumPorts(2) (Driver/XLink.cpp:888-913) clears
//     SM_MISC2_DISABLE_PORT1|SM_MISC2_DISABLE_PORT2 in GCSR2, then
//   XLink::BusInit (Driver/XLink.cpp:483-689) treats each bus alike: clock
//     detected and data link up, reset the bus, word clock (every bus after the
//     first is told to take external clock: SetWCMaster(bus, TRUE) :542-549),
//     then walk the chain: INQUIRE + XTD_INQUIRE to the broadcast address,
//     stop at the first unit that reports no channels, otherwise SET_ADDR and
//     PASS_COMMANDS and ask again (:596-660), up to XLINK_MAX_DEVICES.
// The original did this only once a 64-channel source was selected: it started
// at "Port 1: 32ch" with port 2 disabled (SetNumPorts(1): DisablePort2 set,
// XLINK_CLOCKING_ENABLE_2 set by setCardEnabled anyway) and BusInit skipped
// the disabled bus. So does this driver: at 32 channels port 2 is disabled,
// never probed and never sent a command. ProbeSecondPort runs from
// EnablePort2Audio, after SetPort2Enabled(true); every way back to 32 disables
// port 2 again. The probe itself sends no audio: no port-2 DMA, no routing,
// no unmute (EnablePort2Audio does those once a unit has answered).
// ══════════════════════════════════════════════════════════════════════════

// XLINK_CLOCKING enable bits written at Start() and after a card reset.
// One port: exactly what the driver has always written.
static uint32_t XLinkClockEnableBits(const SymphonyThunderbridge_IVars *ivars)
{
    return ivars->portCount == 2 ? (kXLinkClockEnable1 | kXLinkClockEnable2)
                                 : kXLinkClockEnable1;
}

// GCSR2 port-disable bits at Start() and after a card reset: port 1 enabled.
// One port: exactly what the driver has always done (DisablePort1 cleared,
// port 2's bit left as found). Two ports: port 2 disabled as well, as the
// original's XLink::SetNumPorts(1) at 32 channels (XLink.cpp:906-907); it is
// enabled only while "Port 1-2: 64ch" is being set up or running.
static uint32_t GCSR2PortDisableBitsToClear(const SymphonyThunderbridge_IVars *)
{
    return kGCSR2_DisablePort1;
}

static uint32_t GCSR2PortDisableBitsToSet(const SymphonyThunderbridge_IVars *ivars)
{
    return ivars->portCount == 2 ? kGCSR2_DisablePort2 : 0u;
}

// Port 2 on (64 being selected) or back off (32), in GCSR2 only. Two-port only.
static void SetPort2Enabled(SymphonyThunderbridge_IVars *ivars, bool on)
{
    if (ivars->portCount != 2) return;
    ivars->port2DisablePending = false;
    ivars->port2On = on;
    if (on) {
        ModifyRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegXLinkClocking, kXLinkClockEnable2, 0);
        ModifyRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegGCSR2, 0, kGCSR2_DisablePort2);
    } else {
        ModifyRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegGCSR2, kGCSR2_DisablePort2, 0);
    }
    STLOG("Port 2: %{public}s (GCSR2 DisablePort2 %{public}s)", on ? "enabled" : "disabled", on ? "cleared" : "set");
}

// Wait for port 2's data link to stop slipping: the same three passes of
// 5 × 50 ms the port-1 bring-up uses. Returns true once a pass is clean.
static bool WaitForPort2Lock(IOPCIDevice *dev, uint8_t mi, int timeoutMs)
{
    const int passes = timeoutMs <= 1000 ? 4 : 20;
    IOSleep(50);
    WriteRegister(dev, mi, kRegXLink2Status, kXLinkDataSlipSticky);
    for (int pass = 0; pass < passes; pass++) {
        bool slipFree = true;
        for (int i = 0; i < 5; i++) {
            IOSleep(50);
            uint32_t status = 0;
            ReadRegister(dev, mi, kRegXLink2Status, &status);
            if (status & kXLinkDataSlipSticky) {
                slipFree = false;
                WriteRegister(dev, mi, kRegXLink2Status, kXLinkDataSlipSticky);
                break;
            }
        }
        if (slipFree) return true;
    }
    return false;
}

// Identify what is cabled to port 2 and record it for ReadPort2State.
// Caller: Start() before DMA starts, or a block on xlinkQueue that has already
// passed XLinkTxAdmissible. Uses bounded IOSleep polling; never the IRQ queue.
// Whether a port-2 unit word is a Symphony I/O ("unit B"). The original went by
// the unit's XLINK_DEVICE_TYPE answer (see kSymphonyPort2UnitTypeOK); the
// channel banks alone cannot say, because a Symphony I/O with a single
// 16-channel card answers 0x0F like a DD-16X. Banks 0xFF (32 in, 32 out) are no
// converter either, as before. ConfigureUnitB still sends nothing unless the
// unit answers a Symphony vendor read.
static bool Port2UnitIsSymphony(uint32_t word)
{
    if (ConverterUnitRouting(word) == kConverterRoutingSymphony) return true;
    return (word & kSymphonyPort2UnitTypeOK) != 0 &&
           (word >> kSymphonyPort2UnitTypeShift) == kSymphonyXLinkDeviceTypeSymphonyIO;
}

static void ProbeSecondPort(SymphonyThunderbridge_IVars *ivars, double rate, const char *why,
                            int clockPolls)
{
    IOPCIDevice *dev = ivars->pciDevice;
    const uint8_t mi = ivars->barMemoryIndex;
    uint32_t flags = kSymphonyPort2FlagProbed;
    uint32_t units[kXLinkMaxDevices] = {};
    uint32_t unitCount = 0;

    uint8_t rateCode = SampleRateToXLinkCode(rate);
    if (rateCode == 0xFF) rateCode = kXLinkSRate44100;

    uint32_t gcsr2 = 0, clk = 0, status = 0;
    ReadRegister(dev, mi, kRegGCSR2, &gcsr2);
    // Port 2's receive clock and a detected rate, with the patience the port-1
    // bring-up has (the original read it five times, XLink.cpp:2631-2690).
    bool clock = false;
    for (int poll = 0; poll < clockPolls; poll++) {
        ReadRegister(dev, mi, kRegXLinkClocking, &clk);
        clock = (clk & kXLinkRX2ClockDetect) != 0 && (clk & kXLinkSR2Mask) != 0;
        if (clock) break;
        IOSleep(50);
    }
    ReadRegister(dev, mi, kRegXLink2Status, &status);
    const bool dataUp = (status & kXLinkDataDownCurrent) == 0;
    STLOG("Port 2 probe (%{public}s): XLinkClocking=0x%08x RX2_clock=%u SR2_bits=0x%02x, "
          "XLink2Status=0x%08x data_link=%{public}s slip=%u slave_mode=%u, GCSR2=0x%08x port2_disabled=%u",
          why, clk, (clk & kXLinkRX2ClockDetect) ? 1 : 0, (clk & kXLinkSR2Mask) >> 16,
          status, dataUp ? "up" : "DOWN", (status & kXLinkDataSlipSticky) ? 1 : 0,
          (status & kXLinkSlaveMode) ? 1 : 0, gcsr2, (gcsr2 & kGCSR2_DisablePort2) ? 1 : 0);

    if (clock) flags |= kSymphonyPort2FlagClockDetected;
    if (clock && dataUp) flags |= kSymphonyPort2FlagDataLinkUp;

    if (!clock) {
        STLOG("Port 2 probe: no unit clock on port 2 — nothing sent on that bus");
    } else if (!dataUp) {
        // The original gave up on a bus whose clock is there but whose data
        // link is down (BusInit :515-522). Report it; send nothing.
        STLOG("Port 2 probe: clock present but the data link is down — nothing sent on that bus");
    } else {
        // Clear the latched status and reset the bus (ResetBus, XLink.cpp:2089),
        // then the rate, as ResetBus did.
        WriteRegister(dev, mi, kRegXLink2Status, 0xFFFFFFFF);
        WriteRegister(dev, mi, kRegXLink2TX, kXLinkResetCmd);
        IOSleep(200);
        bool sent = SendXLinkCommandOn(dev, mi, kRegXLink2TX,
                                       kXLinkCmdAddrAll, kXLinkCmdSetSampleRate, rateCode);
        IOSleep(10);
        // Every bus after the first takes external word clock: SET_EXT_LOCK to
        // the broadcast address with data 1 (SetWCMaster(bus, TRUE) → SetExtLock).
        sent = sent && SendXLinkCommandOn(dev, mi, kRegXLink2TX,
                                          kXLinkCmdAddrAll, kXLinkCmdSetExtLock, 1);
        if (!sent) {
            flags |= kSymphonyPort2FlagTxTimeout;
            STERR("Port 2 probe: XLink 2 TX stayed busy — bus not enumerated");
        } else {
            // BusInit's initial data-link check is the short wait. Changing
            // the word-clock source is the original 5-second WC-change wait.
            const bool dataLocked = WaitForPort2Lock(dev, mi, kPort2LockShortMs);
            const bool locked = dataLocked && WaitForPort2Lock(dev, mi, kPort2LockWordClockMs);
            if (locked) flags |= kSymphonyPort2FlagLocked;
            STLOG("Port 2 probe: bus reset, rate %u Hz, external word clock; data link %{public}s",
                  (uint32_t)(rate + 0.5), locked ? "LOCKED" : "still slipping (continuing)");

            for (uint8_t addr = 1; addr <= kXLinkMaxDevices; addr++) {
                uint8_t inquire = 0, xtd = 0;
                uint32_t word = 0;
                bool keptAddress = false;
                // Position 1 is asked up to five times, 250 ms apart: a
                // Symphony I/O that an earlier probe addressed did not answer
                // the broadcast address for the rest of a session (field
                // report 6F64285E, 2026-11-20: found once, then "no reply" on
                // every later probe until its link restarted). Each round asks
                // the broadcast address, as BusInit did, and then address 1,
                // as the original's link check asked a unit it already knew
                // (CheckLinkStatus, XLink.cpp:2025-2031).
                // The waiting rounds only while no audio runs (a switch to 64);
                // the link watch's look with port 1 streaming asks once, so this
                // queue is held about 80 ms longer there, not over a second.
                const int rounds = (addr == 1 && !__atomic_load_n(&ivars->ioRunning, __ATOMIC_ACQUIRE)) ? 5 : 1;
                for (int round = 0; round < rounds; round++) {
                    if (round) IOSleep(250);
                    word = 0; inquire = 0; xtd = 0;
                    if (XLinkInquireOn(dev, mi, kRegXLink2TX, kRegXLink2RX,
                                       kXLinkCmdAddrAll, kXLinkCmdInquire, &inquire,
                                       ivars->isLegacyPCIe2100))
                        word |= kSymphonyPort2UnitInquireOK | inquire;
                    if (XLinkInquireOn(dev, mi, kRegXLink2TX, kRegXLink2RX,
                                       kXLinkCmdAddrAll, kXLinkCmdXtdInquire, &xtd,
                                       ivars->isLegacyPCIe2100))
                        word |= kSymphonyPort2UnitXtdOK | ((uint32_t)xtd << 8);
                    if (((xtd & 0xF0) | ((inquire & 0xF0) >> 4)) != 0 || addr != 1) break;
                    uint8_t i1 = 0, x1 = 0;
                    uint32_t w1 = 0;
                    if (XLinkInquireOn(dev, mi, kRegXLink2TX, kRegXLink2RX, 1, kXLinkCmdInquire, &i1,
                                       ivars->isLegacyPCIe2100))
                        w1 |= kSymphonyPort2UnitInquireOK | i1;
                    if (XLinkInquireOn(dev, mi, kRegXLink2TX, kRegXLink2RX, 1, kXLinkCmdXtdInquire, &x1,
                                       ivars->isLegacyPCIe2100))
                        w1 |= kSymphonyPort2UnitXtdOK | ((uint32_t)x1 << 8);
                    // Only a Symphony I/O is taken this way (the unit this was
                    // seen on). A converter chain in that state would be found
                    // one unit short, so it is left as "no unit", as before.
                    uint8_t t1 = 0;
                    if (((x1 & 0xF0) | ((i1 & 0xF0) >> 4)) != 0 &&
                        XLinkInquireOn(dev, mi, kRegXLink2TX, kRegXLink2RX, 1, kXLinkCmdDeviceType, &t1,
                                       ivars->isLegacyPCIe2100) &&
                        t1 == kSymphonyXLinkDeviceTypeSymphonyIO) {
                        inquire = i1; xtd = x1; word = w1 | kSymphonyPort2UnitKeptAddress;
                        keptAddress = true;
                        STLOG("Port 2 probe: unit 1 answers at address 1, not the broadcast address — kept from an earlier probe");
                        break;
                    }
                }
                // The original's test for "a unit is here": any channel-group bit
                // in either reply (CONVERT_ROUTING_COMMANDS_TO_NEW_FORMAT,
                // XLinkRegisters.h:444; the low nibbles are not channel bits).
                const uint8_t channels = (uint8_t)((xtd & 0xF0) | ((inquire & 0xF0) >> 4));
                if (channels == 0) {
                    STLOG("Port 2 probe: no %{public}sunit at position %u (INQUIRE %{public}s 0x%02x, XTD_INQUIRE %{public}s 0x%02x)",
                          addr > 1 ? "further " : "", addr,
                          (word & kSymphonyPort2UnitInquireOK) ? "replied" : "no reply", inquire,
                          (word & kSymphonyPort2UnitXtdOK) ? "replied" : "no reply", xtd);
                    // Keep what the first position said even when it is not a
                    // unit we recognise: that reply is the evidence.
                    if (addr == 1 && word != 0) units[unitCount++] = word;
                    break;
                }
                // dext 139: every unit gets the rest of BusInit's sequence
                // (XLink.cpp:603-654), as the original sent it to converters and
                // Symphony I/Os alike: the firmware and DEVICE_TYPE queries,
                // SET_ADDR, DEVICE_TYPE at its address (the answer that says
                // whether it is a Symphony I/O) and the authentication before
                // PASS_COMMANDS. A unit that kept its address is not asked at
                // the broadcast address or addressed again.
                uint8_t scratch = 0, type = 0;
                if (!keptAddress) {
                    XLinkInquireOn(dev, mi, kRegXLink2TX, kRegXLink2RX, kXLinkCmdAddrAll,
                                   kXLinkCmdXtdInquire, &scratch, ivars->isLegacyPCIe2100);
                    XLinkInquireOn(dev, mi, kRegXLink2TX, kRegXLink2RX, kXLinkCmdAddrAll,
                                   kXLinkCmdInquire, &scratch, ivars->isLegacyPCIe2100);
                    XLinkInquireOn(dev, mi, kRegXLink2TX, kRegXLink2RX, kXLinkCmdAddrAll,
                                   kXLinkCmdDeviceType, &scratch, ivars->isLegacyPCIe2100);
                }
                const bool addressed = keptAddress ||
                    SendXLinkCommandOn(dev, mi, kRegXLink2TX, kXLinkCmdAddrAll, kXLinkCmdSetAddr, addr);
                bool typeOK = false;
                if (addressed) {
                    // Asked up to three times: one lost answer would make a
                    // Symphony I/O a converter until the next probe. (The
                    // original asked again on every link check, XLink.cpp:2031.)
                    for (int attempt = 0; attempt < 3 && !typeOK; attempt++)
                        typeOK = XLinkInquireOn(dev, mi, kRegXLink2TX, kRegXLink2RX, addr,
                                                kXLinkCmdDeviceType, &type, ivars->isLegacyPCIe2100);
                    if (typeOK) word |= kSymphonyPort2UnitTypeOK | ((uint32_t)type << kSymphonyPort2UnitTypeShift);
                    word |= AuthenticateConverter(ivars, kRegXLink2TX, kRegXLink2RX, addr, channels, inquire, 2);
                }
                if (!addressed ||
                    !SendXLinkCommandOn(dev, mi, kRegXLink2TX, addr, kXLinkCmdPassCommands, 1)) {
                    flags |= kSymphonyPort2FlagTxTimeout;
                    units[unitCount++] = word;
                    STERR("Port 2 probe: could not address unit %u", addr);
                    break;
                }
                IOSleep(5);
                units[unitCount++] = word | kSymphonyPort2UnitAddressed;
                STLOG("Port 2 probe: unit %u INQUIRE 0x%02x XTD_INQUIRE %{public}s 0x%02x → channel groups 0x%02x, "
                      "DEVICE_TYPE %{public}s 0x%02x (%{public}s), addressed",
                      addr, inquire, (word & kSymphonyPort2UnitXtdOK) ? "replied" : "no reply", xtd, channels,
                      typeOK ? "replied" : "no reply", type,
                      Port2UnitIsSymphony(word) ? "Symphony I/O" : "converter");
            }
            // The rate went out before these units had an address; send it again
            // so each has it (the original re-applied the rate after BusInit).
            // No UNMUTE: port 2 stays silent in stage 1.
            if (unitCount)
                SendXLinkCommandOn(dev, mi, kRegXLink2TX,
                                   kXLinkCmdAddrAll, kXLinkCmdSetSampleRate, rateCode);
        }
    }

    // Publish: counts and words first, flags last.
    ivars->port2XlinkStatus = status;
    ivars->port2Clocking    = clk;
    ivars->port2Gcsr2       = gcsr2;
    for (uint32_t i = 0; i < kXLinkMaxDevices; i++) ivars->port2Unit[i] = units[i];
    ivars->port2UnitCount   = unitCount;
    ivars->port2RateHz      = 0;   // the probe sends the rate but does not verify it
    ivars->port2ProbeCount++;
    __atomic_store_n(&ivars->port2Flags, flags, __ATOMIC_RELEASE);
    STLOG("Port 2 probe: done — %u unit(s) answered, flags=0x%x (probe #%u). Port 2 carries audio "
          "only while \"" kSymphonyPortSourceName64 "\" is selected.",
          unitCount, flags, ivars->port2ProbeCount);
}

// Link-watch hook (two-port mode only): `clk` is the kRegXLinkClocking value the
// tick has just read, so this costs no bus access. Port 2 is looked at only
// while "Port 1-2: 64ch" is running, as the original's XLink thread ignored a
// disabled bus (PortEnabled(), XLink.cpp:125-129, :300). At 32 channels a
// chain plugged into port 2 is found when 64 is selected, not before.
static void Port2AudioFallBack(SymphonyThunderbridge_IVars *ivars, SymphonyThunderbridge *self,
                               uint32_t reason, bool touchHardware);
static void ProbeSecondPort(SymphonyThunderbridge_IVars *ivars, double rate, const char *why,
                            int clockPolls);
static bool Port2FoundUnit(const SymphonyThunderbridge_IVars *ivars);
static void RequestPortModeConfigChange(SymphonyThunderbridge_IVars *ivars,
                                        SymphonyThunderbridge *self, const char *why);

static void LeaveTwoUnit(SymphonyThunderbridge_IVars *ivars, bool touchHardware);   // below

static void ClearPort2Units(SymphonyThunderbridge_IVars *ivars, uint32_t clk)
{
    __atomic_and_fetch(&ivars->convFlags, ~kSymphonyConvPort2Converters, __ATOMIC_RELEASE);
    ConvSetPort(ivars, 1, false, 0, nullptr);
    LeaveTwoUnit(ivars, true);   // unit B is set up again when 64 starts
    ivars->port2Clocking  = clk;
    ivars->port2UnitCount = 0;
    ivars->port2RateHz    = 0;
    for (uint32_t i = 0; i < kXLinkMaxDevices; i++) ivars->port2Unit[i] = 0;
    __atomic_store_n(&ivars->port2Flags, kSymphonyPort2FlagProbed, __ATOMIC_RELEASE);
}

static void WatchSecondPort(SymphonyThunderbridge_IVars *ivars, SymphonyThunderbridge *self,
                            uint32_t clk)
{
    if (__atomic_load_n(&ivars->portMode, __ATOMIC_ACQUIRE) != 64) {
        // A switch to 64 that was abandoned for a stop or power-down left
        // port 2 enabled and wrote nothing more. The card answers again (the
        // tick has just read it): disable port 2, as every other way back to
        // 32 does. The only register this tick writes at 32 channels.
        const bool abandonedSwitch = ivars->port2DisablePending;
        if (abandonedSwitch) {
            STLOG("Port 2: still enabled after an abandoned switch to 64 — disabling it");
            SetPort2Enabled(ivars, false);
            __atomic_store_n(&ivars->requestedPortMode, 32u, __ATOMIC_RELEASE);
        }
        // Keep a remembered 64-channel request alive. Once the link watch sees
        // a returned unit, ask Core Audio for the same configuration change as
        // RequestPortMode; the host then performs the actual 32 -> 64 switch.
        bool clock = (clk & kXLinkRX2ClockDetect) != 0 && (clk & kXLinkSR2Mask) != 0;
        if (!abandonedSwitch && clock && __atomic_load_n(&ivars->requestedPortMode, __ATOMIC_ACQUIRE) == 64) {
            SetPort2Enabled(ivars, true);
            ProbeSecondPort(ivars, ivars->xlinkRate > 0.0 ? ivars->xlinkRate : 44100.0,
                            "64-channel request resumed", kPort2ClockPollsOnSelect);
            if (Port2FoundUnit(ivars)) {
                if (!ivars->port2ResumeUnitSeen) {
                    ivars->port2ResumeUnitSeen = true;
                    RequestPortModeConfigChange(ivars, self, "port 2 unit returned");
                }
            } else {
                ivars->port2ResumeUnitSeen = false;
            }
            // dext 131 review: never leave port 2 switched on at 32 channels;
            // the switch to 64 (EnablePort2Audio) enables it again.
            SetPort2Enabled(ivars, false);
        } else if (!abandonedSwitch && !clock && __atomic_load_n(&ivars->requestedPortMode, __ATOMIC_ACQUIRE) == 64 &&
                   !__atomic_load_n(&ivars->ioRunning, __ATOMIC_ACQUIRE) &&
                   ivars->port2ResumeProbes < 20 &&
                   clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - ivars->port2ResumeProbeNs >= 30000000000ull) {
            // The FPGA may suppress RX2 detection while DisablePort2 is set;
            // briefly enable the bus so a late powered-on unit can be seen.
            // Only while no audio runs on port 1, and at most every 30 s:
            // enabling port 2 and polling for its clock (up to 2 s on this
            // queue) must never disturb or hold up port 1 audio at 32 channels.
            ivars->port2ResumeProbeNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
            // About ten minutes of looking (20 x 30 s), then only the passive
            // check above; choosing 64 channels again starts over.
            ivars->port2ResumeProbes++;
            SetPort2Enabled(ivars, true);
            for (int poll = 0; poll < kPort2ClockPollsOnSelect && !clock; poll++) {
                ReadRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegXLinkClocking, &clk);
                clock = (clk & kXLinkRX2ClockDetect) != 0 && (clk & kXLinkSR2Mask) != 0;
                if (!clock) IOSleep(50);
            }
            if (clock) {
                ProbeSecondPort(ivars, ivars->xlinkRate > 0.0 ? ivars->xlinkRate : 44100.0,
                                "64-channel request resumed", kPort2ClockPollsOnSelect);
                if (Port2FoundUnit(ivars)) {
                    ivars->port2ResumeUnitSeen = true;
                    RequestPortModeConfigChange(ivars, self, "port 2 unit returned");
                } else {
                    ivars->port2ResumeUnitSeen = false;
                    SetPort2Enabled(ivars, false);
                }
            } else {
                SetPort2Enabled(ivars, false);
            }
        }
        if (!clock) {
            ivars->port2ResumeUnitSeen = false;
        }
        return;
    }
    if ((clk & kXLinkClockEnable2) == 0) {
        // The card's registers are gone, and its DMA with them (a D3 power
        // cycle across sleep, the port-1 re-initialization not yet run).
        // Record that 64 is no longer running; nothing is written for it.
        ivars->port2ClockingProblem = true;
        UpdateStatusLEDs(ivars, false, true);
        Port2AudioFallBack(ivars, self, kSymphonyPort2ReasonCardReset, false);
        STLOG("Port 2: XLINK_CLOCKING_ENABLE_2 was clear (XLinkClocking=0x%08x) — card reset; back at 32", clk);
        ClearPort2Units(ivars, clk);
        return;
    }
    const bool present = (clk & kXLinkRX2ClockDetect) != 0 && (clk & kXLinkSR2Mask) != 0;
    if (present) {
        if (ivars->port2ClockingProblem) {
            ivars->port2ClockingProblem = false;
            UpdateStatusLEDs(ivars, true, false);
        }
        return;
    }
    ivars->port2ClockingProblem = true;
    UpdateStatusLEDs(ivars, false, true);
    STLOG("Port 2: unit clock gone (XLinkClocking=0x%08x) — back to port 1 alone", clk);
    Port2AudioFallBack(ivars, self, kSymphonyPort2ReasonClockGone, true);
    UpdateStatusLEDs(ivars, false, true);
    ClearPort2Units(ivars, clk);
}

// Whether the last probe found a unit on port 2 with its data link up.
// Runs on xlinkQueue, where the probe writes these fields.
static bool Port2FoundUnit(const SymphonyThunderbridge_IVars *ivars)
{
    if (ivars->portCount != 2) return false;
    const uint32_t flags = __atomic_load_n(&ivars->port2Flags, __ATOMIC_ACQUIRE);
    return (flags & kSymphonyPort2FlagDataLinkUp) != 0 && ivars->port2UnitCount > 0;
}

// Whether a device rate change should go to port 2 too: 64 channels running
// (port 2 enabled, as the original sent rates only to enabled buses,
// XLink.cpp:993) and the probe found a unit. ChangeSampleRate still checks
// port 2's clock itself before sending (the unit may have gone since).
static bool Port2TakesRateChanges(const SymphonyThunderbridge_IVars *ivars)
{
    return Port2FoundUnit(ivars) && __atomic_load_n(&ivars->portMode, __ATOMIC_ACQUIRE) == 64;
}

// After ChangeSampleRate (xlinkQueue). If port 2 was told the new rate but
// port 1 was not (port-1 TX busy), port 1's units stay at the old rate and the
// caller puts DDS back there, so port 2 is put back too. Then publish the
// result for ReadPort2State.
static void FinishPort2RateChange(SymphonyThunderbridge_IVars *ivars, double newRate,
                                  double oldXlinkRate, bool port1CommandIssued,
                                  const Port2RateChange &p2)
{
    if (!p2.attempted) return;   // unsupported rate: nothing was sent anywhere
    uint32_t rateHz = p2.ok ? (uint32_t)(newRate + 0.5) : 0;
    // sentNew with port 1 not told can only be the before-step's send: the
    // after-step runs only once port 1 has succeeded.
    if (p2.sentNew && !port1CommandIssued) {
        const uint8_t oldCode = SampleRateToXLinkCode(oldXlinkRate);
        if (oldCode != 0xFF &&
            SendXLinkCommandOn(ivars->pciDevice, ivars->barMemoryIndex, kRegXLink2TX,
                               kXLinkCmdAddrAll, kXLinkCmdSetSampleRate, oldCode)) {
            STLOG("ChangeSampleRate: port 1 was not told; port 2 put back to %.0f Hz", oldXlinkRate);
        } else {
            STERR("ChangeSampleRate: port 1 was not told and port 2 could not be put back "
                  "to %.0f Hz", oldXlinkRate);
        }
        rateHz = 0;
    }
    ivars->port2RateHz = rateHz;
    ivars->port2RateChanges++;
    uint32_t flags = __atomic_load_n(&ivars->port2Flags, __ATOMIC_ACQUIRE);
    // Only the rate-failed flag is ours; TxTimeout stays the probe's.
    flags &= ~(kSymphonyPort2FlagRateFailed);
    if (!p2.ok) flags |= kSymphonyPort2FlagRateFailed;
    __atomic_store_n(&ivars->port2Flags, flags, __ATOMIC_RELEASE);
    STLOG("Port 2 rate change to %.0f Hz: %{public}s (port 2 reports %u Hz, change #%u)", newRate,
          p2.ok ? "locked and verified"
                : !p2.clock ? "not sent (no unit clock on port 2)"
                : !port1CommandIssued ? "abandoned (port 1 was not told)"
                : !p2.sentNew ? "not sent (port 1 failed, or port 2 TX busy / stopping)"
                : "sent but port 2 did not lock or report the rate",
          p2.detectedHz, ivars->port2RateChanges);
}

// The personality's SymphonyPortCount. Anything but the number 2 (key absent,
// another number, a string) means one port.
static uint32_t ReadPortCountProperty(IOService *service)
{
    uint32_t count = 1;
    OSDictionary *properties = nullptr;
    if (service->CopyProperties(&properties) == kIOReturnSuccess && properties) {
        OSNumber *number = OSDynamicCast(OSNumber, properties->getObject(kSymphonyPortCountKey));
        if (number && number->unsigned32BitValue() == 2) count = 2;
    }
    OSSafeReleaseNULL(properties);
    return count;
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
    ArmMicPreSettle(ivars);   // coreaudiod re-reads the device and its controls
    self->retain();
    ivars->defaultQueue->DispatchAsync(^{
        if (!__atomic_load_n(&ivars->stopping, __ATOMIC_ACQUIRE) && ivars->audioDevice) {
            const bool ioRunning = __atomic_load_n(&ivars->ioRunning, __ATOMIC_ACQUIRE);
            kern_return_t rc = ivars->audioDevice->RequestDeviceConfigurationChange(
                kSymphonyConfigChangeLinkRecovered, nullptr);
            STLOG("Link watch: requested Core Audio configuration change (%{public}s, ioRunning=%u, 0x%x)",
                  why, ioRunning ? 1u : 0u, rc);
        }
        self->release();
    });
}

// ══════════════════════════════════════════════════════════════════════════
// ── EXPERIMENT (64ch, stage 2): audio on port 2 ────────────────────────────
// Runs only when ivars->portCount == 2. The card is in one of two modes:
//   32: port 1 alone, exactly what the driver has always programmed;
//   64: both ports, selected with the "Port 1-2: 64ch" data source.
// What the original did for the second port (og_source/symphonymk1/ext/
// Symphony64/Driver):
//   Symphony64Card::SetupMemoryForSecondPort (:1638) a second DMA buffer pair;
//   cmdSetBuffers (:1358) A2H2/H2A2 BUF_SIZE in words and HBA, or zero when the
//     second port is off;
//   setNumDMAChannels (:1818-1920) mute, StopDMA, 100 ms, the 32-channel size
//     bits in GCSR and GCSR2, the bus's routing entries, StartDMA, unmute;
//   StartDMA (:1517-1590) trigger-selects and then enables to GCSR2 BEFORE GCSR
//     ("hardware requires second port to be enabled before the first");
//   Sym64Routing::init (Sym64Routing.cpp:300) input n <- XLINK_RX n, output n <-
//     PCI_OUT n (slot 64+n), n = 0..63: port 2 is entries 32..63;
//   XLink::EnableDeviceRouting (XLink.cpp:1863) UNMUTE to each unit of the bus;
//   XLink::SetSampleRate (XLink.cpp:1079-1150) the phase alignment;
//   EnableInterruptsInHardware (:410) only the port-1 A2H wrap interrupt,
//     with one port or two.
// Everything here runs on xlinkQueue unless it says otherwise, and none of it
// calls into AudioDriverKit (the configuration-change path waits on this queue).
// ══════════════════════════════════════════════════════════════════════════

static constexpr uint64_t kSymphonyConfigChangePortMode = 0x504F5254ULL;   // 'PORT'
static constexpr uint8_t  kXLinkCmdWclkPhase   = 0x09;   // XLINK_CMD_WCLK_PHASE
static constexpr uint32_t kJamActive           = 0x00000100;   // SAMPLE_PHASE_JAM_ACTIVE
static constexpr uint8_t  kJamNoAdjustment     = 0xFF;   // JAM_NO_PHASE_ADJUSTMENT
static constexpr uint8_t  kDefaultPhaseOffset  = 5;      // DEFAULT_PHASE_OFFSET (SymphonyDrivers.h:61)
static constexpr uint8_t  kPhaseWindow         = 0x30;   // og: "working region of 0x0 < phase < 0x30"
static constexpr uint32_t kPort2FirstChannel   = kMaxChannelsPerPort;   // routing entries 32..63

// Record how the last request for 64 ended (or that the driver dropped it).
// outcome is 0, kSymphonyPort2AudioRefused or kSymphonyPort2AudioFellBack.
static void Port2AudioNote(SymphonyThunderbridge_IVars *ivars, uint32_t outcome, uint32_t reason)
{
    uint32_t f = __atomic_load_n(&ivars->port2AudioFlags, __ATOMIC_ACQUIRE);
    f &= ~(kSymphonyPort2AudioRefused | kSymphonyPort2AudioFellBack | kSymphonyPort2AudioReasonMask);
    f |= outcome | ((reason << kSymphonyPort2AudioReasonShift) & kSymphonyPort2AudioReasonMask);
    __atomic_store_n(&ivars->port2AudioFlags, f, __ATOMIC_RELEASE);
}

static void Port2SetCardMode(SymphonyThunderbridge_IVars *ivars, uint32_t mode)
{
    if (__atomic_load_n(&ivars->portMode, __ATOMIC_ACQUIRE) != mode) ivars->port2ModeChanges++;
    __atomic_store_n(&ivars->portMode, mode, __ATOMIC_RELEASE);
}

// Mute, then stop the DMA engines of both ports (og MuteOutputs + StopDMA, then
// the 100 ms setNumDMAChannels waits). GCSR is written as the rate change
// writes it; GCSR2 loses its four DMA bits and keeps the 32-channel size.
// Returns whether port 1's engine was running when this was called. It is not
// after a failed rate change (StartDevice leaves the card stopped and muted
// until the next start sorts the clock out), and then nothing here may start it.
static bool Port2StopBothEngines(IOPCIDevice *dev, uint8_t mi)
{
    ModifyRegister(dev, mi, kRegClkCtrl,
                   0, kClkCtrl_Unmute | kClkCtrl_InputUnmute | kClkCtrl_OutputUnmute);
    uint32_t gcsr = 0;
    ReadRegister(dev, mi, kRegGCSR, &gcsr);
    const bool wasRunning = (gcsr & (kGCSR_A2HDMAEnable | kGCSR_H2ADMAEnable)) != 0;
    gcsr = (gcsr & ~kGCSR_DMAMask) | (kGCSR_DMAOutSize32 | kGCSR_DMAInSize32);
    gcsr &= ~(kGCSR_A2HDMAEnable | kGCSR_H2ADMAEnable |
              kGCSR_A2HTrigSelect | kGCSR_H2ATrigSelect |
              kGCSR_MeterDMAEnable | kGCSR_MeterTrigSelect);
    WriteRegister(dev, mi, kRegGCSR, gcsr);
    ModifyRegister(dev, mi, kRegGCSR2, kGCSR2_DMAOutSize32 | kGCSR2_DMAInSize32,
                   kGCSR2_DMAEnableMask | kGCSR2_DMAMask);
    IOSleep(100);
    return wasRunning;
}

static uint32_t ClkCtrlUnmuteBits(const SymphonyThunderbridge_IVars *ivars);
// Start port 1's engine alone and unmute: the same writes, in the same order,
// as the rate change's restart (StartDevice steps 5-7).
static void Port2StartPort1Engine(SymphonyThunderbridge_IVars *ivars)
{
    IOPCIDevice *dev = ivars->pciDevice;
    const uint8_t mi = ivars->barMemoryIndex;
    WriteRegister(dev, mi, kRegIntStatus, 0xFFFFFFFF);
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
    IOSleep(10);
    ModifyRegister(dev, mi, kRegClkCtrl,
                   ClkCtrlUnmuteBits(ivars), 0);
}

// Start both engines in the original's order and unmute. Each step goes to
// GCSR2 (port 2) before GCSR (port 1), as og StartDMA :1564-1590 requires. The
// caller has cleared the interrupt status.
static void Port2StartBothEngines(SymphonyThunderbridge_IVars *ivars)
{
    IOPCIDevice *dev = ivars->pciDevice;
    const uint8_t mi = ivars->barMemoryIndex;
    uint32_t gcsr = 0, gcsr2 = 0;
    ReadRegister(dev, mi, kRegGCSR, &gcsr);
    ReadRegister(dev, mi, kRegGCSR2, &gcsr2);
    gcsr  = (gcsr & ~kGCSR_DMAMask) | (kGCSR_DMAOutSize32 | kGCSR_DMAInSize32);
    gcsr2 = (gcsr2 & ~kGCSR2_DMAMask) | (kGCSR2_DMAOutSize32 | kGCSR2_DMAInSize32);
    gcsr |= kGCSR_OnlyMasterDMA;   // one card (og m_fOnlyCardEnabled), however many ports
    WriteRegister(dev, mi, kRegGCSR, gcsr);

    // Everything off first: the engines start on a rising edge (og :1537-1539).
    gcsr &= ~(kGCSR_A2HDMAEnable | kGCSR_H2ADMAEnable |
              kGCSR_A2HTrigSelect | kGCSR_H2ATrigSelect |
              kGCSR_MeterDMAEnable | kGCSR_MeterTrigSelect);
    gcsr2 &= ~kGCSR2_DMAEnableMask;
    WriteRegister(dev, mi, kRegGCSR, gcsr);
    WriteRegister(dev, mi, kRegGCSR2, gcsr2);

    // Trigger-selects, port 2 first.
    gcsr2 |= kGCSR2_A2HTrigSelect | kGCSR2_H2ATrigSelect;
    gcsr  |= kGCSR_A2HTrigSelect | kGCSR_H2ATrigSelect;
    if (ivars->meterDMAActive) gcsr |= kGCSR_MeterTrigSelect;
    WriteRegister(dev, mi, kRegGCSR2, gcsr2);
    WriteRegister(dev, mi, kRegGCSR, gcsr);

    // Enables, port 2 first.
    gcsr2 |= kGCSR2_A2HDMAEnable | kGCSR2_H2ADMAEnable;
    gcsr  |= kGCSR_A2HDMAEnable | kGCSR_H2ADMAEnable;
    if (ivars->meterDMAActive) gcsr |= kGCSR_MeterDMAEnable;
    WriteRegister(dev, mi, kRegGCSR2, gcsr2);
    WriteRegister(dev, mi, kRegGCSR, gcsr);
    STLOG("Port 2 audio: both DMA engines started (GCSR2=0x%08x, then GCSR=0x%08x)", gcsr2, gcsr);

    IOSleep(10);
    ModifyRegister(dev, mi, kRegClkCtrl,
                   ClkCtrlUnmuteBits(ivars), 0);
}

// Port 2's routing entries (32..63): input n <- XLink RX slot n, output n <-
// PCI OUT slot 64+n, with or without the enable bit (og Sym64Routing::init and
// DisableXLinkPortChannels). Whole values are written, not read-modify-write.
static void Port2ProgramRouting(SymphonyThunderbridge_IVars *ivars, bool enable)
{
    IOPCIDevice *dev = ivars->pciDevice;
    const uint8_t mi = ivars->barMemoryIndex;
    const uint32_t en = enable ? kRoutingEnable : 0;
    for (uint32_t n = kPort2FirstChannel; n < kPort2FirstChannel + kMaxChannelsPerPort; n++) {
        WriteCardInputRoute(ivars, n, (kTDM_XLinkRX0 + n) | en);
        const uint32_t output = (enable && ivars->cardOutputRouteSet[n])
            ? ivars->cardOutputRoute[n] : ((kTDM_PCIOut0 + n) | en);
        WriteRegister(dev, mi, kRegOutputRouting + n * 4, output);
    }
}

// 64→32 policy: B RX slots are invalid once port 2 is stopped. Restore a
// safe single-unit identity route here; Maestro may then overlay its saved
// 32-channel scope.
static void RestorePort1InputRoutesAfter64(SymphonyThunderbridge_IVars *ivars)
{
    // Symphony I/O topologies only: converters re-apply their own routing on a
    // port-mode change (ApplyConverterRouting), and their traces stay unchanged.
    if (ivars->convPort1 ||
        (__atomic_load_n(&ivars->convFlags, __ATOMIC_ACQUIRE) & kSymphonyConvPort2Converters) != 0)
        return;
    for (uint32_t host = 0; host < kMaxChannelsPerPort; ++host) {
        const uint32_t word = __atomic_load_n(&ivars->cardInputRoute[host], __ATOMIC_ACQUIRE);
        if ((word & 0xFFu) >= kPort2FirstChannel)
            WriteCardInputRoute(ivars, host, (kTDM_XLinkRX0 + host) | kRoutingEnable);
    }
}

// The four port-2 DMA buffer registers (og cmdSetBuffers). on: sizes in words
// and the device-visible addresses, then both addresses are read back; returns
// false if the card did not keep them. off: zero, as the driver has always
// written them.
static bool Port2ProgramBuffers(SymphonyThunderbridge_IVars *ivars, bool on)
{
    IOPCIDevice *dev = ivars->pciDevice;
    const uint8_t mi = ivars->barMemoryIndex;
    const uint32_t words = on ? (uint32_t)(kDMABufferSize / (kAudioBitDepth / 8)) : 0;
    const uint32_t a2h = on ? (uint32_t)ivars->a2h2PhysAddr : 0;
    const uint32_t h2a = on ? (uint32_t)ivars->h2a2PhysAddr : 0;
    WriteRegister(dev, mi, kRegA2H2BUFSIZE, words);
    WriteRegister(dev, mi, kRegH2A2BUFSIZE, words);
    WriteRegister(dev, mi, kRegA2H2HBA, a2h);
    WriteRegister(dev, mi, kRegH2A2HBA, h2a);
    if (!on) return true;
    uint32_t ra = 0, rh = 0;
    ReadRegister(dev, mi, kRegA2H2HBA, &ra);
    ReadRegister(dev, mi, kRegH2A2HBA, &rh);
    if (ra != a2h || rh != h2a) {
        STERR("Port 2 audio: buffer address readback mismatch (A2H2 0x%08x want 0x%08x, "
              "H2A2 0x%08x want 0x%08x)", ra, a2h, rh, h2a);
        return false;
    }
    return true;
}

// Port 2's capture and playback buffers hold silence whenever its engine is
// off. Until Core Audio performs the configuration change the IO handler still
// copies channels 33-64 to and from them, and they must not replay old audio.
// Host memory only, no register access.
static void Port2SilenceBuffers(SymphonyThunderbridge_IVars *ivars)
{
    if (ivars->a2h2DMA)
        ivars->a2h2DMA->PerformOperation(
            kIODMACommandPerformOperationOptionZero, 0, kDMABufferSize, 0, nullptr);
    if (ivars->h2a2DMA)
        ivars->h2a2DMA->PerformOperation(
            kIODMACommandPerformOperationOptionZero, 0, kDMABufferSize, 0, nullptr);
}

// Phase alignment (og XLink::SetSampleRate :1079-1150). For every unit that is
// not a Symphony I/O, on port 1 and then port 2, read its word-clock phase
// (XLINK_CMD_WCLK_PHASE, one byte). Keep the first, and replace it whenever a
// later unit is more than 0x30 away. Then jam the card's sample count with
// (that phase - 5), using 0 instead of 0xFF when a unit reported phase 0
// (SampleClock::ShiftPhase). One jam for both ports; with only Symphony units
// nothing is read and the jam is 0 - 5 = 0xFB, as the original wrote.
// A unit that does not answer, or a jam still in progress, means nothing is
// written; that is recorded and (unlike the original) does not fail the caller.
// Called with the card muted and both engines stopped.
static void AlignXLinkPhase(SymphonyThunderbridge_IVars *ivars)
{
    IOPCIDevice *dev = ivars->pciDevice;
    const uint8_t mi = ivars->barMemoryIndex;
    uint8_t  base = 0;
    bool     first = true, zeroPhase = false, failed = false;
    uint32_t measured = 0;

    // Port 1: only a chain of the older converters is measured. unitProbeWord is
    // 0 for a Symphony I/O (Sym2Sym), which the original skipped.
    uint8_t port1Units = 0;
    const uint32_t probe = ivars->unitProbeWord;
    if ((probe & kUnitProbeInquireOK) && ((probe & 0xFF) >> 4) != 0) {
        port1Units = 1;
        for (uint8_t addr = 2; addr <= kXLinkMaxDevices; addr++)
            if ((probe >> (16 + 4 * (addr - 2))) & 0xF) port1Units = addr; else break;
    }
    for (int port = 1; port <= 2 && !failed; port++) {
        const uint64_t tx = port == 1 ? kRegXLink1TX : kRegXLink2TX;
        const uint64_t rx = port == 1 ? kRegXLink1RX : kRegXLink2RX;
        // Only a port that is switched on (the original: PortEnabled && clock,
        // XLink.cpp:985-986, 1079-1083); after 64 -> 32 port 2's units are still
        // listed but cannot answer, and asking them would fail the whole jam.
        const uint32_t count = port == 1 ? port1Units : (ivars->port2On ? ivars->port2UnitCount : 0);
        for (uint8_t addr = 1; addr <= count && addr <= kXLinkMaxDevices; addr++) {
            if (port == 2) {
                const uint32_t word = ivars->port2Unit[addr - 1];
                if (!(word & kSymphonyPort2UnitAddressed)) continue;
                const uint8_t groups = (uint8_t)(((word >> 8) & 0xF0) | ((word & 0xF0) >> 4));
                if (groups == 0xFF) continue;   // DEVICE_ROUTING_SYM2SYM: a Symphony I/O
            }
            uint8_t phase = 0;
            if (!XLinkInquireOn(dev, mi, tx, rx, addr, kXLinkCmdWclkPhase, &phase,
        ivars->isLegacyPCIe2100)) {
                STERR("Phase alignment: port %d unit %u did not answer the phase query", port, addr);
                failed = true;
                break;
            }
            measured++;
            if (phase == 0) zeroPhase = true;
            if (first || (uint8_t)(phase - base) > kPhaseWindow) {
                first = false;
                base = phase;
            }
            STLOG("Phase alignment: port %d unit %u phase 0x%02x (base 0x%02x)", port, addr, phase, base);
        }
    }

    uint32_t flags = __atomic_load_n(&ivars->port2AudioFlags, __ATOMIC_ACQUIRE);
    flags &= ~(kSymphonyPort2AudioPhaseAligned | kSymphonyPort2AudioPhaseFailed);
    uint8_t jam = 0;
    if (!failed) {
        // The original shifted the phase only while the first bus was receiving
        // clocks (XLink.cpp:1139).
        uint32_t clk = 0;
        ReadRegister(dev, mi, kRegXLinkClocking, &clk);
        if (!(clk & kXLinkRX1ClockDetect)) {
            STERR("Phase alignment: port 1 has no receive clock (0x%08x) — not written", clk);
            failed = true;
        }
    }
    if (!failed) {
        jam = (uint8_t)(base - kDefaultPhaseOffset);
        if (zeroPhase && jam == kJamNoAdjustment) jam = 0;
        uint32_t busy = 0;
        ReadRegister(dev, mi, kRegJam, &busy);
        if (busy & kJamActive) {
            STERR("Phase alignment: a jam is still in progress (0x%08x) — not written", busy);
            failed = true;
        } else {
            WriteRegister(dev, mi, kRegJam, jam);
            STLOG("Phase alignment: %u unit(s) measured, base 0x%02x, jam 0x%02x written", measured, base, jam);
        }
    }
    flags |= failed ? kSymphonyPort2AudioPhaseFailed : kSymphonyPort2AudioPhaseAligned;
    __atomic_store_n(&ivars->port2AudioFlags, flags, __ATOMIC_RELEASE);
    ivars->port2PhaseWord = kSymphonyPort2PhaseValid | (failed ? 0u : jam)
        | ((measured & 0xFF) << kSymphonyPort2PhaseUnitsShift)
        | ((uint32_t)base << kSymphonyPort2PhaseBaseShift);
}

// 32 -> 64. The caller has passed XLinkTxAdmissible; Core Audio has stopped IO.
// Returns true with both ports running, false with port 1 running alone as
// before and the reason recorded.
// Unit A's clock with or without its Loop Sync output, from the last ClockMode
// it was sent (the user's source is kept). With unit B present unit A must be
// the Loop Sync master: a recorded Loop Sync slave source becomes Internal.
static bool SendUnitAClock(SymphonyThunderbridge_IVars *ivars, bool loopSyncOut)
{
    uint8_t bytes[4] = { 0x01, 0x01, 0x00, 0x00 };
    if (ivars->unitAClockKnown) memcpy(bytes, ivars->unitAClock, 4);
    if (loopSyncOut) {
        if (bytes[0] == 3) { bytes[0] = 1; bytes[3] = 0; }
        bytes[1] = 1;
        bytes[2] = 1;
    }
    if (!loopSyncOut && ivars->loopSyncConfig != 0) {
        // Restore A as a standalone master after a non-default topology.
        if (bytes[0] == 3) { bytes[0] = 1; bytes[3] = 0; }
        bytes[1] = 1; bytes[2] = 0;
    }
    const bool ok = SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex, ivars->symphonyAddr,
                      kSIOCmd_ClockMode, 0, bytes, sizeof(bytes), ivars->runtimeTxSeq);
    ivars->unitAClockSentKnown = false;   // two-unit bytes: never a same-value skip
    STLOG("Unit A clock: source %u, %{public}s, Loop Sync output %{public}s",
          bytes[0], bytes[1] ? "master" : "slave", bytes[2] ? "on" : "off");
    return ok;
}

// Evidence: og_source/maestrolink/Software/SymphonyController.cpp:202-235
// (master first), og_source/maestrolink/Software/SymphonyPeripheralDevice.cpp:340-346
// (off => first unit), og_source/maestrolink/Software/SymphonyIO.cpp:4754-4767
// (non-master without Loop Sync => Word Clock).
static bool ApplyLoopSync(SymphonyThunderbridge_IVars *ivars, uint32_t config)
{
    const bool enabled = !(config & 1);
    const unsigned master = enabled && (config & 2) ? 1 : 0;
    uint8_t clock[2][4] = { {1,1,0,0}, {1,1,0,0} };
    if (ivars->unitAClockKnown) memcpy(clock[0], ivars->unitAClock, 4);
    if (ivars->unitBMasterClockKnown) memcpy(clock[1], ivars->unitBMasterClock, 4);
    if (clock[master][0] == 3) { clock[master][0] = 1; clock[master][3] = 0; }
    clock[master][1] = 1;
    clock[master][2] = enabled ? 1 : 0;
    const unsigned slave = 1 - master;
    clock[slave][0] = enabled ? 3 : 2;
    clock[slave][1] = enabled ? 0 : 1;
    clock[slave][2] = enabled ? 1 : 0;
    clock[slave][3] = 0;
    ivars->loopSyncValid = false;
    ivars->unitAClockSentKnown = false;   // two-unit bytes: never a same-value skip
    for (unsigned n = 0; n < 2; n++) {
        if (!XLinkTxAdmissible(ivars) || !ivars->port2On) return false;
        const unsigned p = n == 0 ? master : slave;
        if (!SendVendorRequestOn(ivars->pciDevice, ivars->barMemoryIndex,
                                 p ? kRegXLink2TX : kRegXLink1TX,
                                 p ? 1 : ivars->symphonyAddr, kSIOCmd_ClockMode, 0,
                                 clock[p], 4, p ? ivars->runtimeTxSeq2 : ivars->runtimeTxSeq)) {
            if (p) ivars->unitBTxErrors++;
            return false; // never make a slave follow a master whose write failed
        }
        if (p) ivars->unitBClockSource = clock[p][0];
    }
    ivars->loopSyncValid = true;
    return true;
}

static void ThunderboltWriteSoftwareReturn(SymphonyThunderbridge_IVars *ivars, uint16_t mixerID, uint8_t source);

// The output a unit's volume keys move: 0 = speakers, 1 = Headphone 1,
// 2 = Headphone 2 (also the headphone index of 0x23/0x24). Anything but a
// headphone choice is the speakers, the original's default.
static unsigned SelectedMonitorKind(const SymphonyThunderbridge_IVars *ivars, bool b)
{
    const uint8_t target = b ? ivars->unitBMonitorOutputTarget : ivars->monitorOutputTarget;
    if (target == kSymphonyMonitorOutputHP1) return 1;
    if (target == kSymphonyMonitorOutputHP2) return 2;
    return 0;
}

// Speakers chosen while the speaker mode is Off (Line): the original ignored
// a Core Audio volume set there (SymphonyIO.cpp:2345-2351) and listed the
// entry as "Speaker (0ch)" (:3562-3571). The volume keys then move nothing
// (the mute key still sets the speaker mute, :2239-2251). The original
// changed its choice to Headphone 1 itself when the user set the mode to Off
// (:6142-6168); Maestro does that and sends the choice (SetMonitorOutput).
static bool SelectedMonitorInert(const SymphonyThunderbridge_IVars *ivars, bool b)
{
    return SelectedMonitorKind(ivars, b) == 0 && (b ? ivars->unitBLineMode : ivars->lineMode);
}

static uint8_t &MonitorAttenuation(SymphonyThunderbridge_IVars *ivars, bool b, unsigned kind)
{
    if (kind == 1) return b ? ivars->unitBHP1Attenuation : ivars->hp1Attenuation;
    if (kind == 2) return b ? ivars->unitBHP2Attenuation : ivars->hp2Attenuation;
    return b ? ivars->unitBSpeakerAttenuation : ivars->speakerAttenuation;
}

static bool &MonitorMute(SymphonyThunderbridge_IVars *ivars, bool b, unsigned kind)
{
    if (kind == 1) return b ? ivars->unitBHP1Mute : ivars->hp1Mute;
    if (kind == 2) return b ? ivars->unitBHP2Mute : ivars->hp2Mute;
    return b ? ivars->unitBSpeakerMute : ivars->speakerMute;
}

// Every way out of two-unit mode: unit B is no longer configured, unit A's
// clock gets its single-unit message back (when the card can be reached), and
// a card-mixer Software Return pointing above DAW 1-16 goes back to 1-2.
// Called on xlinkQueue, alongside physical monitor writes and target changes.
// Evidence: og_source/maestrolink/Software/SymphonyController.cpp:528-550
// changes monitor identity and publishes that device's level/mute together.
static void PublishSelectedMonitor(SymphonyThunderbridge_IVars *ivars)
{
    const bool b = ivars->monitorDeviceB;
    const unsigned kind = SelectedMonitorKind(ivars, b);
    // Speakers chosen in Line mode: the original's reading there is a fixed
    // 20 dB attenuation (SymphonyIO.cpp:3145-3152) with the speaker's mute
    // (:3069-3081); the control does nothing (see the drain).
    const uint8_t attenuation = SelectedMonitorInert(ivars, b)
        ? kLineModeSpeakerReading : MonitorAttenuation(ivars, b, kind);
    const bool muted = MonitorMute(ivars, b, kind);
    ivars->lastVolumeDb = -static_cast<float>(attenuation);
    ivars->lastMuteState = muted;
    if (ivars->outputVolumeControl) ivars->outputVolumeControl->SetDecibelValue(ivars->lastVolumeDb);
    if (ivars->outputMuteControl) ivars->outputMuteControl->SetControlValue(muted);
    __atomic_fetch_add(&ivars->monitorGeneration, 1, __ATOMIC_RELEASE);
}

// Whether a control holds a value other than the one last sent or shown.
static bool MonitorControlsMoved(SymphonyThunderbridge_IVars *ivars)
{
    if (ivars->outputVolumeControl) {
        const float diff = ivars->outputVolumeControl->GetDecibelValue() - ivars->lastVolumeDb;
        if (diff > 0.5f || diff < -0.5f) return true;
    }
    return ivars->outputMuteControl && ivars->outputMuteControl->GetControlValue() != ivars->lastMuteState;
}

// The ClkCtrl bits an unmute may set: while a fresh instance holds its
// start-up output gate, every unmute (rate change, recovery, wake) leaves the
// output path muted, so nothing plays before Core Audio's saved state lands.
static uint32_t ClkCtrlUnmuteBits(const SymphonyThunderbridge_IVars *ivars)
{
    uint32_t bits = kClkCtrl_Unmute | kClkCtrl_InputUnmute;
    if (!ivars || !ivars->startupOutputMuteHeld) bits |= kClkCtrl_OutputUnmute;
    return bits;
}

// dext 152: the gate opens kStartupRateGraceNs after the hardware runs at
// Core Audio's rate, or at the deadline when no rate settled. It no longer
// waits for a Core Audio control to change: Core Audio restores the values
// the controls already show, so that wait always ran to the deadline. A
// mute Core Audio restores before the gate opens is applied first: the
// release runs the monitor poll itself, inline on xlinkQueue, just before
// it unmutes the outputs. The interrupt's poll is not enough on its own:
// with no IO running nothing schedules it.
static constexpr uint64_t kStartupRateGraceNs = 400000000ull;   // 400 ms

static void RunMonitorPollOnQueue(SymphonyThunderbridge_IVars *ivars);

static void MaybeReleaseStartupOutputMute(SymphonyThunderbridge_IVars *ivars)
{
    if (!ivars || !ivars->startupOutputMuteHeld) return;
    const uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    const uint64_t releaseAt = __atomic_load_n(&ivars->startupReleaseAtNs, __ATOMIC_ACQUIRE);
    // Once the rate has settled, the grace decides (the 3 s cap is for a
    // rate that never settles).
    const bool settled = releaseAt != 0;
    if (settled ? now < releaseAt : now < ivars->startupOutputMuteDeadlineNs) return;
    // ModifyRegister reads the BAR: never with the endpoint gone (asleep,
    // powered off, link down). Stay held; a later tick retries, and every
    // reprogram after recovery or wake goes through ClkCtrlUnmuteBits.
    if (__atomic_load_n(&ivars->stopping, __ATOMIC_ACQUIRE) ||
        !XLinkTxAdmissible(ivars) ||
        __atomic_load_n(&ivars->hwSuspended, __ATOMIC_ACQUIRE) ||
        __atomic_load_n(&ivars->providerPowerOff, __ATOMIC_ACQUIRE))
        return;

    // Send whatever the monitor poll would send (a restored mute on, a
    // level) to the unit first, the same way and on the same queue as the
    // interrupt's poll, so the unit's own speaker/headphone mute is on before
    // any output opens. Then release the card's whole output path; the card
    // gate covers every output, so it must never stay closed.
    if (!__atomic_load_n(&ivars->txShutdown, __ATOMIC_ACQUIRE))
        RunMonitorPollOnQueue(ivars);
    if (ivars->pciDevice) {
        ModifyRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegClkCtrl,
                       kClkCtrl_OutputUnmute, 0);
        if (settled) {
            const uint64_t settledAt = releaseAt > kStartupRateGraceNs ? releaseAt - kStartupRateGraceNs : 0;
            STLOG("ClkCtrl: startup output unmuted %llu ms after the rate settled",
                  (unsigned long long)((now - settledAt) / 1000000ull));
        } else
            STLOG("ClkCtrl: startup output unmuted after 3 s timeout (no rate)");
    }
    ivars->startupOutputMuteHeld = false;
    __atomic_store_n(&ivars->startupRatePending, false, __ATOMIC_RELEASE);
}

// dext 151: the hardware now runs at Core Audio's rate: a rate Core Audio
// set was programmed, or Core Audio set the rate the hardware already runs
// at. dext 152: an IO start at the hardware's rate no longer counts (it can
// come before Core Audio has restored its controls); the gate keeps its
// deadline then. Clears the start-up gate's rate wait and arms the release
// on xlinkQueue, which owns the gate; a no-op once the gate has opened.
static void NoteStartupRateSettled(SymphonyThunderbridge_IVars *ivars, double rate, const char *why)
{
    if (!ivars || !__atomic_exchange_n(&ivars->startupRatePending, false, __ATOMIC_ACQ_REL)) return;
    STLOG("ClkCtrl: startup rate settled at %.0f Hz (%{public}s)", rate, why);
    __atomic_store_n(&ivars->startupReleaseAtNs,
                     clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) + kStartupRateGraceNs, __ATOMIC_RELEASE);
    // The link watch releases the gate when the grace is over.
    ArmLinkWatch(ivars, kStartupRateGraceNs);
}

static bool ReadUnitAMonitorLevel(SymphonyThunderbridge_IVars *ivars, uint32_t output);

static void LeaveTwoUnit(SymphonyThunderbridge_IVars *ivars, bool touchHardware)
{
    ++ivars->unitBGeneration;
    const bool was = ivars->unitBConfigured;
    ivars->unitBConfigured = false;
    LatchChannelOrder(ivars, 1, 0);   // no unit B tables in use: selector 17 reports None
    for (uint32_t ch = 0; ch < 8; ++ch)
        __atomic_store_n(&ivars->unitBMicPreTypeKnown[ch], false, __ATOMIC_RELEASE);
    memset(ivars->unitBMicPreGainKnown, 0, sizeof(ivars->unitBMicPreGainKnown));
    PublishAllMicPreControls(ivars);   // inputs routed to unit B no longer resolve
    ivars->loopSyncValid = false;
    if (__atomic_exchange_n(&ivars->monitorDeviceB, false, __ATOMIC_ACQ_REL)) {
        PublishSelectedMonitor(ivars);
        STLOG("Monitor target fallback: unit B left 64-channel mode; volume keys now target unit A");
    }
    if (!was) return;
    const bool reachable = touchHardware && ivars->pciDevice && XLinkTxAdmissible(ivars);
    if (reachable) SendUnitAClock(ivars, false);
    for (uint16_t m = 1; m <= 2; m++) {
        if (IsThunderboltSoftwareReturnSource(ivars->mixerSwReturnSource[m - 1])) continue;
        ivars->mixerSwReturnSource[m - 1] = 0;
        if (reachable) ThunderboltWriteSoftwareReturn(ivars, m, 0);
    }
    STLOG("Unit B: left two-unit mode%{public}s", reachable ? "" : " (card not reachable; clock left as it was)");
}

static void ThunderboltWriteSoftwareReturn(SymphonyThunderbridge_IVars *ivars, uint16_t mixerID, uint8_t source)
{
    for (uint8_t side = 0; side < 2; side++)
        WriteRegister(ivars->pciDevice, ivars->barMemoryIndex, ThunderboltMixerReturnRegister(mixerID, side),
                      ThunderboltSoftwareReturnSlot(source, side) | kRoutingEnable);
    STLOG("Card mixer: mixer %u SW Return source=%u (back within DAW 1-32)", mixerID, source);
}

// Two units at 64 channels: configure the Symphony I/O on port 2 ("unit B").
// The original created a full SymphonyIO peripheral for (card, bus 1, device 0)
// and sent it everything unit A got, over XLink 2 to address 1, with its own
// message sequence (SymphonyIOSymphonyPeripheralDevice.cpp:52-70,
// SymphonyDriverInterface.cpp:982-1016); not being the master, it was set to
// Loop Sync slave of unit A (Loop Sync mode on, the original's default). This mirrors what ConfigureSymphonyLink sends unit A (19b): lock,
// clock, optical format, playback and capture routing, unlock. Unit B's
// monitor settings stay its own;
// Maestro sets the rest through the port byte. On xlinkQueue, port 2 enabled
// and its unit addressed; nothing is sent unless the unit answers a vendor read.
static void ConfigureUnitB(SymphonyThunderbridge_IVars *ivars)
{
    ++ivars->unitBGeneration;
    // setupFlags is already part of selector 11.  Keep bit 0 as the historic
    // "configured" value and expose the first failed mandatory stage in the
    // high byte so the app can report why unit B fell back without an ABI
    // change.  The stage order follows the original ApplySettingsToHardware /
    // SetPeripheralReady flow (og_source/maestrolink/Software/SymphonyIO.cpp:4660-4735).
    enum : uint32_t {
        kUnitBSetupOK       = 1u << 0,
        kUnitBFailBoard0    = 1u << 8,
        kUnitBFailBoard1    = 1u << 9,
        kUnitBFailPrefix    = 1u << 10,
        kUnitBFailLock      = 1u << 11,
        kUnitBFailClock     = 1u << 12,
        kUnitBFailOptical   = 1u << 13,
        kUnitBFailRouting   = 1u << 14,
        kUnitBFailMute      = 1u << 15,
        kUnitBFailUnlock    = 1u << 16,
    };
    IOPCIDevice *dev = ivars->pciDevice;
    const uint8_t mi = ivars->barMemoryIndex;
    const bool pcie = ivars->isLegacyPCIe2100;
    uint8_t &seq = ivars->runtimeTxSeq2;
    auto send = [&](uint8_t cmd, uint32_t value, const uint8_t *data, uint16_t len) {
        const bool ok = SendVendorRequestOn(dev, mi, kRegXLink2TX, 1, cmd, value, data, len, seq);
        if (!ok) ivars->unitBTxErrors++;
        return ok;
    };
    ivars->unitBConfigured = false;
    LatchChannelOrder(ivars, 1, 0);   // latched again below once the set-up succeeds
    for (uint32_t ch = 0; ch < 8; ++ch)
        __atomic_store_n(&ivars->unitBMicPreTypeKnown[ch], false, __ATOMIC_RELEASE);
    memset(ivars->unitBMicPreGainKnown, 0, sizeof(ivars->unitBMicPreGainKnown));
    ResetMicPreUnitCaches(ivars, 1, true);   // possibly another unit B: its edits go too
    ivars->unitBSetupFlags = 0;
    uint32_t failures = 0;
    bool mandatoryOK = true;
    auto require = [&](bool ok, uint32_t flag, const char *stage) {
        if (ok) return;
        mandatoryOK = false;
        failures |= flag;
        STERR("Unit B: mandatory %s failed", stage);
    };
    for (uint32_t b = 0; b < 2; b++) {
        uint8_t bt = kSIOOptionBoard_None;
        const bool boardOK = ReadVendorRequestOn(dev, mi, kRegXLink2TX, kRegXLink2RX, 1,
                                                 kSIOCmd_OptionBoardType, b, &bt, 1, seq, pcie);
        if (!boardOK) ivars->unitBTxErrors++;
        require(boardOK, b == 0 ? kUnitBFailBoard0 : kUnitBFailBoard1,
                b == 0 ? "OptionBoardType(0) read" : "OptionBoardType(1) read");
        ivars->unitBBoardValid[b] = boardOK;
        ivars->unitBBoardType[b] = ivars->unitBBoardValid[b] ? bt : 0;
    }
    // Identity gate (kept from dext 131): a unit that answers neither board-type
    // read is not a Symphony I/O (converters do not answer Symphony vendor
    // reads). Nothing more is sent to it — no lock, clock, routing or unlock —
    // and unit A's clock is not touched.
    if (!ivars->unitBBoardValid[0] && !ivars->unitBBoardValid[1]) {
        ivars->unitBSetupFlags = failures;
        STERR("Unit B: the Symphony I/O on port 2 does not answer — not configured");
        return;
    }
    uint8_t prefix = 0;
    const bool prefixOK = ReadVendorRequestOn(dev, mi, kRegXLink2TX, kRegXLink2RX, 1,
                                               kSymphonyCmdPrefix, 0, &prefix, 1, seq, pcie);
    if (!prefixOK) ivars->unitBTxErrors++;
    require(prefixOK, kUnitBFailPrefix, "prefix read");
    if (prefixOK)
        ivars->unitBPrefix = prefix;
    uint8_t lock = 1;
    require(send(kSIOCmd_PreferenceLoadLock, 0, &lock, 1), kUnitBFailLock, "preference lock");
    IOSleep(10);
    // Loop Sync, as the original by default (SymphonyController m_fLoopSyncMode
    // starts true, SymphonyController.cpp:2708; the Symphony I/O user guide
    // links the units by their Loop Sync BNCs): the master (unit A) first with
    // its Loop Sync output on, then unit B as Loop Sync slave
    // (SymphonyController.cpp:202-235, SymphonyIO.cpp:4752-4767).
    bool clockOK;
    if (ivars->loopSyncConfig == 0) {
        // Preserve the existing default startup bytes and delays.
        const bool masterOK = SendUnitAClock(ivars, true);
        IOSleep(10);
        const uint8_t clockData[4] = { 0x03, 0x00, 0x01, 0x00 };
        clockOK = masterOK && send(kSIOCmd_ClockMode, 0, clockData, sizeof(clockData));
        if (clockOK) ivars->unitBClockSource = 3;
        ivars->loopSyncValid = clockOK;
    } else {
        clockOK = ApplyLoopSync(ivars, ivars->loopSyncConfig);
    }
    require(clockOK, kUnitBFailClock, "clock mode");
    IOSleep(10);
    for (uint32_t b = 0; b < 2; b++) {
        if (!BootSendsOpticalFormat(ivars->unitBBoardValid[b], ivars->unitBBoardType[b])) continue;
        const uint8_t format = 0;   // ADAT/SMUX until Maestro sets unit B's
        ivars->unitBOptical[b] = 0;
        require(send(kSIOCmd_OpticalFormat, b, &format, 1), kUnitBFailOptical, "optical format");
        IOSleep(10);
    }
    // dext 150: unit B is laid out analog first from its own two board
    // types, as unit A is (steps 19b-1 and 19b-2, SymphonyPlaybackSource /
    // SymphonyCaptureSource): by position / card by card while a type is
    // unknown.
    uint8_t routes[32];
    bool routingSent = true;   // every 0x31 send below went out (selector 17's latch)
    for (uint32_t board = 0; board < 2; board++) {
        for (int n = 0; n < 16; n++) {
            routes[n * 2] = (uint8_t)((board ? kSIODest_IOBoard1Ch0 : kSIODest_IOBoard0Ch0) + n);
            routes[n * 2 + 1] = SymphonyPlaybackSource(ivars->unitBBoardType, ivars->unitBBoardValid, board, (unsigned)n);
        }
        const bool playbackOK = send(kSIOCmd_AudioRouting, 0, routes, sizeof(routes));
        routingSent = routingSent && playbackOK;
        require(playbackOK, kUnitBFailRouting,
                board ? "playback routing (board 1)" : "playback routing (board 0)");
        IOSleep(20);
    }
    for (int half = 0; half < 2; half++) {
        for (int n = 0; n < 16; n++) {
            const unsigned host = (unsigned)(half * 16 + n);
            routes[n * 2] = (uint8_t)(kSIODest_P2PCh0 + host);
            routes[n * 2 + 1] = SymphonyCaptureSource(ivars->unitBBoardType, ivars->unitBBoardValid, host);
        }
        const bool captureOK = send(kSIOCmd_AudioRouting, 0, routes, sizeof(routes));
        routingSent = routingSent && captureOK;
        require(captureOK, kUnitBFailRouting, "capture routing");
        if (captureOK) {
            for (uint32_t n = 0; n < 16; n++)
                __atomic_store_n(&ivars->unitBInputRouteSource[(unsigned)half * 16 + n], routes[n * 2 + 1], __ATOMIC_RELEASE);
        }
        IOSleep(20);
    }
    // (dext 142) The unit's mixer inputs are not muted any more, as for unit
    // A (19b-3). kUnitBFailMute stays in the set-up word for the app's sake
    // and is never set.
    // Match SetPeripheralReady(true): retry the final unlock, and verify the
    // read-back up to ten times at 5 ms intervals even when an earlier stage
    // failed, so a partially configured unit is never left muted.
    uint8_t unlock = 0;
    bool unlocked = false;
    for (int attempt = 0; attempt < 10; attempt++) {
        send(kSIOCmd_PreferenceLoadLock, 0, &unlock, 1);
        uint8_t locked = 1;
        const bool read = ReadVendorRequestOn(dev, mi, kRegXLink2TX, kRegXLink2RX, 1,
                                              kSIOCmd_PreferenceLoadLock, 0, &locked, 1, seq, pcie);
        if (read && locked == 0) { unlocked = true; break; }
        if (attempt != 9) IOSleep(5);
    }
    require(unlocked, kUnitBFailUnlock, "preference unlock/read-back");
    ivars->unitBSetupFlags = unlocked && mandatoryOK ? kUnitBSetupOK : failures;
    ivars->unitBConfigured = unlocked && mandatoryOK;
    // dext 150: the order and types unit B's four 0x31 sends built, for
    // selector 17 and unit B's channel names. Only for a configured unit B
    // (routing is mandatory, so that already means every send went out); an
    // unconfigured one stays None, as LeaveTwoUnit leaves it.
    if (ivars->unitBConfigured && routingSent)
        LatchChannelOrder(ivars, 1, PackChannelOrder(ivars->unitBBoardType, ivars->unitBBoardValid));
    // A MicPre companion owns its selector state on unit B.  Read it once at
    // configuration so the published selectors and gain lane start from the
    // hardware value; rigs without the option board take no extra traffic.
    if (ivars->unitBConfigured && ivars->unitBBoardValid[1] &&
        ivars->unitBBoardType[1] == kSIOOptionBoard_MicPre8) {
        for (uint32_t ch = 0; ch < 8; ++ch) {
            uint8_t type = 0;
            if (!ReadVendorRequestOn(dev, mi, kRegXLink2TX, kRegXLink2RX, 1,
                                     kSIOCmd_CurrentAnalogInputType,
                                     0x80000000u | ch, &type, 1, seq, pcie) || type > 4)
                continue;
            ivars->unitBMicPreInstrument[ch] = type == 4;
            ivars->unitBMicPreMic[ch] = type == 3;
            ivars->unitBMicPreTypeKnown[ch] = true;
            ivars->micPreType[1][ch] = type;
            ivars->halMicTypeStamp[1][ch] = 0;   // the unit reported it
        }
        // Polarity and high-pass too, as for unit A (SymphonyIOBoard_MicPre8ch.cpp:2205-2223).
        for (uint32_t ch = 0; ch < 8; ++ch) ReadMicPreSwitches(ivars, 1, ch);
    }
    if (!ivars->unitBConfigured) {
        ivars->loopSyncValid = false;
        // The controls go back to unit A at unit A's level: left at unit B's,
        // the next key would step unit A from it. (Today every caller has
        // already left two-unit mode, LeaveTwoUnit, which does the same; this
        // keeps it true if that ever changes.)
        if (__atomic_exchange_n(&ivars->monitorDeviceB, false, __ATOMIC_ACQ_REL)) PublishSelectedMonitor(ivars);
    }
    if (!ivars->unitBConfigured) SendUnitAClock(ivars, false);   // no unit B after all: unit A's Loop Sync output off again
    PublishAllMicPreControls(ivars);   // host inputs routed to unit B resolve again (or no longer)
    STLOG("Unit B: %{public}s (boards %u/%u, prefix 0x%02x, %u message error(s), set-up 0x%05x)",
          unlocked ? "configured" : "set-up incomplete", ivars->unitBBoardType[0], ivars->unitBBoardType[1],
          ivars->unitBPrefix, ivars->unitBTxErrors, ivars->unitBSetupFlags);
}

static bool EnablePort2Audio(SymphonyThunderbridge_IVars *ivars)
{
    // A unit B from an earlier 64 session is set up again below, or not at all.
    LeaveTwoUnit(ivars, true);
    IOPCIDevice *dev = ivars->pciDevice;
    const uint8_t mi = ivars->barMemoryIndex;
    if (!ivars->port2AudioReady) {
        Port2AudioNote(ivars, kSymphonyPort2AudioRefused, kSymphonyPort2ReasonNoBuffers);
        STERR("Port 2 audio: refused — the port-2 DMA buffers do not exist");
        return false;
    }
    const double rate = ivars->xlinkRate > 0.0 ? ivars->xlinkRate : 44100.0;
    const uint8_t rateCode = SampleRateToXLinkCode(rate);
    // Port 2 is switched on and identified now, not at Start: the original
    // enabled a second bus only for a 64-channel source and its next BusInit
    // enumerated it (setCardEnabled(true, 2) → XLink::SetNumPorts(2) →
    // ForceReconfigure, Symphony64Card.cpp:2249-2262, XLink.cpp:888-913).
    // The unit's clock needs a moment once the port is enabled, so the probe
    // waits up to 2 s for it (unverified on hardware).
    SetPort2Enabled(ivars, true);
    ProbeSecondPort(ivars, rate, "\"" kSymphonyPortSourceName64 "\" selected", kPort2ClockPollsOnSelect);
    // The probe can take seconds. If a stop or power-down began meanwhile,
    // touch nothing more. Port 2 stays enabled until the next Start(), the
    // wake re-initialization of a reset card, or, when the card kept its
    // registers across the sleep, the first link-watch tick that reaches it
    // (port2DisablePending).
    if (!XLinkTxAdmissible(ivars)) {
        ivars->port2DisablePending = true;
        Port2AudioNote(ivars, kSymphonyPort2AudioRefused, kSymphonyPort2ReasonUnreachable);
        STERR("Port 2 audio: refused — stop or power-down began while port 2 was looked at");
        return false;
    }
    if (!Port2FoundUnit(ivars)) {
        // Deliberate departure: the original kept reconfiguring, muted, while
        // port 2 had no clock (XLink.cpp:300-304). This driver refuses and
        // stays at 32 with port 2 disabled again.
        SetPort2Enabled(ivars, false);
        Port2AudioNote(ivars, kSymphonyPort2AudioRefused, kSymphonyPort2ReasonNoUnit);
        STLOG("Port 2 audio: refused — no unit with its data link up on port 2");
        return false;
    }

    // Unit-B vendor bring-up is performed by the dedicated user-client path
    // once the second bus is carrying audio; discovery remains side-effect free.
    STLOG("Port 2 audio: enabling at %.0f Hz (%u unit(s) on port 2)", rate, ivars->port2UnitCount);

    if (!Port2StopBothEngines(dev, mi)) {
        // The card was stopped and muted (a failed rate change). It stays so.
        SetPort2Enabled(ivars, false);
        Port2AudioNote(ivars, kSymphonyPort2AudioRefused, kSymphonyPort2ReasonUnreachable);
        STERR("Port 2 audio: refused — the card's DMA was stopped (failed rate change); left stopped");
        return false;
    }

    // Port 2 must be at the rate port 1 runs at, and locked, before it carries
    // audio: the per-bus part of the original's SetSampleRate.
    Port2RateChange p2;
    p2.ivars = ivars;
    {
        uint32_t clk = 0;
        ReadRegister(dev, mi, kRegXLinkClocking, &clk);
        p2.clock = (clk & kXLinkRX2ClockDetect) != 0 && (clk & kXLinkSR2Mask) != 0;
    }
    if (p2.clock && rateCode != 0xFF) Port2RateAfter(dev, mi, rate, rateCode, &p2);
    ivars->port2RateHz = p2.ok ? (uint32_t)(rate + 0.5) : 0;
    if (!p2.ok) {
        SetPort2Enabled(ivars, false);
        Port2StartPort1Engine(ivars);
        Port2AudioNote(ivars, kSymphonyPort2AudioRefused, kSymphonyPort2ReasonRateNotLocked);
        STERR("Port 2 audio: refused — port 2 did not lock at %.0f Hz; port 1 restarted alone", rate);
        return false;
    }

    // The lock waits above can take seconds. If a stop or a power-down began, or
    // the endpoint went away meanwhile, touch nothing more: the card stays
    // muted with its engines off, which is what Stop() and the wake
    // re-initialization (CardLostConfiguration sees DMA off) both start from.
    // Port 2 is disabled by either, or by the link watch (port2DisablePending).
    if (!XLinkTxAdmissible(ivars)) {
        ivars->port2DisablePending = true;
        Port2AudioNote(ivars, kSymphonyPort2AudioRefused, kSymphonyPort2ReasonUnreachable);
        STERR("Port 2 audio: refused — stop or power-down began during the switch");
        return false;
    }

    AlignXLinkPhase(ivars);

    Port2SilenceBuffers(ivars);
    if (!Port2ProgramBuffers(ivars, true)) {
        Port2ProgramBuffers(ivars, false);
        SetPort2Enabled(ivars, false);
        Port2StartPort1Engine(ivars);
        Port2AudioNote(ivars, kSymphonyPort2AudioRefused, kSymphonyPort2ReasonRegisters);
        return false;
    }
    Port2ProgramRouting(ivars, true);
    // The units on port 2 were never unmuted in stage 1 (og EnableDeviceRouting).
    for (uint8_t addr = 1; addr <= ivars->port2UnitCount && addr <= kXLinkMaxDevices; addr++) {
        if (!(ivars->port2Unit[addr - 1] & kSymphonyPort2UnitAddressed)) continue;
        if (!SendXLinkCommandOn(dev, mi, kRegXLink2TX, addr, kXLinkCmdUnmute, 0x80))
            STERR("Port 2 audio: UNMUTE to port 2 unit %u timed out", addr);
    }
    // dext 131: converters on port 2 are placed and named by the routing
    // layer's rules, after port 1's channels (SymphonyConverters.h). A Symphony
    // I/O on port 2 keeps the identity routing written above.
    {
        uint32_t n = 0, p2units[kXLinkMaxDevices] = {};
        for (uint32_t u = 0; u < ivars->port2UnitCount && u < kXLinkMaxDevices; u++) {
            const uint32_t w = ivars->port2Unit[u];
            if (!(w & kSymphonyPort2UnitAddressed) || Port2UnitIsSymphony(w)) break;
            // The converter words keep their own flag bits (Device Type); the
            // port-2 probe's type byte and kept-address bit stay out of them.
            p2units[n++] = w & ~(kSymphonyPort2UnitTypeMask | kSymphonyPort2UnitTypeOK | kSymphonyPort2UnitKeptAddress);
        }
        ConvSetPort(ivars, 1, n != 0, n, p2units);
        if (n) {
            __atomic_or_fetch(&ivars->convFlags, kSymphonyConvPort2Converters, __ATOMIC_RELEASE);
            ApplyConverterRouting(ivars, "64 channels");
        } else {
            __atomic_and_fetch(&ivars->convFlags, ~kSymphonyConvPort2Converters, __ATOMIC_RELEASE);
        }
    }
    // A Symphony I/O on port 2 is unit B: set it up as the original did.
    if (ivars->port2UnitCount > 0 && (ivars->port2Unit[0] & kSymphonyPort2UnitAddressed) &&
        Port2UnitIsSymphony(ivars->port2Unit[0]))
        ConfigureUnitB(ivars);

    // Last check before DMA is enabled (the phase queries and unmutes above
    // take time too). Stop() re-clears the DMA bits after draining this queue
    // in any case; this keeps the window as small as the one-port restart's.
    if (!XLinkTxAdmissible(ivars)) {
        Port2ProgramRouting(ivars, false);
        Port2ProgramBuffers(ivars, false);
        ivars->port2DisablePending = true;
        Port2AudioNote(ivars, kSymphonyPort2AudioRefused, kSymphonyPort2ReasonUnreachable);
        STERR("Port 2 audio: refused — stop or power-down began before the engines were started");
        return false;
    }
    WriteRegister(dev, mi, kRegIntStatus, 0xFFFFFFFF);
    Port2SetCardMode(ivars, 64);
    UpdateStatusLEDs(ivars, true, ivars->port2ClockingProblem);
    Port2StartBothEngines(ivars);
    Port2AudioNote(ivars, 0, kSymphonyPort2ReasonNone);
    STLOG("Port 2 audio: ON — channels 33-64 are port 2");
    return true;
}

// 64 -> 32: port 2's engine off, its routing entries disabled, its buffer
// registers back to zero, port 1 restarted alone (if it was running). Sends nothing on port 2 (its
// units may be gone). outcome/reason as Port2AudioNote.
static void DisablePort2Audio(SymphonyThunderbridge_IVars *ivars, uint32_t outcome, uint32_t reason)
{
    // dext 131: port 2's converters stop counting (their routing entries are
    // disabled with the rest of port 2's below).
    __atomic_and_fetch(&ivars->convFlags, ~kSymphonyConvPort2Converters, __ATOMIC_RELEASE);
    ConvSetPort(ivars, 1, false, 0, nullptr);
    LeaveTwoUnit(ivars, true);   // unit B is set up again when 64 starts
    IOPCIDevice *dev = ivars->pciDevice;
    const uint8_t mi = ivars->barMemoryIndex;
    const bool wasRunning = Port2StopBothEngines(dev, mi);
    Port2ProgramRouting(ivars, false);
    RestorePort1InputRoutesAfter64(ivars);
    Port2ProgramBuffers(ivars, false);
    Port2SilenceBuffers(ivars);
    // Port 2 off again, as the original's SetNumPorts(1) (XLink.cpp:906-907).
    SetPort2Enabled(ivars, false);
    Port2SetCardMode(ivars, 32);
    UpdateStatusLEDs(ivars, false, ivars->port2ClockingProblem);
    if (wasRunning) Port2StartPort1Engine(ivars);   // else: stopped and muted stays stopped and muted
    Port2AudioNote(ivars, outcome, reason);
    STLOG("Port 2 audio: OFF (reason %u) — port 1 %{public}s", reason,
          wasRunning ? "running alone" : "left stopped (it was stopped)");
}

// Ask Core Audio for the configuration change in which the streams and the
// selectors are brought in line with the card. From any queue: the request is
// made on the default queue, never on xlinkQueue.
static void RequestPortModeConfigChange(SymphonyThunderbridge_IVars *ivars,
                                        SymphonyThunderbridge *self, const char *why)
{
    if (!ivars || !ivars->defaultQueue || !self) return;
    ArmMicPreSettle(ivars);   // coreaudiod re-reads the device and its controls
    self->retain();
    ivars->defaultQueue->DispatchAsync(^{
        if (!__atomic_load_n(&ivars->stopping, __ATOMIC_ACQUIRE) && ivars->audioDevice) {
            kern_return_t rc = ivars->audioDevice->RequestDeviceConfigurationChange(
                kSymphonyConfigChangePortMode, nullptr);
            STLOG("Port selection: requested Core Audio configuration change (%{public}s, 0x%x)", why, rc);
        }
        self->release();
    });
}

// The driver itself leaves 64 (port 2's clock went, the card was reset, port 2
// did not follow a rate change). On xlinkQueue. With touchHardware the card is
// put back to port 1 alone here and now; without, only the bookkeeping changes
// (the caller has already left the card with port 2 off). Either way Core Audio
// is asked for a configuration change so the streams return to 32 channels.
// Does nothing unless 64 is running.
static void Port2AudioFallBack(SymphonyThunderbridge_IVars *ivars, SymphonyThunderbridge *self,
                               uint32_t reason, bool touchHardware)
{
    if (ivars->portCount != 2 ||
        __atomic_load_n(&ivars->portMode, __ATOMIC_ACQUIRE) != 64) return;
    if (touchHardware) {
        DisablePort2Audio(ivars, kSymphonyPort2AudioFellBack, reason);
    } else {
        LeaveTwoUnit(ivars, false);
        Port2SilenceBuffers(ivars);
        Port2SetCardMode(ivars, 32);
        Port2AudioNote(ivars, kSymphonyPort2AudioFellBack, reason);
    }
    // Preserve a remembered 64-channel request. The next watch tick that sees
    // a returned port-2 unit asks Core Audio to retry the configuration change.
    __atomic_store_n(&ivars->requestedPortMode, 64u, __ATOMIC_RELEASE);
    ivars->port2ResumeUnitSeen = false;
    STERR("Port 2 audio: fell back to port 1 alone (reason %u)", reason);
    RequestPortModeConfigChange(ivars, self, "fell back to 32 channels");
}

static void RecomputeCardMixer(SymphonyThunderbridge_IVars *iv, IOPCIDevice *dev, uint8_t mi,
                               uint16_t mixerID);

// ── Per-channel names ───────────────────────────────────────────────────────
// Apogee's daemon gave every host channel of the Symphony card the name of the
// hardware channel it carried (SymphonyCard.cpp:828-866), following the rate,
// optical format and S/PDIF Coax Replaces; see SymphonyChannelNames.h. Input
// channels are named after the Symphony routing source this driver last sent
// for P2P n. Output channels keep fixed names from their position: host
// output n is named after the board output the driver's own table at step
// 19b-1 sends it to (dext 150: the n-th board output, analog first; by
// position, slot 1 output n for 1-16 and slot 2 output n-16 for 17-32, while
// a board type is unknown), as the app's Output Routing rows name them, and
// never after the card's output
// routes or mixer (SymphonyHostOutputName). Both are republished on the same
// events: rate, optical format, prefix, Replaces and a card read or recovery.
// dext 150: the board types both units are named from are the ones their
// tables were built from (channelOrderLatch, selector 17), see below.
//
// Inputs first resolve the card host-to-RX route, then that port's P2P table.
// This also handles duplicate sources and cross-port routes; disabled routes
// have no hardware name. Output names remain fixed by position.
// Evidence: og_source/maestrolink/Software/SymphonyCard.cpp:828-866.
//
// Runs on the default queue (Start, or a block queued by
// ScheduleChannelNames), never on xlinkQueue.
static void PublishChannelNames(SymphonyThunderbridge_IVars *ivars)
{
    if (!ivars || !ivars->audioDevice || __atomic_load_n(&ivars->stopping, __ATOMIC_ACQUIRE))
        return;
    // dext 150: each unit's names are built from the board types its routing
    // tables were last programmed with (channelOrderLatch, selector 17), not
    // from a separate 0xA1 read: output n is named after the board output
    // the playback table plays it through, and that depends on the types the
    // table was built from. Start and link recovery read the types again
    // after the configuration (optionBoardType, for the app's card detection
    // and the MicPre), and one of the two reads can fail while the other
    // answers; names from that read named outputs 9-16 of two 8x8s "Line
    // 9-16" while they played slot 1's ADAT. A slot whose type was not read
    // for the tables (no Symphony answering) is not named at all; see
    // SymphonyHostInputName.
    uint8_t latchedType[2][2];
    bool latchedKnown[2][2];
    LatchedChannelOrder(ivars, 0, latchedType[0], latchedKnown[0]);
    LatchedChannelOrder(ivars, 1, latchedType[1], latchedKnown[1]);
    SymphonyNamingState s = {};
    for (uint32_t b = 0; b < 2; b++) {
        s.boardKnown[b] = latchedKnown[0][b];
        s.boardType[b] = latchedType[0][b];
        s.opticalIsSPDIF[b] = __atomic_load_n(&ivars->pendingOpticalFmt[b], __ATOMIC_ACQUIRE) != 0;
        s.coaxReplace[b] = __atomic_load_n(&ivars->namingCoaxReplace[b], __ATOMIC_ACQUIRE);
    }
    s.sampleRate = __atomic_load_n(&ivars->namingSampleRate, __ATOMIC_ACQUIRE);
    s.prefix = __atomic_load_n(&ivars->namingPrefix, __ATOMIC_ACQUIRE);
    SymphonyNamingState sB = {};
    for (uint32_t b = 0; b < 2; b++) {
        // Unit B's latch is None unless unit B is configured, and is built
        // from unitBBoardType (dext 149 named from unitBBoardValid &&
        // unitBConfigured, the same values).
        sB.boardKnown[b] = latchedKnown[1][b];
        sB.boardType[b] = latchedType[1][b];
        sB.opticalIsSPDIF[b] = ivars->unitBOptical[b] != 0;   // unit B's own format
        sB.coaxReplace[b] = ivars->unitBCoaxReplace[b];
    }
    sB.sampleRate = s.sampleRate;
    sB.prefix = SymphonyIsPrefixLetter(ivars->unitBPrefix)
        ? ivars->unitBPrefix
        : (uint8_t)(SymphonyPrefixLetter(s.prefix) == 'Z' ? 'A' : SymphonyPrefixLetter(s.prefix) + 1);

    // Only a channel whose name differs from what Core Audio has is set: each
    // SetElementName notifies every client, and a rate change on a unit with
    // no optical card renames nothing.
    // dext 131: converter channels are named after the unit channel behind the
    // host channel (SymphonyConverters.h), port 2's while 64 channels run.
    const bool convP2 = (__atomic_load_n(&ivars->convFlags, __ATOMIC_ACQUIRE) & kSymphonyConvPort2Converters) != 0;
    ConverterChain conv;
    BuildConverterChain(ivars, conv);
    const uint32_t convBase = ConvPort1(ivars) ? 0 : 32;           // first host channel converters name
    const char convPrefix = ConvPort1(ivars) ? 'A' : 'B';         // a Symphony I/O on port 1 is unit A
    const uint32_t nameCount = (convP2 || ivars->unitBConfigured) ? 64 : 32;
    auto convNames = [&](uint32_t n) { return ConvPort1(ivars) || (convP2 && n >= 32); };
    // VBus (dext 143): VBus channel k is device channel vbusBase + k and is
    // named "VBin k" / "VBout k", as Apogee's daemon named every channel past
    // the physical ones (og_source/symphonymk1/ext/maestrolink/Software/
    // SymphonyController.cpp:3145-3158; it also refused custom names there).
    const uint32_t vbusCount = __atomic_load_n(&ivars->vbusPublished, __ATOMIC_ACQUIRE);
    const uint32_t vbusBase = __atomic_load_n(&ivars->vbusBase, __ATOMIC_ACQUIRE);
    auto vbusName = [&](uint32_t n, bool input, char *name, size_t size) {
        if (!vbusCount || n < vbusBase || n >= vbusBase + vbusCount) return false;
        snprintf(name, size, input ? "VBin %u" : "VBout %u", n - vbusBase + 1);
        return true;
    };
    uint32_t changed = 0;
    for (uint32_t n = 0; n < nameCount; n++) {
        char name[sizeof(ivars->publishedInputName[0])] = {};
        const uint32_t route = __atomic_load_n(&ivars->cardInputRoute[n], __ATOMIC_ACQUIRE);
        const uint32_t rx = route & 0xFFu;
        if (vbusName(n, true, name, sizeof(name))) { }
        else if (convNames(n)) ConverterHostChannelName(conv, true, n - convBase, name, sizeof(name), convPrefix);
        else if ((route & kRoutingEnable) && rx < 64) {
            const uint8_t source = rx < 32
                ? __atomic_load_n(&ivars->inputRouteSource[rx], __ATOMIC_ACQUIRE)
                : __atomic_load_n(&ivars->unitBInputRouteSource[rx - 32], __ATOMIC_ACQUIRE);
            if (!SymphonyHostInputName(rx < 32 ? s : sB, source, name, sizeof(name))) name[0] = 0;
        }
        if (strncmp(name, ivars->publishedInputName[n], sizeof(name)) == 0) continue;
        // A null name removes it, leaving Core Audio's default for that channel.
        OSString *str = name[0] ? OSString::withCString(name) : nullptr;
        ivars->audioDevice->SetElementName(n + 1, IOUserAudioObjectPropertyScope::Input, str);
        OSSafeReleaseNULL(str);
        strlcpy(ivars->publishedInputName[n], name, sizeof(ivars->publishedInputName[n]));
        changed++;
    }
    uint32_t outChanged = 0;
    for (uint32_t n = 0; n < nameCount; n++) {
        char name[sizeof(ivars->publishedOutputName[0])] = {};
        if (vbusName(n, false, name, sizeof(name))) { }
        else if (convNames(n)) ConverterHostChannelName(conv, false, n - convBase, name, sizeof(name), convPrefix);
        else if (n < 32) {
            if (!SymphonyHostOutputName(s, n, name, sizeof(name))) name[0] = 0;
        } else if (!SymphonyHostOutputName(sB, n - 32, name, sizeof(name))) name[0] = 0;
        if (strncmp(name, ivars->publishedOutputName[n], sizeof(name)) == 0) continue;
        OSString *str = name[0] ? OSString::withCString(name) : nullptr;
        ivars->audioDevice->SetElementName(n + 1, IOUserAudioObjectPropertyScope::Output, str);
        OSSafeReleaseNULL(str);
        strlcpy(ivars->publishedOutputName[n], name, sizeof(ivars->publishedOutputName[n]));
        outChanged++;
    }
    // dext 131 review: names 33-64 published for converters or unit B in an
    // earlier 64-channel session are removed when that is no longer the case.
    // dext 143: the same pass names the VBus channels that lie past the named
    // hardware channels and removes VBus names left where there is no VBus
    // channel any more (VBus turned off or made smaller, or moved by a port
    // change). With VBus off this is the loop above it replaces: every entry
    // from 64 up is empty.
    for (uint32_t n = nameCount; n < 128; n++) {
        for (uint32_t dir = 0; dir < 2; dir++) {
            const bool input = dir == 0;
            char (*published)[20] = input ? ivars->publishedInputName : ivars->publishedOutputName;
            char name[sizeof(ivars->publishedInputName[0])] = {};
            vbusName(n, input, name, sizeof(name));
            if (strncmp(name, published[n], sizeof(name)) == 0) continue;
            OSString *str = name[0] ? OSString::withCString(name) : nullptr;
            ivars->audioDevice->SetElementName(n + 1, input ? IOUserAudioObjectPropertyScope::Input
                                                            : IOUserAudioObjectPropertyScope::Output, str);
            OSSafeReleaseNULL(str);
            strlcpy(published[n], name, sizeof(published[n]));
            if (input) changed++; else outChanged++;
        }
    }
    if (changed || outChanged)
        STLOG("Channel names: %u input, %u output names changed (prefix %c, boards %u/%u known %u/%u, %u Hz, spdif %u/%u, coax %u/%u)",
              changed, outChanged, SymphonyPrefixLetter(s.prefix), s.boardType[0], s.boardType[1],
              s.boardKnown[0] ? 1u : 0u, s.boardKnown[1] ? 1u : 0u, s.sampleRate,
              s.opticalIsSPDIF[0] ? 1u : 0u, s.opticalIsSPDIF[1] ? 1u : 0u,
              s.coaxReplace[0], s.coaxReplace[1]);
}

static void ScheduleChannelNames(SymphonyThunderbridge_IVars *ivars, SymphonyThunderbridge *self)
{
    if (!ivars || !ivars->defaultQueue || !self) return;
    self->retain();
    ivars->defaultQueue->DispatchAsync(^{
        PublishChannelNames(ivars);
        self->release();
    });
}

// ── Nominal rate → channel names ────────────────────────────────────────────
// Core Audio changes the nominal rate through HandleChangeSampleRate on the
// device, with or without IO running: coreaudiod restores a device's saved
// rate when it arrives, and Audio MIDI Setup or an app can set one with no
// client streaming. The hardware follows only at the next StartDevice, but the
// names must follow at once, or a 176.4/192 kHz stream start followed by a
// 48 kHz nominal change leaves every optical channel "N.A." (seen after a
// replug with the device saved at 176.4 kHz). SymphonyAudioDevice has no
// pointer to this driver, so Start registers the pair here and Stop removes it.
struct NominalRateObserver {
    IOUserAudioDevice           *device;
    SymphonyThunderbridge       *driver;
    SymphonyThunderbridge_IVars *ivars;
};
static constexpr uint32_t kMaxNominalRateObservers = 4;
static NominalRateObserver sNominalRateObservers[kMaxNominalRateObservers];
static IOLock *sNominalRateLock;

static IOLock *NominalRateLock()
{
    IOLock *lock = __atomic_load_n(&sNominalRateLock, __ATOMIC_ACQUIRE);
    if (lock) return lock;
    IOLock *fresh = IOLockAlloc();
    if (!fresh) return nullptr;
    IOLock *expected = nullptr;
    if (!__atomic_compare_exchange_n(&sNominalRateLock, &expected, fresh, false,
                                     __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
        IOLockFree(fresh);
        return expected;
    }
    return fresh;
}

static void RegisterNominalRateObserver(IOUserAudioDevice *device, SymphonyThunderbridge *driver,
                                        SymphonyThunderbridge_IVars *ivars)
{
    IOLock *lock = NominalRateLock();
    if (!lock || !device || !driver || !ivars) return;
    IOLockLock(lock);
    for (auto &o : sNominalRateObservers) {
        if (!o.device) { o = { device, driver, ivars }; break; }
    }
    IOLockUnlock(lock);
}

static void UnregisterNominalRateObserver(SymphonyThunderbridge *driver)
{
    IOLock *lock = __atomic_load_n(&sNominalRateLock, __ATOMIC_ACQUIRE);
    if (!lock || !driver) return;
    IOLockLock(lock);
    for (auto &o : sNominalRateObservers) {
        if (o.driver == driver) o = { nullptr, nullptr, nullptr };
    }
    IOLockUnlock(lock);
}

// Called by SymphonyAudioDevice::HandleChangeSampleRate once the framework has
// accepted `rate` as the nominal rate. The driver is retained across the call,
// so a concurrent Stop cannot free its ivars underneath it.
void SymphonyNoteNominalSampleRate(IOUserAudioDevice *device, double rate)
{
    IOLock *lock = __atomic_load_n(&sNominalRateLock, __ATOMIC_ACQUIRE);
    if (!lock || !device) return;
    SymphonyThunderbridge *driver = nullptr;
    SymphonyThunderbridge_IVars *ivars = nullptr;
    IOLockLock(lock);
    for (auto &o : sNominalRateObservers) {
        if (o.device == device) {
            driver = o.driver;
            ivars = o.ivars;
            driver->retain();
            break;
        }
    }
    IOLockUnlock(lock);
    if (!driver) return;
    const uint32_t hz = SymphonyNamingRateHz(rate);
    const uint32_t before = __atomic_exchange_n(&ivars->namingSampleRate, hz, __ATOMIC_ACQ_REL);
    if (before != hz) {
        STLOG("Channel names: nominal rate %u -> %u Hz", before, hz);
        ScheduleChannelNames(ivars, driver);
    }
    driver->release();
}

// dext 131: the converters' latency for the device's timing tuple
// (SymphonyAudioDevice::HandleChangeSampleRate). 0/0 when the device is not
// ours or port 1 is not converters, and the Symphony I/O table applies.
void SymphonyConverterLatencyForDevice(IOUserAudioDevice *device, double rate,
                                       uint32_t *inLatency, uint32_t *outLatency)
{
    *inLatency = *outLatency = 0;
    IOLock *lock = __atomic_load_n(&sNominalRateLock, __ATOMIC_ACQUIRE);
    if (!lock || !device) return;
    SymphonyThunderbridge *driver = nullptr;
    SymphonyThunderbridge_IVars *ivars = nullptr;
    IOLockLock(lock);
    for (auto &o : sNominalRateObservers) {
        if (o.device == device) { driver = o.driver; ivars = o.ivars; driver->retain(); break; }
    }
    IOLockUnlock(lock);
    if (!driver) return;
    ConverterLatencyFor(ivars, rate, inLatency, outLatency);
    ivars->convLatencyIn = *inLatency;
    ivars->convLatencyOut = *outLatency;
    driver->release();
}

// The card a slot's S/PDIF Coax Replaces / Mirrors were just written to or
// read from, so link configuration puts them back only on that type of card
// (ReplaysCoaxSettings).
static void NoteCoaxBoardType(SymphonyThunderbridge_IVars *ivars, uint32_t board)
{
    if (board > 1) return;
    const uint8_t type = ivars->optionBoardTypeValid[board] ? ivars->optionBoardType[board]
                                                            : kSIOOptionBoard_None;
    __atomic_store_n(&ivars->sessionCoaxBoardType[board], type, __ATOMIC_RELEASE);
}

// The unit's peripheral prefix letter (0x37), which every channel name starts
// with. Read where the option-board types are read (Start, link recovery):
// the unit keeps the letter across power cycles, as the daemon relied on
// (SymphonyIO.cpp:1245-1258). Unlike the daemon, nothing is written back when
// the unit has no letter yet; names then use "A". Returns true when the stored
// byte changed. XLink init path only (ReadVendorRequest polls with IOSleep).
static bool ReadNamingPrefix(SymphonyThunderbridge_IVars *ivars, uint8_t &txSeq)
{
    uint8_t raw = 0;
    if (!ReadVendorRequest(ivars->pciDevice, ivars->barMemoryIndex, ivars->symphonyAddr,
                           kSymphonyCmdPrefix, 0, &raw, 1, txSeq,
        ivars->isLegacyPCIe2100)) {
        STLOG("SymphonyIO: Prefix (0x37) read failed; names keep '%c'",
              SymphonyPrefixLetter(__atomic_load_n(&ivars->namingPrefix, __ATOMIC_ACQUIRE)));
        return false;
    }
    STLOG("SymphonyIO: Prefix (0x37) = 0x%02x → names use '%c'", raw, SymphonyPrefixLetter(raw));
    return __atomic_exchange_n(&ivars->namingPrefix, raw, __ATOMIC_ACQ_REL) != raw;
}

// The Symphony's capture routing as ConfigureSymphonyLink leaves it
// (SymphonyCaptureSource): analog first from both slots' types (dext 150),
// card by card from slot 1's while a type is unknown, the fixed 16 + 16
// while slot 1's is.
static void ResetInputRouteSources(SymphonyThunderbridge_IVars *ivars,
                                   const uint8_t slotType[2], const bool slotKnown[2])
{
    for (unsigned n = 0; n < 32; n++)
        __atomic_store_n(&ivars->inputRouteSource[n],
                         SymphonyCaptureSource(slotType, slotKnown, n), __ATOMIC_RELEASE);
}

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
// ── dext 130: tell the Symphony 64 PCIe card its place in the card arrangement ──
// Apogee's driver sends every card CMD_CONFIGURE, which writes SM_REG_EXPANSION
// (0x2214) = 1 << boardID: "Set the board id to ensure correct routing of
// expansion signals" (Driver/Symphony64Card.cpp:951-959). configureComponents
// (SymphonyAPI/SymphonyBaseAudioEngine.cpp:1964-1990) sends it at engine init,
// on wake and after firmware load, always before StartDMA; the arm64e build of
// Symphony64.kext in Symphony 5.5 contains the same write. On this FPGA a card's
// DMA start waits for the multi-card synchronisation signal
// (Symphony64AudioEngine.cpp:324-325). This driver never wrote it, and the
// PCIe card's DMA never started (2026-11-18 report: CHA stayed at HBA, no
// HBO/ABU). The ThunderBridge has no expansion bus and is master by design, so
// this runs for the 0x2100 card only: one card, board 0, value 1.
static void ConfigureLegacyPCIeExpansion(SymphonyThunderbridge_IVars *ivars, const char *where)
{
    if (!ivars || !ivars->isLegacyPCIe2100) return;
    if (!ivars->isMaster) {
        // The original disables a card jumpered as a slave (Symphony64Card.cpp:144-152)
        // and needs a master; it would not tell a lone slave it is board 0.
        STERR("PCIe card is jumpered as SLAVE (Board ID bit 0x20 clear): Apogee's driver would not use it as "
              "the only card; expansion register left unwritten (%{public}s)", where);
        return;
    }
    IOPCIDevice *dev = ivars->pciDevice;
    const uint8_t mi = ivars->barMemoryIndex;
    uint32_t before = 0, after = 0, clk = 0;
    ReadRegister(dev, mi, kRegExpansion, &before);
    WriteRegister(dev, mi, kRegExpansion, 1u << 0);
    ReadRegister(dev, mi, kRegExpansion, &after);
    ReadRegister(dev, mi, kRegExpansionClk, &clk);
    ivars->expansionBefore = before;
    ivars->expansionAfter  = after;
    ivars->expansionClk    = clk;
    STLOG("PCIe card: expansion register 0x2214 read 0x%08x, wrote 0x1 (board 0 of 1), reads 0x%08x; "
          "expansion clock 0x94=0x%08x (%{public}s)", before, after, clk, where);
}

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

// Runs ON xlinkQueue (no rate transaction can interleave). Mirrors Start()
// steps 10–29b in order; the XLink re-lock (ConfigureSymphonyLink) follows.
static void ReprogramCardAfterReset(SymphonyThunderbridge_IVars *ivars, uint32_t gcsrSeen)
{
    IOPCIDevice *dev = ivars->pciDevice;
    const uint8_t mi = ivars->barMemoryIndex;
    ivars->cardReinitCount++;
    // dext 127, diagnostics: which of CardLostConfiguration's checks failed.
    const bool swapLost = (gcsrSeen & kGCSR_SwapToLE) != kGCSR_SwapToLE;
    const bool chLost   = (gcsrSeen & kGCSR_DMAMask) != (kGCSR_DMAOutSize32 | kGCSR_DMAInSize32);
    const uint32_t dmaBits = kGCSR_A2HDMAEnable | kGCSR_H2ADMAEnable;
    const bool dmaLost  = ivars->dmaRunning && (gcsrSeen & dmaBits) != dmaBits;
    STLOG("Card re-init #%u: GCSR=0x%08x lost its programmed state (%{public}s%{public}s%{public}s) — re-programming IRQ, DMA, "
          "routing, mixer", ivars->cardReinitCount, gcsrSeen,
          swapLost ? "byte order " : "", chLost ? "channel count " : "", dmaLost ? "DMA enables" : "");
    // Quiet first: no interrupts, no DMA, clear latched status.
    WriteRegister(dev, mi, kRegIntMask, 0);
    WriteRegister(dev, mi, kRegIntStatus, 0xFFFFFFFF);
    WriteRegister(dev, mi, kRegRxStatusErr, 0xFFFFFFFF);
    WriteRegister(dev, mi, kRegGCSR, kGCSR_SwapToLE);
    ConfigureLegacyPCIeExpansion(ivars, "card re-init");
    ModifyRegister(dev, mi, kRegXLinkClocking, XLinkClockEnableBits(ivars), 0);
    // Two-port experiment only: the state Start() left, port 1 enabled and
    // port 2 disabled until "Port 1-2: 64ch" is selected (the re-programming
    // is port 1 alone, so 64 is no longer running; see the caller).
    if (ivars->portCount == 2) {
        ModifyRegister(dev, mi, kRegGCSR2, GCSR2PortDisableBitsToSet(ivars), GCSR2PortDisableBitsToClear(ivars));
        ivars->port2DisablePending = false;
    }
    // Routing tables: the app's card output routes where known, Start()'s
    // defaults elsewhere (every output direct, see step 21b); input routing
    // is always the default.
    for (uint32_t n = 0; n < kMaxChannelsPerPort; n++) {
        const uint32_t def = (kTDM_PCIOut0 + n) | kRoutingEnable;
        WriteRegister(dev, mi, kRegOutputRouting + n * 4,
                      ivars->cardOutputRouteSet[n] ? ivars->cardOutputRoute[n] : def);
        WriteCardInputRoute(ivars, n, (kTDM_XLinkRX0 + n) | kRoutingEnable);
    }
    // dext 131: converters keep the routing layer's placement.
    ApplyConverterRouting(ivars, "card reprogrammed after reset");
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
        } else if (mixerID == 1 &&
                   __atomic_load_n(&ivars->converterVolumeKeys, __ATOMIC_ACQUIRE)) {
            ApplyConverterTrim(ivars);   // unity defaults with the key trim
        } else {
            const uint32_t bank = (mixerID == 1) ? 0 : 2;
            WriteRegister(dev, mi, MixerCoefOffset(bank,     128), kMixerUnityCoeff);
            WriteRegister(dev, mi, MixerCoefOffset(bank + 1, 129), kMixerUnityCoeff);
        }
    }
    ivars->mixersSilencedForSleep = false;   // rewritten above
    STLOG("Card re-init: mixer 1 %{public}s, mixer 2 %{public}s (SW Return sources %u/%u)",
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
        IOSleep(10);
        ModifyRegister(dev, mi, kRegClkCtrl,
                       ClkCtrlUnmuteBits(ivars), 0);
        uint32_t verify = 0;
        ReadRegister(dev, mi, kRegGCSR, &verify);
        STLOG("Card re-init: DMA restarted, unmuted (GCSR=0x%08x)", verify);
    }
}

// The recovery body shared by the link watch and the (now on-demand) probe path.
// Runs ON xlinkQueue. Clears linkRecoveryInFlight when done.
static void RunLinkRecoveryOnQueue(SymphonyThunderbridge_IVars *ivars, SymphonyThunderbridge *self)
{
    // dext 152: the unit may have lost its clock and optical settings.
    ForgetSentClockAndOptical(ivars);
    if (!XLinkTxAdmissible(ivars)) {
        __atomic_store_n(&ivars->linkRecoveryInFlight, false, __ATOMIC_RELEASE);
        return;
    }
    // dext 117: remember whether Core Audio had already restarted IO and was still
    // waiting for its first wrap IRQ (true after an ordinary wake: StartDevice ran,
    // the reset card delivered nothing). Captured BEFORE the re-init, which is what
    // makes the IRQs flow and clears the flag.
    const bool anchorPendingAtEntry = ivars->firstTimestampAfterStart;
    bool cardReprogrammed = false;
    {
        uint32_t gcsr = 0;
        if (CardLostConfiguration(ivars, &gcsr)) {
            ReprogramCardAfterReset(ivars, gcsr);
            cardReprogrammed = true;
            // Two-port experiment, stage 2: the re-programming above is port 1
            // alone (port-2 buffer registers zero, port-2 DMA off). If 64 was
            // running, record that it no longer is and have the streams follow.
            Port2AudioFallBack(ivars, self, kSymphonyPort2ReasonCardReset, false);
        }
    }
    // Re-enumerate at the rate the units last ran at so Core Audio's
    // stream format and the hardware agree without a rate change.
    double rate = ivars->xlinkRate > 0.0
        ? ivars->xlinkRate
        : (ivars->audioDevice ? ivars->audioDevice->GetSampleRate() : 44100.0);
    SymphonyLinkInitResult restored = {};
    bool ok = ConfigureSymphonyLink(ivars, rate, &restored);
    // Two-port experiment: port 2 is not looked at here. It is switched on
    // and identified only when "Port 1-2: 64ch" is selected, as the original
    // (XLink::BusInit skips a bus PortEnabled() says is off, XLink.cpp:510).
    (void)cardReprogrammed;
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
        // The unit came back, maybe another one: forget its cached MicPre
        // state and read the types again (unread DAW edits are kept).
        ResetMicPreUnitCaches(ivars, 0, false);
        RereadMicPreTypesA(ivars);
        ArmMicPreSettle(ivars);
        // A port-1 recovery can leave a running 64-channel card with a new
        // XLink frame phase. Re-run the original shared phase jam across both
        // ports before resuming the engines.
        if (__atomic_load_n(&ivars->portMode, __ATOMIC_ACQUIRE) == 64 && ivars->port2On) {
            const bool wasRunning = Port2StopBothEngines(ivars->pciDevice, ivars->barMemoryIndex);
            // dext 131 review: the port-1 bring-up sent unit A a plain master
            // ClockMode; with unit B following it by Loop Sync, put unit A's
            // Loop Sync output back on and remind unit B it is the slave.
            if (ivars->unitBConfigured && ivars->loopSyncConfig != 0) {
                ApplyLoopSync(ivars, ivars->loopSyncConfig);
            } else if (ivars->unitBConfigured) {
                SendUnitAClock(ivars, true);
                const uint8_t slave[4] = { 0x03, 0x00, 0x01, 0x00 };
                if (!SendVendorRequestOn(ivars->pciDevice, ivars->barMemoryIndex, kRegXLink2TX, 1,
                                         kSIOCmd_ClockMode, 0, slave, sizeof(slave), ivars->runtimeTxSeq2))
                    ivars->unitBTxErrors++;
                IOSleep(10);
            }
            AlignXLinkPhase(ivars);
            if (wasRunning) Port2StartBothEngines(ivars);
            STLOG("Link recovery: re-aligned phase for both ports while 64 channels ran");
        }
        // ConfigureSymphonyLink replayed the unit's stored boot monitor
        // values. The HAL controls and the dext's cached session state
        // still hold what the user set, so push those to the hardware;
        // otherwise the slider and the unit disagree until the next change.
        if (__atomic_load_n(&ivars->converterVolumeKeys, __ATOMIC_ACQUIRE)) {
            // Converters only: the keys are the mixer-1 trim. Bring the HAL
            // controls to it (a unit that was off at Start() left them at the
            // -20 dB fallback) and put it on the card.
            if (ivars->outputVolumeControl)
                ivars->outputVolumeControl->SetDecibelValue(-static_cast<float>(ivars->converterTrimAtten));
            if (ivars->outputMuteControl)
                ivars->outputMuteControl->SetControlValue(ivars->converterTrimMuted);
            ApplyConverterTrim(ivars);
            STLOG("Link recovery: converter volume trim atten=%u mute=%u",
                  ivars->converterTrimAtten, ivars->converterTrimMuted ? 1 : 0);
        } else {
            // Levels are only ever sent or shown when they were read from
            // the unit or set in this driver instance. A Start() that found
            // no Symphony I/O left fallbacks: take what the unit just reported
            // instead (the replay below then sends the unit its own values).
            // Headphone 2 is always taken from the unit: nothing replays it.
            if (restored.levelsRead) {
                if (!ivars->monitorLevelsKnown) {
                    if (restored.speakerLevelRead) {
                        __atomic_store_n(&ivars->speakerAttenuation, restored.speakerAttenuation, __ATOMIC_RELEASE);
                        __atomic_store_n(&ivars->speakerMute, restored.speakerMuteRaw, __ATOMIC_RELEASE);
                    }
                    __atomic_store_n(&ivars->hp1Attenuation, restored.hp1Attenuation, __ATOMIC_RELEASE);
                    __atomic_store_n(&ivars->hp1Mute, restored.hp1MuteRaw, __ATOMIC_RELEASE);
                }
                ivars->hp2Attenuation = restored.hp2Attenuation;
                ivars->hp2Mute = restored.hp2MuteRaw;
                ivars->monitorLevelsKnown = true;
                if (restored.speakerLevelRead) ivars->speakerLevelKnown = true;
            }
            uint8_t spkAtten = __atomic_load_n(&ivars->speakerAttenuation, __ATOMIC_ACQUIRE);
            uint8_t spkMute  = __atomic_load_n(&ivars->speakerMute, __ATOMIC_ACQUIRE) ? 1 : 0;
            uint8_t hpAtten  = __atomic_load_n(&ivars->hp1Attenuation, __ATOMIC_ACQUIRE);
            uint8_t hpMute   = __atomic_load_n(&ivars->hp1Mute, __ATOMIC_ACQUIRE) ? 1 : 0;
            // The speakers only outside Line and when their level is known.
            if (!restored.lineMonitor && ivars->speakerLevelKnown) {
                SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex, ivars->symphonyAddr,
                                  kSIOCmd_SpeakerVolume, 0, &spkAtten, 1, ivars->runtimeTxSeq);
                SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex, ivars->symphonyAddr,
                                  kSIOCmd_SpeakerMute, 0, &spkMute, 1, ivars->runtimeTxSeq);
            }
            SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex, ivars->symphonyAddr,
                              kSIOCmd_HeadphoneVolume, 0, &hpAtten, 1, ivars->runtimeTxSeq);
            SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex, ivars->symphonyAddr,
                              kSIOCmd_HeadphoneMute, 0, &hpMute, 1, ivars->runtimeTxSeq);
            STLOG("Link recovery: replayed session monitor state (speaker atten=%u mute=%u, "
                  "HP1 atten=%u mute=%u)", spkAtten, spkMute, hpAtten, hpMute);
            // The controls show the keys' output at the level just settled
            // (the output itself was kept, or follows the unit's speaker
            // mode while the app has not chosen: ConfigureSymphonyLink).
            if (!ivars->monitorDeviceB) PublishSelectedMonitor(ivars);
        }
        // Start() may have run with no Symphony at all, in which case the
        // option-board types were never read. Refresh them so the app's
        // card detection (kSelectorReadBoardTypes) answers from hardware.
        // dext 131: not on converters (no Symphony I/O to ask).
        for (uint32_t b = 0; b < 2; b++) {
            uint8_t bt = 0;
            bool okb = !ivars->convPort1 && ReadVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                         ivars->symphonyAddr, kSIOCmd_OptionBoardType,
                                         b, &bt, 1, ivars->runtimeTxSeq,
        ivars->isLegacyPCIe2100);
            ivars->optionBoardType[b]     = okb ? bt : 0;
            ivars->optionBoardTypeValid[b] = okb;
        }
        if (!ivars->convPort1) ReadNamingPrefix(ivars, ivars->runtimeTxSeq);
        ScheduleChannelNames(ivars, self);
        if (!LinkRecoveryAborted(ivars)) IndicateLinkOK(ivars);
        STLOG("Link recovery: Symphony re-enumerated and configured at %u Hz "
              "(recovery #%u, monitor=%{public}s atten=%u)",
              (uint32_t)(rate + 0.5), ivars->linkRecoveryCount,
              restored.lineMonitor ? "Line" : "speakers", restored.monitorAttenuation);
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
        const bool ioRunningNow = __atomic_load_n(&ivars->ioRunning, __ATOMIC_ACQUIRE);
        if (ioRunningNow && anchorPendingAtEntry) {
            STLOG("Link recovery: IO already running with its anchor pending — no configuration "
                  "change requested (playback continues)");
        } else {
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

// dext 131: a full re-initialisation of the converter chain (the original's
// ForceReconfigure -> BusInit): word clock change, a unit that stopped
// answering, a rate set that did not lock at bring-up. The link recovery
// path, on xlinkQueue, once at a time.
static void RequestConverterReinit(SymphonyThunderbridge_IVars *ivars, SymphonyThunderbridge *self, const char *why)
{
    if (!ivars || !self || !ivars->xlinkQueue) return;
    if (__atomic_load_n(&ivars->linkRecoveryInFlight, __ATOMIC_ACQUIRE)) return;
    __atomic_store_n(&ivars->linkRecoveryInFlight, true, __ATOMIC_RELEASE);
    __atomic_store_n(&ivars->linkState, kLinkStateRecovering, __ATOMIC_RELEASE);
    STLOG("Converter: re-initialising the chain (%{public}s)", why);
    self->retain();
    ivars->xlinkQueue->DispatchAsync(^{
        RunLinkRecoveryOnQueue(ivars, self);
        self->release();
    });
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
// dext 131: converter health, the part of the original's CheckLinkStatus and
// FrequencyStatus (XLink.cpp:1995-2061, 2427-2512) that the clock and down
// bits above do not cover. On xlinkQueue, from the link watch, about once a
// second while converters are on port 1 (the original: every 300 ms), also
// while audio runs, XLink queries only:
//   - a broadcast INQUIRE answered = a unit added at the end -> re-initialise;
//   - each unit's INQUIRE + XTD_INQUIRE: a change or no answer -> re-initialise;
//   - each unit's WCLK_PHASE twice: more than 2 apart = not locked; either
//     outside 0x01-0x2F = out of the window where the units play (they mute
//     themselves) -> the rate transaction with phase alignment.
// Nothing is jammed or re-initialised under running DMA here: a re-initialise
// goes through the link recovery, a re-alignment through StartDevice's rate
// transaction (convRecoveryPending + a configuration change). At most one
// recovery every 10 s, and none after three in a row that did not help.
static constexpr uint64_t kConverterHealthNs      = 1000000000ull;
static constexpr uint64_t kConverterRecoveryGapNs = 10000000000ull;
static constexpr uint8_t  kXLinkCmdWclkPhaseQuery = 0x09;   // XLINK_CMD_WCLK_PHASE
static constexpr uint8_t  kConverterPhaseMin = 0x01, kConverterPhaseMax = 0x2F;
static constexpr int      kConverterPhaseJitter = 2;        // MAX_WCLK_PHASE_DIFF

static bool ConverterHealthCheck(SymphonyThunderbridge_IVars *ivars, SymphonyThunderbridge *self)
{
    IOPCIDevice *dev = ivars->pciDevice;
    const uint8_t mi = ivars->barMemoryIndex;
    const bool pcie = ivars->isLegacyPCIe2100;
    const bool p1 = ivars->convPort1;
    const bool p2 = (__atomic_load_n(&ivars->convFlags, __ATOMIC_ACQUIRE) & kSymphonyConvPort2Converters) != 0;
    ivars->convHealthTicks++;
    bool reinit = false, realign = false;
    // A rate set at bring-up that did not lock: the original retried until
    // it did, with the outputs muted.
    if (p1 && ivars->convRateUnlocked) {
        STLOG("Converter health: the units never locked to the rate — re-initialising");
        reinit = true;
    }
    uint8_t extra = 0;
    if (p1 && !reinit &&
        XLinkInquire(dev, mi, kXLinkCmdAddrAll, kXLinkCmdInquire, &extra, pcie) && (extra >> 4) != 0) {
        STLOG("Converter health: a unit answers after the last one (INQUIRE 0x%02x) — re-initialising", extra);
        reinit = true;
    }
    // Each unanswered query waits up to 20 ms on xlinkQueue; after two in one
    // tick the rest wait for the next tick, so clock, config and app commands
    // are never held up for long while audio runs.
    uint32_t misses = 0;
    bool port2Changed = false;
    ConvSnapshotData snap;
    ConvSnapshot(ivars, snap);
    for (uint32_t port = 0; port < 2 && !reinit && misses < 2; port++) {
        if ((port == 0 && !p1) || (port == 1 && !p2)) continue;
        const uint64_t tx = port ? kRegXLink2TX : kRegXLink1TX;
        const uint64_t rx = port ? kRegXLink2RX : kRegXLink1RX;
        uint32_t phases = 0;
        for (uint32_t u = 0; u < snap.count[port] && u < kXLinkMaxDevices && misses < 2; u++) {
            const uint8_t addr = (uint8_t)(u + 1);
            const uint32_t w = snap.unit[port][u];
            // Each unit still the same one (CheckLinkStatus compared every unit's
            // routing, XLink.cpp:2018-2061).
            uint8_t inq = 0, xtd = 0;
            const bool inqOK = XLinkInquireOn(dev, mi, tx, rx, addr, kXLinkCmdInquire, &inq, pcie);
            const bool xtdOK = XLinkInquireOn(dev, mi, tx, rx, addr, kXLinkCmdXtdInquire, &xtd, pcie);
            const uint8_t was = ConverterUnitRouting(w);
            const uint8_t now = ConverterRouting(inq, (w & kSymphonyConvUnitXtdOK) && xtdOK ? xtd : 0);
            if (!inqOK || now != was) {
                STLOG("Converter health: port %u unit %u %{public}s (routing 0x%02x, was 0x%02x)",
                      port + 1, addr, inqOK ? "changed" : "does not answer", now, was);
                if (port == 0) { reinit = true; break; }
                // Port 2: a unit replaced, added or gone while 64 runs. Its
                // placement, names and routes describe the old chain, so go
                // back to 32 cleanly (the remembered 64 request switches back
                // once the chain is found again).
                port2Changed = true;
                break;
            }
            uint8_t a = 0, b = 0;
            const bool aOK = XLinkInquireOn(dev, mi, tx, rx, addr, kXLinkCmdWclkPhaseQuery, &a, pcie);
            const bool bOK = aOK && XLinkInquireOn(dev, mi, tx, rx, addr, kXLinkCmdWclkPhaseQuery, &b, pcie);
            if (!bOK) {
                // The original counted an unanswered phase query as a command
                // error and re-initialised (FrequencyStatus -> ForceReconfigure).
                misses++;
                STLOG("Converter health: port %u unit %u does not report its phase", port + 1, addr);
                if (port == 0) { reinit = true; break; }
                realign = true;
                continue;
            }
            phases |= (uint32_t)b << (8 * u);
            const int diff = (int)a - (int)b;
            if (diff > kConverterPhaseJitter || diff < -kConverterPhaseJitter) {
                ivars->convUnlocks++;
                realign = true;
                STLOG("Converter health: port %u unit %u not locked (phase 0x%02x then 0x%02x)", port + 1, addr, a, b);
            } else if (a < kConverterPhaseMin || a > kConverterPhaseMax || b < kConverterPhaseMin || b > kConverterPhaseMax) {
                ivars->convPhaseErrors++;
                realign = true;
                STLOG("Converter health: port %u unit %u phase 0x%02x/0x%02x outside 0x01-0x2F (unit muted)",
                      port + 1, addr, a, b);
            }
        }
        ivars->convPhase[port] = phases;
    }
    if (port2Changed) {
        STLOG("Converter health: port 2's converters changed — back to 32 channels, port 2 is looked at again");
        Port2AudioFallBack(ivars, self, kSymphonyPort2ReasonClockGone, true);
        return false;
    }
    if (!reinit && !realign) {
        __atomic_or_fetch(&ivars->convFlags, kSymphonyConvHealthy, __ATOMIC_RELEASE);
        ivars->convFailedRecoveries = 0;
        return false;
    }
    __atomic_and_fetch(&ivars->convFlags, ~kSymphonyConvHealthy, __ATOMIC_RELEASE);
    const uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    if (ivars->convFailedRecoveries >= 3) return false;   // logged once below; stop trying
    if (ivars->convLastRecoveryNs && now - ivars->convLastRecoveryNs < kConverterRecoveryGapNs) return false;
    ivars->convLastRecoveryNs = now;
    ivars->convRecoveries++;
    if (++ivars->convFailedRecoveries == 3)
        STERR("Converter health: three recoveries in a row did not help — not trying again until it is healthy");
    if (reinit) return true;   // the caller runs the link recovery (BusInit again)
    __atomic_store_n(&ivars->convRecoveryPending, true, __ATOMIC_RELEASE);
    __atomic_or_fetch(&ivars->convFlags, kSymphonyConvRecoveryPending, __ATOMIC_RELEASE);
    if (__atomic_load_n(&ivars->ioRunning, __ATOMIC_ACQUIRE)) {
        RequestIORestartFromDefaultQueue(ivars, self, "converter phase");
    } else {
        // No audio running: re-send the rate and align now (DMA is stopped
        // only in the rate transaction, so that is where it happens; mark it
        // for the next IO start as well).
        STLOG("Converter health: re-alignment waits for the next audio start");
    }
    return false;
}

void IMPL(SymphonyThunderbridge, LinkWatchTimerOccurred)
{
    if (!ivars) return;
    if (__atomic_load_n(&ivars->stopping, __ATOMIC_ACQUIRE) ||
        __atomic_load_n(&ivars->txShutdown, __ATOMIC_ACQUIRE)) return;
    // On xlinkQueue, behind any monitor control work already queued there
    // (a mute Core Audio restored is applied before the outputs open).
    if (ivars->startupOutputMuteHeld && ivars->xlinkQueue)
        ivars->xlinkQueue->DispatchAsync(^{ MaybeReleaseStartupOutputMute(ivars); });
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
        // dext 127, diagnostics: once per IO start, say whether audio wraps
        // arrived. Logging only; the decisions below are unchanged.
        if (ioRunning && __atomic_load_n(&ivars->ioStartReported, __ATOMIC_ACQUIRE) == 0) {
            const uint64_t irqNow = __atomic_load_n(&ivars->interruptCount, __ATOMIC_RELAXED);
            const uint64_t dWraps = wraps - ivars->ioStartWraps;
            const uint64_t dIrq   = irqNow - ivars->ioStartIrq;
            const uint64_t ticks  = ivars->linkWatchTicks - ivars->ioStartWatchTick;
            if (dWraps > 0) {
                STLOG("Audio start: wraps arriving (irq +%llu, wraps +%llu, %llu watch ticks after StartDevice)",
                      dIrq, dWraps, ticks);
                __atomic_store_n(&ivars->ioStartReported, 1u, __ATOMIC_RELEASE);
            } else if (ticks >= 3) {
                STLOG("Audio start: IO running but NO audio wraps — irq +%llu wraps +0 over %llu watch ticks "
                      "(GCSR=0x%08x, cardReinits=%u)", dIrq, ticks, ivars->lastWatchGcsr, ivars->cardReinitCount);
                __atomic_store_n(&ivars->ioStartReported, 1u, __ATOMIC_RELEASE);
            }
        }
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
        if (ivars->portCount == 2) WatchSecondPort(ivars, this, clk);   // two-port experiment only
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
            __atomic_store_n(&ivars->linkState, kLinkStateRecovering, __ATOMIC_RELEASE);
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
            STLOG("Link watch: wake revalidation XLink1Status=0x%08x clocking=0x%08x tunnelWasAbsent=%u → %{public}s",
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
        // A3: a clean wake keeps the card's state, so the mixers silenced for
        // sleep are put back here (a re-lock rewrites them in the card re-init).
        if (ivars->mixersSilencedForSleep && ivars->xlinkQueue)
            ivars->xlinkQueue->DispatchAsync(^{ RestoreCardMixersAfterSleep(ivars); });
        next = wrapsFlowing ? kLinkWatchStreamNs : kLinkWatchIdleNs;
        // dext 131: converters are checked about once a second (never a
        // Symphony I/O). A unit added, changed or gone re-runs the bus init.
        if (ivars->convPort1 ||
            (__atomic_load_n(&ivars->convFlags, __ATOMIC_ACQUIRE) & kSymphonyConvPort2Converters)) {
            next = kConverterHealthNs;
            if (ConverterHealthCheck(ivars, this) &&
                !__atomic_load_n(&ivars->linkRecoveryInFlight, __ATOMIC_ACQUIRE)) {
                __atomic_store_n(&ivars->linkRecoveryInFlight, true, __ATOMIC_RELEASE);
                __atomic_store_n(&ivars->linkState, kLinkStateRecovering, __ATOMIC_RELEASE);
                this->retain();
                SymphonyThunderbridge *self = this;
                ivars->xlinkQueue->DispatchAsync(^{
                    RunLinkRecoveryOnQueue(ivars, self);
                    self->release();
                });
                break;
            }
        }
        // Two-port experiment, 64 channels running: keep the fast interval so a
        // port-2 chain that goes away is noticed within about two seconds.
        if (ivars->portCount == 2 &&
            __atomic_load_n(&ivars->portMode, __ATOMIC_ACQUIRE) == 64)
            next = kLinkWatchFastNs;
    } while (false);
    if (ivars->startupOutputMuteHeld) {
        const uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
        const uint64_t releaseAt = __atomic_load_n(&ivars->startupReleaseAtNs, __ATOMIC_ACQUIRE);
        const uint64_t due = releaseAt ? releaseAt : ivars->startupOutputMuteDeadlineNs;
        if (now < due) {
            const uint64_t untilRelease = due - now;
            if (untilRelease < next) next = untilRelease;
        }
    }
    ArmLinkWatch(ivars, next);
    // NoteStartupRateSettled may have stored a release time and armed the
    // timer for it between the read above and this arm, which would push the
    // release out to `next`. Arming first and reading again afterwards takes
    // the earlier of the two: either this re-read sees the store, or the
    // store's own arm comes after ours.
    if (ivars->startupOutputMuteHeld) {
        const uint64_t releaseAt = __atomic_load_n(&ivars->startupReleaseAtNs, __ATOMIC_ACQUIRE);
        const uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
        if (releaseAt && releaseAt < now + next)
            ArmLinkWatch(ivars, releaseAt > now ? releaseAt - now : 0);
    }
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
    // A watch tick may occur while power is off. Never publish the pre-sleep
    // UP cache as proof that the post-wake link check completed. No bus access.
    if (__atomic_load_n(&ivars->providerPowerOff, __ATOMIC_ACQUIRE) ||
        __atomic_load_n(&ivars->linkNeedsRevalidation, __ATOMIC_ACQUIRE))
        outWords[1] = kLinkStateRecovering;
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
    outWords[15] = ivars->unitProbeWord |
        (__atomic_load_n(&ivars->converterVolumeKeys, __ATOMIC_ACQUIRE)
             ? kUnitProbeConverterVolumeKeys : 0u);          // dext 121: see kUnitProbe*
    return kIOReturnSuccess;
}

// Optional tail of the existing host-only link-state read.
kern_return_t SymphonyThunderbridge::ReadPhantomObservations(uint32_t *outWords)
{
    if (!ivars || !outWords) return kIOReturnBadArgument;
    for (uint32_t i = 0; i < 16; ++i) {
        const uint64_t stamp = __atomic_load_n(&ivars->halPhantomOff[i], __ATOMIC_ACQUIRE);
        outWords[i * 2] = static_cast<uint32_t>(stamp);
        outWords[i * 2 + 1] = static_cast<uint32_t>(stamp >> 32);
    }
    return kIOReturnSuccess;
}

// D5: the optional tail after the phantom words. Reads ivars only, no bus
// access. The app restores its saved card mixer only on an instance that
// reports no app mixer state (a fresh driver); an in-place recovery keeps
// both flags, since ReprogramCardAfterReset recomputes from the cache.
kern_return_t SymphonyThunderbridge::ReadMixerInstance(uint32_t *outWords)
{
    if (!ivars || !outWords) return kIOReturnBadArgument;
    uint32_t flags = 0;
    if (__atomic_load_n(&ivars->mixerStateValid[0], __ATOMIC_ACQUIRE)) flags |= kSymphonyMixerInstanceMixer1Valid;
    if (__atomic_load_n(&ivars->mixerStateValid[1], __ATOMIC_ACQUIRE)) flags |= kSymphonyMixerInstanceMixer2Valid;
    outWords[0] = kSymphonyMixerInstanceMagic;
    outWords[1] = flags;
    outWords[2] = static_cast<uint32_t>(ivars->startNonce);
    outWords[3] = static_cast<uint32_t>(ivars->startNonce >> 32);
    return kIOReturnSuccess;
}

// Third optional tail (words 52-99 of a 100-word read): host-originated MicPre edits, three words per physical
// channel A0..7, B0..7 (see kSymphonyMicPreEditWords). Reads ivars only. The
// stamp is read on both sides of the fields so a record written meanwhile is
// read again rather than torn.
kern_return_t SymphonyThunderbridge::ReadMicPreEdits(uint32_t *outWords)
{
    if (!ivars || !outWords) return kIOReturnBadArgument;
    for (uint32_t i = 0; i < 16; ++i) {
        uint64_t stamp = 0;
        uint32_t fields = 0;
        for (int attempt = 0; attempt < 4; ++attempt) {
            stamp = __atomic_load_n(&ivars->halMicPreEditStamp[i], __ATOMIC_ACQUIRE);
            fields = __atomic_load_n(&ivars->halMicPreEdit[i], __ATOMIC_ACQUIRE);
            if (__atomic_load_n(&ivars->halMicPreEditStamp[i], __ATOMIC_ACQUIRE) == stamp) break;
        }
        outWords[i * 3] = static_cast<uint32_t>(stamp);
        outWords[i * 3 + 1] = static_cast<uint32_t>(stamp >> 32);
        outWords[i * 3 + 2] = fields;
    }
    return kIOReturnSuccess;
}

// ── ReadPort2State (EXPERIMENT, 64ch stage 1) ────────────────────────────────
// What the last port-2 probe found (SymphonyPort2StateOutput). Reads ivars
// only, like ReadLinkState, whose 16 words are left exactly as they were. In a
// one-port build this reports portCount 1 and nothing else.
kern_return_t SymphonyThunderbridge::ReadPort2State(uint32_t *outWords)
{
    if (!ivars || !outWords) return kIOReturnBadArgument;
    for (uint32_t i = 0; i < 16; i++) outWords[i] = 0;
    outWords[1]  = ivars->portCount == 2 ? 2u : 1u;
    outWords[2]  = __atomic_load_n(&ivars->port2Flags, __ATOMIC_ACQUIRE);
    outWords[3]  = ivars->port2XlinkStatus;
    outWords[4]  = ivars->port2Clocking;
    outWords[5]  = ivars->port2Gcsr2;
    outWords[6]  = ivars->port2UnitCount;
    for (uint32_t i = 0; i < kXLinkMaxDevices; i++) outWords[7 + i] = ivars->port2Unit[i];
    outWords[11] = ivars->port2ProbeCount;
    outWords[12] = ivars->port2RateHz;
    outWords[13] = ivars->port2RateChanges;
    if (ivars->portCount == 2) {   // stage 2; both words stay 0 in a one-port build
        uint32_t audio = __atomic_load_n(&ivars->port2AudioFlags, __ATOMIC_ACQUIRE);
        audio |= kSymphonyPort2AudioStage2;
        if (ivars->port2AudioReady) audio |= kSymphonyPort2AudioCapable;
        if (__atomic_load_n(&ivars->portMode, __ATOMIC_ACQUIRE) == 64) audio |= kSymphonyPort2AudioActive;
        if (__atomic_load_n(&ivars->ioChannels, __ATOMIC_ACQUIRE) == 64) audio |= kSymphonyPort2AudioPublished64;
        audio |= (ivars->port2ModeChanges & 0xFFFFu) << kSymphonyPort2AudioChangesShift;
        outWords[14] = audio;
        outWords[15] = ivars->port2PhaseWord;
    }
    return kIOReturnSuccess;
}

// Serialized with all hardware work. No caller can change a single-unit rig,
// a converter chain, or an unconfigured second unit through this selector.
kern_return_t SymphonyThunderbridge::LoopSyncConfig(uint32_t operation, uint32_t config, uint32_t *outWords)
{
    if (!outWords || operation > 1 || config > 3) return kIOReturnBadArgument;
    if (!ivars || !ivars->xlinkQueue) return kIOReturnNotReady;
    __block kern_return_t result = kIOReturnNotReady;
    ivars->xlinkQueue->DispatchSync(^{
        // B7: one Symphony I/O on port 1: the Loop Sync output on unit A only
        // (bit 0 of config = off, as with two units; the master bit is
        // ignored). Applied by re-sending unit A's clock with the new byte.
        if (!ivars->unitBConfigured && !ivars->convPort1 && ivars->symphonyLinkConfigured &&
            XLinkTxAdmissible(ivars)) {
            const bool enabled = !(config & 1);
            if (operation == 1 && enabled != ivars->oneUnitLoopSync) {
                ivars->oneUnitLoopSync = enabled;
                uint8_t bytes[4] = { 0x01, 0x01, 0x00, 0x00 };
                if (ivars->unitAClockKnown) memcpy(bytes, ivars->unitAClock, 4);
                ApplyOneUnitLoopSyncByte(ivars, bytes);
                const bool sent = SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex, ivars->symphonyAddr,
                                                    kSIOCmd_ClockMode, 0, bytes, sizeof(bytes), ivars->runtimeTxSeq);
                NoteUnitAClockSent(ivars, bytes, sent);
                if (!sent) {
                    result = kIOReturnIOError;
                    return;
                }
                STLOG("Loop Sync (one unit): output %{public}s", enabled ? "on" : "off");
            }
            SymphonyLoopSyncOutput out = {};
            out.config = ivars->oneUnitLoopSync ? 0 : 1;
            out.valid = 1;
            out.sourceA = ivars->unitAClockKnown ? ivars->unitAClock[0] | (ivars->unitAClock[3] << 8) : 1;
            out.sourceB = 0;
            uint8_t measured[5] = {};
            const bool ok = ReadVendorRequestOn(ivars->pciDevice, ivars->barMemoryIndex,
                kRegXLink1TX, kRegXLink1RX, ivars->symphonyAddr, kSIOCmd_ClockRateAndLock, 0, measured, 5,
                ivars->runtimeTxSeq, ivars->isLegacyPCIe2100);
            out.lockA = ok && measured[0] <= 1 ? (measured[0] ? 2 : 1) : 0;
            memcpy(outWords, &out, sizeof(out));
            result = kIOReturnSuccess;
            return;
        }
        if (!ivars->unitBConfigured)
            STLOG("Loop Sync: refused with one unit (converters on port 1 %u, link configured %u, admissible %u)",
                  ivars->convPort1 ? 1 : 0, ivars->symphonyLinkConfigured ? 1 : 0, XLinkTxAdmissible(ivars) ? 1 : 0);
        if (!XLinkTxAdmissible(ivars) || !ivars->unitBConfigured || !ivars->port2On ||
            __atomic_load_n(&ivars->portMode, __ATOMIC_ACQUIRE) != 64 || ivars->convPort1 ||
            (__atomic_load_n(&ivars->convFlags, __ATOMIC_ACQUIRE) & kSymphonyConvPort2Converters)) return;
        if (operation == 1 && (config != ivars->loopSyncConfig || !ivars->loopSyncValid)) {
            // Keep the requested topology even on a partial failure; valid=false
            // reports uncertainty, and a repeat applies both writes again.
            ivars->loopSyncConfig = config;
            if (!ApplyLoopSync(ivars, config)) { result = kIOReturnIOError; return; }
        }
        SymphonyLoopSyncOutput out = {};
        out.config = ivars->loopSyncConfig;
        out.valid = ivars->loopSyncValid ? 1 : 0;
        out.sourceA = ivars->unitAClockKnown ? ivars->unitAClock[0] | (ivars->unitAClock[3] << 8) : 1;
        out.sourceB = ivars->unitBMasterClockKnown ? ivars->unitBMasterClock[0] | (ivars->unitBMasterClock[3] << 8) : 1;
        for (unsigned p = 0; p < 2; p++) {
            if (!XLinkTxAdmissible(ivars)) break;
            uint8_t measured[5] = {};
            bool ok = ReadVendorRequestOn(ivars->pciDevice, ivars->barMemoryIndex,
                p ? kRegXLink2TX : kRegXLink1TX, p ? kRegXLink2RX : kRegXLink1RX,
                p ? 1 : ivars->symphonyAddr, kSIOCmd_ClockRateAndLock, 0, measured, 5,
                p ? ivars->runtimeTxSeq2 : ivars->runtimeTxSeq, ivars->isLegacyPCIe2100);
            uint32_t lock = ok && measured[0] <= 1 ? (measured[0] ? 2 : 1) : 0;
            if (p) out.lockB = lock; else out.lockA = lock;
        }
        memcpy(outWords, &out, sizeof(out));
        result = kIOReturnSuccess;
    });
    return result;
}

kern_return_t SymphonyThunderbridge::ReadUnitBState(uint32_t *outWords)
{
    if (!ivars || !outWords) return kIOReturnBadArgument;
    SymphonyUnitBStateOutput o = {};
    o.present = ivars->unitBConfigured ? 1u : 0u;
    for (uint32_t i = 0; i < 2; i++) {
        o.boardType[i] = ivars->unitBBoardType[i];
        o.boardValid[i] = ivars->unitBBoardValid[i] ? 1 : 0;
    }
    o.prefix = ivars->unitBPrefix;
    o.clockSource = ivars->unitBClockSource;
    o.setupFlags = ivars->unitBSetupFlags;
    o.txErrors = ivars->unitBTxErrors;
    o.reserved2[0] = ivars->unitBGeneration;
    memcpy(outWords, &o, sizeof(o));
    return kIOReturnSuccess;
}

// dext 150: kSelectorReadChannelOrder. Driver state only, no bus access: the
// order and board types each unit's routing tables were last programmed with
// (channelOrderLatch), which the channel names are built from. The two words
// and the generation are read until the generation is the same on both sides
// of them, so the reply is one moment's state.
kern_return_t SymphonyThunderbridge::ReadChannelOrder(uint32_t *outWords)
{
    if (!ivars || !outWords) return kIOReturnBadArgument;
    SymphonyChannelOrderOutput o = {};
    uint32_t words[2] = {};
    uint32_t generation = 0;
    for (int attempt = 0; attempt < 8; attempt++) {
        generation = __atomic_load_n(&ivars->channelOrderGeneration, __ATOMIC_ACQUIRE);
        words[0] = __atomic_load_n(&ivars->channelOrderLatch[0], __ATOMIC_ACQUIRE);
        words[1] = __atomic_load_n(&ivars->channelOrderLatch[1], __ATOMIC_ACQUIRE);
        if (__atomic_load_n(&ivars->channelOrderGeneration, __ATOMIC_ACQUIRE) == generation) break;
    }
    o.status = 0;
    o.generation = generation;
    for (uint32_t u = 0; u < 2; u++) {
        uint8_t type[2];
        bool known[2];
        o.unit[u].order = UnpackChannelOrder(words[u], type, known);
        for (uint32_t b = 0; b < 2; b++) {
            o.unit[u].boardType[b] = type[b];
            o.unit[u].boardKnown[b] = known[b] ? 1 : 0;
        }
    }
    memcpy(outWords, &o, sizeof(o));
    return kIOReturnSuccess;
}

// dext 131: kSelectorReadConverters. Driver state only, no bus access.
kern_return_t SymphonyThunderbridge::ReadConverterState(uint32_t *outWords)
{
    if (!ivars || !outWords) return kIOReturnBadArgument;
    SymphonyConverterStateOutput o = {};
    o.version = 1;
    o.flags = __atomic_load_n(&ivars->convFlags, __ATOMIC_ACQUIRE);
    ConvSnapshotData d;
    ConvSnapshot(ivars, d);
    for (uint32_t p = 0; p < 2; p++) {
        o.unitCount[p] = d.count[p];
        for (uint32_t u = 0; u < 4; u++) {
            uint32_t w = d.unit[p][u];
            if (u < o.unitCount[p]) {
                const uint32_t bit = p * 4 + u;
                const uint32_t cfg = __atomic_load_n(&ivars->convConfig, __ATOMIC_ACQUIRE);
                if (ConverterUnitRouting(w) == kConverterRoutingDD && ((cfg >> (kSymphonyConvConfigDDAsDAShift + bit)) & 1u))
                    w |= kSymphonyConvUnitTypeIsDA;
                if (ConverterUnitRouting(w) == kConverterRoutingRosetta && ((cfg >> (kSymphonyConvConfigR200Shift + bit)) & 1u))
                    w |= kSymphonyConvUnitIsR200;
            }
            o.unit[p][u] = w;
        }
        o.phase[p] = ivars->convPhase[p];
    }
    o.healthTicks = ivars->convHealthTicks;
    o.phaseErrors = ivars->convPhaseErrors;
    o.unlocks = ivars->convUnlocks;
    o.recoveries = ivars->convRecoveries;
    o.latencyIn = ivars->convLatencyIn;
    o.latencyOut = ivars->convLatencyOut;
    o.hostInputs = ivars->convHostIn;
    o.hostOutputs = ivars->convHostOut;
    o.config = __atomic_load_n(&ivars->convConfig, __ATOMIC_ACQUIRE);
    memcpy(outWords, &o, sizeof(o));
    return kIOReturnSuccess;
}

// dext 131: kSelectorSetConverterConfig. Records the choice; on the XLink
// queue, a word clock change is sent to the first unit and followed by the
// rate set and phase alignment (SetWCMaster -> reconfigure), and a Device Type
// change re-places and renames the channels. Nothing is sent to a Symphony I/O.
kern_return_t SymphonyThunderbridge::SetConverterConfig(uint32_t config)
{
    if (!ivars || !ivars->xlinkQueue) return kIOReturnNotReady;
    const uint32_t old = __atomic_exchange_n(&ivars->convConfig, config, __ATOMIC_ACQ_REL);
    STLOG("Converter config: 0x%08x (was 0x%08x)", config, old);
    if (old == config) return kIOReturnSuccess;
    // The Core Audio clock selector follows a choice made in Maestro.
    if (ivars->convPort1 && ivars->clockSourceControl && ((old ^ config) & kSymphonyConvConfigClockExternal)) {
        IOUserAudioSelectorValue sel = (config & kSymphonyConvConfigClockExternal) ? 2 : 1;
        ivars->clockSourceControl->SetCurrentSelectedValues(&sel, 1);
    }
    SymphonyThunderbridge *self = this;
    ivars->xlinkQueue->DispatchAsync(^{
        const bool converters = ivars->convPort1 ||
            (__atomic_load_n(&ivars->convFlags, __ATOMIC_ACQUIRE) & kSymphonyConvPort2Converters);
        if (!converters || !XLinkTxAdmissible(ivars)) return;
        if (ivars->convPort1 && ((old ^ config) & kSymphonyConvConfigClockExternal)) {
            // The original: SetClockSource -> ForceReconfigure (bus reset, the
            // whole chain again, then the rate and phase), XLink.cpp:144-162, 354.
            RequestConverterReinit(ivars, self, "word clock changed");
            return;
        }
        ApplyConverterRouting(ivars, "converter config");
        ScheduleChannelNames(ivars, self);
    });
    return kIOReturnSuccess;
}

// ── Port selection (EXPERIMENT, 64ch stage 2; two-port builds only) ──────────

// The 32- or 64-channel stream formats, one per supported rate, and the index
// of `rate` among them.
static uint32_t BuildStreamFormats(uint32_t channels, double rate,
                                   IOUserAudioStreamBasicDescription formats[6])
{
    static const double rates[6] = { 44100.0, 48000.0, 88200.0, 96000.0, 176400.0, 192000.0 };
    uint32_t current = 0;
    for (uint32_t i = 0; i < 6; i++) {
        IOUserAudioStreamBasicDescription f = {};
        f.mSampleRate       = rates[i];
        f.mFormatID         = IOUserAudioFormatID::LinearPCM;
        f.mFormatFlags      = (IOUserAudioFormatFlags)(0x4 | 0x8);   // SInt32 packed LE, as Start()
        f.mBytesPerPacket   = channels * (kAudioBitDepth / 8);
        f.mFramesPerPacket  = 1;
        f.mBytesPerFrame    = channels * (kAudioBitDepth / 8);
        f.mChannelsPerFrame = channels;
        f.mBitsPerChannel   = kAudioBitDepth;
        f.mReserved         = 0;
        formats[i] = f;
        if (rates[i] == rate) current = i;
    }
    return current;
}

// The selector's new value. Called by SymphonyPortSourceControl on that
// control's work queue, after it has set its own value. Touches no hardware and
// no other AudioDriverKit object: it records the request and asks for a
// configuration change, in which both selectors are set to what the card ends
// up doing (the original set the opposite selector too,
// Symphony64AudioEngine.cpp:256-300).
kern_return_t SymphonyThunderbridge::RequestPortMode(uint32_t selectorValue)
{
    if (!ivars || ivars->portCount != 2) return kIOReturnUnsupported;
    if (selectorValue != kSymphonyPortSourcePort1 && selectorValue != kSymphonyPortSourcePorts1And2)
        return kIOReturnBadArgument;
    const uint32_t want = selectorValue == kSymphonyPortSourcePorts1And2 ? 64u : 32u;
    ivars->port2ResumeProbes = 0;   // a new request: look for a returning unit again
    __atomic_store_n(&ivars->requestedPortMode, want, __ATOMIC_RELEASE);
    if (want == 32) ivars->port2ResumeUnitSeen = false;
    // Already there (the same entry picked again, or Core Audio restoring the
    // saved selection at start-up): no configuration change, so no IO restart.
    if (__atomic_load_n(&ivars->portMode, __ATOMIC_ACQUIRE) == want &&
        __atomic_load_n(&ivars->ioChannels, __ATOMIC_ACQUIRE) == want &&
        !__atomic_load_n(&ivars->portSelectorsStale, __ATOMIC_ACQUIRE))
        return kIOReturnSuccess;
    __atomic_store_n(&ivars->portSelectorsStale, true, __ATOMIC_RELEASE);
    STLOG("Port selection: \"%{public}s\" requested", want == 64 ? kSymphonyPortSourceName64 : kSymphonyPortSourceName32);
    RequestPortModeConfigChange(ivars, this, "selector");
    return kIOReturnSuccess;
}

// Called by SymphonyAudioDevice::PerformDeviceConfigurationChange, with IO
// stopped by Core Audio, for every configuration change of a two-port build.
// 1. If the selector asked for a mode the card is not in, switch the card. That
//    runs on xlinkQueue (DispatchSync, the hop StartDevice's rate change makes
//    from this same path); nothing on that queue waits for this thread.
// 2. On this thread, under portPublishLock (Stop()'s teardown takes it before
//    releasing these objects), give the streams the buffer and formats of the
//    mode the card ended up in and set both selectors to it. A refused request
//    therefore shows as the 32-channel entry again, and a fallback the driver made on
//    its own is published here too.
kern_return_t SymphonyThunderbridge::PerformPortModeChange()
{
    if (!ivars || ivars->portCount != 2 || !ivars->portPublishLock) return kIOReturnSuccess;
    uint32_t want = __atomic_load_n(&ivars->requestedPortMode, __ATOMIC_ACQUIRE);
    __block uint32_t card = __atomic_load_n(&ivars->portMode, __ATOMIC_ACQUIRE);
    // A port-mode change is being performed (not, say, a rate change's
    // configuration change with no port request pending).
    bool portModeChange = want != card;
    IODispatchQueue *queue = ivars->xlinkQueue;
    if (queue && want != card) {
        queue->DispatchSync(^{
            card = __atomic_load_n(&ivars->portMode, __ATOMIC_ACQUIRE);
            if (want == card) return;
            if (!XLinkTxAdmissible(ivars)) {
                if (want == 64)
                    Port2AudioNote(ivars, kSymphonyPort2AudioRefused, kSymphonyPort2ReasonUnreachable);
                STERR("Port selection: card not reachable (stopping or powered down) — staying at %u", card);
                return;
            }
            if (want == 64) {
                if (EnablePort2Audio(ivars)) {
                    card = 64;
                    ivars->port2ResumeUnitSeen = true;
                } else {
                    // Keep the user's 64-channel intent. The link watch will
                    // retry when a unit returns instead of silently selecting 32.
                    __atomic_store_n(&ivars->requestedPortMode, 64u, __ATOMIC_RELEASE);
                    ivars->port2ResumeUnitSeen = false;
                }
            } else {
                DisablePort2Audio(ivars, 0, kSymphonyPort2ReasonNone);
                card = 32;
            }
        });
    }
    // The request this call acted on is settled: the card's mode is now the
    // selection. A newer request (the selector changed meanwhile, or the driver
    // fell back) is left for the configuration change it asked for.
    if (card == 64 || want == 32)
        __atomic_compare_exchange_n(&ivars->requestedPortMode, &want, card,
                                    false, __ATOMIC_ACQ_REL, __ATOMIC_RELAXED);
    if (card == 64 && ivars->unitBConfigured) ScheduleChannelNames(ivars, this);

    IOLockLock(ivars->portPublishLock);
    if (!__atomic_load_n(&ivars->stopping, __ATOMIC_ACQUIRE) &&
        ivars->audioDevice && ivars->inputStream && ivars->outputStream) {
        // Publish what the card is doing NOW (a fallback may have happened
        // since the block above).
        card = __atomic_load_n(&ivars->portMode, __ATOMIC_ACQUIRE);
        if (__atomic_load_n(&ivars->ioChannels, __ATOMIC_ACQUIRE) != card) {
            IOUserAudioStreamBasicDescription formats[6];
            const uint32_t current = BuildStreamFormats(card, ivars->audioDevice->GetSampleRate(), formats);
            // The buffer first, so it always fits the format in effect.
            ivars->inputStream->SetIOMemoryDescriptor(card == 64 ? ivars->a2hStream64Buffer : ivars->a2hStreamBuffer);
            ivars->inputStream->SetAvailableStreamFormats(formats, 6);
            ivars->inputStream->SetCurrentStreamFormat(&formats[current]);
            ivars->outputStream->SetIOMemoryDescriptor(card == 64 ? ivars->h2aStream64Buffer : ivars->h2aStreamBuffer);
            ivars->outputStream->SetAvailableStreamFormats(formats, 6);
            ivars->outputStream->SetCurrentStreamFormat(&formats[current]);
            __atomic_store_n(&ivars->ioChannels, card, __ATOMIC_RELEASE);
            __atomic_store_n(&ivars->portSelectorsStale, true, __ATOMIC_RELEASE);
            STLOG("Port selection: streams are now %u channels in and out", card);
        }
        if (__atomic_exchange_n(&ivars->portSelectorsStale, false, __ATOMIC_ACQ_REL)) {
            portModeChange = true;
            IOUserAudioSelectorValue value = card == 64 ? kSymphonyPortSourcePorts1And2 : kSymphonyPortSourcePort1;
            for (uint32_t i = 0; i < 2; i++)
                if (ivars->portSourceControl[i]) ivars->portSourceControl[i]->SetCurrentSelectedValues(&value, 1);
        }
    }
    IOLockUnlock(ivars->portPublishLock);
    // The request armed the settle window, but the work above (the port-2
    // probe, ConfigureUnitB) can take seconds, and coreaudiod re-reads the
    // controls only once this configuration change ends: start the window
    // again from here so its restore burst still falls inside it.
    if (portModeChange) ArmMicPreSettle(ivars);
    return kIOReturnSuccess;
}

// ══════════════════════════════════════════════════════════════════════════
// VBus (dext 143)
//
// Apogee's "virtual buses": N output channels and N input channels after the
// hardware channels, where what applications play to the outputs is what they
// record from the inputs (user guide, "Working with VBus").
//
// The original (og_source/symphonymk1/ext/Symphony64/SymphonyAPI/
// SymphonyBaseAudioEngine.cpp):
//   initVBUSBuffers (:921-960): one more output stream and one more input
//     stream, after the cards' streams, on ONE sample buffer
//     (m_pVBUSInputBuffer = m_pVBUSOutputBuffer, :942), off by default (:956).
//   VBUS_STREAM_FORMAT (SymphonyDrivers.h:103-123): 32-bit float, which
//     clipOutputSamples / convertInputSamples copy unchanged
//     (Driver/AudioClip.cpp:303-316, :393-406): no clipping, no conversion.
//   The streams are named "VBus channels" (SymphonyCommon.h:83).
//   setNumVBUSChannels (:1391-1440): the engine is paused, both streams are
//     made available or unavailable and given the N-channel format inside
//     beginConfigurationChange / completeConfigurationChange.
//   No latency or safety offset of their own: the engine's offsets and
//     latency (setLatenciesForSampleRate, :1318-1337) apply to every stream,
//     the VBus streams included, and no stream has a latency of its own
//     (SymphonyBaseCard::setLatenciesForStream, SymphonyBaseCard.cpp:441-447,
//     is never called). Sample T of the output is sample T of the input,
//     because both streams are one buffer.
//   The output buffer was cleared by IOAudioFamily's erase head, which the
//     original held back 1200 frames "for correct VBUS operation" (:1849) so
//     an input read came before the erase.
//
// Here:
//   A second stream pair as well, added to the device (and removed from it)
//   in the Core Audio configuration change the port selection uses: IO is
//   stopped, and the streams are published under portPublishLock
//   (PerformVBusChange, called after PerformPortModeChange). Apple's
//   IOUserAudioClockDevice.iig lists "changing stream layout" among the
//   changes that go through RequestDeviceConfigurationChange, and
//   IOUserAudioDevice.iig documents AddStream/RemoveStream and
//   IOUserAudioStream::SetStartingChannel ("the first element in the owning
//   device that corresponds to element one of this stream"). The hardware
//   streams, their buffers and the DMA copy are not touched, and nothing here
//   reads or writes a register.
//   AudioDriverKit has no erase head, and nothing clears a stream buffer the
//   host stops writing. So the two streams have a buffer each, and the IO
//   handler copies output to input at the SAME ring position (sample T out is
//   sample T in, as in the original) for the sample times the host really
//   wrote, and gives silence for every other one (VBusIO).
//   The format is the original's: Float32, copied bit for bit. Only the size
//   chosen in Maestro is offered (the original also listed every size as a
//   stream format in Audio MIDI Setup, performFormatChange :1239-1260).
//   The device's timing is not changed: like the original's, the VBus streams
//   have no latency of their own and run under the device's safety offsets
//   and latency, exactly as the hardware streams do.
// ══════════════════════════════════════════════════════════════════════════

static constexpr uint64_t kSymphonyConfigChangeVBus = 0x56425553ULL;   // 'VBUS'
static constexpr uint32_t kVBusBytesPerSample = 4;                      // Float32 (VBUS_BIT_WIDTH 32)

// The hardware channels in front of the VBus channels: 32, or 64 while both
// ports run.
static uint32_t VBusHardwareChannels(const SymphonyThunderbridge_IVars *ivars)
{
    return (ivars->portCount == 2 && __atomic_load_n(&ivars->ioChannels, __ATOMIC_ACQUIRE) == 64)
        ? 2 * kMaxChannelsPerPort : kMaxChannelsPerPort;
}

// `count` (<= kNumSampleFrames) frames of a ring starting at sample time `t`.
static inline void VBusRingZero(uint8_t *ring, size_t frameBytes, uint64_t t, uint32_t count)
{
    const uint32_t frame = (uint32_t)(t % kNumSampleFrames);
    const uint32_t first = (frame + count <= kNumSampleFrames) ? count : kNumSampleFrames - frame;
    memset(ring + (size_t)frame * frameBytes, 0, (size_t)first * frameBytes);
    if (count > first) memset(ring, 0, (size_t)(count - first) * frameBytes);
}

static inline void VBusRingCopy(uint8_t *dst, const uint8_t *src, size_t frameBytes, uint64_t t, uint32_t count)
{
    const uint32_t frame = (uint32_t)(t % kNumSampleFrames);
    const uint32_t first = (frame + count <= kNumSampleFrames) ? count : kNumSampleFrames - frame;
    memcpy(dst + (size_t)frame * frameBytes, src + (size_t)frame * frameBytes, (size_t)first * frameBytes);
    if (count > first) memcpy(dst, src, (size_t)(count - first) * frameBytes);
}

// The loopback, called by both IO handlers for WriteEnd and BeginRead with
// the generation they loaded (null: VBus is off, nothing to do).
// Real-time: integer arithmetic and a bounded number of memcpy/memset over
// memory mapped before IO started. No lock, no allocation, no logging, no
// register.
//
// WriteEnd(t, frames): the host has just written [t, t + frames) of the VBus
// output. That span is added to [validStart, validEnd). Frames the host
// skipped between the end of the span and t are cleared (they still hold the
// previous lap), and the span never covers more than one ring.
// The host is not trusted to write every cycle (a cycle with no client
// playing to VBus may leave the buffer as it was): after each WriteEnd the
// output ring just past the span is zeroed for the next cycle's worth of
// frames, so a cycle the host does not write holds silence, not the audio of
// a ring ago. That region is taken out of the span (it costs the oldest
// frames of a full ring, which nothing reads any more).
// BeginRead(t, frames): the host is about to read [t, t + frames) of the VBus
// input. The part inside the span is copied from the output buffer at the
// same ring position; the rest is silence. A position is therefore never
// read unless it was marked for that very sample time: nothing plays ->
// silence, and a client that stops playing is not heard again a ring later.
// Every offset is taken modulo the ring and `frames` is clamped to it, so a
// wrong sample time can cost audio but never memory.
static inline void VBusIO(SymphonyVBusIO *v, bool write, uint32_t frames, uint64_t t)
{
    if (!v) return;
    const size_t frameBytes = (size_t)v->channels * kVBusBytesPerSample;
    if (frames > kNumSampleFrames) frames = kNumSampleFrames;
    uint64_t start = v->validStart, end = v->validEnd;
    if (write) {
        if (end != start && t >= start && t <= end) {
            // Follows the span, or rewrites part of it.
        } else if (end != start && t > end && t - end < kNumSampleFrames) {
            VBusRingZero(v->out, frameBytes, end, (uint32_t)(t - end));
        } else {
            start = t;   // the first write, a restart, or a jump of a ring or more
        }
        end = t + frames;
        // Silence for the next cycle, never over what was just written.
        uint32_t ahead = frames;
        if (ahead > kNumSampleFrames - frames) ahead = kNumSampleFrames - frames;
        if (ahead) VBusRingZero(v->out, frameBytes, end, ahead);
        if (end + ahead - start > kNumSampleFrames) start = end + ahead - kNumSampleFrames;
        v->validStart = start;
        v->validEnd = end;
        return;
    }
    const uint64_t readEnd = t + frames;
    const uint64_t from = t > start ? t : start;
    const uint64_t to = readEnd < end ? readEnd : end;
    if (from >= to) {
        VBusRingZero(v->in, frameBytes, t, frames);
        return;
    }
    if (from > t) VBusRingZero(v->in, frameBytes, t, (uint32_t)(from - t));
    VBusRingCopy(v->in, v->out, frameBytes, from, (uint32_t)(to - from));
    if (readEnd > to) VBusRingZero(v->in, frameBytes, to, (uint32_t)(readEnd - to));
}

static inline SymphonyVBusIO *VBusCurrent(SymphonyThunderbridge_IVars *ivars)
{
    return __atomic_load_n(&ivars->vbusIO, __ATOMIC_ACQUIRE);
}

// An empty span: every sample time reads as silence until the host writes it
// again. Two integer stores and no buffer access (StopDevice).
static void VBusResetSpan(SymphonyThunderbridge_IVars *ivars)
{
    if (SymphonyVBusIO *v = VBusCurrent(ivars)) {
        v->validStart = 0;
        v->validEnd = 0;
    }
}

// Silence in both rings and an empty span, with IO stopped: StartDevice
// (nothing of an earlier IO session is in the buffers when the host's first
// cycle comes, whether or not the host writes it) and a move after a Ports
// change. Takes no lock: the generation it loaded stays mapped until the
// change after the next one, or Stop() (see vbusRetired).
static void VBusSilence(SymphonyThunderbridge_IVars *ivars)
{
    SymphonyVBusIO *v = VBusCurrent(ivars);
    if (!v) return;
    const size_t bytes = (size_t)kNumSampleFrames * v->channels * kVBusBytesPerSample;
    memset(v->out, 0, bytes);
    memset(v->in, 0, bytes);
    v->validStart = 0;
    v->validEnd = 0;
}

static void VBusFreeGeneration(SymphonyVBusIO *g)
{
    if (!g) return;
    OSSafeReleaseNULL(g->outMap);
    OSSafeReleaseNULL(g->inMap);
    OSSafeReleaseNULL(g->outBuffer);
    OSSafeReleaseNULL(g->inBuffer);
    IODelete(g, SymphonyVBusIO, 1);
}

// The generation in use stops being used and is kept, mapped, as the one
// retired generation; the generation retired by the change before this one
// is freed now, a whole configuration change (IO stopped, started and
// stopped again) after the IO handler last could have loaded it. Under
// portPublishLock.
static void VBusRetireLocked(SymphonyThunderbridge_IVars *ivars)
{
    SymphonyVBusIO *old = __atomic_exchange_n(&ivars->vbusIO, (SymphonyVBusIO *)nullptr, __ATOMIC_ACQ_REL);
    if (!old) return;   // nothing in use: what is retired stays until the next real change
    VBusFreeGeneration(ivars->vbusRetired);
    ivars->vbusRetired = old;
}

// Every generation, in Stop() where the hardware streams' own buffers are
// released (step 11b), long after the device went.
static void VBusFreeAll(SymphonyThunderbridge_IVars *ivars)
{
    VBusFreeGeneration(__atomic_exchange_n(&ivars->vbusIO, (SymphonyVBusIO *)nullptr, __ATOMIC_ACQ_REL));
    VBusFreeGeneration(ivars->vbusRetired);
    ivars->vbusRetired = nullptr;
}

// Take the VBus streams off the device. In a configuration change this is
// under portPublishLock (the change's own thread); Stop() calls it BEFORE it
// takes the lock, with the hardware streams' RemoveStream, so that it never
// waits, holding the lock, for a queue a configuration change is blocked on.
static void VBusRemoveStreams(SymphonyThunderbridge_IVars *ivars)
{
    if (!ivars->audioDevice) return;
    if (ivars->vbusOutStream) ivars->audioDevice->RemoveStream(ivars->vbusOutStream);
    if (ivars->vbusInStream)  ivars->audioDevice->RemoveStream(ivars->vbusInStream);
}

// Drop the driver's references to the VBus streams. Under portPublishLock;
// makes no call into the device. The memory is not touched.
static void VBusReleaseStreamsLocked(SymphonyThunderbridge_IVars *ivars)
{
    OSSafeReleaseNULL(ivars->vbusOutStream);
    OSSafeReleaseNULL(ivars->vbusInStream);
    __atomic_store_n(&ivars->vbusPublished, 0u, __ATOMIC_RELEASE);
}

// A configuration change takes VBus off the device: the streams go, and the
// generation is retired (not freed). Under portPublishLock with IO stopped.
static void VBusUnpublishLocked(SymphonyThunderbridge_IVars *ivars)
{
    VBusRetireLocked(ivars);
    VBusRemoveStreams(ivars);
    VBusReleaseStreamsLocked(ivars);
}

// The N-channel Float32 formats, one per supported rate, and the index of
// `rate` among them (VBUS_STREAM_FORMAT, SymphonyDrivers.h:103-123).
static uint32_t BuildVBusFormats(uint32_t channels, double rate,
                                 IOUserAudioStreamBasicDescription formats[6])
{
    static const double rates[6] = { 44100.0, 48000.0, 88200.0, 96000.0, 176400.0, 192000.0 };
    uint32_t current = 0;
    for (uint32_t i = 0; i < 6; i++) {
        IOUserAudioStreamBasicDescription f = {};
        f.mSampleRate       = rates[i];
        f.mFormatID         = IOUserAudioFormatID::LinearPCM;
        // FormatFlagsNativeFloatPacked (AudioDriverKitTypes.h): IsFloat | IsPacked.
        f.mFormatFlags      = (IOUserAudioFormatFlags)(0x1 | 0x8);
        f.mBytesPerPacket   = channels * kVBusBytesPerSample;
        f.mFramesPerPacket  = 1;
        f.mBytesPerFrame    = channels * kVBusBytesPerSample;
        f.mChannelsPerFrame = channels;
        f.mBitsPerChannel   = kVBusBytesPerSample * 8;
        f.mReserved         = 0;
        formats[i] = f;
        if (rates[i] == rate) current = i;
    }
    return current;
}

// Create the VBus stream pair for `channels` and add it to the device after
// `base` hardware channels. Under portPublishLock with IO stopped, after
// VBusUnpublishLocked; nothing is published when it fails.
static kern_return_t VBusPublishLocked(SymphonyThunderbridge_IVars *ivars, SymphonyThunderbridge *self,
                                       uint32_t channels, uint32_t base)
{
    SymphonyVBusIO *g = IONewZero(SymphonyVBusIO, 1);
    if (!g) return kIOReturnNoMemory;
    g->channels = channels;
    // Exactly one ring of the format, like the hardware streams' buffers.
    const uint64_t bytes = (uint64_t)kNumSampleFrames * channels * kVBusBytesPerSample;
    kern_return_t ret = IOBufferMemoryDescriptor::Create(kIOMemoryDirectionInOut, bytes, 0, &g->outBuffer);
    if (ret == kIOReturnSuccess && g->outBuffer)
        ret = IOBufferMemoryDescriptor::Create(kIOMemoryDirectionInOut, bytes, 0, &g->inBuffer);
    if (ret == kIOReturnSuccess && (!g->outBuffer || !g->inBuffer)) ret = kIOReturnNoMemory;
    if (ret == kIOReturnSuccess) {
        g->outBuffer->SetLength(bytes);
        g->inBuffer->SetLength(bytes);
        ret = g->outBuffer->CreateMapping(0, 0, 0, 0, 0, &g->outMap);
    }
    if (ret == kIOReturnSuccess)
        ret = g->inBuffer->CreateMapping(0, 0, 0, 0, 0, &g->inMap);
    if (ret == kIOReturnSuccess && (!g->outMap || !g->inMap)) ret = kIOReturnNoMemory;
    if (ret == kIOReturnSuccess) {
        g->out = (uint8_t *)g->outMap->GetAddress();
        g->in = (uint8_t *)g->inMap->GetAddress();
        // New memory is never read before it is silence.
        memset(g->out, 0, (size_t)bytes);
        memset(g->in, 0, (size_t)bytes);
        auto out = IOUserAudioStream::Create(self, IOUserAudioStreamDirection::Output, g->outBuffer);
        auto in = IOUserAudioStream::Create(self, IOUserAudioStreamDirection::Input, g->inBuffer);
        if (out && in) {
            ivars->vbusOutStream = out.get();
            ivars->vbusOutStream->retain();
            ivars->vbusInStream = in.get();
            ivars->vbusInStream->retain();
        } else {
            ret = kIOReturnNoMemory;
        }
    }
    if (ret == kIOReturnSuccess) {
        IOUserAudioStreamBasicDescription formats[6];
        const uint32_t current = BuildVBusFormats(channels, ivars->audioDevice->GetSampleRate(), formats);
        OSString *name = OSString::withCString("VBus channels");   // SYMPHONY_STREAM_NAME2
        IOUserAudioStream *pair[2] = { ivars->vbusOutStream, ivars->vbusInStream };
        for (IOUserAudioStream *stream : pair) {
            stream->SetAvailableStreamFormats(formats, 6);
            stream->SetCurrentStreamFormat(&formats[current]);
            stream->SetTerminalType(IOUserAudioStreamTerminalType::Line);
            stream->SetStartingChannel(base + 1);
            if (name) stream->SetName(name);
        }
        OSSafeReleaseNULL(name);
        ret = ivars->audioDevice->AddStream(ivars->vbusOutStream);
        if (ret == kIOReturnSuccess) ret = ivars->audioDevice->AddStream(ivars->vbusInStream);
    }
    if (ret != kIOReturnSuccess) {
        // The IO handler never saw this generation: it is freed at once.
        VBusRemoveStreams(ivars);
        VBusReleaseStreamsLocked(ivars);
        VBusFreeGeneration(g);
        return ret;
    }
    __atomic_store_n(&ivars->vbusBase, base, __ATOMIC_RELEASE);
    __atomic_store_n(&ivars->vbusPublished, channels, __ATOMIC_RELEASE);
    // Last: from here the IO handler uses the generation.
    __atomic_store_n(&ivars->vbusIO, g, __ATOMIC_RELEASE);
    return kIOReturnSuccess;
}

// Selector 16, "set". From the user client's queue. Records the size and asks
// Core Audio for the configuration change in which PerformVBusChange applies
// it; touches no AudioDriverKit stream and no hardware. The size is the
// driver's until it stops: a new driver instance starts with VBus off (the
// original's daemon sent its saved size again, SymphonyController.cpp:2881),
// and Maestro sends the saved choice again.
kern_return_t SymphonyThunderbridge::SetVBusChannels(uint32_t channels)
{
    if (!ivars) return kIOReturnNotReady;
    if (!SymphonyVBusChannelsValid(channels)) return kIOReturnBadArgument;
    if (__atomic_load_n(&ivars->stopping, __ATOMIC_ACQUIRE) || !ivars->audioDevice ||
        !ivars->portPublishLock || !ivars->defaultQueue) return kIOReturnNotReady;
    __atomic_store_n(&ivars->vbusRequested, channels, __ATOMIC_RELEASE);
    __atomic_and_fetch(&ivars->vbusFlags, ~kSymphonyVBusFlagPublishFailed, __ATOMIC_RELEASE);
    // Already there: no configuration change, so no IO restart.
    if (__atomic_load_n(&ivars->vbusPublished, __ATOMIC_ACQUIRE) == channels) return kIOReturnSuccess;
    STLOG("VBus: %u channels requested", channels);
    ArmMicPreSettle(ivars);   // coreaudiod re-reads the device and its controls
    SymphonyThunderbridge *self = this;
    SymphonyThunderbridge_IVars *iv = ivars;
    self->retain();
    ivars->defaultQueue->DispatchAsync(^{
        if (!__atomic_load_n(&iv->stopping, __ATOMIC_ACQUIRE) && iv->audioDevice) {
            kern_return_t rc = iv->audioDevice->RequestDeviceConfigurationChange(
                kSymphonyConfigChangeVBus, nullptr);
            STLOG("VBus: requested Core Audio configuration change (0x%x)", rc);
        }
        self->release();
    });
    return kIOReturnSuccess;
}

// Selector 16's output (SymphonyVBusStateOutput). Driver state only.
kern_return_t SymphonyThunderbridge::ReadVBusState(uint32_t *outWords)
{
    if (!ivars || !outWords) return kIOReturnBadArgument;
    const uint32_t published = __atomic_load_n(&ivars->vbusPublished, __ATOMIC_ACQUIRE);
    outWords[0] = published;
    outWords[1] = __atomic_load_n(&ivars->vbusRequested, __ATOMIC_ACQUIRE);
    outWords[2] = published ? __atomic_load_n(&ivars->vbusBase, __ATOMIC_ACQUIRE) + 1 : 0;
    outWords[3] = __atomic_load_n(&ivars->vbusFlags, __ATOMIC_ACQUIRE);
    return kIOReturnSuccess;
}

// Called by SymphonyAudioDevice::PerformDeviceConfigurationChange for every
// configuration change, after PerformPortModeChange, with IO stopped by Core
// Audio. Under portPublishLock (Stop()'s teardown takes it before releasing
// these objects):
//   the requested size differs from the published one: the old stream pair
//     is removed and released, and a new pair on new, silent buffers is added
//     after the hardware channels. Nothing of the old size can be read again.
//     The old buffers stay mapped until the change after this one (or Stop()),
//     so the change does not rely on the last IO callback having returned.
//   the size is the same but the hardware channels changed (Ports 32 <-> 64):
//     the VBus channels move to follow them, 33- or 65-; the buffers are
//     cleared.
// A configuration change for anything else (rate, link recovery, card
// re-init, sleep/wake) finds nothing to do and leaves VBus as it is.
kern_return_t SymphonyThunderbridge::PerformVBusChange()
{
    if (!ivars || !ivars->portPublishLock) return kIOReturnSuccess;
    kern_return_t result = kIOReturnSuccess;
    bool changed = false;
    IOLockLock(ivars->portPublishLock);
    if (!__atomic_load_n(&ivars->stopping, __ATOMIC_ACQUIRE) &&
        ivars->audioDevice && ivars->inputStream && ivars->outputStream) {
        const uint32_t want = __atomic_load_n(&ivars->vbusRequested, __ATOMIC_ACQUIRE);
        const uint32_t have = __atomic_load_n(&ivars->vbusPublished, __ATOMIC_ACQUIRE);
        const uint32_t base = VBusHardwareChannels(ivars);
        if (want != have) {
            VBusUnpublishLocked(ivars);
            if (want) {
                result = VBusPublishLocked(ivars, this, want, base);
                if (result != kIOReturnSuccess) {
                    // Not asked for again by itself: the device is left as it
                    // is without VBus, and the app is told.
                    uint32_t expected = want;
                    __atomic_compare_exchange_n(&ivars->vbusRequested, &expected, 0u, false,
                                                __ATOMIC_ACQ_REL, __ATOMIC_RELAXED);
                    __atomic_or_fetch(&ivars->vbusFlags, kSymphonyVBusFlagPublishFailed, __ATOMIC_RELEASE);
                    STERR("VBus: %u channels could not be published (0x%x) — VBus is off", want, result);
                }
            }
            if (result == kIOReturnSuccess)
                STLOG("VBus: %u channels in and out, after %u hardware channels", want, base);
            changed = true;
        } else if (have && __atomic_load_n(&ivars->vbusBase, __ATOMIC_ACQUIRE) != base) {
            ivars->vbusOutStream->SetStartingChannel(base + 1);
            ivars->vbusInStream->SetStartingChannel(base + 1);
            __atomic_store_n(&ivars->vbusBase, base, __ATOMIC_RELEASE);
            VBusSilence(ivars);
            STLOG("VBus: %u channels moved after %u hardware channels", have, base);
            changed = true;
        }
    }
    IOLockUnlock(ivars->portPublishLock);
    if (changed) {
        ScheduleChannelNames(ivars, this);
        ArmMicPreSettle(ivars);   // coreaudiod re-reads the controls when the change ends
    }
    return result;
}

// The IO handler of a two-port build (the one-port handler in Start() is left
// as it is). With 32 channels it does the one-port copy. With 64 the stream
// buffers hold 64-channel frames: channels 1-32 of each frame belong to port
// 1's DMA buffer and channels 33-64 to port 2's, at the same frame position.
// Real-time: no logging, no allocation, one atomic load.
static kern_return_t InstallTwoPortIOHandler(SymphonyThunderbridge_IVars *ivars)
{
    uint8_t *a2h1 = (uint8_t *)ivars->a2hDMAMap->GetAddress();
    uint8_t *h2a1 = (uint8_t *)ivars->h2aDMAMap->GetAddress();
    uint8_t *a2h2 = ivars->port2AudioReady ? (uint8_t *)ivars->a2h2DMAMap->GetAddress() : nullptr;
    uint8_t *h2a2 = ivars->port2AudioReady ? (uint8_t *)ivars->h2a2DMAMap->GetAddress() : nullptr;
    // The 32-channel stream buffers (the ones a one-port build has) and the
    // 64-channel ones the streams are switched to while 64 is selected.
    uint8_t *inStream32  = (uint8_t *)ivars->a2hStreamMap->GetAddress();
    uint8_t *outStream32 = (uint8_t *)ivars->h2aStreamMap->GetAddress();
    uint8_t *inStream64  = ivars->port2AudioReady ? (uint8_t *)ivars->a2hStream64Map->GetAddress() : nullptr;
    uint8_t *outStream64 = ivars->port2AudioReady ? (uint8_t *)ivars->h2aStream64Map->GetAddress() : nullptr;
    constexpr uint32_t kPortBytes = kMaxChannelsPerPort * (kAudioBitDepth / 8);   // 128 per frame per port

    return ivars->audioDevice->SetIOOperationHandler(
        ^kern_return_t(IOUserAudioObjectID in_device,
                       IOUserAudioIOOperation in_io_operation,
                       uint32_t in_io_buffer_frame_size,
                       uint64_t in_sample_time,
                       uint64_t in_host_time) {
            const bool write = in_io_operation == IOUserAudioIOOperationWriteEnd;
            if (!write && in_io_operation != IOUserAudioIOOperationBeginRead)
                return kIOReturnSuccess;
            VBusIO(VBusCurrent(ivars), write, in_io_buffer_frame_size, in_sample_time);   // one atomic load when off
            const bool both = a2h2 && h2a2 &&
                              __atomic_load_n(&ivars->ioChannels, __ATOMIC_RELAXED) == 64;
            const uint32_t streamFrameBytes = both ? 2 * kPortBytes : kPortBytes;
            uint8_t *inStream  = both ? inStream64 : inStream32;
            uint8_t *outStream = both ? outStream64 : outStream32;
            uint32_t frame = (uint32_t)(in_sample_time % kNumSampleFrames);
            uint32_t frames = in_io_buffer_frame_size;
            if (frames > kNumSampleFrames) frames = kNumSampleFrames;
            while (frames) {
                // One run up to the end of the ring, then the rest from frame 0.
                const uint32_t run = (frame + frames <= kNumSampleFrames) ? frames
                                                                         : kNumSampleFrames - frame;
                if (!both) {
                    const size_t off = (size_t)frame * kPortBytes;
                    if (write) memcpy(h2a1 + off, outStream + off, (size_t)run * kPortBytes);
                    else       memcpy(inStream + off, a2h1 + off, (size_t)run * kPortBytes);
                } else {
                    for (uint32_t n = 0; n < run; n++) {
                        const size_t dma = (size_t)(frame + n) * kPortBytes;
                        uint8_t *s = (write ? outStream : inStream) + (size_t)(frame + n) * streamFrameBytes;
                        if (write) {
                            memcpy(h2a1 + dma, s, kPortBytes);
                            memcpy(h2a2 + dma, s + kPortBytes, kPortBytes);
                        } else {
                            memcpy(s, a2h1 + dma, kPortBytes);
                            memcpy(s + kPortBytes, a2h2 + dma, kPortBytes);
                        }
                    }
                }
                frames -= run;
                frame = 0;
            }
            return kIOReturnSuccess;
        });
}

// ── RetireForUpgrade (kSelectorRetireForUpgrade) ─────────────────────────────
// After an update, sysextd registers the new copy and reports the activation
// complete, but kernelmanagerd will not terminate the old copy while it holds
// the PCI device ("is being replaced and cannot be terminated right away"); the
// device stays on the old binary until a replug, a restart, or the extension is
// turned off and on in System Settings. Maestro, having seen that state, asks
// the serving copy to step aside: this calls Terminate(0) on the service, so
// Stop() runs exactly as for any other teardown (mute, zero the buffers, IRQs
// masked, DMA off, XLink queue drained, DMA unmapped, PCI closed) and the
// device is left for the copy macOS has registered.
//
// UNDOCUMENTED: IOService::Terminate is documented in DriverKit only for a
// service made with Create() ("An IOService object created with Create() may be
// removed by calling Terminate()"). Its behaviour for a service matched from a
// personality onto a provider, and whether IOKit then matches the replacement
// copy onto the PCI nub without a replug, is not documented. It needs the
// hardware test (exp64 9005 → 9006, then release 123 → 124). The app gives the
// device about 10 s to come back on the new build and falls back to the
// reconnect / turn off and on / restart guidance if it does not.
//
// Called on the user client's queue, never on xlinkQueue (Stop() drains that
// queue synchronously). Refused unless the replacement build is nonzero and not
// this binary's own, and this binary's build is stamped. Idempotent: a second
// request while the first is pending, or once Stop() has begun, does nothing.
kern_return_t SymphonyThunderbridge::RetireForUpgrade(uint32_t replacementBuild)
{
    if (!ivars) return kIOReturnNotReady;
    const uint32_t ownBuild = (uint32_t)SYMPHONY_DEXT_BUILD;
    switch (SymphonyDecideRetire(ownBuild, replacementBuild,
                                 __atomic_load_n(&ivars->stopping, __ATOMIC_ACQUIRE),
                                 __atomic_load_n(&ivars->retireRequested, __ATOMIC_ACQUIRE))) {
    case kSymphonyRetireUnstamped:
        STLOG("Retire: refused — this build is not stamped");
        return kIOReturnUnsupported;
    case kSymphonyRetireBadReplacement:
        STLOG("Retire: refused — replacement build %u, this is %u", replacementBuild, ownBuild);
        return kIOReturnBadArgument;
    case kSymphonyRetireAlreadyGoing:
        return kIOReturnSuccess;
    case kSymphonyRetireTerminate:
        break;
    }
    // Two requests racing past the decision: only one calls Terminate.
    bool expected = false;
    if (!__atomic_compare_exchange_n(&ivars->retireRequested, &expected, true, false,
                                     __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {
        return kIOReturnSuccess;
    }
    STLOG("Retire: build %u stepping aside for build %u — Terminate(0)", ownBuild, replacementBuild);
    kern_return_t r = Terminate(0);
    if (r != kIOReturnSuccess) {
        STERR("Retire: Terminate failed 0x%x — still serving", r);
        __atomic_store_n(&ivars->retireRequested, false, __ATOMIC_RELEASE);
    }
    return r;
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
    ivars->convLock = IOLockAlloc();
    ivars->startNonce = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) | 1u;
    STLOG("init()");
    return true;
}

void SymphonyThunderbridge::free()
{
    STLOG("free()");
    if (ivars) {
        if (ivars->convLock) { IOLockFree(ivars->convLock); ivars->convLock = nullptr; }
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
        if (ivars->portPublishLock) {   // two-port experiment only
            IOLockFree(ivars->portPublishLock);
            ivars->portPublishLock = nullptr;
        }
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
    uint8_t initialHP2Attenuation = 20;
    bool initialHP2Mute = false;
    bool initialLevelsRead = false;
    bool initialSpeakerLevelRead = false;

    STLOG("Start() — Apogee ThunderBridge DriverKit driver");

    ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) {
        STERR("super::Start failed: 0x%x", ret);
        return ret;
    }

    // EXPERIMENT (64ch, stage 1). Read once; 1 unless the personality says 2.
    // Touches no hardware. See the "second XLink port" section above.
    ivars->portCount = ReadPortCountProperty(this);
    if (ivars->portCount == 2)
        STLOG("EXPERIMENT: SymphonyPortCount=2 — XLink port 2 will be enabled and identified. "
              "The device starts with 32 channels (port 1); port 2 carries audio once "
              "\"" kSymphonyPortSourceName64 "\" is selected.");

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
    STLOG("PCI identity: vendor=0x%04x device=0x%04x (%{public}s)", pciVendor, pciDevice,
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
    STLOG("  Board role:        %{public}s", ivars->isMaster ? "MASTER" : "SLAVE");

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
    STLOG("  Flash status:      0x%08x (%{public}s image)", flashStatus,
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
    ConfigureLegacyPCIeExpansion(ivars, "Start");

    // ── 11. Enable XLink port 1 ─────────────────────────────────────────
    // Legacy: setCardEnabled() at Symphony64Card.cpp:2258 enables XLink clocking.
    // This allows the ThunderBridge to detect Symphony IO on PC-32.

    ModifyRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegXLinkClocking,
                   XLinkClockEnableBits(ivars), 0);
    STLOG("XLink port 1 enabled (XLINK_CLOCKING_ENABLE_1)");
    if (ivars->portCount == 2)
        STLOG("EXPERIMENT: XLINK_CLOCKING_ENABLE_2 set as well, as the original's setCardEnabled "
              "(port 2 itself stays disabled in GCSR2 until \"" kSymphonyPortSourceName64 "\" is selected)");

    SymphonyLinkInitResult linkInit = {};
    ivars->symphonyLinkConfigured = ConfigureSymphonyLink(ivars, 44100.0, &linkInit);
    if (ivars->symphonyLinkConfigured) {
        initialLineMonitor        = linkInit.lineMonitor;
        initialMonitorAttenuation = linkInit.monitorAttenuation;
        initialMonitorMute        = linkInit.monitorMute;
        initialSpeakerAttenuation = linkInit.speakerAttenuation;
        initialSpeakerLevelRead   = linkInit.speakerLevelRead;
        initialSpeakerMute        = linkInit.speakerMute;
        initialHP1Attenuation     = linkInit.hp1Attenuation;
        initialHP1Mute            = linkInit.hp1Mute;
        initialHP2Attenuation     = linkInit.hp2Attenuation;
        initialHP2Mute            = linkInit.hp2Mute;
        initialLevelsRead         = linkInit.levelsRead;
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

    // dext 142: every output is direct, the main pair included, and no card
    // mixer feeds an output until the app routes one. That is the original's
    // default (SymphonyPCIeRoutingController::ResetToDefaults / ResetRouting,
    // og_source/maestrolink/Software/SymphonyPCIeRoutingController.cpp:453-458
    // and :918-938: the mixer destinations are cleared and software output n
    // is routed to hardware output n). Builds up to 141 put ch0/1 on card
    // mixer 1 here, a leftover of the removed Input Monitoring mode.
    for (uint32_t n = 0; n < kMaxChannelsPerPort; n++) {
        WriteRegister(ivars->pciDevice, ivars->barMemoryIndex,
                      kRegOutputRouting + n * 4,
                      (kTDM_PCIOut0 + n) | kRoutingEnable);
    }
    STLOG("Output routing: ch0-%u ← PCI_OUT (enabled); no mixer feeds an output",
          kMaxChannelsPerPort - 1);

    // ── 21c. Input routing: map XLink RX inputs → A2H DMA channels ────────
    // Legacy: Sym64Routing::init() — 1:1 mapping of XLink RX to PCI input.
    // Needed for capture (recording from Symphony IO ADCs).

    for (uint32_t n = 0; n < kMaxChannelsPerPort; n++) {
        WriteCardInputRoute(ivars, n, (kTDM_XLinkRX0 + n) | kRoutingEnable);
    }
    STLOG("Input routing: %u channels mapped (XLink RX → PCI_IN, enabled)",
          kMaxChannelsPerPort);
    // dext 131: converters found while the link was configured above get the
    // routing layer's placement instead (nothing is written for a Symphony I/O).
    ApplyConverterRouting(ivars, "Start");

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
    // (PCI_OUT0/1) into Mixer0(L)/Mixer1(R) returns at unity: the original card
    // mixer's own start (Software Return 1-2 at 0 dB, unmuted, Master at 0 dB:
    // og_source/maestrolink/Software/SymphonyPCIeCardMixer.cpp:30-50 and
    // ResetToDefaults at :1758-1798). No output plays a mixer until the app
    // routes one (step 21b), so none of this is heard before then. The fixed
    // inputs stay at zero coefficients, as the original card driver's
    // Mixer::init left them (step 21d): the original's strips came up unmuted
    // at 0 dB only once its daemon had written the mixer, and here Maestro
    // writes a mixer in full before it routes it. Unmuting them in the driver
    // would put live inputs on an output the moment a mixer is routed by
    // anything that has not written it.
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
        STLOG("Card mixer: host PCI_OUT0/1 → mixer returns @ unity (0x%08x); no mixer is routed to an output",
              kMixerUnityCoeff);
    }

    // ── 21e. Ensure GCSR2 port 1 is enabled ───────────────────────────────
    // Legacy: setCardEnabled() clears DisablePort1. Bit may be stale.

    ModifyRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegGCSR2,
                   GCSR2PortDisableBitsToSet(ivars), GCSR2PortDisableBitsToClear(ivars));
    STLOG("GCSR2: Port 1 enabled (DisablePort1 cleared)");
    if (ivars->portCount == 2)
        STLOG("EXPERIMENT: GCSR2: Port 2 disabled (DisablePort2 set) until \"" kSymphonyPortSourceName64 "\" is selected");

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

    // ── 21g. EXPERIMENT (64ch): port 2 is NOT looked at here ─────────────
    // The original started at "Port 1: 32ch" (Symphony64AudioEngine.cpp:66,
    // :87) with one port enabled (Symphony64Card.cpp:73, :208 → XLink::
    // SetNumPorts(1)), and its BusInit skipped a disabled bus
    // (XLink.cpp:510, :2827). Port 2 was enabled and enumerated only when a
    // 64-channel source was chosen (UpdateEnabledSymphonyPorts →
    // EnableSymphonyCards → setCardEnabled(true, 2)). EnablePort2Audio does
    // the same here.

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

    // dext 143: every build has the lock now, for VBus (PerformVBusChange).
    // It was a two-port build's only; PerformPortModeChange still does
    // nothing unless portCount is 2.
    if (!ivars->portPublishLock) ivars->portPublishLock = IOLockAlloc();

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

    // ── 24p. EXPERIMENT (64ch, stage 2): the second DMA buffer pair ────────
    // Two-port builds only (og Symphony64Card::SetupMemoryForSecondPort). The
    // pair is allocated and mapped here, like port 1's, but the card is not told
    // about it: step 24 still writes zero to the port-2 buffer registers, and
    // they are programmed only while "Port 1-2: 64ch" is selected. A failure is
    // not fatal: the device then offers 64 and refuses it.
    if (ivars->portCount == 2) {
        kern_return_t p2 = AllocateDMABuffer(this, ivars->pciDevice, kDMABufferSize,
                                             kIOMemoryDirectionInOut,
                                             &ivars->a2h2Buffer, &ivars->a2h2DMA, &ivars->a2h2PhysAddr);
        if (p2 == kIOReturnSuccess)
            p2 = AllocateDMABuffer(this, ivars->pciDevice, kDMABufferSize,
                                   kIOMemoryDirectionInOut,
                                   &ivars->h2a2Buffer, &ivars->h2a2DMA, &ivars->h2a2PhysAddr);
        if (p2 == kIOReturnSuccess) {
            ivars->a2h2DMA->PerformOperation(
                kIODMACommandPerformOperationOptionZero, 0, kDMABufferSize, 0, nullptr);
            ivars->h2a2DMA->PerformOperation(
                kIODMACommandPerformOperationOptionZero, 0, kDMABufferSize, 0, nullptr);
            p2 = ivars->a2h2Buffer->CreateMapping(
                kIOMemoryMapCacheModeInhibit, 0, 0, 0, 0, &ivars->a2h2DMAMap);
        }
        if (p2 == kIOReturnSuccess)
            p2 = ivars->h2a2Buffer->CreateMapping(
                kIOMemoryMapCacheModeInhibit, 0, 0, 0, 0, &ivars->h2a2DMAMap);
        // The 64-channel stream buffers (not DMA; Core Audio maps them).
        if (p2 == kIOReturnSuccess)
            p2 = IOBufferMemoryDescriptor::Create(
                kIOMemoryDirectionInOut, 2 * kDMABufferSize, 0, &ivars->a2hStream64Buffer);
        if (p2 == kIOReturnSuccess)
            p2 = IOBufferMemoryDescriptor::Create(
                kIOMemoryDirectionInOut, 2 * kDMABufferSize, 0, &ivars->h2aStream64Buffer);
        if (p2 == kIOReturnSuccess && ivars->a2hStream64Buffer && ivars->h2aStream64Buffer) {
            ivars->a2hStream64Buffer->SetLength(2 * kDMABufferSize);
            ivars->h2aStream64Buffer->SetLength(2 * kDMABufferSize);
            p2 = ivars->a2hStream64Buffer->CreateMapping(0, 0, 0, 0, 0, &ivars->a2hStream64Map);
            if (p2 == kIOReturnSuccess)
                p2 = ivars->h2aStream64Buffer->CreateMapping(0, 0, 0, 0, 0, &ivars->h2aStream64Map);
        }
        if (!ivars->portPublishLock) ivars->portPublishLock = IOLockAlloc();
        ivars->port2AudioReady = (p2 == kIOReturnSuccess) && ivars->a2h2DMAMap && ivars->h2a2DMAMap
            && ivars->a2hStream64Map && ivars->h2aStream64Map && ivars->portPublishLock;
        if (ivars->port2AudioReady)
            STLOG("EXPERIMENT: port-2 DMA buffers ready (A2H2 io=0x%llx, H2A2 io=0x%llx), not yet programmed",
                  ivars->a2h2PhysAddr, ivars->h2a2PhysAddr);
        else
            STERR("EXPERIMENT: port-2 DMA buffers unavailable (0x%x) — 64 channels will be refused", p2);
        __atomic_store_n(&ivars->portMode, 32u, __ATOMIC_RELEASE);
        __atomic_store_n(&ivars->ioChannels, 32u, __ATOMIC_RELEASE);
        __atomic_store_n(&ivars->requestedPortMode, 32u, __ATOMIC_RELEASE);
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
        STLOG("DMA: Channel count set to 32 in/out (GCSR=0x%08x, bits[5:0]=0x%02x%{public}s)",
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
    STLOG("DMA: Frame size set to %u samples (%{public}s profile)", initialFrameSize,
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

        // dext 128: use the first PCI-messaged (MSI) interrupt index, as
        // Apogee's driver does: findMSIInterruptTypeIndex
        // (SymphonyAPI/SymphonyBaseAudioEngine.cpp:645-680), shared by its
        // PCIe and ThunderBridge drivers and present in the arm64e build of
        // its PCIe driver in Symphony 5.5. Query up to 10 indexes, stop at the
        // first the provider does not have, fall back to 0. Apple Silicon
        // delivers only messaged interrupts; on the ThunderBridge index 0 is
        // messaged (measured 2026-11-17), so it gets the same index as before.
        // Assumed, until a PCIe report says otherwise: the Symphony 64 PCIe
        // card's messaged interrupt is not at index 0, so a source on 0 never
        // fires there (detected, rate changes work, no audio).
        static constexpr uint64_t kTypePCIMessaged = 0x00010000;  // kIOInterruptTypePCIMessaged
        for (uint32_t i = 0; i < 4; i++) {
            uint64_t type = 0;
            ivars->irqTypeAtStart[i] =
                (IOInterruptDispatchSource::GetInterruptType(ivars->pciDevice, i, &type) == kIOReturnSuccess)
                    ? type : ~0ull;
        }
        uint32_t irqIndex = 0;
        bool irqIndexIsMSI = false;
        for (uint32_t i = 0; i < 10; i++) {
            uint64_t type = 0;
            if (IOInterruptDispatchSource::GetInterruptType(ivars->pciDevice, i, &type) != kIOReturnSuccess)
                break;
            if (type & kTypePCIMessaged) { irqIndex = i; irqIndexIsMSI = true; break; }
        }
        ivars->irqIndexUsed = irqIndex;
        STLOG("DMA: interrupt types idx0=0x%llx idx1=0x%llx idx2=0x%llx idx3=0x%llx "
              "(0x10000 = PCI messaged, 0xffffffffffffffff = none) — using index %u (%{public}s)",
              ivars->irqTypeAtStart[0], ivars->irqTypeAtStart[1],
              ivars->irqTypeAtStart[2], ivars->irqTypeAtStart[3], irqIndex,
              irqIndexIsMSI ? "first PCI-messaged" : "no PCI-messaged index found, falling back to 0");

        ret = IOInterruptDispatchSource::Create(
            ivars->pciDevice, irqIndex, ivars->interruptQueue,
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

        STLOG("DMA: Interrupt handler installed (index %u)", ivars->irqIndexUsed);
    }

    // ── 28. Enable FPGA interrupt mask ──────────────────────────────────
    // Legacy: EnableInterruptsInHardware(true) — only enables A2H wrap (port 1)
    // Clear all status first, then set mask.

    WriteRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegIntStatus, 0xFFFFFFFF);
    WriteRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegIntMask, 0);
    WriteRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegIntMask, kInt_A2HWrap);
    STLOG("DMA: Interrupt mask set to A2H wrap (0x%08x)", kInt_A2HWrap);

    // dext 130, Symphony 64 PCIe card only: a known pattern in the meter buffer,
    // so the check after DMA start can tell "the card writes to host memory but
    // audio is held off" from "nothing reaches host memory". Cleared again below
    // if the card never overwrites it, so the meters never show it.
    if (ivars->isLegacyPCIe2100 && ivars->meterWords && ivars->meterDMAActive) {
        for (uint32_t i = 0; i < kSymphonyMeterWordCount; i++) ivars->meterWords[i] = 0xFFFFFFFFu;
    }

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
        STLOG("DMA: Started (A2H + H2A%{public}s). GCSR=0x%08x",
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
            ivars->dmaVerifiedRunning = false;
        } else {
            STLOG("DMA: CHA advancing — DMA is RUNNING!");
            ivars->dmaVerifiedRunning = true;
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
    if (SYMPHONY_STARTUP_OUTPUT_HOLD_NS() > 0) {
        ModifyRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegClkCtrl,
                       kClkCtrl_Unmute | kClkCtrl_InputUnmute,
                       kClkCtrl_OutputUnmute);
        __atomic_store_n(&ivars->startupReleaseAtNs, (uint64_t)0, __ATOMIC_RELEASE);
        __atomic_store_n(&ivars->startupRatePending, true, __ATOMIC_RELEASE);
        ivars->startupOutputMuteHeld = true;
        ivars->startupOutputMuteDeadlineNs =
            clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) + SYMPHONY_STARTUP_OUTPUT_HOLD_NS();
        STLOG("ClkCtrl: global + input unmuted AFTER DMA start; output held until Core Audio's rate settles");
    } else {
        ModifyRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegClkCtrl,
                       kClkCtrl_Unmute | kClkCtrl_InputUnmute | kClkCtrl_OutputUnmute, 0);
        STLOG("ClkCtrl: unmuted AFTER DMA start (global + input + output = 0x70000000)");
    }

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

    // dext 130, Symphony 64 PCIe card only: look again a second after DMA start, after the unmute (the original starts
    // DMA with the global unmute already on: XLink.cpp:747-792), and record
    // what decides the next step. Reads only (plus clearing the meter pattern).
    if (ivars->isLegacyPCIe2100) {
        IOSleep(900);
        IOPCIDevice *dev = ivars->pciDevice;
        const uint8_t mi = ivars->barMemoryIndex;
        uint32_t a2hCHA = 0, h2aCHA = 0, intStatus = 0, gcsr = 0, gcsr2 = 0, clk = 0;
        ReadRegister(dev, mi, kRegA2HCHA, &a2hCHA);
        ReadRegister(dev, mi, kRegH2ACHA, &h2aCHA);
        ReadRegister(dev, mi, kRegIntStatus, &intStatus);
        ReadRegister(dev, mi, kRegGCSR, &gcsr);
        ReadRegister(dev, mi, kRegGCSR2, &gcsr2);
        ReadRegister(dev, mi, kRegClkCtrl, &clk);
        uint32_t written = 0;
        if (ivars->meterWords && ivars->meterDMAActive) {
            for (uint32_t i = 0; i < kSymphonyMeterWordCount; i++)
                if (ivars->meterWords[i] != 0xFFFFFFFFu) written++;
            if (written == 0)
                for (uint32_t i = 0; i < kSymphonyMeterWordCount; i++) ivars->meterWords[i] = 0;
        }
        uint16_t pciCmd = 0, pciStatus = 0;
        dev->ConfigurationRead16(0x04, &pciCmd);
        dev->ConfigurationRead16(0x06, &pciStatus);
        // PCI Express capability (ID 0x10): Device Control/Status and Link Status.
        uint16_t devCtl = 0, devSta = 0, lnkSta = 0, ptrWord = 0;
        bool havePCIe = false;
        dev->ConfigurationRead16(0x34, &ptrWord);
        uint16_t cap = ptrWord & 0xFC;
        for (int hops = 0; cap >= 0x40 && hops < 48; hops++) {
            uint16_t hdr = 0;
            dev->ConfigurationRead16(cap, &hdr);
            if ((hdr & 0xFF) == 0x10) {
                dev->ConfigurationRead16(cap + 0x08, &devCtl);
                dev->ConfigurationRead16(cap + 0x0A, &devSta);
                dev->ConfigurationRead16(cap + 0x12, &lnkSta);
                havePCIe = true;
                break;
            }
            cap = (hdr >> 8) & 0xFC;
        }
        const uint32_t a2hOff = a2hCHA - (uint32_t)ivars->a2hPhysAddr;
        ivars->dmaCheckA2HOffset1s = a2hOff;
        ivars->dmaCheckIntStatus1s = intStatus;
        ivars->dmaCheckMeterWritten = written;
        ivars->pciStatusAtStart = pciStatus;
        if (a2hOff != 0 || h2aCHA != (uint32_t)ivars->h2aPhysAddr) ivars->dmaVerifiedRunning = true;
        STLOG("PCIe card, 1 s after DMA start: A2H offset=%u H2A offset=%u (%{public}s); IntStatus=0x%08x "
              "(wrap=%u overflow=%u underflow=%u meterTimer=%u); meter words written by the card=%u of %u",
              a2hOff, h2aCHA - (uint32_t)ivars->h2aPhysAddr,
              ivars->dmaVerifiedRunning ? "DMA running" : "DMA NOT running",
              intStatus, (intStatus & kInt_A2HWrap) ? 1 : 0, (intStatus & kInt_HostBufOverflow) ? 1 : 0,
              (intStatus & kInt_AudioBufUnderflow) ? 1 : 0, (intStatus & kInt_MeterTrigger) ? 1 : 0,
              written, (uint32_t)kSymphonyMeterWordCount);
        STLOG("PCIe card, 1 s after DMA start: GCSR=0x%08x GCSR2=0x%08x ClkCtrl=0x%08x; PCI command=0x%04x "
              "status=0x%04x (masterAbort=%u targetAbort=%u); PCIe %{public}s devCtl=0x%04x devSta=0x%04x lnkSta=0x%04x",
              gcsr, gcsr2, clk, pciCmd, pciStatus, (pciStatus & 0x2000) ? 1 : 0, (pciStatus & 0x1000) ? 1 : 0,
              havePCIe ? "capability" : "capability not found", devCtl, devSta, lnkSta);
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
        // Nominal-rate changes rename the optical channels (SymphonyNoteNominalSampleRate).
        RegisterNominalRateObserver(ivars->audioDevice, this, ivars);

        STLOG("Audio: Device created (UID=%{private}s, ZTS period=%u)", uidStr, kNumSampleFrames);  // from the card serial: stays private
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
        __atomic_store_n(&ivars->namingSampleRate, SymphonyNamingRateHz(44100.0), __ATOMIC_RELEASE);

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
        uint32_t convIn = 0, convOut = 0;
        ConverterLatencyFor(ivars, 44100.0, &convIn, &convOut);
        ivars->convLatencyIn = convIn;
        ivars->convLatencyOut = convOut;
        const kern_return_t timingResult =
            ApplyAudioTimingProfile(ivars->audioDevice, 44100.0, convIn, convOut);
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

        STLOG("Audio: Device configured (44.1-192kHz, Thunderbolt, 32ch, %{public}s profile)",
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
                    STLOG("Audio: Output volume control added (-64..0 dB, init=%.1f, speakers%{public}s)",
                          initialMonitorDb, initialLineMonitor ? " in Line mode: the control does nothing" : "");
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
            // The keys' output was set with the link (ConfigureSymphonyLink):
            // Headphone 1 for a unit in Line mode, else the speakers, until
            // the app chooses (selector 15). With no unit yet: the speakers.
            if (ivars->monitorOutputTarget == kSymphonyMonitorOutputNone)
                ivars->monitorOutputTarget = kSymphonyMonitorOutputSpeakers;
            ivars->unitBMonitorOutputTarget = kSymphonyMonitorOutputSpeakers;
            ivars->monitorLevelsKnown = initialLevelsRead;
            ivars->speakerLevelKnown = initialSpeakerLevelRead;
            ivars->lineMode = initialLineMonitor;
            ivars->speakerAttenuation = initialSpeakerAttenuation;
            ivars->speakerMute = initialSpeakerMute;
            ivars->hp1Attenuation = initialHP1Attenuation;
            ivars->hp1Mute = initialHP1Mute;
            ivars->hp2Attenuation = initialHP2Attenuation;
            ivars->hp2Mute = initialHP2Mute;
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
                for (int c = 0; c < 64; c++) {
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
                // dext 131: converters offer Internal and External (word clock)
                // only, as the original listed them from unit 0/0/0
                // (SymphonyPeripheralDevice.cpp:781-820); 2 = External.
                const bool convClock = ivars->convPort1;
                clockCtrl->AddControlValueDescriptions(clockValues, convClock ? 2 : 5);
                IOUserAudioSelectorValue initSel = (convClock &&
                    (__atomic_load_n(&ivars->convConfig, __ATOMIC_ACQUIRE) & kSymphonyConvConfigClockExternal)) ? 2 : 1;
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
        // board (fail-safe, same discipline as numMicChannels). An AES board gets
        // no control: it has no optical format (SymphonyOptionBoard.h). The boot
        // path (step 19b-0c) sends 0x34 to every slot except a positively-read AES
        // board, because that's harmless on an empty slot, but a CONTROL must
        // reflect real hardware. Runs on the XLink
        // init path, so ReadVendorRequest's bounded IOSleep polling is safe here.
        // The peripheral prefix the channel names start with (0x37).
        // dext 131: none of these Symphony I/O reads go to converters (the
        // original sent its vendor messages to Symphony I/O units only).
        if (!ivars->convPort1) ReadNamingPrefix(ivars, ivars->runtimeTxSeq);
        ivars->numOpticalBoards = 0;
        for (uint32_t b = 0; b < 2; b++) {
            uint8_t bt = kSIOOptionBoard_None;
            bool ok = !ivars->convPort1 && ReadVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                        ivars->symphonyAddr, kSIOCmd_OptionBoardType,
                                        /*nValue=board*/ b, &bt, /*wLength*/1,
                                        ivars->runtimeTxSeq,
        ivars->isLegacyPCIe2100);
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
            STLOG("Audio: Optical format controls added (%u board%{public}s)",
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
        // The MicPre8 board can only be fitted in the secondary slot (wire
        // board index 1; see CardLayout.swift slot2). Reuse the option-board
        // result already captured above instead of sending another 0xA1 read.
        // An unread/failed slot, converter port, or other board type is fail-safe.
        {
            const uint8_t boardType = ivars->optionBoardType[1];
            const bool boardTypeValid = ivars->optionBoardTypeValid[1];
            ivars->numMicChannels = MicPreChannelsForSlots(
                ivars->optionBoardTypeValid[0], ivars->optionBoardType[0],
                boardTypeValid, boardType, ivars->convPort1);
            STLOG("SymphonyIO: OptionBoardType(secondary slot, board 1) = %u (%{public}s) → numMicChannels=%u",
                  boardType,
                  boardTypeValid && boardType == kSIOOptionBoard_MicPre8 ? "MicPre8" : "other/none",
                  ivars->numMicChannels);
        }

        // Best-effort clock lock/rate readback (ClockRateAndLock, 0x51 — read-only,
        // wLength=5: [0]=lock 0/1, [1..4]=uint32 BE measured rate). Proof-point toward
        // clock-status readback; NEVER blocks Start on it. LE decode; sanity-check
        // against the register-based GetActualClockRate on first hardware run.
        {
            uint8_t clk[5] = { 0, 0, 0, 0, 0 };
            bool ok = !ivars->convPort1 && ReadVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                        ivars->symphonyAddr, kSIOCmd_ClockRateAndLock,
                                        /*nValue*/0, clk, /*wLength*/5,
                                        ivars->runtimeTxSeq,
        ivars->isLegacyPCIe2100);
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
                STLOG("SymphonyIO: ClockRateAndLock — %{public}s, measured %u Hz (register-based=%u Hz)",
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

            // Read the selected stage for a fitted MicPre, including an
            // Instrument channel retained by the unit before Maestro starts.
            // Evidence: og_source/symphonymk1/ext/Symphony64/generic/Products/SymphonyIO/SymphonyIOControl.cpp:692-714.
            uint8_t type = 0;
            if (ReadVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                  ivars->symphonyAddr, kSIOCmd_CurrentAnalogInputType,
                                  0x80000000u | ch, &type, 1, ivars->runtimeTxSeq, ivars->isLegacyPCIe2100) && type <= 4) {
                __atomic_store_n(&ivars->micPreInstrument[ch], type == 4, __ATOMIC_RELEASE);
                __atomic_store_n(&ivars->micPreMic[ch], type == 3, __ATOMIC_RELEASE);
                ivars->micPreType[0][ch] = type;
                __atomic_store_n(&ivars->micPreTypeKnown[ch], true, __ATOMIC_RELEASE);
            }
            // Polarity and high-pass start from the unit, as the original's
            // RecallSettingsFromHardware read them
            // (og_source/maestrolink/Software/SymphonyIOBoard_MicPre8ch.cpp:2205-2223).
            // A failed read leaves the value unknown and the control at Off.
            ReadMicPreSwitches(ivars, 0, ch);
            // AudioDriverKit has no public range setter after init. Keep the
            // full Mic range; PublishMicGain clamps + notifies for Instrument.
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

            // Polarity, 80 Hz high-pass and input type, per host input like
            // phantom and gain. Each starts from what the unit reported and
            // follows the host input's MicPre route (PublishMicPreControls).
            SymphonyPhaseControl *pc = OSTypeAlloc(SymphonyPhaseControl);
            if (pc && pc->init(this, /*settable*/true, ivars->micPrePhase[0][ch],
                               (IOUserAudioObjectPropertyElement)(ch + 1),
                               IOUserAudioObjectPropertyScope::Input,
                               IOUserAudioClassID::PhaseInvertControl)) {   // 'phsi'
                pc->SetChannel(ch);
                pc->SetDriver(this);
                ret = ivars->audioDevice->AddControl(pc);
                if (ret != kIOReturnSuccess) {
                    STERR("Audio: AddControl(polarity ch%u) failed: 0x%x", ch, ret);
                } else {
                    ivars->phaseControl[ch] = pc;
                    ivars->phaseControl[ch]->retain();
                }
            } else {
                STERR("Audio: SymphonyPhaseControl alloc/init failed (ch%u)", ch);
            }
            OSSafeReleaseNULL(pc);

            SymphonyHighPassControl *hc = OSTypeAlloc(SymphonyHighPassControl);
            if (hc && hc->init(this, /*settable*/true, (IOUserAudioObjectPropertyElement)(ch + 1),
                               IOUserAudioObjectPropertyScope::Input,
                               IOUserAudioClassID::HighPassFilterControl)) {   // 'hipf'
                IOUserAudioSelectorValueDescription values[2] = {
                    { 0, OSSharedPtr<OSString>(OSString::withCString("Off"), OSNoRetain) },
                    { 1, OSSharedPtr<OSString>(OSString::withCString("On"), OSNoRetain) },
                };
                hc->AddControlValueDescriptions(values, 2);
                IOUserAudioSelectorValue initial = ivars->micPreHighPass[0][ch] ? 1 : 0;
                hc->SetCurrentSelectedValues(&initial, 1);
                hc->SetChannel(ch);
                hc->SetDriver(this);
                ret = ivars->audioDevice->AddControl(hc);
                if (ret != kIOReturnSuccess) {
                    STERR("Audio: AddControl(high-pass ch%u) failed: 0x%x", ch, ret);
                } else {
                    ivars->highPassControl[ch] = hc;
                    ivars->highPassControl[ch]->retain();
                }
            } else {
                STERR("Audio: SymphonyHighPassControl alloc/init failed (ch%u)", ch);
            }
            OSSafeReleaseNULL(hc);

            // A line-level control ('nlvl'), so the HAL exposes it as
            // kAudioDevicePropertyChannelNominalLineLevel(s) and ...NameForID,
            // the properties the original served for the input type
            // (SymphonyIOBoard_MicPre8ch.cpp:383-388). IDs are CoreAudio's
            // order (+4, -10, Variable, Mic, Instrument; mAEstro.h:353-357).
            SymphonyInputTypeControl *tc = OSTypeAlloc(SymphonyInputTypeControl);
            if (tc && tc->init(this, /*settable*/true, (IOUserAudioObjectPropertyElement)(ch + 1),
                               IOUserAudioObjectPropertyScope::Input,
                               IOUserAudioClassID::LineLevelControl)) {   // 'nlvl'
                // Instrument only where the host input reaches MicPre 1-4
                // (SymphonyIOBoard_MicPre8ch.cpp:26,970-974); routes refresh it.
                IOUserAudioSelectorValueDescription types[5];
                FillMicPreTypeDescriptions(types);
                ivars->inputTypeChoices[ch] = MicPreTypeChoicesForHost(ivars, ch);
                tc->AddControlValueDescriptions(types, ivars->inputTypeChoices[ch]);
                IOUserAudioSelectorValue initial = WireInputTypeToCore(ivars->micPreType[0][ch]);
                tc->SetCurrentSelectedValues(&initial, 1);
                tc->SetChannel(ch);
                tc->SetDriver(this);
                ret = ivars->audioDevice->AddControl(tc);
                if (ret != kIOReturnSuccess) {
                    STERR("Audio: AddControl(input type ch%u) failed: 0x%x", ch, ret);
                } else {
                    ivars->inputTypeControl[ch] = tc;
                    ivars->inputTypeControl[ch]->retain();
                }
            } else {
                STERR("Audio: SymphonyInputTypeControl alloc/init failed (ch%u)", ch);
            }
            OSSafeReleaseNULL(tc);
        }
        ArmMicPreSettle(ivars);   // coreaudiod sees the controls for the first time
        if (ivars->numMicChannels > 0)
            STLOG("Audio: MicPre8 phantom, gain, polarity, high-pass and type controls added (%u channels)",
                  ivars->numMicChannels);

        // ── 36e. EXPERIMENT (64ch, stage 2): the port selector ─────────────
        // Two-port builds only. The original's input and output data-source
        // selectors, same two entries in the same order, the first selected
        // (Symphony64AudioEngine.cpp:38-93), named after the device rather
        // than Apogee's "Port 1: 32ch" / "Port 1-2: 64ch" (see
        // SymphonyThunderbridgeShared.h for why).
        // Audio MIDI Setup shows them as "Source". They sit on the main
        // element; the optical format selectors above use elements 1 and 2.
        // macOS also offers a data source in Sound settings and shows its name
        // there in place of the device's, as it did with the original.
        if (ivars->portCount == 2) {
            for (uint32_t i = 0; i < 2; i++) {
                SymphonyPortSourceControl *pc = OSTypeAlloc(SymphonyPortSourceControl);   // +1
                if (pc && pc->init(this, /*settable*/true,
                        IOUserAudioObjectPropertyElementMain,
                        i == 0 ? IOUserAudioObjectPropertyScope::Input
                               : IOUserAudioObjectPropertyScope::Output,
                        IOUserAudioClassID::DataSourceControl)) {
                    IOUserAudioSelectorValueDescription portValues[2] = {
                        { kSymphonyPortSourcePort1,
                          OSSharedPtr<OSString>(OSString::withCString(kSymphonyPortSourceName32), OSNoRetain) },
                        { kSymphonyPortSourcePorts1And2,
                          OSSharedPtr<OSString>(OSString::withCString(kSymphonyPortSourceName64), OSNoRetain) },
                    };
                    pc->AddControlValueDescriptions(portValues, 2);
                    IOUserAudioSelectorValue initSel = kSymphonyPortSourcePort1;
                    pc->SetCurrentSelectedValues(&initSel, 1);
                    pc->SetDriver(this);
                    ret = ivars->audioDevice->AddControl(pc);   // framework retains
                    if (ret == kIOReturnSuccess) {
                        ivars->portSourceControl[i] = pc;
                        ivars->portSourceControl[i]->retain();   // tracked ref (balanced in teardown)
                    } else {
                        STERR("Audio: AddControl(port selector %u) failed: 0x%x", i, ret);
                    }
                } else {
                    STERR("Audio: SymphonyPortSourceControl alloc/init failed (%u)", i);
                }
                OSSafeReleaseNULL(pc);   // drop the OSTypeAlloc +1; ivar ref keeps it alive
            }
            // Every configuration change of this device now passes through
            // PerformPortModeChange (see SymphonyAudioDevice.cpp).
            if (auto *device = OSDynamicCast(SymphonyAudioDevice, ivars->audioDevice))
                device->SetPortModeDriver(this);
            STLOG("EXPERIMENT: port selector published (\"" kSymphonyPortSourceName32 "\" selected, \""
                  kSymphonyPortSourceName64 "\" available)");
        }

        // dext 143: every build's configuration changes pass through the
        // driver, for VBus (PerformVBusChange; set once, so this does nothing
        // after the two-port call above).
        if (auto *device = OSDynamicCast(SymphonyAudioDevice, ivars->audioDevice))
            device->SetPortModeDriver(this);

        // ── 37. Set IO operation handler ─────────────────────────────────
        // Copy between CoreAudio stream buffers and FPGA DMA buffers.
        // WriteEnd (playback): CoreAudio wrote to stream buf → copy to DMA buf.
        // BeginRead (capture): copy DMA buf → stream buf before CoreAudio reads.
        //
        // Ring buffer layout: kNumSampleFrames frames × kMaxChannelsPerPort channels × 4 bytes
        // The sample_time wraps around the ring buffer via modulo.

        // EXPERIMENT (64ch, stage 2): a two-port build installs its own handler,
        // which can also split 64-channel frames between the two ports' DMA
        // buffers. The one-port handler below is unchanged and is the only one a
        // one-port build ever installs.
        if (ivars->portCount == 2) {
            ret = InstallTwoPortIOHandler(ivars);
        } else
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

                    // VBus (dext 143): host memory only; one atomic load when off.
                    if (in_io_operation == IOUserAudioIOOperationWriteEnd ||
                        in_io_operation == IOUserAudioIOOperationBeginRead)
                        VBusIO(VBusCurrent(ivars), in_io_operation == IOUserAudioIOOperationWriteEnd,
                               in_io_buffer_frame_size, in_sample_time);

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
                                  "dma[0..3]=0x%08x,0x%08x,0x%08x,0x%08x %{public}s",
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
        OSString *deviceName = OSString::withCString(kSymphonyDeviceName);
        if (deviceName) {
            ivars->audioDevice->SetName(deviceName);
            OSSafeReleaseNULL(deviceName);
        }

        // Per-channel input and output names (SymphonyChannelNames.h).
        PublishChannelNames(ivars);

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
        // dext 130: say what the DMA check found, not just that DMA was enabled.
        STLOG("  PT-06 DMA: enabled, %{public}s (A2H + H2A, 32ch, 1MB buffers)",
              ivars->dmaVerifiedRunning ? "running (CHA advanced)" : "NOT running (CHA did not advance)");
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

// The monitor control poll: the Core Audio volume/mute (or the converter
// keys) sent to the chosen output when they moved. Runs on xlinkQueue, from
// the interrupt's poll block and, inline, just before the start-up output
// gate opens (MaybeReleaseStartupOutputMute), so a mute Core Audio restored
// reaches the unit before the outputs do even when no interrupt ran.
static void RunMonitorPollOnQueue(SymphonyThunderbridge_IVars *ivars)
{
    if (ivars->monitorDeviceB && (!ivars->unitBConfigured || ivars->portMode != 64)) {
        ivars->monitorDeviceB = false;
        PublishSelectedMonitor(ivars);
    } else {
        const bool b = ivars->monitorDeviceB;
        const bool converter = __atomic_load_n(&ivars->converterVolumeKeys, __ATOMIC_ACQUIRE);
        const uint32_t arms = __atomic_load_n(&ivars->monitorSettleArms, __ATOMIC_ACQUIRE);
        // The app's Audio Output choice: 0 speakers, 1/2 a headphone
        // (the headphone's index is kind - 1).
        const unsigned kind = SelectedMonitorKind(ivars, b);
        // Nothing to move: Speakers chosen in Line mode
        // (SymphonyIO.cpp:2345-2351), or "None" on converters. The
        // control is put back to what it showed and nothing is written.
        const bool inert = converter ? ivars->converterKeysOff : SelectedMonitorInert(ivars, b);
        // The control's value is not known to belong to this output
        // while coreaudiod may be restoring a value it saved earlier,
        // possibly for another output (the settle window: Start, a
        // coreaudiod connection, wake, link recovery, a configuration
        // change; kHALMicPreSettleNs). A level is never sent from such
        // a value: the control is put back to the output's level, and
        // a key pressed after the window is honoured.
        // Unit A's levels were never read (every read was lost when
        // the link came up): read them now that a control moved. The
        // controls then show the unit's level; that value is not sent.
        if (!converter && !b && !ivars->monitorLevelsKnown && ivars->symphonyLinkConfigured &&
            !ivars->convPort1 && XLinkTxAdmissible(ivars) && MonitorControlsMoved(ivars)) {
            if (ReadUnitAMonitorLevel(ivars, kSymphonyMonitorOutputSpeakers) &&
                ReadUnitAMonitorLevel(ivars, kSymphonyMonitorOutputHP1) &&
                ReadUnitAMonitorLevel(ivars, kSymphonyMonitorOutputHP2)) {
                ivars->monitorLevelsKnown = true;
                PublishSelectedMonitor(ivars);
            }
        }
        // The first pass after the window was armed counts as inside
        // it, however late it runs (monitorSettleArms).
        const bool settling = MicPreSettling(ivars) ||
            arms != __atomic_load_n(&ivars->monitorPolledArm, __ATOMIC_ACQUIRE);
        // No level of the unit's is known: nothing at all is sent.
        const bool unknown = !converter && !b && (!ivars->monitorLevelsKnown ||
            (SelectedMonitorKind(ivars, false) == 0 && !ivars->speakerLevelKnown));
        // While settling, only a change towards quiet is honoured: a
        // level below the output's, and mute on. Those cannot make
        // anything louder than the unit was, and a mute the user sees
        // as on is never dropped. Louder and unmute are put back.
        // Target and value are consumed together here. No delayed block
        // re-resolves a physical destination after selection changes.
        // Diagnostics: one line per handled change, for reports
        // of keys that "do nothing". The first 64 lines of a
        // driver session, then one in 16, so key repeat cannot
        // flood the log. No behaviour depends on it.
        static uint32_t sKeyLogCount = 0;
        const char *keyOutput = converter ? "converter"
            : (kind == 1 ? "HP1" : (kind == 2 ? "HP2" : "speakers"));
        auto keyLog = [&](const char *what, const char *outcome, float shown, float wanted) {
            const uint32_t n = sKeyLogCount++;
            if (n < 64 || n % 16 == 0)
                STLOG("Volume keys: unit=%{public}s output=%{public}s %{public}s %.1f -> %.1f: %{public}s",
                      b ? "B" : "A", keyOutput, what, shown, wanted, outcome);
        };
        auto keepReason = [&](bool louder) -> const char * {
            if (inert) return "put back: line mode";
            if (unknown) return "put back: levels not known";
            return louder ? "put back: settling (louder)" : "put back: settling (unmute)";
        };
        if (ivars->outputVolumeControl) {
            const float db = ivars->outputVolumeControl->GetDecibelValue();
            const float diff = db - ivars->lastVolumeDb;
            if ((diff > 0.5f || diff < -0.5f) && (inert || unknown || (settling && diff > 0.0f))) {
                keyLog("level", keepReason(true), ivars->lastVolumeDb, db);
                ivars->outputVolumeControl->SetDecibelValue(ivars->lastVolumeDb);
            } else if ((diff > 0.5f || diff < -0.5f) && XLinkTxAdmissible(ivars)) {
                keyLog("level", "sent", ivars->lastVolumeDb, db);
                ivars->lastVolumeDb = db;
                uint8_t value = static_cast<uint8_t>(db > 0 ? 0 : (db < -64 ? 64 : -db));
                if (converter) {
                    ivars->converterTrimAtten = value;
                    ApplyConverterTrim(ivars);
                } else {
                    MonitorAttenuation(ivars, b, kind) = value;
                    SendVendorRequestOn(ivars->pciDevice, ivars->barMemoryIndex,
                        b ? kRegXLink2TX : kRegXLink1TX, b ? 1 : ivars->symphonyAddr,
                        kind ? kSIOCmd_HeadphoneVolume : kSIOCmd_SpeakerVolume, kind ? kind - 1 : 0,
                        &value, 1, b ? ivars->runtimeTxSeq2 : ivars->runtimeTxSeq);
                }
            }
        }
        // The mute key is ignored only with "None" on converters.
        // With Speakers chosen in Line mode the original still
        // set the speaker mute (SymphonyIO.cpp:2239-2251 has no
        // mode check; only the volume set has one, :2345-2351).
        const bool muteInert = converter && ivars->converterKeysOff;
        if (ivars->outputMuteControl) {
            const bool muted = ivars->outputMuteControl->GetControlValue();
            if (muted != ivars->lastMuteState && (muteInert || unknown || (settling && !muted))) {
                keyLog("mute", muteInert ? "put back: keys set to None" : keepReason(false),
                       ivars->lastMuteState ? 1.0f : 0.0f, muted ? 1.0f : 0.0f);
                ivars->outputMuteControl->SetControlValue(ivars->lastMuteState);
            } else if (muted != ivars->lastMuteState && XLinkTxAdmissible(ivars)) {
                keyLog("mute", "sent", ivars->lastMuteState ? 1.0f : 0.0f, muted ? 1.0f : 0.0f);
                ivars->lastMuteState = muted;
                uint8_t value = muted ? 1 : 0;
                if (converter) {
                    ivars->converterTrimMuted = muted;
                    ApplyConverterTrim(ivars);
                } else {
                    // The Core Audio mute is the chosen output's own mute
                    // (SymphonyIO.cpp:2239-2276).
                    MonitorMute(ivars, b, kind) = muted;
                    SendVendorRequestOn(ivars->pciDevice, ivars->barMemoryIndex,
                        b ? kRegXLink2TX : kRegXLink1TX, b ? 1 : ivars->symphonyAddr,
                        kind ? kSIOCmd_HeadphoneMute : kSIOCmd_SpeakerMute, kind ? kind - 1 : 0,
                        &value, 1, b ? ivars->runtimeTxSeq2 : ivars->runtimeTxSeq);
                }
            }
        }
        __atomic_store_n(&ivars->monitorPolledArm, arms, __ATOMIC_RELEASE);
    }
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

    // Sample and send on the same serial queue as target selection/publication.
    // The IRQ never waits for XLink. At most one sample is queued; publications
    // invalidate it, so a pending old-target value cannot become a new command.
    IODispatchQueue *txq = ivars->xlinkQueue;
    if (txq && !__atomic_load_n(&ivars->txShutdown, __ATOMIC_ACQUIRE)) {
        const uint32_t generation = __atomic_load_n(&ivars->monitorGeneration, __ATOMIC_ACQUIRE);
        bool expected = false;
        if (__atomic_compare_exchange_n(&ivars->monitorPollScheduled, &expected, true,
                                        false, __ATOMIC_ACQ_REL, __ATOMIC_RELAXED)) {
            txq->DispatchAsync(^{
                if (generation == __atomic_load_n(&ivars->monitorGeneration, __ATOMIC_ACQUIRE)) {
                    RunMonitorPollOnQueue(ivars);
                }
                __atomic_store_n(&ivars->monitorPollScheduled, false, __ATOMIC_RELEASE);
            });
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
        STLOG("  SampleOut[0]=0x%08x SampleOut[1]=0x%08x%{public}s",
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
        STLOG("  SampleIn[0..3]=0x%08x,0x%08x,0x%08x,0x%08x%{public}s",
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
            STLOG("  A2H DMA buf @frame %u: [0..3]=0x%08x,0x%08x,0x%08x,0x%08x%{public}s",
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

// The rate-change transaction: mute, stop DMA, the rate to every unit, lock,
// the external clock source again, frame size, restart DMA, unmute. DMA runs
// whether or not Core Audio has IO started, so this is the same with audio
// idle. Callers: StartDevice (a nominal rate the hardware is not at yet) and,
// dext 141, SymphonySyncHardwareRate below (the moment the rate is set).
// Runs on the AudioDriverKit control thread, never on xlinkQueue.
static kern_return_t ApplyRequestedSampleRate(SymphonyThunderbridge_IVars *ivars,
                                              SymphonyThunderbridge *self,
                                              double requestedRate, const char *why)
{
    STLOG("%{public}s: sample rate changed %.0f → %.0f, reprogramming hardware",
          why, ivars->lastSampleRate, requestedRate);

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
        // EXPERIMENT (64ch, stage 2): with both ports running, port 2's
        // engine stops too (og StopDMA clears GCSR and GCSR2). Never true
        // in a one-port build.
        const bool bothPorts = ivars->portCount == 2 &&
            __atomic_load_n(&ivars->portMode, __ATOMIC_ACQUIRE) == 64;
        if (bothPorts)
            ModifyRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegGCSR2,
                           kGCSR2_DMAOutSize32 | kGCSR2_DMAInSize32,
                           kGCSR2_DMAEnableMask | kGCSR2_DMAMask);
        IOSleep(10);  // Let last DMA transfer complete

        // 3. Change sample rate via XLink (full lock/verify/lock sequence).
        bool cmdIssued = false;
        // EXPERIMENT: with two ports and a unit found on port 2, the
        // rate goes there too (null otherwise: one-port path unchanged).
        Port2RateChange port2Rate;
        port2Rate.ivars = ivars;
        Port2RateChange *port2 = Port2TakesRateChanges(ivars) ? &port2Rate : nullptr;
        rateOk = ChangeSampleRate(ivars->pciDevice,
                                  ivars->barMemoryIndex, requestedRate, &cmdIssued,
                                  port2, ivars->isLegacyPCIe2100);
        if (port2)
            FinishPort2RateChange(ivars, requestedRate, oldXlinkRate, cmdIssued, port2Rate);
        // Stage 2: port 1 changed rate but port 2 did not follow while it
        // was carrying audio. The original failed the whole change; here
        // port 1 carries on alone. Port 2's engine is already stopped, so
        // only its routing and buffer registers are put back, and Core
        // Audio is asked to return the streams to 32 channels.
        bool restartBothPorts = bothPorts;
        if (bothPorts && rateOk && !(port2 && port2Rate.ok)) {
            Port2ProgramRouting(ivars, false);
            Port2ProgramBuffers(ivars, false);
            SetPort2Enabled(ivars, false);   // back at 32: port 2 disabled, as SetNumPorts(1)
            // Port 2 had no unit clock at all: its units are gone.
            if (port2 && port2Rate.attempted && !port2Rate.clock) {
                const uint32_t failed = __atomic_load_n(&ivars->port2Flags, __ATOMIC_ACQUIRE)
                                      & kSymphonyPort2FlagRateFailed;
                ClearPort2Units(ivars, ivars->port2Clocking);
                __atomic_fetch_or(&ivars->port2Flags, failed, __ATOMIC_ACQ_REL);
            }
            Port2AudioFallBack(ivars, self, kSymphonyPort2ReasonRateChange, false);
            restartBothPorts = false;
        }

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
                SetDDSSampleRate(ivars->pciDevice, ivars->barMemoryIndex, oldXlinkRate,
                                 ivars->isLegacyPCIe2100);
            }
            STERR("StartDevice: rate change FAILED (cmdIssued=%d) — DMA stopped, outputs "
                  "muted, DDS+XLink consistent (offline pending reinit)", cmdIssued);
            return;
        }

        // 3b. dext 140: an external clock source is sent again once the
        // units run at the new rate. On a cold start Core Audio restores
        // the saved source (Word Clock, say) through the selector while
        // the hardware is still at its start-up 44.1 kHz, and this is
        // the first moment it is at the rate the external clock runs at;
        // without it the unit kept blinking until the source was
        // switched away and back by hand (issue 31). The original tied
        // the two together from the other side: changing external lock
        // forced a full rate re-sync, and a rate set that had trouble
        // re-set the word-clock setting (Symphony64 Driver/XLink.cpp
        // :149-160, :352-356). DMA is stopped and the card muted here.
        // Internal (the default) sends nothing: unchanged traces.
        // Not with unit B set up: there unit A's ClockMode carries the
        // Loop Sync output and master choice, which SendUnitAClock and
        // the Loop Sync configuration own, and the recorded bytes do
        // not include them.
        if (!ivars->convPort1 && !ivars->unitBConfigured && ivars->unitAClockKnown &&
            ivars->unitAClock[0] >= 2 && ivars->unitAClock[0] <= 5) {
            uint8_t clockData[4];
            memcpy(clockData, ivars->unitAClock, 4);
            ApplyOneUnitLoopSyncByte(ivars, clockData);
            const bool ok = SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                              ivars->symphonyAddr, kSIOCmd_ClockMode, 0,
                                              clockData, sizeof(clockData), ivars->runtimeTxSeq);
            NoteUnitAClockSent(ivars, clockData, ok);
            // Give the unit up to a second to lock to its external
            // clock before DMA restarts and the card is unmuted (it
            // goes on either way, as before this change).
            uint8_t clk[5] = {};
            bool read = false;
            for (int poll = 0; ok && poll < 10; poll++) {
                IOSleep(100);
                memset(clk, 0, sizeof(clk));
                read = ReadVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                         ivars->symphonyAddr, kSIOCmd_ClockRateAndLock, 0, clk, 5,
                                         ivars->runtimeTxSeq, ivars->isLegacyPCIe2100);
                if (!read || clk[0]) break;
            }
            const uint32_t measured = ((uint32_t)clk[1] << 24) | ((uint32_t)clk[2] << 16) |
                                      ((uint32_t)clk[3] << 8) | clk[4];
            STLOG("StartDevice: ClockMode(source %u) sent again after the rate change to %.0f Hz: %{public}s; "
                  "unit reports %{public}s, measured %u Hz",
                  clockData[0], requestedRate, ok ? "OK" : "FAILED",
                  !read ? "nothing" : clk[0] ? "locked" : "not locked", read ? measured : 0u);
        }

        // 4. Reprogram ClkCtrl frame size (legacy does this in every
        // StartDMA).  The legacy High Performance profile changes the
        // FPGA period with sample-rate tier: 4, 8, then 32 frames.
        const TimingProfile profile = TimingProfileForRate(requestedRate);
        ModifyRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegClkCtrl,
                       ((profile.frameSize - 1) << kClkCtrl_FrameShift) & kClkCtrl_FrameMask,
                       kClkCtrl_FrameMask);
        uint32_t convIn = 0, convOut = 0;
        ConverterLatencyFor(ivars, requestedRate, &convIn, &convOut);
        ivars->convLatencyIn = convIn;
        ivars->convLatencyOut = convOut;
        const kern_return_t timingResult =
            ApplyAudioTimingProfile(ivars->audioDevice, requestedRate, convIn, convOut);
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
        STLOG("StartDevice: FPGA frame size set to %u samples (%{public}s profile)",
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

        // EXPERIMENT (64ch, stage 2): both ports were running and both
        // followed the rate. Align the phase as the original did after
        // every rate change, then start both engines, port 2 first, and
        // unmute. Never taken in a one-port build.
        if (restartBothPorts) {
            AlignXLinkPhase(ivars);
            // The alignment asks each unit a question; check for a stop
            // again so DMA is not enabled after one has begun.
            if (__atomic_load_n(&ivars->stopping, __ATOMIC_ACQUIRE) || !ivars->pciDevice) {
                aborted = true;
                STERR("StartDevice: stop began during the phase alignment — leaving both "
                      "ports stopped + muted for teardown");
                return;
            }
            Port2StartBothEngines(ivars);
            STLOG("StartDevice: both ports restarted and unmuted after rate change to %.0f Hz",
                  requestedRate);
            return;
        }

        // dext 130, Symphony 64 PCIe card: after a rate change the original
        // jams the sample-count phase (XLink::SetSampleRate :1074-1150) and
        // then pulses frame sync on every card (syncComponents), before the
        // engine starts DMA. Card muted, DMA stopped here.
        // dext 131: converters on either card get the same alignment
        // (the original ran it in every SetSampleRate); a Symphony I/O on
        // the ThunderBridge is unchanged.
        if (ivars->isLegacyPCIe2100 || ConvPort1(ivars)) {
            AlignXLinkPhase(ivars);
            __atomic_store_n(&ivars->convRecoveryPending, false, __ATOMIC_RELEASE);
            __atomic_and_fetch(&ivars->convFlags, ~kSymphonyConvRecoveryPending, __ATOMIC_RELEASE);
            if (__atomic_load_n(&ivars->stopping, __ATOMIC_ACQUIRE) || !ivars->pciDevice) {
                aborted = true;
                STERR("StartDevice: stop began during the phase alignment — leaving DMA "
                      "stopped + muted for teardown");
                return;
            }
            if (ivars->isLegacyPCIe2100)
                PulseFrameSyncLegacyPCIe(ivars->pciDevice, ivars->barMemoryIndex, "rate change");
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
            STLOG("StartDevice: DMA restarted (GCSR=0x%08x%{public}s)", gcsr,
                  ivars->meterDMAActive ? " +Meters" : "");
        }

        // 7. Unmute after DMA is running (legacy: unmute AFTER StartDMA + delay)
        IOSleep(10);
        ModifyRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegClkCtrl,
                       ClkCtrlUnmuteBits(ivars), 0);
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
    __atomic_store_n(&ivars->namingSampleRate, SymphonyNamingRateHz(requestedRate), __ATOMIC_RELEASE);
    STLOG("StartDevice: hardware now at %.0f Hz", requestedRate);
    NoteStartupRateSettled(ivars, requestedRate, "Core Audio's rate programmed");
    // Optical channel names follow the rate (ADAT / SMUX / N.A.).
    ScheduleChannelNames(ivars, self);
    return kIOReturnSuccess;
}

// dext 141: the hardware takes a new nominal rate when it is set, not at the
// next IO start. The original did this in performFormatChange, which called
// setSampleRateInHardware straight away (Symphony64 SymphonyAPI/
// SymphonyBaseAudioEngine.cpp:1232-1236, :2046-2096). Before this, a rate that
// Core Audio restored after a start or a reconnect stayed on the device only:
// with nothing playing, the Symphony sat at its start-up 44.1 kHz, could not
// lock to an external clock at another rate, and blinked (issue 31).
// Called by SymphonyAudioDevice with IO stopped by Core Audio: after a nominal
// rate change, with that rate; and after the driver's own "link recovered"
// configuration change (rate 0: the device's current rate), which is how a
// rate set while the link was still coming up is caught once it is up. Not on
// the host's own configuration changes, where the device can still report the
// previous rate. A rate that failed here is not tried again until the rate
// changes or IO starts: the link watch repairs the card after a failure and
// asks for another configuration change, which would otherwise loop.
void SymphonySyncHardwareRate(IOUserAudioDevice *device, double rate, uint64_t changeAction, const char *why)
{
    if (rate <= 0.0 && changeAction != kSymphonyConfigChangeLinkRecovered) return;
    IOLock *lock = __atomic_load_n(&sNominalRateLock, __ATOMIC_ACQUIRE);
    if (!lock || !device) return;
    SymphonyThunderbridge *driver = nullptr;
    SymphonyThunderbridge_IVars *ivars = nullptr;
    IOLockLock(lock);
    for (auto &o : sNominalRateObservers) {
        if (o.device == device) {
            driver = o.driver;
            ivars = o.ivars;
            driver->retain();
            break;
        }
    }
    IOLockUnlock(lock);
    if (!driver) return;
    const double requestedRate = rate > 0.0 ? rate : device->GetSampleRate();
    // dext 151: Core Audio set the rate the hardware already runs at.
    if (rate > 0.0 && requestedRate == ivars->lastSampleRate)
        NoteStartupRateSettled(ivars, requestedRate, "Core Audio set the rate the hardware runs at");
    if (requestedRate != ivars->lastSampleRate) {
        // No "recovery in flight" gate: the transaction waits its turn behind
        // a recovery on xlinkQueue, as StartDevice's does.
        const char *skip = nullptr;
        if (__atomic_load_n(&ivars->ioRunning, __ATOMIC_ACQUIRE)) skip = "IO is running";
        else if (!ivars->symphonyLinkConfigured) skip = "the link is not configured yet";
        else if (!HardwareReachable(ivars)) skip = "the endpoint is not reachable";
        else if (requestedRate == ivars->idleRateFailed) skip = "this rate already failed with no IO start";
        if (skip) {
            STLOG("Rate sync (%{public}s): device at %.0f Hz, hardware at %.0f Hz; not applied now (%{public}s)",
                  why, requestedRate, ivars->lastSampleRate, skip);
        } else {
            const kern_return_t rc = ApplyRequestedSampleRate(ivars, driver, requestedRate, why);
            ivars->idleRateFailed = rc == kIOReturnSuccess ? 0.0 : requestedRate;
            STLOG("Rate sync (%{public}s): %.0f Hz applied to the hardware with no IO start: 0x%x",
                  why, requestedRate, rc);
        }
    }
    driver->release();
}

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
    // dext 131: a converter recovery that found audio running (phase out of the
    // units' window, a unit that lost lock, a word clock change) is done here,
    // with the rate-change transaction below: mute, stop DMA, the rate to every
    // unit, lock, verify, phase alignment, restart, unmute.
    if ((ConvPort1(ivars) ||
         (__atomic_load_n(&ivars->convFlags, __ATOMIC_ACQUIRE) & kSymphonyConvPort2Converters)) &&
        __atomic_load_n(&ivars->convRecoveryPending, __ATOMIC_ACQUIRE)) {
        STLOG("StartDevice: converter recovery pending — running the rate transaction at the same rate");
        ivars->lastSampleRate = 0;
    }
    if (ivars->audioDevice) {
        double requestedRate = ivars->audioDevice->GetSampleRate();
        if (requestedRate != ivars->lastSampleRate) {
            ivars->idleRateFailed = 0.0;
            const kern_return_t rateResult =
                ApplyRequestedSampleRate(ivars, this, requestedRate, "StartDevice");
            if (rateResult != kIOReturnSuccess) return rateResult;
        } else if (__atomic_load_n(&ivars->startupRatePending, __ATOMIC_ACQUIRE)) {
            // dext 151: IO starts at the rate the hardware already runs at.
            // dext 152: not counted as the rate settling. A client can start
            // IO before Core Audio has restored its controls (a saved mute),
            // and nothing the release could sample would show it yet, so the
            // start-up gate keeps its deadline. A later rate Core Audio sets
            // still shortens it (startupRatePending stays set).
            STLOG("ClkCtrl: IO start at the hardware's rate (%.0f Hz); startup output gate keeps its deadline",
                  requestedRate);
        }
    }

    // The hardware now runs at the nominal rate. If that rate reached the
    // device some way that skipped HandleChangeSampleRate (a stream format
    // set directly), the names catch up here.
    if (ivars->audioDevice) {
        const uint32_t hz = SymphonyNamingRateHz(ivars->audioDevice->GetSampleRate());
        if (__atomic_exchange_n(&ivars->namingSampleRate, hz, __ATOMIC_ACQ_REL) != hz)
            ScheduleChannelNames(ivars, this);
    }

    // dext 130, Symphony 64 PCIe card: the original starts audio DMA at every IO
    // start, not once at load (performAudioEngineStart: INTMASK 0 then AHI, the
    // StartDMA disable / trigger-select / enable edge, 10 ms, unmute;
    // SymphonyBaseAudioEngine.cpp:798-844, Symphony64Card.cpp:1517-1580). This
    // driver starts it in Start(). If the card's DMA is not moving now, run the
    // original's start sequence once, on the serial XLink queue, and log the result.
    if (ivars->isLegacyPCIe2100 && ivars->dmaRunning && ivars->xlinkQueue &&
        !__atomic_load_n(&ivars->stopping, __ATOMIC_ACQUIRE)) {
        ivars->xlinkQueue->DispatchSync(^{
            IOPCIDevice *dev = ivars->pciDevice;
            if (!dev || __atomic_load_n(&ivars->stopping, __ATOMIC_ACQUIRE)) return;
            const uint8_t mi = ivars->barMemoryIndex;
            uint32_t cha1 = 0, cha2 = 0;
            ReadRegister(dev, mi, kRegA2HCHA, &cha1);
            IOSleep(20);
            ReadRegister(dev, mi, kRegA2HCHA, &cha2);
            if (cha1 != cha2) {
                STLOG("StartDevice (PCIe card): DMA moving (A2H_CHA 0x%08x -> 0x%08x), no restart needed", cha1, cha2);
                return;
            }
            STLOG("StartDevice (PCIe card): DMA not moving (A2H_CHA=0x%08x) — running the original's DMA start", cha1);
            ModifyRegister(dev, mi, kRegClkCtrl, 0, kClkCtrl_Unmute | kClkCtrl_InputUnmute | kClkCtrl_OutputUnmute);
            WriteRegister(dev, mi, kRegIntStatus, 0xFFFFFFFF);
            WriteRegister(dev, mi, kRegIntMask, 0);
            WriteRegister(dev, mi, kRegIntMask, kInt_A2HWrap);
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
            IOSleep(10);
            ModifyRegister(dev, mi, kRegClkCtrl, ClkCtrlUnmuteBits(ivars), 0);
            IOSleep(90);
            uint32_t cha3 = 0, intStatus = 0;
            ReadRegister(dev, mi, kRegA2HCHA, &cha3);
            ReadRegister(dev, mi, kRegIntStatus, &intStatus);
            STLOG("StartDevice (PCIe card): after the DMA start A2H_CHA=0x%08x (%{public}s), IntStatus=0x%08x, GCSR=0x%08x",
                  cha3, cha3 != cha1 ? "moving" : "still not moving", intStatus, gcsr);
        });
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
    ivars->ioOpCount = 0;  // Reset diagnostic counter
    // dext 143: the sample time starts again at 0, and both VBus rings are
    // silence, so nothing of an earlier IO session can be read, whether or
    // not the host writes its first cycles.
    VBusSilence(ivars);
    // M2: ioRunning is the publication gate between this thread (the AudioDriverKit
    // control queue) and the IRQ queue. Store it with RELEASE so the anchor payload
    // written just above (zeroTimestampSampleTime, firstTimestampAfterStart) is
    // guaranteed visible to any IRQ callback that observes ioRunning==true via its
    // ACQUIRE load — the handler can never pair "running" with a stale anchor.
    // dext 127, diagnostics: counters at IO start, for the link watch's one
    // report on whether audio wraps follow (LinkWatchTimerOccurred).
    ivars->ioStartIrq       = __atomic_load_n(&ivars->interruptCount, __ATOMIC_RELAXED);
    ivars->ioStartWraps     = __atomic_load_n(&ivars->audioWrapCount, __ATOMIC_RELAXED);
    ivars->ioStartWatchTick = __atomic_load_n(&ivars->linkWatchTicks, __ATOMIC_RELAXED);
    __atomic_store_n(&ivars->ioStartReported, 0u, __ATOMIC_RELEASE);
    STLOG("StartDevice: IO starting — irq=%llu wraps=%llu cardReinits=%u GCSR(last watch)=0x%08x "
          "irqIndex=%u irqTypes=0x%llx/0x%llx/0x%llx/0x%llx",
          ivars->ioStartIrq, ivars->ioStartWraps, ivars->cardReinitCount, ivars->lastWatchGcsr,
          ivars->irqIndexUsed,
          ivars->irqTypeAtStart[0], ivars->irqTypeAtStart[1],
          ivars->irqTypeAtStart[2], ivars->irqTypeAtStart[3]);
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

    // Call super to update IO state
    const kern_return_t ret = super::StopDevice(in_object_id, in_flags);

    // dext 131: the card keeps playing its output ring while DMA runs, so the
    // last ~170 ms a client wrote would repeat until IO starts again (heard on
    // the PCIe card after quitting a DAW). Apogee's performAudioEngineStop
    // cleared the host output buffers for the same reason ("this will help to
    // clear the sample buffers in the hardware", SymphonyBaseAudioEngine.cpp
    // :846-870) before stopping DMA. Host memory only, no register access;
    // the next client's audio overwrites it as before.
    if (ivars->h2aDMA)
        ivars->h2aDMA->PerformOperation(kIODMACommandPerformOperationOptionZero, 0, kDMABufferSize, 0, nullptr);
    if (ivars->h2a2DMA)
        ivars->h2a2DMA->PerformOperation(kIODMACommandPerformOperationOptionZero, 0, kDMABufferSize, 0, nullptr);
    STLOG("StopDevice: playback buffers cleared (the card plays silence until IO starts again)");
    // VBus (dext 143): IO has stopped, so nothing a client wrote in this
    // session can be read in the next one (the sample time starts again).
    VBusResetSpan(ivars);
    return ret;
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
        ivars->startupOutputMuteHeld = false;
        __atomic_store_n(&ivars->startupRatePending, false, __ATOMIC_RELEASE);
        // dext 152: nothing is known to be on a unit after Stop (xlinkQueue
        // state, but TX is shut down above, so no sender reads it again).
        ForgetSentClockAndOptical(ivars);
        // No more nominal-rate renames: the device is about to be released.
        UnregisterNominalRateObserver(this);

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
        // Two-port experiment only (null otherwise): port 2's buffers too.
        if (ivars->a2h2DMA) {
            ivars->a2h2DMA->PerformOperation(
                kIODMACommandPerformOperationOptionZero, 0, kDMABufferSize, 0, nullptr);
        }
        if (ivars->h2a2DMA) {
            ivars->h2a2DMA->PerformOperation(
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

                // ── 8b. Let XLink work already in flight finish BEFORE the audio
                //    objects go (retire, kSelectorRetireForUpgrade, makes Stop()
                //    with the hardware present and a client possibly streaming a
                //    routine path). A rate transaction or volume drain that began
                //    before 'stopping' was set may still use audioDevice; anything
                //    that starts after it sees 'stopping' and returns. No register
                //    access: the drain at step 10 stays where it was.
                if (iv->xlinkQueue) {
                    iv->xlinkQueue->DispatchSync(^{});
                }

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
                    VBusRemoveStreams(iv);   // dext 143: here, not under portPublishLock
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
                        if (iv->phaseControl[ch]) iv->audioDevice->RemoveControl(iv->phaseControl[ch]);
                        if (iv->highPassControl[ch]) iv->audioDevice->RemoveControl(iv->highPassControl[ch]);
                        if (iv->inputTypeControl[ch]) iv->audioDevice->RemoveControl(iv->inputTypeControl[ch]);
                    }
                    if (iv->vendorProperty)      iv->audioDevice->RemoveCustomProperty(iv->vendorProperty);
                    // Two-port experiment only (both null otherwise): the port
                    // selectors, and the device's pointer back to this driver.
                    for (uint32_t i = 0; i < 2; i++)
                        if (iv->portSourceControl[i]) iv->audioDevice->RemoveControl(iv->portSourceControl[i]);
                    self->RemoveObject(iv->audioDevice);
                }
                // Two-port experiment only (the lock is null otherwise): a
                // configuration change being performed right now uses the
                // selectors, streams and device under this lock; wait for it.
                // 'stopping' is set, so it will not start on them afterwards.
                if (iv->portPublishLock) IOLockLock(iv->portPublishLock);
                VBusReleaseStreamsLocked(iv);   // dext 143: references only; no call into the device under the lock
                for (uint32_t i = 0; i < 2; i++)
                    OSSafeReleaseNULL(iv->portSourceControl[i]);
                OSSafeReleaseNULL(iv->vendorProperty);
                OSSafeReleaseNULL(iv->outputVolumeControl);
                OSSafeReleaseNULL(iv->outputMuteControl);
                OSSafeReleaseNULL(iv->clockSourceControl);
                for (uint32_t b = 0; b < 2; b++)
                    OSSafeReleaseNULL(iv->opticalControl[b]);
                for (uint32_t ch = 0; ch < 8; ch++) {
                    OSSafeReleaseNULL(iv->phantomControl[ch]);
                    OSSafeReleaseNULL(iv->micGainControl[ch]);
                    OSSafeReleaseNULL(iv->phaseControl[ch]);
                    OSSafeReleaseNULL(iv->highPassControl[ch]);
                    OSSafeReleaseNULL(iv->inputTypeControl[ch]);
                }
                OSSafeReleaseNULL(iv->inputStream);
                OSSafeReleaseNULL(iv->outputStream);
                OSSafeReleaseNULL(iv->audioDevice);
                if (iv->portPublishLock) IOLockUnlock(iv->portPublishLock);

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
                // Two-port experiment only (null otherwise). Port 2's engine was
                // stopped with port 1's: steps 6 and 10b clear GCSR2's DMA bits.
                iv->port2AudioReady = false;
                if (iv->a2h2DMA) {
                    iv->a2h2DMA->CompleteDMA(kIODMACommandCompleteDMANoOptions);
                    OSSafeReleaseNULL(iv->a2h2DMA);
                }
                if (iv->h2a2DMA) {
                    iv->h2a2DMA->CompleteDMA(kIODMACommandCompleteDMANoOptions);
                    OSSafeReleaseNULL(iv->h2a2DMA);
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
                VBusFreeAll(iv);   // dext 143: the VBus buffers in use and retired (none unless VBus was on)
                OSSafeReleaseNULL(iv->a2hStreamMap);
                OSSafeReleaseNULL(iv->h2aStreamMap);
                OSSafeReleaseNULL(iv->a2hStreamBuffer);
                OSSafeReleaseNULL(iv->h2aStreamBuffer);
                OSSafeReleaseNULL(iv->a2hBuffer);
                OSSafeReleaseNULL(iv->h2aBuffer);
                OSSafeReleaseNULL(iv->a2hStream64Map);
                OSSafeReleaseNULL(iv->h2aStream64Map);
                OSSafeReleaseNULL(iv->a2hStream64Buffer);
                OSSafeReleaseNULL(iv->h2aStream64Buffer);
                OSSafeReleaseNULL(iv->a2h2DMAMap);
                OSSafeReleaseNULL(iv->h2a2DMAMap);
                OSSafeReleaseNULL(iv->a2h2Buffer);
                OSSafeReleaseNULL(iv->h2a2Buffer);
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

        // Fallback: no interrupt source — release everything synchronously.
        // Same early drain as step 8b above, before the audio objects go.
        if (ivars->xlinkQueue) {
            ivars->xlinkQueue->DispatchSync(^{});
        }
        if (ivars->audioDevice) {
            // Phase 7: symmetric teardown — every Add* balanced by its Remove* (see cancel-handler
            // path above). Missing Remove* leaves a child alive that retains the driver → orphan.
            if (ivars->inputStream)  ivars->audioDevice->RemoveStream(ivars->inputStream);
            if (ivars->outputStream) ivars->audioDevice->RemoveStream(ivars->outputStream);
            VBusRemoveStreams(ivars);   // dext 143: here, not under portPublishLock
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
            // Two-port experiment only (both null otherwise).
            for (uint32_t i = 0; i < 2; i++)
                if (ivars->portSourceControl[i]) ivars->audioDevice->RemoveControl(ivars->portSourceControl[i]);
            RemoveObject(ivars->audioDevice);
        }
        if (ivars->portPublishLock) IOLockLock(ivars->portPublishLock);
        VBusReleaseStreamsLocked(ivars);   // dext 143: references only; no call into the device under the lock
        for (uint32_t i = 0; i < 2; i++)
            OSSafeReleaseNULL(ivars->portSourceControl[i]);
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
        if (ivars->portPublishLock) IOLockUnlock(ivars->portPublishLock);
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
        ivars->port2AudioReady = false;   // two-port experiment only (null otherwise)
        if (ivars->a2h2DMA) {
            ivars->a2h2DMA->CompleteDMA(kIODMACommandCompleteDMANoOptions);
            OSSafeReleaseNULL(ivars->a2h2DMA);
        }
        if (ivars->h2a2DMA) {
            ivars->h2a2DMA->CompleteDMA(kIODMACommandCompleteDMANoOptions);
            OSSafeReleaseNULL(ivars->h2a2DMA);
        }
        ivars->meterDMAActive = false;
        ivars->meterWords = nullptr;
        if (ivars->meterDMA) {
            ivars->meterDMA->CompleteDMA(kIODMACommandCompleteDMANoOptions);
            OSSafeReleaseNULL(ivars->meterDMA);
        }
        OSSafeReleaseNULL(ivars->a2hDMAMap);
        OSSafeReleaseNULL(ivars->h2aDMAMap);
        VBusFreeAll(ivars);   // dext 143: the VBus buffers in use and retired (none unless VBus was on)
        OSSafeReleaseNULL(ivars->a2hStreamMap);
        OSSafeReleaseNULL(ivars->h2aStreamMap);
        OSSafeReleaseNULL(ivars->a2hStreamBuffer);
        OSSafeReleaseNULL(ivars->h2aStreamBuffer);
        OSSafeReleaseNULL(ivars->a2hBuffer);
        OSSafeReleaseNULL(ivars->h2aBuffer);
        OSSafeReleaseNULL(ivars->a2hStream64Map);
        OSSafeReleaseNULL(ivars->h2aStream64Map);
        OSSafeReleaseNULL(ivars->a2hStream64Buffer);
        OSSafeReleaseNULL(ivars->h2aStream64Buffer);
        OSSafeReleaseNULL(ivars->a2h2DMAMap);
        OSSafeReleaseNULL(ivars->h2a2DMAMap);
        OSSafeReleaseNULL(ivars->a2h2Buffer);
        OSSafeReleaseNULL(ivars->h2a2Buffer);
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
    STLOG("SetPowerState: flags=0x%08x → %{public}s", powerFlags, on ? "ON" : "OFF/LOW");
    if (ivars) {
        if (!on) {
            // A3: silence the card mixers while the card can still be reached.
            if (!__atomic_load_n(&ivars->stopping, __ATOMIC_ACQUIRE) && ivars->xlinkQueue &&
                HardwareReachable(ivars)) {
                ivars->xlinkQueue->DispatchSync(^{ SilenceCardMixersForSleep(ivars); });
                STLOG("SetPowerState: card mixers silenced for sleep");
            }
            // SEQ_CST pairs with the Dekker re-check in HardwareReachable().
            __atomic_store_n(&ivars->linkState, kLinkStateRecovering, __ATOMIC_RELEASE);
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
            ArmMicPreSettle(ivars);   // coreaudiod may restore controls after a wake
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
    // V3: coreaudiod's connection arrives here (at a cold boot and after a
    // coreaudiod restart); it may restore saved control values right after.
    if (type != kSymphonyUserClientType) ArmMicPreSettle(ivars);
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

// Unit B contributes the second 32 hardware-input strips only while the card
// is actually running 64 channels and the port-2 probe identified a Symphony
// I/O (Port2UnitIsSymphony: its DEVICE_TYPE answer). Converters keep their existing
// routing/mixer paths. Evidence: the original port-2 XLink probe and
// SymphonyPCIeCardMixer.cpp:1101-1130,1276-1330.
static bool CardMixerUnitBActive(const SymphonyThunderbridge_IVars *iv)
{
    if (!iv || iv->portCount != 2 || !iv->port2On ||
        __atomic_load_n(&iv->portMode, __ATOMIC_ACQUIRE) != 64 ||
        iv->port2UnitCount == 0)
        return false;
    const uint32_t flags = __atomic_load_n(&iv->port2Flags, __ATOMIC_ACQUIRE);
    return (flags & kSymphonyPort2FlagDataLinkUp) != 0 &&
           (iv->port2Unit[0] & kSymphonyPort2UnitAddressed) != 0 &&
           // Not the INQUIRE byte alone: a real unit's low nibble is its
           // firmware (0xF8 in report 6F64285E), never 0xFF.
           Port2UnitIsSymphony(iv->port2Unit[0]);
}

// A fader byte as the original read a fader: dB + 48, at or below -48 dB
// (byte 0) off, the range up to +6 dB (byte 54) (SymphonyPCIeCardMixer.cpp:
// 241-244, 691-692). Returns false for off.
static bool MixerFaderDb(uint8_t byte, int &db)
{
    if (byte == 0) return false;
    db = (int)(byte > 54 ? 54 : byte) - 48;
    return true;
}

// One input strip's left and right coefficients, as the original computed
// them (SymphonyPCIeCardMixer.cpp:1364-1430): fader + equal-power pan term +
// that side's Master, then the converter volume-key trim. Off when muted,
// soloed out, or the fader or that side's Master is at the bottom.
static void WriteMixerCoefPair(IOPCIDevice *dev, uint8_t mi,
                               uint64_t offL, uint64_t offR,
                               uint8_t fader, uint8_t pan, uint8_t masterL, uint8_t masterR,
                               bool play, int trim = 0)
{
    uint32_t cL = kMixerMuteCoeff, cR = kMixerMuteCoeff;
    int f = 0, mL = 0, mR = 0;
    if (play && MixerFaderDb(fader, f)) {
        const unsigned p = pan > 128 ? 128 : pan;
        if (MixerFaderDb(masterL, mL)) cL = SymphonyMixerCoef(f + mL - trim, 128 - p);
        if (MixerFaderDb(masterR, mR)) cR = SymphonyMixerCoef(f + mR - trim, p);
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
    const int inputCount = CardMixerUnitBActive(iv) ? 64 : 32;
    for (int c = 0; c < inputCount && !anySolo; c++)
        if (state.inputSoloed[c]) anySolo = true;

    // Converter volume keys: mixer 1 only, every source it carries, so the
    // mute key silences live inputs too. Zero and unmuted on a Symphony I/O.
    const bool keyTrim = mixerID == 1 &&
                         __atomic_load_n(&iv->converterVolumeKeys, __ATOMIC_ACQUIRE);
    const int trim = keyTrim ? (int)iv->converterTrimAtten : 0;
    const bool trimMuted = keyTrim && iv->converterTrimMuted;
    // Master mute is ours (the original had none): it silences the whole
    // mixer, inputs as well as the Software Return.
    bool rplay = !state.swReturnMuted && !state.masterMuted && !trimMuted &&
                 (!anySolo || state.swReturnSoloed);
    // Software Return: its fader + Master per side, no pan
    // (SymphonyPCIeCardMixer.cpp:1289-1318).
    uint32_t returnCoefL = kMixerMuteCoeff;
    uint32_t returnCoefR = kMixerMuteCoeff;
    int rL = 0, rR = 0, mL = 0, mR = 0;
    if (rplay && MixerFaderDb(state.swReturnLeftByte, rL) && MixerFaderDb(state.masterLeftByte, mL))
        returnCoefL = SymphonyMixerCoef(rL + mL - trim, 128);
    if (rplay && MixerFaderDb(state.swReturnRightByte, rR) && MixerFaderDb(state.masterRightByte, mR))
        returnCoefR = SymphonyMixerCoef(rR + mR - trim, 128);
    WriteRegister(dev, mi, MixerCoefOffset(physicalBase, 128), returnCoefL);
    WriteRegister(dev, mi, MixerCoefOffset(physicalBase + 1, 129), returnCoefR);

    // Fixed hardware inputs 0..31, plus unit B's XLink RX 32..63 at 64ch.
    for (int c = 0; c < inputCount; c++) {
        bool play = !state.inputMuted[c] && !trimMuted && !state.masterMuted &&
                    (!anySolo || state.inputSoloed[c]);
        WriteMixerCoefPair(dev, mi, MixerCoefOffset(physicalBase, c),
                           MixerCoefOffset(physicalBase + 1, c),
                           state.inputByte[c], state.inputPanByte[c],
                           state.masterLeftByte, state.masterRightByte, play, trim);
    }
}

// Put the converter volume-key trim on card mixer 1. When the app has sent
// mixer state, recompute from it; otherwise only the return slots carry audio
// (Start()'s unity defaults; the input coefficients are zero), so trim those.
// Start() before audio runs, or xlinkQueue.
static void ApplyConverterTrim(SymphonyThunderbridge_IVars *ivars)
{
    if (!ivars->pciDevice) return;
    if (ivars->mixerStateValid[0]) {
        RecomputeCardMixer(ivars, ivars->pciDevice, ivars->barMemoryIndex, 1);
        return;
    }
    const bool on = __atomic_load_n(&ivars->converterVolumeKeys, __ATOMIC_ACQUIRE);
    const uint32_t coef = (on && ivars->converterTrimMuted)
        ? kMixerMuteCoeff
        : SymphonyMixerCoef(-(on ? (int)ivars->converterTrimAtten : 0), 128);
    WriteRegister(ivars->pciDevice, ivars->barMemoryIndex, MixerCoefOffset(0, 128), coef);
    WriteRegister(ivars->pciDevice, ivars->barMemoryIndex, MixerCoefOffset(1, 129), coef);
}

// A3: before the Mac sleeps, every card-mixer coefficient goes to minus
// infinity, as the original did on sleep, shutdown and restart
// (SymphonyCard.cpp:1047-1076), so no mixer output makes a sound as the link
// goes away. On xlinkQueue, with the card reachable.
static void SilenceCardMixersForSleep(SymphonyThunderbridge_IVars *ivars)
{
    if (!ivars->pciDevice) return;
    for (uint64_t off = 0; off < 0x1000; off += 4)
        WriteRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegMixerCoeff + off, 0);
    ivars->mixersSilencedForSleep = true;
}

// A3, at wake: each mixer back to the app's state, or to Start()'s unity
// defaults if the app never set it (the same choice as the card re-init).
static void RestoreCardMixersAfterSleep(SymphonyThunderbridge_IVars *ivars)
{
    if (!ivars->mixersSilencedForSleep || !ivars->pciDevice) return;
    ivars->mixersSilencedForSleep = false;
    for (uint16_t mixerID = 1; mixerID <= 2; mixerID++) {
        if (ivars->mixerStateValid[mixerID - 1]) {
            RecomputeCardMixer(ivars, ivars->pciDevice, ivars->barMemoryIndex, mixerID);
        } else if (mixerID == 1 && __atomic_load_n(&ivars->converterVolumeKeys, __ATOMIC_ACQUIRE)) {
            ApplyConverterTrim(ivars);
        } else {
            const uint32_t bank = (mixerID == 1) ? 0 : 2;
            WriteRegister(ivars->pciDevice, ivars->barMemoryIndex, MixerCoefOffset(bank,     128), kMixerUnityCoeff);
            WriteRegister(ivars->pciDevice, ivars->barMemoryIndex, MixerCoefOffset(bank + 1, 129), kMixerUnityCoeff);
        }
    }
    STLOG("Wake: card mixers restored after sleep");
}

// ── SendVendorCommand ───────────────────────────────────────────────────────
// Public wrapper around the static SendVendorRequest() for vendor commands.
// Called by SymphonyUserClient::ExternalMethod.

// MicPre8 is a companion to the analog board, not a capture source of its
// own. Resolve host -> card RX -> unit P2P -> analog channel without I/O.
// Evidence: og_source/maestrolink/Software/SymphonyIOBoard_MicPre8ch.cpp:337-361.
static bool ResolveMicPreRoute(SymphonyThunderbridge_IVars *iv, uint32_t host,
                               uint32_t &port, uint32_t &channel)
{
    if (!iv || host >= 64) return false;
    port = 0; channel = host;
    // Preserve the historical direct entry point when no HAL preamp controls
    // exist. Once routing is edited it must obey the same resolver as HAL.
    // dext 150: host input n is no longer slot 1 channel n (analog first:
    // with slot 1 empty, an A16 OP or a 2x6, host input 1-8 carry slot 2's
    // or digital channels), so it goes through unit A's capture table and
    // the analog check too (SymphonyMicPreChannelForSource), skipping only
    // the card route. With slot 1's type unread the table is the fixed
    // 16 + 16, so this is still channel n then.
    // The source comes from the table actually programmed (inputRouteSource
    // follows channelOrderLatch); whether that board channel is an analog
    // input is a property of the card fitted, so the check below uses the
    // fitted type (optionBoardType, read after the configuration), as does
    // numMicChannels, rather than the type the table was built from.
    if (!iv->numMicChannels && !__atomic_load_n(&iv->preampRoutingEdited, __ATOMIC_ACQUIRE) && host < 8)
        return SymphonyMicPreChannelForSource(__atomic_load_n(&iv->inputRouteSource[host], __ATOMIC_ACQUIRE),
                                              iv->optionBoardType[0], iv->optionBoardTypeValid[0],
                                              iv->namingCoaxReplace[0], &channel);
    const uint32_t word = __atomic_load_n(&iv->cardInputRoute[host], __ATOMIC_ACQUIRE);
    const uint32_t rx = word & 0xFFu;
    if (!(word & kRoutingEnable) || rx >= 64) return false;
    port = rx / 32;
    if (port && (!iv->unitBConfigured || !CardMixerUnitBActive(iv))) return false;
    const uint8_t source = port
        ? __atomic_load_n(&iv->unitBInputRouteSource[rx % 32], __ATOMIC_ACQUIRE)
        : __atomic_load_n(&iv->inputRouteSource[rx], __ATOMIC_ACQUIRE);
    // Slot 1's analog inputs 1-8 only: a source on board 0 channel 3-8 of a
    // 2x6 is its AES or optical input, and every input of an A16 OP is
    // optical, never a preamp (SymphonyMicPreChannelForSource).
    if (!SymphonyMicPreChannelForSource(source,
                                        port ? iv->unitBBoardType[0] : iv->optionBoardType[0],
                                        port ? iv->unitBBoardValid[0] : iv->optionBoardTypeValid[0],
                                        port ? iv->unitBCoaxReplace[0] : iv->namingCoaxReplace[0],
                                        &channel))
        return false;
    return port ? (iv->unitBBoardValid[1] && iv->unitBBoardType[1] == kSIOOptionBoard_MicPre8)
                : iv->numMicChannels > channel;
}

// AudioDriverKit's public IOUserAudioLevelControl API (SDK 25.2) fixes the
// range at init; there is no range setter. Keep 0..85 so a channel initially
// in Instrument mode can later reach Mic 85. Clamp the value to its active
// stage and use SetDecibelValue, whose successful changes notify the host.
// This cannot change HAL's advertised range/scalar conversion after a switch.
// Evidence: og_source/maestrolink/Software/SymphonyIOBoard_MicPre8ch.cpp:797-828.
// Called only on xlinkQueue; publishing must not send another hardware write.
static void PublishMicGain(SymphonyThunderbridge_IVars *iv, uint32_t ch, uint32_t port = 0)
{
    if (ch >= 8 || !(port ? __atomic_load_n(&iv->unitBMicPreTypeKnown[ch], __ATOMIC_ACQUIRE) :
        __atomic_load_n(&iv->micPreTypeKnown[ch], __ATOMIC_ACQUIRE))) return;
    const bool instrument = port ? __atomic_load_n(&iv->unitBMicPreInstrument[ch], __ATOMIC_ACQUIRE) :
        __atomic_load_n(&iv->micPreInstrument[ch], __ATOMIC_ACQUIRE);
    const uint32_t lane = instrument ? 1 : 0;
    for (uint32_t host = 0; host < iv->numMicChannels; ++host) {
        uint32_t targetPort = 0, targetChannel = 0;
        if (!iv->micGainControl[host] || !ResolveMicPreRoute(iv, host, targetPort, targetChannel) ||
            targetPort != port || targetChannel != ch) continue;
        const bool known = port ? iv->unitBMicPreGainKnown[lane][ch] : iv->micPreGainKnown[lane][ch];
        float gain = known ? (port ? iv->unitBMicPreGain[lane][ch] : iv->micPreGain[lane][ch])
                           : iv->micGainControl[host]->GetDecibelValue();
        const float maximum = instrument ? 65.0f : kMicGainMaxDb;
        if (gain > maximum) gain = maximum;
        if (gain < kMicGainMinDb) gain = kMicGainMinDb;
        iv->micGainControl[host]->SetDecibelValue(gain);
    }
}

static void PublishMicPreControls(SymphonyThunderbridge_IVars *iv, uint32_t port, uint32_t ch)
{
    if (!iv || ch >= 8 || !iv->audioDevice) return;
    const uint32_t count = iv->numMicChannels;
    for (uint32_t host = 0; host < count; ++host) {
        uint32_t p = 0, c = 0;
        if (!ResolveMicPreRoute(iv, host, p, c) || p != port || c != ch) continue;
        if (iv->phaseControl[host]) iv->phaseControl[host]->SetControlValue(iv->micPrePhase[port][ch]);
        if (iv->highPassControl[host]) {
            IOUserAudioSelectorValue v = iv->micPreHighPass[port][ch] ? 1 : 0;
            iv->highPassControl[host]->SetCurrentSelectedValues(&v, 1);
        }
        if (iv->inputTypeControl[host]) {
            IOUserAudioSelectorValue v = WireInputTypeToCore(iv->micPreType[port][ch]);
            iv->inputTypeControl[host]->SetCurrentSelectedValues(&v, 1);
        }
    }
}

// Host-only observation entry. No vendor command fallback on older drivers.
kern_return_t SymphonyThunderbridge::PublishObservedMicGain(
    uint32_t port, uint32_t channel, uint32_t lane, uint32_t gain)
{
    if (port > 1 || channel >= 8 || lane > 1 || gain > (lane ? 65u : 85u))
        return kIOReturnBadArgument;
    if (!ivars || !ivars->xlinkQueue) return kIOReturnNotReady;
    __block kern_return_t result = kIOReturnNotReady;
    ivars->xlinkQueue->DispatchSync(^{
        // This entry never touches PCI: use lifecycle state without the
        // HardwareReachable config-space probe used before real XLink IO.
        if (__atomic_load_n(&ivars->txShutdown, __ATOMIC_ACQUIRE) ||
            __atomic_load_n(&ivars->stopping, __ATOMIC_ACQUIRE) ||
            __atomic_load_n(&ivars->providerPowerOff, __ATOMIC_ACQUIRE) ||
            __atomic_load_n(&ivars->hwSuspended, __ATOMIC_ACQUIRE) ||
            !ivars->pciDevice || ivars->convPort1 ||
            (port && (!ivars->unitBConfigured || !CardMixerUnitBActive(ivars)))) return;
        if (port ? (!ivars->unitBBoardValid[1] || ivars->unitBBoardType[1] != kSIOOptionBoard_MicPre8)
                 : channel >= ivars->numMicChannels) return;
        // The front panel moved this gain: an unread DAW gain is now stale,
        // whether or not the driver knows the stage (a failed 0x60 read).
        ClearHalMicPreEdit(ivars, port, channel, kMicPreEditGainValid);
        const bool known = port ? ivars->unitBMicPreTypeKnown[channel] : ivars->micPreTypeKnown[channel];
        const bool instrument = port ? ivars->unitBMicPreInstrument[channel] : ivars->micPreInstrument[channel];
        if (!known || lane != (instrument ? 1u : 0u)) return;
        (port ? ivars->unitBMicPreGain[lane][channel] : ivars->micPreGain[lane][channel]) = gain;
        (port ? ivars->unitBMicPreGainKnown[lane][channel] : ivars->micPreGainKnown[lane][channel]) = true;
        // Routed aliases receive SetDecibelValue only, never HandleChange or TX.
        // og_source/maestrolink/Software/SymphonyIOBoard_MicPre8ch.cpp:246,323.
        PublishMicGain(ivars, channel, port);
        result = kIOReturnSuccess;
    });
    return result;
}

kern_return_t SymphonyThunderbridge::SendVendorCommand(
    uint8_t         command,
    uint32_t        value,
    const uint8_t  *payload,
    uint16_t        payloadLen,
    uint8_t         port)
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
    __block bool namesChanged = false;
    q->DispatchSync(^{
        if (!XLinkTxAdmissible(ivars)) {
            STERR("SendVendorCommand: TX shut down / stopping — not sending");
            result = kIOReturnNotReady;
            return;
        }

        if (port > 1) { result = kIOReturnBadArgument; return; }
        if (port == 1 && (!ivars->unitBConfigured || ivars->portMode != 64)) {
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
            // Every software pair of the ports in use, as the original
            // (SymphonyCard.cpp:739-753): 32 at 64 channels with a second
            // Symphony I/O or converters on port 2.
            const bool port2Pairs = CardMixerUnitBActive(ivars) ||
                (ivars->port2On && __atomic_load_n(&ivars->portMode, __ATOMIC_ACQUIRE) == 64 &&
                 (__atomic_load_n(&ivars->convFlags, __ATOMIC_ACQUIRE) & kSymphonyConvPort2Converters) != 0);
            const bool sourceOK = IsThunderboltSoftwareReturnSource(source) ||
                                  (port2Pairs && IsThunderboltSoftwareReturnSource64(source));
            if (element == 0 && mixerID >= 1 && mixerID <= 2 && sourceOK) {
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
        // dext 131: with converters on port 1 the card routing follows their
        // placement (ApplyConverterRouting); a Symphony I/O output route from
        // the app would undo it.
        // dext 131: with converters the card routing is theirs to edit, both
        // ways and on both ports (SymphonyCardMixerRouting.h).
        {
            const bool p2conv = (__atomic_load_n(&ivars->convFlags, __ATOMIC_ACQUIRE) & kSymphonyConvPort2Converters) != 0;
            const bool conv = ivars->convPort1 || p2conv;
            if (!conv && (command == kThunderboltConverterRoutingResetCommand ||
                          command == kThunderboltCardInputRouteCommand)) {
                // The source peripheral port is independent of the software destination.
                // Evidence: og_source/maestrolink/Software/SymphonyPCIeRoutingController.cpp:976-1069,1860-1888.
                if (!ivars->symphonyLinkConfigured) {
                    result = kIOReturnNotReady;
                    return;
                }
                const bool unitB = ivars->unitBConfigured && CardMixerUnitBActive(ivars);
                const uint32_t channels = unitB ? 64 : 32;
                if (command == kThunderboltCardInputRouteCommand) {
                    if (!payload || payloadLen != 3 || payload[0] >= channels || payload[1] >= channels) {
                        result = kIOReturnBadArgument;
                        return;
                    }
                    __atomic_store_n(&ivars->preampRoutingEdited, true, __ATOMIC_RELEASE);
                    WriteCardInputRoute(ivars, payload[0], (kTDM_XLinkRX0 + payload[1]) |
                                        (payload[2] ? kRoutingEnable : 0u));
                    PublishAllMicPreControls(ivars);
                } else {
                    for (uint32_t n = 0; n < 64; n++)
                        WriteCardInputRoute(ivars, n, (kTDM_XLinkRX0 + n) |
                                            (n < channels ? kRoutingEnable : 0u));
                    PublishAllMicPreControls(ivars);
                }
                namesChanged = true;
                result = kIOReturnSuccess;
                return;
            }
            if (conv && command == kThunderboltConverterRoutingResetCommand) {
                ivars->convOutRouteSet = 0;
                ivars->convInRouteSet = 0;
                ApplyConverterRouting(ivars, "Reset Routing");
                result = kIOReturnSuccess;
                return;
            }
            // A Symphony I/O on port 1 with converters on port 2: port 1's output
            // routes (0-31) are the Symphony grid's and take the normal path below.
            const bool symphonyEntry = !ivars->convPort1 && command == kThunderboltCardOutputRouteCommand &&
                                       payload && payloadLen == 3 && payload[0] < 32;
            if (conv && !symphonyEntry &&
                (command == kThunderboltCardOutputRouteCommand || command == kThunderboltCardInputRouteCommand)) {
                const bool in = command == kThunderboltCardInputRouteCommand;
                // Entries a converter port owns: 0-31 with converters on port 1,
                // 32-63 while port 2 carries converters.
                const uint32_t lo = ivars->convPort1 ? 0 : 32, hi = p2conv ? 64 : 32;
                if (!payload || payloadLen != 3 || payload[0] < lo || payload[0] >= hi ||
                    (in && payload[1] >= 64)) {
                    STERR("Converter route: bad request cmd=0x%02x payload=%u entry=%u", command, payloadLen,
                          payload ? payload[0] : 0xFF);
                    result = kIOReturnBadArgument;
                    return;
                }
                const uint8_t entry = payload[0];
                const uint32_t word = (in ? (kTDM_XLinkRX0 + payload[1]) : payload[1]) | (payload[2] ? kRoutingEnable : 0u);
                if (in) { ivars->convInRoute[entry] = word; ivars->convInRouteSet |= 1ull << entry; }
                else    { ivars->convOutRoute[entry] = word; ivars->convOutRouteSet |= 1ull << entry; }
                WriteRegister(ivars->pciDevice, ivars->barMemoryIndex,
                              (in ? kRegInputRouting : kRegOutputRouting) + entry * 4, word);
                STLOG("Converter route: %{public}s %u <- %{public}s %u (%{public}s)",
                      in ? "host input" : "XLink TX", entry, in ? "XLink RX" : "TDM slot", payload[1],
                      payload[2] ? "enabled" : "disabled");
                result = kIOReturnSuccess;
                return;
            }
        }
        if (command == kThunderboltCardOutputRouteCommand) {
            if (!payload || payloadLen != 3 ||
                payload[0] >= kThunderboltCardOutputChannels ||
                (payload && payload[0] >= kPort2FirstChannel && !CardMixerUnitBActive(ivars))) {
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
            STLOG("Card output route: XLink TX %u ← TDM slot %u (%{public}s)",
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
                              ch < (CardMixerUnitBActive(ivars) ? 64 : 32));
            if ((mixerID == 1 || mixerID == 2) && isMixerCmd && isMixerCh && payload && payloadLen >= 1) {
                ThunderboltMixerState &state = ivars->mixer[mixerID - 1];
                uint8_t p0 = payload[0];
                if (ch == kMixerChSwReturn) {
                    if      (command == kSIOCmd_MixerFaderLevel) {
                        state.swReturnLeftByte = (p0 > 54) ? 54 : p0;
                        state.swReturnRightByte = (p0 > 54) ? 54 : p0;
                    }
                    else if (command == kSIOCmd_MixerInputPan)
                        state.swReturnPanByte = (p0 > 128) ? 128 : p0;
                    else if (command == kSIOCmd_MixerInputSolo)  state.swReturnSoloed  = (p0 != 0);
                    else                                         state.swReturnMuted   = (p0 != 0);
                } else if (ch == kMixerChMaster) {
                    if      (command == kSIOCmd_MixerFaderLevel) {
                        state.masterLeftByte = (p0 > 54) ? 54 : p0;
                        state.masterRightByte = (p0 > 54) ? 54 : p0;
                    }
                    else if (command == kSIOCmd_MixerInputMute)  state.masterMuted = (p0 != 0);
                    // Master pan/solo not applicable.
                } else if (ch == kMixerChSwReturnLeft || ch == kMixerChSwReturnRight) {
                    if (command == kSIOCmd_MixerFaderLevel) {
                        uint8_t level = (p0 > 54) ? 54 : p0;
                        if (ch == kMixerChSwReturnLeft) state.swReturnLeftByte = level;
                        else state.swReturnRightByte = level;
                    }
                } else if (ch == kMixerChMasterLeft || ch == kMixerChMasterRight) {
                    if (command == kSIOCmd_MixerFaderLevel) {
                        uint8_t level = (p0 > 54) ? 54 : p0;
                        if (ch == kMixerChMasterLeft) state.masterLeftByte = level;
                        else state.masterRightByte = level;
                    }
                } else { // hardware-input strip 0..31
                    if      (command == kSIOCmd_MixerFaderLevel) state.inputByte[ch]    = (p0 > 54) ? 54 : p0;
                    else if (command == kSIOCmd_MixerInputPan)   state.inputPanByte[ch] = (p0 > 128) ? 128 : p0;
                    else if (command == kSIOCmd_MixerInputSolo)  state.inputSoloed[ch]  = (p0 != 0);
                    else                                         state.inputMuted[ch]   = (p0 != 0);
                }
                // Recompute only the selected physical stereo mixer; the two
                // logical banks must remain independent like the legacy PCIe
                // driver.
                __atomic_store_n(&ivars->mixerStateValid[mixerID - 1], true, __ATOMIC_RELEASE);
                RecomputeCardMixer(ivars, ivars->pciDevice,
                                   ivars->barMemoryIndex, mixerID);
                STLOG("Card mixer: mixer=%u ch=%u cmd=0x%02x val=%u → recomputed",
                      mixerID, ch, command, p0);
                result = kIOReturnSuccess;
                return;
            }
            // dext 131 review: a card-mixer command (mixer 1/2) the card does not
            // take (a unit-B strip 33-64 left over after going back to 32) is
            // refused, never forwarded to unit A as a vendor message.
            if ((mixerID == 1 || mixerID == 2) && isMixerCmd) {
                result = kIOReturnBadArgument;
                return;
            }
        }

        // dext 131: a ClockMode for unit A (e.g. a card input as the clock,
        // sent by the app on this path) keeps its Loop Sync output on while
        // unit B follows it, and is remembered so leaving two-unit mode keeps
        // the source. Loop Sync as unit A's source is refused then.
        uint8_t clockCopy[4];
        const uint8_t *sendPayload = payload;
        if (ivars->unitBConfigured && command == kSIOCmd_ClockMode) {
            const bool enabled = !(ivars->loopSyncConfig & 1);
            const unsigned master = enabled && (ivars->loopSyncConfig & 2) ? 1 : 0;
            if (!payload || payloadLen != 4 || port != master || payload[0] == 3) {
                result = kIOReturnUnsupported;
                return;
            }
            memcpy(clockCopy, payload, 4);
            clockCopy[1] = 1; clockCopy[2] = enabled ? 1 : 0;
            sendPayload = clockCopy;
            if (port) {
                memcpy(ivars->unitBMasterClock, payload, 4);
                ivars->unitBMasterClockKnown = true;
                ivars->unitBClockSource = payload[0];
            } else {
                memcpy(ivars->unitAClock, payload, 4);
                ivars->unitAClockKnown = true;
            }
        } else if (port == 0 && command == kSIOCmd_ClockMode && payload && payloadLen == 4) {
            if (ivars->unitBConfigured && payload[0] == 3) {
                STLOG("SendVendorCommand: Loop Sync refused for unit A while unit B follows it");
                result = kIOReturnUnsupported;
                return;
            }
            memcpy(clockCopy, payload, 4);
            if (ivars->unitBConfigured && clockCopy[1] == 1) clockCopy[2] = 1;
            ApplyOneUnitLoopSyncByte(ivars, clockCopy);
            memcpy(ivars->unitAClock, payload, 4);
            ivars->unitAClockKnown = true;
            sendPayload = clockCopy;
        }
        // dext 131: Symphony I/O vendor messages never go to converters (the
        // original sent them to Symphony I/O units only).
        if (port == 0 && ivars->convPort1) {
            STLOG("SendVendorCommand: cmd=0x%02x not sent — port 1 carries converters", command);
            result = kIOReturnUnsupported;
            return;
        }
        // N4: whether this MicPre channel was already in Mic before Maestro's
        // 0x20, read before the hooks below record the new type.
        const bool micPreTypeWrite = command == kSIOCmd_AnalogReferenceLevel && payload &&
            payloadLen == 2 && (value & 0xFFFFFFF8u) == 0x80000000u;
        const bool micPreWasMic = micPreTypeWrite &&
            MicPreTypeKnownOn(ivars, port, value & 7u) && ivars->micPreType[port][value & 7u] == 3;
        const uint64_t tx = port ? kRegXLink2TX : kRegXLink1TX;
        uint8_t &seq = port ? ivars->runtimeTxSeq2 : ivars->runtimeTxSeq;
        bool ok = SendVendorRequestOn(ivars->pciDevice, ivars->barMemoryIndex, tx,
                                      port ? 1 : ivars->symphonyAddr, command, value,
                                      sendPayload, payloadLen, seq);
        // dext 152: what unit A holds now, for the same-value skip.
        if (port == 0 && command == kSIOCmd_ClockMode) {
            if (ivars->unitBConfigured || payloadLen != 4) ivars->unitAClockSentKnown = false;
            else NoteUnitAClockSent(ivars, sendPayload, ok);
        } else if (port == 0 && command == kSIOCmd_OpticalFormat && value < 2) {
            ivars->opticalSentKnown[value] = false;
        }
        if (!ok) {
            if (ivars->unitBConfigured && command == kSIOCmd_ClockMode) ivars->loopSyncValid = false;
            STERR("SendVendorCommand: failed cmd=0x%02x value=0x%08x payload=%u",
                  command, value, payloadLen);
            result = kIOReturnIOError;
            return;
        }
        // Maestro's own 0xC6 ON supersedes any older unread HAL OFF receipt on
        // this same serialized XLink lane. Without this ordering, the next
        // observation tick could erase the later explicit ON from saved state.
        if (command == kSIOCmd_PhantomPower && payload && payloadLen == 1 &&
            payload[0] != 0 && value < 8) {
            __atomic_store_n(&ivars->halPhantomOff[port * 8 + value], 0, __ATOMIC_RELEASE);
        }
        if (port == 1 && command == kSIOCmd_AnalogReferenceLevel && payload &&
            payloadLen == 2 && payload[0] <= 4 && (value & 0xFFFFFFF8u) == 0x80000000u) {
            __atomic_store_n(&ivars->unitBMicPreInstrument[value & 7u], payload[0] == 4, __ATOMIC_RELEASE);
            __atomic_store_n(&ivars->unitBMicPreMic[value & 7u], payload[0] == 3, __ATOMIC_RELEASE);
            __atomic_store_n(&ivars->unitBMicPreTypeKnown[value & 7u], true, __ATOMIC_RELEASE);
            ivars->micPreType[1][value & 7u] = payload[0];
            PublishMicGain(ivars, value & 7u, 1);
            PublishMicPreControls(ivars, 1, value & 7u);
        }
        if (port == 1 && (command == kSIOCmd_MicGain || command == kSIOCmd_InstrumentGain) &&
            value < 8 && payload && payloadLen == 1) {
            const uint32_t lane = command == kSIOCmd_InstrumentGain ? 1 : 0;
            ivars->unitBMicPreGain[lane][value] = payload[0];
            ivars->unitBMicPreGainKnown[lane][value] = true;
            PublishMicGain(ivars, value, 1);
        }
        // Each unit owns its preamp state; publish only to HAL elements that
        // currently resolve to that unit. Only retain successfully sent types.
        // Evidence: og_source/maestrolink/Software/SymphonyIOBoard_MicPre8ch.cpp:797-828.
        if (port == 0 && command == kSIOCmd_AnalogReferenceLevel && payload &&
            payloadLen == 2 && payload[0] <= 4 && (value & 0xFFFFFFF8u) == 0x80000000u) {
            __atomic_store_n(&ivars->micPreInstrument[value & 7u], payload[0] == 4, __ATOMIC_RELEASE);
            __atomic_store_n(&ivars->micPreMic[value & 7u], payload[0] == 3, __ATOMIC_RELEASE);
            __atomic_store_n(&ivars->micPreTypeKnown[value & 7u], true, __ATOMIC_RELEASE);
            ivars->micPreType[0][value & 7u] = payload[0];
            PublishMicGain(ivars, value & 7u);
            PublishMicPreControls(ivars, 0, value & 7u);
        }
        // Maestro's own MicPre writes: keep what the unit took, and clear any
        // older unread HAL edit of the same field so it cannot overwrite this
        // later choice in Maestro's saved state (as for 0xC6 ON above).
        if (port <= 1 && command == kSIOCmd_AnalogReferenceLevel && payload && payloadLen == 2 &&
            payload[0] <= 4 && (value & 0xFFFFFFF8u) == 0x80000000u) {
            // A Maestro Mic authorises phantom at once, except over a channel
            // that was already in Mic: that is Maestro replaying a HAL Mic it
            // saved, which must not cut the arm delay short.
            if (!(payload[0] == 3 && micPreWasMic))
                __atomic_store_n(&ivars->halMicTypeStamp[port][value & 7u], 0, __ATOMIC_RELEASE);
            ClearHalMicPreEdit(ivars, port, value & 7u, kMicPreEditTypeValid);
            RecordMicPreTrim(ivars, port, value & 7u, payload[0], payload[1]);
        }
        if (port <= 1 && (command == kSIOCmd_MicGain || command == kSIOCmd_InstrumentGain) &&
            payload && payloadLen == 1 && value < 8)
            ClearHalMicPreEdit(ivars, port, value, kMicPreEditGainValid);
        if (port <= 1 && command == kSIOCmd_Insert && payload && payloadLen == 1 && value < 8) {
            ivars->micPreInsertMask[port][value] = payload[0];
            ivars->micPreInsertMaskKnown[port][value] = true;
            // Maestro assigned the insert again: the HAL release is old news.
            for (uint32_t ch = 0; ch < 8; ++ch)
                if (payload[0] & (1u << ch)) ClearHalMicPreEdit(ivars, port, ch, kMicPreEditInsertOff);
        }
        if (port <= 1 && command == kSIOCmd_InsertEnable && payload && payloadLen == 1 && value < 8)
            ClearHalMicPreEdit(ivars, port, value, kMicPreEditInsertOff);
        if (port <= 1 && command == kSIOCmd_PhaseInverse && payload && payloadLen == 1 && value < 8) {
            ivars->micPrePhase[port][value] = payload[0] != 0;
            ivars->micPrePhaseKnown[port][value] = true;
            ClearHalMicPreEdit(ivars, port, value, kMicPreEditPhaseValid);
            PublishMicPreControls(ivars, port, value);
        }
        if (port <= 1 && command == kSIOCmd_HighPassFilter && payload && payloadLen == 1 && value < 8) {
            ivars->micPreHighPass[port][value] = payload[0] != 0;
            ivars->micPreHighPassKnown[port][value] = true;
            ClearHalMicPreEdit(ivars, port, value, kMicPreEditHighPassValid);
            PublishMicPreControls(ivars, port, value);
        }
        if (port == 0 && (command == kSIOCmd_MicGain || command == kSIOCmd_InstrumentGain) &&
            value < ivars->numMicChannels && payload && payloadLen == 1) {
            const uint32_t lane = command == kSIOCmd_InstrumentGain ? 1 : 0;
            ivars->micPreGain[lane][value] = payload[0];
            ivars->micPreGainKnown[lane][value] = true;
            if (lane == (__atomic_load_n(&ivars->micPreInstrument[value], __ATOMIC_ACQUIRE) ? 1u : 0u))
                PublishMicGain(ivars, value);
        }
        if (payload && payloadLen == 1) {
            // A level or mute set elsewhere (Maestro's knobs): kept per output,
            // and shown on the controls when it is the keys' output.
            const bool speaker = command == kSIOCmd_SpeakerVolume || command == kSIOCmd_SpeakerMute;
            const bool headphone = (command == kSIOCmd_HeadphoneVolume || command == kSIOCmd_HeadphoneMute) && value <= 1;
            if (speaker || headphone) {
                const bool b = port == 1;
                const unsigned kind = speaker ? 0 : value + 1;
                if (command == kSIOCmd_SpeakerVolume || command == kSIOCmd_HeadphoneVolume) {
                    MonitorAttenuation(ivars, b, kind) = payload[0];
                    if (!b && kind == 0 && !__atomic_load_n(&ivars->lineMode, __ATOMIC_ACQUIRE))
                        ivars->speakerLevelKnown = true;
                } else {
                    MonitorMute(ivars, b, kind) = payload[0] != 0;
                }
                if (b == ivars->monitorDeviceB && SelectedMonitorKind(ivars, b) == kind) PublishSelectedMonitor(ivars);
            }
        }
        // Host input names follow the capture routes and S/PDIF Coax Replaces.
        // Each unit owns its own P2P table and naming state. The card route
        // decides which host inputs carry that unit, including duplicates.
        if (port == 1) {
            if (command == kSIOCmd_AudioRouting) {
                uint8_t sources[32];
                for (uint32_t n = 0; n < 32; n++)
                    sources[n] = __atomic_load_n(&ivars->unitBInputRouteSource[n], __ATOMIC_ACQUIRE);
                if (SymphonyNoteInputRoutes(sources, payload, payloadLen)) {
                __atomic_store_n(&ivars->preampRoutingEdited, true, __ATOMIC_RELEASE);
                    for (uint32_t n = 0; n < 32; n++)
                        __atomic_store_n(&ivars->unitBInputRouteSource[n], sources[n], __ATOMIC_RELEASE);
                    namesChanged = true;
                    PublishAllMicPreControls(ivars);
                }
            } else if (command == kSymphonyCmdPrefix && payload && payloadLen == 1 &&
                SymphonyIsPrefixLetter(payload[0]) && ivars->unitBPrefix != payload[0]) {
                ivars->unitBPrefix = payload[0];
                namesChanged = true;
            } else if (command == kSIOCmd_OpticalFormat && value < 2 && payload && payloadLen >= 1) {
                ivars->unitBOptical[value] = payload[0];
                namesChanged = true;
            } else if (command == kSIOCmd_SPDIFCoaxReplaceInput && value < 2 && payload && payloadLen >= 1) {
                ivars->unitBCoaxReplace[value] = payload[0];
                namesChanged = true;
                PublishAllMicPreControls(ivars);
            }
        } else if (command == kSIOCmd_AudioRouting) {
            uint8_t sources[32];
            for (uint32_t n = 0; n < 32; n++)
                sources[n] = __atomic_load_n(&ivars->inputRouteSource[n], __ATOMIC_ACQUIRE);
            if (SymphonyNoteInputRoutes(sources, payload, payloadLen)) {
                __atomic_store_n(&ivars->preampRoutingEdited, true, __ATOMIC_RELEASE);
                for (uint32_t n = 0; n < 32; n++)
                    __atomic_store_n(&ivars->inputRouteSource[n], sources[n], __ATOMIC_RELEASE);
                namesChanged = true;
                PublishAllMicPreControls(ivars);
            }
        } else if (command == kSIOCmd_SPDIFCoaxReplaceInput && value < 2 && payload && payloadLen >= 1) {
            __atomic_store_n(&ivars->namingCoaxReplace[value], payload[0], __ATOMIC_RELEASE);
            NoteCoaxBoardType(ivars, value);
            namesChanged = true;
            PublishAllMicPreControls(ivars);
        } else if (command == kSymphonyCmdPrefix && payload && payloadLen == 1 &&
                   SymphonyIsPrefixLetter(payload[0])) {
            // The app's Peripheral Prefix, written to the unit as the daemon did.
            if (__atomic_exchange_n(&ivars->namingPrefix, payload[0], __ATOMIC_ACQ_REL) != payload[0])
                namesChanged = true;
        } else if (command == kSIOCmd_SPDIFCoaxMirrorOutput && value < 2 && payload && payloadLen >= 1) {
            // Kept so a link recovery can put it back.
            __atomic_store_n(&ivars->sessionCoaxMirror[value], payload[0], __ATOMIC_RELEASE);
            NoteCoaxBoardType(ivars, value);
        }
        // The speaker mode decides whether the speakers can be moved by the
        // keys (Off, i.e. Line: they cannot). Once the app has chosen the
        // keys' output (SetMonitorOutput) the mode never changes it.
        // Remembered only after the hardware mode write succeeded.
        if ((port == 0 || port == 1) && command == kSIOCmd_SpeakerMode && payload && payloadLen >= 1 &&
            !__atomic_load_n(&ivars->converterVolumeKeys, __ATOMIC_ACQUIRE)) {
            const bool line = payload[0] == 0;
            if (port == 1) {
                __atomic_store_n(&ivars->unitBLineMode, line, __ATOMIC_RELEASE);
            } else {
                const bool wasLine = __atomic_load_n(&ivars->lineMode, __ATOMIC_ACQUIRE);
                __atomic_store_n(&ivars->lineMode, line, __ATOMIC_RELEASE);
                // Out of Line with the speakers' level not known (Maestro
                // started in Line): read it once now. The unit puts the level
                // it kept aside back when it leaves Line; give it the time it
                // takes (about 300 ms, measured from the app on 2026-11-21).
                if (wasLine && !line && !ivars->speakerLevelKnown) {
                    IOSleep(300);
                    if (ReadUnitAMonitorLevel(ivars, kSymphonyMonitorOutputSpeakers))
                        STLOG("Monitor: unit=A speaker level read after leaving Line: atten=%u mute=%u",
                              ivars->speakerAttenuation, ivars->speakerMute ? 1 : 0);
                }
            }
            // Until the app has chosen the output (monitorOutputChosen), it
            // follows the mode, as builds up to 141 did.
            if (!ivars->monitorOutputChosen[port])
                (port ? ivars->unitBMonitorOutputTarget : ivars->monitorOutputTarget) =
                    line ? kSymphonyMonitorOutputHP1 : kSymphonyMonitorOutputSpeakers;

            if ((port == 1) == ivars->monitorDeviceB) PublishSelectedMonitor(ivars);
            STLOG("Monitor: unit=%{public}s speaker mode=%u%{public}s", port ? "B" : "A",
                  payload[0], line ? " (Line: the keys do not move the speakers)" : "");
        }
        result = kIOReturnSuccess;
    });
    if (namesChanged) ScheduleChannelNames(ivars, this);
    return result;
}

// One of unit A's outputs (kSymphonyMonitorOutput*): its level and mute, read
// from the unit into the session state. On xlinkQueue.
static bool ReadUnitAMonitorLevel(SymphonyThunderbridge_IVars *ivars, uint32_t output)
{
    const unsigned kind = output == kSymphonyMonitorOutputHP1 ? 1 : (output == kSymphonyMonitorOutputHP2 ? 2 : 0);
    // The speakers in Line: the unit answers 0. Nothing is read or changed.
    if (kind == 0 && __atomic_load_n(&ivars->lineMode, __ATOMIC_ACQUIRE)) return true;
    uint8_t level = 0, mute = 0;
    if (!ReadVendorRequest(ivars->pciDevice, ivars->barMemoryIndex, ivars->symphonyAddr,
                           kind ? kSIOCmd_HeadphoneVolume : kSIOCmd_SpeakerVolume, kind ? kind - 1 : 0,
                           &level, 1, ivars->runtimeTxSeq, ivars->isLegacyPCIe2100) ||
        !ReadVendorRequest(ivars->pciDevice, ivars->barMemoryIndex, ivars->symphonyAddr,
                           kind ? kSIOCmd_HeadphoneMute : kSIOCmd_SpeakerMute, kind ? kind - 1 : 0,
                           &mute, 1, ivars->runtimeTxSeq, ivars->isLegacyPCIe2100))
        return false;
    MonitorAttenuation(ivars, false, kind) = level > 64 ? 64 : level;
    MonitorMute(ivars, false, kind) = mute != 0;
    if (kind == 0) ivars->speakerLevelKnown = true;
    return true;
}

// Unit B's Headphone 2 level and mute, read from the unit. On xlinkQueue.
static bool ReadUnitBHeadphone2(SymphonyThunderbridge_IVars *ivars)
{
    uint8_t level = 0, mute = 0;
    if (!ReadVendorRequestOn(ivars->pciDevice, ivars->barMemoryIndex, kRegXLink2TX, kRegXLink2RX, 1,
                             kSIOCmd_HeadphoneVolume, 1, &level, 1, ivars->runtimeTxSeq2, ivars->isLegacyPCIe2100) ||
        !ReadVendorRequestOn(ivars->pciDevice, ivars->barMemoryIndex, kRegXLink2TX, kRegXLink2RX, 1,
                             kSIOCmd_HeadphoneMute, 1, &mute, 1, ivars->runtimeTxSeq2, ivars->isLegacyPCIe2100))
        return false;
    ivars->unitBHP2Attenuation = level > 64 ? 64 : level;
    ivars->unitBHP2Mute = mute != 0;
    return true;
}

// Select which configured Symphony I/O owns the single Core Audio volume/mute
// control. The original exposed this in System Setup as the monitor device.
kern_return_t SymphonyThunderbridge::SetMonitorDevice(uint32_t unit)
{
    if (!ivars || unit > 1) return kIOReturnBadArgument;
    IODispatchQueue *q = ivars->xlinkQueue;
    if (!q) return kIOReturnNotReady;
    __block kern_return_t result = kIOReturnSuccess;
    q->DispatchSync(^{
        if (unit == 1 && (!ivars->unitBConfigured || ivars->portMode != 64)) {
            result = kIOReturnNotReady;
            return;
        }
        if (ivars->monitorDeviceB == (unit == 1)) return;
        if (!XLinkTxAdmissible(ivars)) {
            result = kIOReturnNotReady;
            return;
        }
        if (unit == 1) {
            uint8_t values[5] = {};
            const uint8_t commands[] = {kSIOCmd_SpeakerMode, kSIOCmd_SpeakerVolume,
                kSIOCmd_SpeakerMute, kSIOCmd_HeadphoneVolume, kSIOCmd_HeadphoneMute};
            for (unsigned n = 0; n < 5; n++) {
                if (!ReadVendorRequestOn(ivars->pciDevice, ivars->barMemoryIndex, kRegXLink2TX,
                    kRegXLink2RX, 1, commands[n], 0, &values[n], 1,
                    ivars->runtimeTxSeq2, ivars->isLegacyPCIe2100)) {
                    result = kIOReturnIOError;
                    return;
                }
            }
            if (!ivars->monitorOutputChosen[1])
                ivars->unitBMonitorOutputTarget = values[0] == 0 ? kSymphonyMonitorOutputHP1 : kSymphonyMonitorOutputSpeakers;
            // Headphone 2 only when it is unit B's Audio Output: nothing
            // else needs its level.
            if (ivars->unitBMonitorOutputTarget == kSymphonyMonitorOutputHP2 && !ReadUnitBHeadphone2(ivars)) {
                result = kIOReturnIOError;
                return;
            }
            ivars->unitBLineMode = values[0] == 0;
            ivars->unitBSpeakerAttenuation = values[1];
            ivars->unitBSpeakerMute = values[2] != 0;
            ivars->unitBHP1Attenuation = values[3];
            ivars->unitBHP1Mute = values[4] != 0;
        }
        ivars->monitorDeviceB = unit == 1;
        PublishSelectedMonitor(ivars);
    });
    return result;
}

// The app's "Audio Output" choice for one unit: which of its outputs the Mac's
// volume and mute controls move. The original kept this per unit as
// m_MonitorOutput (og_source/symphonymk1/ext/maestrolink/Software/
// SymphonyIO.cpp:2410-2445) and sent a Core Audio volume or mute set to that
// output (:2239-2276, :2345-2395). Unit B's choice is kept while unit A owns
// the controls and takes effect when unit B is selected (SetMonitorDevice).
// Converters only (our addition; the original had no working volume there):
// 1 = the card mixer trim, 0 = "None", which puts the trim back to 0 dB,
// unmuted, and makes the controls do nothing.
kern_return_t SymphonyThunderbridge::SetMonitorOutput(uint32_t unit, uint32_t output)
{
    if (!ivars || unit > 1 || output > kSymphonyMonitorOutputHP2) return kIOReturnBadArgument;
    IODispatchQueue *q = ivars->xlinkQueue;
    if (!q) return kIOReturnNotReady;
    __block kern_return_t result = kIOReturnSuccess;
    q->DispatchSync(^{
        if (__atomic_load_n(&ivars->converterVolumeKeys, __ATOMIC_ACQUIRE)) {
            if (unit != 0 || output > kSymphonyMonitorOutputSpeakers) {
                result = kIOReturnUnsupported;   // no speakers or headphones on converters
                return;
            }
            const bool off = output == kSymphonyMonitorOutputNone;
            if (ivars->converterKeysOff == off) return;
            ivars->converterKeysOff = off;
            if (off) {
                ivars->converterTrimAtten = 0;
                ivars->converterTrimMuted = false;
                // Not reachable now: link recovery puts the trim on the card.
                if (XLinkTxAdmissible(ivars)) ApplyConverterTrim(ivars);
            }
            ivars->lastVolumeDb = -static_cast<float>(ivars->converterTrimAtten);
            ivars->lastMuteState = ivars->converterTrimMuted;
            if (ivars->outputVolumeControl) ivars->outputVolumeControl->SetDecibelValue(ivars->lastVolumeDb);
            if (ivars->outputMuteControl) ivars->outputMuteControl->SetControlValue(ivars->lastMuteState);
            __atomic_fetch_add(&ivars->monitorGeneration, 1, __ATOMIC_RELEASE);
            STLOG("Volume keys: converters, %{public}s", off ? "None (trim back to 0 dB, unmuted)" : "card mixer level");
            return;
        }
        if (output == kSymphonyMonitorOutputNone) {
            result = kIOReturnBadArgument;   // "None" exists for converters only
            return;
        }
        if (unit == 1 && (!ivars->unitBConfigured || ivars->portMode != 64)) {
            result = kIOReturnNotReady;
            return;
        }
        uint8_t &target = unit ? ivars->unitBMonitorOutputTarget : ivars->monitorOutputTarget;
        ivars->monitorOutputChosen[unit] = true;
        if (target == output) return;
        // Unit A: the chosen output's level and mute are read from the unit
        // before the controls show them, so that no level is shown, or
        // stepped from by the next key, that the unit does not have. With
        // no unit on the link the choice is kept and link recovery reads them.
        if (unit == 0 && ivars->symphonyLinkConfigured && !ivars->convPort1 && XLinkTxAdmissible(ivars)) {
            if (!ReadUnitAMonitorLevel(ivars, output)) { result = kIOReturnIOError; return; }
        }
        // Unit B's Headphone 2 has not been read yet when it becomes the
        // output the controls show.
        if (unit == 1 && output == kSymphonyMonitorOutputHP2 && ivars->monitorDeviceB) {
            if (!XLinkTxAdmissible(ivars)) { result = kIOReturnNotReady; return; }
            if (!ReadUnitBHeadphone2(ivars)) { result = kIOReturnIOError; return; }
        }
        __atomic_store_n(&target, static_cast<uint8_t>(output), __ATOMIC_RELEASE);
        if ((unit == 1) == ivars->monitorDeviceB) PublishSelectedMonitor(ivars);
        STLOG("Volume keys: unit %{public}s output %u (1 speakers, 2 HP1, 3 HP2)", unit ? "B" : "A", output);
    });
    return result;
}

// ── ReadVendorCommand ────────────────────────────────────────────────────────
// Serialized counterpart to SendVendorCommand. The XLink request/response
// transaction must share the same queue as writes so a readback cannot race a
// pending routing or mixer command.
kern_return_t SymphonyThunderbridge::ReadVendorCommand(
    uint8_t command, uint32_t value, uint8_t *outPayload, uint16_t responseLen, uint8_t port)
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
        if (port > 1 || (port == 1 && (!ivars->unitBConfigured || ivars->portMode != 64))) {
            result = port == 1 ? kIOReturnNotReady : kIOReturnBadArgument;
            return;
        }
        if (port == 0 && ivars->convPort1) {   // dext 131: never a Symphony I/O read to converters
            result = kIOReturnUnsupported;
            return;
        }
        uint8_t &seq = port ? ivars->runtimeTxSeq2 : ivars->runtimeTxSeq;
        const bool ok = ReadVendorRequestOn(ivars->pciDevice, ivars->barMemoryIndex,
                              port ? kRegXLink2TX : kRegXLink1TX,
                              port ? kRegXLink2RX : kRegXLink1RX,
                              port ? 1 : ivars->symphonyAddr, command, value,
                              response, responseLen, seq,
                              ivars->isLegacyPCIe2100);
        if (ok) {
            // Consume the existing parameter poll; no extra bus traffic and no
            // front-panel echo. Match SymphonyIO.cpp:6460-6871 and the wire
            // layout in SymphonyIOVendorSpecific.h:1036-1046.
            if (command == 0x28 && responseLen == 12) {
                const uint32_t rate = (uint32_t(response[0]) << 24) | (uint32_t(response[1]) << 16)
                    | (uint32_t(response[2]) << 8) | response[3];
                if (rate >= 32000 && rate <= 200000 && response[4] <= 1 && response[7] <= 2 &&
                    response[10] <= 1 && response[11] <= 1 && response[9] <= (response[8] == 2 ? 64 : 127)) {
                    bool publish = false;
                    // Front panel selection: 0 = HP1, 1 = HP2, 2 = speaker
                    // (SymphonyIOVendorSpecific.h:1010-1012).
                    const unsigned selected = SelectedMonitorKind(ivars, port != 0);
                    if (response[10] || ivars->monitorKnobChanging[port]) {
                        if (response[8] == 2) {
                            // Not unit A's speakers in Line: that reading is the unit's 0.
                            if (port || !__atomic_load_n(&ivars->lineMode, __ATOMIC_ACQUIRE)) {
                                (port ? ivars->unitBSpeakerAttenuation : ivars->speakerAttenuation) = response[9];
                                if (!port) ivars->speakerLevelKnown = true;
                            }
                            publish = selected == 0;
                        } else if (response[8] <= 1) {
                            const unsigned kind = response[8] + 1u;
                            MonitorAttenuation(ivars, port != 0, kind) = response[9] > 64 ? 64 : response[9];
                            publish = selected == kind;
                        }
                    }
                    ivars->monitorKnobChanging[port] = response[10] != 0;
                    if (response[7] && response[7] != ivars->monitorMuteAll[port]) {
                        (port ? ivars->unitBSpeakerMute : ivars->speakerMute) = response[7] == 2;
                        (port ? ivars->unitBHP1Mute : ivars->hp1Mute) = response[7] == 2;
                        (port ? ivars->unitBHP2Mute : ivars->hp2Mute) = response[7] == 2;
                        publish = true;
                    }
                    ivars->monitorMuteAll[port] = response[7];
                    if (publish && (port == 1) == ivars->monitorDeviceB) PublishSelectedMonitor(ivars);
                }
            }
            result = kIOReturnSuccess;
        } else {
            result = kIOReturnIOError;
        }
    });
    if (result == kIOReturnSuccess)
        for (uint16_t i = 0; i < responseLen; i++) outPayload[i] = response[i];
    // The app reads S/PDIF Coax Replaces at connect; the unit keeps it across a
    // driver restart, so this is where the driver learns it.
    // dext 131: a read from unit B (port 1) only updates unit B's own naming.
    if (result == kIOReturnSuccess && port == 1 && command == kSIOCmd_SPDIFCoaxReplaceInput && value < 2 &&
        ivars->unitBCoaxReplace[value] != outPayload[0]) {
        ivars->unitBCoaxReplace[value] = outPayload[0];
        ScheduleChannelNames(ivars, this);
        if (ivars->xlinkQueue) ivars->xlinkQueue->DispatchAsync(^{ PublishAllMicPreControls(ivars); });
    }
    if (result == kIOReturnSuccess && port == 1 && command == kSymphonyCmdPrefix && responseLen == 1 &&
        SymphonyIsPrefixLetter(outPayload[0]) && ivars->unitBPrefix != outPayload[0]) {
        ivars->unitBPrefix = outPayload[0];
        ScheduleChannelNames(ivars, this);
    }
    if (result == kIOReturnSuccess && port == 0 && command == kSymphonyCmdPrefix && responseLen == 1 &&
        __atomic_exchange_n(&ivars->namingPrefix, outPayload[0], __ATOMIC_ACQ_REL) != outPayload[0]) {
        ScheduleChannelNames(ivars, this);
    }
    if (result == kIOReturnSuccess && port == 0 && command == kSIOCmd_SPDIFCoaxReplaceInput && value < 2) {
        const uint8_t before = __atomic_exchange_n(&ivars->namingCoaxReplace[value], outPayload[0],
                                                   __ATOMIC_ACQ_REL);
        NoteCoaxBoardType(ivars, value);
        if (before != outPayload[0]) {
            ScheduleChannelNames(ivars, this);
            if (ivars->xlinkQueue) ivars->xlinkQueue->DispatchAsync(^{ PublishAllMicPreControls(ivars); });
        }
    }
    return result;
}

#if defined(SYMPHONY_REGISTER_TRACE_HOST)
kern_return_t SymphonyThunderbridge::SendVendorCommand(uint8_t command, uint32_t value,
                                                        const uint8_t *payload, uint16_t payloadLen)
{
    return SendVendorCommand(command, value, payload, payloadLen, 0);
}

kern_return_t SymphonyThunderbridge::ReadVendorCommand(uint8_t command, uint32_t value,
                                                       uint8_t *outPayload, uint16_t responseLen)
{
    return ReadVendorCommand(command, value, outPayload, responseLen, 0);
}
#endif

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

    // dext 130: repeat what Start() found, at most every 10 minutes. The driver
    // usually starts at boot, long before anyone turns diagnostics on, and a
    // diagnostics capture reads timing health at its start: either this logs
    // now, or it did within the last 10 minutes, inside the capture's 30-minute
    // look-back. Logging only.
    {
        const uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
        const uint64_t last = __atomic_load_n(&ivars->startSummaryLoggedNs, __ATOMIC_RELAXED);
        if (last == 0 || now - last >= 600ull * 1000000000ull) {
            __atomic_store_n(&ivars->startSummaryLoggedNs, now, __ATOMIC_RELAXED);
            STLOG("Start-up summary: card=%{public}s FPGA=%u role=%{public}s irqIndex=%u "
                  "irqTypes=0x%llx/0x%llx/0x%llx/0x%llx DMA at start=%{public}s cardReinits=%u",
                  ivars->isLegacyPCIe2100 ? "Symphony 64 PCIe (0x2100)" : "ThunderBridge",
                  ivars->fpgaVersion, ivars->isMaster ? "MASTER" : "SLAVE", ivars->irqIndexUsed,
                  ivars->irqTypeAtStart[0], ivars->irqTypeAtStart[1],
                  ivars->irqTypeAtStart[2], ivars->irqTypeAtStart[3],
                  ivars->dmaVerifiedRunning ? "running" : "NOT running", ivars->cardReinitCount);
            if (ivars->isLegacyPCIe2100)
                STLOG("Start-up summary (PCIe card): expansion 0x2214 0x%08x -> 0x%08x, clock 0x94=0x%08x; "
                      "1 s after DMA start A2H offset=%u IntStatus=0x%08x meter words written=%u PCI status=0x%04x",
                      ivars->expansionBefore, ivars->expansionAfter, ivars->expansionClk,
                      ivars->dmaCheckA2HOffset1s, ivars->dmaCheckIntStatus1s,
                      ivars->dmaCheckMeterWritten, ivars->pciStatusAtStart);
        }
    }

    // A PCI service and its DMA/register window can remain alive after the
    // downstream Symphony loses power. Make this selector a real endpoint
    // health read by issuing the original read-only ClockRateAndLock command
    // on the same serialized XLink queue used by all vendor traffic. This
    // prevents the app from promoting stale timing registers or meter memory
    // to a live device state. The read is bounded by ReadVendorRequest's
    // existing 200 ms timeout and is outside the realtime audio path.
    __block bool live = false;
    __block uint32_t clkCtrl = 0, intStatus = 0, xlinkStatus = 0, gcsr = 0;
    // The audio device's values are read inside the block too: Stop() drains
    // this queue (step 8b) before it releases audioDevice, so inside the block
    // the pointer is either valid or the block saw 'stopping' and returned.
    // These getters already run on xlinkQueue elsewhere: the rate-change
    // transaction's ApplyAudioTimingProfile (Get/Set latency and safety
    // offsets) and GetSampleRate in ReprogramCardAfterReset and
    // RunLinkRecoveryOnQueue.
    __block double rate = 0.0;
    __block uint32_t inLatency = 0, outLatency = 0, inSafety = 0, outSafety = 0;
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
                                 ivars->runtimeTxSeq,
        ivars->isLegacyPCIe2100);
        if (!live) return;
        // dext 112 (review item 3): the register snapshot is BAR loads too. Take
        // it HERE, on the queue the SetPowerState(Off) barrier drains, never on
        // the caller's thread after the block has returned.
        ReadRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegClkCtrl, &clkCtrl);
        ReadRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegIntStatus, &intStatus);
        ReadRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegXLink1Status, &xlinkStatus);
        ReadRegister(ivars->pciDevice, ivars->barMemoryIndex, kRegGCSR, &gcsr);
        if (ivars->audioDevice) {
            rate       = ivars->audioDevice->GetSampleRate();
            inLatency  = ivars->audioDevice->GetInputLatency();
            outLatency = ivars->audioDevice->GetOutputLatency();
            inSafety   = ivars->audioDevice->GetInputSafetyOffset();
            outSafety  = ivars->audioDevice->GetOutputSafetyOffset();
        }
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
        if (!__atomic_load_n(&ivars->stopping, __ATOMIC_ACQUIRE) && ivars->audioDevice) {
            // Requested even when no IO is running: the host re-evaluates the
            // device, and clients that were refused while the link was down
            // (StartDevice → kIOReturnNotReady) see a device configuration
            // change rather than silence.
            ArmMicPreSettle(ivars);
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
    outWords[8] = inLatency;
    outWords[9] = outLatency;
    outWords[10] = inSafety;
    outWords[11] = outSafety;
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
                const bool admissible = XLinkTxAdmissible(ivars);
                if (admissible && ivars->convPort1) {
                    // dext 131: converters take no Symphony I/O ClockMode. Their
                    // word clock is Internal or External (SetWCMaster); any source
                    // but Internal (1) means External.
                    const uint32_t cfg = __atomic_load_n(&ivars->convConfig, __ATOMIC_ACQUIRE);
                    const uint32_t want = src == 1 ? (cfg & ~kSymphonyConvConfigClockExternal)
                                                   : (cfg | kSymphonyConvConfigClockExternal);
                    if (want != cfg) SetConverterConfig(want);
                } else if (admissible && ivars->unitBConfigured && (src == 3 || ivars->loopSyncConfig == 2)) {
                    // dext 131: with unit B on port 2, unit A is the Loop Sync
                    // master; it cannot also be a Loop Sync slave.
                    STLOG("RequestClockSource: Loop Sync refused for unit A while unit B follows it");
                } else if (admissible) {
                    // ClockMode 0x50: [source, master, loopSync, boardClockSrc].
                    // LoopSync(3) ⇒ slave + loopSync on; all others ⇒ master, loopSync
                    // off. boardClockSrc left 0. (SymphonyIOVendorSpecific.h:222-247;
                    // boot sends {1,1,0,0} = Internal, Master.)
                    uint8_t clockData[4] = {
                        (uint8_t)src,
                        (uint8_t)(src == 3 ? 0 : 1),
                        // dext 131: with unit B on port 2, unit A stays the
                        // Loop Sync master (output on), as the original.
                        (uint8_t)((src == 3 || (ivars->unitBConfigured && !(ivars->loopSyncConfig & 1))
                                   || (!ivars->unitBConfigured && ivars->oneUnitLoopSync)) ? 1 : 0),
                        0
                    };
                    // dext 152: the bytes unit A already accepted on this
                    // link (Core Audio restoring the selector it shows) are
                    // not sent again.
                    if (!ivars->unitBConfigured && ivars->unitAClockSentKnown &&
                        memcmp(clockData, ivars->unitAClockSent, 4) == 0) {
                        if (!ivars->clockSkipLogged) {
                            ivars->clockSkipLogged = true;
                            STLOG("RequestClockSource: ClockMode unchanged, not sent (source %u)", src);
                        }
                    } else {
                        const bool ok = SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                                          ivars->symphonyAddr, kSIOCmd_ClockMode, 0,
                                                          clockData, sizeof(clockData), ivars->runtimeTxSeq);
                        if (ivars->unitBConfigured) ivars->unitAClockSentKnown = false;
                        else NoteUnitAClockSent(ivars, clockData, ok);
                    }
                    memcpy(ivars->unitAClock, clockData, 4);
                    ivars->unitAClockKnown = true;
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
                const bool admissible = XLinkTxAdmissible(ivars);   // one presence check per pass
                if (admissible && ivars->opticalSentKnown[b] && ivars->opticalSent[b] == val) {
                    // dext 152: the format this board already took on this
                    // link (Core Audio restoring it) is not sent again.
                    if (!ivars->opticalSkipLogged) {
                        ivars->opticalSkipLogged = true;
                        STLOG("RequestOpticalFormat: OpticalFormat unchanged, not sent (board %u)", b);
                    }
                } else if (admissible) {
                    uint8_t pData = val;   // 0=ADAT/SMUX, 1=S/PDIF
                    const bool ok = SendVendorRequest(ivars->pciDevice, ivars->barMemoryIndex,
                                                      ivars->symphonyAddr, kSIOCmd_OpticalFormat,
                                                      b /*nValue = 0-based board index*/,
                                                      &pData, 1, ivars->runtimeTxSeq);
                    ivars->opticalSent[b] = val;
                    ivars->opticalSentKnown[b] = ok;
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
    // Optical channel names follow the format (ADAT/SMUX or SPDIF Opt).
    ScheduleChannelNames(ivars, this);
    return kIOReturnSuccess;
}

// ── RequestPhantom / RequestMicGain — per-mic-channel push senders ───────────
// Mirror RequestClockSource exactly, but keep an independent coalescing lane per
// channel (parallel arrays indexed by ch). Each lane dispatches its own drain on
// the shared serial xlinkQueue, so channels never lose each other's latest value
// and all XLink TX still serializes (MSG_BYTE frames never interleave). Never
// call SendVendorRequest from the control/IRQ queue — only from the drain block.

static bool MicPreIsMic(SymphonyThunderbridge_IVars *iv, uint32_t port, uint32_t ch)
{
    return port ? __atomic_load_n(&iv->unitBMicPreMic[ch], __ATOMIC_ACQUIRE) :
                  __atomic_load_n(&iv->micPreMic[ch], __ATOMIC_ACQUIRE);
}

// ── MicPre DAW-control helpers (polarity, high-pass, input type) ────────────
// All of these run on the serial xlinkQueue unless noted.

static bool MicPreTypeKnownOn(SymphonyThunderbridge_IVars *iv, uint32_t port, uint32_t ch)
{
    return port ? __atomic_load_n(&iv->unitBMicPreTypeKnown[ch], __ATOMIC_ACQUIRE)
                : __atomic_load_n(&iv->micPreTypeKnown[ch], __ATOMIC_ACQUIRE);
}

// Polarity and high-pass exist for Mic and Instrument only; the original hid
// both on line types (SymphonyIOBoard_MicPre8ch.cpp:1288-1297,1603-1620). An
// unknown type does not refuse them: they change no power or routing.
static bool MicPreTypeAllowsSwitches(SymphonyThunderbridge_IVars *iv, uint32_t port, uint32_t ch)
{
    if (!MicPreTypeKnownOn(iv, port, ch)) return true;
    const uint8_t type = iv->micPreType[port][ch];
    return type == 3 || type == 4;
}

// Finding 9: a Mic type that came from the HAL authorises HAL phantom ON only
// once kHALMicArmNs has passed since the unit took it. Mic read from the unit
// or set by Maestro carries no stamp. Any thread.
static bool HalMicArmed(SymphonyThunderbridge_IVars *iv, uint32_t port, uint32_t ch)
{
    const uint64_t stamp = __atomic_load_n(&iv->halMicTypeStamp[port][ch], __ATOMIC_ACQUIRE);
    return stamp == 0 || SYMPHONY_MICPRE_NOW_NS() - stamp >= kHALMicArmNs;
}

// N1: the settle window after the controls (re)appear to coreaudiod. Any thread.
static void ArmMicPreSettle(SymphonyThunderbridge_IVars *iv)
{
    if (!iv) return;
    __atomic_store_n(&iv->halMicPreSettleUntil, SYMPHONY_MICPRE_NOW_NS() + kHALMicPreSettleNs,
                     __ATOMIC_RELEASE);
    __atomic_fetch_add(&iv->monitorSettleArms, 1, __ATOMIC_RELEASE);
}

static bool MicPreSettling(SymphonyThunderbridge_IVars *iv)
{
    return SYMPHONY_MICPRE_NOW_NS() < __atomic_load_n(&iv->halMicPreSettleUntil, __ATOMIC_ACQUIRE);
}

// A refused request leaves the control on its old value; publish it again so
// a client that showed the new one optimistically gets a notification.
static void RepublishMicPreHostLater(SymphonyThunderbridge_IVars *iv, uint32_t host);

// A unit may have been swapped or reconfigured: what the driver remembered
// about its MicPre (insert table, trims, start values) belongs to the unit
// that was there. `clearEdits` also drops the unread DAW edits: set when the
// unit is set up again (ConfigureUnitB), not on a link recovery, which is
// usually the same unit coming back. The type stamp is kept: dropping it
// could only shorten the phantom arm delay. xlinkQueue.
static void ResetMicPreUnitCaches(SymphonyThunderbridge_IVars *iv, uint32_t port, bool clearEdits)
{
    for (uint32_t ch = 0; ch < 8; ++ch) {
        if (clearEdits) {
            __atomic_store_n(&iv->halMicPreEdit[port * 8 + ch], 0, __ATOMIC_RELEASE);
            __atomic_store_n(&iv->halMicPreEditStamp[port * 8 + ch], 0, __ATOMIC_RELEASE);
        }
        iv->micPreInsertMaskKnown[port][ch] = false;
        iv->micPreTrimKnown[port][ch] = false;
        iv->micPrePhaseKnown[port][ch] = false;
        iv->micPreHighPassKnown[port][ch] = false;
    }
}

static bool SendMicPre(SymphonyThunderbridge_IVars *iv, uint32_t port, uint8_t command,
                       uint32_t value, const uint8_t *payload, uint16_t len)
{
    return SendVendorRequestOn(iv->pciDevice, iv->barMemoryIndex,
                               port ? kRegXLink2TX : kRegXLink1TX,
                               port ? 1 : iv->symphonyAddr, command, value, payload, len,
                               port ? iv->runtimeTxSeq2 : iv->runtimeTxSeq);
}

static bool ReadMicPre(SymphonyThunderbridge_IVars *iv, uint32_t port, uint8_t command,
                       uint32_t value, uint8_t *out)
{
    return ReadVendorRequestOn(iv->pciDevice, iv->barMemoryIndex,
                               port ? kRegXLink2TX : kRegXLink1TX,
                               port ? kRegXLink2RX : kRegXLink1RX,
                               port ? 1 : iv->symphonyAddr, command, value, out, 1,
                               port ? iv->runtimeTxSeq2 : iv->runtimeTxSeq,
                               iv->isLegacyPCIe2100);
}

// Start (unit A) and ConfigureUnitB (unit B), MicPre rigs only.
static void ReadMicPreSwitches(SymphonyThunderbridge_IVars *iv, uint32_t port, uint32_t ch)
{
    uint8_t on = 0;
    iv->micPrePhaseKnown[port][ch] = ReadMicPre(iv, port, kSIOCmd_PhaseInverse, ch, &on);
    iv->micPrePhase[port][ch] = iv->micPrePhaseKnown[port][ch] && on != 0;
    on = 0;
    iv->micPreHighPassKnown[port][ch] = ReadMicPre(iv, port, kSIOCmd_HighPassFilter, ch, &on);
    iv->micPreHighPass[port][ch] = iv->micPreHighPassKnown[port][ch] && on != 0;
}

// V4: after unit A comes back from a link recovery the cached type may be
// another unit's. Mark it unknown first (unknown sends both OFFs on a HAL type
// change and refuses HAL phantom ON), then read 0x60 again as Start does;
// a failed read leaves the channel unknown. MicPre rigs only. xlinkQueue.
static void RereadMicPreTypesA(SymphonyThunderbridge_IVars *iv)
{
    for (uint32_t ch = 0; ch < iv->numMicChannels && ch < 8; ++ch) {
        // Unknown means no stage flags either: a stale Instrument flag would
        // make an unknown channel drop its Mic-lane gain.
        __atomic_store_n(&iv->micPreTypeKnown[ch], false, __ATOMIC_RELEASE);
        __atomic_store_n(&iv->micPreMic[ch], false, __ATOMIC_RELEASE);
        __atomic_store_n(&iv->micPreInstrument[ch], false, __ATOMIC_RELEASE);
        uint8_t type = 0;
        if (ReadVendorRequest(iv->pciDevice, iv->barMemoryIndex, iv->symphonyAddr,
                              kSIOCmd_CurrentAnalogInputType, 0x80000000u | ch, &type, 1,
                              iv->runtimeTxSeq, iv->isLegacyPCIe2100) && type <= 4) {
            __atomic_store_n(&iv->micPreInstrument[ch], type == 4, __ATOMIC_RELEASE);
            __atomic_store_n(&iv->micPreMic[ch], type == 3, __ATOMIC_RELEASE);
            iv->micPreType[0][ch] = type;
            __atomic_store_n(&iv->micPreTypeKnown[ch], true, __ATOMIC_RELEASE);
        }
        ReadMicPreSwitches(iv, 0, ch);
        PublishMicGain(iv, ch);
    }
    PublishAllMicPreControls(iv);
}

static void FillMicPreTypeDescriptions(IOUserAudioSelectorValueDescription (&out)[5])
{
    static const char *const names[5] = { "+4 dBu", "-10 dBV", "Variable", "Mic", "Instrument" };
    for (uint32_t i = 0; i < 5; ++i)
        out[i] = { i, OSSharedPtr<OSString>(OSString::withCString(names[i]), OSNoRetain) };
}

// Instrument is offered where the host input currently reaches MicPre 1-4.
// An unresolved input keeps the Start layout (host channel 1-4).
static uint8_t MicPreTypeChoicesForHost(SymphonyThunderbridge_IVars *iv, uint32_t host)
{
    uint32_t port = 0, ch = host;
    if (!ResolveMicPreRoute(iv, host, port, ch)) ch = host;
    return ch < 4 ? 5 : 4;
}

static void RefreshMicPreTypeChoices(SymphonyThunderbridge_IVars *iv, uint32_t host)
{
    SymphonyInputTypeControl *control = iv->inputTypeControl[host];
    if (!control) return;
    const uint8_t want = MicPreTypeChoicesForHost(iv, host);
    if (want == iv->inputTypeChoices[host]) return;
    IOUserAudioSelectorValueDescription types[5];
    FillMicPreTypeDescriptions(types);
    if (want == 5) control->AddControlValueDescriptions(&types[4], 1);
    else control->RemoveControlValueDescriptions(&types[4], 1);
    iv->inputTypeChoices[host] = want;
}

// Every host input after a route edit: entries first, then the values of the
// MicPre channel it now reaches.
static void PublishAllMicPreControls(SymphonyThunderbridge_IVars *iv)
{
    for (uint32_t host = 0; host < iv->numMicChannels; ++host) {
        RefreshMicPreTypeChoices(iv, host);
        uint32_t port = 0, ch = 0;
        if (ResolveMicPreRoute(iv, host, port, ch)) PublishMicPreControls(iv, port, ch);
    }
}

// A request that did not reach the unit: show the real value again on the
// host input that asked (and its aliases). An input that no longer resolves
// still holds the last published value, which was never changed.
static void RepublishMicPreHost(SymphonyThunderbridge_IVars *iv, uint32_t host)
{
    uint32_t port = 0, ch = 0;
    if (host < 64 && ResolveMicPreRoute(iv, host, port, ch)) PublishMicPreControls(iv, port, ch);
}

static void RepublishMicPreHostLater(SymphonyThunderbridge_IVars *iv, uint32_t host)
{
    if (!iv || !iv->xlinkQueue) return;
    iv->xlinkQueue->DispatchAsync(^{ RepublishMicPreHost(iv, host); });
}

static bool MicPreRouteStillBound(SymphonyThunderbridge_IVars *iv, uint32_t host,
                                  uint32_t port, uint32_t ch)
{
    uint32_t p = 0, c = 0;
    return ResolveMicPreRoute(iv, host, p, c) && p == port && c == ch &&
           (!port || (iv->unitBConfigured && CardMixerUnitBActive(iv)));
}

// The host-only OFF receipt the app reads (ReadPhantomObservations). Monotonic
// per channel, so the app can tell a new OFF from one it has already seen.
static void StampHalPhantomOff(SymphonyThunderbridge_IVars *iv, uint32_t port, uint32_t ch)
{
    uint64_t previous = __atomic_load_n(&iv->halPhantomOff[port * 8 + ch], __ATOMIC_ACQUIRE);
    uint64_t next;
    do {
        const uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
        next = now > previous ? now : previous + 1;
    } while (!__atomic_compare_exchange_n(&iv->halPhantomOff[port * 8 + ch], &previous,
                                         next, false, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE));
}

// Record a host-originated edit the unit took. Fields are cumulative per
// channel (`replaced` names the bits this edit owns), so a DAW recall burst or
// an hour of DAW work while Maestro is closed all reaches the app. A field
// goes stale only when something else sets it, and those paths clear its bit:
// Maestro's own write (SendVendorCommand) and a front-panel gain
// (PublishObservedMicGain). Fields first, then the stamp, so a reader that
// sees the new stamp sees the new fields (ReadMicPreEdits).
static void StampHalMicPreEdit(SymphonyThunderbridge_IVars *iv, uint32_t port, uint32_t ch,
                               uint32_t fields, uint32_t replaced)
{
    const uint32_t i = port * 8 + ch;
    const uint32_t old = __atomic_load_n(&iv->halMicPreEdit[i], __ATOMIC_ACQUIRE);
    __atomic_store_n(&iv->halMicPreEdit[i], (old & ~replaced) | fields, __ATOMIC_RELEASE);
    uint64_t previous = __atomic_load_n(&iv->halMicPreEditStamp[i], __ATOMIC_ACQUIRE);
    uint64_t next;
    do {
        const uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
        next = now > previous ? now : previous + 1;
    } while (!__atomic_compare_exchange_n(&iv->halMicPreEditStamp[i], &previous, next,
                                         false, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE));
}

// Maestro set this field itself: an older unread HAL value must not win.
static void ClearHalMicPreEdit(SymphonyThunderbridge_IVars *iv, uint32_t port, uint32_t ch,
                               uint32_t validBit)
{
    __atomic_and_fetch(&iv->halMicPreEdit[port * 8 + ch], ~validBit, __ATOMIC_ACQ_REL);
}

static void PublishMicPrePhantomOff(SymphonyThunderbridge_IVars *iv, uint32_t port, uint32_t ch)
{
    for (uint32_t host = 0; host < iv->numMicChannels; ++host) {
        uint32_t p = 0, c = 0;
        if (iv->phantomControl[host] && ResolveMicPreRoute(iv, host, p, c) && p == port && c == ch)
            iv->phantomControl[host]->SetControlValue(false);
    }
}

// Maestro's 0x20 trim byte as 0.1 dB: +4/-10 carry 0.1 dB, Variable 0.5 dB
// (Apps/Maestro/MaestroCore/InputChannelState.swift trimRange/trimByte).
static void RecordMicPreTrim(SymphonyThunderbridge_IVars *iv, uint32_t port, uint32_t ch,
                             uint8_t type, uint8_t byte)
{
    if (type > 2 || byte == kSIOTrimDoNotSet) return;
    const int8_t b = static_cast<int8_t>(byte);
    iv->micPreTrimTenths[port][ch] = static_cast<int16_t>(type == 0 ? b * 5 : b);
    iv->micPreTrimKnown[port][ch] = true;
}

// The trim byte for a HAL type change: the stored trim clamped and encoded
// for the new line type, as Maestro would encode it; Mic/Instrument and an
// unknown trim send DO_NOT_SET, which leaves the unit's own trim alone.
static uint8_t MicPreTrimByte(SymphonyThunderbridge_IVars *iv, uint32_t port, uint32_t ch,
                              uint8_t type)
{
    if (type > 2 || !iv->micPreTrimKnown[port][ch]) return kSIOTrimDoNotSet;
    int t = iv->micPreTrimTenths[port][ch];
    if (type == 0) {                       // Variable: 0..25 dB in 0.5 dB steps
        if (t < 0) t = 0;
        if (t > 250) t = 250;
        int b = (t + 2) / 5;
        if (b == kSIOTrimDoNotSet) b = kSIOTrimDoNotSet - 1;
        return static_cast<uint8_t>(b);
    }
    if (t < -20) t = -20;                  // +4 dBu / -10 dBV: ±2 dB in 0.1 dB steps
    if (t > 20) t = 20;
    return static_cast<uint8_t>(static_cast<int8_t>(t));
}

// Release this channel's insert assignment as the original's SetInsert(off)
// did: every insert slot that holds the channel gets its mask without it
// (SymphonyIOBoard_MicPre8ch.cpp:455-461,1753-1808). A slot never written by
// Maestro is read first; one that cannot be read is left alone (its return
// is switched off next in any case). False only when a send failed.
static bool ReleaseMicPreInsert(SymphonyThunderbridge_IVars *iv, uint32_t port, uint32_t ch,
                                bool &released)
{
    const uint8_t bit = static_cast<uint8_t>(1u << ch);
    for (uint32_t insert = 0; insert < 8; ++insert) {
        if (!iv->micPreInsertMaskKnown[port][insert]) {
            uint8_t mask = 0;
            if (!ReadMicPre(iv, port, kSIOCmd_Insert, insert, &mask)) continue;
            iv->micPreInsertMask[port][insert] = mask;
            iv->micPreInsertMaskKnown[port][insert] = true;
        }
        const uint8_t mask = iv->micPreInsertMask[port][insert];
        if (!(mask & bit)) continue;
        const uint8_t next = static_cast<uint8_t>(mask & ~bit);
        if (!SendMicPre(iv, port, kSIOCmd_Insert, insert, &next, 1)) {
            STERR("MicPre type: insert %u release failed (port %u ch%u)", insert, port, ch);
            return false;
        }
        iv->micPreInsertMask[port][insert] = next;
        released = true;
    }
    return true;
}

// Polarity (0xC5) or high-pass (0xCA) for one physical channel.
static void ApplyMicPreSwitch(SymphonyThunderbridge_IVars *iv, uint32_t kind, uint32_t port,
                              uint32_t ch, bool on, uint32_t host)
{
    const bool phase = kind == kMicPreLanePhase;
    if (!XLinkTxAdmissible(iv) || !MicPreRouteStillBound(iv, host, port, ch) ||
        !MicPreTypeAllowsSwitches(iv, port, ch)) {
        RepublishMicPreHost(iv, host);
        return;
    }
    const uint8_t v = on ? 1 : 0;
    if (!SendMicPre(iv, port, phase ? kSIOCmd_PhaseInverse : kSIOCmd_HighPassFilter, ch, &v, 1)) {
        STERR("MicPre %s: send failed (port %u ch%u)", phase ? "polarity" : "high-pass", port, ch);
        RepublishMicPreHost(iv, host);
        return;
    }
    (phase ? iv->micPrePhase : iv->micPreHighPass)[port][ch] = on;
    (phase ? iv->micPrePhaseKnown : iv->micPreHighPassKnown)[port][ch] = true;
    const uint32_t valueBit = phase ? kMicPreEditPhase : kMicPreEditHighPass;
    const uint32_t validBit = phase ? kMicPreEditPhaseValid : kMicPreEditHighPassValid;
    StampHalMicPreEdit(iv, port, ch, (on ? valueBit : 0u) | validBit, valueBit | validBit);
    PublishMicPreControls(iv, port, ch);
}

// A HAL input type change, in the order that keeps the channel safe:
//  1. Phantom OFF first unless the channel is known not to be Mic. Maestro
//     does the same (Apps/Maestro/MaestroApp/InputViews.swift applyInputTypeChange);
//     the original never sent it (fTurnOffPhantomPower is unused,
//     SymphonyIOBoard_MicPre8ch.cpp:403-423). An unknown type gets the OFF.
//  2. For a line type, unless the channel is known to be on a line type
//     already: release the insert, then insert return OFF
//     (SymphonyIOBoard_MicPre8ch.cpp:455-461).
//  3. Only if every OFF went out: the type, with the stored trim
//     (MicPreTrimByte) or DO_NOT_SET.
//  4. Mic/Instrument only, as the original (its line branch returns at
//     SymphonyIOBoard_MicPre8ch.cpp:465): the stored gain for the new stage
//     (:472-482), then group Off if the type changed (:513-521).
// A HAL set of the type the channel is known to have sends nothing and
// records no edit; a Mic still restarts the phantom arm delay. If the insert
// was released but a later step failed, the edit record says so
// (kMicPreEditInsertOff) so the app does not keep an insert the unit lost.
// N7 (review v2): the insert reads and the start-up 0xC5/0xCA reads run on
// the serial XLink queue with the usual 200 ms read timeout; the original read
// the same values, so the firmware answers them. Not measured on a rig.
static void ApplyMicPreInputType(SymphonyThunderbridge_IVars *iv, uint32_t port, uint32_t ch,
                                 uint8_t type, uint32_t host)
{
    if (!XLinkTxAdmissible(iv) || !MicPreRouteStillBound(iv, host, port, ch) ||
        type > 4 || (type == 4 && ch >= 4)) {
        RepublishMicPreHost(iv, host);
        return;
    }
    const bool known = MicPreTypeKnownOn(iv, port, ch);
    const uint8_t old = iv->micPreType[port][ch];
    const bool toPreamp = type == 3 || type == 4;
    if (known && old == type) {
        if (type == 3) {
            const uint64_t now = SYMPHONY_MICPRE_NOW_NS();
            __atomic_store_n(&iv->halMicTypeStamp[port][ch], now ? now : 1, __ATOMIC_RELEASE);
        }
        PublishMicPreControls(iv, port, ch);
        return;
    }
    bool insertReleased = false;
    auto reportInsertLoss = [&]() {
        if (insertReleased) StampHalMicPreEdit(iv, port, ch, kMicPreEditInsertOff, 0);
    };
    if (type != 3 && (!known || old == 3)) {
        const uint8_t off = 0;
        if (!SendMicPre(iv, port, kSIOCmd_PhantomPower, ch, &off, 1)) {
            STERR("MicPre type: phantom OFF failed (port %u ch%u), type unchanged", port, ch);
            RepublishMicPreHost(iv, host);
            return;
        }
        StampHalPhantomOff(iv, port, ch);
        PublishMicPrePhantomOff(iv, port, ch);
    }
    if (!toPreamp && (!known || old == 3 || old == 4)) {
        const uint8_t off = 0;
        if (!ReleaseMicPreInsert(iv, port, ch, insertReleased) ||
            !SendMicPre(iv, port, kSIOCmd_InsertEnable, ch, &off, 1)) {
            STERR("MicPre type: insert OFF failed (port %u ch%u), type unchanged", port, ch);
            reportInsertLoss();
            RepublishMicPreHost(iv, host);
            return;
        }
        insertReleased = true;   // return OFF went out: the insert is gone either way
    }
    const uint8_t payload[2] = { type, MicPreTrimByte(iv, port, ch, type) };
    if (!SendMicPre(iv, port, kSIOCmd_AnalogReferenceLevel, 0x80000000u | ch, payload, 2)) {
        STERR("MicPre type: 0x20 failed (port %u ch%u)%{public}s", port, ch,
              insertReleased ? " after the insert was released" : "");
        reportInsertLoss();
        RepublishMicPreHost(iv, host);
        return;
    }
    if (port) {
        __atomic_store_n(&iv->unitBMicPreInstrument[ch], type == 4, __ATOMIC_RELEASE);
        __atomic_store_n(&iv->unitBMicPreMic[ch], type == 3, __ATOMIC_RELEASE);
        __atomic_store_n(&iv->unitBMicPreTypeKnown[ch], true, __ATOMIC_RELEASE);
    } else {
        __atomic_store_n(&iv->micPreInstrument[ch], type == 4, __ATOMIC_RELEASE);
        __atomic_store_n(&iv->micPreMic[ch], type == 3, __ATOMIC_RELEASE);
        __atomic_store_n(&iv->micPreTypeKnown[ch], true, __ATOMIC_RELEASE);
    }
    iv->micPreType[port][ch] = type;
    uint64_t now = SYMPHONY_MICPRE_NOW_NS();
    if (now == 0) now = 1;
    __atomic_store_n(&iv->halMicTypeStamp[port][ch], type == 3 ? now : 0, __ATOMIC_RELEASE);
    StampHalMicPreEdit(iv, port, ch, type | kMicPreEditTypeValid |
                                         (insertReleased ? kMicPreEditInsertOff : 0u),
                       kMicPreEditTypeMask | kMicPreEditTypeValid);
    if (toPreamp) {
        const uint32_t lane = type == 4 ? 1 : 0;
        const bool gainKnown = port ? iv->unitBMicPreGainKnown[lane][ch] : iv->micPreGainKnown[lane][ch];
        if (gainKnown) {
            const uint8_t gain = port ? iv->unitBMicPreGain[lane][ch] : iv->micPreGain[lane][ch];
            if (!SendMicPre(iv, port, lane ? kSIOCmd_InstrumentGain : kSIOCmd_MicGain, ch, &gain, 1))
                STERR("MicPre type: stored gain not re-sent (port %u ch%u)", port, ch);
        }
        if (!known || old != type) {
            const uint8_t groupOff = 0;   // eSymphonyIOMicPre8ChGroup_Off
            if (!SendMicPre(iv, port, kSIOCmd_ChannelGroup, ch, &groupOff, 1))
                STERR("MicPre type: group Off failed (port %u ch%u)", port, ch);
        }
    }
    PublishMicGain(iv, ch, port);
    PublishMicPreControls(iv, port, ch);
}

static void ApplyMicPreLane(SymphonyThunderbridge_IVars *iv, uint32_t kind, uint32_t port,
                            uint32_t ch, uint8_t value, uint32_t host)
{
    if (kind == kMicPreLaneType) ApplyMicPreInputType(iv, port, ch, value, host);
    else ApplyMicPreSwitch(iv, kind, port, ch, value != 0, host);
}

// Same generation + CAS discipline as the phantom and gain lanes: the drain
// block sends the latest value; a change made during a send is picked up by
// the same block. Any thread.
static void QueueMicPreLane(SymphonyThunderbridge_IVars *iv, uint32_t kind, uint32_t port,
                            uint32_t ch, uint8_t value, uint32_t host)
{
    MicPreLane *lane = &iv->micPreLane[kind][port][ch];
    __atomic_store_n(&lane->value, value, __ATOMIC_RELAXED);
    __atomic_store_n(&lane->host, static_cast<uint8_t>(host), __ATOMIC_RELAXED);
    __atomic_fetch_add(&lane->gen, 1, __ATOMIC_RELEASE);
    bool expected = false;
    if (!__atomic_compare_exchange_n(&lane->scheduled, &expected, true,
                                     false, __ATOMIC_ACQ_REL, __ATOMIC_RELAXED))
        return;
    iv->xlinkQueue->DispatchAsync(^{
        for (;;) {
            const uint32_t gen = __atomic_load_n(&lane->gen, __ATOMIC_ACQUIRE);
            ApplyMicPreLane(iv, kind, port, ch, __atomic_load_n(&lane->value, __ATOMIC_RELAXED),
                            __atomic_load_n(&lane->host, __ATOMIC_RELAXED));
            __atomic_store_n(&lane->scheduled, false, __ATOMIC_RELEASE);
            if (__atomic_load_n(&lane->gen, __ATOMIC_ACQUIRE) == gen) break;
            bool again = false;
            if (!__atomic_compare_exchange_n(&lane->scheduled, &again, true,
                                             false, __ATOMIC_ACQ_REL, __ATOMIC_RELAXED))
                break;
        }
    });
}

static kern_return_t RequestMicPreSwitch(SymphonyThunderbridge_IVars *iv, uint32_t kind,
                                         uint32_t channel, bool on)
{
    if (!iv || channel >= 64) return kIOReturnBadArgument;
    uint32_t port = 0, ch = 0;
    if (!ResolveMicPreRoute(iv, channel, port, ch) || !iv->xlinkQueue ||
        __atomic_load_n(&iv->txShutdown, __ATOMIC_ACQUIRE)) return kIOReturnNotReady;
    // Read without the queue: a type change racing this is re-checked in the
    // drain block, which refuses there and republishes.
    if (!MicPreTypeAllowsSwitches(iv, port, ch)) return kIOReturnNotPermitted;
    if (MicPreSettling(iv)) {
        STERR("MicPre %s: refused during the settle window (coreaudiod restore)",
              kind == kMicPreLanePhase ? "polarity" : "high-pass");
        RepublishMicPreHostLater(iv, channel);
        return kIOReturnNotPermitted;
    }
    QueueMicPreLane(iv, kind, port, ch, on ? 1 : 0, channel);
    return kIOReturnSuccess;
}

kern_return_t SymphonyThunderbridge::RequestPhantom(uint32_t channel, bool on)
{
    if (!ivars || channel >= 64) return kIOReturnBadArgument;
    const uint32_t hostChannel = channel;
    uint32_t port = 0, ch = 0;
    if (!ResolveMicPreRoute(ivars, channel, port, ch)) return kIOReturnNotReady;
    const bool admittedTypeKnown = port ? __atomic_load_n(&ivars->unitBMicPreTypeKnown[ch], __ATOMIC_ACQUIRE) :
        __atomic_load_n(&ivars->micPreTypeKnown[ch], __ATOMIC_ACQUIRE);
    const bool admittedInstrument = port ? __atomic_load_n(&ivars->unitBMicPreInstrument[ch], __ATOMIC_ACQUIRE) :
        __atomic_load_n(&ivars->micPreInstrument[ch], __ATOMIC_ACQUIRE);
    // Phantom ON only for a channel known to be in Mic mode; the original
    // ignores phantom on any other input type
    // (og_source/maestrolink/Software/SymphonyIOBoard_MicPre8ch.cpp:683-691).
    // OFF is always allowed.
    if (on && !(admittedTypeKnown && MicPreIsMic(ivars, port, ch))) {
        STERR("RequestPhantom: ON refused, ch%u is not known to be in Mic mode", ch);
        return kIOReturnNotPermitted;
    }
    // A Mic type the HAL itself set moments ago may be coreaudiod restoring
    // saved values; it does not authorise +48V until kHALMicArmNs has passed.
    if (on && MicPreSettling(ivars)) {
        STERR("RequestPhantom: ON refused during the settle window (coreaudiod restore)");
        return kIOReturnNotPermitted;
    }
    if (on && !HalMicArmed(ivars, port, ch)) {
        STERR("RequestPhantom: ON refused, ch%u was put in Mic through the HAL too recently", ch);
        return kIOReturnNotPermitted;
    }
    IODispatchQueue *txq = ivars->xlinkQueue;
    if (!txq) {
        STERR("RequestPhantom: no XLink queue (setup incomplete)");
        return kIOReturnNotReady;
    }
    if (__atomic_load_n(&ivars->txShutdown, __ATOMIC_ACQUIRE)) {
        STERR("RequestPhantom: TX shut down — not sending");
        return kIOReturnNotReady;
    }
    // Keep the admitted physical target with the queued lane. The receipt is
    // published only after that exact target accepts the OFF send below; an
    // admission that is later refused must not look like an observed hardware
    // OFF. ON has no receipt and cannot authorize a future automatic ON.
    __atomic_store_n(&ivars->pendingPhantom[port][ch], on ? 1 : 0, __ATOMIC_RELAXED);
    __atomic_store_n(&ivars->pendingPhantomHost[port][ch], (uint8_t)hostChannel, __ATOMIC_RELAXED);
    __atomic_store_n(&ivars->pendingPhantomTypeKnown[port][ch], admittedTypeKnown, __ATOMIC_RELAXED);
    __atomic_store_n(&ivars->pendingPhantomInstrument[port][ch], admittedInstrument, __ATOMIC_RELAXED);
    __atomic_fetch_add(&ivars->pendingPhantomGen[port][ch], 1, __ATOMIC_RELEASE);
    bool expected = false;
    if (__atomic_compare_exchange_n(&ivars->phantomTxScheduled[port][ch], &expected, true,
                                    false, __ATOMIC_ACQ_REL, __ATOMIC_RELAXED)) {
        txq->DispatchAsync(^{
            for (;;) {
                uint32_t gen = __atomic_load_n(&ivars->pendingPhantomGen[port][ch], __ATOMIC_ACQUIRE);
                uint8_t  val = __atomic_load_n(&ivars->pendingPhantom[port][ch], __ATOMIC_RELAXED);
                const uint32_t pendingHost = __atomic_load_n(&ivars->pendingPhantomHost[port][ch], __ATOMIC_RELAXED);
                const bool pendingTypeKnown = __atomic_load_n(&ivars->pendingPhantomTypeKnown[port][ch], __ATOMIC_RELAXED);
                const bool pendingInstrument = __atomic_load_n(&ivars->pendingPhantomInstrument[port][ch], __ATOMIC_RELAXED);
                uint32_t resolvedPort = 0, resolvedChannel = 0;
                const bool routeUnchanged = ResolveMicPreRoute(ivars, pendingHost, resolvedPort, resolvedChannel) &&
                    resolvedPort == port && resolvedChannel == ch &&
                    (port ? __atomic_load_n(&ivars->unitBMicPreTypeKnown[ch], __ATOMIC_ACQUIRE) :
                        __atomic_load_n(&ivars->micPreTypeKnown[ch], __ATOMIC_ACQUIRE)) == pendingTypeKnown &&
                    (port ? __atomic_load_n(&ivars->unitBMicPreInstrument[ch], __ATOMIC_ACQUIRE) :
                        __atomic_load_n(&ivars->micPreInstrument[ch], __ATOMIC_ACQUIRE)) == pendingInstrument;
                // ON needs the route it was admitted for. OFF is the safe direction:
                // it still reaches the channel the request was made for, so a route
                // change can never leave +48 V on a channel the user just switched off.
                if (XLinkTxAdmissible(ivars) &&
                    (val == 0 || (routeUnchanged && pendingTypeKnown && MicPreIsMic(ivars, port, ch) &&
                                  HalMicArmed(ivars, port, ch) && !MicPreSettling(ivars))) &&
                    (!port || (ivars->unitBConfigured && CardMixerUnitBActive(ivars)))) {
                    uint8_t pData = val;   // 1=on, 0=off
                    const bool sent = SendVendorRequestOn(ivars->pciDevice, ivars->barMemoryIndex,
                                      port ? kRegXLink2TX : kRegXLink1TX,
                                      port ? 1 : ivars->symphonyAddr, kSIOCmd_PhantomPower,
                                      ch, &pData, 1, port ? ivars->runtimeTxSeq2 : ivars->runtimeTxSeq);
                    if (sent && val == 0) StampHalPhantomOff(ivars, port, ch);
                }
                __atomic_store_n(&ivars->phantomTxScheduled[port][ch], false, __ATOMIC_RELEASE);
                if (__atomic_load_n(&ivars->pendingPhantomGen[port][ch], __ATOMIC_ACQUIRE) == gen)
                    break;
                bool exp2 = false;
                if (!__atomic_compare_exchange_n(&ivars->phantomTxScheduled[port][ch], &exp2, true,
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
    if (!ivars || channel >= 64) return kIOReturnBadArgument;
    const uint32_t hostChannel = channel;
    uint32_t port = 0, ch = 0;
    if (!ResolveMicPreRoute(ivars, channel, port, ch)) return kIOReturnNotReady;
    IODispatchQueue *txq = ivars->xlinkQueue;
    if (!txq) {
        STERR("RequestMicGain: no XLink queue (setup incomplete)");
        return kIOReturnNotReady;
    }
    if (__atomic_load_n(&ivars->txShutdown, __ATOMIC_ACQUIRE)) {
        STERR("RequestMicGain: TX shut down — not sending");
        return kIOReturnNotReady;
    }
    // Unit A: an unknown type (the start-up 0x60 read failed and no type write
    // has been seen) is treated as Mic, as every driver before build 132 did, so
    // the DAW's gain control never goes dead (review 2026-11-19 finding 9).
    // Unit B (new in 132, B10): unknown refuses rather than guessing.
    if (port && !__atomic_load_n(&ivars->unitBMicPreTypeKnown[ch], __ATOMIC_ACQUIRE)) return kIOReturnNotReady;
    const bool admittedTypeKnown = port ? __atomic_load_n(&ivars->unitBMicPreTypeKnown[ch], __ATOMIC_ACQUIRE) :
        __atomic_load_n(&ivars->micPreTypeKnown[ch], __ATOMIC_ACQUIRE);
    const bool instrument = port ? __atomic_load_n(&ivars->unitBMicPreInstrument[ch], __ATOMIC_ACQUIRE) :
        (admittedTypeKnown && __atomic_load_n(&ivars->micPreInstrument[ch], __ATOMIC_ACQUIRE));
    const uint32_t lane = instrument ? 1 : 0;
    const uint8_t command = instrument ? kSIOCmd_InstrumentGain : kSIOCmd_MicGain;
    const float maxDb = instrument ? 65.0f : kMicGainMaxDb;
    // Clamp + quantize to the selected MicPre8 gain range before publishing.
    if (!(decibels == decibels)) return kIOReturnBadArgument;
    float clamped = decibels;
    if (clamped < kMicGainMinDb) clamped = kMicGainMinDb;
    if (clamped > maxDb) clamped = maxDb;
    uint8_t gainByte = (uint8_t)(clamped + 0.5f);   // round to nearest dB
    __atomic_store_n(&ivars->pendingMicGain[port][lane][ch], gainByte, __ATOMIC_RELAXED);
    __atomic_store_n(&ivars->pendingMicGainHost[port][lane][ch], (uint8_t)hostChannel, __ATOMIC_RELAXED);
    __atomic_store_n(&ivars->pendingMicGainTypeKnown[port][lane][ch], admittedTypeKnown, __ATOMIC_RELAXED);
    __atomic_store_n(&ivars->pendingMicGainInstrument[port][lane][ch], instrument, __ATOMIC_RELAXED);
    __atomic_fetch_add(&ivars->pendingMicGainGen[port][lane][ch], 1, __ATOMIC_RELEASE);
    bool expected = false;
    if (__atomic_compare_exchange_n(&ivars->micGainTxScheduled[port][lane][ch], &expected, true,
                                    false, __ATOMIC_ACQ_REL, __ATOMIC_RELAXED)) {
        txq->DispatchAsync(^{
            for (;;) {
                uint32_t gen = __atomic_load_n(&ivars->pendingMicGainGen[port][lane][ch], __ATOMIC_ACQUIRE);
                uint8_t  val = __atomic_load_n(&ivars->pendingMicGain[port][lane][ch], __ATOMIC_RELAXED);
                const uint32_t pendingHost = __atomic_load_n(&ivars->pendingMicGainHost[port][lane][ch], __ATOMIC_RELAXED);
                const bool pendingTypeKnown = __atomic_load_n(&ivars->pendingMicGainTypeKnown[port][lane][ch], __ATOMIC_RELAXED);
                const bool pendingInstrument = __atomic_load_n(&ivars->pendingMicGainInstrument[port][lane][ch], __ATOMIC_RELAXED);
                uint32_t resolvedPort = 0, resolvedChannel = 0;
                const bool routeUnchanged = ResolveMicPreRoute(ivars, pendingHost, resolvedPort, resolvedChannel) &&
                    resolvedPort == port && resolvedChannel == ch &&
                    (port ? __atomic_load_n(&ivars->unitBMicPreTypeKnown[ch], __ATOMIC_ACQUIRE) :
                        __atomic_load_n(&ivars->micPreTypeKnown[ch], __ATOMIC_ACQUIRE)) == pendingTypeKnown &&
                    (port ? __atomic_load_n(&ivars->unitBMicPreInstrument[ch], __ATOMIC_ACQUIRE) :
                        __atomic_load_n(&ivars->micPreInstrument[ch], __ATOMIC_ACQUIRE)) == pendingInstrument;
                if (XLinkTxAdmissible(ivars) && routeUnchanged &&
                    (!port || (ivars->unitBConfigured && CardMixerUnitBActive(ivars)))) {
                    uint8_t pData = val;   // gain 0..85
                    if (SendVendorRequestOn(ivars->pciDevice, ivars->barMemoryIndex,
                                          port ? kRegXLink2TX : kRegXLink1TX,
                                          port ? 1 : ivars->symphonyAddr, command,
                                          ch, &pData, 1, port ? ivars->runtimeTxSeq2 : ivars->runtimeTxSeq)) {
                        // Only the HAL calls RequestMicGain: record it for the app.
                        StampHalMicPreEdit(ivars, port, ch,
                                           (uint32_t(val) << kMicPreEditGainShift) | kMicPreEditGainValid |
                                               (lane ? kMicPreEditGainInstrument : 0u),
                                           kMicPreEditGainMask | kMicPreEditGainValid | kMicPreEditGainInstrument);
                        if (port == 1) {
                            ivars->unitBMicPreGain[lane][ch] = val;
                            ivars->unitBMicPreGainKnown[lane][ch] = true;
                            PublishMicGain(ivars, ch, 1);
                        } else {
                            ivars->micPreGain[lane][ch] = val;
                            ivars->micPreGainKnown[lane][ch] = true;
                            if (lane == (__atomic_load_n(&ivars->micPreInstrument[ch], __ATOMIC_ACQUIRE) ? 1u : 0u))
                                PublishMicGain(ivars, ch);
                        }
                    }
                }
                __atomic_store_n(&ivars->micGainTxScheduled[port][lane][ch], false, __ATOMIC_RELEASE);
                if (__atomic_load_n(&ivars->pendingMicGainGen[port][lane][ch], __ATOMIC_ACQUIRE) == gen)
                    break;
                bool exp2 = false;
                if (!__atomic_compare_exchange_n(&ivars->micGainTxScheduled[port][lane][ch], &exp2, true,
                                                 false, __ATOMIC_ACQ_REL, __ATOMIC_RELAXED))
                    break;
            }
        });
    }
    STLOG("RequestMicGain: ch=%u gain=%u [coalesced]", ch, gainByte);
    return kIOReturnSuccess;
}

// ── RequestPhaseInvert / RequestHighPass / RequestInputType ─────────────────
// The DAW-facing MicPre controls. Each request is admitted here, coalesced on
// its own lane (QueueMicPreLane) and sent from the serial XLink queue. A
// control's value moves only when PublishMicPreControls publishes what the
// unit took; a refused or dropped request republishes the real value.

kern_return_t SymphonyThunderbridge::RequestPhaseInvert(uint32_t channel, bool on)
{
    return RequestMicPreSwitch(ivars, kMicPreLanePhase, channel, on);
}

kern_return_t SymphonyThunderbridge::RequestHighPass(uint32_t channel, bool on)
{
    return RequestMicPreSwitch(ivars, kMicPreLaneHighPass, channel, on);
}

kern_return_t SymphonyThunderbridge::RequestInputType(uint32_t channel, uint32_t type)
{
    if (!ivars || channel >= 64 || type > 4) return kIOReturnBadArgument;
    uint32_t port = 0, ch = 0;
    if (!ResolveMicPreRoute(ivars, channel, port, ch) || !ivars->xlinkQueue ||
        __atomic_load_n(&ivars->txShutdown, __ATOMIC_ACQUIRE)) return kIOReturnNotReady;
    // Instrument exists on MicPre channels 1-4 only (SymphonyIOBoard_MicPre8ch.cpp:26,970-974).
    if (ch >= 4 && type == 4) return kIOReturnBadArgument;
    if (MicPreSettling(ivars)) {
        STERR("RequestInputType: refused during the settle window (coreaudiod restore)");
        RepublishMicPreHostLater(ivars, channel);
        return kIOReturnNotPermitted;
    }
    QueueMicPreLane(ivars, kMicPreLaneType, port, ch, CoreInputTypeToWire(type), channel);
    STLOG("RequestInputType: host=%u -> port %u ch%u type=%u [coalesced]", channel, port, ch, type);
    return kIOReturnSuccess;
}
