import Foundation
import Testing
@testable import MaestroApp
@testable import MaestroCore

@Suite("Monitor device selection")
struct MonitorDeviceSelectionTests {
    @Test("defaults to unit A and persists unit B by card role")
    func defaultAndPersistence() {
        let suite = "MonitorDeviceSelectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(MonitorDeviceSelectionStore.load(productID: 2200, defaults: defaults) == .a)
        MonitorDeviceSelectionStore.save(.b, productID: 2200, defaults: defaults)
        #expect(MonitorDeviceSelectionStore.load(productID: 2200, defaults: defaults) == .b)
        #expect(MonitorDeviceSelectionStore.load(productID: 2100, defaults: defaults) == .a)
    }

    @Test("System Setup only offers the original keyboard volume control for dual 64-channel units")
    func placementAndGate() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MaestroApp/SettingsViews.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("Section(\"Keyboard Volume Control\")"))
        #expect(source.contains("appState.portSelection.selection == .ports1And2"))
        #expect(source.contains("appState.unitB?.setupComplete == true"))
    }
}
