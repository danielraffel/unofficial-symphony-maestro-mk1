import Foundation
import MaestroCore
import Testing
@testable import MaestroApp

@Suite("Setup document and level overlay")
struct SetupDocumentAndOverlayTests {
    @Test("Title uses the file name without extension")
    func title() {
        #expect(SetupDocumentTitle.title(for: nil) == "Maestro")
        #expect(SetupDocumentTitle.title(for: URL(fileURLWithPath: "/tmp/Studio.mst2")) == "Studio")
    }

    @Test("Stored setup edits mark the document")
    func editKinds() {
        #expect(Set(SetupEditKind.allCases.filter(\.marksDocumentEdited)) ==
            [.routing, .mixer, .inputChannelSettings, .outputChannelSettings, .monitorControls, .deviceSettings])
        #expect(Set(SetupEditKind.allCases.filter { !$0.marksDocumentEdited }) ==
            [.presetRecallOrStore, .loopSync, .clockSource, .sampleRate, .vBus, .identify, .meterClear])
    }

    @Test("Close asks only for an edited document with a file")
    func closeDecision() {
        #expect(SetupDocumentDecision.forClose(edited: true, hasCurrentFile: true) == .askToSave)
        #expect(SetupDocumentDecision.forClose(edited: true, hasCurrentFile: false) == .proceed)
        #expect(SetupDocumentDecision.forClose(edited: false, hasCurrentFile: true) == .proceed)
        #expect(SetupDocumentDecision.forClose(edited: false, hasCurrentFile: false) == .proceed)
    }

    @Test("Overlay bars are clamped to sixteen")
    func bars() {
        #expect(LevelOverlayMath.filledBars(level: -64, range: -64...0) == 0)
        #expect(LevelOverlayMath.filledBars(level: -32, range: -64...0) == 8)
        #expect(LevelOverlayMath.filledBars(level: 1, range: -64...0) == 16)
        #expect(LevelOverlayMath.filledBars(level: -100, range: -64...0) == 0)
        #expect(LevelOverlayMath.filledBars(level: 32.5, range: 0...65) == 8)
        #expect(LevelOverlayMath.filledBars(level: .nan, range: 0...65) == 0)
    }

    @Test("Front-panel changes show the overlay, while Mac volume adoption is excluded")
    func sources() {
        #expect(LevelOverlayChangeSource.frontPanel.showsOverlay)
        #expect(LevelOverlayChangeSource.maestroControl.showsOverlay)
        #expect(LevelOverlayChangeSource.macVolume.showsOverlay)
        #expect(!LevelOverlayChangeSource.maestroUSBVolume.showsOverlay)
        #expect(!LevelOverlayChangeSource.launch.showsOverlay)
        #expect(!LevelOverlayChangeSource.restore.showsOverlay)
    }

    @Test("8MicPre overlay uses the input strip's group and input type")
    func micPreGroup() {
        var strip = InputChannelState()
        strip.inputType = AnalogInputLevel.instrument.rawValue
        strip.group = 2
        #expect(LevelOverlaySource.micPre(channel: 2, state: strip) ==
            .micPre(channel: 2, grouped: true, level: .instrument))
        strip.group = InputChannelLogic.groupOff
        #expect(LevelOverlaySource.micPre(channel: 2, state: strip) ==
            .micPre(channel: 2, grouped: false, level: .instrument))
    }
}
