import Foundation
import Testing
import MaestroCore
import MaestroDevice

@Suite("Mixer initial state")
struct MixerStateSnapshotTests {
    private let unity = MixerChannelState(level: 0, pan: 0, isMuted: false, isSoloed: false)
    private let edited = MixerChannelState(level: -17.5, pan: 0.35, isMuted: true, isSoloed: true)
    /// `edited` as a Software Return shows it: the strip has no pan, so a saved one reads centre.
    private let editedReturn = MixerChannelState(level: -17.5, pan: 0, isMuted: true, isSoloed: true)
    private let layout = CardLayout(slot1: .optical, slot2: .analogAD16)

    private func withDefaults(_ body: (UserDefaults, ChannelStateStore) throws -> Void) rethrows {
        let name = "maestro.tests.mixerSnapshot.\(UUID().uuidString)"
        let defaults = ScratchUserDefaults(suiteName: name)!
        defer { defaults.cleanup() }
        let store = ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: false, identity: 1)
        try body(defaults, store)
    }

    @Test func physicalReplacementDoesNotInheritMixerWideState() throws {
        try withDefaults { defaults, _ in
            defaults.set(-19.0, forKey: "mixerMasterLevel_0")
            defaults.set(3, forKey: "mixerSoftwareReturnSource_0")
            defaults.set(try JSONEncoder().encode(edited), forKey: "mixerState_swReturn")
            let a = ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: false, identity: 101)
            let first = MixerStateSnapshot(channelCount: 1, mixer: 0, store: a, defaults: defaults)
            #expect(first.masterLevel == -19)
            #expect(first.swReturnChannel == editedReturn)
            #expect(first.softwareReturnSource == 3)
            let replacement = ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: false, identity: 202)
            let second = MixerStateSnapshot(channelCount: 1, mixer: 0, store: replacement, defaults: defaults)
            #expect(second.masterLevel == 0)
            #expect(second.swReturnChannel == unity)
            #expect(second.softwareReturnSource == 0)
            defaults.set(-1.0, forKey: "mixerMasterLevel_0")
            let unchanged = MixerStateSnapshot(channelCount: 1, mixer: 0, store: a, defaults: defaults)
            #expect(unchanged.masterLevel == -19)
        }
    }

    @Test func savedControlsAreAvailableTogetherOnInitialization() throws {
        try withDefaults { defaults, store in
            let saved = Array(repeating: edited, count: layout.mixerChannels.count)
            store.save(saved, for: ChannelStateStore.mixerKey(0))
            let softwareReturn = MixerChannelState(level: -6, pan: -0.25, isMuted: false, isSoloed: true)
            defaults.set(try JSONEncoder().encode(softwareReturn), forKey: "mixerState_swReturn")
            defaults.set(-9.5, forKey: "mixerMasterLevel_0")

            let snapshot = MixerStateSnapshot(channelCount: layout.mixerChannels.count, mixer: 0,
                                              store: store, defaults: defaults)
            #expect(snapshot.channels == saved)
            // Software Return has no pan: the saved -0.25 is not applied.
            #expect(snapshot.swReturnChannel == MixerChannelState(level: -6, pan: 0, isMuted: false, isSoloed: true))
            #expect(snapshot.masterLevel == -9.5)
        }
    }

    @Test func defaultSnapshotHasEveryInstalledInputImmediately() {
        withDefaults { defaults, _ in
            for cards in [layout, CardLayout(slot1: .analogADDA16, slot2: .micPre8)] {
                let store = ChannelStateStore(defaults: defaults, layout: cards, isSimulatingCards: false)
                let snapshot = MixerStateSnapshot(channelCount: cards.mixerChannels.count, mixer: 0,
                                                  store: store, defaults: defaults)
                #expect(snapshot.channels == Array(repeating: unity, count: cards.mixerChannels.count))
                #expect(!snapshot.channels.isEmpty)
                #expect(snapshot.swReturnChannel == unity)
                #expect(snapshot.masterLevel == 0)
            }
        }
    }

    @Test func resizingPreservesSavedControlsWithoutOverwritingThem() {
        withDefaults { defaults, store in
            let key = ChannelStateStore.mixerKey(0)
            let saved = [edited, unity, edited]
            store.save(saved, for: key)
            let dataBefore = defaults.data(forKey: store.key(key))

            let padded = MixerStateSnapshot(channelCount: 5, mixer: 0, store: store, defaults: defaults)
            #expect(padded.channels == saved + [unity, unity])
            let trimmed = MixerStateSnapshot(channelCount: 1, mixer: 0, store: store, defaults: defaults)
            #expect(trimmed.channels == [edited])
            let empty = MixerStateSnapshot(channelCount: 0, mixer: 0, store: store, defaults: defaults)
            #expect(empty.channels.isEmpty)
            #expect(defaults.data(forKey: store.key(key)) == dataBefore)
        }
    }

    @Test func malformedSavedControlsFallBackToCompleteDefaults() {
        withDefaults { defaults, store in
            store.saveData(Data("{bad json".utf8), for: ChannelStateStore.mixerKey(0))
            defaults.set(Data("{bad json".utf8), forKey: "mixerState_swReturn")
            let snapshot = MixerStateSnapshot(channelCount: 16, mixer: 0, store: store, defaults: defaults)
            #expect(snapshot.channels == Array(repeating: unity, count: 16))
            #expect(snapshot.swReturnChannel == unity)
            #expect(snapshot.masterLevel == 0)
        }
    }

    @Test func emptySavedArrayGetsACompleteDefaultSnapshot() {
        withDefaults { defaults, store in
            store.save([MixerChannelState](), for: ChannelStateStore.mixerKey(0))
            let snapshot = MixerStateSnapshot(channelCount: 32, mixer: 0, store: store, defaults: defaults)
            #expect(snapshot.channels == Array(repeating: unity, count: 32))
        }
    }

    @Test func mixersKeepSeparateInputsAndMasterButShareSoftwareReturn() throws {
        try withDefaults { defaults, store in
            store.save([edited], for: ChannelStateStore.mixerKey(0))
            store.save([unity], for: ChannelStateStore.mixerKey(1))
            defaults.set(-3.0, forKey: "mixerMasterLevel_0")
            defaults.set(-12.0, forKey: "mixerMasterLevel_1")
            defaults.set(2, forKey: "mixerSoftwareReturnSource_0")
            defaults.set(7, forKey: "mixerSoftwareReturnSource_1")
            defaults.set(try JSONEncoder().encode(edited), forKey: "mixerState_swReturn")

            let first = MixerStateSnapshot(channelCount: 1, mixer: 0, store: store, defaults: defaults)
            let second = MixerStateSnapshot(channelCount: 1, mixer: 1, store: store, defaults: defaults)
            #expect(first.channels == [edited])
            #expect(second.channels == [unity])
            #expect(first.masterLevel == -3)
            #expect(second.masterLevel == -12)
            #expect(first.swReturnChannel == editedReturn)
            #expect(second.swReturnChannel == editedReturn)
            #expect(first.softwareReturnSource == 2)
            #expect(second.softwareReturnSource == 7)
        }
    }
}
