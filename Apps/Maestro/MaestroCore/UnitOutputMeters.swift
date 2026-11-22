import Foundation

/// The Symphony I/O's own output meters, as Apogee's software read them on
/// every connection: vendor read `0x30`, group 1 (Output), 64 bytes.
///
/// The unit meters each board output at the output, after routing: whatever
/// is playing there (`SymphonyIOAudioRouteManager.cpp:704-717, 884-890`).
/// The reply is 32 little-endian words, 16 for each board; on a board the
/// analog outputs come first and the digital ones straight after
/// (`SymphonyIO.cpp:6921-6946`, `SymphonyIO_IOBoard.cpp:279-289`). A word's
/// level is its low 14 bits, 0x3FFF = full scale, and at or below 0x40 it
/// reads as silence (`SymphonyIO_Stream.cpp:559-571`).
public enum UnitOutputMeters {
    /// Build 144 accepts the 72-byte vendor reply. Build 143 rejects it while
    /// holding the driver's control queue, so older or unknown builds are gated.
    public static let requiredDriverBuild: UInt32 = 144

    public static func driverSupports(_ servingBuild: ServingDextBuild?) -> Bool {
        guard case .build(let build) = servingBuild else { return false }
        return build >= requiredDriverBuild
    }
    public static let payloadLength = 64
    public static let wordsPerBoard = 16
    /// Board b's digital output k at `b * 8 + k`, as
    /// ``CardLayout/DigitalPair/meterIndex`` reads it.
    public static let digitalSlots = 24

    public struct Levels: Sendable, Equatable {
        /// Slot 1's analog outputs, then slot 2's (dBFS, -60 = silence).
        public let analog: [Double]
        public let digital: [Double]
    }

    public static func level(word: UInt16) -> Double {
        let value = word & 0x3FFF
        guard value > 0x40 else { return -60.0 }
        return max(-60.0, 20.0 * log10(Double(value) / 16383.0))
    }

    /// Nil for a reply that is short or all zero (the unit sends its buffer
    /// even when it has not filled it), and for an unknown card layout.
    public static func levels(payload: Data, layout: CardLayout) -> Levels? {
        guard layout.isKnown, payload.count >= payloadLength,
              payload.prefix(payloadLength).contains(where: { $0 != 0 }) else { return nil }
        let bytes = [UInt8](payload.prefix(payloadLength))
        func level(_ word: Int) -> Double {
            guard word >= 0, word * 2 + 1 < bytes.count else { return -60.0 }
            return Self.level(word: UInt16(bytes[word * 2]) | UInt16(bytes[word * 2 + 1]) << 8)
        }
        var analog: [Double] = []
        var digital = [Double](repeating: -60.0, count: digitalSlots)
        let meteredPerBoard = CardLayout.meteredDigitalPairsPerBoard * 2
        for (board, card) in layout.slots.enumerated() {
            let base = board * wordsPerBoard
            for channel in 0..<min(card.analogOutputChannels, wordsPerBoard) {
                analog.append(level(base + channel))
            }
            let room = wordsPerBoard - card.analogOutputChannels
            for k in 0..<min(meteredPerBoard, card.digitalOutputChannels, max(0, room)) {
                digital[board * meteredPerBoard + k] = level(base + card.analogOutputChannels + k)
            }
        }
        return Levels(analog: analog, digital: digital)
    }
}
