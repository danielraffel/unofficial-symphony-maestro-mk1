import Testing
import Foundation
@testable import MaestroDevice
@testable import MaestroCore

/// The Input Routing grid draws ``SymphonyIODefaultRouting/inputRoutes(board0:board1:usbChannelCount:)``
/// through ``CardLayout/inputRoutingColumns`` whenever the hardware read comes
/// back empty — which on both transports is always, because neither has a read
/// opcode for `.routing`. So this derivation *is* the grid the user sees, and a
/// mismatch between the two halves is a visible bug, not an internal detail.
///
/// This mirrors `InputRoutingView.defaultRouteGrid()` exactly. Keep them in step.
private func derivedInputGrid(slot1: IOCardType, slot2: IOCardType) -> [Int: Int] {
    let layout = CardLayout(slot1: slot1, slot2: slot2, isKnown: true)
    let columns = layout.inputRoutingColumns

    func column(forRoutingByte byte: UInt8) -> Int? {
        let left = byte - (byte % 2)
        return columns.firstIndex { $0.routingByte == left }
    }

    let routeList = SymphonyIODefaultRouting.inputRoutes(
        board0: .init(analog: slot1.analogInputChannels, digital: slot1.digitalInputChannels),
        board1: .init(analog: slot2.analogInputChannels, digital: slot2.digitalInputChannels),
        usbChannelCount: SymphonyIODefaultRouting.usbChannelCount)

    var grid: [Int: Int] = [:]
    for route in routeList {
        guard route.source != SymphonyIORoutingAddress.none,
              route.destination % 2 == 0,
              let col = column(forRoutingByte: route.source)
        else { continue }
        grid[Int(route.destination - SymphonyIORoutingAddress.p2pBase) / 2] = col
    }
    return grid
}

@Suite("Input routing default grid")
struct InputRoutingDefaultGridTests {

    /// The dev unit: ADAT (optical) in slot 1, AD16 in slot 2.
    @Test("ADAT + AD16 derives a diagonal, not a stack")
    func adatPlusAD16() {
        let grid = derivedInputGrid(slot1: .optical, slot2: .analogAD16)
        #expect(grid == [0: 0, 1: 1, 2: 2, 3: 3, 4: 4, 5: 5, 6: 6, 7: 7])
    }

    /// Every card pair must land each software pair on a distinct column —
    /// two software pairs sharing one hardware pair is the stacking bug.
    @Test("No card pair stacks two software rows on one column")
    func noStacking() {
        for slot1 in IOCardType.allCases {
            for slot2 in IOCardType.allCases {
                let grid = derivedInputGrid(slot1: slot1, slot2: slot2)
                #expect(Set(grid.values).count == grid.count,
                        "\(slot1)+\(slot2) stacks rows: \(grid.sorted { $0.key < $1.key })")
            }
        }
    }

    /// Every derived column index must exist in the grid the view renders.
    @Test("Derived columns are all in range")
    func columnsInRange() {
        for slot1 in IOCardType.allCases {
            for slot2 in IOCardType.allCases {
                let count = CardLayout(slot1: slot1, slot2: slot2, isKnown: true)
                    .inputRoutingColumns.count
                for (row, col) in derivedInputGrid(slot1: slot1, slot2: slot2) {
                    #expect(col < count,
                            "\(slot1)+\(slot2) row \(row) → column \(col) of \(count)")
                }
            }
        }
    }
}

/// ThunderBridge: the grid's default is the table the driver programs at
/// Start (board order: host input n from slot 1 channel n, 16 + n from slot 2),
/// not the USB analog-first table. `SymphonyThunderbridge.cpp` step 19b-2 and
/// `SymphonyChannelNames.h` `SymphonyDefaultInputSource`; the original's PCIe
/// reset ordered plugs the same way (`SymphonyPCIeRoutingController.cpp:849-866`).
@Suite("ThunderBridge input routing")
struct ThunderboltInputRoutingTests {

    @Test("The driver's capture table is board order")
    func boardOrderTable() {
        let routes = SymphonyIODefaultRouting.thunderboltInputRoutes()
        #expect(routes.count == 32)
        #expect(routes[0] == (destination: 192, source: 32))
        #expect(routes[8] == (destination: 200, source: 40))
        #expect(routes[16] == (destination: 208, source: 48))
        #expect(routes[31] == (destination: 223, source: 63))
    }

    /// The reported unit: 8x8 on optical (S/PDIF) + A16 IP at 48 kHz. The grid,
    /// its row labels and the driver's Core Audio names must say the same thing.
    @Test("Reported unit: rows name what the driver routes to them")
    func reportedUnitLabels() {
        let layout = CardLayout(slot1: .optical, slot2: .analogAD16,
                                naming: .init(sampleRate: 48000, opticalIsSPDIF: [true, nil]))
        let cols = layout.inputRoutingColumns
        let grid = SymphonyIODefaultRouting.inputGrid(
            SymphonyIODefaultRouting.thunderboltInputRoutes(), columns: cols)
        let rows = CardLayout.softwareInputRowNames(rowCount: 16, routes: grid, columns: cols, prefix: "A")
        #expect(Array(rows[0..<4]) == ["A Line 1/2", "A Line 3/4", "A Line 5/6", "A Line 7/8"])
        // Mac 9-10 carry slot 1's optical, as the driver names them
        // ("A SPDIF Opt 1", "A SPDIF Opt 2"); 11-16 carry nothing at S/PDIF.
        #expect(rows[4] == "A SPDIF Opt 1/2")
        #expect(Array(rows[5..<8]) == ["N.A.", "N.A.", "N.A."])
        // Mac 17-32 carry the A16 IP's Line 9-24.
        #expect(rows[8] == "A Line 9/10")
        #expect(rows[15] == "A Line 23/24")
        #expect(grid.count == 16)
    }

    @Test("A slot with no card leaves its host inputs N.A.")
    func emptySlotIsNotApplicable() {
        let layout = CardLayout(slot1: .analogADDA16, slot2: .none)
        let cols = layout.inputRoutingColumns
        let grid = SymphonyIODefaultRouting.inputGrid(
            SymphonyIODefaultRouting.thunderboltInputRoutes(), columns: cols)
        let rows = CardLayout.softwareInputRowNames(rowCount: 16, routes: grid, columns: cols, prefix: "A")
        #expect(rows[7] == "A Line 15/16")
        #expect(rows[8] == "N.A.")
        #expect(grid[8] == nil)
    }

    @Test("Saved input choices replay as left/right 0x31 writes")
    func replayWrites() {
        let layout = CardLayout(slot1: .optical, slot2: .analogAD16)
        let cols = layout.inputRoutingColumns
        let spdif = cols.firstIndex { $0.routingByte == 40 }!
        let writes = InputRoutingReplay.writes(saved: [12: spdif, 0: 0, 40: 0, 3: 99], columns: cols, pairCount: 16)
        #expect(writes.count == 4)
        #expect(writes[0] == (destination: 192, source: 32))
        #expect(writes[1] == (destination: 193, source: 33))
        #expect(writes[2] == (destination: 216, source: 40))   // Mac 25-26 ← SPDIF Opt 1/2
        #expect(writes[3] == (destination: 217, source: 41))
        #expect(InputRoutingReplay.writes(saved: [:], columns: cols, pairCount: 16).isEmpty)
    }

    @Test("Reset plan on ThunderBridge describes the board-order table")
    func resetPlanBoardOrder() {
        let plan = RoutingResetGuard.inputPlanLines(
            board1: .optical, board2: .analogAD16, usbChannelCount: 32,
            routes: SymphonyIODefaultRouting.thunderboltInputRoutes())
        let text = plan.joined(separator: "\n")
        #expect(text.contains("17-32"), "\(text)")
    }
}
