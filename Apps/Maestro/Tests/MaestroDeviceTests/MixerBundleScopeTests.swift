import Foundation
import Testing
import MaestroCore
import MaestroDevice

@Suite("Bundle mixer scope")
struct MixerBundleScopeTests {
    @Test func bundleCommitWritesEachPhysicalOwnerOnly() throws {
        let name = "MixerBundleScopeTests.\(UUID())"
        let defaults = try #require(ScratchUserDefaults(suiteName: name))
        defer { defaults.cleanup() }
        let layout = CardLayout(slot1: .analogADDA16, slot2: .none)
        let a = ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: false, identity: 42)
        let b = ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: false, unit: .b, identity: 84)
        var preset = ThunderboltPreset(layout: layout, metadata: MaestroPreset())
        // A bundle from an older version, saved in "DAW" mode. It is not kept.
        preset.routingMode = 0
        var mixer = ThunderboltPreset.Mixer(snapshot: MixerStateSnapshot(channelCount: 1, mixer: 0, store: a))
        mixer.master = -17
        mixer.source = 3
        preset.mixers = [mixer]
        try a.saveMixerPreset(preset.mixers, sourceCount: 8)
        mixer.master = -23
        preset.mixers = [mixer]
        try b.saveMixerPreset(preset.mixers, sourceCount: 32)
        #expect(a.mixerPreferences.object(forKey: "mixerMasterLevel_0") as? Double == -17)
        #expect(b.mixerPreferences.object(forKey: "mixerMasterLevel_0") as? Double == -23)
        // The removed Input Monitoring setting is never written again.
        #expect(a.mixerPreferences.object(forKey: "routingMode") == nil)
        #expect(b.mixerPreferences.object(forKey: "routingMode") == nil)
        #expect(b.mixerPreferences.integer(forKey: "mixerSoftwareReturnSource_0") == 3)
        #expect(defaults.object(forKey: "mixerMasterLevel_0") == nil)
        #expect(defaults.object(forKey: "routingMode") == nil)
    }
}
