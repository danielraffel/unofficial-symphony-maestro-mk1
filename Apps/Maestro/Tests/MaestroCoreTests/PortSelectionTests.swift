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

    @Test("the two entries are the original's, in its order, with its names and IDs")
    func entries() {
        // og_source/symphonymk1/ext/Symphony64/SymphonyAPI/SymphonyCommon.h:182-183
        #expect(PortSelection.allCases == [.port1, .ports1And2])
        #expect(PortSelection.port1.name == "Port 1: 32ch")
        #expect(PortSelection.ports1And2.name == "Port 1-2: 64ch")
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

    @Test("a refused request comes back as 32 channels with the driver's reason")
    func refused() {
        var model = PortSelectionModel()
        model.deviceReported(dataSourceID: 0, state: state(audio: stage2Capable))
        #expect(model.userChose(.ports1And2) == 1)
        model.deviceReported(dataSourceID: 1, state: state(audio: stage2Capable))
        // The driver could not do it: reason 1, nothing on port 2.
        let refusedWord = stage2Capable | SecondPortState.audioRefusedFlag | (1 << 8)
        model.deviceReported(dataSourceID: 0, state: state(audio: refusedWord))
        #expect(model.selection == .port1 && model.pending == nil)
        #expect(model.notice == "64 channels refused: there is no unit with its link up on port 2.")
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
        #expect(model.notice == "Went back to 32 channels: port 2's unit clock went away.")
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
                == ["Experimental two-port driver", "Port 2 Link", "Port 2 Clock", "Port 2 Units"])
        #expect(state.deviceInfoRows[0].value == SecondPortState.experimentValue)
        #expect(!state.rawText.contains("audio="))
    }

    @Test("rows and copied text with stage 2")
    func rows() {
        let off = SecondPortState(portCount: 2, flags: 0x0F, audio: 0x01)
        #expect(off.deviceInfoRows.map(\.label)
                == ["Experimental two-port driver", "Port 2 Audio", "Port 2 Link", "Port 2 Clock", "Port 2 Units"])
        #expect(off.deviceInfoRows[0].value == "On. Port 2 carries audio when \"Port 1-2: 64ch\" is selected.")
        #expect(off.deviceInfoRows[1].value == "Off: 32 channels, port 1 only")
        let on = SecondPortState(portCount: 2, flags: 0x0F, audio: 0x0001_0007, phase: 0x8010_010B)
        #expect(on.deviceInfoRows.map(\.label).prefix(3) == ["Experimental two-port driver", "Port 2 Audio", "Port 2 Phase"])
        #expect(on.deviceInfoRows[1].value == "On: 64 channels, 33-64 are port 2 (Core Audio has not switched yet)")
        #expect(on.deviceInfoRows[2].value == "Aligned, jam 0x0b; 1 unit read")
        #expect(on.reportLines.last?.hasSuffix(" audio=0x00010007 phase=0x8010010b") == true)
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
