import Foundation
import Testing
@testable import MaestroApp

@Suite("MicPre DAW sync")
struct MicPreDAWSyncTests {
    @Test("observes fitted Thunderbolt MicPre controls and persists changes")
    func listenerAndPersistencePath() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("MaestroApp/AppState.swift"), encoding: .utf8)
        #expect(source.contains("cardLayout.slot2 == .micPre8"))
        #expect(source.contains("kAudioDevicePropertyPhaseInvert"))
        #expect(source.contains("kAudioDevicePropertyHighPassFilterSetting"))
        #expect(source.contains("kAudioDevicePropertyChannelNominalLineLevel"))
        #expect(source.contains("channelStateStore.save(states, for: ChannelStateStore.inputKey)"))
        #expect(source.contains("states[channel].inputType = raw == 0 ? 1 : raw == 1 ? 2 : raw == 2 ? 0 : raw"))
        #expect(!source.contains("phantomProvenance = PhantomProvenance"))
    }
}
