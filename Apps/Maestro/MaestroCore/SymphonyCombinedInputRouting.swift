import Foundation

/// The card-level input matrix shown when two Symphony I/Os share a
/// ThunderBridge card.  Each column is a connected unit's stream pair; the
/// stream pair's current P2P route supplies its physical hardware name.
/// Card routing still addresses the stream pair (the same B6 path used by the
/// existing card grid), while the per-unit P2P tables remain the source of the
/// names and are reset/replayed by their existing owners.
public struct SymphonyCombinedInputColumn: Equatable, Sendable {
    public let unit: DeviceUnit
    public let sourcePair: Int
    public let name: String

    public init(unit: DeviceUnit, sourcePair: Int, name: String) {
        self.unit = unit
        self.sourcePair = sourcePair
        self.name = name
    }
}

public enum SymphonyCombinedInputRouting {
    public static let softwarePairCount = 32
    public static let unitPairCount = 16

    /// Preserve stream order within each unit, omitting unavailable rows.
    public static func columns(unitANames: [String], unitBNames: [String])
        -> [SymphonyCombinedInputColumn] {
        let a = unitANames.prefix(unitPairCount).enumerated().compactMap { pair, name in
            name == CardLayout.notApplicable ? nil
                : SymphonyCombinedInputColumn(unit: .a, sourcePair: pair, name: name)
        }
        let b = unitBNames.prefix(unitPairCount).enumerated().compactMap { pair, name in
            name == CardLayout.notApplicable ? nil
                : SymphonyCombinedInputColumn(unit: .b, sourcePair: unitPairCount + pair, name: name)
        }
        return a + b
    }

    /// Card B6/B7 edits for one stereo software row and one selected stream
    /// pair. The two bytes are deliberately adjacent and use the stream pair's
    /// card RX address, matching the established card-input write path.
    public static func cardEdits(row: Int, column: SymphonyCombinedInputColumn?) -> [Int: Int] {
        guard (0..<softwarePairCount).contains(row), let column else { return [:] }
        let source = column.sourcePair * 2
        return [row * 2: source, row * 2 + 1: source + 1]
    }
}
