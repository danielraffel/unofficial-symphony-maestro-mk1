import Foundation
import Testing
@testable import MaestroApp
import MaestroCore

/// The two settings pages: Device Settings (the Symphony I/O) and App Settings
/// (Maestro itself), their sidebar entries, their section order, and the words
/// the rest of the app uses to point at them.
@Suite("Settings pages")
struct SettingsPagesTests {
    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // MaestroAppTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // Apps/Maestro

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.appRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// The text of one top-level declaration, from its line to the next top-level one.
    private func declaration(_ start: String, in text: String) throws -> Substring {
        let begin = try #require(text.range(of: start))
        let tail = text[begin.upperBound...]
        let end = tail.range(of: "\n}\n")?.upperBound ?? tail.endIndex
        return text[begin.lowerBound..<end]
    }

    /// Section titles in source order: `Section("X")` and the first `Text("X")`
    /// of a `header:` closure.
    private func sectionTitles(_ text: Substring) throws -> [String] {
        let pattern = #"Section\("([^"]+)"\)|\} header: \{\s*(?:HStack \{\s*)?Text\("([^"]+)"\)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let string = String(text)
        let range = NSRange(string.startIndex..., in: string)
        return regex.matches(in: string, range: range).compactMap { match in
            for group in 1...2 {
                if let r = Range(match.range(at: group), in: string) { return String(string[r]) }
            }
            return nil
        }
    }

    @Test("The sidebar has Device Settings and App Settings, with their icons")
    func navigationAreas() {
        let device = NavigationArea.deviceSettings
        let app = NavigationArea.appSettings
        #expect(device.rawValue == "Device Settings")
        #expect(device.systemImage == "hifireceiver")
        #expect(app.rawValue == "App Settings")
        #expect(app.systemImage == "gearshape")
        let names = NavigationArea.allCases.map(\.rawValue)
        #expect(names.suffix(2) == ["Device Settings", "App Settings"])
        for retired in ["System Setup", "Hardware", "Preferences"] {
            #expect(!names.contains(retired), "\(retired)")
        }
    }

    @Test("A launch argument naming a retired page opens the page that replaced it")
    func formerNamesMigrate() {
        for old in ["systemSetup", "System Setup", "hardware", "Hardware", "deviceSettings", "Device Settings"] {
            let area = NavigationArea.named(old)
            #expect(area == .deviceSettings, "\(old)")
        }
        for old in ["preferences", "Preferences", "appSettings", "App Settings"] {
            let area = NavigationArea.named(old)
            #expect(area == .appSettings, "\(old)")
        }
        let routing = NavigationArea.named("outputRouting")
        #expect(routing == .outputRouting)
        let unknown = NavigationArea.named("nonsense")
        #expect(unknown == nil)
    }

    @Test("Device Settings is one form with its sections in the owner's order")
    func deviceSettingsSections() throws {
        let text = try source("MaestroApp/SettingsViews.swift")
        let view = try declaration("struct DeviceSettingsView: View {", in: text)
        // Each section is a property, declared in page order; the body adds Status last.
        let sections = try #require(view.range(of: "// MARK: - Sections, in page order"))
        let titles = try sectionTitles(view[sections.upperBound...])
        let expected = ["Clock", "Connection", "Input Monitoring", "Volume Keys", "Front Panel",
                        "Cards", "Naming", "Info"]
        #expect(titles == expected)
        let bodyTitles = try sectionTitles(view[..<sections.lowerBound])
        #expect(bodyTitles == ["Status"])
        let forms = view.components(separatedBy: "Form {").count - 1
        #expect(forms == 1)
        #expect(view.contains(".formStyle(.grouped)"))
        #expect(view.contains(".navigationTitle(\"Device Settings\")"))
        // The body lays the sections out in the same order.
        let body = try #require(view.range(of: "var body: some View {"))
        let calls = ["clockSection", "connectionSection", "inputMonitoringSection", "volumeKeysSection",
                     "frontPanelSection", "cardsSection", "namingSection", "infoSection", "Section(\"Status\")"]
        var cursor = body.upperBound
        for call in calls {
            let found = try #require(view.range(of: call, range: cursor..<view.endIndex), "\(call)")
            cursor = found.upperBound
        }
    }

    @Test("\"Applies to both units.\" is a section footer, shown only with two units")
    func bothUnitsFooter() throws {
        let text = try source("MaestroApp/SettingsViews.swift")
        let view = String(try declaration("struct DeviceSettingsView: View {", in: text))
        let lines = view.components(separatedBy: "\n")
        let notes = lines.indices.filter { lines[$0].contains("Applies to both units.") }
        #expect(notes.count == 2)
        for index in notes {
            #expect(lines[index].contains("if showsBothUnitsFooter"))
            #expect(lines[index - 1].contains("} footer: {"))
        }
        #expect(view.contains("private var showsBothUnitsFooter: Bool { appState.unitPickerVisible }"))
    }

    @Test("Each hardware value is read by exactly one of the page's two loads")
    func noDuplicateReads() throws {
        let text = try source("MaestroApp/SettingsViews.swift")
        let view = String(try declaration("struct DeviceSettingsView: View {", in: text))
        for selector in [".deviceMode", ".peakHoldMode", ".oversHoldMode", ".prefix", ".clockSource",
                         ".versionString"] {
            let reads = view.components(separatedBy: "readSetting(\(selector)").count - 1
                + view.components(separatedBy: "PropertyAddress(selector: \(selector)))").count - 1
            #expect(reads == 1, "\(selector) is read \(reads) times")
        }
        // Word Clock Divide was an Ensemble setting; the Symphony I/O has none,
        // so the page neither shows nor reads it.
        #expect(!view.contains("Word Clock Divide"))
        #expect(!view.contains("PropertyAddress(selector: .wordClockDivide)"))
        let tasks = view.components(separatedBy: ".task(id: settingsLoadID)").count - 1
        #expect(tasks == 1)
        let propertyTasks = view.components(separatedBy: ".task(id: appState.viewReloadToken)").count - 1
        #expect(propertyTasks == 1)
        #expect(view.contains("private var isLoading: Bool { settingsLoading || propertiesLoading }"))
    }

    @Test("App Settings is one form with its sections in the owner's order")
    func appSettingsSections() throws {
        let text = try source("MaestroApp/SettingsViews.swift")
        let view = try declaration("struct AppSettingsView: View {", in: text)
        let titles = try sectionTitles(view)
        let expected = ["General", "When a Device Connects", "Updates", "Diagnostics & Feedback", "About"]
        #expect(titles == expected)
        let forms = view.components(separatedBy: "Form {").count - 1
        #expect(forms == 1)
        #expect(view.contains(".navigationTitle(\"App Settings\")"))
        #expect(view.contains("Toggle(\"Restore my mixer after a USB reconnect\", isOn: $autoRecoverMixerState)"))
        // The driver extension stays with the hardware.
        #expect(!view.contains("ThunderBridge Driver Extension"))
        // Nothing on this page talks to the Symphony I/O.
        #expect(!view.contains("setProperty(") && !view.contains("getProperty("))
    }

    @Test("The Help menu links to bug reports and the Gearspace discussion")
    func helpMenuItems() throws {
        let app = try source("MaestroApp/MaestroApp.swift")
        #expect(app.contains("Button(\"Report a Bug…\") { NSWorkspace.shared.open(FeedbackLinks.reportBug) }"))
        #expect(app.contains("Button(\"Discuss on Gearspace…\") { NSWorkspace.shared.open(FeedbackLinks.discussion) }"))
    }

    @Test("No user-facing text names a retired page")
    func noRetiredPageNames() throws {
        let fm = FileManager.default
        var files: [URL] = []
        for dir in ["MaestroApp", "MaestroCore", "MaestroDevice"] {
            let url = Self.appRoot.appendingPathComponent(dir)
            let found = try #require(fm.enumerator(at: url, includingPropertiesForKeys: nil))
            for case let file as URL in found where ["swift", "html"].contains(file.pathExtension) {
                files.append(file)
            }
        }
        #expect(files.count > 20)
        // macOS System Information's own categories, not Maestro pages.
        let allowed = ["Hardware › Thunderbolt/USB4", "Hardware › PCI"]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.components(separatedBy: "\n").enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") { continue }
                var visible = line
                for phrase in allowed { visible = visible.replacingOccurrences(of: phrase, with: "") }
                for retired in ["System Setup", "Hardware ›", "Preferences ›", "Device Settings › Preferences",
                                "Device Settings › Updates", "Device Settings › Diagnostics"] {
                    #expect(!visible.contains(retired), "\(file.lastPathComponent):\(number + 1) says \(retired)")
                }
            }
        }
    }

    @Test("The Unit A / Unit B picker help names Device Settings, never App Settings")
    func unitPickerPages() {
        let text = SecondUnitHelp.lines.joined(separator: " ")
        #expect(text.contains("Input, Output, Input Routing and Device Settings show a **Unit A / Unit B** picker"))
        #expect(!text.contains("App Settings"))
    }
}
