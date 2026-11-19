import Testing
import Foundation
@testable import MaestroDevice
@testable import MaestroCore

private final class IdentityVendorMock: VendorTransport, @unchecked Sendable {
    private let lock = NSLock()
    var replies: [Data] = []
    var ports: [UInt8] = []
    var commands: [UInt8] = []
    var isConnected = true

    func sendVendorCommand(command: UInt8, value: UInt32, payload: Data, port: UInt8) throws {}
    func readVendorCommand(command: UInt8, value: UInt32, responseLength: Int, port: UInt8) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        commands.append(command); ports.append(port)
        return replies.isEmpty ? Data() : replies.removeFirst()
    }
}

@Suite("Unit identity")
struct UnitIdentityTests {
    private let uid = Data([1, 2, 3, 4, 5, 6, 7, 8])

    @Test func thunderboltUnitAUsesC0AndPortZero() async {
        let mock = IdentityVendorMock(); mock.replies = [uid]
        let id = await SymphonyIdentityReader.readThunderbolt(transport: mock, port: 0, attempts: 1, delay: .zero)
        #expect(id == 0x0102030405060708)
        #expect(mock.commands == [0xC0]); #expect(mock.ports == [0])
    }

    @Test func thunderboltUnitBUsesC0AndPortOne() async {
        let mock = IdentityVendorMock(); mock.replies = [uid]
        let id = await SymphonyIdentityReader.readThunderbolt(transport: mock, port: 1, attempts: 1, delay: .zero)
        #expect(id == 0x0102030405060708)
        #expect(mock.commands == [0xC0]); #expect(mock.ports == [1])
    }

    @Test func usbReadUsesC0AndEightBytes() async {
        let transport = MockUSBTransport()
        transport.setResponse(for: .uniqueID, data: uid)
        let id = await SymphonyIdentityReader.readUSB(transport: transport, attempts: 1, delay: .zero)
        #expect(id == 0x0102030405060708)
        #expect(transport.sentRequests.first?.request == 0xC0)
        #expect(transport.sentRequests.first?.data.count == 8)
    }

    @Test func xpcReadUsesC0AndRejectsErrorStatus() async {
        let transport = MockXPCTransport()
        transport.nextReply = XPCPropertyReply(status: 0, data: uid)
        let connection = XPCDeviceConnection(identifier: USBDeviceIdentifier(vendorID: ApogeeUSB.vendorID, productID: ApogeeUSB.SymphonyIO.pid16ch, deviceUID: "identity-test")!, transport: transport)
        #expect(await connection.readHardwareUniqueID() == 0x0102030405060708)
        #expect(transport.getPropertyCalls.first?.bRequest == 0xC0)
        transport.nextReply = XPCPropertyReply(status: 1, data: uid)
        #expect(await connection.readHardwareUniqueID() == nil)
    }

    @Test func zeroReplyRetriesTenTimesThenSucceeds() async {
        let mock = IdentityVendorMock(); mock.replies = Array(repeating: Data(repeating: 0, count: 8), count: 9) + [uid]
        let id = await SymphonyIdentityReader.readThunderbolt(transport: mock, port: 0, attempts: 10, delay: .zero)
        #expect(id == 0x0102030405060708); #expect(mock.ports.count == 10)
    }

    @Test func shortAndErrorRepliesAreUnknown() async {
        #expect(SymphonyIdentityReader.decode(Data()) == nil)
        #expect(SymphonyIdentityReader.decode(Data(repeating: 0, count: 7)) == nil)
        #expect(SymphonyIdentityReader.decode(Data(repeating: 0, count: 8)) == nil)
        let mock = IdentityVendorMock(); mock.replies = [Data([1])]
        #expect(await SymphonyIdentityReader.readThunderbolt(transport: mock, port: 0, attempts: 1, delay: .zero) == nil)
    }

    @Test func converterCapabilityRefusesIdentity() {
        let converter = ConnectedUnit(probeWord: 0x8000_0000)!
        let layout = CardLayout(isKnown: false, converter: converter)
        #expect(!SymphonyIdentityReader.isSupported(layout: layout, unit: .a))
        #expect(!SymphonyIdentityReader.isSupported(layout: layout, unit: .b))
        #expect(SymphonyIdentityReader.isSupported(layout: CardLayout(slot1: .analogAD16), unit: .a))
    }

    @Test func identityScopesMigrateLayoutOnce() {
        let suite = "maestro.tests.identity.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        let layout = CardLayout(slot1: .optical, slot2: .analogAD16)
        let legacy = "inputChannelStates.\(layout.savedStateScope!)"
        defaults.set(Data("legacy".utf8), forKey: legacy)
        let first = ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: false, identity: 0xA)
        #expect(first.loadData(ChannelStateStore.inputKey) == Data("legacy".utf8))
        #expect(defaults.string(forKey: "\(legacy).migratedTo") == first.scope)
        let replaced = ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: false, identity: 0xB)
        #expect(replaced.loadData(ChannelStateStore.inputKey) == nil)
    }

    @Test func identityScopeKeepsTheCardLayout() {
        let suite = "maestro.tests.identity.layout.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        let a = CardLayout(slot1: .optical, slot2: .analogAD16)
        let b = CardLayout(slot1: .analogADDA16, slot2: .none)
        let storeA = ChannelStateStore(defaults: defaults, layout: a, isSimulatingCards: false, identity: 0xA)
        storeA.saveData(Data("cardsA".utf8), for: ChannelStateStore.inputKey)
        // Same unit, different cards: never the other layout's strips.
        let storeB = ChannelStateStore(defaults: defaults, layout: b, isSimulatingCards: false, identity: 0xA)
        #expect(storeB.loadData(ChannelStateStore.inputKey) == nil)
        #expect(storeA.scope != storeB.scope)
        // Back to the first cards: their state is still there.
        let again = ChannelStateStore(defaults: defaults, layout: a, isSimulatingCards: false, identity: 0xA)
        #expect(again.loadData(ChannelStateStore.inputKey) == Data("cardsA".utf8))
    }

    @Test func settingsIdentityMigrationDoesNotFollowReplacement() {
        let suite = "maestro.tests.identity.settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        let address = PropertyAddress(selector: .prefix)
        DeviceSettingsStore(defaults: defaults, productID: 0x12).record(.string("A"), for: address)
        let first = DeviceSettingsStore(defaults: defaults, productID: 0x12, identity: 1)
        #expect(first.value(for: address) == .string("A"))
        let replaced = DeviceSettingsStore(defaults: defaults, productID: 0x12, identity: 2)
        #expect(replaced.value(for: address) == nil)
    }

    @Test func markerWithoutIdentityContinuesUsingMigratedChannelScope() {
        let suite = "maestro.tests.identity.marker.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        let layout = CardLayout(slot1: .optical, slot2: .analogAD16)
        let legacy = "inputChannelStates.\(layout.savedStateScope!)"
        let migratedScope = "unitA:v2:a:\(layout.savedStateScope!)"
        defaults.set(migratedScope, forKey: "\(legacy).migratedTo")
        defaults.set(Data("new".utf8), forKey: "inputChannelStates.\(migratedScope)")
        defaults.set(Data("frozen".utf8), forKey: legacy)
        let store = ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: false)
        #expect(store.loadData(ChannelStateStore.inputKey) == Data("new".utf8))
        store.saveData(Data("written".utf8), for: ChannelStateStore.inputKey)
        #expect(defaults.data(forKey: "inputChannelStates.\(migratedScope)") == Data("written".utf8))
        #expect(defaults.data(forKey: legacy) == Data("frozen".utf8))
    }

    @Test func settingsMarkerWithoutIdentityUsesMigratedScope() {
        let suite = "maestro.tests.identity.settings-marker.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = DeviceSettingsStore.defaultsKey(productID: 0x12)
        let migrated = DeviceSettingsStore.defaultsKey(productID: 0x12, unit: .a, identity: 0xA)
        let address = PropertyAddress(selector: .prefix)
        defaults.set(String(0xA, radix: 16), forKey: "\(legacy).migratedTo")
        let migratedStore = DeviceSettingsStore(defaults: defaults, productID: 0x12, identity: 0xA)
        migratedStore.record(.string("new"), for: address)
        let store = DeviceSettingsStore(defaults: defaults, productID: 0x12)
        #expect(store.value(for: address) == .string("new"))
        #expect(defaults.data(forKey: migrated) != nil)
    }
}
