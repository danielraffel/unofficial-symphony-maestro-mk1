/// Symphony IO vendor-specific USB command opcodes.
///
/// Complete enumeration of the XMOS USB vendor-specific control protocol
/// for the Apogee Symphony I/O MKI. Each case maps to a bRequest value
/// used in USB control transfers.
///
/// Evidence: `og_source/maestrolink/Software/SymphonyIO/SymphonyIOVendorSpecific.h`
/// — enum SymphonyIOCommands (100+ opcodes)
/// Evidence: `og_source/maestrolink/Software/SymphonyIO/SymphonyIOControl.cpp`
/// — usage patterns for each command

import Foundation
import MaestroCore

// MARK: - Command Opcode

/// USB vendor-specific command opcodes for Symphony IO.
///
/// These are the bRequest values sent in USB control transfers.
/// Each command has specific wValue encoding and pData format requirements.
///
/// Evidence: `og_source/maestrolink/Software/SymphonyIO/SymphonyIOVendorSpecific.h`
public enum SymphonyIOCommand: UInt8, Sendable, CaseIterable {
    // MARK: Audio Control
    /// Set device sample rate. pData: 1 byte encoding sample rate.
    case setSampleRate = 0x03
    /// Set external clock config (HD mode). pData: 1 byte source selection.
    case setExternalClock = 0x04

    // MARK: Front Panel Metering
    /// Set front panel meter display mode. wValue: meter bank (0=left, 1=right).
    case frontPanelMeterShow = 0x10
    /// Set peak hold mode. pData: 0=off, 1=2sec, 2=infinite.
    case peakHold = 0x11
    /// Set over hold mode. pData: `eSymphonyIOMeteringLEDOverHold`
    /// (`SymphonyIOVendorSpecific.h:706-712`) -- 0=off, 1=2 seconds, 2=infinite,
    /// 3=auto clear. This comment previously read "1=auto-clear, 2=infinite",
    /// which is the same transposition that made the Settings menu send the
    /// wrong mode (fixed in efa0c7b). Over Hold has FOUR values; Peak Hold has
    /// three, and they are not interchangeable lists.
    case overHold = 0x12
    /// Clear front panel meters.
    case clearMeters = 0x13

    // MARK: Analog Reference Levels
    /// Set analog reference level. wValue: bit31=I/O, bits[7:0]=channel.
    case analogReferenceLevel = 0x20
    /// Set digital reference level. wValue: bit31=I/O, bits[7:0]=channel.
    case digitalReferenceLevel = 0x21
    /// Set input soft limiter. nValue: channel → wIndex after split. pData: limiter mode.
    case softLimit = 0x22

    // MARK: Headphone & Speaker
    /// Set headphone volume. nValue: channel (0-1) → wIndex after split. pData: 0-64 attenuation.
    case headphoneVolume = 0x23
    /// Set headphone mute. nValue: channel (0-1) → wIndex after split. pData: bool.
    case headphoneMute = 0x24
    /// Set speaker output mode. pData: 0=off, 2=stereo, 6=5.1, 8=7.1.
    case speakerOutputMode = 0x25
    /// Set speaker output volume. pData: 0-64 attenuation.
    case speakerOutputVolume = 0x26
    /// Set speaker output mute. pData: bool.
    case speakerOutputMute = 0x27

    // MARK: Metering & Routing
    /// Read TDM meter data. wValue: group (0=input, 1=output, 2=mixer).
    case tdmMeterData = 0x30
    /// Get/set audio routing. Read: wIndex=dest, returns src. Write: dest/src pairs.
    case audioRouting = 0x31
    /// Set device channel bank. wValue: usage type enum.
    case deviceChannelBank = 0x32
    /// Get/set optical format. wValue: board index. pData: 0=ADAT, 1=S/PDIF.
    /// Evidence: `SymphonyIOVendorSpecific.h` lines 183-188
    case opticalFormat = 0x34
    /// Get/set S/PDIF coax replace input. wValue: board. pData: replacement channel pair.
    /// Evidence: `SymphonyIOVendorSpecific.h` lines 190-202
    case spdifCoaxReplaceInput = 0x35
    /// Get/set S/PDIF coax mirror output. wValue: board. pData: mirror channel pair.
    /// Evidence: `SymphonyIOVendorSpecific.h` lines 204-216
    case spdifCoaxMirrorOutput = 0x36

    // MARK: Clock & Sync
    /// Set clock mode. pData: 4 bytes (mode, master, loopSync, boardIndex).
    case clockMode = 0x50
    /// Read clock rate and lock status. pData: 5 bytes return.
    case clockRateAndLock = 0x51
    /// Read IO board digital input lock status.
    case ioBoardDigitalInputLock = 0x52
    /// Enable/disable ProTools star sync. pData: bool.
    case proToolsStarSync = 0x53

    // MARK: Current State Reads
    /// Read current analog input type. nValue: channel → wIndex after split. pData: 1 byte return.
    case currentAnalogInputType = 0x60

    // MARK: HD Board 1
    /// HD board 1 clock source selection.
    case hdBoard1ClockSourceSelection = 0x81
    /// HD board 1 clock source index.
    case hdBoard1ClockSourceIndex = 0x82
    /// HD board 1 digital format.
    case hdBoard1DigitalFormat = 0x83
    /// HD board 1 clock qualifier.
    case hdBoard1ClockQualifier = 0x84

    // MARK: HD Board 2
    /// HD board 2 clock source selection.
    case hdBoard2ClockSourceSelection = 0x91
    /// HD board 2 clock source index.
    case hdBoard2ClockSourceIndex = 0x92
    /// HD board 2 digital format.
    case hdBoard2DigitalFormat = 0x93
    /// HD board 2 clock qualifier.
    case hdBoard2ClockQualifier = 0x94

    // MARK: Firmware & Device Info
    /// Read firmware version. wValue: version type enum. pData: 3 bytes return.
    case symphonyIOVersion = 0xA0
    /// Read option board type. wValue: 0=primary, 1=secondary. pData: 1 byte return.
    case optionBoardType = 0xA1
    /// Get/set device operating mode. pData: 1 byte mode enum.
    case symphonyIOMode = 0xA6

    // MARK: Mixer
    /// Set mixer fader level. wValue: bits[23:16]=mixerID, bits[15:0]=channel.
    case mixerFaderLevel = 0xB0
    /// Set mixer input pan. wValue: mixer/channel encoding. pData: 0-128 (64=center).
    case mixerInputPan = 0xB1
    /// Set mixer input solo. wValue: mixer/channel. pData: bool.
    case mixerInputSolo = 0xB2
    /// Set mixer input mute. wValue: mixer/channel. pData: bool.
    case mixerInputMute = 0xB3

    // MARK: Mic Preamp (MicPre8 Board)
    /// Set mic preamp gain. nValue: channel → wIndex after split. pData: 0-85 (dB).
    case micGain = 0xC3
    /// Set instrument input gain. nValue: channel → wIndex after split. pData: 0-65.
    case instrumentGain = 0xC4
    /// Set phase invert. nValue: channel → wIndex after split. pData: bool.
    case phaseInverse = 0xC5
    /// Set phantom power. nValue: channel → wIndex after split. pData: bool.
    case phantomPower = 0xC6
    /// Set mic-pre gain group. nValue: channel → wIndex after split. pData: group
    /// number (0 = Off, 1...8).
    /// Evidence: `SymphonyIOControl.cpp:1755-1770` — `setMicPreGroup(nChannel, nGroupID)`
    /// sends `nValue = nChannel`, `pData = &nGroupID` (1 byte). The caller passes
    /// `nChannel-1` (`SymphonyIOBoard_MicPre8ch.cpp:844`), so the wire index is 0-based.
    case channelGroup = 0xC7

    /// Set insert assignment. **The header comment for this opcode is WRONG.**
    ///
    /// `SymphonyIOVendorSpecific.h:429-431` documents it as
    /// "nValue: Bit[0:7] - Channel Index / pData: insert #". The daemon does the
    /// opposite: `SetInsertAssignmentInHardware`
    /// (`SymphonyIOBoard_MicPre8ch.cpp:1790-1810`) loops the eight INSERTS and calls
    /// `setMicPreInsert(nInsert, cNewMask)` — so `wIndex` is the 0-based INSERT
    /// index and the payload is a 0-based CHANNEL BITMASK.
    ///
    /// It also rebuilds the payload for **all eight** inserts on every change, so a
    /// single UI change is eight control transfers, not one. See
    /// `SymphonyIORequestBuilder.setInsertAssignments`.
    case insert = 0xC8

    /// Set insert return ("In") enable. nValue: channel → wIndex after split.
    /// pData: 0/1.
    /// Evidence: `SymphonyIOControl.cpp:1787-1801` — `setMicPreInsertEnable`;
    /// callers pass `nChannel-1` (`SymphonyIOBoard_MicPre8ch.cpp:554`, `:613`).
    case insertEnable = 0xC9

    /// Set high-pass filter. nValue: channel → wIndex after split. pData: bool.
    case highPassFilter = 0xCA

    // MARK: Device Identity & Reset
    /// Read unique device ID. wValue: 0/1/2 = main/primary/secondary board.
    case uniqueID = 0xC0
    /// Reset to default audio routing. XMOS firmware sets 1:1 routing.
    /// Evidence: `SymphonyIOControl.cpp` lines 229-242 — ResetRouting()
    case resetToDefaultRouting = 0xC2

    // MARK: Preference & Initialization
    /// Preference load lock. pData: 0=unlocked (ready), 1=locked (initializing).
    /// Evidence: `SymphonyIOVendorSpecific.h` — signals firmware that init is complete.
    case preferenceLoadLock = 0xDD
    /// Read current preference settings from the XMOS. Returns a 4-byte
    /// `SymphonyIOSettings`: metersShow1, metersShow2, oversHoldMode, peakHoldMode.
    ///
    /// This is the ONLY readback path for the front-panel meter bank source —
    /// the `0x10` FrontPanelMeterShow READ is disabled in firmware.
    ///
    /// Evidence: `SymphonyIOVendorSpecific.h:526-530` — GetCurrentPreferenceSettings,
    /// "meant to be for reading current setting from the xmos only ... pData: SymphonyIOSettings"
    /// Evidence: `SymphonyIOVendorSpecific.h:1050-1056` — struct layout.
    case getCurrentPreferenceSettings = 0xDE

    // MARK: Monitor Output Controls
    /// Monitor output dim. nValue: output type (0=speaker, 1=HP1, 2=HP2) → wIndex after split. pData: bool.
    /// Evidence: `SymphonyIOVendorSpecific.h` opcode 0xE7
    case monitorOutputDim = 0xE7
    /// Monitor sum to mono. nValue: output type → wIndex after split. pData: bool.
    /// Evidence: `SymphonyIOVendorSpecific.h` opcode 0xE8
    case monitorSumToMono = 0xE8
    /// Active speaker set. pData: bitmask (A=bit0, B=bit1, C=bit2).
    /// Evidence: `SymphonyIOVendorSpecific.h` opcode 0xE9
    case activeSpeakerSet = 0xE9

    // MARK: Headphone Assignment
    /// Headphone assignments. pData: 1 byte, low nibble=HP1, high nibble=HP2.
    /// Evidence: `SymphonyIOVendorSpecific.h` opcode 0x54
    case headphoneAssignments = 0x54

    // MARK: Connectivity
    /// Connectivity verification. Returns magic 0xDAE5C4A1 when device is ready.
    /// Evidence: `SymphonyIOControl.cpp` — waitForSystemReady() polls this.
    case connectivityVerification = 0xFF

    // MARK: Firmware Update
    /// Enter DFU mode.
    case enterDFUMode = 0xF1
    /// Read primary SPI flash status.
    case getPrimarySPIFlashStatus = 0xF2
    /// Read secondary SPI flash status.
    case getSecondarySPIFlashStatus = 0xF3

    // MARK: Temperature
    /// Read temperature sensors. wLength determines count.
    case getTemperatureReadings = 0xFE
}

// MARK: - Routing Byte Addresses

/// USB routing protocol byte addresses for Symphony IO.
///
/// Each routing entity (board I/O, USB playback/record, mixer) has a
/// fixed byte range. Routing commands use 2 bytes: [destination, source].
///
/// Evidence: `og_source/maestrolink/Software/SymphonyIO/SymphonyIORouting.h`
/// Evidence: `og_source/maestrolink/Software/SymphonyIOUSBAudioRoutingController.cpp:714-792`
public enum SymphonyIORoutingAddress {
    /// IOBoard 0 channels 0-15: bytes 32-47. Physical I/O on board slot 1.
    public static let ioBoard0Base: UInt8 = 32
    /// IOBoard 1 channels 0-15: bytes 48-63. Physical I/O on board slot 2.
    public static let ioBoard1Base: UInt8 = 48
    /// P2P (USB audio) channels 0-15: bytes 192-207.
    /// Used as destination for record (input routing) or source for playback (output routing).
    public static let p2pBase: UInt8 = 192

    /// Host playback as the Symphony sees it in Symphony (ThunderBridge) mode:
    /// the XLink RX channels 0x00…0x1F. P2P (192+) is the host interface only in
    /// the USB modes; in Symphony mode a route from P2P carries silence. The
    /// dext's own default playback routing uses XLink sources
    /// (`SymphonyThunderbridge.cpp` step 19b-1, `kSIOSrc_XLinkCh0 + n`), and that
    /// is the path that audibly works. Jeff's 0.8.19 report "output routing does
    /// not work in ThunderBridge mode" was the matrix writing P2P sources.
    public static let xlinkPlaybackBase: UInt8 = 0x00

    /// The playback source base for a transport.
    public static func hostPlaybackBase(for transport: TransportType) -> UInt8 {
        transport == .thunderbolt ? xlinkPlaybackBase : p2pBase
    }
    /// Mixer 0 stereo output: bytes 64-65.
    public static let mixer0Base: UInt8 = 64
    /// Mixer 1 stereo output: bytes 96-97.
    public static let mixer1Base: UInt8 = 96
    /// Digital silence (no source). Byte 236.
    ///
    /// Evidence: `SymphonyIORouting.h:149` — `eSymphonyIORoutingSource_None=236`.
    /// Note this is the *source* enum's silence value, which is what
    /// `ResetOutputRouting()` pre-fills the table with
    /// (`SymphonyIOUSBAudioRoutingController.cpp:626-630`). The vendor header
    /// separately documents `0xFF` in a `0x31` payload as "clear a route and mute
    /// the destination output" (`SymphonyIOVendorSpecific.h`, opcode 0x31) — see
    /// `clearRoute`. They are not interchangeable; legacy writes 236.
    public static let none: UInt8 = 236

    /// Source byte meaning "clear this route and mute the destination".
    ///
    /// Evidence: `SymphonyIOVendorSpecific.h`, opcode `0x31` write payload:
    /// "[n+1] - source channel number from FPGA wiki, or 0xFF to clear a route
    /// and mute the destination output."
    public static let clearRoute: UInt8 = 0xFF

    /// The right-channel source for a stereo route whose left source is
    /// `left`: the next channel, except that a clear (0xFF) clears both
    /// channels. `0xFF + 1` is an overflow trap (crash 2026-10-22 11:00,
    /// clearing an active Output Routing cell).
    public static func rightChannelSource(of left: UInt8) -> UInt8 {
        (left == clearRoute || left == none) ? left : left &+ 1
    }

    /// Channels addressable per I/O board in the routing table (0-15).
    ///
    /// Evidence: `SymphonyIORouting.h:187-225` — IOBoard0Ch0=32…IOBoard0Ch15,
    /// IOBoard1Ch0=48…IOBoard1Ch15. Matches
    /// `cstSymphonyIORoutingController_SourcesPerBoard`.
    public static let channelsPerIOBoard: Int = 16

    /// Headphone 1 (firmware "HP0") crosspoint destinations: 224 (L), 225 (R).
    ///
    /// Evidence: `SymphonyIORouting.h:339-340` —
    /// `eSymphonyIORoutingDestination_HP0Ch0=224`, `_HP0Ch1`.
    public static let headphone1Base: UInt8 = 224

    /// Headphone 2 (firmware "HP1") crosspoint destinations: 226 (L), 227 (R).
    ///
    /// Evidence: `SymphonyIORouting.h:342-343` —
    /// `eSymphonyIORoutingDestination_HP1Ch0=226`, `_HP1Ch1`.
    public static let headphone2Base: UInt8 = 226

    /// Mixer 0 application-input destinations: 228 (L), 229 (R).
    ///
    /// Evidence: `SymphonyIORouting.h:345-347` —
    /// `eSymphonyIORoutingDestination_Mixer0AppInputCh0=228`.
    public static let mixer0AppInputBase: UInt8 = 228

    /// Mixer 1 application-input destinations: 230 (L), 231 (R).
    ///
    /// Evidence: `SymphonyIORouting.h:348-350` —
    /// `eSymphonyIORoutingDestination_Mixer1AppInputCh0` follows 229.
    public static let mixer1AppInputBase: UInt8 = 230
}

/// USB playback stereo pairs exposed by the Symphony IO Software Return input.
/// Values are the legacy `eSymphonyIOUSBAudioSoftwareReturn_*` IDs, not channel
/// numbers: ID 0 means USB channels 1–2, ID 1 means 3–4, and so on.
public enum SymphonyIOSoftwareReturnSource: UInt32, CaseIterable, Sendable {
    case output1_2 = 0
    case output3_4
    case output5_6
    case output7_8
    case output9_10
    case output11_12
    case output13_14
    case output15_16

    public var displayName: String {
        switch self {
        case .output1_2: return "1-2"
        case .output3_4: return "3-4"
        case .output5_6: return "5-6"
        case .output7_8: return "7-8"
        case .output9_10: return "9-10"
        case .output11_12: return "11-12"
        case .output13_14: return "13-14"
        case .output15_16: return "15-16"
        }
    }
}

// MARK: - Headphone Source Routing

/// Resolves a Symphony I/O MKI headphone **source ID** to the FPGA crosspoint
/// writes that actually make it audible.
///
/// ## Why this type exists
///
/// Setting the headphone Output Source is a **two-step** operation and only one
/// step is audible:
///
/// 1. `0x54 HeadphoneAssignments` stores the choice. The vendor header is
///    explicit that this is inert: *"1 byte, opaque for the firmware. Software
///    uses it to store/recall the headphone assignment"*
///    (`SymphonyIOVendorSpecific.h:274-276`). Writing it alone changes nothing
///    you can hear.
/// 2. `RouteHeadphones()` (`SymphonyIO_Stream.cpp:756-805`) programs the FPGA
///    crosspoint with `0x31`, destinations `HP0Ch0/Ch1 = 224/225` and
///    `HP1Ch0/Ch1 = 226/227`.
///
/// The **source** for step 2 is resolved *indirectly*. Legacy does not map the
/// chosen output pair to a source directly — it asks the routing controller what
/// is currently feeding that pair's hardware outputs
/// (`GetRoutedToHWSource`, `SymphonyIOUSBAudioRoutingController.cpp:382-396`)
/// and copies that source byte onto the headphone destination. So the headphone
/// *inherits* Output Routing, and legacy re-runs `RouteHeadphones()` after every
/// routing change (`SymphonyIOUSBAudioRoutingController.cpp:1005-1008`,
/// `:1193-1196`, `SymphonyIO_Stream.cpp:429-437`).
///
/// ## Source ID numbering
///
/// Source IDs are **output pair indices, 0-15** — NOT the
/// `kmAEstroHeadPhoneAssign*` constants in `mAEstro.h:437-448`. Those are the
/// Ensemble-family encoding; the Symphony MKI daemon builds its own list:
///
///     m_aHPSourceIDs[i] = nBoardIdx * 8 + (m_nStartChannel / 2) + i
///     (`SymphonyIO_Stream.cpp:264-276`, with
///      SYMPHONYIO_NUMBER_HP_ASSIGN_CHOICES_PER_BOARD = 16/2 = 8)
///
/// so board 0's output pairs are IDs 0-7 and board 1's are 8-15. The 4-bit
/// nibbles of `0x54` hold exactly this range — `setHeadphoneAssignmentData()`
/// logs an error for anything `> 0xF`
/// (`SymphonyIOControl.cpp:826-833`).
public enum SymphonyIOHeadphoneRouting {

    /// Output pairs addressable per I/O board (16 channels / 2).
    ///
    /// Evidence: `SymphonyIO_Stream.cpp:27` —
    /// `SYMPHONYIO_NUMBER_HP_ASSIGN_CHOICES_PER_BOARD (SYMPHONYIO_NUMBEROF_CHANNELS_PER_IOBOARD/2)`
    /// with `SYMPHONYIO_NUMBEROF_CHANNELS_PER_IOBOARD = 16` (`SymphonyIO.h:48`).
    public static let pairsPerBoard: Int = 8

    /// Largest source ID that fits in a `0x54` nibble.
    public static let maximumSourceID: UInt32 = 15

    /// Headphone selector, in the same firmware order as ``SymphonyIORequestBuilder/MonitorOutput``.
    public enum Headphone: Int, Sendable, CaseIterable {
        case headphone1 = 0
        case headphone2 = 1

        /// Crosspoint destination bytes for this headphone's L/R.
        public var destinations: (left: UInt8, right: UInt8) {
            let base = self == .headphone1
                ? SymphonyIORoutingAddress.headphone1Base
                : SymphonyIORoutingAddress.headphone2Base
            return (base, base + 1)
        }
    }

    /// True when `id` can be stored in a `0x54` nibble and names a real output pair.
    public static func isValidSourceID(_ id: UInt32) -> Bool { id <= maximumSourceID }

    /// Split a source ID into (board index, output pair within that board).
    ///
    /// Returns nil for IDs outside 0-15.
    public static func decompose(sourceID: UInt32) -> (board: Int, pair: Int)? {
        guard isValidSourceID(sourceID) else { return nil }
        return (Int(sourceID) / pairsPerBoard, Int(sourceID) % pairsPerBoard)
    }

    /// The routing-table **destination** bytes of the hardware output pair named
    /// by `sourceID`.
    ///
    /// These are not what gets written for the headphone — they are what gets
    /// *read*, so the headphone can inherit whatever source currently feeds them.
    ///
    /// Evidence: `SymphonyIO_Stream.cpp:779-786` — `nRoutedTo = 2*i + startChan() + 1`
    /// (1-based), resolved by `GetRoutedToHWSource` against
    /// `m_aSourceToIOBoard{0,1}[inEl - 1]`.
    public static func outputPairDestinations(sourceID: UInt32) -> (left: UInt8, right: UInt8)? {
        guard let (board, pair) = decompose(sourceID: sourceID) else { return nil }
        let base = board == 0
            ? SymphonyIORoutingAddress.ioBoard0Base
            : SymphonyIORoutingAddress.ioBoard1Base
        let left = base + UInt8(pair * 2)
        return (left, left + 1)
    }

    /// Crosspoint destination bytes for a headphone's L/R.
    public static func headphoneDestinations(_ hp: Headphone) -> (left: UInt8, right: UInt8) {
        hp.destinations
    }

    // MARK: Source resolution — never from the wire

    /// Source bytes that may legitimately feed a hardware output destination.
    ///
    /// Output routing only ever drives an IOBoard destination from a P2P (USB
    /// playback) channel or a mixer bus. An IOBoard byte (32-63) in the *source*
    /// position of an output route is not a route we ever write, so seeing one
    /// means the value did not come from our own bookkeeping.
    public static func isPlausibleOutputSource(_ source: UInt8) -> Bool {
        if source >= SymphonyIORoutingAddress.p2pBase,
           source <= SymphonyIORoutingAddress.p2pBase &+ 31 { return true }
        // XLink RX channels: host playback on ThunderBridge.
        if source <= SymphonyIORoutingAddress.xlinkPlaybackBase &+ 31 { return true }
        if source == SymphonyIORoutingAddress.mixer0Base
            || source == SymphonyIORoutingAddress.mixer0Base &+ 1 { return true }
        if source == SymphonyIORoutingAddress.mixer1Base
            || source == SymphonyIORoutingAddress.mixer1Base &+ 1 { return true }
        return false
    }

    /// The byte returned by the old incorrectly addressed `0x31` read request:
    /// `0x20` (32) — IOBoard0 channel 0, i.e. analog input 1.
    ///
    /// Measured across all 80 destinations 32-191, *including* DAC L/R which are
    /// demonstrably mixer-fed. That historical result in `Docs/issue-1-research.md`
    /// used wValue instead of wIndex; correctly addressed reads return distinct
    /// routes. Retain this cache guard: headphone inheritance still follows the
    /// legacy in-memory table, not hardware reads. `RouteHeadphones`
    /// (`SymphonyIO_Stream.cpp:756-805`) asks `GetRoutedToHWSource`, which returns
    /// the daemon's own in-memory table
    /// (`SymphonyIOUSBAudioRoutingController.cpp:382-396`).
    public static let routeReadbackResidue: UInt8 = 0x20

    /// The source the proxy programs into a hardware output destination at boot.
    ///
    /// Deterministic, and the only thing that is true about the crosspoint before
    /// the user has routed anything. Evidence:
    /// `Drivers/VolumeProxy/MaestroVolumeProxy.c:1233-1276` —
    ///
    /// * DAC L/R (dest 32/33) ← Mixer0 out L/R (64/65)
    /// * IOBoard0 ch2-15 (dest 34-47) ← USB ch2-15 (192 + (dest - 32))
    /// * IOBoard1 ch0-15 (dest 48-63) ← USB ch0-15 (192 + (dest - 48))
    ///
    /// On ThunderBridge the boot table is the dext's, not the proxy's
    /// (`SymphonyThunderbridge.cpp` steps 19b-1/19b-1b): every IOBoard0 and
    /// IOBoard1 channel n is fed directly from XLink RX n, DAC L/R included
    /// (routing through Mixer0 went silent on hardware, see the 19b-1 note).
    ///
    /// Returns nil for anything that is not a hardware output destination.
    public static func bootTableSource(forDestination destination: UInt8,
                                       transport: TransportType = .usb) -> UInt8? {
        let board0 = SymphonyIORoutingAddress.ioBoard0Base   // 32
        let board1 = SymphonyIORoutingAddress.ioBoard1Base   // 48
        let lastBoard1 = board1 &+ UInt8(SymphonyIORoutingAddress.channelsPerIOBoard - 1) // 63
        let playback = SymphonyIORoutingAddress.hostPlaybackBase(for: transport)
        switch destination {
        case board0, board0 &+ 1:
            return transport == .thunderbolt
                ? playback &+ (destination &- board0)
                : SymphonyIORoutingAddress.mixer0Base &+ (destination &- board0)
        case (board0 &+ 2)...(board1 &- 1):
            return playback &+ (destination &- board0)
        case board1...lastBoard1:
            return playback &+ (destination &- board1)
        default:
            return nil
        }
    }

    /// Resolve what feeds a hardware output destination **without touching the
    /// wire**, so a headphone crosspoint can inherit it.
    ///
    /// Order of trust:
    /// 1. `cachedRoutes` — the app's own persisted output routing. This is the
    ///    direct analogue of legacy's in-memory table.
    /// 2. The proxy's boot table, which is what the crosspoint actually holds
    ///    until the user routes something.
    ///
    /// A cached entry that is not a plausible output source (notably the `0x20`
    /// readback residue) is discarded rather than written — see
    /// ``routeReadbackResidue``. Returns nil when nothing can be determined, and
    /// the caller must then write no crosspoint at all: guessing re-points a
    /// physical jack.
    public static func inheritedSource(
        forDestination destination: UInt8,
        cachedRoutes: [UInt8: UInt8],
        transport: TransportType = .usb
    ) -> UInt8? {
        // On ThunderBridge host playback is routed on the card (see
        // `ThunderboltCardRouting`); the Symphony's table stays at the driver's
        // fixed XLink n → output n, so a headphone following output n always
        // inherits XLink n, whatever the user routed onto it.
        if transport == .thunderbolt {
            return bootTableSource(forDestination: destination, transport: .thunderbolt)
        }
        if let cached = cachedRoutes[destination], isPlausibleOutputSource(cached) {
            return cached
        }
        if let boot = bootTableSource(forDestination: destination, transport: transport),
           isPlausibleOutputSource(boot) {
            return boot
        }
        return nil
    }
}

// MARK: - Sample Rate Encoding

/// Encoding for sample rate values in USB commands.
///
/// Evidence: `og_source/maestrolink/Software/SymphonyIO/SymphonyIOVendorSpecific.h`
/// — SetSampleRate pData encoding: 3 bits for rate selection.
public enum SymphonyIOSampleRateCode: UInt8, Sendable, CaseIterable {
    case rate48000  = 0x00  // 000b
    case rate96000  = 0x01  // 001b
    case rate192000 = 0x02  // 010b
    case rate44100  = 0x04  // 100b
    case rate88200  = 0x05  // 101b
    case rate176400 = 0x06  // 110b

    /// The actual sample rate in Hz.
    public var sampleRate: Double {
        switch self {
        case .rate44100:  return 44100
        case .rate48000:  return 48000
        case .rate88200:  return 88200
        case .rate96000:  return 96000
        case .rate176400: return 176400
        case .rate192000: return 192000
        }
    }

    /// Create from a sample rate in Hz, or nil if not a valid rate.
    public init?(sampleRate: Double) {
        switch sampleRate {
        case 44100:  self = .rate44100
        case 48000:  self = .rate48000
        case 88200:  self = .rate88200
        case 96000:  self = .rate96000
        case 176400: self = .rate176400
        case 192000: self = .rate192000
        default: return nil
        }
    }
}

// MARK: - Clock Source

/// Clock source selection codes (ClockMode `pData[0]`).
///
/// Evidence: `eSymphonyIOClockSource_*` in
/// `og_source/maestrolink/Software/SymphonyIO/SymphonyIOVendorSpecific.h:857-865`,
/// sent verbatim as `acData[0]` by the daemon (`SymphonyIOControl.cpp:992`). The XMOS
/// firmware switches on this exact enum (`SymphonyIOStateData.cpp:2276-2291`); a value
/// of 0 (`unknown`) is a no-op that silently leaves the clock source unchanged.
///
/// The previous numbering was off by one (`internal = 0`) and invented digital sources
/// (aesEbu/spdif/adat/opticalSPDIF) that are board sub-sources, not clock sources — so
/// selecting "Internal" put 0 (unknown) on the wire and every source was misaddressed.
public enum SymphonyIOClockSource: UInt8, Sendable, CaseIterable {
    case unknown = 0
    case `internal` = 1
    case wordClock = 2
    case loopSync = 3
    case ioBoard1 = 4
    case ioBoard2 = 5
}

// MARK: - Meter Group

/// TDM meter data groups.
///
/// Evidence: `og_source/maestrolink/Software/SymphonyIO/SymphonyIOVendorSpecific.h`
/// — TDMMeterData wValue values.
public enum SymphonyIOMeterGroup: UInt8, Sendable {
    case input = 0
    case output = 1
    case mixer = 2

    /// Expected message length in bytes.
    ///
    /// Evidence: `SymphonyIOVendorSpecific.h`
    /// - eSymphonyIOTDMMeterGroupIO_MessageLengthBytes = 64
    /// - eSymphonyIOTDMMeterGroupMixer_MessageLengthBytes = 32
    public var messageLengthBytes: Int {
        switch self {
        case .input, .output: return 64
        case .mixer: return 32
        }
    }
}

// MARK: - Speaker Output Mode

/// Speaker output configuration modes.
///
/// Evidence: `og_source/maestrolink/Software/SymphonyIO/SymphonyIOVendorSpecific.h`
/// — SpeakerOutputMode pData values.
///
/// The legal values are **non-contiguous** (0, 2, 6, 8, 9, 10). A popup that
/// sends its row index instead of the ID silently selects a different mode —
/// row 2 ("2 Speaker Sets") would send 2, which is Stereo.
///
/// Evidence: `SymphonyIOVendorSpecific.h:967-975` — `enum SymphonyIOSpeakerOutputMode`.
/// Cross-checked against the property-layer enum `eMainOutControls`
/// (`mAEstro.h:540-546`): None=0x00, Stereo=0x02, 6ch=0x06, 8ch=0x08.
///
/// Note `0` is **Off**, not "Line". `eSymphonyIOSpeakerOutputMode_Off` is what
/// `ResetToDefaults` selects when the unit has fewer than two analog outputs
/// (`SymphonyIO.cpp:1588-1595`), and `UpdateMainOutputChannelMode` treats it as
/// "disable the speaker knob and fall back to HP1"
/// (`SymphonyIO.cpp:6142-6168`).
public enum SymphonyIOSpeakerMode: UInt8, Sendable, CaseIterable {
    case off = 0
    case stereo = 2
    case surround51 = 6
    case surround71 = 8
    case twoSpeakerSets = 9
    case threeSpeakerSets = 10

    /// Number of speaker sets this mode exposes (1 unless a multi-set mode).
    ///
    /// Evidence: `SymphonyIO.cpp:6126-6136`.
    public var speakerSetCount: Int {
        switch self {
        case .twoSpeakerSets:   return 2
        case .threeSpeakerSets: return 3
        default:                return 1
        }
    }
}

// MARK: - Front Panel Meter Source

/// What a front-panel meter bank displays (`0x10` `pData[0]`).
///
/// **Two independent axes, easily conflated.** `wValue` picks the physical LED
/// bank — 0 = meters 1-8, 1 = meters 9-16 — while `pData[0]` separately says
/// *which* octet of channels that bank shows. A UI that always sends payload 0
/// pins both banks to Analog Output 1-8 and makes channels 9-16 unreachable by
/// construction; showing outputs 9-16 requires payload **4**.
///
/// Evidence: `SymphonyIOVendorSpecific.h:45-49` — "nValue: 0 for Left Bank (1~8)
/// and 1 for Right Bank (9~16); pData[0]: eMaestroEnum_MetersShowValues (1 byte)".
/// Evidence: `mAEstroTypes.h:17-39` — the value table reproduced below.
public enum SymphonyIOFrontPanelMeterSource: UInt8, Sendable, CaseIterable {
    case analogOutput1to8    = 0
    case analogInput1to8     = 1
    case digitalOutput1to8   = 2
    case digitalInput1to8    = 3
    case analogOutput9to16   = 4
    case analogInput9to16    = 5
    case digitalOutput9to16  = 6
    case digitalInput9to16   = 7
    case analogOutput17to24  = 8
    case analogInput17to24   = 9
    case digitalOutput17to24 = 10
    case digitalInput17to24  = 11
    case analogOutput25to32  = 12
    case analogInput25to32   = 13
    case digitalOutput25to32 = 14
    case digitalInput25to32  = 15

    /// Which octet of channels: 0 = 1-8, 1 = 9-16, 2 = 17-24, 3 = 25-32.
    public var octetIndex: Int { Int(rawValue) / 4 }
    /// True for the input variants (odd positions within each octet group).
    public var isInput: Bool { (rawValue % 4) % 2 == 1 }
    /// True for the analog variants (first two positions within each octet group).
    public var isAnalog: Bool { (rawValue % 4) < 2 }

    /// First channel number (1-based) shown by this source.
    public var firstChannel: Int { octetIndex * 8 + 1 }

    /// Compose a source from its three axes, or nil if the octet is out of range.
    public static func make(analog: Bool, input: Bool, octetIndex: Int) -> Self? {
        guard (0...3).contains(octetIndex) else { return nil }
        let within = (analog ? 0 : 2) + (input ? 1 : 0)
        return Self(rawValue: UInt8(octetIndex * 4 + within))
    }
}

/// Physical front-panel meter bank (`0x10` `wValue`).
///
/// Evidence: `SymphonyIOVendorSpecific.h:47`. Do not confuse with
/// ``SymphonyIOFrontPanelMeterSource`` — the bank is the LED column, the source
/// is the audio it shows.
public enum SymphonyIOFrontPanelMeterBank: UInt16, Sendable, CaseIterable {
    /// Meters 1-8.
    case left = 0
    /// Meters 9-16.
    case right = 1

    /// The `'AEmi'` property addresses banks 1-based (`m_aMeterShow[nChan-1]`,
    /// `SymphonyIO.cpp:2574-2619`). Convert without double-incrementing.
    public init?(propertyElement: UInt32) {
        switch propertyElement {
        // Element 0 is tolerated for a caller that already converted to 0-based.
        case 0, 1: self = .left
        case 2:    self = .right
        default:   return nil
        }
    }
}

/// The 4-byte `SymphonyIOSettings` payload returned by `0xDE`.
///
/// Evidence: `SymphonyIOVendorSpecific.h:1050-1056`:
/// `{ char m_cMetersShow1; char m_cMetersShow2; char m_cOversHoldMode; char m_cPeakHoldMode; }`
public struct SymphonyIOPreferenceSettings: Sendable, Equatable {
    public let meterSourceBank1: SymphonyIOFrontPanelMeterSource?
    public let meterSourceBank2: SymphonyIOFrontPanelMeterSource?
    public let oversHoldMode: UInt8
    public let peakHoldMode: UInt8

    /// Parse the raw reply. Returns nil if fewer than 4 bytes came back.
    public init?(data: Data) {
        guard data.count >= 4 else { return nil }
        let bytes = [UInt8](data.prefix(4))
        meterSourceBank1 = SymphonyIOFrontPanelMeterSource(rawValue: bytes[0])
        meterSourceBank2 = SymphonyIOFrontPanelMeterSource(rawValue: bytes[1])
        oversHoldMode = bytes[2]
        peakHoldMode = bytes[3]
    }
}

// MARK: - Soft Limiter Mode

/// Input soft limiter modes.
///
/// Evidence: `og_source/maestrolink/Software/SymphonyIO/SymphonyIOVendorSpecific.h`
/// — SoftLimit pData values.
public enum SymphonyIOSoftLimitMode: UInt8, Sendable {
    case off = 0
    case limit2dBfs = 1
    case limit4dBfs = 2
    case softSaturate = 3
    case softCrunch = 4
}

// MARK: - Version Type

/// Firmware version query types.
///
/// Evidence: `og_source/maestrolink/Software/SymphonyIO/SymphonyIOVendorSpecific.h`
/// — SymphonyIOVersion wValue values.
public enum SymphonyIOVersionType: UInt16, Sendable {
    case mainBoard = 0
    case primaryIOBoard = 1
    case secondaryIOBoard = 2
}

// MARK: - Device Mode

/// Symphony IO operating modes.
///
/// Evidence: `og_source/maestrolink/Software/SymphonyIO/SymphonyIOVendorSpecific.h`
/// — SymphonyIOMode pData values.
public enum SymphonyIODeviceMode: UInt8, Sendable {
    case dfu = 0
    case symphony = 1
    case standalone = 2
    case proTools = 3
    case usbAudio16 = 4
    case usbAudio32 = 5
    case usbAudio8 = 6
}

// MARK: - Constants

/// Symphony IO protocol constants.
///
/// Evidence: `og_source/maestrolink/Software/SymphonyIO/SymphonyIOVendorSpecific.h`
public enum SymphonyIOConstants {
    /// Number of mixer buses.
    public static let numberOfMixers = 4
    /// Number of input channels per mixer.
    public static let mixerInputChannelCount = 33
    /// Total fader count per mixer (inputs + master).
    public static let mixerFaderCount = 34
    /// Pan center value (0-128 range, 64 = center).
    public static let panCenterValue: UInt8 = 64
    /// Fader zero offset: -48 to +6 dB mapped to 0-54.
    public static let faderZeroOffset: UInt8 = 48
    /// Mic gain range: 0-85 dB.
    public static let micGainMaximum: UInt8 = 85
    /// Instrument gain range: 0-65.
    public static let instrumentGainMaximum: UInt8 = 65
    /// Headphone attenuation is 0..64 dB; 64 is the hardware mute point.
    /// The legacy SymphonyIO control stores this as an int8_t and clamps any
    /// larger request to 64 before publishing mute state.
    public static let headphoneVolumeMaximum: UInt8 = 64
    /// Speaker volume range: 0-64 attenuation.
    public static let speakerVolumeMaximum: UInt8 = 64
    /// Connectivity verification magic number.
    public static let connectivityVerificationCode: UInt32 = 0xDAE5_C4A1
    /// DO_NOT_SET_TRIM_VALUE sentinel.
    public static let doNotSetTrimValue: UInt8 = 127
}

// MARK: - Reset

/// How much of the device a reset touches.
///
/// Evidence: `SymphonyIOResetRequestType` distinguishes `ResetAll` from
/// `ResetAllButCalibration`. Trims are treated as **calibration data**: the
/// "-but-calibration" variant preserves them. Default to that one — a reset
/// button should not silently discard a user's converter trims.
public enum SymphonyIOResetScope: Sendable, Equatable, CaseIterable {
    /// Everything except per-channel trims.
    case allButCalibration
    /// Everything, trims included.
    case all

    /// True when this scope should also zero `'AEtr'` on every analog channel.
    public var resetsTrims: Bool { self == .all }
}

/// Monitor-section values that `SymphonyIO::ResetToDefaults` restores.
///
/// Evidence: `og_source/.../SymphonyIO.cpp:1570-1637`:
/// - `changeHPLevel(20, i)` / `changeMainOutAtten(20)` — **20 dB attenuation**,
///   i.e. a displayed level of -20 dB, for both headphones and the speakers.
/// - `changeHPMute(false, i)`, `changeMainOutMute(false)`, and
///   `m_fDim = m_fSum = false` on all three monitor outputs.
/// - Speaker mode: `Stereo` when the unit has >= 2 analog outputs, else `Off`
///   (`:1588-1595`).
/// - `changeMonitorOutput(eSymphonyIO_MonitorOutput_Speakers)`.
/// - Peak and over hold both `Off` in USB Audio boot mode (`:1603-1610`).
///
/// Front-panel bank defaults come from `ResetMeterSourceToDefault`
/// (`SymphonyIO.cpp:1702-1724`, commented as matching the firmware) and are
/// **asymmetric**: bank 1 shows analog *input* 1-8, bank 2 analog *output* 1-8.
/// Neither defaults to a 9-16 octet. When a board has no analog channels in that
/// direction the digital equivalent is used instead.
public enum SymphonyIOMonitorDefaults {
    /// Attenuation in dB for speaker and both headphones (displayed as -20 dB).
    public static let levelAttenuationDB: UInt8 = 20
    public static let muted = false
    public static let dimmed = false
    public static let summedToMono = false
    /// `eSymphonyIOMeteringLEDPeakHold_Off`.
    public static let peakHoldMode: UInt8 = 0
    /// `eSymphonyIOMeteringLEDOverHold_Off`.
    public static let oversHoldMode: UInt8 = 0

    /// Default speaker mode for a unit with `analogOutputChannels` analog outs.
    public static func speakerMode(analogOutputChannels: Int) -> SymphonyIOSpeakerMode {
        analogOutputChannels >= 2 ? .stereo : .off
    }

    /// Default source for front-panel bank 1 (meters 1-8).
    public static func meterSourceBank1(hasAnalogInputs: Bool) -> SymphonyIOFrontPanelMeterSource {
        hasAnalogInputs ? .analogInput1to8 : .digitalInput1to8
    }

    /// Default source for front-panel bank 2 (meters 9-16).
    public static func meterSourceBank2(hasAnalogOutputs: Bool) -> SymphonyIOFrontPanelMeterSource {
        hasAnalogOutputs ? .analogOutput1to8 : .digitalOutput1to8
    }
}

// MARK: - Request Builders

/// Convenience builders for common Symphony IO USB requests.
///
/// These encode the command-specific wValue/pData formats.
///
/// Evidence: `og_source/maestrolink/Software/SymphonyIO/SymphonyIOControl.cpp`
public enum SymphonyIORequestBuilder {

    // MARK: Sample Rate

    /// Build a "set sample rate" request.
    public static func setSampleRate(_ rate: SymphonyIOSampleRateCode) -> USBControlRequest {
        USBControlRequest(
            direction: .write,
            request: SymphonyIOCommand.setSampleRate.rawValue,
            data: Data([rate.rawValue])
        )
    }

    /// Build a "read sample rate" request (reads current rate code).
    public static func getSampleRate() -> USBControlRequest {
        USBControlRequest(
            direction: .read,
            request: SymphonyIOCommand.setSampleRate.rawValue,
            data: Data(count: 1)
        )
    }

    // MARK: Clock

    /// Build a "set clock mode" request.
    ///
    /// Evidence: `SymphonyIOControl.cpp` — ClockMode uses 4-byte payload:
    /// [0]=mode, [1]=isMaster, [2]=loopSync, [3]=boardIndex
    public static func setClockMode(
        source: SymphonyIOClockSource,
        isMaster: Bool = true,
        loopSync: Bool = false,
        boardIndex: UInt8 = 0
    ) -> USBControlRequest {
        USBControlRequest(
            direction: .write,
            request: SymphonyIOCommand.clockMode.rawValue,
            data: Data([source.rawValue, isMaster ? 1 : 0, loopSync ? 1 : 0, boardIndex])
        )
    }

    /// Build a "read clock rate and lock" request.
    /// Returns 5 bytes: lock state + 4-byte measured sample rate.
    public static func getClockRateAndLock() -> USBControlRequest {
        USBControlRequest(
            direction: .read,
            request: SymphonyIOCommand.clockRateAndLock.rawValue,
            data: Data(count: 5)
        )
    }

    // MARK: Mic Preamp

    /// Build a "set mic gain" request.
    ///
    /// Evidence: `SymphonyIOControl.cpp:1687-1691` — SendRequest(true, MicGain, nChannel, ...)
    /// nValue = nChannel → wValue=0, wIndex=channel after split.
    public static func setMicGain(channel: UInt16, gain: UInt8) -> USBControlRequest {
        USBControlRequest(
            direction: .write,
            request: SymphonyIOCommand.micGain.rawValue,
            index: channel,
            data: Data([min(gain, SymphonyIOConstants.micGainMaximum)])
        )
    }

    /// Build a "read mic gain" request.
    public static func getMicGain(channel: UInt16) -> USBControlRequest {
        USBControlRequest(
            direction: .read,
            request: SymphonyIOCommand.micGain.rawValue,
            index: channel,
            data: Data(count: 1)
        )
    }

    /// Build a "set phantom power" request.
    ///
    /// Evidence: `SymphonyIOControl.cpp:1649-1653` — SendRequest(true, PhantomPower, nChannel, ...)
    public static func setPhantomPower(channel: UInt16, enabled: Bool) -> USBControlRequest {
        USBControlRequest(
            direction: .write,
            request: SymphonyIOCommand.phantomPower.rawValue,
            index: channel,
            data: Data([enabled ? 1 : 0])
        )
    }

    /// Build a "read phantom power" request.
    public static func getPhantomPower(channel: UInt16) -> USBControlRequest {
        USBControlRequest(
            direction: .read,
            request: SymphonyIOCommand.phantomPower.rawValue,
            index: channel,
            data: Data(count: 1)
        )
    }

    /// Build a "set phase invert" request.
    ///
    /// Evidence: `SymphonyIOControl.cpp:1611-1615` — SendRequest(true, PhaseInverse, nChannel, ...)
    public static func setPhaseInvert(channel: UInt16, enabled: Bool) -> USBControlRequest {
        USBControlRequest(
            direction: .write,
            request: SymphonyIOCommand.phaseInverse.rawValue,
            index: channel,
            data: Data([enabled ? 1 : 0])
        )
    }

    /// Build a "set high-pass filter" request.
    ///
    /// Evidence: `SymphonyIOControl.cpp:1868-1872` — SendRequest(true, HighPassFilter, nChannel, ...)
    public static func setHighPassFilter(channel: UInt16, enabled: Bool) -> USBControlRequest {
        USBControlRequest(
            direction: .write,
            request: SymphonyIOCommand.highPassFilter.rawValue,
            index: channel,
            data: Data([enabled ? 1 : 0])
        )
    }

    // MARK: Mic Preamp — Group / Insert

    /// Build a "set mic-pre gain group" request (`0xC7`).
    ///
    /// `wIndex` = 0-based channel, payload = 1 byte group ID (0 = Off, 1...8).
    /// Evidence: `SymphonyIOControl.cpp:1755-1770` (`setMicPreGroup`),
    /// `SymphonyIOBoard_MicPre8ch.cpp:844` (`setMicPreGroup(nChannel-1, ...)`),
    /// `SymphonyIOVendorSpecific.h:1072-1083` (`eSymphonyIOMicPre8ChGroup_*`).
    public static func setChannelGroup(channel: UInt16, group: UInt8) -> USBControlRequest {
        USBControlRequest(
            direction: .write,
            request: SymphonyIOCommand.channelGroup.rawValue,
            index: channel,
            data: Data([min(group, UInt8(InputChannelLogic.micPreGroupCount))])
        )
    }

    /// Build a "read mic-pre gain group" request (`0xC7`).
    /// Evidence: `SymphonyIOControl.cpp:1771-1786` (`getMicPreGroup`) — same index.
    public static func getChannelGroup(channel: UInt16) -> USBControlRequest {
        USBControlRequest(
            direction: .read,
            request: SymphonyIOCommand.channelGroup.rawValue,
            index: channel,
            data: Data(count: 1)
        )
    }

    /// Build ONE "set insert assignment" request (`0xC8`).
    ///
    /// `wIndex` = **0-based INSERT index** (insert ID 1...8 → 0...7), payload =
    /// 1-byte **channel bitmask** (`0x01 << channel`, 0-based channel). This is the
    /// opposite of what `SymphonyIOVendorSpecific.h:429-431` claims; the daemon is
    /// the authority. See `SymphonyIOCommand.insert`.
    ///
    /// Prefer ``setInsertAssignments(insertPerChannel:)`` — the firmware is only
    /// ever handed a *complete* eight-insert table.
    /// Evidence: `SymphonyIOBoard_MicPre8ch.cpp:1790-1810`,
    /// `SymphonyIOControl.cpp:1824-1838` (`setMicPreInsert`).
    public static func setInsertAssignment(insert: UInt16, channelMask: UInt8) -> USBControlRequest {
        USBControlRequest(
            direction: .write,
            request: SymphonyIOCommand.insert.rawValue,
            index: insert,
            data: Data([channelMask])
        )
    }

    /// Build the FULL eight-insert rebuild the daemon performs on every change.
    ///
    /// `SetInsertAssignmentInHardware` (`SymphonyIOBoard_MicPre8ch.cpp:1790-1810`)
    /// does not write just the insert that moved: it walks inserts 0...7, derives
    /// each one's channel mask from the whole assignment table, and writes all
    /// eight. An insert nobody holds is explicitly written as mask `0x00`, which is
    /// what actually releases it.
    ///
    /// - Parameter insertPerChannel: insert ID per 0-based MicPre channel
    ///   (0 = None, 1...8 = "Insert N"). Shorter arrays are padded with None.
    /// - Returns: exactly `micPreInsertCount` requests, insert 0 first.
    public static func setInsertAssignments(insertPerChannel: [UInt32]) -> [USBControlRequest] {
        InputChannelLogic.insertAssignmentMasks(insertPerChannel: insertPerChannel)
            .map { setInsertAssignment(insert: UInt16($0.insert), channelMask: $0.mask) }
    }

    /// Build a "set insert return enable" request (`0xC9`).
    ///
    /// `wIndex` = 0-based channel, payload = 0/1. Unlike `0xC8` this one DOES match
    /// its header comment.
    /// Evidence: `SymphonyIOControl.cpp:1787-1801` (`setMicPreInsertEnable`),
    /// `SymphonyIOBoard_MicPre8ch.cpp:1742-1750` (`SetInsertEn`) whose callers pass
    /// `nChannel-1`.
    public static func setInsertReturnEnable(channel: UInt16, enabled: Bool) -> USBControlRequest {
        USBControlRequest(
            direction: .write,
            request: SymphonyIOCommand.insertEnable.rawValue,
            index: channel,
            data: Data([enabled ? 1 : 0])
        )
    }

    /// Build a "read insert return enable" request (`0xC9`).
    /// Evidence: `SymphonyIOControl.cpp:1803-1822` (`getMicPreInsertEnable`).
    public static func getInsertReturnEnable(channel: UInt16) -> USBControlRequest {
        USBControlRequest(
            direction: .read,
            request: SymphonyIOCommand.insertEnable.rawValue,
            index: channel,
            data: Data(count: 1)
        )
    }

    // MARK: Output

    /// Build a "set headphone volume" request.
    ///
    /// Evidence: `SymphonyIOControl.cpp:322-326` — SendRequest(true, HeadphoneVolume, nHeadphoneChannel, ...)
    /// nValue = nHeadphoneChannel (0 or 1) → wValue=0, wIndex=channel after split.
    public static func setHeadphoneVolume(channel: UInt16, attenuation: UInt8) -> USBControlRequest {
        USBControlRequest(
            direction: .write,
            request: SymphonyIOCommand.headphoneVolume.rawValue,
            index: channel,
            data: Data([min(attenuation, SymphonyIOConstants.headphoneVolumeMaximum)])
        )
    }

    /// Build a "set headphone mute" request.
    ///
    /// Evidence: `SymphonyIOControl.cpp` — SendRequest(true, HeadphoneMute, nHeadphoneChannel, ...)
    public static func setHeadphoneMute(channel: UInt16, muted: Bool) -> USBControlRequest {
        USBControlRequest(
            direction: .write,
            request: SymphonyIOCommand.headphoneMute.rawValue,
            index: channel,
            data: Data([muted ? 1 : 0])
        )
    }

    /// Build a "set speaker volume" request.
    public static func setSpeakerVolume(attenuation: UInt8) -> USBControlRequest {
        USBControlRequest(
            direction: .write,
            request: SymphonyIOCommand.speakerOutputVolume.rawValue,
            data: Data([min(attenuation, SymphonyIOConstants.speakerVolumeMaximum)])
        )
    }

    /// Build a "set speaker mute" request.
    public static func setSpeakerMute(muted: Bool) -> USBControlRequest {
        USBControlRequest(
            direction: .write,
            request: SymphonyIOCommand.speakerOutputMute.rawValue,
            data: Data([muted ? 1 : 0])
        )
    }

    /// Build a "set speaker output mode" request.
    ///
    /// Evidence: `SymphonyIOControl.cpp:394-408` — `SendRequest(true,
    /// SpeakerOutputMode, 0, 1, &cMode, 0)`; wValue and wIndex are both 0 and the
    /// mode ID is the whole payload.
    public static func setSpeakerMode(_ mode: SymphonyIOSpeakerMode) -> USBControlRequest {
        USBControlRequest(
            direction: .write,
            request: SymphonyIOCommand.speakerOutputMode.rawValue,
            data: Data([mode.rawValue])
        )
    }

    /// Build a "read speaker output mode" request.
    ///
    /// Evidence: `SymphonyIOControl.cpp:410-427` — `getSpeakerOutputMode()` does
    /// the same transfer with fWrite=false and a 1-byte buffer.
    public static func getSpeakerMode() -> USBControlRequest {
        USBControlRequest(
            direction: .read,
            request: SymphonyIOCommand.speakerOutputMode.rawValue,
            data: Data(count: 1)
        )
    }

    // MARK: Metering

    /// Build a "read TDM meter data" request.
    ///
    /// Evidence: `SymphonyIOControl.cpp` lines 176-180
    public static func getMeterData(group: SymphonyIOMeterGroup) -> USBControlRequest {
        USBControlRequest(
            direction: .read,
            request: SymphonyIOCommand.tdmMeterData.rawValue,
            // Group is the low half of nValue, same split as 0x10 above
            // (legacy: SendRequest(false, 0x30, meterGroup, ...) —
            // og_source/maestrolink/Software/SymphonyIO/SymphonyIOControl.cpp:176-181).
            index: UInt16(group.rawValue),
            data: Data(count: group.messageLengthBytes)
        )
    }

    // MARK: Routing

    /// Build a "read audio routing" request for a single destination.
    ///
    /// Evidence: `SymphonyIOControl.cpp:206-219` passes destination as nValue;
    /// `ControlProtocol/SimpleControlProtocolUSB.cpp:56-57` splits nValue into
    /// wValue (high 16 bits) and wIndex (low 16 bits).
    public static func getAudioRoute(destination: UInt16) -> USBControlRequest {
        USBControlRequest(
            direction: .read,
            request: SymphonyIOCommand.audioRouting.rawValue,
            index: destination,
            data: Data(count: 1)
        )
    }

    /// Build a "set audio routing" request for one or more route pairs.
    ///
    /// Each pair is (destination, source). Max 32 pairs per transfer.
    public static func setAudioRoutes(_ routes: [(destination: UInt8, source: UInt8)]) -> USBControlRequest {
        var data = Data(capacity: routes.count * 2)
        for route in routes {
            data.append(route.destination)
            data.append(route.source)
        }
        return USBControlRequest(
            direction: .write,
            request: SymphonyIOCommand.audioRouting.rawValue,
            data: data
        )
    }

    /// Build a "set audio routing" request for a SINGLE route.
    ///
    /// Matches legacy `SymphonyIOControl::setAudioRoute(dest, src)` exactly:
    /// wValue=0, pData=[dest, src], 2 bytes.
    ///
    /// Evidence: `SymphonyIOControl.cpp` lines 244-258
    public static func setAudioRoute(destination: UInt8, source: UInt8) -> USBControlRequest {
        USBControlRequest(
            direction: .write,
            request: SymphonyIOCommand.audioRouting.rawValue,
            data: Data([destination, source])
        )
    }

    /// Reset routing to **firmware** defaults (`0xC2`).
    ///
    /// Evidence: `SymphonyIOControl.cpp:229-242` — ResetRouting().
    ///
    /// - Warning: The USB routing controller never calls this. Legacy's
    ///   "Reset Routing" on a USB Symphony computes the default table in software
    ///   and writes it with `0x31` pairs
    ///   (`SymphonyIOUSBAudioRoutingController.cpp:623-712`, `:714-812`); only the
    ///   PCIe/Symphony64 controller issues `0xC2`
    ///   (`SymphonyIORoutingController.cpp:371-381`). The firmware's own default
    ///   is a flat 1:1 map that is not board-aware, so it can re-point optical
    ///   destinations. Prefer ``SymphonyIORequestBuilder/setAudioRoutes(_:)`` with
    ///   a computed table.
    public static func resetRouting() -> USBControlRequest {
        USBControlRequest(
            direction: .write,
            request: SymphonyIOCommand.resetToDefaultRouting.rawValue,
            data: Data()
        )
    }

    /// Build the `0x31` write that makes a headphone source audible.
    ///
    /// This is the second half of the headphone Output Source operation — see
    /// ``SymphonyIOHeadphoneRouting`` for why `0x54` alone does nothing. Both L
    /// and R go in one transfer, exactly as legacy sends two consecutive
    /// `setAudioRoute` calls for `HPnCh0` and `HPnCh1`
    /// (`SymphonyIO_Stream.cpp:773-801`).
    ///
    /// - Parameters:
    ///   - headphone: Which headphone jack.
    ///   - leftSource: Source byte currently feeding the chosen pair's left output.
    ///   - rightSource: Source byte currently feeding the chosen pair's right output.
    public static func setHeadphoneCrosspoint(
        headphone: SymphonyIOHeadphoneRouting.Headphone,
        leftSource: UInt8,
        rightSource: UInt8
    ) -> USBControlRequest {
        let dest = headphone.destinations
        return setAudioRoutes([
            (destination: dest.left,  source: leftSource),
            (destination: dest.right, source: rightSource)
        ])
    }

    /// Build a "read current preference settings" request (`0xDE`).
    ///
    /// Returns 4 bytes; decode with ``SymphonyIOPreferenceSettings``. This is the
    /// only way to read back the front-panel meter bank sources, because the
    /// `0x10` read is disabled in firmware.
    public static func getCurrentPreferenceSettings() -> USBControlRequest {
        USBControlRequest(
            direction: .read,
            request: SymphonyIOCommand.getCurrentPreferenceSettings.rawValue,
            data: Data(count: 4)
        )
    }

    // MARK: Digital I/O

    /// Read optical format for a board.
    /// BoardIdx is the low half of logical nValue, so it belongs in USB wIndex.
    /// Evidence: SymphonyIOControl.cpp:1355–1370 and SimpleControlProtocolUSB.cpp:54–57.
    public static func getOpticalFormat(board: UInt16 = 0) -> USBControlRequest {
        USBControlRequest(
            direction: .read,
            request: SymphonyIOCommand.opticalFormat.rawValue,
            index: board,
            data: Data(count: 1)
        )
    }

    /// Set optical format for a board (0=ADAT, 1=S/PDIF).
    public static func setOpticalFormat(board: UInt16 = 0, format: UInt8) -> USBControlRequest {
        USBControlRequest(
            direction: .write,
            request: SymphonyIOCommand.opticalFormat.rawValue,
            index: board,
            data: Data([format])
        )
    }

    /// Read S/PDIF coax input replace setting for a board.
    public static func getSPDIFCoaxReplaceInput(board: UInt16 = 0) -> USBControlRequest {
        USBControlRequest(
            direction: .read,
            request: SymphonyIOCommand.spdifCoaxReplaceInput.rawValue,
            value: board,
            data: Data(count: 1)
        )
    }

    /// Set S/PDIF coax input replace setting for a board.
    public static func setSPDIFCoaxReplaceInput(board: UInt16 = 0, replacement: UInt8) -> USBControlRequest {
        USBControlRequest(
            direction: .write,
            request: SymphonyIOCommand.spdifCoaxReplaceInput.rawValue,
            value: board,
            data: Data([replacement])
        )
    }

    /// Read S/PDIF coax output mirror setting for a board.
    public static func getSPDIFCoaxMirrorOutput(board: UInt16 = 0) -> USBControlRequest {
        USBControlRequest(
            direction: .read,
            request: SymphonyIOCommand.spdifCoaxMirrorOutput.rawValue,
            value: board,
            data: Data(count: 1)
        )
    }

    /// Set S/PDIF coax output mirror setting for a board.
    public static func setSPDIFCoaxMirrorOutput(board: UInt16 = 0, mirror: UInt8) -> USBControlRequest {
        USBControlRequest(
            direction: .write,
            request: SymphonyIOCommand.spdifCoaxMirrorOutput.rawValue,
            value: board,
            data: Data([mirror])
        )
    }

    // MARK: Initialization

    /// Check device connectivity. Returns 4 bytes; compare to SymphonyIOConstants.connectivityVerificationCode.
    /// Evidence: `SymphonyIOControl.cpp` — waitForSystemReady() reads opcode 0xFF
    public static func getConnectivityVerification() -> USBControlRequest {
        USBControlRequest(
            direction: .read,
            request: SymphonyIOCommand.connectivityVerification.rawValue,
            data: Data(count: 4)
        )
    }

    /// Set preference load lock. locked=true means "still initializing", false means "ready".
    /// Evidence: `SymphonyIOControl.cpp` — setPreferenceLoadLock(false) called after init complete
    public static func setPreferenceLoadLock(locked: Bool) -> USBControlRequest {
        USBControlRequest(
            direction: .write,
            request: SymphonyIOCommand.preferenceLoadLock.rawValue,
            data: Data([locked ? 1 : 0])
        )
    }

    /// Set active speaker set bitmask. Set A=1, Set B=2, Set C=4.
    /// Evidence: `SymphonyIOVendorSpecific.h` — ActiveSpeakerSet assignment mask
    public static func setActiveSpeakerSet(mask: UInt8) -> USBControlRequest {
        USBControlRequest(
            direction: .write,
            request: SymphonyIOCommand.activeSpeakerSet.rawValue,
            data: Data([mask])
        )
    }

    // MARK: Mixer

    /// Build a "set mixer fader level" request.
    ///
    /// Level is in the range 0-54 (representing -48 to +6 dB).
    ///
    /// Evidence: mixer nValue encodes mixerID in bits[23:16] and channel in bits[15:0].
    /// After split: wValue=mixerID, wIndex=channel.
    public static func setMixerFaderLevel(
        mixerID: UInt8,
        channel: UInt16,
        level: UInt8
    ) -> USBControlRequest {
        let (wValue, wIndex) = USBValueEncoding.split(
            USBValueEncoding.mixerValue(mixerID: mixerID, channel: channel)
        )
        return USBControlRequest(
            direction: .write,
            request: SymphonyIOCommand.mixerFaderLevel.rawValue,
            value: wValue,
            index: wIndex,
            data: Data([level])
        )
    }

    /// Build a "set mixer pan" request.
    ///
    /// Pan is 0-128 with 64 as center.
    public static func setMixerPan(
        mixerID: UInt8,
        channel: UInt16,
        pan: UInt8
    ) -> USBControlRequest {
        let (wValue, wIndex) = USBValueEncoding.split(
            USBValueEncoding.mixerValue(mixerID: mixerID, channel: channel)
        )
        return USBControlRequest(
            direction: .write,
            request: SymphonyIOCommand.mixerInputPan.rawValue,
            value: wValue,
            index: wIndex,
            data: Data([pan])
        )
    }

    /// Build a "set mixer mute" request.
    public static func setMixerMute(
        mixerID: UInt8,
        channel: UInt16,
        muted: Bool
    ) -> USBControlRequest {
        let (wValue, wIndex) = USBValueEncoding.split(
            USBValueEncoding.mixerValue(mixerID: mixerID, channel: channel)
        )
        return USBControlRequest(
            direction: .write,
            request: SymphonyIOCommand.mixerInputMute.rawValue,
            value: wValue,
            index: wIndex,
            data: Data([muted ? 1 : 0])
        )
    }

    /// Build a "set mixer solo" request.
    public static func setMixerSolo(
        mixerID: UInt8,
        channel: UInt16,
        solo: Bool
    ) -> USBControlRequest {
        let (wValue, wIndex) = USBValueEncoding.split(
            USBValueEncoding.mixerValue(mixerID: mixerID, channel: channel)
        )
        return USBControlRequest(
            direction: .write,
            request: SymphonyIOCommand.mixerInputSolo.rawValue,
            value: wValue,
            index: wIndex,
            data: Data([solo ? 1 : 0])
        )
    }

    // MARK: Device Info

    /// Build a "read firmware version" request.
    public static func getFirmwareVersion(type: SymphonyIOVersionType) -> USBControlRequest {
        USBControlRequest(
            direction: .read,
            request: SymphonyIOCommand.symphonyIOVersion.rawValue,
            value: type.rawValue,
            data: Data(count: 3) // major, minor, build
        )
    }

    /// Build a "read device mode" request.
    public static func getDeviceMode() -> USBControlRequest {
        USBControlRequest(
            direction: .read,
            request: SymphonyIOCommand.symphonyIOMode.rawValue,
            data: Data(count: 1)
        )
    }

    /// Build a "read option board type" request.
    ///
    /// Legacy daemon uses `SendRequest(false, 0xA1, nValue, 1, &byte, 0)` where nValue=0 (primary)
    /// or nValue=1 (secondary). The transport splits nValue as:
    ///   wValue = nValue >> 16 = 0
    ///   wIndex = nValue & 0xFFFF = slot
    /// Evidence: `og_source/maestrolink/Software/ControlProtocol/SimpleControlProtocolUSB.cpp:56-57`
    public static func getOptionBoardType(slot: UInt16) -> USBControlRequest {
        USBControlRequest(
            direction: .read,
            request: SymphonyIOCommand.optionBoardType.rawValue,
            value: 0,
            index: slot,
            data: Data(count: 1)
        )
    }

    /// Build a "read unique ID" request.
    public static func getUniqueID(board: UInt16 = 0) -> USBControlRequest {
        USBControlRequest(
            direction: .read,
            request: SymphonyIOCommand.uniqueID.rawValue,
            value: board,
            data: Data(count: 8)
        )
    }

    // MARK: Soft Limit

    // MARK: Monitor Output Controls

/// Monitor output destination, in the encoding the FIRMWARE actually expects.
///
/// This is a documented trap. `SymphonyIOVendorSpecific.h:576-584` describes
/// `wIndex` for opcodes 0xE7 (Dim) and 0xE8 (SumToMono) as
/// `eSymphonyIO_MonitorOutput`, i.e. Speakers=1, HP1=2, HP2=3. **That comment is
/// wrong.** The daemon translates through a different enum before anything
/// reaches the wire — `SymphonyIOControl.cpp:25-29`, sent at `:2159-2183` and
/// `:2188-2210` — and the firmware agrees with the daemon, not the header
/// (`SymphonyIOEventProperties.h:380-385`):
///
///     eSymphonyIOFirmware_MonitorOutput_HP1     = 0
///     eSymphonyIOFirmware_MonitorOutput_HP2     = 1
///     eSymphonyIOFirmware_MonitorOutput_Speaker = 2
///
/// We previously used 0=speaker, 1=HP1, 2=HP2, which rotated every command by
/// one: pressing Dim on Headphone 1 dimmed Headphone 2, and pressing it on the
/// speakers dimmed Headphone 1. The buttons changed state and nothing audible
/// happened on the output being monitored — reported publicly as
/// "D and M do nothing".
///
/// Named rather than inlined so the mapping is stated once and cannot silently
/// drift back to the header's version.
public enum MonitorOutput: UInt16, Sendable, CaseIterable {
    case headphone1 = 0
    case headphone2 = 1
    case speaker    = 2
}

    /// Build a "set monitor dim" request.
    /// Evidence: `SymphonyIOControl.cpp:2159-2183` — SendRequest(true, MonitorOutputDim, ...)
    /// nValue = firmware output index → wValue=0, wIndex=index after split.
    /// See `MonitorOutput` for why the index is not what the header comment says.
    public static func setMonitorDim(output: MonitorOutput, enabled: Bool) -> USBControlRequest {
        USBControlRequest(
            direction: .write,
            request: SymphonyIOCommand.monitorOutputDim.rawValue,
            index: output.rawValue,
            data: Data([enabled ? 1 : 0])
        )
    }

    /// Build a "read monitor dim" request.
    public static func getMonitorDim(output: MonitorOutput) -> USBControlRequest {
        USBControlRequest(
            direction: .read,
            request: SymphonyIOCommand.monitorOutputDim.rawValue,
            index: output.rawValue,
            data: Data(count: 1)
        )
    }

    /// Build a "set monitor sum to mono" request.
    ///
    /// Evidence: `SymphonyIOControl.cpp:2188-2210` — SendRequest(true, MonitorSumToMono, ...)
    /// See `MonitorOutput` for the firmware's actual index encoding.
    public static func setMonitorSumToMono(output: MonitorOutput, enabled: Bool) -> USBControlRequest {
        USBControlRequest(
            direction: .write,
            request: SymphonyIOCommand.monitorSumToMono.rawValue,
            index: output.rawValue,
            data: Data([enabled ? 1 : 0])
        )
    }

    /// Build a "read monitor sum to mono" request.
    public static func getMonitorSumToMono(output: MonitorOutput) -> USBControlRequest {
        USBControlRequest(
            direction: .read,
            request: SymphonyIOCommand.monitorSumToMono.rawValue,
            index: output.rawValue,
            data: Data(count: 1)
        )
    }

    /// Build a "read active speaker set" request.
    public static func getActiveSpeakerSet() -> USBControlRequest {
        USBControlRequest(
            direction: .read,
            request: SymphonyIOCommand.activeSpeakerSet.rawValue,
            data: Data(count: 1)
        )
    }

    /// Build a "read headphone assignments" request.
    /// Returns 1 byte: low nibble=HP1, high nibble=HP2.
    public static func getHeadphoneAssignments() -> USBControlRequest {
        USBControlRequest(
            direction: .read,
            request: SymphonyIOCommand.headphoneAssignments.rawValue,
            data: Data(count: 1)
        )
    }

    /// Build a "set headphone assignments" request.
    /// pData: 1 byte, low nibble=HP1, high nibble=HP2.
    public static func setHeadphoneAssignments(hp1: UInt8, hp2: UInt8) -> USBControlRequest {
        let value = (hp2 << 4) | (hp1 & 0x0F)
        return USBControlRequest(
            direction: .write,
            request: SymphonyIOCommand.headphoneAssignments.rawValue,
            data: Data([value])
        )
    }

    /// Build a "set digital reference level" request.
    public static func setDigitalReferenceLevel(
        channel: UInt16,
        isOutput: Bool,
        level: UInt8
    ) -> USBControlRequest {
        let nValue = USBValueEncoding.channelValue(channel: channel, isOutput: isOutput)
        let (wValue, wIndex) = USBValueEncoding.split(nValue)
        return USBControlRequest(
            direction: .write,
            request: SymphonyIOCommand.digitalReferenceLevel.rawValue,
            value: wValue,
            index: wIndex,
            data: Data([level])
        )
    }

    /// Build a "read digital reference level" request.
    public static func getDigitalReferenceLevel(
        channel: UInt16,
        isOutput: Bool
    ) -> USBControlRequest {
        let nValue = USBValueEncoding.channelValue(channel: channel, isOutput: isOutput)
        let (wValue, wIndex) = USBValueEncoding.split(nValue)
        return USBControlRequest(
            direction: .read,
            request: SymphonyIOCommand.digitalReferenceLevel.rawValue,
            value: wValue,
            index: wIndex,
            data: Data(count: 1)
        )
    }

    /// Build a "set front panel meter show" request (`0x10`).
    ///
    /// **The bank and the source are independent.** `wValue` selects the physical
    /// LED bank (0 = meters 1-8, 1 = meters 9-16); `pData[0]` says which octet of
    /// channels that bank displays. The previous version of this builder took only
    /// a bank and always sent `pData[0] = 0`, which pins both banks to Analog
    /// Output 1-8 and makes channels 9-16 unreachable — the "meters offset by +8 /
    /// wrong bank source" report.
    ///
    /// Evidence: `SymphonyIOVendorSpecific.h:45-49`.
    ///
    /// - Warning: Sending this opcode to the dev unit has historically wedged the
    ///   XMOS EP0 endpoint until reboot (`Docs/Learnings.md`, 2026-02-22). The
    ///   mapper therefore treats `.frontPanelMeterBank` / `.metersShowInput` as
    ///   cache-only and never emits this request by default. This builder exists so
    ///   the encoding is correct and pinned by tests when the send is re-enabled.
    public static func setFrontPanelMeterShow(
        bank: SymphonyIOFrontPanelMeterBank,
        source: SymphonyIOFrontPanelMeterSource
    ) -> USBControlRequest {
        USBControlRequest(
            direction: .write,
            request: SymphonyIOCommand.frontPanelMeterShow.rawValue,
            // Bank is the LOW half of legacy's nValue, so it goes in wIndex.
            // SymphonyIOVendorSpecific.h:47-49 says "nValue : 0 for Left Bank,
            // 1 for Right Bank"; SimpleControlProtocolUSB.cpp:56-57 then splits
            // wValue = nValue >> 16, wIndex = nValue & 0xFFFF. Sending the bank in
            // wValue made the firmware reconstruct 0x00010000 for bank 1, which
            // wedged EP0 device-side 3-for-3 (Docs/Learnings.md 2026-09-11).
            index: bank.rawValue,
            data: Data([source.rawValue])
        )
    }

    // MARK: Soft Limit

    /// Build a "set soft limit" request.
    ///
    /// Evidence: `SymphonyIOControl.cpp:540-545` — SendRequest(true, SoftLimit, nChannel, ...)
    /// nValue = nChannel → wValue=0, wIndex=channel after split.
    public static func setSoftLimit(channel: UInt16, mode: SymphonyIOSoftLimitMode) -> USBControlRequest {
        USBControlRequest(
            direction: .write,
            request: SymphonyIOCommand.softLimit.rawValue,
            index: channel,
            data: Data([mode.rawValue])
        )
    }

    // MARK: Analog Reference

    /// Build a "set analog reference level" request.
    ///
    /// Evidence: `SymphonyIOVendorSpecific.h` — wValue bit31=I/O, bits[7:0]=channel.
    /// pData: 1 byte type + 1 byte trim/gain value.
    public static func setAnalogReferenceLevel(
        channel: UInt16,
        isOutput: Bool,
        type: UInt8,
        trimValue: UInt8 = SymphonyIOConstants.doNotSetTrimValue
    ) -> USBControlRequest {
        let nValue = USBValueEncoding.channelValue(channel: channel, isOutput: isOutput)
        let (wValue, wIndex) = USBValueEncoding.split(nValue)
        return USBControlRequest(
            direction: .write,
            request: SymphonyIOCommand.analogReferenceLevel.rawValue,
            value: wValue,
            index: wIndex,
            data: Data([type, trimValue])
        )
    }
}

// MARK: - Default Routing Tables

/// Reproduces the daemon's default routing, which is **not** a plain diagonal.
///
/// `ResetOutputRouting` / `ResetInputRouting`
/// (`SymphonyIOUSBAudioRoutingController.cpp:623-712`, `:714-812`) walk the
/// installed boards in a fixed order — **all analog channels across both boards
/// first, then all digital channels across both boards** — assigning a single
/// running USB channel counter as it goes, wrapping modulo the USB channel count.
/// Unused board destinations are left at `eSymphonyIORoutingSource_None` (236).
///
/// Two things this corrects in our previous "Reset Routing":
///
/// 1. We wrote a **dual** map (every DAW pair driving both board 0 and board 1).
///    Legacy never does that; each hardware output gets its own USB channel.
/// 2. We ignored the analog-before-digital ordering, so on an Analog+Optical unit
///    the ADAT destinations were fed the wrong USB channels.
///
/// The firmware-side reset (`0xC2`) is deliberately not used — see the
/// `.resetRouting` comment in `SymphonyIOPropertyMapper`.
public enum SymphonyIODefaultRouting {

    /// One entry per (destination byte, source byte) pair.
    public typealias Route = (destination: UInt8, source: UInt8)

    /// `cstSymphonyIOUSBAIMNumberOfUSBChannels` — **16**, always.
    ///
    /// This is NOT the device mode's channel count, and using the mode count here
    /// is a routing bug in both directions:
    ///
    /// * 8-channel mode: the running source counter wraps at 8, so an Optical
    ///   card's ADAT 1-8 gets fed DAW 1-8 — the same channels as the analog
    ///   outputs — instead of DAW 9-16.
    /// * 32-channel mode: the counter runs to 31, assigning P2P bytes 208-223
    ///   (USB playback 16-31). The FPGA's P2P source block is 192-207 and the
    ///   proxy's shared audio ring is 16 channels wide
    ///   (`MAESTRO_SHM_CHANNELS`, `Drivers/Shared/MaestroAudioShm.h:58`), so
    ///   nothing is ever rendered into those channels.
    ///
    /// Legacy hard-codes 16 (`SymphonyIOUSBAudioRoutingController.cpp:623-712`).
    public static let usbChannelCount: Int = 16

    /// Per-board channel counts, in the order the reset walk consumes them.
    public struct BoardChannels {
        public var analog: Int
        public var digital: Int
        public init(analog: Int, digital: Int) {
            self.analog = max(0, analog)
            self.digital = max(0, digital)
        }
    }

    /// Default OUTPUT routing: IOBoard destinations fed from P2P (USB playback).
    ///
    /// - Parameters:
    ///   - board0: Analog/digital OUTPUT channel counts on slot 0.
    ///   - board1: Analog/digital OUTPUT channel counts on slot 1.
    ///   - usbChannelCount: `cstSymphonyIOUSBAIMNumberOfUSBChannels` — 16 in the
    ///     legacy daemon, the device's actual mode channel count for us.
    public static func outputRoutes(
        board0: BoardChannels,
        board1: BoardChannels,
        usbChannelCount: Int,
        playbackBase: UInt8 = SymphonyIORoutingAddress.p2pBase
    ) -> [Route] {
        let perBoard = SymphonyIORoutingAddress.channelsPerIOBoard
        let bases = [SymphonyIORoutingAddress.ioBoard0Base, SymphonyIORoutingAddress.ioBoard1Base]
        // Pre-fill every board destination with silence, exactly as legacy does.
        var table = [[UInt8]](repeating: [UInt8](repeating: SymphonyIORoutingAddress.none, count: perBoard),
                              count: 2)
        var channelOffset = [0, 0]
        var sourceOffset = 0
        let modulo = max(1, usbChannelCount)

        func assign(_ counts: [Int]) {
            for board in 0..<2 {
                for _ in 0..<counts[board] where channelOffset[board] < perBoard {
                    table[board][channelOffset[board]] =
                        playbackBase + UInt8(sourceOffset)
                    sourceOffset = (sourceOffset + 1) % modulo
                    channelOffset[board] += 1
                }
            }
        }
        assign([board0.analog, board1.analog])
        assign([board0.digital, board1.digital])

        var routes: [Route] = []
        for board in 0..<2 {
            for index in 0..<perBoard {
                routes.append((destination: bases[board] + UInt8(index), source: table[board][index]))
            }
        }
        return routes
    }

    /// Default INPUT routing: P2P (USB record) destinations fed from IOBoard sources.
    public static func inputRoutes(
        board0: BoardChannels,
        board1: BoardChannels,
        usbChannelCount: Int
    ) -> [Route] {
        let perBoard = SymphonyIORoutingAddress.channelsPerIOBoard
        let bases = [SymphonyIORoutingAddress.ioBoard0Base, SymphonyIORoutingAddress.ioBoard1Base]
        let destinationCount = max(1, usbChannelCount)
        var table = [UInt8](repeating: SymphonyIORoutingAddress.none, count: destinationCount)
        var channelOffset = [0, 0]
        var usbIndex = 0

        func assign(_ counts: [Int]) {
            for board in 0..<2 {
                for _ in 0..<counts[board]
                where usbIndex < destinationCount && channelOffset[board] < perBoard {
                    table[usbIndex] = bases[board] + UInt8(channelOffset[board])
                    usbIndex += 1
                    channelOffset[board] += 1
                }
            }
        }
        assign([board0.analog, board1.analog])
        assign([board0.digital, board1.digital])

        return (0..<destinationCount).map { index in
            (destination: SymphonyIORoutingAddress.p2pBase + UInt8(index), source: table[index])
        }
    }
}

// MARK: - Routing Reset Safety

/// The guard and the plain-language plan that sit in front of "Reset Routing".
///
/// ## Why this exists
///
/// The default routing table is derived **entirely** from what the two option
/// slots report. Get a card wrong and the table is wrong — specifically, on an
/// Optical + AD16 unit, misreading slot 1 as another Optical card moves ADAT 1-8
/// from DAW 9-16 onto DAW 1-8, so the ADAT feed silently changes to whatever is
/// already going to the analog outputs.
///
/// The old guard only refused when BOTH slots reported `.none`. That is the wrong
/// failure mode to guard: `AppState.readCardTypes()` leaves the previous (cached)
/// value in place when a live `0xA1` read fails, so what actually reaches the
/// table builder is a *stale card*, never `.none`. The guard therefore has to be
/// about **provenance**, not about the value.
public enum RoutingResetGuard {

    /// Why the reset must not run, or nil when both slots were genuinely measured.
    ///
    /// `BoardDetectionSource.isTrustworthy` is true only for `.detected` — a live
    /// `0xA1` read this session. `.cached`, `.simulated` and `.unknown` all fail.
    public static func refusalReason(
        board1: BoardTypeReading,
        board2: BoardTypeReading
    ) -> String? {
        var untrusted: [String] = []
        if !board1.source.isTrustworthy {
            untrusted.append("Slot 1: \(board1.displayText)")
        }
        if !board2.source.isTrustworthy {
            untrusted.append("Slot 2: \(board2.displayText)")
        }
        guard !untrusted.isEmpty else { return nil }
        return """
            Reset Routing is unavailable because the installed I/O cards were not \
            detected this session.

            \(untrusted.joined(separator: "\n"))

            The default routing table is built from the card types, so a wrong card \
            would re-point real outputs — on a unit with an Optical card, the ADAT \
            outputs would change which DAW channels they carry. Nothing was written.
            """
    }

    /// Human-readable description of exactly what an OUTPUT reset would do.
    ///
    /// Derived from the same table the reset writes, so the text cannot drift from
    /// the behaviour. One line per destination run, naming the card and the DAW
    /// channels that will feed it.
    public static func outputPlanLines(board1: IOCardType, board2: IOCardType) -> [String] {
        let routes = SymphonyIODefaultRouting.outputRoutes(
            board0: .init(analog: board1.analogOutputChannels, digital: board1.digitalOutputChannels),
            board1: .init(analog: board2.analogOutputChannels, digital: board2.digitalOutputChannels),
            usbChannelCount: SymphonyIODefaultRouting.usbChannelCount)
        var byDestination: [UInt8: UInt8] = [:]
        for route in routes { byDestination[route.destination] = route.source }

        var lines: [String] = []
        for slot in 0..<2 {
            let card = slot == 0 ? board1 : board2
            let base = slot == 0
                ? SymphonyIORoutingAddress.ioBoard0Base
                : SymphonyIORoutingAddress.ioBoard1Base
            guard card != .none else {
                lines.append("Slot \(slot + 1): no card — nothing written.")
                continue
            }
            let analog = card.analogOutputChannels
            let digital = card.digitalOutputChannels
            if analog == 0 && digital == 0 {
                lines.append("Slot \(slot + 1) (\(card.productName)): no outputs.")
                continue
            }
            if analog > 0 {
                let sources = (0..<analog).map { byDestination[base &+ UInt8($0)] ?? SymphonyIORoutingAddress.none }
                lines.append("Slot \(slot + 1) (\(card.productName)) analog out 1-\(analog) ← \(describe(sources))")
            }
            if digital > 0 {
                let start = analog
                // One line per digital plug type (the 2x6 has AES then optical).
                var channel = 0
                while channel < digital {
                    let label = card.digitalLabel(forChannel: channel)
                    var count = 0
                    while channel + count < digital && card.digitalLabel(forChannel: channel + count) == label { count += 1 }
                    let sources = (0..<count).map {
                        byDestination[base &+ UInt8(start + channel + $0)] ?? SymphonyIORoutingAddress.none
                    }
                    lines.append("Slot \(slot + 1) (\(card.productName)) \(label) out 1-\(count) ← \(describe(sources))")
                    channel += count
                }
            }
        }
        return lines
    }

    /// Human-readable description of exactly what an INPUT reset would do.
    ///
    /// Input reset writes only P2P (USB record) destinations, so it can never
    /// touch a hardware output — ADAT included. That fact is stated outright in
    /// the confirmation so the user is not asked to fear the wrong thing.
    /// `usbChannelCount` is the number of USB record destinations the current
    /// device mode actually streams — a COUNT here, not the wrapping modulo it is
    /// on the output side.
    public static func inputPlanLines(
        board1: IOCardType,
        board2: IOCardType,
        usbChannelCount: Int
    ) -> [String] {
        let routes = SymphonyIODefaultRouting.inputRoutes(
            board0: .init(analog: board1.analogInputChannels, digital: board1.digitalInputChannels),
            board1: .init(analog: board2.analogInputChannels, digital: board2.digitalInputChannels),
            usbChannelCount: usbChannelCount)

        /// One hardware input group, named the way the front panel does.
        struct Group: Equatable {
            let slot: Int
            let label: String
        }
        func group(for source: UInt8) -> (group: Group, channel: Int)? {
            guard source != SymphonyIORoutingAddress.none else { return nil }
            let slot = source >= SymphonyIORoutingAddress.ioBoard1Base ? 2 : 1
            let base = slot == 2
                ? SymphonyIORoutingAddress.ioBoard1Base
                : SymphonyIORoutingAddress.ioBoard0Base
            let card = slot == 1 ? board1 : board2
            let channelOnBoard = Int(source &- base)
            let isDigital = channelOnBoard >= card.analogInputChannels
            let digitalOffset = channelOnBoard - card.analogInputChannels
            let label = isDigital ? card.digitalLabel(forChannel: digitalOffset) : "Analog"
            let number = isDigital ? card.digitalChannelNumber(forChannel: digitalOffset) : channelOnBoard + 1
            return (Group(slot: slot, label: label), number)
        }

        // Collapse the per-channel table into contiguous runs so the dialog says
        // "DAW in 1-8 ← Slot 1 Analog in 1-8", not sixteen separate lines.
        var lines: [String] = []
        var silent: [Int] = []
        var runGroup: Group?
        var runDAW: (first: Int, last: Int) = (0, 0)
        var runSource: (first: Int, last: Int) = (0, 0)

        func flush() {
            guard let current = runGroup else { return }
            lines.append(
                "DAW in \(range(runDAW)) ← Slot \(current.slot) \(current.label) in \(range(runSource))")
            runGroup = nil
        }

        for route in routes {
            let usbChannel = Int(route.destination &- SymphonyIORoutingAddress.p2pBase) + 1
            guard let (grouping, channel) = group(for: route.source) else {
                flush()
                silent.append(usbChannel)
                continue
            }
            if runGroup == grouping,
               usbChannel == runDAW.last + 1,
               channel == runSource.last + 1 {
                runDAW.last = usbChannel
                runSource.last = channel
                continue
            }
            flush()
            runGroup = grouping
            runDAW = (usbChannel, usbChannel)
            runSource = (channel, channel)
        }
        flush()

        if !silent.isEmpty {
            lines.append("DAW in \(compactRuns(silent)): no hardware input behind them — left silent.")
        }
        // What will NOT reach the DAW: hardware inputs the default table never
        // assigns, because the USB record channels ran out before they were
        // reached (analog is consumed across both boards before any digital).
        for slot in 1...2 {
            let card = slot == 1 ? board1 : board2
            guard card != .none else { continue }
            let assigned = routes.compactMap { group(for: $0.source) }
                .filter { $0.group.slot == slot }
            let analog = card.analogInputChannels
            let analogAssigned = assigned.filter { $0.group.label == "Analog" }.count
            if analog > analogAssigned {
                lines.append("Slot \(slot) Analog in \(analogAssigned + 1)-\(analog): NOT routed to the DAW.")
            }
            // Per digital plug type (the 2x6 has AES then optical).
            for label in ["AES", "ADAT"] {
                let digital = card.digitalChannelCount(label: label, isInput: true)
                guard digital > 0 else { continue }
                let digitalAssigned = assigned.filter { $0.group.label == label }.count
                if digital > digitalAssigned {
                    lines.append("Slot \(slot) \(label) in \(digitalAssigned + 1)-\(digital): NOT routed to the DAW.")
                }
            }
        }
        lines.append("Only USB record channels are written. No hardware output is touched — ADAT outputs are unaffected.")
        return lines
    }

    /// "1-8" for a run, "3" for a single channel.
    private static func range(_ run: (first: Int, last: Int)) -> String {
        run.first == run.last ? "\(run.first)" : "\(run.first)-\(run.last)"
    }

    /// Render a list of source bytes as DAW channel numbers, collapsing runs.
    private static func describe(_ sources: [UInt8]) -> String {
        var daw: [Int] = []
        var hasSilence = false
        for source in sources {
            if source == SymphonyIORoutingAddress.none {
                hasSilence = true
            } else if source >= SymphonyIORoutingAddress.p2pBase {
                daw.append(Int(source &- SymphonyIORoutingAddress.p2pBase) + 1)
            } else if source <= SymphonyIORoutingAddress.xlinkPlaybackBase &+ 31 {
                daw.append(Int(source &- SymphonyIORoutingAddress.xlinkPlaybackBase) + 1)
            }
        }
        if daw.isEmpty { return "silence" }
        let text = "DAW \(compactRuns(daw))"
        return hasSilence ? "\(text) (remainder silent)" : text
    }

    /// "1, 2, 3, 5" -> "1-3, 5".
    private static func compactRuns(_ values: [Int]) -> String {
        guard !values.isEmpty else { return "none" }
        var parts: [String] = []
        var runStart = values[0]
        var previous = values[0]
        for value in values.dropFirst() {
            if value == previous + 1 { previous = value; continue }
            parts.append(runStart == previous ? "\(runStart)" : "\(runStart)-\(previous)")
            runStart = value
            previous = value
        }
        parts.append(runStart == previous ? "\(runStart)" : "\(runStart)-\(previous)")
        return parts.joined(separator: ", ")
    }
}
