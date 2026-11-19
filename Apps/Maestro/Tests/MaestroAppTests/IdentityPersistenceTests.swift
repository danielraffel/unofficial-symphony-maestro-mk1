import Foundation
import Testing
@testable import MaestroApp
import MaestroCore
import MaestroDevice

private actor SuspendedIdentityRead {
    private var readContinuation: CheckedContinuation<UInt64?, Never>?
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var started = false

    func read() async -> UInt64? {
        await withCheckedContinuation {
            readContinuation = $0
            started = true
            startContinuation?.resume()
            startContinuation = nil
        }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startContinuation = $0 }
    }
    func finish(_ identity: UInt64?) {
        readContinuation?.resume(returning: identity)
        readContinuation = nil
    }
}

@Suite("Identity connection boundaries", .serialized)
@MainActor
struct IdentityPersistenceTests {
    @Test func callerCancellationDoesNotCancelIdentity() async {
        let state = AppState()
        let connection = SimulatedDevice.symphonyIO32ch()
        state.device = connection
        let gate = SuspendedIdentityRead()
        let operation = Task {
            await state.resolveUnitIdentity(for: .a, connection: connection) { await gate.read() }
        }
        await gate.waitUntilStarted()
        operation.cancel()
        await gate.finish(42)
        await operation.value
        #expect(state.unitAIdentityState == .known(42))
    }

    @Test func failedReadRetriesOnlyAtNextRecovery() async {
        let state = AppState()
        let connection = SimulatedDevice.symphonyIO32ch()
        state.device = connection
        await state.resolveUnitIdentity(for: .a, connection: connection) { nil }
        state.retryFailedIdentityOnRecovery()
        #expect(state.unitAIdentityState == .pending)
        await state.resolveUnitIdentity(for: .a, connection: connection) { nil }
        state.retryFailedIdentityOnRecovery()
        #expect(state.unitAIdentityState == .failed)
        state.device = SimulatedDevice.symphonyIO32ch()
        #expect(!state.identityRecoveryRetried)
    }

    @Test(arguments: [DeviceUnit.a, .b])
    func replacementDiscardsSuspendedRead(unit: DeviceUnit) async {
        let state = AppState()
        let original = SimulatedDevice.symphonyIO32ch()
        let replacement = SimulatedDevice.symphonyIO32ch()
        state.device = SimulatedDevice.symphonyIO32ch()
        if unit == .a { state.device = original } else { state.unitBDevice = original }
        let parent = state.device
        let gate = SuspendedIdentityRead()
        let read = Task { await state.resolveUnitIdentity(for: unit, connection: original) { await gate.read() } }
        await gate.waitUntilStarted()
        if unit == .a { state.device = replacement } else { state.unitBDevice = replacement }
        #expect((unit == .a ? state.unitAIdentityState : state.unitBIdentityState) == .pending)
        await gate.finish(42)
        await read.value
        #expect((unit == .a ? state.unitAIdentity : state.unitBIdentity) == nil)
        if unit == .b { #expect(state.device === parent) }
        await state.resolveUnitIdentity(for: unit, connection: replacement) { 43 }
        #expect((unit == .a ? state.unitAIdentity : state.unitBIdentity) == 43)
    }

    @Test func converterTransitionClearsKnownAndPendingIdentity() async {
        let state = AppState()
        let connection = SimulatedDevice.symphonyIO32ch()
        state.device = connection
        state.unitAIdentity = 42
        state.connectedUnit = ConnectedUnit(probeWord: 0x8000_0000)
        #expect(state.unitAIdentity == nil)
        #expect(state.unitAIdentityState == .failed)
        state.connectedUnit = nil
        let gate = SuspendedIdentityRead()
        let read = Task { await state.resolveUnitIdentity(for: .a, connection: connection) { await gate.read() } }
        await gate.waitUntilStarted()
        state.connectedUnit = ConnectedUnit(probeWord: 0x8000_0000)
        await gate.finish(42)
        await read.value
        #expect(state.unitAIdentity == nil)
        #expect(state.unitAIdentityState == .failed)
    }

    @Test func knownIdentityIsStickyAndFailureIsExplicit() async {
        let state = AppState()
        let connection = SimulatedDevice.symphonyIO32ch()
        state.device = connection
        await state.resolveUnitIdentity(for: .a, connection: connection) { 42 }
        await state.resolveUnitIdentity(for: .a, connection: connection) {
            Issue.record("Known identity must not be retried during recovery")
            return nil
        }
        #expect(state.unitAIdentityState == .known(42))
        state.device = SimulatedDevice.symphonyIO32ch()
        let replacement = state.device!
        await state.resolveUnitIdentity(for: .a, connection: replacement) { nil }
        #expect(state.unitAIdentityState == .failed)
        await state.resolveUnitIdentity(for: .a, connection: replacement) {
            Issue.record("Failed discovery must not retry on every health tick")
            return 43
        }
        #expect(state.unitAIdentity == nil)
    }
}
