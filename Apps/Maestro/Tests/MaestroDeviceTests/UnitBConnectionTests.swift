import Foundation
import Testing
@testable import MaestroDevice
@testable import MaestroCore

/// Records what a connection hands the driver, with the port byte.
final class RecordingVendorTransport: VendorTransport, @unchecked Sendable {
    struct Sent: Equatable { let command: UInt8; let value: UInt32; let payload: Data; let port: UInt8 }
    struct Read: Equatable { let command: UInt8; let value: UInt32; let length: Int; let port: UInt8 }
    var sent: [Sent] = []
    var reads: [Read] = []
    var reply: [UInt8] = [0x07]
    var failRead = false
    var emptyRead = false
    var isConnected: Bool { true }
    func sendVendorCommand(command: UInt8, value: UInt32, payload: Data, port: UInt8) throws {
        sent.append(Sent(command: command, value: value, payload: payload, port: port))
    }
    func readVendorCommand(command: UInt8, value: UInt32, responseLength: Int, port: UInt8) throws -> Data {
        if failRead { throw DeviceConnectionError.notConnected }
        if emptyRead { return Data() }
        reads.append(Read(command: command, value: value, length: responseLength, port: port))
        let bytes = Array(reply.prefix(responseLength)) + [UInt8](repeating: 0, count: max(0, responseLength - reply.count))
        return Data(bytes)
    }
}

@Suite("Unit B: vendor bytes carry port 2")
struct UnitBConnectionTests {
    static let state = UnitBState(present: true, boardType: [IOCardType.analogADDA16.rawValue, IOCardType.optical.rawValue],
                                  boardValid: [1, 1], prefix: 0x42, clockSource: 2, setupFlags: 1, txErrors: 0)

    private func connection(_ t: RecordingVendorTransport, state: UnitBState? = Self.state) -> ThunderboltUnitBConnection {
        ThunderboltUnitBConnection(identifier: SimulatedDevice.symphonyIO32ch().identifier, transport: t,
                                   state: { state })
    }

    @Test("The 78-byte command input: unit A port 0, unit B port 1, nothing else differs")
    func packedCommandBytes() {
        let a = DextUserClient.packVendorCommand(command: 0x20, value: 0x0001_0003, payload: Data([0x2A]), port: 0)
        let b = DextUserClient.packVendorCommand(command: 0x20, value: 0x0001_0003, payload: Data([0x2A]), port: 1)
        var expected = [UInt8](repeating: 0, count: 78)
        expected.replaceSubrange(0..<15, with: [0x50, 0x4D, 0x59, 0x53, 0x20, 0x00, 0x00, 0x00,
                                                0x03, 0x00, 0x01, 0x00, 0x01, 0x00, 0x2A])
        #expect([UInt8](a) == expected)
        expected[5] = 0x01
        #expect([UInt8](b) == expected)
    }

    @Test("The 14-byte read input: port byte at offset 5")
    func packedReadBytes() {
        let a = DextUserClient.packVendorRead(command: 0x35, value: 1, responseLength: 1, port: 0)
        let b = DextUserClient.packVendorRead(command: 0x35, value: 1, responseLength: 1, port: 1)
        #expect([UInt8](a) == [0x50, 0x4D, 0x59, 0x53, 0x35, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00])
        #expect([UInt8](b) == [0x50, 0x4D, 0x59, 0x53, 0x35, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00])
    }

    /// One value per mapped selector the pages write.
    static let writes: [(PropertyAddress, PropertyValue)] = [
        (PropertyAddress(selector: .micGain, scope: .input, element: 3), .uint32(40)),
        (PropertyAddress(selector: .instrumentGain, scope: .input, element: 3), .uint32(90)),
        (PropertyAddress(selector: .phantom, scope: .input, element: 2), .bool(true)),
        (PropertyAddress(selector: .phaseReverse, scope: .input, element: 1), .bool(true)),
        (PropertyAddress(selector: .highPassFilter, scope: .input, element: 0), .bool(true)),
        (PropertyAddress(selector: .softLimit, scope: .input, element: 4), .uint32(1)),
        (PropertyAddress(selector: .analogIOType, scope: .input, element: 5), .uint32(2)),
        (PropertyAddress(selector: .analogIOType, scope: .output, element: 6), .uint32(0x7F01)),
        (PropertyAddress(selector: .digitalRefLevel, scope: .output, element: 7), .uint32(1)),
        (PropertyAddress(selector: .outputLevel), .uint32(12)),
        (PropertyAddress(selector: .outputMute), .bool(true)),
        (PropertyAddress(selector: .outputDim), .bool(true)),
        (PropertyAddress(selector: .outputSumToMono), .bool(true)),
        (PropertyAddress(selector: .headphone1Level), .uint32(20)),
        (PropertyAddress(selector: .headphone2Mute), .bool(true)),
        (PropertyAddress(selector: .activeSpeakerSet), .uint32(3)),
        (PropertyAddress(selector: .peaksClear), .uint32(1)),
        (PropertyAddress(selector: .peakHoldMode), .uint32(1)),
        (PropertyAddress(selector: .oversHoldMode), .uint32(2)),
        (PropertyAddress(selector: .opticalInFormat, element: 1), .uint32(1)),
        (PropertyAddress(selector: .opticalOutFormat, element: 0), .uint32(1)),
    ]

    @Test("Every unit B write is the mapper's request with port byte 1")
    func everyWriteOnPort2() async throws {
        for (address, value) in Self.writes {
            let t = RecordingVendorTransport()
            try await connection(t).setProperty(address, value: value)
            let request = try SymphonyIOPropertyMapper.buildWriteRequest(for: address, value: value)
            #expect(t.sent == [.init(command: request.request, value: DextUserClient.nValue(for: request),
                                     payload: request.data, port: 1)], "\(address.selector)")
        }
    }

    @Test("Optical format on unit B is vendor command 0x34 to the board, port 1")
    func opticalFormatIsAVendorCommand() async throws {
        let t = RecordingVendorTransport()
        try await connection(t).setProperty(PropertyAddress(selector: .opticalOutFormat, element: 1), value: .uint32(1))
        #expect(t.sent.count == 1)
        #expect(t.sent.first?.command == 0x34)
        #expect(t.sent.first?.value == 1)
        #expect(t.sent.first?.payload == Data([1]))
        #expect(t.sent.first?.port == 1)
    }

    @Test("Identify on unit B uses command 0x33 and port byte 1")
    func identifyUsesUnitBPort() async throws {
        let t = RecordingVendorTransport()
        let c = connection(t)
        try await c.setProperty(PropertyAddress(selector: .identify), value: .bool(true))
        #expect(t.sent == [RecordingVendorTransport.Sent(command: 0x33, value: 0,
                                                          payload: Data([1]), port: 1)])
    }

    @Test("Unit B reads go out on port 1")
    func readsOnPort2() async throws {
        let t = RecordingVendorTransport()
        t.reply = [0x0C]
        let c = connection(t)
        #expect(try await c.getProperty(PropertyAddress(selector: .outputLevel)) == .uint32(12))
        #expect(try await c.getProperty(PropertyAddress(selector: .opticalInFormat, element: 1)) == .uint32(12))
        #expect(t.reads.count == 2)
        #expect(t.reads.allSatisfy { $0.port == 1 })
        #expect(t.reads.last?.command == 0x34)
    }

    @Test("Board types, clock and prefix come from the driver's unit B report, without bus traffic")
    func reportReads() async throws {
        let t = RecordingVendorTransport()
        let c = connection(t)
        #expect(try await c.getProperty(PropertyAddress(selector: .primaryBoardType))
                == .uint32(UInt32(IOCardType.analogADDA16.rawValue)))
        #expect(try await c.getProperty(PropertyAddress(selector: .secondaryBoardType))
                == .uint32(UInt32(IOCardType.optical.rawValue)))
        #expect(try await c.getProperty(PropertyAddress(selector: .clockSource)) == .uint32(2))
        #expect(try await c.getProperty(PropertyAddress(selector: .prefix)) == .string("B"))
        #expect(t.reads.isEmpty && t.sent.isEmpty)
    }

    @Test("Clock, sample rate, mixer and routing are not unit B's: refused, nothing sent")
    func notUnitB() async {
        let t = RecordingVendorTransport()
        let c = connection(t)
        let addresses = [PropertyAddress(selector: .clockSource), PropertyAddress(selector: .sampleRate),
                         PropertyAddress(selector: .mixerChannelLevel, element: 1 << 16 | 32),
                         PropertyAddress(selector: .mixerSoftwareReturnID, element: 1 << 16),
                         PropertyAddress(selector: .routing, scope: .output, element: 32)]
        for address in addresses {
            await #expect(throws: DeviceConnectionError.self) {
                try await c.setProperty(address, value: .uint32(1))
            }
        }
        #expect(t.sent.isEmpty)
    }

    @Test("Prefix, Speaker Mode and the coax settings go to unit B now that the driver keeps the units apart")
    func unitOnlyWrites() async throws {
        #expect(ThunderboltUnitBConnection.driverKeepsUnitsApart == true)
        let t = RecordingVendorTransport()
        let c = ThunderboltUnitBConnection(identifier: SimulatedDevice.symphonyIO32ch().identifier, transport: t,
                                           settingsStore: DeviceSettingsStore(), state: { Self.state })
        // Speaker Mode 2 = Stereo (a legal SymphonyIOSpeakerMode); coax 1 = a pair.
        try await c.setProperty(PropertyAddress(selector: .speakerOutputMode), value: .uint32(2))
        for selector in [AudioPropertySelector.spdifReplaceID, .spdifMirrorID] {
            try await c.setProperty(PropertyAddress(selector: selector, scope: .input, element: 0), value: .uint32(1))
        }
        #expect(!t.sent.isEmpty)
        #expect(t.sent.allSatisfy { $0.port == 1 })
    }

    @Test("Owned settings are kept in unit B's store and replayed on port 1")
    func storedAndReplayed() async throws {
        let t = RecordingVendorTransport()
        let c = ThunderboltUnitBConnection(identifier: SimulatedDevice.symphonyIO32ch().identifier, transport: t,
                                           settingsStore: DeviceSettingsStore(), state: { Self.state })
        try await c.setProperty(PropertyAddress(selector: .peakHoldMode), value: .uint32(1))
        #expect(try await c.getProperty(PropertyAddress(selector: .peakHoldMode)) == .uint32(1))
        t.sent = []
        let replay = await c.reapplyStoredSettings()
        #expect(replay.applied == 1)
        #expect(t.sent.count == 1 && t.sent.first?.port == 1)
    }

    /// Explicit wire expectations, independent of the mapper under test.
    static let monitorWire: [(AudioPropertySelector, UInt8, UInt32, PropertyValue)] = [
        (.headphone1Level, 0x23, 0, .uint32(41)), (.headphone2Level, 0x23, 1, .uint32(51)),
        (.headphone1Mute, 0x24, 0, .bool(true)), (.headphone2Mute, 0x24, 1, .bool(true)),
        (.speakerOutputMode, 0x25, 0, .uint32(2)),
        (.outputLevel, 0x26, 0, .uint32(31)), (.outputMute, 0x27, 0, .bool(true)),
        (.headphone1Dim, 0xE7, 0, .bool(true)), (.headphone2Dim, 0xE7, 1, .bool(true)),
        (.outputDim, 0xE7, 2, .bool(true)),
        (.headphone1SumToMono, 0xE8, 0, .bool(true)), (.headphone2SumToMono, 0xE8, 1, .bool(true)),
        (.outputSumToMono, 0xE8, 2, .bool(true)), (.activeSpeakerSet, 0xE9, 0, .uint32(3)),
    ]

    @Test("All B monitor selectors use their firmware indices and port 1 for reads and writes")
    func monitorWire() async throws {
        let t = RecordingVendorTransport()
        let c = connection(t)
        for (selector, opcode, index, value) in Self.monitorWire {
            let address = PropertyAddress(selector: selector)
            let byte = UInt8(value.asUInt32 ?? (value.asBool == true ? 1 : 0))
            t.reply = [byte]
            try await c.setProperty(address, value: value)
            #expect(t.sent.last == .init(command: opcode, value: index, payload: Data([byte]), port: 1))
            #expect(try await c.getProperty(address) == value)
            #expect(t.reads.last == .init(command: opcode, value: index, length: 1, port: 1))
            #expect(await c.isPropertySettable(address))
        }
    }

    @Test("B monitor recall never returns or replays host settings, including failed reads")
    func monitorHardwareRecall() async throws {
        let t = RecordingVendorTransport()
        let store = DeviceSettingsStore()
        for (selector, _, _, value) in Self.monitorWire {
            store.record(value, for: PropertyAddress(selector: selector))
        }
        let c = ThunderboltUnitBConnection(identifier: SimulatedDevice.symphonyIO32ch().identifier,
                                           transport: t, settingsStore: store, state: { Self.state })
        #expect(await c.reapplyStoredSettings().applied == 0)
        #expect(t.sent.isEmpty)
        for (selector, _, _, _) in Self.monitorWire {
            t.failRead = true
            await #expect(throws: DeviceConnectionError.self) {
                try await c.getProperty(PropertyAddress(selector: selector))
            }
            t.failRead = false
            t.emptyRead = true
            await #expect(throws: DeviceConnectionError.self) {
                try await c.getProperty(PropertyAddress(selector: selector))
            }
            t.emptyRead = false
        }
        await c.disconnect()
        await #expect(throws: DeviceConnectionError.self) {
            try await c.setProperty(PropertyAddress(selector: .outputLevel), value: .uint32(0))
        }
        #expect(t.sent.isEmpty)
    }

    @Test("Selector 11 decodes; a non-zero status is not a reading")
    func decodeUnitB() {
        var bytes = [UInt8](repeating: 0, count: 40)
        bytes[4] = 1; bytes[8] = 7; bytes[9] = 0; bytes[10] = 1; bytes[11] = 0
        bytes[12] = 0x42; bytes[13] = 2; bytes[16] = 1; bytes[20] = 3
        let s = UnitBState.decode(bytes)
        #expect(s == UnitBState(present: true, boardType: [7, 0], boardValid: [1, 0], prefix: 0x42,
                                clockSource: 2, setupFlags: 1, txErrors: 3))
        #expect(s?.info?.slot1 == IOCardType(rawValue: 7))
        #expect(s?.info?.slotValid == [true, false])
        bytes[0] = 1
        #expect(UnitBState.decode(bytes) == nil)
        #expect(UnitBState.decode([UInt8](repeating: 0, count: 39)) == nil)
        #expect(UnitBState(present: false, boardType: [0, 0], boardValid: [0, 0], prefix: 0,
                           clockSource: 0, setupFlags: 0, txErrors: 0).info == nil)
    }
}

@Suite("Unit B: card routing and meters")
struct UnitBCardTests {
    @Test("Unit B outputs are XLink TX 32-63")
    func unitBRoutes() {
        let board0 = SymphonyIORoutingAddress.ioBoard0Base
        let board1 = SymphonyIORoutingAddress.ioBoard1Base
        let r = ThunderboltCardRouting.unitBRoute(destination: board0, slot: ThunderboltCardRouting.playbackSlot(channel: 32))
        #expect(r == .init(channel: 32, slot: 96, enabled: true))
        #expect(r?.payload == Data([32, 96, 1]))
        #expect(ThunderboltCardRouting.unitBRoute(destination: board1 + 15,
                                                  slot: ThunderboltCardRouting.mixerSlot(mixer: 1, side: 1))
                == .init(channel: 63, slot: 131, enabled: true))
        #expect(ThunderboltCardRouting.unitBRoute(destination: board1, slot: nil)
                == .init(channel: 48, slot: 112, enabled: false))
        #expect(ThunderboltCardRouting.unitBRoute(destination: 0, slot: 64) == nil)
        #expect(ThunderboltCardRouting.playbackSlot(channel: 64) == nil)
        // Unit A's routes are unchanged.
        #expect(ThunderboltCardRouting.route(destination: board0, source: 0) == .init(channel: 0, slot: 64, enabled: true))
    }

    @Test("Unit B's input meters are words 32-63, its playback 96-127")
    func meterWords() {
        let layout = CardLayout(slot1: .analogAES, slot2: .analogAD16, isKnown: true)
        let a = ThunderboltInputMeterMap.words(
            layout: layout, routes: ThunderboltInputMeterMap.currentRoutes(slot1: .analogAES, replayed: []))
        let b = UnitBMeterMap.inputWords(layout: layout)
        #expect(b.channels.count == a.channels.count)
        #expect(b.channels == a.channels.map { $0.map { $0 + 32 } })
        #expect(b.channels.compactMap { $0 }.allSatisfy { (32..<64).contains($0) })
        #expect(b.digital == a.digital.map { $0.map { $0 + 32 } })
        #expect(UnitBMeterMap.playbackWord(channel: 0) == 96)
        #expect(UnitBMeterMap.playbackWord(channel: 31) == 127)
        var host = [Double](repeating: -60, count: 64)
        host[32 + 16] = -6      // unit B's A16 Line 1, on its host input 17
        let levels = ThunderboltInputMeterMap.stripLevels(host: host, words: b, count: b.channels.count)
        #expect(levels[8] == -6)
        #expect(UnitBMeterMap.outputLevels(dB: { Double($0) }, count: 3) == [96, 97, 98])
    }
}

@Suite("Unit B: saved state keys")
struct UnitBPersistenceTests {
    @Test("Unit B's channel state never shares unit A's key, even with the same cards")
    func channelStateKeys() throws {
        let suite = "unitB-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let layout = CardLayout(slot1: .analogADDA16, slot2: .none, isKnown: true)
        let a = ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: false)
        let b = ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: false, unit: .b)
        #expect(a.key("inputChannelStates") == "inputChannelStates.analogADDA16+none")
        #expect(b.key("inputChannelStates") == "inputChannelStates.unitB:analogADDA16+none")
        // Unit B never inherits or claims the legacy unscoped key.
        defaults.set(Data([1, 2, 3]), forKey: "inputChannelStates")
        #expect(b.loadData("inputChannelStates") == nil)
        #expect(defaults.string(forKey: ChannelStateStore.claimKey("inputChannelStates")) == nil)
        b.saveData(Data([9]), for: "inputChannelStates")
        #expect(a.loadData("inputChannelStates") == Data([1, 2, 3]))
        // Unknown cards: unit B still has its own key, never the legacy one.
        let unknown = ChannelStateStore(defaults: defaults, layout: CardLayout(isKnown: false),
                                        isSimulatingCards: false, unit: .b)
        #expect(unknown.key("outputChannelStates") == "outputChannelStates.unitB")
        let sim = ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: true, unit: .b)
        #expect(sim.key("x") == "x.sim:unitB:analogADDA16+none")
    }

    @Test("Unit B's device settings have their own key; unit A's is unchanged")
    func deviceSettingsKeys() throws {
        #expect(DeviceSettingsStore.defaultsKey(productID: 0x12) == "deviceSettings_18_v1")
        #expect(DeviceSettingsStore.defaultsKey(productID: 0x12, unit: .a) == "deviceSettings_18_v1")
        #expect(DeviceSettingsStore.defaultsKey(productID: 0x12, unit: .b) == "deviceSettings_18_unitB_v1")
        let suite = "unitB-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = DeviceSettingsStore(defaults: defaults, productID: 0x12)
        let b = DeviceSettingsStore(defaults: defaults, productID: 0x12, unit: .b)
        a.record(.uint32(1), for: PropertyAddress(selector: .peakHoldMode))
        b.record(.uint32(2), for: PropertyAddress(selector: .peakHoldMode))
        #expect(DeviceSettingsStore(defaults: defaults, productID: 0x12)
                    .value(for: PropertyAddress(selector: .peakHoldMode)) == .uint32(1))
        #expect(DeviceSettingsStore(defaults: defaults, productID: 0x12, unit: .b)
                    .value(for: PropertyAddress(selector: .peakHoldMode)) == .uint32(2))
    }
}
