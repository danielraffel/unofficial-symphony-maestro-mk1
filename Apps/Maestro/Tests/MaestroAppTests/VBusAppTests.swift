import Foundation
import Testing
@testable import MaestroApp
import MaestroCore
import MaestroDevice

/// Device Settings › VBus, on the app's own code over an
/// in-memory driver.
@Suite("VBus in the app", .serialized)
@MainActor
struct VBusAppTests {
    private func thunderbolt(build: UInt32? = 143, uid: String = "SymphonyThunderbridge-test-1",
                             defaults: UserDefaults? = nil)
        -> (AppState, ThunderboltDeviceConnection, FakeThunderboltDriver, UserDefaults) {
        let name = "VBusAppTests.\(UUID().uuidString)"
        let store = defaults ?? UserDefaults(suiteName: name)!
        if defaults == nil { store.removePersistentDomain(forName: name) }
        let state = AppState()
        state.vbusDefaults = store
        state.connectionMode = .hardware
        state.transportType = .thunderbolt
        state.isHardwareInitialized = true
        state.servingDextBuild = build.map { .build($0) }
        let driver = FakeThunderboltDriver()
        driver.driverBuild = build
        let base = SimulatedDevice.symphonyIO32ch(deviceUID: uid).identifier
        let tb = ThunderboltDeviceConnection(identifier: base, audioDeviceID: 0, driver: driver)
        state.device = tb
        return (state, tb, driver, store)
    }

    @Test("shown on ThunderBridge and PCIe, and not over USB, in simulation or with nothing connected")
    func shownOnTheCardConnectionOnly() {
        let (state, _, _, _) = thunderbolt()
        #expect(state.vbusShown)
        state.connectionMode = .simulated
        #expect(!state.vbusShown)
        let usb = AppState()
        usb.connectionMode = .hardware
        usb.device = SimulatedDevice.symphonyIO32ch()
        #expect(!usb.vbusShown && usb.vbusReportLine == nil && usb.vbusUnavailableReason == nil)
        let none = AppState()
        #expect(!none.vbusShown)
    }

    @Test("None until chosen; a choice is saved for the card and sent to the driver")
    func chooseSavesAndSends() async {
        let (state, _, driver, store) = thunderbolt()
        #expect(state.vbusChoice == .none)
        await state.serviceVBus()
        #expect(driver.vbusSetCalls == [.none])   // the saved size, None included, as the original's daemon sent it
        #expect(state.vbusState?.published == 0)
        state.chooseVBus(.eight)
        #expect(state.vbusChoice == .eight)
        #expect(VBusChannels.saved(in: store, deviceUID: "SymphonyThunderbridge-test-1") == .eight)
        await state.serviceVBus()
        #expect(driver.vbusSetCalls.last == .eight)
        #expect(state.vbusState == VBusState(published: 8, requested: 8, firstChannel: 33, flags: 0))
        #expect(state.vbusStatusLine == nil)
        // Nothing more is sent while nothing changes.
        let sent = driver.vbusSetCalls.count
        await state.serviceVBus()
        await state.serviceVBus()
        #expect(driver.vbusSetCalls.count == sent)
    }

    @Test("the saved choice is sent again when the app starts, to another card its own")
    func reappliedOnConnect() async {
        let (first, _, _, store) = thunderbolt()
        first.chooseVBus(.sixteen)
        await first.serviceVBus()
        // A new launch, the same card: the saved size goes to the driver.
        let (second, _, driver, _) = thunderbolt(defaults: store)
        #expect(second.vbusChoice == .sixteen)
        await second.serviceVBus()
        #expect(driver.vbusSetCalls == [.sixteen])
        // Another card has its own choice.
        let (other, _, otherDriver, _) = thunderbolt(uid: "SymphonyThunderbridge-test-2", defaults: store)
        #expect(other.vbusChoice == .none)
        await other.serviceVBus()
        #expect(otherDriver.vbusSetCalls == [.none])
    }

    @Test("a driver that restarts or is replaced is sent the size again")
    func reappliedAfterDriverRestart() async {
        let (state, tb, driver, _) = thunderbolt()
        state.chooseVBus(.four)
        await state.serviceVBus()
        #expect(driver.vbusPublished == 4)
        _ = tb.linkState()               // the health loop's read
        driver.simulateDriverRestart()   // a new driver: no VBus
        #expect(driver.vbusPublished == 0)
        _ = tb.linkState()
        await state.serviceVBus()
        #expect(driver.vbusPublished == 4 && driver.vbusSetCalls.suffix(2) == [.four, .four])
        // A link recovery: sent again, which the driver takes as nothing to do.
        driver.simulateLinkRecovery()
        _ = tb.linkState()
        await state.serviceVBus()
        #expect(driver.vbusPublished == 4)
    }

    @Test("an older driver is never asked, and the pop-up is disabled with the reason")
    func olderDriver() async {
        for build: UInt32? in [142, 131] {
            let (state, _, driver, store) = thunderbolt(build: build)
            #expect(state.vbusShown && !state.vbusDriverSupports)
            #expect(state.vbusUnavailableReason?.contains("older") == true)
            state.chooseVBus(.eight)
            await state.serviceVBus()
            #expect(driver.vbusSetCalls.isEmpty)
            #expect(driver.vbusCallCount == 0)   // not even tried: the app itself holds back
            #expect(VBusChannels.saved(in: store, deviceUID: "SymphonyThunderbridge-test-1") == .none)
            #expect(state.vbusReportLine?.contains("not available") == true)
        }
        // The build not read yet: nothing sent, and nothing to say.
        let (unread, _, driver, _) = thunderbolt(build: nil)
        #expect(unread.vbusUnavailableReason == nil && !unread.vbusDriverSupports)
        await unread.serviceVBus()
        #expect(driver.vbusSetCalls.isEmpty && driver.vbusCallCount == 0)
    }

    @Test("a size the driver does not take is tried again after a pause, not on every cycle")
    func refusedIsRetried() async {
        let (state, _, driver, _) = thunderbolt()
        driver.acceptsVBus = false
        state.chooseVBus(.eight)
        await state.serviceVBus()
        await state.serviceVBus()
        #expect(driver.vbusSetCalls.isEmpty && state.vbusSent == nil)
        #expect(state.vbusRetryAfter > Date())
        driver.acceptsVBus = true
        state.vbusRetryAfter = .distantPast
        await state.serviceVBus()
        #expect(driver.vbusSetCalls == [.eight])
    }

    @Test("until Core Audio has made the change the page says so, then follows the driver")
    func followsTheDriver() async {
        let (state, _, driver, _) = thunderbolt()
        driver.vbusPublishesAtOnce = false
        state.chooseVBus(.eight)
        await state.serviceVBus()
        #expect(state.vbusState?.published == 0 && state.vbusState?.requested == 8)
        #expect(state.vbusStatusLine == "Changing…")
        driver.performVBusChange()
        await state.serviceVBus()
        #expect(state.vbusState?.published == 8 && state.vbusStatusLine == nil)
        #expect(driver.vbusSetCalls == [.eight])   // followed by reading, not by sending again
    }

    @Test("a size the driver could not add is sent again after the pause, and the page says Maestro will try again")
    func failedPublishIsRetried() async {
        let (state, _, driver, _) = thunderbolt()
        driver.vbusFailPublishes = 1
        state.chooseVBus(.eight)
        await state.serviceVBus()
        #expect(driver.vbusSetCalls == [.eight] && state.vbusState?.publishFailed == true)
        #expect(state.vbusStatusLine == "The driver could not add the VBus channels. Maestro will try again.")
        // Not on every cycle: the pause comes first.
        await state.serviceVBus()
        await state.serviceVBus()
        #expect(driver.vbusSetCalls == [.eight])
        state.vbusSentAt = .distantPast
        await state.serviceVBus()
        #expect(driver.vbusSetCalls == [.eight, .eight])
        #expect(state.vbusState == VBusState(published: 8, requested: 8, firstChannel: 33, flags: 0))
        #expect(state.vbusStatusLine == nil)
        await state.serviceVBus()
        #expect(state.vbusRetries == 0 && driver.vbusSetCalls.count == 2)
    }

    @Test("a size that keeps failing is sent a few times, not for ever; choosing it again sends it again")
    func failedPublishGivesUp() async {
        let (state, _, driver, _) = thunderbolt()
        driver.vbusFailPublishes = 100
        state.chooseVBus(.eight)
        for _ in 0..<12 {
            state.vbusSentAt = .distantPast
            await state.serviceVBus()
        }
        #expect(driver.vbusSetCalls.count == 1 + AppState.vbusMaxRetries)
        #expect(state.vbusStatusLine
                == "The driver could not add the VBus channels. Choose None, then the size again, or restart the Mac.")
        let calls = driver.vbusCallCount
        await state.serviceVBus()
        #expect(driver.vbusCallCount == calls)   // nothing more is asked of the driver
        // The same size chosen again (through None, as the page says, or directly).
        driver.vbusFailPublishes = 0
        state.chooseVBus(.eight)
        await state.serviceVBus()
        #expect(driver.vbusSetCalls.last == .eight && driver.vbusSetCalls.count == 2 + AppState.vbusMaxRetries)
        #expect(state.vbusState?.published == 8 && state.vbusStatusLine == nil && state.vbusRetries == 0)
    }

    @Test("a change that never finishes is sent again after the pause")
    func abortedChangeIsRetried() async {
        let (state, _, driver, _) = thunderbolt()
        driver.vbusPublishesAtOnce = false
        state.chooseVBus(.eight)
        await state.serviceVBus()
        await state.serviceVBus()
        #expect(driver.vbusSetCalls == [.eight] && state.vbusStatusLine == "Changing…")
        state.vbusSentAt = .distantPast
        await state.serviceVBus()
        #expect(driver.vbusSetCalls == [.eight, .eight])
        driver.performVBusChange()
        await state.serviceVBus()
        #expect(state.vbusState?.published == 8 && state.vbusStatusLine == nil)
        await state.serviceVBus()
        #expect(driver.vbusSetCalls.count == 2 && state.vbusRetries == 0)
    }

    @Test("nothing is sent while the hardware is asleep")
    func notWhileSuspended() async {
        let (state, _, driver, _) = thunderbolt()
        state.hardwareSleepState = .sleeping
        state.chooseVBus(.eight)
        await state.serviceVBus()
        #expect(driver.vbusSetCalls.isEmpty)
        state.hardwareSleepState = .awake
        await state.serviceVBus()
        #expect(driver.vbusSetCalls == [.eight])
    }

    @Test("the diagnostics report's device section records the VBus size")
    func diagnostics() async {
        let (state, _, _, _) = thunderbolt()
        state.chooseVBus(.eight)
        await state.serviceVBus()
        #expect(state.vbusReportLine == "VBus: 8 Channels (driver: 8 published, 8 requested, first channel 33)")
        #expect(state.deviceInfoReportForDiagnostics?.clipboardText.contains(
            "VBus: 8 Channels (driver: 8 published, 8 requested, first channel 33)") == true)
    }

    @Test("software meter peaks keep the hardware channels: VBus channels are not hardware outputs")
    func metersIgnoreVBusChannels() {
        let (state, _, _, _) = thunderbolt()
        let peaks = (0..<40).map { Float(-$0) }   // 32 hardware + 8 VBus from the Core Audio tap
        #expect(state.thunderboltHardwareChannels == 32)
        #expect(state.hardwareSoftwarePeaks(peaks) == Array(peaks.prefix(32)))
        #expect(state.hardwareSoftwarePeaks(nil) == nil)
        // Not on ThunderBridge: untouched.
        let usb = AppState()
        usb.device = SimulatedDevice.symphonyIO32ch()
        #expect(usb.hardwareSoftwarePeaks(peaks) == peaks)
    }

    @Test("every software-meter read on the ThunderBridge path goes through the hardware-only filter")
    func everyMeterReadIsFiltered() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("MaestroApp/AppState.swift"), encoding: .utf8)
        for call in ["softwareInputPeaks()", "softwareOutputPeaks()"] {
            let all = source.components(separatedBy: "meterDevice?.\(call)").count - 1
            let filtered = source.components(separatedBy: "hardwareSoftwarePeaks(self.meterDevice?.\(call))").count - 1
            #expect(all > 0 && all == filtered, "\(call): \(filtered) of \(all) reads filtered")
        }
    }

    @Test("VBus has its own section directly after Connection, with the About VBus button, Device channels and the note")
    func ownSectionAfterConnection() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let settings = try String(contentsOf: root.appendingPathComponent("MaestroApp/SettingsViews.swift"), encoding: .utf8)
        #expect(settings.contains("            connectionSection\n            vbusSection\n"))
        let connection = try #require(settings.range(of: "@ViewBuilder private var connectionSection"))
        let vbus = try #require(settings.range(of: "@ViewBuilder private var vbusSection"))
        let end = try #require(settings.range(of: "@ViewBuilder private var volumeKeysSection"))
        // Ports and Rescan stay in Connection; nothing of VBus is left there.
        let connectionBody = settings[connection.upperBound..<vbus.lowerBound]
        // The Symphony Source label carries its info button (a label: closure).
        #expect(connectionBody.contains("Text(\"Symphony Source\")") && connectionBody.contains("Button(\"Rescan\")"))
        #expect(!connectionBody.contains("appState.vbus") && !connectionBody.contains("VBusChannels"))
        let body = settings[vbus.upperBound..<end.lowerBound]
        for piece in ["if appState.vbusShown", "Section(\"VBus\")", ".accessibilityLabel(VBusChannels.infoTitle)",
                      "VBusChannels.infoParagraphs", "Link(VBusChannels.apogeeArticleTitle, destination: VBusChannels.apogeeArticleURL)",
                      "LabeledContent(\"Device channels\", value: range)", "appState.vbusDeviceChannels",
                      "appState.vbusReopenNote", "appState.vbusStatusLine", "appState.vbusUnavailableReason"] {
            #expect(body.contains(piece), "\(piece)")
        }
    }

    @Test("Device channels: shown while VBus is on and the device has the channels, after the hardware channels")
    func deviceChannelsRow() async {
        let (state, _, driver, _) = thunderbolt()
        await state.serviceVBus()
        #expect(state.vbusDeviceChannels == nil)   // None
        state.chooseVBus(.eight)
        #expect(state.vbusDeviceChannels == nil)   // chosen, the device does not have them yet
        await state.serviceVBus()
        #expect(driver.vbusPublished == 8)
        #expect(state.vbusDeviceChannels == "33–40")
        state.chooseVBus(.none)
        await state.serviceVBus()
        #expect(state.vbusDeviceChannels == nil)
        // Not over USB.
        let usb = AppState()
        usb.connectionMode = .hardware
        usb.device = SimulatedDevice.symphonyIO32ch()
        #expect(usb.vbusDeviceChannels == nil && usb.vbusReopenNote == nil)
    }

    @Test("the note about open applications: not at launch or when the saved size is sent, from the first change on, not saved")
    func reopenNoteAfterAChange() async {
        let (first, _, _, store) = thunderbolt()
        await first.serviceVBus()
        #expect(first.vbusReopenNote == nil)
        first.chooseVBus(.none)   // the same size again: nothing changed
        #expect(first.vbusReopenNote == nil)
        first.chooseVBus(.eight)
        await first.serviceVBus()
        #expect(first.vbusReopenNote == "If an open audio application doesn't show the new channels, quit and reopen it.")
        first.chooseVBus(.none)
        #expect(first.vbusReopenNote == "If an open audio application still shows the VBus channels, quit and reopen it.")
        first.chooseVBus(.sixteen)
        await first.serviceVBus()
        #expect(first.vbusReopenNote?.contains("new channels") == true)
        // The next launch: the saved size is sent on connect, without the note.
        let (second, _, driver, _) = thunderbolt(defaults: store)
        await second.serviceVBus()
        #expect(driver.vbusSetCalls == [.sixteen] && second.vbusChoice == .sixteen)
        #expect(second.vbusReopenNote == nil)
        // An older driver: the pop-up is disabled, nothing is changed, no note.
        let (old, _, _, _) = thunderbolt(build: 142)
        old.chooseVBus(.eight)
        #expect(old.vbusReopenNote == nil)
    }
}
