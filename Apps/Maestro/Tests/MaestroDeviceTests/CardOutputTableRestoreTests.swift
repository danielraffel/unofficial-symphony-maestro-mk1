import Foundation
import Testing
import MaestroCore
@testable import MaestroDevice

/// The ThunderBridge chokepoint, on a real `ThunderboltDeviceConnection` over
/// the in-memory driver: a mixer is routed only when the connection saw it
/// written in full in the serving driver state, and a mixer that may be on an
/// output is not written before that.
@Suite("ThunderBridge card mixer chokepoint")
struct CardMixerChokepointTests {
    let layout = CardLayout(slot1: .analogADDA16, slot2: .analogADDA16)
    var required: [Int: Set<CardWriteLogChecker.Control>] { CardWriteLogChecker.required(layout: layout) }

    private func make() -> (ThunderboltDeviceConnection, FakeThunderboltDriver) {
        let driver = FakeThunderboltDriver()
        let tb = ThunderboltDeviceConnection(identifier: SimulatedDevice.symphonyIO32ch().identifier,
                                             audioDeviceID: 0, driver: driver)
        return (tb, driver)
    }

    private func completeWrites(_ mixer: Int, muted: Bool = false) -> [ThunderboltPreset.Write] {
        let snapshot = MixerStateSnapshot(channelCount: layout.mixerChannels.count, mixer: mixer,
                                          store: ChannelStateStore(defaults: ScratchUserDefaults(suiteName: "chokepoint.\(UUID())")!,
                                                                   layout: layout, isSimulatingCards: false, identity: 7))
        return CardMixerReplay.writes(mixer: mixer, layout: layout, snapshot: snapshot).map {
            guard muted, case .property(let address, _) = $0, address.selector == .mixerChannelMute,
                  address.element & 0xFFFF < 1000 else { return $0 }
            return .property(address, .bool(true))
        }
    }

    private func mixerRoute(_ channel: UInt8, mixer: Int) -> ThunderboltCardRouting.Route {
        .init(channel: channel, slot: ThunderboltCardRouting.mixerOutBase + UInt8(mixer * 2) + channel % 2, enabled: true)
    }

    private func direct(_ channel: UInt8) -> ThunderboltCardRouting.Route {
        .init(channel: channel, slot: ThunderboltCardRouting.pciOutBase + channel, enabled: true)
    }

    /// Every table channel direct: nothing is on a mixer afterwards.
    private func clearTable(_ tb: ThunderboltDeviceConnection) throws {
        tb.cardMixers.declareTable(channels: Set(0..<32))
        for channel in UInt8(0)..<32 { #expect(try tb.setCardOutputRoute(direct(channel)) == .written) }
    }

    private let unmute = PropertyAddress(selector: .mixerChannelMute, element: 1 << 16 | 0)

    @Test("at connect a mixer write is deferred (the main pair is on the driver's mixer 1) and nothing reaches the card")
    func mixerWriteDeferredAtConnect() async {
        let (tb, driver) = make()
        await #expect(throws: CardMixerWriteDeferred.self) { try await tb.setProperty(unmute, value: .bool(false)) }
        #expect(driver.sent.isEmpty)
        #expect(tb.cardMixers.needsRestore)
        #expect(tb.cardMixers.owed == 1)
    }

    @Test("a route from a mixer that is not written is deferred, not sent and not thrown")
    func routeDeferred() throws {
        let (tb, driver) = make()
        try clearTable(tb)
        let before = driver.sent.count
        #expect(try tb.setCardOutputRoute(mixerRoute(0, mixer: 0)) == .deferred)
        #expect(driver.sent.count == before)
        #expect(driver.mixerFeeds.isEmpty)
        #expect(CardWriteLogChecker.violations(driver.log, required: required).isEmpty)
    }

    @Test("a mixer on no output takes edits, but only a complete write the connection saw land marks it written")
    func onlyACompleteWriteMarks() async throws {
        let (tb, driver) = make()
        try clearTable(tb)
        // Inaudible: allowed. Not a mark.
        try await tb.setProperty(unmute, value: .bool(false))
        #expect(!tb.cardMixers.isWritten(0))
        #expect(try tb.setCardOutputRoute(mixerRoute(0, mixer: 0)) == .deferred)
        // A plan that leaves one strip's level out is not complete.
        let short = completeWrites(0).filter {
            if case .property(let address, _) = $0 {
                return !(address.selector == .mixerChannelLevel && address.element & 0xFFFF == 3)
            }
            return true
        }
        await #expect(throws: (any Error).self) {
            _ = try await tb.writeCompleteCardMixer(0, writes: short, layout: layout, shouldContinue: { true }, gap: .zero)
        }
        #expect(!tb.cardMixers.isWritten(0))
        // One refused write: not marked either.
        driver.shouldFail = { $0.command == 0xB3 && $0.value == (1 << 16 | 5) }
        await #expect(throws: (any Error).self) {
            _ = try await tb.writeCompleteCardMixer(0, writes: completeWrites(0), layout: layout,
                                                    shouldContinue: { true }, gap: .zero)
        }
        #expect(!tb.cardMixers.isWritten(0))
        driver.shouldFail = nil
        #expect(try await tb.writeCompleteCardMixer(0, writes: completeWrites(0), layout: layout,
                                                    shouldContinue: { true }, gap: .zero) == .written)
        #expect(tb.cardMixers.isWritten(0))
        #expect(!tb.cardMixers.isWritten(1))
        // Now its route goes, the other mixer's does not.
        #expect(try tb.setCardOutputRoute(mixerRoute(0, mixer: 0)) == .written)
        #expect(try tb.setCardOutputRoute(mixerRoute(2, mixer: 1)) == .deferred)
        // A written mixer that plays on an output still takes edits.
        try await tb.setProperty(unmute, value: .bool(true))
        #expect(CardWriteLogChecker.violations(driver.log, required: required).isEmpty)
    }

    @Test("a complete write is refused while the mixer may be on an output")
    func completeWriteNeedsAClearTable() async throws {
        let (tb, driver) = make()
        #expect(try await tb.writeCompleteCardMixer(0, writes: completeWrites(0), layout: layout,
                                                    shouldContinue: { true }, gap: .zero) == .deferred)
        #expect(driver.sent.isEmpty)
    }

    @Test("a link recovery, a card re-init and a driver restart each drop the marks",
          arguments: ["recovery", "reinit", "restart"])
    func stateChangeClears(_ change: String) async throws {
        let (tb, driver) = make()
        try clearTable(tb)
        _ = try await tb.writeCompleteCardMixer(0, writes: completeWrites(0), layout: layout,
                                                shouldContinue: { true }, gap: .zero)
        #expect(try tb.setCardOutputRoute(mixerRoute(4, mixer: 0)) == .written)
        switch change {
        case "recovery": driver.simulateLinkRecovery()
        case "reinit": driver.simulateCardReinit()
        default: driver.simulateDriverRestart()
        }
        // No health poll in between: the next write sees the new state itself.
        #expect(try tb.setCardOutputRoute(mixerRoute(4, mixer: 0)) == .deferred)
        #expect(!tb.cardMixers.isWritten(0))
        await #expect(throws: CardMixerWriteDeferred.self) { try await tb.setProperty(unmute, value: .bool(false)) }
        #expect(CardWriteLogChecker.violations(driver.log, required: required, settled: false).isEmpty)
    }

    @Test("a complete write that an edit or a state change interrupts does not mark")
    func interruptedCompleteWrite() async throws {
        let (tb, driver) = make()
        try clearTable(tb)
        let count = Counter()
        driver.onWrite = { event in
            if case .mixer = event, count.next() == 10 { driver.simulateCardReinit() }
        }
        await #expect(throws: (any Error).self) {
            _ = try await tb.writeCompleteCardMixer(0, writes: completeWrites(0), layout: layout,
                                                    shouldContinue: { true }, gap: .zero)
        }
        #expect(!tb.cardMixers.isWritten(0))
    }

    @Test("a whole mixer is written Master, Software Return, then strips with level and pan before mute and solo")
    func completeWriteOrder() throws {
        let writes = completeWrites(0)
        let keys: [(AudioPropertySelector, UInt32)] = writes.compactMap {
            if case .property(let address, _) = $0 { return (address.selector, address.element & 0xFFFF) }
            return nil
        }
        #expect(keys.first?.1 == 2000)
        let firstStrip = try #require(keys.firstIndex { $0.1 < 1000 && $0.0 != .mixerSoftwareReturnID })
        // Master and all of Software Return (its source included) come before any strip.
        let headChannels: Set<UInt32> = Set(keys[..<firstStrip].map(\.1))
        #expect(headChannels.isSubset(of: [2000, 1000, 0x1002, 0]))
        #expect(keys[..<firstStrip].contains { $0.0 == .mixerSoftwareReturnID })
        #expect(keys[firstStrip...].allSatisfy { $0.1 < 1000 })
        // Software Return: level before mute and solo, the source last.
        let own = keys[..<firstStrip].filter { $0.1 != 2000 }.map(\.0)
        let ownLevel = try #require(own.firstIndex(of: .mixerChannelLevel))
        let ownMute = try #require(own.firstIndex(of: .mixerChannelMute))
        #expect(ownLevel < ownMute)
        #expect(own.last == .mixerSoftwareReturnID)
        // Each strip: level, pan, mute, solo.
        let strips = Array(keys[firstStrip...])
        try #require(strips.count == layout.mixerChannels.count * 4)
        for start in stride(from: 0, to: strips.count, by: 4) {
            #expect(strips[start..<start + 4].map(\.0)
                    == [.mixerChannelLevel, .mixerChannelPan, .mixerChannelMute, .mixerChannelSolo])
            #expect(Set(strips[start..<start + 4].map(\.1)).count == 1)
        }
        // And it is exactly what the connection requires of a complete write.
        let addresses: Set<PropertyAddress> = Set(writes.compactMap {
            if case .property(let address, _) = $0, address.selector != .mixerSoftwareReturnID { return address }
            return nil
        })
        #expect(addresses == CardMixerReplay.requiredAddresses(mixer: 0, layout: layout))
    }

    @Test("recall order: routes with the mixer-fed ones disabled, the rest, the mixers, then the mixer-fed routes")
    func recallOrder() {
        let mixer = ThunderboltPreset.Write.property(unmute, .bool(false))
        let other = ThunderboltPreset.Write.property(PropertyAddress(selector: .softLimit, scope: .input, element: 0), .uint32(1))
        let fed = ThunderboltPreset.Write.output(mixerRoute(0, mixer: 0))
        let plain = ThunderboltPreset.Write.output(direct(2))
        let ordered = CardOutputTableOrder.ordered([fed, mixer, plain, other])
        #expect(ordered == [.output(CardOutputTableOrder.disabled(mixerRoute(0, mixer: 0))), plain, other, mixer, fed])
        // A mixer already written keeps its route where it was: nothing is silenced.
        #expect(CardOutputTableOrder.ordered([fed, mixer, plain, other], written: [0]) == [fed, plain, other, mixer])
    }

    @Test("a preset recall on written mixers passes; a recall that fails partway leaves no output on a mixer it touched")
    func presetRecall() async throws {
        let (tb, driver) = make()
        try clearTable(tb)
        for mixer in 0..<2 {
            _ = try await tb.writeCompleteCardMixer(mixer, writes: completeWrites(mixer), layout: layout,
                                                    shouldContinue: { true }, gap: .zero)
        }
        #expect(try tb.setCardOutputRoute(mixerRoute(0, mixer: 0)) == .written)
        #expect(try tb.setCardOutputRoute(mixerRoute(1, mixer: 0)) == .written)
        tb.cardMixers.completeRestore(epoch: tb.cardMixers.epoch, covering: tb.cardMixers.owed)
        #expect(!tb.cardMixers.needsRestore)

        let writes = completeWrites(0, muted: true)
            + [.output(mixerRoute(0, mixer: 0)), .output(mixerRoute(1, mixer: 0)), .output(direct(2))]
        let start = driver.log.count
        try tb.applyPresetWrites(writes, layout: layout)
        let recall = Array(driver.log[start...])
        // The main pair is disabled first, the mixer written, then routed.
        #expect(recall.prefix(2) == [.route(channel: 0, mixer: nil, enabled: false),
                                     .route(channel: 1, mixer: nil, enabled: false)])
        #expect(recall.suffix(2) == [.route(channel: 0, mixer: 0, enabled: true),
                                     .route(channel: 1, mixer: 0, enabled: true)])
        #expect(driver.mixerFeeds == [0: 0, 1: 0])
        // The recall does not carry every control: the restore is owed.
        #expect(tb.cardMixers.needsRestore)

        // Now one that the card refuses halfway through the mixer.
        driver.shouldFail = { $0.command == 0xB3 && $0.value == (1 << 16 | 7) }
        #expect(throws: (any Error).self) { try tb.applyPresetWrites(writes, layout: layout) }
        driver.shouldFail = nil
        #expect(driver.mixerFeeds.isEmpty)
        #expect(!tb.cardMixers.isWritten(0))
        #expect(tb.cardMixers.isWritten(1))
        #expect(try tb.setCardOutputRoute(mixerRoute(0, mixer: 0)) == .deferred)
        #expect(CardWriteLogChecker.violations(driver.log, required: required).isEmpty)
    }

    @Test("a recall that fails in its last phase, with a mixer route already live, takes that route back")
    func presetRecallFailsInRoutePhase() async throws {
        let (tb, driver) = make()
        try clearTable(tb)
        _ = try await tb.writeCompleteCardMixer(0, writes: completeWrites(0), layout: layout,
                                                shouldContinue: { true }, gap: .zero)
        let writes = completeWrites(0, muted: true) + [.output(mixerRoute(0, mixer: 0)), .output(mixerRoute(1, mixer: 0))]
        driver.shouldFail = { $0.command == 0xB5 && $0.payload == [1, ThunderboltCardRouting.mixerOutBase + 1, 1] }
        #expect(throws: (any Error).self) { try tb.applyPresetWrites(writes, layout: layout) }
        #expect(driver.mixerFeeds.isEmpty)
        #expect(!tb.cardMixers.isWritten(0))
    }

    // MARK: 64 channels, two units

    private func twoUnits() -> (ThunderboltDeviceConnection, ThunderboltUnitBConnection, FakeThunderboltDriver, CardLayout) {
        let layoutB = CardLayout(slot1: .analogADDA16, slot2: .none)
        let driver = FakeThunderboltDriver()
        driver.portSelectionOverride = PortSelection.ports1And2.rawValue
        driver.unitB = UnitBState(present: true, boardType: [layoutB.slot1.rawValue, layoutB.slot2.rawValue],
                                  boardValid: [1, 1], prefix: 0x42, clockSource: 1,
                                  setupFlags: 1, txErrors: 0, generation: 1)
        driver.port2 = SecondPortState(portCount: 2, flags: 0x0F)
        let tb = ThunderboltDeviceConnection(identifier: SimulatedDevice.symphonyIO32ch().identifier,
                                             audioDeviceID: 0, driver: driver)
        return (tb, tb.makeUnitBConnection(), driver, layoutB)
    }

    /// Both units' outputs direct, except Mixer 1 on unit A's first pair and
    /// Mixer 2 on unit B's first pair; both mixers in full.
    private func twoUnitPlan(layoutB: CardLayout, dropping dropped: PropertyAddress? = nil) -> TwoUnitReplay {
        var plan = TwoUnitReplay()
        plan.unitBBoards = [layoutB.slot1.rawValue, layoutB.slot2.rawValue]
        plan.mixerLayouts = (layout, layoutB)
        for channel in UInt8(0)..<64 {
            let route: ThunderboltCardRouting.Route = switch channel {
            case 0, 1: mixerRoute(channel, mixer: 0)
            case 32, 33: mixerRoute(channel, mixer: 1)
            default: direct(channel)
            }
            plan.card.append(.card(.output(route)))
        }
        let store = ChannelStateStore(defaults: ScratchUserDefaults(suiteName: "chokepoint.\(UUID())")!,
                                      layout: layout, isSimulatingCards: false, identity: 7)
        for mixer in 0..<2 {
            let a = MixerStateSnapshot(channelCount: layout.mixerChannels.count, mixer: mixer, store: store)
            let b = MixerStateSnapshot(channelCount: layoutB.mixerChannels.count, mixer: mixer, store: store)
            plan.card += CardMixerReplay.writes(mixer: mixer, layout: layout, snapshot: a, second: (layoutB, b))
                .filter { if case .property(let address, _) = $0 { address != dropped } else { true } }
                .map { .card($0) }
        }
        return plan
    }

    @Test("64 channels: the two-unit replay takes the same order through the same chokepoint, and a second one silences nothing")
    func twoUnitReplay() throws {
        let (tb, b, driver, layoutB) = twoUnits()
        let needed = CardWriteLogChecker.required(layout: layout, second: layoutB)
        try tb.replayTwoUnits(twoUnitPlan(layoutB: layoutB), unitB: b, recoveryCount: 0, unitBGeneration: 1)
        #expect(driver.mixerFeeds == [0: 0, 1: 0, 32: 1, 33: 1])
        #expect(tb.cardMixers.writtenMixers == [0, 1])
        #expect(CardWriteLogChecker.violations(driver.log, required: needed).isEmpty)
        // The mixer-fed pairs were disabled until their mixer had every control.
        let log = driver.log
        let off = try #require(log.firstIndex(of: .route(channel: 32, mixer: nil, enabled: false)))
        let on = try #require(log.firstIndex(of: .route(channel: 32, mixer: 1, enabled: true)))
        #expect(off < on)
        // Nothing changed in the driver state: the next replay disables nothing.
        let before = log.count
        try tb.replayTwoUnits(twoUnitPlan(layoutB: layoutB), unitB: b, recoveryCount: 0, unitBGeneration: 1)
        #expect(!driver.log[before...].contains { if case .route(_, _, false) = $0 { true } else { false } })
        // A link recovery: disabled again, written again, routed again.
        driver.simulateLinkRecovery()
        try tb.replayTwoUnits(twoUnitPlan(layoutB: layoutB), unitB: b, recoveryCount: 1, unitBGeneration: 1)
        #expect(driver.mixerFeeds == [0: 0, 1: 0, 32: 1, 33: 1])
        #expect(CardWriteLogChecker.violations(driver.log, required: needed).isEmpty)
    }

    @Test("64 channels: every card channel is declared and written; one the plan does not route is disabled, also when an earlier session left it on a mixer")
    func twoUnitReplayWritesEveryChannel() throws {
        let (tb, b, driver, layoutB) = twoUnits()
        // An earlier session, with other cards fitted, left Mixer 2 here.
        driver.seedRoute(channel: 50, mixer: 1)
        var plan = twoUnitPlan(layoutB: layoutB)
        // The plan routes only the outputs the fitted cards have: unit B's
        // slot 2 is empty, so its channels 48-63 are not in it.
        plan.card.removeAll {
            if case .card(.output(let route)) = $0 { return route.channel >= 48 }
            return false
        }
        try tb.replayTwoUnits(plan, unitB: b, recoveryCount: 0, unitBGeneration: 1)
        #expect(driver.mixerFeeds == [0: 0, 1: 0, 32: 1, 33: 1])
        #expect(driver.routes.count == 64)
        #expect((48..<64).allSatisfy { driver.routes[UInt8($0)]?.enabled == false })
        #expect(tb.cardMixers.writtenMixers == [0, 1])
        #expect(CardWriteLogChecker.violations(driver.log, required: CardWriteLogChecker.required(layout: layout, second: layoutB)) == [])
    }

    @Test("the in-memory driver re-inits a card as the real one: the app's last routes and mixer controls, and no unit B channel without unit B")
    func fakeDriverReinit() throws {
        let (tb, driver) = make()
        try clearTable(tb)
        _ = try tb.setCardOutputRoute(direct(0))
        _ = try tb.setCardOutputRoute(direct(1))
        // The app's routes: Mixer 2 on channels 6/7, the main pair direct.
        driver.seedRoute(channel: 9, mixer: 0)          // not a route the app wrote
        try driver.sendVendorCommand(command: 0xB5, value: 0, payload: mixerRoute(6, mixer: 1).payload, port: 0)
        try driver.sendVendorCommand(command: 0xB3, value: 2 << 16 | 3, payload: Data([1]), port: 0)
        driver.simulateCardReinit()
        // Replayed: the app's route to Mixer 2, and the direct main pair
        // (not the start-up default, Mixer 1). The seeded route is the
        // card's own state and is gone.
        #expect(driver.mixerFeeds == [6: 1])
        #expect(driver.routes[6] == mixerRoute(6, mixer: 1))
        // The mixer the app wrote keeps its controls; the other is at default.
        #expect(driver.control(mixer: 1, command: 0xB3, channel: 3) == 1)
        #expect(driver.control(mixer: 0, command: 0xB3, channel: 3) == nil)
        guard case .driverState(let feeds)? = driver.log.last else { Issue.record("no driver state event"); return }
        #expect(feeds == [6: 1])
        // The ledger does not trust any of it: the marks are gone.
        _ = tb.probeEndpoint()
        #expect(tb.cardMixers.writtenMixers.isEmpty)
        #expect(tb.cardMixers.mayFeed(1))
        // A link recovery and a restart are the start-up default table.
        driver.simulateLinkRecovery()
        #expect(driver.mixerFeeds == [0: 0, 1: 0])
        // Unit B's channels do not exist at 32 channels.
        let before = driver.sent.count
        #expect(throws: (any Error).self) {
            try driver.sendVendorCommand(command: 0xB5, value: 0, payload: self.direct(32).payload, port: 0)
        }
        #expect(throws: (any Error).self) {
            try driver.sendVendorCommand(command: 0xB5, value: 0, payload: Data([64, 64, 1]), port: 0)
        }
        #expect(driver.sent.count == before && driver.routes[32] == nil)
        let (_, _, both, _) = twoUnits()
        try both.sendVendorCommand(command: 0xB5, value: 0, payload: direct(32).payload, port: 0)
        #expect(both.routes[32] == direct(32))
    }

    @Test("64 channels: a plan that leaves one of unit B's strips out does not mark the mixer, and its route is not sent")
    func twoUnitReplayIncomplete() {
        let (tb, b, driver, layoutB) = twoUnits()
        let strip = PropertyAddress(selector: .mixerChannelMute,
                                    element: 2 << 16 | UInt32(32 + layoutB.mixerChannels[3].hardwareIndex))
        #expect(throws: (any Error).self) {
            try tb.replayTwoUnits(twoUnitPlan(layoutB: layoutB, dropping: strip), unitB: b,
                                  recoveryCount: 0, unitBGeneration: 1)
        }
        #expect(tb.cardMixers.writtenMixers == [0])
        #expect(driver.mixerFeeds == [0: 0, 1: 0])
        #expect(CardWriteLogChecker.violations(driver.log, required: CardWriteLogChecker.required(layout: layout, second: layoutB)).isEmpty)
    }

    @Test("the checker reports a mixer routed before it was written, an unmute on a live unwritten mixer, and a stale route left at the end")
    func checkerCatchesViolations() {
        let early: [FakeThunderboltDriver.Event] = [
            .driverState(feeds: [:]), .route(channel: 4, mixer: 1, enabled: true),
        ]
        #expect(CardWriteLogChecker.violations(early, required: required, settled: false).count == 1)
        let unmuteOnDefault: [FakeThunderboltDriver.Event] = [
            .driverState(feeds: [0: 0, 1: 0]), .mixer(mixer: 0, command: 0xB3, channel: 0, byte: 0),
        ]
        #expect(CardWriteLogChecker.violations(unmuteOnDefault, required: required, settled: false).count == 1)
        let stale: [FakeThunderboltDriver.Event] = [.driverState(feeds: [0: 0, 1: 0])]
        #expect(CardWriteLogChecker.violations(stale, required: required).count == 2)
        #expect(CardWriteLogChecker.violations(stale, required: required, settled: false).isEmpty)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
    var count: Int { lock.withLock { value } }
}
