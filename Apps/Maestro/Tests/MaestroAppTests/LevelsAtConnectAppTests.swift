import Foundation
import Testing
@testable import MaestroApp
import MaestroCore
import MaestroDevice

extension StandardDefaultsSuites {
/// A4: levels at connect, on the app's own code over the in-memory driver.
@Suite("Levels at connect (A4) in the app", .serialized)
@MainActor
struct LevelsAtConnectAppTests {
    static let speakerVolume: UInt8 = 0x26
    static let headphoneVolume: UInt8 = 0x23

    private func thunderbolt(mode: UInt8 = 2, speaker: UInt8 = 20, hp1: UInt8 = 20, hp2: UInt8 = 20,
                             saved: [MonitorLevelsAtConnect.Output: UInt32] = [:])
        -> (AppState, ThunderboltDeviceConnection, FakeThunderboltDriver) {
        let state = AppState()
        state.connectionMode = .hardware
        state.transportType = .thunderbolt
        state.isHardwareInitialized = true
        state.servingDextBuild = .build(150)
        let driver = FakeThunderboltDriver(primary: .analogADDA16, secondary: .none)
        driver.seedRead(command: 0x25, reply: [mode])
        driver.seedRead(command: Self.speakerVolume, reply: [speaker])
        driver.seedRead(command: Self.headphoneVolume, value: 0, reply: [hp1])
        driver.seedRead(command: Self.headphoneVolume, value: 1, reply: [hp2])
        let tb = ThunderboltDeviceConnection(identifier: SimulatedDevice.symphonyIO32ch().identifier,
                                             audioDeviceID: 0, driver: driver)
        for (output, level) in saved { tb.recordSavedMonitorLevel(output, attenuation: level) }
        state.device = tb
        state.primaryBoardType = .analogADDA16
        state.secondaryBoardType = IOCardType.none
        state.primaryBoardSource = .detected
        state.secondaryBoardSource = .detected
        state.unitAIdentity = 0xF2C0_0A04
        _ = tb.probeEndpoint()   // the health loop's cached link state
        return (state, tb, driver)
    }

    private func levelWrites(_ driver: FakeThunderboltDriver) -> [FakeThunderboltDriver.Command] {
        driver.sent.filter { $0.command == Self.speakerVolume || $0.command == Self.headphoneVolume }
    }

    @Test("connect: the saved, quieter levels are sent after the monitor mode and shown")
    func connectSequence() async {
        let (state, tb, driver) = thunderbolt(saved: [.speakers: 35, .headphone1: 28, .headphone2: 12])
        tb.settingsStore.record(.uint32(2), for: PropertyAddress(selector: .speakerOutputMode))
        await state.syncDeviceSettingsToHardware()
        let writes = levelWrites(driver)
        #expect(writes.map(\.payload) == [[35], [28]])
        // The monitor mode the original wrote first goes before the levels.
        let modeIndex = driver.sent.firstIndex { $0.command == 0x25 }
        let levelIndex = driver.sent.firstIndex { $0.command == Self.speakerVolume }
        #expect(modeIndex != nil && levelIndex != nil && modeIndex! < levelIndex!)
        #expect(state.speakerLevel == -35)
        #expect(state.hp1Level == -28)
        // Headphone 2's saved level was louder: the unit's -20 stands.
        #expect(state.hp2Level == -20)
        #expect(tb.savedMonitorLevel(.headphone2) == 20)
    }

    @Test("nothing saved: nothing is sent and the unit's levels are shown and saved")
    func nothingSaved() async {
        let (state, tb, driver) = thunderbolt(speaker: 26, hp1: 31, hp2: 64)
        await state.applyMonitorLevelsAtConnect(tb)
        #expect(levelWrites(driver).isEmpty)
        #expect(state.speakerLevel == -26 && state.hp1Level == -31 && state.hp2Level == -64)
        #expect(tb.savedMonitorLevel(.speakers) == 26)
    }

    @Test("a muted speaker stays muted; no mute is sent")
    func muteKept() async {
        let (state, tb, driver) = thunderbolt(saved: [.speakers: 40])
        state.speakerMuted = true
        await state.applyMonitorLevelsAtConnect(tb)
        #expect(state.speakerMuted)
        #expect(!driver.sent.contains { $0.command == 0x27 || $0.command == 0x24 })
        #expect(levelWrites(driver).map(\.payload) == [[40]])
    }

    @Test("Line: the speakers are neither written nor saved, now or afterwards")
    func lineLeavesSpeakers() async {
        let (state, tb, driver) = thunderbolt(mode: 0, speaker: 0, hp1: 20, saved: [.speakers: 40, .headphone1: 30])
        state.speakerLevel = -12
        await state.applyMonitorLevelsAtConnect(tb)
        #expect(state.speakerOutputMode == SpeakerOutputLogic.line)
        #expect(!driver.sent.contains { $0.command == Self.speakerVolume })
        #expect(state.speakerLevel == -12)   // not the unit's Line reading
        state.speakerLevel = 0
        #expect(tb.savedMonitorLevel(.speakers) == 40)
        #expect(state.hp1Level == -30)
    }

    @Test("after connect a level change is saved; before it, none is")
    func recording() async {
        let (state, tb, _) = thunderbolt(saved: [.headphone1: 30])
        // Before the step: the shown level may be a default.
        state.hp1Level = -5
        #expect(tb.savedMonitorLevel(.headphone1) == 30)
        await state.applyMonitorLevelsAtConnect(tb)
        state.hp1Level = -44   // knob, volume keys or front panel
        #expect(tb.savedMonitorLevel(.headphone1) == 44)
        state.speakerLevel = -18
        #expect(tb.savedMonitorLevel(.speakers) == 18)
        // Asleep: nothing.
        state.hardwareSleepState = .sleeping
        state.hp1Level = -10
        #expect(tb.savedMonitorLevel(.headphone1) == 44)
    }

    @Test("after a link recovery nothing is saved until the step has run again")
    func recoveryStopsRecording() async {
        let (state, tb, driver) = thunderbolt(saved: [.speakers: 30])
        await state.applyMonitorLevelsAtConnect(tb)
        #expect(state.speakerLevel == -30)
        // The unit is power-cycled: back at its -20 default.
        driver.simulateLinkRecovery()
        driver.seedRead(command: Self.speakerVolume, reply: [20])
        _ = tb.probeEndpoint()
        state.speakerLevel = -20   // e.g. the front panel poller sees the default
        #expect(tb.savedMonitorLevel(.speakers) == 30)
        await state.applyMonitorLevelsAtConnect(tb)
        #expect(state.speakerLevel == -30)
        #expect(levelWrites(driver).map(\.payload).last == [30])
    }

    @Test("a step that could not run (asleep) is owed and run by the health loop's service")
    func owedWhileAsleep() async {
        let (state, tb, driver) = thunderbolt(saved: [.speakers: 30])
        state.hardwareSleepState = .sleeping
        await state.applyMonitorLevelsAtConnect(tb)
        #expect(driver.sent.isEmpty)
        #expect(state.monitorLevelsOwed === tb)
        await state.serviceMonitorLevels()   // still asleep: still owed
        #expect(driver.sent.isEmpty && state.monitorLevelsOwed === tb)
        state.hardwareSleepState = .awake
        await state.serviceMonitorLevels()
        #expect(levelWrites(driver).map(\.payload) == [[30]])
        #expect(state.monitorLevelsOwed == nil)
        // Saving has resumed.
        state.speakerLevel = -36
        #expect(tb.savedMonitorLevel(.speakers) == 36)
        // Nothing owed: the service sends nothing more.
        await state.serviceMonitorLevels()
        #expect(levelWrites(driver).count == 1)
    }

    @Test("an unreadable link state leaves the step owed; the service runs it once it reads")
    func owedWithoutLinkState() async {
        let (state, tb, driver) = thunderbolt(saved: [.headphone2: 40])
        driver.linkReported = false
        await state.applyMonitorLevelsAtConnect(tb)
        #expect(driver.sent.isEmpty && state.monitorLevelsOwed === tb)
        driver.linkReported = true
        _ = tb.probeEndpoint()
        await state.serviceMonitorLevels()
        #expect(levelWrites(driver).map(\.payload) == [[40]])
        #expect(state.hp2Level == -40)
    }

    @Test("the service never makes the first run, nor runs for another connection")
    func serviceOnlyRetries() async {
        let (state, tb, driver) = thunderbolt(saved: [.speakers: 30])
        await state.serviceMonitorLevels()
        #expect(driver.sent.isEmpty)
        state.hardwareSleepState = .sleeping
        await state.applyMonitorLevelsAtConnect(tb)
        state.hardwareSleepState = .awake
        let (_, other, _) = thunderbolt()
        state.device = other
        await state.serviceMonitorLevels()
        #expect(driver.sent.isEmpty)
    }

    @Test("converters: nothing is sent, nothing saved")
    func converters() async {
        let (state, tb, driver) = thunderbolt(saved: [.speakers: 40])
        driver.converterFlags = ConverterState.flagPort1Converters
        await state.applyMonitorLevelsAtConnect(tb)
        #expect(driver.sent.isEmpty)
        #expect(state.monitorLevelsSettled == nil)
        state.speakerLevel = 0
        #expect(tb.savedMonitorLevel(.speakers) == 40)
    }

    @Test("unit B is never written; only unit A's port")
    func unitBUntouched() async {
        let (state, tb, driver) = thunderbolt(saved: [.speakers: 40, .headphone1: 40, .headphone2: 40])
        await state.applyMonitorLevelsAtConnect(tb)
        #expect(levelWrites(driver).count == 3)
        #expect(driver.sent.allSatisfy { $0.port == 0 })
    }

    @Test("a unit whose identity is not known yet is left alone")
    func identityUnknown() async {
        let (state, tb, driver) = thunderbolt(saved: [.speakers: 40])
        state.unitAIdentity = nil
        await state.applyMonitorLevelsAtConnect(tb)
        #expect(driver.sent.isEmpty)
        #expect(state.monitorLevelsSettled == nil)
    }
}
}
