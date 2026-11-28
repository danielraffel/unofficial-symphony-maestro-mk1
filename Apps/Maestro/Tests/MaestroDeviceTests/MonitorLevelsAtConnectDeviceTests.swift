import Foundation
import Testing
@testable import MaestroDevice
import MaestroCore

/// A4: levels at connect over ThunderBridge/PCIe, against the fake driver.
@Suite("Levels at connect (A4): ThunderBridge connection")
struct MonitorLevelsAtConnectDeviceTests {
    static let speakerMode: UInt8 = 0x25
    static let speakerVolume: UInt8 = 0x26
    static let headphoneVolume: UInt8 = 0x23
    static let speakerMute: UInt8 = 0x27

    /// A unit that reports mode `mode` and these attenuations.
    static func unit(mode: UInt8 = 2, speaker: UInt8 = 20, hp1: UInt8 = 20, hp2: UInt8 = 20)
        -> (FakeThunderboltDriver, ThunderboltDeviceConnection, DeviceSettingsStore) {
        let driver = FakeThunderboltDriver()
        driver.seedRead(command: speakerMode, reply: [mode])
        driver.seedRead(command: speakerVolume, reply: [speaker])
        driver.seedRead(command: headphoneVolume, value: 0, reply: [hp1])
        driver.seedRead(command: headphoneVolume, value: 1, reply: [hp2])
        let store = DeviceSettingsStore()
        let tb = ThunderboltDeviceConnection(identifier: SimulatedDevice.symphonyIO32ch().identifier,
                                             audioDeviceID: 0, settingsStore: store, driver: driver)
        return (driver, tb, store)
    }

    static func levelWrites(_ driver: FakeThunderboltDriver) -> [FakeThunderboltDriver.Command] {
        driver.sent.filter { $0.command == speakerVolume || $0.command == headphoneVolume }
    }

    @Test("a unit that powered up at its default goes down to the quieter saved levels")
    func quieterSavedWins() async throws {
        let (driver, tb, _) = Self.unit(speaker: 20, hp1: 20, hp2: 20)
        tb.recordSavedMonitorLevel(.speakers, attenuation: 35)
        tb.recordSavedMonitorLevel(.headphone1, attenuation: 28)
        tb.recordSavedMonitorLevel(.headphone2, attenuation: 10)   // louder than the unit: left alone
        let result = try #require(await tb.applySavedMonitorLevels())
        #expect(!result.speakersInLine)
        #expect(result.written == [.speakers, .headphone1])
        #expect(result.settled == [.speakers: 35, .headphone1: 28, .headphone2: 20])
        let writes = Self.levelWrites(driver)
        #expect(writes.map(\.command) == [Self.speakerVolume, Self.headphoneVolume])
        #expect(writes.map(\.payload) == [[35], [28]])
        #expect(writes[1].value == 0)   // Headphone 1
        // Saved from now on: what the unit is at.
        #expect(tb.savedMonitorLevel(.speakers) == 35)
        #expect(tb.savedMonitorLevel(.headphone2) == 20)
        // No mute is sent.
        #expect(!driver.sent.contains { $0.command == Self.speakerMute || $0.command == 0x24 })
    }

    @Test("a level turned down on the front panel while Maestro was closed is kept")
    func frontPanelLowerKept() async throws {
        let (driver, tb, _) = Self.unit(speaker: 40, hp1: 50, hp2: 20)
        tb.recordSavedMonitorLevel(.speakers, attenuation: 30)
        tb.recordSavedMonitorLevel(.headphone1, attenuation: 30)
        tb.recordSavedMonitorLevel(.headphone2, attenuation: 20)   // a replug, unit still on: same
        let result = try #require(await tb.applySavedMonitorLevels())
        #expect(result.written.isEmpty)
        #expect(Self.levelWrites(driver).isEmpty)
        #expect(tb.savedMonitorLevel(.speakers) == 40)
        #expect(tb.savedMonitorLevel(.headphone1) == 50)
    }

    @Test("nothing saved: the unit is left alone, its levels are saved")
    func nothingSaved() async throws {
        let (driver, tb, _) = Self.unit(speaker: 22, hp1: 18, hp2: 64)
        let result = try #require(await tb.applySavedMonitorLevels())
        #expect(result.written.isEmpty)
        #expect(driver.sent.isEmpty)
        #expect(result.settled == [.speakers: 22, .headphone1: 18, .headphone2: 64])
        #expect(tb.savedMonitorLevel(.headphone2) == 64)
    }

    @Test("Line: the speakers are not read, written or saved; the headphones are")
    func lineLeavesSpeakers() async throws {
        let (driver, tb, _) = Self.unit(mode: 0, speaker: 0, hp1: 20)
        tb.recordSavedMonitorLevel(.speakers, attenuation: 40)
        tb.recordSavedMonitorLevel(.headphone1, attenuation: 30)
        let result = try #require(await tb.applySavedMonitorLevels())
        #expect(result.speakersInLine)
        #expect(result.speakerMode == 0)
        #expect(result.written == [.headphone1])
        #expect(!driver.sent.contains { $0.command == Self.speakerVolume })
        #expect(result.settled[.speakers] == nil)
        #expect(tb.savedMonitorLevel(.speakers) == 40)
    }

    @Test("an unreadable speaker mode counts as Line")
    func unreadableModeIsLine() async throws {
        let (driver, tb, _) = Self.unit(speaker: 0)
        driver.refuseRead(command: Self.speakerMode)
        tb.recordSavedMonitorLevel(.speakers, attenuation: 40)
        let result = try #require(await tb.applySavedMonitorLevels())
        #expect(result.speakersInLine && result.speakerMode == nil)
        #expect(!driver.sent.contains { $0.command == Self.speakerVolume })
        // A mode byte that is not a mode is unreadable too.
        let (driver2, tb2, _) = Self.unit(mode: 7, speaker: 0)
        tb2.recordSavedMonitorLevel(.speakers, attenuation: 40)
        #expect(try #require(await tb2.applySavedMonitorLevels()).speakersInLine)
        #expect(driver2.sent.isEmpty)
    }

    @Test("an unreadable or out-of-range level is not written and the saved one is kept")
    func unreadableLevel() async throws {
        let (driver, tb, _) = Self.unit(speaker: 0xFF)
        driver.refuseRead(command: Self.headphoneVolume, value: 0)
        tb.recordSavedMonitorLevel(.speakers, attenuation: 30)
        tb.recordSavedMonitorLevel(.headphone1, attenuation: 30)
        let result = try #require(await tb.applySavedMonitorLevels())
        #expect(result.written.isEmpty)
        #expect(Self.levelWrites(driver).isEmpty)
        #expect(tb.savedMonitorLevel(.speakers) == 30)
        #expect(tb.savedMonitorLevel(.headphone1) == 30)
    }

    @Test("a refused write keeps the unit's level as what is saved")
    func refusedWrite() async throws {
        let (driver, tb, _) = Self.unit(speaker: 20)
        driver.shouldFail = { $0.command == Self.speakerVolume }
        tb.recordSavedMonitorLevel(.speakers, attenuation: 40)
        let result = try #require(await tb.applySavedMonitorLevels())
        #expect(!result.written.contains(.speakers))
        #expect(result.settled[.speakers] == 20)
    }

    @Test("mutes restore only towards muted and save the settled unit state")
    func mutesAtConnect() async throws {
        let (driver, tb, _) = Self.unit()
        driver.seedRead(command: Self.speakerMute, reply: [0])
        driver.seedRead(command: 0x24, value: 0, reply: [0])
        driver.seedRead(command: 0x24, value: 1, reply: [1])
        tb.recordSavedMonitorMute(.speakers, muted: true)
        tb.recordSavedMonitorMute(.headphone1, muted: true)
        tb.recordSavedMonitorMute(.headphone2, muted: false)
        let result = try #require(await tb.applySavedMonitorLevels())
        #expect(result.mutesWritten == [.speakers, .headphone1])
        #expect(result.mutesSettled == [.speakers: true, .headphone1: true, .headphone2: true])
        #expect(driver.sent.contains { $0.command == Self.speakerMute && $0.payload == [1] })
        #expect(driver.sent.contains { $0.command == 0x24 && $0.value == 0 && $0.payload == [1] })
        #expect(!driver.sent.contains { $0.command == 0x24 && $0.value == 1 })
        #expect(tb.savedMonitorMute(.headphone2) == true)
    }

    @Test("Line leaves the speaker mute alone")
    func muteLineLeavesSpeaker() async throws {
        let (driver, tb, _) = Self.unit(mode: 0)
        driver.seedRead(command: Self.speakerMute, reply: [0])
        tb.recordSavedMonitorMute(.speakers, muted: true)
        let result = try #require(await tb.applySavedMonitorLevels())
        #expect(result.mutesSettled[.speakers] == nil)
        #expect(!driver.sent.contains { $0.command == Self.speakerMute })
        #expect(tb.savedMonitorMute(.speakers) == true)
    }

    @Test("converters: nothing is read or sent")
    func convertersLeftAlone() async {
        let (driver, tb, _) = Self.unit()
        driver.converterFlags = ConverterState.flagPort1Converters
        tb.recordSavedMonitorLevel(.speakers, attenuation: 40)
        #expect(await tb.applySavedMonitorLevels() == nil)
        #expect(driver.sent.isEmpty)
        #expect(tb.savedMonitorLevel(.speakers) == 40)
    }

    @Test("saved levels are kept per unit identity, and are not replayed or answered as settings")
    func savedPerUnitAndNotOwned() throws {
        let suite = "MonitorLevelsAtConnectDeviceTests.\(UUID().uuidString)"
        let defaults = try #require(ScratchUserDefaults(suiteName: suite))
        defer { defaults.cleanup() }
        let a = DeviceSettingsStore(defaults: defaults, productID: 2200, unit: .a, identity: 0xA1)
        let tb = ThunderboltDeviceConnection(identifier: SimulatedDevice.symphonyIO32ch().identifier,
                                             audioDeviceID: 0, settingsStore: a, driver: FakeThunderboltDriver())
        tb.recordSavedMonitorLevel(.speakers, attenuation: 33)
        let again = DeviceSettingsStore(defaults: defaults, productID: 2200, unit: .a, identity: 0xA1)
        #expect(again.value(for: ThunderboltDeviceConnection.savedLevelAddress(.speakers)) == .uint32(33))
        let other = DeviceSettingsStore(defaults: defaults, productID: 2200, unit: .a, identity: 0xB2,
                                        allowLegacyMigration: false)
        #expect(other.value(for: ThunderboltDeviceConnection.savedLevelAddress(.speakers)) == nil)
        for output in MonitorLevelsAtConnect.Output.allCases {
            let selector = ThunderboltDeviceConnection.savedLevelAddress(output).selector
            #expect(!DeviceSettingsStore.ownedSettings.contains(selector))
        }
        #expect(again.entries().isEmpty)
        // Out of range is never saved.
        tb.recordSavedMonitorLevel(.speakers, attenuation: 0xFF)
        #expect(tb.savedMonitorLevel(.speakers) == 33)
    }
}
