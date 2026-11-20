import Foundation

/// The Symphony I/O Output Routing grid's columns. With two Symphony I/Os at
/// 64 channels the card is one routing device, so the grid shows unit A's
/// hardware output pairs and then unit B's, each block headed by its unit, as
/// the original's routing card showed every attached device's outputs side by
/// side (`og_source/maestro2/App/Controllers/APOutputRoutingTabRowViewController.m:120-266`,
/// `APOutputRoutingTabViewController.m:81-160`). With one unit it is that
/// unit's columns alone, with no block header.
///
/// Rows are the grid's: with one unit, unit A's DAW pairs then Mixer 1/2; with
/// two, the 32 DAW pairs then Mixer 1/2 (see ``TwoUnitOutputRouting``). A cell
/// resolves to the unit, that unit's own saved row numbering and its column,
/// so a click writes exactly the route the per-unit tables always held.
public struct OutputRoutingGrid: Sendable, Equatable {
    /// One unit's run of columns.
    public struct Block: Sendable, Equatable {
        public let unit: DeviceUnit
        /// The block's header ("Unit A (A)"); empty with one unit.
        public let title: String
        public let columns: [CardLayout.RoutingColumn]
    }

    /// Where a click on a cell goes.
    public struct Cell: Sendable, Equatable {
        public let unit: DeviceUnit
        /// The row in that unit's saved table: unit A's single-unit numbering
        /// (its DAW pairs, then the two mixers, then DAW 33-64), unit B's
        /// 64-channel grid row.
        public let row: Int
        /// The column within that unit's block.
        public let column: Int
        /// The output pair's left routing byte on that unit.
        public let routingByte: UInt8
    }

    public let blocks: [Block]
    /// Unit A's DAW pairs in its saved numbering (the device mode's pairs).
    public let unitAPairs: Int

    /// One Symphony I/O (USB, PCIe, ThunderBridge at 32 channels): its own
    /// columns, rows passed straight through.
    public static func singleUnit(columns: [CardLayout.RoutingColumn], unitAPairs: Int) -> OutputRoutingGrid {
        OutputRoutingGrid(blocks: [Block(unit: .a, title: "", columns: columns)], unitAPairs: unitAPairs)
    }

    /// Two Symphony I/Os at 64 channels: unit A's columns as unit A shows
    /// them, then unit B's named with its prefix letter (`N.A.` and the
    /// optical format follow unit B's own layout).
    public static func twoUnits(unitA: [CardLayout.RoutingColumn], prefixA: String,
                                unitB: CardLayout, prefixB: String, unitAPairs: Int) -> OutputRoutingGrid {
        OutputRoutingGrid(blocks: [
            Block(unit: .a, title: UnitPicker.label(.a, prefix: prefixA), columns: unitA),
            Block(unit: .b, title: UnitPicker.label(.b, prefix: prefixB),
                  columns: TwoUnitMixer.unitBRoutingColumns(layout: unitB, prefix: prefixB, isInput: false)),
        ], unitAPairs: unitAPairs)
    }

    public var isTwoUnits: Bool { blocks.count > 1 }

    /// Every column, left to right.
    public var columns: [CardLayout.RoutingColumn] { blocks.flatMap(\.columns) }

    /// One unit's columns (empty for a unit not in the grid).
    public func columns(of unit: DeviceUnit) -> [CardLayout.RoutingColumn] {
        blocks.first { $0.unit == unit }?.columns ?? []
    }

    /// The header over each block, with its width in columns. None with one
    /// unit, which keeps the grid's single "Hardware Outputs" header.
    public var columnGroups: [(label: String, count: Int)] {
        isTwoUnits ? blocks.map { (label: $0.title, count: $0.columns.count) } : []
    }

    /// The unit, row and column a grid cell edits, or nil for a cell that
    /// unit's table cannot hold.
    public func cell(gridRow: Int, column: Int) -> Cell? {
        guard column >= 0 else { return nil }
        var offset = column
        for block in blocks {
            guard offset >= block.columns.count else {
                let row: Int?
                if !isTwoUnits {
                    row = gridRow
                } else if block.unit == .a {
                    row = TwoUnitOutputRouting.unitARow(gridRow: gridRow, unitAPairs: unitAPairs)
                } else {
                    row = (0..<TwoUnitOutputRouting.rowCount).contains(gridRow) ? gridRow : nil
                }
                guard let row else { return nil }
                return Cell(unit: block.unit, row: row, column: offset,
                            routingByte: block.columns[offset].routingByte)
            }
            offset -= block.columns.count
        }
        return nil
    }
}
