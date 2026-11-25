import Foundation
import Testing
@testable import MaestroApp
@testable import MaestroDevice
@testable import MaestroCore

/// 0.9.28: the app side of the 48V display. A DAW's ON is session display
/// state only; Maestro's own ON made before the identity was known stays lit
/// for the connection it was made in.
@MainActor
@Suite("Phantom display")
struct PhantomDisplayAppTests {
    private static func link(_ fields: [Int: UInt32]) -> LinkState {
        LinkState(state: .up, clockPresent: true, ioRunning: false, irqCount: 0, recoveryCount: 0,
                  hwSuspended: false, linkConfigured: true, lastClockReg: 0, watchTicks: 0, audioWraps: 0,
                  phantomOffReceipts: Array(repeating: 0, count: 16),
                  micPreEdits: (0..<16).map { MicPreEditRecord(stamp: fields[$0] == nil ? 0 : 5, fields: fields[$0] ?? 0) })
    }

    @Test("a DAW's 48V ON is shown on the 8MicPre unit only, from driver 153, and cleared by Maestro's write")
    func observedOnFollowsRecordsAndBuild() {
        let state = AppState()
        state.transportType = .thunderbolt
        state.primaryBoardType = .analogADDA16
        state.secondaryBoardType = .micPre8
        let on = MicPreEditRecord.phantomValid | MicPreEditRecord.phantomBit
        state.servingDextBuild = .build(152)
        state.updatePhantomObservedOn(Self.link([0: on, 8: on]))
        #expect(!state.phantomObserved(unit: .a, channel: 0))
        state.servingDextBuild = .build(153)
        state.updatePhantomObservedOn(Self.link([0: on, 8: on]))
        #expect(state.phantomObserved(unit: .a, channel: 0))
        // No unit B 8MicPre: its records are not shown.
        #expect(!state.phantomObserved(unit: .b, channel: 0))
        state.clearPhantomObserved(unit: .a, channel: 0)
        #expect(!state.phantomObserved(unit: .a, channel: 0))
    }

    @Test("an own ON awaiting identity belongs to its connection generation")
    func pendingOwnOnIsPerGeneration() {
        let state = AppState()
        state.notePendingPhantomProvenance(unit: .a, channel: 3)
        #expect(state.pendingPhantomOn(unit: .a, channel: 3))
        #expect(!state.pendingPhantomOn(unit: .b, channel: 3) && !state.pendingPhantomOn(unit: .a, channel: 2))
        state.dropPendingPhantomProvenance(unit: .a, channel: 3)
        #expect(!state.pendingPhantomOn(unit: .a, channel: 3))
        state.notePendingPhantomProvenance(unit: .a, channel: 3)
        state.invalidateUnitAIdentity()   // another connection: maybe another unit
        #expect(!state.pendingPhantomOn(unit: .a, channel: 3))
        // Finishing in the new generation does nothing (and writes nothing).
        state.finishPendingPhantomProvenance(unit: .a, identity: 42, records: nil)
        #expect(state.pendingPhantomProvenance[.a] == nil)
    }

    @Test("review m4: a DAW phantom edit after Maestro's ON drops it; no fresh read grants nothing")
    func dawEditDropsPendingOwnOn() {
        let state = AppState()
        state.notePendingPhantomProvenance(unit: .a, channel: 1)
        state.notePendingPhantomProvenance(unit: .a, channel: 2)
        state.notePendingPhantomProvenance(unit: .b, channel: 1)
        var records = (0..<16).map { _ in MicPreEditRecord(stamp: 0, fields: 0) }
        records[1] = MicPreEditRecord(stamp: 3, fields: MicPreEditRecord.phantomValid)        // DAW OFF on A2
        records[9] = MicPreEditRecord(stamp: 4, fields: MicPreEditRecord.phantomValid | MicPreEditRecord.phantomBit) // DAW ON on B2
        state.dropPendingPhantomProvenance(after: records)
        #expect(!state.pendingPhantomOn(unit: .a, channel: 1) && state.pendingPhantomOn(unit: .a, channel: 2))
        #expect(!state.pendingPhantomOn(unit: .b, channel: 1))
        state.finishPendingPhantomProvenance(unit: .a, identity: 42, records: nil)
        #expect(!state.pendingPhantomOn(unit: .a, channel: 2))
    }
}
