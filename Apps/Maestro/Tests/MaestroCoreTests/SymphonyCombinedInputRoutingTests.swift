import Testing
@testable import MaestroCore

struct SymphonyCombinedInputRoutingTests {
    @Test func twoUnitLayoutKeepsUnitOrderAndOmitsUnavailableInputs() {
        let columns = SymphonyCombinedInputRouting.columns(
            unitANames: ["A Line 1/2", CardLayout.notApplicable, "A Line 5/6"],
            unitBNames: ["B Line 1/2", "B Line 3/4"])
        let units = columns.map(\.unit)
        let pairs = columns.map(\.sourcePair)
        let names = columns.map(\.name)
        #expect(units == [.a, .a, .b, .b])
        #expect(pairs == [0, 2, 16, 17])
        #expect(names == ["A Line 1/2", "A Line 5/6", "B Line 1/2", "B Line 3/4"])
    }

    @Test func combinedWriteMapsSoftwarePairToCardRxPair() {
        let column = SymphonyCombinedInputColumn(unit: .b, sourcePair: 17, name: "B Line 3/4")
        #expect(SymphonyCombinedInputRouting.cardEdits(row: 4, column: column) == [8: 34, 9: 35])
        #expect(SymphonyCombinedInputRouting.cardEdits(row: -1, column: column).isEmpty)
    }
}
