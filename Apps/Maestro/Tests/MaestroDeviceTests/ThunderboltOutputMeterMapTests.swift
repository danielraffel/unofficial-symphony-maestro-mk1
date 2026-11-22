import Foundation
import Testing
@testable import MaestroCore
@testable import MaestroDevice

/// Output meters on ThunderBridge and PCIe read the meter word of what each
/// output plays: software output n is word 64 + n, the card mixers 128-131.
@Suite("ThunderBridge output meter map")
struct ThunderboltOutputMeterMapTests {
    private func table(_ slot1: IOCardType, _ slot2: IOCardType) -> [UInt8: UInt8] {
        let routes = SymphonyIODefaultRouting.thunderboltOutputRoutes(
            board0Outputs: slot1.totalOutputChannels, board1Outputs: slot2.totalOutputChannels)
        return Dictionary(uniqueKeysWithValues: routes.map { ($0.destination, $0.source) })
    }
    private func words(_ slot1: IOCardType, _ slot2: IOCardType,
                       _ table: [UInt8: UInt8]) -> ThunderboltOutputMeterMap.Words? {
        ThunderboltOutputMeterMap.words(
            layout: CardLayout(slot1: slot1, slot2: slot2), table: table, unitBActive: false)
    }

    /// GitHub issue 31: 16x16 Analog in slot 1, 8x8 AES/OPT in slot 2. Music on
    /// software outputs 27/28 (meter words 90/91) played through AES 3/4 and
    /// the AES meters stayed dark.
    @Test("16x16 + 8x8: slot 2's digital outputs read software outputs 25-32")
    func digitalOutputsOfSecondCard() throws {
        let w = try #require(words(.analogADDA16, .optical, table(.analogADDA16, .optical)))
        #expect(w.analog.count == 24)
        #expect(w.analog[0] == 64 && w.analog[15] == 79)
        #expect(w.analog[16] == 80 && w.analog[23] == 87)       // slot 2 Line 1-8
        #expect(Array(w.digital[0..<8]) == [Int?](repeating: nil, count: 8))   // 16x16: no digital
        #expect(w.digital[8] == 88 && w.digital[15] == 95)
        #expect(w.digital[10] == 90 && w.digital[11] == 91)     // digital 3/4 = software 27/28
        let levels = ThunderboltOutputMeterMap.levels(w.digital) { $0 == 90 || $0 == 91 ? -6 : -60 }
        #expect(levels[10] == -6 && levels[11] == -6 && levels[9] == -60 && levels[12] == -60)
    }

    @Test("8x8 + 16x16: slot 2's analog strips do not read slot 1's digital outputs")
    func analogAfterDigital() throws {
        let w = try #require(words(.optical, .analogADDA16, table(.optical, .analogADDA16)))
        #expect(w.analog.count == 24)
        #expect(w.analog[7] == 71)
        #expect(w.analog[8] == 80)                               // not 72, slot 1's first digital
        #expect(w.digital[0] == 72 && w.digital[7] == 79)
    }

    @Test("16 Analog In / 16 Digital Out: all outputs are digital, from the board's first channel")
    func digitalOnlyCard() throws {
        let w = try #require(words(.optical, .analogAD16, table(.optical, .analogAD16)))
        #expect(w.analog.count == 8)
        #expect(w.digital[8] == 80 && w.digital[15] == 87)       // slot 2 digital 1-8
    }

    @Test("an output follows Output Routing: another software pair, a mixer, or disabled")
    func followsRouting() throws {
        var t = table(.optical, .none)
        let board0 = SymphonyIORoutingAddress.ioBoard0Base
        t[board0] = 4; t[board0 + 1] = 5                                         // Line 1/2 plays Software 5/6
        t[board0 + 2] = SymphonyIORoutingAddress.mixer0Base
        t[board0 + 3] = SymphonyIORoutingAddress.mixer0Base + 1                  // Line 3/4 plays Mixer 1
        t[board0 + 8] = SymphonyIORoutingAddress.mixer1Base
        t[board0 + 9] = SymphonyIORoutingAddress.mixer1Base + 1                  // digital 1/2 plays Mixer 2
        t[board0 + 4] = SymphonyIORoutingAddress.none                            // Line 5 disabled
        let w = try #require(words(.optical, .none, t))
        #expect(w.analog[0] == 68 && w.analog[1] == 69)
        #expect(w.analog[2] == 128 && w.analog[3] == 129)
        #expect(w.analog[4] == nil)
        #expect(w.analog[5] == 69)                                               // Line 6 untouched: software 6
        #expect(w.digital[0] == 130 && w.digital[1] == 131)
        #expect(ThunderboltOutputMeterMap.levels(w.analog, count: 8) { _ in -3 }[4] == -60)
    }

    @Test("no map for an unknown layout or an empty table")
    func noMap() {
        #expect(ThunderboltOutputMeterMap.words(
            layout: CardLayout(isKnown: false), table: table(.optical, .none), unitBActive: false) == nil)
        #expect(words(.optical, .none, [:]) == nil)
    }
}
