import Foundation
import Testing
import MaestroCore
@testable import MaestroApp

/// The installer and the app look for the same Apogee MkI components, and the
/// app surfaces what it finds where the owner asked for it.
@Suite("Original Apogee driver check: installer, app and Help agree")
struct OriginalApogeeDriversWiringTests {
    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func file(_ relative: String) throws -> String {
        try String(contentsOf: Self.appRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test("preinstall checks every component the app checks")
    func preinstallMatchesDetector() throws {
        let preinstall = try file("../../Installer/scripts-core/preinstall")
        for component in OriginalApogeeDrivers.components {
            let name = URL(fileURLWithPath: component.path).lastPathComponent
            #expect(preinstall.contains("\"\(name)\""), "\(name)")
        }
        for id in OriginalApogeeDrivers.kernelExtensionBundleIDs {
            #expect(preinstall.contains("\"\(id)\""), "\(id)")
        }
        #expect(preinstall.contains("kmutil"))
        #expect(preinstall.contains("Restart your Mac"))
    }

    @Test("preinstall and the app name the same ThunderBridge and PCIe kernel drivers, and the same update sentence")
    func sameKernelDriversAndUpdateNote() throws {
        let preinstall = try file("../../Installer/scripts-core/preinstall")
        let ids = OriginalApogeeDrivers.pciKernelExtensionBundleIDs.map { "\"\($0)\"" }.joined(separator: " ")
        #expect(preinstall.contains("APOGEE_PCIE_KEXT_IDS=(\(ids))"))
        // The same idea in both, each in its own tense.
        let shared = "because this version now checks for Apogee's original driver, and it found it on this Mac."
        #expect(preinstall.contains("UPDATE_NOTE=\"You are seeing this while updating \(shared) Your current Maestro is unchanged.\""))
        #expect(ApogeeDriverConflict.updateNote.contains(shared))
        // Maestro's own removal commands are never the installer's advice.
        #expect(!preinstall.contains("clear-staging") && !preinstall.contains("kmutil rebuild"))
        #expect(preinstall.contains(OriginalApogeeDrivers.releaseDMGURL.absoluteString))
    }

    @Test("No driver request while Apogee's kernel driver is loaded: one gate, before every submit")
    func activationGate() throws {
        let source = try file("MaestroApp/SystemExtensionInstaller.swift")
        // One place submits a request, and the check comes before it.
        #expect(source.components(separatedBy: "OSSystemExtensionManager.shared.submitRequest(").count - 1 == 1)
        #expect(source.components(separatedBy: "OSSystemExtensionRequest.activationRequest(").count - 1 == 1)
        let activate = try #require(source.range(of: "public func activate() {"))
        let gate = try #require(source.range(of: "switch Self.admission(dextBundled: isDextBundled, "
            + "requestInFlight: activationRequestInFlight,\n                              conflict: currentApogeeConflict) {",
            range: activate.upperBound..<source.endIndex))
        let held = try #require(source.range(of: "case .heldForApogeeDriver:", range: gate.upperBound..<source.endIndex))
        let submit = try #require(source.range(of: "OSSystemExtensionManager.shared.submitRequest("))
        #expect(held.upperBound < submit.lowerBound)
        // The held case leaves before the request is made.
        #expect(source[held.upperBound..<submit.lowerBound].contains("            return\n        case .alreadyInFlight:"))
        // Nothing in the app deactivates, retires or stops the driver.
        for name in ["SystemExtensionInstaller.swift", "DriverHandover.swift", "AppState.swift", "AppShell.swift",
                     "SettingsViews.swift"] {
            let text = try file("MaestroApp/\(name)")
            #expect(!text.contains("deactivationRequest("), "\(name)")
        }
        // The banner for this state replaces the ones that say to activate or replug.
        let shell = try file("MaestroApp/AppShell.swift")
        let banner = try #require(shell.range(of: "private var visibleThunderBridgeBanner"))
        let ours = try #require(shell.range(of: "appState.apogeeDriverConflict?.banner", range: banner.upperBound..<shell.endIndex))
        let theirs = try #require(shell.range(of: "thunderBridgeReport.thunderBridgeBanner", range: banner.upperBound..<shell.endIndex))
        #expect(ours.lowerBound < theirs.lowerBound)
        #expect(try file("MaestroApp/SettingsViews.swift")
            .contains("OriginalApogeeDriversWarning(finding: found, conflict: appState.apogeeDriverConflict)"))
    }

    @Test("A call to activate: held while Apogee's kernel driver is loaded, whatever else is true")
    func admission() {
        typealias I = SystemExtensionInstaller
        func decision(loaded: Bool) -> ApogeeDriverConflict.Decision {
            ApogeeDriverConflict.decide(kextLoaded: loaded, copyOnDisk: true, maestroDriverActive: true,
                                        updatePending: true)
        }
        for inFlight in [false, true] {
            #expect(I.admission(dextBundled: true, requestInFlight: inFlight) { decision(loaded: true) }
                == .heldForApogeeDriver)
        }
        #expect(I.admission(dextBundled: true, requestInFlight: false) { decision(loaded: false) } == .submit)
        #expect(I.admission(dextBundled: true, requestInFlight: true) { decision(loaded: false) } == .alreadyInFlight)
        // No driver in the app: nothing to hold, and nothing is looked up.
        var asked = 0
        #expect(I.admission(dextBundled: false, requestInFlight: false) { asked += 1; return decision(loaded: true) }
            == .notBundled)
        #expect(asked == 0)
    }

    @Test("What sysextd's records say: active when enabled, update pending when a registered build differs")
    func conflictInputs() {
        func dext(_ build: String, enabled: Bool = true, uninstalling: Bool = false) -> InstalledDextInfo {
            InstalledDextInfo(bundleVersion: build, bundleShortVersion: "0.11.14", isEnabled: enabled,
                              isAwaitingUserApproval: false, isAwaitingReboot: false, isUninstalling: uninstalling)
        }
        typealias I = SystemExtensionInstaller
        #expect(I.conflictInputs(registered: nil, bundledBuild: "140") == (false, false))
        #expect(I.conflictInputs(registered: [], bundledBuild: "140") == (false, false))
        #expect(I.conflictInputs(registered: [dext("140")], bundledBuild: "140") == (true, false))
        #expect(I.conflictInputs(registered: [dext("123")], bundledBuild: "140") == (true, true))
        #expect(I.conflictInputs(registered: [dext("123"), dext("140")], bundledBuild: "140") == (true, true))
        #expect(I.conflictInputs(registered: [dext("140", enabled: false)], bundledBuild: "140") == (false, false))
        #expect(I.conflictInputs(registered: [dext("123", uninstalling: true)], bundledBuild: nil) == (false, false))
    }

    @Test("Warning page, Help and the app use the same Release 5.5 download")
    func sameDownload() throws {
        let url = OriginalApogeeDrivers.releaseDMGURL.absoluteString
        #expect(try file("../../Installer/resources/warning.html").contains(url))
        #expect(try file("MaestroApp/HelpView.swift").contains("Can I keep Apogee's original drivers installed?"))
    }

    @Test("Last resort: in the user guide (collapsed) and the app, never in the installer")
    func manualStepsPlacement() throws {
        let guide = try file("../../docs/UserManual.md")
        let section = try #require(guide.range(of: "## Removing Apogee's original drivers"))
        // Two collapsed blocks, in this order: what to try when the warning
        // survives the uninstaller, then the last resort.
        let details = try #require(guide.range(of: "<details>", range: section.upperBound..<guide.endIndex))
        #expect(guide[details.upperBound...].hasPrefix("\n<summary>If the warning is still there after uninstalling and restarting</summary>"))
        for command in OriginalApogeeDrivers.stillThereCommands {
            #expect(guide.contains("```\n\(command)\n```"), "\(command)")
        }
        // Offered as a user's feedback, untested, with their report linked.
        #expect(guide.contains("We have not tested them."))
        #expect(guide.contains(OriginalApogeeDrivers.userReportURL.absoluteString))
        #expect(guide.contains(OriginalApogeeDrivers.stillThereCaveat + "\n"))
        let lastResort = try #require(guide.range(of: "<details>", range: details.upperBound..<guide.endIndex))
        #expect(guide[lastResort.upperBound...].hasPrefix("\n<summary>\(ManualApogeeRemovalSteps.title)</summary>"))
        #expect(guide.contains(OriginalApogeeDrivers.manualRemovalIntro + "\n"))
        for part in OriginalApogeeDrivers.manualRemovalParts {
            #expect(guide.contains("- \(part)\n"), "\(part)")
        }
        let warning = try file("../../Installer/resources/warning.html")
        let preinstall = try file("../../Installer/scripts-core/preinstall")
        for installer in [warning, preinstall] {
            #expect(!installer.contains("Background helpers"))
            #expect(installer.contains("Removing Apogee"))
            #expect(installer.contains("Uninstall also removes"))
        }
        #expect(warning.contains("docs/UserManual.md#removing-apogees-original-drivers"))
        // Help and the warning both carry the collapsed steps.
        #expect(try file("MaestroApp/HelpView.swift").contains("ManualApogeeRemovalSteps()"))
    }

    @Test("The screenshot preview: a sample finding in DEBUG, compiled out of release builds")
    func previewIsDebugOnly() throws {
        let key = AppState.originalApogeeDriversPreviewKey
        defer { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.set("installed", forKey: key)
        let installed = try #require(AppState.previewOriginalApogeeDrivers())
        #expect(!installed.isEmpty && !installed.isAwaitingRestartOnly)
        UserDefaults.standard.set("restart", forKey: key)
        #expect(AppState.previewOriginalApogeeDrivers()?.isAwaitingRestartOnly == true)
        UserDefaults.standard.removeObject(forKey: key)
        #expect(AppState.previewOriginalApogeeDrivers() == nil)
        // The only read of the key sits between #if DEBUG and #else, so a release
        // build (`swift build -c release`, Installer/build-installer.sh) cannot see it.
        let source = try file("MaestroApp/OriginalApogeeDriverCheck.swift")
        let body = try #require(source.range(of: "static func previewOriginalApogeeDrivers()"))
        let debug = try #require(source.range(of: "#if DEBUG", range: body.upperBound..<source.endIndex))
        let release = try #require(source.range(of: "#else\n        return nil\n        #endif", range: debug.upperBound..<source.endIndex))
        let read = try #require(source.range(of: "forKey: originalApogeeDriversPreviewKey", range: body.upperBound..<source.endIndex))
        #expect(debug.upperBound <= read.lowerBound && read.upperBound <= release.lowerBound)
        #expect(source.components(separatedBy: "originalApogeeDriversPreviewKey").count - 1 == 2) // declared, read once
        let build = try file("../../Installer/build-installer.sh")
        #expect(build.contains("swift build --package-path \"$REPO_ROOT/Apps/Maestro\" -c release"))
    }

    @Test("Device Settings shows the warning first, unredacted; checked at launch and on open; in the report")
    func wiring() throws {
        let settings = try file("MaestroApp/SettingsViews.swift")
        let form = try #require(settings.range(of: "Form {"))
        let warning = try #require(settings.range(of: "OriginalApogeeDriversWarning(finding:", range: form.upperBound..<settings.endIndex))
        let clock = try #require(settings.range(of: "clockSection", range: form.upperBound..<settings.endIndex))
        #expect(warning.lowerBound < clock.lowerBound)
        #expect(settings[warning.upperBound...].prefix(200).contains(".unredacted()"))
        #expect(settings.contains("appState.refreshOriginalApogeeDrivers()"))
        #expect(try file("MaestroApp/AppShell.swift").contains("appState.refreshOriginalApogeeDrivers()"))
        let diagnostics = try file("MaestroApp/Diagnostics.swift")
        #expect(diagnostics.contains("blocks.append(originalApogeeDrivers.reportText)"))
        // No dismiss button: it goes away when they do. Its only control
        // besides the disclosure is the download link.
        let source = try file("MaestroApp/OriginalApogeeDriverCheck.swift")
        let view = try #require(source.range(of: "struct OriginalApogeeDriversWarning: View {"))
        let end = try #require(source.range(of: "struct ManualApogeeRemovalSteps: View {"))
        let warningView = source[view.upperBound..<end.lowerBound]
        #expect(!warningView.contains("Button"))
        #expect(warningView.contains("Link(destination: OriginalApogeeDrivers.releaseDMGURL)"))
        #expect(warningView.contains("ManualApogeeRemovalSteps()"))
    }
}
