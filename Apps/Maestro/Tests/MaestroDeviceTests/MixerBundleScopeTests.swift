import Foundation
import Testing
import MaestroCore
import MaestroDevice

@Suite("Bundle mixer scope")
struct MixerBundleScopeTests {
    @Test func bundleCommitWritesEachPhysicalOwnerOnly() throws {
        let name = "MixerBundleScopeTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let layout = CardLayout(slot1: .analogADDA16, slot2: .none)
        let a = ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: false, identity: 42)
        let b = ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: false, unit: .b, identity: 84)
        var preset = ThunderboltPreset(layout: layout, metadata: MaestroPreset())
        preset.routingMode = 1
        var mixer = ThunderboltPreset.Mixer(snapshot: MixerStateSnapshot(channelCount: 1, mixer: 0, store: a))
        mixer.master = -17
        mixer.source = 3
        preset.mixers = [mixer]
        try a.saveMixerPreset(preset.mixers, routingMode: preset.routingMode, sourceCount: 8)
        mixer.master = -23
        preset.mixers = [mixer]
        try b.saveMixerPreset(preset.mixers, routingMode: preset.routingMode, sourceCount: 32)
        #expect(a.mixerPreferences.object(forKey: "mixerMasterLevel_0") as? Double == -17)
        #expect(b.mixerPreferences.object(forKey: "mixerMasterLevel_0") as? Double == -23)
        #expect(b.mixerPreferences.integer(forKey: "routingMode") == 1)
        #expect(b.mixerPreferences.integer(forKey: "mixerSoftwareReturnSource_0") == 3)
        #expect(defaults.object(forKey: "mixerMasterLevel_0") == nil)
        #expect(defaults.object(forKey: "routingMode") == nil)
    }
}
