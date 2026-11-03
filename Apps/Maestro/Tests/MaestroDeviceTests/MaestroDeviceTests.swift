import Testing
@testable import MaestroDevice
@testable import MaestroCore

@Test func deviceModuleLoads() {
    // Shape, not literal — see MaestroCoreTests.coreModuleLoads.
    let parts = MaestroDevice.version.split(separator: ".")
    #expect(parts.count == 3)
    #expect(parts.allSatisfy { UInt($0) != nil })
}

// MARK: - USB Device Identifier Tests

@Suite("USBDeviceIdentifier")
struct USBDeviceIdentifierTests {

    @Test func apogeeVendorID() {
        #expect(ApogeeUSB.vendorID == 0x0C60)
    }

    @Test func symphonyIOProductIDs() {
        #expect(ApogeeUSB.SymphonyIO.pid16ch == 0x0010)
        #expect(ApogeeUSB.SymphonyIO.pid8ch == 0x0011)
        #expect(ApogeeUSB.SymphonyIO.pid32ch == 0x0012)
        #expect(ApogeeUSB.SymphonyIO.allProductIDs.count == 3)
    }

    @Test func usbModeFromProductID() {
        #expect(USBMode(productID: 0x0010) == .channels16)
        #expect(USBMode(productID: 0x0011) == .channels8)
        #expect(USBMode(productID: 0x0012) == .channels32)
        #expect(USBMode(productID: 0x9999) == nil)
    }

    @Test func usbModeChannelCounts() {
        #expect(USBMode.channels32.channelCount == 32)
        #expect(USBMode.channels16.channelCount == 16)
        #expect(USBMode.channels8.channelCount == 8)
    }

    @Test func usbModeProductIDRoundTrip() {
        for mode in [USBMode.channels8, .channels16, .channels32] {
            #expect(USBMode(productID: mode.productID) == mode)
        }
    }

    @Test func usbModeSampleRates() {
        #expect(USBMode.channels32.availableSampleRates.count == 2)
        #expect(USBMode.channels16.availableSampleRates.count == 4)
        #expect(USBMode.channels8.availableSampleRates.count == 6)
    }

    @Test func identifierCreation() {
        let id = USBDeviceIdentifier(
            vendorID: 0x0C60,
            productID: 0x0010,
            deviceUID: "test-device"
        )
        #expect(id != nil)
        #expect(id?.mode == .channels16)
        #expect(id?.deviceUID == "test-device")
        #expect(id?.isSymphonyIO == true)
    }

    @Test func identifierRejectsWrongVendor() {
        let id = USBDeviceIdentifier(
            vendorID: 0x1234,
            productID: 0x0010,
            deviceUID: "test"
        )
        #expect(id == nil)
    }

    @Test func identifierRejectsUnknownProduct() {
        let id = USBDeviceIdentifier(
            vendorID: 0x0C60,
            productID: 0xFFFF,
            deviceUID: "test"
        )
        #expect(id == nil)
    }

    @Test func identifierEquatable() {
        let a = USBDeviceIdentifier(vendorID: 0x0C60, productID: 0x0010, deviceUID: "dev1")!
        let b = USBDeviceIdentifier(vendorID: 0x0C60, productID: 0x0010, deviceUID: "dev1")!
        let c = USBDeviceIdentifier(vendorID: 0x0C60, productID: 0x0010, deviceUID: "dev2")!
        #expect(a == b)
        #expect(a != c)
    }

    @Test func identifierHashable() {
        let a = USBDeviceIdentifier(vendorID: 0x0C60, productID: 0x0011, deviceUID: "dev1")!
        let b = USBDeviceIdentifier(vendorID: 0x0C60, productID: 0x0011, deviceUID: "dev1")!
        var set = Set<USBDeviceIdentifier>()
        set.insert(a)
        set.insert(b)
        #expect(set.count == 1)
    }
}

// MARK: - Simulated Device Tests

@Suite("SimulatedDevice")
struct SimulatedDeviceTests {

    @Test func factoryCreates16ch() {
        let device = SimulatedDevice.symphonyIO16ch()
        #expect(device.identifier.mode == .channels16)
        #expect(device.isConnected == true)
    }

    @Test func factoryCreates32ch() {
        let device = SimulatedDevice.symphonyIO32ch()
        #expect(device.identifier.mode == .channels32)
        #expect(device.isConnected == true)
    }

    @Test func getDefaultSampleRate() async throws {
        let device = SimulatedDevice.symphonyIO16ch()
        let value = try await device.getProperty(
            PropertyAddress(selector: .sampleRate)
        )
        #expect(value == .float64(48000.0))
    }

    @Test func setAndGetProperty() async throws {
        let device = SimulatedDevice.symphonyIO16ch()
        let address = PropertyAddress(selector: .outputLevel)
        try await device.setProperty(address, value: .float64(-12.0))
        let value = try await device.getProperty(address)
        #expect(value == .float64(-12.0))
    }

    @Test func readOnlyPropertyThrows() async throws {
        let device = SimulatedDevice.symphonyIO16ch()
        let address = PropertyAddress(selector: .version)
        do {
            try await device.setProperty(address, value: .string("hacked"))
            #expect(Bool(false), "Should have thrown")
        } catch let error as DeviceConnectionError {
            #expect(error == .readOnly(.version))
        }
    }

    @Test func unsupportedPropertyThrows() async throws {
        let device = SimulatedDevice.symphonyIO16ch()
        let address = PropertyAddress(selector: AudioPropertySelector(rawValue: 0xDEAD))
        do {
            _ = try await device.getProperty(address)
            #expect(Bool(false), "Should have thrown")
        } catch let error as DeviceConnectionError {
            #expect(error == .unsupportedProperty(AudioPropertySelector(rawValue: 0xDEAD)))
        }
    }

    @Test func disconnectedDeviceThrows() async throws {
        let device = SimulatedDevice.symphonyIO16ch()
        await device.disconnect()
        #expect(device.isConnected == false)
        do {
            _ = try await device.getProperty(PropertyAddress(selector: .sampleRate))
            #expect(Bool(false), "Should have thrown")
        } catch let error as DeviceConnectionError {
            #expect(error == .notConnected)
        }
    }

    @Test func reconnect() async throws {
        let device = SimulatedDevice.symphonyIO16ch()
        await device.disconnect()
        #expect(device.isConnected == false)
        device.reconnect()
        #expect(device.isConnected == true)
        let value = try await device.getProperty(PropertyAddress(selector: .sampleRate))
        #expect(value == .float64(48000.0))
    }

    @Test func hasProperty() async {
        let device = SimulatedDevice.symphonyIO16ch()
        let has = await device.hasProperty(PropertyAddress(selector: .sampleRate))
        #expect(has == true)
        let hasNot = await device.hasProperty(
            PropertyAddress(selector: AudioPropertySelector(rawValue: 0xBEEF))
        )
        #expect(hasNot == false)
    }

    @Test func isPropertySettable() async {
        let device = SimulatedDevice.symphonyIO16ch()
        let settable = await device.isPropertySettable(PropertyAddress(selector: .outputLevel))
        #expect(settable == true)
        let readOnly = await device.isPropertySettable(PropertyAddress(selector: .version))
        #expect(readOnly == false)
    }

    @Test func perChannelInputGain() async throws {
        let device = SimulatedDevice.symphonyIO16ch()
        let addr = PropertyAddress(selector: .micGain, scope: .input, element: 3)
        try await device.setProperty(addr, value: .uint32(42))
        let value = try await device.getProperty(addr)
        #expect(value == .uint32(42))
    }

    @Test func propertyValueExtractors() {
        #expect(PropertyValue.uint32(42).asUInt32 == 42)
        #expect(PropertyValue.float64(3.14).asFloat64 == 3.14)
        #expect(PropertyValue.string("hello").asString == "hello")
        #expect(PropertyValue.bool(true).asBool == true)
        #expect(PropertyValue.uint32(42).asString == nil)
        #expect(PropertyValue.string("x").asFloat64 == nil)
    }
}

// MARK: - Property Listener Tests

@Suite("PropertyListener")
struct PropertyListenerTests {

    @Test func observerReceivesChange() async throws {
        let device = SimulatedDevice.symphonyIO16ch()
        let observer = PropertyObserver()
        let address = PropertyAddress(selector: .outputLevel)
        await device.addListener(observer, for: address)

        try await device.setProperty(address, value: .float64(-6.0))

        var received: PropertyChange?
        for await change in observer.stream {
            received = change
            break
        }
        #expect(received?.address == address)
        #expect(received?.value == .float64(-6.0))
    }

    @Test func observerDoesNotReceiveUnrelated() async throws {
        let device = SimulatedDevice.symphonyIO16ch()
        let observer = PropertyObserver()
        let listenAddress = PropertyAddress(selector: .outputLevel)
        let otherAddress = PropertyAddress(selector: .outputDim)
        await device.addListener(observer, for: listenAddress)

        // Set a different property — observer should not fire
        try await device.setProperty(otherAddress, value: .bool(true))

        // Finish stream to unblock
        observer.finish()

        var count = 0
        for await _ in observer.stream {
            count += 1
        }
        #expect(count == 0)
    }

    @Test func removeListenerStopsNotifications() async throws {
        let device = SimulatedDevice.symphonyIO16ch()
        let observer = PropertyObserver()
        let address = PropertyAddress(selector: .outputLevel)
        await device.addListener(observer, for: address)
        await device.removeListener(observer, for: address)

        try await device.setProperty(address, value: .float64(-6.0))

        observer.finish()
        var count = 0
        for await _ in observer.stream {
            count += 1
        }
        #expect(count == 0)
    }
}

// MARK: - Simulated Discovery Tests

@Suite("SimulatedDiscovery")
struct SimulatedDiscoveryTests {

    @Test func scanReturnsEmpty() async throws {
        let discovery = SimulatedDiscovery()
        let devices = try await discovery.scan()
        #expect(devices.isEmpty)
    }

    @Test func addAndScanDevice() async throws {
        let discovery = SimulatedDiscovery()
        let id = USBDeviceIdentifier(vendorID: 0x0C60, productID: 0x0010, deviceUID: "test")!
        let device = DiscoveredDevice(usbIdentifier: id, name: "Test Symphony")
        discovery.addDevice(device)

        let devices = try await discovery.scan()
        #expect(devices.count == 1)
        #expect(devices[0].name == "Test Symphony")
    }

    @Test func removeDevice() async throws {
        let discovery = SimulatedDiscovery()
        let id = USBDeviceIdentifier(vendorID: 0x0C60, productID: 0x0010, deviceUID: "test")!
        discovery.addDevice(DiscoveredDevice(usbIdentifier: id, name: "Test"))
        discovery.removeDevice(uid: "test")

        let devices = try await discovery.scan()
        #expect(devices.isEmpty)
    }

    @Test func discoveredDeviceIdentifiable() {
        let id = USBDeviceIdentifier(vendorID: 0x0C60, productID: 0x0011, deviceUID: "abc")!
        let device = DiscoveredDevice(usbIdentifier: id, name: "Symphony IO")
        #expect(device.id == "abc")
    }
}
