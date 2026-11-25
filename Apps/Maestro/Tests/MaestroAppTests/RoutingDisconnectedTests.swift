import Foundation
import Testing
import MaestroDevice
@testable import MaestroApp

@Suite("Routing controls with no hardware")
@MainActor
struct RoutingDisconnectedTests {
    @Test func disconnectedAppStateDisablesRoutingWrites() {
        let state = AppState()
        state.connectionMode = .disconnected
        #expect(!state.routingHardwareAvailable)
    }

    @Test func availabilityNeedsAModeAndADevice() {
        #expect(!AppState.routingHardwareAvailable(mode: .disconnected, hasDevice: true))
        #expect(!AppState.routingHardwareAvailable(mode: .hardware, hasDevice: false))
        #expect(AppState.routingHardwareAvailable(mode: .hardware, hasDevice: true))
        #expect(AppState.routingHardwareAvailable(mode: .simulated, hasDevice: true))
    }

    /// Reset Routing, Identify and preset loading are tied to the predicate.
    @Test func routingPagesGateResetIdentifyAndPresetLoad() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("MaestroApp")
        for file in ["RoutingViews.swift", "SymphonyCardInputRoutingView.swift", "ConverterRoutingViews.swift"] {
            let text = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
            #expect(text.contains(".disabled(!appState.routingHardwareAvailable)"), "\(file)")
            #expect(text.contains("canLoad: appState.routingHardwareAvailable"), "\(file)")
        }
        let routing = try String(contentsOf: dir.appendingPathComponent("RoutingViews.swift"), encoding: .utf8)
        #expect(routing.contains("device: appState.routingHardwareAvailable ? appState.device : nil"))
    }
}

@Suite("Routing grid with no hardware")
@MainActor
struct RoutingGridDisconnectedTests {
    @Test func gridIgnoresClicksWhenDisabled() throws {
        var taps = 0
        var hoverRow: Int? = nil, hoverCol: Int? = nil
        let grid = RoutingGridView(
            rowCount: 1, columnCount: 1, rowLabels: [(number: "1-2", name: "A")],
            columnLabels: [(type: "Analog", channels: "1-2")], rowGroupLabel: "R", colGroupLabel: "C",
            isActiveCell: { _, _ in false },
            hoverRow: .init(get: { hoverRow }, set: { hoverRow = $0 }),
            hoverCol: .init(get: { hoverCol }, set: { hoverCol = $0 }),
            isEnabled: AppState.routingHardwareAvailable(mode: .disconnected, hasDevice: true),
            onCellTap: { _, _ in taps += 1 })
        #expect(!grid.isEnabled)
        #expect(taps == 0)
    }

    @Test func notConnectedReadsPlainly() {
        let text = DeviceConnectionError.notConnected.localizedDescription
        #expect(!text.contains("MaestroDevice"))
        #expect(text == "No Symphony is connected.")
    }

    @Test func everyTapPathIsGatedInSource() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("MaestroApp")
        for file in ["RoutingViews.swift", "SymphonyCardInputRoutingView.swift", "ConverterRoutingViews.swift"] {
            let text = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
            #expect(text.contains("isEnabled: appState.routingHardwareAvailable,"), "\(file)")
        }
    }
}

@Suite("Pages with no hardware")
struct PagesDisconnectedTests {
    private func source(_ file: String) throws -> String {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("MaestroApp")
        return try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
    }

    /// Device Settings: not redacted, controls disabled, no green clock dot.
    @Test func deviceSettingsIsNotRedactedButIsDisabledWhenDisconnected() throws {
        let text = try source("SettingsViews.swift")
        #expect(text.contains("private var isLoading: Bool { settingsLoading || propertiesLoading || !appState.routingHardwareAvailable }"))
        #expect(text.contains(".redacted(reason: showsPlaceholder ? .placeholder : [])"))
        #expect(text.contains("(settingsLoading || propertiesLoading) && appState.routingHardwareAvailable"))
        #expect(text.contains("!appState.routingHardwareAvailable ? Color.gray : shownClockLocked ? .green : .red"))
    }

    @Test func statusBarShowsNoStaleReady() throws {
        let text = try source("MonitorViews.swift")
        #expect(text.contains("Text(!hardwareAvailable ? \"—\" : PortStatusMessage.clock("))
        #expect(text.contains("!hardwareAvailable ? Color.secondary : shownClockLocked ? .green : .red"))
    }

    /// A read-only grid (no Symphony connected) shows no hover crosshair
    /// (owner, 2026-11-24: it looked clickable).
    @Test func readOnlyGridHasNoHoverHighlight() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("MaestroApp/RoutingViews.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("let isHovered = isEnabled && (hoverRow == row || hoverCol == col)"))
        #expect(text.contains("if hovering, isEnabled {"))
    }
}
