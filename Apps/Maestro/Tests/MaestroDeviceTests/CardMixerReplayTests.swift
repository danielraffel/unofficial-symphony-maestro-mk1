import Foundation
import Testing
import MaestroCore
@testable import MaestroDevice

@Suite("D5 page-closed card mixer replay")
struct CardMixerReplayTests {
    @Test("Capability gate keeps 64-channel and converter paths out")
    func capabilityGate() {
        #expect(CardMixerReplay.supportsSingleUnit(channelCount: 32, converterFlags: 0))
        #expect(!CardMixerReplay.supportsSingleUnit(channelCount: 64, converterFlags: 0))
        #expect(!CardMixerReplay.supportsSingleUnit(channelCount: 32, converterFlags: 1))
    }

    @Test("The gap between card mixer commands is short but not zero: both mixers in under a second")
    func commandGap() {
        #expect(CardMixerReplay.commandGap == .milliseconds(2))
        #expect(CardMixerReplay.commandGap > .zero)
        // 270 commands for two 32-channel mixers (below): the gaps alone.
        #expect(CardMixerReplay.commandGap * 270 < .seconds(1))
    }

    @Test("16x16 plus 8x8 restores both mixers with the documented command count")
    func commandCountAndRightReturnID() throws {
        let name = "d5-count-\(UUID())"
        let defaults = ScratchUserDefaults(suiteName: name)!
        defer { defaults.cleanup() }
        let layout = CardLayout(slot1: .analogADDA16, slot2: .optical)
        let store = ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: false, identity: 9)
        let state = MixerChannelState(level: -6, pan: 0.1, isMuted: false, isSoloed: false)
        for mixer in 0..<2 { store.save(Array(repeating: state, count: layout.mixerChannelCount), for: ChannelStateStore.mixerKey(mixer)) }
        let groups = (0..<2).map { mixer in
            let snapshot = MixerStateSnapshot(channelCount: layout.mixerChannelCount, mixer: mixer, store: store)
            return CardMixerReplay.writes(mixer: mixer, layout: layout, snapshot: snapshot)
        }
        #expect(layout.mixerChannelCount == 32)
        #expect(CardMixerReplay.commandCount(groups) == 270)
        #expect(value(groups[0], .mixerChannelLevel, 0x10000 | 0x1002) != nil)
        #expect(value(groups[0], .mixerChannelLevel, 0x10000 | 1001) == nil)
    }

    @Test("Each mixer restores its own saved software-return fader")
    func separateReturnFaders() throws {
        let name = "d45-\(UUID())"
        let defaults = ScratchUserDefaults(suiteName: name)!
        defer { defaults.cleanup() }
        let shared = MixerChannelState(level: -3, pan: 0.25, isMuted: true, isSoloed: true)
        defaults.set(try JSONEncoder().encode(shared), forKey: "mixerState_swReturn")
        let layout = CardLayout(slot1: .optical, slot2: .none)
        let store = ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: false, identity: 42)
        for mixer in 0..<2 {
            let expected = mixer == 0 ? -27.0 : -12.0
            store.mixerPreferences.set(expected, forKey: "mixerSWReturnLeftLevel_\(mixer)")
            let snapshot = MixerStateSnapshot(channelCount: layout.mixerChannelCount, mixer: mixer, store: store, defaults: defaults)
            let writes = CardMixerReplay.writes(mixer: mixer, layout: layout, snapshot: snapshot)
            let base = UInt32(mixer + 1) << 16
            let level = value(writes, .mixerChannelLevel, base | 1000)?.asFloat64
            #expect(level == expected)
            #expect(value(writes, .mixerChannelMute, base | 1000)?.asBool == true)
            #expect(value(writes, .mixerChannelSolo, base | 1000)?.asBool == true)
            // Software Return has no pan: the saved 0.25 is ignored, centre is written.
            #expect(value(writes, .mixerChannelPan, base | 1000)?.asFloat64 == 0)
            let saved = CardMixerReplay.savedWrites(mixer: mixer, layout: layout, store: store)
            #expect(value(saved, .mixerChannelPan, base | 1000)?.asFloat64 == 0)
        }
    }

    @Test("A strip is muted only when it was saved muted: nothing is forced, whatever routingMode says")
    func noForcedMute() throws {
        let name = "d5-nomute-\(UUID())"
        let defaults = ScratchUserDefaults(suiteName: name)!
        defer { defaults.cleanup() }
        let layout = CardLayout(slot1: .optical, slot2: .none)
        let store = ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: false, identity: 42)
        // The removed setting's old value for "DAW" (0), in the scoped store and globally.
        store.mixerPreferences.set(0, forKey: "routingMode")
        defaults.set(0, forKey: "routingMode")
        var strips = Array(repeating: MixerChannelState(level: -6, pan: 0, isMuted: false, isSoloed: false),
                           count: layout.mixerChannelCount)
        strips[3].isMuted = true
        store.save(strips, for: ChannelStateStore.mixerKey(0))
        let snapshot = MixerStateSnapshot(channelCount: layout.mixerChannelCount, mixer: 0, store: store)
        for writes in [CardMixerReplay.writes(mixer: 0, layout: layout, snapshot: snapshot),
                       CardMixerReplay.savedWrites(mixer: 0, layout: layout, store: store)] {
            for (index, strip) in layout.mixerChannels.enumerated() {
                #expect(value(writes, .mixerChannelMute, 0x10000 | UInt32(strip.hardwareIndex))?.asBool == (index == 3))
            }
        }
    }

    @Test("An unrouted saved strip is written muted and unsoloed")
    func unroutedStripCannotKeepSilencingTheMixer() throws {
        let name = "d5-unrouted-\(UUID())"
        let defaults = ScratchUserDefaults(suiteName: name)!
        defer { defaults.cleanup() }
        let layout = CardLayout(slot1: .optical, slot2: .none)
        let store = ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: false, identity: 42)
        store.save(Array(repeating: MixerChannelState(level: 0, pan: 0, isMuted: false, isSoloed: true),
                         count: layout.mixerChannelCount), for: ChannelStateStore.mixerKey(0))
        let writes = CardMixerReplay.savedWrites(mixer: 0, layout: layout, store: store, routes: [])
        #expect(value(writes, .mixerChannelMute, 0x10000)?.asBool == true)
        #expect(value(writes, .mixerChannelSolo, 0x10000)?.asBool == false)
    }

    @Test("Removing a soloed route sends mute and unsolo to the card")
    func removedRouteClearsLiveCardStrip() {
        let before = Set([7])
        let after = Set<Int>()
        let writes = CardMixerReplay.unroutedWrites(mixer: 0, inputIDs: before.subtracting(after))
        #expect(value(writes, .mixerChannelMute, 0x10000 | 7)?.asBool == true)
        #expect(value(writes, .mixerChannelSolo, 0x10000 | 7)?.asBool == false)
    }

    private func value(_ writes: [ThunderboltPreset.Write], _ selector: AudioPropertySelector,
                       _ element: UInt32) -> PropertyValue? {
        for case .property(let address, let value) in writes where address.selector == selector && address.element == element {
            return value
        }
        return nil
    }
}

extension CardMixerReplayTests {
    @Test("Removal, rediscovery, card swap and 64-32-64 preserve the saved mixer")
    func lifecyclePlans() throws {
        let name = "d45-lifecycle-\(UUID())"
        let defaults = ScratchUserDefaults(suiteName: name)!
        defer { defaults.cleanup() }
        let a = CardLayout(slot1: .optical, slot2: .analogAD16)
        let b = CardLayout(slot1: .analogADDA16, slot2: .micPre8)
        let storeA = ChannelStateStore(defaults: defaults, layout: a, isSimulatingCards: false, identity: 42)
        let storeB = ChannelStateStore(defaults: defaults, layout: b, isSimulatingCards: false, unit: .b, identity: 43)
        let channelA = MixerChannelState(level: -18, pan: -0.4, isMuted: true, isSoloed: false)
        let channelB = MixerChannelState(level: -9, pan: 0.6, isMuted: false, isSoloed: true)
        for mixer in 0..<2 {
            storeA.save(Array(repeating: channelA, count: a.mixerChannelCount), for: ChannelStateStore.mixerKey(mixer))
            storeB.save(Array(repeating: channelB, count: b.mixerChannelCount), for: ChannelStateStore.mixerKey(mixer))
            storeA.mixerPreferences.set(23 + mixer, forKey: "mixerSoftwareReturnSource_\(mixer)")
            storeA.mixerPreferences.set(-7.0, forKey: "mixerMasterLevel_\(mixer)")
        }
        let savedA = storeA.loadData(ChannelStateStore.mixerKey(0))
        for activeB in [true, false, true] {
            for mixer in 0..<2 {
                let snapA = MixerStateSnapshot(channelCount: a.mixerChannelCount, mixer: mixer, store: storeA, defaults: defaults)
                let snapB = MixerStateSnapshot(channelCount: b.mixerChannelCount, mixer: mixer, store: storeB, defaults: defaults)
                let writes = CardMixerReplay.writes(mixer: mixer, layout: a, snapshot: snapA,
                    second: activeB ? (b, snapB) : nil)
                let base = UInt32(mixer + 1) << 16
                let expectedSource = UInt32(activeB ? 23 + mixer : 0)
                #expect(value(writes, .mixerSoftwareReturnID, base)?.asUInt32 == expectedSource)
                #expect(value(writes, .mixerChannelLevel, base | 2000)?.asFloat64 == -7)
                for id in a.mixerChannels.map(\.hardwareIndex) {
                    let element = base | UInt32(id)
                    #expect(value(writes, .mixerChannelLevel, element)?.asFloat64 == -18)
                    #expect(value(writes, .mixerChannelPan, element)?.asFloat64 == -0.4)
                    #expect(value(writes, .mixerChannelMute, element)?.asBool == true)
                }
                for id in b.mixerChannels.map(\.hardwareIndex) {
                    let solo = value(writes, .mixerChannelSolo, base | UInt32(32 + id))?.asBool
                    #expect(solo == (activeB ? true : nil))
                }
                // Run the actual B7 executor, including both cleanups, without a view.
                var plan = TwoUnitReplay()
                plan.card = writes.map { .card($0) }
                var sent = 0
                var unlocked: [DeviceUnit] = []
                try plan.run(validate: {}, send: { _ in sent += 1 },
                             unlock: { unlocked.append($0); return true }, delay: {})
                #expect(sent == writes.count + 2)
                #expect(unlocked == [.a, .b])
            }
        }
        let changed = ChannelStateStore(defaults: defaults, layout: b, isSimulatingCards: false, identity: 42)
        let changedState: [MixerChannelState]? = changed.load(ChannelStateStore.mixerKey(0))
        #expect(changedState == nil)
        let rediscovered = ChannelStateStore(defaults: defaults, layout: a, isSimulatingCards: false, identity: 42)
        #expect(rediscovered.loadData(ChannelStateStore.mixerKey(0)) == savedA)
        #expect(storeA.mixerPreferences.integer(forKey: "mixerSoftwareReturnSource_0") == 23)
    }

    @Test("An unconfigured mixer gets only its strips unmuted and the return centred")
    func noSavedState() {
        let name = "d45-empty-\(UUID())"
        let defaults = ScratchUserDefaults(suiteName: name)!
        defer { defaults.cleanup() }
        let layout = CardLayout(slot1: .analogADDA16, slot2: .optical)
        let store = ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: false, identity: 42)
        // The driver starts its card mixer with the inputs muted; an untouched
        // strip shows unmuted. So each strip gets an unmute and nothing else.
        let empty = CardMixerReplay.savedWrites(mixer: 0, layout: layout, store: store)
        #expect(empty.count == layout.mixerChannelCount + 1)
        for strip in layout.mixerChannels {
            #expect(value(empty, .mixerChannelMute, 0x10000 | UInt32(strip.hardwareIndex))?.asBool == false)
            #expect(value(empty, .mixerChannelLevel, 0x10000 | UInt32(strip.hardwareIndex)) == nil)
        }
        #expect(value(empty, .mixerChannelPan, 0x10000 | 1000)?.asFloat64 == 0)
        #expect(value(empty, .mixerChannelLevel, 0x10000 | 1000) == nil)
        #expect(value(empty, .mixerChannelLevel, 0x10000 | 2000) == nil)
        store.mixerPreferences.set(-18.0, forKey: "mixerSWReturnLeftLevel_0")
        let restored = CardMixerReplay.savedWrites(mixer: 0, layout: layout, store: store)
        #expect(value(restored, .mixerChannelLevel, 0x10000 | 1000)?.asFloat64 == -18)
        // The whole mixer, defaults included: once after the reset.
        let complete = CardMixerReplay.plan(mixers: [0, 1], layout: layout, store: store, complete: true)
        #expect(complete.count == 2)
        #expect(value(complete[1], .mixerChannelLevel, 0x20000 | 2000)?.asFloat64 == 0)
        #expect(value(complete[1], .mixerChannelLevel, 0x20000 | 1000)?.asFloat64 == 0)
        #expect(value(complete[1], .mixerSoftwareReturnID, 0x20000)?.asUInt32 == 0)
        for strip in layout.mixerChannels {
            let element = 0x20000 | UInt32(strip.hardwareIndex)
            #expect(value(complete[1], .mixerChannelLevel, element)?.asFloat64 == 0)
            #expect(value(complete[1], .mixerChannelMute, element)?.asBool == false)
        }
    }

    @Test("Every failed mixer step ends with unlock")
    func faultEveryStep() throws {
        let name = "d45-fault-\(UUID())"
        let defaults = ScratchUserDefaults(suiteName: name)!
        defer { defaults.cleanup() }
        let layout = CardLayout(slot1: .twoBySix, slot2: .none)
        let store = ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: false, identity: 42)
        let snapshot = MixerStateSnapshot(channelCount: layout.mixerChannelCount, mixer: 0, store: store, defaults: defaults)
        let routes: [UInt8: UInt8] = [32: SymphonyIORoutingAddress.mixer0Base, 33: SymphonyIORoutingAddress.mixer0Base + 1]
        let writes = CardMixerReplay.outputWrites(routes)
            + CardMixerReplay.writes(mixer: 0, layout: layout, snapshot: snapshot)
        for failure in writes.indices {
            var sends = 0
            var unlocks = 0
            var failed = false
            do {
                try ThunderboltPreset.recall(writes, send: { _ in
                    defer { sends += 1 }
                    if sends == failure { throw DeviceConnectionError.notConnected }
                }, unlock: { unlocks += 1; return true }, retryDelay: {})
            } catch { failed = true }
            #expect(failed)
            #expect(sends == failure + 1)
            #expect(unlocks == 1)
        }
    }
}

extension CardMixerReplayTests {
    @Test("Recovery programs card mixer destinations, never a peripheral playback route")
    func mixerDestinations() throws {
        let routes: [UInt8: UInt8] = [32: SymphonyIORoutingAddress.mixer0Base,
                                     33: SymphonyIORoutingAddress.mixer0Base + 1,
                                     48: SymphonyIORoutingAddress.mixer1Base,
                                     49: SymphonyIORoutingAddress.mixer1Base + 1]
        let writes = CardMixerReplay.outputWrites(routes)
        var payloads: [Data] = []
        var unlocks = 0
        try ThunderboltPreset.recall(writes, send: { write in
            guard case .output(let route) = write else {
                Issue.record("Expected a card output register write")
                return
            }
            payloads.append(route.payload)
        }, unlock: { unlocks += 1; return true }, retryDelay: {})
        let expected = [Data([0, 128, 1]), Data([1, 129, 1]), Data([16, 130, 1]), Data([17, 131, 1])]
        #expect(payloads == expected)
        #expect(unlocks == 1)
        #expect(CardMixerReplay.outputWrites([:]).isEmpty)
    }
}

extension CardMixerReplayTests {
    @Test("An edit before or during the replay stops every later write; no unlock is sent")
    func editsInvalidateEveryBoundary() async throws {
        let writes: [ThunderboltPreset.Write] = (0..<4).map {
            .property(.init(selector: .mixerChannelLevel, element: UInt32(0x10000 + $0)), .float64(-18))
        }
        for editAfter in 0..<writes.count {
            let edits = MixerEditGeneration()
            let captured = edits.capture()
            var sent = 0
            var refused = false
            if editAfter == 0 { edits.invalidate() }
            do {
                try await CardMixerReplay.run([Array(writes.prefix(2)), Array(writes.suffix(2))],
                    validateMixer: {}, send: { _ in
                        guard edits.isCurrent(captured) else { throw DeviceConnectionError.notConnected }
                        sent += 1
                        if sent == editAfter { edits.invalidate() }
                    }, pace: {})
            } catch { refused = true }
            #expect(refused)
            #expect(sent == editAfter)
        }
    }

    @Test("Unchanged replay validates each mixer once, paces between writes, sends no 0xDD")
    func liveFenceAndGroupCounts() async throws {
        let write = ThunderboltPreset.Write.property(.init(selector: .mixerChannelLevel, element: 0x10000), .float64(-9))
        var groups = 0, sends = 0, paced = 0
        try await CardMixerReplay.run([[write, write], [], [write, write]],
            validateMixer: { groups += 1 }, send: { _ in sends += 1 }, pace: { paced += 1 })
        #expect(groups == 2)
        #expect(sends == 4)
        #expect(paced == 3)
    }

    @Test("B7 also refuses unlock after a mixer edit")
    func twoUnitEditFence() {
        let edits = MixerEditGeneration()
        let captured = edits.capture()
        var plan = TwoUnitReplay()
        plan.card = [.card(.property(.init(selector: .mixerChannelLevel, element: 0x10000), .float64(-9)))]
        var sends = 0, unlocks = 0
        var refused = false
        do {
            try plan.run(validate: {
                guard edits.isCurrent(captured) else { throw DeviceConnectionError.notConnected }
            }, send: { _ in sends += 1; edits.invalidate() },
                unlock: { _ in unlocks += 1; return true }, delay: {})
        } catch { refused = true }
        #expect(refused)
        #expect(sends == 1)
        #expect(unlocks == 0)
    }
}
