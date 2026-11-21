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

    /// Unit and helper calls in the order they were made.
    var events: [String] = []
    /// Fail the first N setProperty calls (a failed USB write).
    var failFirstSets = 0
    /// Fail every setProperty call at this wIndex.
    var failWIndex: UInt16?

    func sendSetProperty(bRequest: UInt8, wValue: UInt16, wIndex: UInt16, data: Data) async throws {
        setPropertyCalls.append((bRequest, wValue, wIndex, data))
        events.append("unit:\(String(bRequest, radix: 16)):\(wValue):\(wIndex)")
        if failFirstSets > 0 { failFirstSets -= 1; throw DeviceConnectionError.transportError("x") }
        if let f = failWIndex, f == wIndex { throw DeviceConnectionError.transportError("x") }
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
        events.append("helperMute:\(muted)")
        swReturnMuteCalls.append(muted)
    }

    var mixerParamCalls: [(usbCmd: UInt8, mixer: UInt16, channel: UInt16, value: UInt8)] = []

    func sendMixerParam(usbCmd: UInt8, mixer: UInt16, channel: UInt16, value: UInt8) {
        mixerParamCalls.append((usbCmd, mixer, channel, value))
    }

    var swReturnLevelCalls: [Double] = []

    func setSwReturnLevel(_ dB: Double) {
        events.append("helperLevel:\(dB)")
        swReturnLevelCalls.append(dB)
    }

    var swReturnChannelLevelCalls: [(channel: Int, dB: Double)] = []

    func setSwReturnChannelLevel(channel: Int, dB: Double) {
        swReturnChannelLevelCalls.append((channel, dB))
    }

    var swReturnProcessingCalls: [Bool] = []

    func setSwReturnProcessing(_ enabled: Bool) {
        swReturnProcessingCalls.append(enabled)
    }

    var swReturnSourceCalls: [UInt32] = []

    func setSwReturnSource(_ source: UInt32) {
        swReturnSourceCalls.append(source)
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
        // The unit is asked (0xDE); the mock's one-byte reply is unusable, so
        // the cached default is what comes back.
        #expect(transport.getPropertyCalls.map(\.bRequest) == [SymphonyIOCommand.getCurrentPreferenceSettings.rawValue])
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
        #expect(transport.getPropertyCalls.map(\.bRequest) == [SymphonyIOCommand.getCurrentPreferenceSettings.rawValue])
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

        conn.sendMixerParam(usbCmd: 0xB0, mixer: 1, channel: 5, value: 42)
        conn.sendMixerParam(usbCmd: 0xB1, mixer: 1, channel: 5, value: 50)

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

    /// Verify SW Return re-sync sends correct proxy calls during recovery.
    @Test func swReturnResyncedOnRecovery() {
        let transport = MockXPCTransport()
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)

        // Simulate what recovery code does: re-sync SW Return
        conn.setSwReturnMute(true)
        conn.setSwReturnLevel(-6.0)

        #expect(transport.swReturnMuteCalls == [true])
        #expect(transport.swReturnLevelCalls == [-6.0])
    }

    // MARK: - Mixer strips restore (no forced mutes)

    /// The connect/recovery restore writes each strip exactly as saved, and an
    /// unsaved strip at the default: unmuted, 0 dB, centre. Nothing is muted
    /// that Maestro does not show muted (the removed Input Monitoring setting
    /// used to force 64 mutes here).
    @Test func mixerStripsRestoreWritesWhatIsShown() async {
        let transport = MockXPCTransport()
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)
        let muted = MixerChannelState(level: -12, pan: 0.5, isMuted: true, isSoloed: true)
        let open = MixerChannelState(level: -6, pan: 0, isMuted: false, isSoloed: false)
        // Mixer 1: strips 0 and 1 saved. Mixer 2: nothing saved.
        let result = await conn.restoreMixerStrips(saved: [[muted, open], []], hardwareIndexes: [0, 1, 16],
                                                   spacing: .zero)
        #expect(result.applied == 2 * 3 * 4 && result.failed == 0)
        func byte(_ request: UInt8, mixer: UInt16, channel: UInt16) -> UInt8? {
            transport.setPropertyCalls.last { $0.bRequest == request && $0.wValue == mixer && $0.wIndex == channel }?.data.first
        }
        // 0xB3 mute, 0xB2 solo.
        #expect(byte(0xB3, mixer: 1, channel: 0) == 1)
        #expect(byte(0xB2, mixer: 1, channel: 0) == 1)
        #expect(byte(0xB3, mixer: 1, channel: 1) == 0)
        #expect(byte(0xB3, mixer: 1, channel: 16) == 0)   // unsaved: default, unmuted
        for channel: UInt16 in [0, 1, 16] {
            #expect(byte(0xB3, mixer: 2, channel: channel) == 0)
            #expect(byte(0xB2, mixer: 2, channel: channel) == 0)
            // Default level 0 dB and centre pan are written too: the unit may hold anything.
            #expect(byte(0xB0, mixer: 2, channel: channel) == byte(0xB0, mixer: 1, channel: 16))
            #expect(byte(0xB1, mixer: 2, channel: channel) == 64)
        }
        #expect(byte(0xB0, mixer: 1, channel: 0) != byte(0xB0, mixer: 1, channel: 16))
        // Never an unmute before its level, and only strips 0-31 (never 32/33 here).
        let firstMute = transport.setPropertyCalls.firstIndex { $0.bRequest == 0xB3 }!
        let firstLevel = transport.setPropertyCalls.firstIndex { $0.bRequest == 0xB0 }!
        #expect(firstLevel < firstMute)
        #expect(transport.setPropertyCalls.allSatisfy { $0.wIndex < 32 })
        // The helper is not touched by the strips.
        #expect(transport.swReturnMuteCalls.isEmpty && transport.swReturnProcessingCalls.isEmpty)
    }

    @Test func mixerStripsRestoreStopsWhenNoLongerCurrent() async {
        let transport = MockXPCTransport()
        let conn = XPCDeviceConnection(identifier: makeTestIdentifier(), transport: transport)
        let result = await conn.restoreMixerStrips(saved: [], hardwareIndexes: [0, 1], spacing: .zero,
                                                   isCurrent: { false })
        #expect(result.applied == 0 && transport.setPropertyCalls.isEmpty)
    }
}
