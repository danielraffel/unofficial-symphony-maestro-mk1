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
/// When: the first time a ThunderBridge driver reports (selector 17) a unit
/// whose channels it programmed analog first and whose cards move
/// (`shouldRun`). Not over USB, whose tables were always analog first, and
/// not while an older driver still serves (it can until the ThunderBridge is
/// replugged after an install). A setup whose order does not change leaves
/// the reset waiting for one that does.
///
/// Each direction on its own: a pair's inputs and outputs move separately
/// (`ThunderboltChannelOrder.differs(slot1:slot2:isInput:)`). 8x8 + A16
/// moves only its inputs, so only its input stores go; its Output Routing
/// (routes from the mixers and speaker sets included) is kept and still
/// plays where it did. Run once (`doneKey`), the pass handles both
/// directions of every card pair, connected or not: none of them can have
/// been saved in the new order, since the first such pair to connect under
/// the new driver runs the reset.
///
/// Removed, per direction, for card pairs whose channels move in that
/// direction (the pair is read from each key's card scope). A key without a
/// card scope (a session's pending copy, a scope that does not parse) goes
/// when that direction moved on a unit connected now.
/// - Inputs: Input Routing, unit A and unit B (`unit.v3.<uid>.inputRouting.<scope>`
///   and `inputRouting_multi`, which USB shares for the same unit: its USB
///   input routing goes back to default too); the card's input routes
///   (`symphonyCardInputs.<A>.<B>.<n>.<topology>`, when either unit's
///   inputs move); `pending.<n>.inputRouting`.
/// - Outputs: Output Routing (`cardRouting.v3.<product>.<topology>.<unit>.<scope>`
///   and `_multi`, unit A's and unit B's, every topology; `unit.v3.<uid>.cardOutput.<scope>`,
///   which USB shares); `pending.cardOutput.`.
/// - The legacy keys they were first migrated from (`routing_…`) and their
///   receipts and markers, so `UnitStateMigration` cannot copy the old table
///   back into a destination just removed. A legacy key whose receipt names
///   a destination that stays is kept.
///
/// Left alone: mixers and Software Return (a DAW pair on the card, which the
/// order does not move), speaker and headphone settings, channel names,
/// routing presets (refused when applied, `RoutingPresetChannelOrder`),
/// simulated units and converter chains, and every store of a direction that
/// did not move.
///
/// The hardware, again per direction moved on a unit connected now: inputs
/// set `RoutingMixerReset.Pending.thunderboltInputRouting`, so the next input
/// sync writes the driver's default capture table first and puts the card's
/// input routes back to straight through; outputs: the output restore writes
/// the whole default table from the now empty store.
public enum ChannelOrderRoutingReset {
    public static let doneKey = "channelOrderRoutingReset.analogFirst.v1.done"
    /// Set with `doneKey`; cleared when the user dismisses the Routing
    /// pages' caption, so a quit before visiting Routing does not lose it.
    public static let noticePendingKey = "channelOrderRoutingReset.analogFirst.v1.noticePending"
    /// The notice's text, built from what moved (`noticeText(...)`).
    public static let noticeTextKey = "channelOrderRoutingReset.analogFirst.v1.noticeText"
    /// Set with `doneKey`; cleared when the one-time alert is closed.
    public static let alertPendingKey = "channelOrderRoutingReset.analogFirst.v1.alertPending"

    public static let alertTitle = "Mac channels are now in Apogee's order"

    /// For a pending notice saved without its text (a test build of 0.9.25).
    public static let genericNoticeText = """
        Mac channels on ThunderBridge are now in Apogee's order: all analog first, then digital. \
        Routing whose channels moved was reset to the defaults, on ThunderBridge and USB. Check \
        levels and speakers before playing loud material, and set your routes again if you had \
        changed them.
        """

    /// What one run did.
    public struct Outcome: Sendable, Equatable {
        public var removed: [String]
        /// Inputs / outputs moved on a unit connected now.
        public var inputsMoved: Bool
        public var outputsMoved: Bool
        /// The alert and caption text (`noticeText`).
        public var notice: String
    }

    /// The notice for a reset that moved `inputsMoved` / `outputsMoved` on
    /// the units connected now. `inputExample`: one input that moved, as
    /// `inputExample(units:)` words it.
    public static func noticeText(inputsMoved: Bool, outputsMoved: Bool, inputExample: String? = nil) -> String {
        var parts: [String] = []
        if inputsMoved {
            parts.append("DAW input channels are now in Apogee's order: all analog first, then digital"
                + (inputExample.map { " (for example, \($0))." } ?? "."))
        }
        if outputsMoved {
            parts.append("Some Mac outputs now play on different physical outputs. "
                + "Check levels and speakers before playing loud material.")
        }
        let reset: String
        let presets: String
        switch (inputsMoved, outputsMoved) {
        case (true, true):
            reset = "Input Routing and Output Routing (including routes from the mixers and speaker sets) "
                + "were reset to the defaults, on ThunderBridge and USB."
            presets = "Routing presets"
        case (false, true):
            reset = "Output Routing (including routes from the mixers and speaker sets) was reset to the "
                + "defaults, on ThunderBridge and USB. Input Routing for these cards was kept."
            presets = "Output Routing presets"
        default:
            reset = "Input Routing was reset to the defaults, on ThunderBridge and USB. Output Routing for these cards "
                + "was kept."
            presets = "Input Routing presets"
        }
        parts.append(reset + " Set your routes again if you had changed them.")
        parts.append("\(presets) saved before this update are kept but can't be applied: delete them or save "
            + "them again. Setup files saved before this update load without their routing.")
        return parts.joined(separator: " ")
    }

    /// One input that moved, in words, for the notice: "analog input 1 of
    /// the card in slot 2 is now DAW input 9, was 17". Nil when no unit's
    /// inputs move.
    public static func inputExample(units: [ThunderboltUnitChannelOrder?]) -> String? {
        for (index, unit) in units.enumerated() {
            guard let unit, unit.movesInputs, let slot1 = unit.slot1, let slot2 = unit.slot2,
                  let host = ThunderboltChannelOrder.firstMovedHost(slot1: slot1, slot2: slot2, isInput: true)
            else { continue }
            let order = ThunderboltChannelOrder.analogFirstOrder(slot1: slot1, slot2: slot2, isInput: true)
            guard host < order.count else { continue }
            let channel = order[host]
            let card = channel.board == 0 ? slot1 : slot2
            let analog = card.analogInputChannels
            let what = channel.channel < analog
                ? "analog input \(channel.channel + 1)"
                : "\(card.digitalRoutingLabel) input \(channel.channel - analog + 1)"
            let was = ThunderboltChannelOrder.hostChannels(of: channel, slot1: slot1, slot2: slot2, isInput: true).cardByCard
            // Unit B's channels are Mac 33-64 on the card.
            let unitText = index == 0 ? "" : " on the second Symphony I/O"
            let offset = index == 0 ? 1 : 33
            return "\(what) of the card in slot \(channel.board + 1)\(unitText) is now DAW input \(host + offset)"
                + (was.map { ", was \($0 + offset)" } ?? ", which had no DAW input before")
        }
        return nil
    }

    /// Whether the reset runs now: not run yet, ThunderBridge, and some
    /// unit's channels the driver reported it programmed analog first move
    /// from where card by card put them. Only a driver that answers selector
    /// 17 (build 150 and later) reports analog first; a build known to be
    /// older never runs it.
    public static func shouldRun(transport: TransportType?, serving: ServingDextBuild?,
                                 units: [ThunderboltUnitChannelOrder?],
                                 defaults: UserDefaults = .standard) -> Bool {
        guard !defaults.bool(forKey: doneKey), transport == .thunderbolt else { return false }
        if case .build(let build)? = serving, build != 0,
           build < UInt32(ServingDextBuild.firstAnalogFirstBuild) { return false }
        return units.contains { $0?.movesChannels == true }
    }

    /// Run the reset on `defaults` if `shouldRun`. Nil when it did not run.
    /// The done flag is written last, so an interrupted run runs again.
    @discardableResult
    public static func runIfNeeded(transport: TransportType?, serving: ServingDextBuild?,
                                   units: [ThunderboltUnitChannelOrder?],
                                   defaults: UserDefaults = .standard) -> Outcome? {
        guard shouldRun(transport: transport, serving: serving, units: units, defaults: defaults) else { return nil }
        let inputs = units.contains { $0?.movesInputs == true }
        let outputs = units.contains { $0?.movesOutputs == true }
        let removed = purge(defaults: defaults, unscopedInputs: inputs, unscopedOutputs: outputs)
        let notice = noticeText(inputsMoved: inputs, outputsMoved: outputs, inputExample: inputExample(units: units))
        if inputs { defaults.set(true, forKey: RoutingMixerReset.Pending.thunderboltInputRouting.key) }
        defaults.set(notice, forKey: noticeTextKey)
        defaults.set(true, forKey: noticePendingKey)
        defaults.set(true, forKey: alertPendingKey)
        defaults.set(true, forKey: doneKey)
        return Outcome(removed: removed, inputsMoved: inputs, outputsMoved: outputs, notice: notice)
    }

    /// The caption's text while it has not been dismissed, nil otherwise.
    public static func pendingNotice(defaults: UserDefaults = .standard) -> String? {
        guard defaults.bool(forKey: noticePendingKey) else { return nil }
        return defaults.string(forKey: noticeTextKey) ?? genericNoticeText
    }

    /// The alert's text while it has not been closed, nil otherwise.
    public static func pendingAlert(defaults: UserDefaults = .standard) -> String? {
        guard defaults.bool(forKey: alertPendingKey) else { return nil }
        return defaults.string(forKey: noticeTextKey) ?? genericNoticeText
    }

    /// Remove every saved store of a card pair whose channels move in the
    /// store's direction (see the type's documentation), and quarantine the
    /// legacy sources they came from. `unscopedInputs` / `unscopedOutputs`:
    /// whether stores of that direction without a card scope go too (the
    /// direction moved on a unit connected now).
    @discardableResult
    public static func purge(defaults: UserDefaults = .standard,
                             unscopedInputs: Bool = true, unscopedOutputs: Bool = true) -> [String] {
        let keys = Array(defaults.dictionaryRepresentation().keys)
        var removed: [String] = []
        func stale(_ key: String) -> Bool {
            isStaleKey(key, unscopedInputs: unscopedInputs, unscopedOutputs: unscopedOutputs)
        }
        for key in keys where stale(key) {
            defaults.removeObject(forKey: key)
            removed.append(key)
        }
        // A destination just removed would be filled again from the legacy
        // key it was first migrated from (`UnitStateMigration.propertyKey`
        // copies `<legacy>.migrationReceipt`, or the legacy value itself when
        // no receipt is kept, into any destination that is missing). The
        // legacy routing keys are older than the per-unit stores, so card by
        // card on ThunderBridge: they go too, in both directions, since one
        // without a receipt could fill a store of a pair that moves. A legacy
        // source whose receipt names a destination that stays (one this
        // reset does not remove, judged in that destination's own direction)
        // is that destination's and is kept.
        let removedSet = Set(removed)
        for key in keys where key.hasPrefix("routing_") && !removedSet.contains(key) {
            var source = key
            for suffix in [".migrationReceipt", ".migratedTo"] where source.hasSuffix(suffix) {
                source.removeLast(suffix.count)
            }
            if let receipt = defaults.dictionary(forKey: source + ".migrationReceipt"),
               let owner = receipt["owner"] as? String, !removedSet.contains(owner), !stale(owner) {
                continue
            }
            defaults.removeObject(forKey: key)
            removed.append(key)
        }
        return removed
    }

    /// A routing store's direction and card scopes (nil scopes: none).
    private struct Store {
        var isInput: Bool
        var scopes: [String]?
    }

    private static func store(_ key: String) -> Store? {
        if key.hasPrefix("sim.") || key.hasPrefix("conv.") || key.hasPrefix("converter.") { return nil }
        if key.hasPrefix("pending.cardOutput.") { return Store(isInput: false, scopes: nil) }
        let parts = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if parts.count >= 3, parts[0] == "pending", let isInput = routingDirection(parts[2]) {
            return Store(isInput: isInput, scopes: nil)
        }
        if parts.count >= 5, parts[0] == "unit", parts[1] == "v3", let isInput = routingDirection(parts[3]) {
            return Store(isInput: isInput, scopes: [parts[4]])
        }
        if key.hasPrefix("cardRouting.v3.") {
            // The card scope is the component after the unit (".a." / ".b.").
            guard let unit = parts.lastIndex(where: { $0 == "a" || $0 == "b" }), unit + 1 < parts.count else {
                return Store(isInput: false, scopes: nil)
            }
            return Store(isInput: false, scopes: [parts[unit + 1].replacingOccurrences(of: "_multi", with: "")])
        }
        if key.hasPrefix("symphonyCardInputs.") {
            guard parts.count >= 3, !parts[1].hasPrefix("sim:") else { return nil }
            return Store(isInput: true, scopes: parts[2] == "none" ? [parts[1]] : [parts[1], parts[2]])
        }
        return nil
    }

    /// Whether `key` is a store this reset removes (all unscoped stores
    /// count, as when both directions moved).
    static func isStaleKey(_ key: String) -> Bool {
        isStaleKey(key, unscopedInputs: true, unscopedOutputs: true)
    }

    static func isStaleKey(_ key: String, unscopedInputs: Bool, unscopedOutputs: Bool) -> Bool {
        guard let store = store(key) else { return false }
        let unscoped = store.isInput ? unscopedInputs : unscopedOutputs
        guard let scopes = store.scopes else { return unscoped }
        return scopes.contains { scope in
            scopeMoves(scope, isInput: store.isInput) ?? unscoped
        }
    }

    /// True for an input routing category, false for an output one, nil
    /// for anything else.
    private static func routingDirection(_ category: String) -> Bool? {
        if category.hasPrefix("inputRouting") { return true }
        if category.hasPrefix("cardOutput") { return false }
        return nil
    }

    /// Whether a card scope (`CardLayout.savedStateScope`, "<slot1>+<slot2>"
    /// by case name) is a pair whose inputs (`isInput`) or outputs move; nil
    /// for a scope that does not parse ("unknown").
    static func scopeMoves(_ scope: String, isInput: Bool) -> Bool? {
        let names = scope.split(separator: "+").map(String.init)
        guard names.count == 2,
              let slot1 = IOCardType.allCases.first(where: { $0.caseName == names[0] }),
              let slot2 = IOCardType.allCases.first(where: { $0.caseName == names[1] }) else { return nil }
        return ThunderboltChannelOrder.differs(slot1: slot1, slot2: slot2, isInput: isInput)
    }
}
