/// Device settings domain model.
///
/// Represents device-level settings beyond per-channel controls.
/// These map to the Device Settings and System Setup tabs in the
/// legacy Maestro UI.
///
/// Evidence: `og_source/maestro2/App/Model/APAudioDeviceModel.h`
/// Evidence: `og_source/maestro2/App/Resources/deviceDescriptions.plist`

// MARK: - Output Control

/// Controls for a physical output pair (main outs, headphones).
///
/// Evidence: `og_source/maestro2/App/Model/APAudioDeviceModel.h`
/// - mainOutLevel, mainOutMute, mainOutDim, mainOutSum
/// - headPhone1Level, headPhone1Mute, etc.
public struct OutputControl: Sendable, Equatable {
    /// Output level (dB). Range defined by `outputLevelRange`.
    public var level: Float64
    /// Whether this output is muted.
    public var isMuted: Bool
    /// Whether this output is dimmed (reduced by a fixed amount).
    public var isDimmed: Bool
    /// Whether this output is summed to mono.
    public var isSummed: Bool

    public init(
        level: Float64 = 0.0,
        isMuted: Bool = false,
        isDimmed: Bool = false,
        isSummed: Bool = false
    ) {
        self.level = level
        self.isMuted = isMuted
        self.isDimmed = isDimmed
        self.isSummed = isSummed
    }
}

// MARK: - Optical Format

/// The digital format for an optical port.
///
/// The Symphony IO optical ports can operate in different modes
/// depending on what's connected.
///
/// Evidence: `og_source/maestro2/App/Model/APAudioDeviceModel.h`
/// - opticalInFormat, opticalOutFormat, opticalFormatPort1, opticalFormatPort2
public enum OpticalFormat: String, Sendable, CaseIterable {
    /// S/PDIF (2 channels) over optical.
    case spdif = "S/PDIF"
    /// ADAT (8 channels at 44.1/48k, 4 at 88.2/96k).
    case adat = "ADAT"
    /// No optical connection / disabled.
    case off = "Off"
}

// MARK: - S/PDIF Configuration

/// S/PDIF mirror and replace settings.
///
/// "Replace" substitutes one pair of analog outputs with S/PDIF output.
/// "Mirror" copies an output pair to the S/PDIF coax output.
///
/// Evidence: `og_source/maestro2/App/Model/APAudioDeviceModel.h`
/// - SPDIFReplaceID, SPDIFMirrorID
public struct SPDIFConfig: Sendable, Equatable {
    /// Which output pair S/PDIF replaces (by ID), or nil if none.
    public var replaceID: UInt32?
    /// Which output pair S/PDIF mirrors (by ID), or nil if none.
    public var mirrorID: UInt32?

    public init(replaceID: UInt32? = nil, mirrorID: UInt32? = nil) {
        self.replaceID = replaceID
        self.mirrorID = mirrorID
    }
}

// MARK: - Meter Display Settings

/// How meters are displayed in the UI.
///
/// Evidence: `og_source/maestro2/App/Model/APAudioDeviceModel.h`
/// - peakHoldMode, oversHoldMode
public struct MeterDisplaySettings: Sendable, Equatable {
    /// Peak hold mode: how long peaks are displayed.
    public var peakHoldMode: PeakHoldMode
    /// Over hold mode: how long over indicators are displayed.
    public var oversHoldMode: OverHoldMode

    public init(
        peakHoldMode: PeakHoldMode = .infinite,
        oversHoldMode: OverHoldMode = .infinite
    ) {
        self.peakHoldMode = peakHoldMode
        self.oversHoldMode = oversHoldMode
    }

    /// `eSymphonyIOMeteringLEDPeakHold` -- `SymphonyIOVendorSpecific.h:698-703`.
    ///
    /// `wireValue` is the byte the hardware expects. Legacy binds the popup's
    /// `selectedIndex` straight to the property
    /// (`APSystemMetersViewController.m:69-71`), so menu order and wire value
    /// are the same number and neither can be reordered independently.
    public enum PeakHoldMode: String, Sendable, CaseIterable {
        case off = "Off"
        case twoSeconds = "2 Seconds"
        case infinite = "Infinite"

        public var wireValue: UInt32 {
            switch self {
            case .off:        return 0
            case .twoSeconds: return 1
            case .infinite:   return 2
            }
        }
    }

    /// `eSymphonyIOMeteringLEDOverHold` -- `SymphonyIOVendorSpecific.h:706-712`.
    ///
    /// Note this carries a fourth mode the peak enum does not: `AutoClear = 3`.
    /// The User's Guide (p. 77) lists only Off / 2 seconds / Infinite for both,
    /// but the daemon accepts AutoClear as valid when reading the unit back
    /// (`SymphonyIO.cpp:1366-1372`), so a unit can legitimately be in it.
    public enum OverHoldMode: String, Sendable, CaseIterable {
        case off = "Off"
        case twoSeconds = "2 Seconds"
        case infinite = "Infinite"
        case autoClear = "Auto Clear"

        public var wireValue: UInt32 {
            switch self {
            case .off:        return 0
            case .twoSeconds: return 1
            case .infinite:   return 2
            case .autoClear:  return 3
            }
        }
    }
}

// MARK: - Device Settings

/// Complete device-level settings for a Symphony IO USB.
///
/// This aggregates all the settings from APAudioDeviceModel that are
/// not per-channel (those are in the channel/mixer/routing models).
///
/// Evidence: `og_source/maestro2/App/Model/APAudioDeviceModel.h`
public struct DeviceSettings: Sendable, Equatable {

    // MARK: Output controls

    /// Main output pair control.
    public var mainOutput: OutputControl

    /// Headphone output 1 control.
    public var headphone1: OutputControl

    /// Headphone output 2 control.
    public var headphone2: OutputControl

    /// Output level range (min/max dB).
    public var outputLevelRange: ClosedRange<Float64>

    // MARK: Digital I/O

    /// Optical format for port 1.
    public var opticalFormatPort1: OpticalFormat

    /// Optical format for port 2.
    public var opticalFormatPort2: OpticalFormat

    /// S/PDIF replace/mirror configuration.
    public var spdifConfig: SPDIFConfig

    // MARK: Headphone routing

    /// Source routing ID for headphone 1 (which output pair feeds it).
    public var headphone1RoutingID: UInt32

    /// Source routing ID for headphone 2.
    public var headphone2RoutingID: UInt32

    // MARK: Meter display

    /// Meter display settings (peak hold, over hold).
    public var meterDisplay: MeterDisplaySettings

    // MARK: Device identity

    /// Custom device name prefix.
    public var namePrefix: String

    /// Firmware version string.
    public var firmwareVersion: String

    public init(
        mainOutput: OutputControl = OutputControl(),
        headphone1: OutputControl = OutputControl(),
        headphone2: OutputControl = OutputControl(),
        outputLevelRange: ClosedRange<Float64> = -64.0...0.0,
        opticalFormatPort1: OpticalFormat = .spdif,
        opticalFormatPort2: OpticalFormat = .spdif,
        spdifConfig: SPDIFConfig = SPDIFConfig(),
        headphone1RoutingID: UInt32 = 0,
        headphone2RoutingID: UInt32 = 0,
        meterDisplay: MeterDisplaySettings = MeterDisplaySettings(),
        namePrefix: String = "",
        firmwareVersion: String = ""
    ) {
        self.mainOutput = mainOutput
        self.headphone1 = headphone1
        self.headphone2 = headphone2
        self.outputLevelRange = outputLevelRange
        self.opticalFormatPort1 = opticalFormatPort1
        self.opticalFormatPort2 = opticalFormatPort2
        self.spdifConfig = spdifConfig
        self.headphone1RoutingID = headphone1RoutingID
        self.headphone2RoutingID = headphone2RoutingID
        self.meterDisplay = meterDisplay
        self.namePrefix = namePrefix
        self.firmwareVersion = firmwareVersion
    }
}
