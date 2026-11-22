import Foundation
import MaestroCore

/// Which ThunderBridge meter word each output strip reads.
///
/// The card's meter snapshot is indexed by TDM slot: word 64 + n is host
/// playback channel n (`PCI_OUT n`) and words 128-131 are the two card mixers'
/// outputs. It has no word for a hardware output as such. An output plays the
/// slot its card route selects (`ThunderboltCardRouting`), so its meter is the
/// word of that slot: the software output, or the mixer, routed to it in
/// Output Routing, and silence when the output is disabled.
///
/// Until 0.9.21 the app read word 64 + i for analog output strip i, which is
/// right only while output i plays software output i and slot 1 has no digital
/// outputs before slot 2's analog ones, and it never set the digital output
/// meters (AES, ADAT/SMUX, S/PDIF) at all on ThunderBridge and PCIe.
public enum ThunderboltOutputMeterMap {
    /// The layout of `AppState.digitalOutputMeterLevels`: board b's digital
    /// output k at `b * 8 + k`, k < 8, as `CardLayout.DigitalPair.meterIndex`
    /// reads it.
    public static let digitalSlots = 24

    public struct Words: Sendable, Equatable {
        /// One entry per analog output strip: slot 1's analog outputs, then
        /// slot 2's, the order of `AppState.outputMeterLevels`.
        public let analog: [Int?]
        public let digital: [Int?]

        public init(analog: [Int?], digital: [Int?]) {
            self.analog = analog
            self.digital = digital
        }
    }

    /// The meter word of the slot that card channel `channel` (board 0:
    /// 0-15, board 1: 16-31) plays, from the app's output table (destination
    /// byte to source byte). Nil when the output is disabled or has no route.
    public static func word(channel: Int, table: [UInt8: UInt8], unitBActive: Bool) -> Int? {
        let perBoard = SymphonyIORoutingAddress.channelsPerIOBoard
        guard channel >= 0, channel < perBoard * 2 else { return nil }
        let base = channel < perBoard ? SymphonyIORoutingAddress.ioBoard0Base : SymphonyIORoutingAddress.ioBoard1Base
        let destination = base + UInt8(channel % perBoard)
        guard let source = table[destination],
              let route = ThunderboltCardRouting.route(destination: destination, source: source,
                                                       unitBActive: unitBActive),
              route.enabled else { return nil }
        return Int(route.slot)
    }

    /// Meter words for one card layout. On a board the analog outputs come
    /// first, then the digital ones (`SymphonyIO.cpp:7041-7100`). Nil for an
    /// unknown layout or an empty table: the caller keeps strip i on software
    /// output i.
    public static func words(layout: CardLayout, table: [UInt8: UInt8], unitBActive: Bool) -> Words? {
        guard layout.isKnown, !table.isEmpty else { return nil }
        let perBoard = SymphonyIORoutingAddress.channelsPerIOBoard
        var analog: [Int?] = []
        var digital = [Int?](repeating: nil, count: digitalSlots)
        let meteredPerBoard = CardLayout.meteredDigitalPairsPerBoard * 2
        for (board, card) in layout.slots.enumerated() {
            for channel in 0..<card.analogOutputChannels {
                analog.append(word(channel: board * perBoard + channel, table: table, unitBActive: unitBActive))
            }
            for k in 0..<min(meteredPerBoard, card.digitalOutputChannels) {
                digital[board * meteredPerBoard + k] = word(
                    channel: board * perBoard + card.analogOutputChannels + k,
                    table: table, unitBActive: unitBActive)
            }
        }
        return Words(analog: analog, digital: digital)
    }

    /// Strip levels from a level per meter word; a strip with no word is silent.
    public static func levels(_ words: [Int?], count: Int? = nil, level: (Int) -> Double) -> [Double] {
        (0..<(count ?? words.count)).map { i in
            guard i < words.count, let word = words[i] else { return -60.0 }
            return level(word)
        }
    }
}
