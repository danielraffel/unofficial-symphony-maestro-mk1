import Foundation
import MaestroCore

/// D5: the card mixer is restored once on a driver instance that holds no app
/// mixer state. The original restored the card mixer from its saved settings
/// with card register writes only: SetSettingsFromDictionary, then
/// ApplySettingsToHardware = UpdateSoftwareReturnID + UpdateLLMHardware
/// (og_source/maestrolink/Software/SymphonyPCIeCardMixer.cpp:1479-1604,
/// 1750-1755). No unit (XLink) command, no preference lock or ready pair.
public enum CardMixerReplay {
    public typealias InputRoute = ThunderboltInputMeterMap.Route

    private static func inputIDs(layout: CardLayout, routes: [InputRoute]?) -> [Int?] {
        let capture = routes ?? ThunderboltInputMeterMap.currentRoutes(
            slot1: layout.isKnown ? layout.slot1 : nil, replayed: [])
        return ThunderboltInputMeterMap.mixerInputs(layout: layout, routes: capture)
    }
    /// Gap between two commands. Each 0xB0-0xB3 makes the driver recompute
    /// the whole mixer, 66 card register writes at 32 channels
    /// (SymphonyThunderbridge.cpp RecomputeCardMixer); 0xB4 makes 2. At 20 ms
    /// that is at most 50 commands, about 3,300 register writes, a second.
    public static let commandGap: Duration = .milliseconds(20)
    /// 21 samples 250 ms apart: 5.0 s of a stable link before the first write.
    public static let stableSamples = 21
    public static let stableInterval: Duration = .milliseconds(250)
    /// Edits must have stopped this long before a plan is rebuilt from the
    /// store: the Mixer page writes first and saves after the write returns.
    public static let quietWindow: Duration = .seconds(1)
    /// Restarts after an edit or a recall. A restart skips every address the
    /// run already sent, so the total stays within one plan; this is only a
    /// safety stop.
    public static let maxRebuilds = 50
    /// Runs started on one driver instance (launch or reconnect, identity, and
    /// a healthy health-loop cycle while the restore is still pending).
    public static let maxAttempts = 3

    public static func supportsSingleUnit(channelCount: Int, converterFlags: UInt32) -> Bool {
        channelCount == 32 && (converterFlags & 3) == 0
    }

    // MARK: - Stability

    public static func isUsable(_ link: LinkState) -> Bool {
        link.state == .up && link.clockPresent && link.linkConfigured && !link.hwSuspended
    }

    public enum Stability: Equatable, Sendable {
        case pending
        case stable(recoveryCount: UInt32)
        case unstable
    }

    /// Accepts samples one at a time and gives up on the first bad one.
    public struct StabilityGate: Sendable {
        public let requiredSamples: Int
        private var recovery: UInt32?
        public private(set) var accepted = 0

        public init(requiredSamples: Int = CardMixerReplay.stableSamples) {
            self.requiredSamples = requiredSamples
        }

        public mutating func add(_ sample: LinkState?) -> Stability {
            guard let sample, CardMixerReplay.isUsable(sample),
                  recovery.map({ $0 == sample.recoveryCount }) ?? true else { return .unstable }
            recovery = sample.recoveryCount
            accepted += 1
            return accepted >= requiredSamples ? .stable(recoveryCount: sample.recoveryCount) : .pending
        }
    }

    /// The 5 s wait. Returns the recovery count it held at, or `nil` on the
    /// first bad sample, a failed or cancelled sleep. `samples` is the number
    /// of link reads made (host only).
    public static func waitForStableLink(requiredSamples: Int = stableSamples,
                                         interval: Duration = stableInterval,
                                         sample: () async -> LinkState?,
                                         sleep: (Duration) async throws -> Void,
                                         isolation: isolated (any Actor)? = #isolation) async -> (recovery: UInt32?, samples: Int) {
        var gate = StabilityGate(requiredSamples: requiredSamples)
        var samples = 0
        while true {
            if Task.isCancelled { return (nil, samples) }
            let link = await sample()
            samples += 1
            switch gate.add(link) {
            case .stable(let recovery): return (recovery, samples)
            case .unstable: return (nil, samples)
            case .pending: break
            }
            do { try await sleep(interval) } catch { return (nil, samples) }
        }
    }

    // MARK: - Plan

    /// What was saved for this mixer: per-mixer keys only, Master and the
    /// return only when their keys exist, and a held Software Return source
    /// (8 or more at 32 channels) not sent. The mixer's Software Return strip
    /// does not make a mixer "saved"; it only supplies the return's mute and
    /// solo once the mixer's own return level was saved (MixerEditorState.save
    /// writes both together).
    ///
    /// Every input strip of the layout is written, saved or not. The driver
    /// starts its card mixer with the inputs muted (SymphonyThunderbridge.cpp,
    /// "inputs start muted"), while a strip nobody has touched shows unmuted at
    /// 0 dB, centre, as the original's did
    /// (og_source/maestrolink/Software/SymphonyIOMixer.h:28-33). An unsaved
    /// strip therefore gets its unmute (the driver's level and pan already are
    /// the defaults), so a strip always does what it shows. Nothing is muted
    /// that the strip does not show muted.
    ///
    /// The return's pan is always written centre: Software Return has no pan
    /// (see `MixerStateSnapshot.savedSoftwareReturn`), and a driver that kept
    /// running may still hold one from an earlier version.
    public static func savedWrites(mixer: Int, layout: CardLayout, store: ChannelStateStore,
                                   preferences: MixerPreferences? = nil,
                                   pairCount: Int = 8,
                                   routes: [InputRoute]? = nil) -> [ThunderboltPreset.Write] {
        let defaults = preferences ?? store.mixerPreferences
        let saved: [MixerChannelState] = store.load(ChannelStateStore.mixerKey(mixer)) ?? []
        let left = defaults.object(forKey: "mixerSWReturnLeftLevel_\(mixer)") as? Double
        let right = defaults.object(forKey: "mixerSWReturnRightLevel_\(mixer)") as? Double
        let master = defaults.object(forKey: "mixerMasterLevel_\(mixer)") as? Double
        let sourceKey = "mixerSoftwareReturnSource_\(mixer)"
        let savedSource: UInt32? = defaults.object(forKey: sourceKey) != nil
            ? UInt32(clamping: defaults.integer(forKey: sourceKey)) : nil

        var writes: [ThunderboltPreset.Write] = []
        let base = UInt32(mixer + 1) << 16
        func put(_ selector: AudioPropertySelector, _ value: PropertyValue, _ channel: Int = 0) {
            writes.append(.property(PropertyAddress(selector: selector, element: base | UInt32(channel)), value))
        }
        if let savedSource {
            let shown = TwoUnitMixer.shownSoftwareReturnSource(savedSource, pairCount: pairCount)
            if !TwoUnitMixer.isHeld(shown: shown, saved: savedSource, pairCount: pairCount) {
                put(.mixerSoftwareReturnID, .uint32(shown))
            }
        }
        let ids = inputIDs(layout: layout, routes: routes)
        for (index, _) in layout.mixerChannels.enumerated() {
            guard let id = ids[index] else { continue }
            guard index < saved.count else {
                put(.mixerChannelMute, .bool(false), id)
                continue
            }
            let state = saved[index]
            // Level, pan, mute: never an unmute before its level.
            put(.mixerChannelLevel, .float64(state.level), id)
            put(.mixerChannelPan, .float64(state.pan), id)
            put(.mixerChannelMute, .bool(state.isMuted), id)
            put(.mixerChannelSolo, .bool(state.isSoloed), id)
        }
        if let left {
            // 1000 sets both sides; the right fader follows on its own ID.
            put(.mixerChannelLevel, .float64(left), 1000)
            if MixerStateSnapshot.hasSavedSoftwareReturn(mixer: mixer, preferences: defaults) {
                let own = MixerStateSnapshot.savedSoftwareReturn(mixer: mixer, preferences: defaults)
                put(.mixerChannelMute, .bool(own.isMuted), 1000)
                put(.mixerChannelSolo, .bool(own.isSoloed), 1000)
            }
        }
        put(.mixerChannelPan, .float64(0), 1000)
        // SymphonyPCIeCardMixer uses a distinct right-side return ID.
        // Evidence: og_source/maestrolink/Software/SymphonyPCIeCardMixer.cpp:27-46,249-261.
        if let right { put(.mixerChannelLevel, .float64(right), 0x1002) }
        if let master { put(.mixerChannelLevel, .float64(master), 2000) }
        return writes
    }

    /// One group per mixer, rebuilt from the store each time it is called.
    /// `complete` writes the whole mixer, defaults included
    /// (``writes(mixer:layout:snapshot:second:)``): used once after the
    /// routing and mixer reset, when a driver that kept running may still hold
    /// the state the reset removed.
    public static func plan(mixers: [Int], layout: CardLayout, store: ChannelStateStore,
                            preferences: MixerPreferences? = nil,
                            complete: Bool = false,
                            routes: [InputRoute]? = nil,
                            pairCount: Int = 8) -> [[ThunderboltPreset.Write]] {
        mixers.map { mixer in
            guard complete else {
                return savedWrites(mixer: mixer, layout: layout, store: store, preferences: preferences,
                                   pairCount: pairCount, routes: routes)
            }
            let snapshot = MixerStateSnapshot(channelCount: layout.mixerChannels.count, mixer: mixer,
                                              store: store, preferences: preferences)
            return writes(mixer: mixer, layout: layout, snapshot: snapshot, routes: routes).filter {
                // A source held for unit B (beyond the pairs on offer) is not sent.
                guard case .property(let address, _) = $0, address.selector == .mixerSoftwareReturnID
                else { return true }
                return snapshot.softwareReturnSource < UInt32(pairCount)
            }
        }
        .filter { !$0.isEmpty }
    }

    public static func commandCount(_ groups: [[ThunderboltPreset.Write]]) -> Int {
        groups.reduce(0) { $0 + $1.count }
    }

    /// Card register writes the driver makes for a plan at 32 channels.
    public static func registerWrites(_ groups: [[ThunderboltPreset.Write]]) -> Int {
        groups.joined().reduce(0) { total, write in
            guard case .property(let address, _) = write else { return total }
            return total + (address.selector == .mixerSoftwareReturnID ? 2 : 66)
        }
    }

    /// Addresses a run has sent, across rebuilds. Filled from the transaction
    /// (off the main actor), read by the runner.
    public final class Progress: @unchecked Sendable {
        private let lock = NSLock()
        private var sentAddresses: Set<PropertyAddress> = []
        public init() {}
        public func sent(_ address: PropertyAddress) { lock.withLock { _ = sentAddresses.insert(address) } }
        public var count: Int { lock.withLock { sentAddresses.count } }
        public var addresses: Set<PropertyAddress> { lock.withLock { sentAddresses } }
        public func remaining(_ groups: [[ThunderboltPreset.Write]]) -> [[ThunderboltPreset.Write]] {
            let done = lock.withLock { sentAddresses }
            return groups.map { $0.filter {
                guard case .property(let address, _) = $0 else { return true }
                return !done.contains(address)
            } }.filter { !$0.isEmpty }
        }
    }

    /// Full layout check once per group, then each write; the caller's `send`
    /// takes the serial owner, checks the live fences and writes. `pace` runs
    /// between writes outside that owner, so other writes are never held up by
    /// the pacing. No unlock or ready command: see the type's comment.
    public static func run(_ groups: [[ThunderboltPreset.Write]],
                           validateMixer: () throws -> Void,
                           send: (ThunderboltPreset.Write) throws -> Void,
                           pace: () async throws -> Void,
                           isolation: isolated (any Actor)? = #isolation) async throws {
        let total = commandCount(groups)
        var sent = 0
        for group in groups where !group.isEmpty {
            try validateMixer()
            for write in group {
                try Task.checkCancellation()
                try send(write)
                sent += 1
                if sent < total { try await pace() }
            }
        }
    }

    public static func outputWrites(_ routes: [UInt8: UInt8]) -> [ThunderboltPreset.Write] {
        routes.sorted { $0.key < $1.key }.compactMap {
            ThunderboltCardRouting.route(destination: $0.key, source: $0.value, unitBActive: false).map {
                ThunderboltPreset.Write.output($0)
            }
        }
    }

    /// One whole card mixer. The order is a safety rule of its own, so that
    /// nothing would be louder than saved for a moment even if a route were
    /// live: Master, Software Return (level, mute, solo, source), then every
    /// input strip with its level and pan before its mute and solo.
    public static func writes(mixer: Int, layout: CardLayout, snapshot: MixerStateSnapshot,
                              second: (CardLayout, MixerStateSnapshot)? = nil,
                              routes: [InputRoute]? = nil,
                              secondRoutes: [InputRoute]? = nil) -> [ThunderboltPreset.Write] {
        var writes: [ThunderboltPreset.Write] = []
        let base = UInt32(mixer + 1) << 16
        func put(_ selector: AudioPropertySelector, _ value: PropertyValue, _ channel: Int = 0) {
            writes.append(.property(PropertyAddress(selector: selector, element: base | UInt32(channel)), value))
        }
        put(.mixerChannelLevel, .float64(snapshot.masterLevel), 2000)
        let own = snapshot.swReturnChannel
        // 1000 sets both sides; the right fader follows on its own ID.
        put(.mixerChannelLevel, .float64(own.level), 1000)
        put(.mixerChannelLevel, .float64(snapshot.swReturnRightLevel), 0x1002)
        // Software Return has no pan: always centre.
        put(.mixerChannelPan, .float64(0), 1000)
        put(.mixerChannelMute, .bool(own.isMuted), 1000)
        put(.mixerChannelSolo, .bool(own.isSoloed), 1000)
        let source = TwoUnitMixer.shownSoftwareReturnSource(snapshot.softwareReturnSource,
            pairCount: TwoUnitMixer.softwareReturnPairCount(unitBActive: second != nil))
        put(.mixerSoftwareReturnID, .uint32(source))
        let idsA = inputIDs(layout: layout, routes: routes)
        let idsB = second.map { inputIDs(layout: $0.0, routes: secondRoutes).map { $0.map { $0 + 32 } } } ?? []
        let ids = idsA + idsB
        let states = snapshot.channels + (second?.1.channels ?? [])
        // Inputs no strip maps to first, muted and unsoloed: an input that now
        // arrives on two receive slots is then not heard twice while the
        // strips are written, and a stale solo cannot silence them.
        let mapped = Set(ids.compactMap { $0 })
        let inputCount = second == nil ? 32 : 64
        for id in 0..<inputCount where !mapped.contains(id) {
            put(.mixerChannelMute, .bool(true), id)
            put(.mixerChannelSolo, .bool(false), id)
        }
        var written = Set<Int>()
        for (id, state) in zip(ids, states) {
            guard let id, written.insert(id).inserted else { continue }
            put(.mixerChannelLevel, .float64(state.level), id)
            put(.mixerChannelPan, .float64(state.pan), id)
            put(.mixerChannelMute, .bool(state.isMuted), id)
            put(.mixerChannelSolo, .bool(state.isSoloed), id)
        }
        return writes
    }

    /// Every control a complete write of one card mixer must reach, for the
    /// connection to count that mixer as written: Master, Software Return
    /// (both sides, pan, mute, solo) and level, pan, mute and solo of every
    /// input strip of the layout (and of unit B's at 64 channels). The
    /// Software Return source is added by the caller when the plan carries it.
    public static func requiredAddresses(mixer: Int, layout: CardLayout,
                                         second: CardLayout? = nil,
                                         routes: [InputRoute]? = nil,
                                         secondRoutes: [InputRoute]? = nil) -> Set<PropertyAddress> {
        let base = UInt32(mixer + 1) << 16
        var required: Set<PropertyAddress> = []
        func need(_ selector: AudioPropertySelector, _ channel: Int) {
            required.insert(PropertyAddress(selector: selector, element: base | UInt32(channel)))
        }
        need(.mixerChannelLevel, 2000)
        need(.mixerChannelLevel, 0x1002)
        let idsA = inputIDs(layout: layout, routes: routes)
        let idsB = second.map { inputIDs(layout: $0, routes: secondRoutes).map { $0.map { $0 + 32 } } } ?? []
        let ids = idsA + idsB
        var written = Set<Int>()
        for id in ids.compactMap({ $0 }) where written.insert(id).inserted {
            for selector in [AudioPropertySelector.mixerChannelLevel, .mixerChannelPan,
                             .mixerChannelMute, .mixerChannelSolo] {
                need(selector, id)
            }
        }
        let inputCount = second == nil ? 32 : 64
        for id in 0..<inputCount where !written.contains(id) {
            need(.mixerChannelMute, id)
            need(.mixerChannelSolo, id)
        }
        for selector in [AudioPropertySelector.mixerChannelLevel, .mixerChannelPan,
                         .mixerChannelMute, .mixerChannelSolo] { need(selector, 1000) }
        return required
    }
}

/// Which mixers D5 restores on which driver instance, decided from the
/// driver's own report (`DriverMixerInstance`), never from a Swift connection
/// object. Pure; AppState owns one.
///
/// - The instance's flags are latched the first time it is seen: a mixer the
///   driver held no app state for at that moment is D5's to restore, even if
///   an edit later sets the driver's flag (the restore then carries the edit,
///   rebuilt from the store).
/// - The baseline is the recovery and re-init counts at the first sighting
///   with the link up. If either moves on this instance, an in-place recovery
///   has happened (the driver recomputed from its cache) and D5 never runs on
///   it again.
/// - A driver without the report: nothing is restored, the page behaves as before.
public struct CardMixerRestoreLedger: Sendable, Equatable {
    public enum Decision: Equatable, Sendable {
        /// Old driver: no instance report.
        case unsupported
        /// Link not up yet; nothing latched as a baseline.
        case notReady
        /// The driver held both mixers at first sight, or the restore finished.
        case nothingToDo
        /// An in-place recovery or too many interruptions on this instance.
        case gaveUp
        case restore(mixers: [Int], recoveryCount: UInt32)
    }

    public private(set) var nonce: UInt64?
    public private(set) var needs: [Bool] = [false, false]
    public private(set) var baselineRecovery: UInt32?
    public private(set) var baselineReinit: UInt32?
    public private(set) var completed = false
    public private(set) var gaveUp = false
    public private(set) var attempts = 0
    /// A run has begun an attempt and not yet ended (see `endAttempt`).
    public private(set) var running = false
    /// Restore both mixers on the next instance seen even if the driver holds
    /// app state for them: set while the routing and mixer reset's defaults
    /// have not reached the card yet (`RoutingMixerReset.Pending.thunderboltCardMixer`).
    /// Setting it on an instance already latched (the Mixer page can look at
    /// the driver before the restore is asked for) takes both mixers too.
    public var restoresHeldMixers = false {
        didSet {
            if restoresHeldMixers, !oldValue, nonce != nil, !completed, !running { needs = [true, true] }
        }
    }

    public init() {}

    /// Latch a newly seen instance; record the baseline at first link-up.
    public mutating func observe(_ link: LinkState?) {
        guard let link, let instance = link.mixerInstance else { return }
        if nonce != instance.nonce {
            let force = restoresHeldMixers
            self = CardMixerRestoreLedger()
            restoresHeldMixers = force
            nonce = instance.nonce
            needs = force ? [true, true] : instance.holdsAppState.prefix(2).map { !$0 }
        }
        if baselineRecovery == nil, CardMixerReplay.isUsable(link) {
            baselineRecovery = link.recoveryCount
            baselineReinit = link.cardReinitCount
        }
    }

    public mutating func decide(_ link: LinkState?) -> Decision {
        observe(link)
        guard let link, let instance = link.mixerInstance, instance.nonce == nonce else { return .unsupported }
        if gaveUp { return .gaveUp }
        if completed || !needs.contains(true) { return .nothingToDo }
        guard let recovery = baselineRecovery, let reinit = baselineReinit else { return .notReady }
        guard link.recoveryCount == recovery, link.cardReinitCount == reinit else {
            gaveUp = true
            return .gaveUp
        }
        guard CardMixerReplay.isUsable(link) else { return .notReady }
        return .restore(mixers: (0..<2).filter { needs[$0] }, recoveryCount: recovery)
    }

    public mutating func complete() { completed = true }
    /// Re-arm a live complete rewrite after the unit's capture table moved.
    /// The driver keeps the written marks for output safety while this run is
    /// in flight, so routes fed by a mixer are never dropped.
    public mutating func noteOwed() {
        completed = false
        gaveUp = false
        attempts = 0
        needs = [true, true]
    }
    public mutating func giveUp() { gaveUp = true }

    /// A run is about to wait on this instance. False (and given up) once
    /// `CardMixerReplay.maxAttempts` runs have started without finishing.
    public mutating func beginAttempt() -> Bool {
        attempts += 1
        if attempts > CardMixerReplay.maxAttempts { gaveUp = true }
        running = !gaveUp
        return !gaveUp
    }

    /// The run task ended or was cancelled. The last allowed attempt ending
    /// without finishing gives up, so the Mixer page gets the mixer back.
    public mutating func endAttempt() {
        running = false
        if !completed, attempts >= CardMixerReplay.maxAttempts { gaveUp = true }
    }

    /// Latched, owned by D5, not finished: a healthy cycle may start a run.
    public var isPending: Bool {
        nonce != nil && needs.contains(true) && !completed && !gaveUp
            && attempts < CardMixerReplay.maxAttempts
    }

    /// Whether the Mixer page's own recall-time sync must leave `mixer` to D5.
    /// D5 owns a mixer the driver reported empty on this instance only while
    /// the restore is still to come (pending or running). Once it finished or
    /// gave up (an in-place recovery, attempts used up, too many rebuilds),
    /// the page syncs as it always did, so a card layout
    /// change still reaches the card, and a mixer D5 never wrote is not left
    /// at the driver's defaults. Only while D5 can run here at all
    /// (`eligible`: one Symphony I/O at 32 channels, no converters, identity
    /// known, ...). An undecided instance is judged from its flags. Otherwise
    /// (old driver, ineligible path, or the driver held that mixer) the page
    /// syncs as it always did.
    public func pageDefersSync(mixer: Int, instance: DriverMixerInstance?, eligible: Bool) -> Bool {
        guard eligible, let instance, (0..<2).contains(mixer) else { return false }
        if instance.nonce == nonce { return needs[mixer] && !completed && !gaveUp }
        return !instance.holdsAppState[mixer]
    }
}

/// The D5 restore task's body, with every outside effect injected so each
/// step can be tested: the host-only link read, sleeping, the ledger, the
/// connection/eligibility check, the recall and edit fences, the plan built
/// from the store, and the paced transaction.
///
/// Order: decide from the driver report; wait 5 s of stable link (first bad
/// sample ends it); wait until no recall is running and edits have been quiet
/// for `quietWindow`; decide again (an in-place recovery since the baseline
/// gives up); rebuild the plan from the store; run it. An edit or recall that
/// lands during the run makes it start over from the store (at most
/// `maxRebuilds` times); a link, layout or connection fence ends it.
public enum CardMixerRestoreRunner {
    public enum Outcome: Equatable, Sendable {
        case unsupported, notReady, nothingToDo, gaveUp
        case unstable(samples: Int)
        case cancelled, superseded, failed
        /// `commands`: distinct addresses written over the whole run.
        case restored(commands: Int, rebuilds: Int)
    }

    public struct Environment {
        public var readLink: @MainActor () async -> LinkState?
        public var sleep: @MainActor (Duration) async throws -> Void
        public var decide: @MainActor (LinkState?) -> CardMixerRestoreLedger.Decision
        public var complete: @MainActor () -> Void
        public var giveUp: @MainActor () -> Void
        /// Same connection, still eligible (single unit, identity known, ...).
        public var isCurrent: @MainActor () -> Bool
        public var recallInFlight: @MainActor () -> Bool
        public var epoch: @MainActor () -> UInt64
        public var epochValid: @MainActor (UInt64) -> Bool
        public var editGeneration: @MainActor () -> UInt64
        public var beginAttempt: @MainActor () -> Bool
        public var plan: @MainActor ([Int]) -> [[ThunderboltPreset.Write]]
        /// Runs the transaction; must stop at the first write after the
        /// captured epoch or edit generation stops being current, and report
        /// each address it wrote to `Progress`.
        public var replay: @MainActor ([[ThunderboltPreset.Write]], UInt32, UInt64, UInt64, CardMixerReplay.Progress) async throws -> Void

        public init(readLink: @escaping @MainActor () async -> LinkState?,
                    sleep: @escaping @MainActor (Duration) async throws -> Void,
                    decide: @escaping @MainActor (LinkState?) -> CardMixerRestoreLedger.Decision,
                    complete: @escaping @MainActor () -> Void,
                    giveUp: @escaping @MainActor () -> Void,
                    isCurrent: @escaping @MainActor () -> Bool,
                    recallInFlight: @escaping @MainActor () -> Bool,
                    epoch: @escaping @MainActor () -> UInt64,
                    epochValid: @escaping @MainActor (UInt64) -> Bool,
                    editGeneration: @escaping @MainActor () -> UInt64,
                    beginAttempt: @escaping @MainActor () -> Bool,
                    plan: @escaping @MainActor ([Int]) -> [[ThunderboltPreset.Write]],
                    replay: @escaping @MainActor ([[ThunderboltPreset.Write]], UInt32, UInt64, UInt64, CardMixerReplay.Progress) async throws -> Void) {
            self.readLink = readLink; self.sleep = sleep; self.decide = decide
            self.complete = complete; self.giveUp = giveUp; self.isCurrent = isCurrent
            self.recallInFlight = recallInFlight; self.epoch = epoch; self.epochValid = epochValid
            self.editGeneration = editGeneration; self.beginAttempt = beginAttempt
            self.plan = plan; self.replay = replay
        }
    }

    static func outcome(_ decision: CardMixerRestoreLedger.Decision) -> Outcome {
        switch decision {
        case .unsupported: .unsupported
        case .notReady: .notReady
        case .nothingToDo: .nothingToDo
        case .gaveUp: .gaveUp
        case .restore: .failed
        }
    }

    @MainActor
    public static func run(_ env: Environment) async -> Outcome {
        let first = env.decide(await env.readLink())
        guard case .restore(_, let recovery) = first else { return outcome(first) }
        guard env.beginAttempt() else { return .gaveUp }
        let progress = CardMixerReplay.Progress()
        let generationAtStart = env.editGeneration()
        let wait = await CardMixerReplay.waitForStableLink(sample: { await env.readLink() },
                                                           sleep: { try await env.sleep($0) })
        if Task.isCancelled { return .cancelled }
        guard wait.recovery == recovery else { return .unstable(samples: wait.samples) }
        let quietTicks = Int(CardMixerReplay.quietWindow / CardMixerReplay.stableInterval)
        var quiet = !env.recallInFlight() && env.editGeneration() == generationAtStart
        var rebuilds = 0
        while true {
            var lastGeneration = env.editGeneration()
            var ticks = 0
            while !quiet {
                do { try await env.sleep(CardMixerReplay.stableInterval) } catch { return .cancelled }
                if Task.isCancelled { return .cancelled }
                guard env.isCurrent() else { return .superseded }
                let generation = env.editGeneration()
                if env.recallInFlight() || generation != lastGeneration {
                    lastGeneration = generation
                    ticks = 0
                } else {
                    ticks += 1
                }
                quiet = ticks >= quietTicks
            }
            if Task.isCancelled { return .cancelled }
            guard env.isCurrent() else { return .superseded }
            let decision = env.decide(await env.readLink())
            guard case .restore(let mixers, let current) = decision, current == recovery else {
                return outcome(decision)
            }
            let epoch = env.epoch()
            let generation = env.editGeneration()
            // Rebuilt from the store; what this run already wrote is not sent
            // again (an edit to it went to the driver with the user's write).
            let plan = progress.remaining(env.plan(mixers))
            guard !plan.isEmpty else {
                env.complete()
                return progress.count == 0 ? .nothingToDo : .restored(commands: progress.count, rebuilds: rebuilds)
            }
            do {
                try await env.replay(plan, recovery, epoch, generation, progress)
                guard env.isCurrent() else { return .superseded }
                env.complete()
                return .restored(commands: progress.count, rebuilds: rebuilds)
            } catch {
                if Task.isCancelled { return .cancelled }
                guard !env.epochValid(epoch) || env.editGeneration() != generation else { return .failed }
                rebuilds += 1
                guard rebuilds <= CardMixerReplay.maxRebuilds else {
                    env.giveUp()
                    return .gaveUp
                }
                quiet = false
            }
        }
    }
}
