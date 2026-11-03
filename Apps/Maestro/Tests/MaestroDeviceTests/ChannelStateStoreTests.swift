import Testing
import Foundation
@testable import MaestroDevice
import MaestroCore

/// Per-channel saved state is keyed by the installed card pair, so a module
/// swap (or the card-simulation harness) no longer restores one unit's strip
/// state into another's — while a user's EXISTING state keeps loading for the
/// cards they have today.
@Suite("Channel state store")
struct ChannelStateStoreTests {

    private func freshDefaults(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private let devUnit = CardLayout(slot1: .optical, slot2: .analogAD16)
    private let reporterUnit = CardLayout(slot1: .analogADDA16, slot2: .micPre8)

    private func encode(_ n: Int) -> Data {
        try! JSONEncoder().encode((0..<n).map { _ in InputChannelState() })
    }

    // MARK: - Scope

    @Test func scopeNamesBothSlots() {
        #expect(devUnit.savedStateScope == "optical+analogAD16")
        #expect(reporterUnit.savedStateScope == "analogADDA16+micPre8")
    }

    @Test func unknownLayoutHasNoScopeAndUsesLegacyKey() {
        let unknown = CardLayout(isKnown: false)
        #expect(unknown.savedStateScope == nil)
        let d = freshDefaults("maestro.tests.store.unknown")
        let store = ChannelStateStore(defaults: d, layout: unknown, isSimulatingCards: false)
        #expect(store.key(ChannelStateStore.inputKey) == "inputChannelStates")
        d.set(encode(24), forKey: "inputChannelStates")
        let loaded: [InputChannelState]? = store.load(ChannelStateStore.inputKey)
        #expect(loaded?.count == 24)
    }

    @Test func scopedKeyAppendsTheScope() {
        let d = freshDefaults("maestro.tests.store.key")
        let store = ChannelStateStore(defaults: d, layout: devUnit, isSimulatingCards: false)
        #expect(store.key("inputChannelStates") == "inputChannelStates.optical+analogAD16")
        #expect(store.key(ChannelStateStore.mixerKey(1)) == "mixerState_1.optical+analogAD16")
    }

    // MARK: - Migration: the developer's current cards keep their state

    @Test func existingLegacyStateStillLoadsForTheCurrentCards() {
        let d = freshDefaults("maestro.tests.store.migrate")
        d.set(encode(24), forKey: "inputChannelStates")         // pre-change save
        let store = ChannelStateStore(defaults: d, layout: devUnit, isSimulatingCards: false)
        let loaded: [InputChannelState]? = store.load(ChannelStateStore.inputKey)
        #expect(loaded?.count == 24)
        // The legacy key is now claimed by this layout.
        #expect(d.string(forKey: ChannelStateStore.claimKey("inputChannelStates")) == "optical+analogAD16")
        // Saves go to the scoped key; the legacy key is left alone.
        store.save([InputChannelState()], for: ChannelStateStore.inputKey)
        #expect(d.data(forKey: "inputChannelStates.optical+analogAD16") != nil)
        #expect(d.data(forKey: "inputChannelStates")?.count == encode(24).count)
        // And the scoped copy wins from now on.
        let again: [InputChannelState]? = store.load(ChannelStateStore.inputKey)
        #expect(again?.count == 1)
    }

    @Test func aDifferentCardPairDoesNotInheritAnotherPairsState() {
        let d = freshDefaults("maestro.tests.store.swap")
        d.set(encode(24), forKey: "inputChannelStates")
        // Dev unit reads (and claims) it.
        let dev = ChannelStateStore(defaults: d, layout: devUnit, isSimulatingCards: false)
        let devLoaded: [InputChannelState]? = dev.load(ChannelStateStore.inputKey)
        #expect(devLoaded?.count == 24)
        // Module swap: the 16x16 + MicPre starts from defaults, not the 24-strip state.
        let swapped = ChannelStateStore(defaults: d, layout: reporterUnit, isSimulatingCards: false)
        let swappedLoaded: [InputChannelState]? = swapped.load(ChannelStateStore.inputKey)
        #expect(swappedLoaded == nil)
        // The claim is unchanged, so swapping back still finds the dev state.
        let back: [InputChannelState]? = dev.load(ChannelStateStore.inputKey)
        #expect(back?.count == 24)
    }

    @Test func unclaimedLegacyStateGoesToWhicheverPairReadsItFirst() {
        let d = freshDefaults("maestro.tests.store.firstclaim")
        d.set(encode(16), forKey: "inputChannelStates")
        let store = ChannelStateStore(defaults: d, layout: reporterUnit, isSimulatingCards: false)
        let loaded: [InputChannelState]? = store.load(ChannelStateStore.inputKey)
        #expect(loaded?.count == 16)
        #expect(d.string(forKey: ChannelStateStore.claimKey("inputChannelStates")) == "analogADDA16+micPre8")
    }

    // MARK: - Simulation is isolated

    @Test func simulationNeverInheritsAndNeverClaimsRealState() {
        let d = freshDefaults("maestro.tests.store.sim")
        d.set(encode(24), forKey: "inputChannelStates")
        let sim = ChannelStateStore(defaults: d, layout: reporterUnit, isSimulatingCards: true)
        #expect(sim.key("inputChannelStates") == "inputChannelStates.sim:analogADDA16+micPre8")
        let loaded: [InputChannelState]? = sim.load(ChannelStateStore.inputKey)
        #expect(loaded == nil)
        #expect(d.string(forKey: ChannelStateStore.claimKey("inputChannelStates")) == nil)
        // A simulated save lands under the sim scope only.
        sim.save([InputChannelState()], for: ChannelStateStore.inputKey)
        #expect(d.data(forKey: "inputChannelStates.sim:analogADDA16+micPre8") != nil)
        #expect(d.data(forKey: "inputChannelStates.analogADDA16+micPre8") == nil)
        #expect(d.data(forKey: "inputChannelStates")?.count == encode(24).count)
        // A real unit with those cards is unaffected by what the harness saved.
        let real = ChannelStateStore(defaults: d, layout: reporterUnit, isSimulatingCards: false)
        let realLoaded: [InputChannelState]? = real.load(ChannelStateStore.inputKey)
        #expect(realLoaded?.count == 24)   // unclaimed legacy — first real reader gets it
    }

    // MARK: - Preset analog levels (debug launch argument)

    @Test func parsesAnalogLevelTokens() {
        #expect(CardSimulation.parseAnalogLevel("mic") == .mic)
        #expect(CardSimulation.parseAnalogLevel("Instrument") == .instrument)
        #expect(CardSimulation.parseAnalogLevel("inst") == .instrument)
        #expect(CardSimulation.parseAnalogLevel("+4 dBu") == nil)   // spaces inside are not a token
        #expect(CardSimulation.parseAnalogLevel("+4") == .plus4dBu)
        #expect(CardSimulation.parseAnalogLevel("line") == .plus4dBu)
        #expect(CardSimulation.parseAnalogLevel("-10") == .minus10dBV)
        #expect(CardSimulation.parseAnalogLevel("variable") == .variable)
        #expect(CardSimulation.parseAnalogLevel("3") == .mic)
        #expect(CardSimulation.parseAnalogLevel("bogus") == nil)
        #expect(CardSimulation.parseAnalogLevel("") == nil)
    }

    @Test func parsesPerChannelListWithGapsAndGain() {
        let presets = CardSimulation.parseAnalogLevels("mic@35, mic,inst@20,-,,line,typo")
        #expect(presets.count == 7)
        #expect(presets[0] == .init(level: .mic, gain: 35))
        #expect(presets[1] == .init(level: .mic, gain: nil))
        #expect(presets[2] == .init(level: .instrument, gain: 20))
        #expect(presets[3] == nil)
        #expect(presets[4] == nil)
        #expect(presets[5] == .init(level: .plus4dBu, gain: nil))
        #expect(presets[6] == nil)
    }

    @Test func analogLevelsAreOnlyHonouredUnderCardSimulation() {
        let name = "maestro.tests.store.levels"
        let d = freshDefaults(name)
        d.set("mic,inst", forKey: CardSimulation.analogLevelsKey)
        #expect(SimulatedDevice.simulatedAnalogLevels(defaults: d) == nil)
        d.set("analogADDA16", forKey: CardSimulation.primaryKey)
        d.set("micPre8", forKey: CardSimulation.secondaryKey)
        let presets = SimulatedDevice.simulatedAnalogLevels(defaults: d)
        #expect(presets?.count == 2)
        #expect(presets?[0]?.level == .mic)
        #expect(presets?[1]?.level == .instrument)
        d.removePersistentDomain(forName: name)
        #expect(CardSimulation.analogLevelsKey == "MaestroSimulateAnalogLevels")
    }
}
