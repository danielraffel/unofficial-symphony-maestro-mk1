import Foundation
import MaestroCore
import MaestroDevice

final class ReplayDeferral: @unchecked Sendable {
    private let lock = NSLock()
    private var recallInFlight = false
    private var requestedDuringRecall = false
    private var epoch: UInt64 = 0

    func beginRecall() { lock.lock(); defer { lock.unlock() }; epoch &+= 1; recallInFlight = true }
    func request() {
        lock.lock(); defer { lock.unlock() }
        if recallInFlight { requestedDuringRecall = true }
    }
    func finishRecall() -> Bool {
        lock.lock(); defer { lock.unlock() }
        recallInFlight = false
        let requested = requestedDuringRecall
        requestedDuringRecall = false
        return requested
    }
    func currentEpoch() -> UInt64 { lock.lock(); defer { lock.unlock() }; return epoch }
    func isValid(_ captured: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return epoch == captured && !recallInFlight
    }
    func isInFlight() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return recallInFlight
    }
}

extension AppState {
    static func replayOutputSources(defaults: [UInt8: UInt8], saved: [UInt8: UInt8],
                                    complete: Bool, destinations: [UInt8]) -> [UInt8: UInt8] {
        var result = complete
            ? Dictionary(uniqueKeysWithValues: destinations.map { ($0, SymphonyIORoutingAddress.none) })
            : defaults
        for destination in destinations {
            if let source = saved[destination] { result[destination] = source }
        }
        return result
    }

    /// At 64 channels the health loop owns routing recall, including the
    /// initial connect. At 32 the existing single-unit path is unchanged.
    var usesTwoUnitReplay: Bool {
        // Only with a configured unit B: if 64 is selected but unit B never
        // finished its set-up, unit A's own replay must still run.
        transportType == .thunderbolt && connectedUnit == nil && converterSystem == nil
            && portSelection.selection == .ports1And2 && unitB != nil
    }

    @MainActor
    func replayUnitBSettings() async {
        guard usesTwoUnitReplay, twoUnitReplayNeeded, !twoUnitReplayRunning,
              !recallInFlight, Date() >= twoUnitRetryAfter,
              !twoUnitSleeping, connectionMode == .hardware, isHardwareInitialized,
              let tb = device as? ThunderboltDeviceConnection,
              let b = unitBDevice as? ThunderboltUnitBConnection,
              let layoutB = unitBLayout, unitBInputRoutingAllowed,
              RoutingResetGuard.refusalReason(board1: primaryBoardReading, board2: secondaryBoardReading) == nil,
              unitBBoardSource(slot: 0) == .detected, unitBBoardSource(slot: 1) == .detected else { return }
        twoUnitReplayRunning = true
        defer { twoUnitReplayRunning = false }
        let link = await Task.detached(priority: .utility) { tb.linkState() }.value
        let bGeneration = await Task.detached(priority: .utility) { tb.readUnitBState()?.generation }.value
        guard device === tb, unitBDevice === b, let link, let bGeneration else { return }
        applyPhantomObservations(link)
        // Deferred mixer edits and routes up to here are in the plan (it is
        // built from the stores). The connection sends the card's part in the
        // restore order and marks each mixer once all of it has landed. A
        // recall, or a mixer edit made after the plan was built, stops it;
        // it is then built again from the stores.
        tb.cardMixers.isBypassed = false
        let epoch = tb.cardMixers.epoch
        let owed = tb.cardMixers.owed
        let routeEdits = outputRouteEdits
        let edits = tb.mixerEdits
        let editGeneration = edits.capture()
        let plan = makeTwoUnitReplay(tb: tb, b: b, layoutB: layoutB)
        let progress = TwoUnitReplay.Progress(tables: plan.tables.count)
        let sendsResetDefaults = plan.consumesRoutingReset && !twoUnitResetDefaultsLanded(tb: tb, b: b)
        let replayDeferral = self.replayDeferral
        let recallEpoch = replayDeferral.currentEpoch()
        twoUnitReplayNeeded = false
        do {
            try await Task.detached(priority: .utility) {
                try tb.replayTwoUnits(plan, unitB: b, recoveryCount: link.recoveryCount,
                                      unitBGeneration: bGeneration,
                                      shouldContinue: {
                                          replayDeferral.isValid(recallEpoch) && edits.isCurrent(editGeneration)
                                      }, progress: progress)
            }.value
            guard device === tb, unitBDevice === b else { return }
            finishTwoUnitReplay(plan, tb: tb, epoch: epoch, owed: owed, routeEdits: routeEdits)
            if let mode = tb.settingsStore.value(for: PropertyAddress(selector: .speakerOutputMode))?.asUInt32 {
                speakerOutputMode = mode
            }
            refreshUnitBNamingFromSaved()
            invalidateThunderboltInputMeterMap()
            symphonyCardInputNamingRevision += 1
            symphonyCardInputEdits = symphonyCardInputStore?.load() ?? [:]
            await refreshChannelNaming()
            print("[Maestro] Two-unit routing, mixers and headphones restored")
        } catch {
            guard device === tb, unitBDevice === b else { return }
            // The reset's default tables and card-input reset reached the
            // hardware before the failure: the retries do not send them again
            // (the saved tables over them are sent each time).
            if sendsResetDefaults, progress.resetDefaultsLanded {
                twoUnitResetDefaultsSent = (ObjectIdentifier(tb), ObjectIdentifier(b))
            }
            // Retried by the health loop with a growing pause, at once when
            // a recall or a mixer edit stopped it (those are saved, and the
            // next plan is built from them).
            twoUnitReplayNeeded = true
            if replayDeferral.isValid(recallEpoch), edits.isCurrent(editGeneration) {
                twoUnitReplayDidNotComplete()
            }
            updateRestoreStatus()
            print("[Maestro] Two-unit replay refused: \(error)")
        }
    }

    /// Whether the reset's default input tables and card-input reset have
    /// already reached these two connections in a replay that failed later.
    func twoUnitResetDefaultsLanded(tb: ThunderboltDeviceConnection, b: ThunderboltUnitBConnection) -> Bool {
        twoUnitResetDefaultsSent.map { $0.a == ObjectIdentifier(tb) && $0.b == ObjectIdentifier(b) } ?? false
    }

    /// Capture saved values on the main actor; all hardware work uses the
    /// immutable plan on the connection's serial owner off the main actor.
    func makeTwoUnitReplay(tb: ThunderboltDeviceConnection, b: ThunderboltUnitBConnection,
                           layoutB: CardLayout) -> TwoUnitReplay {
        var plan = TwoUnitReplay()
        plan.unitBBoards = [layoutB.slot1.rawValue, layoutB.slot2.rawValue]
        plan.mixerLayouts = (cardLayout, layoutB)
        let cacheA = peripheralRoutingCache(direction: "input")
        _ = ThunderboltInputRoutingMigration.run(routingKey: cacheA.key)
        // After the routing and mixer reset the default tables go first (a
        // driver that kept running still has the units on the removed
        // routes), and the card's own input routes go back to straight
        // through (their saved copy is gone too). The flag is cleared when
        // this plan has run to the end (`finishTwoUnitReplay`); it used to be
        // cleared by the single-unit replay only, so at 64 channels the
        // default tables were written before the saved ones on every replay.
        let resetPending = RoutingMixerReset.isPending(.thunderboltInputRouting)
        let cardInputReset = symphonyCardInputs.resetCommand
        plan.consumesRoutingReset = resetPending
            && (symphonyCardInputs.channelCount == 0 || cardInputReset != nil)
        // Once they have landed on these connections they are not sent again
        // by a retry of a replay that failed later on (they were sent before
        // the saved tables on every retry while the flag stayed pending).
        let sendDefaults = resetPending && !twoUnitResetDefaultsLanded(tb: tb, b: b)
        if sendDefaults, let cardInputReset { plan.card.append(.card(.cardInput(cardInputReset))) }
        for (unit, layout, cache) in [(DeviceUnit.a, cardLayout, Optional(cacheA)), (.b, layoutB, unitBInputRoutingCache)] {
            var writes = sendDefaults
                ? SymphonyIODefaultRouting.thunderboltInputRoutes(
                    slot1: unit == .a ? thunderboltCaptureSlot1 : unitB?.slot1)
                : []
            writes += InputRoutingReplay.writes(saved: cache?.load() ?? [:],
                                                columns: layout.inputRoutingColumns, pairCount: 16)
            for write in writes {
                plan.tables.append(.unit(unit, PropertyAddress(selector: .routing, scope: .input,
                                                              element: UInt32(write.destination)),
                                         .uint32(UInt32(write.source))))
            }
        }
        for command in symphonyCardInputs.commands(edits: symphonyCardInputStore?.load() ?? [:]) {
            plan.card.append(.card(.cardInput(command)))
        }
        let outputCache = peripheralRoutingCache(direction: "output")
        let savedA = outputCache.loadMulti() ?? [:]
        let completeA = (0..<TwoUnitOutputRouting.rowCount).allSatisfy { savedA[$0] != nil }
        let defaultsA = SymphonyIODefaultRouting.thunderboltOutputRoutes(
            board0Outputs: primaryBoardType.totalOutputChannels,
            board1Outputs: secondaryBoardType.totalOutputChannels)
        let defaultSourcesA = Dictionary(uniqueKeysWithValues: defaultsA.map { ($0.destination, $0.source) })
        // Always the whole table, with nothing saved too: the driver starts the
        // card with the main pair on card mixer 1 and keeps an earlier
        // session's routes, and the default is every output direct
        // (see syncOutputRoutingToHardware).
        do {
            let sources = cachedOutputRouteMap()
            let destinations = cardLayout.outputRoutingColumns.flatMap { [$0.routingByte, $0.routingByte &+ 1] }
            let merged = Self.replayOutputSources(defaults: defaultSourcesA, saved: sources,
                                                  complete: completeA, destinations: destinations)
            for destination in destinations {
                    let source = merged[destination] ?? SymphonyIORoutingAddress.none
                    if let route = ThunderboltCardRouting.route(destination: destination, source: source, unitBActive: true) {
                        plan.card.append(.card(.output(route)))
                    }
            }
        }
        do {
            let rows = unitBOutputRoutingCache?.loadMulti() ?? [:]
            let resolved = TwoUnitOutputRouting.resolvedRows(saved: rows, columns: layoutB.outputRoutingColumns)
            for (index, column) in layoutB.outputRoutingColumns.enumerated() {
                if let owner = rows.keys.sorted().last(where: { rows[$0]?.contains(index) == true }),
                   !(0..<TwoUnitOutputRouting.rowCount).contains(owner) { continue }
                let row = resolved[index]
                if let routes = Self.unitBRoutePair(destLeft: column.routingByte, gridRow: row) {
                    plan.card += routes.map { .card(.output($0)) }
                }
            }
        }
        // Card coefficients and return selection must recover with pages closed.
        // og_source/maestrolink/Software/SymphonyCard.cpp:1031-1044.
        for mixer in 0..<2 {
            let a = MixerStateSnapshot(channelCount: cardLayout.mixerChannels.count, mixer: mixer, store: channelStateStore, preferences: mixerPreferences)
            let b = MixerStateSnapshot(channelCount: layoutB.mixerChannels.count, mixer: mixer, store: unitBChannelStateStore)
            // The whole mixer, in the order of `CardMixerReplay.writes`
            // (Master, Software Return, then strips with level and pan
            // before mute and solo).
            plan.card += CardMixerReplay.writes(mixer: mixer, layout: cardLayout, snapshot: a,
                                                second: (layoutB, b)).map { .card($0) }
        }
        // The connection orders these when it runs the plan: every route
        // first with one fed by a mixer it has not seen written disabled,
        // then the mixers, then those routes (`replayTwoUnits`).
        // Keep B5's departure: B monitor settings are read, never host-replayed.
        for (unit, store) in [(DeviceUnit.a, tb.settingsStore), (.b, b.settingsStore)] {
            for entry in store.entries() {
                if unit == .b && ThunderboltUnitBConnection.monitorSelectors.contains(entry.address.selector) { continue }
                plan.settings.append(.unit(unit, entry.address, entry.value))
            }
        }
        // MicPre replay shares this transaction owner and the per-unit F2 identity.
        for (unit, layout, store, digital) in [
            (DeviceUnit.a, cardLayout, channelStateStore, rememberedDigitalSettings),
            (.b, layoutB, unitBChannelStateStore, unitBDigitalSettings)
        ] {
            let inputs: [InputChannelState] = store.load(ChannelStateStore.inputKey) ?? []
            let outputs: [OutputChannelState] = store.load(ChannelStateStore.outputKey) ?? []
            for (index, state) in inputs.prefix(layout.analogInputStripCount).enumerated() {
                let level = AnalogInputLevel(rawValue: state.inputType) ?? .plus4dBu
                if !level.isPreampLevel && !(layout.slot2 == .micPre8 && index < 8) {
                    plan.settings.append(.unit(unit, PropertyAddress(selector: .analogIOType, scope: .input, element: UInt32(index)),
                                               .uint32(InputChannelLogic.analogIOTypeWithTrim(level: level, trim: state.trim))))
                }
                plan.settings.append(.unit(unit, PropertyAddress(selector: .digitalRefLevel, scope: .input, element: UInt32(index)), .uint32(state.digitalRefLevel)))
                let softLimit = InputChannelLogic.coerceSoftLimit(state.softLimit, card: layout.cardForAnalogInputStrip(index))
                plan.settings.append(.unit(unit, PropertyAddress(selector: .softLimit, scope: .input, element: UInt32(index)), .uint32(softLimit)))
            }
            for write in MicPreSettingsReplay.writes(inputs: inputs, layout: layout, identity: store.identity) {
                if case .property(let address, let value) = write {
                    plan.settings.append(.unit(unit, address, value))
                }
            }
            for (index, state) in outputs.prefix(layout.analogOutputStripCount).enumerated() {
                let trim = UInt32(UInt8(bitPattern: Int8(clamping: Int((state.trim * 10).rounded()))))
                plan.settings.append(.unit(unit, PropertyAddress(selector: .analogIOType, scope: .output, element: UInt32(index)), .uint32(trim << 8 | state.analogRefLevel)))
                plan.settings.append(.unit(unit, PropertyAddress(selector: .digitalRefLevel, scope: .output, element: UInt32(index)), .uint32(state.digitalRefLevel)))
            }
            for write in digital.writes(layout: layout) {
                plan.settings.append(.unit(unit, write.address, .uint32(write.value)))
            }
        }
        return plan
    }

    /// Suspend every app-owned writer while macOS sleeps. Keep the existing
    /// transport connection; the driver owns link recovery and the health loop
    /// performs the normal input-routing replay after recovery.
    /// Evidence: og_source/maestrolink/Software/SymphonyIOSymphonyPeripheralDevice.cpp:247-325;
    /// og_source/maestrolink/Software/SymphonyController.cpp:3653-3710.
    @MainActor
    func suspendTwoUnitReplay() {
        hardwareSleepState = .sleeping
        wakeReconnectTask?.cancel()
        wakeReconnectTask = nil
        wakeFallbackTask?.cancel()
        // Fallback for a missed didWake. It is evidence-based, not a timer from
        // willSleep: it fires wakeFallbackDelay after the system has actually
        // slept (the continuous clock ran ahead of the suspending clock), or
        // after wakeFallbackAbortLimit if no sleep ever happened (aborted sleep).
        // The original only resumes on SystemWake
        // (og_source/maestrolink/Software/SymphonyIOSymphonyPeripheralDevice.cpp:307-325).
        let continuousStart = ContinuousClock.now
        let suspendingStart = SuspendingClock.now
        wakeFallbackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let tick = min(self.wakeFallbackDelay, .seconds(2))
            var sleptAt: ContinuousClock.Instant?
            while !Task.isCancelled, self.hardwareSleepState == .sleeping {
                try? await Task.sleep(for: tick)
                let now = ContinuousClock.now
                let slept = (now - continuousStart) - (SuspendingClock.now - suspendingStart)
                if sleptAt == nil, slept > .seconds(1) { sleptAt = now }
                if let sleptAt, now - sleptAt >= self.wakeFallbackDelay { break }
                if sleptAt == nil, now - continuousStart >= self.wakeFallbackAbortLimit { break }
            }
            guard !Task.isCancelled, self.hardwareSleepState == .sleeping else { return }
            self.wakeFallbackFired = true
            self.wakeTwoUnitReplay()
        }
        wakeValidationGeneration &+= 1
        if let tb = device as? ThunderboltDeviceConnection, let link = tb.lastLinkState {
            wakeBaselineWatchTicks = link.watchTicks
            wakeBaselineRecoveryCount = link.recoveryCount
        } else {
            wakeBaselineWatchTicks = nil
            wakeBaselineRecoveryCount = nil
        }
        wakeStableRecoveryCount = nil
        wakeStableProbeCount = 0
        wakeDownProbeCount = 0
        device?.hardwareWriteGate?.holdForValidation()
        unitBDevice?.hardwareWriteGate?.holdForValidation()
        twoUnitReplayNeeded = true
        (unitBDevice as? ThunderboltUnitBConnection)?.invalidate()
        applyUnitB(nil, from: nil)
        isHardwareInitialized = false
        stopMeterPolling()
    }

    @MainActor
    func wakeTwoUnitReplay() {
        if hardwareSleepState != .sleeping {
            // A real didWake after the fallback already ran: validate again.
            guard wakeFallbackFired else { return }
            wakeFallbackFired = false
            suspendTwoUnitReplay()
        }
        wakeFallbackTask?.cancel()
        wakeFallbackTask = nil
        hardwareSleepState = .validating
        retryWakeValidation()
    }

    @MainActor
    func endWakeValidationForReconnect() {
        guard hardwareSleepState == .validating else { return }
        wakeReconnectTask?.cancel()
        wakeReconnectTask = nil
        hardwareSleepState = .awake
        device?.hardwareWriteGate?.retire()
        unitBDevice?.hardwareWriteGate?.retire()
        reconnectRequestedWhileSuspended = false
    }

    /// Record all interrupted discovery/reconnect work, including work that spans
    /// an entire sleep/wake generation. It must restart with a fresh connection.
    @MainActor
    func admitConnectionWork(generation: Int? = nil) -> Bool {
        guard !hardwareWritesSuspended,
              generation == nil || generation == wakeValidationGeneration else {
            reconnectRequestedWhileSuspended = true
            return false
        }
        return true
    }

    @MainActor
    func replaySuspendedReconnectIfNeeded() {
        guard !hardwareWritesSuspended, !isReconnecting,
              reconnectRequestedWhileSuspended else { return }
        reconnectRequestedWhileSuspended = false
        Task { @MainActor [weak self] in await self?.reconnectHardware() }
    }

    @MainActor
    func deferHealthCheckForSleep() -> Bool {
        guard hardwareWritesSuspended else { return false }
        if hardwareSleepState == .validating { retryWakeValidation() }
        return true
    }

    /// Only cached driver link state is read on ThunderBridge. USB reads have a
    /// deadline independent of whether the proxy ever replies.
    @MainActor
    func retryWakeValidation() {
        guard wakeReconnectTask == nil, hardwareSleepState == .validating else { return }
        let generation = wakeValidationGeneration
        wakeReconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.wakeValidationGeneration == generation { self.wakeReconnectTask = nil } }
            for _ in 0..<self.wakeRetryLimit {
                guard !Task.isCancelled, self.hardwareSleepState == .validating,
                      self.wakeValidationGeneration == generation else { return }
                if let connection = self.device {
                    if let tb = connection as? ThunderboltDeviceConnection {
                        let link: LinkState?
                        if let probe = self.wakeLinkProbe { link = await probe(tb) }
                        else {
                            // Wake validation is deliberately limited to the
                            // driver's cached link-state selector. The older
                            // timing-health probe is a vendor read and can
                            // never certify a sleeping/revalidating endpoint.
                            link = await Task.detached(priority: .utility) { tb.linkState() }.value
                        }
                        guard !Task.isCancelled, self.wakeValidationGeneration == generation else { return }
                        if self.device !== connection {
                            self.wakeStableRecoveryCount = nil
                            self.wakeStableProbeCount = 0
                            self.reconnectRequestedWhileSuspended = true
                        } else if let link {
                            if link.state == .down && !link.clockPresent {
                                self.wakeDownProbeCount += 1
                            } else {
                                self.wakeDownProbeCount = 0
                            }
                            if self.wakeDownProbeCount >= 3 {
                                // The health loop owns reconnect from here.
                                self.reconnectRequestedWhileSuspended = false
                                self.markHardwareDisconnected()
                                self.hardwareSleepState = .awake
                                self.startThunderboltHealthCheck()
                                return
                            }
                            if self.wakeProbeIsStable(link) {
                                self.finishWakeValidation(connection)
                                return
                            }
                        } else {
                            // A removed/stale user client cannot become valid by
                            // waiting for the retry budget. Hand it to the same
                            // reconnect path used by a live device-list removal.
                            self.wakeStableRecoveryCount = nil
                            self.wakeStableProbeCount = 0
                            // This code runs inside wakeReconnectTask: detach it first so
                            // ending validation does not cancel the reconnect itself.
                            self.wakeReconnectTask = nil
                            self.endWakeValidationForReconnect()
                            Task { @MainActor in await self.reconnectHardware() }
                            return
                        }
                    } else if await self.validateHardwareAfterWake(connection) { return }
                }
                try? await Task.sleep(for: self.wakeRetryInterval)
            }
            guard !Task.isCancelled, self.wakeValidationGeneration == generation,
                  self.hardwareSleepState == .validating else { return }
            self.markHardwareDisconnected()
            self.device?.hardwareWriteGate?.retire()
            self.hardwareSleepState = .awake
            self.reconnectRequestedWhileSuspended = false
            // A health loop on the stale client cannot repair a terminated nub.
            await self.reconnectHardware()
        }
    }

    @MainActor
    func wakeProbeIsStable(_ link: LinkState) -> Bool {
        guard link.state == .up, !link.hwSuspended, link.linkConfigured, link.clockPresent else {
            wakeStableRecoveryCount = nil
            wakeStableProbeCount = 0
            return false
        }
        // != accepts both watch-counter wrap and a restarted driver's counter.
        if let baseline = wakeBaselineWatchTicks,
           link.watchTicks == baseline, link.recoveryCount == wakeBaselineRecoveryCount { return false }
        if wakeStableRecoveryCount == link.recoveryCount { wakeStableProbeCount += 1 }
        else { wakeStableRecoveryCount = link.recoveryCount; wakeStableProbeCount = 1 }
        return wakeStableProbeCount >= 2
    }

    @MainActor
    func finishWakeValidation(_ connection: any DeviceConnection) {
        guard hardwareSleepState == .validating, device === connection else { return }
        wakeDownProbeCount = 0
        hardwareSleepState = .awake
        // A pinned simulation has no discovery/replay work to restart.
        if cardSimulation != nil { reconnectRequestedWhileSuspended = false }
        if reconnectRequestedWhileSuspended || isReconnecting {
            reconnectRequestedWhileSuspended = true
            replaySuspendedReconnectIfNeeded()
            return
        }
        guard connectionMode == .hardware else { return }
        connection.hardwareWriteGate?.openAfterValidation()
        isHardwareInitialized = true
        twoUnitReplayNeeded = usesTwoUnitReplay
        startMeterPolling()
        if cardDiscoverySkippedDuringSleep {
            cardDiscoverySkippedDuringSleep = false
            Task { @MainActor in await self.readCardTypes() }
        }
    }

    @MainActor
    func validateHardwareAfterWake(_ connection: any DeviceConnection) async -> Bool {
        guard hardwareSleepState == .validating, device === connection else { return false }
        let generation = wakeValidationGeneration
        let valid = await WakeReadDeadline.validate(connection, timeout: wakeReadTimeout)
        guard valid, !Task.isCancelled, hardwareSleepState == .validating,
              generation == wakeValidationGeneration, device === connection else { return false }
        finishWakeValidation(connection)
        return true
    }

}
