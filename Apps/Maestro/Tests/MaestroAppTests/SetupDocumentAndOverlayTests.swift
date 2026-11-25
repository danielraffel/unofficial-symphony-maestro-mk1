import CoreServices
import Foundation
import MaestroCore
import MaestroDevice
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

    @MainActor
    @Test("Over USB an edit never marks the setup file; elsewhere it does")
    func usbNeverEdited() {
        let state = AppState()
        state.currentSetupURL = URL(fileURLWithPath: "/tmp/Studio.mst2")
        defer { state.currentSetupURL = nil }
        state.transportType = .usb
        state.markSetupEdited(.mixer)
        #expect(!state.setupDocumentEdited)
        state.transportType = .thunderbolt
        state.markSetupEdited(.mixer)
        #expect(state.setupDocumentEdited)
    }

    @Test("Close asks only for an edited document with a file")
    func closeDecision() {
        #expect(SetupDocumentDecision.forClose(edited: true, hasCurrentFile: true) == .askToSave)
        #expect(SetupDocumentDecision.forClose(edited: true, hasCurrentFile: false) == .proceed)
        #expect(SetupDocumentDecision.forClose(edited: false, hasCurrentFile: true) == .proceed)
        #expect(SetupDocumentDecision.forClose(edited: false, hasCurrentFile: false) == .proceed)
    }

    @Test("Quit asks only for the app menu with an edited document and a file",
          arguments: SetupQuitReason.allCases)
    func quitDecision(reason: SetupQuitReason) {
        for edited in [false, true] {
            for hasFile in [false, true] {
                let expected: SetupDocumentDecision = reason == .appMenu && edited && hasFile ? .askToSave : .proceed
                #expect(SetupDocumentDecision.forQuit(reason: reason, edited: edited, hasCurrentFile: hasFile) == expected)
            }
        }
    }

    @Test("Session Apple Events override an app-menu quit",
          arguments: [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAERestart, kAEShowShutdownDialog, kAEShutDown])
    func systemQuitReason(code: OSType) {
        #expect(SetupQuitReason(fromMenu: true, fromSignal: false, appleEventReason: code) == .systemSession)
    }

    @Test("Only the app menu initiates an interactive quit")
    func quitSource() {
        #expect(SetupQuitReason(fromMenu: true, fromSignal: false, appleEventReason: nil) == .appMenu)
        #expect(SetupQuitReason(fromMenu: false, fromSignal: false, appleEventReason: nil) == .external)
        #expect(SetupQuitReason(fromMenu: true, fromSignal: true, appleEventReason: nil) == .signal)
    }

    @MainActor
    @Test("A disconnected save replaces metadata and preserves the rest of an existing package",
          arguments: [false, true])
    func appOnlySave(retainedThunderBridge: Bool) async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }

        let package = root.appendingPathComponent("Studio.mst2", isDirectory: true)
        let extra = package.appendingPathComponent("Extra", isDirectory: true)
        try fm.createDirectory(at: extra, withIntermediateDirectories: true)
        let hardware = package.appendingPathComponent(ThunderboltPreset.fileName)
        let hidden = package.appendingPathComponent(".metadata")
        let nested = extra.appendingPathComponent("data")
        let metadata = package.appendingPathComponent("MaestroApp.plist")
        let original = Data("original".utf8)
        for url in [hardware, hidden, nested, metadata] { try original.write(to: url) }

        let state = AppState()
        if retainedThunderBridge {
            state.device = ThunderboltDeviceConnection(
                identifier: SimulatedDevice.symphonyIO32ch().identifier, audioDeviceID: 0)
            state.transportType = .thunderbolt
        } else {
            state.device = nil
        }
        state.connectionMode = .disconnected
        state.speakerLevel = -32
        try await state.savePresetBundle(to: package, associateWithDocument: false)

        for url in [hardware, hidden, nested] {
            #expect(try Data(contentsOf: url) == original)
        }
        let saved = try PropertyListDecoder().decode(MaestroPreset.self, from: Data(contentsOf: metadata))
        #expect(saved.outputLevel == -32)
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

    @Test("ThunderBridge Mac volume and Maestro controls show an overlay")
    func sources() {
        #expect(LevelOverlayChangeSource.frontPanel.showsOverlay)
        #expect(LevelOverlayChangeSource.maestroControl.showsOverlay)
        #expect(LevelOverlayChangeSource.macVolume.showsOverlay)
        #expect(!LevelOverlayChangeSource.maestroUSBVolume.showsOverlay)
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
