import Foundation
import Testing
@testable import MaestroApp
import MaestroCore
import MaestroDevice

private final class SilentVendorTransport: VendorTransport, @unchecked Sendable {
    var isConnected: Bool { true }
    func sendVendorCommand(command: UInt8, value: UInt32, payload: Data, port: UInt8) throws {}
    func readVendorCommand(command: UInt8, value: UInt32, responseLength: Int, port: UInt8) throws -> Data {
        Data(count: responseLength)
    }
}

private final class Tick: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}

extension StandardDefaultsSuites {
/// ThunderBridge, on the real restore, service loop, route and mixer writes
/// and preset recall, over an in-memory driver. Every scenario replays the
/// driver's write log through `CardWriteLogChecker`: no output is ever
/// routed from a card mixer that was not written in full in the driver state
/// then serving, no mixer that may be on an output is written before that,
/// and none is left on a stale or driver-default mixer route.
@Suite("ThunderBridge mixer routing safety", .serialized)
@MainActor
struct CardOutputTableGuardTests {
    private func restoringDefaults() -> () -> Void {
        let defaults = UserDefaults.standard
        let before = defaults.dictionaryRepresentation()
        return {
            for key in defaults.dictionaryRepresentation().keys where before[key] == nil { defaults.removeObject(forKey: key) }
            for (key, value) in before { defaults.set(value, forKey: key) }
        }
    }

    private let layout = CardLayout(slot1: .analogADDA16, slot2: .analogADDA16)
    private var required: [Int: Set<CardWriteLogChecker.Control>] { CardWriteLogChecker.required(layout: layout) }
    private let mixer1 = SymphonyIORoutingAddress.mixer0Base

    private func makeState(identity: UInt64?, cardsRead: Bool = true,
                           mixer1ToLine12: Bool = false) -> (AppState, ThunderboltDeviceConnection, FakeThunderboltDriver) {
        UserDefaults.standard.removeObject(forKey: "mixerWideState.migratedTo")
        let state = AppState()
        state.cardMixerCommandGap = .zero
        state.cardMixerEditQuietWindow = .zero
        state.connectionMode = .hardware
        state.transportType = .thunderbolt
        state.isHardwareInitialized = true
        let driver = FakeThunderboltDriver()
        let tb = ThunderboltDeviceConnection(identifier: SimulatedDevice.symphonyIO32ch().identifier,
                                             audioDeviceID: 0, driver: driver)
        state.device = tb
        // A driver that reports a build before 150 (no selector 17): card by
        // card. With no build known nothing would be written.
        state.servingDextBuild = .build(140)
        state.primaryBoardType = .analogADDA16
        state.secondaryBoardType = .analogADDA16
        state.primaryBoardSource = cardsRead ? .detected : .cached
        state.secondaryBoardSource = cardsRead ? .detected : .cached
        if let identity {
            state.unitAIdentity = identity
            state.unitAIdentityState = .known(identity)
        }
        // 32 channels: 16 software pairs, so row 16 is Mixer 1. Column 0 is Line 1/2.
        if mixer1ToLine12 { state.peripheralRoutingCache(direction: "output").save([16: Set([0])]) }
        return (state, tb, driver)
    }

    /// Health cycles (no waiting for the backoff) until nothing is owed.
    private func settle(_ state: AppState, _ tb: ThunderboltDeviceConnection, cycles: Int = 12) async {
        for _ in 0..<cycles {
            state.cardOutputRetryAfter = .distantPast
            await state.serviceCardOutputTable(tb)
            if !tb.cardMixers.needsRestore, !state.cardOutputTableReplayNeeded { return }
        }
    }

    private func violations(_ driver: FakeThunderboltDriver, settled: Bool = true) -> [String] {
        CardWriteLogChecker.violations(driver.log, required: required, settled: settled)
    }

    /// What is on the card equals the saved table.
    private func expectUnitEqualsTable(_ state: AppState, _ tb: ThunderboltDeviceConnection,
                                       _ driver: FakeThunderboltDriver,
                                       sourceLocation: SourceLocation = #_sourceLocation) {
        for (destination, source) in state.thunderboltOutputTable(for: tb, quiet: true) {
            let wanted = ThunderboltCardRouting.route(destination: destination, source: source)
            #expect(wanted != nil && driver.routes[wanted!.channel] == wanted,
                    "output \(destination) ← \(source)", sourceLocation: sourceLocation)
        }
    }

    private func saveStrip(_ state: AppState, mixer: Int, strip: Int, muted: Bool, level: Double = -6) {
        var strips: [MixerChannelState] = state.channelStateStore.load(ChannelStateStore.mixerKey(mixer))
            ?? Array(repeating: MixerChannelState(level: 0, pan: 0, isMuted: false, isSoloed: false),
                     count: layout.mixerChannels.count)
        strips[strip] = MixerChannelState(level: level, pan: 0, isMuted: muted, isSoloed: false)
        state.channelStateStore.save(strips, for: ChannelStateStore.mixerKey(mixer))
    }

    private func muteByte(_ driver: FakeThunderboltDriver, mixer: Int, strip: Int) -> UInt8? {
        driver.control(mixer: mixer, command: 0xB3, channel: UInt32(layout.mixerChannels[strip].hardwareIndex))
    }

    private func withMute(_ writes: [ThunderboltPreset.Write], strip: Int, muted: Bool) -> [ThunderboltPreset.Write] {
        let channel = UInt32(layout.mixerChannels[strip].hardwareIndex)
        return writes.map {
            guard case .property(let address, _) = $0, address.selector == .mixerChannelMute,
                  address.element & 0xFFFF == channel else { return $0 }
            return .property(address, .bool(muted))
        }
    }

    private func mixerEvents(_ log: [FakeThunderboltDriver.Event]) -> Int {
        log.filter { if case .mixer = $0 { true } else { false } }.count
    }

    // MARK: Connect

    @Test("connect on the default direct routing: no output is silenced, no mixer is routed, both mixers are written after the main pair is direct")
    func connectDirect() async {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, tb, driver) = makeState(identity: 0xF2C0_0001)
        #expect(state.mixerPreferences.isWritable)
        await state.syncOutputRoutingToHardware()
        #expect(!tb.cardMixers.needsRestore)
        #expect(!state.cardOutputTableReplayNeeded)
        #expect(state.restoreStatusNote == nil)
        #expect(violations(driver).isEmpty)
        #expect(driver.mixerFeeds.isEmpty)
        // No silence for a user who routes no mixer.
        #expect(!driver.log.contains { if case .route(_, _, false) = $0 { true } else { false } })
        #expect(tb.cardMixers.writtenMixers == [0, 1])
        expectUnitEqualsTable(state, tb, driver)
    }

    @Test("connect with Mixer 1 on Line 1/2: the pair is disabled, the mixer written from the saved state, then routed")
    func connectWithMixerRoute() async throws {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, tb, driver) = makeState(identity: 0xF2C0_0002, mixer1ToLine12: true)
        saveStrip(state, mixer: 0, strip: 2, muted: true)
        // The driver says it holds app state for both mixers: that is not evidence.
        driver.claimAppState()
        // An earlier session left Mixer 2 on output 5.
        driver.seedRoute(channel: 4, mixer: 1)
        await state.syncOutputRoutingToHardware()
        #expect(!tb.cardMixers.needsRestore)
        #expect(violations(driver).isEmpty)
        #expect(driver.mixerFeeds == [0: 0, 1: 0])
        let log = driver.log
        let disabled = try #require(log.firstIndex(of: .route(channel: 0, mixer: nil, enabled: false)))
        let firstMixer = try #require(log.firstIndex { if case .mixer = $0 { true } else { false } })
        let routed = try #require(log.firstIndex(of: .route(channel: 0, mixer: 0, enabled: true)))
        #expect(disabled < firstMixer && firstMixer < routed)
        // The strips on the card are the saved ones.
        #expect(muteByte(driver, mixer: 0, strip: 2) == 1)
        #expect(muteByte(driver, mixer: 0, strip: 3) == 0)
        expectUnitEqualsTable(state, tb, driver)
        #expect(state.restoreStatusNote == nil)
    }

    @Test("a second run with nothing changed in the driver state silences nothing")
    func replayDoesNotSilence() async {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, tb, driver) = makeState(identity: 0xF2C0_0003, mixer1ToLine12: true)
        await state.syncOutputRoutingToHardware()
        let before = driver.log.count
        state.cardOutputTableReplayNeeded = true
        await settle(state, tb)
        let again = driver.log[before...]
        #expect(!again.isEmpty)
        #expect(!again.contains { if case .route(_, _, false) = $0 { true } else { false } })
        #expect(driver.mixerFeeds == [0: 0, 1: 0])
        #expect(violations(driver).isEmpty)
    }

    // MARK: One restore per connect

    /// Lets every task the sequence spawned run: a restore started from a
    /// spawned task finishes before anything is counted.
    private func drain(_ state: AppState) async {
        var quiet = 0
        for _ in 0..<400 where quiet < 20 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
            quiet = state.cardOutputRestoreRunning ? 0 : quiet + 1
        }
    }

    /// How many times each mixer was written in full since `from`: every
    /// complete write sends strip 1's mute once.
    private func wholeMixerWrites(_ state: AppState, _ driver: FakeThunderboltDriver, from: Int = 0) -> [Int] {
        let required = CardWriteLogChecker.required(layout: layout, routes: state.thunderboltCaptureRoutes(unit: .a))
        return (0..<2).map { mixer in
            guard let channel = required[mixer]?.filter({ $0.command == 0xB3 }).map(\.channel).min() else { return -1 }
            return driver.log[from...].filter {
                if case .mixer(mixer, 0xB3, channel, _) = $0 { true } else { false }
            }.count
        }
    }

    private func violations(_ state: AppState, _ driver: FakeThunderboltDriver) -> [String] {
        CardWriteLogChecker.violations(driver.log, required: CardWriteLogChecker.required(
            layout: layout, routes: state.thunderboltCaptureRoutes(unit: .a)), settled: true)
    }

    /// The connect sequence with a saved input route that renumbers the
    /// strips, Mixer 1 on Line 1/2.
    private func connected(identity: UInt64) async -> (AppState, ThunderboltDeviceConnection, FakeThunderboltDriver) {
        let (state, tb, driver) = makeState(identity: identity, mixer1ToLine12: true)
        driver.boards = (layout.slot1.rawValue, layout.slot2.rawValue)
        // Reading the capture table back after the input routing is slow on
        // a real unit: long enough for a restore started meanwhile to end.
        driver.onRead = { if $0 == SymphonyIOCommand.audioRouting.rawValue { usleep(3_000) } }
        let numbers = state.thunderboltMixerInputNumbers()
        UserDefaults.standard.set(true, forKey: ThunderboltInputRoutingMigration.doneKey)
        state.peripheralRoutingCache(direction: "input").save([0: 2])
        await state.syncSavedStateToHardware()
        await drain(state)
        #expect(state.thunderboltMixerInputNumbers() != numbers, "the saved input route renumbers the strips")
        return (state, tb, driver)
    }

    @Test("connect: the input routing, then one restore of the routes and both mixers, in order")
    func connectRestoresOnce() async {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, tb, driver) = await connected(identity: 0xF2C0_0101)
        #expect(wholeMixerWrites(state, driver) == [1, 1])
        // The next health cycle finds nothing owed ("Restoring" does not come back).
        let mark = driver.log.count
        await state.serviceCardOutputTable(tb)
        await drain(state)
        #expect(driver.log.count == mark)
        #expect(!tb.cardMixers.needsRestore)
        #expect(!state.cardOutputTableReplayNeeded)
        #expect(state.restoreStatusNote == nil)
        // A fresh connection: Line 1/2 disabled until Mixer 1 is written, then routed.
        #expect(violations(state, driver).isEmpty)
        #expect(driver.mixerFeeds == [0: 0, 1: 0])
        expectUnitEqualsTable(state, tb, driver)
    }

    @Test("with nothing owed the output sync writes nothing, and the same input table written again owes nothing")
    func nothingOwedWritesNothing() async {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, tb, driver) = await connected(identity: 0xF2C0_0102)
        let mark = driver.log.count
        let owed = tb.cardMixers.owed
        await state.syncOutputRoutingToHardware()
        await drain(state)
        #expect(driver.log.count == mark)
        await state.syncInputRoutingToHardware()
        await drain(state)
        #expect(tb.cardMixers.owed == owed)
        #expect(!tb.cardMixers.needsRestore)
        #expect(driver.log.count == mark)
        // The whole sequence again on the same connection (launch and
        // reconnect both ask for it): nothing is restored again.
        await state.syncSavedStateToHardware()
        await drain(state)
        #expect(wholeMixerWrites(state, driver, from: mark) == [0, 0])
        #expect(!driver.log[mark...].contains { if case .route = $0 { true } else { false } })
    }

    @Test("channel naming (sample rate, optical format, Replaces) changing after the restore writes nothing")
    func namingChangeOwesNothing() async {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, tb, driver) = await connected(identity: 0xF2C0_0106)
        let mark = driver.log.count
        let epoch = tb.cardMixers.epoch
        state.channelNaming.sampleRate = 96_000
        state.channelNaming.opticalIsSPDIF = [true, nil]
        state.channelNaming.spdifReplace = [1, 0]
        #expect(state.cardLayout != state.cardRestoreOwner?.owner.layout, "the naming is part of the layout")
        for _ in 0..<3 {
            await state.serviceCardOutputTable(tb)
            await drain(state)
        }
        #expect(driver.log.count == mark)
        #expect(tb.cardMixers.epoch == epoch)
        #expect(tb.cardMixers.writtenMixers == [0, 1])
        #expect(!state.cardOutputTableReplayNeeded)
    }

    @Test("the input routing put back on the defaults (the channel-order reset): the mixers are written again, in order")
    func inputResetToDefaultsOwesMixers() async {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, tb, driver) = await connected(identity: 0xF2C0_0105)
        // As `runChannelOrderResetIfNeeded` does when the inputs moved: the
        // unit still has the saved table, the strips are numbered from it.
        state.peripheralRoutingCache(direction: "input").save([Int: Int]())
        RoutingMixerReset.setPending(.thunderboltInputRouting)
        state.thunderboltInputRoutingWritten = false
        state.invalidateThunderboltInputMeterMap()
        let mark = driver.log.count
        await state.syncInputRoutingToHardware()
        await drain(state)
        #expect(wholeMixerWrites(state, driver, from: mark) == [1, 1])
        #expect(!tb.cardMixers.needsRestore)
        // Every control of both mixers in the new numbering went out again. (The
        // log checker takes one numbering for the whole log, so it cannot
        // judge the writes made before the table changed.)
        let required = CardWriteLogChecker.required(layout: layout, routes: state.thunderboltCaptureRoutes(unit: .a))
        for mixer in 0..<2 {
            let sent = Set(driver.log[mark...].compactMap { event -> CardWriteLogChecker.Control? in
                if case .mixer(mixer, let command, let channel, _) = event {
                    return CardWriteLogChecker.Control(command: command, channel: channel)
                }
                return nil
            })
            #expect(required[mixer]?.isSubset(of: sent) == true, "mixer \(mixer + 1)")
        }
    }

    @Test("a link recovery: one restore of the routes and both mixers")
    func recoveryRestoresOnce() async {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, tb, driver) = await connected(identity: 0xF2C0_0103)
        driver.simulateLinkRecovery()
        _ = tb.probeEndpoint()
        let mark = driver.log.count
        await state.restoreAfterLinkRecovery(tb)
        await drain(state)
        #expect(wholeMixerWrites(state, driver, from: mark) == [1, 1])
        let after = driver.log.count
        await state.serviceCardOutputTable(tb)
        await drain(state)
        #expect(driver.log.count == after)
        #expect(!tb.cardMixers.needsRestore)
        #expect(!state.cardOutputTableReplayNeeded)
        #expect(violations(state, driver).isEmpty)
        #expect(driver.mixerFeeds == [0: 0, 1: 0])
        expectUnitEqualsTable(state, tb, driver)
    }

    @Test("the Mixer page re-sends no strip on ThunderBridge once the restore is complete; a reset still writes")
    func mixerPageAfterRestore() async {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, tb, driver) = await connected(identity: 0xF2C0_0104)
        #expect(tb.cardMixers.isRestored)
        #expect(!state.mixerPageMayWriteStrips(mixer: 0, recalling: true))
        #expect(!state.mixerPageMayWriteStrips(mixer: 1, recalling: true))
        #expect(state.mixerPageMayWriteStrips(mixer: 0, recalling: false))
        // A card layout change: the restore writes the mixers again, not the page.
        let mark = driver.log.count
        state.secondaryBoardType = .analogAD16
        driver.boards = (layout.slot1.rawValue, IOCardType.analogAD16.rawValue)
        await state.serviceCardOutputTable(tb)
        await drain(state)
        #expect(mixerEvents(Array(driver.log[mark...])) > 0)
        #expect(state.cardRestoreOwner?.owner.layout == state.cardLayout)
    }

    // MARK: Driver state changes

    @Test("a link recovery, a card re-init and a driver restart: the health loop puts everything back in order",
          arguments: ["recovery", "reinit", "restart"])
    func driverStateChange(_ change: String) async {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, tb, driver) = makeState(identity: 0xF2C0_0004, mixer1ToLine12: true)
        saveStrip(state, mixer: 0, strip: 0, muted: true)
        await state.syncOutputRoutingToHardware()
        #expect(!tb.cardMixers.needsRestore)
        switch change {
        case "recovery": driver.simulateLinkRecovery()
        case "reinit": driver.simulateCardReinit()
        default: driver.simulateDriverRestart()
        }
        // The health loop's probe sees it; nothing is trusted from before.
        _ = tb.probeEndpoint()
        #expect(tb.cardMixers.needsRestore)
        #expect(tb.cardMixers.writtenMixers.isEmpty)
        await state.serviceCardOutputTable(tb)
        #expect(!tb.cardMixers.needsRestore)
        #expect(violations(driver).isEmpty)
        #expect(driver.mixerFeeds == [0: 0, 1: 0])
        #expect(muteByte(driver, mixer: 0, strip: 0) == 1)
        expectUnitEqualsTable(state, tb, driver)
    }

    // MARK: Interactive writes

    @Test("a mixer route clicked before that mixer is written is owed, its output disabled, and sent once the mixer is written")
    func interactiveRouteBeforeMixerWritten() async throws {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, tb, driver) = makeState(identity: 0xF2C0_0005)
        // Before any restore has run on this driver state.
        let result = try await state.writeOutputRoutePair(destLeft: 34, srcLeft: mixer1, device: tb)
        #expect(result == .deferred)
        #expect(driver.mixerFeeds == [0: 0, 1: 0])   // only the driver's own default, untouched
        #expect(driver.routes[2]?.enabled == false && driver.routes[3]?.enabled == false)
        #expect(state.restoreStatusNote == PortStatusMessage.restoringMixerAndRouting)
        // The page saves the choice and shows it.
        state.peripheralRoutingCache(direction: "output").save([16: Set([1])])
        state.outputRoutingSaved()
        await settle(state, tb)
        #expect(driver.mixerFeeds == [2: 0, 3: 0])
        #expect(violations(driver).isEmpty)
        #expect(state.restoreStatusNote == nil)
        expectUnitEqualsTable(state, tb, driver)
        // After the mixers are written a mixer route is immediate.
        #expect(try await state.writeOutputRoutePair(destLeft: 36, srcLeft: SymphonyIORoutingAddress.mixer1Base,
                                                     device: tb) == .written)
        #expect(driver.mixerFeeds[4] == 1)
        #expect(violations(driver).isEmpty)
    }

    @Test("a strip edit made before the mixers are written is deferred, kept, and on the card after the restore")
    func deferredEditIsReplayed() async {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, tb, driver) = makeState(identity: 0xF2C0_0006, mixer1ToLine12: true)
        // The page saves the edit, then sends it: the main pair is still on
        // the driver's mixer 1, so it is not sent.
        saveStrip(state, mixer: 0, strip: 1, muted: false, level: -12)
        let address = PropertyAddress(selector: .mixerChannelMute,
                                      element: 1 << 16 | UInt32(layout.mixerChannels[1].hardwareIndex))
        await #expect(throws: CardMixerWriteDeferred.self) { try await tb.setProperty(address, value: .bool(false)) }
        #expect(driver.sent.isEmpty)
        #expect(await state.mixerPageDefersToCardMixerRestore(mixer: 0))
        await settle(state, tb)
        #expect(driver.control(mixer: 0, command: 0xB0, channel: UInt32(layout.mixerChannels[1].hardwareIndex)) == 36)
        #expect(violations(driver).isEmpty)
        #expect(!(await state.mixerPageDefersToCardMixerRestore(mixer: 0)))
    }

    @Test("a route moved from a mixer to a direct source while the restore is writing that mixer is not put back by a later phase")
    func directEditDuringRestore() async {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, tb, driver) = makeState(identity: 0xF2C0_0013, mixer1ToLine12: true)
        let tick = Tick()
        let cache = state.peripheralRoutingCache(direction: "output")
        // On the 30th mixer write the user puts software 1/2 on Line 1/2.
        driver.onWrite = { event in
            guard case .mixer = event, tick.next() == 30 else { return }
            Task { @MainActor in
                _ = try? await state.writeOutputRoutePair(destLeft: 32, srcLeft: 0, device: tb)
                cache.save([0: Set([0])])
                state.outputRoutingSaved()
            }
        }
        await state.syncOutputRoutingToHardware()
        for _ in 0..<20 where state.outputRouteEdits == 0 { await Task.yield() }
        await settle(state, tb)
        #expect(state.outputRouteEdits > 0)
        #expect(driver.mixerFeeds.isEmpty)
        #expect(driver.routes[0] == ThunderboltCardRouting.Route(channel: 0, slot: ThunderboltCardRouting.pciOutBase, enabled: true))
        #expect(violations(driver).isEmpty)
        expectUnitEqualsTable(state, tb, driver)
    }

    @Test("a route edit made while the restore is writing a mixer is what ends on the unit")
    func routeEditDuringRestore() async {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, tb, driver) = makeState(identity: 0xF2C0_0007, mixer1ToLine12: true)
        let tick = Tick()
        let cache = state.peripheralRoutingCache(direction: "output")
        // On the 30th mixer write: the user moves Line 1/2 from Mixer 1 to
        // software 1/2 and puts Mixer 2 on Line 3/4.
        driver.onWrite = { event in
            guard case .mixer = event, tick.next() == 30 else { return }
            Task { @MainActor in
                _ = try? await state.writeOutputRoutePair(destLeft: 32, srcLeft: 0, device: tb)
                _ = try? await state.writeOutputRoutePair(destLeft: 34, srcLeft: SymphonyIORoutingAddress.mixer1Base,
                                                          device: tb)
                cache.save([0: Set([0]), 17: Set([1])])
                state.outputRoutingSaved()
            }
        }
        await state.syncOutputRoutingToHardware()
        for _ in 0..<20 where state.outputRouteEdits == 0 { await Task.yield() }
        await settle(state, tb)
        #expect(state.outputRouteEdits > 0)
        #expect(driver.mixerFeeds == [2: 1, 3: 1])
        #expect(violations(driver).isEmpty)
        expectUnitEqualsTable(state, tb, driver)
    }

    @Test("Reset Routing during the restore wins: no mixer is routed afterwards")
    func resetRoutingDuringRestore() async {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, tb, driver) = makeState(identity: 0xF2C0_0008, mixer1ToLine12: true)
        let tick = Tick()
        let cache = state.peripheralRoutingCache(direction: "output")
        driver.onWrite = { event in
            guard case .mixer = event, tick.next() == 100 else { return }
            Task { @MainActor in
                // What the Output Routing page's reset does: every default
                // route, then the saved rows are cleared.
                for destination in UInt8(32)..<64 {
                    _ = try? await state.writeOutputRoute(destination: destination, source: destination - 32, device: tb)
                }
                cache.save([Int: Set<Int>]())
                state.outputRoutingSaved()
            }
        }
        await state.syncOutputRoutingToHardware()
        for _ in 0..<50 where state.outputRouteEdits < 33 { await Task.yield() }
        await settle(state, tb)
        #expect(state.outputRouteEdits >= 33)
        #expect(driver.mixerFeeds.isEmpty)
        #expect(violations(driver).isEmpty)
        expectUnitEqualsTable(state, tb, driver)
    }

    // MARK: Preset recall

    @Test("a recall that starts during the restore stops it; the restore then runs from what the recall saved")
    func recallDuringRestore() async {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, tb, driver) = makeState(identity: 0xF2C0_0009, mixer1ToLine12: true)
        saveStrip(state, mixer: 0, strip: 4, muted: false)
        let tick = Tick()
        let deferral = state.replayDeferral
        driver.onWrite = { event in
            if case .mixer = event, tick.next() == 20 { deferral.beginRecall() }
        }
        await state.syncOutputRoutingToHardware()
        driver.onWrite = nil
        // It stopped at once: nothing more of the pre-recall state went out.
        #expect(mixerEvents(driver.log) == 20)
        #expect(tb.cardMixers.needsRestore)
        // While the recall runs, the health loop leaves the card alone.
        let during = driver.log.count
        await settle(state, tb, cycles: 3)
        #expect(driver.log.count == during)
        #expect(violations(driver, settled: false).isEmpty)
        // The recall saves a muted strip 5 and moves Mixer 1 to Line 3/4.
        saveStrip(state, mixer: 0, strip: 4, muted: true)
        state.peripheralRoutingCache(direction: "output").save([16: Set([1])])
        state.finishRecall()
        await settle(state, tb)
        #expect(!tb.cardMixers.needsRestore)
        #expect(muteByte(driver, mixer: 0, strip: 4) == 1)
        #expect(driver.mixerFeeds == [2: 0, 3: 0])
        #expect(violations(driver).isEmpty)
        expectUnitEqualsTable(state, tb, driver)
    }

    @Test("a preset recall: mixer-fed outputs are disabled first and routed last, and the unit ends on what the recall saved")
    func presetRecall() async throws {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, tb, driver) = makeState(identity: 0xF2C0_000A, mixer1ToLine12: true)
        await state.syncOutputRoutingToHardware()
        let start = driver.log.count
        // The recall: Mixer 2 onto Line 1/2 with strip 1 muted.
        let snapshot = MixerStateSnapshot(channelCount: layout.mixerChannels.count, mixer: 1,
                                          store: state.channelStateStore, preferences: state.mixerPreferences)
        let slot = ThunderboltCardRouting.mixerOutBase + 2
        let writes: [ThunderboltPreset.Write] = [
            .output(.init(channel: 0, slot: slot, enabled: true)), .output(.init(channel: 1, slot: slot + 1, enabled: true)),
        ] + withMute(CardMixerReplay.writes(mixer: 1, layout: layout, snapshot: snapshot), strip: 0, muted: true)
        state.beginRecall()
        try await Task.detached { try tb.applyPresetWrites(writes, layout: CardLayout(slot1: .analogADDA16, slot2: .analogADDA16)) }.value
        let recall = Array(driver.log[start...])
        #expect(recall.first == .route(channel: 0, mixer: nil, enabled: false))
        #expect(recall.last == .route(channel: 1, mixer: 1, enabled: true))
        saveStrip(state, mixer: 1, strip: 0, muted: true, level: 0)
        state.peripheralRoutingCache(direction: "output").save([17: Set([0])])
        state.finishRecall()
        // The follow-up from the stores silences nothing.
        let after = driver.log.count
        await settle(state, tb)
        #expect(!driver.log[after...].contains { if case .route(_, _, false) = $0 { true } else { false } })
        #expect(driver.mixerFeeds == [0: 1, 1: 1])
        #expect(muteByte(driver, mixer: 1, strip: 0) == 1)
        #expect(violations(driver).isEmpty)
        expectUnitEqualsTable(state, tb, driver)
    }

    @Test("a recall that fails partway: no output stays on a card mixer, and the saved routing and mixers come back")
    func failedRecall() async {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, tb, driver) = makeState(identity: 0xF2C0_000B, mixer1ToLine12: true)
        saveStrip(state, mixer: 0, strip: 6, muted: true)
        await state.syncOutputRoutingToHardware()
        // The bundle would unmute strip 7 of Mixer 1; the card refuses a later write.
        let snapshot = MixerStateSnapshot(channelCount: layout.mixerChannels.count, mixer: 0,
                                          store: state.channelStateStore, preferences: state.mixerPreferences)
        let writes = withMute(CardMixerReplay.writes(mixer: 0, layout: layout, snapshot: snapshot), strip: 6, muted: false)
        let lastStrip = UInt32(1 << 16) | UInt32(layout.mixerChannels.last!.hardwareIndex)
        driver.shouldFail = { $0.command == 0xB3 && $0.value == lastStrip }
        state.beginRecall()
        let failed = await Task.detached { (try? tb.applyPresetWrites(writes, layout: CardLayout(slot1: .analogADDA16, slot2: .analogADDA16))) == nil }.value
        #expect(failed)
        driver.shouldFail = nil
        // The card holds part of the bundle (strip 7 unmuted), so nothing plays Mixer 1.
        #expect(muteByte(driver, mixer: 0, strip: 6) == 0)
        #expect(driver.mixerFeeds.isEmpty)
        await state.recoverFromFailedRecall(tb)
        state.finishRecall()
        #expect(state.restoreStatusNote == PortStatusMessage.restoringMixerAndRouting)
        await settle(state, tb)
        #expect(muteByte(driver, mixer: 0, strip: 6) == 1)
        #expect(driver.mixerFeeds == [0: 0, 1: 0])
        #expect(violations(driver).isEmpty)
        #expect(state.restoreStatusNote == nil)
    }

    // MARK: Owed work, and the cases that cannot proceed

    @Test("owed work is never dropped: after many interrupted attempts the restore still completes")
    func owedSurvivesInterruptedAttempts() async {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, tb, driver) = makeState(identity: 0xF2C0_000C, mixer1ToLine12: true)
        saveStrip(state, mixer: 0, strip: 9, muted: true)
        let strip = UInt32(1 << 16) | UInt32(layout.mixerChannels[9].hardwareIndex)
        driver.shouldFail = { $0.command == 0xB3 && $0.value == strip }
        for attempt in 1...8 {
            state.cardOutputRetryAfter = .distantPast
            await state.serviceCardOutputTable(tb)
            #expect(tb.cardMixers.needsRestore, "attempt \(attempt)")
            #expect(state.cardOutputRetryAfter > Date(), "attempt \(attempt) waits before the next")
            #expect(state.restoreStatusNote == PortStatusMessage.restoringMixerAndRouting)
            // Line 1/2 stays disabled, never on the unwritten mixer.
            #expect(driver.mixerFeeds.isEmpty)
        }
        // Inside the backoff the loop does not hammer the card.
        let quiet = driver.sent.count
        await state.serviceCardOutputTable(tb)
        #expect(driver.sent.count == quiet)
        driver.shouldFail = nil
        await settle(state, tb)
        #expect(!tb.cardMixers.needsRestore)
        #expect(driver.mixerFeeds == [0: 0, 1: 0])
        #expect(muteByte(driver, mixer: 0, strip: 9) == 1)
        #expect(violations(driver).isEmpty)
        #expect(state.restoreStatusNote == nil)
    }

    @Test("a failed edit of a written mixer is owed and written again by the health loop")
    func failedEditIsRetried() async {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, tb, driver) = makeState(identity: 0xF2C0_000D, mixer1ToLine12: true)
        await state.syncOutputRoutingToHardware()
        saveStrip(state, mixer: 0, strip: 0, muted: true)
        let address = PropertyAddress(selector: .mixerChannelMute,
                                      element: 1 << 16 | UInt32(layout.mixerChannels[0].hardwareIndex))
        driver.shouldFail = { $0.command == 0xB3 }
        await #expect(throws: (any Error).self) { try await tb.setProperty(address, value: .bool(true)) }
        driver.shouldFail = nil
        #expect(tb.cardMixers.needsRestore)
        await settle(state, tb)
        #expect(muteByte(driver, mixer: 0, strip: 0) == 1)
        #expect(violations(driver).isEmpty)
    }

    @Test("cards not detected this session: nothing at all is written, it is said, retried, and completes once they are",
          arguments: [true, false])
    func cannotReadTheTable(cardsMissing: Bool) async {
        let restore = restoringDefaults()
        defer { restore() }
        // Either the cards are not detected, or the unit is not identified.
        let (state, tb, driver) = makeState(identity: cardsMissing ? 0xF2C0_000E : nil, cardsRead: !cardsMissing,
                                            mixer1ToLine12: cardsMissing)
        await state.syncOutputRoutingToHardware()
        #expect(driver.sent.isEmpty)
        #expect(state.restoreStatusNote == PortStatusMessage.mixerWaitsForIdentity)
        #expect(state.cardOutputRetryAfter > Date())
        #expect(tb.cardMixers.needsRestore)
        // A mixer edit and a mixer route meanwhile: neither reaches a mixer.
        let unmute = PropertyAddress(selector: .mixerChannelMute, element: 1 << 16 | 0)
        await #expect(throws: CardMixerWriteDeferred.self) { try await tb.setProperty(unmute, value: .bool(false)) }
        #expect(mixerEvents(driver.log) == 0)
        #expect(violations(driver, settled: false).isEmpty)
        // The condition clears.
        if cardsMissing {
            state.primaryBoardSource = .detected
            state.secondaryBoardSource = .detected
        } else {
            state.unitAIdentity = 0xF2C0_000F
            state.unitAIdentityState = .known(0xF2C0_000F)
        }
        await settle(state, tb)
        #expect(!tb.cardMixers.needsRestore)
        #expect(state.restoreStatusNote == nil)
        #expect(violations(driver).isEmpty)
        expectUnitEqualsTable(state, tb, driver)
        // No output was ever disabled on the way for a table with no mixer;
        // with one, the pair came on.
        #expect(driver.mixerFeeds == (cardsMissing ? [0: 0, 1: 0] : [:]))
    }

    @Test("cards or identity still unread at the third check: every card channel is written direct, mixer edits then reach the card, and the restore goes on retrying",
          arguments: [true, false])
    func cannotReadTheTableForLong(cardsMissing: Bool) async throws {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, tb, driver) = makeState(identity: cardsMissing ? 0xF2C0_0020 : nil, cardsRead: !cardsMissing,
                                            mixer1ToLine12: cardsMissing)
        // The session before the update left Mixer 2 on output 5 as well as
        // the driver's own Mixer 1 on the main pair.
        driver.seedRoute(channel: 4, mixer: 1)
        // Two checks: nothing is written (a read normally arrives in time).
        for _ in 0..<2 {
            state.cardOutputRetryAfter = .distantPast
            await state.serviceCardOutputTable(tb)
            #expect(driver.sent.isEmpty)
            #expect(state.cardOutputRetryAfter > Date())
        }
        #expect(driver.mixerFeeds == [0: 0, 1: 0, 4: 1])
        // Inside the pause nothing happens either.
        await state.serviceCardOutputTable(tb)
        #expect(driver.sent.isEmpty)
        // The third: all 32 channels direct, no mixer on any output.
        state.cardOutputRetryAfter = .distantPast
        await state.serviceCardOutputTable(tb)
        #expect(driver.mixerFeeds.isEmpty)
        #expect(driver.routes.count == 32)
        for channel in UInt8(0)..<32 {
            #expect(driver.routes[channel] == ThunderboltCardRouting.Route(
                channel: channel, slot: ThunderboltCardRouting.pciOutBase + channel, enabled: true))
        }
        #expect(mixerEvents(driver.log) == 0)
        // Still said, still owed, still retried.
        #expect(state.restoreStatusNote == PortStatusMessage.mixerWaitsForIdentity)
        #expect(tb.cardMixers.needsRestore)
        #expect(state.cardOutputRetryAfter > Date())
        // A mixer edit is no longer held back for ever: it cannot be heard.
        let unmute = PropertyAddress(selector: .mixerChannelMute, element: 1 << 16 | 0)
        try await tb.setProperty(unmute, value: .bool(false))
        #expect(mixerEvents(driver.log) == 1)
        // A mixer route is still not sent.
        #expect(try await state.writeOutputRoutePair(destLeft: 34, srcLeft: mixer1, device: tb) == .deferred)
        #expect(driver.mixerFeeds.isEmpty)
        #expect(violations(driver, settled: false).isEmpty)
        // Written once per driver state, not on every retry...
        let count = driver.sent.count
        state.cardOutputRetryAfter = .distantPast
        await state.serviceCardOutputTable(tb)
        #expect(driver.sent.count == count)
        // ...and again after the driver re-programmed the card.
        driver.simulateDriverRestart()
        #expect(driver.mixerFeeds == [0: 0, 1: 0])
        state.cardOutputRetryAfter = .distantPast
        await state.serviceCardOutputTable(tb)
        #expect(driver.mixerFeeds.isEmpty)
        // The condition clears: the saved table and the mixers, in order.
        if cardsMissing {
            state.primaryBoardSource = .detected
            state.secondaryBoardSource = .detected
        } else {
            state.unitAIdentity = 0xF2C0_0021
            state.unitAIdentityState = .known(0xF2C0_0021)
        }
        await settle(state, tb)
        #expect(!tb.cardMixers.needsRestore)
        #expect(state.restoreStatusNote == nil)
        #expect(state.cardBlockedChecks == 0)
        #expect(violations(driver).isEmpty)
        expectUnitEqualsTable(state, tb, driver)
        #expect(driver.mixerFeeds == (cardsMissing ? [0: 0, 1: 0] : [:]))
    }

    @Test("every card channel is in the table: one past the fitted cards' outputs is written disabled, also when an earlier session left it on a mixer")
    func everyChannelIsDeclared() async {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, tb, driver) = makeState(identity: 0xF2C0_0022, mixer1ToLine12: true)
        // Slot 2 is empty now: card channels 16-31 have no output.
        state.secondaryBoardType = .none
        driver.boards = (IOCardType.analogADDA16.rawValue, IOCardType.none.rawValue)
        // Saved routing is kept per card layout.
        state.peripheralRoutingCache(direction: "output").save([16: Set([0])])
        // With other cards fitted, an earlier session put Mixer 2 on one of them.
        driver.seedRoute(channel: 20, mixer: 1)
        let table = state.thunderboltOutputTable(for: tb, quiet: true)
        #expect(Set(table.keys.compactMap(ThunderboltCardRouting.channel(forDestination:))) == Set(0..<32))
        #expect((48..<64).allSatisfy { table[UInt8($0)] == SymphonyIORoutingAddress.none })
        await state.syncOutputRoutingToHardware()
        #expect(!tb.cardMixers.needsRestore)
        // "Mixer 2 feeds nothing" is true of the card when it is written.
        let needed = CardWriteLogChecker.required(layout: CardLayout(slot1: .analogADDA16, slot2: .none))
        #expect(CardWriteLogChecker.violations(driver.log, required: needed) == [])
        #expect(driver.mixerFeeds == [0: 0, 1: 0])
        #expect(driver.routes.count == 32)
        #expect((16..<32).allSatisfy { driver.routes[UInt8($0)]?.enabled == false })
        #expect(tb.cardMixers.writtenMixers == [0, 1])
    }

    // MARK: 64 channels

    private func makeTwoUnitState(identity: UInt64) -> (AppState, ThunderboltDeviceConnection,
                                                        ThunderboltUnitBConnection, FakeThunderboltDriver) {
        let (state, tb, driver) = makeState(identity: identity, mixer1ToLine12: true)
        driver.portSelectionOverride = PortSelection.ports1And2.rawValue
        driver.unitB = UnitBState(present: true, boardType: [IOCardType.analogADDA16.rawValue, IOCardType.none.rawValue],
                                  boardValid: [1, 1], prefix: 0x42, clockSource: 1,
                                  setupFlags: 1, txErrors: 0, generation: 1)
        driver.port2 = SecondPortState(portCount: 2, flags: 0x0F)
        let b = tb.makeUnitBConnection()
        state.unitB = SecondUnitInfo(slot1: .analogADDA16, slot2: .none)
        state.unitBDevice = b
        state.portSelection.deviceReported(dataSourceID: PortSelection.ports1And2.rawValue, state: nil)
        state.unitBIdentity = identity + 0x100
        state.unitBIdentityState = .known(identity + 0x100)
        state.servingDextBuild = .build(140)
        // The card's table is saved per pair of units; unit A's rows keep
        // their numbering (16 is Mixer 1). Column 0 is Line 1/2.
        state.peripheralRoutingCache(direction: "output").save([16: Set([0])])
        return (state, tb, b, driver)
    }

    @Test("64 channels: an owner recorded by an earlier single-unit restore does not make every cycle ask for the replay")
    func twoUnitIgnoresSingleUnitOwner() async {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, tb, _, driver) = makeTwoUnitState(identity: 0xF2C0_0031)
        #expect(state.usesTwoUnitReplay)
        state.twoUnitReplayNeeded = true
        await state.replayUnitBSettings()
        #expect(!state.twoUnitReplayNeeded)
        #expect(!tb.cardMixers.needsRestore)
        // Written by a single-unit restore before unit B came up, for another layout.
        state.cardRestoreOwner = (ObjectIdentifier(tb), CardRestoreOwner(storageKey: "earlier", layout: CardLayout()))
        let mark = driver.sent.count
        for _ in 0..<3 {
            await state.serviceCardOutputTable(tb)
            #expect(!state.twoUnitReplayNeeded)
            #expect(!state.cardOutputTableReplayNeeded)
        }
        #expect(driver.sent.count == mark)
    }

    @Test("64 channels: a replay that keeps failing waits longer each time, sends the reset's default tables once, and consumes the flags when it completes")
    func twoUnitReplayBacksOff() async throws {
        let restore = restoringDefaults()
        defer { restore() }
        for item in RoutingMixerReset.Pending.allCases {
            UserDefaults.standard.set(true, forKey: "routingMixerReset.pending.\(item.rawValue)")
        }
        let (state, tb, _, driver) = makeTwoUnitState(identity: 0xF2C0_0030)
        #expect(state.usesTwoUnitReplay)
        #expect(state.cardTableUnreadableReason() == nil)
        // Mixer 2 refuses one strip's mute: the tables land, the mixers do not.
        let strip = UInt32(2 << 16) | UInt32(layout.mixerChannels[9].hardwareIndex)
        driver.shouldFail = { $0.command == 0xB3 && $0.value == strip }
        /// The units' input table writes (0x31) and the card-input reset.
        func tables(_ commands: ArraySlice<FakeThunderboltDriver.Command>) -> Int {
            commands.filter { $0.command == 0x31 || ($0.command == ConverterRouting.resetRoutingCommand.command
                && $0.payload == ConverterRouting.resetRoutingCommand.payload) }.count
        }
        state.twoUnitReplayNeeded = true
        await state.replayUnitBSettings()
        #expect(state.twoUnitReplayNeeded)
        let first = driver.sent.count
        #expect(tables(driver.sent[...]) > 32, "both units' default input tables and the card-input reset went out")
        #expect(RoutingMixerReset.isPending(.thunderboltInputRouting))
        // It waits: a health cycle inside the pause sends nothing.
        var pause = state.twoUnitRetryAfter.timeIntervalSinceNow
        #expect(pause > 1 && pause <= 2)
        await state.replayUnitBSettings()
        #expect(driver.sent.count == first)
        #expect(state.restoreStatusNote == PortStatusMessage.restoringMixerAndRouting)
        // Each further failure waits longer, up to 30 s, and none sends the
        // default tables again.
        for attempt in 2...6 {
            state.twoUnitRetryAfter = .distantPast
            let before = driver.sent.count
            await state.replayUnitBSettings()
            #expect(driver.sent.count > before, "attempt \(attempt) ran")
            #expect(tables(driver.sent[before...]) == 0, "attempt \(attempt) sent no default table")
            let next = state.twoUnitRetryAfter.timeIntervalSinceNow
            #expect(next > pause || next > 29, "attempt \(attempt) waits longer")
            pause = next
        }
        #expect(pause > 29 && pause <= 30)
        #expect(state.twoUnitReplayNeeded)
        #expect(driver.mixerFeeds[0] == 0 || driver.mixerFeeds[0] == nil)
        // The card takes the write: complete, flags consumed, no pause left.
        driver.shouldFail = nil
        state.twoUnitRetryAfter = .distantPast
        await state.replayUnitBSettings()
        #expect(!state.twoUnitReplayNeeded)
        #expect(!RoutingMixerReset.isPending(.thunderboltInputRouting))
        #expect(state.twoUnitRetryAttempts == 0)
        #expect(tb.cardMixers.writtenMixers == [0, 1])
        #expect(driver.mixerFeeds == [0: 0, 1: 0])
        #expect(driver.routes.count == 64)
        let needed = CardWriteLogChecker.required(layout: layout, second: CardLayout(slot1: .analogADDA16, slot2: .none))
        #expect(CardWriteLogChecker.violations(driver.log, required: needed) == [])
        #expect(state.restoreStatusNote == nil)
    }

    @Test("64 channels: unit B's cards still unread at the third check: all 64 card channels are written direct")
    func twoUnitCannotReadTheTableForLong() async {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, tb, _, driver) = makeTwoUnitState(identity: 0xF2C0_0031)
        state.unitB = SecondUnitInfo(slot1: .analogADDA16, slot2: .none, slotValid: [true, false])
        #expect(state.usesTwoUnitReplay)
        #expect(state.cardTableUnreadableReason() != nil)
        driver.seedRoute(channel: 40, mixer: 1)
        _ = tb.probeEndpoint()
        for _ in 0..<2 {
            state.cardOutputRetryAfter = .distantPast
            await state.serviceCardOutputTable(tb)
            await state.replayUnitBSettings()
            #expect(driver.sent.isEmpty)
        }
        state.cardOutputRetryAfter = .distantPast
        await state.serviceCardOutputTable(tb)
        #expect(driver.mixerFeeds.isEmpty)
        #expect(driver.routes.count == 64)
        #expect(driver.routes[40] == ThunderboltCardRouting.Route(channel: 40, slot: ThunderboltCardRouting.pciOutBase + 40, enabled: true))
        #expect(state.restoreStatusNote == PortStatusMessage.mixerWaitsForIdentity)
        #expect(state.twoUnitReplayNeeded)
    }

    @Test("saved mixer state not available: direct routes are written, mixer-fed outputs disabled, no mixer written; it completes once it is")
    func mixerStateUnavailable() async {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, tb, driver) = makeState(identity: 0xF2C0_0010, mixer1ToLine12: true)
        let key = state.mixerPreferencesCacheKey
        state.cachedMixerPreferences = (key, MixerPreferences(legacyDefaults: .standard, readOnly: true))
        #expect(!state.mixerPreferences.isWritable)
        await state.syncOutputRoutingToHardware()
        #expect(mixerEvents(driver.log) == 0)
        #expect(driver.mixerFeeds.isEmpty)
        #expect(driver.routes[0]?.enabled == false && driver.routes[1]?.enabled == false)
        #expect((2..<32).allSatisfy { driver.routes[UInt8($0)]?.enabled == true })
        #expect(state.restoreStatusNote == PortStatusMessage.mixerWaitsForIdentity)
        #expect(violations(driver).isEmpty)
        // Not disabled for good: the state becomes available.
        state.cachedMixerPreferences = nil
        #expect(state.mixerPreferences.isWritable)
        await settle(state, tb)
        #expect(driver.mixerFeeds == [0: 0, 1: 0])
        #expect(state.restoreStatusNote == nil)
        #expect(violations(driver).isEmpty)
    }

    @Test("another unit's saved state: the marks made from the first are dropped and both mixers written again")
    func ownerChange() async {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, tb, driver) = makeState(identity: 0xF2C0_0011, mixer1ToLine12: true)
        await state.syncOutputRoutingToHardware()
        state.unitAIdentity = 0xF2C0_0012
        state.unitAIdentityState = .known(0xF2C0_0012)
        state.peripheralRoutingCache(direction: "output").save([16: Set([0])])
        let before = driver.log.count
        state.cardOutputTableReplayNeeded = true
        await settle(state, tb)
        // The pair was taken off the mixer until it was written from this unit's state.
        #expect(driver.log[before...].contains(.route(channel: 0, mixer: nil, enabled: false)))
        #expect(driver.mixerFeeds == [0: 0, 1: 0])
        #expect(violations(driver).isEmpty)
    }

    // MARK: Table and two-unit plan

    @Test("the table is the whole default with the saved rows over it, mixer routes included")
    func table() {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, tb, _) = makeState(identity: 0xF2B0_0004)
        var table = state.thunderboltOutputTable(for: tb)
        // Default: 32 outputs, each from its own playback channel, no mixer.
        #expect(table.count == 32)
        #expect(table.values.allSatisfy { CardOutputTableOrder.mixer(ofSource: $0) == nil })
        state.peripheralRoutingCache(direction: "output").save([16: Set([0])])
        table = state.thunderboltOutputTable(for: tb)
        #expect(table[32] == SymphonyIORoutingAddress.mixer0Base)
        #expect(table[33] == SymphonyIORoutingAddress.mixer0Base + 1)
    }

    @Test("two-unit replay: the reset's defaults and card-input reset go out, both mixers in full, and the flags are consumed only when it has run")
    func twoUnitResetConsumer() throws {
        let restore = restoringDefaults()
        defer { restore() }
        let defaults = UserDefaults.standard
        for item in RoutingMixerReset.Pending.allCases {
            defaults.set(true, forKey: "routingMixerReset.pending.\(item.rawValue)")
        }
        let (state, tb, _) = makeState(identity: 0xF2B0_0005, mixer1ToLine12: true)
        // A driver that takes the card's own input routes (build 132 and later).
        state.servingDextBuild = .build(140)
        #expect(state.symphonyCardInputs.resetCommand != nil)
        let layoutB = CardLayout(slot1: .analogADDA16, slot2: .none)
        let b = ThunderboltUnitBConnection(identifier: SimulatedDevice.symphonyIO32ch().identifier,
                                           transport: SilentVendorTransport(), state: { nil })

        let plan = state.makeTwoUnitReplay(tb: tb, b: b, layoutB: layoutB)
        #expect(plan.consumesRoutingReset)
        // Building a plan consumes nothing.
        #expect(RoutingMixerReset.isPending(.thunderboltInputRouting))
        let card: [ThunderboltPreset.Write] = plan.card.compactMap {
            if case .card(let write) = $0 { return write }
            return nil
        }
        #expect(card.contains(.cardInput(ConverterRouting.resetRoutingCommand)))
        // Each mixer is in the plan in full, unit B's strips included, so the
        // connection can mark it written.
        let layouts = try #require(plan.mixerLayouts)
        for mixer in 0..<2 {
            let addresses: Set<PropertyAddress> = Set(card.compactMap {
                if case .property(let address, _) = $0, ThunderboltDeviceConnection.cardMixer(of: address) == mixer {
                    return address
                }
                return nil
            })
            #expect(CardMixerReplay.requiredAddresses(mixer: mixer, layout: layouts.a, second: layouts.b,
                                                      routes: state.thunderboltCaptureRoutes(unit: .a),
                                                      secondRoutes: state.thunderboltCaptureRoutes(unit: .b))
                .isSubset(of: addresses))
        }
        // As the connection sends it: no mixer write before every route has
        // gone out with the mixer-fed ones disabled; Mixer 1 last.
        let ordered = CardOutputTableOrder.ordered(card)
        let firstMixer = try #require(ordered.firstIndex {
            if case .property(let address, _) = $0 { return ThunderboltDeviceConnection.mixerEditSelectors.contains(address.selector) }
            return false
        })
        let fed = ordered.indices.filter {
            if case .output(let route) = ordered[$0] { return CardOutputTableOrder.isMixerFed(route) }
            return false
        }
        #expect(fed.count == 2 && fed.allSatisfy { $0 > firstMixer } && fed.last == ordered.count - 1)
        #expect(ordered[..<firstMixer].filter {
            if case .output(let route) = $0 { return !route.enabled && route.channel < 2 }
            return false
        }.count == 2)

        // A replay the connection did not complete leaves the flags.
        state.finishTwoUnitReplay(plan, tb: tb, epoch: tb.cardMixers.epoch, owed: tb.cardMixers.owed,
                                  routeEdits: state.outputRouteEdits)
        #expect(RoutingMixerReset.isPending(.thunderboltInputRouting))
        #expect(state.twoUnitReplayNeeded)
    }

    @Test("two units: a saved +6 dB fader, Master and Software Return are sent as 0 dB once the driver plays above 0")
    func twoUnitHeadroomClamp() throws {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, tb, _) = makeState(identity: 0xF2B0_0006, mixer1ToLine12: true)
        state.servingDextBuild = .build(144)
        state.unitB = SecondUnitInfo(slot1: .analogADDA16, slot2: .none)
        state.unitBIdentity = 0xF2B0_0007
        let layoutB = try #require(state.unitBLayout)
        let b = ThunderboltUnitBConnection(identifier: SimulatedDevice.symphonyIO32ch().identifier,
                                           transport: SilentVendorTransport(), state: { nil })
        func loud(_ count: Int) -> [MixerChannelState] {
            Array(repeating: MixerChannelState(level: 6, pan: 0, isMuted: false, isSoloed: false), count: count)
        }
        let storeA = state.channelStateStore, storeB = state.unitBChannelStateStore
        for mixer in 0..<2 {
            storeA.save(loud(layout.mixerChannels.count), for: ChannelStateStore.mixerKey(mixer))
            storeB.save(loud(layoutB.mixerChannels.count), for: ChannelStateStore.mixerKey(mixer))
        }
        for prefs in [state.mixerPreferences, storeB.mixerPreferences] {
            for mixer in 0..<2 {
                prefs.set(6.0, forKey: "mixerMasterLevel_\(mixer)")
                prefs.set(6.0, forKey: "mixerSWReturnLeftLevel_\(mixer)")
                prefs.set(6.0, forKey: "mixerSWReturnRightLevel_\(mixer)")
            }
        }
        func levels(_ plan: TwoUnitReplay) -> [Double] {
            plan.card.compactMap {
                if case .card(.property(let address, .float64(let value))) = $0,
                   address.selector == .mixerChannelLevel { return value }
                return nil
            }
        }
        // Without the migration the plan carries +6.
        #expect(levels(state.makeTwoUnitReplay(tb: tb, b: b, layoutB: layoutB)).contains(6))
        state.migrateMixerHeadroomIfNeeded()
        let plan = state.makeTwoUnitReplay(tb: tb, b: b, layoutB: layoutB)
        #expect(!levels(plan).isEmpty && levels(plan).allSatisfy { $0 <= 0 })
        // Once per unit: a level raised afterwards stays.
        state.mixerPreferences.set(3.0, forKey: "mixerMasterLevel_0")
        state.migrateMixerHeadroomIfNeeded()
        #expect(state.mixerPreferences.object(forKey: "mixerMasterLevel_0") as? Double == 3)
        // With 143 serving nothing is touched.
        let (old, _, _) = makeState(identity: 0xF2B0_0008)
        old.servingDextBuild = .build(143)
        old.mixerPreferences.set(6.0, forKey: "mixerMasterLevel_0")
        old.migrateMixerHeadroomIfNeeded()
        #expect(old.mixerPreferences.object(forKey: "mixerMasterLevel_0") as? Double == 6)
    }
}
}
