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

@Suite("Output Routing grid: block headers")
struct OutputRoutingGridHeaderTests {
    @Test("A unit with no outputs (an 8MicPre alone) gets no block header")
    func emptyBlockSkipped() {
        let adOnly = CardLayout(slot1: .none, slot2: .micPre8, isKnown: true)   // inputs only
        #expect(adOnly.outputRoutingColumns.isEmpty)
        let b = CardLayout(slot1: .analogADDA16, slot2: .none, isKnown: true)
        let grid = OutputRoutingGrid.twoUnits(unitA: adOnly.outputRoutingColumns, prefixA: "A",
                                              unitB: b, prefixB: "B", unitAPairs: 16)
        #expect(grid.columnGroups.map(\.label) == ["Unit B (B)"])
        #expect(grid.columnGroups.map(\.count) == [b.outputRoutingColumns.count])
        #expect(grid.cell(gridRow: 0, column: 0)?.unit == .b)
    }
}

@Suite("Output Routing presets: one rule for both units")
struct OutputRoutingPresetsTests {
    typealias Presets = OutputRoutingPresets
    private let rowsA: [Int: Set<Int>] = [0: [0], 1: [1]]
    private let rowsB: [Int: Set<Int>] = [16: [0], 17: [1], 32: [2]]
    private func state(scope: String? = "16x16", columns: Int = 8, writable: Bool = true) -> Presets.UnitBState {
        .init(cardScope: scope, columnCount: columns, writable: writable)
    }

    @Test("A two-unit save keeps both halves; a load writes both")
    func saveAndLoadBoth() throws {
        var presets = Presets()
        presets.save(name: "Tracking", unitA: rowsA, unitB: .init(cardScope: "16x16", rows: rowsB))
        let plan = try presets.loadPlan(.preset("Tracking"), unitB: state()).get()
        #expect(plan.unitA == rowsA)
        #expect(plan.unitB == rowsB)
        // With one unit the same preset writes unit A only.
        #expect(try presets.loadPlan(.preset("Tracking"), unitB: nil).get() == .init(unitA: rowsA, unitB: nil))
    }

    @Test("A one-unit re-save drops the stale unit B half")
    func oneUnitResave() throws {
        var presets = Presets()
        presets.save(name: "Tracking", unitA: rowsA, unitB: .init(cardScope: "16x16", rows: rowsB))
        presets.save(name: "Tracking", unitA: [0: [3]], unitB: nil)
        #expect(presets.unitB["Tracking"] == nil)
        let plan = try presets.loadPlan(.preset("Tracking"), unitB: state()).get()
        #expect(plan.unitA == [0: [3]])
        #expect(plan.unitB == nil, "a preset without unit B leaves unit B alone")
    }

    @Test("Delete matches save: the whole preset, and only what is listed")
    func deleteMatchesSave() {
        var presets = Presets(legacyUnitB: ["Tracking": [16: [0]]])
        presets.save(name: "Tracking", unitA: rowsA, unitB: .init(cardScope: "16x16", rows: rowsB))
        // With one unit, the unit-B-only preset is hidden, so not deletable.
        #expect(presets.entries(twoUnits: false) == [.preset("Tracking")])
        presets.delete(.preset("Tracking"))
        #expect(presets.unitA.isEmpty && presets.unitB.isEmpty)
        #expect(presets.legacyUnitB["Tracking"] == [16: [0]])
    }

    @Test("A legacy unit-B-only preset stays its own entry, never joining unit A's of that name")
    func legacyStaysSeparate() throws {
        var presets = Presets(legacyUnitB: ["X": rowsB])
        presets.save(name: "X", unitA: rowsA, unitB: nil)
        let entries = presets.entries(twoUnits: true)
        #expect(entries == [.preset("X"), .unitBOnly("X")])
        #expect(entries.map(\.displayName) == ["X", "X (Unit B only)"])
        #expect(presets.entry(displayName: "X", twoUnits: true) == .preset("X"))
        #expect(presets.entry(displayName: "X (Unit B only)", twoUnits: false) == nil)
        #expect(try presets.loadPlan(.preset("X"), unitB: state()).get() == .init(unitA: rowsA, unitB: nil))
        #expect(try presets.loadPlan(.unitBOnly("X"), unitB: state()).get() == .init(unitA: nil, unitB: rowsB))
        #expect(presets.loadPlan(.unitBOnly("X"), unitB: nil) == .failure(.unitBAbsent))
        presets.delete(.unitBOnly("X"))
        #expect(presets.legacyUnitB.isEmpty && presets.unitA["X"] == rowsA)
    }

    @Test("Unit B's half is checked against unit B's cards before anything is written")
    func unitBRefusedUpFront() {
        var presets = Presets()
        presets.save(name: "T", unitA: rowsA, unitB: .init(cardScope: "16x16", rows: rowsB))
        // Other cards on unit B, even with as many outputs: refused whole.
        #expect(presets.loadPlan(.preset("T"), unitB: state(scope: "8x8+none")) == .failure(.unitBCardsChanged))
        #expect(presets.loadPlan(.preset("T"), unitB: state(scope: nil)) == .failure(.unitBCardsChanged))
        #expect(presets.loadPlan(.preset("T"), unitB: state(writable: false)) == .failure(.unitBNotWritable))
        // Fewer outputs than the preset routes.
        #expect(presets.loadPlan(.preset("T"), unitB: state(columns: 2)) == .failure(.unitBInvalid))
        // A legacy preset has no card scope; its shape is still checked.
        let legacy = Presets(legacyUnitB: ["L": [0: [5]]])
        #expect(legacy.loadPlan(.unitBOnly("L"), unitB: state(columns: 4)) == .failure(.unitBInvalid))
        for refusal in [Presets.Refusal.unitBCardsChanged, .unitBNotWritable, .unitBInvalid, .unitBAbsent] {
            #expect(refusal.message.contains("unit B"), "\(refusal)")
        }
    }

    @Test("Unit B tables: validity and complete tables")
    func tables() {
        #expect(TwoUnitOutputRouting.isValidUnitBTable([0: [0], 33: [1]], columnCount: 2))
        #expect(!TwoUnitOutputRouting.isValidUnitBTable([0: [0], 1: [0]], columnCount: 2), "one source per output")
        #expect(!TwoUnitOutputRouting.isValidUnitBTable([34: [0]], columnCount: 2))
        #expect(!TwoUnitOutputRouting.isValidUnitBTable([0: [2]], columnCount: 2))
        let table = TwoUnitOutputRouting.completeTable([3: [1], 99: [0]])
        #expect(table.count == TwoUnitOutputRouting.rowCount)
        #expect(table[3] == [1] && table[0] == [] && table[99] == nil)
    }
}
