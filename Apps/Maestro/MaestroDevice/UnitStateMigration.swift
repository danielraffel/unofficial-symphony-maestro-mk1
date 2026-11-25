import Foundation

/// A migration commits ownership and its immutable source snapshot together in
/// one preferences value. If interrupted before materializing the destination,
/// the next read finishes that copy. Sources are never removed or modified.
/// Callers select scopes before starting replay; migration never confers hardware
/// provenance (in particular, a copied phantom bit is not permission to power it).
public enum UnitStateMigration {
    /// One ownership decision shared by all stores for a prior layout/port.
    /// The marker's value is the physical UID, not the new category key.
    public static func claim(defaults: UserDefaults = .standard, scope: String, identity: UInt64) -> Bool {
        let key = "unitStateOwner." + scope
        let owner = String(identity, radix: 16)
        if let existing = defaults.string(forKey: key) { return existing == owner }
        defaults.set(owner, forKey: key)
        return true
    }

    public static func copyData(defaults: UserDefaults, source: String,
                                destination: String, owner: String, data: Data?) -> Data? {
        let receiptKey = source + ".migrationReceipt"
        let markerKey = source + ".migratedTo"
        let receipt: [String: Any]
        if let existing = defaults.dictionary(forKey: receiptKey) {
            receipt = existing
        } else {
            guard defaults.string(forKey: markerKey).map({ $0 == owner }) ?? true,
                  let data else { return nil }
            receipt = ["owner": owner, "data": data]
            defaults.set(receipt, forKey: receiptKey)
        }
        guard receipt["owner"] as? String == owner,
              let snapshot = receipt["data"] as? Data else { return nil }
        defaults.set(snapshot, forKey: destination)
        defaults.set(owner, forKey: markerKey)
        return snapshot
    }

    /// Non-channel settings use the same one-owner, source-preserving policy.
    /// Property-list encoding also supports the older string/dictionary stores.
    public static func key(defaults: UserDefaults = .standard, legacy: String,
                           identity: UInt64?, category: String, allowMigration: Bool = true) -> String {
        guard let identity else { return legacy }
        let destination = "unit.v3.\(String(identity, radix: 16)).\(category)"
        return propertyKey(defaults: defaults, legacy: legacy, destination: destination, allowMigration: allowMigration)
    }

    public static func propertyKey(defaults: UserDefaults = .standard, legacy: String,
                                   destination: String, allowMigration: Bool) -> String {
        if allowMigration, defaults.object(forKey: destination) == nil {
            let data = defaults.object(forKey: legacy).flatMap {
                try? PropertyListSerialization.data(fromPropertyList: ["value": $0], format: .binary, options: 0)
            }
            if let snapshot = copyData(defaults: defaults, source: legacy,
                                       destination: destination + ".snapshot", owner: destination, data: data),
               let record = try? PropertyListSerialization.propertyList(from: snapshot, options: [], format: nil) as? [String: Any],
               let value = record["value"] {
                defaults.set(value, forKey: destination)
            }
        }
        return destination
    }
}
