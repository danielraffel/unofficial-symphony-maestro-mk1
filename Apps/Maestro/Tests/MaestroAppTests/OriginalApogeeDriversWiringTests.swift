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
        let details = try #require(guide.range(of: "<details>", range: section.upperBound..<guide.endIndex))
        #expect(guide[details.upperBound...].hasPrefix("\n<summary>\(ManualApogeeRemovalSteps.title)</summary>"))
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
