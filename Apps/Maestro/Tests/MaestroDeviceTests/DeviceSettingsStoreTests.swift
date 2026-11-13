import Testing
import Foundation
@testable import MaestroDevice
@testable import MaestroCore

/// The Mac-side settings store, and the two connections that record into it and
/// replay it. The reported bug was a setting that reverted on screen after
/// leaving a tab; the complete form of it is a setting that reverts after a
/// relaunch or a power cycle, which is what persistence and replay are for.
@Suite("DeviceSettingsStore")
struct DeviceSettingsStoreTests {

    /// A private defaults domain per test, removed afterwards, so nothing is
    /// read from or left in the real preferences.
    private static func withDefaults<T>(_ body: (UserDefaults) async throws -> T) async rethrows -> T {
        let suite = "maestro.tests.settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        return try await body(defaults)
    }

    private static let peak = PropertyAddress(selector: .peakHoldMode)
    private static let bank2 = PropertyAddress(selector: .metersShowInput, element: 2)

    private static let thunderbolt = USBDeviceIdentifier(
        vendorID: ApogeeUSB.vendorID, productID: 0x0012, deviceUID: "test-tb")!

    // MARK: - Store

    @Test("values survive a new store on the same defaults")
    func persistsAcrossInstances() async {
        await Self.withDefaults { defaults in
            let first = DeviceSettingsStore(defaults: defaults, productID: 0x12)
            first.record(.uint32(2), for: Self.peak)
            first.record(.uint32(5), for: Self.bank2)
            first.record(.string("C"), for: PropertyAddress(selector: .prefix))
            first.record(.bool(true), for: PropertyAddress(selector: .outputDim))

            let second = DeviceSettingsStore(defaults: defaults, productID: 0x12)
            #expect(second.value(for: Self.peak) == .uint32(2))
            #expect(second.value(for: Self.bank2) == .uint32(5))
            #expect(second.value(for: PropertyAddress(selector: .prefix)) == .string("C"))
            #expect(second.value(for: PropertyAddress(selector: .outputDim)) == .bool(true))
            // Element is part of the identity: bank 1 was never written.
            #expect(second.value(for: PropertyAddress(selector: .metersShowInput, element: 1)) == nil)
        }
    }

    @Test("each product keeps its own settings")
    func isolatedPerProduct() async {
        await Self.withDefaults { defaults in
            DeviceSettingsStore(defaults: defaults, productID: 0x12).record(.uint32(2), for: Self.peak)
            #expect(DeviceSettingsStore(defaults: defaults, productID: 0x10).value(for: Self.peak) == nil)
        }
    }

    @Test("an in-memory store saves nothing")
    func inMemoryStoreIsNotPersisted() {
        let store = DeviceSettingsStore()
        store.record(.uint32(1), for: Self.peak)
        #expect(store.value(for: Self.peak) == .uint32(1))
        #expect(DeviceSettingsStore().value(for: Self.peak) == nil)
    }

    @Test("damaged data reads as no settings")
    func damagedDataIsEmpty() async {
        await Self.withDefaults { defaults in
            defaults.set(Data("not json".utf8), forKey: DeviceSettingsStore.defaultsKey(productID: 0x12))
            let store = DeviceSettingsStore(defaults: defaults, productID: 0x12)
            #expect(store.entries().isEmpty)
            // And it is usable afterwards.
            store.record(.uint32(1), for: Self.peak)
            #expect(DeviceSettingsStore(defaults: defaults, productID: 0x12).value(for: Self.peak) == .uint32(1))
        }
    }

    @Test("values that cannot be saved are not stored")
    func unsupportedValuesIgnored() {
        let store = DeviceSettingsStore()
        store.record(.range(min: -64, max: 0), for: Self.peak)
        store.record(.data(Data([1])), for: Self.peak)
        #expect(store.value(for: Self.peak) == nil)
    }

    /// The original wrote the monitor mode before the dim, mono and speaker set
    /// that only mean something within it. FourCC order would put them first.
    @Test("replay order follows the original: monitor mode before its dependents")
    func entriesFollowOwnedOrder() {
        let store = DeviceSettingsStore()
        store.record(.uint32(1), for: Self.peak)
        store.record(.uint32(2), for: PropertyAddress(selector: .activeSpeakerSet))
        store.record(.bool(true), for: PropertyAddress(selector: .outputDim))
        store.record(.uint32(1), for: Self.bank2)
        store.record(.uint32(1), for: PropertyAddress(selector: .metersShowInput, element: 1))
        store.record(.uint32(3), for: PropertyAddress(selector: .speakerOutputMode))
        let order = store.entries().map(\.address)
        #expect(order == [
            PropertyAddress(selector: .speakerOutputMode),
            PropertyAddress(selector: .outputDim),
            PropertyAddress(selector: .activeSpeakerSet),
            PropertyAddress(selector: .metersShowInput, element: 1),
            Self.bank2,
            Self.peak,
        ])
    }

    @Test("settings the store does not own are never replayed")
    func foreignEntriesAreNotReplayed() {
        let store = DeviceSettingsStore()
        for selector: AudioPropertySelector in [.micGain, .clockSource, .outputLevel,
                                                .headphone1RoutingID, .headphone2RoutingID] {
            store.record(.uint32(1), for: PropertyAddress(selector: selector))
        }
        #expect(store.entries().isEmpty)
    }

    // MARK: - Thunderbolt

    /// Relaunch: a new connection on the same store reads back what the last
    /// one wrote. `.prefix` has no hardware opcode, so the write needs no driver.
    @Test("Thunderbolt: a setting written in one session reads back in the next")
    func thunderboltSurvivesRelaunch() async throws {
        try await Self.withDefaults { defaults in
            let prefix = PropertyAddress(selector: .prefix)
            let first = ThunderboltDeviceConnection(
                identifier: Self.thunderbolt, audioDeviceID: 0,
                settingsStore: DeviceSettingsStore(defaults: defaults, productID: 0x12))
            try await first.setProperty(prefix, value: .string("D"))

            let second = ThunderboltDeviceConnection(
                identifier: Self.thunderbolt, audioDeviceID: 0,
                settingsStore: DeviceSettingsStore(defaults: defaults, productID: 0x12))
            #expect(try await second.getProperty(prefix) == .string("D"))
        }
    }

    /// The store never answers for state that has its own owner, even if such a
    /// value somehow got into it.
    @Test("Thunderbolt: only owned settings are answered from the store")
    func thunderboltIgnoresForeignEntries() async {
        let store = DeviceSettingsStore()
        store.record(.uint32(30), for: PropertyAddress(selector: .micGain))
        let conn = ThunderboltDeviceConnection(
            identifier: Self.thunderbolt, audioDeviceID: 0, settingsStore: store)
        await #expect(throws: DeviceConnectionError.unsupportedProperty(.micGain)) {
            _ = try await conn.getProperty(PropertyAddress(selector: .micGain))
        }
        let replay = await conn.reapplyStoredSettings()
        #expect(replay == DeviceSettingsReplay())
    }

    /// With no driver attached a hardware-backed setting cannot be written. The
    /// replay must say so, keep the stored value, and still apply the rest.
    @Test("Thunderbolt: replay reports what the hardware refused")
    func thunderboltReplayReportsFailures() async throws {
        let store = DeviceSettingsStore()
        store.record(.uint32(2), for: Self.peak)
        store.record(.string("B"), for: PropertyAddress(selector: .prefix))
        let conn = ThunderboltDeviceConnection(
            identifier: Self.thunderbolt, audioDeviceID: 0, settingsStore: store)

        let replay = await conn.reapplyStoredSettings()
        #expect(replay.applied == 1)
        #expect(replay.failed == [.peakHoldMode])
        #expect(store.value(for: Self.peak) == .uint32(2))
        #expect(try await conn.getProperty(Self.peak) == .uint32(2))
    }

    // MARK: - USB

    private static let usb = USBDeviceIdentifier(
        vendorID: ApogeeUSB.vendorID, productID: 0x0010, deviceUID: "test-usb")!

    @Test("USB: saved Peak Hold and Over Hold are shown after a relaunch")
    func usbStartsFromSavedSettings() async throws {
        let store = DeviceSettingsStore()
        store.record(.uint32(2), for: Self.peak)
        store.record(.uint32(3), for: PropertyAddress(selector: .oversHoldMode))
        store.record(.string("K"), for: PropertyAddress(selector: .prefix))
        let conn = XPCDeviceConnection(
            identifier: Self.usb, transport: MockXPCTransport(), settingsStore: store)

        #expect(try await conn.getProperty(Self.peak) == .uint32(2))
        #expect(try await conn.getProperty(PropertyAddress(selector: .oversHoldMode)) == .uint32(3))
        #expect(try await conn.getProperty(PropertyAddress(selector: .prefix)) == .string("K"))
    }

    @Test("USB: a successful write is saved, a failed one is not")
    func usbRecordsOnlySuccessfulWrites() async throws {
        let store = DeviceSettingsStore()
        let transport = MockXPCTransport()
        let conn = XPCDeviceConnection(identifier: Self.usb, transport: transport, settingsStore: store)

        try await conn.setProperty(Self.peak, value: .uint32(1))
        #expect(store.value(for: Self.peak) == .uint32(1))

        transport.nextSetError = DeviceConnectionError.transportError("USB write failed")
        await #expect(throws: DeviceConnectionError.self) {
            try await conn.setProperty(Self.peak, value: .uint32(2))
        }
        #expect(store.value(for: Self.peak) == .uint32(1))
    }

    /// Power cycle: the unit is back at its defaults, the app shows the saved
    /// values, so connect has to write them. Clock source is not replayed.
    @Test("USB: replay writes the saved settings to the hardware")
    func usbReplayWritesToHardware() async {
        let store = DeviceSettingsStore()
        store.record(.uint32(2), for: Self.peak)
        store.record(.uint32(1), for: PropertyAddress(selector: .oversHoldMode))
        store.record(.uint32(2), for: PropertyAddress(selector: .clockSource))
        let transport = MockXPCTransport()
        let conn = XPCDeviceConnection(identifier: Self.usb, transport: transport, settingsStore: store)

        let replay = await conn.reapplyStoredSettings(force: true)
        #expect(replay == DeviceSettingsReplay(applied: 2))
        let requests = Set(transport.setPropertyCalls.map(\.bRequest))
        #expect(requests == [SymphonyIOCommand.peakHold.rawValue, SymphonyIOCommand.overHold.rawValue])
        #expect(transport.setPropertyCalls.first { $0.bRequest == SymphonyIOCommand.peakHold.rawValue }?.data == Data([2]))
    }

    /// The original pushed the monitor settings on connect in USB mode too.
    /// Both transports must own the same list, so a unit behaves the same
    /// whichever cable it is on.
    @Test("USB and Thunderbolt save and replay the same settings")
    func bothTransportsOwnTheSameSettings() {
        #expect(XPCDeviceConnection.storedSelectors == ThunderboltDeviceConnection.storedSelectors)
        // Never replayed: the front panel can change these behind the app.
        for selector: AudioPropertySelector in [.outputLevel, .outputMute, .headphone1Level,
                                                .headphone2Level, .headphone1Mute,
                                                .headphone2Mute, .clockSource] {
            #expect(!XPCDeviceConnection.storedSelectors.contains(selector))
            #expect(!ThunderboltDeviceConnection.storedSelectors.contains(selector))
        }
    }

    @Test("USB: a monitor setting is saved on write and replayed on connect")
    func usbReplaysMonitorSettings() async throws {
        let store = DeviceSettingsStore()
        let first = XPCDeviceConnection(identifier: Self.usb, transport: MockXPCTransport(), settingsStore: store)
        try await first.setProperty(PropertyAddress(selector: .outputDim), value: .bool(true))
        #expect(store.value(for: PropertyAddress(selector: .outputDim)) == .bool(true))

        let transport = MockXPCTransport()
        let second = XPCDeviceConnection(identifier: Self.usb, transport: transport, settingsStore: store)
        let replay = await second.reapplyStoredSettings(force: true)
        #expect(replay == DeviceSettingsReplay(applied: 1))
        #expect(transport.setPropertyCalls.count == 1)
    }

    /// Meter sources are part of what the original pushed on connect, and are
    /// replayed with everything else, in the store's order.
    @Test("USB: front panel meter sources are replayed with the other settings")
    func usbReplaysMeterSources() async throws {
        let store = DeviceSettingsStore()
        store.record(.uint32(4), for: PropertyAddress(selector: .metersShowInput, element: 1))
        store.record(.uint32(5), for: Self.bank2)
        store.record(.uint32(2), for: Self.peak)
        let transport = MockXPCTransport()
        let conn = XPCDeviceConnection(identifier: Self.usb, transport: transport, settingsStore: store)

        #expect(await conn.reapplyStoredSettings() == DeviceSettingsReplay(applied: 3))
        #expect(transport.setPropertyCalls.map(\.bRequest) == [
            SymphonyIOCommand.frontPanelMeterShow.rawValue,
            SymphonyIOCommand.frontPanelMeterShow.rawValue,
            SymphonyIOCommand.peakHold.rawValue,
        ])
    }

    /// The shipping behaviour.
    @Test("USB: saved settings are written on connect by default")
    func usbReplaysByDefault() async {
        #expect(XPCDeviceConnection.replaysOnConnect)
        let store = DeviceSettingsStore()
        store.record(.uint32(2), for: Self.peak)
        store.record(.bool(true), for: PropertyAddress(selector: .outputDim))
        let transport = MockXPCTransport()
        let conn = XPCDeviceConnection(identifier: Self.usb, transport: transport, settingsStore: store)

        #expect(await conn.reapplyStoredSettings() == DeviceSettingsReplay(applied: 2))
        #expect(transport.setPropertyCalls.count == 2)
    }

    /// The unit is the truth for Peak Hold and Over Hold when it answers.
    /// 0xDE reply: [meter bank 1, meter bank 2, over hold, peak hold].
    @Test("USB: Peak Hold and Over Hold are read from the unit")
    func usbReadsHoldModesFromUnit() async throws {
        let store = DeviceSettingsStore()
        store.record(.uint32(0), for: Self.peak)
        let transport = MockXPCTransport()
        transport.nextReply = XPCPropertyReply(status: 0, data: Data([1, 0, 3, 2]))
        let conn = XPCDeviceConnection(identifier: Self.usb, transport: transport, settingsStore: store)

        #expect(try await conn.getProperty(Self.peak) == .uint32(2))
        #expect(try await conn.getProperty(PropertyAddress(selector: .oversHoldMode)) == .uint32(3))
        #expect(transport.getPropertyCalls.allSatisfy {
            $0.bRequest == SymphonyIOCommand.getCurrentPreferenceSettings.rawValue })
    }

    /// A failed, short or nonsense reply must not be shown as a setting.
    @Test("USB: an unusable hold-mode reply falls back to the saved value")
    func usbHoldModeFallsBackToSaved() async throws {
        let store = DeviceSettingsStore()
        store.record(.uint32(1), for: Self.peak)
        let transport = MockXPCTransport()
        let conn = XPCDeviceConnection(identifier: Self.usb, transport: transport, settingsStore: store)

        transport.nextReply = XPCPropertyReply(status: 0, data: Data([0]))            // short
        #expect(try await conn.getProperty(Self.peak) == .uint32(1))
        transport.nextReply = XPCPropertyReply(status: 0, data: Data([0xFF, 0xFF, 0xFF, 0xFF]))  // dead EP0
        #expect(try await conn.getProperty(Self.peak) == .uint32(1))
        transport.nextReply = XPCPropertyReply(status: -1, data: Data())              // failed
        #expect(try await conn.getProperty(Self.peak) == .uint32(1))
        transport.nextError = DeviceConnectionError.transportError("gone")
        #expect(try await conn.getProperty(Self.peak) == .uint32(1))
    }

    @Test("USB: nothing saved means nothing written on connect")
    func usbReplayWithNothingSaved() async {
        let transport = MockXPCTransport()
        let conn = XPCDeviceConnection(identifier: Self.usb, transport: transport)
        #expect(await conn.reapplyStoredSettings(force: true) == DeviceSettingsReplay())
        #expect(transport.setPropertyCalls.isEmpty)
    }
}
