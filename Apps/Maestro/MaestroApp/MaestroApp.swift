/// MaestroApp — Apogee Maestro for Symphony MKI (macOS)
///
/// SwiftUI-based control application for Apogee Symphony I/O MKI USB.
/// Replaces the legacy Maestro 2 Obj-C/XIB app with a modern Swift UI.
///
/// Evidence: `og_source/maestro2/App/Controllers/APApplicationDelegate.m`
/// Evidence: `og_source/maestro2/App/Views/APMaestroFullViewWindow.m`

import SwiftUI
import AppKit
import ApplicationServices
import CoreAudio
import CoreGraphics
import MaestroCore
import MaestroDevice


// MARK: - App Entry Point

struct MaestroApp: App {
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(MaestroAppDelegate.self) private var appDelegate
    @StateObject private var updates = UpdateController()
    @State private var appState = MaestroApp.makeAppState()
    @State private var diagnostics = DiagnosticsRecorder()
    @State private var presetLibrary = PresetLibrary.shared

    /// The one-time routing and mixer reset (0.9.21, `RoutingMixerReset`) runs
    /// before `AppState` exists, so nothing has read the saved state it removes.
    private static func makeAppState() -> AppState {
        if RoutingMixerReset.runIfNeeded(defaults: .standard) {
            print("[Maestro] Output Routing, Input Routing, converter routing and both mixers reset to defaults (one time, 0.9.21)")
        }
        return AppState()
    }

    init() {
        // Disable stdout buffering so log output appears immediately when
        // redirecting to a file (e.g. MaestroApp > log.txt 2>&1).
        setbuf(stdout, nil)

        // When launched via `swift run` (bare executable, not .app bundle),
        // macOS defaults to accessory activation — no Dock icon, no menu bar.
        // Only activate for bare executables — .app bundles handle activation
        // normally via macOS, and we don't want LaunchAgent-triggered launches
        // to steal focus repeatedly.
        if let app = NSApp,
           !(Bundle.main.bundlePath.hasSuffix(".app")) {
            app.setActivationPolicy(.regular)
            app.activate(ignoringOtherApps: true)
        }

        // Activate the embedded ThunderBridge driver extension — but ONLY when the ThunderBridge
        // PCIe card is actually present (checked now + watched for hotplug). USB-only Macs never
        // have this card, so the driver stays dormant and they're never asked to approve a system
        // extension they don't need. First activation on a TB machine needs user approval in
        // System Settings > General > Login Items & Extensions > Driver Extensions.
        SystemExtensionInstaller.shared.onStatusChange = { status in
            switch status {
            case .notBundled:          break
            case .activating:          print("[Maestro] Driver extension: activating...")
            case .needsUserApproval:   print("[Maestro] Driver extension: approve in System Settings > General > Login Items & Extensions")
            case .activated:           print("[Maestro] Driver extension: activated")
            case .willCompleteAfterReboot: print("[Maestro] Driver extension: reboot to finish activation")
            case .upgradePending:      print("[Maestro] Driver extension: upgrade pending; reconnect ThunderBridge")
            case .heldForApogeeDriver: print("[Maestro] Driver extension: not requested; Apogee's kernel driver for the card is loaded")
            case .failed(let why):     print("[Maestro] Driver extension: activation failed — \(why)")
            }
        }
        SystemExtensionInstaller.shared.activateWhenThunderBridgePresent()
    }

    var body: some Scene {
        Window("Maestro", id: "main") {
            ContentView()
                .environment(appState)
                .environmentObject(updates)
                .onReceive(updates.$effectiveChannel) { appState.updateChannel = $0 }
                .environment(diagnostics)
                .onChange(of: appState.initialSetupRestoreFinished) { _, ready in
                    if ready { appDelegate.openPendingSetup() }
                }
                .onAppear {
                    appDelegate.showMainWindow = showMainWindow
                    appDelegate.appState = appState
                    diagnostics.appState = appState
                    // Testing only: `-MaestroDiagnosticsSelfTest 20` turns
                    // diagnostics on, adds a note, runs the checks again and
                    // saves after that many seconds. It never sends unless
                    // `-MaestroDiagnosticsSelfTestSend "<note>"` is also given,
                    // which sends one report (an email to the developer).
                    let seconds = UserDefaults.standard.integer(forKey: "MaestroDiagnosticsSelfTest")
                    guard seconds > 0, !diagnostics.isRecording else { return }
                    diagnostics.start()
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(min(5, seconds / 2)))
                        diagnostics.addNote("self-test note")
                        diagnostics.runChecksNow()
                        try? await Task.sleep(for: .seconds(max(1, seconds - min(5, seconds / 2))))
                        await diagnostics.stopAndSave()
                        guard let note = UserDefaults.standard.string(forKey: "MaestroDiagnosticsSelfTestSend"),
                              let file = diagnostics.lastSaved else { return }
                        guard let sender = DiagnosticsSender.configured else {
                            print("[Maestro] Diagnostics self-test send: not configured"); return
                        }
                        do {
                            let ref = try await sender.send(report: file, message: .init(
                                note: note, issue: "", contact: "",
                                version: MaestroCore.version, channel: appState.updateChannel?.rawValue.capitalized ?? ""))
                            print("[Maestro] Diagnostics self-test send: ok reference=\(ref)")
                        } catch {
                            print("[Maestro] Diagnostics self-test send: failed \(DiagnosticsSender.userMessage(for: error)) (\(error))")
                        }
                    }
                }
                .frame(minWidth: 800, minHeight: 500)
        }
        .handlesExternalEvents(matching: [])
        .defaultSize(width: 1440, height: 700)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit Maestro", action: appDelegate.quitFromMenu)
                    .keyboardShortcut("q", modifiers: .command)
            }

            // About box
            CommandGroup(replacing: .appInfo) {
                Button("About Maestro") {
                    appState.showAbout = true
                }
            }

            CommandGroup(after: .appInfo) {
                Button("Check for Updates…", action: updates.checkForUpdates)
                    .disabled(!updates.canCheckForUpdates)
            }

            CommandGroup(after: .textEditing) {
                Button("Select All") {
                    guard !(NSApp.keyWindow?.firstResponder is NSTextField), !(NSApp.keyWindow?.firstResponder is NSTextView) else { return }
                    NotificationCenter.default.post(name: .mixerSelectAll, object: nil)
                }
                .keyboardShortcut("a", modifiers: .command)
                .disabled(appState.selectedArea != .mixer)

                Button("Deselect All") {
                    guard !(NSApp.keyWindow?.firstResponder is NSTextField), !(NSApp.keyWindow?.firstResponder is NSTextView) else { return }
                    NotificationCenter.default.post(name: .mixerDeselectAll, object: nil)
                }
                .keyboardShortcut("d", modifiers: [.shift])
                .disabled(appState.selectedArea != .mixer)
            }

            // View menu — toggle monitor panel, trims, clear meters
            CommandGroup(after: .toolbar) {
                Button({
                    switch appState.selectedArea {
                    case .output: return appState.showOutputTrims ? "Hide Trims" : "Show Trims"
                    default:      return appState.showInputTrims  ? "Hide Trims" : "Show Trims"
                    }
                }()) {
                    switch appState.selectedArea {
                    case .input:  appState.showInputTrims.toggle()
                    case .output: appState.showOutputTrims.toggle()
                    default: break
                    }
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(appState.selectedArea != .input && appState.selectedArea != .output)

                Divider()

                Button("Clear Meters") {
                    appState.clearMeters()
                }
                .keyboardShortcut("k", modifiers: [.command])
                .disabled(appState.hardwareWritesSuspended)
                .maestroHelp("Clear all peak hold and over indicators (Cmd+K).")
            }

            // File menu — preset save / load (P3F-31, P3F-53)
            // Evidence: og_source/maestro2/App/APDocument.m — storeMaestroPreferenceFile:/recallMaestroPreferenceFile:
            CommandGroup(replacing: .saveItem) {
                // Replacing this group removes the system's Close item, so it is
                // put back. Closing the window does not quit Maestro: it keeps
                // following the Symphony, restores settings when the unit
                // reconnects, and reopens from the Dock.
                Button("Close Window") {
                    NSApp.keyWindow?.performClose(nil)
                }
                .keyboardShortcut("w")

                Divider()

                Button("Save") {
                    Task { await appState.saveCurrentSetup() }
                }
                .keyboardShortcut("s")

                Button("Save As...") {
                    Task { await appState.saveCurrentSetup(showPanel: true) }
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Button("Open Preset...") {
                    let panel = NSOpenPanel()
                    panel.title = "Open Maestro Preset"
                    panel.allowedContentTypes = [.maestroSetup]
                    panel.allowsMultipleSelection = false
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = true  // .mst2 bundles are directories
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    Task { await appState.openSetupFromUser(url) }
                }
                .keyboardShortcut("o")
                .disabled(appState.hardwareWritesSuspended)

                Divider()

                Button("Rescan") {
                    Task { await appState.reconnectHardware() }
                }
                .keyboardShortcut("r", modifiers: [.command])
                .maestroHelp("Re-establish the link to Symphony. Use this when the unit "
                      + "is connected and powered on but Maestro has not found it.")
            }

            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appState.selectedArea = .appSettings
                    showMainWindow()
                }
                .keyboardShortcut(",")
            }

            CommandGroup(after: .windowArrangement) {
                Button("Maestro", action: showMainWindow)
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }

            // Presets menu — named preset library (P3F-32)
            // Evidence: og_source/maestro2/App/APPresetManagerWindowController.m
            CommandMenu("Presets") {
                Button("Save as Preset...") {
                    Task { @MainActor in
                        let alert = NSAlert()
                        alert.messageText = "Save Preset"
                        alert.informativeText = "Enter a name for this preset:"
                        alert.addButton(withTitle: "Save")
                        alert.addButton(withTitle: "Cancel")
                        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
                        tf.placeholderString = "My Preset"
                        alert.accessoryView = tf
                        alert.window.initialFirstResponder = tf
                        guard alert.runModal() == .alertFirstButtonReturn else { return }
                        let name = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else { return }
                        do {
                            // Save full hardware state via daemon bundle format (same as Save Preset...)
                            try await appState.savePresetBundle(to: presetLibrary.url(for: name), associateWithDocument: false)
                            presetLibrary.refresh()
                        } catch {
                            let err = NSAlert()
                            err.messageText = "Could not save preset"
                            err.informativeText = error.localizedDescription
                            err.runModal()
                        }
                    }
                }

                Divider()

                if presetLibrary.names.isEmpty {
                    Button("No Saved Presets") {}.disabled(true)
                } else {
                    ForEach(presetLibrary.names, id: \.self) { name in
                        Button(name) {
                            Task { @MainActor in
                                do {
                                    // Supports both bundle format (daemon AERP) and legacy flat format
                                    try await appState.loadPresetBundle(from: presetLibrary.url(for: name), associateWithDocument: false)
                                } catch {
                                    print("[Maestro] Load preset '\(name)' failed: \(error)")
                                    NSAlert(error: error).runModal()
                                }
                            }
                        }
                        .disabled(appState.hardwareWritesSuspended)
                    }
                }

                Divider()

                Button("Manage Presets...") {
                    presetLibrary.openInFinder()
                }
            }

            // Navigate menu — Cmd+1..8 for sidebar tabs
            CommandMenu("Navigate") {
                ForEach(Array(NavigationArea.allCases.enumerated()), id: \.element) { index, area in
                    Button(area.rawValue) {
                        appState.selectedArea = area
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }

            // Help menu — user manual + legal pages
            CommandGroup(replacing: .help) {
                Button("Maestro Help") {
                    appState.openHelp()
                }
                .keyboardShortcut("?", modifiers: .command)

                Divider()

                // Opens Help's own section, which asks for diagnostics first
                // and links to the GitHub issue form from there.
                Button("Report a Bug…") { NSWorkspace.shared.open(appState.reportBugURL) }
                Button("Discuss on Gearspace…") { NSWorkspace.shared.open(FeedbackLinks.discussion) }

                Divider()

                Button("Terms of Service") {
                    openBundledOrRepoFile("Terms", extension: "html", repoSubpath: "Apps/Maestro/MaestroApp/Resources")
                }
                Button("Privacy Policy") {
                    openBundledOrRepoFile("Privacy", extension: "html", repoSubpath: "Apps/Maestro/MaestroApp/Resources")
                }
                Button("Acknowledgements") {
                    openBundledOrRepoFile("Acknowledgements", extension: "html", repoSubpath: "Apps/Maestro/MaestroApp/Resources")
                }
            }
        }

    }

    private func showMainWindow() {
        if let window = WindowDocumentBridge.currentWindow, window.isVisible || window.isMiniaturized {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }

    /// Open a file from the app bundle (deployed builds) or repo (dev builds).
    private func openBundledOrRepoFile(_ name: String, extension ext: String, repoSubpath: String) {
        if let url = Bundle.main.url(forResource: name, withExtension: ext) {
            NSWorkspace.shared.open(url)
            return
        }

        // In an unbundled development run, look for the checkout from the
        // current working directory without assuming a particular username
        // or private checkout location.
        var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<5 {
            let repoURL = directory.appendingPathComponent(repoSubpath)
                .appendingPathComponent("\(name).\(ext)")
            if FileManager.default.fileExists(atPath: repoURL.path) {
                NSWorkspace.shared.open(repoURL)
                return
            }
            directory.deleteLastPathComponent()
        }
    }
}
