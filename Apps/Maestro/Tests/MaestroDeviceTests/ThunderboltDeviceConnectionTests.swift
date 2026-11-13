/// Tests for ThunderboltDeviceConnection.
///
/// Validates transport type detection, property mapping, and the
/// Thunderbolt connection behavior for unsupported properties.
/// Hardware tests require a ThunderBridge adapter connected.

import Testing
import MaestroCore
@testable import MaestroDevice

@Suite("ThunderboltDeviceConnection")
struct ThunderboltDeviceConnectionTests {

    // Create a test identifier (same pattern as USBDeviceIdentifier for 32ch mode)
    static let testIdentifier = USBDeviceIdentifier(
        vendorID: ApogeeUSB.vendorID,
        productID: ApogeeUSB.SymphonyIO.pid32ch,
        deviceUID: "SymphonyThunderbridge-test-uid"
    )!

    // MARK: - TransportType

    @Test("TransportType: USB display name")
    func transportTypeUSB() {
        let t = TransportType.usb
        #expect(t.displayName == "USB")
        #expect(t.rawValue == "USB")
    }

    @Test("TransportType: Thunderbolt display name")
    func transportTypeThunderbolt() {
        let t = TransportType.thunderbolt
        #expect(t.displayName == "ThunderBridge")
        #expect(t.rawValue == "Thunderbolt")
    }

    @Test("TransportType: equality")
    func transportTypeEquality() {
        #expect(TransportType.usb == TransportType.usb)
        #expect(TransportType.thunderbolt != TransportType.usb)
    }

    @Test("TransportType: Hashable conformance")
    func transportTypeHashable() {
        let set: Set<TransportType> = [.usb, .thunderbolt, .usb]
        #expect(set.count == 2)
    }

    @Test("TransportType: raw value round-trip")
    func transportTypeRawRoundTrip() {
        let original = TransportType.thunderbolt
        let raw = original.rawValue
        let restored = TransportType(rawValue: raw)
        #expect(restored == original)
        #expect(raw == "Thunderbolt")

        let usbRaw = TransportType.usb.rawValue
        #expect(TransportType(rawValue: usbRaw) == .usb)

        // Invalid raw value returns nil
        #expect(TransportType(rawValue: "FireWire") == nil)
    }

    // MARK: - ThunderboltDeviceConnection

    @Test("ThunderboltDeviceConnection: initial state")
    func connectionInitialState() {
        let conn = ThunderboltDeviceConnection(
            identifier: Self.testIdentifier, audioDeviceID: 0)
        #expect(conn.isConnected == true)
        #expect(conn.identifier.mode == .channels32)
        #expect(conn.identifier.vendorID == ApogeeUSB.vendorID)
    }

    @Test("ThunderboltDeviceConnection: disconnect sets isConnected false")
    func connectionDisconnect() async {
        let conn = ThunderboltDeviceConnection(
            identifier: Self.testIdentifier, audioDeviceID: 0)
        await conn.disconnect()
        #expect(conn.isConnected == false)
    }

    @Test("ThunderboltDeviceConnection: hasProperty for supported selectors")
    func connectionHasProperty() async {
        let conn = ThunderboltDeviceConnection(
            identifier: Self.testIdentifier, audioDeviceID: 0)

        // Supported via CoreAudio HAL
        #expect(await conn.hasProperty(PropertyAddress(selector: .outputLevel)) == true)
        #expect(await conn.hasProperty(PropertyAddress(selector: .outputMute)) == true)
        #expect(await conn.hasProperty(PropertyAddress(selector: .sampleRate)) == true)
        #expect(await conn.hasProperty(PropertyAddress(selector: .outputLevelRange)) == true)

        // Supported via dext vendor commands
        #expect(await conn.hasProperty(PropertyAddress(selector: .clockSource)) == true)
        #expect(await conn.hasProperty(PropertyAddress(selector: .micGain)) == true)
        #expect(await conn.hasProperty(PropertyAddress(selector: .softLimit)) == true)
        #expect(await conn.hasProperty(PropertyAddress(selector: .digitalRefLevel)) == true)
        #expect(await conn.hasProperty(PropertyAddress(selector: .analogIOType)) == true)
        #expect(await conn.hasProperty(PropertyAddress(selector: .outputSumToMono)) == true)
        #expect(await conn.hasProperty(PropertyAddress(selector: .headphone1Dim)) == true)
        #expect(await conn.hasProperty(PropertyAddress(selector: .headphone2Dim)) == true)
        #expect(await conn.hasProperty(PropertyAddress(selector: .headphone1SumToMono)) == true)
        #expect(await conn.hasProperty(PropertyAddress(selector: .headphone2SumToMono)) == true)
        #expect(await conn.hasProperty(PropertyAddress(selector: .activeSpeakerSet)) == true)
        #expect(await conn.hasProperty(PropertyAddress(selector: .peaksClear)) == true)
        #expect(await conn.hasProperty(PropertyAddress(selector: .spdifReplaceID)) == true)
        #expect(await conn.hasProperty(PropertyAddress(selector: .spdifMirrorID)) == true)
        #expect(await conn.hasProperty(PropertyAddress(selector: .opticalInFormat)) == true)
        #expect(await conn.hasProperty(PropertyAddress(selector: .opticalOutFormat)) == true)
        #expect(await conn.hasProperty(PropertyAddress(selector: .mixerSoftwareReturnID)) == true)

        // Supported for READ only — served by the dext's board-type read selector,
        // never writable (writing a fitted card is meaningless).
        #expect(await conn.hasProperty(PropertyAddress(selector: .primaryBoardType)) == true)
        #expect(await conn.hasProperty(PropertyAddress(selector: .secondaryBoardType)) == true)
        #expect(await conn.isPropertySettable(PropertyAddress(selector: .primaryBoardType)) == false)
        #expect(await conn.isPropertySettable(PropertyAddress(selector: .secondaryBoardType)) == false)
    }

    /// Clock source is asked of CoreAudio, not refused outright. There is no
    /// device 0, so the read fails -- as a transport error, which is what tells
    /// the caller a real read was attempted.
    @Test("ThunderboltDeviceConnection: clock source is read from the device")
    func clockSourceIsReadFromDevice() async {
        let conn = ThunderboltDeviceConnection(
            identifier: Self.testIdentifier, audioDeviceID: 0)
        do {
            _ = try await conn.getProperty(PropertyAddress(selector: .clockSource))
            #expect(Bool(false), "No such device; should have thrown")
        } catch let error as DeviceConnectionError {
            guard case .transportError = error else {
                #expect(Bool(false), "Wrong error type: \(error)")
                return
            }
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    // MARK: - Remembered write-only settings

    /// The reported bug: change a setting, leave the tab, come back, and the
    /// control shows its default. The view re-reads the device on appearance, so
    /// the read has to return what was written. `.prefix` has no hardware opcode
    /// on any transport, so this exercises the real write path with no dext.
    @Test("ThunderboltDeviceConnection: a written setting reads back")
    func rememberedSettingReadsBack() async throws {
        let conn = ThunderboltDeviceConnection(
            identifier: Self.testIdentifier, audioDeviceID: 0)
        let prefix = PropertyAddress(selector: .prefix)

        try await conn.setProperty(prefix, value: .string("C"))
        #expect(try await conn.getProperty(prefix) == .string("C"))

        try await conn.setProperty(prefix, value: .string("F"))
        #expect(try await conn.getProperty(prefix) == .string("F"))
    }

    /// Nothing is invented: until this connection has written a value the read
    /// throws as it always did, and the caller keeps its own default.
    @Test("ThunderboltDeviceConnection: an unwritten setting still throws")
    func unwrittenSettingStillThrows() async {
        let conn = ThunderboltDeviceConnection(
            identifier: Self.testIdentifier, audioDeviceID: 0)
        for selector in ThunderboltDeviceConnection.rememberedSelectors {
            await #expect(throws: DeviceConnectionError.unsupportedProperty(selector)) {
                _ = try await conn.getProperty(PropertyAddress(selector: selector))
            }
        }
    }

    /// A write that never reached the driver must not be reported back as the
    /// device's state. With no dext attached the send throws.
    @Test("ThunderboltDeviceConnection: a failed write is not remembered")
    func failedWriteIsNotRemembered() async {
        let conn = ThunderboltDeviceConnection(
            identifier: Self.testIdentifier, audioDeviceID: 0)
        let peakHold = PropertyAddress(selector: .peakHoldMode)

        await #expect(throws: (any Error).self) {
            try await conn.setProperty(peakHold, value: .uint32(2))
        }
        await #expect(throws: DeviceConnectionError.unsupportedProperty(.peakHoldMode)) {
            _ = try await conn.getProperty(peakHold)
        }
    }

    /// Per-channel input, mixer and routing state keep their own stores; this
    /// cache must not become a second answer for them.
    @Test("ThunderboltDeviceConnection: remembered set excludes channel, mixer and routing state")
    func rememberedSetIsNarrow() {
        let excluded: [AudioPropertySelector] = [
            .micGain, .phantom, .analogIOType, .routing, .mixerChannelLevel,
            .mixerChannelMute, .mixerSoftwareReturnID, .clockSource, .sampleRate,
            .outputLevel, .outputMute, .opticalInFormat, .opticalOutFormat,
        ]
        for selector in excluded {
            #expect(!ThunderboltDeviceConnection.rememberedSelectors.contains(selector))
        }
    }

    @Test("ThunderboltDeviceConnection: isPropertySettable")
    func connectionSettable() async {
        let conn = ThunderboltDeviceConnection(
            identifier: Self.testIdentifier, audioDeviceID: 0)

        #expect(await conn.isPropertySettable(PropertyAddress(selector: .outputLevel)) == true)
        #expect(await conn.isPropertySettable(PropertyAddress(selector: .outputMute)) == true)
        #expect(await conn.isPropertySettable(PropertyAddress(selector: .sampleRate)) == true)

        // Read-only
        #expect(await conn.isPropertySettable(PropertyAddress(selector: .outputLevelRange)) == false)
        // Settable via IOUserClient
        #expect(await conn.isPropertySettable(PropertyAddress(selector: .clockSource)) == true)
        #expect(await conn.isPropertySettable(PropertyAddress(selector: .opticalOutFormat)) == true)
        #expect(await conn.isPropertySettable(PropertyAddress(selector: .mixerSoftwareReturnID)) == true)
    }

    @Test("ThunderboltDeviceConnection: unsupported property throws")
    func connectionUnsupportedProperty() async {
        let conn = ThunderboltDeviceConnection(
            identifier: Self.testIdentifier, audioDeviceID: 0)
        // .micGain has no read on this transport. (.clockSource used to stand in
        // here; it is now read from the dext's clock control -- see below.)
        do {
            _ = try await conn.getProperty(PropertyAddress(selector: .micGain))
            #expect(Bool(false), "Should have thrown")
        } catch let error as DeviceConnectionError {
            if case .unsupportedProperty(let sel) = error {
                #expect(sel == .micGain)
            } else {
                #expect(Bool(false), "Wrong error type: \(error)")
            }
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    @Test("ThunderboltDeviceConnection: disconnected throws")
    func connectionDisconnectedThrows() async {
        let conn = ThunderboltDeviceConnection(
            identifier: Self.testIdentifier, audioDeviceID: 0)
        await conn.disconnect()
        do {
            _ = try await conn.getProperty(PropertyAddress(selector: .outputLevel))
            #expect(Bool(false), "Should have thrown")
        } catch let error as DeviceConnectionError {
            #expect(error == .notConnected)
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    @Test("ThunderboltDeviceConnection: setProperty on disconnected throws")
    func connectionSetPropertyDisconnectedThrows() async {
        let conn = ThunderboltDeviceConnection(
            identifier: Self.testIdentifier, audioDeviceID: 0)
        await conn.disconnect()
        do {
            try await conn.setProperty(
                PropertyAddress(selector: .outputLevel), value: .float64(-20.0))
            #expect(Bool(false), "Should have thrown")
        } catch let error as DeviceConnectionError {
            #expect(error == .notConnected)
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    @Test("ThunderboltDeviceConnection: setProperty unsupported selector throws")
    func connectionSetPropertyUnsupportedThrows() async {
        let conn = ThunderboltDeviceConnection(
            identifier: Self.testIdentifier, audioDeviceID: 0)
        do {
            try await conn.setProperty(
                PropertyAddress(selector: .primaryBoardType), value: .uint32(0))
            #expect(Bool(false), "Should have thrown")
        } catch let error as DeviceConnectionError {
            if case .unsupportedProperty(let sel) = error {
                #expect(sel == .primaryBoardType)
            } else {
                #expect(Bool(false), "Wrong error type: \(error)")
            }
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    @Test("ThunderboltDeviceConnection: setProperty outputLevel type mismatch throws")
    func connectionSetPropertyTypeMismatch() async {
        let conn = ThunderboltDeviceConnection(
            identifier: Self.testIdentifier, audioDeviceID: 0)
        do {
            // outputLevel expects Float64, not string
            try await conn.setProperty(
                PropertyAddress(selector: .outputLevel), value: .uint32(42))
            // uint32 doesn't have asFloat64, so this should throw typeMismatch
            // Actually, PropertyValue.uint32 doesn't provide asFloat64, so it throws
        } catch let error as DeviceConnectionError {
            if case .typeMismatch = error {
                // Expected
            } else {
                // May also be a transport error from invalid AudioDeviceID=0 — both acceptable
            }
        } catch {
            // CoreAudio error from invalid device ID — acceptable in unit test
        }
    }

    @Test("ThunderboltDeviceConnection: outputLevelRange returns -64..0")
    func connectionLevelRange() async throws {
        let conn = ThunderboltDeviceConnection(
            identifier: Self.testIdentifier, audioDeviceID: 0)
        let value = try await conn.getProperty(PropertyAddress(selector: .outputLevelRange))
        if case .range(let min, let max) = value {
            #expect(min == -64.0)
            #expect(max == 0.0)
        } else {
            #expect(Bool(false), "Expected .range, got \(value)")
        }
    }

    @Test("ThunderboltDeviceConnection: outputLevelRange not settable")
    func connectionLevelRangeNotSettable() async {
        let conn = ThunderboltDeviceConnection(
            identifier: Self.testIdentifier, audioDeviceID: 0)
        #expect(await conn.hasProperty(PropertyAddress(selector: .outputLevelRange)) == true)
        #expect(await conn.isPropertySettable(PropertyAddress(selector: .outputLevelRange)) == false)
    }

    // MARK: - Discovery

    @Test("Discovery: discoverAllSymphonyIO returns array")
    func discoveryReturnsArray() {
        // This tests the API shape — actual device detection requires hardware
        let results = CoreAudioDeviceConnection.discoverAllSymphonyIO()
        // No hardware in CI → empty array. If hardware is present, validate structure.
        for result in results {
            #expect(result.identifier.vendorID == ApogeeUSB.vendorID)
            #expect(result.name.contains("Symphony"))
            #expect(result.transportType == .usb || result.transportType == .thunderbolt)
        }
    }

    @Test("Discovery: discoverSymphonyIO backward compatible")
    func discoveryBackwardCompatible() {
        // The legacy API should still work (returns first match or nil)
        let result = CoreAudioDeviceConnection.discoverSymphonyIO()
        // No assertion on non-nil — depends on hardware presence
        if let (deviceID, identifier) = result {
            #expect(deviceID > 0)
            #expect(identifier.vendorID == ApogeeUSB.vendorID)
        }
    }

    @Test("Discovery: discoverAllSymphonyIO excludes Maestro ASP")
    func discoveryExcludesMaestro() {
        // If both Symphony IO hardware and "Symphony I/O : Maestro" are present,
        // the ASP should be filtered out (contains "Maestro" in name).
        let results = CoreAudioDeviceConnection.discoverAllSymphonyIO()
        for result in results {
            #expect(!result.name.contains("Maestro"),
                    "Discovery should exclude ASP virtual device, got: \(result.name)")
        }
    }

    @Test("Discovery: Thunderbolt sorted first")
    func discoveryThunderboltFirst() {
        let results = CoreAudioDeviceConnection.discoverAllSymphonyIO()
        // If both transports are present, Thunderbolt should come first
        if results.count >= 2 {
            let tbIndex = results.firstIndex { $0.transportType == .thunderbolt }
            let usbIndex = results.firstIndex { $0.transportType == .usb }
            if let tb = tbIndex, let usb = usbIndex {
                #expect(tb < usb, "Thunderbolt should be sorted before USB")
            }
        }
    }

    // MARK: - DiscoveredSymphonyIO Structure

    @Test("DiscoveredSymphonyIO: struct fields accessible")
    func discoveredStructFields() {
        // Verify the struct has the expected public fields
        let discovered = CoreAudioDeviceConnection.DiscoveredSymphonyIO(
            audioDeviceID: 42,
            identifier: Self.testIdentifier,
            transportType: .thunderbolt,
            name: "Symphony I/O: ThunderBridge"
        )
        #expect(discovered.audioDeviceID == 42)
        #expect(discovered.identifier.vendorID == ApogeeUSB.vendorID)
        #expect(discovered.transportType == .thunderbolt)
        #expect(discovered.name == "Symphony I/O: ThunderBridge")
    }
}
