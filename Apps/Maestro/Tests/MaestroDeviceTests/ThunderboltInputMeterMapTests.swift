import Testing
@testable import MaestroDevice
@testable import MaestroCore

/// ThunderBridge input meters: each strip reads the meter word of the host
/// input its hardware channel is routed to (``ThunderboltInputMeterMap``),
/// not the word at its device-wide position.
@Suite("ThunderBridge input meter map")
struct ThunderboltInputMeterMapTests {
    typealias Map = ThunderboltInputMeterMap

    private func words(_ slot1: IOCardType, _ slot2: IOCardType, slot1Read: Bool = true,
                       saved: [Int: Int] = [:]) -> Map.Words {
        let layout = CardLayout(slot1: slot1, slot2: slot2, isKnown: true)
        let replayed = InputRoutingReplay.writes(saved: saved, columns: layout.inputRoutingColumns, pairCount: 16)
        let routes = Map.currentRoutes(slot1: slot1Read ? slot1 : nil, replayed: replayed)
        return Map.words(layout: layout, routes: routes)
    }

    @Test("8x8 AES/OPT in slot 1, A16 in slot 2 (Daniel's rig): every strip reads its own channel")
    func aesPlusAD16() {
        let w = words(.analogAES, .analogAD16)
        // Mixer order: slot 1 Line 1-8, slot 2 Line 1-16, then slot 1's 8 digital.
        #expect(w.channels.count == 32)
        #expect(Array(w.channels[0..<8]) == (0..<8).map { Optional($0) })
        // A16 Line 1-16 are host inputs 17-32, not 9-24.
        #expect(Array(w.channels[8..<24]) == (16..<32).map { Optional($0) })
        // Slot 1's digital channels are host inputs 9-16, not A16 Line 9-16.
        #expect(Array(w.channels[24..<32]) == (8..<16).map { Optional($0) })
        // Input-tab digital strips: board 0's eight, board 1 has none.
        #expect(Array(w.digital[0..<8]) == (8..<16).map { Optional($0) })
        #expect(w.digital[8..<24].allSatisfy { $0 == nil })
    }

    @Test("Before the fix A16 Line 1 read host input 9: the levels now come from 17")
    func stripLevelsFollowTheMap() {
        let w = words(.analogAES, .analogAD16)
        var host = [Double](repeating: -60, count: 32)
        host[16] = -6    // A16 Line 1 on host input 17
        host[8] = -20    // slot 1 digital 1 on host input 9
        let strips = Map.stripLevels(host: host, words: w, count: 32)
        #expect(strips[8] == -6)      // A16 Line 1 strip
        #expect(strips[24] == -20)    // first digital mixer strip
        #expect(strips[0] == -60)
        #expect(Map.digitalLevels(host: host, words: w)[0] == -20)
    }

    @Test("A 2x6 in slot 1 packs slot 2 from host input 13")
    func twoBySixInSlot1() {
        let w = words(.twoBySix, .analogAD16)
        // 2 analog, then the AD16's 16, then the 2x6's AES 2 + optical 8.
        #expect(w.channels[0] == 0 && w.channels[1] == 1)
        #expect(Array(w.channels[2..<18]) == (12..<28).map { Optional($0) })
        // The 2x6's digital inputs are board channels 2-11 = host inputs 3-12.
        #expect(Array(w.channels[18..<28]) == (2..<12).map { Optional($0) })
        // Metered digital: the first eight of the 2x6's ten.
        #expect(Array(w.digital[0..<8]) == (2..<10).map { Optional($0) })
    }

    @Test("Slot 1 not read this session: the driver's fixed 16 + 16")
    func unreadSlot1() {
        let w = words(.twoBySix, .analogAD16, slot1Read: false)
        #expect(Array(w.channels[2..<18]) == (16..<32).map { Optional($0) })
    }

    @Test("A saved Input Routing choice moves the meter with the channel")
    func reroutedInput() {
        let layout = CardLayout(slot1: .analogAES, slot2: .analogAD16, isKnown: true)
        // Software pair 1 (host inputs 1-2) from A16 Line 1/2.
        let a16Line1 = layout.inputRoutingColumns.firstIndex {
            $0.routingByte == SymphonyIORoutingAddress.ioBoard1Base
        }!
        let w = words(.analogAES, .analogAD16, saved: [0: a16Line1])
        // A16 Line 1 is now on host inputs 1 and 17: the lowest is read.
        #expect(w.channels[8] == 0)
        #expect(w.channels[9] == 1)
        // Slot 1 Line 1/2 reach no host input any more: no meter word.
        #expect(w.channels[0] == nil && w.channels[1] == nil)
        #expect(Map.stripLevels(host: [Double](repeating: -3, count: 32), words: w, count: 32)[0] == -60)
    }

    @Test("Unknown layout keeps host input i on strip i")
    func unknownLayoutIsIdentity() {
        let w = Map.words(layout: CardLayout(slot1: .none, slot2: .none, isKnown: false),
                          routes: SymphonyIODefaultRouting.thunderboltInputRoutes())
        #expect(w.channels.isEmpty)
        let host = (0..<32).map { Double(-$0) }
        #expect(Map.stripLevels(host: host, words: w, count: 32) == host)
    }

    @Test("Mixer channels carry their board channel")
    func mixerChannelBoardPositions() {
        let channels = CardLayout(slot1: .analogAES, slot2: .analogAD16, isKnown: true).mixerChannels
        #expect(channels[8].boardIndex == 1 && channels[8].channelOnBoard == 0)
        #expect(channels[24].boardIndex == 0 && channels[24].channelOnBoard == 8)
    }
}
