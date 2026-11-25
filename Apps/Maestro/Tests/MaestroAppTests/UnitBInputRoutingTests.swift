import Foundation
import Testing
@testable import MaestroApp
import MaestroCore

@Suite("Unit B input routing", .serialized)
@MainActor
struct UnitBInputRoutingTests {
    @Test("Input routing follows the picker; shared output routing does not")
    func picker() throws {
        #expect(UnitPicker.isPerUnit(page: "Input Routing"))
        #expect(!UnitPicker.isPerUnit(page: "Output Routing"))
        let text = try source("RoutingViews.swift").components(separatedBy: "struct OutputRoutingView")[0]
        #expect(text.contains("unit = appState.activeUnit"))
        #expect(text.contains("device = appState.unitDevice"))
        #expect(text.contains("if unit == .b { return unitBCache }"))
        #expect(text.contains("unit == .b ? (appState.unitBLayout ?? CardLayout(isKnown: false)) : appState.cardLayout"))
        #expect(text.contains("type: unit == .b ? \"\\(prefix) \\($0.type)\" : $0.type"))
        #expect(text.contains("i * 2 + 1 + (unit == .b ? 32 : 0)"))
        #expect(text.contains("i * 2 + 2 + (unit == .b ? 32 : 0)"))
    }

    @Test("Different B cards have their own input columns")
    func columns() {
        let a = CardLayout(slot1: .analogADDA16, slot2: .none, isKnown: true)
        let b = SecondUnitInfo(slot1: .optical, slot2: .none, slotValid: [true, true]).layout()
        // A's columns are its 16x16 analog card; B's come from B's own 8x8
        // optical card, so B shows ADAT inputs that A does not have.
        #expect(a.inputRoutingColumns.allSatisfy { !$0.isDigital })
        #expect(b.inputRoutingColumns.contains { $0.isDigital && $0.type == "ADAT" })
        #expect(a.inputRoutingColumns.map(\.type) != b.inputRoutingColumns.map(\.type))
    }

    @Test("B's saved input routes cannot overwrite A or B's outputs")
    func cacheIsolation() throws {
        #expect(AppState.unitBInputRoutingDirection(cardScope: nil, simulating: false) == nil)
        let scope = UUID().uuidString
        let direction = try #require(AppState.unitBInputRoutingDirection(cardScope: scope, simulating: false))
        #expect(direction == "input.unitB.\(scope)")
        #expect(AppState.unitBInputRoutingDirection(cardScope: scope, simulating: true) == "input.unitB.sim:\(scope)")
        // A unique direction avoids touching any real saved routes.
        let a = RoutingStateCache(direction: "input.test.\(scope)", productID: 18)
        let b = RoutingStateCache(direction: direction, productID: 18)
        let output = RoutingStateCache(direction: "output.unitB.\(scope)", productID: 18)
        defer {
            for cache in [a, b, output] { UserDefaults.standard.removeObject(forKey: cache.key) }
        }
        a.save([0: 1]); b.save([0: 7]); output.save([0: 3])
        #expect(a.load() == [0: 1])
        #expect(b.load() == [0: 7])
        #expect(output.load() == [0: 3])
        b.save([0: 2])
        #expect(a.load() == [0: 1])
        #expect(output.load() == [0: 3])
        #expect(b.key != "routing_input_18_v2")
    }

    @Test("The B table requires 64 channels, configuration and a Symphony topology")
    func capabilityGate() {
        let endpoint = SymphonyRoutingModel.Endpoint.peripheral(.init(port: .two)!)
        for channels in [0, 32, 64] {
            for configured in [false, true] {
                let model = SymphonyRoutingModel(topology: .symphonyOnly, hostChannels: channels,
                                                 unitBConfigured: configured)
                #expect(model.allows(.unitRouting, at: endpoint) == (channels == 64 && configured))
            }
        }
        for topology: SymphonyRoutingModel.Topology in [.unknown, .symphonyAndConverters([])] {
            let model = SymphonyRoutingModel(topology: topology, hostChannels: 64, unitBConfigured: true)
            #expect(!model.allows(.unitRouting, at: endpoint))
        }
        let model = SymphonyRoutingModel(topology: .symphonyOnly, hostChannels: 64, unitBConfigured: true)
        let first = SymphonyRoutingModel.P2P(unit: .init(port: .two)!, channel: 0)!
        let last = SymphonyRoutingModel.P2P(unit: .init(port: .two)!, channel: 31)!
        #expect(model.cardRX(for: first)?.index == 32)
        #expect(model.cardRX(for: last)?.index == 63)
    }

    private func source(_ file: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MaestroApp/\(file)")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
