/// Clock configuration domain model.
///
/// The Symphony IO can derive its audio clock from several sources:
/// its internal crystal, an external word clock input, a digital audio
/// input (AES/Optical/S/PDIF), or loop sync from another device.
/// The clock source determines the master timing for all audio I/O.
///
/// Evidence: `og_source/maestrolink/Software/SymphonyIO/SymphonyIOVendorSpecific.h` (SymphonyIOClockSource enum, lines 857–865)
/// Evidence: `og_source/maestrolink/Software/SymphonyIO/SymphonyIOControl.h` (setClockMode/getClockMode)
/// Evidence: `og_source/generic/CoreAudio/mAEstro.h` (kmAEStroPropertyClockSource)
/// Evidence: `og_source/generic/CoreAudio/ApogeeCustomProperties.h` (kApogeeCustomProperty_ClockSourceID, SampleRate, ClockStatus)

// MARK: - Clock Source

/// The primary clock source for the device.
///
/// Maps to `SymphonyIOClockSource` enum in the legacy code.
/// Evidence: `SymphonyIOVendorSpecific.h` lines 857–865
public enum ClockSource: String, Sendable, CaseIterable {
    /// Internal crystal oscillator. The device generates its own clock.
    case `internal` = "Internal"
    /// External word clock input (BNC connector).
    case wordClock = "Word Clock"
    /// Loop sync — device slaves to another device's clock.
    case loopSync = "Loop Sync"
    /// Digital I/O board 1 (recovers clock from incoming digital audio).
    case ioBoard1 = "IO Board 1"
    /// Digital I/O board 2.
    case ioBoard2 = "IO Board 2"
}

// MARK: - Board Clock Source

/// When the primary clock source is an IO board, this specifies which
/// digital input on that board provides the clock reference.
///
/// Evidence: `SymphonyIOVendorSpecific.h` lines 879–888
/// (SymphonyIOAnalogAESOptBoardClockSourceIdx)
public enum BoardClockSource: String, Sendable, CaseIterable {
    case aes12 = "AES 1-2"
    case aes34 = "AES 3-4"
    case aes56 = "AES 5-6"
    case aes78 = "AES 7-8"
    case optical0 = "Optical 1"
    case optical1 = "Optical 2"
    case spdifCoax = "S/PDIF Coax"

    /// The byte ClockMode (0x50) carries in `pData[3]` for this input: the
    /// `SymphonyIOAnalogAESOptBoardClockSourceIdx` value
    /// (`og_source/maestrolink/Software/SymphonyIO/SymphonyIOVendorSpecific.h:879-888`).
    ///
    /// The comment on `SymphonyIOCommands_ClockMode` in the same header
    /// (`:234-247`) numbers these differently (S/PDIF Coax 0, AES 1-2 = 1). The
    /// software and firmware Apogee shipped both use the enum: the daemon sends
    /// `eSymphonyIOAnalogAESOptBoardClockSourceIdx_AES12 + i` for AES pair `i`
    /// (`og_source/maestrolink/Software/AESIn_SymphonyIO_Stream.cpp:57-93`) and
    /// `..._SPDIFCoax` for the coax input (`SymphonyIO_IOBoard.cpp:57-77`), and
    /// the firmware's own front-panel clock list uses the same values
    /// (`og_source/symphonymk1/ext/SymphonyIO/Software/XMOS/SymphonyIO/src/XMOS/
    /// XCore/Core3/SymphonyIOStateThread/SymphonyIOStateData/SymphonyIOStateData.cpp:1988-2008`).
    public var wireIndex: UInt8 {
        switch self {
        case .aes12: return 0
        case .aes34: return 1
        case .aes56: return 2
        case .aes78: return 3
        case .optical0: return 4
        case .optical1: return 5
        case .spdifCoax: return 6
        }
    }
}

// MARK: - Clock Source menu

/// One row of the Clock Source menu and what choosing it sends.
public struct ClockSourceChoice: Sendable, Equatable, Identifiable {
    /// The picker key. 1-5 are the plain `eSymphonyIOClockSource` values (the
    /// ThunderBridge driver's own clock control uses the same numbers); an input
    /// on an I/O board is `source | (boardInput + 1) << 8`, see
    /// ``ClockSourceMenu/key(source:boardInput:)``.
    public let id: UInt32
    public let name: String
    /// ClockMode `pData[0]`, an `eSymphonyIOClockSource` value.
    public let source: UInt8
    /// ClockMode `pData[3]` when the row names a particular board input; nil
    /// for the plain sources.
    public let boardInput: UInt8?
}

/// The Clock Source menu for each connection, as Apogee's software built it.
public enum ClockSourceMenu {
    public static let internalClock: UInt32 = 1
    public static let wordClock: UInt32 = 2
    public static let loopSync: UInt32 = 3
    public static let ioBoard1: UInt32 = 4
    public static let ioBoard2: UInt32 = 5
    /// The highest board input the original ever sent: S/PDIF coax, 6
    /// (`SymphonyIOVendorSpecific.h:879-888`). The firmware writes the byte
    /// straight into the board FPGA's clock select
    /// (`SymphonyIOClockManager.cpp:169, 216-224`), so nothing above it is sent.
    public static let maxBoardInput: UInt8 = BoardClockSource.spdifCoax.wireIndex

    /// The picker key for a board input. Kept above 0xFF so it can never be
    /// mistaken for a plain source, and so `key & 0xFF` is the source.
    public static func key(source: UInt8, boardInput: UInt8) -> UInt32 {
        UInt32(source) | ((UInt32(boardInput) + 1) << 8)
    }

    /// The ClockMode bytes a key stands for: the source and, for a board input,
    /// `pData[3]`. Nil for anything that is not a source.
    public static func decode(_ key: UInt32) -> (source: UInt8, boardInput: UInt8?)? {
        let source = UInt8(key & 0xFF)
        guard (1...5).contains(source), key <= 0xFFFF else { return nil }
        let high = key >> 8
        if high == 0 { return (source, nil) }
        guard source == 4 || source == 5, high - 1 <= UInt32(maxBoardInput) else { return nil }
        return (source, UInt8(high - 1))
    }

    /// The older converters (AD-16X, DA-16X, DD-16X, Rosetta) on a
    /// ThunderBridge: their own clock or word clock, nothing else, as the
    /// original offered for them. Sent to the driver as the converter config's
    /// clock bit, never as a Symphony I/O ClockMode.
    public static let converters: [ClockSourceChoice] = [
        ClockSourceChoice(id: internalClock, name: "Internal", source: 1, boardInput: nil),
        ClockSourceChoice(id: wordClock, name: "External (Word Clock)", source: 2, boardInput: nil),
    ]

    /// Over USB: Internal only (see `SystemSetupView.clockSourceChoices`).
    public static let usb: [ClockSourceChoice] = [
        ClockSourceChoice(id: internalClock, name: "Internal", source: 1, boardInput: nil),
    ]

    /// Over ThunderBridge.
    ///
    /// In the Symphony (PCIe) mode Apogee's daemon listed Internal and Word
    /// Clock, then each fitted board's own clock sources
    /// (`og_source/maestrolink/Software/SymphonyIO.cpp:1727-1766`): the board's
    /// S/PDIF coax input first, then its input streams' sources in stream order
    /// (`SymphonyIO_IOBoard.cpp:79-90`, `NonCADeviceObject.cpp:326-370`). Only
    /// AES and optical input streams have clock sources
    /// (`AESIn_SymphonyIO_Stream.cpp:40-44, 95-104`,
    /// `OpticalIn_SymphonyIO_Stream.cpp:82-104`); analog and output streams have
    /// none (`NonCoreAudioObject.h:91`). So, per card:
    ///
    /// - 8x8 AES: coax, AES 1-2, 3-4, 5-6, 7-8 (inputs 6, 0-3).
    /// - 8x8 Optical: coax, optical (inputs 6, 4).
    /// - A16 OP (DA16): coax, optical; the optical input is 0 in S/PDIF format
    ///   and 2 in ADAT/SMUX (`DA16OpticalIn_SymphonyIO_Stream.cpp:24-45`).
    /// - 2x6: coax, AES 1-2, optical (inputs 6, 0, 4; `SymphonyIOBoard_2x6.cpp:40-52`).
    /// - A16 IP (AD16) and 16x16 (ADDA16): coax only (6).
    /// - 8MicPre or an empty slot: nothing (`SymphonyIOBoard_MicPre8ch.h:36`).
    ///
    /// Choosing one sends ClockMode with the board as the source and the input
    /// in `pData[3]` (`AESIn_SymphonyIO_Stream.cpp:57-93`,
    /// `OpticalIn_SymphonyIO_Stream.cpp:106-129`, `SymphonyIO_IOBoard.cpp:57-77`).
    /// Names follow the daemon's (`SymphonyIO_IOBoard.cpp:1286-1308`,
    /// `AESIn_SymphonyIO_Stream.cpp:198-226`,
    /// `OpticalIn_SymphonyIO_Stream.cpp:246-302`); slot 2 numbers on from slot
    /// 1's channels of the same kind (`SymphonyIO_IOBoard.cpp:1533-1560`). The
    /// optical row's name depends on the rate and the board's optical format,
    /// so pass them when known; without them it is named as ADAT, the format
    /// both drivers set at start.
    ///
    /// No Loop Sync: in the Symphony mode the original listed it only in the
    /// Pro Tools HD boot mode (`SymphonyIO.cpp:1726-1767`), which ThunderBridge
    /// never runs in.
    public static func thunderbolt(slot1: IOCardType, slot2: IOCardType,
                                   sampleRate: Double? = nil,
                                   opticalIsSPDIF: [Bool?] = [nil, nil]) -> [ClockSourceChoice] {
        var choices = [
            ClockSourceChoice(id: internalClock, name: "Internal", source: 1, boardInput: nil),
            ClockSourceChoice(id: wordClock, name: "Word Clock", source: 2, boardInput: nil),
        ]
        let spdif = { (slot: Int) -> Bool? in slot < opticalIsSPDIF.count ? opticalIsSPDIF[slot] : nil }
        choices += boardChoices(slot: 0, card: slot1, preceding: .none,
                                sampleRate: sampleRate, opticalIsSPDIF: spdif(0))
        choices += boardChoices(slot: 1, card: slot2, preceding: slot1,
                                sampleRate: sampleRate, opticalIsSPDIF: spdif(1))
        return choices
    }

    /// Unit A's rows while a second Symphony I/O (unit B, port 2) follows it:
    /// no Loop Sync. The driver keeps unit A's Loop Sync output on for unit B
    /// and refuses Loop Sync as unit A's own source then.
    public static func unitAChoices(_ choices: [ClockSourceChoice], unitBFollows: Bool) -> [ClockSourceChoice] {
        unitBFollows ? choices.filter { $0.source != UInt8(loopSync) } : choices
    }

    /// Whether a picker key may be sent to unit A.
    public static func unitAMaySend(_ key: UInt32, unitBFollows: Bool) -> Bool {
        !(unitBFollows && decode(key)?.source == UInt8(loopSync))
    }

    /// Shown under unit A's clock picker while unit B follows it.
    public static let loopSyncUnavailableNote =
        "Unit A can't take Loop Sync while unit B follows it."

    /// Shown when the driver refuses a clock choice while unit B follows unit A.
    public static let refusedWithUnitBNote =
        "The driver did not accept that clock source while unit B follows unit A through Loop Sync."

    /// The board input byte an optical clock row sends. The DA16's optical
    /// receiver has its own index table (`SymphonyIOVendorSpecific.h:903-912`).
    public static func opticalClockInput(card: IOCardType, opticalIsSPDIF: Bool?) -> UInt8 {
        if card == .analogDA16 { return opticalIsSPDIF == true ? 0 : 2 }
        return BoardClockSource.optical0.wireIndex
    }

    /// The daemon's name for a board's optical clock source
    /// (`OpticalIn_SymphonyIO_Stream.cpp:257-295`): N.A. at 176.4 kHz and up;
    /// in S/PDIF format "SPDIF Opt n-m"; above 48 kHz "SMUX n-(n+3)"; otherwise
    /// "ADAT n-(n+7)", numbered on from slot 1's optical inputs.
    public static func opticalClockName(precedingOpticalInputs: Int,
                                        sampleRate: Double?,
                                        opticalIsSPDIF: Bool?) -> String {
        let rate = sampleRate ?? 48000
        guard rate < 176400 else { return "N.A." }
        if opticalIsSPDIF == true {
            let offset = precedingOpticalInputs / 8
            return "SPDIF Opt \(offset * 2 + 1)-\(offset * 2 + 2)"
        }
        let first = precedingOpticalInputs + 1
        return rate > 48000 ? "SMUX \(first)-\(first + 3)" : "ADAT \(first)-\(first + 7)"
    }

    private static func boardChoices(slot: Int, card: IOCardType, preceding: IOCardType,
                                     sampleRate: Double?,
                                     opticalIsSPDIF: Bool?) -> [ClockSourceChoice] {
        let source: UInt8 = slot == 0 ? 4 : 5
        guard card.hasSPDIFCoax else { return [] }
        func row(_ name: String, _ input: UInt8) -> ClockSourceChoice {
            ClockSourceChoice(id: key(source: source, boardInput: input),
                              name: name, source: source, boardInput: input)
        }
        // Channels on slot 1 that slot 2's numbering continues from.
        let coaxBefore = preceding.hasSPDIFCoax ? 2 : 0
        let aesBefore = preceding.digitalChannelCount(label: "AES", isInput: true)
        let opticalBefore = preceding.digitalChannelCount(label: "ADAT", isInput: true)

        var rows = [row("SPDIF Coax \(coaxBefore + 1)-\(coaxBefore + 2)",
                        BoardClockSource.spdifCoax.wireIndex)]
        let aesPairs = card.digitalChannelCount(label: "AES", isInput: true) / 2
        for pair in 0..<aesPairs {
            let first = aesBefore + pair * 2 + 1
            rows.append(row("AES \(first)-\(first + 1)", UInt8(pair)))
        }
        if card.digitalChannelCount(label: "ADAT", isInput: true) > 0 {
            rows.append(row(opticalClockName(precedingOpticalInputs: opticalBefore,
                                             sampleRate: sampleRate,
                                             opticalIsSPDIF: opticalIsSPDIF),
                            opticalClockInput(card: card, opticalIsSPDIF: opticalIsSPDIF)))
        }
        return rows
    }

    /// The row to show for a source the hardware or driver reported. A plain
    /// IO Board source (what the driver's clock control reports; it always
    /// sends input byte 0) selects that board's input-0 row when it has one:
    /// AES 1-2 on an AES or 2x6 board, the S/PDIF optical input on a DA16.
    /// Nil when nothing matches.
    public static func row(for reported: UInt32, in choices: [ClockSourceChoice]) -> UInt32? {
        if choices.contains(where: { $0.id == reported }) { return reported }
        guard let decoded = decode(reported) else { return nil }
        let plain = UInt32(decoded.source)
        if choices.contains(where: { $0.id == plain }) { return plain }
        if decoded.boardInput == nil, decoded.source == 4 || decoded.source == 5 {
            let input0 = key(source: decoded.source, boardInput: 0)
            if choices.contains(where: { $0.id == input0 }) { return input0 }
        }
        return nil
    }
}

// MARK: - Sample Rate

/// Standard audio sample rates supported by the Symphony IO USB.
///
/// The available rates depend on the USB mode (channel count):
/// - 32ch (PID 18): 44.1, 48 kHz only
/// - 16ch (PID 16): 44.1, 48, 88.2, 96 kHz
/// - 8ch  (PID 17): 44.1, 48, 88.2, 96, 176.4, 192 kHz
///
/// Evidence: `og_source/generic/ApogeeUSBProductID.h` (PIDs 16/17/18)
public enum SampleRate: Float64, Sendable, CaseIterable, Comparable {
    case rate44100  = 44100.0
    case rate48000  = 48000.0
    case rate88200  = 88200.0
    case rate96000  = 96000.0
    case rate176400 = 176400.0
    case rate192000 = 192000.0

    /// Human-readable display string.
    public var displayName: String {
        switch self {
        case .rate44100:  return "44.1 kHz"
        case .rate48000:  return "48 kHz"
        case .rate88200:  return "88.2 kHz"
        case .rate96000:  return "96 kHz"
        case .rate176400: return "176.4 kHz"
        case .rate192000: return "192 kHz"
        }
    }

    /// Whether this is a "high" sample rate (2x base rates).
    public var isDouble: Bool {
        rawValue >= 88200.0 && rawValue < 176400.0
    }

    /// Whether this is a "quad" sample rate (4x base rates).
    public var isQuad: Bool {
        rawValue >= 176400.0
    }

    public static func < (lhs: SampleRate, rhs: SampleRate) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Clock Status

/// The lock/sync status of the device's clock.
///
/// Evidence: `og_source/generic/CoreAudio/ApogeeCustomProperties.h`
/// `kApogeeCustomProperty_ClockStatus` ('AEs3')
public enum ClockStatus: String, Sendable {
    /// Clock is locked and stable.
    case locked = "Locked"
    /// Clock is not locked (no valid signal on selected source).
    case unlocked = "Unlocked"
    /// Clock source is syncing (transient state).
    case syncing = "Syncing"
}

// MARK: - Clock Configuration

/// Complete clock state for a device.
///
/// Evidence: `og_source/maestrolink/Software/SymphonyIO/SymphonyIOControl.h` lines 173–174, 187
/// - `setClockMode(clockSource, fIsClockMaster, fUseLoopSync, boardClockSource)`
/// - `getClockMode(pClockSource, pBoardClockSource)`
public struct ClockConfig: Sendable, Equatable {
    /// The primary clock source.
    public var source: ClockSource

    /// The board-level clock source (only relevant when source is .ioBoard1 or .ioBoard2).
    public var boardSource: BoardClockSource?

    /// The current sample rate.
    public var sampleRate: SampleRate

    /// Whether the device is the clock master on the sync chain.
    public var isClockMaster: Bool

    /// Whether word clock termination is enabled (75 ohm).
    /// Evidence: `mAEstro.h` kMaestroPropertyWordClockTermination ('AEwt')
    public var wordClockTermination: Bool

    /// Current lock status.
    public var status: ClockStatus

    public init(
        source: ClockSource = .internal,
        boardSource: BoardClockSource? = nil,
        sampleRate: SampleRate = .rate48000,
        isClockMaster: Bool = true,
        wordClockTermination: Bool = false,
        status: ClockStatus = .locked
    ) {
        self.source = source
        self.boardSource = boardSource
        self.sampleRate = sampleRate
        self.isClockMaster = isClockMaster
        self.wordClockTermination = wordClockTermination
        self.status = status
    }
}

// MARK: - Sample Rate Availability

/// Determines available sample rates based on Symphony IO USB mode.
///
/// Evidence: `og_source/generic/ApogeeUSBProductID.h`
/// - PID 16 (0x10): SymphonyIOUSBAudio — 16ch, 44.1–96 kHz
/// - PID 17 (0x11): SymphonyIOUSBAudio8 — 8ch, 44.1–192 kHz
/// - PID 18 (0x12): SymphonyIOUSBAudio32 — 32ch, 44.1–48 kHz
public enum SampleRateAvailability: Sendable {

    /// Available rates for 32-channel USB mode (PID 18).
    public static let mode32ch: [SampleRate] = [.rate44100, .rate48000]

    /// Available rates for 16-channel USB mode (PID 16).
    public static let mode16ch: [SampleRate] = [.rate44100, .rate48000, .rate88200, .rate96000]

    /// Available rates for 8-channel USB mode (PID 17).
    public static let mode8ch: [SampleRate] = SampleRate.allCases
}
