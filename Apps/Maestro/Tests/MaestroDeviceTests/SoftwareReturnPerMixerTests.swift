import Foundation
import Testing
import MaestroCore
@testable import MaestroDevice

/// Each mixer keeps its own Software Return mute and solo, as the original
/// did; pan stays one value for both. Reported 2026-11-21: a mute set on
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

    @Test("pan is one value for both mixers")
    func panShared() {
        let (_, p, done) = prefs(); defer { done() }
        MixerStateSnapshot.saveSoftwareReturn(strip(pan: -0.5, muted: false), mixer: 1, preferences: p)
        #expect(MixerStateSnapshot.savedSoftwareReturn(mixer: 0, preferences: p).pan == -0.5)
        #expect(USBMixerSavedState.load(preferences: p).softwareReturnPan == -0.5)
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
        #expect(USBMixerRestorePlan.steps(for: state).contains(.helperNeutral(muted: false)))
    }

    @Test("the helper mutes only when every mixer on USB 1-2 is muted")
    func helperRule() {
        #expect(USBMixerSavedState.helperMuted([(0, true), (0, true)]))
        #expect(!USBMixerSavedState.helperMuted([(0, true), (0, false)]))
        // A mixer on another source does not hear the helper's pair.
        #expect(USBMixerSavedState.helperMuted([(0, true), (2, false)]))
        #expect(!USBMixerSavedState.helperMuted([(2, true), (2, true)]))
    }
}
