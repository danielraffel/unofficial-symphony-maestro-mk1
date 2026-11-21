import Foundation
import MaestroCore
import MaestroDevice

extension AppState {
    /// The whole ThunderBridge output table for one Symphony I/O: the default
    /// (every output direct, no mixer routed, as the original's
    /// SymphonyPCIeRoutingController::ResetRouting, output branch) with the
    /// saved choices over it. Never only the saved rows: the driver starts the
    /// card with the main pair on card mixer 1 and keeps the routes an earlier
    /// session wrote. A saved source the card cannot play is left out (and
    /// said once here) rather than failing the table for good.
    @MainActor
    func thunderboltOutputTable(for device: any DeviceConnection) -> [UInt8: UInt8] {
        let routes = peripheralRoutingCache(direction: "output").loadMulti() ?? [:]
        let defaults = SymphonyIODefaultRouting.thunderboltOutputRoutes(
            board0Outputs: primaryBoardType.totalOutputChannels,
            board1Outputs: secondaryBoardType.totalOutputChannels)
            .filter { $0.source != SymphonyIORoutingAddress.none }
        let rowCount = device.identifier.mode.channelCount / 2 + 2
        let table = Self.replayOutputSources(
            defaults: Dictionary(uniqueKeysWithValues: defaults.map { ($0.destination, $0.source) }),
            saved: cachedOutputRouteMap(),
            complete: (0..<rowCount).allSatisfy { routes[$0] != nil },
            destinations: defaults.map(\.destination))
        return table.filter { destination, source in
            let playable = ThunderboltCardRouting.route(destination: destination, source: source,
                                                        unitBActive: unitBOnCard) != nil
            if !playable {
                print("[Maestro] syncOutputRouting: output \(destination) ← source \(source) has no card route; left out")
            }
            return playable
        }
    }

    /// The table counts as unwritten from here on, and card mixer writes wait.
    @MainActor
    func invalidateCardOutputTable(_ tb: ThunderboltDeviceConnection) {
        tb.cardMixerHold.hold()
        cardOutputLedger.invalidate()
        cardOutputTableReplayNeeded = true
        cardOutputRetryAttempts = 0
        cardOutputRetryAfter = .distantPast
    }

    /// Card mixer writes the hold refused on this connection that no full
    /// mixer write has covered yet.
    @MainActor
    func cardMixerOwesReplay(_ tb: ThunderboltDeviceConnection) -> Bool {
        let covered = cardMixerRefusedReplayed.flatMap { $0.connection == ObjectIdentifier(tb) ? $0.count : nil } ?? 0
        return tb.cardMixerHold.refusedCount > covered
    }

    @MainActor
    func markCardMixerReplayed(_ tb: ThunderboltDeviceConnection, upTo count: UInt64) {
        cardMixerRefusedReplayed = (ObjectIdentifier(tb), count)
    }

    /// The ordered restore for one Symphony I/O on ThunderBridge.
    ///
    /// The driver starts the card, and re-programs it after a reset, with the
    /// main pair on card mixer 1 and the mixer inputs muted. So the output
    /// table is written first: after its first phase no output carries a mixer
    /// through a route this run did not write (an output the saved table feeds
    /// from a mixer still to be written is silent until that mixer's strips
    /// are on the card). Then those mixers, in full; then their routes
    /// (`CardOutputTableOrder`). Until every write has succeeded, on the same
    /// driver state it started on, the table counts as unwritten: card mixer
    /// writes stay held (`CardMixerHold`), D5 and the Mixer page wait, and the
    /// health loop tries again.
    @MainActor
    func restoreThunderboltOutputTable(_ tb: ThunderboltDeviceConnection) async {
        guard !cardOutputRestoreRunning else { cardOutputTableReplayNeeded = true; return }
        cardOutputRestoreRunning = true
        defer { cardOutputRestoreRunning = false }
        tb.cardMixerHold.hold()
        cardOutputLedger.invalidate()
        cardOutputTableReplayNeeded = true
        func retryLater(_ why: String) {
            cardOutputRetryAttempts += 1
            let wait = min(30.0, pow(2.0, Double(min(cardOutputRetryAttempts, 5))))
            cardOutputRetryAfter = Date().addingTimeInterval(wait)
            print("[Maestro] syncOutputRouting: output table NOT written (\(why)); card mixer writes stay held, retry in \(Int(wait)) s")
        }
        // Symphony I/O routing only: nothing is sent to a unit that is not one.
        guard connectedUnit == nil else { return }
        // Replaying a cached table can target stale board destinations after a
        // card change: this session's card types must have been detected (the
        // provenance rule Reset Routing applies) before anything is written.
        if let reason = RoutingResetGuard.refusalReason(board1: primaryBoardReading, board2: secondaryBoardReading) {
            retryLater("cards not read this session: \(reason.prefix(80))")
            return
        }
        let link = await Task.detached(priority: .utility) { tb.linkState() }.value
        guard device === tb else { return }
        let instance = CardOutputTableLedger.Instance(link)
        let layout = cardLayout
        let preferences = mixerPreferences
        let refusedAtStart = tb.cardMixerHold.refusedCount
        // A mixer the driver already holds the app's state for needs no write
        // before its routes, unless the reset's defaults or a held-back edit
        // have not reached the card.
        let owed = cardMixerOwesReplay(tb)
        var ready: Set<Int> = []
        if !owed, !RoutingMixerReset.isPending(.thunderboltCardMixer),
           let flags = link?.mixerInstance?.holdsAppState {
            ready = Set((0..<2).filter { $0 < flags.count && flags[$0] })
        }
        var phases = CardOutputTableOrder.phases(table: thunderboltOutputTable(for: tb), readyMixers: ready)
        if owed { phases.mixers = [0, 1] }
        let store = channelStateStore
        let environment = CardOutputTableRestore.Environment(
            writeRoute: { [weak self] destination, source in
                guard let self else { throw DeviceConnectionError.notConnected }
                try await self.writeOutputRoute(destination: destination, source: source, device: tb,
                                                restoring: true)
            },
            writeMixers: { mixers in
                guard preferences.isWritable else {
                    throw DeviceConnectionError.transportError("saved mixer state is not available for this unit")
                }
                let plan = CardMixerReplay.plan(mixers: mixers, layout: layout, store: store,
                                                preferences: preferences, complete: true)
                try await Task.detached(priority: .utility) {
                    try await tb.writeCardMixers(plan, shouldContinue: { true })
                }.value
            },
            isCurrent: { [weak self] in
                guard let self else { return false }
                return self.device === tb && !self.hardwareWritesSuspended && self.cardLayout == layout
                    && self.connectedUnit == nil && !self.usesTwoUnitReplay
                    && self.mixerPreferences.storageKey == preferences.storageKey
            })
        let outcome = await CardOutputTableRestore.run(phases, environment)
        guard device === tb else { return }
        guard case .written(let count, let mixers) = outcome else {
            retryLater("\(outcome)")
            return
        }
        // A recovery, card re-init or driver restart during the run means the
        // driver may have re-programmed the card under it.
        let after = await Task.detached(priority: .utility) { tb.linkState() }.value
        guard device === tb, CardOutputTableLedger.Instance(after) == instance else {
            retryLater("the driver state changed during the write")
            return
        }
        cardOutputLedger.recordWritten(instance)
        cardOutputTableReplayNeeded = false
        cardOutputRetryAttempts = 0
        cardOutputRetryAfter = .distantPast
        if mixers == [0, 1] {
            markCardMixerReplayed(tb, upTo: refusedAtStart)
            // Both mixers are on the card in full: D5 has nothing left to do
            // on this driver instance, and the reset's defaults have landed.
            observeCardMixerInstance(after)
            cardMixerLedger.complete()
            RoutingMixerReset.clearPending(.thunderboltCardMixer)
            cardMixerLedger.restoresHeldMixers = false
        }
        tb.cardMixerHold.release()
        print("[Maestro] syncOutputRouting: wrote \(count) output route writes"
            + (mixers.isEmpty ? "" : ", card mixer(s) \(mixers.map { $0 + 1 }) before the routes they feed"))
        await replayHeldCardMixerEdits(tb)
    }

    /// Edits the hold refused (saved and shown by the Mixer page, not sent)
    /// reach the card now that the table is written: both mixers in full from
    /// the store. A live edit during the replay restarts it from the store.
    @MainActor
    func replayHeldCardMixerEdits(_ tb: ThunderboltDeviceConnection) async {
        guard cardMixerOwesReplay(tb), device === tb, !tb.cardMixerHold.isHeld else { return }
        if usesTwoUnitReplay { twoUnitReplayNeeded = true; return }
        let hold = tb.cardMixerHold
        let edits = tb.mixerEdits
        for attempt in 0..<CardMixerReplay.maxAttempts {
            if attempt > 0 { try? await Task.sleep(for: CardMixerReplay.quietWindow) }
            guard device === tb, !hold.isHeld, !usesTwoUnitReplay, mixerPreferences.isWritable else { return }
            let refused = hold.refusedCount
            let generation = edits.capture()
            let plan = CardMixerReplay.plan(mixers: [0, 1], layout: cardLayout, store: channelStateStore,
                                            preferences: mixerPreferences, complete: true)
            do {
                try await Task.detached(priority: .utility) {
                    try await tb.writeCardMixers(plan, shouldContinue: {
                        edits.isCurrent(generation) && !hold.isHeld
                    })
                }.value
                guard device === tb else { return }
                markCardMixerReplayed(tb, upTo: refused)
                print("[Maestro] Card mixers replayed after the output table: edits made while they were held are on the card")
                return
            } catch {
                print("[Maestro] Card mixer replay after the output table interrupted: \(error)")
            }
        }
    }

    /// A healthy health-loop cycle. The table is unwritten for the driver
    /// state now serving (a restart, a card re-init, a recovery, or a write
    /// that failed or was refused): hold the mixers and run the ordered
    /// restore again, with a growing pause between failed attempts.
    @MainActor
    func serviceCardOutputTable(_ tb: ThunderboltDeviceConnection) async {
        guard device === tb, connectionMode == .hardware, !hardwareWritesSuspended else { return }
        if converterRoutingSurface { tb.cardMixerHold.release(); return }
        if !cardOutputLedger.isWritten(on: tb.lastLinkState) {
            tb.cardMixerHold.hold()
            cardOutputTableReplayNeeded = true
        }
        guard cardOutputTableReplayNeeded, !recallInFlight, !cardOutputRestoreRunning else { return }
        if usesTwoUnitReplay {
            // The two-unit replay writes the table and the mixers in the same
            // order and records the result (`finishTwoUnitReplay`).
            twoUnitReplayNeeded = true
            return
        }
        guard Date() >= cardOutputRetryAfter else { return }
        await syncOutputRoutingToHardware()
    }

    /// A two-unit replay ran to the end: the tables, the whole output table
    /// and both mixers are on the card. Only now are the reset's pending flags
    /// consumed and held mixer writes let through.
    @MainActor
    func finishTwoUnitReplay(_ plan: TwoUnitReplay, tb: ThunderboltDeviceConnection,
                             link: LinkState, refusedAtPlan: UInt64) {
        if plan.consumesRoutingReset {
            RoutingMixerReset.clearPending(.thunderboltInputRouting)
            RoutingMixerReset.clearPending(.thunderboltCardMixer)
            cardMixerLedger.restoresHeldMixers = false
        }
        cardOutputLedger.recordWritten(CardOutputTableLedger.Instance(link))
        cardOutputTableReplayNeeded = false
        markCardMixerReplayed(tb, upTo: refusedAtPlan)
        tb.cardMixerHold.release()
        // An edit refused while the replay ran is not in its plan.
        if cardMixerOwesReplay(tb) { twoUnitReplayNeeded = true }
    }
}
