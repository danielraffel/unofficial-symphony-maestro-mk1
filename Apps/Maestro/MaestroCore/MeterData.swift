/// Metering domain model.
///
/// The Symphony IO reports real-time peak levels and over indicators for
/// all audio channels: hardware inputs, software playback, mixer outputs,
/// and hardware outputs. Meter data arrives as variable-length structs
/// that must be polled or streamed at a regular interval.
///
/// Evidence: `og_source/generic/CoreAudio/mAEstro.h` (mAEstroStreamMeter, SymphonyIOMeteringData, mAEstroHardwareMeteringData)
/// Evidence: `og_source/maestro2/App/Model/APAudioMeterBankModel.h`
/// Evidence: `og_source/maestro2/App/Controllers/APDeviceMetersViewController.h`

// MARK: - Meter Sample

/// A single channel's meter reading at one instant.
///
/// The legacy code stores `Float32 peakValue` and `BOOL over` per channel
/// in `APAudioChannelModel`. The hardware returns UInt8 levels (0–255)
/// in `mAEstroHardwareMeteringData` or Float32 peaks in `mAEstroStreamMeter`.
public struct MeterSample: Sendable, Equatable {
    /// Peak level as a linear value: 0.0 = silence, 1.0 = full scale.
    /// Derived from `m_aPeaks` in `mAEstroStreamMeter` or UInt8 hardware levels.
    public var peak: Float

    /// Whether the channel has clipped (gone over 0 dBFS).
    /// Derived from the `m_abOvers` bitmask in `mAEstroStreamMeter`
    /// or per-channel over masks in `mAEstroHardwareMeteringData`.
    public var isOver: Bool

    public init(peak: Float = 0.0, isOver: Bool = false) {
        self.peak = peak
        self.isOver = isOver
    }

    /// A silent (no signal) meter sample.
    public static let silence = MeterSample(peak: 0.0, isOver: false)
}

// MARK: - Meter Bank

/// Meter readings for a group of channels.
///
/// Corresponds to `APAudioMeterBankModel` in the legacy app, which
/// groups channels by type (input, output, mixer) for display.
public struct MeterBank: Sendable, Equatable {
    /// Per-channel meter samples, indexed by channel number.
    public var channels: [MeterSample]

    public init(channels: [MeterSample] = []) {
        self.channels = channels
    }

    /// Create a bank with a given number of silent channels.
    public init(channelCount: Int) {
        self.channels = Array(repeating: .silence, count: channelCount)
    }

    /// Clear all over flags without resetting peak values.
    public mutating func clearOvers() {
        for i in channels.indices {
            channels[i].isOver = false
        }
    }

    /// Reset all meters to silence.
    public mutating func reset() {
        for i in channels.indices {
            channels[i] = .silence
        }
    }
}

// MARK: - Meter Snapshot

/// Complete meter state for a device at one instant.
///
/// The Symphony IO has three meter groups, matching the legacy
/// `SymphonyIOMeteringData` struct:
/// - ADC (hardware input) levels
/// - Playback (software output) levels
/// - Mix (mixer bus output) levels
///
/// Evidence: `og_source/generic/CoreAudio/mAEstro.h` lines 208–216
public struct MeterSnapshot: Sendable, Equatable {
    /// Hardware input (ADC) meters.
    public var inputs: MeterBank

    /// Software playback meters.
    public var playback: MeterBank

    /// Mixer output meters.
    public var mixOutput: MeterBank

    public init(
        inputs: MeterBank = MeterBank(),
        playback: MeterBank = MeterBank(),
        mixOutput: MeterBank = MeterBank()
    ) {
        self.inputs = inputs
        self.playback = playback
        self.mixOutput = mixOutput
    }

    /// Clear all over flags across all banks.
    public mutating func clearOvers() {
        inputs.clearOvers()
        playback.clearOvers()
        mixOutput.clearOvers()
    }

    /// Reset all meters to silence.
    public mutating func reset() {
        inputs.reset()
        playback.reset()
        mixOutput.reset()
    }
}

// MARK: - Meter Configuration

/// What meters to display, corresponding to user selection.
///
/// Evidence: `og_source/generic/CoreAudio/mAEstro.h`
/// - `kmAEstroPropertyMetersShowInput` ('AEmi') — which bus to show
/// - `kmAEstroPropertyMetersFollowSelection` ('AEff') — auto-follow
/// - `kmAEstroPropertyMetersEnable` ('AEme') — enable/disable
/// - `mAEstroMeteringConfiguration` struct (line 166–172)
public struct MeterConfiguration: Sendable, Equatable {
    /// Which output channel(s) to display on the meters.
    public var outputChannel: UInt32

    /// Which mixer bus to display.
    public var mixChannel: UInt32

    /// Whether to show only minimal metering (e.g., mic settings window only).
    public var isMinimal: Bool

    /// Whether meters follow the current selection automatically.
    public var followsSelection: Bool

    /// Whether metering is enabled.
    public var isEnabled: Bool

    public init(
        outputChannel: UInt32 = 0,
        mixChannel: UInt32 = 0,
        isMinimal: Bool = false,
        followsSelection: Bool = true,
        isEnabled: Bool = true
    ) {
        self.outputChannel = outputChannel
        self.mixChannel = mixChannel
        self.isMinimal = isMinimal
        self.followsSelection = followsSelection
        self.isEnabled = isEnabled
    }
}

// MARK: - Default Factory

/// Creates default meter configurations for Symphony IO.
public enum MeterDefaults: Sendable {

    /// Default meter snapshot for Symphony IO USB at standard sample rates.
    /// 8 analog + 8 digital inputs, 16 outputs, 2 mix outputs (stereo).
    public static func snapshot(inputChannels: Int, outputChannels: Int, mixOutputChannels: Int = 2) -> MeterSnapshot {
        MeterSnapshot(
            inputs: MeterBank(channelCount: inputChannels),
            playback: MeterBank(channelCount: outputChannels),
            mixOutput: MeterBank(channelCount: mixOutputChannels)
        )
    }
}

// MARK: - Hardware Value Conversion

/// Converts between hardware meter values and domain-level representation.
///
/// Evidence: `og_source/generic/CoreAudio/mAEstro.h`
/// - `mAEstroHardwareMeteringData` uses UInt8 levels (0–255)
/// - `mAEstroStreamMeter` uses Float32 peaks
/// - Over indicators are bitmask packed in UInt32 words
public enum MeterValueConversion: Sendable {

    /// Convert a UInt8 hardware level to linear 0.0–1.0 scale.
    public static func uint8ToLinear(_ value: UInt8) -> Float {
        Float(value) / 255.0
    }

    /// Convert a linear 0.0–1.0 value to UInt8 hardware level.
    public static func linearToUInt8(_ value: Float) -> UInt8 {
        UInt8(min(max(value * 255.0, 0.0), 255.0))
    }

    /// Extract the over flag for a channel from a bitmask word.
    ///
    /// The `m_abOvers` array in `mAEstroStreamMeter` uses LSB=ch0.
    /// Multiple UInt32 words are used for >32 channels.
    public static func isOver(bitmask: UInt32, channel: Int) -> Bool {
        let bit = channel % 32
        return bitmask & (1 << bit) != 0
    }

    /// Compute the bitmask word index for a given channel.
    /// Each UInt32 word holds 32 channels of over flags.
    public static func overWordIndex(for channel: Int) -> Int {
        channel / 32
    }
}
