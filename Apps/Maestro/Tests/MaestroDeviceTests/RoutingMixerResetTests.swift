import Foundation
import Testing
import MaestroCore
@testable import MaestroDevice

/// The one-time reset of 0.9.21: Output Routing, Input Routing and both
/// mixers back to default for every unit and layout; everything else kept.
@Suite("Routing and mixer reset (one time)")
struct RoutingMixerResetTests {
    private let layout = CardLayout(slot1: .optical, slot2: .analogAD16)
    private let other = CardLayout(slot1: .analogADDA16, slot2: .none)

    private func suite() -> (UserDefaults, () -> Void) {
        let name = "RoutingMixerResetTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (defaults, { defaults.removePersistentDomain(forName: name) })
    }

    private let strip = MixerChannelState(level: -20, pan: 0.5, isMuted: true, isSoloed: true)

    /// A 0.9.18 install: old global keys, two identified units (one of them
    /// unit B) with their own copies made by migration, and saved routing.
    private func seedOldInstall(_ defaults: UserDefaults) throws {
        // Old global keys.
        defaults.set(0, forKey: "routingMode")
        defaults.set(-12.0, forKey: "mixerMasterLevel_0")
        defaults.set(-9.0, forKey: "mixerSWReturnLeftLevel_0")
        defaults.set(3, forKey: "mixerSoftwareReturnSource_1")
        defaults.set(try JSONEncoder().encode(strip), forKey: "mixerState_swReturn")
        defaults.set(try JSONEncoder().encode([strip, strip]), forKey: "mixerState_0")
        defaults.set(["0": [2]], forKey: "routing_output_18_v2_multi")
        defaults.set(["1": 3], forKey: "routing_input_18_v2")
        defaults.set(true, forKey: "thunderboltMainPairMixerMigration_v1")
        // Unit A (identity 0xA1) migrates them into its own scope, receipts and all.
        let a = ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: false, identity: 0xA1)
        #expect(a.mixerPreferences.object(forKey: "mixerMasterLevel_0") as? Double == -12)
        #expect((a.load(ChannelStateStore.mixerKey(0)) as [MixerChannelState]?)?.count == 2)
        a.mixerPreferences.set(1, forKey: "routingMode")
        // A second unit and unit B with state of their own.
        let second = ChannelStateStore(defaults: defaults, layout: other, isSimulatingCards: false, identity: 0xA2,
                                       allowLegacyMigration: false)
        second.save([strip], for: ChannelStateStore.mixerKey(1))
        second.mixerPreferences.set(-30.0, forKey: "mixerMasterLevel_1")
        let b = ChannelStateStore(defaults: defaults, layout: other, isSimulatingCards: false, unit: .b, identity: 0xB1)
        b.save([strip], for: ChannelStateStore.mixerKey(0))
        b.mixerPreferences.set(-6.0, forKey: "mixerMasterLevel_0")
        // Per-unit routing, as AppState keys it, with a migration receipt of the global table.
        let cardKey = UnitStateMigration.propertyKey(
            defaults: defaults, legacy: "routing_output_18_v2_multi",
            destination: "cardRouting.v3.18.a=a1.b=none.channels=32.a.\(layout.savedStateScope ?? "x")_multi",
            allowMigration: true)
        #expect(defaults.dictionary(forKey: cardKey) != nil)
        let inputKey = UnitStateMigration.key(defaults: defaults, legacy: "routing_input_18_v2", identity: 0xA1,
                                              category: "inputRouting.\(layout.savedStateScope ?? "x")")
        #expect(defaults.dictionary(forKey: inputKey) != nil)
        defaults.set(["4": [1]], forKey: "unit.v3.a2.cardOutput_multi.\(other.savedStateScope ?? "x")")
        SymphonyCardInputStore(scope: "a1", defaults: defaults).save([0: 5])
    }

    /// What the reset must not touch.
    private func seedKept(_ defaults: UserDefaults) -> [String: NSObject] {
        var input = InputChannelState(); input.gain = 21
        var output = OutputChannelState(); output.trim = -3
        for (store, _) in [(ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: false, identity: 0xA1), 0)] {
            store.save([input], for: ChannelStateStore.inputKey)
            store.save([output], for: ChannelStateStore.outputKey)
        }
        defaults.set(try! JSONEncoder().encode([input]), forKey: ChannelStateStore.inputKey)
        defaults.set("[\"Kick\",\"Snare\"]", forKey: "mixerChannelNames")
        defaults.set("[\"Vox\"]", forKey: "unit.v3.a1.mixerChannelNames.\(layout.savedStateScope ?? "x")")
        defaults.set(Data([1, 2, 3]), forKey: "outputRoutingPresets")
        defaults.set(Data([4]), forKey: "outputRoutingPresets.twoUnit.unitB")
        defaults.set(Data([5]), forKey: "mixerPresets")
        defaults.set("a1", forKey: "unitStateOwner.unitA.\(layout.savedStateScope ?? "x")")
        // Device settings: speaker mode, headphone sources, front panel (clock is read from the unit).
        let settings = DeviceSettingsStore(defaults: defaults, productID: 18, identity: 0xA1)
        settings.record(.uint32(3), for: PropertyAddress(selector: .speakerOutputMode))
        settings.record(.uint32(1), for: PropertyAddress(selector: .frontPanelMeterBank))
        defaults.set(96000.0, forKey: "lastSampleRate")
        var kept: [String: NSObject] = [:]
        for (key, value) in defaults.dictionaryRepresentation() where !RoutingMixerReset.isResetKey(key) {
            kept[key] = value as? NSObject
        }
        return kept
    }

    @Test("after the reset every unit, layout and connection reads the defaults")
    func defaultsAfterReset() throws {
        let (defaults, done) = suite(); defer { done() }
        try seedOldInstall(defaults)
        #expect(RoutingMixerReset.runIfNeeded(defaults: defaults))
        // Not one routing or mixer key is left, in any scope.
        #expect(defaults.dictionaryRepresentation().keys.filter(RoutingMixerReset.isResetKey).isEmpty)

        let unity = MixerChannelState(level: 0, pan: 0, isMuted: false, isSoloed: false)
        let stores = [
            ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: false, identity: 0xA1),
            ChannelStateStore(defaults: defaults, layout: other, isSimulatingCards: false, identity: 0xA2),
            ChannelStateStore(defaults: defaults, layout: other, isSimulatingCards: false, unit: .b, identity: 0xB1),
            // A unit never seen before, an unidentified one, and one still awaiting its identity.
            ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: false, identity: 0xC3),
            ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: false),
        ]
        for store in stores {
            for mixer in 0..<2 {
                #expect(store.loadData(ChannelStateStore.mixerKey(mixer)) == nil)
                let snapshot = MixerStateSnapshot(channelCount: 4, mixer: mixer, store: store, defaults: defaults)
                // Strips 0 dB, centre, unmuted, no solo (SymphonyIOMixer.h:28-33).
                #expect(snapshot.channels == Array(repeating: unity, count: 4))
                #expect(snapshot.swReturnChannel == unity)
                #expect(snapshot.swReturnLeftLevel == 0 && snapshot.swReturnRightLevel == 0)
                #expect(snapshot.softwareReturnSource == 0)
                #expect(snapshot.masterLevel == 0)
            }
            #expect(store.mixerPreferences.object(forKey: "routingMode") == nil)
            // Nothing saved means the USB restore is the unit's own defaults, the helper neutral.
            let usb = USBMixerSavedState.load(preferences: store.mixerPreferences)
            #expect(usb.mixes.allSatisfy { $0.masterLevel == 0 && $0.softwareReturnLeft == 0
                && $0.softwareReturnSource == 0 && !$0.softwareReturn.isMuted && !$0.softwareReturn.isSoloed })
            #expect(usb.helper(routedToOutput: [false, false]) == .neutral)
        }
        // Routing: no saved table in any scope, so the default (direct) table stands.
        #expect(defaults.object(forKey: "routingMode") == nil)
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix("routing_") || key.hasPrefix("cardRouting.") {
            Issue.record("routing state came back: \(key) = \(value)")
        }
        #expect(SymphonyCardInputStore(scope: "a1", defaults: defaults).load().isEmpty)
        // The hardware may still hold the old state: each part is flagged for a default push.
        for item in RoutingMixerReset.Pending.allCases {
            #expect(RoutingMixerReset.isPending(item, defaults: defaults))
            RoutingMixerReset.clearPending(item, defaults: defaults)
            #expect(!RoutingMixerReset.isPending(item, defaults: defaults))
        }
    }

    @Test("old global keys and migration receipts cannot bring the state back later")
    func nothingIsReimported() throws {
        let (defaults, done) = suite(); defer { done() }
        try seedOldInstall(defaults)
        // The receipts hold a full copy of the old state; they must go too.
        #expect(defaults.dictionary(forKey: "mixerWideState.migrationReceipt") != nil)
        #expect(defaults.dictionary(forKey: "routing_output_18_v2_multi.migrationReceipt") != nil)
        RoutingMixerReset.runIfNeeded(defaults: defaults)
        #expect(defaults.dictionary(forKey: "mixerWideState.migrationReceipt") == nil)
        #expect(defaults.string(forKey: "mixerWideState.migratedTo") == nil)

        // A unit that connects for the first time after the reset, allowed to migrate.
        let late = ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: false, identity: 0xD4)
        #expect(late.mixerPreferences.object(forKey: "mixerMasterLevel_0") == nil)
        #expect(late.mixerPreferences.object(forKey: "mixerSoftwareReturnSource_1") == nil)
        #expect((late.load(ChannelStateStore.mixerKey(0)) as [MixerChannelState]?) == nil)
        // The unit that owned the old state, reconnecting: its scoped copy is gone and nothing refills it.
        let owner = ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: false, identity: 0xA1)
        #expect(owner.mixerPreferences.object(forKey: "mixerMasterLevel_0") == nil)
        #expect((owner.load(ChannelStateStore.mixerKey(0)) as [MixerChannelState]?) == nil)
        // Routing: a fresh per-unit key migrates nothing, for the old owner or a new unit.
        for identity in ["a1", "d4"] {
            let key = UnitStateMigration.propertyKey(
                defaults: defaults, legacy: "routing_output_18_v2_multi",
                destination: "cardRouting.v3.18.a=\(identity).b=none.channels=32.a.\(layout.savedStateScope ?? "x")_multi",
                allowMigration: true)
            #expect(defaults.object(forKey: key) == nil)
        }
        let input = UnitStateMigration.key(defaults: defaults, legacy: "routing_input_18_v2", identity: 0xA1,
                                           category: "inputRouting.\(layout.savedStateScope ?? "x")")
        #expect(defaults.object(forKey: input) == nil)

        // State written after the reset is kept, and still migrates as on a new install.
        late.mixerPreferences.set(-5.0, forKey: "mixerMasterLevel_0")
        late.save([strip], for: ChannelStateStore.mixerKey(0))
        #expect(!RoutingMixerReset.runIfNeeded(defaults: defaults))
        #expect(late.mixerPreferences.object(forKey: "mixerMasterLevel_0") as? Double == -5)
        #expect((late.load(ChannelStateStore.mixerKey(0)) as [MixerChannelState]?) == [strip])
    }

    @Test("it runs once per install, and again only if it was interrupted")
    func runsOnce() throws {
        let (defaults, done) = suite(); defer { done() }
        try seedOldInstall(defaults)
        #expect(RoutingMixerReset.runIfNeeded(defaults: defaults))
        #expect(defaults.integer(forKey: RoutingMixerReset.versionKey) == RoutingMixerReset.currentVersion)
        // State saved afterwards survives every later launch.
        defaults.set(-4.0, forKey: "mixerMasterLevel_0")
        defaults.set(["0": [1]], forKey: "routing_output_18_v2_multi")
        for _ in 0..<3 { #expect(!RoutingMixerReset.runIfNeeded(defaults: defaults)) }
        #expect(defaults.object(forKey: "mixerMasterLevel_0") as? Double == -4)
        #expect(defaults.dictionary(forKey: "routing_output_18_v2_multi") != nil)

        // Interrupted before the marker was written: the next launch finishes it.
        let (crashed, doneCrashed) = suite(); defer { doneCrashed() }
        try seedOldInstall(crashed)
        crashed.removeObject(forKey: "mixerState_0")          // some keys already gone
        crashed.set(true, forKey: "routingMixerReset.pending.usbInputRouting")
        #expect(crashed.object(forKey: RoutingMixerReset.versionKey) == nil)
        #expect(RoutingMixerReset.runIfNeeded(defaults: crashed))
        #expect(crashed.dictionaryRepresentation().keys.filter(RoutingMixerReset.isResetKey).isEmpty)

        // A new install: nothing to remove, marker written, never runs again.
        let (fresh, doneFresh) = suite(); defer { doneFresh() }
        #expect(RoutingMixerReset.runIfNeeded(defaults: fresh))
        #expect(!RoutingMixerReset.runIfNeeded(defaults: fresh))
    }

    @Test("levels, trims, names, device settings and presets are untouched")
    func untouched() throws {
        let (defaults, done) = suite(); defer { done() }
        try seedOldInstall(defaults)
        let kept = seedKept(defaults)
        #expect(kept.count >= 12)
        RoutingMixerReset.runIfNeeded(defaults: defaults)
        for (key, value) in kept {
            #expect(defaults.object(forKey: key) as? NSObject == value, "\(key) changed")
        }
        let store = ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: false, identity: 0xA1)
        #expect((store.load(ChannelStateStore.inputKey) as [InputChannelState]?)?.first?.gain == 21)
        #expect((store.load(ChannelStateStore.outputKey) as [OutputChannelState]?)?.first?.trim == -3)
        let settings = DeviceSettingsStore(defaults: defaults, productID: 18, identity: 0xA1)
        #expect(settings.value(for: PropertyAddress(selector: .speakerOutputMode)) == .uint32(3))
        #expect(settings.value(for: PropertyAddress(selector: .frontPanelMeterBank)) == .uint32(1))
    }

    @Test("a converter chain's saved routes, a card mixer on a converter output included, are reset; its routing presets are kept")
    func converterRouting() throws {
        let (defaults, cleanup) = suite()
        defer { cleanup() }
        let signature = "ad16x+da16x"
        let store = ConverterRoutingStore(signature: signature, defaults: defaults)
        // Mixer 1 on the chain's first output pair, and an input route.
        var edits = ConverterRoutingEdits()
        edits.outputs[0] = ConverterRouting.mixerSource(mixer: 0, side: 0)
        edits.outputs[1] = ConverterRouting.mixerSource(mixer: 0, side: 1)
        edits.inputs[4] = 6
        store.save(edits)
        store.savePreset(name: "Tracking", input: false, routes: [0: ConverterRouting.mixerSource(mixer: 1, side: 0)])
        #expect(!store.load().isEmpty)
        #expect(RoutingMixerReset.runIfNeeded(defaults: defaults))
        #expect(store.load().isEmpty)
        #expect(defaults.object(forKey: store.key) == nil)
        #expect(store.presetNames(input: false) == ["Tracking"])
    }

    @Test("an install that ran the first version of the reset gets only what was added: converter routes and the USB output flag")
    func upgradeFromVersion1() throws {
        let (defaults, cleanup) = suite()
        defer { cleanup() }
        defaults.set(1, forKey: RoutingMixerReset.versionKey)
        // Set up again after the first reset: kept.
        defaults.set(["x": 1], forKey: "routing_output_18_v2_multi")
        defaults.set(Data([1]), forKey: "mixerState_0")
        let store = ConverterRoutingStore(signature: "ad16x", defaults: defaults)
        var edits = ConverterRoutingEdits()
        edits.outputs[0] = ConverterRouting.mixerSource(mixer: 0, side: 0)
        store.save(edits)
        #expect(RoutingMixerReset.runIfNeeded(defaults: defaults))
        #expect(defaults.integer(forKey: RoutingMixerReset.versionKey) == RoutingMixerReset.currentVersion)
        #expect(store.load().isEmpty)
        #expect(defaults.object(forKey: "routing_output_18_v2_multi") != nil)
        #expect(defaults.object(forKey: "mixerState_0") != nil)
        #expect(RoutingMixerReset.isPending(.usbOutputRouting, defaults: defaults))
        #expect(!RoutingMixerReset.isPending(.usbInputRouting, defaults: defaults))
        #expect(!RoutingMixerReset.isPending(.thunderboltCardMixer, defaults: defaults))
        #expect(!RoutingMixerReset.runIfNeeded(defaults: defaults))
    }

    @Test("only routing and mixer keys are in scope")
    func keyFamilies() {
        for key in ["routingMode", "mixerState_0", "mixerState_1.unit:v3:a1:8x8", "mixerState_0.claimedBy",
                    "mixerState_0.8x8.migratedTo", "mixerState_0.8x8.migrationReceipt", "mixerState_swReturn_1",
                    "mixerWideState.unit:v3:a1", "mixerWideState.unit:v3:a1.snapshot", "mixerWideState.migratedTo",
                    "mixerWideState.migrationReceipt", "mixerMasterLevel_1", "mixerSWReturnRightLevel_0",
                    "mixerSoftwareReturnSource_0", "mixerMasterFadersLinked",
                    "routing_output_18_v2", "routing_output_18_v2_multi", "routing_input_16_v2.migratedTo",
                    "routing_output.unitB.8x8_18_v2_multi", "routing_output_18_v2_multi.migrationReceipt",
                    "cardRouting.v3.18.a=a1.b=none.channels=32.a.8x8", "cardRouting.v3.18.a=a1.b=b1.channels=64.b.8x8_multi.snapshot",
                    "unit.v3.a1.inputRouting.8x8", "unit.v3.a1.cardOutput_multi.8x8.snapshot",
                    "pending.cardOutput.a=pending.b=none.channels=32.a", "pending.6F9619FF.inputRouting",
                    "sim.routing_output_18_v2_multi", "symphonyCardInputs.a1", "thunderboltMainPairMixerMigration_v1",
                    // A converter chain's routes (its output grid has the card mixers as sources).
                    "converterRouting.ad16x+da16x", "converterRouting.sim:ad16x", "conv.ad16x.cardOutput",
                    "conv.ad16x.inputRouting_multi", "converter.cardOutput"] {
            #expect(RoutingMixerReset.isResetKey(key), "\(key) should be reset")
        }
        for key in ["inputChannelStates", "outputChannelStates.unit:v3:a1:8x8", "inputChannelStates.claimedBy",
                    "mixerChannelNames", "unit.v3.a1.mixerChannelNames.8x8", "mixerPresets", "outputRoutingPresets",
                    "outputRoutingPresets.twoUnit.unitB", "outputRoutingPresets.unitB", "deviceSettings_18_v1",
                    "deviceSettings_18_identity_v3_a1", "unitStateOwner.unitA.8x8", "lastSelectedMixer",
                    "conv.ad16x.mixerChannelNames", "converter.digital", "routingMixerReset.version",
                    "converterOutputRoutingPresets.ad16x", "converterInputRoutingPresets.ad16x",
                    "routingMixerReset.pending.usbInputRouting", "unit.v3.a1.digital.8x8", "pending.6F9619FF.mixerChannelNames"] {
            #expect(!RoutingMixerReset.isResetKey(key), "\(key) should be kept")
        }
    }
}
