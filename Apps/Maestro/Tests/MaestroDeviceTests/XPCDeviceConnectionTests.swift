import Testing
import Foundation
@testable import MaestroDevice
@testable import MaestroCore

// MARK: - Mock XPC Transport

/// Mock XPC transport that records sent messages and returns configurable replies.
final class MockXPCTransport: XPCTransport, @unchecked Sendable {
    var _isConnected = true
    var setPropertyCalls: [(bRequest: UInt8, wValue: UInt16, wIndex: UInt16, data: Data)] = []
    var getPropertyCalls: [(bRequest: UInt8, wValue: UInt16, wIndex: UInt16, dataLength: UInt16)] = []

    /// Reply to return for getProperty calls.
    var nextReply: XPCPropertyReply = XPCPropertyReply(status: 0, data: Data([0]))

    /// Error to throw for getProperty calls (if set, overrides nextReply).
    var nextError: Error?

    var isConnected: Bool { _isConnected }

    /// Error to throw for setProperty calls (simulates a failed USB write).
    var nextSetError: Error?

    func sendSetProperty(bRequest: UInt8, wValue: UInt16, wIndex: UInt16, data: Data) async throws {
        setPropertyCalls.append((bRequest, wValue, wIndex, data))
        if let err = nextSetError { throw err }
    }

    func sendGetProperty(bRequest: UInt8, wValue: UInt16, wIndex: UInt16, dataLength: UInt16) async throws -> XPCPropertyReply {
        getPropertyCalls.append((bRequest, wValue, wIndex, dataLength))
        if let err = nextError { throw err }
        return nextReply
    }

    func getSoftwareMeterLevels() async -> (Float, Float)? {
        return nil  // Not available in test mock
    }

    var swReturnMuteCalls: [Bool] = []

    func setSwReturnMute(_ muted: Bool) {
        swReturnMuteCalls.append(muted)
    }

    var mixerParamCalls: [(usbCmd: UInt8, mixer: UInt16, channel: UInt16, value: UInt8)] = []

    func sendMixerParam(usbCmd: UInt8, mixer: UInt16, channel: UInt16, value: UInt8) {
        mixerParamCalls.append((usbCmd, mixer, channel, value))
    }

    var swReturnLevelCalls: [Double] = []

    func setSwReturnLevel(_ dB: Double) {
        swReturnLevelCalls.append(dB)
    }

    var swReturnPanCalls: [Double] = []

    func setSwReturnPan(_ pan: Double) {
        swReturnPanCalls.append(pan)
    }

    var swReturnProcessingCalls: [Bool] = []

    func setSwReturnProcessing(_ enabled: Bool) {
        swReturnProcessingCalls.append(enabled)
    }

    var swReturnSourceCalls: [UInt32] = []

    func setSwReturnSource(_ source: UInt32) {
        swReturnSourceCalls.append(source)
    }

    var routingModeCalls: [Int] = []

    func setRoutingMode(_ mode: Int) {
        routingModeCalls.append(mode)
    }

    /// Records that the audio path rebuild was requested.
    var resetAudioOutputCount = 0
    func resetAudioOutput() { resetAudioOutputCount += 1 }
}

// MARK: - Test Helpers

private func makeTestIdentifier() -> USBDeviceIdentifier {
    USBDeviceIdentifier(
        vendorID: ApogeeUSB.vendorID,
        productID: ApogeeUSB.SymphonyIO.pid16ch,
        deviceUID: "test-xpc-device"
    )!
}

// MARK: - XPCDeviceConnection Tests

@Suite("XPCDeviceConnection")
struct XPCDeviceConnectionTests {

    @Test func isConnectedDelegatestoTransport() {
        let transport = MockXPCTransport()
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)
        #expect(conn.isConnected == true)
        transport._isConnected = false
        #expect(conn.isConnected == false)
    }

    @Test func getPropertySendsCorrectUSBFields() async throws {
        let transport = MockXPCTransport()
        transport.nextReply = XPCPropertyReply(status: 0, data: Data([20]))
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)

        let value = try await conn.getProperty(PropertyAddress(selector: .outputLevel))
        #expect(value == .float64(-20.0))

        #expect(transport.getPropertyCalls.count == 1)
        let call = transport.getPropertyCalls[0]
        #expect(call.bRequest == SymphonyIOCommand.speakerOutputVolume.rawValue)
    }

    @Test func setPropertySendsCorrectUSBFields() async throws {
        let transport = MockXPCTransport()
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)

        try await conn.setProperty(
            PropertyAddress(selector: .outputMute),
            value: .bool(true))

        #expect(transport.setPropertyCalls.count == 1)
        let call = transport.setPropertyCalls[0]
        #expect(call.bRequest == SymphonyIOCommand.speakerOutputMute.rawValue)
    }

    @Test func getPropertyThrowsWhenDisconnected() async {
        let transport = MockXPCTransport()
        transport._isConnected = false
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)

        await #expect(throws: DeviceConnectionError.self) {
            try await conn.getProperty(PropertyAddress(selector: .outputLevel))
        }
    }

    @Test func setPropertyThrowsWhenDisconnected() async {
        let transport = MockXPCTransport()
        transport._isConnected = false
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)

        await #expect(throws: DeviceConnectionError.self) {
            try await conn.setProperty(
                PropertyAddress(selector: .outputMute),
                value: .bool(false))
        }
    }

    @Test func sampleRateReturnsCachedValue() async throws {
        let transport = MockXPCTransport()
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)

        // Default cache is 48000
        let value = try await conn.getProperty(PropertyAddress(selector: .sampleRate))
        #expect(value == .float64(48000.0))
        // No XPC call for cached property
        #expect(transport.getPropertyCalls.isEmpty)
    }

    @Test func sampleRateCacheUpdatesOnSet() async throws {
        let transport = MockXPCTransport()
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)

        try await conn.setProperty(
            PropertyAddress(selector: .sampleRate),
            value: .float64(96000.0))

        let cached = try await conn.getProperty(PropertyAddress(selector: .sampleRate))
        #expect(cached == .float64(96000.0))
    }

    @Test func clockSourceReturnsCachedValue() async throws {
        let transport = MockXPCTransport()
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)

        let value = try await conn.getProperty(PropertyAddress(selector: .clockSource))
        #expect(value == .uint32(0))
        #expect(transport.getPropertyCalls.isEmpty)
    }

    @Test func clockSourceCacheUpdatesOnSet() async throws {
        let transport = MockXPCTransport()
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)

        try await conn.setProperty(
            PropertyAddress(selector: .clockSource),
            value: .uint32(1))

        let cached = try await conn.getProperty(PropertyAddress(selector: .clockSource))
        #expect(cached == .uint32(1))
    }

    @Test func hasPropertyTrueForMappedSelectors() async {
        let transport = MockXPCTransport()
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)

        let hasMute = await conn.hasProperty(PropertyAddress(selector: .outputMute))
        #expect(hasMute == true)

        let hasRate = await conn.hasProperty(PropertyAddress(selector: .sampleRate))
        #expect(hasRate == true)
    }

    @Test func hasPropertyFalseForUnmapped() async {
        let transport = MockXPCTransport()
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)

        let has = await conn.hasProperty(PropertyAddress(selector: .daemonAlive))
        #expect(has == false)
    }

    @Test func readOnlyPropertyCannotBeSet() async {
        let transport = MockXPCTransport()
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)

        await #expect(throws: DeviceConnectionError.self) {
            try await conn.setProperty(
                PropertyAddress(selector: .version),
                value: .string("1.0.0"))
        }
    }

    @Test func isPropertySettableForOutputLevel() async {
        let transport = MockXPCTransport()
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)
        let settable = await conn.isPropertySettable(PropertyAddress(selector: .outputLevel))
        #expect(settable == true)
    }

    @Test func isPropertySettableFalseForVersion() async {
        let transport = MockXPCTransport()
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)
        let settable = await conn.isPropertySettable(PropertyAddress(selector: .version))
        #expect(settable == false)
    }

    @Test func getPropertyPropagatesTransportError() async {
        let transport = MockXPCTransport()
        transport.nextError = DeviceConnectionError.transportError("XPC reply error")
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)

        await #expect(throws: DeviceConnectionError.self) {
            try await conn.getProperty(PropertyAddress(selector: .outputLevel))
        }
    }

    @Test func getPropertyFailsOnNonZeroStatus() async {
        let transport = MockXPCTransport()
        transport.nextReply = XPCPropertyReply(status: -1, data: Data())
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)

        await #expect(throws: DeviceConnectionError.self) {
            try await conn.getProperty(PropertyAddress(selector: .outputLevel))
        }
    }

    @Test func setPropertyMultipleCallsTracked() async throws {
        let transport = MockXPCTransport()
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)

        try await conn.setProperty(PropertyAddress(selector: .outputMute), value: .bool(true))
        try await conn.setProperty(PropertyAddress(selector: .outputMute), value: .bool(false))

        #expect(transport.setPropertyCalls.count == 2)
    }

    // MARK: - S5: Failed USB Write Surfaces as Thrown Error

    /// A failed USB write (transport reply with non-zero status) must propagate
    /// as a thrown error from setProperty instead of a silent false success.
    @Test func setPropertyThrowsOnFailedUSBWrite() async {
        let transport = MockXPCTransport()
        transport.nextSetError = DeviceConnectionError.transportError("USB write failed: status -1")
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)

        await #expect(throws: DeviceConnectionError.self) {
            try await conn.setProperty(
                PropertyAddress(selector: .outputMute),
                value: .bool(true))
        }
        // The write was attempted (not swallowed) before the failure surfaced.
        #expect(transport.setPropertyCalls.count == 1)
    }

    /// When a write-only property's USB write fails, the write-only cache must be
    /// left unchanged — the failure means the hardware never accepted the value,
    /// so a subsequent read must not report the (unwritten) value as current.
    @Test func setPropertyLeavesCacheUnchangedOnFailedWrite() async throws {
        let transport = MockXPCTransport()
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)

        // Default cached value for peakHoldMode is 0.
        let before = try await conn.getProperty(PropertyAddress(selector: .peakHoldMode))
        #expect(before == .uint32(0))

        // Fail the USB write.
        transport.nextSetError = DeviceConnectionError.transportError("USB write failed: status -1")
        await #expect(throws: DeviceConnectionError.self) {
            try await conn.setProperty(
                PropertyAddress(selector: .peakHoldMode),
                value: .uint32(2))
        }

        // Cache must NOT have advanced to 2 — the write failed.
        let after = try await conn.getProperty(PropertyAddress(selector: .peakHoldMode))
        #expect(after == .uint32(0))
    }

    /// A successful write (no transport error) still updates the write-only cache.
    /// Guards against over-correcting the S5 fix into never updating the cache.
    @Test func setPropertyUpdatesCacheOnSuccessfulWrite() async throws {
        let transport = MockXPCTransport()
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)

        try await conn.setProperty(
            PropertyAddress(selector: .peakHoldMode),
            value: .uint32(2))

        #expect(transport.setPropertyCalls.count == 1)
        let cached = try await conn.getProperty(PropertyAddress(selector: .peakHoldMode))
        #expect(cached == .uint32(2))
    }

    @Test func identifierPreserved() {
        let transport = MockXPCTransport()
        let id = makeTestIdentifier()
        let conn = XPCDeviceConnection(identifier: id, transport: transport)
        #expect(conn.identifier == id)
    }

    @Test func micGainRoundTrip() async throws {
        let transport = MockXPCTransport()
        transport.nextReply = XPCPropertyReply(status: 0, data: Data([45]))
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)

        let address = PropertyAddress(selector: .micGain, element: 2)
        let value = try await conn.getProperty(address)
        #expect(value == .uint32(45))
    }

    @Test func phantomRoundTrip() async throws {
        let transport = MockXPCTransport()
        transport.nextReply = XPCPropertyReply(status: 0, data: Data([1]))
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)

        let value = try await conn.getProperty(PropertyAddress(selector: .phantom))
        #expect(value == .bool(true))
    }

    // MARK: - Write-Only Cached Property Tests

    @Test func peakHoldModeReturnsCachedDefault() async throws {
        let transport = MockXPCTransport()
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)

        let value = try await conn.getProperty(PropertyAddress(selector: .peakHoldMode))
        #expect(value == .uint32(0))
        #expect(transport.getPropertyCalls.isEmpty)  // No USB read — cached
    }

    @Test func peakHoldModeCacheUpdatesOnSet() async throws {
        let transport = MockXPCTransport()
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)

        try await conn.setProperty(
            PropertyAddress(selector: .peakHoldMode),
            value: .uint32(2))

        let cached = try await conn.getProperty(PropertyAddress(selector: .peakHoldMode))
        #expect(cached == .uint32(2))
    }

    @Test func oversHoldModeReturnsCachedDefault() async throws {
        let transport = MockXPCTransport()
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)

        let value = try await conn.getProperty(PropertyAddress(selector: .oversHoldMode))
        #expect(value == .uint32(0))
        #expect(transport.getPropertyCalls.isEmpty)
    }

    @Test func frontPanelMeterBankReadsHardwareNotCache() async throws {
        let transport = MockXPCTransport()
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)

        // SymphonyIOSettings: m_cMetersShow1, m_cMetersShow2, overs, peak.
        transport.nextReply = XPCPropertyReply(status: 0, data: Data([1, 0, 0, 0]))

        let value = try await conn.getProperty(PropertyAddress(selector: .frontPanelMeterBank))
        #expect(value == .uint32(1), "bank 1 source comes from byte 0 of the 0xDE block")
        #expect(transport.getPropertyCalls.count == 1,
                "must reach the device — answering from cache is what made the picker lie")
        #expect(transport.getPropertyCalls.first?.bRequest == 0xDE)
    }

    @Test func metersShowInputReadsEachBankFromItsOwnByte() async throws {
        let transport = MockXPCTransport()
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)

        // Bank 1 = Analog In 1-8 (1), bank 2 = Analog Out 1-8 (0). This is the real
        // dev-unit state that the pickers used to misreport as Out 1-8 on both.
        transport.nextReply = XPCPropertyReply(status: 0, data: Data([1, 0, 0, 0]))

        let bank1 = try await conn.getProperty(PropertyAddress(selector: .metersShowInput, element: 1))
        let bank2 = try await conn.getProperty(PropertyAddress(selector: .metersShowInput, element: 2))
        #expect(bank1 == .uint32(1))
        #expect(bank2 == .uint32(0))
        #expect(transport.getPropertyCalls.allSatisfy { $0.bRequest == 0xDE })
    }

    @Test func metersShowInputWriteStillUsesTheBankOpcode() async throws {
        let transport = MockXPCTransport()
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)

        try await conn.setProperty(
            PropertyAddress(selector: .metersShowInput, element: 2),
            value: .uint32(3))

        // Reads go to 0xDE, but writes still go to 0x10 -- with the bank in wIndex.
        let call = try #require(transport.setPropertyCalls.last)
        #expect(call.bRequest == 0x10)
        #expect(call.wValue == 0)
        #expect(call.wIndex == 1, "element 2 is the right bank, bank value 1")
        #expect(call.data == Data([3]))
    }

    @Test func prefixReturnsCachedDefault() async throws {
        let transport = MockXPCTransport()
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)

        let value = try await conn.getProperty(PropertyAddress(selector: .prefix))
        #expect(value == .string("A"))
        #expect(transport.getPropertyCalls.isEmpty)
    }

    @Test func prefixSetDoesNotSendUSB() async throws {
        let transport = MockXPCTransport()
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)

        try await conn.setProperty(
            PropertyAddress(selector: .prefix),
            value: .string("B"))

        // Prefix has no USB opcode — should not send any USB command
        #expect(transport.setPropertyCalls.isEmpty)

        let cached = try await conn.getProperty(PropertyAddress(selector: .prefix))
        #expect(cached == .string("B"))
    }

    @Test func keyboardVolumePeripheralIDReturnsCachedDefault() async throws {
        let transport = MockXPCTransport()
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)

        let value = try await conn.getProperty(PropertyAddress(selector: .keyboardVolumePeripheralID))
        #expect(value == .uint32(0))
        #expect(transport.getPropertyCalls.isEmpty)
    }

    @Test func keyboardVolumePeripheralIDSetDoesNotSendUSB() async throws {
        let transport = MockXPCTransport()
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)

        try await conn.setProperty(
            PropertyAddress(selector: .keyboardVolumePeripheralID),
            value: .uint32(5))

        #expect(transport.setPropertyCalls.isEmpty)

        let cached = try await conn.getProperty(PropertyAddress(selector: .keyboardVolumePeripheralID))
        #expect(cached == .uint32(5))
    }

    @Test func keyboardVolumeOutputIDReturnsCachedDefault() async throws {
        let transport = MockXPCTransport()
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)

        let value = try await conn.getProperty(PropertyAddress(selector: .keyboardVolumeOutputID))
        #expect(value == .uint32(0))
        #expect(transport.getPropertyCalls.isEmpty)
    }

    @Test func keyboardVolumeOutputIDSetDoesNotSendUSB() async throws {
        let transport = MockXPCTransport()
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)

        try await conn.setProperty(
            PropertyAddress(selector: .keyboardVolumeOutputID),
            value: .uint32(3))

        #expect(transport.setPropertyCalls.isEmpty)

        let cached = try await conn.getProperty(PropertyAddress(selector: .keyboardVolumeOutputID))
        #expect(cached == .uint32(3))
    }

    // MARK: - USB Health Check Probe

    /// Health check uses deviceMode as a lightweight read-only probe.
    /// Verifies it sends the correct USB fields via XPC.
    @Test func healthCheckProbeReadsDeviceMode() async throws {
        let transport = MockXPCTransport()
        transport.nextReply = XPCPropertyReply(status: 0, data: Data([0]))
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)

        _ = try await conn.getProperty(PropertyAddress(selector: .deviceMode))

        #expect(transport.getPropertyCalls.count == 1)
        let call = transport.getPropertyCalls[0]
        #expect(call.bRequest == SymphonyIOCommand.symphonyIOMode.rawValue)
    }

    /// Health check probe should throw when transport is disconnected,
    /// which triggers proxy-side USB recovery.
    @Test func healthCheckProbeThrowsWhenDisconnected() async {
        let transport = MockXPCTransport()
        transport._isConnected = false
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)

        await #expect(throws: DeviceConnectionError.self) {
            try await conn.getProperty(PropertyAddress(selector: .deviceMode))
        }
    }

    /// Health check probe should propagate transport errors (stale USB handle).
    @Test func healthCheckProbePropagatesTransportError() async {
        let transport = MockXPCTransport()
        transport.nextError = DeviceConnectionError.transportError("USB stale handle")
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)

        await #expect(throws: DeviceConnectionError.self) {
            try await conn.getProperty(PropertyAddress(selector: .deviceMode))
        }
    }

    // MARK: - Software Mute

    @Test func setSwReturnMuteDelegatesToTransport() {
        let transport = MockXPCTransport()
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)

        conn.setSwReturnMute(true)
        conn.setSwReturnMute(false)

        #expect(transport.swReturnMuteCalls == [true, false])
    }

    @Test func sendMixerParamDelegatesToTransport() {
        let transport = MockXPCTransport()
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)

        conn.sendMixerParam(usbCmd: 0xB0, mixer: 1, channel: 1000, value: 42)
        conn.sendMixerParam(usbCmd: 0xB1, mixer: 1, channel: 1000, value: 50)

        #expect(transport.mixerParamCalls.count == 2)
        #expect(transport.mixerParamCalls[0].usbCmd == 0xB0)
        #expect(transport.mixerParamCalls[0].value == 42)
        #expect(transport.mixerParamCalls[1].usbCmd == 0xB1)
        #expect(transport.mixerParamCalls[1].value == 50)
    }

    // MARK: - Recovery Detection Pattern Tests

    /// Verify the recovery detection state machine logic:
    /// failure→success transition should be detectable.
    @Test func recoveryDetectionStateMachine() {
        // Simulate the state machine used in AppState meter polling.
        var meterPollWasDisconnected = false
        var deviceRecoveryCount = 0
        var lastRecoveryTime = Date.distantPast

        // Initial state: not disconnected
        #expect(meterPollWasDisconnected == false)
        #expect(deviceRecoveryCount == 0)

        // Simulate TDM read failure
        meterPollWasDisconnected = true
        #expect(meterPollWasDisconnected == true)

        // Simulate TDM read success (recovery)
        if meterPollWasDisconnected {
            meterPollWasDisconnected = false
            let now = Date()
            if now.timeIntervalSince(lastRecoveryTime) > 5.0 {
                lastRecoveryTime = now
                deviceRecoveryCount += 1
            }
        }
        #expect(deviceRecoveryCount == 1)
        #expect(meterPollWasDisconnected == false)
    }

    /// Verify debounce prevents duplicate recovery events within 5 seconds.
    @Test func recoveryDebouncePreventsDuplicates() {
        var deviceRecoveryCount = 0
        var lastRecoveryTime = Date.distantPast

        // First recovery — should increment
        let now = Date()
        if now.timeIntervalSince(lastRecoveryTime) > 5.0 {
            lastRecoveryTime = now
            deviceRecoveryCount += 1
        }
        #expect(deviceRecoveryCount == 1)

        // Immediate second recovery (within 5s) — should NOT increment
        if now.timeIntervalSince(lastRecoveryTime) > 5.0 {
            lastRecoveryTime = now
            deviceRecoveryCount += 1
        }
        #expect(deviceRecoveryCount == 1, "Debounce should prevent duplicate increment")
    }

    /// Verify no recovery when auto-recover is disabled.
    @Test func noRecoveryWhenAutoRecoverDisabled() {
        var meterPollWasDisconnected = true
        var deviceRecoveryCount = 0
        let autoRecover = false  // User disabled

        if meterPollWasDisconnected {
            meterPollWasDisconnected = false
            if autoRecover {
                deviceRecoveryCount += 1
            }
        }
        #expect(deviceRecoveryCount == 0, "Should not increment when auto-recover is disabled")
        #expect(meterPollWasDisconnected == false, "Disconnected flag should still clear")
    }

    /// Verify SW Return re-sync sends correct proxy calls during recovery.
    @Test func swReturnResyncedOnRecovery() {
        let transport = MockXPCTransport()
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)

        // Simulate what recovery code does: re-sync SW Return
        conn.setSwReturnMute(true)
        conn.setSwReturnLevel(-6.0)
        conn.setSwReturnPan(0.5)

        #expect(transport.swReturnMuteCalls == [true])
        #expect(transport.swReturnLevelCalls == [-6.0])
        #expect(transport.swReturnPanCalls == [0.5])
    }

    // MARK: - Routing Mode

    @Test func setRoutingModeDelegatesToTransport() {
        let transport = MockXPCTransport()
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)

        conn.setRoutingMode(0)  // DAW
        conn.setRoutingMode(1)  // Direct Monitor

        #expect(transport.routingModeCalls == [0, 1])
    }

    // MARK: - DAW Force-Mute Pattern

    /// Verify the force-mute batch pattern: 2 mixers x 32 channels = 64 mute commands.
    /// This is the pattern used by the app in DAW mode to silence all HW mixer inputs.
    @Test func dawForceMuteBatchPattern() {
        let transport = MockXPCTransport()
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)

        // Simulate the DAW force-mute loop from MaestroApp
        for mixerID: UInt16 in 1...2 {
            for ch: UInt16 in 0..<32 {
                conn.sendMixerParam(usbCmd: 0xB3, mixer: mixerID, channel: ch, value: 1)
            }
        }

        #expect(transport.mixerParamCalls.count == 64)
        // All calls should be mute command (0xB3) with value 1 (muted)
        for call in transport.mixerParamCalls {
            #expect(call.usbCmd == 0xB3)
            #expect(call.value == 1)
        }
        // First 32 calls are mixer 1, next 32 are mixer 2
        for i in 0..<32 {
            #expect(transport.mixerParamCalls[i].mixer == 1)
            #expect(transport.mixerParamCalls[i].channel == UInt16(i))
        }
        for i in 32..<64 {
            #expect(transport.mixerParamCalls[i].mixer == 2)
            #expect(transport.mixerParamCalls[i].channel == UInt16(i - 32))
        }
    }

    /// Verify Direct Monitor restore: unmute all channels (value 0) when no persisted state.
    @Test func directMonitorRestoreUnmutesAll() {
        let transport = MockXPCTransport()
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)

        // Simulate the Direct Monitor fallback (no persisted state) from MaestroApp
        for mixerID: UInt16 in 1...2 {
            for ch: UInt16 in 0..<32 {
                conn.sendMixerParam(usbCmd: 0xB3, mixer: mixerID, channel: ch, value: 0)
            }
        }

        #expect(transport.mixerParamCalls.count == 64)
        for call in transport.mixerParamCalls {
            #expect(call.usbCmd == 0xB3)
            #expect(call.value == 0)  // unmuted
        }
    }

    /// Verify routing mode + force-mute sequence: setRoutingMode then batch mute.
    @Test func routingModeAndForceMuteSequence() {
        let transport = MockXPCTransport()
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)

        // DAW mode: set routing then force-mute
        conn.setRoutingMode(0)
        for mixerID: UInt16 in 1...2 {
            for ch: UInt16 in 0..<32 {
                conn.sendMixerParam(usbCmd: 0xB3, mixer: mixerID, channel: ch, value: 1)
            }
        }

        #expect(transport.routingModeCalls == [0])
        #expect(transport.mixerParamCalls.count == 64)

        // Switch to Direct Monitor: set routing then unmute
        conn.setRoutingMode(1)
        for mixerID: UInt16 in 1...2 {
            for ch: UInt16 in 0..<32 {
                conn.sendMixerParam(usbCmd: 0xB3, mixer: mixerID, channel: ch, value: 0)
            }
        }

        #expect(transport.routingModeCalls == [0, 1])
        #expect(transport.mixerParamCalls.count == 128)  // 64 mute + 64 unmute
    }

    /// SW Return uses separate dedicated function — never part of force-mute batch.
    @Test func swReturnMuteIndependentOfForceMute() {
        let transport = MockXPCTransport()
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)

        // Force-mute all HW inputs
        for mixerID: UInt16 in 1...2 {
            for ch: UInt16 in 0..<32 {
                conn.sendMixerParam(usbCmd: 0xB3, mixer: mixerID, channel: ch, value: 1)
            }
        }
        // SW Return mute is a separate path
        conn.setSwReturnMute(false)

        // mixerParam calls should NOT contain SW Return (channel 1000)
        for call in transport.mixerParamCalls {
            #expect(call.channel != 1000, "Force-mute should not touch SW Return channel")
        }
        // SW Return mute goes through dedicated function
        #expect(transport.swReturnMuteCalls == [false])
    }
}
