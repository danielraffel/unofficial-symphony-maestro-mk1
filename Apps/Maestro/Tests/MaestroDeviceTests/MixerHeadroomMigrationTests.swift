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

    @Test("notice explains the one-time level change")
    func notice() {
        #expect(MixerHeadroomMigration.noticeText.contains("set to 0 dB"))
        #expect(MixerHeadroomMigration.noticeText.contains("old values were kept"))
    }

    @Test("above 0 to 0, at or below unchanged, backup written, runs once")
    func migration() throws {
        let name = "MixerHeadroomMigrationTests.\(UUID().uuidString)"
        let defaults = try #require(ScratchUserDefaults(suiteName: name))
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

@Suite("Headroom: Software Return strips, and the flag a new file gets")
struct HeadroomStripAndFlagTests {
    @Test("a Software Return level held only in the saved strips is lowered, then reads 0")
    func strips() throws {
        let name = "HeadroomStrips.\(UUID().uuidString)"
        let defaults = try #require(ScratchUserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let layout = CardLayout(slot1: .optical, slot2: .none)
        let store = ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: false, identity: 9)
        let prefs = store.mixerPreferences
        let strip = MixerChannelState(level: 5, pan: 0, isMuted: true, isSoloed: false)
        prefs.set(try JSONEncoder().encode(strip), forKey: MixerStateSnapshot.sharedSoftwareReturnKey)
        prefs.set(try JSONEncoder().encode(strip), forKey: MixerStateSnapshot.softwareReturnKey(mixer: 0))
        #expect(MixerStateSnapshot(channelCount: 2, mixer: 1, store: store).swReturnLeftLevel == 5)
        #expect(MixerHeadroomMigration.run(store: store, preferences: prefs) == 2)
        for mixer in 0..<2 {
            let snapshot = MixerStateSnapshot(channelCount: 2, mixer: mixer, store: store)
            #expect(snapshot.swReturnLeftLevel == 0 && snapshot.swReturnRightLevel == 0)
            #expect(snapshot.swReturnChannel.isMuted)   // the rest of the strip is kept
        }
        let backup = try #require(prefs.object(forKey: MixerHeadroomMigration.backupKey) as? [String: Double])
        #expect(backup[MixerStateSnapshot.sharedSoftwareReturnKey] == 5)
    }

    @Test("a new file is marked only when the serving driver plays above 0 dB")
    func flag() {
        #expect(ThunderboltPreset.fadersPlayAboveZero(serving: .build(144)))
        #expect(!ThunderboltPreset.fadersPlayAboveZero(serving: .build(143)))
        #expect(!ThunderboltPreset.fadersPlayAboveZero(serving: nil))
        let layout = CardLayout(slot1: .optical, slot2: .none)
        let old = ThunderboltPreset(layout: layout, metadata: MaestroPreset(), fadersAboveZeroPlay: false)
        #expect(old.fadersAboveZeroPlay == false)
        // Saved under 143 it loads clamped, as the levels were heard.
        var mixer = ThunderboltPreset.Mixer(snapshot: MixerStateSnapshot(
            channelCount: 1, mixer: 0, store: ChannelStateStore(defaults: .standard, layout: layout, isSimulatingCards: true)))
        mixer.master = 6
        var file = old
        file.mixers = [mixer, mixer]
        #expect(file.headroomClamped().mixers[0].master == 0)
    }

    @Test("the launch recall leaves monitor controls out when level recall is disabled")
    func launchRecall() throws {
        let layout = CardLayout(slot1: .optical, slot2: .none)
        var preset = ThunderboltPreset(layout: layout, metadata: MaestroPreset())
        for selector in ThunderboltPreset.monitorOrder { preset.globals[selector.rawValue] = 0 }
        func selectors(_ writes: [ThunderboltPreset.Write]) -> Set<AudioPropertySelector> {
            Set(writes.compactMap { if case .property(let address, _) = $0 { return address.selector }; return nil })
        }
        let all = selectors(try preset.writes(layout: layout, legacy: true))
        let launch = selectors(try preset.writes(layout: layout, legacy: true, recallsMonitorLevels: false))
        for selector in ThunderboltPreset.monitorLevelSelectors {
            #expect(all.contains(selector))
            #expect(!launch.contains(selector))
        }
        #expect(!launch.contains(.speakerOutputMode) && !launch.contains(.outputDim))
        #expect(!launch.contains(.activeSpeakerSet))
    }
}

@Suite("Card presets saved before 0.9.23 load with faders above 0 at 0")
struct PresetHeadroomTests {
    @Test("old file clamped, new file as written")
    func clamp() throws {
        let layout = CardLayout(slot1: .optical, slot2: .none)
        var preset = ThunderboltPreset(layout: layout, metadata: MaestroPreset())
        let name = "PresetHeadroomTests.\(UUID().uuidString)"
        let defaults = try #require(ScratchUserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: false, identity: 3)
        let snapshot = MixerStateSnapshot(channelCount: 2, mixer: 0, store: store)
        var mixer = ThunderboltPreset.Mixer(snapshot: snapshot)
        mixer.channels = [MixerChannelState(level: 5, pan: 0, isMuted: false, isSoloed: false),
                          MixerChannelState(level: -4, pan: 0, isMuted: false, isSoloed: false)]
        mixer.softwareReturn.level = 3
        mixer.master = 6
        preset.mixers = [mixer, mixer]
        #expect(preset.headroomClamped() == preset)            // saved by 0.9.23: as written
        preset.fadersAboveZeroPlay = nil                        // an older file
        let loaded = preset.headroomClamped()
        #expect(loaded.mixers[0].channels.map(\.level) == [0, -4])
        #expect(loaded.mixers[1].softwareReturn.level == 0 && loaded.mixers[1].master == 0)
    }
}
