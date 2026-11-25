import Foundation
import Testing
@testable import MaestroCore
@testable import MaestroDevice

/// Unit B's output meters read what the two-unit replay plays on each of its
/// outputs: one function (`TwoUnitOutputRouting.table`) gives both the same
/// table, so they cannot disagree.
@Suite("Unit B output meters")
struct UnitBOutputMeterTests {
    /// 8x8 in slot 1, 16x16 in slot 2: 24 analog outputs, 8 digital.
    private let layout = CardLayout(slot1: .optical, slot2: .analogADDA16)
    private var columns: [CardLayout.RoutingColumn] { layout.outputRoutingColumns }

    private func words(_ saved: [Int: Set<Int>]) throws -> ThunderboltOutputMeterMap.Words {
        try #require(ThunderboltOutputMeterMap.words(
            layout: layout, table: TwoUnitOutputRouting.table(saved: saved, columns: columns),
            unitBActive: true, unitB: true))
    }
    /// The column index of the pair whose left output is card channel `channel`.
    private func column(channel: Int) throws -> Int {
        try #require(columns.firstIndex { Int($0.routingByte) - TwoUnitOutputRouting.outputDestinationBase == channel })
    }
    private func completeTable(_ rows: [Int: Set<Int>]) -> [Int: Set<Int>] {
        var saved = rows
        for row in 0..<TwoUnitOutputRouting.rowCount where saved[row] == nil { saved[row] = [] }
        return saved
    }

    @Test("the Core routing bytes equal the device layer's")
    func constants() {
        #expect(TwoUnitOutputRouting.outputDestinationBase == Int(SymphonyIORoutingAddress.ioBoard0Base))
        #expect(TwoUnitOutputRouting.mixer0SourceBase == SymphonyIORoutingAddress.mixer0Base)
        #expect(TwoUnitOutputRouting.mixer1SourceBase == SymphonyIORoutingAddress.mixer1Base)
        #expect(TwoUnitOutputRouting.noSource == SymphonyIORoutingAddress.none)
    }

    @Test("nothing saved: every unit B output plays software 33 + its channel, analog and digital")
    func nothingSaved() throws {
        let w = try words([:])
        #expect(w.analog.count == 24)
        #expect(w.analog[0] == 96 && w.analog[7] == 103)       // slot 1 Line 1-8: software 33-40
        #expect(w.analog[8] == 112 && w.analog[23] == 127)     // slot 2 Line 1-16: software 49-64
        #expect(w.digital[0] == 104 && w.digital[7] == 111)    // slot 1 digital 1-8: software 41-48
        #expect(w.digital[8...].allSatisfy { $0 == nil })   // 16x16: no digital
    }

    @Test("one output changed: it follows the change, the rest stay on their default")
    func partialTable() throws {
        // Unit B Line 1/2 plays software 1/2 (a unit A pair): words 64/65.
        let w = try words([0: [try column(channel: 0)]])
        #expect(w.analog[0] == 64 && w.analog[1] == 65)
        #expect(w.analog[2] == 98 && w.analog[3] == 99)        // Line 3/4 still software 35/36
        #expect(w.digital[0] == 104)
        #expect(w.analog[8] == 112)
    }

    @Test("a complete table: an output no row owns is off; mixers read the mixer words")
    func completeSavedTable() throws {
        let line34 = try column(channel: 2), digital12 = try column(channel: 8), slot2Line12 = try column(channel: 16)
        let w = try words(completeTable([
            TwoUnitOutputRouting.mixer1Row: [line34],
            TwoUnitOutputRouting.mixer2Row: [digital12],
            20: [slot2Line12],                                  // software 41/42
        ]))
        #expect(w.analog[0] == nil && w.analog[1] == nil)      // Line 1/2: no owner, off
        #expect(w.analog[2] == 128 && w.analog[3] == 129)      // Mixer 1
        #expect(w.digital[0] == 130 && w.digital[1] == 131)    // Mixer 2
        #expect(w.analog[8] == 104 && w.analog[9] == 105)
        #expect(ThunderboltOutputMeterMap.levels(w.analog, count: 32) { _ in -3 }[0] == -60)
    }

    @Test("a saved row past the valid sources is no route, not a mixer")
    func invalidRow() throws {
        let w = try words([TwoUnitOutputRouting.rowCount + 3: [try column(channel: 0)]])
        #expect(w.analog[0] == nil && w.analog[1] == nil)
        #expect(w.analog[2] == 98)
    }

    @Test("resolved rows: the last owner wins, as in the replay")
    func resolvedRows() throws {
        let line12 = try column(channel: 0)
        let rows = TwoUnitOutputRouting.resolvedRows(saved: [3: [line12], 7: [line12]], columns: columns)
        #expect(rows[line12] == 7)
        #expect(rows[try column(channel: 2)] == TwoUnitOutputRouting.defaultRow(unitBChannel: 2))
    }
}

@Suite("Unit meter reading: which unit a reply belongs to, and the driver gate")
struct UnitMeterReplyTests {
    private final class Connection {}
    private let layoutA = CardLayout(slot1: .optical, slot2: .none)
    private let layoutB = CardLayout(slot1: .analogADDA16, slot2: .none)

    @Test("a reply is kept only for the unit, layout and connection it was read from")
    func replyBelongs() {
        let a = Connection(), b = Connection()
        let idA = ObjectIdentifier(a), idB = ObjectIdentifier(b)
        func belongs(_ unit: DeviceUnit, _ layout: CardLayout, _ id: ObjectIdentifier,
                     now activeUnit: DeviceUnit, _ activeLayout: CardLayout?, _ activeID: ObjectIdentifier?) -> Bool {
            UnitOutputMeters.replyBelongs(unit: unit, layout: layout, connection: id,
                                          activeUnit: activeUnit, activeLayout: activeLayout,
                                          activeConnection: activeID)
        }
        #expect(belongs(.a, layoutA, idA, now: .a, layoutA, idA))
        #expect(!belongs(.a, layoutA, idA, now: .b, layoutB, idB))    // picker moved to B while A's read was out
        #expect(!belongs(.b, layoutB, idB, now: .a, layoutA, idA))    // and the reverse
        #expect(!belongs(.b, layoutB, idB, now: .b, layoutA, idB))    // unit B's cards changed meanwhile
        #expect(!belongs(.a, layoutA, idA, now: .a, layoutA, idB))    // reconnected: another connection
        #expect(!belongs(.a, layoutA, idA, now: .a, nil, nil))        // the device went away
    }

    @Test("the unit read needs driver build 144; unknown, pre-reporting and older builds never ask")
    func gate() {
        #expect(!UnitOutputMeters.driverSupports(nil))
        #expect(!UnitOutputMeters.driverSupports(.olderThanBuildReporting))
        #expect(!UnitOutputMeters.driverSupports(.build(0)))
        #expect(!UnitOutputMeters.driverSupports(.build(143)))
        #expect(UnitOutputMeters.driverSupports(.build(144)))
        #expect(UnitOutputMeters.driverSupports(.build(150)))
    }
}
