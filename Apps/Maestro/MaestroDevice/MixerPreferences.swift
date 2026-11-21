import Foundation

/// Mixer-wide values share the channel store's physical UID/layout scope.
/// Original: og_source/maestrolink/Software/SymphonyIOMixer.cpp:1000-1075
/// looks up master/return/source by DeviceUIDCFStringRef (:1372-1389).
/// One immutable migration receipt captures *all* old keys, including absence,
/// so later edits to global keys can never leak into an identified unit.
// UserDefaults is thread-safe; the app serializes mutations on MainActor.
// Transport tasks receive this immutable handle only to read a restore snapshot.
public struct MixerPreferences: @unchecked Sendable {
    private let defaults: UserDefaults
    private let enabled: Bool
    private let readOnly: Bool
    public let storageKey: String?

    public var isWritable: Bool { enabled && !readOnly }

    public static let legacyKeys = ["mixerState_swReturn",
        "mixerMasterFadersLinked", "mixerSWReturnFadersLinked"] + (0..<2).flatMap { mixer in
        ["mixerMasterLevel", "mixerMasterLeftLevel", "mixerMasterRightLevel",
         "mixerSWReturnLeftLevel", "mixerSWReturnRightLevel", "mixerSoftwareReturnSource",
         "mixerState_swReturn"].map { "\($0)_\(mixer)" }
    }

    /// Legacy adapter for old-format tools and read-only failed-identity restore.
    /// Read-only handles cannot write global keys or create ownership receipts.
    public init(legacyDefaults: UserDefaults, readOnly: Bool = false) {
        self.readOnly = readOnly
        enabled = true
        defaults = legacyDefaults
        storageKey = nil
    }

    init(defaults: UserDefaults, scope: String, migrate: Bool) {
        readOnly = false
        enabled = scope != "pending"
        self.defaults = defaults
        let destination = "mixerWideState.\(scope)"
        storageKey = destination
        guard defaults.dictionary(forKey: destination) == nil, migrate else { return }
        // Once claimed, never even read the old global keys. The receipt is
        // the immutable source if destination materialization was interrupted.
        if let owner = defaults.string(forKey: "mixerWideState.migratedTo"), owner != scope { return }
        var data: Data?
        if defaults.dictionary(forKey: "mixerWideState.migrationReceipt") == nil {
            let legacy = Self.legacyKeys.reduce(into: [String: Any]()) { values, key in
                values[key] = defaults.object(forKey: key)
            }
            data = try? PropertyListSerialization.data(fromPropertyList: legacy, format: .binary, options: 0)
        }
        if let snapshot = UnitStateMigration.copyData(defaults: defaults, source: "mixerWideState",
                destination: destination + ".snapshot", owner: scope, data: data),
           let values = try? PropertyListSerialization.propertyList(from: snapshot, options: [], format: nil) as? [String: Any] {
            defaults.set(values, forKey: destination)
        }
    }

    public func object(forKey key: String) -> Any? {
        guard enabled else { return nil }
        if let storageKey { return defaults.dictionary(forKey: storageKey)?[key] }
        return defaults.object(forKey: key)
    }
    public func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    public func integer(forKey key: String) -> Int { (object(forKey: key) as? NSNumber)?.intValue ?? 0 }
    public func set(_ value: Any?, forKey key: String) {
        guard enabled, !readOnly else { return }
        if let storageKey {
            var values = defaults.dictionary(forKey: storageKey) ?? [:]
            values[key] = value
            defaults.set(values, forKey: storageKey)
        } else { defaults.set(value, forKey: key) }
    }
}
