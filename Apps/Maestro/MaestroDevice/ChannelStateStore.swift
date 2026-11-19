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

    /// Addressing role, used only for historical layout-key migration. Known
    /// physical UIDs use the same destination on either port. Unit B never
    /// inherits unit A's unscoped legacy record.
    public let unit: DeviceUnit
    /// Hardware identity when the transport could read it. Production discovery
    /// sets awaitingIdentity to keep pending/failed sessions out of legacy state.
    public let identity: UInt64?
    private let legacyScope: String?
    private let permitsLegacyInheritance: Bool
    private let layoutScope: String?
    private let awaitingIdentity: Bool
    private let allowLegacyMigration: Bool

    public init(
        defaults: UserDefaults = .standard,
        layout: CardLayout,
        isSimulatingCards: Bool = SimulatedDevice.isSimulatingCards(),
        unit: DeviceUnit = .a,
        identity: UInt64? = nil,
        awaitingIdentity: Bool = false,
        allowLegacyMigration: Bool = true
    ) {
        self.defaults = defaults
        self.awaitingIdentity = awaitingIdentity
        self.allowLegacyMigration = allowLegacyMigration
        self.isSimulating = isSimulatingCards
        self.unit = unit
        let identity = layout.converterLayout == nil && layout.converter == nil ? identity : nil
        self.identity = identity
        self.layoutScope = layout.savedStateScope
        self.permitsLegacyInheritance = layout.converterLayout == nil && layout.converter == nil
        var computedScope: String?
        if unit == .a, let converters = layout.converterLayout {
            let chain = "conv:\(converters.routingSignature)"
            computedScope = chain
        } else if layout.converter != nil {
            computedScope = "conv:unidentified"
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
            let layoutPart = layout.savedStateScope.map { ":\($0)" } ?? ""
            self.scope = "unit:v3:\(String(identity, radix: 16))\(layoutPart)"
        } else {
            self.scope = isSimulatingCards ? computedScope.map { "sim:\($0)" } : computedScope
        }
    }

    public var mixerPreferences: MixerPreferences {
        if !awaitingIdentity, identity == nil, !isSimulating, permitsLegacyInheritance, unit == .a {
            if let owner = defaults.string(forKey: "mixerWideState.migratedTo"), !owner.isEmpty {
                return MixerPreferences(defaults: defaults, scope: owner, migrate: false)
            }
            return MixerPreferences(legacyDefaults: defaults)
        }
        return MixerPreferences(defaults: defaults,
            scope: awaitingIdentity ? "pending" : (scope ?? (isSimulating ? "sim:unidentified" : "unidentified")),
            migrate: identity != nil && !isSimulating && !awaitingIdentity
                && permitsLegacyInheritance && unit == .a && allowLegacyMigration)
    }

    /// The key a `base` is read from / written to for this scope.
    public func key(_ base: String) -> String {
        if identity == nil, !isSimulating, permitsLegacyInheritance, let legacyScope,
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
        guard !awaitingIdentity else { return nil }
        if let data = defaults.data(forKey: key(base)) { return data }
        if identity == nil, !isSimulating, permitsLegacyInheritance, let legacyScope,
           defaults.string(forKey: "\(base).\(legacyScope).migratedTo") != nil {
            return nil
        }
        if let identity, let scope, !isSimulating, permitsLegacyInheritance {
            let destination = "\(base).\(scope)"
            // Previous F2 versions included the port twice for B. Accept both
            // histories, but never take another physical UID's migrated data.
            for role in [DeviceUnit.a, .b] {
                let oldLayout = layoutScope.map { role == .b ? "unitB:\($0)" : $0 }
                let suffix = oldLayout.map { ":\($0)" } ?? ""
                let old = "\(base).\(role == .a ? "unitA" : "unitB"):v2:\(String(identity, radix: 16))\(suffix)"
                if let historical = defaults.data(forKey: old) {
                    let data = unverified(historical, base: base)
                    defaults.set(data, forKey: destination)
                    if let oldLayout {
                        let marker = "\(base).\(oldLayout).migratedTo"
                        if defaults.string(forKey: marker) == String(old.dropFirst(base.count + 1)) {
                            defaults.set(scope, forKey: marker)
                        }
                    }
                    return data
                }
            }
            guard allowLegacyMigration else { return nil }
            if let legacyScope {
                let source = "\(base).\(legacyScope)"
                let claimed = unit == .a && defaults.string(forKey: Self.claimKey(base)) == legacyScope
                let unclaimed = unit == .a && defaults.string(forKey: Self.claimKey(base)) == nil
                let data = defaults.data(forKey: source)
                    ?? ((claimed || unclaimed) ? defaults.data(forKey: base) : nil)
                let copied = UnitStateMigration.copyData(defaults: defaults, source: source,
                                                         destination: destination, owner: scope, data: data.map { unverified($0, base: base) })
                if copied != nil, claimed || unclaimed {
                    defaults.set(legacyScope, forKey: Self.claimKey(base))
                }
                return copied
            }
            return nil
        }
        guard let scope else { return nil }                 // unscoped key was already tried
        guard !isSimulating else { return nil }             // never inherit real state
        guard unit == .a else { return nil }                // unit B never inherits unit A's
        guard permitsLegacyInheritance else { return nil }  // converters never inherit a Symphony I/O's
        guard let legacy = defaults.data(forKey: base) else { return nil }
        let claim = Self.claimKey(base)
        if let owner = defaults.string(forKey: claim), owner != scope { return nil }
        defaults.set(scope, forKey: claim)
        return unverified(legacy, base: base)
    }

    private func unverified(_ data: Data, base: String) -> Data {
        guard base == Self.inputKey,
              var inputs = try? JSONDecoder().decode([InputChannelState].self, from: data),
              inputs.contains(where: { $0.phantomProvenance != nil }) else { return data }
        for index in inputs.indices { inputs[index].phantomProvenance = nil }
        return (try? JSONEncoder().encode(inputs)) ?? data
    }

    /// Store `data` for `base` under this scope.
    public func saveData(_ data: Data, for base: String) {
        guard !awaitingIdentity else { return }
        defaults.set(data, forKey: key(base))
    }

    /// Compatibility query only; saving an array never establishes authority.
    public var hasVerifiedInputIdentity: Bool {
        guard let identity, let inputs: [InputChannelState] = load(Self.inputKey) else { return false }
        return inputs.enumerated().contains { index, state in
            state.restoresPhantom(identity: identity, boardSlot: 1, channel: index)
        }
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
