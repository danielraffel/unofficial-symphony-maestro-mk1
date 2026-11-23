import Foundation
import Testing
@testable import MaestroDevice
import MaestroCore

@Suite("Volume Keys: Audio Output, driver and settings store")
struct KeyboardVolumeOutputDeviceTests {
    private static let address = PropertyAddress(selector: .keyboardVolumeOutputID)

    @Test("selector 15's input is magic, unit, output")
    func driverInput() {
        let magic: UInt32 = 0x53594D50
        #expect(DextUserClient.monitorOutputInput(.speakers, unit: .a) == [magic, 0, 1])
        #expect(DextUserClient.monitorOutputInput(.headphone1, unit: .a) == [magic, 0, 2])
        #expect(DextUserClient.monitorOutputInput(.headphone2, unit: .a) == [magic, 0, 3])
        #expect(DextUserClient.monitorOutputInput(.speakers, unit: .b) == [magic, 1, 1])
        #expect(DextUserClient.monitorOutputInput(.headphone1, unit: .b) == [magic, 1, 2])
        #expect(DextUserClient.monitorOutputInput(.headphone2, unit: .b) == [magic, 1, 3])
        #expect(DextUserClient.monitorOutputInput(.mixer1Level, unit: .a) == [magic, 0, 1])
        #expect(DextUserClient.monitorOutputInput(.none, unit: .a) == [magic, 0, 0])
    }

    @Test("the connection passes the choice and the unit to the driver, and reports a refusal")
    func connectionReachesTheDriver() async {
        let driver = FakeThunderboltDriver()
        let tb = ThunderboltDeviceConnection(identifier: SimulatedDevice.symphonyIO32ch().identifier,
                                             audioDeviceID: 0, driver: driver)
        #expect(await tb.setMonitorOutput(.headphone2, unit: .a))
        #expect(await tb.setMonitorOutput(.headphone1, unit: .b))
        #expect(driver.monitorOutputCalls == [
            .init(unit: .a, output: .headphone2), .init(unit: .b, output: .headphone1),
        ])
        driver.acceptsMonitorOutput = false
        #expect(!(await tb.setMonitorOutput(.speakers, unit: .a)))
        #expect(driver.monitorOutputCalls.count == 2)
    }

    @Test("the choice is saved per unit, by the unit's identity, and survives a new store")
    func savedPerUnit() throws {
        let suite = "KeyboardVolumeOutputDeviceTests.\(UUID().uuidString)"
        let defaults = try #require(ScratchUserDefaults(suiteName: suite))
        defer { defaults.cleanup() }
        let first = DeviceSettingsStore(defaults: defaults, productID: 2200, unit: .a, identity: 0x1111)
        let second = DeviceSettingsStore(defaults: defaults, productID: 2200, unit: .b, identity: 0x2222)
        #expect(first.value(for: Self.address) == nil)
        first.record(.uint32(KeyboardVolumeOutput.headphone2.rawValue), for: Self.address)
        second.record(.uint32(KeyboardVolumeOutput.headphone1.rawValue), for: Self.address)
        // Read again from the preferences, as after a relaunch, and with the
        // units on the other ports: each unit's choice follows the unit.
        let firstAsB = DeviceSettingsStore(defaults: defaults, productID: 2200, unit: .b, identity: 0x1111)
        let secondAsA = DeviceSettingsStore(defaults: defaults, productID: 2200, unit: .a, identity: 0x2222)
        #expect(firstAsB.value(for: Self.address)?.asUInt32 == KeyboardVolumeOutput.headphone2.rawValue)
        #expect(secondAsA.value(for: Self.address)?.asUInt32 == KeyboardVolumeOutput.headphone1.rawValue)
        // A unit never seen has nothing saved.
        let third = DeviceSettingsStore(defaults: defaults, productID: 2200, unit: .a, identity: 0x3333,
                                        allowLegacyMigration: false)
        #expect(third.value(for: Self.address) == nil)
        // It is not one of the settings replayed to the unit as a property.
        #expect(!DeviceSettingsStore.ownedSettings.contains(.keyboardVolumeOutputID))
        #expect(first.entries().allSatisfy { $0.address.selector != .keyboardVolumeOutputID })
    }
}
