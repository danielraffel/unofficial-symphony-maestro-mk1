import Foundation

/// User-editable names for the 8MicPre module's eight rear-panel inserts.
///
/// The Symphony I/O User's Guide (p. 65, item 4) documents these as customisable
/// in the Device Settings tab, "if you have a Mic Pre module installed". We had
/// the Insert popup but no editor, so the labels were stuck at "Insert 1"…
/// "Insert 8" and the Help deliberately said nothing about renaming them.
///
/// Semantics follow `kmAEstroPropertyInsertNameForID` ('AEiv') as the daemon
/// implements it in `SymphonyIOBoard_MicPre8ch.cpp:567-597`:
///
/// - Names are keyed by INSERT ID, not by channel, and are **shared across every
///   channel** -- the daemon's own comment at the notify loop says so, and it
///   re-notifies all eight channels after a single rename. Renaming "Insert 3" to
///   "LA-2A" changes it everywhere that insert can be chosen.
/// - Setting an EMPTY string clears the override and restores the default: the
///   daemon frees the stored string and only re-allocates when the new value is
///   non-empty, after which the getter falls back to `s_szSymphonyIOMicPre-
///   InsertNames`. Clearing a field here does the same rather than leaving a
///   blank menu entry.
///
/// These lived in the daemon's memory and were persisted with the rest of its
/// settings. We have no daemon, so they live in the app; the user-visible
/// behaviour is the same.
public struct InsertLabels: Equatable, Sendable {

    /// Insert IDs are 1-based; 0 is "None" and is never renameable.
    public static let count = 8

    /// Longest name accepted. Legacy had no explicit cap -- it `malloc`s whatever
    /// arrives -- but these are drawn in a narrow popup inside a channel strip,
    /// and an unbounded string would either truncate mid-render or stretch the
    /// strip and drag every meter in the rack out of alignment with it.
    public static let maxLength = 24

    /// Overrides by insert ID (1...8). A missing entry means "use the default".
    private var overrides: [UInt32: String]

    public init(overrides: [UInt32: String] = [:]) {
        self.overrides = [:]
        for (id, name) in overrides { self[id] = name }
    }

    /// The default name for an insert, used when nothing overrides it.
    public static func defaultName(_ id: UInt32) -> String {
        id == 0 ? "None" : "Insert \(id)"
    }

    /// Read or write the name for one insert.
    ///
    /// Writing whitespace-only text clears the override rather than storing a
    /// blank, matching the daemon's empty-string behaviour. Names are trimmed and
    /// capped; ID 0 ("None") is not renameable and writes to it are ignored.
    public subscript(id: UInt32) -> String {
        get { overrides[id] ?? Self.defaultName(id) }
        set {
            guard id >= 1, id <= UInt32(Self.count) else { return }
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == Self.defaultName(id) {
                overrides[id] = nil
            } else {
                overrides[id] = String(trimmed.prefix(Self.maxLength))
            }
        }
    }

    /// Whether this insert carries a user-chosen name.
    public func isCustom(_ id: UInt32) -> Bool { overrides[id] != nil }

    /// Whether any insert has been renamed.
    public var hasAnyCustom: Bool { !overrides.isEmpty }

    /// Clear every override, restoring "Insert 1"…"Insert 8".
    public mutating func resetAll() { overrides = [:] }

    // MARK: Persistence

    /// Round-trips through a plain `[String: String]` so this can sit in
    /// `UserDefaults` without a custom coder.
    public var storage: [String: String] {
        var out: [String: String] = [:]
        for (id, name) in overrides { out[String(id)] = name }
        return out
    }

    public init(storage: [String: String]) {
        self.overrides = [:]
        for (key, name) in storage {
            guard let id = UInt32(key) else { continue }
            self[id] = name
        }
    }
}
