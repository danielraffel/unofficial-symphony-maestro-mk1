import Testing
@testable import MaestroApp
import MaestroCore
import MaestroDevice

@Suite("Identify lifecycle")
@MainActor
struct IdentifyStateTests {
    final class RecordingDevice: DeviceConnection, @unchecked Sendable {
        let identifier = USBDeviceIdentifier(vendorID: ApogeeUSB.vendorID, productID: 0x12, deviceUID: "identify")!
        var isConnected = true
        var fail = false
        var writes: [Bool] = []
        var started: (() -> Void)?
        var hold: CheckedContinuation<Void, Never>?
        var suspendWrite = false

        func setProperty(_ address: PropertyAddress, value: PropertyValue) async throws {
            #expect(address == PropertyAddress(selector: .identify))
            #expect(value.asBool != nil)
            writes.append(value.asBool ?? false)
            if suspendWrite {
                await withCheckedContinuation { continuation in
                    hold = continuation
                    started?()
                }
            }
            if fail { throw DeviceConnectionError.notConnected }
        }
        func getProperty(_ address: PropertyAddress) async throws -> PropertyValue { .bool(false) }
        func hasProperty(_ address: PropertyAddress) async -> Bool { true }
        func isPropertySettable(_ address: PropertyAddress) async -> Bool { true }
        func addListener(_ listener: PropertyListener, for address: PropertyAddress) async {}
        func removeListener(_ listener: PropertyListener, for address: PropertyAddress) async {}
        func disconnect() async { isConnected = false }
    }

    @Test func onOffAndRapidClicks() async {
        let state = IdentifyState()
        let device = RecordingDevice()
        let on = state.toggle(device: device)
        #expect(!state.isOn)
        await on.value
        #expect(state.isOn)
        await state.toggle(device: device).value
        #expect(!state.isOn)
        state.toggle(device: device)
        await state.toggle(device: device).value
        #expect(!state.isOn)
        #expect(device.writes == [true, false, true, false])
        await state.reset().value
        #expect(device.writes.count == 4) // Already OFF: no extra write.
    }

    @Test func failureKeepsPreviousState() async {
        let state = IdentifyState()
        let device = RecordingDevice()
        device.fail = true
        await state.toggle(device: device).value
        #expect(!state.isOn)
        device.fail = false
        await state.toggle(device: device).value
        device.fail = true
        await state.toggle(device: device).value
        #expect(state.isOn)
        await state.reset().value
        #expect(!state.isOn) // Teardown resets even when OFF fails.
    }

    @Test func disconnectResetsAndReconnectStartsOff() async {
        let state = IdentifyState()
        let old = RecordingDevice()
        await state.toggle(device: old).value
        old.isConnected = false
        await state.reset().value
        #expect(!state.isOn)
        #expect(old.writes == [true])
        let replacement = RecordingDevice()
        await state.toggle(device: replacement).value
        #expect(replacement.writes == [true])
        await state.reset().value
        #expect(replacement.writes == [true, false])
        #expect(old.writes == [true])
    }

    @Test func unitBLossLeavesAOn() async {
        let a = IdentifyState()
        let b = IdentifyState()
        let deviceA = RecordingDevice()
        let deviceB = RecordingDevice()
        await a.toggle(device: deviceA).value
        await b.toggle(device: deviceB).value
        await b.reset().value
        #expect(a.isOn)
        #expect(!b.isOn)
        #expect(deviceA.writes == [true])
        #expect(deviceB.writes == [true, false])
        await a.reset().value // The same cleanup used at quit.
        #expect(deviceA.writes == [true, false])
    }

    @Test func teardownDuringOnSendsOffAfterWriteAndDropsQueuedClick() async {
        let state = IdentifyState()
        let device = RecordingDevice()
        device.suspendWrite = true
        await withCheckedContinuation { started in
            device.started = { started.resume() }
            state.toggle(device: device)
        }
        #expect(!state.isOn)
        state.toggle(device: device)
        let cleanup = state.reset()
        device.suspendWrite = false
        device.hold?.resume()
        await cleanup.value
        #expect(!state.isOn)
        #expect(device.writes == [true, false])
    }
}
