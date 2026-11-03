import Foundation
import MaestroCore

/// Per-channel saved state (input strips, output strips, mixer faders), keyed
/// by the installed card pair.
///
/// # Why
///
/// These arrays were stored under one global `UserDefaults` key each, so the
/// state of a 24-strip unit was restored — trimmed to fit — into a 16-strip
/// one whenever the card complement changed: after a module swap on a real
/// unit, and every time the card-simulation harness ran on a developer's
/// machine. Scoping the key by `CardLayout.savedStateScope` gives each card
/// pair its own settings.
///
/// # Migration
///
/// Existing users have state under the legacy unscoped key. The first layout
/// that reads it *claims* it (recorded under `<base>.claimedBy`) and keeps
/// loading it until its own scoped copy is written; any other layout starts
/// from defaults. So a developer's current cards keep every setting they had,
/// and a different card pair does not inherit them.
///
/// Card simulation never inherits and never claims: its keys carry a `sim:`
/// scope so a harness run cannot read or write a real unit's state.
public struct ChannelStateStore {

    public static let inputKey = "inputChannelStates"
    public static let outputKey = "outputChannelStates"
    public static func mixerKey(_ mixer: Int) -> String { "mixerState_\(mixer)" }

    private let defaults: UserDefaults
    /// Scope suffix, or nil to use the legacy unscoped key.
    public let scope: String?
    /// True under the card-simulation harness: isolated from real state.
    public let isSimulating: Bool

    public init(
        defaults: UserDefaults = .standard,
        layout: CardLayout,
        isSimulatingCards: Bool = SimulatedDevice.isSimulatingCards()
    ) {
        self.defaults = defaults
        self.isSimulating = isSimulatingCards
        if let scope = layout.savedStateScope {
            self.scope = isSimulatingCards ? "sim:\(scope)" : scope
        } else {
            self.scope = nil
        }
    }

    /// The key a `base` is read from / written to for this scope.
    public func key(_ base: String) -> String {
        guard let scope else { return base }
        return "\(base).\(scope)"
    }

    /// Marker recording which scope inherited the legacy unscoped `base`.
    public static func claimKey(_ base: String) -> String { "\(base).claimedBy" }

    /// Raw saved data for `base`, applying the migration rules above.
    public func loadData(_ base: String) -> Data? {
        if let data = defaults.data(forKey: key(base)) { return data }
        guard let scope else { return nil }                 // unscoped key was already tried
        guard !isSimulating else { return nil }             // never inherit real state
        guard let legacy = defaults.data(forKey: base) else { return nil }
        let claim = Self.claimKey(base)
        if let owner = defaults.string(forKey: claim), owner != scope { return nil }
        defaults.set(scope, forKey: claim)
        return legacy
    }

    /// Store `data` for `base` under this scope.
    public func saveData(_ data: Data, for base: String) {
        defaults.set(data, forKey: key(base))
    }

    public func load<T: Decodable>(_ base: String, as type: [T].Type = [T].self) -> [T]? {
        guard let data = loadData(base) else { return nil }
        return try? JSONDecoder().decode([T].self, from: data)
    }

    public func save<T: Encodable>(_ values: [T], for base: String) {
        guard let data = try? JSONEncoder().encode(values) else { return }
        saveData(data, for: base)
    }
}
