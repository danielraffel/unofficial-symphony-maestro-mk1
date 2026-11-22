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

    /// Whether a reply still belongs to the unit, layout, and connection that
    /// initiated its read.
    public static func replyBelongs(unit: DeviceUnit, layout: CardLayout,
                                    connection: ObjectIdentifier,
                                    activeUnit: DeviceUnit, activeLayout: CardLayout?,
                                    activeConnection: ObjectIdentifier?) -> Bool {
        unit == activeUnit && layout == activeLayout && connection == activeConnection
    }
    public static let payloadLength = 64
    public static let wordsPerBoard = IOCardType.busChannelsPerBoard
    public static let digitalSlots = CardLayout.digitalMeterSlots

    public struct Levels: Sendable, Equatable {
        /// Slot 1's analog outputs, then slot 2's.
        public let analogReadings: [MeterReading]
        public let digitalReadings: [MeterReading]

        public var analog: [Double] { analogReadings.map(\.level) }
        public var digital: [Double] { digitalReadings.map(\.level) }
    }

    public static func level(word: UInt16) -> Double {
        MeterReading.unit(word: word).level
    }

    /// Nil for a reply that is short or all zero (the unit sends its buffer
    /// even when it has not filled it), and for an unknown card layout.
    public static func levels(payload: Data, layout: CardLayout) -> Levels? {
        guard layout.isKnown, payload.count >= payloadLength,
              payload.prefix(payloadLength).contains(where: { $0 != 0 }) else { return nil }
        let analog = layout.slots.enumerated().flatMap { board, card in
            (0..<min(card.analogOutputChannels, wordsPerBoard)).map { channel in
                TDMMeterPayload.reading(payload, word: board * wordsPerBoard + channel)
            }
        }
        return Levels(analogReadings: analog,
                      digitalReadings: TDMMeterPayload.digitalReadings(payload, layout: layout, isInput: false))
    }
}
