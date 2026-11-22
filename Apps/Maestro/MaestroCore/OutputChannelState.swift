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
    /// Stored calibration for each analog reference. The existing live callers
    /// still own `trim`; `switchingTrimReference` binds it to these values.
    public var trimPlus4: Double = 0
    public var trimMinus10: Double = 0

    public init(
        analogRefLevel: UInt32 = 1,
        digitalRefLevel: UInt32 = 2,
        trim: Double = 0.0
    ) {
        self.analogRefLevel = analogRefLevel
        self.digitalRefLevel = digitalRefLevel
        self.trim = trim
        self.trimPlus4 = analogRefLevel == AnalogInputLevel.plus4dBu.rawValue ? trim : 0
        self.trimMinus10 = analogRefLevel == AnalogInputLevel.minus10dBV.rawValue ? trim : 0
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        analogRefLevel = try c.decodeIfPresent(UInt32.self, forKey: .analogRefLevel) ?? 1
        digitalRefLevel = try c.decodeIfPresent(UInt32.self, forKey: .digitalRefLevel) ?? 2
        trim = try c.decodeIfPresent(Double.self, forKey: .trim) ?? 0
        trimPlus4 = try c.decodeIfPresent(Double.self, forKey: .trimPlus4)
            ?? (analogRefLevel == AnalogInputLevel.plus4dBu.rawValue ? trim : 0)
        trimMinus10 = try c.decodeIfPresent(Double.self, forKey: .trimMinus10)
            ?? (analogRefLevel == AnalogInputLevel.minus10dBV.rawValue ? trim : 0)
    }
}
