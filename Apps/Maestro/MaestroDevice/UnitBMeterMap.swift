import Foundation
import MaestroCore

/// Which card meter word each of unit B's strips reads, while 64 channels run
/// with a second Symphony I/O on ThunderBridge port 2.
///
/// The card's meter buffer holds 64 input words and 64 playback words: unit A's
/// host inputs are words 0-31 and unit B's 32-63 (XLink RX 32-63); host
/// playback 1-64 are words 64-127, so unit B's outputs (playback 33-64) are
/// 96-127. Unit B's capture table is the one the driver programs for it from
/// its own slot-1 card (`ConfigureUnitB`), the same board-order table unit A
/// starts with, so its strips map exactly as unit A's do, 32 words up.
public enum UnitBMeterMap {
    /// Meter word of unit B's host input 1.
    public static let inputWordBase = 32
    /// Meter word of unit B's first playback channel (host playback 33).
    public static let playbackWordBase = 96
    /// Input words read while unit B is metered (0-63).
    public static let inputWordCount = 64

    /// Unit B's strip words (offset into the 64 input words), in the order of
    /// `layout.mixerChannels`, and its digital strips. Empty for an unknown layout.
    /// `order`: unit B's channel order, for its default capture table when
    /// `routes` is not given (nil: card by card from the layout's slot 1).
    public static func inputWords(layout: CardLayout, routes: [ThunderboltInputMeterMap.Route]? = nil,
                                  order: ThunderboltUnitChannelOrder? = nil) -> ThunderboltInputMeterMap.Words {
        let slot1: IOCardType? = layout.isKnown ? layout.slot1 : nil
        let capture = routes ?? (order.map {
            ThunderboltInputMeterMap.currentRoutes(slot1: $0.slot1, slot2: $0.slot2, order: $0.order, replayed: [])
        } ?? ThunderboltInputMeterMap.currentRoutes(slot1: slot1, replayed: []))
        let words = ThunderboltInputMeterMap.words(layout: layout, routes: capture)
        return ThunderboltInputMeterMap.Words(
            channels: words.channels.map { $0.map { $0 + inputWordBase } },
            digital: words.digital.map { $0.map { $0 + inputWordBase } })
    }

    /// The meter word of unit B's output channel `channel` (0-based, as
    /// playback 33 + channel reaches it by default). For an analog output
    /// strip that is exact under an analog-first driver (150+), whose table
    /// plays XLink n on the n-th analog output; card by card it was exact for
    /// slot 1's strips only.
    public static func playbackWord(channel: Int) -> Int { playbackWordBase + channel }

    /// Unit B's output levels from the buffer's playback words.
    public static func outputLevels(dB: (Int) -> Double, count: Int) -> [Double] {
        (0..<count).map { dB(playbackWord(channel: $0)) }
    }
}
