import Foundation
import Testing
@testable import MaestroApp
import MaestroCore
import MaestroDevice

/// 0.9.10 final review, finding 2: while hardware writes are suspended (sleep,
/// wake validation) an edit would be saved and shown but never sent, and
/// nothing replays it. The pages are disabled then, and an edit that still
/// gets through is neither saved nor left on screen.
extension StandardDefaultsSuites {
@Suite("Edits while hardware writes are suspended", .serialized)
@MainActor
struct SuspendedEditsTests {
    @Test func noteFollowsTheSleepStateWithTheStatusBarWords() {
        let state = AppState()
        #expect(state.hardwareSuspendedNote == nil)
        state.hardwareSleepState = .sleeping
        #expect(state.hardwareSuspendedNote == "Hardware sleeping")
        #expect(state.endpointStatusMessage == "Hardware sleeping")
        state.hardwareSleepState = .validating
        #expect(state.hardwareSuspendedNote == "Validating hardware after wake…")
        #expect(state.endpointStatusMessage == "Validating hardware after wake…")
        state.hardwareSleepState = .awake
        #expect(state.hardwareSuspendedNote == nil)
    }

    /// Card present, no unit answering: the status bar shows the short text
    /// and the whole Apogee message stays available for the tooltip and the
    /// info button's pop-up, naming the card.
    @Test func statusBarShowsTheShortPortMessageAndKeepsTheFullOne() {
        let state = AppState()
        state.connectionMode = .disconnected
        state.transportType = .thunderbolt
        state.transportPresent = true
        state.thunderboltCardPhrase = "the Symphony 64 PCIe card"
        state.thunderboltPortLink = .noHardware
        #expect(state.endpointStatusMessage == "No hardware detected")
        #expect(state.portStatusMessage
                == "No hardware has been detected on the primary port of the Symphony 64 PCIe card.\n"
                + "Verify that the hardware is properly connected and powered on.")
        state.thunderboltBothPortsInUse = true
        #expect(state.endpointStatusMessage == "No hardware detected on port 1")
        state.thunderboltPortLink = .busError
        #expect(state.endpointStatusMessage == "Bus error on port 1")
        state.thunderboltBothPortsInUse = false
        #expect(state.endpointStatusMessage == "Bus error")
        #expect(state.portStatusMessage
                == "A bus error has occurred on the Primary port of the Symphony 64 PCIe card.\n"
                + "Verify that the hardware is properly connected and powered on.")
        // Not one of the two messages: unchanged.
        state.thunderboltPortLink = .other
        #expect(state.portStatusMessage == nil)
        #expect(state.endpointStatusMessage == state.connectionPresentation.endpointLabel)
    }

    /// The info button after the short text: the About Clock Status / Ports /
    /// VBus pop-up, showing the whole message.
    @Test func statusBarInfoButtonShowsTheWholeMessage() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MaestroApp/MonitorViews.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        let start = try #require(source.range(of: "if let fullMessage = appState.portStatusMessage {"))
        let block = String(source[start.lowerBound...].prefix(1200))
        #expect(block.contains("Image(systemName: \"info.circle\")"))
        #expect(block.contains(".accessibilityLabel(PortStatusMessage.infoLabel)"))
        #expect(block.contains(".maestroHelp(fullMessage)"))
        #expect(block.contains(".popover(isPresented: $showPortMessageInfo, arrowEdge: .bottom)"))
        #expect(block.contains("Text(fullMessage)"))
        #expect(block.contains(".multilineTextAlignment(.leading)"))
        #expect(block.contains(".frame(width: 340, alignment: .leading)"))
    }

    @Test func everyDevicePageButAppSettingsIsDisabledWhileSuspended() {
        let state = AppState()
        for area in NavigationArea.allCases {
            #expect(DetailView.suspendedNote(area: area, appState: state) == nil)
        }
        state.hardwareSleepState = .validating
        for area in NavigationArea.allCases {
            let note = DetailView.suspendedNote(area: area, appState: state)
            #expect(note == (area == .appSettings ? nil : "Validating hardware after wake…"), "\(area)")
        }
    }

    @Test(arguments: [AppState.HardwareSleepState.sleeping, .validating])
    func mixerEditWhileSuspendedIsNeitherSavedNorShown(sleep: AppState.HardwareSleepState) async {
        let defaults = UserDefaults.standard
        let before = defaults.dictionaryRepresentation()
        defer {
            for key in defaults.dictionaryRepresentation().keys where before[key] == nil {
                defaults.removeObject(forKey: key)
            }
            for (key, value) in before { defaults.set(value, forKey: key) }
        }
        let mixer = 0
        let state = AppState()
        state.connectionMode = .hardware
        state.transportType = .thunderbolt
        let connection = SimulatedDevice.symphonyIO32ch()
        state.device = connection
        let identity: UInt64 = 0xF1605678
        await state.resolveUnitIdentity(for: .a, connection: connection) { identity }
        let store = state.channelStateStore
        let strip = MixerChannelState(level: -13, pan: 0.25, isMuted: false, isSoloed: false)
        store.save([strip], for: ChannelStateStore.mixerKey(mixer))
        state.mixerPreferences.set(-24.0, forKey: "mixerMasterLevel_\(mixer)")

        var editor = MixerEditorState(appState: state, selectedMixer: mixer)
        #expect(editor.canEdit(state))

        state.hardwareSleepState = sleep
        #expect(!editor.canEdit(state))
        // The binding has already changed the local copy when the handler runs.
        editor.channels[0].isMuted = true
        editor.masterLevel = -3
        editor.save(appState: state, selectedMixer: mixer)
        // Not saved...
        let saved: [MixerChannelState]? = store.load(ChannelStateStore.mixerKey(mixer))
        #expect(saved?.first?.isMuted == false)
        #expect(state.mixerPreferences.object(forKey: "mixerMasterLevel_\(mixer)") as? Double == -24)
        // ...and not left on screen.
        #expect(editor.channels.first?.isMuted == false)
        #expect(editor.masterLevel == -24)

        // Awake again: the same editor saves as before.
        state.hardwareSleepState = .awake
        #expect(editor.canEdit(state))
        editor.channels[0].isMuted = true
        editor.save(appState: state, selectedMixer: mixer)
        let after: [MixerChannelState]? = store.load(ChannelStateStore.mixerKey(mixer))
        #expect(after?.first?.isMuted == true)
    }
}
}
