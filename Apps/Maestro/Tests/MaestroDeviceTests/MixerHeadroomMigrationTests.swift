import Foundation
import Testing
@testable import MaestroCore
@testable import MaestroDevice

@Suite("Faders above 0 dB are lowered once for driver 144")
struct MixerHeadroomMigrationTests {
    @Test("only build 144 and later")
    func builds() {
        #expect(!MixerHeadroomMigration.applies(to: nil))
        #expect(!MixerHeadroomMigration.applies(to: .build(143)))
        #expect(MixerHeadroomMigration.applies(to: .build(144)))
        #expect(MixerHeadroomMigration.applies(to: .build(150)))
    }

    @Test("above 0 to 0, at or below unchanged, backup written, runs once")
    func migration() throws {
        let name = "MixerHeadroomMigrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let layout = CardLayout(slot1: .optical, slot2: .none)
        let store = ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: false, identity: 7)
        let prefs = store.mixerPreferences
        store.save([MixerChannelState(level: 4, pan: 0, isMuted: false, isSoloed: false),
                    MixerChannelState(level: -6, pan: 0, isMuted: false, isSoloed: false),
                    MixerChannelState(level: 0, pan: 0, isMuted: false, isSoloed: false)],
                   for: ChannelStateStore.mixerKey(0))
        prefs.set(6.0, forKey: "mixerMasterLevel_0")
        prefs.set(2.0, forKey: "mixerSWReturnLeftLevel_1")
        prefs.set(-3.0, forKey: "mixerSWReturnRightLevel_1")

        #expect(MixerHeadroomMigration.run(store: store, preferences: prefs) == 3)
        let strips: [MixerChannelState] = try #require(store.load(ChannelStateStore.mixerKey(0)))
        #expect(strips.map(\.level) == [0, -6, 0])
        #expect(prefs.object(forKey: "mixerMasterLevel_0") as? Double == 0)
        #expect(prefs.object(forKey: "mixerSWReturnLeftLevel_1") as? Double == 0)
        #expect(prefs.object(forKey: "mixerSWReturnRightLevel_1") as? Double == -3)
        let backup = try #require(prefs.object(forKey: MixerHeadroomMigration.backupKey) as? [String: Double])
        #expect(backup["mixerMasterLevel_0"] == 6 && backup["mixerSWReturnLeftLevel_1"] == 2)

        // A level raised again afterwards is the user's, and stays.
        prefs.set(5.0, forKey: "mixerMasterLevel_0")
        #expect(MixerHeadroomMigration.run(store: store, preferences: prefs) == 0)
        #expect(prefs.object(forKey: "mixerMasterLevel_0") as? Double == 5)
    }
}
