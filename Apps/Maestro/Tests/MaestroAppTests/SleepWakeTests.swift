import Foundation
import Testing
@testable import MaestroApp
import MaestroDevice
import MaestroCore

@Suite("Sleep/wake hardware admission", .serialized)
@MainActor
struct SleepWakeTests {
    func state(_ connection: any DeviceConnection) -> AppState {
        let state = AppState()
        state.device = connection
        state.connectionMode = .hardware
        state.transportType = .thunderbolt
        state.wakeRetryInterval = .milliseconds(1)
        state.wakeRetryLimit = 3
        state.wakeReadTimeout = .milliseconds(5)
        return state
    }

    @Test func writesAreRefusedWhileAsleep() async {
        let connection = WakeConnection()
        let state = state(connection)
        state.suspendTwoUnitReplay()
        do {
            try await connection.setProperty(PropertyAddress(selector: .outputMute), value: .uint32(1))
            Issue.record("a sleeping connection accepted a write")
        } catch { #expect(connection.writeCount == 0) }
    }

    @Test func wakeTaskOpensGateAndStartsMetersWithoutView() async {
        let connection = WakeConnection()
        let state = state(connection)
        defer { state.stopMeterPolling() }
        state.suspendTwoUnitReplay()
        state.wakeTwoUnitReplay()
        await state.wakeReconnectTask?.value
        #expect(!state.hardwareWritesSuspended)
        #expect(connection.hardwareWriteGate?.allowsWrites == true)
        #expect(state.meterPollingTask != nil)
        #expect(connection.writeCount == 0)
    }

    @Test func missingDidWakeNotificationUsesBoundedFallback() async {
        let connection = WakeConnection()
        let state = state(connection)
        state.wakeFallbackDelay = .milliseconds(1)
        state.wakeFallbackAbortLimit = .milliseconds(5) // no real sleep in a test: aborted-sleep path
        defer { state.stopMeterPolling() }
        state.suspendTwoUnitReplay()
        await state.wakeFallbackTask?.value
        await state.wakeReconnectTask?.value
        #expect(state.hardwareSleepState == .awake)
        #expect(!state.hardwareWritesSuspended)
    }

    /// 2026-11-22: a USB device that went away while a reconnect was running
    /// asked for another reconnect, which was dropped, and Maestro stayed on
    /// the old USB connection, "Disconnected", until relaunched.
    @Test func reconnectRequestedDuringReconnectIsNotDropped() async {
        let state = state(WakeConnection(failSupportedRead: false))
        var runs = 0
        var release: CheckedContinuation<Void, Never>?
        state.reconnectOperation = {
            runs += 1
            if runs == 1 { await withCheckedContinuation { release = $0 } }
        }
        let first = Task { @MainActor in await state.reconnectHardware() }
        while release == nil { await Task.yield() }
        await state.reconnectHardware()          // the device-list change meanwhile
        await state.reconnectHardware()          // and another: coalesced
        #expect(runs == 1)
        release?.resume()
        await first.value
        for _ in 0..<50 where runs < 2 { await Task.yield() }
        #expect(runs == 2)
        for _ in 0..<20 { await Task.yield() }
        #expect(runs == 2)
    }

    @Test func failedWakeReadExhaustsAndReconnectsWithDisconnectBookkeeping() async {
        let connection = WakeConnection(failSupportedRead: true)
        let state = state(connection)
        var reconnects = 0
        state.reconnectOperation = {
            reconnects += 1
            #expect(state.awaitingSymphonyReturn)
            #expect(state.statusMessage == "Symphony disconnected")
            #expect(state.connectionMode == .disconnected)
            #expect(state.inputMeterLevels.allSatisfy { $0 == -60 })
        }
        state.inputMeterLevels = [0, -1]
        state.suspendTwoUnitReplay()
        state.wakeTwoUnitReplay()
        await state.wakeReconnectTask?.value
        #expect(!state.hardwareWritesSuspended)
        #expect(reconnects == 1)
        #expect(connection.readSelectors.count == 3)
        #expect(connection.hardwareWriteGate?.allowsWrites == false)
    }

    @Test(arguments: [false, true])
    func suspendedReconnectIsReplayedOnSuccessAndExhaustion(fails: Bool) async {
        let connection = WakeConnection(failSupportedRead: fails)
        let state = state(connection)
        var reconnects = 0
        state.reconnectOperation = { reconnects += 1 }
        state.suspendTwoUnitReplay()
        await state.reconnectHardware()
        #expect(state.reconnectRequestedWhileSuspended)
        state.wakeTwoUnitReplay()
        await state.reconnectHardware()
        let wake = state.wakeReconnectTask
        await wake?.value
        // The success path schedules a separate task; bounded yields allow it to run.
        for _ in 0..<100 where reconnects == 0 { await Task.yield() }
        #expect(reconnects == 1)
        #expect(!state.reconnectRequestedWhileSuspended)
        #expect(!state.hardwareWritesSuspended)
    }

    @Test func interruptedLaunchAdmissionRequestsReconnect() async {
        let state = state(WakeConnection())
        var reconnects = 0
        state.reconnectOperation = { reconnects += 1 }
        state.launchDiscoveryPending = true
        state.launchDiscoveryOperation = {
            state.suspendTwoUnitReplay()
            return []
        }
        await state.completeLaunchDiscovery()
        #expect(state.reconnectRequestedWhileSuspended)
        state.wakeTwoUnitReplay()
        await state.wakeReconnectTask?.value
        for _ in 0..<100 where reconnects == 0 { await Task.yield() }
        #expect(reconnects == 1)
    }

    @Test func reconnectSpanningWholeSleepGenerationRestarts() async {
        let state = state(WakeConnection())
        var reconnects = 0
        state.reconnectOperation = {
            reconnects += 1
            if reconnects == 1 {
                state.suspendTwoUnitReplay()
                state.wakeTwoUnitReplay()
                await state.wakeReconnectTask?.value
            }
        }
        await state.reconnectHardware()
        for _ in 0..<100 where reconnects < 2 { await Task.yield() }
        #expect(reconnects == 2)
        #expect(!state.hardwareWritesSuspended)
    }

    @Test func usbSwitchTaskSurvivesWatchCancellation() async {
        let state = state(WakeConnection())
        state.transportType = .usb
        var completed = false
        state.reconnectOperation = {
            await Task.yield()
            completed = !Task.isCancelled
        }
        var switched: Task<Void, Never>?
        state.thunderboltWatchTask = Task { switched = state.scheduleThunderboltSwitch() }
        await state.thunderboltWatchTask?.value
        await switched?.value
        #expect(completed)
        #expect(state.thunderboltWatchTask?.isCancelled == true)
    }

    @Test func hungUSBReadTimesOutAndLateReplyCannotOpenRetiredGate() async {
        let connection = WakeConnection(hang: true)
        let state = state(connection)
        var reconnects = 0
        state.reconnectOperation = { reconnects += 1 }
        state.suspendTwoUnitReplay()
        state.wakeTwoUnitReplay()
        await state.wakeReconnectTask?.value
        #expect(reconnects == 1)
        #expect(!state.hardwareWritesSuspended)
        connection.releaseReads()
        for _ in 0..<10 { await Task.yield() }
        #expect(connection.hardwareWriteGate?.allowsWrites == false)
        #expect(!state.isHardwareInitialized)
    }

    @Test func validatingStatusOverridesDisconnectedStatus() {
        let state = state(WakeConnection())
        state.markHardwareDisconnected()
        state.hardwareSleepState = .validating
        #expect(state.endpointStatusMessage == "Validating hardware after wake…")
    }

    @Test func healthLoopDefersDuringSleepAndDoesNotDuplicateWakeTask() async {
        let connection = WakeConnection(failSupportedRead: true)
        let state = state(connection)
        var reconnects = 0
        state.reconnectOperation = { reconnects += 1 }
        state.suspendTwoUnitReplay()
        let asleep = state.deferHealthCheckForSleep()
        #expect(asleep)
        #expect(state.wakeReconnectTask == nil)
        state.wakeTwoUnitReplay()
        for _ in 0..<4 {
            let deferred = state.deferHealthCheckForSleep()
            #expect(deferred)
        }
        await state.wakeReconnectTask?.value
        #expect(connection.readSelectors.count == 3)
        #expect(reconnects == 1)
        let awake = state.deferHealthCheckForSleep()
        #expect(!awake)
    }

    @Test func replacementWhileValidatingReconnectsAndKeepsNewGateClosed() async {
        let old = WakeConnection(hang: true)
        let replacement = WakeConnection()
        let state = state(old)
        var reconnects = 0
        state.reconnectOperation = { reconnects += 1 }
        state.suspendTwoUnitReplay()
        state.wakeTwoUnitReplay()
        await Task.yield()
        state.device = replacement
        old.releaseReads()
        await state.wakeReconnectTask?.value
        for _ in 0..<100 where reconnects == 0 { await Task.yield() }
        old.releaseReads()
        #expect(reconnects == 1)
        #expect(replacement.hardwareWriteGate?.allowsWrites == false)
        #expect(!state.hardwareWritesSuspended)
    }

    @Test func repeatedSleepInvalidatesOldWakeCompletion() async {
        let connection = WakeConnection(hang: true)
        let state = state(connection)
        state.suspendTwoUnitReplay()
        state.wakeTwoUnitReplay()
        let oldTask = state.wakeReconnectTask
        await Task.yield()
        state.suspendTwoUnitReplay()
        connection.releaseReads()
        await oldTask?.value
        connection.releaseReads()
        #expect(state.hardwareSleepState == .sleeping)
        #expect(connection.hardwareWriteGate?.allowsWrites == false)
        #expect(state.meterPollingTask == nil)
    }

    func link(ticks: UInt32 = 2, recovery: UInt32 = 0, suspended: Bool = false,
              status: LinkState.State = .up) -> LinkState {
        LinkState(state: status, clockPresent: true, ioRunning: false, irqCount: 0,
                  recoveryCount: recovery, hwSuspended: suspended, linkConfigured: true,
                  lastClockReg: 0, watchTicks: ticks, audioWraps: 0)
    }

    @Test func stableProofRejectsSuspensionAndRestartsAfterBadProbe() {
        let state = state(WakeConnection())
        state.wakeBaselineWatchTicks = 100
        state.wakeBaselineRecoveryCount = 0
        let first = state.wakeProbeIsStable(link()) // restarted counter
        let bad = state.wakeProbeIsStable(link(suspended: true))
        let next = state.wakeProbeIsStable(link())
        let final = state.wakeProbeIsStable(link())
        #expect(!first && !bad && !next && final)
    }

    @Test func realThunderboltReadTableNeedsNoVendorReadsOnWake() async {
        let connection = await Task.detached {
            ThunderboltDeviceConnection(identifier: SimulatedDevice.symphonyIO32ch().identifier, audioDeviceID: 0)
        }.value
        // This is the actual transport read table, not a fake answering all selectors.
        do {
            _ = try await connection.getProperty(PropertyAddress(selector: .headphone1Level))
            Issue.record("headphone1Level unexpectedly implemented")
        } catch DeviceConnectionError.unsupportedProperty(_) {} catch { Issue.record(error) }
        let state = state(connection)
        defer { state.stopMeterPolling() }
        let healthy = link()
        state.wakeLinkProbe = { _ in healthy }
        state.suspendTwoUnitReplay()
        state.wakeTwoUnitReplay()
        await state.wakeReconnectTask?.value
        // With no user client, any vendor read would fail. Cached link proof alone succeeds.
        #expect(state.isHardwareInitialized)
        #expect(!state.hardwareWritesSuspended)
        await connection.disconnect()
    }

    @Test func thunderboltWakeDownHandsOffToHealthLoopAfterThreeNoClockProbes() async {
        let connection = await Task.detached {
            ThunderboltDeviceConnection(identifier: SimulatedDevice.symphonyIO32ch().identifier, audioDeviceID: 0)
        }.value
        let state = state(connection)
        state.wakeRetryInterval = .milliseconds(1)
        state.wakeRetryLimit = 10
        state.wakeLinkProbe = { _ in
            LinkState(state: .down, clockPresent: false, ioRunning: false, irqCount: 0,
                      recoveryCount: 1, hwSuspended: false, linkConfigured: true,
                      lastClockReg: 0, watchTicks: 1, audioWraps: 0)
        }
        state.suspendTwoUnitReplay()
        state.wakeTwoUnitReplay()
        await state.wakeReconnectTask?.value
        #expect(state.hardwareSleepState == .awake)
        #expect(state.connectionMode == .disconnected)
        #expect(state.awaitingSymphonyReturn)
        #expect(!state.isHardwareInitialized)
        state.stopThunderboltHealthCheck()
        await connection.disconnect()
    }

    @Test func thunderboltWakeKeepsRecoveringProbeInValidation() {
        let state = state(WakeConnection())
        let recovering = link(status: .recovering)
        #expect(!state.wakeProbeIsStable(recovering))
        #expect(state.hardwareSleepState == .awake)
    }

    @Test func thunderboltWakeStaleClientReconnectsImmediatelyWhenLinkStateMissing() async {
        let connection = await Task.detached {
            ThunderboltDeviceConnection(identifier: SimulatedDevice.symphonyIO32ch().identifier, audioDeviceID: 0)
        }.value
        let state = state(connection)
        state.wakeRetryLimit = 30
        state.wakeRetryInterval = .seconds(10)
        var reconnects = 0
        state.reconnectOperation = { reconnects += 1 }
        state.wakeLinkProbe = { _ in nil }
        state.suspendTwoUnitReplay()
        state.wakeTwoUnitReplay()
        await state.wakeReconnectTask?.value
        #expect(reconnects == 1)
        #expect(state.hardwareSleepState == .awake)
        #expect(!state.reconnectRequestedWhileSuspended)
        await connection.disconnect()
    }

    @Test func removedDeviceDuringValidationEndsValidationBeforeReconnect() async {
        let state = state(WakeConnection())
        var reconnects = 0
        state.reconnectOperation = { reconnects += 1 }
        state.hardwareSleepState = .validating
        state.connectionMode = .disconnected
        await state.reconnectHardware()
        #expect(reconnects == 1)
        #expect(state.hardwareSleepState == .awake)
        #expect(!state.hardwareWritesSuspended)
    }

    @Test func fallbackDoesNotFireBeforeSleepOrAbortLimit() async {
        let connection = WakeConnection()
        let state = state(connection)
        state.wakeFallbackDelay = .milliseconds(1)
        state.wakeFallbackAbortLimit = .seconds(30)
        defer { state.wakeFallbackTask?.cancel(); state.stopMeterPolling() }
        state.suspendTwoUnitReplay()
        try? await Task.sleep(for: .milliseconds(300))
        // No sleep happened and the abort limit is far away: still suspended.
        let stillSleeping = state.hardwareSleepState
        #expect(stillSleeping == .sleeping)
    }

    @Test func realDidWakeAfterFallbackValidatesAgain() async {
        let connection = WakeConnection()
        let state = state(connection)
        state.wakeFallbackDelay = .milliseconds(1)
        state.wakeFallbackAbortLimit = .milliseconds(5)
        defer { state.stopMeterPolling() }
        state.suspendTwoUnitReplay()
        await state.wakeFallbackTask?.value
        await state.wakeReconnectTask?.value
        let afterFallback = state.hardwareSleepState
        let fired = state.wakeFallbackFired
        #expect(afterFallback == .awake)
        #expect(fired)
        state.wakeTwoUnitReplay() // the real didWake arrives later
        let firedAfterWake = state.wakeFallbackFired
        let stateAfterWake = state.hardwareSleepState
        #expect(!firedAfterWake)
        #expect(stateAfterWake != .sleeping)
        await state.wakeReconnectTask?.value
        #expect(state.hardwareSleepState == .awake)
    }
}

private final class WakeConnection: DeviceConnection, @unchecked Sendable {
    let identifier = SimulatedDevice.symphonyIO32ch().identifier
    let isConnected = true
    let hardwareWriteGate: HardwareWriteGate? = HardwareWriteGate()
    let failSupportedRead: Bool
    let hang: Bool
    private let lock = NSLock()
    private var writes = 0
    private var reads: [AudioPropertySelector] = []
    private var pending: [CheckedContinuation<PropertyValue, Error>] = []
    var writeCount: Int { lock.withLock { writes } }
    var readSelectors: [AudioPropertySelector] { lock.withLock { reads } }

    init(failSupportedRead: Bool = false, hang: Bool = false) {
        self.failSupportedRead = failSupportedRead
        self.hang = hang
    }
    func releaseReads() {
        let continuations = lock.withLock { let result = pending; pending = []; return result }
        for continuation in continuations { continuation.resume(returning: .uint32(0)) }
    }
    func getProperty(_ address: PropertyAddress) async throws -> PropertyValue {
        lock.withLock { reads.append(address.selector) }
        if hang {
            return try await withCheckedThrowingContinuation { continuation in
                lock.withLock { pending.append(continuation) }
            }
        }
        if failSupportedRead { throw DeviceConnectionError.notConnected }
        switch address.selector {
        case .outputLevel, .outputMute: return .uint32(20)
        default: throw DeviceConnectionError.unsupportedProperty(address.selector)
        }
    }
    func setProperty(_ address: PropertyAddress, value: PropertyValue) async throws {
        try hardwareWriteGate?.check()
        lock.withLock { writes += 1 }
    }
    func hasProperty(_ address: PropertyAddress) async -> Bool { true }
    func isPropertySettable(_ address: PropertyAddress) async -> Bool { true }
    func addListener(_ listener: PropertyListener, for address: PropertyAddress) async {}
    func removeListener(_ listener: PropertyListener, for address: PropertyAddress) async {}
    func disconnect() async {}
}
