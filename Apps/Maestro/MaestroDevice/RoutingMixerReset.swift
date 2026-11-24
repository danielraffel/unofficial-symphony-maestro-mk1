import Foundation

/// The one-time return to the original's defaults when the Input Monitoring
/// setting was removed (0.9.21): Output Routing, Input Routing and both mixers
/// go back to default for every unit, card layout, converter chain and
/// connection ever saved.
///
/// Nothing is converted. Every key of the routing and mixer families is
/// removed, in whatever scope it was saved: the old global keys, the per-unit
/// and per-layout copies, and the migration receipts and markers that hold a
/// snapshot of them. With the sources, the copies and the receipts all gone
/// there is nothing left for a later migration to import, so a unit that
/// connects for the first time long after the update also starts from default.
/// It is the same state as a new install, which every store already handles.
///
/// A converter chain's routing is reset too. Its output grid has the two card
/// mixers as sources (`ConverterRoutingLayout.outputRowSource(row:)`, rows after
/// the playback pairs), so a saved route "Mixer 1 to a converter output" kept
/// across this reset would play a mixer whose strips the reset has just put
/// back to 0 dB, unmuted; and those routes are sent to the card outside the
/// rule that waits for a mixer to be written. The card itself goes back to
/// the default placement the next time Maestro connects to the chain
/// (`AppState.replayConverterRouting(resetFirst:)`).
///
/// Left alone: input and output levels and trims, channel names, device
/// settings (clock, speaker and headphone settings, front panel) and saved
/// presets (a converter chain's routing presets included).
///
/// Defaults follow the original: outputs fed directly from the matching
/// software output and no mixer routed
/// (og_source/maestrolink/Software/SymphonyIOUSBAudioRoutingController.cpp:623-712),
/// strips at 0 dB, centre, unmuted (og_source/maestrolink/Software/SymphonyIOMixer.h:28-33).
public enum RoutingMixerReset {
    public static let versionKey = "routingMixerReset.version"
    /// 1: the reset as first built (early 0.9.21 development builds). 2: converter
    /// routing is part of it, and a USB unit's outputs are written direct
    /// once. An install that ran 1 gets only what 2 added.
    public static let currentVersion = 2

    /// Hardware that may still hold the old state after the saved copy is
    /// gone (a unit that was not power-cycled, a driver that kept running).
    /// Each flag is set by the reset and cleared once the defaults have been
    /// written to that part of the hardware.
    public enum Pending: String, CaseIterable, Sendable {
        case usbInputRouting, usbOutputRouting, thunderboltInputRouting, thunderboltCardMixer
        var key: String { "routingMixerReset.pending.\(rawValue)" }
    }

    public static func isPending(_ item: Pending, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: item.key)
    }

    /// The saved copy is gone but the hardware may still hold the old state:
    /// the next write of that part puts the defaults on it.
    public static func setPending(_ item: Pending, defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: item.key)
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
                           "symphonyCardInputs.", "sim.routing_", "pending.cardOutput."] + converterPrefixes

    /// A converter chain's saved routes (`ConverterRoutingStore.key`, also
    /// the simulation's `converterRouting.sim:`).
    static let converterPrefixes = ["converterRouting."]

    /// What version 2 added to the reset: a converter chain's routes, and
    /// the routing tables kept under a converter layout
    /// (`AppState.unitPreferenceKey`: `conv.<chain>.<category>`,
    /// `converter.<category>`).
    static func isConverterRoutingKey(_ key: String) -> Bool {
        if converterPrefixes.contains(where: key.hasPrefix) { return true }
        guard key.hasPrefix("conv.") || key.hasPrefix("converter."),
              let category = key.split(separator: ".").last else { return false }
        return category.hasPrefix("cardOutput") || category.hasPrefix("inputRouting")
    }

    /// Whether `key` holds routing or mixer state (in any scope).
    public static func isResetKey(_ key: String) -> Bool {
        if exactKeys.contains(key) { return true }
        if prefixes.contains(where: key.hasPrefix) || isConverterRoutingKey(key) { return true }
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
        let ran = defaults.integer(forKey: versionKey)
        guard ran < currentVersion else { return false }
        if ran >= 1 {
            // Version 1 ran here: routing and mixers were reset then and may
            // have been set up again since. Only what version 2 added.
            defaults.set(true, forKey: Pending.usbOutputRouting.key)
            for key in defaults.dictionaryRepresentation().keys where isConverterRoutingKey(key) {
                defaults.removeObject(forKey: key)
            }
            defaults.set(currentVersion, forKey: versionKey)
            return true
        }
        for item in Pending.allCases { defaults.set(true, forKey: item.key) }
        for key in defaults.dictionaryRepresentation().keys where isResetKey(key) {
            defaults.removeObject(forKey: key)
        }
        defaults.set(currentVersion, forKey: versionKey)
        return true
    }
}
