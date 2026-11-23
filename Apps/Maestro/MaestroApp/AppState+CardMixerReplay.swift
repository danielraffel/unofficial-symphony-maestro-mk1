import Foundation
import MaestroCore
import MaestroDevice

extension AppState {
    /// Input routing changes the receive slots under the card mixer. Rebuild
    /// both mixers immediately after a successful route write. A driver
    /// in-place recovery with non-default routing can still expose defaults
    /// until this replay runs, which only a driver change could eliminate.
    @MainActor
    func thunderboltInputRoutingDidChange(previousRoutes: [DeviceUnit: [ThunderboltInputMeterMap.Route]] = [:]) {
        thunderboltInputRoutingWritten = true
        if let tb = device as? ThunderboltDeviceConnection {
            let layouts: [(DeviceUnit, CardLayout?, [ThunderboltInputMeterMap.Route]?)] = [
                (.a, cardLayout, previousRoutes[.a]),
                (.b, unitBOnCard ? unitBLayout : nil, previousRoutes[.b]),
            ]
            let repairs = layouts.flatMap { unit, layout, oldRoutes -> [ThunderboltPreset.Write] in
                guard let layout, let oldRoutes else { return [] }
                let oldIDs = Set(ThunderboltInputMeterMap.mixerInputs(layout: layout, routes: oldRoutes).compactMap { $0 })
                let newIDs = Set(ThunderboltInputMeterMap.mixerInputs(layout: layout, routes: thunderboltCaptureRoutes(unit: unit)).compactMap { $0 })
                let offset = unit == .b ? 32 : 0
                return CardMixerReplay.unroutedWrites(mixer: 0, inputIDs: oldIDs.subtracting(newIDs).map { $0 + offset })
                    + CardMixerReplay.unroutedWrites(mixer: 1, inputIDs: oldIDs.subtracting(newIDs).map { $0 + offset })
            }
            if !repairs.isEmpty {
                Task.detached(priority: .userInitiated) {
                    try? await tb.writeCardMixerEdits(repairs, shouldContinue: { tb.isConnected })
                }
            }
        }
        thunderboltCaptureTableDidChange()
    }

    /// What arrives on the card's receive slots has changed (an Input
    /// Routing write, the connect-time replay landing or failing), so each
    /// Mixer strip's card input may have moved. The mixers are written again
    /// in full by the restore that already serves a recall's follow-up: the
    /// connection's ledger counts what is owed, and a run only covers what
    /// was owed when it began, so a second change during a run is followed by
    /// another run and none is lost. The mixers stay marked written, so no
    /// output fed from a mixer is switched off meanwhile. It also works after
    /// a link recovery or card re-init, which the Mixer page's own one-time
    /// restore does not follow.
    @MainActor
    func thunderboltCaptureTableDidChange() {
        invalidateThunderboltInputMeterMap()
        if usesTwoUnitReplay {
            twoUnitReplayNeeded = true
            Task { await replayUnitBSettings() }
            return
        }
        guard let tb = device as? ThunderboltDeviceConnection else { return }
        tb.cardMixers.noteOwed()
        Task { await serviceCardOutputTable(tb) }
    }

    /// D5: restore the saved card mixer once on a driver instance that holds no
    /// app mixer state (a fresh dext), even if the Mixer page is never opened.
    /// Launch and reconnect call this after the ThunderBridge health check has
    /// started; identity resolving later calls it again. It only starts a
    /// stored task and returns: nothing in either pipeline waits for it.
    ///
    /// "Fresh" comes from the driver (the 52-word link-state read,
    /// `DriverMixerInstance`), not from a new Swift connection object: an
    /// in-place recovery keeps the driver's state and its flags, so it is never
    /// followed by a restore. A driver without that report gets no restore.
    /// The original's restore was card registers only:
    /// og_source/maestrolink/Software/SymphonyPCIeCardMixer.cpp:1479-1604,1750-1755.
    @MainActor
    func syncCardMixerToHardware() {
        guard let tb = device as? ThunderboltDeviceConnection else { return }
        // Once after the routing and mixer reset: both mixers are written in
        // full even if the driver holds app state, because that state is what
        // the reset removed from this Mac (the driver kept running).
        cardMixerLedger.restoresHeldMixers = cardMixerLedger.restoresHeldMixers
            || RoutingMixerReset.isPending(.thunderboltCardMixer)
        cardMixerRestoreRequested = true
        if let run = cardMixerRestoreRun, run.connection === tb { return }
        cancelCardMixerRestore()
        guard cardMixerRestoreEligible(tb) else {
            // Re-armed when unit A's identity resolves (pending now, or a
            // failed read retried after a recovery); eligibility is checked again.
            cardMixerRestoreAwaitingIdentity = unitAIdentity == nil
            return
        }
        cardMixerRestoreAwaitingIdentity = false
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await CardMixerRestoreRunner.run(self.cardMixerRestoreEnvironment(tb))
            print("[Maestro] D5 card mixer restore: \(outcome)")
            if case .restored = outcome {
                self.refreshSoftwareReturnMeterGains()
                if self.cardMixerLedger.restoresHeldMixers {
                    RoutingMixerReset.clearPending(.thunderboltCardMixer)
                    self.cardMixerLedger.restoresHeldMixers = false
                }
            }
            if self.cardMixerRestoreRun?.token == token {
                self.cardMixerRestoreRun = nil
                self.cardMixerLedger.endAttempt()
            }
        }
        cardMixerRestoreRun = CardMixerRestoreRun(token: token, connection: tb, task: task)
    }

    /// Disconnect, replacement, or a link drop seen by the health loop.
    @MainActor
    func cancelCardMixerRestore() {
        guard let run = cardMixerRestoreRun else { return }
        run.task.cancel()
        cardMixerRestoreRun = nil
        cardMixerLedger.endAttempt()
    }

    /// Identity resolved after launch or reconnect asked for the restore.
    @MainActor
    func rearmCardMixerRestoreAfterIdentity() {
        guard cardMixerRestoreAwaitingIdentity else { return }
        syncCardMixerToHardware()
    }

    /// A healthy health-loop cycle: start another run if launch or reconnect
    /// asked for the restore, none is running, and the ledger still has it
    /// pending (a run that ended not ready, unstable without a recovery,
    /// superseded or failed). The ledger still refuses after an in-place
    /// recovery, and `CardMixerReplay.maxAttempts` bounds the runs.
    @MainActor
    func rearmCardMixerRestoreIfPending() {
        guard cardMixerRestoreRequested, cardMixerRestoreRun == nil, cardMixerLedger.isPending,
              let tb = device as? ThunderboltDeviceConnection, cardMixerRestoreEligible(tb) else { return }
        syncCardMixerToHardware()
    }

    /// Latch a driver instance as soon as it is seen, so an edit made before
    /// the restore task runs cannot hide that the driver started empty.
    @MainActor
    func observeCardMixerInstance(_ link: LinkState?) {
        cardMixerLedger.observe(link)
    }

    /// The Mixer page's recall-time sync leaves a mixer to D5 when D5 owns it
    /// on the serving driver instance (see `CardMixerRestoreLedger.pageDefersSync`).
    @MainActor
    func mixerPageDefersToCardMixerRestore(mixer: Int) async -> Bool {
        guard let tb = device as? ThunderboltDeviceConnection else { return false }
        // The restore writes both mixers in full and is not done yet: a
        // partial copy from the page would only interrupt it.
        if tb.cardMixers.needsRestore { return true }
        let link = await Task.detached(priority: .utility) { tb.linkState() }.value
        guard device === tb else { return true }
        observeCardMixerInstance(link)
        return cardMixerLedger.pageDefersSync(mixer: mixer, instance: link?.mixerInstance,
                                              eligible: cardMixerRestoreEligible(tb))
    }

    @MainActor
    private func cardMixerRestoreEligible(_ tb: ThunderboltDeviceConnection) -> Bool {
        // Not before the restore has completed (it writes both mixers in
        // full and then marks this restore complete, so in practice D5 has
        // nothing left to do on a driver the restore has run on).
        device === tb && !tb.cardMixers.needsRestore && !twoUnitSleeping && !usesTwoUnitReplay
            && connectionMode == .hardware && isHardwareInitialized
            && unitAIdentity != nil && connectedUnit == nil && converterSystem == nil
            && mixerPreferences.isWritable
            && portSelection.selection?.channelCount != 64
            && RoutingResetGuard.refusalReason(board1: primaryBoardReading, board2: secondaryBoardReading) == nil
    }

    @MainActor
    private func cardMixerRestoreEnvironment(_ tb: ThunderboltDeviceConnection) -> CardMixerRestoreRunner.Environment {
        let deferral = replayDeferral
        let edits = tb.mixerEdits
        let layout = cardLayout
        let preferencesKey = mixerPreferences.storageKey
        let ledger = { [weak self] in self?.cardMixerLedger.nonce }
        return CardMixerRestoreRunner.Environment(
            readLink: { await Task.detached(priority: .utility) { tb.linkState() }.value },
            sleep: { try await Task.sleep(for: $0) },
            decide: { [weak self] link in self?.cardMixerLedger.decide(link) ?? .unsupported },
            complete: { [weak self] in self?.cardMixerLedger.complete() },
            giveUp: { [weak self] in self?.cardMixerLedger.giveUp() },
            isCurrent: { [weak self] in
                guard let self else { return false }
                return self.cardMixerRestoreEligible(tb) && self.cardLayout == layout
                    && self.mixerPreferences.storageKey == preferencesKey
            },
            recallInFlight: { deferral.isInFlight() },
            epoch: { deferral.currentEpoch() },
            epochValid: { deferral.isValid($0) },
            editGeneration: { edits.capture() },
            beginAttempt: { [weak self] in self?.cardMixerLedger.beginAttempt() ?? false },
            plan: { [weak self] mixers in
                guard let self else { return [] }
                return CardMixerReplay.plan(mixers: mixers, layout: layout, store: self.channelStateStore,
                                            preferences: self.mixerPreferences,
                                            complete: self.cardMixerLedger.restoresHeldMixers,
                                            routes: self.thunderboltCaptureRoutes(unit: .a),
                                            pairCount: self.softwareReturnPairCount)
            },
            replay: { plan, recovery, epoch, generation, progress in
                let started = Date()
                guard let nonce = ledger() else { throw DeviceConnectionError.notConnected }
                let transaction = Task.detached(priority: .utility) {
                    try await tb.replayCardMixer(plan, layout: layout, recoveryCount: recovery, nonce: nonce,
                        shouldContinue: { deferral.isValid(epoch) && edits.isCurrent(generation) },
                        progress: progress)
                }
                try await withTaskCancellationHandler {
                    try await transaction.value
                } onCancel: {
                    transaction.cancel()
                }
                print(String(format: "[Maestro] D5 card mixer replay: %d commands, %d card register writes, %.3f s",
                             CardMixerReplay.commandCount(plan), CardMixerReplay.registerWrites(plan),
                             Date().timeIntervalSince(started)))
            })
    }
}

/// The stored D5 task and the connection it was started for.
struct CardMixerRestoreRun {
    let token: UUID
    let connection: ThunderboltDeviceConnection
    let task: Task<Void, Never>
}
