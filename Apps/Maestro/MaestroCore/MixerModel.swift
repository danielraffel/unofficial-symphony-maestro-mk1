/// Mixer domain model.
///
/// The Symphony IO has multiple low-latency hardware mixers that blend
/// device inputs and software playback into stereo output pairs. Each
/// mixer has input channels, a software return, and a master output.
///
/// Evidence: `og_source/generic/CoreAudio/mAEstro.h` (MaestroMixerChannelBitMask, mixer selectors)
/// Evidence: `og_source/maestrolink/Software/SymphonyIO/SymphonyIOVendorSpecific.h` (mixer constants)
/// Evidence: `og_source/maestro2/App/Model/APAudioMixerModel.h`
/// Evidence: `og_source/maestro2/App/Model/APAudioMixerChannelModel.h`
/// Evidence: `og_source/maestro2/App/Model/APAudioMixerMasterChannelModel.h`
/// Evidence: `og_source/maestro2/App/Model/APAudioMixerSoftwareReturnModel.h`

// MARK: - Mixer Element Encoding

/// Encodes a mixer channel identity into a UInt32 element value.
///
/// The legacy code packs mixer identity into a bitmask:
/// - Bits 0–7: channel index within the mixer (0–255)
/// - Bit 12: software return flag
/// - Bit 13: master output flag
/// - Bits 16–19: mixer index (0–15)
///
/// Evidence: `og_source/generic/CoreAudio/mAEstro.h` lines 595–602
public struct MixerElementID: Sendable, Equatable, Hashable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// The mixer index (0-based).
    public var mixerIndex: Int {
        Int((rawValue & 0xF0000) >> 16)
    }

    /// The channel index within the mixer.
    public var channelIndex: Int {
        Int(rawValue & 0x000FF)
    }

    /// Whether this is the software return channel.
    public var isSoftwareReturn: Bool {
        rawValue & 0x01000 != 0
    }

    /// Whether this is the master output channel.
    public var isMasterOutput: Bool {
        rawValue & 0x02000 != 0
    }

    /// Create an element ID for an input channel.
    public static func inputChannel(mixer: Int, channel: Int) -> MixerElementID {
        MixerElementID(rawValue: UInt32(mixer) << 16 | UInt32(channel))
    }

    /// Create an element ID for the software return.
    public static func softwareReturn(mixer: Int) -> MixerElementID {
        MixerElementID(rawValue: UInt32(mixer) << 16 | 0x01000)
    }

    /// Create an element ID for the master output.
    public static func masterOutput(mixer: Int) -> MixerElementID {
        MixerElementID(rawValue: UInt32(mixer) << 16 | 0x02000)
    }
}

// MARK: - Mixer Channel

/// Per-channel mixer state (level, pan, mute, solo).
///
/// Every fader strip in the mixer — whether a device input, software return,
/// or master output — shares these same controls.
///
/// Evidence: `og_source/maestro2/App/Model/APAudioMixerChannelModel.h`
/// - `mixerLevel` (Float64, dB)
/// - `mixerPan` (Float64)
/// - `mixerMute` (Bool)
/// - `mixerSolo` (Bool)
/// - `mixerLabel` (String)
public struct MixerChannel: Sendable, Equatable {
    /// Fader level in dB. Range: -48.0 (silence) to +6.0.
    ///
    /// Evidence: `SymphonyIOVendorSpecific.h`
    /// - `kSymphonyIOMixer_ScaledFaderSettingZeroOffset = 48`
    /// - Hardware stores as 0–54 unsigned (offset by 48).
    public var level: Float64

    /// Pan position. Range: -1.0 (full left) to +1.0 (full right), 0.0 = center.
    ///
    /// Evidence: `SymphonyIOVendorSpecific.h`
    /// - `kSymphonyIOMixer_ScaledPanSettingZeroOffset = 64`
    /// - Hardware stores as 0–128 unsigned (offset by 64, then /64).
    public var pan: Float64

    /// Whether this channel is muted.
    public var isMuted: Bool

    /// Whether this channel is soloed.
    public var isSoloed: Bool

    /// Display label for this channel.
    public var label: String

    public init(
        level: Float64 = MixerConstants.levelMinimum,
        pan: Float64 = 0.0,
        isMuted: Bool = false,
        isSoloed: Bool = false,
        label: String = ""
    ) {
        self.level = level
        self.pan = pan
        self.isMuted = isMuted
        self.isSoloed = isSoloed
        self.label = label
    }
}

// MARK: - Mixer

/// A single stereo mixer instance.
///
/// Each mixer in the Symphony IO blends up to 32 device input channels
/// plus a software return pair into a master stereo output. The device
/// supports up to 4 independent mixers.
///
/// Evidence: `og_source/maestro2/App/Model/APAudioMixerModel.h`
/// - `mixerIndex`, `mixerChannelSet`, `master`, `softwareReturn`
/// - `mixerInputChannels` (fetched property)
public struct Mixer: Sendable, Equatable {
    /// Zero-based mixer index.
    public let index: Int

    /// Input channel strips (hardware device inputs routed into this mixer).
    /// Up to 32 channels for Symphony IO.
    public var inputChannels: [MixerChannel]

    /// The software return strip (returns software playback audio to the mixer).
    public var softwareReturn: MixerChannel

    /// The master output strip.
    public var master: MixerChannel

    /// Source ID for the software return (which software stream feeds it).
    public var softwareReturnSourceID: UInt32

    /// Output ID for the master (which hardware output this mixer feeds).
    public var masterOutputID: UInt32

    public init(
        index: Int,
        inputChannels: [MixerChannel] = [],
        softwareReturn: MixerChannel = MixerChannel(label: "SW Return"),
        master: MixerChannel = MixerChannel(level: 0.0, label: "Master"),
        softwareReturnSourceID: UInt32 = 0,
        masterOutputID: UInt32 = 0
    ) {
        self.index = index
        self.inputChannels = inputChannels
        self.softwareReturn = softwareReturn
        self.master = master
        self.softwareReturnSourceID = softwareReturnSourceID
        self.masterOutputID = masterOutputID
    }
}

// MARK: - Mixer Bank

/// All mixers for a device.
///
/// The Symphony IO supports up to 4 independent stereo mixers.
/// The actual count depends on the device configuration and sample rate.
public struct MixerBank: Sendable, Equatable {
    /// The device's mixers, indexed by mixer number.
    public var mixers: [Mixer]

    public init(mixers: [Mixer] = []) {
        self.mixers = mixers
    }

    /// Look up a mixer by index.
    public func mixer(at index: Int) -> Mixer? {
        mixers.first { $0.index == index }
    }
}

// MARK: - Constants

/// Constants for Symphony IO mixer configuration.
///
/// Evidence: `og_source/maestrolink/Software/SymphonyIO/SymphonyIOVendorSpecific.h`
/// lines 1108–1123
public enum MixerConstants: Sendable {
    /// Maximum number of stereo mixers in Symphony IO.
    public static let maxMixerCount = 4

    /// Number of device input channels per mixer.
    public static let inputChannelCount = 32

    /// Total fader count per mixer (inputs + software return + master).
    public static let faderCount = 34

    /// Fader index where device inputs start.
    public static let faderIndexDeviceInputs = 0

    /// Fader index of the software return.
    public static let faderIndexSoftwareReturn = 32

    /// Fader index of the master output.
    public static let faderIndexMasterOut = 33

    /// Minimum fader level in dB.
    public static let levelMinimum: Float64 = -48.0

    /// Maximum fader level in dB.
    public static let levelMaximum: Float64 = 6.0

    /// Hardware offset for scaled fader values (0 represents -48 dB).
    public static let scaledFaderZeroOffset = 48

    /// Hardware offset for scaled pan values (0 represents full-left/-64).
    public static let scaledPanZeroOffset = 64
}

// MARK: - Default Factory

/// Creates default mixer configurations for Symphony IO.
public enum MixerDefaults: Sendable {

    /// Create a default mixer bank with the specified number of mixers.
    /// Each mixer gets default input channels at minimum level, center pan.
    public static func bank(mixerCount: Int, inputChannelsPerMixer: Int = MixerConstants.inputChannelCount) -> MixerBank {
        let mixers = (0..<mixerCount).map { index in
            mixer(index: index, inputChannelCount: inputChannelsPerMixer)
        }
        return MixerBank(mixers: mixers)
    }

    /// Create a single default mixer.
    public static func mixer(index: Int, inputChannelCount: Int = MixerConstants.inputChannelCount) -> Mixer {
        let inputs = (0..<inputChannelCount).map { ch in
            MixerChannel(label: "In \(ch + 1)")
        }
        return Mixer(
            index: index,
            inputChannels: inputs,
            softwareReturn: MixerChannel(label: "SW Return"),
            master: MixerChannel(level: 0.0, label: "Master")
        )
    }
}

// MARK: - Hardware Value Conversion

/// Converts between domain-level mixer values and hardware-level scaled integers.
///
/// Evidence: `og_source/maestrolink/Software/SymphonyIO/SymphonyIOControl.cpp`
/// lines 1910, 1930, 1990, 2011
public enum MixerValueConversion: Sendable {

    /// Convert a dB level to the hardware's scaled integer value.
    /// Domain: -48.0 to +6.0 dB → Hardware: 0 to 54.
    public static func levelToScaled(_ level: Float64) -> Int {
        Int(level) + MixerConstants.scaledFaderZeroOffset
    }

    /// Convert a hardware scaled integer to dB level.
    /// Hardware: 0 to 54 → Domain: -48.0 to +6.0 dB.
    public static func scaledToLevel(_ scaled: Int) -> Float64 {
        Float64(scaled - MixerConstants.scaledFaderZeroOffset)
    }

    /// Convert a normalized pan value to the hardware's scaled integer.
    /// Domain: -1.0 to +1.0 → Hardware: 0 to 128.
    public static func panToScaled(_ pan: Float64) -> Int {
        Int(pan * 64.0) + MixerConstants.scaledPanZeroOffset
    }

    /// Convert a hardware scaled pan integer to normalized value.
    /// Hardware: 0 to 128 → Domain: -1.0 to +1.0.
    public static func scaledToPan(_ scaled: Int) -> Float64 {
        Float64(scaled - MixerConstants.scaledPanZeroOffset) / 64.0
    }
}
