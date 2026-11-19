// SymphonyThunderbridgeShared.h — Shared types between dext and client app.
// Used by AudioDriverKit custom property and IOUserClient to pass vendor commands.
#pragma once

#include <stdint.h>

#define kSymphonyUCMagic        0x53594D50u  // 'SYMP'
#define kSelectorSendVendor     0            // ExternalMethod selector: write command
#define kSelectorReadMeters     1            // ExternalMethod selector: read meter buffer
#define kSelectorReadBoardTypes 2            // ExternalMethod selector: read fitted option boards
#define kSelectorReadTimingHealth 3         // ExternalMethod selector: timing/register snapshot
#define kSelectorReadVendor     4            // ExternalMethod selector: read XLink vendor command
#define kSelectorReadLinkState  5            // ExternalMethod selector: link watch state (no bus access)
#define kSelectorReadDriverBuild 6           // ExternalMethod selector: this dext's CFBundleVersion (dext 123+)
#define kSelectorRetireForUpgrade 7          // ExternalMethod selector: stop serving the device so the copy
                                             // macOS registered to replace this one can take
                                             // it (dext 123+). Takes a
                                             // non-empty SymphonyRetireInput, so a call made with
                                             // another selector's shape (an experimental app
                                             // polling 7 with no input) is refused.
#define kSelectorReadPort2State 8            // EXPERIMENT (64ch): what is on XLink port 2 (no bus access).
                                             // Was 6 in exp64 builds 9001-9003 and 7 in 9004;
                                             // 6 and 7 are released selectors (driver build, retire).
                                             // Each selector checks its exact input and output
                                             // sizes, so an old/new app/dext mismatch is rejected
                                             // and the app treats the answer as absent: a new app
                                             // asking 8 of 9004 gets "no such selector", and
                                             // a retire call (8-byte input) on 9004's no-input
                                             // 7 is refused.
#define kSelectorReadConverters 9            // The older XLink converters on ports 1 and 2 (dext 131+;
                                             // no bus access). See SymphonyConverterStateOutput.
#define kSelectorSetConverterConfig 10       // The user's converter choices: word clock source and
                                             // Device Type (dext 131+). See SymphonyConverterConfigInput.
#define kSelectorReadUnitB      11           // 64ch unit-B state (no bus access)
// Selector 12 is reserved for B6 device information. Existing ABIs are unchanged.
#define kSelectorLoopSync       13
#define kSelectorCount          14

// Version 1: operation 0 reads; 1 applies. config bit 0 = disabled,
// bit 1 = preferred master B (retained while disabled). Zero is the legacy default.
typedef struct { uint32_t magic, version, operation, config; } SymphonyLoopSyncInput;
static inline uint32_t SymphonyLoopSyncInputValid(const SymphonyLoopSyncInput *input) {
    return input && input->magic == kSymphonyUCMagic && input->version == 1 &&
        input->operation <= 1 && input->config <= 3;
}
// valid means both ClockMode writes succeeded; locks are measured independently:
// 0 = not read, 1 = unlocked, 2 = locked. sourceA/B hold the preferred master
// source in bits 7:0 and board input in 15:8. Reads require two configured SIOs at 64.
typedef struct { uint32_t config, valid, lockA, lockB, sourceA, sourceB; } SymphonyLoopSyncOutput;
#define kSymphonyUserClientType 0x53594D43u  // 'SYMC' — our custom IOUserClient type
#define kSymphonyMeterWordCount 256          // words in the card meter DMA buffer

// Custom property selector for vendor commands via AudioDriverKit.
// App uses AudioObjectSetPropertyData with this selector on the audio device.
// FourCC 'SYVC' = Symphony Vendor Command
#define kSymphonyVendorCommandSelector  0x53595643u  // 'SYVC'

#pragma pack(push, 1)

typedef struct {
    uint32_t magic;         // kSymphonyUCMagic — validated by dext
    uint8_t  command;       // SymphonyIOCommand opcode (bRequest)
    uint8_t  port;           // 0 = XLink port 1 / unit A, 1 = port 2 / unit B
    uint8_t  reserved[2];   // alignment padding
    uint32_t value;         // nValue = (wValue << 16) | wIndex
    uint16_t payloadLen;    // number of valid bytes in payload[]
    uint8_t  payload[64];   // command data (max USB control transfer size)
} SymphonyVendorCommandInput;  // 78 bytes

typedef struct {
    uint32_t status;        // 0 = success, nonzero = IOReturn error code
} SymphonyVendorCommandOutput; // 4 bytes

// Output of kSelectorReadMeters — a snapshot of the card FPGA meter DMA buffer.
// Per word: peak magnitude in bits[31:24] (dB = 20*log10(peak/256)); over = bit1.
// Words 0-31 = hardware inputs, 64-95 = host playback, 128-131 = mixer0/1 out.
typedef struct {
    uint32_t status;                             // 0 = success
    uint32_t words[kSymphonyMeterWordCount];     // 256 raw meter words
} SymphonyMeterOutput; // 1028 bytes

// Output of kSelectorReadBoardTypes — the fitted option board in each of the two
// slots, as read from the hardware with OptionBoardType (0xA1) during Start().
// `board[i]` is a SymphonyIOOptionBoardType (matches IOCardType.rawValue on the
// Swift side); `valid[i]` is 0 when that slot's read failed or timed out, in which
// case `board[i]` is meaningless and the caller must NOT treat it as "empty slot".
// Cards are not hot-swappable (the unit is powered down to change them), so the
// Start()-time read is the live value for the life of this dext instance.
typedef struct {
    uint32_t status;        // 0 = success
    uint8_t  board[2];      // slot 0 / slot 1 option board type
    uint8_t  valid[2];      // 1 = read succeeded, 0 = unknown
} SymphonyBoardTypesOutput; // 8 bytes

// Output of kSelectorReadTimingHealth. This is a read-only diagnostic snapshot
// used by the latency study. Register status bits are sampled synchronously
// outside the audio interrupt path.
typedef struct {
    uint32_t status;
    uint32_t clkCtrl;
    uint32_t intStatus;
    uint32_t xlinkStatus;
    uint32_t gcsr;
    uint32_t frameReadback;
    uint32_t expectedFrame;
    uint32_t sampleRate;
    uint32_t inputLatency;
    uint32_t outputLatency;
    uint32_t inputSafety;
    uint32_t outputSafety;
} SymphonyTimingHealthOutput; // 48 bytes

// Output of kSelectorReadLinkState (dext 113). Reads driver state only — no PCI
// transaction — so the app can poll it freely. linkState: 0 unknown, 1 up,
// 2 down (card present, no Symphony clock), 3 recovering (re-lock in progress).
typedef struct {
    uint32_t status;
    uint32_t linkState;
    uint32_t clockPresent;
    uint32_t ioRunning;
    uint32_t irqCountLo;
    uint32_t irqCountHi;
    uint32_t recoveryCount;
    uint32_t hwSuspended;
    uint32_t linkConfigured;
    uint32_t lastClockReg;
    uint32_t watchTicks;
    uint32_t audioWraps;
    uint32_t lastGcsr;        // dext 117: last GCSR the watch sampled
    uint32_t lastXlinkStatus; // dext 117: last XLink1Status the watch sampled
    uint32_t cardReinitCount; // dext 117: ReprogramCardAfterReset runs since Start()
    uint32_t reserved;
} SymphonyLinkStateOutput; // 64 bytes

// The CFBundleVersion of the dext binary answering, so the app can tell which
// build actually serves the ThunderBridge. After an update macOS can keep an
// older copy running the device until restart while sysextd already reports
// the new copy as active. build.sh passes the Info.plist value; a build made
// without it answers 0. Dexts before 123 reject the selector.
#ifndef SYMPHONY_DEXT_BUILD
#define SYMPHONY_DEXT_BUILD 0
#endif

typedef struct {
    uint32_t status;
    uint32_t build;           // CFBundleVersion of the serving dext, 0 = not stamped
} SymphonyDriverBuildOutput; // 8 bytes

// Input/output for kSelectorRetireForUpgrade. After an update sysextd lists the
// new copy as active, but kernelmanagerd refuses to terminate the old copy while
// it holds the PCI device ("being replaced"), so the device stays on the old
// binary until a replug, a restart, or the extension is turned off and on. The
// app, having seen its own activation request complete with a different build
// still serving, asks the serving copy to retire: the driver calls Terminate(0)
// on itself so Stop() runs and the device is free for the copy macOS has
// already registered.
//
// The driver refuses unless magic matches, replacementBuild is nonzero and
// differs from its own stamped build, and its own build is stamped (a dev build
// answering 0 never retires). status 0 = termination requested; the reply is
// sent before Stop() runs. build = the build that is retiring.
#define kSymphonyRetireMagic 0x52455449u     // 'RETI'

typedef struct {
    uint32_t magic;            // kSymphonyRetireMagic
    uint32_t replacementBuild; // CFBundleVersion the app expects to take over
} SymphonyRetireInput;  // 8 bytes

typedef struct {
    uint32_t status;
    uint32_t build;            // CFBundleVersion of the copy that is retiring
} SymphonyRetireOutput; // 8 bytes

// ── EXPERIMENT (64ch, stage 1): second XLink port ───────────────────────────
// The driver uses one XLink port unless the matched IOKit personality carries
// this key with the integer 2. No released Info.plist has it. With 2 the driver
// publishes the port selector; port 2 stays disabled and is not looked at until
// "Port 1-2: 64ch" is selected, as in Apogee's driver. Then it is switched on,
// the units cabled to it are identified and it carries audio (stage 2, below).
#define kSymphonyPortCountKey "SymphonyPortCount"

// SymphonyPort2StateOutput.flags
#define kSymphonyPort2FlagProbed        0x00000001u  // a probe has run (two-port mode only)
#define kSymphonyPort2FlagClockDetected 0x00000002u  // RX2 clock and a detected rate
#define kSymphonyPort2FlagDataLinkUp    0x00000004u  // XLink2Status data-down bit clear
#define kSymphonyPort2FlagLocked        0x00000008u  // no data slip after the bus reset
#define kSymphonyPort2FlagTxTimeout     0x00000010u  // XLink 2 TX stayed busy; enumeration cut short
#define kSymphonyPort2FlagRateFailed    0x00000020u  // the last device rate change did not reach port 2,
                                                     // or port 2 did not lock and report the new rate

// SymphonyPort2StateOutput.unit[n]: bits 7:0 INQUIRE reply, bits 15:8
// XTD_INQUIRE reply, then:
#define kSymphonyPort2UnitInquireOK     0x00010000u  // INQUIRE was answered
#define kSymphonyPort2UnitXtdOK         0x00020000u  // XTD_INQUIRE was answered
#define kSymphonyPort2UnitAddressed     0x00040000u  // given address n+1 and told to pass commands on

// Output of kSelectorReadPort2State. Reads driver state only, like
// kSelectorReadLinkState (whose layout is unchanged). In a one-port build:
// portCount 1, everything else 0.
typedef struct {
    uint32_t status;
    uint32_t portCount;       // 1 or 2
    uint32_t flags;           // kSymphonyPort2Flag*
    uint32_t xlink2Status;    // XLink 2 status register at the last probe
    uint32_t xlinkClocking;   // XLink clocking register at the last probe
    uint32_t gcsr2;           // GCSR2 at the last probe
    uint32_t unitCount;       // entries of unit[] that are filled
    uint32_t unit[4];         // nearest unit first; see kSymphonyPort2Unit*
    uint32_t probeCount;      // probes since Start()
    uint32_t rateHz;          // rate port 2 locked to and reported after the last device
                              // rate change; 0 if it did not, or none since the last probe
    uint32_t rateChanges;     // device rate changes made while a port-2 unit was known
                              // (including ones where nothing could be sent), since Start()
    uint32_t audio;           // stage 2: kSymphonyPort2Audio* (0 in a one-port build)
    uint32_t phase;           // stage 2: kSymphonyPort2Phase* (0 until an alignment has run)
} SymphonyPort2StateOutput; // 64 bytes

// ── EXPERIMENT (64ch, stage 2): audio on port 2 and the port selector ────────
// Two-port builds publish an input and an output data-source selector with the
// original's two entries, in its order (Symphony64AudioEngine.cpp:38-93,
// SymphonyCommon.h:182): the selector value is the entry's index.
//
// The NAMES depart from Apogee's ("Port 1: 32ch" / "Port 1-2: 64ch") on
// purpose. macOS's menu-bar Sound menu shows the selected data source's name
// instead of the device name (Apple names its built-in sources after the
// device, e.g. "MacBook Pro Speakers"), while Logic and other DAWs show only
// the device name. Naming the default entry after the device keeps
// "Symphony I/O: ThunderBridge" on screen everywhere in normal use; the
// 64-channel entry adds "64". Maestro reads these from here
// (PortSelectionTests) and its own picker uses plain labels (PortSelection.swift).
#define kSymphonyDeviceName "Symphony I/O: ThunderBridge"   // the Core Audio device name
#define kSymphonyPortSourcePort1     0u   // kSymphonyPortSourceName32, the default
#define kSymphonyPortSourcePorts1And2 1u  // kSymphonyPortSourceName64
#define kSymphonyPortSourceName32 "Symphony I/O: ThunderBridge"
#define kSymphonyPortSourceName64 "Symphony I/O: ThunderBridge 64"

// SymphonyPort2StateOutput.audio
#define kSymphonyPort2AudioCapable      0x00000001u  // port-2 DMA buffers exist: 64 can be selected
#define kSymphonyPort2AudioActive       0x00000002u  // the card is running both ports (64 channels)
#define kSymphonyPort2AudioPhaseAligned 0x00000004u  // the last phase alignment wrote the jam register
#define kSymphonyPort2AudioPhaseFailed  0x00000008u  // a unit did not answer the phase query, or a jam
                                                     // was still in progress: nothing was written
#define kSymphonyPort2AudioRefused      0x00000010u  // the last request for 64 was refused (see reason)
#define kSymphonyPort2AudioFellBack     0x00000020u  // the driver went from 64 back to 32 by itself
#define kSymphonyPort2AudioPublished64  0x00000040u  // Core Audio's streams are 64 channels now
#define kSymphonyPort2AudioStage2       0x00000080u  // always set by a two-port driver with stage 2
#define kSymphonyPort2AudioReasonShift  8            // bits 15:8: kSymphonyPort2Reason*
#define kSymphonyPort2AudioReasonMask   0x0000FF00u
#define kSymphonyPort2AudioChangesShift 16           // bits 31:16: 32<->64 changes since Start()

// Why 64 was refused or dropped (SymphonyPort2StateOutput.audio bits 15:8).
#define kSymphonyPort2ReasonNone          0u
#define kSymphonyPort2ReasonNoUnit        1u  // no unit with its data link up on port 2
#define kSymphonyPort2ReasonNoBuffers     2u  // the port-2 DMA buffers could not be allocated
#define kSymphonyPort2ReasonRateNotLocked 3u  // port 2 did not lock to the current rate
#define kSymphonyPort2ReasonRegisters     4u  // the card did not keep the port-2 buffer addresses
#define kSymphonyPort2ReasonClockGone     5u  // port 2's unit clock went away while 64 was running
#define kSymphonyPort2ReasonCardReset     6u  // the card lost its registers (sleep); back at 32
#define kSymphonyPort2ReasonRateChange    7u  // port 2 did not follow a sample-rate change
#define kSymphonyPort2ReasonUnreachable   8u  // the card could not be reached (stopping, asleep)

// SymphonyPort2StateOutput.phase: the last phase alignment (og XLink.cpp:1079-1150).
#define kSymphonyPort2PhaseValid        0x80000000u  // an alignment has run
#define kSymphonyPort2PhaseJamMask      0x000000FFu  // value written to the jam register
#define kSymphonyPort2PhaseUnitsShift   8            // bits 15:8: units whose phase was read
#define kSymphonyPort2PhaseBaseShift    16           // bits 23:16: the phase the jam was derived from

// Input/output for kSelectorReadVendor. This is deliberately a bounded,
// read-only counterpart to SymphonyVendorCommandInput. It lets the app read
// routing and other XLink properties after a write, instead of displaying a
// cache or a default table as if it were hardware state.
typedef struct {
    uint32_t magic;
    uint8_t  command;
    uint8_t  port;
    uint8_t  reserved[2];
    uint32_t value;
    uint16_t responseLen;
} SymphonyVendorReadInput; // 16 bytes

typedef struct {
    uint32_t status;
    uint16_t responseLen;
    uint8_t  reserved[2];
    uint8_t  payload[64];
} SymphonyVendorReadOutput; // 72 bytes

typedef struct {
    uint32_t status;
    uint32_t present;        // 1 when a Symphony I/O is configured on port 2
    uint8_t boardType[2];
    uint8_t boardValid[2];
    uint8_t prefix;
    uint8_t clockSource;
    uint8_t reserved[2];
    uint32_t setupFlags;
    uint32_t txErrors;
    uint32_t reserved2[4];
} SymphonyUnitBStateOutput; // 40 bytes


// ── The older XLink converters (dext 131+) ──────────────────────────────────
// AD-16X, DA-16X, DD-16X, Rosetta 800/200 on port 1 and, while 64 channels run,
// port 2. Rules and evidence: SymphonyConverters.h. Both selectors check exact
// sizes; an app that gets "no such selector" uses the older probe word
// (SymphonyLinkStateOutput word 15) and SymphonyPort2StateOutput.

// SymphonyConverterStateOutput.flags
#define kSymphonyConvPort1Converters   0x00000001u  // port 1 positively identified as converters
#define kSymphonyConvPort2Converters   0x00000002u  // port 2 carries converters (64 channels running)
#define kSymphonyConvClockExternal     0x00000004u  // unit 1 of port 1 takes external word clock
#define kSymphonyConvHealthy           0x00000008u  // last health check found every unit locked and in phase
#define kSymphonyConvRecoveryPending   0x00000010u  // a recovery is waiting for a controlled restart
#define kSymphonyConvRoutingApplied    0x00000020u  // the card routing follows the converter placement

// SymphonyConverterStateOutput.unit[port][n], nearest unit first
#define kSymphonyConvUnitInquireMask   0x000000FFu  // INQUIRE reply
#define kSymphonyConvUnitXtdShift      8            // bits 15:8: XTD_INQUIRE reply
#define kSymphonyConvUnitInquireOK     0x00010000u
#define kSymphonyConvUnitXtdOK         0x00020000u
#define kSymphonyConvUnitAddressed     0x00040000u  // given its address and told to pass commands on
#define kSymphonyConvUnitAuthRan       0x00080000u  // the authentication exchange ran
#define kSymphonyConvUnitAuthOK        0x00100000u  // and the unit's answer verified (the original
                                                    // refused a unit that failed; this driver reports it)
#define kSymphonyConvUnitTypeIsDA      0x00200000u  // routing 0x0F used as DA (Device Type), else AD
#define kSymphonyConvUnitIsR200        0x00400000u  // routing 0x05 named Rosetta 200 (Device Type)

typedef struct {
    uint32_t status;
    uint32_t version;         // 1
    uint32_t flags;           // kSymphonyConv*
    uint32_t unitCount[2];    // per port, 0-4
    uint32_t unit[2][4];      // kSymphonyConvUnit*
    uint32_t phase[2];        // last WCLK_PHASE reading, byte n = unit n+1 of that port
    uint32_t healthTicks;     // health checks since Start()
    uint32_t phaseErrors;     // a unit outside 0x01-0x2F
    uint32_t unlocks;         // two readings more than 2 apart
    uint32_t recoveries;      // rate re-sent + realigned, or the port re-initialised
    uint32_t latencyIn;       // converter latency reported to Core Audio (samples, before the frame)
    uint32_t latencyOut;
    uint32_t hostInputs;      // host channels carrying a converter channel
    uint32_t hostOutputs;
    uint32_t config;          // the last SymphonyConverterConfigInput.config applied
    uint32_t reserved[4];
} SymphonyConverterStateOutput; // 112 bytes

// SymphonyConverterConfigInput.config. Mask bit n = port*4 + (unit address - 1).
#define kSymphonyConvConfigClockExternal  0x00000001u
#define kSymphonyConvConfigDDAsDAShift    8          // bits 15:8: routing-0x0F units used as DA-16X
#define kSymphonyConvConfigR200Shift      16         // bits 23:16: routing-0x05 units that are Rosetta 200s

typedef struct {
    uint32_t magic;           // kSymphonyUCMagic
    uint32_t config;
} SymphonyConverterConfigInput; // 8 bytes

#pragma pack(pop)
