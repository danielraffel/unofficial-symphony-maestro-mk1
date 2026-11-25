import Foundation
import Testing
import MaestroCore
@testable import MaestroDevice

@Suite("Output routing across Symphony ports")
struct CrossPortOutputRoutingTests {
    // Follow unit A's grid -> saved row -> source -> card route conversion.
    private func unitAPair(gridRow: Int, unitBActive: Bool, clear: Bool = false) -> [ThunderboltCardRouting.Route]? {
        guard let row = TwoUnitOutputRouting.unitARow(gridRow: gridRow, unitAPairs: 16) else { return nil }
        let source: UInt8
        if clear {
            source = SymphonyIORoutingAddress.none
        } else if let pair = TwoUnitOutputRouting.playbackPair(unitARow: row, unitAPairs: 16,
                                                              unitBActive: unitBActive) {
            source = UInt8(pair * 2)
        } else if row == 16 {
            source = SymphonyIORoutingAddress.mixer0Base
        } else if row == 17 {
            source = SymphonyIORoutingAddress.mixer1Base
        } else { return nil }
        let right = clear ? source : source + 1
        guard let leftRoute = ThunderboltCardRouting.route(destination: 32, source: source, unitBActive: unitBActive),
              let rightRoute = ThunderboltCardRouting.route(destination: 33, source: right, unitBActive: unitBActive)
        else { return nil }
        return [leftRoute, rightRoute]
    }

    @Test("DAW 33/34 feeds unit A outputs 1/2, and removal disables both destinations")
    func crossPortAndRemoval() {
        #expect(unitAPair(gridRow: 16, unitBActive: true)?.map(\.payload)
                == [Data([0, 96, 1]), Data([1, 97, 1])])
        #expect(unitAPair(gridRow: 16, unitBActive: true, clear: true)?.map(\.payload)
                == [Data([0, 64, 0]), Data([1, 65, 0])])
    }

    @Test("All 64 DAW channels and both card mixers reach every output on either port")
    func everySourceAndDestination() throws {
        for row in 0..<34 {
            let pair = try #require(unitAPair(gridRow: row, unitBActive: true))
            let slot = UInt8(row < 32 ? 64 + row * 2 : 128 + (row - 32) * 2)
            #expect(pair.map(\.slot) == [slot, slot + 1])
            for destination in UInt8(32)...63 {
                let a = ThunderboltCardRouting.route(destination: destination,
                    source: row < 32 ? UInt8(row * 2) : (row == 32 ? 64 : 96), unitBActive: true)
                let b = ThunderboltCardRouting.unitBRoute(destination: destination, slot: slot)
                #expect(a?.channel == destination - 32)
                #expect(b?.channel == destination)
                #expect(a?.slot == slot)
                #expect(b?.slot == slot)
            }
        }
    }

    @Test("At 32 channels DAW 33-64 are unavailable; returning to 64 restores their meaning")
    func channelModeChanges() {
        for row in 16..<32 {
            #expect(unitAPair(gridRow: row, unitBActive: false) == nil)
            #expect(unitAPair(gridRow: row, unitBActive: true) != nil)
        }
        for source in UInt8(32)...63 {
            #expect(ThunderboltCardRouting.slot(forSource: source) == nil)
        }
        for row in Array(0..<16) + [32, 33] {
            #expect(unitAPair(gridRow: row, unitBActive: false) == unitAPair(gridRow: row, unitBActive: true))
        }
    }

    @Test("Presets preserve old mixer rows and round-trip extra DAW pairs only at 64 channels")
    func presetRows() {
        let old: [Int: Set<Int>] = [0: [0], 16: [1], 17: [2]]
        #expect(RoutingPresetRows.encode(old, dawPairCount: 16)
                == RoutingPresetRows.encode(old, dawPairCount: 16, unitBActive: true))
        let extended = old.merging([18: [3], 33: [4]]) { _, new in new }
        let saved = RoutingPresetRows.encode(extended, dawPairCount: 16, unitBActive: true)
        #expect(saved[16] == [3]) // DAW 33/34, not Mixer 1.
        #expect(saved[31] == [4]) // DAW 63/64.
        #expect(RoutingPresetRows.decode(saved, dawPairCount: 16, unitBActive: true) == extended)
        #expect(RoutingPresetRows.decode(saved, dawPairCount: 16) == old)
        #expect(RoutingPresetRows.decode(old, dawPairCount: 16, unitBActive: true) == old)
    }
}
