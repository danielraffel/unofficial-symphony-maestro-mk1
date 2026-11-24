import Foundation
import MaestroCore

/// The one-time routing reset for the analog-first channel order (0.9.25,
/// ThunderBridge driver build 150).
///
/// Driver 150 lays a unit's host channels out analog first, as Apogee's
/// original did (`ThunderboltChannelOrder.analogFirst`); 149 and earlier laid
/// them out card by card. For some card pairs that moves a unit's channels to
/// other Mac channel numbers (`ThunderboltChannelOrder.differs`). Everything
/// Maestro saved for those pairs is indexed by the old numbers: Input Routing
/// rows (Mac input pairs), Output Routing tables (whose defaults and XLink
/// channels were by position), the card's own input routes (host channel to
/// card RX slot). Nothing is converted (Daniel: no migrations of saved data):
/// those stores are removed once and the unit goes back to the defaults of
/// the new order, the state of a new install.
///
/// When: the first time a ThunderBridge driver serving build 150 or later (or
/// an unstamped local build of that code, 0) reports a unit whose channels it
/// programmed analog first and whose cards move (`shouldRun`). Not over USB,
/// whose tables were always analog first, and not while an older driver still
/// serves (it can until the ThunderBridge is replugged after an install). A
/// setup whose order does not change leaves the reset waiting for one that
/// does. Run once (`doneKey`), it removes the stores of every card pair that
/// moves, for every unit and topology, connected or not: none of them can
/// have been saved in the new order, since the first such pair to connect
/// under the new driver runs the reset.
///
/// Removed, for card pairs that move (the pair is read from each key's card
/// scope; a key without one, a session's pending copy or a pre-identity
/// legacy key, is removed too):
/// - Input Routing, unit A and unit B (`unit.v3.<uid>.inputRouting.<scope>`
///   and `inputRouting_multi`, which USB shares for the same unit: its USB
///   input routing goes back to default too).
/// - Output Routing (`cardRouting.v3.<product>.<topology>.<unit>.<scope>` and
///   `_multi`), unit A's and unit B's, every topology.
/// - The card's input routes (`symphonyCardInputs.<A>.<B>.<n>.<topology>`).
/// - Every session's pending copies (`pending.cardOutput.`, `pending.<n>.inputRouting`).
/// - The legacy keys they were first migrated from (`routing_…`) and their
///   receipts and markers, so `UnitStateMigration` cannot copy the old table
///   back into a destination just removed.
///
/// Left alone: mixers and Software Return (a DAW pair on the card, which the
/// order does not move), speaker and headphone settings, channel names,
/// routing presets (refused when applied, `RoutingPresetChannelOrder`),
/// simulated units and converter chains.
///
/// The hardware: `RoutingMixerReset.Pending.thunderboltInputRouting` is set,
/// so the next input sync writes the driver's default capture table first and
/// puts the card's input routes back to straight through; the output restore
/// writes the whole default table from the now empty store.
public enum ChannelOrderRoutingReset {
    public static let doneKey = "channelOrderRoutingReset.analogFirst.v1.done"
    /// Set with `doneKey`; cleared when the user dismisses the notice, so a
    /// quit before visiting Routing does not lose it.
    public static let noticePendingKey = "channelOrderRoutingReset.analogFirst.v1.noticePending"

    public static let noticeText = """
        Routing was reset to the defaults because Mac channels are now in Apogee's order: all analog \
        inputs and outputs first, then digital. Some Mac outputs now play on different physical \
        outputs: check your levels and speakers before playing loud material. Set your routes again \
        if you had changed them; routing presets saved before this update can't be applied and can be \
        deleted or saved again.
        """

    /// Whether the reset runs now: not run yet, ThunderBridge, a driver of
    /// build 150 or later (or 0) serving, and some unit's channels the driver
    /// programmed analog first move from where card by card put them.
    public static func shouldRun(transport: TransportType?, serving: ServingDextBuild?,
                                 units: [ThunderboltUnitChannelOrder?],
                                 defaults: UserDefaults = .standard) -> Bool {
        guard !defaults.bool(forKey: doneKey), transport == .thunderbolt,
              ThunderboltChannelOrder.serving(serving) == .analogFirst else { return false }
        return units.contains { $0?.movesChannels == true }
    }

    /// Run the reset on `defaults` if `shouldRun`. Returns the keys removed,
    /// nil when it did not run. The done flag is written last, so an
    /// interrupted run runs again.
    @discardableResult
    public static func runIfNeeded(transport: TransportType?, serving: ServingDextBuild?,
                                   units: [ThunderboltUnitChannelOrder?],
                                   defaults: UserDefaults = .standard) -> [String]? {
        guard shouldRun(transport: transport, serving: serving, units: units, defaults: defaults) else { return nil }
        let removed = purge(defaults: defaults)
        defaults.set(true, forKey: RoutingMixerReset.Pending.thunderboltInputRouting.key)
        defaults.set(true, forKey: noticePendingKey)
        defaults.set(true, forKey: doneKey)
        return removed
    }

    /// Remove every saved store of a card pair that moves (see the type's
    /// documentation), and quarantine the legacy sources they came from.
    @discardableResult
    public static func purge(defaults: UserDefaults = .standard) -> [String] {
        let keys = Array(defaults.dictionaryRepresentation().keys)
        var removed: [String] = []
        for key in keys where isStaleKey(key) {
            defaults.removeObject(forKey: key)
            removed.append(key)
        }
        // A destination just removed would be filled again from the legacy
        // key it was first migrated from (`UnitStateMigration.propertyKey`
        // copies `<legacy>.migrationReceipt`, or the legacy value itself when
        // no receipt is kept). The legacy routing keys are older than the
        // per-unit stores, so card by card on ThunderBridge: they go too.
        // A legacy source whose receipt names a destination that stays (one
        // this reset does not remove) is that destination's and is kept.
        let removedSet = Set(removed)
        for key in keys where key.hasPrefix("routing_") && !removedSet.contains(key) {
            var source = key
            for suffix in [".migrationReceipt", ".migratedTo"] where source.hasSuffix(suffix) {
                source.removeLast(suffix.count)
            }
            if let receipt = defaults.dictionary(forKey: source + ".migrationReceipt"),
               let owner = receipt["owner"] as? String, !removedSet.contains(owner), !isStaleKey(owner) {
                continue
            }
            defaults.removeObject(forKey: key)
            removed.append(key)
        }
        return removed
    }

    /// Whether `key` is a store this reset removes.
    static func isStaleKey(_ key: String) -> Bool {
        if key.hasPrefix("sim.") || key.hasPrefix("conv.") || key.hasPrefix("converter.") { return false }
        if key.hasPrefix("pending.cardOutput.") { return true }
        let parts = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if parts.count >= 3, parts[0] == "pending", isRoutingCategory(parts[2]) { return true }
        if parts.count >= 5, parts[0] == "unit", parts[1] == "v3", isRoutingCategory(parts[3]) {
            return scopeMoves(parts[4])
        }
        if key.hasPrefix("cardRouting.v3.") {
            // The card scope is the component after the unit (".a." / ".b.").
            guard let unit = parts.lastIndex(where: { $0 == "a" || $0 == "b" }), unit + 1 < parts.count else {
                return true
            }
            return scopeMoves(parts[unit + 1].replacingOccurrences(of: "_multi", with: ""))
        }
        if key.hasPrefix("symphonyCardInputs.") {
            guard parts.count >= 3, !parts[1].hasPrefix("sim:") else { return false }
            return scopeMoves(parts[1]) || (parts[2] != "none" && scopeMoves(parts[2]))
        }
        return false
    }

    private static func isRoutingCategory(_ category: String) -> Bool {
        category.hasPrefix("inputRouting") || category.hasPrefix("cardOutput")
    }

    /// Whether a card scope (`CardLayout.savedStateScope`, "<slot1>+<slot2>"
    /// by case name) is a pair whose channels move; true for a scope that
    /// does not parse ("unknown"), whose store cannot be trusted either way.
    static func scopeMoves(_ scope: String) -> Bool {
        let names = scope.split(separator: "+").map(String.init)
        guard names.count == 2,
              let slot1 = IOCardType.allCases.first(where: { $0.caseName == names[0] }),
              let slot2 = IOCardType.allCases.first(where: { $0.caseName == names[1] }) else { return true }
        return ThunderboltChannelOrder.differs(slot1: slot1, slot2: slot2)
    }
}
