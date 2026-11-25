import Foundation
import Testing
@testable import MaestroDevice
import MaestroCore

@Suite("VBus: the driver client")
struct VBusDeviceTests {
    @Test("the real driver client does not send selector 16 to an older or unread driver")
    func clientGate() {
        let client = DextUserClient()   // not connected: no driver build read
        #expect(client.vbus(.eight) == nil && client.vbus(nil) == nil)
        #expect(DextUserClient.vbusInput(.eight) == [0x53594D50, 1, 8])
        #expect(DextUserClient.vbusInput(VBusChannels.none) == [0x53594D50, 1, 0])
        #expect(DextUserClient.vbusInput(nil) == [0x53594D50, 0, 0])
    }

    @Test("the connection asks its driver client, and an older driver answers nothing")
    func connection() async {
        let driver = FakeThunderboltDriver()
        let tb = ThunderboltDeviceConnection(identifier: SimulatedDevice.symphonyIO32ch().identifier,
                                             audioDeviceID: 0, driver: driver)
        #expect(await tb.vbus(nil) == VBusState(published: 0, requested: 0, firstChannel: 0, flags: 0))
        #expect(await tb.vbus(.eight) == VBusState(published: 8, requested: 8, firstChannel: 33, flags: 0))
        driver.vbusHardwareChannels = 64
        #expect(await tb.vbus(nil)?.firstChannel == 65)
        driver.driverBuild = 142
        #expect(await tb.vbus(.sixteen) == nil)
        #expect(driver.vbusSetCalls == [.eight])
    }
}
