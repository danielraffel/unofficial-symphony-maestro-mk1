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
#define kSelectorCount          6
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
    uint8_t  reserved[3];   // alignment padding
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

// Input/output for kSelectorReadVendor. This is deliberately a bounded,
// read-only counterpart to SymphonyVendorCommandInput. It lets the app read
// routing and other XLink properties after a write, instead of displaying a
// cache or a default table as if it were hardware state.
typedef struct {
    uint32_t magic;
    uint8_t  command;
    uint8_t  reserved[3];
    uint32_t value;
    uint16_t responseLen;
} SymphonyVendorReadInput; // 16 bytes

typedef struct {
    uint32_t status;
    uint16_t responseLen;
    uint8_t  reserved[2];
    uint8_t  payload[64];
} SymphonyVendorReadOutput; // 72 bytes

#pragma pack(pop)
