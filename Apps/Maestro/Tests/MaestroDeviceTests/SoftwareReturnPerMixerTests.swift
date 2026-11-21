import Foundation
import Testing
import MaestroCore
@testable import MaestroDevice

/// Each mixer keeps its own Software Return mute and solo, as the original
/// did; there is no Software Return pan. Reported 2026-11-21: a mute set on
/// Mixer 1 showed on Mixer 2 and the reverse.
@Suite("Software Return: each mixer has its own mute and solo")
struct SoftwareReturnPerMixerTests {
    private func prefs() -> (UserDefaults, MixerPreferences, () -> Void) {
        let name = "maestro.tests.swReturnPerMixer.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        return (d, MixerPreferences(legacyDefaults: d), { d.removePersistentDomain(forName: name) })
    }
    private func strip(pan: Double = 0, muted: Bool, solo: Bool = false) -> MixerChannelState {
        MixerChannelState(level: 0, pan: pan, isMuted: muted, isSoloed: solo)
    }

    @Test("a mute saved on one mixer does not show on the other")
    func independent() {
        let (_, p, done) = prefs(); defer { done() }
        MixerStateSnapshot.saveSoftwareReturn(strip(muted: true, solo: true), mixer: 0, preferences: p)
        #expect(MixerStateSnapshot.savedSoftwareReturn(mixer: 0, preferences: p).isMuted)
        #expect(MixerStateSnapshot.savedSoftwareReturn(mixer: 0, preferences: p).isSoloed)
        #expect(!MixerStateSnapshot.savedSoftwareReturn(mixer: 1, preferences: p).isMuted)
        #expect(!MixerStateSnapshot.savedSoftwareReturn(mixer: 1, preferences: p).isSoloed)
    }

    @Test("after updating, both mixers start from the strip they shared, and a save on one leaves the other as it was")
    func migratesFromSharedStrip() throws {
        let (d, p, done) = prefs(); defer { done() }
        d.set(try JSONEncoder().encode(strip(pan: 0.4, muted: true)), forKey: "mixerState_swReturn")
        #expect(MixerStateSnapshot.savedSoftwareReturn(mixer: 0, preferences: p).isMuted)
        #expect(MixerStateSnapshot.savedSoftwareReturn(mixer: 1, preferences: p).isMuted)
        MixerStateSnapshot.saveSoftwareReturn(strip(pan: 0.4, muted: false), mixer: 0, preferences: p)
        #expect(!MixerStateSnapshot.savedSoftwareReturn(mixer: 0, preferences: p).isMuted)
        #expect(MixerStateSnapshot.savedSoftwareReturn(mixer: 1, preferences: p).isMuted)
    }

    @Test("each mixer's strip moves with the unit's settings when its identity is learned")
    func perMixerKeysMigrate() {
        #expect(MixerPreferences.legacyKeys.contains(MixerStateSnapshot.softwareReturnKey(mixer: 0)))
        #expect(MixerPreferences.legacyKeys.contains(MixerStateSnapshot.softwareReturnKey(mixer: 1)))
    }

    @Test("ThunderBridge replay gives each mixer its own mute and solo")
    func cardReplayPerMixer() {
        let (_, p, done) = prefs(); defer { done() }
        MixerStateSnapshot.saveSoftwareReturn(strip(muted: true), mixer: 0, preferences: p)
        MixerStateSnapshot.saveSoftwareReturn(strip(muted: false, solo: true), mixer: 1, preferences: p)
        #expect(MixerStateSnapshot.savedSoftwareReturn(mixer: 0, preferences: p) == strip(muted: true))
        #expect(MixerStateSnapshot.savedSoftwareReturn(mixer: 1, preferences: p) == strip(muted: false, solo: true))
    }

    @Test("Software Return has no pan: one an earlier version saved is ignored, and centre is what gets saved")
    func savedPanIgnored() throws {
        let (d, p, done) = prefs(); defer { done() }
        // As 0.9.18 left it: a panned strip under the shared key and a mixer's own.
        d.set(try JSONEncoder().encode(strip(pan: -0.5, muted: true)), forKey: "mixerState_swReturn")
        d.set(try JSONEncoder().encode(strip(pan: 0.8, muted: false)), forKey: "mixerState_swReturn_1")
        #expect(MixerStateSnapshot.savedSoftwareReturn(mixer: 0, preferences: p) == strip(pan: 0, muted: true))
        #expect(MixerStateSnapshot.savedSoftwareReturn(mixer: 1, preferences: p) == strip(pan: 0, muted: false))
        // Saving a strip that still carries a pan writes centre.
        MixerStateSnapshot.saveSoftwareReturn(strip(pan: 0.3, muted: false), mixer: 0, preferences: p)
        for key in ["mixerState_swReturn_0", "mixerState_swReturn"] {
            let data = try #require(d.data(forKey: key))
            #expect(try JSONDecoder().decode(MixerChannelState.self, from: data).pan == 0)
        }
        // The USB restore has no balance step at all.
        let steps = USBMixerRestorePlan.steps(for: USBMixerSavedState.load(preferences: p), routedToOutput: [true, true])
        #expect(!steps.contains { if case .hardware(let a, _) = $0 { return a.selector == .mixerChannelPan } else { return false } })
    }

    @Test("USB restore gives each mixer its own mute and solo")
    func restorePlan() {
        let (_, p, done) = prefs(); defer { done() }
        MixerStateSnapshot.saveSoftwareReturn(strip(muted: true), mixer: 0, preferences: p)
        MixerStateSnapshot.saveSoftwareReturn(strip(muted: false, solo: true), mixer: 1, preferences: p)
        let state = USBMixerSavedState.load(preferences: p)
        #expect(state.mixes[0].softwareReturn.isMuted && !state.mixes[0].softwareReturn.isSoloed)
        #expect(!state.mixes[1].softwareReturn.isMuted && state.mixes[1].softwareReturn.isSoloed)
        // Mixer 2 still plays USB 1-2, so the helper must not silence it.
        #expect(USBMixerRestorePlan.steps(for: state, routedToOutput: [true, true]).contains(.helperNeutral(muted: false)))
        // With the default routing no mixer feeds an output: the helper is out of the path.
        let direct = USBMixerRestorePlan.steps(for: state)
        #expect(direct.contains(.helperNeutral(muted: false)))
        #expect(direct.contains(.helperProcessing(false)))
    }

    private func helper(_ mixers: [(UInt32, Bool, Bool)]) -> USBHelperSoftwareReturn.State {
        USBHelperSoftwareReturn.state(mixers.map { .init(source: $0.0, muted: $0.1, routedToOutput: $0.2) })
    }

    @Test("the helper acts only while a mixer on USB 1-2 feeds an output, and mutes only when every such mixer is muted")
    func helperRule() {
        let on = USBHelperSoftwareReturn.State(processing: true, muted: true)
        let passing = USBHelperSoftwareReturn.State(processing: true, muted: false)
        // Default routing: no mixer feeds an output. Neutral whatever the mutes say,
        // because a Software Return mute never touches a direct output.
        #expect(helper([(0, true, false), (0, true, false)]) == .neutral)
        #expect(helper([(0, false, false), (0, false, false)]) == .neutral)
        // One mixer on USB 1-2 routed to an output: its mute is the helper's.
        #expect(helper([(0, true, true), (0, false, false)]) == on)
        #expect(helper([(0, false, true), (0, true, false)]) == passing)
        // Both routed: only when both are muted.
        #expect(helper([(0, true, true), (0, true, true)]) == on)
        #expect(helper([(0, true, true), (0, false, true)]) == passing)
        // A routed mixer on another source does not hear the helper's pair.
        #expect(helper([(2, true, true), (2, true, true)]) == .neutral)
        #expect(helper([(0, true, true), (2, false, true)]) == on)
        #expect(helper([(2, true, true), (0, true, false)]) == .neutral)
        #expect(helper([]) == .neutral)
    }

    @Test("which mixers feed an output comes from the Output Routing rows after the software pairs")
    func mixersRouted() {
        #expect(USBHelperSoftwareReturn.mixersRouted(rows: [:], softwarePairs: 8) == [false, false])
        #expect(USBHelperSoftwareReturn.mixersRouted(rows: [0: [0], 3: [1]], softwarePairs: 8) == [false, false])
        #expect(USBHelperSoftwareReturn.mixersRouted(rows: [8: [0]], softwarePairs: 8) == [true, false])
        #expect(USBHelperSoftwareReturn.mixersRouted(rows: [8: [], 9: [2, 3]], softwarePairs: 8) == [false, true])
        #expect(USBHelperSoftwareReturn.mixersRouted(rows: [8: [0]], softwarePairs: 16) == [false, false])
    }
}
