import Testing
import Foundation
@testable import MaestroDevice
@testable import MaestroCore

@Suite("Analog channel settings replay")
struct AnalogChannelSettingsReplayTests {
    final class RecordingDevice: DeviceConnection, @unchecked Sendable {
        let identifier = USBDeviceIdentifier(vendorID: ApogeeUSB.vendorID, productID: 0x12, deviceUID: "replay")!
        let isConnected = true
        var writes: [(PropertyAddress, PropertyValue)] = []
        func getProperty(_ address: PropertyAddress) async throws -> PropertyValue { .uint32(0) }
        func setProperty(_ address: PropertyAddress, value: PropertyValue) async throws { writes.append((address, value)) }
        func hasProperty(_ address: PropertyAddress) async -> Bool { true }
        func isPropertySettable(_ address: PropertyAddress) async -> Bool { true }
        func addListener(_ listener: PropertyListener, for address: PropertyAddress) async {}
        func removeListener(_ listener: PropertyListener, for address: PropertyAddress) async {}
        func disconnect() async {}
    }

    @Test func replaysInputsThenOutputs() async {
        let device = RecordingDevice()
        let layout = CardLayout(slot1: .analogADDA16, slot2: .none)
        let inputs = [InputChannelState(softLimit: 2, inputType: 1, trim: 1.2, digitalRefLevel: 4)]
        let outputs = [OutputChannelState(analogRefLevel: 2, digitalRefLevel: 1, trim: -0.5)]
        _ = await AnalogChannelSettingsReplay.apply(inputs: inputs, outputs: outputs, layout: layout, device: device)
        #expect(device.writes.count == 5)
        #expect(device.writes[0].0 == PropertyAddress(selector: .analogIOType, scope: .input, element: 0))
        #expect(device.writes[1].0.selector == .digitalRefLevel)
        #expect(device.writes[2].0.selector == .softLimit)
        #expect(device.writes[3].0 == PropertyAddress(selector: .analogIOType, scope: .output, element: 0))
        #expect(device.writes[4].0.selector == .digitalRefLevel)
        #expect(device.writes[0].1 == .uint32(0x0c01))
        #expect(device.writes[3].1 == .uint32(0xfb02))
    }

    @Test func converterLayoutGetsNoWrites() async throws {
        let device = RecordingDevice()
        let converters = try #require(ConverterSystem(simulationName: "ad16x"))
        let layout = CardLayout(isKnown: false, converters: converters)
        _ = await AnalogChannelSettingsReplay.apply(
            inputs: [InputChannelState()], outputs: [OutputChannelState()], layout: layout, device: device)
        #expect(device.writes.isEmpty)
    }
}
