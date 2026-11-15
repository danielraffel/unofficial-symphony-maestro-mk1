import Foundation
import Testing
@testable import MaestroCore

/// EXPERIMENT (64 channels, stage 2): the port selection Maestro shows, and how
/// it stays in step with the Core Audio device (Audio MIDI Setup, Sound
/// settings, Maestro and the driver itself can all change it).
@Suite("PortSelection")
struct PortSelectionTests {
    private let stage2Capable: UInt32 = SecondPortState.audioCapable

    private func state(audio: UInt32) -> SecondPortState {
        SecondPortState(portCount: 2, flags: 0x0F, audio: audio)
    }

    @Test("the two entries are the original's, in its order and with its IDs; named after the device")
    func entries() {
        // og_source/symphonymk1/ext/Symphony64/SymphonyAPI/SymphonyCommon.h:182-183
        #expect(PortSelection.allCases == [.port1, .ports1And2])
        // Not Apogee's names, on purpose: the menu-bar Sound menu shows the
        // selected entry's name in place of the device name.
        #expect(PortSelection.port1.name == "Symphony I/O: ThunderBridge")
        #expect(PortSelection.ports1And2.name == "Symphony I/O: ThunderBridge 64")
        #expect(PortSelection.port1.apogeeName == "Port 1: 32ch")
        #expect(PortSelection.ports1And2.apogeeName == "Port 1-2: 64ch")
        #expect(PortSelection.port1.pickerLabel == "32 channels")
        #expect(PortSelection.ports1And2.pickerLabel == "64 channels (two units)")
        #expect(PortSelection.port1.rawValue == 0 && PortSelection.ports1And2.rawValue == 1)
        #expect(PortSelection.port1.channelCount == 32 && PortSelection.ports1And2.channelCount == 64)
    }

    @Test("only the two data-source IDs are a port selection")
    func ids() {
        #expect(PortSelection(dataSourceID: 0) == .port1)
        #expect(PortSelection(dataSourceID: 1) == .ports1And2)
        #expect(PortSelection(dataSourceID: 2) == nil)
        #expect(PortSelection(dataSourceID: nil) == nil)
    }

    @Test("nothing is shown for a device without the selector")
    func unavailable() {
        var model = PortSelectionModel()
        #expect(!model.isAvailable && model.selection == nil)
        model.deviceReported(dataSourceID: nil, state: nil)
        #expect(!model.isAvailable && model.notice == nil)
        // And nothing is written.
        #expect(model.userChose(.ports1And2) == nil)
        #expect(model.pending == nil)
    }

    @Test("a change made in Audio MIDI Setup shows in Maestro")
    func followsTheDevice() {
        var model = PortSelectionModel()
        model.deviceReported(dataSourceID: 0, state: state(audio: stage2Capable))
        #expect(model.selection == .port1 && model.notice == nil)
        // Someone picks "Port 1-2: 64ch" elsewhere; the listener reports it.
        model.deviceReported(dataSourceID: 1,
                             state: state(audio: stage2Capable | SecondPortState.audioActiveFlag))
        #expect(model.selection == .ports1And2 && model.notice == nil && model.pending == nil)
        // And back.
        model.deviceReported(dataSourceID: 0, state: state(audio: stage2Capable))
        #expect(model.selection == .port1 && model.notice == nil)
    }

    @Test("a choice made in Maestro is written once and confirmed by the device")
    func userChoice() {
        var model = PortSelectionModel()
        model.deviceReported(dataSourceID: 0, state: state(audio: stage2Capable))
        // The entry already selected is not written again.
        #expect(model.userChose(.port1) == nil)
        #expect(model.userChose(.ports1And2) == 1)
        #expect(model.pending == .ports1And2 && model.selection == .port1)
        // The device shows the new value at once, before the switch is done.
        model.deviceReported(dataSourceID: 1, state: state(audio: stage2Capable))
        #expect(model.selection == .ports1And2 && model.pending == nil)
    }

    @Test("a refused request comes back as 32 channels with the reason in plain words")
    func refused() {
        var model = PortSelectionModel()
        model.deviceReported(dataSourceID: 0, state: state(audio: stage2Capable))
        #expect(model.userChose(.ports1And2) == 1)
        model.deviceReported(dataSourceID: 1, state: state(audio: stage2Capable))
        // The driver could not do it: reason 1, nothing on port 2.
        let refusedWord = stage2Capable | SecondPortState.audioRefusedFlag | (1 << 8)
        model.deviceReported(dataSourceID: 0, state: state(audio: refusedWord))
        #expect(model.selection == .port1 && model.pending == nil)
        #expect(model.notice == "64 channels needs a second unit on port 2, and none was found.")
        // The same pick made by accident in Sound settings ends the same way.
        var other = PortSelectionModel()
        other.deviceReported(dataSourceID: 0, state: state(audio: refusedWord))
        #expect(other.selection == .port1 && other.notice == model.notice)
    }

    @Test("a fallback the driver made on its own is explained")
    func fellBack() {
        var model = PortSelectionModel()
        model.deviceReported(dataSourceID: 1,
                             state: state(audio: stage2Capable | SecondPortState.audioActiveFlag))
        #expect(model.notice == nil)
        // Port 2's units were switched off: reason 5.
        model.deviceReported(dataSourceID: 0,
                             state: state(audio: stage2Capable | SecondPortState.audioFellBackFlag | (5 << 8)))
        #expect(model.selection == .port1)
        #expect(model.notice == "Back to 32 channels: the unit on port 2 stopped sending its clock.")
        // Selecting 64 again and getting it clears the notice.
        model.deviceReported(dataSourceID: 1,
                             state: state(audio: stage2Capable | SecondPortState.audioActiveFlag))
        #expect(model.notice == nil)
    }

    @Test("a failed write changes nothing")
    func writeFailed() {
        var model = PortSelectionModel()
        model.deviceReported(dataSourceID: 0, state: nil)
        #expect(model.userChose(.ports1And2) == 1)
        model.writeFailed()
        #expect(model.pending == nil && model.selection == .port1)
    }

    @Test("the selector going away (driver replaced, device gone) hides the picker")
    func disappears() {
        var model = PortSelectionModel()
        model.deviceReported(dataSourceID: 1,
                             state: state(audio: stage2Capable | SecondPortState.audioActiveFlag))
        _ = model.userChose(.port1)
        model.deviceReported(dataSourceID: nil, state: nil)
        #expect(model == PortSelectionModel())
    }
}

@Suite("SecondPortState stage 2")
struct SecondPortStateAudioTests {
    private func words(audio: UInt32, phase: UInt32 = 0) -> [UInt32] {
        var w = [UInt32](repeating: 0, count: 16)
        w[1] = 2; w[2] = 0x0F; w[14] = audio; w[15] = phase
        return w
    }

    @Test("the audio and phase words are words 14 and 15")
    func decode() throws {
        let state = try #require(SecondPortState.decode(words(audio: 0x0003_0047, phase: 0x8020_021B)))
        #expect(state.audio == 0x0003_0047 && state.phase == 0x8020_021B)
        #expect(state.supportsPort2Audio && state.audioActive && state.audioPublished64)
        #expect(!state.audioRefused && !state.audioFellBack && state.audioReason == 0)
        #expect(state.audioModeChanges == 3)
        #expect(state.audioText == "On: 64 channels, 33-64 are port 2")
        #expect(state.phaseText == "Aligned, jam 0x1b; 2 units read")
        #expect(state.audioProblemText == nil)
    }

    @Test("a stage-1 driver leaves both words zero and nothing new is shown")
    func stageOne() throws {
        let state = try #require(SecondPortState.decode(words(audio: 0)))
        #expect(!state.supportsPort2Audio && !state.audioActive && state.phaseText == nil)
        #expect(state.deviceInfoRows.map(\.label)
                == ["Two-port driver", "Port 2 Link", "Port 2 Clock", "Port 2 Units"])
        #expect(state.deviceInfoRows[0].value == SecondPortState.experimentValue)
        #expect(!state.rawText.contains("audio="))
    }

    @Test("rows and copied text with stage 2")
    func rows() {
        let off = SecondPortState(portCount: 2, flags: 0x0F, audio: 0x01)
        #expect(off.deviceInfoRows.map(\.label)
                == ["Two-port driver", "Port 2 Audio", "Port 2 Link", "Port 2 Clock", "Port 2 Units"])
        #expect(off.deviceInfoRows[0].value
                == "On. Port 2 is switched on, looked at and carries audio only while 64 channels are selected.")
        #expect(off.deviceInfoRows[1].value == "Off: 32 channels, port 1 only")
        let on = SecondPortState(portCount: 2, flags: 0x0F, audio: 0x0001_0007, phase: 0x8010_010B)
        #expect(on.deviceInfoRows.map(\.label).prefix(3) == ["Two-port driver", "Port 2 Audio", "Port 2 Phase"])
        #expect(on.deviceInfoRows[1].value == "On: 64 channels, 33-64 are port 2 (Core Audio has not switched yet)")
        #expect(on.deviceInfoRows[2].value == "Aligned, jam 0x0b; 1 unit read")
        #expect(on.reportLines.last?.hasSuffix(" audio=0x00010007 phase=0x8010010b") == true)
        // Stage 2 without its buffers: said plainly, not shown as a stage-1 driver.
        let unavailable = SecondPortState(portCount: 2, flags: 0x0F, audio: SecondPortState.audioStage2)
        #expect(unavailable.deviceInfoRows[0].value == SecondPortState.experimentValueWithAudio)
        #expect(unavailable.deviceInfoRows[1].value
                == "Not available: the driver could not set up port 2's audio buffers")
        // One-port answer: still nothing at all.
        #expect(SecondPortState(portCount: 1, audio: 0x47).deviceInfoRows.isEmpty)
    }

    @Test("every refusal and fallback reason is put into words")
    func reasons() {
        let expected: [(UInt32, String)] = [
            (1, "there is no unit with its link up on port 2"),
            (2, "the driver could not set up port 2's audio buffers"),
            (3, "port 2 did not lock at the current sample rate"),
            (4, "the card did not accept port 2's buffer addresses"),
            (5, "port 2's unit clock went away"),
            (6, "the card was reset (after sleep); select 64 channels again"),
            (7, "port 2 did not follow a sample rate change"),
            (8, "the card could not be reached, or it is stopped after a failed sample rate change"),
        ]
        for (code, text) in expected {
            let refused = SecondPortState(portCount: 2, audio: 0x11 | (code << 8))
            #expect(refused.audioRefused && refused.audioReason == code)
            #expect(refused.audioText == "Off. 64 channels refused: \(text).")
            let fell = SecondPortState(portCount: 2, audio: 0x21 | (code << 8))
            #expect(fell.audioFellBack)
            #expect(fell.audioText == "Off. Went back to 32 channels: \(text).")
        }
        #expect(SecondPortState.reasonText(99) == "reason 99")
        // While 64 is running an old reason is not a problem to report.
        #expect(SecondPortState(portCount: 2, audio: 0x13 | (1 << 8)).audioProblemText == nil)
    }

    @Test("a failed phase alignment says so")
    func phaseFailed() {
        let state = SecondPortState(portCount: 2, audio: 0x0B, phase: 0x8010_0300)
        #expect(state.phaseText == "Not aligned (a unit did not answer, or the card was busy); 3 units read")
        #expect(SecondPortState(portCount: 2, audio: 0x03).phaseText == nil)
    }
}

/// EXPERIMENT (64 channels): what Maestro calls the port selection and how
/// Device Info lays it out.
@Suite("Ports wording and layout")
struct PortsWordingTests {
    private let stage2Capable: UInt32 = SecondPortState.audioCapable

    private func state(audio: UInt32) -> SecondPortState {
        SecondPortState(portCount: 2, flags: 0x0F, audio: audio)
    }

    // MARK: - Maestro's wording

    /// The names Maestro uses for the Source menu are the driver's
    /// (`kSymphonyDeviceName`, `kSymphonyPortSourceName32/64`), read from the
    /// header rather than copied.
    @Test("the data-source names are the driver's, read from its header")
    func namesMatchTheDriver() throws {
        let header = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Drivers/Thunderbolt/Source/SymphonyThunderbridgeShared.h")
        let text = try String(contentsOf: header, encoding: .utf8)
        func define(_ name: String) -> String? {
            text.split(separator: "\n").first { $0.hasPrefix("#define \(name) ") }
                .map { String($0.dropFirst("#define \(name) ".count)).trimmingCharacters(in: .whitespaces) }
        }
        let name32 = try #require(define("kSymphonyPortSourceName32"))
        let name64 = try #require(define("kSymphonyPortSourceName64"))
        #expect(name32 == "\"\(PortSelection.port1.name)\"")
        #expect(name64 == "\"\(PortSelection.ports1And2.name)\"")
        let device = try #require(define("kSymphonyDeviceName"))
        #expect(device.hasPrefix("\"\(PortSelection.port1.name)\""))
        // The temporary naming switch is gone: the driver has one pair of names.
        #expect(define("kSymphonyPortSourceSchemeCount") == nil)
        #expect(!text.contains("SchemeName"))
        #expect(define("kSymphonyPortSourcePort1")?.hasPrefix("0u") == true)
        #expect(define("kSymphonyPortSourcePorts1And2")?.hasPrefix("1u") == true)
    }

    @Test("the info popover and Help use the driver's Source names and say \"should keep\"")
    func infoAndHelpUseTheDriverNames() {
        let info = PortSelection.infoText
        #expect(info == "In Audio MIDI Setup (Source) and the macOS Sound menu, these choices are named:\n"
                + "• \(PortSelection.port1.name) — 32 channels\n"
                + "• \(PortSelection.ports1And2.name) — 64 channels (two units)\n"
                + "Apogee's software called these \"Port 1: 32ch\" and \"Port 1-2: 64ch\".\n"
                + "Your DAW should keep the same device either way.")
        #expect(info.contains("• Symphony I/O: ThunderBridge — 32 channels"))
        #expect(info.contains("• Symphony I/O: ThunderBridge 64 — 64 channels (two units)"))
        let help = PortSelection.helpText.joined(separator: " ")
        #expect(help.contains("**\(PortSelection.port1.name)**"))
        #expect(help.contains("**\(PortSelection.ports1And2.name)**"))
        #expect(help.contains(PortSelection.ports1And2.pickerLabel))
        #expect(help.contains("refuses 64 channels"))
        #expect(help.contains("Reports from people using it are welcome"))
        // Same bytes become stable at promotion: nothing may call this a test build or a beta.
        for word in ["test build", "Test build", "beta", "Beta", "EXPERIMENT"] {
            #expect(!help.contains(word))
            #expect(!PortSelection.infoText.contains(word))
        }
        #expect(help.contains("should keep"))
        #expect(help.contains(PortSelection.apogeeNamesSentence))
        #expect(PortSelection.explanationLines == [
            "32 channels: one Symphony I/O on ThunderBridge port 1.",
            "64 channels: adds a second unit on port 2 as channels 33–64.",
        ])
    }

    @Test("every driver reason has a plain sentence; the copied details keep the driver's words")
    func plainReasons() {
        for code in UInt32(1)...8 {
            let refused = SecondPortState(portCount: 2, audio: 0x11 | (code << 8))
            let plain = refused.plainProblemText ?? ""
            #expect(plain.hasPrefix(code == 1 ? "64 channels needs" : "64 channels could not start: "))
            #expect(plain.hasSuffix("."))
            #expect(!plain.contains("reason "))
            // The raw reason stays in the copied details.
            #expect(refused.reportLines.contains("Port 2 Audio: Off. 64 channels refused: \(SecondPortState.reasonText(code))."))
            let fell = SecondPortState(portCount: 2, audio: 0x21 | (code << 8))
            #expect(fell.plainProblemText == "Back to 32 channels: \(SecondPortState.plainReason(code)).")
        }
        #expect(SecondPortState(portCount: 2, audio: 0x11 | (1 << 8)).plainProblemText
                == "64 channels needs a second unit on port 2, and none was found.")
        #expect(SecondPortState(portCount: 2, audio: 0x13 | (1 << 8)).plainProblemText == nil)
        #expect(SecondPortState.plainReason(99) == "the driver gave reason 99")
    }

    // MARK: - Device Info layout

    private func model(_ id: UInt32, _ state: SecondPortState, choose: PortSelection? = nil) -> PortSelectionModel {
        var m = PortSelectionModel()
        m.deviceReported(dataSourceID: id, state: state)
        if let choose { _ = m.userChose(choose) }
        return m
    }

    @Test("at 32 channels: no rows (no test-build row, no port-2 rows)")
    func layoutAt32() {
        let s = state(audio: stage2Capable)
        let shown = PortsPresentation(model: model(0, s), state: s)
        #expect(shown.rows.isEmpty)
        #expect(shown.statusLine == nil)
        // The copied details still carry everything.
        #expect(s.reportLines.contains { $0.hasPrefix("Port 2 Link: ") })
        #expect(s.reportLines.contains { $0.hasPrefix("Port 2 Raw: ") })
    }

    @Test("after a refusal: the plain reason once, under the picker, and no port-2 rows")
    func layoutAfterRefusal() {
        let s = state(audio: stage2Capable | SecondPortState.audioRefusedFlag | (1 << 8))
        let shown = PortsPresentation(model: model(0, s), state: s)
        #expect(shown.statusLine == "64 channels needs a second unit on port 2, and none was found.")
        #expect(shown.rows.isEmpty)
        #expect(!shown.rows.contains { $0.value.contains("refused") })
        #expect(s.reportLines.contains { $0.contains("64 channels refused") })
    }

    @Test("while switching: one line under the picker, no port-2 rows")
    func layoutSwitching() {
        let s = state(audio: stage2Capable)
        // Chosen in Maestro, not confirmed yet.
        let chosen = PortsPresentation(model: model(0, s, choose: .ports1And2), state: s)
        #expect(chosen.statusLine == "Switching to 64 channels…")
        #expect(chosen.rows.isEmpty)
        // Chosen elsewhere: the device says 64, the card is not running it yet.
        let elsewhere = PortsPresentation(model: model(1, s), state: s)
        #expect(elsewhere.statusLine == "Switching to 64 channels…")
        #expect(elsewhere.rows.isEmpty)
    }

    @Test("64 channels running: Link, Clock, Units and Phase")
    func layoutRunning() {
        let s = SecondPortState(portCount: 2, flags: 0x0F, xlinkClocking: 0x0102_0000,
                                units: [0x0007_FFFF], audio: stage2Capable | SecondPortState.audioActiveFlag | 0x04,
                                phase: 0x8001_010B)
        let shown = PortsPresentation(model: model(1, s), state: s)
        #expect(shown.statusLine == nil)
        #expect(shown.rows.map { $0.label } == ["Port 2 Link", "Port 2 Clock", "Port 2 Unit 1", "Port 2 Phase"])
        // Back to 32: the rows go again.
        let back = state(audio: stage2Capable)
        #expect(PortsPresentation(model: model(0, back), state: back).rows.isEmpty)
    }

    @Test("the picker shows the device's value, not the request: pick 64, refused, stays 32")
    func pickRefused() {
        var model = PortSelectionModel()
        model.deviceReported(dataSourceID: 0, state: state(audio: stage2Capable))
        #expect(model.canChoose)
        #expect(model.userChose(.ports1And2) == 1)
        #expect(model.pending == .ports1And2)
        #expect(model.displayedSelection == .port1)
        #expect(!model.canChoose)
        #expect(model.userChose(.ports1And2) == nil)
        model.deviceReported(dataSourceID: 0,
                             state: state(audio: stage2Capable | SecondPortState.audioRefusedFlag))
        #expect(model.displayedSelection == .port1 && model.pending == nil && model.canChoose)
    }

    @Test("pick 64, accepted: the display becomes 64 when the device says so")
    func pickAccepted() {
        var model = PortSelectionModel()
        model.deviceReported(dataSourceID: 0, state: state(audio: stage2Capable))
        _ = model.userChose(.ports1And2)
        #expect(model.displayedSelection == .port1)
        model.deviceReported(dataSourceID: 1,
                             state: state(audio: stage2Capable | SecondPortState.audioActiveFlag))
        #expect(model.displayedSelection == .ports1And2 && model.pending == nil && model.canChoose)
    }

    @Test("an unanswered request expires and the picker is usable again")
    func expiry() {
        var model = PortSelectionModel()
        model.deviceReported(dataSourceID: 0, state: state(audio: stage2Capable))
        _ = model.userChose(.ports1And2)
        model.requestExpired()
        #expect(model.displayedSelection == .port1 && model.canChoose)
    }
}
