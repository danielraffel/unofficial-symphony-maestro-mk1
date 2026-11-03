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
