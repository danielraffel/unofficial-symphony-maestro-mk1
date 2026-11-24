import Foundation
import MaestroCore

/// Which host channel order a named routing preset was saved in.
///
/// Routing presets (Input Routing, Output Routing, the two-unit card input
/// grid) are indexed by Mac channel. A preset saved while a ThunderBridge
/// driver laid the channels out card by card (build 149 and earlier, every
/// preset saved before 0.9.25) means other channels once the driver lays them
/// out analog first, where the cards move. Nothing is converted or deleted
/// (Daniel: no migrations; the user deletes or saves them again): such a
/// preset stays in the list, marked, and is refused when applied, but only
/// while the order it would be applied in is analog first and moves this
/// unit's channels. Otherwise it applies as before.
///
/// The order is kept beside the presets, per preset key, so the stored
/// presets themselves are not rewritten: `routingPresetChannelOrder.<key>`
/// = [name: "analogFirst" | "cardByCard"]. A name without an entry was saved
/// card by card (before the marker existed).
public enum RoutingPresetChannelOrder {
    public static let staleSuffix = " (old channel order)"

    public static let refusalMessage = "This routing preset was saved before Mac channels were in Apogee's order "
        + "(all analog first, then digital), so it can't be applied. Delete it, or set the routing again and "
        + "save it under the same name."

    static func markerKey(_ presetKey: String) -> String { "routingPresetChannelOrder." + presetKey }

    /// The order a connection's routing is in, for marking a save: ThunderBridge
    /// the driver's (`current`, card by card while not known); USB analog
    /// first, as its tables always were.
    public static func savingOrder(transport: TransportType?, current: ThunderboltUnitChannelOrder?) -> ThunderboltChannelOrder {
        transport == .thunderbolt ? (current?.order ?? .cardByCard) : .analogFirst
    }

    /// Record the order `name` was saved in under `presetKey`.
    public static func mark(name: String, presetKey: String, order: ThunderboltChannelOrder,
                            defaults: UserDefaults = .standard) {
        var marks = defaults.dictionary(forKey: markerKey(presetKey)) as? [String: String] ?? [:]
        marks[name] = ThunderboltPreset.channelOrderTag(order)
        defaults.set(marks, forKey: markerKey(presetKey))
    }

    /// Forget `name`'s order (it was deleted).
    public static func unmark(name: String, presetKey: String, defaults: UserDefaults = .standard) {
        var marks = defaults.dictionary(forKey: markerKey(presetKey)) as? [String: String] ?? [:]
        guard marks.removeValue(forKey: name) != nil else { return }
        defaults.set(marks, forKey: markerKey(presetKey))
    }

    /// The order `name` was saved in; card by card without a marker.
    public static func order(name: String, presetKey: String, defaults: UserDefaults = .standard) -> ThunderboltChannelOrder {
        let marks = defaults.dictionary(forKey: markerKey(presetKey)) as? [String: String] ?? [:]
        return marks[name] == "analogFirst" ? .analogFirst : .cardByCard
    }

    /// Whether `name` must be refused (and is shown marked): it was not saved
    /// analog first and one of `current` (the units it would be applied to,
    /// nil entries ignored) is laid out analog first with channels that move.
    public static func isStale(name: String, presetKey: String, current: [ThunderboltUnitChannelOrder?],
                               defaults: UserDefaults = .standard) -> Bool {
        guard current.contains(where: { $0?.movesChannels == true }) else { return false }
        return order(name: name, presetKey: presetKey, defaults: defaults) != .analogFirst
    }

    /// The menu line for a preset.
    public static func label(_ displayName: String, stale: Bool) -> String {
        stale ? displayName + staleSuffix : displayName
    }
}
