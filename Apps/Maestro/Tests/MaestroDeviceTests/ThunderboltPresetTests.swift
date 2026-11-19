import Foundation
import Testing
@testable import MaestroCore
@testable import MaestroDevice

@Suite("ThunderBridge single-unit preset recall")
struct ThunderboltPresetTests {
    let layout = CardLayout(slot1: .optical, slot2: .optical)

    func fixture() throws -> ThunderboltPreset {
        var meta = MaestroPreset()
        meta.createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        meta.inputChannelStates = (0..<layout.analogInputStripCount).map {
            InputChannelState(softLimit: UInt32($0 % 3), inputType: 1,
                              trim: Double($0 % 5) / 10, digitalRefLevel: UInt32($0 % 6))
        }
        meta.outputChannelStates = (0..<layout.analogOutputStripCount).map {
            OutputChannelState(analogRefLevel: UInt32(1 + $0 % 2), digitalRefLevel: UInt32($0 % 6), trim: -0.5)
        }
        meta.channelNames = ["Vocal", "Synth"]
        meta.opticalInFormat = 1
        meta.spdifReplaceID = 2
        meta.spdifMirrorID = 3
        meta.slot2OpticalFormat = 0
        meta.slot2SPDIFReplaceID = 4
        meta.slot2SPDIFMirrorID = 5
        meta.meterBank1Source = 1
        meta.meterBank2Source = 5
        meta.peakHoldMode = 2
        meta.overHoldMode = 3
        var preset = ThunderboltPreset(layout: layout, metadata: meta)
        for selector in ThunderboltPreset.monitorOrder {
            preset.globals[selector.rawValue] = ThunderboltPreset.booleanSelectors.contains(selector) ? 1 : 0
        }
        preset.globals[AudioPropertySelector.speakerOutputMode.rawValue] = 9
        preset.globals[AudioPropertySelector.outputLevel.rawValue] = 23
        preset.globals[AudioPropertySelector.activeSpeakerSet.rawValue] = 3
        preset.globals[AudioPropertySelector.headphone1Level.rawValue] = 17
        preset.globals[AudioPropertySelector.headphone2Level.rawValue] = 31
        preset.globals[AudioPropertySelector.headphone1RoutingID.rawValue] = 3
        preset.globals[AudioPropertySelector.headphone2RoutingID.rawValue] = 9
        preset.globals[AudioPropertySelector.clockSource.rawValue] = 1
        preset.frontPanelSelection = 1
        preset.inputRoutes = (0..<32).map { UInt8(32 + (31 - $0)) }
        preset.outputRoutes = (0..<32).map { UInt8($0) }
        preset.outputRoutes[0] = SymphonyIORoutingAddress.mixer1Base
        preset.outputRoutes[1] = SymphonyIORoutingAddress.mixer1Base + 1
        preset.outputRoutes[2] = SymphonyIORoutingAddress.none
        preset.outputRoutes[3] = SymphonyIORoutingAddress.none
        let defaults = try #require(UserDefaults(suiteName: "B4a-\(UUID().uuidString)"))
        let store = ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: true)
        for mixer in 0..<2 {
            store.save((0..<layout.mixerChannelCount).map {
                MixerChannelState(level: Double(-$0), pan: $0 % 2 == 0 ? -0.5 : 0.5,
                                  isMuted: $0 == mixer, isSoloed: $0 == 3)
            }, for: ChannelStateStore.mixerKey(mixer))
        }
        preset.mixers = (0..<2).map {
            var mixer = ThunderboltPreset.Mixer(snapshot: MixerStateSnapshot(channelCount: layout.mixerChannelCount,
                                                                            mixer: $0, store: store, defaults: defaults))
            mixer.source = UInt32($0 + 2)
            mixer.master = -7 - Double($0)
            mixer.softwareReturn = MixerChannelState(level: -11, pan: 0.25, isMuted: true, isSoloed: false)
            return mixer
        }
        return preset
    }

    /// A simulated card + unit: independent hardware registers survive only
    /// actual sends. The ready check records both the write and the read.
    final class SimulatedThunderBridge {
        var properties: [PropertyAddress: PropertyValue] = [:]
        var routes: [UInt8: ThunderboltCardRouting.Route] = [:]
        var cardInputs: [Int: Int] = [:]
        var frontPanel: UInt8 = 0
        var trace: [String] = []
        var failedStep: Int?
        var step = 0
        var disconnected = false
        func send(_ write: ThunderboltPreset.Write) throws {
            let current = step
            step += 1
            if current == failedStep || disconnected { throw DeviceConnectionError.notConnected }
            trace.append("write")
            switch write {
            case .property(let address, let value): properties[address] = value
            case .output(let route): routes[route.channel] = route
            case .cardInput(let command): cardInputs = SymphonyCardInputRouting.applying([command], to: cardInputs)
            case .frontPanel(let value): frontPanel = value
            }
        }
        func unlock() -> Bool {
            trace += ["0xDD 0", "read 0xDD"]
            return !disconnected
        }
        func recall(_ preset: ThunderboltPreset, layout: CardLayout) throws {
            // Exactly the preflight and executor used by the real connection.
            let writes = try preset.writes(layout: layout)
            try ThunderboltPreset.recall(writes, send: send, unlock: unlock, retryDelay: {})
        }
    }

    @Test func saveChangeLoadRestoresEverySavedHardwareField() throws {
        let original = try fixture()
        let simulated = SimulatedThunderBridge()
        try simulated.recall(original, layout: layout)
        let before = simulated.properties, routes = simulated.routes, frontPanel = simulated.frontPanel
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("B4a-\(UUID().uuidString).mst2")
        defer { try? FileManager.default.removeItem(at: directory) }
        try original.writeBundle(to: directory)
        // Change every hardware register, not just the in-memory preset.
        simulated.properties = before.mapValues { _ in .uint32(255) }
        simulated.routes.removeAll()
        simulated.frontPanel = 0
        let (loaded, legacy) = try ThunderboltPreset.loadBundle(from: directory, layout: layout)
        #expect(!legacy)
        try simulated.recall(loaded, layout: layout)
        #expect(loaded == original)
        #expect(simulated.properties == before)
        #expect(simulated.routes == routes)
        #expect(simulated.frontPanel == frontPanel)
        #expect(simulated.properties[PropertyAddress(selector: .analogIOType, scope: .output, element: 0)] == .uint32(0xFB01))
        #expect(simulated.properties[PropertyAddress(selector: .opticalInFormat, element: 1)] == .uint32(0))
        #expect(simulated.properties[PropertyAddress(selector: .mixerChannelLevel, element: (2 << 16) | 2000)] == .float64(-8))
        #expect(simulated.properties[PropertyAddress(selector: .mixerChannelPan, element: (1 << 16) | 1000)] == .float64(0.25))
        #expect(simulated.routes[2]?.enabled == false)
        #expect(simulated.trace.suffix(2) == ["0xDD 0", "read 0xDD"])
    }

    @Test func cardInputsBundleRoundTripAndRefusal() throws {
        var preset = try fixture()
        preset.cardInputRoutes = Array(0..<32)
        preset.cardInputRoutes?[0] = 12
        preset.cardInputRoutes?[1] = 12
        preset.cardInputRoutes?[2] = -1
        let data = try PropertyListEncoder().encode(preset)
        let loaded = try PropertyListDecoder().decode(ThunderboltPreset.self, from: data)
        let hardware = SimulatedThunderBridge()
        try hardware.recall(loaded, layout: layout)
        #expect(hardware.cardInputs[0] == 12)
        #expect(hardware.cardInputs[1] == 12)
        #expect(hardware.cardInputs[2] == -1)
        #expect(try loaded.writes(layout: layout).first == .cardInput(.init(command: 0xB6, payload: [0, 12, 1])))
        // Older B4a bundles leave this independently owned table alone.
        let old = try fixture()
        let decodedOld = try PropertyListDecoder().decode(ThunderboltPreset.self, from: PropertyListEncoder().encode(old))
        #expect(decodedOld.cardInputRoutes == nil)
        #expect(!(try decodedOld.writes(layout: layout)).contains { if case .cardInput = $0 { return true }; return false })
        for invalid in [[Int](), Array(repeating: 32, count: 32), Array(repeating: -2, count: 32)] {
            preset.cardInputRoutes = invalid
            let untouched = SimulatedThunderBridge()
            #expect(throws: (any Error).self) { try untouched.recall(preset, layout: layout) }
            #expect(untouched.trace.isEmpty)
        }
        // Every card write refusal still executes the original unlock tail.
        for index in 0..<32 {
            let refused = SimulatedThunderBridge()
            refused.failedStep = index
            #expect(throws: (any Error).self) { try refused.recall(loaded, layout: layout) }
            #expect(refused.cardInputs.count == index)
            #expect(refused.trace.suffix(2) == ["0xDD 0", "read 0xDD"])
        }
    }

    @Test func cardInputTableFollowsServingDriverCapability() throws {
        var preset = try fixture()
        preset.cardInputRoutes = Array(0..<32)
        for (build, supported) in [(131, false), (132, true)] {
            var skipped: [String] = []
            let writes = try preset.writes(layout: layout, cardInputSupported: supported,
                                           onSkipped: { skipped.append($0) })
            #expect(writes.contains { if case .cardInput = $0 { return true }; return false } == supported)
            #expect(skipped.isEmpty == supported)
            _ = build
        }
        var unavailableWarnings: [String] = []
        _ = try preset.writes(layout: layout, cardInputSupported: false,
                              onSkipped: { unavailableWarnings.append($0) })
        #expect(unavailableWarnings == ["card input routing not restored: serving driver does not support it"])
    }

    @Test func recallOrderAndNoMuteFirst() throws {
        let writes = try fixture().writes(layout: layout)
        #expect(writes[32] == .property(PropertyAddress(selector: .routing, scope: .input, element: 192), .uint32(63)))
        #expect(writes[0] == .output(.init(channel: 0, slot: 130, enabled: true)))
        let monitor = Array(writes[64..<78])
        let selectors = monitor.compactMap { write -> AudioPropertySelector? in
            if case .property(let address, _) = write { return address.selector }; return nil
        }
        #expect(selectors == [.speakerOutputMode, .outputLevel, .outputMute, .outputDim, .outputSumToMono, .activeSpeakerSet,
                              .headphone1Level, .headphone1Mute, .headphone1Dim, .headphone1SumToMono,
                              .headphone2Level, .headphone2Mute, .headphone2Dim, .headphone2SumToMono])
        #expect(writes[80] == .frontPanel(1))
        let boardStart = try #require(writes.firstIndex(of: .property(PropertyAddress(selector: .spdifReplaceID, scope: .input), .uint32(2))))
        #expect(writes[boardStart + 1] == .property(PropertyAddress(selector: .spdifMirrorID, scope: .output), .uint32(3)))
        #expect(writes[boardStart + 2] == .property(PropertyAddress(selector: .analogIOType, scope: .input), .uint32(1)))
        #expect(writes[boardStart + 3] == .property(PropertyAddress(selector: .digitalRefLevel, scope: .input), .uint32(0)))
        #expect(writes[boardStart + 4] == .property(PropertyAddress(selector: .softLimit, scope: .input), .uint32(0)))
    }

    @Test func mismatchAndMalformedContentWriteNothing() throws {
        let original = try fixture()
        let card = SimulatedThunderBridge()
        #expect(throws: (any Error).self) { try card.recall(original, layout: CardLayout(slot1: .analogAES, slot2: .none)) }
        var invalids = [ThunderboltPreset]()
        var p = original; p.version = 99; invalids.append(p)
        p = original; p.outputRoutes[31] = 100; invalids.append(p)
        p = original; p.metadata.slot2OpticalFormat = 77; invalids.append(p)
        p = original; p.metadata.inputChannelStates.removeLast(); invalids.append(p)
        p = original; p.mixers[1].master = .nan; invalids.append(p)
        p = original; p.globals[AudioPropertySelector.speakerOutputMode.rawValue] = 4; invalids.append(p)
        for invalid in invalids { #expect(throws: (any Error).self) { try card.recall(invalid, layout: layout) } }
        #expect(card.trace.isEmpty)
    }

    @Test func everyFailedWriteStillUnlocksAndReportsFailure() throws {
        let writes = try fixture().writes(layout: layout)
        for failure in writes.indices {
            let card = SimulatedThunderBridge()
            card.failedStep = failure
            #expect(throws: (any Error).self) {
                try ThunderboltPreset.recall(writes, send: card.send, unlock: card.unlock, retryDelay: {})
            }
            #expect(card.step == failure + 1)
            #expect(card.trace.suffix(2) == ["0xDD 0", "read 0xDD"])
        }
    }

    @Test func unlockReadBackRetriesAreBounded() throws {
        var attempts = 0, delays = 0
        try ThunderboltPreset.recall([], send: { _ in }, unlock: {
            attempts += 1
            if attempts < 3 { throw DeviceConnectionError.notConnected }
            return true
        }, retryDelay: { delays += 1 })
        #expect(attempts == 3 && delays == 2)
        let card = SimulatedThunderBridge()
        card.disconnected = true
        #expect(throws: (any Error).self) {
            try ThunderboltPreset.recall(try fixture().writes(layout: layout), send: card.send, unlock: card.unlock, retryDelay: {})
        }
        #expect(card.trace.filter { $0 == "read 0xDD" }.count == 10)
    }

    @Test func oldFlatAndAppMetadataPayloadStillLoads() throws {
        var old = MaestroPreset()
        old.outputLevel = -32
        old.hp1Level = -24
        old.channelNames = ["Old name"]
        let data = try PropertyListEncoder().encode(old)
        let decoded = try PropertyListDecoder().decode(MaestroPreset.self, from: data)
        let preset = try ThunderboltPreset.legacy(decoded, layout: layout)
        let writes = try preset.writes(layout: layout, legacy: true)
        #expect(!writes.contains { if case .property(let a, _) = $0 { return a.selector == .outputLevel || a.selector == .outputMute || a.selector == .outputDim || a.selector == .outputSumToMono || a.selector == .headphone1Level || a.selector == .headphone1Mute || a.selector == .headphone2Level || a.selector == .headphone2Mute }; return false })
        #expect(!writes.contains { if case .output = $0 { return true }; return false })
        #expect(!writes.contains { if case .property(let a, _) = $0 { return a.selector == .speakerOutputMode }; return false })
        #expect(preset.metadata.channelNames == ["Old name"])
    }

    @Test func coaxMirrorZeroIsAValidHardwareValue() throws {
        // A unit can report 0 (Off); capture must not fail on it. The original's
        // Mirrors menu has no Off (OutputChannelLogic.swift:224), so it is not written.
        var preset = try fixture()
        preset.metadata.spdifMirrorID = 0
        let writes = try preset.writes(layout: layout)
        #expect(!writes.contains(.property(PropertyAddress(selector: .spdifMirrorID, scope: .output), .uint32(0))))
    }
    @Test func appOnlyBundleAndFlatFileAreBothLegacy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("B4a-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var meta = MaestroPreset()
        meta.createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        meta.outputLevel = -29
        try meta.save(to: root.appendingPathComponent("MaestroApp.plist"))
        let (bundle, isLegacy) = try ThunderboltPreset.loadBundle(from: root, layout: layout)
        let (flat, flatLegacy) = try ThunderboltPreset.loadBundle(from: root.appendingPathComponent("MaestroApp.plist"), layout: layout)
        #expect(isLegacy && flatLegacy && bundle == flat)
        try Data("unsupported daemon content".utf8).write(to: root.appendingPathComponent("SymphonyIO.plist"))
        #expect(throws: (any Error).self) { try ThunderboltPreset.loadBundle(from: root, layout: layout) }
    }

    @Test func phantomRequiresMatchingIdentityBoardSlotAndMicChannel() throws {
        let preampLayout = CardLayout(slot1: .analogADDA16, slot2: .micPre8)
        var meta = MaestroPreset()
        meta.createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        meta.spdifMirrorID = 1
        meta.inputChannelStates = Array(repeating: InputChannelState(), count: 16)
        meta.outputChannelStates = Array(repeating: OutputChannelState(), count: 16)
        meta.inputChannelStates[0] = InputChannelState(gain: 42, phantom: true, inputType: AnalogInputLevel.mic.rawValue)
        var p = try fixture()
        p.boards = [preampLayout.slot1.rawValue, preampLayout.slot2.rawValue]
        p.metadata = meta
        p.frontPanelSelection = 3
        p.unitID = Data([1, 2, 3, 4, 5, 6, 7, 8])
        for index in p.mixers.indices { p.mixers[index].channels = Array(p.mixers[index].channels.prefix(preampLayout.mixerChannelCount)) }
        var skipped: [String] = []
        let writes = try p.writes(layout: preampLayout, currentUnitID: p.unitID, onSkipped: { skipped.append($0) })
        // Merely stamping the bundle's unit ID does not authorize its channels.
        #expect(!writes.contains(.property(PropertyAddress(selector: .phantom), .bool(true))))
        #expect(skipped == ["phantom power not restored from a bundle"])
        let unitID = try #require(p.unitID)
        let identity = try #require(SymphonyIdentityReader.decode(unitID))
        p.metadata.inputChannelStates[0].recordPhantomRequest(true, identity: identity, boardSlot: 1, channel: 0)
        let verified = try p.writes(layout: preampLayout, currentUnitID: p.unitID)
        let on = ThunderboltPreset.Write.property(PropertyAddress(selector: .phantom), .bool(true))
        #expect(verified.contains(on))
        let mismatch = try p.writes(layout: preampLayout, currentUnitID: Data(repeating: 9, count: 8))
        #expect(!mismatch.contains(on))
        // An Instrument channel never gets phantom ON either.
        p.metadata.inputChannelStates[0].inputType = AnalogInputLevel.instrument.rawValue
        let instrumentWrites = (try? p.writes(layout: preampLayout, currentUnitID: p.unitID)) ?? []
        #expect(!instrumentWrites.contains(.property(PropertyAddress(selector: .phantom), .bool(true))))
    }

    @Test func replacingAnExistingBundleAndRefusingAdditionalHardwareContent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("B4a-replace-\(UUID().uuidString).mst2")
        defer { try? FileManager.default.removeItem(at: directory) }
        var preset = try fixture()
        try preset.writeBundle(to: directory)
        preset.metadata.channelNames = ["Replacement"]
        try preset.writeBundle(to: directory)
        let (loaded, _) = try ThunderboltPreset.loadBundle(from: directory, layout: layout)
        #expect(loaded.metadata.channelNames == ["Replacement"])
        try Data().write(to: directory.appendingPathComponent("UnitB.plist"))
        #expect(throws: (any Error).self) { try ThunderboltPreset.loadBundle(from: directory, layout: layout) }
    }

}

@Suite("Partial preset capture")
struct PartialPresetCaptureTests {
    @Test("An unreadable input route is omitted, not saved as route 0")
    func unreadableRouteIsOmitted() throws {
        let layout = CardLayout(slot1: .optical, slot2: .optical)
        var metadata = MaestroPreset()
        metadata.inputChannelStates = Array(repeating: InputChannelState(), count: layout.analogInputStripCount)
        metadata.outputChannelStates = Array(repeating: OutputChannelState(), count: layout.analogOutputStripCount)
        var seed = ThunderboltPreset(layout: layout, metadata: metadata)
        seed.outputRoutes = Array(0..<32)
        let suite = "partial.capture.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: false, identity: 42)
        seed.mixers = (0..<2).map {
            .init(snapshot: MixerStateSnapshot(channelCount: layout.mixerChannelCount, mixer: $0, store: store, defaults: defaults))
        }
        let failing = UInt32(SymphonyIORoutingAddress.p2pBase) + 5
        let captured = try ThunderboltPreset.capture(seed, layout: layout, hostChannels: 32, readProperty: { address in
            if address.selector == .routing {
                if address.element == failing { throw DeviceConnectionError.notConnected }
                return .uint32(40)
            }
            if address.selector == .speakerOutputMode { return .uint32(9) }
            if address.selector == .clockSource { return .uint32(1) }
            if address.selector == .spdifMirrorID { return .uint32(1) }
            return .uint32(0)
        }, readRaw: { _, _, _ in Data([0]) })
        let mask = try #require(captured.inputRouteMask)
        #expect(mask.count == 32)
        #expect(!mask[5])
        #expect(mask.filter { $0 }.count == 31)
        let writes = try captured.writes(layout: layout, hostChannels: 32)
        let routeElements: [UInt32] = writes.compactMap {
            if case .property(let address, _) = $0, address.selector == .routing, address.scope == .input { return address.element }
            return nil
        }
        #expect(!routeElements.contains(failing))
        #expect(routeElements.count == 31)
    }

    @Test("A fully readable capture keeps the old bundle shape")
    func fullCaptureHasNoMask() throws {
        let layout = CardLayout(slot1: .optical, slot2: .optical)
        var metadata = MaestroPreset()
        metadata.inputChannelStates = Array(repeating: InputChannelState(), count: layout.analogInputStripCount)
        metadata.outputChannelStates = Array(repeating: OutputChannelState(), count: layout.analogOutputStripCount)
        var seed = ThunderboltPreset(layout: layout, metadata: metadata)
        seed.outputRoutes = Array(0..<32)
        let captured = try ThunderboltPreset.capture(seed, layout: layout, hostChannels: 32, readProperty: { address in
            address.selector == .routing ? .uint32(40) : .uint32(0)
        }, readRaw: { _, _, _ in Data([0]) })
        #expect(captured.inputRouteMask == nil)
    }
}
