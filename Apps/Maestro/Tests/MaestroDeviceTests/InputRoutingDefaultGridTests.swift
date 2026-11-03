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
