import Foundation
import SwiftUI
import Testing
@testable import MaestroApp
import MaestroCore
import MaestroDevice

/// Software Return and Master are one stereo fader: left and right are always
/// the same level, whichever way the handles are moved or reset.
extension StandardDefaultsSuites {
@Suite("Stereo faders stay linked", .serialized)
@MainActor
struct StereoFaderLinkedTests {
    private func makeEditor(_ body: (MixerPreferences, AppState) -> Void = { _, _ in }) -> (MixerEditorState, AppState) {
        let state = AppState()
        state.connectionMode = .hardware
        state.device = SimulatedDevice.symphonyIO32ch()
        state.unitAIdentity = UInt64.random(in: 1...UInt64.max)
        body(state.mixerPreferences, state)
        return (MixerEditorState(appState: state, selectedMixer: 0), state)
    }

    private func linked(_ e: MixerEditorState) -> Bool {
        e.swReturnLeftLevel == e.swReturnRightLevel && e.swReturnLeftLevel == e.swReturnChannel.level
            && e.masterLeftLevel == e.masterRightLevel && e.masterLeftLevel == e.masterLevel
    }

    @Test func oneSideDraggedOrResetMovesBoth() {
        var (e, _) = makeEditor()
        // One handle dragged (Option-drag with no selection, or a plain drag).
        e.swReturnLeftLevel = -30
        #expect(e.swReturnRightLevel == -30 && linked(e))
        e.masterRightLevel = -20
        #expect(e.masterLeftLevel == -20 && linked(e))
        // Option-click or double-click reset on either side, via the fader's own binding.
        let sw = Binding(get: { e.swReturnRightLevel }, set: { e.swReturnRightLevel = $0 })
        sw.wrappedValue = MixerValueConversion.faderDoubleClickResetValue()
        #expect(e.swReturnLeftLevel == MixerValueConversion.faderDoubleClickResetValue() && linked(e))
        e.masterLeftLevel = -9
        e.masterRightLevel = MixerValueConversion.faderDoubleClickResetValue()
        #expect(e.masterLeftLevel == MixerValueConversion.faderDoubleClickResetValue() && linked(e))
    }

    @Test func groupDragAndTypedValueKeepBothSides() {
        var (e, _) = makeEditor()
        let starts = [-10.0, -20.0]
        let moved = MixerGroupMath.applyingDelta(-8, to: starts, in: -48...6)
        e.swReturnChannel.level = moved[0]
        e.masterLevel = moved[1]
        #expect(linked(e))
        #expect(e.swReturnLeftLevel == moved[0] && e.masterRightLevel == moved[1])
        e.swReturnRightLevel = 0
        e.masterLeftLevel = 0
        #expect(linked(e) && e.swReturnChannel.level == 0 && e.masterLevel == 0)
    }

    @Test func savedSplitStateLoadsEqualAndSavesEqual() {
        let (e, state) = makeEditor { prefs, _ in
            prefs.set(-24.0, forKey: "mixerMasterLevel_0")
            prefs.set(-24.0, forKey: "mixerMasterLeftLevel_0")
            prefs.set(-3.0, forKey: "mixerMasterRightLevel_0")
            prefs.set(-29.0, forKey: "mixerSWReturnLeftLevel_0")
            prefs.set(-5.0, forKey: "mixerSWReturnRightLevel_0")
        }
        #expect(linked(e))
        #expect(e.swReturnRightLevel == -29 && e.masterRightLevel == -24)
        _ = state
    }
}
}
