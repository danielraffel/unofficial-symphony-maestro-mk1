/// State for a single output channel.
///
/// `Codable` so values can be persisted to UserDefaults and `.mst2` preset files.
/// Since the Symphony IO MKI cannot be read back per-channel (P3G-31 BLOCKED),
/// state is restored from UserDefaults on startup so the UI reflects the last session.
///
/// Evidence: `og_source/maestro2/App/Model/APAudioDeviceModel.h`
/// Evidence: `og_source/generic/CoreAudio/mAEstro.h` — output properties
/// Evidence: `SymphonyIOVendorSpecific.h` — SymphonyIOAnalogIOType, SymphonyIODigitalReferenceLevel
public struct OutputChannelState: Codable, Sendable, Equatable {
    /// Analog reference level. Maps to 'AErl' (analogIOType) scope=output.
    /// 1=+4 dBu, 2=-10 dBV. (0=Variable is input-only; outputs don't have Variable.)
    public var analogRefLevel: UInt32 = 1
    /// Digital reference level ID. Maps to 'AEdr' (digitalRefLevel) scope=output.
    /// 0=-20dBfs, 1=-18dBfs, 2=-16dBfs, 3=-14dBfs, 4=-12dBfs, 5=-10dBfs.
    public var digitalRefLevel: UInt32 = 2  // default -16 dBfs (matches original)
    /// Calibration trim in dB. Range ±2.0, 0.1 step.
    /// Sent as part of the analog ref level USB command (byte[1]).
    public var trim: Double = 0.0

    public init(
        analogRefLevel: UInt32 = 1,
        digitalRefLevel: UInt32 = 2,
        trim: Double = 0.0
    ) {
        self.analogRefLevel = analogRefLevel
        self.digitalRefLevel = digitalRefLevel
        self.trim = trim
    }
}
