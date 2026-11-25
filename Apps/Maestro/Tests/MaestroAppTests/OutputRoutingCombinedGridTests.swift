import Foundation
import Testing

/// Output Routing is the card's page: with two Symphony I/Os it is one grid
/// and never follows the Unit A / Unit B picker of the per-unit pages.
struct OutputRoutingCombinedGridTests {
    private func outputRoutingSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("MaestroApp/RoutingViews.swift"), encoding: .utf8)
        let afterStart = try #require(source.components(separatedBy: "struct OutputRoutingView").last)
        return try #require(afterStart.components(separatedBy: "// MARK: - Routing Grid").first)
    }

    @Test("Cells, presets and reset never depend on the other pages' unit picker")
    func noHiddenPicker() throws {
        let view = try outputRoutingSource()
        #expect(!view.contains("activeUnit"))
        #expect(!view.contains("unitWriteTarget"))
        #expect(view.contains("grid.cell(gridRow: row, column: col)"))
        #expect(view.contains("columnGroups: grid.columnGroups"))
        // Save, load and delete follow OutputRoutingPresets' rule (tested in
        // MaestroCore); unit B is checked before anything is written.
        #expect(view.contains("presets.save(name: name,"))
        #expect(view.contains("presets.delete(entry)"))
        #expect(view.contains("switch presets.loadPlan(entry, unitB: state)"))
        #expect(view.contains("appState.unitBWriteTarget"))
        #expect(view.contains("\"Unit A loaded; unit B\""))
        // Wide grids scroll rather than squash.
        #expect(view.contains("ScrollView([.horizontal, .vertical])"))
    }
}
