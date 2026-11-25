import Foundation
import Testing
@testable import MaestroCore

/// Editable converter routing: the grid's channels and names, the default
/// placement, the exact vendor command bytes the driver takes
/// (`SymphonyCardMixerRouting.h`: 0xB5, 0xB6, 0xB7), and persistence per
/// chain of units.
@Suite("Converter routing")
struct ConverterRoutingTests {
    private func layout(_ name: String) throws -> (ConverterRoutingLayout, ConverterSystem) {
        let system = try #require(ConverterSystem(simulationName: name))
        return (ConverterRoutingLayout(system: system), system)
    }

    // MARK: Columns, rows and defaults

    @Test func adAdDaDaOnOnePort() throws {
        let (l, system) = try layout("ad16x+ad16x+da16x+da16x")
        #expect(l.hostChannels == 32)
        #expect(l.outputs.count == 32)
        #expect(l.outputs.first == .init(bus: 0, name: "C Line 1", unit: 2, element: 0))
        #expect(l.outputs[15].name == "C Line 16")
        #expect(l.outputs[16] == .init(bus: 16, name: "D Line 1", unit: 3, element: 0))
        #expect(l.outputs.last == .init(bus: 31, name: "D Line 16", unit: 3, element: 15))
        #expect(l.inputs.first?.name == "A Line 1")
        #expect(l.inputs[16] == .init(bus: 16, name: "B Line 1", unit: 1, element: 0))
        // Pair columns, the grid's style.
        #expect(l.outputPairs.count == 16)
        #expect(l.outputPairs[0].name == "C Line 1/2")
        #expect(l.outputPairs[0].header.type == "C Line" && l.outputPairs[0].header.channels == "1/2")
        #expect(l.outputPairs[15].name == "D Line 15/16")
        #expect(l.inputPairs.map(\.name).prefix(2) == ["A Line 1/2", "A Line 3/4"])
        // Rows: 16 DAW playback pairs, then Mixer 1 and Mixer 2.
        #expect(l.playbackPairCount == 16)
        #expect(l.outputRowSource(row: 0) == 64)
        #expect(l.outputRowSource(row: 15) == 94)
        #expect(l.outputRowSource(row: 16) == 128)
        #expect(l.outputRowSource(row: 17) == 130)
        #expect(l.outputRowSource(row: 18) == nil)
        #expect(l.playbackRowNames(system: system).first == "C Line 1/2")
        #expect(l.inputPairCount == 16)
        // Default: DAW output n straight to the converter output the host map
        // puts at n, 1-2 included; no mixer anywhere.
        let out = l.outputSources(ConverterRoutingEdits())
        #expect(out.count == 32)
        #expect(out[0] == 64 && out[1] == 65 && out[2] == 66 && out[31] == 95)
        #expect(!out.values.contains { $0 >= 128 })
        #expect((0..<16).allSatisfy { l.outputCellActive(row: $0, column: $0, sources: out) })
        #expect(!l.outputCellActive(row: 16, column: 0, sources: out))
        // DAW input n from converter input bus n.
        let inp = l.inputSources(ConverterRoutingEdits())
        #expect(inp.count == 32 && inp[0] == 0 && inp[31] == 31)
        #expect(l.inputColumn(row: 8, sources: inp) == 8)
        #expect(l.inputRowNames(sources: inp)[8] == "B Line 1/2")
    }

    @Test func adAdDaDaOnTwoPorts() throws {
        let (l, system) = try layout("ad16x+ad16x+da16x+da16x|ad16x+ad16x+da16x+da16x")
        #expect(l.hostChannels == 64)
        #expect(l.playbackPairCount == 32 && l.inputPairCount == 32)
        #expect(l.outputs.count == 64)
        #expect(l.outputs[32] == .init(bus: 32, name: "G Line 1", unit: 6, element: 0))
        #expect(l.outputs.last == .init(bus: 63, name: "H Line 16", unit: 7, element: 15))
        #expect(l.inputs[32].name == "E Line 1" && l.inputs[32].bus == 32)
        #expect(l.outputPairs.count == 32)
        #expect(l.outputRowSource(row: 32) == 128)   // Mixer 1 after 32 DAW pairs
        let out = l.outputSources(ConverterRoutingEdits())
        #expect(out[32] == 96 && out[63] == 127)
        #expect(l.inputSources(ConverterRoutingEdits())[40] == 40)
        #expect(l.playbackRowNames(system: system)[16] == "G Line 1/2")
        #expect(system.routingSignature == "p1u1r03-p1u2r03-p1u3r0c-p1u4r0c-p2u1r03-p2u2r03-p2u3r0c-p2u4r0c")
    }

    @Test func rosettaThenAD() throws {
        let (l, _) = try layout("rosetta800+ad16x")
        #expect(l.outputs.map(\.name) == (1...8).map { "A Out \($0)" })
        #expect(l.outputs.map(\.bus) == Array(0..<8))
        #expect(l.inputs.prefix(8).map(\.name) == (1...8).map { "A In \($0)" })
        // The AD after a Rosetta starts on slot 16 (SymphonyConverters.h offsets).
        #expect(l.inputs[8] == .init(bus: 16, name: "B Line 1", unit: 1, element: 0))
        #expect(l.outputPairs.map(\.name) == ["A Out 1/2", "A Out 3/4", "A Out 5/6", "A Out 7/8"])
        let inp = l.inputSources(ConverterRoutingEdits())
        #expect(inp[7] == 7 && inp[8] == 16 && inp[23] == 31 && inp[24] == nil)
        let rows = l.inputRowNames(sources: inp)
        #expect(rows[0] == "A In 1/2" && rows[4] == "B Line 1/2" && rows[12] == CardLayout.notApplicable)
        // Output hosts past the Rosetta's eight carry nothing.
        #expect(l.outputSources(ConverterRoutingEdits()).keys.sorted() == Array(0..<8))
    }

    // MARK: Command bytes

    @Test func commandBytes() {
        #expect(ConverterRouting.outputCommand(bus: 5, source: 70)
                == .init(command: 0xB5, payload: [5, 70, 1]))
        #expect(ConverterRouting.outputCommand(bus: 40, source: 129)
                == .init(command: 0xB5, payload: [40, 129, 1]))
        #expect(ConverterRouting.outputCommand(bus: 5, source: nil)
                == .init(command: 0xB5, payload: [5, 0, 0]))
        #expect(ConverterRouting.inputCommand(host: 3, bus: 17)
                == .init(command: 0xB6, payload: [3, 17, 1]))
        #expect(ConverterRouting.inputCommand(host: 63, bus: nil)
                == .init(command: 0xB6, payload: [63, 0, 0]))
        #expect(ConverterRouting.resetRoutingCommand == .init(command: 0xB7, payload: []))
        #expect(ConverterRouting.mixerSource(mixer: 1, side: 1) == 131)
        #expect(ConverterRouting.playbackSource(host: 0) == 64)
    }

    @Test func outputClicksSendBothChannels() throws {
        let (l, _) = try layout("ad16x+ad16x+da16x+da16x")
        // Mixer 2 (row 17) to D Line 1/2 (column 8, bus 16/17).
        let set = try #require(l.toggleOutput(row: 17, column: 8, edits: ConverterRoutingEdits()))
        #expect(set.commands == [.init(command: 0xB5, payload: [16, 130, 1]),
                                 .init(command: 0xB5, payload: [17, 131, 1])])
        #expect(set.edits.outputs == [16: 130, 17: 131])
        #expect(l.outputCellActive(row: 17, column: 8, sources: l.outputSources(set.edits)))
        // The same cell again: silent.
        let cleared = try #require(l.toggleOutput(row: 17, column: 8, edits: set.edits))
        #expect(cleared.commands == [.init(command: 0xB5, payload: [16, 0, 0]),
                                     .init(command: 0xB5, payload: [17, 0, 0])])
        #expect(cleared.edits.outputs == [16: -1, 17: -1])
        // Back to the default: no edit left to keep.
        let back = try #require(l.toggleOutput(row: 8, column: 8, edits: cleared.edits))
        #expect(back.commands == [.init(command: 0xB5, payload: [16, 80, 1]),
                                  .init(command: 0xB5, payload: [17, 81, 1])])
        #expect(back.edits.isEmpty)
    }

    @Test func inputClicksSendBothChannels() throws {
        let (l, _) = try layout("ad16x+ad16x+da16x+da16x|ad16x+ad16x+da16x+da16x")
        // DAW inputs 1-2 (row 0) from E Line 1/2 (column 16, bus 32/33).
        let set = try #require(l.toggleInput(row: 0, column: 16, edits: ConverterRoutingEdits()))
        #expect(set.commands == [.init(command: 0xB6, payload: [0, 32, 1]),
                                 .init(command: 0xB6, payload: [1, 33, 1])])
        #expect(l.inputColumn(row: 0, sources: l.inputSources(set.edits)) == 16)
        let cleared = try #require(l.toggleInput(row: 0, column: 16, edits: set.edits))
        #expect(cleared.commands == [.init(command: 0xB6, payload: [0, 0, 0]),
                                     .init(command: 0xB6, payload: [1, 0, 0])])
        #expect(l.inputRowNames(sources: l.inputSources(cleared.edits))[0] == "N.A.")
        // Replay sends each edit once, outputs then inputs, in order.
        let edits = ConverterRoutingEdits(outputs: [33: -1, 2: 128], inputs: [5: 40])
        #expect(l.replayCommands(edits) == [.init(command: 0xB5, payload: [2, 128, 1]),
                                            .init(command: 0xB5, payload: [33, 0, 0]),
                                            .init(command: 0xB6, payload: [5, 40, 1])])
        #expect(l.fullOutputCommands(ConverterRoutingEdits()).count == 64)
        #expect(l.fullInputCommands(ConverterRoutingEdits()).count == 64)
    }

    // MARK: Persistence per chain

    @Test func routesAreKeptPerChain() throws {
        let suite = "ConverterRoutingTests.\(UUID().uuidString)"
        let defaults = try #require(ScratchUserDefaults(suiteName: suite))
        defer { defaults.cleanup() }

        let one = try #require(ConverterSystem(simulationName: "ad16x+da16x"))
        let other = try #require(ConverterSystem(simulationName: "da16x+ad16x"))
        let wider = try #require(ConverterSystem(simulationName: "ad16x+da16x|ad16x"))
        #expect(one.routingSignature == "p1u1r03-p1u2r0c")
        #expect(other.routingSignature != one.routingSignature)
        #expect(wider.routingSignature != one.routingSignature)
        // A Device Type change is another chain.
        var config = ConverterConfig()
        config.deviceTypes[ConverterDeviceType.defaultsKey(port: 0, address: 1)] = .ddAsDA
        let asDA = try #require(ConverterSystem(simulationName: "dd16x", config: config))
        let asAD = try #require(ConverterSystem(simulationName: "dd16x"))
        #expect(asDA.routingSignature == "p1u1r0fda" && asAD.routingSignature == "p1u1r0f")

        let store = ConverterRoutingStore(signature: one.routingSignature, defaults: defaults)
        let edits = ConverterRoutingEdits(outputs: [0: 128, 1: 129], inputs: [2: -1])
        store.save(edits)
        #expect(ConverterRoutingStore(signature: one.routingSignature, defaults: defaults).load() == edits)
        #expect(ConverterRoutingStore(signature: other.routingSignature, defaults: defaults).load().isEmpty)
        #expect(ConverterRoutingStore(signature: wider.routingSignature, defaults: defaults).load().isEmpty)
        store.save(ConverterRoutingEdits())
        #expect(defaults.object(forKey: store.key) == nil)

        // Presets: per chain and direction.
        store.savePreset(name: "Mix", input: false, routes: [0: 130])
        #expect(store.presetNames(input: false) == ["Mix"])
        #expect(store.presetNames(input: true).isEmpty)
        #expect(ConverterRoutingStore(signature: other.routingSignature, defaults: defaults)
                    .presetNames(input: false).isEmpty)
        #expect(store.presets(input: false)["Mix"] == [0: 130])
        store.deletePreset(name: "Mix", input: false)
        #expect(store.presetNames(input: false).isEmpty)
    }

    // MARK: A Symphony I/O on port 1, converters on port 2

    @Test func port2ConvertersBehindASymphony() throws {
        var units: [[UInt32]] = [[0, 0, 0, 0], [0, 0, 0, 0]]
        // Port 1 answers as a Symphony I/O (routing 0xFF), port 2 an AD-16X.
        units[0][0] = 0xFF | 0xFF << 8 | ConverterState.unitInquireOK | ConverterState.unitXtdOK
        units[1][0] = 0x37 | 0x02 << 8 | ConverterState.unitInquireOK | ConverterState.unitXtdOK
        let state = ConverterState(flags: ConverterState.flagPort2Converters, unitCount: [1, 1], units: units)
        let system = try #require(ConverterSystem(state: state))
        #expect(system.ports[0].isEmpty)
        #expect(system.ports[1].first?.kind == .ad16x)
        #expect(system.connectedUnit == nil)   // Symphony I/O guards stay as they are
        #expect(!system.layoutKnown)
        #expect(ConverterSystem(state: ConverterState(flags: 0)) == nil)

        // The Symphony I/O routing grids are exactly what they are without
        // the port-2 converters, on every card pair.
        for slot1 in IOCardType.allCases {
            for slot2 in IOCardType.allCases {
                let plain = CardLayout(slot1: slot1, slot2: slot2)
                let withPort2 = CardLayout(slot1: slot1, slot2: slot2, converters: system)
                #expect(withPort2.converterLayout == nil)
                #expect(withPort2.inputRoutingColumns == plain.inputRoutingColumns)
                #expect(withPort2.outputRoutingColumns == plain.outputRoutingColumns)
                #expect(withPort2.converterPairNames(isInput: false, pairCount: 16) == nil)
            }
        }
    }

    @Test("A refused route goes back alone; accepted and newer ones stay")
    func revertRefusedOnly() {
        let previous = ConverterRoutingEdits(outputs: [0: 70], inputs: [2: 5])
        let attempted = ConverterRoutingEdits(outputs: [0: 80, 1: 81], inputs: [2: 6])
        let refused = [ConverterRouting.outputCommand(bus: 1, source: 81)]
        #expect(attempted.reverting(refused, attempted: attempted, previous: previous)
                == ConverterRoutingEdits(outputs: [0: 80], inputs: [2: 6]))
        // A newer change to the refused route stays.
        var newer = attempted; newer.outputs[1] = 90
        #expect(newer.reverting(refused, attempted: attempted, previous: previous).outputs[1] == 90)
        // An input route.
        let refusedInput = [ConverterRouting.inputCommand(host: 2, bus: 6)]
        #expect(attempted.reverting(refusedInput, attempted: attempted, previous: previous).inputs[2] == 5)
        // A refused Reset Routing puts everything back.
        let reset = [ConverterRouting.resetRoutingCommand]
        #expect(ConverterRoutingEdits().reverting(reset, attempted: ConverterRoutingEdits(), previous: previous)
                == previous)
    }
}

@Suite("Port status messages")
struct PortStatusMessageTests {
    @Test func apogeeWording() {
        let verify = "\nVerify that the hardware is properly connected and powered on."
        let absent = "No hardware has been detected on the primary port of the ThunderBridge." + verify
        let busHeadline = "A bus error has occurred on the Primary port of the ThunderBridge."
        let bus = busHeadline + verify
        let absentPCIe = "No hardware has been detected on the primary port of the Symphony 64 PCIe card." + verify
        #expect(PortStatusMessage.primary(.noHardware) == absent)
        #expect(PortStatusMessage.primary(.busError) == bus)
        #expect(PortStatusMessage.primary(.other) == nil)
        let pcie = PortStatusMessage.cardPhrase(pciIdentifier: "pci19c2,2100")
        #expect(pcie == "the Symphony 64 PCIe card")
        #expect(PortStatusMessage.cardPhrase(pciIdentifier: "pci19c2,2200") == "the ThunderBridge")
        #expect(PortStatusMessage.cardPhrase(pciIdentifier: nil) == "the ThunderBridge")
        #expect(PortStatusMessage.primary(.noHardware, card: pcie) == absentPCIe)
        #expect(PortStatusMessage.headline(bus) == busHeadline)
    }

    /// The status bar's short text: the port is named only when both ports are
    /// in use, and the full message is untouched (it is the pop-up's text).
    @Test func shortStatusNamesThePortOnlyWhenBothAreInUse() {
        typealias M = PortStatusMessage
        #expect(M.shortStatus(.noHardware, port: .primary, bothPortsInUse: false) == "No hardware detected")
        #expect(M.shortStatus(.noHardware, port: .secondary, bothPortsInUse: false) == "No hardware detected")
        #expect(M.shortStatus(.busError, port: .primary, bothPortsInUse: false) == "Bus error")
        #expect(M.shortStatus(.busError, port: .secondary, bothPortsInUse: false) == "Bus error")
        #expect(M.shortStatus(.noHardware, port: .primary, bothPortsInUse: true) == "No hardware detected on port 1")
        #expect(M.shortStatus(.noHardware, port: .secondary, bothPortsInUse: true) == "No hardware detected on port 2")
        #expect(M.shortStatus(.busError, port: .primary, bothPortsInUse: true) == "Bus error on port 1")
        #expect(M.shortStatus(.busError, port: .secondary, bothPortsInUse: true) == "Bus error on port 2")
        #expect(M.shortStatus(.other, port: .primary, bothPortsInUse: false) == nil)
        #expect(M.shortStatus(.other, port: .secondary, bothPortsInUse: true) == nil)
        #expect(M.infoLabel == "About this message")
    }

    @Test func secondPortNotFound() {
        // 64 channels refused because nothing answered on port 2 (reason 1).
        let refused = SecondPortState(portCount: 2, audio: 0x11 | (1 << 8))
        let headline = "No hardware has been detected on the secondary port of the Symphony 64 PCIe card."
        let expected = headline + "\nVerify that the hardware is properly connected and powered on."
        #expect(refused.plainProblemText(card: "the Symphony 64 PCIe card") == expected)
        // A clock failure uses the original clock status.
        let other = SecondPortState(portCount: 2, audio: 0x11 | (3 << 8))
        #expect(other.plainProblemText == "Clock Mismatch")
        var model = PortSelectionModel()
        model.deviceReported(dataSourceID: 0, state: SecondPortState(portCount: 2, audio: 0x01),
                             card: "the Symphony 64 PCIe card")
        _ = model.userChose(.ports1And2)
        model.deviceReported(dataSourceID: 0, state: refused, card: "the Symphony 64 PCIe card")
        #expect(model.notice?.hasPrefix(headline) == true)
    }
}
