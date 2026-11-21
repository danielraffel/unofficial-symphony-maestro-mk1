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

/// ThunderBridge: the grid's default is the table the driver programs at link
/// configuration (card by card: host input n from slot 1 channel n, then slot
/// 2 from where slot 1's inputs end), not the USB analog-first table.
/// `SymphonyThunderbridge.cpp` step 19b-2 and `SymphonyChannelNames.h`
/// `SymphonyCaptureSource`; the original's PCIe reset ordered plugs the same
/// way (`SymphonyPCIeRoutingController.cpp:849-866`).
@Suite("ThunderBridge input routing")
struct ThunderboltInputRoutingTests {

    @Test("Unread slot 1: the capture table is the fixed 16 + 16")
    func boardOrderTable() {
        let routes = SymphonyIODefaultRouting.thunderboltInputRoutes(slot1: nil)
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
        #expect(text.contains("Software 17–32: Card 2 analog in 1–16"), "\(text)")
    }

    // MARK: - Channel packing per slot

    /// Where slot 2 starts for every slot-1 case. Only the 2x6 (12 inputs)
    /// moves it; an empty or Mic Pre slot 1, or an unread one, keeps 16.
    @Test("Slot 2's first host input for every slot-1 card",
          arguments: [
            (IOCardType?.none, 16), (.some(.none), 16), (.some(.micPre8), 16),
            (.some(.analogAES), 16), (.some(.optical), 16), (.some(.analogAD16), 16),
            (.some(.analogDA16), 16), (.some(.analogADDA16), 16), (.some(.twoBySix), 12),
          ] as [(IOCardType?, Int)])
    func slot2Base(slot1: IOCardType?, base: Int) {
        #expect(SymphonyIODefaultRouting.thunderboltSlot2InputBase(slot1: slot1) == base)
        let routes = SymphonyIODefaultRouting.thunderboltInputRoutes(slot1: slot1)
        #expect(routes.count == 32)
        #expect(routes[base].source == SymphonyIORoutingAddress.ioBoard1Base)
        #expect(routes[base - 1].source == SymphonyIORoutingAddress.ioBoard0Base + UInt8(base - 1))
        #expect(routes.map(\.destination) == (0..<32).map { SymphonyIORoutingAddress.p2pBase + UInt8($0) })
    }

    /// 2x6 + A16 IP: slot 2's Line 3-18 on Mac 13-28, Mac 29-32 silent. Rows,
    /// grid and reset plan say the same.
    @Test("2x6 in slot 1 packs slot 2 behind its 12 inputs")
    func twoBySixPacks() {
        let routes = SymphonyIODefaultRouting.thunderboltInputRoutes(slot1: .twoBySix)
        #expect(routes[11] == (destination: 203, source: 43))
        #expect(routes[12] == (destination: 204, source: 48))
        #expect(routes[27] == (destination: 219, source: 63))
        #expect(routes[28...].allSatisfy { $0.source == SymphonyIORoutingAddress.none })

        let layout = CardLayout(slot1: .twoBySix, slot2: .analogAD16)
        let cols = layout.inputRoutingColumns
        let grid = SymphonyIODefaultRouting.inputGrid(routes, columns: cols)
        let rows = CardLayout.softwareInputRowNames(rowCount: 16, routes: grid, columns: cols, prefix: "A")
        #expect(rows[0] == "A Line 1/2")
        #expect(rows[6] == "A Line 3/4")      // Mac 13-14
        #expect(rows[13] == "A Line 17/18")   // Mac 27-28
        #expect(rows[14] == "N.A.")           // Mac 29-30
        #expect(grid[14] == nil && grid[15] == nil)

        let plan = RoutingResetGuard.inputPlanLines(
            board1: .twoBySix, board2: .analogAD16, usbChannelCount: 32, routes: routes)
        let text = plan.joined(separator: "\n")
        #expect(text.contains("Software 13–28: Card 2 analog in 1–16"), "\(text)")
        #expect(text.contains("Software 29–32: no hardware input, silent."), "\(text)")
    }

    /// The common setups do not move: slot 2 stays on Mac 17-32.
    @Test("Every other slot-1 card keeps slot 2 on Mac 17-32",
          arguments: [IOCardType.analogAES, .optical, .analogAD16, .analogDA16, .analogADDA16, .micPre8, .none])
    func othersDoNotMove(slot1: IOCardType) {
        #expect(SymphonyIODefaultRouting.thunderboltInputRoutes(slot1: slot1).map(\.source)
                == SymphonyIODefaultRouting.thunderboltInputRoutes(slot1: nil).map(\.source))
    }

    /// The app draws the packed table only when the driver on the card packs.
    @Test("Packing follows the serving driver and the card read")
    func captureSlot1Gate() {
        let f = SymphonyIODefaultRouting.thunderboltCaptureSlot1
        #expect(f(.twoBySix, .detected, .build(123)) == .twoBySix)
        #expect(f(.twoBySix, .detected, .build(124)) == .twoBySix)
        #expect(f(.twoBySix, .detected, .build(0)) == .twoBySix)          // local build of this code
        #expect(f(.twoBySix, .detected, .build(122)) == nil)
        #expect(f(.twoBySix, .detected, .olderThanBuildReporting) == nil) // old copy still serving
        #expect(f(.twoBySix, .detected, nil) == nil)                      // not asked
        #expect(f(.twoBySix, .cached, .build(123)) == nil)                // not read this session
        #expect(f(.twoBySix, .unknown, .build(123)) == nil)
        #expect(f(.twoBySix, .simulated, nil) == .twoBySix)
        // An old driver serving a 2x6 unit: the grid keeps 16 + 16, as that driver programs.
        #expect(SymphonyIODefaultRouting.thunderboltSlot2InputBase(
            slot1: f(.twoBySix, .detected, .olderThanBuildReporting)) == 16)
    }
}
