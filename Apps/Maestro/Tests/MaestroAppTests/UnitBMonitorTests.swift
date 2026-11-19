import Testing
@testable import MaestroApp
import MaestroCore
import MaestroDevice

@Suite("Unit B monitor recall")
@MainActor
struct UnitBMonitorTests {
    final class Device: DeviceConnection, @unchecked Sendable {
        let identifier = USBDeviceIdentifier(vendorID: ApogeeUSB.vendorID, productID: 0x12, deviceUID: "monitor")!
        var isConnected = true
        var values: [AudioPropertySelector: PropertyValue] = [:]
        var writes = 0
        func getProperty(_ address: PropertyAddress) async throws -> PropertyValue {
            guard let value = values[address.selector] else { throw DeviceConnectionError.notConnected }
            return value
        }
        func setProperty(_ address: PropertyAddress, value: PropertyValue) async throws { writes += 1 }
        func hasProperty(_ address: PropertyAddress) async -> Bool { true }
        func isPropertySettable(_ address: PropertyAddress) async -> Bool { true }
        func addListener(_ listener: PropertyListener, for address: PropertyAddress) async {}
        func removeListener(_ listener: PropertyListener, for address: PropertyAddress) async {}
        func disconnect() async { isConnected = false }
    }

    @Test func failedFieldsStayUnknownOrUnchanged() async {
        let state = UnitBMonitorState()
        let b = Device()
        b.values = [.headphone1Level: .uint32(53), .outputMute: .bool(true), .activeSpeakerSet: .uint32(0)]
        await state.refresh(from: b)
        #expect(state.values[.headphone1Level] == .uint32(53))
        #expect(state.values[.outputMute] == .bool(true))
        #expect(state.values[.outputLevel] == nil)
        #expect(state.values[.activeSpeakerSet] == nil)
        b.values = [:]
        await state.refresh(from: b)
        #expect(state.values[.headphone1Level] == .uint32(53))
        #expect(state.values[.outputMute] == .bool(true))
        #expect(state.values[.outputLevel] == nil)
        #expect(b.writes == 0)
    }

    @Test func connectionsHaveIndependentState() async {
        let a = UnitBMonitorState()
        let b = UnitBMonitorState()
        let deviceA = Device()
        let deviceB = Device()
        deviceA.values = [.outputLevel: .uint32(5)]
        deviceB.values = [.outputLevel: .uint32(60)]
        await a.refresh(from: deviceA)
        await b.refresh(from: deviceB)
        b.values[.outputLevel] = .uint32(55)
        #expect(a.values[.outputLevel] == .uint32(5))
        #expect(deviceA.writes == 0)
        let replacement = UnitBMonitorState()
        #expect(replacement.values.isEmpty)
        deviceB.isConnected = false
        deviceB.values = [.outputLevel: .uint32(0)]
        await b.refresh(from: deviceB)
        #expect(b.values[.outputLevel] == .uint32(55))
    }
}
