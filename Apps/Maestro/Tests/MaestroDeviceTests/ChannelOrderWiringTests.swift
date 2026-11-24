import Foundation
import Testing
@testable import MaestroDevice
import MaestroCore

/// Phase 2 of the analog-first channel order (driver build 150): the gate,
/// the one-time routing reset, routing preset marking, .mst2 routing skip,
/// headphones and resets in the order the driver applied.
@Suite("Channel order: gate, reset, presets, setup files")
struct ChannelOrderWiringTests {
    private func scratch(_ name: String = #function) -> UserDefaults {
        let suite = "maestro.tests.channelOrder.\(name.filter { $0.isLetter || $0.isNumber })"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private let analogFirst88 = ThunderboltUnitChannelOrder(order: .analogFirst, slot1: .optical, slot2: .optical)

    // MARK: Gate

    @Test("The order follows the serving build: 149 keeps card by card, 150 takes what the driver applied")
    func gate() {
        let applied = ThunderboltAppliedChannelOrder.Unit(order: .analogFirst, slot1: .optical, slot2: .analogAD16)
        let fallback: (slot1: IOCardType?, slot2: IOCardType?) = (.optical, .analogAD16)
        #expect(ThunderboltUnitChannelOrder.resolve(serving: .build(149), applied: applied, fallback: fallback)
            == ThunderboltUnitChannelOrder(order: .cardByCard, slot1: .optical, slot2: .analogAD16))
        #expect(ThunderboltUnitChannelOrder.resolve(serving: .olderThanBuildReporting, applied: applied, fallback: fallback)?.order
            == .cardByCard)
        #expect(ThunderboltUnitChannelOrder.resolve(serving: nil, applied: applied, fallback: fallback)?.order == .cardByCard)
        #expect(ThunderboltUnitChannelOrder.resolve(serving: .build(150), applied: applied, fallback: fallback)
            == ThunderboltUnitChannelOrder(order: .analogFirst, slot1: .optical, slot2: .analogAD16))
        // An unstamped local build of this code is treated as 150.
        #expect(ThunderboltUnitChannelOrder.resolve(serving: .build(0), applied: applied, fallback: fallback)?.order
            == .analogFirst)
        // What the driver applied wins over the app's own reads.
        let cardByCard = ThunderboltAppliedChannelOrder.Unit(order: .cardByCard, slot1: nil, slot2: .optical)
        #expect(ThunderboltUnitChannelOrder.resolve(serving: .build(150), applied: cardByCard, fallback: fallback)
            == ThunderboltUnitChannelOrder(order: .cardByCard, slot1: nil, slot2: .optical))
        // Not reported (selector missing, or the unit not programmed yet): not known.
        #expect(ThunderboltUnitChannelOrder.resolve(serving: .build(150), applied: nil, fallback: fallback) == nil)
        #expect(ThunderboltUnitChannelOrder.resolve(
            serving: .build(150), applied: .init(order: nil, slot1: nil, slot2: nil), fallback: fallback) == nil)
    }

    @Test("Selector 17's 24 bytes decode to each unit's order and the types it was built from")
    func decodeAppliedOrder() throws {
        var bytes = [UInt8](repeating: 0, count: 24)
        bytes[4] = 7                                   // generation
        bytes[8] = 2; bytes[12] = 3; bytes[13] = 4; bytes[14] = 1; bytes[15] = 1   // A: analog first, 8x8 + A16
        bytes[16] = 1; bytes[20] = 9; bytes[21] = 6; bytes[22] = 1; bytes[23] = 1  // B: card by card, unknown + 16x16
        let order = try #require(ThunderboltAppliedChannelOrder.decode(bytes))
        #expect(order.generation == 7)
        #expect(order.unitA == .init(order: .analogFirst, slot1: .optical, slot2: .analogAD16))
        #expect(order.unitB == .init(order: .cardByCard, slot1: nil, slot2: .analogADDA16))
        var failed = bytes; failed[0] = 1
        #expect(ThunderboltAppliedChannelOrder.decode(failed) == nil)
        #expect(ThunderboltAppliedChannelOrder.decode(Array(bytes.prefix(16))) == nil)
        var none = bytes; none[16] = 0; none[22] = 0; none[23] = 0
        #expect(ThunderboltAppliedChannelOrder.decode(none)?.unitB == .init(order: nil, slot1: nil, slot2: nil))
    }

    @Test("Channels move only where a card's digital channels sat before the other card's analog ones")
    func differs() {
        #expect(!ThunderboltChannelOrder.differs(slot1: .optical, slot2: .none))
        #expect(!ThunderboltChannelOrder.differs(slot1: .none, slot2: .optical))
        #expect(!ThunderboltChannelOrder.differs(slot1: .analogADDA16, slot2: .analogADDA16))
        #expect(!ThunderboltChannelOrder.differs(slot1: .twoBySix, slot2: .none))
        #expect(!ThunderboltChannelOrder.differs(slot1: .analogADDA16, slot2: .micPre8))
        #expect(ThunderboltChannelOrder.differs(slot1: .optical, slot2: .analogAD16))
        #expect(ThunderboltChannelOrder.differs(slot1: .optical, slot2: .optical))
        #expect(ThunderboltChannelOrder.differs(slot1: .analogAD16, slot2: .analogDA16))
        #expect(!ThunderboltChannelOrder.differs(slot1: nil, slot2: .optical))
    }

    // MARK: One-time reset

    @Test("The reset runs only on ThunderBridge, from build 150, for cards that move, and once")
    func resetGate() {
        let defaults = scratch()
        let moving: [ThunderboltUnitChannelOrder?] = [analogFirst88]
        let still: [ThunderboltUnitChannelOrder?] = [ThunderboltUnitChannelOrder(order: .analogFirst, slot1: .analogADDA16, slot2: .analogADDA16)]
        #expect(!ChannelOrderRoutingReset.shouldRun(transport: .usb, serving: .build(150), units: moving, defaults: defaults))
        #expect(!ChannelOrderRoutingReset.shouldRun(transport: .thunderbolt, serving: .build(149), units: moving, defaults: defaults))
        #expect(!ChannelOrderRoutingReset.shouldRun(transport: .thunderbolt, serving: nil, units: moving, defaults: defaults))
        #expect(!ChannelOrderRoutingReset.shouldRun(transport: .thunderbolt, serving: .build(150), units: still, defaults: defaults))
        #expect(!ChannelOrderRoutingReset.shouldRun(transport: .thunderbolt, serving: .build(150), units: [nil], defaults: defaults))
        // Card by card reported by a 150 driver (a type unknown): nothing moved.
        #expect(!ChannelOrderRoutingReset.shouldRun(transport: .thunderbolt, serving: .build(150),
            units: [ThunderboltUnitChannelOrder(order: .cardByCard, slot1: .optical, slot2: .optical)], defaults: defaults))
        #expect(ChannelOrderRoutingReset.shouldRun(transport: .thunderbolt, serving: .build(0), units: moving, defaults: defaults))
        // Unit B alone moving is enough.
        #expect(ChannelOrderRoutingReset.shouldRun(transport: .thunderbolt, serving: .build(150),
                                                   units: still + [analogFirst88], defaults: defaults))
        #expect(ChannelOrderRoutingReset.runIfNeeded(transport: .thunderbolt, serving: .build(150), units: moving, defaults: defaults) != nil)
        #expect(defaults.bool(forKey: ChannelOrderRoutingReset.doneKey))
        #expect(defaults.bool(forKey: ChannelOrderRoutingReset.noticePendingKey))
        #expect(RoutingMixerReset.isPending(.thunderboltInputRouting, defaults: defaults))
        #expect(ChannelOrderRoutingReset.runIfNeeded(transport: .thunderbolt, serving: .build(150), units: moving, defaults: defaults) == nil)
    }

    @Test("The reset removes every routing store of a card pair that moves, and nothing else")
    func resetClearsStores() {
        let defaults = scratch()
        let moving = "optical+optical", still = "analogADDA16+analogADDA16"
        let topology = "a=1f.b=none.channels=32"
        let removedKeys = [
            "unit.v3.1f.inputRouting.\(moving)",
            "unit.v3.1f.inputRouting_multi.\(moving)",
            "unit.v3.2e.inputRouting.\(moving)",                       // unit B, not connected
            "unit.v3.1f.inputRouting.\(moving).snapshot",
            "cardRouting.v3.18.\(topology).a.\(moving)",
            "cardRouting.v3.18.\(topology).a.\(moving)_multi",
            "cardRouting.v3.18.a=1f.b=2e.channels=64.b.\(moving)_multi",  // the two-unit topology
            "symphonyCardInputs.\(moving).none.32.\(topology)",
            "symphonyCardInputs.\(still).\(moving).64.a=1f.b=2e.channels=64",
            "pending.cardOutput.a=pending-3.b=none.channels=32.a",
            "pending.4.inputRouting",
            "routing_input_18_v2",
            "routing_input_18_v2.migrationReceipt",
            "routing_input_18_v2.migratedTo",
        ]
        let keptKeys = [
            "unit.v3.1f.inputRouting.\(still)",
            "cardRouting.v3.18.\(topology).a.\(still)_multi",
            "symphonyCardInputs.\(still).none.32.\(topology)",
            "symphonyCardInputs.sim:\(moving).none.32.\(topology)",
            "sim.routing_input_18_v2",
            "conv.abc.inputRouting",
            "unit.v3.1f.mixerChannelNames.\(moving)",
            "mixerState_0", "mixerSoftwareReturnSource_0",
            "inputRoutingPresets", "outputRoutingPresets",
            "routing_output_18_v2", "routing_output_18_v2.migrationReceipt",
        ]
        for key in removedKeys + keptKeys { defaults.set(["0": 1], forKey: key) }
        defaults.set(["owner": "unit.v3.1f.inputRouting.\(moving)", "data": Data()], forKey: "routing_input_18_v2.migrationReceipt")
        defaults.set(["owner": "cardRouting.v3.18.\(topology).a.\(still)", "data": Data()], forKey: "routing_output_18_v2.migrationReceipt")
        let removed = ChannelOrderRoutingReset.purge(defaults: defaults)
        for key in removedKeys {
            #expect(defaults.object(forKey: key) == nil, "\(key) kept")
            #expect(removed.contains(key))
        }
        for key in keptKeys { #expect(defaults.object(forKey: key) != nil, "\(key) removed") }
        // Nothing can be migrated back into a destination it removed.
        let destination = "unit.v3.1f.inputRouting.\(moving)"
        _ = UnitStateMigration.propertyKey(defaults: defaults, legacy: "routing_input_18_v2",
                                           destination: destination, allowMigration: true)
        #expect(defaults.object(forKey: destination) == nil)
    }

    // MARK: Presets

    @Test("A routing preset is marked with its order on save, refused only where channels move")
    func presetMarking() {
        let defaults = scratch()
        let key = "inputRoutingPresets"
        #expect(RoutingPresetChannelOrder.order(name: "Old", presetKey: key, defaults: defaults) == .cardByCard)
        #expect(RoutingPresetChannelOrder.isStale(name: "Old", presetKey: key, current: [analogFirst88], defaults: defaults))
        // The same preset applies as before where nothing moves, or under an older driver.
        #expect(!RoutingPresetChannelOrder.isStale(name: "Old", presetKey: key,
            current: [ThunderboltUnitChannelOrder(order: .analogFirst, slot1: .analogADDA16, slot2: .analogADDA16)], defaults: defaults))
        #expect(!RoutingPresetChannelOrder.isStale(name: "Old", presetKey: key,
            current: [ThunderboltUnitChannelOrder(order: .cardByCard, slot1: .optical, slot2: .optical)], defaults: defaults))
        RoutingPresetChannelOrder.mark(name: "New", presetKey: key, order: .analogFirst, defaults: defaults)
        #expect(!RoutingPresetChannelOrder.isStale(name: "New", presetKey: key, current: [analogFirst88], defaults: defaults))
        RoutingPresetChannelOrder.mark(name: "Old", presetKey: key, order: .cardByCard, defaults: defaults)
        #expect(RoutingPresetChannelOrder.isStale(name: "Old", presetKey: key, current: [analogFirst88], defaults: defaults))
        RoutingPresetChannelOrder.unmark(name: "New", presetKey: key, defaults: defaults)
        #expect(RoutingPresetChannelOrder.order(name: "New", presetKey: key, defaults: defaults) == .cardByCard)
        #expect(RoutingPresetChannelOrder.label("Old", stale: true) == "Old (old channel order)")
        #expect(RoutingPresetChannelOrder.label("New", stale: false) == "New")
        // Presets saved over USB are in the analog-first order already.
        #expect(RoutingPresetChannelOrder.savingOrder(transport: .usb, current: nil) == .analogFirst)
        #expect(RoutingPresetChannelOrder.savingOrder(transport: .thunderbolt, current: nil) == .cardByCard)
        #expect(RoutingPresetChannelOrder.savingOrder(transport: .thunderbolt, current: analogFirst88) == .analogFirst)
        // The stored presets themselves are untouched.
        #expect(defaults.object(forKey: key) == nil)
    }

    // MARK: Setup files

    private func preset(boards: (IOCardType, IOCardType)) -> ThunderboltPreset {
        let layout = CardLayout(slot1: boards.0, slot2: boards.1)
        var metadata = MaestroPreset()
        metadata.inputChannelStates = Array(repeating: InputChannelState(), count: layout.analogInputStripCount)
        metadata.outputChannelStates = Array(repeating: OutputChannelState(), count: layout.analogOutputStripCount)
        metadata.opticalInFormat = 0
        metadata.slot2OpticalFormat = 0
        metadata.spdifReplaceID = 0; metadata.slot2SPDIFReplaceID = 0
        metadata.spdifMirrorID = 0; metadata.slot2SPDIFMirrorID = 0
        var value = ThunderboltPreset(layout: layout, metadata: metadata)
        value.inputRoutes = (0..<32).map { UInt8(32 + $0) }
        value.outputRoutes = (0..<32).map(UInt8.init)
        value.cardInputRoutes = Array(0..<32)
        value.mixers = (0..<2).map { _ in
            ThunderboltPreset.Mixer(snapshot: MixerStateSnapshot(channelCount: layout.mixerChannelCount, mixer: 0,
                                                                 store: ChannelStateStore(defaults: scratch("mixer"), layout: layout,
                                                                                          isSimulatingCards: false, identity: 1)))
        }
        value.globals[AudioPropertySelector.headphone1RoutingID.rawValue] = 8   // slot 2's outputs 1-2
        return value
    }

    @Test("An older setup file is card by card and restores without its routing where the cards move")
    func setupFileOrder() throws {
        var old = preset(boards: (.optical, .optical))
        old.channelOrder = nil
        let decoded = try PropertyListDecoder().decode(ThunderboltPreset.self, from: PropertyListEncoder().encode(old))
        #expect(decoded.channelOrder == nil && decoded.savedChannelOrder == .cardByCard)
        #expect(!old.routingApplies(current: .analogFirst))
        #expect(old.routingApplies(current: .cardByCard))
        var new = old
        new.channelOrder = ThunderboltPreset.channelOrderTag(.analogFirst)
        #expect(new.routingApplies(current: .analogFirst))
        // A new file on an older driver is refused the other way.
        #expect(!new.routingApplies(current: .cardByCard))
        // Cards the order does not move: the routing applies either way.
        #expect(preset(boards: (.analogADDA16, .analogADDA16)).routingApplies(current: .analogFirst))
    }

    @Test("Restoring without routing writes no input, card input or output route, and keeps the rest")
    func setupFileSkipsRouting() throws {
        let file = preset(boards: (.optical, .optical))
        let layout = CardLayout(slot1: .optical, slot2: .optical)
        let current = (0..<32).map { (destination: UInt8(192 + $0), source: UInt8(40)) }
        let skipped = try file.writes(layout: layout, currentInputRoutes: current, restoresRouting: false,
                                      channelOrder: analogFirst88)
        #expect(!skipped.contains { if case .output = $0 { true } else { false } })
        #expect(!skipped.contains { if case .cardInput = $0 { true } else { false } })
        #expect(!skipped.contains {
            if case .property(let address, _) = $0 { address.selector == .routing && address.scope == .input } else { false }
        })
        #expect(skipped.contains {
            if case .property(let address, _) = $0 { address.selector == .mixerChannelLevel } else { false }
        })
        let full = try file.writes(layout: layout, currentInputRoutes: current, channelOrder: analogFirst88)
        #expect(full.filter { if case .output = $0 { true } else { false } }.count == 32)
        #expect(full.contains { if case .cardInput = $0 { true } else { false } })
    }

    // MARK: Headphones and resets

    @Test("A headphone follows the XLink channel the unit plays on its pair, in the driver's order")
    func headphoneBootTable() throws {
        let slot2Line12 = SymphonyIORoutingAddress.ioBoard1Base
        // Two 8x8s analog first: slot 2's Line 1-2 play Mac 9-10 (XLink 8-9).
        #expect(SymphonyIOHeadphoneRouting.thunderboltBootTableSource(forDestination: slot2Line12, order: analogFirst88) == 8)
        #expect(SymphonyIOHeadphoneRouting.inheritedSource(forDestination: slot2Line12 + 1, cachedRoutes: [:],
                                                           transport: .thunderbolt, thunderboltOrder: analogFirst88) == 9)
        // Card by card (and with no order): by position, XLink 16.
        #expect(SymphonyIOHeadphoneRouting.thunderboltBootTableSource(
            forDestination: slot2Line12, order: .init(order: .cardByCard, slot1: .optical, slot2: .optical)) == 16)
        #expect(SymphonyIOHeadphoneRouting.inheritedSource(forDestination: slot2Line12, cachedRoutes: [:],
                                                           transport: .thunderbolt) == 16)
        // A setup file's headphone 1 on slot 2's outputs 1-2 is written in the order.
        let writes = try preset(boards: (.optical, .optical)).writes(
            layout: CardLayout(slot1: .optical, slot2: .optical), channelOrder: analogFirst88)
        let hp = SymphonyIOHeadphoneRouting.Headphone.headphone1.destinations
        func source(_ destination: UInt8) -> UInt32? {
            for case .property(let address, let value) in writes
            where address.selector == .routing && address.scope == .output && address.element == UInt32(destination) {
                return value.asUInt32
            }
            return nil
        }
        #expect(source(hp.left) == 8 && source(hp.right) == 9)
        // Reset Routing's headphones too.
        let reset = try ThunderboltPreset.peripheralReset(layout: CardLayout(slot1: .optical, slot2: .optical), input: false,
                                                           order: analogFirst88) { $0 == .headphone1RoutingID ? 8 : 0 }
        #expect(reset.first == .property(PropertyAddress(selector: .routing, scope: .output, element: UInt32(hp.left)), .uint32(8)))
    }

    @Test("Reset Routing's input table follows the driver's order, and the card reset covers every XLink channel")
    func resets() throws {
        let layout = CardLayout(slot1: .optical, slot2: .analogAD16)
        let order = ThunderboltUnitChannelOrder(order: .analogFirst, slot1: .optical, slot2: .analogAD16)
        let input = try ThunderboltPreset.peripheralReset(layout: layout, input: true, order: order) { _ in nil }
        let expected = SymphonyIODefaultRouting.thunderboltInputRoutes(slot1: .optical, slot2: .analogAD16, order: .analogFirst)
        #expect(input == expected.map {
            .property(PropertyAddress(selector: .routing, scope: .input, element: UInt32($0.destination)), .uint32(UInt32($0.source)))
        })
        let cardByCard = try ThunderboltPreset.peripheralReset(
            layout: layout, input: true, order: .init(order: .cardByCard, slot1: .optical, slot2: .analogAD16)) { _ in nil }
        #expect(cardByCard.count == 32 && cardByCard != input)
        // 8x8 + 2x6 analog first: 8 + 6 analog then 8 + 10 digital outputs = 32.
        // 8x8 + empty: 16 outputs, XLink 16-31 written disabled.
        let single = CardLayout(slot1: .optical, slot2: .none)
        let writes = ThunderboltPreset.cardReset(input: false, layouts: [single],
                                                 orders: [ThunderboltUnitChannelOrder(order: .analogFirst, slot1: .optical, slot2: IOCardType.none)])
        #expect(writes.count == 32)
        for case .output(let route) in writes {
            #expect(route.enabled == (route.channel < 16), "XLink \(route.channel)")
            #expect(route.slot == 64 + route.channel)
        }
    }

    @Test("Every XLink channel is reached by exactly one board output or written disabled, for every card pair")
    func xlinkCoverage() {
        for slot1 in IOCardType.allCases {
            for slot2 in IOCardType.allCases {
                let order = ThunderboltChannelOrder.analogFirst
                var reached: [UInt8] = []
                for destination in UInt8(32)..<64 {
                    if let channel = ThunderboltCardRouting.channel(forDestination: destination, slot1: slot1,
                                                                    slot2: slot2, order: order) {
                        reached.append(channel)
                    }
                }
                #expect(Set(reached).count == reached.count, "\(slot1)+\(slot2): an XLink channel on two outputs")
                let unreached = ThunderboltCardRouting.unreachedChannels(slot1: slot1, slot2: slot2, order: order)
                #expect(Set(reached).union(unreached) == Set(0..<32), "\(slot1)+\(slot2)")
                #expect(Set(reached).isDisjoint(with: unreached))
                let outputs = min(32, slot1.totalOutputChannels + slot2.totalOutputChannels)
                #expect(reached.count == outputs, "\(slot1)+\(slot2)")
            }
        }
    }

    @Test("Reset output text names what the driver's order plays")
    func outputResetText() {
        let routes = SymphonyIODefaultRouting.thunderboltOutputRoutes(slot1: .optical, slot2: .optical, order: .analogFirst)
        let lines = RoutingResetGuard.outputPlanLines(board1: .optical, board2: .optical, transport: .thunderbolt, routes: routes)
        #expect(lines.first == "Card 1 analog out 1–8: Software 1–8")
        #expect(lines.contains("Card 2 analog out 1–8: Software 9–16"))
    }
}
