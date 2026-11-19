import Foundation
import Testing
@testable import MaestroApp
@testable import MaestroDevice
@testable import MaestroCore

@Suite("Unit B in the app")
struct UnitBAppTests {
    @Test("Unit B output pairs route on XLink TX 32-63")
    func unitBRoutePairs() throws {
        let board0 = SymphonyIORoutingAddress.ioBoard0Base
        let board1 = SymphonyIORoutingAddress.ioBoard1Base
        // DAW 33-34 (grid row 16) to unit B's first pair.
        let daw = try #require(AppState.unitBRoutePair(destLeft: board0, gridRow: 16))
        #expect(daw.map(\.payload) == [Data([32, 96, 1]), Data([33, 97, 1])])
        // DAW 1-2 to unit B's slot 2 output 3-4.
        let first = try #require(AppState.unitBRoutePair(destLeft: board1 + 2, gridRow: 0))
        #expect(first.map(\.payload) == [Data([50, 64, 1]), Data([51, 65, 1])])
        // Mixer 1 and Mixer 2 (grid rows 32, 33).
        #expect(AppState.unitBRoutePair(destLeft: board0, gridRow: 32)?.map(\.payload)
                == [Data([32, 128, 1]), Data([33, 129, 1])])
        #expect(AppState.unitBRoutePair(destLeft: board0 + 14, gridRow: 33)?.map(\.payload)
                == [Data([46, 130, 1]), Data([47, 131, 1])])
        // Clearing disables the channels on their own PCI_OUT slots.
        #expect(AppState.unitBRoutePair(destLeft: board0, gridRow: nil)?.map(\.payload)
                == [Data([32, 96, 0]), Data([33, 97, 0])])
        // A row past the mixers, or a destination that is not an output, is refused.
        #expect(AppState.unitBRoutePair(destLeft: board0, gridRow: 34) == nil)
        #expect(AppState.unitBRoutePair(destLeft: 0, gridRow: 0) == nil)
    }

    private func source(_ file: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MaestroApp/\(file)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("Input and Output pages read the chosen unit, never unit A's members directly")
    func perUnitPagesUseUnitMembers() throws {
        for file in ["InputViews.swift", "OutputViews.swift"] {
            let text = try source(file)
            for member in ["appState.device", "appState.channelStateStore", "appState.channelNaming",
                           "appState.inputMeterLevels", "appState.outputMeterLevels",
                           "appState.primaryBoardType", "appState.rememberDigitalSetting("] {
                #expect(!text.contains(member + " ") && !text.contains(member + ".")
                        && !text.contains(member + "?") && !text.contains(member + ")"),
                        "\(file) reads \(member)")
            }
            #expect(!text.contains("appState.cardLayout.") && !text.contains("appState.cardLayout }"),
                    "\(file) reads appState.cardLayout")
        }
    }

    @Test("The picker sits above the per-unit pages only, and rebuilds them on a change")
    func pickerPlacement() throws {
        let shell = try source("AppShell.swift")
        #expect(shell.contains("if isPerUnit && appState.unitPickerVisible {"))
        #expect(shell.contains("page.id(appState.activeUnit)"))
    }
}
