import Foundation
import Testing
@testable import MaestroCore

struct LoopSyncTests {
    @Test func defaultsAndOffKeepThePreferredMaster() {
        let initial = LoopSyncSettings()
        #expect(initial.enabled)
        #expect(initial.effectiveMaster == .a)
        let off = LoopSyncSettings(enabled: false, master: .b)
        #expect(off.master == .b)
        #expect(off.effectiveMaster == .a)
        #expect(off.role(.b) == "Word Clock")
        #expect(LoopSyncSettings(word: off.word) == off)
        #expect(LoopSyncSettings(word: 4) == nil)
    }

    @Test func onlyTwoConfiguredSymphoniesCanUseTheControls() {
        let topologies: [SymphonyRoutingModel.Topology] = [
            .symphonyOnly, .unknown, .symphonyAndConverters([.ad16x])
        ]
        for (index, topology) in topologies.enumerated() {
            for channels in [32, 64] {
                for configured in [false, true] {
                    let routing = SymphonyRoutingModel(topology: topology, hostChannels: channels,
                                                       unitBConfigured: configured)
                    let available = LoopSyncSettings.available(in: routing)
                    #expect(available == (index == 0 && channels == 64 && configured))
                }
            }
        }
    }

    @Test func configuredRoleDoesNotImplyMeasuredLock() {
        let state = LoopSyncState.decode([2, 1, 1, 0, 1, 1])
        #expect(state?.role(.b) == "Loop Sync master")
        #expect(state?.role(.a) == "Loop Sync (follows Unit B)")
        #expect(state?.lockText(.a) == "Clock Mismatch")
        #expect(state?.lockText(.b) == "Not read")
        let partial = LoopSyncState.decode([2, 0, 2, 2, 1, 1])
        #expect(partial?.role(.b) == "Not confirmed")
        #expect(partial?.lockText(.b) == "Ready")
        #expect(LoopSyncState.decode([2, 1]) == nil)
        #expect(LoopSyncState.decode([2, 1, 3, 0, 1, 1]) == nil)
    }

    @Test func persistenceDoesNotTurnPreferencesIntoAReading() throws {
        let name = "LoopSyncTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(LoopSyncSettings.saved(in: defaults) == nil)
        let saved = LoopSyncSettings(enabled: false, master: .b)
        saved.save(in: defaults)
        #expect(LoopSyncSettings.saved(in: defaults) == saved)
        // The independently decoded driver still reports the default until applied.
        let driver = LoopSyncState.decode([0, 1, 2, 2, 1, 1])
        #expect(driver?.settings == LoopSyncSettings())
    }

    @Test func masterBoardInputReadback() {
        let state = LoopSyncState.decode([2, 1, 2, 2, 1, 0x0204])
        let expected = ClockSourceMenu.key(source: 4, boardInput: 2)
        #expect(state?.sourceKey(.b) == expected)
    }
}
