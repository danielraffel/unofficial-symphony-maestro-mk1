import Foundation

/// The one-time return to the original's defaults when the Input Monitoring
/// setting was removed (0.9.19): Output Routing, Input Routing and both mixers
/// go back to default for every unit, card layout and connection ever saved.
///
/// Nothing is converted. Every key of the routing and mixer families is
/// removed, in whatever scope it was saved: the old global keys, the per-unit
/// and per-layout copies, and the migration receipts and markers that hold a
/// snapshot of them. With the sources, the copies and the receipts all gone
/// there is nothing left for a later migration to import, so a unit that
/// connects for the first time long after the update also starts from default.
/// It is the same state as a new install, which every store already handles.
///
/// Left alone: input and output levels and trims, channel names, device
/// settings (clock, speaker and headphone settings, front panel), saved
/// presets, and a converter chain's own routing.
///
/// Defaults follow the original: outputs fed directly from the matching
/// software output and no mixer routed
/// (og_source/maestrolink/Software/SymphonyIOUSBAudioRoutingController.cpp:623-712),
/// strips at 0 dB, centre, unmuted (og_source/maestrolink/Software/SymphonyIOMixer.h:28-33).
public enum RoutingMixerReset {
    public static let versionKey = "routingMixerReset.version"
    public static let currentVersion = 1

    /// Hardware that may still hold the old state after the saved copy is
    /// gone (a unit that was not power-cycled, a driver that kept running).
    /// Each flag is set by the reset and cleared once the defaults have been
    /// written to that part of the hardware.
    public enum Pending: String, CaseIterable, Sendable {
        case usbInputRouting, thunderboltInputRouting, thunderboltCardMixer
        var key: String { "routingMixerReset.pending.\(rawValue)" }
    }

    public static func isPending(_ item: Pending, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: item.key)
    }

    public static func clearPending(_ item: Pending, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: item.key)
    }

    /// Old global keys with no shared prefix.
    static let exactKeys: Set<String> = Set(MixerPreferences.legacyKeys
        + ["routingMode", "thunderboltMainPairMixerMigration_v1"])

    /// Every scope, copy, receipt and marker of these families starts with one
    /// of these: mixer strips and Software Return (`mixerState_`), Master,
    /// return level and source (`mixerWideState.`), the routing tables as first
    /// saved (`routing_`), per-unit card output routes (`cardRouting.`), card
    /// input routes (`symphonyCardInputs.`), and simulated units.
    static let prefixes = ["mixerState_", "mixerWideState.", "routing_", "cardRouting.",
                           "symphonyCardInputs.", "sim.routing_", "pending.cardOutput."]

    /// Whether `key` holds routing or mixer state (in any scope).
    public static func isResetKey(_ key: String) -> Bool {
        if exactKeys.contains(key) { return true }
        if prefixes.contains(where: key.hasPrefix) { return true }
        // unit.v3.<uid>.<category>.<layout> and pending.<session>.<category>
        // (AppState.unitPreferenceKey): only the routing categories.
        let parts = key.split(separator: ".", omittingEmptySubsequences: false)
        let category: Substring?
        if parts.count >= 4, parts[0] == "unit", parts[1] == "v3" { category = parts[3] }
        else if parts.count >= 3, parts[0] == "pending" { category = parts[2] }
        else { category = nil }
        guard let category else { return false }
        return category.hasPrefix("cardOutput") || category.hasPrefix("inputRouting")
    }

    /// Run the reset if this install has not run it. Returns whether it ran.
    ///
    /// Safe if interrupted: removing a key twice is harmless, and the version
    /// marker is written last, so an interrupted run is simply run again.
    /// Must be called before anything reads saved routing or mixer state.
    @discardableResult
    public static func runIfNeeded(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.integer(forKey: versionKey) < currentVersion else { return false }
        for item in Pending.allCases { defaults.set(true, forKey: item.key) }
        for key in defaults.dictionaryRepresentation().keys where isResetKey(key) {
            defaults.removeObject(forKey: key)
        }
        defaults.set(currentVersion, forKey: versionKey)
        return true
    }
}
