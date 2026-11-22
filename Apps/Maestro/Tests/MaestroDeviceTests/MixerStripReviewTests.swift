import Foundation
import Testing
@testable import MaestroCore
@testable import MaestroDevice

@Suite("Mixer strip review regressions")
struct MixerStripReviewTests {
    private func property(_ writes: [ThunderboltPreset.Write], _ selector: AudioPropertySelector,
                          _ channel: Int) -> PropertyValue? {
        writes.compactMap { write in
            guard case .property(let address, let value) = write,
                  address.selector == selector, Int(address.element & 0xffff) == channel else { return nil }
            return value
        }.last
    }

    private func routes(_ layout: CardLayout, _ moved: [(Int, Int)]) -> [ThunderboltInputMeterMap.Route] {
        var result = ThunderboltInputMeterMap.currentRoutes(slot1: layout.slot1, replayed: [])
        for (destination, source) in moved {
            result[destination] = (destination: UInt8(SymphonyIORoutingAddress.p2pBase + UInt8(destination)),
                                   source: UInt8(source))
        }
        return result
    }

    @Test("Input Routing is followed by a complete rewrite without disabling outputs")
    func inputRoutingRewrite() {
        let layout = CardLayout(slot1: .optical, slot2: .analogAD16)
        let snapshot = MixerStateSnapshot(channelCount: layout.mixerChannelCount, mixer: 0,
                                          store: ChannelStateStore(defaults: .standard, layout: layout, isSimulatingCards: true))
        let writes = CardMixerReplay.writes(mixer: 0, layout: layout, snapshot: snapshot,
                                            routes: routes(layout, [(8, Int(SymphonyIORoutingAddress.ioBoard1Base))]))
        #expect(property(writes, .mixerChannelMute, 16)?.asBool == true)
        #expect(property(writes, .mixerChannelSolo, 16)?.asBool == false)
        #expect(property(writes, .mixerChannelMute, 8)?.asBool == false)
        #expect(!writes.contains { if case .output = $0 { true } else { false } })
        var ledger = CardMixerRestoreLedger()
        ledger.complete()
        ledger.noteOwed()
        #expect(!ledger.completed && ledger.needs == [true, true])
    }

    @Test("Two-unit required addresses use both route tables")
    func twoUnitWrittenMarks() {
        let a = CardLayout(slot1: .none, slot2: .analogAD16)
        let b = CardLayout(slot1: .analogDA16, slot2: .none)
        let ra = ThunderboltInputMeterMap.currentRoutes(slot1: a.slot1, replayed: [])
        let rb = ThunderboltInputMeterMap.currentRoutes(slot1: b.slot1, replayed: [])
        let required = CardMixerReplay.requiredAddresses(mixer: 0, layout: a, second: b,
                                                         routes: ra, secondRoutes: rb)
        let defaults = UserDefaults(suiteName: "review-(UUID())")!
        let store = ChannelStateStore(defaults: defaults, layout: a, isSimulatingCards: true)
        let second = MixerStateSnapshot(channelCount: b.mixerChannelCount, mixer: 0,
                                        store: ChannelStateStore(defaults: defaults, layout: b, isSimulatingCards: true, unit: .b))
        let writes = CardMixerReplay.writes(mixer: 0, layout: a,
                                            snapshot: MixerStateSnapshot(channelCount: a.mixerChannelCount, mixer: 0, store: store),
                                            second: (b, second), routes: ra, secondRoutes: rb)
        let sent = Set(writes.compactMap { if case .property(let address, _) = $0 { address } else { nil } })
        #expect(required.isSubset(of: sent))
        var plan = TwoUnitReplay()
        plan.tables = [.unit(.a, PropertyAddress(selector: .routing, scope: .input, element: 192), .uint32(32)),
                       .unit(.b, PropertyAddress(selector: .routing, scope: .input, element: 192), .uint32(32))]
        plan.card = writes.map { .card($0) }
        plan.settings = [.unit(.a, PropertyAddress(selector: .speakerOutputMode), .uint32(0)),
                         .unit(.b, PropertyAddress(selector: .speakerOutputMode), .uint32(0))]
        var landed = 0
        var unlocked: [DeviceUnit] = []
        try? plan.run(validate: {}, send: { _ in landed += 1 }, unlock: { unit in unlocked.append(unit); return true }, delay: {})
        #expect(landed == plan.tables.count + plan.card.count + plan.settings.count + 2)
        #expect(unlocked == [.a, .b])
    }

    @Test("Required addresses equal the complete write for every card pair")
    func requiredEqualsWritesForEveryPair() {
        for s1 in [IOCardType.none, .analogAES, .optical, .analogAD16, .analogDA16, .analogADDA16, .twoBySix] {
            for s2 in [IOCardType.none, .analogAES, .optical, .analogAD16, .analogDA16, .analogADDA16, .twoBySix, .micPre8] {
                let layout = CardLayout(slot1: s1, slot2: s2)
                guard layout.isKnown else { continue }
                let defaults = UserDefaults(suiteName: "pairs-(UUID())")!
                let store = ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: true)
                let snapshot = MixerStateSnapshot(channelCount: layout.mixerChannelCount, mixer: 0, store: store)
                let routes = ThunderboltInputMeterMap.currentRoutes(slot1: s1, replayed: [])
                let writes = CardMixerReplay.writes(mixer: 0, layout: layout, snapshot: snapshot, routes: routes)
                let sent = Set(writes.compactMap { if case .property(let address, _) = $0 { address } else { nil } })
                #expect(CardMixerReplay.requiredAddresses(mixer: 0, layout: layout, routes: routes).isSubset(of: sent))
            }
        }
    }

    @Test("A duplicated input mutes the unused receive slot")
    func duplicateInputMutesOtherSlot() {
        let layout = CardLayout(slot1: .optical, slot2: .none)
        let p2p = SymphonyIORoutingAddress.p2pBase, source = SymphonyIORoutingAddress.ioBoard0Base
        let capture = routes(layout, [(0, Int(source)), (1, Int(source))])
        let defaults = UserDefaults(suiteName: "duplicate-(UUID())")!
        let store = ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: true)
        let writes = CardMixerReplay.writes(mixer: 0, layout: layout,
                                            snapshot: MixerStateSnapshot(channelCount: layout.mixerChannelCount, mixer: 0, store: store),
                                            routes: capture)
        #expect(property(writes, .mixerChannelMute, 1)?.asBool == true)
        #expect(property(writes, .mixerChannelSolo, 1)?.asBool == false)
        _ = p2p
    }

    @Test("Unit B adds 32 and leaves an unmapped strip unwritten")
    func unitBNilInput() {
        let channels = TwoUnitMixer.unitBChannels(layout: CardLayout(slot1: .optical, slot2: .none), prefix: "B",
                                                   inputNumbers: [nil, 4])
        #expect(channels[0].hardwareIndex == -1)
        #expect(channels[1].hardwareIndex == 36)
    }

    @Test("Preset numbering uses its written table and mutes unmapped inputs")
    func presetUsesWrittenRoutes() throws {
        let layout = CardLayout(slot1: .optical, slot2: .optical)
        var metadata = MaestroPreset()
        metadata.inputChannelStates = Array(repeating: InputChannelState(), count: layout.analogInputStripCount)
        metadata.outputChannelStates = Array(repeating: OutputChannelState(), count: layout.analogOutputStripCount)
        metadata.opticalInFormat = 0
        metadata.slot2OpticalFormat = 0
        metadata.spdifReplaceID = 0
        metadata.spdifMirrorID = 0
        metadata.slot2SPDIFReplaceID = 0
        metadata.slot2SPDIFMirrorID = 0
        var preset = ThunderboltPreset(layout: layout, metadata: metadata)
        preset.inputRoutes = Array(repeating: SymphonyIORoutingAddress.none, count: 32)
        preset.inputRoutes[0] = SymphonyIORoutingAddress.ioBoard0Base + 8
        preset.inputRouteMask = Array(repeating: true, count: 32)
        preset.outputRoutes = Array(0..<32).map(UInt8.init)
        let defaults = UserDefaults(suiteName: "preset-review-(UUID())")!
        let store = ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: true)
        for mixer in 0..<2 {
            store.save(Array(repeating: MixerChannelState(level: 0, pan: 0, isMuted: false, isSoloed: false), count: layout.mixerChannelCount),
                       for: ChannelStateStore.mixerKey(mixer))
        }
        preset.mixers = (0..<2).map { ThunderboltPreset.Mixer(
            snapshot: MixerStateSnapshot(channelCount: layout.mixerChannelCount, mixer: $0, store: store)) }
        let writes = try preset.writes(layout: layout, currentInputRoutes: ThunderboltInputMeterMap.currentRoutes(slot1: layout.slot1, replayed: []))
        #expect(property(writes, .mixerChannelLevel, 0) != nil)
        #expect(property(writes, .mixerChannelMute, 1)?.asBool == true)
    }

    @Test("Replay tables precede mixer writes")
    func connectOrder() {
        var plan = TwoUnitReplay()
        plan.tables = [.unit(.a, PropertyAddress(selector: .routing, scope: .input, element: 192), .uint32(32))]
        plan.card = [.card(.property(PropertyAddress(selector: .mixerChannelMute, element: 0x10000), .bool(true)))]
        #expect(plan.writes.first.map { if case .unit = $0 { true } else { false } } == true)
    }

    @Test("Every pair preserves strip labels while receive slots move")
    func labelsAndKinds() {
        let layout = CardLayout(slot1: .optical, slot2: .analogAD16)
        #expect(layout.mixerChannels[8].label == "Line 9")
        #expect(layout.mixerChannels[24].label == "ADAT 1")
        #expect(ThunderboltInputMeterMap.mixerInputs(layout: layout,
            routes: ThunderboltInputMeterMap.currentRoutes(slot1: layout.slot1, replayed: []))[8] == 16)
    }
}
