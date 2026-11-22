import Foundation
import Testing
@testable import MaestroCore
@testable import MaestroDevice

@Suite struct PhantomObservationTests {
    @Test(arguments: [
        (UInt64(12), true, UInt64(11), ServingDextBuild.build(144), Optional(true)),
        (UInt64(12), false, UInt64(11), ServingDextBuild.build(144), Optional(false)),
        (UInt64(12), true, UInt64(12), ServingDextBuild.build(144), nil),
        (UInt64(11), false, UInt64(12), ServingDextBuild.build(144), nil),
        (UInt64(0), false, UInt64(0), ServingDextBuild.build(144), nil),
        (UInt64(12), true, UInt64(11), ServingDextBuild.build(143), nil),
        (UInt64(12), false, UInt64(11), ServingDextBuild.build(143), Optional(false)),
    ])
    func onAndOffReceiptsRespectGenerationAndServingBuild(
        generation: UInt64, isOn: Bool, seen: UInt64, build: ServingDextBuild, expected: Bool?
    ) {
        #expect(PhantomObservation.observedState(generation: generation, isOn: isOn,
                                                lastSeenGeneration: seen, servingBuild: build) == expected)
        #expect(PhantomObservation.observedState(generation: generation, isOn: true,
                                                lastSeenGeneration: seen, servingBuild: nil) == nil)
    }

    @Test func offClearsOnlyTargetAndDoesNotRevokeLaterExplicitOn() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let layout = CardLayout(slot1: .analogADDA16, slot2: .micPre8)
        let a = ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: false, identity: 42)
        let b = ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: false, unit: .b, identity: 43)
        var states = [InputChannelState(inputType: 3), InputChannelState(inputType: 3)]
        for i in states.indices { states[i].recordPhantomRequest(true, identity: 43, boardSlot: 1, channel: i) }
        a.save(states, for: ChannelStateStore.inputKey)
        b.save(states, for: ChannelStateStore.inputKey)
        var receipts = [UInt64](repeating: 0, count: 16)
        receipts[8] = 123
        let changedA = PhantomObservation.apply(receipts, to: a)
        let changedB = PhantomObservation.apply(receipts, to: b)
        #expect(!changedA)
        #expect(changedB)
        let saved = try #require(b.load(ChannelStateStore.inputKey, as: [InputChannelState].self))
        #expect(!saved[0].phantom)
        #expect(saved[0].phantomProvenance == nil)
        #expect(saved[1].phantom)
        #expect(saved[1].phantomProvenance != nil)
        b.save(states, for: ChannelStateStore.inputKey) // later explicit authorized ON
        let repeated = PhantomObservation.apply(receipts, to: b)
        #expect(!repeated)
        #expect(b.load(ChannelStateStore.inputKey, as: [InputChannelState].self)?[0].phantom == true)
    }
    @Test func extendedLinkStatePreservesLegacyPrefix() throws {
        var words = [UInt32](repeating: 0, count: 48)
        words[1] = 1
        words[6] = 7
        words[15] = 9
        words[32] = 123 // B channel 0, low word
        words[33] = 2
        let state = try #require(LinkState.decode(words))
        #expect(state.recoveryCount == 7)
        #expect(state.unitProbe == 9)
        #expect(state.phantomOffReceipts[0] == 0)
        #expect(state.phantomOffReceipts[8] == (UInt64(2) << 32 | 123))
        let legacy = try #require(LinkState.decode(Array(words.prefix(16))))
        #expect(legacy.phantomOffReceipts.isEmpty)
        #expect(legacy.recoveryCount == state.recoveryCount)
        #expect(LinkState.decode(Array(words.prefix(47))) == nil)
    }

    @Test func onAndUnmappedCannotGrantAuthority() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let store = ChannelStateStore(defaults: defaults, layout: CardLayout(slot1: .analogADDA16, slot2: .micPre8), isSimulatingCards: false, identity: 42)
        store.save([InputChannelState(inputType: 3)], for: ChannelStateStore.inputKey)
        let on = PhantomObservation.apply(Array(repeating: 0, count: 16), to: store)
        let unmapped = PhantomObservation.apply([123], to: store)
        #expect(!on)
        #expect(!unmapped)
        let saved = try #require(store.load(ChannelStateStore.inputKey, as: [InputChannelState].self))
        #expect(!saved[0].phantom)
        #expect(saved[0].phantomProvenance == nil)
    }

    @Test func receiptIsAcknowledgedBeforeALaterMaestroOn() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let store = ChannelStateStore(defaults: defaults,
            layout: CardLayout(slot1: .analogADDA16, slot2: .micPre8),
            isSimulatingCards: false, identity: 42)
        var receipts = Array(repeating: UInt64(0), count: 16)
        receipts[0] = 77
        let firstApply = PhantomObservation.apply(receipts, to: store)
        #expect(!firstApply)
        var on = InputChannelState(inputType: 3)
        on.recordPhantomRequest(true, identity: 42, boardSlot: 1, channel: 0)
        store.save([on], for: ChannelStateStore.inputKey)
        let secondApply = PhantomObservation.apply(receipts, to: store)
        #expect(!secondApply)
        #expect(store.load(ChannelStateStore.inputKey, as: [InputChannelState].self)?[0].phantom == true)
    }
}
