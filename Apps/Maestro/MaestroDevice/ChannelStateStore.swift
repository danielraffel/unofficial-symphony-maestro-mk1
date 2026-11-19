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
///
/// Converters have no cards: their state is kept per chain of units
/// (`conv:<routingSignature>`), and a chain never claims the legacy key,
/// which was a Symphony I/O's.
public struct ChannelStateStore {

    public static let inputKey = "inputChannelStates"
    public static let outputKey = "outputChannelStates"
    public static func mixerKey(_ mixer: Int) -> String { "mixerState_\(mixer)" }

    private let defaults: UserDefaults
    /// Scope suffix, or nil to use the legacy unscoped key.
    public let scope: String?
    /// True under the card-simulation harness: isolated from real state.
    public let isSimulating: Bool

    /// Which unit the state belongs to. Unit B (the second Symphony I/O on
    /// ThunderBridge port 2) has its own keys, prefixed `unitB:`, so a unit B
    /// with the same cards as unit A never reads or overwrites unit A's state,
    /// and it never inherits or claims the legacy unscoped key.
    public let unit: DeviceUnit
    /// Hardware identity when the transport could read it. Unknown keeps the
    /// historical layout-keyed behaviour.
    public let identity: UInt64?
    private let legacyScope: String?

    public init(
        defaults: UserDefaults = .standard,
        layout: CardLayout,
        isSimulatingCards: Bool = SimulatedDevice.isSimulatingCards(),
        unit: DeviceUnit = .a,
        identity: UInt64? = nil
    ) {
        self.defaults = defaults
        self.isSimulating = isSimulatingCards
        self.unit = unit
        self.identity = identity
        var computedScope: String?
        if unit == .a, let converters = layout.converterLayout {
            let chain = "conv:\(converters.routingSignature)"
            computedScope = chain
        } else if let scope = layout.savedStateScope {
            let unitScope = unit == .b ? "unitB:\(scope)" : scope
            computedScope = unitScope
        } else if unit == .b {
            computedScope = "unitB"
        } else {
            computedScope = nil
        }
        self.legacyScope = computedScope
        if let identity, !isSimulatingCards {
            // Identity AND card layout: the strips depend on the fitted cards,
            // so a card swap in the same unit must not load the other layout's
            // state (the reason the layout scope exists).
            let prefix = unit == .a ? "unitA" : "unitB"
            let layoutPart = computedScope.map { ":\($0)" } ?? ""
            self.scope = "\(prefix):v2:\(String(identity, radix: 16))\(layoutPart)"
        } else {
            self.scope = isSimulatingCards ? computedScope.map { "sim:\($0)" } : computedScope
        }
    }

    /// The key a `base` is read from / written to for this scope.
    public func key(_ base: String) -> String {
        if identity == nil, let legacyScope,
           let migratedScope = defaults.string(forKey: "\(base).\(legacyScope).migratedTo"),
           !migratedScope.isEmpty {
            return "\(base).\(migratedScope)"
        }
        guard let scope else { return base }
        return "\(base).\(scope)"
    }

    /// Marker recording which scope inherited the legacy unscoped `base`.
    public static func claimKey(_ base: String) -> String { "\(base).claimedBy" }

    /// Raw saved data for `base`, applying the migration rules above.
    public func loadData(_ base: String) -> Data? {
        if let data = defaults.data(forKey: key(base)) { return data }
        if identity == nil, let legacyScope,
           defaults.string(forKey: "\(base).\(legacyScope).migratedTo") != nil {
            return nil
        }
        if identity != nil, let legacyScope, !isSimulating {
            let legacyKey = "\(base).\(legacyScope)"
            let marker = "\(legacyKey).migratedTo"
            if defaults.string(forKey: marker) == nil, let data = defaults.data(forKey: legacyKey) {
                defaults.set(data, forKey: key(base))
                defaults.set(scope, forKey: marker)
                return data
            }
        }
        guard let scope else { return nil }                 // unscoped key was already tried
        guard !isSimulating else { return nil }             // never inherit real state
        guard unit == .a else { return nil }                // unit B never inherits unit A's
        guard !scope.hasPrefix("conv:") else { return nil }  // converters never inherit a Symphony I/O's
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
