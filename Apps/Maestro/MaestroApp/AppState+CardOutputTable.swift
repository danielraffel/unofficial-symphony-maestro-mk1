import Foundation
import MaestroCore
import MaestroDevice

/// How one run of the ThunderBridge restore ended.
enum CardRestoreOutcome: Equatable {
    /// Every route and both mixers are on the card and equal what is saved.
    case complete
    /// The cards, the unit's identity or its saved mixer state are not
    /// available yet. Nothing mixer-related was written; from the third
    /// check in a row every card channel is direct.
    case waiting(String)
    /// A write failed or the driver state changed under the run.
    case failed(String)
    /// A recall, a reset or an edit happened during the run: it wins, and the
    /// run starts again from what is saved now.
    case superseded
}

extension AppState {
    /// The whole ThunderBridge output table for one Symphony I/O: the default
    /// (every output direct, no mixer routed, as the original's
    /// SymphonyPCIeRoutingController::ResetRouting, output branch) with the
    /// saved choices over it. Never only the saved rows: the card keeps the
    /// routes an earlier session wrote, and a driver before build 142 starts
    /// it with the main pair on card mixer 1. A saved source the card cannot play (a unit B playback
    /// pair at 32 channels) does not fail the table: its output is disabled
    /// (and said, unless `quiet`), so that every destination is written and
    /// none is left on whatever the card had. The table has all 32 card
    /// channels of the unit, whatever cards are fitted.
    @MainActor
    func thunderboltOutputTable(for device: any DeviceConnection, quiet: Bool = false) -> [UInt8: UInt8] {
        let routes = peripheralRoutingCache(direction: "output").loadMulti() ?? [:]
        // Every destination of both slots, so every card channel (0-31) is
        // in the table: one past a card's outputs, or in an empty slot, has
        // no source and is written disabled. Left out, such a channel kept
        // whatever the card had (a mixer route of an earlier session or of
        // other cards), while the ledger believed that mixer fed nothing.
        let defaults = SymphonyIODefaultRouting.thunderboltOutputRoutes(
            board0Outputs: primaryBoardType.totalOutputChannels,
            board1Outputs: secondaryBoardType.totalOutputChannels)
        let rowCount = device.identifier.mode.channelCount / 2 + 2
        let table = Self.replayOutputSources(
            defaults: Dictionary(uniqueKeysWithValues: defaults.map { ($0.destination, $0.source) }),
            saved: cachedOutputRouteMap(),
            complete: (0..<rowCount).allSatisfy { routes[$0] != nil },
            destinations: defaults.map(\.destination))
        var playable: [UInt8: UInt8] = [:]
        for (destination, source) in table where ThunderboltCardRouting.channel(forDestination: destination) != nil {
            if ThunderboltCardRouting.route(destination: destination, source: source, unitBActive: unitBOnCard) != nil {
                playable[destination] = source
            } else {
                if !quiet {
                    print("[Maestro] syncOutputRouting: output \(destination) ← source \(source) has no card route; output disabled")
                }
                playable[destination] = SymphonyIORoutingAddress.none
            }
        }
        return playable
    }

    /// The pause before retry number `attempt` of a restore that did not
    /// complete: 2, 4, 8, 16 s, then 30 s. One scheme for the single-unit
    /// restore, the 64-channel replay and (with its own counter) USB.
    static func restoreRetryPause(_ attempt: Int) -> TimeInterval {
        min(30.0, pow(2.0, Double(min(max(attempt, 1), 5))))
    }

    /// The driver re-programmed the card (the connection's ledger has dropped
    /// its marks by itself): run the restore at the next opportunity.
    @MainActor
    func invalidateCardOutputTable(_ tb: ThunderboltDeviceConnection) {
        cardOutputTableReplayNeeded = true
        cardOutputRetryAttempts = 0
        cardOutputRetryAfter = .distantPast
        twoUnitRetryAttempts = 0
        twoUnitRetryAfter = .distantPast
        updateRestoreStatus()
    }

    /// The Output Routing page has saved a change. A restore that is running
    /// (or one that deferred the route just written) starts again from what
    /// is saved now, so the page's choice is what ends up on the unit.
    @MainActor
    func outputRoutingSaved() {
        invalidateThunderboltOutputMeterMap()
        unitBOutputMeterWords = nil
        unitBOutputMeterLayout = nil
        unitBOutputMeterWordsPollStamp = -1
        outputRouteEdits &+= 1
        guard outputRouteDeferredSinceSave || cardOutputRestoreRunning || usbRestoreTask != nil else { return }
        outputRouteDeferredSinceSave = false
        if device is ThunderboltDeviceConnection {
            cardOutputTableReplayNeeded = true
            cardOutputRetryAfter = .distantPast
            twoUnitRetryAfter = .distantPast
        } else {
            usbRestoreOwed = true
            usbRestoreRetryAfter = .distantPast
        }
        updateRestoreStatus()
    }

    /// Why the saved output table cannot be read at all (its destinations
    /// depend on the cards, its rows on the unit), nil when it can.
    @MainActor
    func cardTableUnreadableReason() -> String? {
        if let reason = RoutingResetGuard.refusalReason(board1: primaryBoardReading, board2: secondaryBoardReading) {
            return "cards not read this session: \(reason.prefix(80))"
        }
        if connectionMode == .hardware, unitAIdentity == nil { return "the unit is not identified yet" }
        // 64 channels: the two-unit replay also waits for unit B's cards.
        if usesTwoUnitReplay, !unitBInputRoutingAllowed || unitBLayout == nil
            || unitBBoardSource(slot: 0) != .detected || unitBBoardSource(slot: 1) != .detected {
            return "the second Symphony I/O's cards are not read yet"
        }
        return nil
    }

    /// Why the restore cannot write mixers or mixer-fed routes yet, nil when
    /// it can.
    @MainActor
    func cardRestoreBlockedReason() -> String? {
        if let reason = cardTableUnreadableReason() { return reason }
        if !mixerPreferences.isWritable { return "saved mixer state is not available for this unit" }
        return nil
    }

    /// How many checks in a row may find the cards or the unit's identity
    /// unread before the card is put on its direct defaults. With the
    /// restore's pauses (2 s, 4 s) the third check comes about 6 s after the
    /// first.
    static let cardBlockedChecksBeforeDirect = 3

    /// The cards or the unit's identity are still not read. Until the third
    /// check in a row nothing is written (a read normally arrives within a
    /// second or two, and the saved table then goes out in order). From the
    /// third on, the card is not left as it was found: every card channel is
    /// written to its direct default (channel n plays software output n), so
    /// that no output stays on a mixer route of the driver's start-up table
    /// or of an earlier session, with that mixer's old strips, while Maestro
    /// shows it direct. With nothing on a mixer, mixer edits made meanwhile
    /// reach the card too. Once per driver state; the restore keeps retrying
    /// and writes the saved table when it can be read.
    @MainActor
    func cardRestoreStillBlocked(_ tb: ThunderboltDeviceConnection) async {
        // Counted per connection: a session that stayed blocked must not make
        // the next connection's first check write the defaults at once.
        if cardBlockedConnection != ObjectIdentifier(tb) {
            cardBlockedConnection = ObjectIdentifier(tb)
            cardBlockedChecks = 0
        }
        cardBlockedChecks += 1
        let epoch = tb.cardMixers.epoch
        guard cardBlockedChecks >= Self.cardBlockedChecksBeforeDirect, device === tb, !hardwareWritesSuspended,
              connectedUnit == nil, !converterRoutingSurface,
              cardDirectFallback.map({ $0.connection != ObjectIdentifier(tb) || $0.epoch != epoch }) ?? true else { return }
        // Unit B's channels exist only while 64 channels run with it.
        let channels: UInt8 = usesTwoUnitReplay ? 64 : 32
        let failed = await Task.detached(priority: .utility) { tb.writeCardDirectDefaults(channels: channels) }.value
        guard device === tb else { return }
        if failed.isEmpty, tb.cardMixers.epoch == epoch { cardDirectFallback = (ObjectIdentifier(tb), epoch) }
        print("[Maestro] syncOutputRouting: cards or identity still not read after \(cardBlockedChecks) checks; "
            + "card channels 0-\(channels - 1) written direct so that no output is on a mixer"
            + (failed.isEmpty ? "" : " (\(failed.count) refused: \(failed))"))
    }

    /// The one restore for a Symphony I/O on ThunderBridge: connect, reconnect,
    /// link recovery, card re-init, and after the routing and mixer reset.
    /// (At 64 channels the two-unit replay sends the same writes in the same
    /// order through the same chokepoint, `replayTwoUnits`.)
    ///
    /// The card keeps whatever an earlier session routed, and a driver before
    /// build 142 starts it, and re-programs it after a reset, with the main
    /// pair on card mixer 1 (from 142 every output starts direct). Nothing
    /// here trusts the state found, and nothing trusts the driver's "holds
    /// app state" flag. In order:
    ///
    /// 1. Preconditions. With the cards not detected or the unit not
    ///    identified, the saved table cannot be read at all (its destinations
    ///    depend on the cards, its rows on the unit). Nothing is written for
    ///    the first two checks; every mixer write stays deferred by the
    ///    connection meanwhile. From the third check on the card is written
    ///    to its direct defaults (`cardRestoreStillBlocked`): the card may
    ///    hold a mixer route of an earlier session with that session's
    ///    strips, not only the driver's start-up table with its inputs muted.
    ///    With only the saved mixer state unavailable, step 2 still runs and
    ///    the mixer-fed outputs stay disabled.
    /// 2. Every destination of the saved table: direct routes as saved, a
    ///    destination fed by a mixer that is not marked written disabled.
    /// 3. Each mixer that feeds something: its complete state, then its routes.
    /// 4. The other mixer's complete state (it feeds nothing), so a route
    ///    added later is immediate.
    /// 5. If anything saved changed during the run, again from the top.
    ///
    /// The table and the mixer state are read from the stores at each write,
    /// not once. A preset recall, Reset Routing or an edit during the run
    /// wins: the run stops or starts over, and what ends on the unit is what
    /// is saved. A mixer already marked written for this driver state is not
    /// silenced again.
    @MainActor
    func restoreThunderboltOutputTable(_ tb: ThunderboltDeviceConnection) async {
        guard !cardOutputRestoreRunning else { cardOutputTableReplayNeeded = true; return }
        cardOutputRestoreRunning = true
        defer { cardOutputRestoreRunning = false; updateRestoreStatus() }
        // Symphony I/O routing only: nothing is sent to a unit that is not one.
        guard connectedUnit == nil else { return }
        cardOutputTableReplayNeeded = true
        updateRestoreStatus()
        var outcome = CardRestoreOutcome.superseded
        for _ in 0..<3 {
            outcome = await runCardRestore(tb)
            guard outcome == .superseded, device === tb, !recallInFlight, !hardwareWritesSuspended,
                  !usesTwoUnitReplay else { break }
        }
        guard device === tb else { return }
        switch outcome {
        case .complete:
            cardOutputTableReplayNeeded = false
            cardOutputRetryAttempts = 0
            cardOutputRetryAfter = .distantPast
        case .superseded:
            // Tried again on the next health cycle (or when the recall ends).
            cardOutputRetryAfter = .distantPast
        case .waiting(let why), .failed(let why):
            cardOutputRetryAttempts += 1
            let wait = Self.restoreRetryPause(cardOutputRetryAttempts)
            cardOutputRetryAfter = Date().addingTimeInterval(wait)
            print("[Maestro] syncOutputRouting: restore not complete (\(why)); no mixer is routed that is not written, retry in \(Int(wait)) s")
        }
    }

    @MainActor
    private func runCardRestore(_ tb: ThunderboltDeviceConnection) async -> CardRestoreOutcome {
        let ledger = tb.cardMixers
        let deferral = replayDeferral
        let recallEpoch = deferral.currentEpoch()
        guard !deferral.isInFlight() else { return .superseded }
        // The driver state now serving; a change drops the ledger's marks.
        _ = await Task.detached(priority: .utility) { tb.linkState() }.value
        guard device === tb, !hardwareWritesSuspended else { return .superseded }
        let layout = cardLayout
        let storageKey = mixerPreferences.storageKey
        // Marks made from another unit's or account's saved state are not
        // marks for this one.
        let owner = CardRestoreOwner(storageKey: storageKey, layout: layout)
        if let known = cardRestoreOwner, known.connection == ObjectIdentifier(tb), known.owner != owner {
            ledger.clear()
        }
        cardRestoreOwner = (ObjectIdentifier(tb), owner)
        func isCurrent() -> Bool {
            device === tb && !hardwareWritesSuspended && cardLayout == layout && connectedUnit == nil
                && !usesTwoUnitReplay && mixerPreferences.storageKey == storageKey
                && deferral.isValid(recallEpoch)
        }
        // 1. Nothing can be read: write nothing at first, then the direct
        //    defaults (see above and `cardRestoreStillBlocked`).
        if let reason = cardTableUnreadableReason() {
            await cardRestoreStillBlocked(tb)
            return .waiting(reason)
        }
        cardBlockedChecks = 0
        let mixersAvailable = mixerPreferences.isWritable
        let epoch = ledger.epoch
        let editsAtStart = outputRouteEdits
        let destinations = thunderboltOutputTable(for: tb).keys.sorted()
        ledger.declareTable(channels: Set(destinations.compactMap(ThunderboltCardRouting.channel(forDestination:))))
        var sent: [UInt8: UInt8] = [:]
        /// Sends what the table says for this destination now. A mixer that
        /// is not marked written is never routed: the destination is disabled.
        func route(_ destination: UInt8, only mixer: Int? = nil) async -> CardRestoreOutcome? {
            guard isCurrent() else { return .superseded }
            guard let saved = thunderboltOutputTable(for: tb, quiet: true)[destination] else { return nil }
            let fedBy = CardOutputTableOrder.mixer(ofSource: saved)
            if let mixer, fedBy != mixer { return nil }
            let source = fedBy.map { mixersAvailable && ledger.isWritten($0) } == false
                ? SymphonyIORoutingAddress.none : saved
            if sent[destination] == source { return nil }
            do {
                guard try await writeOutputRoute(destination: destination, source: source, device: tb,
                                                 restoring: true) == .written else {
                    return .failed("the driver state changed during the write")
                }
            } catch {
                return .failed("output \(destination) ← source \(source): \(error)")
            }
            sent[destination] = source
            return nil
        }
        // 2. Direct routes, and every mixer-fed destination whose mixer is
        //    not written disabled.
        for destination in destinations {
            if let stop = await route(destination) { return stop }
        }
        guard mixersAvailable else { return .waiting("saved mixer state is not available for this unit") }
        // Deferrals up to here are in the stores the mixers are read from next.
        let owed = ledger.owed
        // 3 and 4. The mixers that feed something first.
        let table = thunderboltOutputTable(for: tb, quiet: true)
        let feeding = Set(table.values.compactMap(CardOutputTableOrder.mixer(ofSource:)))
        for mixer in feeding.sorted() + (0..<2).filter({ !feeding.contains($0) }) {
            if let stop = await writeCompleteCardMixer(mixer, tb: tb, layout: layout, isCurrent: isCurrent,
                                                       recallEpoch: recallEpoch) { return stop }
            for destination in destinations {
                if let stop = await route(destination, only: mixer) { return stop }
            }
        }
        // A recovery, card re-init or driver restart during the run means
        // the driver may have re-programmed the card under it (the read lets
        // the ledger see it).
        let after = await Task.detached(priority: .utility) { tb.linkState() }.value
        // 5. Anything saved since the run started: the stores win. No
        //    suspension between this check and the record below.
        guard isCurrent() else { return .superseded }
        let final = thunderboltOutputTable(for: tb, quiet: true)
        guard outputRouteEdits == editsAtStart, final.keys.sorted() == destinations,
              final.allSatisfy({ sent[$0.key] == $0.value }) else { return .superseded }
        guard ledger.completeRestore(epoch: epoch, covering: owed) else {
            return .failed("the driver state changed during the write")
        }
        // Both mixers are on the card in full: D5 has nothing left to do on
        // this driver instance, and the reset's defaults have landed.
        observeCardMixerInstance(after)
        cardMixerLedger.complete()
        RoutingMixerReset.clearPending(.thunderboltCardMixer)
        cardMixerLedger.restoresHeldMixers = false
        print("[Maestro] syncOutputRouting: \(sent.count) output routes and both card mixers written; mixer-fed outputs routed after their mixer")
        return .complete
    }

    /// One card mixer in full, from the store as it is when the write starts.
    /// An edit during the write starts it again from the store (the edit has
    /// been saved); a recall stops it.
    @MainActor
    private func writeCompleteCardMixer(_ mixer: Int, tb: ThunderboltDeviceConnection, layout: CardLayout,
                                        isCurrent: () -> Bool, recallEpoch: UInt64) async -> CardRestoreOutcome? {
        let edits = tb.mixerEdits
        let deferral = replayDeferral
        let gap = cardMixerCommandGap
        for attempt in 0..<CardMixerReplay.maxAttempts {
            if attempt > 0 { try? await Task.sleep(for: cardMixerEditQuietWindow) }
            guard isCurrent() else { return .superseded }
            let generation = edits.capture()
            let routesA = thunderboltCaptureRoutes(unit: .a)
            let routesB = unitBOnCard ? thunderboltCaptureRoutes(unit: .b) : nil
            let plan = CardMixerReplay.plan(mixers: [mixer], layout: layout, store: channelStateStore,
                                            preferences: mixerPreferences,
                                            complete: true,
                                            routes: routesA).first ?? []
            do {
                let result = try await Task.detached(priority: .utility) {
                    try await tb.writeCompleteCardMixer(mixer, writes: plan, layout: layout,
                        routes: routesA, secondRoutes: routesB,
                        shouldContinue: {
                        edits.isCurrent(generation) && deferral.isValid(recallEpoch)
                    }, gap: gap)
                }.value
                guard result == .written else { return .failed("card mixer \(mixer + 1) may still be on an output") }
                return nil
            } catch {
                guard isCurrent() else { return .superseded }
                if edits.isCurrent(generation) { return .failed("card mixer \(mixer + 1): \(error)") }
            }
        }
        // Edits keep arriving; the run is tried again on the next cycle.
        return .superseded
    }

    /// A healthy health-loop cycle. Whatever is owed (a restore not completed
    /// for the driver state now serving, a deferred or failed route or mixer
    /// write, a recall's follow-up) is tried again, with a growing pause
    /// between failed attempts, until it is done or the connection ends.
    /// Nothing owed is ever dropped: the ledger keeps the count and the
    /// stores keep the values.
    @MainActor
    func serviceCardOutputTable(_ tb: ThunderboltDeviceConnection) async {
        guard device === tb, connectionMode == .hardware else { return }
        // Converters: their own routes; the Symphony I/O rule does not apply.
        tb.cardMixers.isBypassed = converterRoutingSurface
        updateRestoreStatus()
        guard !hardwareWritesSuspended, !converterRoutingSurface else { return }
        guard cardOutputTableReplayNeeded || tb.cardMixers.needsRestore,
              !recallInFlight, !cardOutputRestoreRunning else { return }
        if usesTwoUnitReplay {
            // The two-unit replay writes the table and the mixers in the same
            // order through the same chokepoint (`finishTwoUnitReplay`).
            twoUnitReplayNeeded = true
            // It does not run while a unit's cards or identity are unread;
            // the same bounded wait, then the direct defaults.
            if cardTableUnreadableReason() != nil, Date() >= cardOutputRetryAfter {
                cardOutputRetryAttempts += 1
                cardOutputRetryAfter = Date().addingTimeInterval(Self.restoreRetryPause(cardOutputRetryAttempts))
                await cardRestoreStillBlocked(tb)
            } else if cardTableUnreadableReason() == nil {
                cardBlockedChecks = 0
            }
            return
        }
        guard Date() >= cardOutputRetryAfter else { return }
        await syncOutputRoutingToHardware()
    }

    /// A two-unit replay ran to the end: the tables, the whole output table
    /// and both mixers are on the card. Only now are the reset's pending
    /// flags consumed.
    @MainActor
    func finishTwoUnitReplay(_ plan: TwoUnitReplay, tb: ThunderboltDeviceConnection,
                             epoch: UInt64, owed: UInt64, routeEdits: UInt64) {
        guard tb.cardMixers.completeRestore(epoch: epoch, covering: owed), outputRouteEdits == routeEdits else {
            // The driver state moved on, or a route was edited under the
            // plan: at once for an edit, otherwise with the growing pause.
            twoUnitReplayNeeded = true
            if outputRouteEdits == routeEdits { twoUnitReplayDidNotComplete() }
            return
        }
        twoUnitRetryAttempts = 0
        twoUnitRetryAfter = .distantPast
        twoUnitResetDefaultsSent = nil
        cardBlockedChecks = 0
        if plan.consumesRoutingReset {
            RoutingMixerReset.clearPending(.thunderboltInputRouting)
            RoutingMixerReset.clearPending(.thunderboltCardMixer)
            cardMixerLedger.restoresHeldMixers = false
        }
        cardOutputTableReplayNeeded = false
        // Something deferred or failed while the replay ran is not in its plan.
        if tb.cardMixers.needsRestore { twoUnitReplayNeeded = true }
        updateRestoreStatus()
    }

    /// A 64-channel replay was refused or did not complete: the next one
    /// waits, as the single-unit restore does (`restoreRetryPause`), instead
    /// of running again on every health cycle.
    @MainActor
    func twoUnitReplayDidNotComplete() {
        twoUnitRetryAttempts += 1
        let wait = Self.restoreRetryPause(twoUnitRetryAttempts)
        twoUnitRetryAfter = Date().addingTimeInterval(wait)
        print("[Maestro] Two-unit replay not complete; retry in \(Int(wait)) s")
    }

    /// A recall or reset failed partway: the unit may differ from what is
    /// saved and shown. No output stays on a card mixer (the connection
    /// disables them and drops the marks), and the restore puts the saved
    /// routing and mixers back.
    @MainActor
    func recoverFromFailedRecall(_ tb: ThunderboltDeviceConnection) async {
        await Task.detached(priority: .utility) { tb.quarantineCardMixers() }.value
        guard device === tb else { return }
        cardOutputTableReplayNeeded = true
        cardOutputRetryAfter = .distantPast
        inputRoutingReplayNeeded = true
        twoUnitRetryAfter = .distantPast
        if usesTwoUnitReplay { twoUnitReplayNeeded = true }
        updateRestoreStatus()
    }

    /// The status line while routing or mixer state saved on this Mac is not
    /// on the unit yet (both transports); nil when everything is.
    @MainActor
    func updateRestoreStatus() {
        var note: String?
        if connectionMode == .hardware, !hardwareWritesSuspended, connectedUnit == nil, !converterRoutingSurface {
            if let tb = device as? ThunderboltDeviceConnection, transportType == .thunderbolt {
                if cardOutputTableReplayNeeded || tb.cardMixers.needsRestore
                    || (usesTwoUnitReplay && twoUnitReplayNeeded) {
                    note = cardRestoreBlockedReason() == nil ? PortStatusMessage.restoringMixerAndRouting
                        : PortStatusMessage.mixerWaitsForIdentity
                }
            } else if device is XPCDeviceConnection, usbHelperOutdated {
                note = PortStatusMessage.usbHelperOutdated
            } else if device is XPCDeviceConnection, usbRestoreOwed || usbRestoreTask != nil {
                note = unitAIdentityState == .pending || !mixerPreferences.isWritable
                    ? PortStatusMessage.mixerWaitsForIdentity : PortStatusMessage.restoringMixerAndRouting
            }
        }
        if restoreStatusNote != note { restoreStatusNote = note }
    }
}

/// Whose saved state the card mixers were written from.
struct CardRestoreOwner: Equatable {
    let storageKey: String?
    let layout: CardLayout
}
