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

@main
struct MaestroApp: App {
    @StateObject private var updates = UpdateController()
    @State private var appState = AppState()
    @State private var presetLibrary = PresetLibrary.shared

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
            case .failed(let why):     print("[Maestro] Driver extension: activation failed — \(why)")
            }
        }
        SystemExtensionInstaller.shared.activateWhenThunderBridgePresent()
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environment(appState)
                .environmentObject(updates)
                .frame(minWidth: 800, minHeight: 500)
        }
        .defaultSize(width: 1440, height: 700)
        .commands {
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
                    Task {
                        do {
                            try await appState.device?.setProperty(
                                PropertyAddress(selector: .peaksClear), value: .uint32(1))
                        } catch {
                            print("[Maestro] ERROR: Clear Meters failed: \(error)")
                        }
                    }
                }
                .keyboardShortcut("k", modifiers: [.command])

                Divider()

                // Rescan — the original Maestro's Window-menu item, described in
                // the User's Guide p.73 as re-initialising "the link between
                // Maestro and Apogee hardware connected to the Mac, in the case
                // where the hardware is correctly connected and powered on but
                // not detected by Maestro".
                //
                // The underlying capability already existed as
                // `reconnectHardware()`, but both places it was exposed are
                // unreachable in precisely that situation: the Settings button
                // sits inside `if let device`, so it only appears once a device
                // is ALREADY connected, and the status-bar button only appears
                // when `hasConnectionIssue` is set. A user whose unit is powered
                // on but undetected had nothing to press. This is always
                // available.
                Button("Rescan") {
                    Task { await appState.reconnectHardware() }
                }
                .keyboardShortcut("r", modifiers: [.command])
                .help("Re-establish the link to Symphony. Use this when the unit "
                      + "is connected and powered on but Maestro has not found it.")
            }

            // File menu — preset save / load (P3F-31, P3F-53)
            // Evidence: og_source/maestro2/App/APDocument.m — storeMaestroPreferenceFile:/recallMaestroPreferenceFile:
            CommandGroup(replacing: .saveItem) {
                Button("Save Preset...") {
                    Task { @MainActor in
                        let panel = NSSavePanel()
                        panel.title = "Save Maestro Preset"
                        // .mst2 bundles are macOS packages (directories with .mst2 extension)
                        panel.allowedContentTypes = [.init(filenameExtension: "mst2")!]
                        panel.nameFieldStringValue = "Untitled.mst2"
                        guard panel.runModal() == .OK, let url = panel.url else { return }
                        do {
                            // Bundle format: daemon writes full hardware state via 'AESP'
                            // Evidence: APMaestroFullViewWindow.m:445 — storeMaestroPreferenceFile
                            try await appState.savePresetBundle(to: url)
                            print("[Maestro] Preset bundle saved to \(url.lastPathComponent)")
                        } catch {
                            print("[Maestro] ERROR: Save preset failed: \(error)")
                        }
                    }
                }
                .keyboardShortcut("s")

                Button("Open Preset...") {
                    Task { @MainActor in
                        let panel = NSOpenPanel()
                        panel.title = "Open Maestro Preset"
                        // Allow both bundles (directories) and legacy flat files
                        panel.allowedContentTypes = [.init(filenameExtension: "mst2")!]
                        panel.allowsMultipleSelection = false
                        panel.canChooseFiles = true
                        panel.canChooseDirectories = true  // .mst2 bundles are directories
                        guard panel.runModal() == .OK, let url = panel.urls.first else { return }
                        do {
                            // Supports both bundle format (daemon recall via 'AERP')
                            // and legacy flat format (our old single-file format)
                            // Evidence: APMaestroFullViewWindow.m:497 — recallMaestroPreferenceFile
                            try await appState.loadPresetBundle(from: url)
                            print("[Maestro] Preset loaded from \(url.lastPathComponent)")
                        } catch {
                            print("[Maestro] ERROR: Open preset failed: \(error)")
                        }
                    }
                }
                .keyboardShortcut("o")
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
                            try await appState.savePresetBundle(to: presetLibrary.url(for: name))
                            presetLibrary.refresh()
                        } catch {
                            let err = NSAlert()
                            err.messageText = "Could not save preset"
                            err.informativeText = error.localizedDescription
                            err.runModal()
                        }
                    }
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Divider()

                if presetLibrary.names.isEmpty {
                    Button("No Saved Presets") {}.disabled(true)
                } else {
                    ForEach(presetLibrary.names, id: \.self) { name in
                        Button(name) {
                            Task { @MainActor in
                                do {
                                    // Supports both bundle format (daemon AERP) and legacy flat format
                                    try await appState.loadPresetBundle(from: presetLibrary.url(for: name))
                                } catch {
                                    print("[Maestro] Load preset '\(name)' failed: \(error)")
                                }
                            }
                        }
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
                    appState.showHelp = true
                }
                .keyboardShortcut("?", modifiers: .command)

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
