import Foundation
import Testing
@testable import MaestroCore
@testable import MaestroDevice

@Suite("Two-unit ThunderBridge settings bundles")
struct TwoUnitPresetTests {
    let fixtures = ThunderboltPresetTests()

    func bundle() throws -> ThunderboltPreset {
        var a = try fixtures.fixture()
        var b = a
        b.globals.removeValue(forKey: AudioPropertySelector.clockSource.rawValue)
        b.globals[AudioPropertySelector.outputLevel.rawValue] = 41
        b.inputRoutes = Array(32..<64)
        b.metadata.inputChannelStates[0].softLimit = 4
        b.mixers[0].channels[0].level = -33
        a.version = 2
        a.cardInputRoutes = Array(0..<64)
        a.cardInputRoutes?[0] = 39
        a.outputRoutes += Array(32..<64)
        a.outputRoutes[32] = 2
        a.unitB = .init(b)
        return a
    }

    @Test func saveChangeLoadBothUnits() throws {
        let original = try bundle()
        let a = ThunderboltPresetTests.SimulatedThunderBridge()
        let b = ThunderboltPresetTests.SimulatedThunderBridge()
        func recall(_ preset: ThunderboltPreset) throws {
            let aWrites = try preset.writes(layout: fixtures.layout, hostChannels: 64)
            let savedB = try #require(preset.unitB)
            let bWrites = try savedB.preset(layout: fixtures.layout).writes(layout: fixtures.layout, hostChannels: 64, peripheralB: true)
            try ThunderboltPreset.recall(aWrites, send: a.send, unlock: a.unlock, retryDelay: {})
            try ThunderboltPreset.recall(bWrites, send: b.send, unlock: b.unlock, retryDelay: {})
        }
        try recall(original)
        let aBefore = a.properties, bBefore = b.properties, routes = a.routes, cardInputs = a.cardInputs
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("B4c-\(UUID().uuidString).mst2")
        defer { try? FileManager.default.removeItem(at: url) }
        try original.writeBundle(to: url)
        a.properties = aBefore.mapValues { _ in .uint32(255) }
        b.properties = bBefore.mapValues { _ in .uint32(255) }
        a.routes.removeAll(); a.cardInputs.removeAll()
        let (loaded, legacy) = try ThunderboltPreset.loadBundle(from: url, layout: fixtures.layout)
        try recall(loaded)
        #expect(!legacy && loaded == original)
        #expect(a.properties == aBefore && b.properties == bBefore)
        #expect(a.routes == routes && a.cardInputs == cardInputs)
        #expect(a.properties != b.properties)
        #expect(a.trace.suffix(2) == ["0xDD 0", "read 0xDD"])
        #expect(b.trace.suffix(2) == ["0xDD 0", "read 0xDD"])
    }

    @Test func missingAndMismatchedBLeaveItsRegistersAlone() throws {
        let preset = try bundle()
        let mismatch = CardLayout(slot1: .analogADDA16, slot2: .none)
        #expect(preset.unitBSkipReason(layout: nil, configured: false) != nil)
        #expect(preset.unitBSkipReason(layout: mismatch, configured: true) != nil)
        #expect(preset.unitBSkipReason(layout: fixtures.layout, configured: true) == nil)
        let a = ThunderboltPresetTests.SimulatedThunderBridge()
        let writes = try preset.writes(layout: fixtures.layout, hostChannels: 32)
        try ThunderboltPreset.recall(writes, send: a.send, unlock: a.unlock, retryDelay: {})
        #expect(a.routes.count == 32 && a.routes[32] == nil)
        #expect(a.cardInputs[0] == -1)
        #expect(a.properties[PropertyAddress(selector: .outputLevel)] == .uint32(23))
    }

    @Test func oldBundlesAndIdentityExtension() throws {
        var old = try fixtures.fixture()
        old.cardInputRoutes = Array(0..<32)
        old.cardInputRoutes?[0] = 12
        let data = try PropertyListEncoder().encode(old)
        let decoded = try PropertyListDecoder().decode(ThunderboltPreset.self, from: data)
        #expect(decoded.unitB == nil && decoded.version == 1)
        let writes = try decoded.writes(layout: fixtures.layout, hostChannels: 64)
        let card = ThunderboltPresetTests.SimulatedThunderBridge()
        try ThunderboltPreset.recall(writes, send: card.send, unlock: card.unlock, retryDelay: {})
        #expect(card.cardInputs[0] == 12)
        for channel in 32..<64 {
            #expect(card.cardInputs[channel] == channel)
            #expect(card.routes[UInt8(channel)]?.slot == UInt8(64 + channel))
        }
        let firstPeripheral = try #require(writes.firstIndex { !$0.isCardRoute })
        let cardFirst = writes.prefix(firstPeripheral).allSatisfy(\.isCardRoute)
        #expect(cardFirst)
        let lateCard = writes.suffix(from: firstPeripheral).contains(where: \.isCardRoute)
        #expect(!lateCard)
        let legacy = try ThunderboltPreset.legacy(MaestroPreset(), layout: fixtures.layout)
        #expect(legacy.unitB == nil)
    }

    @Test func unitBHasNoCardMastersClockOrUnitAInputStrips() throws {
        let saved = try #require(bundle().unitB)
        let writes = try saved.preset(layout: fixtures.layout).writes(layout: fixtures.layout, hostChannels: 64, peripheralB: true)
        let cardWrites = writes.contains(where: \.isCardRoute)
        #expect(!cardWrites)
        for write in writes {
            guard case .property(let address, _) = write else { continue }
            #expect(address.selector != .clockSource && address.selector != .mixerSoftwareReturnID)
            if [.mixerChannelLevel, .mixerChannelMute, .mixerChannelPan, .mixerChannelSolo].contains(address.selector) {
                #expect((32..<64).contains(address.element & 0xFFFF))
            }
        }
    }

    @Test func resetCoversTheWholeCardAndBothLocalTables() throws {
        let cardIn = ThunderboltPreset.cardReset(input: true, layouts: [fixtures.layout, fixtures.layout])
        let cardOut = ThunderboltPreset.cardReset(input: false, layouts: [fixtures.layout, fixtures.layout])
        #expect(cardIn.count == 64 && cardOut.count == 64)
        let local = try ThunderboltPreset.peripheralReset(layout: fixtures.layout, input: true) { _ in nil }
        #expect(local.count == 32)
        for (index, write) in local.enumerated() {
            guard case .property(let address, _) = write else { Issue.record("Not a peripheral route"); continue }
            #expect(address.element == UInt32(192 + index))
            #expect(address.scope == .input)
        }
        let headphones = try ThunderboltPreset.peripheralReset(layout: fixtures.layout, input: false) { $0 == .headphone1RoutingID ? 3 : 9 }
        #expect(headphones.count == 4)
        #expect(headphones.first == .property(PropertyAddress(selector: .routing, scope: .output, element: 224), .uint32(6)))
    }

    final class Transport: VendorTransport, @unchecked Sendable {
        var isConnected = true
        var sent: [(UInt8, UInt8)] = []
        var failure: Int?
        var step = 0
        var afterSend: (() -> Void)?
        var identityByte: UInt8 = 0
        func sendVendorCommand(command: UInt8, value: UInt32, payload: Data, port: UInt8) throws {
            defer { step += 1 }
            if step == failure { throw DeviceConnectionError.notConnected }
            sent.append((command, port))
            afterSend?()
        }
        func readVendorCommand(command: UInt8, value: UInt32, responseLength: Int, port: UInt8) throws -> Data {
            Data(repeating: command == 0xC0 ? identityByte : 0, count: responseLength)
        }
    }

    func connection(_ transport: Transport, channels: Int = 64, configured: Bool = true,
                    topology: SymphonyRoutingModel.Topology = .symphonyOnly,
                    layout: CardLayout? = nil) -> ThunderboltUnitBConnection {
        let layout = layout ?? fixtures.layout
        return ThunderboltUnitBConnection(identifier: SimulatedDevice.symphonyIO32ch().identifier, transport: transport,
            infoRouting: { .init(topology: topology, hostChannels: channels, unitBConfigured: configured) },
            state: { UnitBState(present: true, boardType: [layout.slot1.rawValue, layout.slot2.rawValue], boardValid: [1, 1],
                               prefix: 66, clockSource: 3, setupFlags: configured ? 1 : 0, txErrors: 0) })
    }

    @Test func everyFailedBWriteStillUnlocksOnlyB() throws {
        let saved = try #require(bundle().unitB)
        let planned = try saved.preset(layout: fixtures.layout).writes(layout: fixtures.layout, hostChannels: 64, peripheralB: true)
        let baseline = Transport()
        try connection(baseline).applyPresetWrites(planned, layout: fixtures.layout) { _, _ in }
        for failedSend in 0..<(baseline.step - 1) {
            let transport = Transport()
            transport.failure = failedSend
            let b = connection(transport)
            #expect(throws: (any Error).self) {
                try b.applyPresetWrites(planned, layout: fixtures.layout) { _, _ in }
            }
            #expect(transport.sent.last?.0 == 0xDD)
            #expect(transport.sent.allSatisfy { $0.1 == 1 })
        }
        let transport = Transport()
        #expect(throws: (any Error).self) {
            try connection(transport).applyPresetWrites(planned, layout: fixtures.layout) { _, _ in
                throw DeviceConnectionError.notConnected
            }
        }
        #expect(transport.sent.last?.0 == 0xDD)
    }

    @Test func unreadableBIdentityCannotAuthorizePhantom() throws {
        let layout = CardLayout(slot1: .analogADDA16, slot2: .micPre8)
        var saved = try #require(bundle().unitB)
        saved.boards = [layout.slot1.rawValue, layout.slot2.rawValue]
        saved.metadata.inputChannelStates[0].inputType = AnalogInputLevel.mic.rawValue
        saved.metadata.inputChannelStates[0].phantom = true
        for index in saved.mixers.indices {
            saved.mixers[index].channels = Array(saved.mixers[index].channels.prefix(layout.mixerChannelCount))
        }
        // Bundles never switch phantom on (safety departure until C2), even with
        // the same boards, channel and a readable matching identity.
        saved.unitID = Data(repeating: 17, count: 8)
        let valid = Transport()
        valid.identityByte = 17
        let accepted = try connection(valid, layout: layout).presetWrites(saved, layout: layout)
        let restoresPhantom = accepted.contains(.property(PropertyAddress(selector: .phantom), .bool(true)))
        #expect(!restoresPhantom)
        for byte: UInt8 in [0, 255] {
            saved.unitID = Data(repeating: byte, count: 8)
            let transport = Transport()
            transport.identityByte = byte
            let b = connection(transport, layout: layout)
            let writes = (try? b.presetWrites(saved, layout: layout)) ?? []
            #expect(!writes.contains(.property(PropertyAddress(selector: .phantom), .bool(true))))
            #expect(transport.sent.isEmpty)
        }
    }

    @Test func disconnectMidSequenceNeverRetargetsOrContinues() throws {
        let transport = Transport()
        let b = connection(transport)
        transport.afterSend = { b.invalidate() }
        #expect(throws: (any Error).self) {
            try b.applyPresetWrites([.frontPanel(1), .frontPanel(2)], layout: fixtures.layout) { _, _ in }
        }
        #expect(transport.sent.count == 1)
        #expect(transport.sent.first?.1 == 1)
    }

    @Test func gatesRefuse32UnconfiguredConvertersAndStaleConnection() throws {
        for b in [connection(Transport(), channels: 32), connection(Transport(), configured: false),
                  connection(Transport(), topology: .unknown), connection(Transport(), topology: .symphonyAndConverters([]))] {
            #expect(throws: (any Error).self) { try b.checkPresetLayout(fixtures.layout) }
        }
        let transport = Transport()
        let b = connection(transport)
        b.invalidate()
        #expect(throws: (any Error).self) {
            try b.applyPresetWrites([.frontPanel(1)], layout: fixtures.layout) { _, _ in }
        }
        #expect(transport.sent.isEmpty)
    }
}
