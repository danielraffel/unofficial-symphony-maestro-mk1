import Foundation

/// A level and its hardware clip flag, decoded from the same word.
public struct MeterReading: Equatable, Sendable {
    public let level: Double
    public let isOver: Bool

    public static let silence = MeterReading(level: -60, isOver: false)

    public static func unit(word: UInt16) -> Self {
        let peak = word & 0x3FFF
        let level = peak <= 0x40 ? -60.0 : max(-60, 20 * log10(Double(peak) / 16383))
        return Self(level: level, isOver: word & 0x8000 != 0)
    }

    /// Over on the card: the peak at full scale. Measured on hardware
    /// (2026-11-23, full-scale square wave to playback 1-2): the peak byte
    /// reads 254 (0xFE), never 255, so full scale is 254 and up. Bit 1 came on
    /// with the tone but stayed set afterwards at any level (a latch, not a
    /// live flag), so it is not used.
    public static let cardFullScalePeak: UInt32 = 0xFE

    public static func card(word: UInt32) -> Self {
        let peakByte = word >> 24
        let peak = Double(peakByte)
        let level = peak == 0 ? -60.0 : max(-60, 20 * log10(peak / 256))
        return Self(level: level, isOver: peakByte >= cardFullScalePeak)
    }
}

/// The hardware clip sources available to the display at the current transport
/// and serving build. USB output and mixer taps may fall back to software.
public enum MeterOverSources {
    /// Hardware check H-M4 (2026-11-23): the card words' bit 1 latches, so it
    /// is not used as a clip flag; Over comes from the full-scale peak.
    public static let cardOverBitConfirmed = false

    public static func available(card: Bool, build: ServingDextBuild? = nil,
                                 unitOutputsFresh: Bool = false,
                                 usbOutputs: Bool = true, usbMixer: Bool = true)
        -> (input: Bool, output: Bool, mixer: Bool) {
        if card {
            // The card's own meter words light Over at full scale (see
            // MeterReading.card); their clip bit joins once H-M4 confirms it.
            return (true, UnitOutputMeters.driverSupports(build) && unitOutputsFresh, true)
        }
        return (true, usbOutputs, usbMixer)
    }
}

extension MeterDisplaySettings {
    /// Display semantics for the legacy Over Hold value 3 are two seconds.
    public init(peakWireValue: UInt32, overWireValue: UInt32) {
        self.init(
            peakHoldMode: PeakHoldMode.allCases.first { $0.wireValue == peakWireValue } ?? .off,
            oversHoldMode: OverHoldMode.allCases.first {
                $0.wireValue == (overWireValue == 3 ? 1 : overWireValue)
            } ?? .off
        )
    }
}

/// Per-channel display state driven by monotonic seconds.
public struct MeterHold: Equatable, Sendable {
    public private(set) var peak = -60.0
    public private(set) var isOver = false
    private var peakTime: Double?
    private var overTime: Double?
    private var updatedAt: Double?

    public init() {}

    public mutating func update(level: Double, over: Bool, at now: Double,
                                settings: MeterDisplaySettings) {
        switch settings.peakHoldMode {
        case .off:
            peak = -60
            peakTime = nil
        case .twoSeconds, .infinite:
            if level >= peak || peakTime == nil {
                peak = level
                peakTime = now
            } else if settings.peakHoldMode == .twoSeconds, let peakTime {
                let decayStart = max(peakTime + 2, updatedAt ?? now)
                peak = max(level, peak - 40 * max(0, now - decayStart))
                if peak == level { self.peakTime = now }
            }
        }
        updatedAt = now

        if over { overTime = now }
        isOver = overTime.map { last in
            switch settings.oversHoldMode {
            case .off: return now < last + 0.1
            case .infinite: return true
            default: return now < last + 2
            }
        } ?? false
        if !isOver { overTime = nil }
    }
}
