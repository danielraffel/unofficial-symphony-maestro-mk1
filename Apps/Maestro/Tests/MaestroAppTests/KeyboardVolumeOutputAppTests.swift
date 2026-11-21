import Foundation
import Testing
@testable import MaestroApp
import MaestroCore
import MaestroDevice

/// A USB unit and helper for the Volume Keys output: answers level and mute
/// reads, records writes and "setMonitorOutput".
private final class KeysHelper: XPCTransport, @unchecked Sendable {
    private let lock = NSLock()
    var isConnected: Bool { true }
    /// Level and mute per vendor request and index.
    var answers: [UInt8: [UInt16: UInt8]] = [0x26: [0: 12], 0x27: [0: 0], 0x23: [0: 18, 1: 30], 0x24: [0: 0, 1: 1]]
    var failReads = false
    private(set) var writes: [UInt8] = []
    private(set) var reads: [UInt8] = []
    private(set) var monitorOutputs: [(output: UInt64, attenuation: UInt64, muted: Bool)] = []
    var helperOutput: UInt64? = 1
    var accepts = true
    /// What the helper answers to "helperVersion".
    var version: UInt64? = XPCDeviceConnection.audioOutputHelperVersion
    func helperVersion() async -> UInt64? { version }

    func sendSetProperty(bRequest: UInt8, wValue: UInt16, wIndex: UInt16, data: Data) async throws {
        lock.withLock { writes.append(bRequest) }
    }
    func sendGetProperty(bRequest: UInt8, wValue: UInt16, wIndex: UInt16, dataLength: UInt16) async throws -> XPCPropertyReply {
        lock.withLock { reads.append(bRequest) }
        guard !failReads, let byte = answers[bRequest]?[wIndex] else { throw DeviceConnectionError.transportError("no answer") }
        return XPCPropertyReply(status: 0, data: Data([byte]))
    }
    func getSoftwareMeterLevels() async -> (Float, Float)? { (0, 0) }
    func setSwReturnMute(_ muted: Bool) {}
    func sendMixerParam(usbCmd: UInt8, mixer: UInt16, channel: UInt16, value: UInt8) {}
    func setSwReturnLevel(_ dB: Double) {}
    func setSwReturnProcessing(_ enabled: Bool) {}
    func resetAudioOutput() {}
    private var epoch: UInt64 = 0
    var helperEpoch: UInt64 { lock.withLock { epoch } }
    func restart() { lock.withLock { epoch += 1 } }
    func helperMonitorOutput() async -> UInt64? { helperOutput }
    func setMonitorOutput(_ output: UInt64, attenuation: UInt64, muted: Bool) async -> Bool {
        guard accepts else { return false }
        lock.withLock { monitorOutputs.append((output, attenuation, muted)) }
        helperOutput = output
        return true
    }
}

extension StandardDefaultsSuites {
/// Device Settings › Volume Keys › Audio Output, on the app's own code over an
/// in-memory driver and helper.
@Suite("Volume Keys: Audio Output in the app", .serialized)
@MainActor
struct KeyboardVolumeOutputAppTests {
    private func thunderbolt(build: UInt32? = 142, slot1: IOCardType = .analogADDA16, slot2: IOCardType = .none,
                             cardsRead: Bool = true)
        -> (AppState, ThunderboltDeviceConnection, FakeThunderboltDriver) {
        let state = AppState()
        state.connectionMode = .hardware
        state.transportType = .thunderbolt
        state.isHardwareInitialized = true
        state.servingDextBuild = build.map { .build($0) }
        let driver = FakeThunderboltDriver(primary: slot1, secondary: slot2)
        let tb = ThunderboltDeviceConnection(identifier: SimulatedDevice.symphonyIO32ch().identifier,
                                             audioDeviceID: 0, driver: driver)
        state.device = tb
        state.primaryBoardType = slot1
        state.secondaryBoardType = slot2
        state.primaryBoardSource = cardsRead ? .detected : .cached
        state.secondaryBoardSource = cardsRead ? .detected : .cached
        state.unitAIdentity = 0xF2C0_0A01
        return (state, tb, driver)
    }

    @Test("nothing is sent while the unit's identity, which its saved choice hangs on, is still being read")
    func waitsForIdentity() async {
        let (state, _, driver) = thunderbolt()
        state.unitAIdentityState = .pending
        await state.serviceKeyboardVolumeOutput()
        #expect(driver.monitorOutputCalls.isEmpty)
        // A unit whose identity could not be read still gets its choice.
        state.unitAIdentityState = .failed
        await state.serviceKeyboardVolumeOutput()
        #expect(driver.monitorOutputCalls == [.init(unit: .a, output: .speakers)])
    }

    @Test("whose level the Mac's volume control holds: nothing is taken for an output before the driver or helper was told it")
    func macVolumeAdoption() {
        func tb(_ build: ServingDextBuild?, _ output: KeyboardVolumeOutput, settled: Bool, mode: UInt32 = 2) -> MacVolumeAdoption {
            AppState.macVolumeAdoption(thunderbolt: true, servingBuild: build, helperOutdated: false,
                                       output: output, settled: settled, speakerMode: mode)
        }
        // Driver build not read yet: nothing.
        #expect(tb(nil, .speakers, settled: false) == .ignore)
        // A driver before 142: the speakers, Headphone 1 in Line mode, whatever is chosen.
        #expect(tb(.build(141), .headphone2, settled: false) == .legacySpeaker)
        #expect(tb(.build(141), .speakers, settled: false, mode: 0) == .legacyHeadphone1)
        #expect(tb(.olderThanBuildReporting, .speakers, settled: false) == .legacySpeaker)
        // Build 142: the chosen output, once the driver was told it.
        #expect(tb(.build(142), .speakers, settled: false) == .ignore)
        #expect(tb(.build(142), .headphone1, settled: false) == .ignore)
        #expect(tb(.build(142), .speakers, settled: true) == .level(.speakers))
        #expect(tb(.build(142), .headphone1, settled: true) == .level(.headphone1))
        #expect(tb(.build(142), .headphone2, settled: true, mode: 0) == .level(.headphone2))
        #expect(tb(.build(142), .mixer1Level, settled: true) == .level(.mixer1Level))
        // Where the keys do nothing the driver holds its control: nothing follows it.
        #expect(tb(.build(142), .speakers, settled: true, mode: 0) == .ignore)
        #expect(tb(.build(142), KeyboardVolumeOutput.none, settled: true) == .ignore)
        // The mute control: still the speaker's with Speaker chosen in Line mode.
        func mute(_ thunderbolt: Bool, _ output: KeyboardVolumeOutput, mode: UInt32) -> MacVolumeAdoption {
            AppState.macVolumeAdoption(thunderbolt: thunderbolt, servingBuild: .build(142), helperOutdated: false,
                                       output: output, settled: true, speakerMode: mode, mute: true)
        }
        #expect(mute(true, .speakers, mode: 0) == .level(.speakers))
        #expect(mute(false, .speakers, mode: 0) == .level(.speakers))
        #expect(mute(true, .headphone1, mode: 0) == .level(.headphone1))
        #expect(mute(true, KeyboardVolumeOutput.none, mode: 2) == .ignore)

        func usb(_ output: KeyboardVolumeOutput, settled: Bool, mode: UInt32 = 2, outdated: Bool = false) -> MacVolumeAdoption {
            AppState.macVolumeAdoption(thunderbolt: false, servingBuild: nil, helperOutdated: outdated,
                                       output: output, settled: settled, speakerMode: mode)
        }
        #expect(usb(.headphone1, settled: false, outdated: true) == .legacySpeaker)
        #expect(usb(.speakers, settled: false) == .ignore)
        #expect(usb(.speakers, settled: true) == .level(.speakers))
        #expect(usb(.headphone2, settled: true) == .level(.headphone2))
        // Speaker in Line mode over USB: the Mac's control is put back.
        #expect(usb(.speakers, settled: true, mode: 0) == .putBack)
        #expect(usb(.headphone1, settled: true, mode: 0) == .level(.headphone1))
    }

    @Test("the output counts as settled only for the connection it was sent to")
    func settledPerConnection() async {
        let (state, _, _) = thunderbolt()
        #expect(!state.keyboardVolumeSettled(.speakers))
        await state.serviceKeyboardVolumeOutput()
        #expect(state.keyboardVolumeSettled(.speakers))
        #expect(!state.keyboardVolumeSettled(.headphone1))
        state.chooseKeyboardVolumeOutput(.headphone1, unit: .a)
        // Chosen, but the driver has not been told yet.
        #expect(!state.keyboardVolumeSettled(.headphone1))
        await state.serviceKeyboardVolumeOutput()
        #expect(state.keyboardVolumeSettled(.headphone1))
        let other = ThunderboltDeviceConnection(identifier: SimulatedDevice.symphonyIO32ch().identifier,
                                                audioDeviceID: 0, driver: FakeThunderboltDriver())
        state.device = other
        #expect(!state.keyboardVolumeSettled(.headphone1))
    }

    @Test("the default is Speaker; it is sent once to a driver that can be told, and again only when something changed")
    func defaultIsSentOnce() async {
        let (state, tb, driver) = thunderbolt()
        #expect(state.keyboardVolumeOutputAvailable)
        #expect(state.keyboardVolumeEntries(for: .a) == [.speakers, .headphone1, .headphone2])
        #expect(state.keyboardVolumeOutput(for: .a) == .speakers)
        _ = tb.linkState()   // the health loop reads the driver's state on every cycle
        await state.serviceKeyboardVolumeOutput()
        #expect(driver.monitorOutputCalls == [.init(unit: .a, output: .speakers)])
        await state.serviceKeyboardVolumeOutput()
        _ = tb.linkState()
        await state.serviceKeyboardVolumeOutput()
        #expect(driver.monitorOutputCalls.count == 1)
        // A link recovery or a card re-init: the driver's state changed, and
        // the choice is sent again.
        driver.simulateLinkRecovery()
        _ = tb.linkState()
        await state.serviceKeyboardVolumeOutput()
        #expect(driver.monitorOutputCalls.count == 2)
        // A restarted driver starts on Speaker again; it is told too.
        driver.simulateDriverRestart()
        _ = tb.linkState()
        await state.serviceKeyboardVolumeOutput()
        #expect(driver.monitorOutputCalls.count == 3)
        #expect(driver.monitorOutputCalls.last == .init(unit: .a, output: .speakers))
    }

    @Test("a choice is saved with the unit's settings, sent, and restored for the next connection")
    func choiceIsSavedAndSent() async {
        let (state, tb, driver) = thunderbolt()
        await state.serviceKeyboardVolumeOutput()
        state.chooseKeyboardVolumeOutput(.headphone2, unit: .a)
        await state.serviceKeyboardVolumeOutput()
        #expect(state.keyboardVolumeOutput(for: .a) == .headphone2)
        #expect(tb.settingsStore.value(for: AppState.keyboardVolumeAddress)?.asUInt32 == 3)
        #expect(driver.monitorOutputCalls.last == .init(unit: .a, output: .headphone2))
        let sent = driver.monitorOutputCalls.count
        // The same store with another connection (a reconnect): the saved
        // choice is what is sent.
        let (again, _, secondDriver) = thunderbolt()
        let reconnected = ThunderboltDeviceConnection(identifier: SimulatedDevice.symphonyIO32ch().identifier,
                                                      audioDeviceID: 0, settingsStore: tb.settingsStore,
                                                      driver: secondDriver)
        again.device = reconnected
        again.unitAIdentity = 0xF2C0_0A01   // read again for the new connection
        #expect(again.keyboardVolumeOutput(for: .a) == .headphone2)
        await again.serviceKeyboardVolumeOutput()
        #expect(secondDriver.monitorOutputCalls == [.init(unit: .a, output: .headphone2)])
        #expect(driver.monitorOutputCalls.count == sent)
        // An entry the unit does not offer is not taken.
        state.chooseKeyboardVolumeOutput(.none, unit: .a)
        #expect(state.keyboardVolumeOutput(for: .a) == .headphone2)
    }

    @Test("a driver before build 142, or one whose build is not known, is never sent the choice")
    func olderDriverIsNotAsked() async {
        for build: UInt32? in [141, 132, nil] {
            let (state, _, driver) = thunderbolt(build: build)
            #expect(!state.keyboardVolumeOutputAvailable)
            state.chooseKeyboardVolumeOutput(.headphone1, unit: .a)
            await state.serviceKeyboardVolumeOutput()
            #expect(driver.monitorOutputCalls.isEmpty)
            #expect(!state.keyboardVolumeKeysDoNothing)
        }
    }

    @Test("a refusal is tried again after a pause, not on every cycle")
    func refusalIsRetried() async {
        let (state, _, driver) = thunderbolt()
        driver.acceptsMonitorOutput = false
        await state.serviceKeyboardVolumeOutput()
        #expect(driver.monitorOutputCalls.isEmpty)
        #expect(state.keyboardVolumeRetryAfter > Date())
        driver.acceptsMonitorOutput = true
        await state.serviceKeyboardVolumeOutput()
        #expect(driver.monitorOutputCalls.isEmpty)   // still pausing
        state.keyboardVolumeRetryAfter = .distantPast
        await state.serviceKeyboardVolumeOutput()
        #expect(driver.monitorOutputCalls == [.init(unit: .a, output: .speakers)])
    }

    @Test("choosing Line on the Output page makes Headphone 1 the Audio Output, saved and sent; leaving Line keeps it; Speaker (0ch) can be chosen by hand")
    func lineMode() async {
        let (state, tb, driver) = thunderbolt()
        await state.serviceKeyboardVolumeOutput()
        #expect(driver.monitorOutputCalls == [.init(unit: .a, output: .speakers)])
        // The user sets Line (the Output page does both).
        state.speakerOutputMode = 0
        state.speakerModeChangedByUser(from: 2, to: 0, unit: .a)
        await state.serviceKeyboardVolumeOutput()
        #expect(state.keyboardVolumeOutput(for: .a) == .headphone1)
        #expect(tb.settingsStore.value(for: AppState.keyboardVolumeAddress)?.asUInt32 == 2)
        #expect(driver.monitorOutputCalls.last == .init(unit: .a, output: .headphone1))
        #expect(!state.keyboardVolumeKeysDoNothing)
        // Back to Stereo: still Headphone 1, as in the original.
        state.speakerOutputMode = 2
        state.speakerModeChangedByUser(from: 0, to: 2, unit: .a)
        await state.serviceKeyboardVolumeOutput()
        #expect(state.keyboardVolumeOutput(for: .a) == .headphone1)
        // Headphone 2 chosen, then Line again: Headphone 1 again.
        state.chooseKeyboardVolumeOutput(.headphone2, unit: .a)
        state.speakerOutputMode = 0
        state.speakerModeChangedByUser(from: 2, to: 0, unit: .a)
        #expect(state.keyboardVolumeOutput(for: .a) == .headphone1)
        // Speaker chosen by hand in Line mode: Speaker (0ch), volume keys do nothing.
        state.chooseKeyboardVolumeOutput(.speakers, unit: .a)
        await state.serviceKeyboardVolumeOutput()
        #expect(state.keyboardVolumeOutput(for: .a) == .speakers)
        #expect(state.keyboardVolumeOutput(for: .a).label(speakerMode: state.keyboardVolumeSpeakerMode(for: .a)) == "Speaker (0ch)")
        #expect(state.keyboardVolumeKeysDoNothing)
        #expect(driver.monitorOutputCalls.last == .init(unit: .a, output: .speakers))
        // A mode that is restored or read from the unit changes nothing.
        state.speakerOutputMode = 2
        state.speakerOutputMode = 0
        #expect(state.keyboardVolumeOutput(for: .a) == .speakers)
        // Reset Defaults: Speaker again.
        state.chooseKeyboardVolumeOutput(.headphone2, unit: .a)
        state.speakerOutputMode = 2
        state.resetKeyboardVolumeOutput(unit: .a)
        #expect(state.keyboardVolumeOutput(for: .a) == .speakers)
        state.speakerOutputMode = 6
        #expect(KeyboardVolumeOutput.speakers.label(speakerMode: state.keyboardVolumeSpeakerMode(for: .a)) == "Speaker (6ch)")
    }

    @Test("a unit found in Line mode with nothing saved (an update from 0.9.18) has Headphone 1; with a driver before 142 nothing is saved by a mode change")
    func lineModeWithNothingSaved() async {
        let (state, tb, driver) = thunderbolt()
        state.speakerOutputMode = 0
        #expect(state.keyboardVolumeOutput(for: .a) == .headphone1)
        await state.serviceKeyboardVolumeOutput()
        #expect(driver.monitorOutputCalls == [.init(unit: .a, output: .headphone1)])
        #expect(tb.settingsStore.value(for: AppState.keyboardVolumeAddress) == nil)
        // Leaving Line by hand keeps Headphone 1, and saves it.
        state.speakerOutputMode = 2
        state.speakerModeChangedByUser(from: 0, to: 2, unit: .a)
        #expect(state.keyboardVolumeOutput(for: .a) == .headphone1)
        let (old, oldTB, _) = thunderbolt(build: 141)
        old.speakerOutputMode = 0
        old.speakerModeChangedByUser(from: 2, to: 0, unit: .a)
        #expect(oldTB.settingsStore.value(for: AppState.keyboardVolumeAddress) == nil)
    }

    @Test("no analog output card: Headphone 1, also after Line is set, after a reset, and when Speaker was saved")
    func noAnalogCardForcesHeadphone1() async {
        let (state, tb, _) = thunderbolt(slot1: .analogAD16, slot2: .none)
        #expect(state.keyboardVolumeOutput(for: .a) == .headphone1)
        state.speakerModeChangedByUser(from: 2, to: 0, unit: .a)
        #expect(state.keyboardVolumeOutput(for: .a) == .headphone1)
        state.resetKeyboardVolumeOutput(unit: .a)
        #expect(state.keyboardVolumeOutput(for: .a) == .headphone1)
        tb.settingsStore.record(.uint32(1), for: AppState.keyboardVolumeAddress)
        #expect(state.keyboardVolumeOutput(for: .a) == .headphone1)
        state.chooseKeyboardVolumeOutput(.speakers, unit: .a)   // not offered
        #expect(state.keyboardVolumeOutput(for: .a) == .headphone1)
    }

    @Test("a unit without an analog output card offers the headphones only; cards not read yet keep Speaker")
    func cardLayouts() async {
        let (digital, _, driver) = thunderbolt(slot1: .analogAD16, slot2: .none)
        #expect(digital.keyboardVolumeEntries(for: .a) == [.headphone1, .headphone2])
        #expect(digital.keyboardVolumeOutput(for: .a) == .headphone1)
        await digital.serviceKeyboardVolumeOutput()
        #expect(driver.monitorOutputCalls == [.init(unit: .a, output: .headphone1)])
        let (unread, _, _) = thunderbolt(slot1: .none, slot2: .none, cardsRead: false)
        #expect(unread.keyboardVolumeEntries(for: .a) == [.speakers, .headphone1, .headphone2])
        let (analog, _, _) = thunderbolt(slot1: .analogAD16, slot2: .analogADDA16)
        #expect(analog.keyboardVolumeEntries(for: .a) == [.speakers, .headphone1, .headphone2])
    }

    @Test("converters only: the Mixer 1 level by default, and None, which is sent as 0 and leaves the level at 0 dB")
    func converters() async {
        let (state, _, driver) = thunderbolt()
        state.connectedUnitProbeWord = 0x8000_0000 | ConnectedUnit.converterVolumeKeysBit | 0xC0
        #expect(state.converterVolumeKeys)
        #expect(state.keyboardVolumeOutputAvailable)
        #expect(state.keyboardVolumeEntries(for: .a) == [.mixer1Level, .none])
        #expect(state.keyboardVolumeOutput(for: .a) == .mixer1Level)
        await state.serviceKeyboardVolumeOutput()
        #expect(driver.monitorOutputCalls == [.init(unit: .a, output: .mixer1Level)])
        #expect(driver.monitorOutputCalls.last?.output.driverValue == 1)
        state.speakerLevel = -31
        state.speakerMuted = true
        state.chooseKeyboardVolumeOutput(.none, unit: .a)
        await state.serviceKeyboardVolumeOutput()
        #expect(driver.monitorOutputCalls.last == .init(unit: .a, output: KeyboardVolumeOutput.none))
        #expect(driver.monitorOutputCalls.last?.output.driverValue == 0)
        #expect(state.keyboardVolumeKeysDoNothing)
        #expect(state.speakerLevel == 0 && !state.speakerMuted)
        // No speaker or headphone entry can be chosen there.
        state.chooseKeyboardVolumeOutput(.headphone1, unit: .a)
        #expect(state.keyboardVolumeOutput(for: .a) == KeyboardVolumeOutput.none)
    }

    @Test("two units: each has its own saved choice, and unit B's is sent only while it runs at 64 channels")
    func twoUnits() async {
        let (state, tb, driver) = thunderbolt()
        await state.serviceKeyboardVolumeOutput()
        #expect(driver.monitorOutputCalls == [.init(unit: .a, output: .speakers)])
        // Unit B appears.
        driver.portSelectionOverride = PortSelection.ports1And2.rawValue
        let b = tb.makeUnitBConnection()
        state.unitB = SecondUnitInfo(slot1: .analogADDA16, slot2: .none)
        state.unitBDevice = b
        state.unitBIdentity = 0xF2C0_0B01
        state.portSelection.deviceReported(dataSourceID: PortSelection.ports1And2.rawValue, state: nil)
        #expect(state.keyboardVolumeEntries(for: .b) == [.speakers, .headphone1, .headphone2])
        state.chooseKeyboardVolumeOutput(.headphone1, unit: .b)
        await state.serviceKeyboardVolumeOutput()
        #expect(state.keyboardVolumeOutput(for: .a) == .speakers)
        #expect(state.keyboardVolumeOutput(for: .b) == .headphone1)
        #expect(b.settingsStore.value(for: AppState.keyboardVolumeAddress)?.asUInt32 == 2)
        #expect(tb.settingsStore.value(for: AppState.keyboardVolumeAddress) == nil)
        #expect(driver.monitorOutputCalls.last == .init(unit: .b, output: .headphone1))
        // Unit A's choice was not sent again for it.
        #expect(driver.monitorOutputCalls.filter { $0.unit == .a }.count == 1)
        // Unit B's Speaker entry is named after unit B's own speaker mode.
        state.speakerOutputMode = 2
        state.unitBSpeakerOutputMode = 0
        #expect(KeyboardVolumeOutput.speakers.label(speakerMode: state.keyboardVolumeSpeakerMode(for: .b)) == "Speaker (0ch)")
        #expect(KeyboardVolumeOutput.speakers.label(speakerMode: state.keyboardVolumeSpeakerMode(for: .a)) == "Speaker (2ch)")
        // Back to 32 channels: nothing is sent for unit B.
        let sent = driver.monitorOutputCalls.count
        state.portSelection.deviceReported(dataSourceID: PortSelection.port1.rawValue, state: nil)
        state.chooseKeyboardVolumeOutput(.headphone2, unit: .b)
        await state.serviceKeyboardVolumeOutput()
        #expect(driver.monitorOutputCalls.count == sent)
    }

    // MARK: USB

    private func usb(_ helper: KeysHelper) throws -> (AppState, XPCDeviceConnection) {
        let state = AppState()
        state.connectionMode = .hardware
        state.transportType = .usb
        state.isHardwareInitialized = true
        let id = try #require(USBDeviceIdentifier(vendorID: ApogeeUSB.vendorID,
            productID: ApogeeUSB.SymphonyIO.pid16ch, deviceUID: "keys-\(UUID().uuidString)"))
        let connection = XPCDeviceConnection(identifier: id, transport: helper)
        state.device = connection
        state.primaryBoardType = .analogADDA16
        state.primaryBoardSource = .detected
        state.secondaryBoardType = .none
        state.secondaryBoardSource = .detected
        state.unitAIdentity = 0xF2C0_0A02
        return (state, connection)
    }

    @Test("USB: a helper that already moves the chosen output is sent nothing")
    func usbNothingToDo() async throws {
        let helper = KeysHelper()
        let (state, _) = try usb(helper)
        await state.serviceKeyboardVolumeOutput()
        await state.serviceKeyboardVolumeOutput()
        #expect(helper.monitorOutputs.isEmpty)
        #expect(helper.writes.isEmpty && helper.reads.isEmpty)
    }

    @Test("USB: a chosen headphone is sent to the helper with its own level and mute, which Maestro then shows")
    func usbHeadphone() async throws {
        let helper = KeysHelper()
        let (state, connection) = try usb(helper)
        await state.serviceKeyboardVolumeOutput()
        state.chooseKeyboardVolumeOutput(.headphone2, unit: .a)
        await state.serviceKeyboardVolumeOutput()
        #expect(helper.monitorOutputs.count == 1)
        #expect(helper.monitorOutputs.first?.output == 3)
        #expect(helper.monitorOutputs.first?.attenuation == 30)
        #expect(helper.monitorOutputs.first?.muted == true)
        #expect(state.hp2Level == -30 && state.hp2Muted)
        #expect(connection.settingsStore.value(for: AppState.keyboardVolumeAddress)?.asUInt32 == 3)
        // Choosing an output writes nothing to the unit.
        #expect(helper.writes.isEmpty)
        // The helper restarted and came back on its saved output: nothing more.
        await state.serviceKeyboardVolumeOutput()
        #expect(helper.monitorOutputs.count == 1)
    }

    @Test("USB: nothing is sent while the output's level cannot be read, or to an older helper")
    func usbRefusals() async throws {
        let helper = KeysHelper()
        helper.failReads = true
        let (state, _) = try usb(helper)
        state.chooseKeyboardVolumeOutput(.headphone1, unit: .a)
        await state.serviceKeyboardVolumeOutput()
        #expect(helper.monitorOutputs.isEmpty)
        #expect(state.keyboardVolumeRetryAfter > Date())
        helper.failReads = false
        state.keyboardVolumeRetryAfter = .distantPast
        state.usbHelperOutdated = true
        #expect(!state.keyboardVolumeOutputAvailable)
        await state.serviceKeyboardVolumeOutput()
        #expect(helper.monitorOutputs.isEmpty)
        state.usbHelperOutdated = false
        await state.serviceKeyboardVolumeOutput()
        #expect(helper.monitorOutputs.first?.output == 2)
        #expect(helper.monitorOutputs.first?.attenuation == 18)
        #expect(state.hp1Level == -18 && !state.hp1Muted)
    }

    @Test("USB, a version-2 helper: still good for mixers, but Audio Output cannot be chosen and the keys are the speaker's",
          arguments: [UInt64(2), nil])
    func usbHelperBeforeAudioOutput(version: UInt64?) async throws {
        let helper = KeysHelper()
        helper.version = version
        let (state, connection) = try usb(helper)
        // The mixer and routing requirement is unchanged: version 2 passes it.
        #expect(XPCDeviceConnection.requiredHelperVersion == 2 && XPCDeviceConnection.audioOutputHelperVersion == 3)
        if version == 2 { #expect(await connection.helperStatus() == .current) }
        connection.settingsStore.record(.uint32(3), for: AppState.keyboardVolumeAddress)
        await state.serviceKeyboardVolumeOutput()
        #expect(!state.keyboardVolumeOutputAvailable)
        #expect(state.keyboardVolumeUnavailableReason != nil)
        #expect(state.usbKeysMoveSpeakerOnly)
        // Nothing is asked of it, nothing is read for it, and a Line change saves nothing.
        #expect(helper.monitorOutputs.isEmpty && helper.reads.isEmpty && helper.writes.isEmpty)
        state.speakerModeChangedByUser(from: 2, to: 0, unit: .a)
        #expect(connection.settingsStore.value(for: AppState.keyboardVolumeAddress)?.asUInt32 == 3)
        #expect(!state.keyboardVolumeKeysDoNothing)
        // The helper is asked its version once per start, not on every cycle.
        helper.version = 3
        await state.serviceKeyboardVolumeOutput()
        #expect(!state.keyboardVolumeOutputAvailable)
        helper.restart()
        await state.serviceKeyboardVolumeOutput()
        #expect(state.keyboardVolumeOutputAvailable && state.keyboardVolumeUnavailableReason == nil)
        #expect(helper.monitorOutputs.first?.output == 3)
    }

    @Test("a choice made while the unit's identity is being read is kept and saved once the unit's own settings are in place")
    func choiceWhileIdentityPending() async {
        let (state, tb, driver) = thunderbolt()
        state.unitAIdentityState = .pending
        state.chooseKeyboardVolumeOutput(.headphone2, unit: .a)
        // Shown at once, not written into the temporary store, not sent yet.
        #expect(state.keyboardVolumeOutput(for: .a) == .headphone2)
        #expect(tb.settingsStore.value(for: AppState.keyboardVolumeAddress) == nil)
        await state.serviceKeyboardVolumeOutput()
        #expect(driver.monitorOutputCalls.isEmpty)
        // Setting Line meanwhile is kept the same way.
        state.speakerOutputMode = 0
        state.speakerModeChangedByUser(from: 2, to: 0, unit: .a)
        #expect(state.keyboardVolumeOutput(for: .a) == .headphone1)
        #expect(tb.settingsStore.value(for: AppState.keyboardVolumeAddress) == nil)
        // The identity arrives (its settings store replaces the temporary one).
        state.unitAIdentity = 0xF2C0_0A09
        await state.serviceKeyboardVolumeOutput()
        #expect(tb.settingsStore.value(for: AppState.keyboardVolumeAddress)?.asUInt32 == 2)
        #expect(state.keyboardVolumePending.isEmpty)
        #expect(state.keyboardVolumeOutput(for: .a) == .headphone1)
        #expect(driver.monitorOutputCalls == [.init(unit: .a, output: .headphone1)])
    }

    @Test("USB, Speaker in Line mode: the speaker's own level is read from the unit and nothing is sent to the helper")
    func usbLineMode() async throws {
        let helper = KeysHelper()
        let (state, connection) = try usb(helper)
        state.speakerOutputMode = 0
        // Speaker chosen by hand in Line mode.
        connection.settingsStore.record(.uint32(1), for: AppState.keyboardVolumeAddress)
        state.speakerLevel = -3   // what a drifted Mac volume would have left
        await state.serviceKeyboardVolumeOutput()
        #expect(state.keyboardVolumeKeysDoNothing)
        #expect(helper.monitorOutputs.isEmpty)
        #expect(helper.reads == [0x26, 0x27])
        #expect(state.speakerLevel == -12 && !state.speakerMuted)
        #expect(helper.writes.isEmpty)
    }
}
}
