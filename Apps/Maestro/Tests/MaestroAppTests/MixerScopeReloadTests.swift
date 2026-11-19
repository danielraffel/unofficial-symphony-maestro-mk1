import Foundation
import Testing
@testable import MaestroApp
import MaestroCore
import MaestroDevice

extension StandardDefaultsSuites {
@Suite("Mixer pending scope reload", .serialized)
@MainActor
struct MixerScopeReloadTests {
    @Test(arguments: [TransportType.usb, .thunderbolt], [0, 1])
    func openPendingResolveThenSave(transport: TransportType, mixer: Int) async throws {
        let defaults = UserDefaults.standard
        let before = defaults.dictionaryRepresentation()
        defer {
            for key in defaults.dictionaryRepresentation().keys where before[key] == nil {
                defaults.removeObject(forKey: key)
            }
            for (key, value) in before { defaults.set(value, forKey: key) }
        }
        let state = AppState()
        state.connectionMode = .hardware
        state.transportType = transport
        let connection = SimulatedDevice.symphonyIO32ch()
        state.device = connection
        let identity: UInt64 = 0xF1601234
        let store = ChannelStateStore(layout: state.cardLayout, isSimulatingCards: false,
            identity: identity, allowLegacyMigration: false)
        let prefs = store.mixerPreferences
        prefs.set(-24.0, forKey: "mixerMasterLevel_\(mixer)")
        prefs.set(-29.0, forKey: "mixerSWReturnLeftLevel_\(mixer)")
        prefs.set(2, forKey: "mixerSoftwareReturnSource_\(mixer)")
        prefs.set(1, forKey: "routingMode")
        let strip = MixerChannelState(level: -13, pan: 0.25, isMuted: false, isSoloed: false)
        store.save([strip], for: ChannelStateStore.mixerKey(mixer))
        var input = InputChannelState()
        input.gain = 17
        store.save([input], for: ChannelStateStore.inputKey)
        var output = OutputChannelState()
        output.trim = -2
        store.save([output], for: ChannelStateStore.outputKey)

        // The same editor value held by @State when a page opens pending.
        let pendingScopes = state.mixerViewScopes
        let pendingUnitScope = state.preferenceViewScope(for: .a)
        var pending = MixerEditorState(appState: state, selectedMixer: mixer)
        #expect(!pending.canEdit(state))
        pending.masterLevel = -1 // Even a delayed callback cannot persist an edit.
        pending.save(appState: state, selectedMixer: mixer)
        #expect(prefs.object(forKey: "mixerMasterLevel_\(mixer)") as? Double == -24)

        await state.resolveUnitIdentity(for: .a, connection: connection) { identity }
        #expect(state.mixerViewScopes != pendingScopes)
        #expect(state.preferenceViewScope(for: .a) != pendingUnitScope)
        #expect(!pending.canEdit(state))
        // Reproduce finding 7: save from the still-open, pre-identity editor.
        pending.save(appState: state, selectedMixer: mixer)
        #expect(prefs.object(forKey: "mixerMasterLevel_\(mixer)") as? Double == -24)
        #expect(prefs.object(forKey: "mixerSWReturnLeftLevel_\(mixer)") as? Double == -29)

        // DetailView's changed scope ID recreates the editor with these values.
        var restored = MixerEditorState(appState: state, selectedMixer: mixer)
        #expect(restored.canEdit(state))
        #expect(restored.masterLevel == -24)
        #expect(restored.masterLeftLevel == -24)
        #expect(restored.masterRightLevel == -24)
        #expect(restored.swReturnChannel.level == -29)
        #expect(restored.swReturnLeftLevel == -29)
        #expect(restored.swReturnRightLevel == -29)
        #expect(restored.softwareReturnSource == 2)
        #expect(restored.channels.first?.level == -13)
        #expect(state.mixerPreferences.integer(forKey: "routingMode") == 1)
        let inputs: [InputChannelState]? = state.unitChannelStateStore.load(ChannelStateStore.inputKey)
        let outputs: [OutputChannelState]? = state.unitChannelStateStore.load(ChannelStateStore.outputKey)
        #expect(inputs?.first?.gain == 17)
        #expect(outputs?.first?.trim == -2)
        #expect(state.softwareReturnMeterGains[mixer].left < 0.1)

        restored.channels[0].isMuted = true
        // Ordinary refreshes must not recreate the editor during a user edit.
        let loadedScopes = state.mixerViewScopes
        state.viewReloadToken = UUID()
        state.routingModeChangeCount += 1
        #expect(state.mixerViewScopes == loadedScopes)
        #expect(restored.canEdit(state))
        restored.save(appState: state, selectedMixer: mixer)
        let after = MixerEditorState(appState: state, selectedMixer: mixer)
        #expect(after.channels[0].isMuted)
        #expect(after.masterLevel == -24)
        #expect(after.swReturnChannel.level == -29)
        #expect(after.softwareReturnSource == 2)

        // A reconnect to the same UID is still a new editor lifetime.
        state.device = SimulatedDevice.symphonyIO32ch()
        #expect(!restored.canEdit(state))
        let replacement = try #require(state.device)
        await state.resolveUnitIdentity(for: .a, connection: replacement) { identity }
        #expect(!restored.canEdit(state))
        let reconnected = MixerEditorState(appState: state, selectedMixer: mixer)
        #expect(reconnected.masterLevel == -24)
        #expect(reconnected.channels[0].isMuted)
    }
}
}
