// Sym64Registers.h — FPGA register map for Symphony64 / ThunderBridge
// Ported from og_source/symphonymk1/ext/Symphony64/Driver/Sym64Registers.h
// for use with DriverKit (no IOKit pointer macros).
//
// All offsets are byte offsets from BAR0 base for use with
// IOPCIDevice::MemoryRead32(memoryIndex, offset, &value).

#pragma once
#include <cstdint>

// ── Core Registers ──────────────────────────────────────────────────────────

static constexpr uint64_t kRegIDReg           = 0x00;  // Board ID (FPGA version, hardware version, master/slave)
static constexpr uint64_t kRegGCSR            = 0x04;  // General Control/Status Register
static constexpr uint64_t kRegIntStatus       = 0x08;  // Interrupt status
static constexpr uint64_t kRegIntMask         = 0x0C;  // Interrupt mask
static constexpr uint64_t kRegScratch         = 0x10;  // Scratch register (0xDEADBEEF test)
static constexpr uint64_t kRegClkCtrl         = 0x14;  // Clock control
static constexpr uint64_t kRegJam             = 0x18;  // Sample phase jam
static constexpr uint64_t kRegMeterTimer      = 0x1C;  // Metering timer
static constexpr uint64_t kRegMeterHBA        = 0x20;  // Meter DMA host base address
// Meter DMA: 256-word (1 KB) buffer; timer = METER_DMA_FREQUENCY(100 ms) *
// METER_CLOCK_FREQUENCY(66000/512=128) = 12800 (~100 ms). Requires FPGA >= 20
// (FIRMWARE_SUPPORTS_METERING). Per word: peak = bits[31:24], over = bit1.
static constexpr uint32_t kMeterBufferWords   = 256;
static constexpr uint64_t kMeterBufferBytes   = 1024;
static constexpr uint32_t kMeterTimerValue    = 12800;
static constexpr uint32_t kMeterFPGAMinVersion = 20;
static constexpr uint32_t kMeterPeakShift     = 24;   // peak magnitude in top 8 bits
static constexpr uint32_t kMeterOverMask      = 0x2;  // over-level latched flag
static constexpr uint64_t kRegA2HBUFSIZE      = 0x24;  // Audio-to-Host buffer size (Port 1)
static constexpr uint64_t kRegA2HHBA          = 0x28;  // Audio-to-Host host buffer address (Port 1)
static constexpr uint64_t kRegA2HCHA          = 0x2C;  // Audio-to-Host current address (Port 1)
static constexpr uint64_t kRegH2AHBA          = 0x30;  // Host-to-Audio host buffer address
static constexpr uint64_t kRegH2ACHA          = 0x34;  // Host-to-Audio current address
static constexpr uint64_t kRegXLink1TX        = 0x38;  // XLink 1 transmit
static constexpr uint64_t kRegXLink1RX        = 0x3C;  // XLink 1 receive
static constexpr uint64_t kRegXLink1Status    = 0x40;  // XLink 1 status
static constexpr uint64_t kRegFPGATest        = 0x44;  // FPGA test (unused)
static constexpr uint64_t kRegFlash           = 0x48;  // Flash update control/status
static constexpr uint64_t kRegH2ABUFSIZE      = 0x4C;  // Host-to-Audio buffer size
static constexpr uint64_t kRegFlashUpdateSize = 0x50;  // Flash update size
static constexpr uint64_t kRegRxStatusErr     = 0x54;  // RX status error (clear on startup)
static constexpr uint64_t kRegClearOvers      = 0x58;  // Clear overflows

// ── XLink 2 & Clocking ─────────────────────────────────────────────────────

static constexpr uint64_t kRegXLinkClocking   = 0x5C;  // XLink clock detection & sample rate
static constexpr uint64_t kRegXLink2Status    = 0x60;  // XLink 2 status
static constexpr uint64_t kRegXLink2TX        = 0x68;  // XLink 2 transmit
static constexpr uint64_t kRegXLink2RX        = 0x6C;  // XLink 2 receive

// ── DNA & Port 2 ───────────────────────────────────────────────────────────

static constexpr uint64_t kRegDNALower        = 0x70;  // Device DNA serial (lower 32)
static constexpr uint64_t kRegDNAUpper        = 0x74;  // Device DNA serial (upper 32)
static constexpr uint64_t kRegA2H2BUFSIZE     = 0x78;  // Audio-to-Host buffer size (Port 2)
static constexpr uint64_t kRegA2H2HBA         = 0x7C;  // Audio-to-Host host buffer addr (Port 2)
static constexpr uint64_t kRegA2H2CHA         = 0x80;  // Audio-to-Host current addr (Port 2)
static constexpr uint64_t kRegH2A2HBA         = 0x84;  // Host-to-Audio host buffer addr (Port 2)
static constexpr uint64_t kRegH2A2CHA         = 0x88;  // Host-to-Audio current addr (Port 2)
static constexpr uint64_t kRegH2A2BUFSIZE     = 0x8C;  // Host-to-Audio buffer size (Port 2)
static constexpr uint64_t kRegGCSR2           = 0x90;  // General Control/Status 2 (Port 2 DMA)
static constexpr uint64_t kRegExpansionClk    = 0x94;  // Expansion bus clock detection
static constexpr uint64_t kRegSPITransfer     = 0x98;  // SPI transfer control (CS2000, FPGA flash)

// ── LED Registers (ThunderBridge only) ──────────────────────────────────────

static constexpr uint64_t kRegPort0RedCtl     = 0xA0;
static constexpr uint64_t kRegPort0GreenCtl   = 0xA4;
static constexpr uint64_t kRegPort0BlueCtl    = 0xA8;
static constexpr uint64_t kRegPort1RedCtl     = 0xAC;
static constexpr uint64_t kRegPort1GreenCtl   = 0xB0;
static constexpr uint64_t kRegPort1BlueCtl    = 0xB4;

// ── Routing & Mixer ─────────────────────────────────────────────────────────

static constexpr uint64_t kRegInputRouting    = 0x2000;
static constexpr uint64_t kRegOutputRouting   = 0x2100;
static constexpr uint64_t kRegMixerRouting    = 0x2200;  // 0x2000 + 128*4
static constexpr uint64_t kRegMixerControl    = 0x2210;  // 0x2000 + 132*4
static constexpr uint64_t kRegExpansion       = 0x2214;  // 0x2000 + 133*4

// ── Sample Memory ───────────────────────────────────────────────────────────

static constexpr uint64_t kRegMixerCoeff      = 0x4000;   // Mixer coefficients (0x1000 bytes)
// Card FPGA low-latency mixer coefficient encoding & addressing.
// Evidence (original Apogee source): Sym64Mixer.cpp:73-83 GetMixerCoefOffset (word
// offset) ×4 → byte offset; Sym64MixerRegisters.h (top-16 bits hold the 16-bit gain);
// SymphonyPCIeCardMixer.cpp:1263-1268 ConvertMixerGain (dGain/4 → l=gain*0x8000 →
// (l&0xFFFF)<<16). Unity (0 dB) = MIX_UNITY 0x2000 in top16 = 0x20000000; mute = 0.
// 4 physical mixers: 0=A-L, 1=A-R, 2=B-L, 3=B-R; each emits TDM slot 128+m.
static constexpr uint32_t kMixerUnityCoeff    = 0x20000000; // 0 dB (MIX_UNITY 0x2000 << 16)
static constexpr uint32_t kMixerMuteCoeff     = 0x00000000; // -inf
// Byte offset into the coefficient RAM for physical mixer m (0..3), TDM slot (0..131).
static inline uint64_t MixerCoefOffset(uint32_t m, uint32_t slot) {
    return kRegMixerCoeff + (uint64_t)(slot * 2u + (m >> 1) + (m & 1u) * 0x200u) * 4u;
}
static constexpr uint64_t kRegSampleIn1Base   = 0x8000;
static constexpr uint64_t kRegSampleIn2Base   = 0xA000;
static constexpr uint64_t kRegSampleOut1Base  = 0xC000;
static constexpr uint64_t kRegSampleOut2Base  = 0xE000;
static constexpr uint64_t kSSRAMBase          = 0x200000;

// ── GCSR Bit Masks (Port 1 DMA Control) ─────────────────────────────────────
// Legacy: Sym64Registers.h:127-166

// NOTE: 0x40000000 is SM_MISC_IT (Interrupt-Test) in the legacy header, NOT
// Meter-DMA-Enable. The real SM_MISC_MDE is 0x20000000. Using 0x40000000 here
// meant every clear-meter-DMA cleared the wrong bit (and left MDE untouched).
// Verified against og_source/symphonymk1/ext/Symphony64/Driver/Sym64Registers.h
// (SM_MISC_IT=0x40000000, SM_MISC_MDE=0x20000000).
static constexpr uint32_t kGCSR_MeterDMAEnable    = 0x20000000;  // SM_MISC_MDE
static constexpr uint32_t kGCSR_ManualMeterTrig   = 0x10000000;  // SM_MISC_MTR
static constexpr uint32_t kGCSR_MeterTrigSelect   = 0x08000000;  // SM_MISC_MTS — 1=timer, 0=manual
static constexpr uint32_t kGCSR_A2HDMAEnable      = 0x04000000;  // SM_MISC_AHE
static constexpr uint32_t kGCSR_A2HTrigger        = 0x02000000;  // SM_MISC_AHT
static constexpr uint32_t kGCSR_A2HTrigSelect     = 0x01000000;  // SM_MISC_AHS
static constexpr uint32_t kGCSR_H2ADMAEnable      = 0x00800000;  // SM_MISC_HAE
static constexpr uint32_t kGCSR_H2ATrigger        = 0x00400000;  // SM_MISC_HAT
static constexpr uint32_t kGCSR_H2ATrigSelect     = 0x00200000;  // SM_MISC_HAS
static constexpr uint32_t kGCSR_A2HBigEndian      = 0x00100000;  // SM_MISC_AHND
static constexpr uint32_t kGCSR_H2ABigEndian      = 0x00080000;  // SM_MISC_HAND
static constexpr uint32_t kGCSR_A2HIntToFloat     = 0x00040000;  // SM_MISC_AHCN
static constexpr uint32_t kGCSR_H2AFloatToInt     = 0x00020000;  // SM_MISC_HACN
static constexpr uint32_t kGCSR_DDSMask           = 0x0000E000;
static constexpr uint32_t kGCSR_MasterLEDFlash    = 0x00000800;
static constexpr uint32_t kGCSR_MasterLEDSolid    = 0x00000400;
static constexpr uint32_t kGCSR_ClockOKFlash      = 0x00000200;
static constexpr uint32_t kGCSR_ClockOKSolid      = 0x00000100;
static constexpr uint32_t kGCSR_OnlyMasterDMA     = 0x00000080;  // SM_MISC_ONLY_MASTER_DMA

// Port 1 DMA channel count (GCSR bits[5:0]) — same bit layout as GCSR2
// Legacy: SM_MISC_DMAOUTPUT_SIZE32 = 0x18, SM_MISC_DMAINPUT_SIZE32 = 0x03
static constexpr uint32_t kGCSR_DMAOutSize32      = 0x00000018;  // bits[4:3]=11 → 32 output channels
static constexpr uint32_t kGCSR_DMAInSize32       = 0x00000003;  // bits[1:0]=11 → 32 input channels
static constexpr uint32_t kGCSR_DMAMask           = 0x0000003F;  // bits[5:0]

// Endianness — AHND/HAND = "Non-Default" byte order.
// FPGA native TDM format is Big Endian (PPC era).
//   AHND/HAND=0: FPGA default = Big Endian DMA data
//   AHND/HAND=1: Non-default = Little Endian DMA data (swap to host byte order)
// MUST be set on Intel and Apple Silicon (both LE) for correct SInt32 DMA.
// Legacy: Symphony64Card.cpp:192 sets both (via `defined(TARGET_RT_BIG_ENDIAN)` quirk).
static constexpr uint32_t kGCSR_SwapToLE          = kGCSR_A2HBigEndian | kGCSR_H2ABigEndian;  // 0x00180000 — SET on LE hosts

// Combined masks for DMA enable/disable
static constexpr uint32_t kGCSR_DMAEnableMask     = kGCSR_A2HDMAEnable | kGCSR_H2ADMAEnable
                                                   | kGCSR_A2HTrigSelect | kGCSR_H2ATrigSelect
                                                   | kGCSR_MeterDMAEnable | kGCSR_MeterTrigSelect;

// ── GCSR2 Bit Masks (Port 2 DMA Control) ───────────────────────────────────
// Legacy: Sym64Registers.h:178-206

static constexpr uint32_t kGCSR2_A2HDMAEnable     = 0x04000000;  // SM_MISC2_AHE
static constexpr uint32_t kGCSR2_A2HTrigger       = 0x02000000;  // SM_MISC2_AHT
static constexpr uint32_t kGCSR2_A2HTrigSelect    = 0x01000000;  // SM_MISC2_AHS
static constexpr uint32_t kGCSR2_H2ADMAEnable     = 0x00800000;  // SM_MISC2_HAE
static constexpr uint32_t kGCSR2_H2ATrigger       = 0x00400000;  // SM_MISC2_HAT
static constexpr uint32_t kGCSR2_H2ATrigSelect    = 0x00200000;  // SM_MISC2_HAS
static constexpr uint32_t kGCSR2_DisablePort1     = 0x00001000;
static constexpr uint32_t kGCSR2_DisablePort2     = 0x00002000;
static constexpr uint32_t kGCSR2_DMAOutSize32     = 0x00000018;  // 32 output channels
static constexpr uint32_t kGCSR2_DMAInSize32      = 0x00000003;  // 32 input channels
static constexpr uint32_t kGCSR2_DMAMask          = 0x0000003F;
static constexpr uint32_t kGCSR2_DMAEnableMask    = kGCSR2_A2HDMAEnable | kGCSR2_H2ADMAEnable
                                                   | kGCSR2_A2HTrigSelect | kGCSR2_H2ATrigSelect;

// ── Clock Control Register ──────────────────────────────────────────────────
// Legacy: Sym64Registers.h:276-292

static constexpr uint32_t kClkCtrl_UseExternal    = 0x80000000;  // SAMPLE_FRAME_USE_EXTERNAL
static constexpr uint32_t kClkCtrl_Unmute         = 0x40000000;  // SAMPLE_FRAME_UNMUTE
static constexpr uint32_t kClkCtrl_InputUnmute    = 0x20000000;  // SAMPLE_FRAME_IN_UNMUTE
static constexpr uint32_t kClkCtrl_OutputUnmute   = 0x10000000;  // SAMPLE_FRAME_OUT_UNMUTE
static constexpr uint32_t kClkCtrl_FrameMask      = 0x000000FC;  // SAMPLE_FRAME_MASK
static constexpr uint32_t kClkCtrl_FrameShift     = 2;           // SAMPLE_FRAME_SHIFT

// ── DMA Buffer Constants ────────────────────────────────────────────────────
// Legacy: SymphonyDrivers.h:50-96

static constexpr uint32_t kNumSampleFrames        = 8192;        // NUM_SAMPLE_FRAMES
static constexpr uint32_t kAudioBitDepth          = 32;          // AUDIO_BIT_DEPTH (bits)
static constexpr uint32_t kMaxChannelsPerPort     = 32;          // MAX_SYMPHONY_CHANNELS_ON_PORT
static constexpr uint32_t kFPGAMaxFrameSize       = 64;          // FPGA_MAX_FRAME_SIZE (samples)

// The legacy Symphony 64/ThunderBridge driver had an explicit High Performance
// profile.  Its per-rate FPGA frame sizes were 4/8/32 samples (44.1/48,
// 88.2/96, 176.4/192 kHz), with 10/20/32-sample safety offsets.  The initial
// DriverKit port used the Standard profile's 32-sample frame and safety offset
// at every rate, which needlessly raises the minimum I/O latency.  Keep the
// profile choice in one place so the experimental build can be reverted to the
// proven Standard values without touching the audio-path code.
static constexpr bool    kUseHighPerformanceProfile = true;
static constexpr uint32_t kStandardFPGAFrameSize    = 32;
static constexpr uint32_t kStandardSafetyOffset     = 32;
static constexpr uint32_t kHighPerformanceFrameLow  = 4;
static constexpr uint32_t kHighPerformanceFrameMid  = 8;
static constexpr uint32_t kHighPerformanceFrameHigh = 32;
static constexpr uint32_t kHighPerformanceSafetyLow = 10;
static constexpr uint32_t kHighPerformanceSafetyMid = 20;
static constexpr uint32_t kHighPerformanceSafetyHigh = 32;
static constexpr uint64_t kDMABufferSize          = (uint64_t)kNumSampleFrames
                                                   * kMaxChannelsPerPort
                                                   * (kAudioBitDepth / 8);  // 1,048,576 bytes (1MB)

// ── Interrupt Status/Mask Bits ──────────────────────────────────────────────

static constexpr uint32_t kInt_A2HWrap            = 0x80000000;  // Port 1 A2H DMA wrap
static constexpr uint32_t kInt_HostBufOverflow     = 0x40000000;  // Port 1 A2H overflow
static constexpr uint32_t kInt_AudioBufUnderflow   = 0x20000000;  // Port 1 H2A underflow
static constexpr uint32_t kInt_MeterTrigger        = 0x10000000;
static constexpr uint32_t kInt_H2AWrap            = 0x04000000;  // Port 1 H2A DMA wrap
static constexpr uint32_t kInt_A2H2Wrap           = 0x02000000;  // Port 2 A2H wrap
static constexpr uint32_t kInt_HostBufOverflow2    = 0x01000000;  // Port 2 overflow
static constexpr uint32_t kInt_AudioBufUnderflow2  = 0x00800000;  // Port 2 underflow
static constexpr uint32_t kInt_H2A2Wrap           = 0x00400000;  // Port 2 H2A wrap

// ── Board ID Macros ─────────────────────────────────────────────────────────

static constexpr uint32_t kBoardIsMasterBit       = 0x20;
static constexpr uint32_t kBoardSlave1Bits        = 0x08;  // bits[4:3] = 01
static constexpr uint32_t kBoardSlave2Bits        = 0x10;  // bits[4:3] = 10

inline uint32_t GetFPGAVersion(uint32_t idReg) { return (idReg >> 24) & 0xFF; }
inline uint32_t GetHardwareVersion(uint32_t idReg) { return idReg & 0x03; }
inline bool IsBoardMaster(uint32_t idReg) { return (idReg & kBoardIsMasterBit) != 0; }

// ── XLink Clocking Bits ─────────────────────────────────────────────────────

static constexpr uint32_t kXLinkClockEnable1      = 0x00004000;
static constexpr uint32_t kXLinkClockEnable2      = 0x40000000;
static constexpr uint32_t kXLinkRX1ClockDetect    = 0x00000100;
static constexpr uint32_t kXLinkRX2ClockDetect    = 0x01000000;
static constexpr uint32_t kXLinkSR1Mask           = 0x0000003F;  // Primary sample rate detect
static constexpr uint32_t kXLinkSR2Mask           = 0x003F0000;  // Secondary sample rate detect

// XLink clock rate detection bits (from kRegXLinkClocking, primary port)
// Legacy: Sym64Registers.h:474-484
static constexpr uint32_t kXLinkSRDetect1_44100   = 0x00000001;
static constexpr uint32_t kXLinkSRDetect1_48000   = 0x00000002;
static constexpr uint32_t kXLinkSRDetect1_88200   = 0x00000004;
static constexpr uint32_t kXLinkSRDetect1_96000   = 0x00000008;
static constexpr uint32_t kXLinkSRDetect1_176400  = 0x00000010;
static constexpr uint32_t kXLinkSRDetect1_192000  = 0x00000020;

// ── XLink Commands ─────────────────────────────────────────────────────────

static constexpr uint32_t kXLinkResetCmd          = 0x00FFFFFF;  // Bus reset command

// ── ThunderBridge Hardware Revisions ────────────────────────────────────────

static constexpr uint32_t kThunderBridgeHWRevWithRGBLeds = 1;  // HW rev 1+ has RGB LEDs

// ── XLink Status Bits ───────────────────────────────────────────────────────

static constexpr uint32_t kXLinkRX18DownSticky    = 0x00000001;
static constexpr uint32_t kXLinkRX18SlipSticky    = 0x00000020;
static constexpr uint32_t kXLinkDataSlipSticky    = 0x00000200;
// Current (non-sticky) link state. These are the authoritative live bits for
// distinguishing a powered-down downstream Symphony from an enumerated
// ThunderBridge PCI function. The legacy driver logs the same fields after
// XLink configuration (SymphonyThunderbridge.cpp:1920).
static constexpr uint32_t kXLinkDataDownCurrent   = 1u << 14;
static constexpr uint32_t kXLinkDataSlipCurrent   = 1u << 19;
static constexpr uint32_t kXLinkSlaveMode         = 0x00100000;

// ── SPI Transfer Bits ───────────────────────────────────────────────────────

static constexpr uint32_t kSPI_FlashHoldN         = 1 << 14;
static constexpr uint32_t kSPI_FlashWPN           = 1 << 13;
static constexpr uint32_t kSPI_Busy               = 1 << 12;
static constexpr uint32_t kSPI_Trigger            = 1 << 10;
static constexpr uint32_t kSPI_MuxCtlMask         = 3 << 8;   // 0=CS2000, 1=FPGA flash
static constexpr uint32_t kSPI_DataMask           = 0xFF;

// ── Flash Bits ──────────────────────────────────────────────────────────────

static constexpr uint32_t kFlashUpdateGolden      = 0x08000000;

// ── Scratch Test Value ──────────────────────────────────────────────────────

static constexpr uint32_t kScratchTestPattern     = 0xDEADBEEF;

// ── Minimum FPGA Version ────────────────────────────────────────────────────
// Legacy: MINIMUM_FPGA_VER = 1 (SymphonyDrivers.h:59)
// ThunderBridge HW v1 ships with FPGA v17 (0x11).

static constexpr uint32_t kMinimumFPGAVersion     = 1;

// ── TDM Bus Slot Assignments ──────────────────────────────────────────────
// The FPGA has a 132-slot internal TDM bus. All routing crosspoints
// reference these slot numbers. (Sym64RoutingRegisters.h)

static constexpr uint32_t kTDM_XLinkRX0           = 0;    // XLink receive (from Symphony IO ADCs)
static constexpr uint32_t kTDM_PCIOut0             = 64;   // PCI/DMA output (from host H2A buffer)
static constexpr uint32_t kTDM_Mixer0Out           = 128;  // Mixer output 0

// ── Routing Register Format ──────────────────────────────────────────────
// Each routing entry: bits[7:0] = source TDM slot, bit[8] = enable

static constexpr uint32_t kRoutingEnable           = 0x100;
static constexpr uint32_t kRoutingSlotMask         = 0xFF;
static constexpr uint32_t kOutputRoutingChannels   = 64;
static constexpr uint32_t kInputRoutingChannels    = 64;

// ── DDS (Direct Digital Synthesizer) Rate Constants ─────────────────────────
// GCSR bits[15:13] — internal clock reference for the FPGA.
// Legacy: Sym64Registers.h:152-158 (SM_MISC_DDS_xxx)
// When ThunderBridge is in Sym2Sym mode (clock from Symphony IO via XLink),
// the DDS rate must match the actual sample rate for proper FPGA operation.

static constexpr uint32_t kGCSR_DDS_Off           = 0x0000E000;  // SM_MISC_DDS_OFF
static constexpr uint32_t kGCSR_DDS_44100         = 0x00002000;  // SM_MISC_DDS_441000
static constexpr uint32_t kGCSR_DDS_48000         = 0x00004000;  // SM_MISC_DDS_480000
static constexpr uint32_t kGCSR_DDS_88200         = 0x00006000;  // SM_MISC_DDS_882000
static constexpr uint32_t kGCSR_DDS_96000         = 0x00008000;  // SM_MISC_DDS_960000
static constexpr uint32_t kGCSR_DDS_176400        = 0x0000A000;  // SM_MISC_DDS_176400
static constexpr uint32_t kGCSR_DDS_192000        = 0x0000C000;  // SM_MISC_DDS_196000

// ── PCIe Device IDs ─────────────────────────────────────────────────────────

static constexpr uint16_t kApogeeVendorID         = 0x19C2;
static constexpr uint16_t kThunderBridgeDeviceID  = 0x2200;
static constexpr uint16_t kSymphonyPCIeDeviceID  = 0x2100;
