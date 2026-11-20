import Foundation
import Testing
import MaestroCore
@testable import MaestroDevice

/// D5 review findings 1-8: one deterministic seam each.
@Suite("D5 card mixer restore: driver-instance decision, saved-only plan, runner")
struct CardMixerRestoreTests {
    // MARK: Fixtures

    static func words(state: UInt32 = 1, recovery: UInt32 = 0, reinit: UInt32 = 0,
                      count: Int = 52, nonce: UInt64 = 0xABCD_0001, flags: UInt32 = 0) -> [UInt32] {
        var w = [UInt32](repeating: 0, count: count)
        w[1] = state; w[2] = 1; w[6] = recovery; w[8] = 1
        if count >= 16 { w[14] = reinit }
        if count == 52 {
            w[48] = DriverMixerInstance.magic
            w[49] = flags
            w[50] = UInt32(truncatingIfNeeded: nonce)
            w[51] = UInt32(truncatingIfNeeded: nonce >> 32)
        }
        return w
    }

    static func link(state: UInt32 = 1, recovery: UInt32 = 0, reinit: UInt32 = 0,
                     nonce: UInt64 = 0xABCD_0001, flags: UInt32 = 0, tail: Bool = true) -> LinkState {
        LinkState.decode(words(state: state, recovery: recovery, reinit: reinit,
                               count: tail ? 52 : 48, nonce: nonce, flags: flags))!
    }

    static func store(_ name: String, layout: CardLayout) -> (ChannelStateStore, UserDefaults, String) {
        let suite = "d5-\(name)-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        return (ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: false, identity: 42), defaults, suite)
    }

    static func value(_ writes: [ThunderboltPreset.Write], _ selector: AudioPropertySelector,
                      _ element: UInt32) -> PropertyValue? {
        for case .property(let address, let value) in writes where address.selector == selector && address.element == element {
            return value
        }
        return nil
    }

    // MARK: Finding 1: the driver says whether it is fresh

    @Test("52-word read carries the instance; 48 and 16 keep their ABI and report none")
    func decodeTail() throws {
        let full = try #require(LinkState.decode(Self.words(flags: 2)))
        #expect(full.mixerInstance == DriverMixerInstance(nonce: 0xABCD_0001, holdsAppState: [false, true]))
        let phantom = try #require(LinkState.decode(Array(Self.words().prefix(48))))
        #expect(phantom.mixerInstance == nil && phantom.phantomOffReceipts.count == 16)
        #expect(try #require(LinkState.decode(Array(Self.words().prefix(16)))).mixerInstance == nil)
        var badMagic = Self.words(); badMagic[48] = 0
        #expect(try #require(LinkState.decode(badMagic)).mixerInstance == nil)
        #expect(LinkState.decode(Array(Self.words().prefix(51))) == nil)
    }

    @Test("Negotiation: an old driver refusing 52 falls back to 48, then 16; a known size is reused")
    func negotiationFallback() throws {
        var asked: [Int] = []
        let old = LinkState.negotiate(known: nil) { count in
            asked.append(count)
            return count == 48 ? Array(Self.words().prefix(48)) : nil
        }
        #expect(old?.1 == 48 && old?.0.mixerInstance == nil)
        #expect(asked == [52, 52, 52, 48])
        asked = []
        let legacy = LinkState.negotiate(known: nil) { count in
            asked.append(count)
            return count == 16 ? Array(Self.words().prefix(16)) : nil
        }
        #expect(legacy?.1 == 16 && asked == [52, 52, 52, 48, 48, 48, 16])
        asked = []
        // A transient first failure does not pin a new driver to 48.
        var failures = 1
        let transient = LinkState.negotiate(known: nil) { count in
            asked.append(count)
            if failures > 0 { failures -= 1; return nil }
            return Self.words()
        }
        #expect(transient?.1 == 52 && asked == [52, 52])
        asked = []
        _ = LinkState.negotiate(known: 48) { asked.append($0); return Array(Self.words().prefix(48)) }
        #expect(asked == [48])
    }

    @Test("Old driver, held state, fresh instance, in-place recovery and a new instance")
    func ledgerDecisions() {
        var ledger = CardMixerRestoreLedger()
        #expect(ledger.decide(Self.link(tail: false)) == .unsupported)
        #expect(ledger.decide(nil) == .unsupported)
        // The driver held both mixers at first sight: nothing to restore.
        #expect(ledger.decide(Self.link(flags: 3)) == .nothingToDo)
        // A new instance (fresh dext): both mixers, latched.
        #expect(ledger.decide(Self.link(recovery: 4, nonce: 2)) == .restore(mixers: [0, 1], recoveryCount: 4))
        // An edit later sets the driver's flag; the latch keeps D5's claim.
        #expect(ledger.decide(Self.link(recovery: 4, nonce: 2, flags: 1)) == .restore(mixers: [0, 1], recoveryCount: 4))
        // An in-place recovery on the same instance: never again on it.
        #expect(ledger.decide(Self.link(recovery: 5, nonce: 2)) == .gaveUp)
        #expect(ledger.decide(Self.link(recovery: 4, nonce: 2)) == .gaveUp)
        // A card re-init (wake with an FPGA reset) counts the same.
        #expect(ledger.decide(Self.link(nonce: 3, flags: 2)) == .restore(mixers: [0], recoveryCount: 0))
        #expect(ledger.decide(Self.link(reinit: 1, nonce: 3, flags: 2)) == .gaveUp)
        // Completion is one-shot per instance.
        #expect(ledger.decide(Self.link(nonce: 4)) == .restore(mixers: [0, 1], recoveryCount: 0))
        ledger.complete()
        #expect(ledger.decide(Self.link(nonce: 4)) == .nothingToDo)
    }

    @Test("First sight with the link down: baseline taken at the first link-up")
    func ledgerBaselineAtFirstLinkUp() {
        var ledger = CardMixerRestoreLedger()
        #expect(ledger.decide(Self.link(state: 2, recovery: 0, nonce: 9)) == .notReady)
        #expect(ledger.baselineRecovery == nil)
        #expect(ledger.decide(Self.link(recovery: 1, nonce: 9)) == .restore(mixers: [0, 1], recoveryCount: 1))
        #expect(ledger.decide(Self.link(state: 3, recovery: 1, nonce: 9)) == .notReady)
        #expect(ledger.decide(Self.link(recovery: 2, nonce: 9)) == .gaveUp)
    }

    // MARK: Finding 4: one owner per mixer

    @Test("Page defers to D5 only for a mixer D5 owns on the serving instance")
    func pageOwnership() {
        var ledger = CardMixerRestoreLedger()
        let fresh = DriverMixerInstance(nonce: 7, holdsAppState: [false, true])
        // Old driver: the page syncs as before.
        #expect(!ledger.pageDefersSync(mixer: 0, instance: nil, eligible: true))
        // Undecided instance: judged from the driver's flags.
        #expect(ledger.pageDefersSync(mixer: 0, instance: fresh, eligible: true))
        #expect(!ledger.pageDefersSync(mixer: 1, instance: fresh, eligible: true))
        // Converters, another unit, 64 channels...: D5 never runs, the page syncs.
        #expect(!ledger.pageDefersSync(mixer: 0, instance: fresh, eligible: false))
        ledger.observe(Self.link(nonce: 7, flags: 2))
        #expect(!ledger.pageDefersSync(mixer: 0, instance: fresh, eligible: false))
        // D5 owns mixer 0 even after it, or an edit, set the driver's flag.
        let set = DriverMixerInstance(nonce: 7, holdsAppState: [true, true])
        #expect(ledger.pageDefersSync(mixer: 0, instance: set, eligible: true))
        #expect(!ledger.pageDefersSync(mixer: 1, instance: set, eligible: true))
        ledger.complete()
        #expect(ledger.pageDefersSync(mixer: 0, instance: set, eligible: true))
        ledger.giveUp()
        #expect(ledger.pageDefersSync(mixer: 0, instance: set, eligible: true))
    }

    @Test("Runs per instance are bounded; pending only while latched, owned and unfinished")
    func attempts() {
        var ledger = CardMixerRestoreLedger()
        #expect(!ledger.isPending)
        ledger.observe(Self.link(nonce: 11))
        #expect(ledger.isPending)
        for _ in 0..<CardMixerReplay.maxAttempts {
            let begun = ledger.beginAttempt()
            #expect(begun)
        }
        #expect(!ledger.isPending)
        let extra = ledger.beginAttempt()
        #expect(!extra)
        #expect(ledger.decide(Self.link(nonce: 11)) == .gaveUp)
        var held = CardMixerRestoreLedger()
        held.observe(Self.link(nonce: 12, flags: 3))
        #expect(!held.isPending)
    }

    // MARK: Finding 2: the 5 s wait exits on the first bad sample

    @Test("Stability: 21 good samples (20 sleeps); the first bad sample ends the wait")
    func stabilityGate() async {
        var sleeps = 0
        let good = await CardMixerReplay.waitForStableLink(sample: { Self.link(recovery: 3) },
                                                           sleep: { _ in sleeps += 1 })
        #expect(good.recovery == 3 && good.samples == 21 && sleeps == 20)
        for badAt in [1, 2, 10, 21] {
            var n = 0
            let result = await CardMixerReplay.waitForStableLink(sample: {
                n += 1
                return n == badAt ? Self.link(state: 3, recovery: 3) : Self.link(recovery: 3)
            }, sleep: { _ in })
            #expect(result.recovery == nil && result.samples == badAt)
        }
        var m = 0
        let moved = await CardMixerReplay.waitForStableLink(sample: { m += 1; return Self.link(recovery: m < 5 ? 3 : 4) },
                                                            sleep: { _ in })
        #expect(moved.recovery == nil && moved.samples == 5)
        let nilRead = await CardMixerReplay.waitForStableLink(sample: { nil }, sleep: { _ in })
        #expect(nilRead.samples == 1)
        let cancelled = await CardMixerReplay.waitForStableLink(sample: { Self.link() },
                                                                sleep: { _ in throw CancellationError() })
        #expect(cancelled.recovery == nil && cancelled.samples == 1)
    }

    // MARK: Finding 3 and 8: saved state only, held sources held

    @Test("A mixer with only the shared return strip saved writes nothing")
    func unsavedMixer() throws {
        let layout = CardLayout(slot1: .analogADDA16, slot2: .optical)
        let (store, defaults, suite) = Self.store("unsaved", layout: layout)
        defer { defaults.removePersistentDomain(forName: suite) }
        store.mixerPreferences.set(try JSONEncoder().encode(MixerChannelState(level: -3, pan: 0, isMuted: false, isSoloed: false)),
                                   forKey: "mixerState_swReturn")
        store.mixerPreferences.set(-6.0, forKey: "mixerMasterLevel_0")
        #expect(CardMixerReplay.savedWrites(mixer: 1, layout: layout, store: store).isEmpty)
        #expect(CardMixerReplay.plan(mixers: [0, 1], layout: layout, store: store).count == 1)
        // Mixer 0 has only its Master saved: one write, no strip is unmuted.
        let zero = CardMixerReplay.savedWrites(mixer: 0, layout: layout, store: store)
        #expect(zero.count == 1 && Self.value(zero, .mixerChannelLevel, 0x10000 | 2000)?.asFloat64 == -6)
    }

    @Test("Only saved strips; return and Master only when their keys exist; DAW mutes")
    func savedOnly() throws {
        let layout = CardLayout(slot1: .analogADDA16, slot2: .optical)
        let (store, defaults, suite) = Self.store("partial", layout: layout)
        defer { defaults.removePersistentDomain(forName: suite) }
        let strip = MixerChannelState(level: -9, pan: 0.5, isMuted: false, isSoloed: true)
        store.save(Array(repeating: strip, count: 5), for: ChannelStateStore.mixerKey(1))
        store.mixerPreferences.set(-12.0, forKey: "mixerSWReturnLeftLevel_1")
        store.mixerPreferences.set(1, forKey: "routingMode")   // Direct Monitor
        let writes = CardMixerReplay.savedWrites(mixer: 1, layout: layout, store: store)
        #expect(writes.count == 5 * 4 + 1)
        let base: UInt32 = 0x20000
        #expect(Self.value(writes, .mixerChannelMute, base | 4)?.asBool == false)
        #expect(Self.value(writes, .mixerChannelLevel, base | 5) == nil)
        #expect(Self.value(writes, .mixerChannelLevel, base | 1000)?.asFloat64 == -12)
        #expect(Self.value(writes, .mixerChannelPan, base | 1000) == nil)   // no shared strip saved
        #expect(Self.value(writes, .mixerChannelLevel, base | 0x1002) == nil)
        #expect(Self.value(writes, .mixerChannelLevel, base | 2000) == nil)
        #expect(Self.value(writes, .mixerSoftwareReturnID, base) == nil)
        store.mixerPreferences.set(0, forKey: "routingMode")   // DAW: strips stay muted
        let daw = CardMixerReplay.savedWrites(mixer: 1, layout: layout, store: store)
        #expect(Self.value(daw, .mixerChannelMute, base | 0)?.asBool == true)
        store.mixerPreferences.set(-15.0, forKey: "mixerSWReturnRightLevel_1")
        store.mixerPreferences.set(-4.0, forKey: "mixerMasterLevel_1")
        let more = CardMixerReplay.savedWrites(mixer: 1, layout: layout, store: store)
        #expect(Self.value(more, .mixerChannelLevel, base | 0x1002)?.asFloat64 == -15)
        #expect(Self.value(more, .mixerChannelLevel, base | 2000)?.asFloat64 == -4)
    }

    @Test("Software Return source: 0-7 written, 8 or more held as the page holds it")
    func heldSource() {
        let layout = CardLayout(slot1: .optical, slot2: .none)
        let (store, defaults, suite) = Self.store("source", layout: layout)
        defer { defaults.removePersistentDomain(forName: suite) }
        store.mixerPreferences.set(3, forKey: "mixerSoftwareReturnSource_0")
        #expect(Self.value(CardMixerReplay.savedWrites(mixer: 0, layout: layout, store: store),
                           .mixerSoftwareReturnID, 0x10000)?.asUInt32 == 3)
        store.mixerPreferences.set(12, forKey: "mixerSoftwareReturnSource_0")
        #expect(CardMixerReplay.savedWrites(mixer: 0, layout: layout, store: store).isEmpty)
    }

    @Test("16x16 + 8x8 fully saved: 135 commands per mixer, 17,692 card register writes")
    func fullTrafficCount() throws {
        let layout = CardLayout(slot1: .analogADDA16, slot2: .optical)
        let (store, defaults, suite) = Self.store("count", layout: layout)
        defer { defaults.removePersistentDomain(forName: suite) }
        let strip = MixerChannelState(level: -6, pan: 0, isMuted: false, isSoloed: false)
        store.mixerPreferences.set(try JSONEncoder().encode(strip), forKey: "mixerState_swReturn")
        for mixer in 0..<2 {
            store.save(Array(repeating: strip, count: layout.mixerChannelCount), for: ChannelStateStore.mixerKey(mixer))
            for key in ["mixerSWReturnLeftLevel", "mixerSWReturnRightLevel", "mixerMasterLevel"] {
                store.mixerPreferences.set(-6.0, forKey: "\(key)_\(mixer)")
            }
            store.mixerPreferences.set(0, forKey: "mixerSoftwareReturnSource_\(mixer)")
        }
        let plan = CardMixerReplay.plan(mixers: [0, 1], layout: layout, store: store)
        #expect(plan.map(\.count) == [135, 135])
        #expect(CardMixerReplay.registerWrites(plan) == 2 * (2 + 134 * 66))
    }

    // MARK: Finding 5: routing is not a mixer edit

    @Test("Routing writes do not invalidate a restore; mixer controls do")
    func routingNotInvalidating() {
        #expect(!ThunderboltDeviceConnection.mixerEditSelectors.contains(.routing))
        for selector: AudioPropertySelector in [.mixerChannelLevel, .mixerChannelPan, .mixerChannelMute,
                                                .mixerChannelSolo, .mixerSoftwareReturnID] {
            #expect(ThunderboltDeviceConnection.mixerEditSelectors.contains(selector))
        }
    }
}

// MARK: - Runner (findings 2, 5, 8 and cancellation)

@MainActor
final class RunnerHarness {
    var ledger = CardMixerRestoreLedger()
    var link: LinkState? = CardMixerRestoreTests.link(recovery: 2)
    var reads = 0
    var linkAt: ((Int) -> LinkState?)?
    var epoch: UInt64 = 0
    var recall = false
    var generation: UInt64 = 0
    var current = true
    var plans: [[Int]] = []
    var replays: [[[ThunderboltPreset.Write]]] = []
    var sent: [ThunderboltPreset.Write] = []
    var level = -6.0
    var stripsPerMixer = 1
    var attemptsAllowed = true
    var onReplay: ((Int) throws -> Void)?
    var onWrite: ((Int) throws -> Void)?
    var onSleep: ((Int) throws -> Void)?
    var sleeps = 0

    var environment: CardMixerRestoreRunner.Environment {
        CardMixerRestoreRunner.Environment(
            readLink: { [unowned self] in
                self.reads += 1
                return self.linkAt?(self.reads) ?? self.link
            },
            sleep: { [unowned self] _ in self.sleeps += 1; try self.onSleep?(self.sleeps) },
            decide: { [unowned self] in self.ledger.decide($0) },
            complete: { [unowned self] in self.ledger.complete() },
            giveUp: { [unowned self] in self.ledger.giveUp() },
            isCurrent: { [unowned self] in self.current },
            recallInFlight: { [unowned self] in self.recall },
            epoch: { [unowned self] in self.epoch },
            epochValid: { [unowned self] in $0 == self.epoch && !self.recall },
            editGeneration: { [unowned self] in self.generation },
            beginAttempt: { [unowned self] in self.attemptsAllowed && self.ledger.beginAttempt() },
            plan: { [unowned self] mixers in
                self.plans.append(mixers)
                return mixers.map { mixer in (0..<self.stripsPerMixer).map {
                    .property(.init(selector: .mixerChannelLevel, element: UInt32(mixer + 1) << 16 | UInt32($0)),
                              .float64(self.level))
                } }
            },
            replay: { [unowned self] plan, _, epoch, generation, progress in
                self.replays.append(plan)
                try self.onReplay?(self.replays.count)
                // The connection's fence: checked before every write.
                for write in plan.joined() {
                    guard epoch == self.epoch, generation == self.generation else { throw DeviceConnectionError.notConnected }
                    guard case .property(let address, _) = write else { continue }
                    progress.sent(address)
                    self.sent.append(write)
                    try self.onWrite?(self.sent.count)
                }
            })
    }
}

@Suite("D5 restore runner")
@MainActor
struct CardMixerRestoreRunnerTests {
    @Test("Fresh instance: one replay after the 5 s wait, then never again on it")
    func restoresOnce() async {
        let h = RunnerHarness()
        #expect(await CardMixerRestoreRunner.run(h.environment) == .restored(commands: 2, rebuilds: 0))
        #expect(h.replays.count == 1 && h.plans == [[0, 1]])
        #expect(h.sleeps == 20)
        #expect(await CardMixerRestoreRunner.run(h.environment) == .nothingToDo)
        #expect(h.replays.count == 1)
    }

    @Test("Driver already holds the app's mixers (same instance after a reconnect): no traffic")
    func heldInstance() async {
        let h = RunnerHarness()
        h.link = CardMixerRestoreTests.link(recovery: 2, flags: 3)
        #expect(await CardMixerRestoreRunner.run(h.environment) == .nothingToDo)
        #expect(h.replays.isEmpty && h.sleeps == 0)
        let old = RunnerHarness()
        old.link = CardMixerRestoreTests.link(tail: false)
        #expect(await CardMixerRestoreRunner.run(old.environment) == .unsupported)
        #expect(old.replays.isEmpty)
    }

    @Test("A drop during the wait aborts at the first bad sample; the recovery then gives up")
    func dropDuringWait() async {
        let h = RunnerHarness()
        h.linkAt = { $0 == 6 ? CardMixerRestoreTests.link(state: 3, recovery: 2) : nil }
        #expect(await CardMixerRestoreRunner.run(h.environment) == .unstable(samples: 5))
        #expect(h.replays.isEmpty)
        h.linkAt = nil
        h.link = CardMixerRestoreTests.link(recovery: 3)
        #expect(await CardMixerRestoreRunner.run(h.environment) == .gaveUp)
        #expect(h.replays.isEmpty)
    }

    @Test("Cancellation (disconnect, replacement) during the wait sends nothing")
    func cancelledDuringWait() async {
        let task = Task { @MainActor in
            let g = RunnerHarness()
            g.onSleep = { n in if n == 2 { withUnsafeCurrentTask { $0?.cancel() } } }
            let outcome = await CardMixerRestoreRunner.run(g.environment)
            return (outcome, g.replays.count)
        }
        let (outcome, replays) = await task.value
        #expect(outcome == .cancelled && replays == 0)
    }

    @Test("Replaced connection after the wait: superseded, nothing sent")
    func superseded() async {
        let h = RunnerHarness()
        h.onSleep = { [unowned h] n in if n == 20 { h.generation += 1; h.current = false } }
        #expect(await CardMixerRestoreRunner.run(h.environment) == .superseded)
        #expect(h.replays.isEmpty)
    }

    @Test("An edit during the replay rebuilds from the store after a quiet second; nothing is sent twice")
    func editRebuilds() async {
        let h = RunnerHarness()
        h.stripsPerMixer = 4
        h.onWrite = { [unowned h] n in
            if n == 1 { h.generation += 1; h.level = -20 }   // user moved a fader and it was saved
        }
        #expect(await CardMixerRestoreRunner.run(h.environment) == .restored(commands: 8, rebuilds: 1))
        #expect(h.replays.count == 2 && h.plans.count == 2)
        #expect(h.sent.count == 8)
        #expect(h.replays.last.map(CardMixerReplay.commandCount) == 7)
        var rebuiltLevel: Double?
        if case .property(_, let value)? = h.sent.last { rebuiltLevel = value.asFloat64 }
        #expect(rebuiltLevel == -20)
        #expect(h.sleeps == 20 + 4)   // the wait, then a 1 s quiet window
    }

    @Test("Many edits during the replay still finish it, within one plan's worth of writes")
    func manyEditsStillRestore() async {
        let h = RunnerHarness()
        h.stripsPerMixer = 4
        h.onWrite = { [unowned h] n in if n <= 5 { h.generation += 1 } }
        #expect(await CardMixerRestoreRunner.run(h.environment) == .restored(commands: 8, rebuilds: 5))
        #expect(h.sent.count == 8)
    }

    @Test("A run that cannot begin another attempt on the instance gives up")
    func attemptsExhausted() async {
        let h = RunnerHarness()
        h.attemptsAllowed = false
        #expect(await CardMixerRestoreRunner.run(h.environment) == .gaveUp)
        #expect(h.replays.isEmpty && h.sleeps == 0)
    }

    @Test("A recall or edit during the wait re-arms: the restore waits for it and goes on")
    func recallDuringWait() async {
        let h = RunnerHarness()
        h.onSleep = { [unowned h] n in
            if n == 10 { h.recall = true; h.epoch += 1 }
            if n == 25 { h.recall = false }
        }
        #expect(await CardMixerRestoreRunner.run(h.environment) == .restored(commands: 2, rebuilds: 0))
        #expect(h.replays.count == 1 && h.sleeps == 25 + 3)   // quiet ticks count from the sleep that saw it end
        let e = RunnerHarness()
        e.onSleep = { [unowned e] n in if n == 5 { e.generation += 1 } }
        #expect(await CardMixerRestoreRunner.run(e.environment) == .restored(commands: 2, rebuilds: 0))
        #expect(e.sleeps == 20 + 4)
    }

    @Test("Edits that keep landing before any write stop at the safety cap")
    func rebuildCap() async {
        let h = RunnerHarness()
        h.onReplay = { [unowned h] _ in h.generation += 1 }
        #expect(await CardMixerRestoreRunner.run(h.environment) == .gaveUp)
        #expect(h.replays.count == CardMixerReplay.maxRebuilds + 1)
        #expect(h.ledger.gaveUp)
    }

    @Test("A link fence failing mid-replay ends the restore without a retry in place")
    func linkFenceEnds() async {
        let h = RunnerHarness()
        h.onReplay = { _ in throw DeviceConnectionError.notConnected }
        #expect(await CardMixerRestoreRunner.run(h.environment) == .failed)
        #expect(h.replays.count == 1)
    }

    @Test("Routing traffic in the window (no edit generation change) does not restart the replay")
    func routingDoesNotRestart() async {
        let h = RunnerHarness()
        // A routing setProperty does not touch mixerEdits (mixerEditSelectors).
        h.onSleep = { [unowned h] n in
            // What setProperty does for a routing write in the window.
            if n == 7, ThunderboltDeviceConnection.mixerEditSelectors.contains(.routing) { h.generation += 1 }
        }
        #expect(await CardMixerRestoreRunner.run(h.environment) == .restored(commands: 2, rebuilds: 0))
        #expect(h.replays.count == 1)
    }
}
