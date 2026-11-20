import Testing
@testable import MaestroCore

@Suite("Output Routing grid: one grid for the card")
struct OutputRoutingGridTests {
    private let unitA = CardLayout(slot1: .analogADDA16, slot2: .none, isKnown: true)
    // Unit B: an 8x8 with optical at 192 kHz, so it has ADAT pairs the rate
    // does not carry (N.A.).
    private let unitB = CardLayout(slot1: .optical, slot2: .none, isKnown: true,
                                   naming: .init(sampleRate: 192000, opticalIsSPDIF: [false, nil]))

    private func twoUnits(pairs: Int = 16) -> OutputRoutingGrid {
        .twoUnits(unitA: unitA.outputRoutingColumns, prefixA: "A",
                  unitB: unitB, prefixB: "D", unitAPairs: pairs)
    }

    @Test("One unit: its own columns, no block headers, rows passed straight through")
    func singleUnitUnchanged() throws {
        for layout in [unitA, unitB, CardLayout(slot1: .analogAES, slot2: .optical, isKnown: true)] {
            let grid = OutputRoutingGrid.singleUnit(columns: layout.outputRoutingColumns, unitAPairs: 8)
            #expect(!grid.isTwoUnits)
            #expect(grid.columns == layout.outputRoutingColumns)
            #expect(grid.columnGroups.isEmpty)
            #expect(grid.columns(of: .b).isEmpty)
            for col in layout.outputRoutingColumns.indices {
                for row in [0, 7, 8, 9] {
                    let cell = try #require(grid.cell(gridRow: row, column: col))
                    #expect(cell == .init(unit: .a, row: row, column: col,
                                          routingByte: layout.outputRoutingColumns[col].routingByte))
                }
            }
            #expect(grid.cell(gridRow: 0, column: layout.outputRoutingColumns.count) == nil)
            #expect(grid.cell(gridRow: 0, column: -1) == nil)
        }
    }

    @Test("Two units: unit A's block, then unit B's, each headed by its unit")
    func twoUnitColumnsAndHeaders() {
        let grid = twoUnits()
        let a = unitA.outputRoutingColumns
        let b = TwoUnitMixer.unitBRoutingColumns(layout: unitB, prefix: "D", isInput: false)
        #expect(grid.isTwoUnits)
        #expect(grid.columns == a + b)
        #expect(grid.columns(of: .a) == a)
        #expect(grid.columns(of: .b) == b)
        let groups = grid.columnGroups
        #expect(groups.map(\.label) == ["Unit A (A)", "Unit B (D)"])
        #expect(groups.map(\.count) == [a.count, b.count])
        // The headers span exactly the grid's columns.
        #expect(groups.map(\.count).reduce(0, +) == grid.columns.count)
        // Unit A's names are as with one unit; unit B's carry its prefix,
        // follow its own optical format and rate, and N.A. stays bare.
        #expect(grid.columns.first?.stereoName == a.first?.stereoName)
        #expect(grid.columns[a.count].stereoName == "D Line 1/2")
        #expect(b.contains { $0.stereoName == CardLayout.notApplicable })
        #expect(!b.contains { $0.stereoName.hasPrefix("D N.A.") })
    }

    @Test("A cell writes the unit, row and output its per-unit table always held")
    func cellMapping() throws {
        let grid = twoUnits(pairs: 16)
        let a = unitA.outputRoutingColumns
        let b = grid.columns(of: .b)

        // Unit A's columns: rows in unit A's saved numbering (DAW 1-32, then
        // Mixer 1/2, then DAW 33-64).
        let first = try #require(grid.cell(gridRow: 0, column: 0))
        #expect(first == .init(unit: .a, row: 0, column: 0, routingByte: a[0].routingByte))
        #expect(grid.cell(gridRow: 15, column: 1)?.row == 15)
        #expect(grid.cell(gridRow: 16, column: 1)?.row == 18)   // DAW 33-34 on unit A
        #expect(grid.cell(gridRow: 31, column: 1)?.row == 33)   // DAW 63-64 on unit A
        #expect(grid.cell(gridRow: TwoUnitOutputRouting.mixer1Row, column: 2)?.row == 16)
        #expect(grid.cell(gridRow: TwoUnitOutputRouting.mixer2Row, column: 2)?.row == 17)
        #expect(grid.cell(gridRow: TwoUnitOutputRouting.rowCount, column: 0) == nil)
        let lastA = try #require(grid.cell(gridRow: 3, column: a.count - 1))
        #expect(lastA.unit == .a && lastA.column == a.count - 1 && lastA.routingByte == a[a.count - 1].routingByte)

        // Unit B's columns: unit B, its own column and output byte, the
        // 64-channel grid row as is.
        for (offset, column) in b.enumerated() {
            for row in [0, 16, 31, TwoUnitOutputRouting.mixer1Row, TwoUnitOutputRouting.mixer2Row] {
                let cell = try #require(grid.cell(gridRow: row, column: a.count + offset))
                #expect(cell == .init(unit: .b, row: row, column: offset, routingByte: column.routingByte))
            }
        }
        #expect(grid.cell(gridRow: TwoUnitOutputRouting.rowCount, column: a.count) == nil)
        #expect(grid.cell(gridRow: 0, column: a.count + b.count) == nil)
    }

    @Test("Unit B's block follows its own cards and prefix, not unit A's")
    func unitBBlockFollowsUnitB() {
        let aes = CardLayout(slot1: .analogAES, slot2: .optical, isKnown: true)
        let grid = OutputRoutingGrid.twoUnits(unitA: unitA.outputRoutingColumns, prefixA: "A",
                                              unitB: aes, prefixB: "Q", unitAPairs: 16)
        #expect(grid.columns(of: .b).count == aes.outputRoutingColumns.count)
        #expect(grid.columns(of: .b).map(\.routingByte) == aes.outputRoutingColumns.map(\.routingByte))
        #expect(grid.columns(of: .b).allSatisfy {
            $0.stereoName.hasPrefix("Q ") || $0.stereoName == CardLayout.notApplicable
        })
        #expect(grid.columnGroups.last?.label == "Unit B (Q)")
    }
}
