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

    @Test("Device Settings only offers the original keyboard volume control for dual 64-channel units")
    func placementAndGate() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MaestroApp/SettingsViews.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("Text(\"Volume Keys\")"))
        // The section is shown for the unit choice (two units) or the output
        // choice; the Peripheral pop-up itself only with two units, named as
        // the original named it.
        #expect(source.contains("if showsVolumeKeys { volumeKeysSection }"))
        #expect(source.contains("hasTwoMonitorDevices || appState.keyboardVolumeOutputAvailable || appState.keyboardVolumeUnavailableReason != nil"))
        // An older USB helper: the pop-up is shown disabled, with the reason below it.
        #expect(source.contains("Picker(\"Audio Output\", selection: .constant(KeyboardVolumeOutput.speakers))"))
        #expect(source.contains("if let reason = appState.keyboardVolumeUnavailableReason {"))
        let section = try #require(source.range(of: "private var volumeKeysSection: some View {"))
        let body = source[section.upperBound...]
        let peripheral = try #require(body.range(of: "Picker(\"Peripheral\""))
        let gate = try #require(body.range(of: "if hasTwoMonitorDevices {"))
        let audioOutput = try #require(body.range(of: "Picker(\"Audio Output\""))
        #expect(gate.lowerBound < peripheral.lowerBound && peripheral.lowerBound < audioOutput.lowerBound)
        #expect(!source.contains("Picker(\"Monitor Device\""))
        #expect(source.contains("KeyboardVolumeOutput.peripheralName(prefix: appState.peripheralPrefix, name: \"Symphony I/O\")"))
        #expect(source.contains("KeyboardVolumeOutput.peripheralName(prefix: appState.unitBPeripheralPrefix, name: \"Symphony I/O\")"))
        #expect(source.contains("appState.portSelection.selection == .ports1And2"))
        #expect(source.contains("appState.unitB?.setupComplete == true"))
    }
    @Test("selection awaits the off-main transaction and rejects stale completions")
    func selectionTransactionBoundary() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let connection = try String(contentsOf: root.appendingPathComponent(
            "MaestroDevice/ThunderboltDeviceConnection.swift"), encoding: .utf8)
        let app = try String(contentsOf: root.appendingPathComponent("MaestroApp/AppState.swift"), encoding: .utf8)
        #expect(connection.contains("func setMonitorDevice(_ unit: DeviceUnit) async -> Bool"))
        #expect(connection.contains("await Task.detached { self.setMonitorDeviceOffMain(unit) }.value"))
        #expect(app.contains("let accepted = await tb.setMonitorDevice(unit)"))
        #expect(app.contains("generation == self.monitorSelectionGeneration"))
        #expect(!app.contains("_ = tb.setMonitorDevice("))
    }

    @Test("physical A writes use the vendor path, with HAL reserved for converter trim")
    func physicalMonitorBoundary() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "MaestroDevice/ThunderboltDeviceConnection.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "private func writeProperty("))
        let body = source[start.lowerBound...]
        let end = try #require(body.range(of: "case .sampleRate:"))
        let monitorWrites = body[..<end.lowerBound]
        #expect(monitorWrites.contains("sendViaDext(SymphonyIOPropertyMapper.buildWriteRequest"))
        #expect(monitorWrites.contains("ConverterState.flagPort1Converters"))
    }

}
