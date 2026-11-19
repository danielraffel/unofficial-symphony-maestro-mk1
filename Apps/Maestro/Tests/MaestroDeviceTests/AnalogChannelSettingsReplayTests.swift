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
        /// What reads answer; nil for an address throws (as ThunderBridge does).
        var reads: [PropertyAddress: UInt32]? = nil
        func getProperty(_ address: PropertyAddress) async throws -> PropertyValue {
            guard let reads else { return .uint32(0) }
            guard let value = reads[address] else { throw DeviceConnectionError.unsupportedProperty(address.selector) }
            return .uint32(value)
        }
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

    @Test func unknownLayoutGetsNoWrites() async {
        let device = RecordingDevice()
        _ = await AnalogChannelSettingsReplay.apply(
            inputs: [InputChannelState(softLimit: 1)], outputs: [OutputChannelState()],
            layout: CardLayout(isKnown: false, fallbackChannelCount: 32), device: device)
        #expect(device.writes.isEmpty)
    }

    @Test func symphonyWithPort2ConvertersStillReplays() async throws {
        let device = RecordingDevice()
        let converters = try #require(ConverterSystem(simulationName: "ad16x|ad16x"))
        let layout = CardLayout(slot1: .analogADDA16, slot2: .none, converters: converters)
        _ = await AnalogChannelSettingsReplay.apply(
            inputs: [InputChannelState(digitalRefLevel: 4)], outputs: [], layout: layout, device: device)
        #expect(!device.writes.isEmpty)
    }

    @Test func matchingReadsAreNotWritten() async {
        let device = RecordingDevice()
        let typeIn = PropertyAddress(selector: .analogIOType, scope: .input, element: 0)
        let refIn = PropertyAddress(selector: .digitalRefLevel, scope: .input, element: 0)
        let typeOut = PropertyAddress(selector: .analogIOType, scope: .output, element: 0)
        let refOut = PropertyAddress(selector: .digitalRefLevel, scope: .output, element: 0)
        device.reads = [typeIn: 1, refIn: 4, typeOut: 2, refOut: 3]
        let result = await AnalogChannelSettingsReplay.apply(
            inputs: [InputChannelState(softLimit: 2, inputType: 1, trim: 0, digitalRefLevel: 4)],
            outputs: [OutputChannelState(analogRefLevel: 2, digitalRefLevel: 1, trim: 0)],
            layout: CardLayout(slot1: .analogADDA16, slot2: .none), device: device)
        // Type and Digital Ref match on the input, the type on the output.
        // Soft Limit has no read used here and is always sent.
        #expect(device.writes.map(\.0) == [
            PropertyAddress(selector: .softLimit, scope: .input, element: 0), refOut])
        #expect(result.skipped == 3)
    }

    @Test func aTrimIsAlwaysSentAndFailedReadsStillWrite() async {
        let device = RecordingDevice()
        let typeIn = PropertyAddress(selector: .analogIOType, scope: .input, element: 0)
        device.reads = [typeIn: 1]   // the Digital Ref read throws
        _ = await AnalogChannelSettingsReplay.apply(
            inputs: [InputChannelState(softLimit: 0, inputType: 1, trim: 1.0, digitalRefLevel: 2)],
            outputs: [], layout: CardLayout(slot1: .analogADDA16, slot2: .none), device: device)
        #expect(device.writes.map(\.0.selector) == [.analogIOType, .digitalRefLevel, .softLimit])
    }

    @Test func micPreChannelsKeepTheirTypeAndSoftLimitIsCoerced() async {
        let device = RecordingDevice()
        let inputs = [InputChannelState(softLimit: 1, inputType: AnalogInputLevel.mic.rawValue),
                      InputChannelState(softLimit: 1, inputType: 1)]
        _ = await AnalogChannelSettingsReplay.apply(
            inputs: inputs, outputs: [], layout: CardLayout(slot1: .analogADDA16, slot2: .micPre8), device: device)
        let channel0 = device.writes.filter { $0.0.element == 0 }
        #expect(!channel0.contains { $0.0.selector == .analogIOType })
        // The 16x16 knows Off and On (2) only: a saved -2 dBFS (1) goes as On.
        let softLimits = device.writes.filter { $0.0.selector == .softLimit }.map(\.1)
        #expect(softLimits == [.uint32(2), .uint32(2)])
    }

    @Test func usbReplaySwitchCoversChannels() {
        #expect(!AnalogChannelSettingsReplay.runs(overUSB: true, usbReplayEnabled: false))
        #expect(AnalogChannelSettingsReplay.runs(overUSB: true, usbReplayEnabled: true))
        #expect(AnalogChannelSettingsReplay.runs(overUSB: false, usbReplayEnabled: false))
    }
}
