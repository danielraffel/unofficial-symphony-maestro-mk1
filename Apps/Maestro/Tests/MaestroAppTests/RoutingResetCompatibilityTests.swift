import Foundation
import Testing

struct RoutingResetCompatibilityTests {
    @Test func outputResetDoesNotTouchCardInputs() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("MaestroApp/RoutingViews.swift"), encoding: .utf8)
        let output = try #require(source.components(separatedBy: "struct OutputRoutingView").last)
        #expect(!output.contains("applySymphonyCardInputs"))
        #expect(!output.contains("software-input mapping"))
        let input = try #require(source.components(separatedBy: "struct OutputRoutingView").first)
        #expect(input.contains("if appState.symphonyCardInputs.channelCount > 0,"))
        #expect(input.contains("applySymphonyCardInputs([:], reset: true)"))
        let state = try String(contentsOf: root.appendingPathComponent("MaestroApp/AppState+CardInputs.swift"), encoding: .utf8)
        #expect(state.contains("servingBuild: servingDextBuild"))
        let twoUnit = try String(contentsOf: root.appendingPathComponent("MaestroApp/ThunderboltRoutingReset.swift"), encoding: .utf8)
        #expect(twoUnit.contains("input && symphonyCardInputs.channelCount == 0 ? []"))
        #expect(twoUnit.contains("cardWrites + aWrites"))
    }
}
