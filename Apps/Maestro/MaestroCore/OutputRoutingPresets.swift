import Foundation

/// Output Routing presets for the Symphony I/O card grid, and the one rule
/// for what a save, load or delete touches.
///
/// - A preset is unit A's table, plus, when it was saved with two Symphony
///   I/Os, unit B's table tagged with unit B's card scope.
/// - Saving always rewrites the whole preset: a save with one unit drops any
///   unit B table of that name, so a preset never carries a stale unit B half.
/// - Loading checks unit B's table against unit B's current cards before
///   anything is written; a mismatch refuses the whole load.
/// - Presets saved for unit B alone by the earlier per-unit grid stay separate
///   entries ("name (Unit B only)"), listed and deletable only while two units
///   are present, so they never join a unit A preset of the same name and are
///   never deleted while hidden.
public struct OutputRoutingPresets: Equatable, Sendable {
    /// Unit B's half of a two-unit preset.
    public struct UnitBHalf: Codable, Equatable, Sendable {
        /// Unit B's card scope (``CardLayout/savedStateScope``) at save time.
        public var cardScope: String
        /// 64-channel grid rows → unit B output columns.
        public var rows: [Int: Set<Int>]
        public init(cardScope: String, rows: [Int: Set<Int>]) {
            self.cardScope = cardScope
            self.rows = rows
        }
    }

    /// One line in the preset menu.
    public enum Entry: Hashable, Sendable {
        case preset(String)
        /// A preset the earlier per-unit grid saved for unit B alone.
        case unitBOnly(String)

        public static let unitBOnlySuffix = " (Unit B only)"

        public var displayName: String {
            switch self {
            case .preset(let name): return name
            case .unitBOnly(let name): return name + Self.unitBOnlySuffix
            }
        }
    }

    /// Unit B as it is now, for a load.
    public struct UnitBState: Equatable, Sendable {
        public var cardScope: String?
        public var columnCount: Int
        /// Both slots detected (or simulated in the second-unit simulation).
        public var writable: Bool
        public init(cardScope: String?, columnCount: Int, writable: Bool) {
            self.cardScope = cardScope
            self.columnCount = columnCount
            self.writable = writable
        }
    }

    /// What a load writes: nil leaves that unit as it is.
    public struct LoadPlan: Equatable, Sendable {
        public var unitA: [Int: Set<Int>]?
        public var unitB: [Int: Set<Int>]?
    }

    /// Why a load was refused before anything was written.
    public enum Refusal: Error, Equatable, Sendable {
        case missing
        case unitBAbsent
        case unitBNotWritable
        case unitBCardsChanged
        case unitBInvalid

        public var message: String {
            switch self {
            case .missing: return "Preset not found."
            case .unitBAbsent: return "Preset not loaded: it is for unit B, which is not connected at 64 channels."
            case .unitBNotWritable: return "Preset not loaded: unit B's I/O cards were not detected this session."
            case .unitBCardsChanged: return "Preset not loaded: unit B's I/O cards are not the ones it was saved with."
            case .unitBInvalid: return "Preset not loaded: unit B's routes do not fit unit B's outputs."
            }
        }
    }

    /// Unit A's tables, in the saved row numbering (``RoutingPresetRows``).
    public var unitA: [String: [Int: Set<Int>]]
    public var unitB: [String: UnitBHalf]
    public var legacyUnitB: [String: [Int: Set<Int>]]

    public init(unitA: [String: [Int: Set<Int>]] = [:], unitB: [String: UnitBHalf] = [:],
                legacyUnitB: [String: [Int: Set<Int>]] = [:]) {
        self.unitA = unitA
        self.unitB = unitB
        self.legacyUnitB = legacyUnitB
    }

    /// The menu's entries: every preset, and with two units the unit-B-only ones.
    public func entries(twoUnits: Bool) -> [Entry] {
        let presets = unitA.keys.sorted().map(Entry.preset)
        guard twoUnits else { return presets }
        return presets + legacyUnitB.keys.sorted().map(Entry.unitBOnly)
    }

    /// The entry a menu line names (a preset first, if both read the same).
    public func entry(displayName: String, twoUnits: Bool) -> Entry? {
        entries(twoUnits: twoUnits).first { $0.displayName == displayName }
    }

    /// Save the whole preset: unit A's table and, with two units, unit B's.
    /// A one-unit save removes the name's unit B half.
    public mutating func save(name: String, unitA rows: [Int: Set<Int>], unitB half: UnitBHalf?) {
        unitA[name] = rows
        unitB[name] = half
    }

    /// Delete exactly what the entry is.
    public mutating func delete(_ entry: Entry) {
        switch entry {
        case .preset(let name):
            unitA.removeValue(forKey: name)
            unitB.removeValue(forKey: name)
        case .unitBOnly(let name):
            legacyUnitB.removeValue(forKey: name)
        }
    }

    /// What loading the entry writes, or why it must write nothing.
    /// `unitB` is nil with one unit.
    public func loadPlan(_ entry: Entry, unitB state: UnitBState?) -> Result<LoadPlan, Refusal> {
        switch entry {
        case .preset(let name):
            guard let rowsA = unitA[name] else { return .failure(.missing) }
            // With one unit a two-unit preset loads unit A's half only.
            guard let state, let half = unitB[name] else {
                return .success(LoadPlan(unitA: rowsA, unitB: nil))
            }
            guard state.writable else { return .failure(.unitBNotWritable) }
            guard state.cardScope == half.cardScope else { return .failure(.unitBCardsChanged) }
            if let refusal = Self.check(half.rows, state: state) { return .failure(refusal) }
            return .success(LoadPlan(unitA: rowsA, unitB: half.rows))
        case .unitBOnly(let name):
            guard let rows = legacyUnitB[name] else { return .failure(.missing) }
            guard let state else { return .failure(.unitBAbsent) }
            // Saved before presets recorded unit B's cards: only its shape
            // can be checked.
            if let refusal = Self.check(rows, state: state) { return .failure(refusal) }
            return .success(LoadPlan(unitA: nil, unitB: rows))
        }
    }

    private static func check(_ rows: [Int: Set<Int>], state: UnitBState) -> Refusal? {
        guard state.writable else { return .unitBNotWritable }
        return TwoUnitOutputRouting.isValidUnitBTable(rows, columnCount: state.columnCount) ? nil : .unitBInvalid
    }
}

extension TwoUnitOutputRouting {
    /// A unit B table the card can hold: rows on the 64-channel grid, columns
    /// among unit B's outputs, one source per output.
    public static func isValidUnitBTable(_ rows: [Int: Set<Int>], columnCount: Int) -> Bool {
        var owned = Set<Int>()
        for (row, cols) in rows {
            guard (0..<rowCount).contains(row) else { return false }
            for col in cols {
                guard (0..<columnCount).contains(col), owned.insert(col).inserted else { return false }
            }
        }
        return true
    }

    /// The table with every row present (empty rows included), so a saved
    /// unit B table is read back as complete: an output it leaves unrouted
    /// stays unrouted rather than returning to its start-up route.
    public static func completeTable(_ rows: [Int: Set<Int>]) -> [Int: Set<Int>] {
        var table = rows.filter { (0..<rowCount).contains($0.key) }
        for row in 0..<rowCount where table[row] == nil { table[row] = [] }
        return table
    }
}
