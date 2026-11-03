import SwiftUI
import AppKit
import ApplicationServices
import CoreAudio
import CoreGraphics
import MaestroCore
import MaestroDevice


// MARK: - Volume Popup

/// Floating volume overlay shown when media keys adjust speaker level.
// MARK: - Copy button glyph

/// A copy button's icon, which becomes a checkmark for a moment after a copy.
///
/// Both glyphs are laid out on top of each other with the unused one merely
/// transparent, so the swap cannot change the button's width. `checkmark` is
/// narrower than `doc.on.doc`, and letting the layout resize around it nudged the
/// version lines sideways every time someone pressed Copy.
struct CopyGlyph: View {
    let copied: Bool

    var body: some View {
        ZStack {
            Image(systemName: "doc.on.doc")
                .opacity(copied ? 0 : 1)
            Image(systemName: "checkmark")
                .foregroundStyle(.green)
                .opacity(copied ? 1 : 0)
        }
        .font(.caption)
        .accessibilityHidden(true)
    }
}

// MARK: - About View (P2C-05)

/// About panel.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @State private var showCopied = false

    var body: some View {
        VStack(spacing: 12) {
            // App icon from bundled resource
            if let iconURL = Bundle.main.url(forResource: "AppIconRounded", withExtension: "icns"),
               let iconImage = NSImage(contentsOf: iconURL) {
                Image(nsImage: iconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 96, height: 96)
            } else {
                Image(systemName: "hifispeaker.2")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
            }
            Text("Maestro")
                .font(.title)
                .fontWeight(.semibold)
            VStack(spacing: 2) {
                Text("Control App for")
                Text("Symphony I/O MK I")
            }
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            // Version and build are what someone quotes in a bug report, so they
            // need to be legible and copyable. They were .tertiary/.quaternary,
            // which renders the build line almost unreadable for no good reason.
            HStack(spacing: 6) {
                VStack(spacing: 2) {
                    Text("Version \(MaestroCore.version)")
                        .font(.caption)
                    if MaestroCore.buildNumber > 0 {
                        Text("Build \(MaestroCore.buildNumber) (\(MaestroCore.gitHash))")
                            .font(.caption2)
                    }
                }
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

                // Copies the WHOLE report - hardware and software - not just the two
                // lines shown above. One button to point someone at beats "open System
                // Setup and press both Copy buttons", which loses half the report.
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(appState.diagnosticsText, forType: .string)
                    showCopied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        showCopied = false
                    }
                } label: {
                    CopyGlyph(copied: showCopied)
                }
                .buttonStyle(.borderless)
                .help("Copy full device and software info for a bug report")
                .accessibilityLabel("Copy device and software info")
            }
            Divider()
            Button("OK") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 300)
        // An activation that finished after launch would otherwise be missing from the
        // report this box copies.
        .onAppear { appState.refreshInstalledDexts() }
    }

}

// MARK: - Auto-Launch Manager

/// Manages a LaunchAgent plist that triggers Maestro when a Symphony IO is plugged in.
///
/// Uses launchd's IOKitMatchingDictionary to detect USB device connection by VID/PID.
/// When the device is connected, launchd launches the Maestro app automatically.
///
/// Evidence: `og_source/maestrolink/Popup2.0/sources/Models/APAudioSystemModel.m` — legacy auto-launch
@MainActor
final class AutoLaunchManager {
    static let shared = AutoLaunchManager()

    private let agentLabel = "com.danielraffel.Maestro.autolaunch"
    private var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent("\(agentLabel).plist")
    }

    /// Whether the LaunchAgent is currently installed.
    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: agentURL.path)
    }

    /// Install or remove the LaunchAgent.
    func setEnabled(_ enabled: Bool) {
        if enabled {
            install()
        } else {
            uninstall()
        }
    }

    private func install() {
        // Ensure LaunchAgents directory exists
        let dir = agentURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Derive direct binary path from the .app bundle.
        // Launch via direct binary, not `open`: stdout/stderr then land in
        // /tmp/maestro.log, which is the only record of what the app did at startup.
        // (This used to be justified by a CGEvent tap. There is no tap — it was
        // removed in 55fe439; the volume keys are the ASP's VolumeControl.)
        let appBundlePath: String
        if let bundlePath = Bundle.main.bundlePath as String?,
           bundlePath.hasSuffix(".app") {
            appBundlePath = bundlePath
        } else {
            appBundlePath = "/Applications/Maestro.app"
        }
        let binaryPath = appBundlePath + "/Contents/MacOS/MaestroApp"

        // LaunchAgent plist — triggered by IOKit matching on the Symphony USB
        // products and the ThunderBridge PCI function. The PCI match is the
        // device/vendor word shown by ioreg for pci19c2,2200.
        // Logs to /tmp/maestro.log, same as manual deploy.sh launch.
        // ThrottleInterval prevents rapid re-launches on USB reconnect storms.
        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": [binaryPath],
            "StandardOutPath": "/tmp/maestro.log",
            "StandardErrorPath": "/tmp/maestro.log",
            "ThrottleInterval": 5,
            "LaunchEvents": [
                "com.apple.iokit.matching": [
                    "com.apogee.symphonyio.32ch": [
                        "IOProviderClass": "IOUSBHostDevice",
                        "idVendor": 0x0C60,
                        "idProduct": 0x0010
                    ] as [String: Any],
                    "com.apogee.symphonyio.16ch": [
                        "IOProviderClass": "IOUSBHostDevice",
                        "idVendor": 0x0C60,
                        "idProduct": 0x0011
                    ] as [String: Any],
                    "com.apogee.symphonyio.8ch": [
                        "IOProviderClass": "IOUSBHostDevice",
                        "idVendor": 0x0C60,
                        "idProduct": 0x0012
                    ] as [String: Any],
                    "com.apogee.symphonyio.thunderbridge": [
                        "IOProviderClass": "IOPCIDevice",
                        "IOPCIMatch": "0x220019c2"
                    ] as [String: Any]
                ] as [String: Any]
            ]
        ]

        let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try? data?.write(to: agentURL)

        // Load the agent into launchd
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["load", agentURL.path]
        try? task.run()
        task.waitUntilExit()
    }

    private func uninstall() {
        // Unload from launchd first
        if isInstalled {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            task.arguments = ["unload", agentURL.path]
            try? task.run()
            task.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: agentURL)
    }
}
