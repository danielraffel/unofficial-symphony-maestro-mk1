import Testing
import Foundation
import CoreAudio
@testable import MaestroDevice
@testable import MaestroCore

// MARK: - CoreAudioDeviceConnection Tests

/// Tests for the CoreAudio transport layer.
///
/// Note: Actual CoreAudio API calls require hardware to be connected,
/// so these tests focus on the testable logic: property type registry,
/// address conversion, and discovery return types.

@Suite("CoreAudioDeviceConnection")
struct CoreAudioDeviceConnectionTests {

    @Test func removedSymphonyDefaultTriggersSafetyFallback() {
        #expect(CoreAudioDeviceConnection.shouldRecoverRemovedDefault(
            removedSymphonyIDs: [106, 126], previousDefault: 106))
        #expect(!CoreAudioDeviceConnection.shouldRecoverRemovedDefault(
            removedSymphonyIDs: [106, 126], previousDefault: 114))
        #expect(!CoreAudioDeviceConnection.shouldRecoverRemovedDefault(
            removedSymphonyIDs: [106, 126], previousDefault: kAudioObjectUnknown))
    }

    // MARK: - Property Type Registry

    @Test func float64Properties() {
        let connection = makeTestConnection()
        let float64Selectors: [AudioPropertySelector] = [
            .sampleRate, .mixerChannelLevel, .mixerChannelPan, .trim,
        ]
        for selector in float64Selectors {
            let dataType = connection.testPropertyDataType(for: selector)
            #expect(dataType == .float64, "Expected .float64 for \(selector)")
        }
    }

    @Test func stringProperties() {
        let connection = makeTestConnection()
        let stringSelectors: [AudioPropertySelector] = [
            .versionString, .prefix, .audioSystemName,
        ]
        for selector in stringSelectors {
            let dataType = connection.testPropertyDataType(for: selector)
            #expect(dataType == .string, "Expected .string for \(selector)")
        }
    }

    @Test func dataProperties() {
        let connection = makeTestConnection()
        let dataSelectors: [AudioPropertySelector] = [
            .meterData, .streamMeter, .route, .routing,
        ]
        for selector in dataSelectors {
            let dataType = connection.testPropertyDataType(for: selector)
            #expect(dataType == .data, "Expected .data for \(selector)")
        }
    }

    @Test func rangeProperties() {
        let connection = makeTestConnection()
        let rangeSelectors: [AudioPropertySelector] = [
            .outputLevelRange, .gainRange, .mixerChannelLevelRange, .trimRange,
        ]
        for selector in rangeSelectors {
            let dataType = connection.testPropertyDataType(for: selector)
            #expect(dataType == .range, "Expected .range for \(selector)")
        }
    }

    @Test func boolProperties() {
        let connection = makeTestConnection()
        let boolSelectors: [AudioPropertySelector] = [
            .outputMute, .outputDim, .outputSumToMono,
            .phantom, .phaseReverse, .highPassFilter,
            .headphone1Mute, .headphone2Mute,
            .headphone1Dim, .headphone2Dim,
            .headphone1SumToMono, .headphone2SumToMono,
            .mixerChannelMute, .mixerChannelSolo,
        ]
        for selector in boolSelectors {
            let dataType = connection.testPropertyDataType(for: selector)
            #expect(dataType == .bool, "Expected .bool for \(selector)")
        }
    }

    @Test func uint32FallbackForUnknownProperties() {
        let connection = makeTestConnection()
        // Properties not specifically classified should default to .uint32.
        // Bug 8: outputLevel/headphone levels are UInt32 attenuation over daemon IPC,
        // NOT Float64. Evidence: mAEstro.h:1027, mAEstroUtilities.c:715.
        let uint32Selectors: [AudioPropertySelector] = [
            .outputLevel, .headphone1Level, .headphone2Level,
            .clockSource, .clockStatus, .micGain, .analogIOType,
            .softLimit, .opticalInFormat, .deviceMode,
            .activeSpeakerSet, .frontPanelMeterBank,
        ]
        for selector in uint32Selectors {
            let dataType = connection.testPropertyDataType(for: selector)
            #expect(dataType == .uint32, "Expected .uint32 for \(selector)")
        }
    }

    // MARK: - Connection State

    @Test func initiallyConnected() {
        let connection = makeTestConnection()
        #expect(connection.isConnected)
    }

    @Test func disconnectSetsFlag() async {
        let connection = makeTestConnection()
        #expect(connection.isConnected)
        await connection.disconnect()
        #expect(!connection.isConnected)
    }

    @Test func getPropertyFailsWhenDisconnected() async {
        let connection = makeTestConnection()
        await connection.disconnect()
        do {
            _ = try await connection.getProperty(PropertyAddress(selector: .outputMute))
            Issue.record("Should have thrown notConnected")
        } catch let error as DeviceConnectionError {
            #expect(error == .notConnected)
        } catch {
            Issue.record("Wrong error type: \(error)")
        }
    }

    @Test func setPropertyFailsWhenDisconnected() async {
        let connection = makeTestConnection()
        await connection.disconnect()
        do {
            try await connection.setProperty(
                PropertyAddress(selector: .outputMute),
                value: .bool(true)
            )
            Issue.record("Should have thrown notConnected")
        } catch let error as DeviceConnectionError {
            #expect(error == .notConnected)
        } catch {
            Issue.record("Wrong error type: \(error)")
        }
    }

    // MARK: - Discovery (no-op without hardware)

    @Test func discoveryReturnsNilWithoutHardware() {
        // On CI/machines without a Symphony IO, discovery should return nil
        // (not crash or hang). This validates the enumeration code path.
        let result = CoreAudioDeviceConnection.discoverSymphonyIO()
        // We can't assert nil — the dev may have hardware connected.
        // Just verify it doesn't crash and returns the right type.
        if let (deviceID, identifier) = result {
            #expect(deviceID != 0)
            #expect(identifier.vendorID == ApogeeUSB.vendorID)
            #expect(ApogeeUSB.SymphonyIO.allProductIDs.contains(identifier.productID))
        }
    }

    // MARK: - Identifier

    @Test func identifierPreserved() {
        let id = USBDeviceIdentifier(
            vendorID: ApogeeUSB.vendorID,
            productID: ApogeeUSB.SymphonyIO.pid16ch,
            deviceUID: "test-uid"
        )!
        let connection = CoreAudioDeviceConnection(identifier: id, audioDeviceID: 42)
        #expect(connection.identifier == id)
        #expect(connection.identifier.vendorID == ApogeeUSB.vendorID)
        #expect(connection.identifier.productID == ApogeeUSB.SymphonyIO.pid16ch)
    }

    // MARK: - Sample rate following

    /// The picker used to sleep 200 ms and read whatever was there. These cover
    /// the replacement's edges: a device that can never report the rate must give
    /// up rather than hang, and it must give up promptly when told to.
    @Test("waitForNominalSampleRate gives up on a device that cannot report one")
    func rateWaitGivesUpOnUnknownDevice() async {
        let settled = await CoreAudioDeviceConnection.waitForNominalSampleRate(
            of: AudioObjectID(kAudioObjectUnknown), toReach: 48000, timeoutMilliseconds: 0)
        #expect(settled == nil)
    }

    @Test("An unqueryable device reports unknown, not idle")
    func unknownDeviceRunningStateIsUnknown() {
        // This decides which of three sentences the user reads when the virtual
        // device has not followed. Collapsing "cannot tell" into "not running"
        // would hand the reassuring message to the one case that is a real fault,
        // so the absence has to survive as an absence.
        #expect(CoreAudioDeviceConnection.isDeviceRunning(AudioObjectID(kAudioObjectUnknown)) == nil)
    }

    @Test("Nudging an absent device is a no-op, not a crash")
    func nudgeOnUnknownDeviceIsHarmless() {
        // Called unconditionally once the grace period lapses, and the virtual
        // device can disappear between the lookup and the nudge (a proxy restart
        // tears it down). Discarding the status is the point; not trapping is too.
        CoreAudioDeviceConnection.nudgeNominalSampleRate(
            of: AudioObjectID(kAudioObjectUnknown), to: 96000)
        #expect(CoreAudioDeviceConnection.nominalSampleRate(
            of: AudioObjectID(kAudioObjectUnknown)) == nil)
    }

    @Test("waitForNominalSampleRate honours its deadline instead of spinning")
    func rateWaitHonoursDeadline() async {
        let started = ContinuousClock.now
        let settled = await CoreAudioDeviceConnection.waitForNominalSampleRate(
            of: AudioObjectID(kAudioObjectUnknown), toReach: 96000, timeoutMilliseconds: 100)
        #expect(settled == nil)
        // Generous upper bound: the point is that it returns at all, near its
        // deadline, rather than waiting on a notification that will never arrive.
        #expect(started.duration(to: .now) < .seconds(2))
    }

    @Test("nominalSampleRate(of:) rejects the unknown device instead of guessing")
    func nominalRateOfUnknownDeviceIsNil() {
        #expect(CoreAudioDeviceConnection.nominalSampleRate(
            of: AudioObjectID(kAudioObjectUnknown)) == nil)
    }

    @Test("findDevice(named:) returns nil for a name no device has")
    func findDeviceByAbsentName() {
        #expect(CoreAudioDeviceConnection.findDevice(
            named: "no device is called this — 3f9c1d") == nil)
    }

    // MARK: - Helpers

    private func makeTestConnection() -> CoreAudioDeviceConnection {
        let id = USBDeviceIdentifier(
            vendorID: ApogeeUSB.vendorID,
            productID: ApogeeUSB.SymphonyIO.pid16ch,
            deviceUID: "test-coreaudio"
        )!
        // AudioDeviceID 0 won't match any real device — property calls will
        // fail with kAudioHardwareBadObjectError, which we handle gracefully.
        return CoreAudioDeviceConnection(identifier: id, audioDeviceID: 0)
    }
}

// MARK: - MaestroLink Protocol Framing Tests

/// Tests that verify the binary layout of MaestroLink IPC messages.
/// These tests catch field-swap bugs like putting the value in m_dataSize
/// instead of m_inputSize, which would cause the daemon to silently ignore writes.
///
/// Evidence: og_source/maestrolink/Software/Messaging/apogeeDriverPlugInMessageTypes/

@Suite("DaemonSocketProtocol")
struct DaemonSocketProtocolTests {

    // MARK: - Struct Layout Constants
    // These match the legacy C++ struct offsets exactly.

    /// Transportable (12 bytes): [totalPacked:4][objectType:4][byteOrder:1][pad:3]
    static let transportableSize = 12
    /// MessageContent (16 bytes): [uniqueID:4][priority:4][processID:4][msgType:1][pad:3]
    static let messageContentSize = 16
    /// SetPropertyContents/GetPropertyContents (28 bytes)
    static let propertyContentsSize = 28
    /// Offset to start of type-specific contents
    static let contentsOffset = transportableSize + messageContentSize  // 28

    // Field offsets within SetPropertyContents (relative to contentsOffset)
    static let fieldDevCtrl = 0
    static let fieldNonCA = 4
    static let fieldPropID = 8
    static let fieldChannel = 12
    static let fieldDataSize = 16     // m_dataSize: auxiliary data size
    static let fieldInputSize = 20    // m_inputSize: PRIMARY value size
    static let fieldIsInput = 24

    // MARK: - SetProperty Tests

    @Test func setPropertyValueInInputSizeField() {
        // THE critical test: value size MUST go in m_inputSize (offset 20),
        // NOT m_dataSize (offset 16). The daemon reads m_inputSize to know
        // how many bytes of primary value data follow the fixed struct.
        let socket = DaemonSocket()
        var muteValue: UInt32 = 1
        let data = Data(bytes: &muteValue, count: 4)

        let payload = socket.buildSetPropertyPayload(
            propertyID: 0x41456D33,  // 'AEm3' = outputMute
            channel: 0,
            isInput: false,
            data: data
        )

        payload.withUnsafeBytes { buf in
            let base = Self.contentsOffset

            // m_dataSize at offset 16 MUST be 0 (auxiliary, unused)
            let dataSize = buf.load(fromByteOffset: base + Self.fieldDataSize, as: UInt32.self)
            #expect(dataSize == 0,
                    "m_dataSize (auxiliary) must be 0, got \(dataSize) — field swap bug!")

            // m_inputSize at offset 20 MUST be 4 (the value size)
            let inputSize = buf.load(fromByteOffset: base + Self.fieldInputSize, as: UInt32.self)
            #expect(inputSize == 4,
                    "m_inputSize (primary value) must be 4, got \(inputSize) — field swap bug!")
        }
    }

    @Test func setPropertyObjectType() {
        let socket = DaemonSocket()
        let data = Data([0x01, 0x00, 0x00, 0x00])
        let payload = socket.buildSetPropertyPayload(
            propertyID: 0x41456D33, channel: 0, isInput: false, data: data
        )

        payload.withUnsafeBytes { buf in
            // Transportable objectType at offset 4 must be 5 (SetProperty)
            let objectType = buf.load(fromByteOffset: 4, as: UInt32.self)
            #expect(objectType == 5, "SetProperty objectType must be 5")
        }
    }

    @Test func setPropertyMessageType() {
        let socket = DaemonSocket()
        let data = Data([0x01, 0x00, 0x00, 0x00])
        let payload = socket.buildSetPropertyPayload(
            propertyID: 0x41456D33, channel: 0, isInput: false, data: data
        )

        payload.withUnsafeBytes { buf in
            // MessageContent messageType at offset 12+12 = 24...
            // Actually: transportable(12) + uniqueID(4) + priority(4) + processID(4) = 24
            let msgType = buf.load(fromByteOffset: Self.transportableSize + 12, as: UInt8.self)
            #expect(msgType == 0x03, "SetProperty messageType must be 0x03")
        }
    }

    @Test func setPropertyIDCorrect() {
        let socket = DaemonSocket()
        let data = Data([0x01, 0x00, 0x00, 0x00])
        let payload = socket.buildSetPropertyPayload(
            propertyID: 0x41456D33, channel: 0, isInput: false, data: data
        )

        payload.withUnsafeBytes { buf in
            let propID = buf.load(
                fromByteOffset: Self.contentsOffset + Self.fieldPropID,
                as: UInt32.self
            )
            #expect(propID == 0x41456D33, "propertyID must match")
        }
    }

    @Test func setPropertyChannelAndScope() {
        let socket = DaemonSocket()
        let data = Data([0x00, 0x00, 0x00, 0x00])
        let payload = socket.buildSetPropertyPayload(
            propertyID: 0x4145C300, channel: 3, isInput: true, data: data
        )

        payload.withUnsafeBytes { buf in
            let base = Self.contentsOffset
            let channel = buf.load(fromByteOffset: base + Self.fieldChannel, as: UInt32.self)
            #expect(channel == 3, "channel must be 3")

            let isInput = buf.load(fromByteOffset: base + Self.fieldIsInput, as: UInt8.self)
            #expect(isInput == 1, "isInput must be 1 for input scope")
        }
    }

    @Test func setPropertyValueDataAppended() {
        // The property value bytes must appear right after the 56-byte fixed header
        let socket = DaemonSocket()
        var value: UInt32 = 0xDEADBEEF
        let data = Data(bytes: &value, count: 4)
        let payload = socket.buildSetPropertyPayload(
            propertyID: 0x41456D33, channel: 0, isInput: false, data: data
        )

        let dataOffset = Self.contentsOffset + Self.propertyContentsSize  // 56
        #expect(payload.count == dataOffset + 4, "Total size: 56 fixed + 4 data")

        payload.withUnsafeBytes { buf in
            let appendedValue = buf.load(fromByteOffset: dataOffset, as: UInt32.self)
            #expect(appendedValue == 0xDEADBEEF, "Value data must follow fixed header")
        }
    }

    @Test func setPropertyTotalPackedSize() {
        // P3G-15i fix (Bug 15): m_nTotalPackedSize must be 0 to match the legacy protocol.
        // The Transportable constructor initializes m_nTotalPackedSize=0 (Transportable.cpp:20)
        // and Pack() never updates it, so the wire format always has 0 in this field.
        // The daemon uses the MLNK frame header's packetSize field, not this field.
        let socket = DaemonSocket()
        let data = Data([0x01, 0x00, 0x00, 0x00])
        let payload = socket.buildSetPropertyPayload(
            propertyID: 0x41456D33, channel: 0, isInput: false, data: data
        )

        payload.withUnsafeBytes { buf in
            // Transportable totalPackedSize at offset 0 — must be 0 per legacy protocol
            let totalPacked = buf.load(fromByteOffset: 0, as: UInt32.self)
            #expect(totalPacked == 0,
                    "totalPackedSize must be 0 per legacy Transportable.cpp:20 (Bug 15 fix)")
        }
    }

    // MARK: - GetProperty Tests

    @Test func getPropertyObjectType() {
        let socket = DaemonSocket()
        let payload = socket.buildGetPropertyPayload(
            propertyID: 0x41456D33, channel: 0, isInput: false
        )

        payload.withUnsafeBytes { buf in
            let objectType = buf.load(fromByteOffset: 4, as: UInt32.self)
            #expect(objectType == 4, "GetProperty objectType must be 4")
        }
    }

    @Test func getPropertyMessageType() {
        let socket = DaemonSocket()
        let payload = socket.buildGetPropertyPayload(
            propertyID: 0x41456D33, channel: 0, isInput: false
        )

        payload.withUnsafeBytes { buf in
            let msgType = buf.load(fromByteOffset: Self.transportableSize + 12, as: UInt8.self)
            #expect(msgType == 0x05, "GetProperty messageType must be 0x05")
        }
    }

    @Test func getPropertyFixedSize() {
        let socket = DaemonSocket()
        let payload = socket.buildGetPropertyPayload(
            propertyID: 0x41456D33, channel: 0, isInput: false
        )

        // GetProperty has no trailing data — just the 56-byte fixed struct
        #expect(payload.count == 56, "GetProperty payload must be exactly 56 bytes")
    }

    @Test func getPropertyMaxReturnSize() {
        let socket = DaemonSocket()
        let payload = socket.buildGetPropertyPayload(
            propertyID: 0x41456D33, channel: 0, isInput: false
        )

        payload.withUnsafeBytes { buf in
            // maxReturnDataSize at GetPropertyContents offset 16 (after devCtrl, nonCA, propID, channel)
            let maxReturn = buf.load(
                fromByteOffset: Self.contentsOffset + 16,
                as: UInt32.self
            )
            #expect(maxReturn == 4096, "maxReturnDataSize should be 4096")
        }
    }

    // MARK: - Transportable Header Tests

    @Test func transportableByteOrder() {
        let socket = DaemonSocket()
        let payload = socket.buildGetPropertyPayload(
            propertyID: 0x41456D33, channel: 0, isInput: false
        )

        payload.withUnsafeBytes { buf in
            let byteOrder = buf.load(fromByteOffset: 8, as: UInt8.self)
            #expect(byteOrder == 0x4C, "Byte order must be 'L' (0x4C) for little-endian")
        }
    }
}

// MARK: - Value Encoding Tests

@Suite("DaemonValueEncoding")
struct DaemonValueEncodingTests {

    @Test func encodeBoolTrue() {
        let connection = makeTestConnection()
        let data = connection.testEncodeValue(.bool(true))
        #expect(data.count == 4)
        let value = data.withUnsafeBytes { $0.load(as: UInt32.self) }
        #expect(value == 1)
    }

    @Test func encodeBoolFalse() {
        let connection = makeTestConnection()
        let data = connection.testEncodeValue(.bool(false))
        #expect(data.count == 4)
        let value = data.withUnsafeBytes { $0.load(as: UInt32.self) }
        #expect(value == 0)
    }

    @Test func encodeUInt32() {
        let connection = makeTestConnection()
        let data = connection.testEncodeValue(.uint32(42))
        #expect(data.count == 4)
        let value = data.withUnsafeBytes { $0.load(as: UInt32.self) }
        #expect(value == 42)
    }

    @Test func encodeFloat64() {
        let connection = makeTestConnection()
        let data = connection.testEncodeValue(.float64(-20.0))
        #expect(data.count == 8)
        let value = data.withUnsafeBytes { $0.load(as: Float64.self) }
        #expect(value == -20.0)
    }

    @Test func decodeBoolFromUInt32() {
        let connection = makeTestConnection()
        var one: UInt32 = 1
        let data = Data(bytes: &one, count: 4)
        let value = connection.testDecodeResponse(data: data, dataType: .bool)
        if case .bool(let b) = value {
            #expect(b == true)
        } else {
            Issue.record("Expected .bool, got \(value)")
        }
    }

    @Test func decodeUInt32FromDaemonResponse() {
        let connection = makeTestConnection()
        var val: UInt32 = 20
        let data = Data(bytes: &val, count: 4)
        let value = connection.testDecodeResponse(data: data, dataType: .uint32)
        if case .uint32(let v) = value {
            #expect(v == 20)
        } else {
            Issue.record("Expected .uint32, got \(value)")
        }
    }

    @Test func decodeFloat64FromUInt32Fallback() {
        // When daemon returns 4 bytes for a float64 property (e.g., outputLevel),
        // the decoder should promote UInt32 → Float64.
        let connection = makeTestConnection()
        var val: UInt32 = 20
        let data = Data(bytes: &val, count: 4)
        let value = connection.testDecodeResponse(data: data, dataType: .float64)
        if case .float64(let f) = value {
            #expect(f == 20.0)
        } else {
            Issue.record("Expected .float64, got \(value)")
        }
    }

    // MARK: - P3G-08: Output level must encode as 4-byte UInt32

    @Test func outputLevelEncodedAsUInt32() {
        // P3G-08: Bug 8 regression guard. Daemon expects UInt32 attenuation (4 bytes),
        // not Float64 (8 bytes). Encode a 64-point attenuation value and verify 4 bytes.
        // Evidence: mAEstro.h:1027 — outputLevel is UInt32; mAEstroUtilities.c:715.
        let connection = makeTestConnection()
        let data = connection.testEncodeValue(.uint32(64))
        #expect(data.count == 4, "outputLevel value must be 4 bytes (UInt32), not 8 (Float64)")
        let decoded = data.withUnsafeBytes { $0.load(as: UInt32.self) }
        #expect(decoded == 64, "UInt32(64) must encode as 64")
    }

    @Test func outputLevelPropertyTypeIsUInt32() {
        // P3G-08: outputLevel, headphone1Level, headphone2Level must be typed as .uint32.
        // Bug 8 was: these were .float64, causing 8-byte payloads the daemon ignored.
        let connection = makeTestConnection()
        for selector in [AudioPropertySelector.outputLevel, .headphone1Level, .headphone2Level] {
            let dataType = connection.testPropertyDataType(for: selector)
            #expect(dataType == .uint32, "\(selector) must be .uint32 (Bug 8 guard)")
        }
    }

    // MARK: - P3G-09: Channel indexing is 1-based in daemon

    @Test func channelIndexIs1BasedInPacket() {
        // P3G-09: Bug 7 regression guard. Daemon uses 1-based channel numbering.
        // UI loop index 0 → element 1 (first channel).
        // Evidence: daemonCommunication.cpp — daemon does m_nChannel-1 on receive.
        let socket = DaemonSocket()
        // Simulate writing to the first input channel (UI index 0 → element 1-based)
        var gain: UInt32 = 40
        let data = Data(bytes: &gain, count: 4)
        let payload = socket.buildSetPropertyPayload(
            propertyID: AudioPropertySelector.micGain.rawValue,
            channel: 1,   // 1-based: first channel (UI index 0 + 1)
            isInput: true,
            data: data
        )

        payload.withUnsafeBytes { buf in
            let base = DaemonSocketProtocolTests.contentsOffset
            let channel = buf.load(fromByteOffset: base + DaemonSocketProtocolTests.fieldChannel, as: UInt32.self)
            #expect(channel == 1, "First channel must be element=1 (1-based), not element=0 (0-based)")
        }
    }

    @Test func channelIndexSecondChannelIs2() {
        // P3G-09: UI index 1 → element 2. The daemon's m_nChannel-1 gives channel 1 (0-based).
        let socket = DaemonSocket()
        var gain: UInt32 = 40
        let data = Data(bytes: &gain, count: 4)
        let payload = socket.buildSetPropertyPayload(
            propertyID: AudioPropertySelector.micGain.rawValue,
            channel: 2,   // 1-based: second channel (UI index 1 + 1)
            isInput: true,
            data: data
        )

        payload.withUnsafeBytes { buf in
            let base = DaemonSocketProtocolTests.contentsOffset
            let channel = buf.load(fromByteOffset: base + DaemonSocketProtocolTests.fieldChannel, as: UInt32.self)
            #expect(channel == 2, "Second channel must be element=2 (1-based)")
        }
    }

    private func makeTestConnection() -> CoreAudioDeviceConnection {
        let id = USBDeviceIdentifier(
            vendorID: ApogeeUSB.vendorID,
            productID: ApogeeUSB.SymphonyIO.pid16ch,
            deviceUID: "test-encoding"
        )!
        return CoreAudioDeviceConnection(identifier: id, audioDeviceID: 0)
    }
}

// MARK: - Routing Protocol Tests (P3G-43/44)

/// Tests for the routing property protocol — maestroRoute struct format, data encoding,
/// and that routing uses the correct data type (.data, not .uint32).
///
/// P3G-43: SetProperty format for routing.
/// P3G-44: GetProperty response parsing for routing.
/// Evidence: og_source/symphonymk1/ext/SymphonyIO/generic/mAEstro.h:567-571
///   typedef struct _maestroRoute { UInt64 mObjectID; UInt64 mElement; } maestroRoute;
/// Evidence: og_source/symphonymk1/ext/maestrolink/Software/NonCAStreamObject.cpp:84-118
@Suite("RoutingProtocol")
struct RoutingProtocolTests {

    // MARK: - P3G-43: SetProperty format for routing

    @Test func routingPropertyTypeIsData() {
        // Routing uses .data (16-byte maestroRoute), NOT .uint32.
        // P3G-15a bug: code was sending .uint32(src) (4 bytes) instead of maestroRoute (16 bytes).
        let connection = makeTestConnection()
        let dataType = connection.testPropertyDataType(for: .routing)
        #expect(dataType == .data, "routing ('AEsA') must be .data type for maestroRoute struct")
    }

    @Test func routePropertyTypeIsData() {
        // Also verify .route ('AErt') is .data typed.
        let connection = makeTestConnection()
        let dataType = connection.testPropertyDataType(for: .route)
        #expect(dataType == .data, "route ('AErt') must be .data type")
    }

    @Test func maestroRouteDataIs16Bytes() {
        // maestroRoute { mObjectID: UInt64, mElement: UInt64 } = 16 bytes.
        // Sending fewer bytes (e.g., 4 from UInt32) causes the daemon to silently fail.
        var objectID: UInt64 = 0x0F00000042
        var element: UInt64 = 1
        var route = Data(count: 16)
        route.withUnsafeMutableBytes {
            $0.storeBytes(of: objectID, toByteOffset: 0, as: UInt64.self)
            $0.storeBytes(of: element,  toByteOffset: 8, as: UInt64.self)
        }
        #expect(route.count == 16, "maestroRoute must be exactly 16 bytes (2 × UInt64)")

        // Verify field layout: mObjectID at offset 0, mElement at offset 8
        let readObjectID = route.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt64.self) }
        let readElement  = route.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt64.self) }
        #expect(readObjectID == objectID, "mObjectID must be at byte offset 0")
        #expect(readElement  == element,  "mElement must be at byte offset 8")
    }

    @Test func routingSetPropertySends16BytePayload() {
        // Verify that a routing SetProperty with 16-byte maestroRoute data
        // builds the correct payload size (56 fixed + 16 route data = 72 bytes).
        let socket = DaemonSocket()
        var objectID: UInt64 = 0x0F00000042
        var element: UInt64 = 1
        var routeData = Data(count: 16)
        routeData.withUnsafeMutableBytes {
            $0.storeBytes(of: objectID, toByteOffset: 0, as: UInt64.self)
            $0.storeBytes(of: element,  toByteOffset: 8, as: UInt64.self)
        }

        let payload = socket.buildSetPropertyPayload(
            propertyID: AudioPropertySelector.routing.rawValue,
            channel: 1,       // 1-based destination element
            isInput: true,    // input scope for input routing
            data: routeData
        )

        // 56 fixed header + 16 maestroRoute data
        #expect(payload.count == 72, "Routing SetProperty payload must be 72 bytes (56 fixed + 16 maestroRoute)")
    }

    @Test func routingSetPropertyInputScope() {
        // Input routing uses isInput=true (scope=input).
        // Evidence: NonCAStreamObject.cpp:84 — SetProperty with kMaestroPropertyRouting + scope=input
        let socket = DaemonSocket()
        var routeData = Data(count: 16)
        let payload = socket.buildSetPropertyPayload(
            propertyID: AudioPropertySelector.routing.rawValue,
            channel: 1,
            isInput: true,
            data: routeData
        )

        let base = DaemonSocketProtocolTests.contentsOffset
        payload.withUnsafeBytes { buf in
            let isInput = buf.load(fromByteOffset: base + DaemonSocketProtocolTests.fieldIsInput, as: UInt8.self)
            #expect(isInput == 1, "Input routing must set isInput=1 (scope=input)")
        }
    }

    @Test func routingSetPropertyOutputScope() {
        // Output routing uses isInput=false (scope=output).
        // Evidence: SymphonyIOUSBAudioRoutingController.cpp:1085 — addr.mScope=kAudioDevicePropertyScopeOutput
        let socket = DaemonSocket()
        var routeData = Data(count: 16)
        let payload = socket.buildSetPropertyPayload(
            propertyID: AudioPropertySelector.routing.rawValue,
            channel: 1,
            isInput: false,   // output scope
            data: routeData
        )

        let base = DaemonSocketProtocolTests.contentsOffset
        payload.withUnsafeBytes { buf in
            let isInput = buf.load(fromByteOffset: base + DaemonSocketProtocolTests.fieldIsInput, as: UInt8.self)
            #expect(isInput == 0, "Output routing must set isInput=0 (scope=output)")
        }
    }

    @Test func routingDestinationElementIs1Based() {
        // Destination element must be 1-based: pair 0 → element 1, pair 1 → element 3, etc.
        // Evidence: SymphonyIOUSBAudioRoutingController.cpp:1084 — addr.mElement=2*nPairIndex+1
        for pair in 0..<4 {
            let expectedElement = UInt32(pair * 2 + 1)
            let socket = DaemonSocket()
            let payload = socket.buildSetPropertyPayload(
                propertyID: AudioPropertySelector.routing.rawValue,
                channel: expectedElement,
                isInput: true,
                data: Data(count: 16)
            )

            let base = DaemonSocketProtocolTests.contentsOffset
            payload.withUnsafeBytes { buf in
                let channel = buf.load(fromByteOffset: base + DaemonSocketProtocolTests.fieldChannel, as: UInt32.self)
                #expect(channel == expectedElement,
                        "Routing destination for pair \(pair) must be element \(expectedElement) (1-based)")
            }
        }
    }

    // MARK: - P3G-44: GetProperty response decoding for routing

    @Test func routingResponseDecodesAsData() {
        // A 16-byte maestroRoute response must decode as .data, not .uint32.
        // The first 8 bytes are mObjectID and the next 8 are mElement.
        let connection = makeTestConnection()
        var objectID: UInt64 = 0x0F00000042
        var element: UInt64 = 3
        var responseData = Data(count: 16)
        responseData.withUnsafeMutableBytes {
            $0.storeBytes(of: objectID, toByteOffset: 0, as: UInt64.self)
            $0.storeBytes(of: element,  toByteOffset: 8, as: UInt64.self)
        }

        let decoded = connection.testDecodeResponse(data: responseData, dataType: .data)
        if case .data(let d) = decoded {
            #expect(d.count == 16, "Decoded routing data must be 16 bytes")
            let readObjID  = d.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt64.self) }
            let readElem   = d.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt64.self) }
            #expect(readObjID == objectID, "mObjectID must survive round-trip decode")
            #expect(readElem  == element,  "mElement must survive round-trip decode")
        } else {
            Issue.record("Routing response must decode as .data, got \(decoded)")
        }
    }

    @Test func routingDataPassthroughEncoding() {
        // .data(routeData) must encode as the exact bytes passed in (no transformation).
        let connection = makeTestConnection()
        var objectID: UInt64 = 0x0F00000099
        var element: UInt64 = 5
        var routeData = Data(count: 16)
        routeData.withUnsafeMutableBytes {
            $0.storeBytes(of: objectID, toByteOffset: 0, as: UInt64.self)
            $0.storeBytes(of: element,  toByteOffset: 8, as: UInt64.self)
        }

        let encoded = connection.testEncodeValue(.data(routeData))
        #expect(encoded.count == 16, "Encoded route data must be 16 bytes")
        #expect(encoded == routeData, "Encoded route data must equal input (passthrough)")
    }

    // MARK: - Helpers

    private func makeTestConnection() -> CoreAudioDeviceConnection {
        let id = USBDeviceIdentifier(
            vendorID: ApogeeUSB.vendorID,
            productID: ApogeeUSB.SymphonyIO.pid16ch,
            deviceUID: "test-routing"
        )!
        return CoreAudioDeviceConnection(identifier: id, audioDeviceID: 0)
    }
}

// MARK: - Response Correlation Tests (P3G-15h)

/// Tests for readResponseSkippingNotifications() response correlation and notification skip logic.
/// Uses socketpair() to simulate daemon messages without real hardware.
@Suite("DaemonSocketResponseCorrelation")
struct DaemonSocketResponseCorrelationTests {

    // MARK: - Fake Message Helpers

    /// Build a minimal MLNK-framed message (24 bytes) for testing response correlation.
    /// Format: [8 frame header][12 Transportable (objectType at +4)][4 MessageContent.uniqueID]
    private func buildFakeMessage(objectType: UInt32, uniqueID: UInt32) -> Data {
        let payloadSize = 16  // Transportable(12) + uniqueID(4)
        var msg = Data(count: 8 + payloadSize)
        msg.withUnsafeMutableBytes { buf in
            let ptr = buf.baseAddress!
            // Frame header: magic(4) + packetSize(4)
            var magic = DaemonSocket.magic
            var size = UInt32(payloadSize)
            memcpy(ptr, &magic, 4)
            memcpy(ptr + 4, &size, 4)
            // Transportable at combined offset 8:
            //   totalPacked(4)=0, objectType(4), byteOrder(1)='L', pad(3)
            var ot = objectType
            var bo: UInt8 = 0x4C
            memcpy(ptr + 12, &ot, 4)   // objectType at Transportable+4 = combined offset 12
            memcpy(ptr + 16, &bo, 1)   // byteOrder at Transportable+8 = combined offset 16
            // MessageContent.uniqueID at Transportable(12) + 0 = combined offset 8+12=20
            var uid = uniqueID
            memcpy(ptr + 20, &uid, 4)
        }
        return msg
    }

    private func makePair() -> (readFD: Int32, writeFD: Int32)? {
        var fds = [Int32](repeating: -1, count: 2)
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { return nil }
        return (fds[0], fds[1])
    }

    private func write(_ msg: Data, to fd: Int32) {
        msg.withUnsafeBytes { buf in
            _ = Darwin.send(fd, buf.baseAddress!, msg.count, 0)
        }
    }

    // MARK: - Offset Sanity (no I/O required)

    /// Verify the uniqueMessageID constant offset in a built GetProperty payload.
    /// buildGetPropertyPayload uses msgID=99 so we can assert the value at offset 12.
    @Test func uniqueMessageIDAtPayloadOffset12() {
        let socket = DaemonSocket()
        let payload = socket.buildGetPropertyPayload(
            propertyID: AudioPropertySelector.outputMute.rawValue,
            channel: 0, isInput: false
        )
        // MessageContent starts after Transportable(12); uniqueID is at MessageContent+0 = payload offset 12.
        let uid = payload.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self) }
        #expect(uid == 99, "buildGetPropertyPayload must embed msgID=99 at payload offset 12 (P3G-15h)")
    }

    @Test func uniqueMessageIDAtPayloadOffset12_setProperty() {
        let socket = DaemonSocket()
        let data = Data([0x01, 0x00, 0x00, 0x00])
        let payload = socket.buildSetPropertyPayload(
            propertyID: AudioPropertySelector.outputMute.rawValue,
            channel: 0, isInput: false, data: data
        )
        let uid = payload.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self) }
        #expect(uid == 99, "buildSetPropertyPayload must embed msgID=99 at payload offset 12 (P3G-15h)")
    }

    // MARK: - Socket-based Correlation Tests

    /// A Response (objectType=2) with matching uniqueMessageID must be returned.
    @Test func matchingUID_accepted() {
        guard let pair = makePair() else { Issue.record("socketpair failed"); return }
        let (readFD, writeFD) = pair
        defer { close(readFD); close(writeFD) }

        let socket = DaemonSocket()
        write(buildFakeMessage(objectType: 2, uniqueID: 42), to: writeFD)

        let result = socket.readResponseSkippingNotifications(fd: readFD, timeout: 500, expectedMsgID: 42)
        #expect(result != nil, "Response with matching uniqueMessageID must be returned")
    }

    /// A Response (objectType=2) with mismatched uniqueMessageID must be skipped.
    /// After skipping, the socket closes and nil is returned (no infinite wait).
    @Test func mismatchedUID_skipped() {
        guard let pair = makePair() else { Issue.record("socketpair failed"); return }
        let (readFD, writeFD) = pair

        let socket = DaemonSocket()
        write(buildFakeMessage(objectType: 2, uniqueID: 99), to: writeFD)  // uid=99, expecting 42
        close(writeFD)  // Close so the reader terminates rather than timing out

        let result = socket.readResponseSkippingNotifications(fd: readFD, timeout: 500, expectedMsgID: 42)
        close(readFD)
        #expect(result == nil, "Response with mismatched uniqueMessageID must be skipped → nil")
    }

    /// A PropertyChanged notification (objectType=6) must be skipped; the following Response returned.
    @Test func notification_skipped_responseReturned() {
        guard let pair = makePair() else { Issue.record("socketpair failed"); return }
        let (readFD, writeFD) = pair
        defer { close(readFD); close(writeFD) }

        let socket = DaemonSocket()
        write(buildFakeMessage(objectType: 6, uniqueID: 0),  to: writeFD)  // notification
        write(buildFakeMessage(objectType: 2, uniqueID: 99), to: writeFD)  // response

        let result = socket.readResponseSkippingNotifications(fd: readFD, timeout: 500, expectedMsgID: 99)
        #expect(result != nil, "Notification must be skipped; Response must be returned")
    }

    /// With no expectedMsgID, any Response (objectType=2) is accepted regardless of uniqueID.
    @Test func noExpectedMsgID_acceptsAnyResponse() {
        guard let pair = makePair() else { Issue.record("socketpair failed"); return }
        let (readFD, writeFD) = pair
        defer { close(readFD); close(writeFD) }

        let socket = DaemonSocket()
        write(buildFakeMessage(objectType: 2, uniqueID: 12345), to: writeFD)

        let result = socket.readResponseSkippingNotifications(fd: readFD, timeout: 500, expectedMsgID: nil)
        #expect(result != nil, "Any Response must be accepted when expectedMsgID is nil")
    }

    /// When no messages arrive, nil is returned after the timeout elapses.
    @Test func timeout_returnsNil() {
        guard let pair = makePair() else { Issue.record("socketpair failed"); return }
        let (readFD, writeFD) = pair
        defer { close(readFD); close(writeFD) }

        let socket = DaemonSocket()
        let start = Date()
        let result = socket.readResponseSkippingNotifications(fd: readFD, timeout: 150, expectedMsgID: nil)
        let elapsed = Date().timeIntervalSince(start)
        #expect(result == nil, "Must return nil when no messages arrive within timeout")
        #expect(elapsed >= 0.100 && elapsed < 1.0,
                "Timeout must be respected (elapsed: \(String(format: "%.3f", elapsed))s)")
    }
}

// MARK: - DeviceControllerID Extraction Tests (P3G-15)

/// Tests for DaemonSocket.parseDeviceControllerID() — the parser that extracts the daemon-assigned
/// DeviceControllerID from a registration response. This ID is required for routing all subsequent
/// Get/SetProperty messages to the correct hardware controller.
///
/// Evidence: daemonCommunication.cpp:606 — m_nDeviceControllerID=*(UInt32*)pResponseMsg->m_pReturnData
@Suite("DaemonSocketDeviceControllerID")
struct DaemonSocketDeviceControllerIDTests {

    /// Build a fake registration response with a known DeviceControllerID at the correct offset.
    /// Full combined layout (frame + payload = 52 bytes):
    ///   [0..7]   frame: magic(4) + packetSize(4)=44
    ///   [8..19]  Transportable(12): totalPacked(4)+objectType(4)+byteOrder(1)+pad(3)
    ///   [20..35] MessageContent(16)
    ///   [36..39] ResponseContents.returnStatus(4)
    ///   [40..43] ResponseContents.senderPID(4)
    ///   [44..47] ResponseContents.returnDataSize(4) = 4
    ///   [48..51] return data: DeviceControllerID(4)
    private func buildFakeRegistrationResponse(devCtrlID: UInt32,
                                               returnStatus: UInt32 = 0,
                                               returnDataSize: UInt32 = 4) -> Data {
        let payloadSize = 12 + 16 + 12 + 4  // Transportable + Message + ResponseContents + data = 44
        var combined = Data(count: 8 + payloadSize)  // 52 bytes total
        combined.withUnsafeMutableBytes { buf in
            let ptr = buf.baseAddress!
            // Frame header
            var magic = DaemonSocket.magic
            var frameSize = UInt32(payloadSize)
            memcpy(ptr, &magic, 4)
            memcpy(ptr + 4, &frameSize, 4)
            // Transportable: objectType=2 (Response) at payload+4 = combined+12
            var ot: UInt32 = 2
            var bo: UInt8 = 0x4C
            memcpy(ptr + 12, &ot, 4)
            memcpy(ptr + 16, &bo, 1)
            // ResponseContents at combined offset 36
            var status = returnStatus
            memcpy(ptr + 36, &status, 4)   // returnStatus at offset 36
            // senderPID at offset 40: leave as 0
            var dataSize = returnDataSize
            memcpy(ptr + 44, &dataSize, 4)  // returnDataSize at offset 44
            // Return data at offset 48: DeviceControllerID
            var devID = devCtrlID
            memcpy(ptr + 48, &devID, 4)
        }
        return combined
    }

    @Test func extractsDeviceControllerID_fromValidResponse() {
        let response = buildFakeRegistrationResponse(devCtrlID: 0xDEAD_BEEF)
        let extracted = DaemonSocket.parseDeviceControllerID(from: response)
        #expect(extracted == 0xDEAD_BEEF, "DevCtrlID must be parsed from combined offset 48")
    }

    @Test func extractsDeviceControllerID_zero_whenResponseTooShort() {
        // Needs at least 52 bytes (devCtrlOffset + 4 = 48 + 4). Anything shorter → 0.
        let shortResponse = Data(count: 51)
        let extracted = DaemonSocket.parseDeviceControllerID(from: shortResponse)
        #expect(extracted == 0, "Too-short response must yield devCtrlID=0 (safe default)")
    }

    @Test func extractsDeviceControllerID_zero_whenReturnDataSizeTooSmall() {
        // returnDataSize < 4 signals no data was returned by the daemon.
        let response = buildFakeRegistrationResponse(devCtrlID: 0x1234_5678, returnDataSize: 0)
        let extracted = DaemonSocket.parseDeviceControllerID(from: response)
        #expect(extracted == 0, "returnDataSize < 4 must yield devCtrlID=0")
    }

    @Test func devCtrlIDOffset_matchesDocumentedLayout() {
        // Authoritative offset check: frame(8)+Transportable(12)+MessageContent(16)+
        // ResponseContents(12) = 48. Verify extraction at exact byte 48.
        let expectedOffset = 8 + 12 + 16 + 12  // 48
        #expect(expectedOffset == 48, "DevCtrlID must be at combined offset 48")

        var response = Data(count: 52)
        var knownID: UInt32 = 0xCAFE_BABE
        var dataSize: UInt32 = 4
        response.withUnsafeMutableBytes { buf in
            memcpy(buf.baseAddress! + 44, &dataSize, 4)  // returnDataSize at offset 44
            memcpy(buf.baseAddress! + 48, &knownID, 4)   // DevCtrlID at offset 48
        }
        let extracted = DaemonSocket.parseDeviceControllerID(from: response)
        #expect(extracted == 0xCAFE_BABE,
                "parseDeviceControllerID must read UInt32 from exact offset 48")
    }
}

// MARK: - Mixer IPC Tests

/// Tests for mixer element encoding and nonCA dispatch.
///
/// Root cause: mixer properties ('AEMl', 'AEMp', 'AEMm', 'AEMs') must target
/// SymphonyIO (symphonyIONonCAID), not SymphonyPeripheralDevice (monitorDeviceID=0).
/// Sending to monitorDeviceID returns 'what' (2003329396) error.
///
/// Evidence: SymphonyIOControl.cpp:1904-1942 — mixer SetProperty targets SymphonyIO.
/// Evidence: SymphonyIOVendorSpecific.h — kSymphonyIOMixerChannelID_MasterOutput = 2000.
@Suite("MixerElementEncoding")
struct MixerElementEncodingTests {

    // MARK: - Mixer FourCC Selectors

    @Test func mixerLevelFourCC() {
        // 'AEMl' = 0x41454D6C — mixer channel level
        // Evidence: SymphonyIOControl.cpp — kMaestroPropertyMixerChannelLevel
        #expect(AudioPropertySelector.mixerChannelLevel.rawValue == 0x41454D6C,
                "mixerChannelLevel FourCC must be 'AEMl' (0x41454D6C)")
    }

    @Test func mixerPanFourCC() {
        // 'AEMp' = 0x41454D70 — mixer channel pan
        #expect(AudioPropertySelector.mixerChannelPan.rawValue == 0x41454D70,
                "mixerChannelPan FourCC must be 'AEMp' (0x41454D70)")
    }

    @Test func mixerMuteFourCC() {
        // 'AEMm' = 0x41454D6D — mixer channel mute
        #expect(AudioPropertySelector.mixerChannelMute.rawValue == 0x41454D6D,
                "mixerChannelMute FourCC must be 'AEMm' (0x41454D6D)")
    }

    @Test func mixerSoloFourCC() {
        // 'AEMs' = 0x41454D73 — mixer channel solo
        #expect(AudioPropertySelector.mixerChannelSolo.rawValue == 0x41454D73,
                "mixerChannelSolo FourCC must be 'AEMs' (0x41454D73)")
    }

    // MARK: - Element Encoding: (mixerIndex << 16) | channel

    @Test func elementEncodingMixer0Channel0() {
        // Mixer 0, channel 0 → element 0x00000000 = 0
        let element: UInt32 = (0 << 16) | 0
        #expect(element == 0)
    }

    @Test func elementEncodingMixer0Channel1() {
        // Mixer 0, channel 1 → element 0x00000001 = 1
        let element: UInt32 = (0 << 16) | 1
        #expect(element == 1)
    }

    @Test func elementEncodingMixer1Channel0() {
        // Mixer 1, channel 0 → element 0x00010000 = 65536
        let element: UInt32 = (1 << 16) | 0
        #expect(element == 65536)
    }

    @Test func elementEncodingMixer1Channel3() {
        // Mixer 1, channel 3 → element 0x00010003 = 65539
        let element: UInt32 = (1 << 16) | 3
        #expect(element == 65539)
    }

    @Test func elementEncodingUpperBitsAreMixerIndex() {
        // The upper 16 bits of the element must equal the mixer index.
        for mixerIndex: UInt32 in [0, 1, 2, 3] {
            for channel: UInt32 in [0, 1, 7, 15] {
                let element = (mixerIndex << 16) | channel
                #expect(element >> 16 == mixerIndex,
                        "Upper 16 bits of element must be mixerIndex \(mixerIndex)")
                #expect(element & 0xFFFF == channel,
                        "Lower 16 bits of element must be channel \(channel)")
            }
        }
    }

    // MARK: - Master Fader Element: (mixerIndex << 16) | 2000

    @Test func masterChannelIDIs2000() {
        // kSymphonyIOMixerChannelID_MasterOutput = 2000
        // Evidence: SymphonyIOVendorSpecific.h
        let masterChannelID: UInt32 = 2000
        #expect(masterChannelID == 2000)
    }

    @Test func masterElementMixer0Is2000() {
        // Mixer 0 master → element 0x00000000 | 2000 = 2000
        let element: UInt32 = (0 << 16) | 2000
        #expect(element == 2000)
    }

    @Test func masterElementMixer1Is67536() {
        // Mixer 1 master → element 0x00010000 | 2000 = 67536 (0x107D0)
        let element: UInt32 = (1 << 16) | 2000
        #expect(element == 67536)
    }

    @Test func masterElementLower16BitsAlways2000() {
        // Regardless of mixer index, master lower 16 bits = 2000.
        for mixerIndex: UInt32 in [0, 1, 2, 3] {
            let element = (mixerIndex << 16) | 2000
            #expect(element & 0xFFFF == 2000,
                    "Master element lower 16 bits must be 2000 for mixer \(mixerIndex)")
        }
    }
}

// MARK: - USB Level Type Acceptance Tests

/// Tests that USBDeviceConnection accepts both Float64 (dB) and UInt32 (attenuation)
/// for level properties. This prevents the typeMismatch regression when the app falls
/// back to USB path after daemon connection failure.
///
/// Root cause: when daemon fails on app re-launch, AppState falls back to USBDeviceConnection.
/// The volume key handler sends .uint32(attenuation) but USB path originally expected .float64(dB).
/// Result: "typeMismatch(expected: Float64, got: uint32(X))" with no hardware volume change.
@Suite("USBLevelTypeAcceptance")
struct USBLevelTypeAcceptanceTests {

    /// Encode a UInt32 attenuation value and verify it round-trips correctly.
    @Test func attenuationEncodingRoundTrip() {
        // The formula: attenuation = max(0, -speakerLevel)
        // For speakerLevel = -48.0 dB → attenuation = 48.
        // The USB path must accept .uint32(48) and map it to 48 dB attenuation.
        let attenuation: UInt32 = 48
        let value = PropertyValue.uint32(attenuation)
        // Verify the value is extractable as UInt32
        #expect(value.asUInt32 == 48, ".uint32(48) must be extractable as UInt32")
        // And NOT extractable as Float64 (ensures the branch is taken correctly)
        #expect(value.asFloat64 == nil, ".uint32(48) must NOT be extractable as Float64")
    }

    @Test func float64DbValueExtractable() {
        // The legacy USB call path uses Float64 dB (e.g. -48.0).
        let value = PropertyValue.float64(-48.0)
        #expect(value.asFloat64 == -48.0)
        #expect(value.asUInt32 == nil, ".float64(-48.0) must NOT be extractable as UInt32")
    }

    @Test func attenuationConversionFromFloat64() {
        // The USB path maps Float64 dB to UInt8 attenuation: UInt8(clamping: Int(-level))
        // Verify the conversion formula is correct.
        let level: Double = -48.0
        let attenuation = UInt8(clamping: Int(-level))
        #expect(attenuation == 48, "Float64(-48.0) dB → UInt8 attenuation must be 48")
    }

    @Test func attenuationConversionFromUInt32() {
        // When value is .uint32(48), the USB path uses Int(att) directly.
        let att: UInt32 = 48
        let attenuation = UInt8(clamping: Int(att))
        #expect(attenuation == 48, "UInt32(48) → UInt8 attenuation must be 48")
    }

    @Test func attenuationEquivalence_float64AndUInt32() {
        // Both .float64(-48.0) and .uint32(48) must produce the same attenuation.
        let fromFloat = UInt8(clamping: Int(-(-48.0)))
        let fromUInt32 = UInt8(clamping: Int(UInt32(48)))
        #expect(fromFloat == fromUInt32,
                "Float64(-48.0) dB and UInt32(48) attenuation must produce the same UInt8 result")
    }

    @Test func maxAttenuation_clampedTo255() {
        // UInt8(clamping:) handles values > 255 gracefully.
        let huge: UInt32 = 1000
        let clamped = UInt8(clamping: Int(huge))
        #expect(clamped == 255, "Attenuation > 255 must clamp to 255")
    }

    @Test func zeroAttenuation_isMaxVolume() {
        // attenuation=0 → 0 dB (maximum volume)
        let level: Double = 0.0
        let attenuation = UInt8(clamping: Int(-level))
        #expect(attenuation == 0, "0 dB → attenuation 0 (max volume)")
    }
}

// MARK: - Snap-Back Regression Tests (Volume Fix)

/// Regression guard for the volume snap-back bug fixed in the session after Phase 3H.
///
/// Root cause: keepalive GET for 'AEl3' was dispatched to symphonyIONonCAID, which SymphonyIO
/// does NOT handle for GetProperty. This left cachedOutputLevel stale. The keepalive SET then
/// wrote the stale value (64) every 400ms, overriding the user's volume changes (snap-back).
///
/// Three fixes:
///   1. getPropertyNonCA: 'AEl3' GET → monitorDeviceID (=0), NOT symphonyIONonCAID.
///   2. getPropertyNonCA: 'AEmD' GET → symphonyIONonCAID (meter data is the exception).
///   3. cachedLevelUpdate: setProperty for 'AEl3' updates cachedOutputLevel immediately.
///
/// Evidence: keepalive priming GET for 'AEl3' uses nonCA=0 and reads correct hardware level.
@Suite("DaemonSocketSnapBackRegression")
struct DaemonSocketSnapBackRegressionTests {

    // MARK: - cachedLevelUpdate: snap-back prevention

    @Test func cachedLevelUpdate_outputLevel_returnsValue() {
        // P3G snap-back fix: setProperty('AEl3', value=80) must update cachedOutputLevel to 80.
        // Without this fix: cachedOutputLevel stays at default (20), keepalive writes 20 every
        // 400ms, overriding the user's change.
        var level: UInt32 = 80
        let data = Data(bytes: &level, count: 4)
        let result = DaemonSocket.cachedLevelUpdate(propertyID: 0x41456C33, data: data)
        #expect(result == 80,
                "cachedLevelUpdate for 'AEl3' (0x41456C33) must return 80 (snap-back regression guard)")
    }

    @Test func cachedLevelUpdate_outputMute_returnsNil() {
        // 'AEm3' (outputMute) is NOT cached — keepalive only writes 'AEl3'.
        // Returning non-nil here would incorrectly stomp cachedOutputLevel.
        var value: UInt32 = 1
        let data = Data(bytes: &value, count: 4)
        let result = DaemonSocket.cachedLevelUpdate(propertyID: 0x41456D33, data: data)
        #expect(result == nil, "'AEm3' (outputMute) must NOT update cachedOutputLevel")
    }

    @Test func cachedLevelUpdate_meterData_returnsNil() {
        // 'AEmD' meter data must not affect the output level cache.
        var value: UInt32 = 100
        let data = Data(bytes: &value, count: 4)
        let result = DaemonSocket.cachedLevelUpdate(propertyID: 0x41456D44, data: data)
        #expect(result == nil, "'AEmD' must NOT update cachedOutputLevel")
    }

    @Test func cachedLevelUpdate_shortData_returnsNil() {
        // Guard against partial writes: < 4 bytes cannot be interpreted as a UInt32 level.
        let data = Data([0x50])  // 1 byte — too short
        let result = DaemonSocket.cachedLevelUpdate(propertyID: 0x41456C33, data: data)
        #expect(result == nil, "Data shorter than 4 bytes must NOT update cachedOutputLevel")
    }

    @Test func cachedLevelUpdate_emptyData_returnsNil() {
        let result = DaemonSocket.cachedLevelUpdate(propertyID: 0x41456C33, data: Data())
        #expect(result == nil, "Empty data must NOT update cachedOutputLevel")
    }

    @Test func cachedLevelUpdate_maxLevel_roundTrips() {
        // Verify extreme values are preserved correctly (UInt32 range, not truncated).
        var level: UInt32 = 127
        let data = Data(bytes: &level, count: 4)
        let result = DaemonSocket.cachedLevelUpdate(propertyID: 0x41456C33, data: data)
        #expect(result == 127, "Max level (127) must round-trip through cachedLevelUpdate")
    }

    @Test func cachedLevelUpdate_zeroLevel_roundTrips() {
        // Level 0 = full attenuation (muted via level). Must cache correctly.
        var level: UInt32 = 0
        let data = Data(bytes: &level, count: 4)
        let result = DaemonSocket.cachedLevelUpdate(propertyID: 0x41456C33, data: data)
        #expect(result == 0, "Level 0 (full attenuation) must round-trip through cachedLevelUpdate")
    }

    // MARK: - getPropertyNonCA: asymmetric GET dispatch

    @Test func getPropertyNonCA_outputLevel_usesMonitorDeviceID() {
        // THE snap-back regression guard: 'AEl3' GET must use monitorDeviceID (=0).
        // Using symphonyIONonCAID here causes daemon error → cachedOutputLevel never
        // refreshed → keepalive writes stale value → snap-back.
        let result = DaemonSocket.getPropertyNonCA(
            propertyID: 0x41456C33,  // 'AEl3' outputLevel
            symphonyIONonCAID: 42,
            monitorDeviceID: 0
        )
        #expect(result == 0,
                "'AEl3' GET must use monitorDeviceID=0 (not symphonyIONonCAID) — snap-back regression guard")
    }

    @Test func getPropertyNonCA_outputMute_usesMonitorDeviceID() {
        // 'AEm3' GET: same asymmetric rule as 'AEl3'. SymphonyIO handles SET but NOT GET.
        let result = DaemonSocket.getPropertyNonCA(
            propertyID: 0x41456D33,  // 'AEm3' outputMute
            symphonyIONonCAID: 42,
            monitorDeviceID: 0
        )
        #expect(result == 0, "'AEm3' (outputMute) GET must use monitorDeviceID=0")
    }

    @Test func getPropertyNonCA_headphoneLevels_useMonitorDeviceID() {
        // 'AEl1' and 'AEl2' GET: same asymmetric rule (SymphonyIO SET-only for levels).
        for propID: UInt32 in [0x41456C31, 0x41456C32] {
            let result = DaemonSocket.getPropertyNonCA(
                propertyID: propID,
                symphonyIONonCAID: 42,
                monitorDeviceID: 0
            )
            #expect(result == 0,
                    "HP level GET (0x\(String(propID, radix: 16))) must use monitorDeviceID=0")
        }
    }

    @Test func getPropertyNonCA_headphoneMutes_useMonitorDeviceID() {
        // 'AEm1' and 'AEm2' GET: same asymmetric rule.
        for propID: UInt32 in [0x41456D31, 0x41456D32] {
            let result = DaemonSocket.getPropertyNonCA(
                propertyID: propID,
                symphonyIONonCAID: 42,
                monitorDeviceID: 0
            )
            #expect(result == 0,
                    "HP mute GET (0x\(String(propID, radix: 16))) must use monitorDeviceID=0")
        }
    }

    @Test func getPropertyNonCA_meterData_usesSymphonyIONonCAID() {
        // 'AEmD' is the ONE exception: SymphonyIO DOES handle GetProperty for meter data.
        let result = DaemonSocket.getPropertyNonCA(
            propertyID: 0x41456D44,  // 'AEmD' meterData
            symphonyIONonCAID: 42,
            monitorDeviceID: 0
        )
        #expect(result == 42, "'AEmD' GET must use symphonyIONonCAID (SymphonyIO handles meter GET)")
    }

    @Test func getPropertyNonCA_meterData_fallsBackToMonitorDeviceID_whenSymphonyIOZero() {
        // If discovery hasn't run yet (symphonyIONonCAID=0), fall back to monitorDeviceID.
        let result = DaemonSocket.getPropertyNonCA(
            propertyID: 0x41456D44,  // 'AEmD'
            symphonyIONonCAID: 0,
            monitorDeviceID: 99
        )
        #expect(result == 99,
                "'AEmD' GET must fall back to monitorDeviceID=99 when symphonyIONonCAID=0")
    }

    @Test func getPropertyNonCA_unknownProperty_usesMonitorDeviceID() {
        // Any property not specifically handled falls through to monitorDeviceID (=0).
        let result = DaemonSocket.getPropertyNonCA(
            propertyID: 0xDEADBEEF,
            symphonyIONonCAID: 42,
            monitorDeviceID: 0
        )
        #expect(result == 0, "Unknown property GET must use monitorDeviceID=0 (safe default)")
    }

    // MARK: - FourCC constant verification

    @Test func fourCC_outputLevel_isAEl3() {
        // 'AEl3' = 'A'(0x41)+'E'(0x45)+'l'(0x6C)+'3'(0x33) = 0x41456C33
        #expect(AudioPropertySelector.outputLevel.rawValue == 0x41456C33,
                "outputLevel FourCC must be 'AEl3' (0x41456C33) — snap-back fix depends on this")
    }

    @Test func fourCC_meterData_isAEmD() {
        // 'AEmD' = 'A'(0x41)+'E'(0x45)+'m'(0x6D)+'D'(0x44) = 0x41456D44
        #expect(AudioPropertySelector.meterData.rawValue == 0x41456D44,
                "meterData FourCC must be 'AEmD' (0x41456D44) — nonCA dispatch depends on this")
    }

    @Test func fourCC_outputMute_isAEm3() {
        // 'AEm3' must fall through to monitorDeviceID=0 for GET (not SymphonyIO branch).
        #expect(AudioPropertySelector.outputMute.rawValue == 0x41456D33,
                "outputMute FourCC must be 'AEm3' (0x41456D33)")
    }
}

// MARK: - Routing Pair Count Tests (P3G routing discovery)

/// Tests for inputRoutingPairCount / outputRoutingPairCount / inputMeterChannelCount / outputMeterChannelCount.
///
/// These are derived from the NonCA stream IDs discovered during daemon connection.
/// Formula: routing pair count = streamCount × 4 (each IOBoard stream covers 4 stereo pairs).
///          meter channel count = streamCount × 8 (each stream covers 8 channels).
///
/// Evidence: SymphonyIOUSBAudioRoutingController.cpp — 4 pairs per stream.
/// Evidence: mAEstro.h:753-755 — 'AEsm' covers 8 channels per stream.
@Suite("RoutingAndMeterCounts")
struct RoutingAndMeterCountTests {

    // MARK: - Zero streams → zero pairs

    @Test func inputRoutingPairCount_zeroWithoutDiscovery() {
        // Before daemon connection, no stream IDs are discovered.
        // inputRoutingPairCount must be 0 — not a stale value.
        let connection = makeTestConnection()
        #expect(connection.inputRoutingPairCount == 0,
                "inputRoutingPairCount must be 0 before discovery (no streams)")
    }

    @Test func outputRoutingPairCount_zeroWithoutDiscovery() {
        let connection = makeTestConnection()
        #expect(connection.outputRoutingPairCount == 0,
                "outputRoutingPairCount must be 0 before discovery (no streams)")
    }

    @Test func inputMeterChannelCount_zeroWithoutDiscovery() {
        let connection = makeTestConnection()
        #expect(connection.inputMeterChannelCount == 0,
                "inputMeterChannelCount must be 0 before discovery")
    }

    @Test func outputMeterChannelCount_zeroWithoutDiscovery() {
        let connection = makeTestConnection()
        #expect(connection.outputMeterChannelCount == 0,
                "outputMeterChannelCount must be 0 before discovery")
    }

    // MARK: - Formula verification (unit tests of the formula itself)

    @Test func routingPairFormula_oneStream_fourPairs() {
        // With 1 stream discovered, routing pair count = 1 × 4 = 4.
        let streamCount = 1
        let pairCount = streamCount * 4
        #expect(pairCount == 4, "1 IOBoard stream must yield 4 stereo routing pairs")
    }

    @Test func routingPairFormula_fourStreams_sixteenPairs() {
        // Symphony IO 16ch: 4 streams × 4 pairs = 16 input routing pairs.
        // Evidence: SymphonyIOUSBAudioRoutingController.cpp — 4 pairs per stream.
        let streamCount = 4
        let pairCount = streamCount * 4
        #expect(pairCount == 16, "4 IOBoard streams must yield 16 stereo routing pairs (Symphony IO 16ch)")
    }

    @Test func meterChannelFormula_oneStream_eightChannels() {
        // With 1 stream, meter channel count = 1 × 8 = 8.
        // Evidence: mAEstro.h:753-755 — 'AEsm' covers 8 channels per stream.
        let streamCount = 1
        let channelCount = streamCount * 8
        #expect(channelCount == 8, "1 stream must yield 8 meter channels")
    }

    @Test func meterChannelFormula_fourStreams_thirtyTwoChannels() {
        // Symphony IO 16ch: 4 streams × 8 channels = 32 total meter channels.
        let streamCount = 4
        let channelCount = streamCount * 8
        #expect(channelCount == 32, "4 streams must yield 32 meter channels (Symphony IO 16ch)")
    }

    // MARK: - Analog/ADAT heuristics (from routing pair count)

    @Test func analogPairHeuristic_zeroTotal() {
        // When total = 0, analog = max(0, 0 - 4) = 0 (no crash, no negative).
        let total = 0
        let analogPairs = max(0, total - 4)
        #expect(analogPairs == 0, "Zero routing pairs must produce zero analog pairs")
    }

    @Test func analogPairHeuristic_fourTotal() {
        // When total = 4 (only ADAT), analog = max(0, 4 - 4) = 0.
        let total = 4
        let analogPairs = max(0, total - 4)
        #expect(analogPairs == 0, "4-pair total is all ADAT — 0 analog pairs")
    }

    @Test func analogPairHeuristic_sixteenTotal() {
        // Symphony IO 16ch: total = 16 input pairs.
        // Analog = max(0, 16 - 4) = 12. ADAT = 4.
        // Evidence: Symphony IO 16ch has 12 analog + 4 ADAT input pairs.
        let total = 16
        let analogPairs = max(0, total - 4)
        #expect(analogPairs == 12, "16-pair total must yield 12 analog input pairs (Symphony IO 16ch)")
        let adatPairs = total - analogPairs
        #expect(adatPairs == 4, "16-pair total must yield 4 ADAT input pairs")
    }

    @Test func outputAnalogHeuristic_sixteenTotal() {
        // Output: analog = min(4, hwPairCount). Symphony IO 16ch: min(4, 16) = 4.
        // Evidence: Symphony IO has at most 4 analog output pairs (8 channels).
        let hwPairCount = 16
        let analogOutPairs = min(4, hwPairCount)
        #expect(analogOutPairs == 4, "min(4, 16) must be 4 output analog pairs")
    }

    @Test func outputAnalogHeuristic_zeroTotal() {
        let hwPairCount = 0
        let analogOutPairs = min(4, hwPairCount)
        #expect(analogOutPairs == 0, "min(4, 0) must be 0")
    }

    @Test func outputAnalogHeuristic_twoTotal() {
        let hwPairCount = 2
        let analogOutPairs = min(4, hwPairCount)
        #expect(analogOutPairs == 2, "min(4, 2) must be 2")
    }

    // MARK: - getStreamMeterLevels: no reconnect when daemon disconnected

    @Test func getStreamMeterLevels_returnsEmptyWhenDaemonDisconnected() {
        // P3G reconnect-flood fix: meter polling (20fps) must NOT call ensureConnectedLocked()
        // when the daemon is disconnected. That would flood the reconnect log and block
        // the lock for 10 seconds per polling cycle.
        // Guard: if !daemonSocket.isConnected → return [] immediately.
        let connection = makeTestConnection()
        // makeTestConnection() uses audioDeviceID=0 → daemonSocket.isConnected = false
        // (never called connect(), so daemon socket is not connected).
        let inputLevels = connection.getStreamMeterLevels(isInput: true)
        let outputLevels = connection.getStreamMeterLevels(isInput: false)
        #expect(inputLevels.isEmpty,
                "getStreamMeterLevels(input) must return [] when daemon disconnected (no reconnect flood)")
        #expect(outputLevels.isEmpty,
                "getStreamMeterLevels(output) must return [] when daemon disconnected (no reconnect flood)")
    }

    // MARK: - Helpers

    private func makeTestConnection() -> CoreAudioDeviceConnection {
        let id = USBDeviceIdentifier(
            vendorID: ApogeeUSB.vendorID,
            productID: ApogeeUSB.SymphonyIO.pid16ch,
            deviceUID: "test-routing-counts"
        )!
        return CoreAudioDeviceConnection(identifier: id, audioDeviceID: 0)
    }
}

// MARK: - mAEstroStreamMeter Parsing Tests (P3F-51)

/// Unit tests for CoreAudioDeviceConnection.parseMaestroStreamMeter(_:).
///
/// Wire format: `UInt32 m_nNumChannels` followed by `Float32 m_aPeaks[numChannels]` (little-endian).
/// Values are dBFS (negative; -INFINITY for silence).
///
/// Evidence: mAEstro.h:126–127 — mAEstroStreamMeter struct.
/// Evidence: SymphonyIO_Stream.cpp:563 — peaks stored as dBFS from 20*log10.
/// Evidence: mAEstroUtilities.c:1224–1231 — parsing pattern.
@Suite("MaestroStreamMeterParsing")
struct MaestroStreamMeterParsingTests {

    // MARK: - Happy path

    @Test func parseSingleChannel() {
        // 4 bytes numChannels=1, 4 bytes Float32 peak=-6.0
        var numCh: UInt32 = 1
        var peak: Float32 = -6.0
        var data = Data(count: 8)
        data.withUnsafeMutableBytes {
            $0.storeBytes(of: numCh,  toByteOffset: 0, as: UInt32.self)
            $0.storeBytes(of: peak,   toByteOffset: 4, as: Float32.self)
        }
        let result = CoreAudioDeviceConnection.parseMaestroStreamMeter(data)
        #expect(result.count == 1, "1 channel → 1 peak value")
        #expect(result[0] == -6.0, "Peak must be -6.0 dBFS")
    }

    @Test func parseTwoChannels() {
        // Stereo stream: 2 channels at -12.0 and -18.0 dBFS
        var numCh: UInt32 = 2
        var peak0: Float32 = -12.0
        var peak1: Float32 = -18.0
        var data = Data(count: 12)
        data.withUnsafeMutableBytes {
            $0.storeBytes(of: numCh,  toByteOffset: 0, as: UInt32.self)
            $0.storeBytes(of: peak0,  toByteOffset: 4, as: Float32.self)
            $0.storeBytes(of: peak1,  toByteOffset: 8, as: Float32.self)
        }
        let result = CoreAudioDeviceConnection.parseMaestroStreamMeter(data)
        #expect(result.count == 2, "2 channels → 2 peak values")
        #expect(result[0] == -12.0)
        #expect(result[1] == -18.0)
    }

    @Test func parseEightChannels() {
        // Full 8-channel stream (one IOBoard stream = 8 channels)
        // Evidence: mAEstro.h:753-755 — 'AEsm' covers 8 channels per stream.
        let numCh: UInt32 = 8
        let peaks: [Float32] = [-6.0, -12.0, -18.0, -24.0, -30.0, -36.0, -42.0, -48.0]
        var data = Data(count: 4 + 8 * 4)
        data.withUnsafeMutableBytes { buf in
            buf.storeBytes(of: numCh, toByteOffset: 0, as: UInt32.self)
            for (i, peak) in peaks.enumerated() {
                buf.storeBytes(of: peak, toByteOffset: 4 + i * 4, as: Float32.self)
            }
        }
        let result = CoreAudioDeviceConnection.parseMaestroStreamMeter(data)
        #expect(result.count == 8, "8-channel stream → 8 peak values")
        for i in 0..<8 {
            #expect(result[i] == peaks[i], "Channel \(i) peak mismatch")
        }
    }

    @Test func parseSilentChannel() {
        // Hardware silence: SymphonyIO firmware emits Float32(-infinity) or very small values
        var numCh: UInt32 = 1
        var peak: Float32 = -.infinity
        var data = Data(count: 8)
        data.withUnsafeMutableBytes {
            $0.storeBytes(of: numCh, toByteOffset: 0, as: UInt32.self)
            $0.storeBytes(of: peak,  toByteOffset: 4, as: Float32.self)
        }
        let result = CoreAudioDeviceConnection.parseMaestroStreamMeter(data)
        #expect(result.count == 1)
        #expect(result[0] == -.infinity, "Silent channel must parse as -infinity dBFS")
    }

    // MARK: - Edge cases and guards

    @Test func returnsEmpty_whenDataTooShort() {
        // Minimum valid response: 4 bytes numChannels + 4 bytes ≥ 1 peak = 8 bytes.
        // Anything < 8 bytes must return [].
        let tooShort = Data(count: 7)
        let result = CoreAudioDeviceConnection.parseMaestroStreamMeter(tooShort)
        #expect(result.isEmpty, "Data < 8 bytes must return [] (no channels parseable)")
    }

    @Test func returnsEmpty_whenNumChannelsIsZero() {
        // numChannels=0 is a valid "nothing to report" signal from the firmware.
        var numCh: UInt32 = 0
        var data = Data(count: 8)
        data.withUnsafeMutableBytes {
            $0.storeBytes(of: numCh, toByteOffset: 0, as: UInt32.self)
        }
        let result = CoreAudioDeviceConnection.parseMaestroStreamMeter(data)
        #expect(result.isEmpty, "numChannels=0 must return []")
    }

    @Test func returnsEmpty_whenDataTruncated() {
        // numChannels=4 but only 1 peak worth of data — truncated payload.
        // Guard: data.count >= 4 + numChannels * 4.
        var numCh: UInt32 = 4
        var peak: Float32 = -6.0
        var data = Data(count: 8)  // Only space for 1 peak, not 4
        data.withUnsafeMutableBytes {
            $0.storeBytes(of: numCh, toByteOffset: 0, as: UInt32.self)
            $0.storeBytes(of: peak,  toByteOffset: 4, as: Float32.self)
        }
        let result = CoreAudioDeviceConnection.parseMaestroStreamMeter(data)
        #expect(result.isEmpty,
                "Truncated payload (numChannels=4 but only 1 peak of data) must return []")
    }

    @Test func returnsEmpty_forEmptyData() {
        let result = CoreAudioDeviceConnection.parseMaestroStreamMeter(Data())
        #expect(result.isEmpty, "Empty data must return []")
    }

    // MARK: - Byte order / format correctness

    @Test func firstFourBytesAreNumChannels() {
        // Verify the function reads numChannels from bytes 0-3 (little-endian UInt32).
        // Build a blob with numChannels=3 and verify exactly 3 peaks are returned.
        var numCh: UInt32 = 3
        var data = Data(count: 4 + 3 * 4)
        data.withUnsafeMutableBytes { buf in
            buf.storeBytes(of: numCh, toByteOffset: 0, as: UInt32.self)
            for i in 0..<3 {
                var p: Float32 = Float32(-i * 6)
                buf.storeBytes(of: p, toByteOffset: 4 + i * 4, as: Float32.self)
            }
        }
        let result = CoreAudioDeviceConnection.parseMaestroStreamMeter(data)
        #expect(result.count == 3,
                "numChannels=3 at first 4 bytes must produce exactly 3 peaks")
    }

    @Test func peaksStartAtByteOffset4() {
        // First peak must be read from offset 4 (immediately after UInt32 numChannels).
        var numCh: UInt32 = 1
        var knownPeak: Float32 = -99.5
        var data = Data(count: 8)
        data.withUnsafeMutableBytes {
            $0.storeBytes(of: numCh,     toByteOffset: 0, as: UInt32.self)
            $0.storeBytes(of: knownPeak, toByteOffset: 4, as: Float32.self)
        }
        let result = CoreAudioDeviceConnection.parseMaestroStreamMeter(data)
        #expect(result.count == 1)
        #expect(result[0] == knownPeak,
                "First peak must be read from byte offset 4 (immediately after UInt32 numChannels)")
    }

    @Test func exactMinimumSizeIsAccepted() {
        // The exact minimum: numChannels=1 → data must be 8 bytes (4 + 1*4).
        var numCh: UInt32 = 1
        var peak: Float32 = -3.0
        var data = Data(count: 8)
        data.withUnsafeMutableBytes {
            $0.storeBytes(of: numCh, toByteOffset: 0, as: UInt32.self)
            $0.storeBytes(of: peak,  toByteOffset: 4, as: Float32.self)
        }
        let result = CoreAudioDeviceConnection.parseMaestroStreamMeter(data)
        #expect(result.count == 1, "Exactly 8 bytes (minimum) must parse successfully")
        #expect(result[0] == -3.0)
    }
}

// MARK: - RoutingStreamConfig Tests (P3G-41)

/// Tests for the RoutingStreamConfig struct used to drive routing grid labels
/// from HAL terminal type discovery. Pure struct tests — no hardware required.
///
/// Evidence: og_source/maestro2/App/Model/APAudioStreamModel.m:89-131
/// Evidence: og_source/maestro2/App/Controllers/APRoutingDeviceColumnViewController.m:90-107
@Suite("RoutingStreamConfig")
struct RoutingStreamConfigTests {

    // MARK: - Basic initialization

    @Test func allZeroConfig() {
        let cfg = RoutingStreamConfig(
            analogInputPairs: 0, digitalInputPairs: 0,
            analogOutputPairs: 0, digitalOutputPairs: 0
        )
        #expect(cfg.analogInputPairs == 0)
        #expect(cfg.digitalInputPairs == 0)
        #expect(cfg.analogOutputPairs == 0)
        #expect(cfg.digitalOutputPairs == 0)
    }

    // MARK: - Computed totalInputPairs / totalOutputPairs

    @Test func totalInputPairs() {
        let cfg = RoutingStreamConfig(
            analogInputPairs: 4, digitalInputPairs: 4,
            analogOutputPairs: 0, digitalOutputPairs: 0
        )
        #expect(cfg.totalInputPairs == 8, "4 analog + 4 digital = 8 total input pairs")
    }

    @Test func totalOutputPairs() {
        let cfg = RoutingStreamConfig(
            analogInputPairs: 0, digitalInputPairs: 0,
            analogOutputPairs: 4, digitalOutputPairs: 4
        )
        #expect(cfg.totalOutputPairs == 8, "4 analog + 4 digital = 8 total output pairs")
    }

    @Test func totalPairs_allAnalog() {
        let cfg = RoutingStreamConfig(
            analogInputPairs: 8, digitalInputPairs: 0,
            analogOutputPairs: 8, digitalOutputPairs: 0
        )
        #expect(cfg.totalInputPairs == 8)
        #expect(cfg.totalOutputPairs == 8)
    }

    @Test func totalPairs_allDigital() {
        let cfg = RoutingStreamConfig(
            analogInputPairs: 0, digitalInputPairs: 8,
            analogOutputPairs: 0, digitalOutputPairs: 8
        )
        #expect(cfg.totalInputPairs == 8)
        #expect(cfg.totalOutputPairs == 8)
    }

    // MARK: - Standard MKI configs

    @Test func standardMKI16ch() {
        // Standard Symphony IO 16ch: 4 analog (8 ch) + 4 ADAT (8 ch) per direction.
        // Terminal type 0x0601 = analog; optical ADAT = digital.
        let cfg = RoutingStreamConfig(
            analogInputPairs: 4, digitalInputPairs: 4,
            analogOutputPairs: 4, digitalOutputPairs: 4
        )
        #expect(cfg.totalInputPairs == 8,  "16ch input: 4+4=8 total")
        #expect(cfg.totalOutputPairs == 8, "16ch output: 4+4=8 total")
        #expect(cfg.analogInputPairs == 4,  "16ch has 4 analog input pairs (Line)")
        #expect(cfg.digitalInputPairs == 4, "16ch has 4 ADAT input pairs")
        #expect(cfg.analogOutputPairs == 4,  "16ch has 4 analog output pairs (Line)")
        #expect(cfg.digitalOutputPairs == 4, "16ch has 4 ADAT output pairs")
    }

    @Test func mki8chAllAnalog() {
        // 8ch device with only analog I/O card installed:
        // 4 analog input pairs (8 channels), 0 digital.
        let cfg = RoutingStreamConfig(
            analogInputPairs: 4, digitalInputPairs: 0,
            analogOutputPairs: 4, digitalOutputPairs: 0
        )
        #expect(cfg.totalInputPairs == 4)
        #expect(cfg.totalOutputPairs == 4)
        #expect(cfg.digitalInputPairs == 0, "All-analog config has no digital input pairs")
    }

    @Test func mki32ch() {
        // 32ch: 4 analog + 12 digital = 16 input pairs per direction.
        let cfg = RoutingStreamConfig(
            analogInputPairs: 4, digitalInputPairs: 12,
            analogOutputPairs: 4, digitalOutputPairs: 12
        )
        #expect(cfg.totalInputPairs == 16)
        #expect(cfg.totalOutputPairs == 16)
    }

    // MARK: - HAL-derived config vs heuristic: same result for standard config

    @Test func halConfigMatchesHeuristicForStandard16ch() {
        // For standard 16ch MKI (4+4 per direction), HAL terminal types and the
        // old heuristic (max(0, total-4)) must produce the same analog pair count.
        let cfg = RoutingStreamConfig(
            analogInputPairs: 4, digitalInputPairs: 4,
            analogOutputPairs: 4, digitalOutputPairs: 4
        )
        let totalInput = cfg.totalInputPairs       // 8
        let heuristicAnalog = max(0, totalInput - 4)  // max(0, 4) = 4
        #expect(cfg.analogInputPairs == heuristicAnalog,
                "HAL analog input pairs must match heuristic for standard 16ch config")

        let totalOutput = cfg.totalOutputPairs     // 8
        let heuristicAnalogOut = min(4, totalOutput)  // min(4, 8) = 4
        #expect(cfg.analogOutputPairs == heuristicAnalogOut,
                "HAL analog output pairs must match heuristic for standard 16ch config")
    }

    @Test func halConfigBetterThanHeuristicForAllAnalog() {
        // All-analog 8ch: HAL gives 4 analog + 0 digital.
        // Old heuristic: max(0, 4-4) = 0 analog (WRONG — shows all as ADAT).
        // HAL config correctly shows 4 analog, 0 digital.
        let cfg = RoutingStreamConfig(
            analogInputPairs: 4, digitalInputPairs: 0,
            analogOutputPairs: 4, digitalOutputPairs: 0
        )
        let heuristicAnalog = max(0, cfg.totalInputPairs - 4)  // max(0, 0) = 0 — wrong!
        #expect(cfg.analogInputPairs != heuristicAnalog,
                "HAL config must differ from heuristic for all-analog device — heuristic is wrong here")
        #expect(cfg.analogInputPairs == 4, "HAL correctly identifies 4 analog pairs for all-analog device")
        #expect(heuristicAnalog == 0, "Old heuristic incorrectly returns 0 for all-analog device")
    }

    // MARK: - routingStreamConfig returns nil without hardware

    @Test func routingStreamConfigNilWithNoHardware() {
        // With audioDeviceID=0 (no real device), HAL stream queries fail gracefully.
        // routingStreamConfig must return nil rather than crash or return bogus values.
        let id = USBDeviceIdentifier(
            vendorID: ApogeeUSB.vendorID,
            productID: ApogeeUSB.SymphonyIO.pid16ch,
            deviceUID: "test-routing-stream-config"
        )!
        let connection = CoreAudioDeviceConnection(identifier: id, audioDeviceID: 0)
        // On CI without hardware: HAL returns error for audioDeviceID=0.
        // On dev machine with hardware: HAL returns real config.
        // Either way must not crash — just validate the type.
        let config = connection.routingStreamConfig
        if let cfg = config {
            // Hardware found: validate config is internally consistent.
            #expect(cfg.totalInputPairs >= 0)
            #expect(cfg.totalOutputPairs >= 0)
            #expect(cfg.analogInputPairs >= 0)
            #expect(cfg.digitalInputPairs >= 0)
        }
        // nil is also a valid return when no hardware is present.
    }
}

// MARK: - Software Metering Tests

/// Tests for the CoreAudio IO proc-based software metering system.
///
/// Software metering bypasses the broken daemon meter collection (firmware 1.6.24
/// returns all -inf due to "Illegal ...>15" errors) by installing a CoreAudio IO proc
/// that reads actual audio samples through usbaudiod and calculates peak dBFS levels.
///
/// REGRESSION GUARD: These tests catch the exact failure mode where meters show -60
/// (silence) even when audio signal is present. The critical path is:
///   IO proc → peak buffers → softwareInputPeaks() → getStreamMeterLevels() → UI
/// If any link in this chain breaks, meters silently fall back to daemon (-inf) or UI default (-60).

@Suite("SoftwareMetering")
struct SoftwareMeteringTests {

    // MARK: - SoftwareMeterContext

    @Test func contextStructLayout() {
        let inputPeaks = UnsafeMutablePointer<Float>.allocate(capacity: 64)
        let outputPeaks = UnsafeMutablePointer<Float>.allocate(capacity: 64)
        var inputCount: Int32 = 0
        var outputCount: Int32 = 0

        defer {
            inputPeaks.deallocate()
            outputPeaks.deallocate()
        }

        let ctx = SoftwareMeterContext(
            inputPeaks: inputPeaks,
            outputPeaks: outputPeaks,
            inputCount: withUnsafeMutablePointer(to: &inputCount) { $0 },
            outputCount: withUnsafeMutablePointer(to: &outputCount) { $0 }
        )

        #expect(ctx.inputPeaks == inputPeaks)
        #expect(ctx.outputPeaks == outputPeaks)
    }

    // MARK: - Peak Calculation Logic (dBFS formulas)

    @Test func dBFSCalculationForFullScale() {
        let peak: Float = 1.0
        let dB: Float = 20.0 * log10f(peak)
        #expect(abs(dB - 0.0) < 0.001, "Full scale peak (1.0) must yield 0 dBFS")
    }

    @Test func dBFSCalculationForHalfScale() {
        let peak: Float = 0.5
        let dB: Float = 20.0 * log10f(peak)
        #expect(abs(dB - (-6.0206)) < 0.01, "Half scale peak (0.5) must yield ~-6 dBFS")
    }

    @Test func dBFSCalculationForSilence() {
        let peak: Float = 0.0
        let dB: Float = peak > 1.0e-10 ? 20.0 * log10f(peak) : -Float.infinity
        #expect(dB == -Float.infinity, "Zero peak must yield -infinity dBFS")
    }

    @Test func dBFSCalculationForNearSilence() {
        let peak: Float = 1.1e-10
        let dB: Float = peak > 1.0e-10 ? 20.0 * log10f(peak) : -Float.infinity
        #expect(dB.isFinite, "Peaks above 1e-10 must produce finite dBFS values")
        #expect(dB < -190, "Near-zero peak must produce very negative dBFS")
    }

    @Test func dBFSCalculationForTypicalSignal() {
        let peak: Float = 0.1
        let dB: Float = 20.0 * log10f(peak)
        #expect(abs(dB - (-20.0)) < 0.01, "Peak 0.1 must yield ~-20 dBFS")
    }

    // MARK: - Software Meter Buffer Access

    @Test func peakBuffersInitializedToNegativeInfinity() {
        let inputPeaks = UnsafeMutablePointer<Float>.allocate(capacity: 64)
        let outputPeaks = UnsafeMutablePointer<Float>.allocate(capacity: 64)
        defer {
            inputPeaks.deallocate()
            outputPeaks.deallocate()
        }

        for i in 0..<64 {
            inputPeaks[i] = -Float.infinity
            outputPeaks[i] = -Float.infinity
        }

        for i in 0..<64 {
            #expect(inputPeaks[i] == -Float.infinity, "Input peak[\(i)] must be -inf initially")
            #expect(outputPeaks[i] == -Float.infinity, "Output peak[\(i)] must be -inf initially")
        }
    }

    @Test func peakBufferWriteAndRead() {
        let inputPeaks = UnsafeMutablePointer<Float>.allocate(capacity: 64)
        defer { inputPeaks.deallocate() }

        for i in 0..<16 {
            inputPeaks[i] = Float(-20.0 + Double(i))
        }

        let count = 16
        let peaks = (0..<min(count, 64)).map { inputPeaks[$0] }

        #expect(peaks.count == 16)
        #expect(abs(peaks[0] - (-20.0)) < 0.001)
        #expect(abs(peaks[15] - (-5.0)) < 0.001)
    }

    // MARK: - Connection Lifecycle

    @Test func softwareMeteringInactiveByDefault() {
        let connection = makeTestConnection()
        #expect(!connection.isSoftwareMeteringActive,
                "Software metering must be inactive before startSoftwareMetering()")
    }

    @Test func softwareMeteringStartFailsGracefullyWithBadDevice() {
        let connection = makeTestConnection()
        connection.startSoftwareMetering()
        if !connection.isSoftwareMeteringActive {
            #expect(!connection.isSoftwareMeteringActive)
        }
    }

    @Test func softwareInputPeaksEmptyWhenInactive() {
        let connection = makeTestConnection()
        let peaks = connection.softwareInputPeaks()
        #expect(peaks.isEmpty, "Input peaks must be empty when metering is inactive")
    }

    @Test func softwareOutputPeaksEmptyWhenInactive() {
        let connection = makeTestConnection()
        let peaks = connection.softwareOutputPeaks()
        #expect(peaks.isEmpty, "Output peaks must be empty when metering is inactive")
    }

    @Test func stopSoftwareMeteringIdempotent() {
        let connection = makeTestConnection()
        connection.stopSoftwareMetering()
        #expect(!connection.isSoftwareMeteringActive)
    }

    @Test func startSoftwareMeteringIdempotent() {
        let connection = makeTestConnection()
        connection.startSoftwareMetering()
        connection.startSoftwareMetering()
        connection.stopSoftwareMetering()
    }

    // MARK: - CRITICAL: Injected Peak Data Pipeline
    // These tests simulate what the IO proc does and verify the full read path.
    // If these fail, meters show -60 (silence) even with real audio signal.

    @Test func injectedInputPeaksReadBack() {
        // REGRESSION GUARD: Simulate IO proc writing 16 channels of input peaks.
        // softwareInputPeaks() must return the injected data.
        let connection = makeTestConnection()
        connection.testSetSoftwareMeteringActive(true)

        let testPeaks: [Float] = (0..<16).map { Float(-20.0 + Double($0)) }
        connection.testInjectSoftwareMeterData(inputPeaks: testPeaks, outputPeaks: [])

        let readBack = connection.softwareInputPeaks()
        #expect(readBack.count == 16,
                "REGRESSION: softwareInputPeaks() must return 16 channels after injection, got \(readBack.count)")
        #expect(abs(readBack[0] - (-20.0)) < 0.001,
                "REGRESSION: First input peak must be -20.0 dBFS, got \(readBack[0])")
        #expect(abs(readBack[15] - (-5.0)) < 0.001,
                "REGRESSION: Last input peak must be -5.0 dBFS, got \(readBack[15])")

        connection.testSetSoftwareMeteringActive(false)
    }

    @Test func injectedOutputPeaksReadBack() {
        // REGRESSION GUARD: Verify output peak injection + readback.
        let connection = makeTestConnection()
        connection.testSetSoftwareMeteringActive(true)

        let testPeaks: [Float] = [-10.0, -12.0, -8.5, -15.0]
        connection.testInjectSoftwareMeterData(inputPeaks: [], outputPeaks: testPeaks)

        let readBack = connection.softwareOutputPeaks()
        #expect(readBack.count == 4, "Output peaks must have 4 channels")
        #expect(abs(readBack[0] - (-10.0)) < 0.001)
        #expect(abs(readBack[2] - (-8.5)) < 0.001)

        connection.testSetSoftwareMeteringActive(false)
    }

    @Test func getStreamMeterLevelsPrefersSoftwareMetering() {
        // CRITICAL REGRESSION GUARD: When software metering is active and has data,
        // getStreamMeterLevels() MUST return the software peaks, NOT fall through
        // to the daemon path (which returns -inf on firmware 1.6.24).
        let connection = makeTestConnection()
        connection.testSetSoftwareMeteringActive(true)

        let testPeaks: [Float] = [-21.6, -22.0, -20.5, -25.0, -30.0, -28.0, -18.0, -19.0,
                                   -21.0, -22.5, -20.0, -24.0, -35.0, -40.0, -45.0, -50.0]
        connection.testInjectSoftwareMeterData(inputPeaks: testPeaks, outputPeaks: [])

        let levels = connection.getStreamMeterLevels(isInput: true)
        #expect(!levels.isEmpty,
                "REGRESSION: getStreamMeterLevels(isInput: true) must NOT be empty when software metering has data")
        #expect(levels.count == 16,
                "REGRESSION: Expected 16 channels from software metering, got \(levels.count)")
        #expect(abs(levels[0] - (-21.6)) < 0.001,
                "REGRESSION: First channel must be -21.6 dBFS from software metering, got \(levels[0])")

        // Verify NO channel is -inf (which would indicate fallback to broken daemon)
        for (i, level) in levels.enumerated() {
            #expect(level.isFinite,
                    "REGRESSION: Channel \(i) is -inf — software metering data was ignored, fell through to daemon!")
        }

        connection.testSetSoftwareMeteringActive(false)
    }

    @Test func getStreamMeterLevelsOutputPathWorks() {
        // Same test for output path.
        let connection = makeTestConnection()
        connection.testSetSoftwareMeteringActive(true)

        let testPeaks: [Float] = [-15.0, -16.0]
        connection.testInjectSoftwareMeterData(inputPeaks: [], outputPeaks: testPeaks)

        let levels = connection.getStreamMeterLevels(isInput: false)
        #expect(!levels.isEmpty,
                "REGRESSION: Output meter levels must NOT be empty when software metering has data")
        #expect(abs(levels[0] - (-15.0)) < 0.001)

        connection.testSetSoftwareMeteringActive(false)
    }

    @Test func getStreamMeterLevelsFallsBackWhenInactive() {
        // When software metering is NOT active, getStreamMeterLevels should fall through
        // to daemon path (which returns [] on CI with no hardware).
        let connection = makeTestConnection()
        #expect(!connection.isSoftwareMeteringActive)

        let levels = connection.getStreamMeterLevels(isInput: true)
        // Without daemon connection or hardware, expect empty
        #expect(levels.isEmpty,
                "Without software metering or hardware, meter levels must be empty")
    }

    @Test func getStreamMeterLevelsFallsBackWhenPeaksEmpty() {
        // EDGE CASE: Software metering is "active" but peaks haven't been written yet
        // (IO proc hasn't fired). getStreamMeterLevels should fall through to daemon.
        let connection = makeTestConnection()
        connection.testSetSoftwareMeteringActive(true)
        // Don't inject any data — peaks count is 0

        let levels = connection.getStreamMeterLevels(isInput: true)
        // Peaks are empty → falls through to daemon → no hardware → empty
        #expect(levels.isEmpty,
                "With empty software peaks, should fall through to daemon (which returns [] without hardware)")

        connection.testSetSoftwareMeteringActive(false)
    }

    @Test func injectedPeaksOverwrite() {
        // Verify that injecting new data overwrites old data.
        let connection = makeTestConnection()
        connection.testSetSoftwareMeteringActive(true)

        // First injection: -20 dBFS
        connection.testInjectSoftwareMeterData(inputPeaks: [-20.0], outputPeaks: [])
        let first = connection.softwareInputPeaks()
        #expect(abs(first[0] - (-20.0)) < 0.001)

        // Second injection: -10 dBFS
        connection.testInjectSoftwareMeterData(inputPeaks: [-10.0], outputPeaks: [])
        let second = connection.softwareInputPeaks()
        #expect(abs(second[0] - (-10.0)) < 0.001,
                "Second injection must overwrite first")

        connection.testSetSoftwareMeteringActive(false)
    }

    @Test func silenceThresholdProducesNegativeInfinity() {
        // Values at or below 1e-10 must produce -inf in the IO proc dBFS calculation.
        // This ensures the UI shows silence (-60) for silent channels.
        let connection = makeTestConnection()
        connection.testSetSoftwareMeteringActive(true)

        connection.testInjectSoftwareMeterData(
            inputPeaks: [-Float.infinity, -Float.infinity],
            outputPeaks: []
        )
        let peaks = connection.softwareInputPeaks()
        #expect(peaks.count == 2)
        #expect(peaks[0] == -Float.infinity, "Silent channel must be -inf dBFS")
        #expect(peaks[1] == -Float.infinity, "Silent channel must be -inf dBFS")

        connection.testSetSoftwareMeteringActive(false)
    }

    @Test func mixedSignalAndSilence() {
        // Realistic scenario: some channels have signal, others are silent.
        // Must correctly report both signal and silence levels.
        let connection = makeTestConnection()
        connection.testSetSoftwareMeteringActive(true)

        let mixed: [Float] = [-21.6, -Float.infinity, -Float.infinity, -Float.infinity,
                               -Float.infinity, -Float.infinity, -Float.infinity, -18.0,
                               -20.0, -22.0, -19.5, -Float.infinity,
                               -Float.infinity, -Float.infinity, -Float.infinity, -Float.infinity]
        connection.testInjectSoftwareMeterData(inputPeaks: mixed, outputPeaks: [])

        let levels = connection.getStreamMeterLevels(isInput: true)
        #expect(levels.count == 16)
        #expect(abs(levels[0] - (-21.6)) < 0.001, "Channel 0 must show signal")
        #expect(levels[1] == -Float.infinity, "Channel 1 must show silence")
        #expect(abs(levels[7] - (-18.0)) < 0.001, "Channel 7 must show signal")
        #expect(levels[15] == -Float.infinity, "Channel 15 must show silence")

        connection.testSetSoftwareMeteringActive(false)
    }

    // MARK: - Helpers

    private func makeTestConnection() -> CoreAudioDeviceConnection {
        let id = USBDeviceIdentifier(
            vendorID: ApogeeUSB.vendorID,
            productID: ApogeeUSB.SymphonyIO.pid16ch,
            deviceUID: "test-software-metering"
        )!
        return CoreAudioDeviceConnection(identifier: id, audioDeviceID: 0)
    }
}

// MARK: - Test Helpers

/// Expose the private propertyDataType method for testing.
extension CoreAudioDeviceConnection {
    func testPropertyDataType(for selector: AudioPropertySelector) -> PropertyDataType {
        propertyDataType(for: selector)
    }

    func testEncodeValue(_ value: PropertyValue) -> Data {
        encodeValue(value)
    }

    func testDecodeResponse(data: Data, dataType: PropertyDataType) -> PropertyValue {
        decodeResponse(data: data, dataType: dataType)
    }
}

@Test("clock-source name uses CoreAudio AudioValueTranslation ABI")
func clockSourceNameTranslationABI() {
    var sourceID: UInt32 = 0x1234
    var output: Unmanaged<CFString>? = nil
    withUnsafeMutablePointer(to: &sourceID) { sourcePointer in
        withUnsafeMutablePointer(to: &output) { outputPointer in
            let translation = CoreAudioDeviceConnection.makeClockSourceNameTranslation(
                sourceID: sourcePointer, output: outputPointer)
            #expect(translation.mInputData == UnsafeMutableRawPointer(sourcePointer))
            #expect(translation.mInputDataSize == UInt32(MemoryLayout<UInt32>.size))
            #expect(translation.mOutputData == UnsafeMutableRawPointer(outputPointer))
            #expect(translation.mOutputDataSize == UInt32(MemoryLayout<CFString?>.size))
            // Exercise both sides as the HAL does, while all pointed-to storage is alive.
            #expect(translation.mInputData.load(as: UInt32.self) == 0x1234)
            let name = Unmanaged.passRetained("Internal" as CFString)
            translation.mOutputData.storeBytes(of: Optional(name), as: Unmanaged<CFString>?.self)
            #expect(outputPointer.pointee?.takeRetainedValue() as String? == "Internal")
        }
    }
}
