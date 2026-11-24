import Foundation
import MaestroCore
import MaestroDevice

extension AppState {
    /// Shared completion boundary for A and B. The injected read is also the
    /// test seam for a suspended transport; it does not bypass capability gates
    /// at either production call site.
    @MainActor
    func resolveUnitIdentity(for unit: DeviceUnit, connection: any DeviceConnection,
                             read: @escaping @Sendable () async -> UInt64?) async {
        // Unstructured ownership: closing the initiating view cannot cancel
        // discovery, binding, or the connection's USB restore.
        let operation = Task {
            await self.completeUnitIdentity(for: unit, connection: connection, read: read)
        }
        await operation.value
    }

    @MainActor
    private func completeUnitIdentity(for unit: DeviceUnit, connection: any DeviceConnection,
                                      read: @escaping @Sendable () async -> UInt64?) async {
        let state = unit == .a ? unitAIdentityState : unitBIdentityState
        let pending = unit == .a ? unitAIdentityTask : unitBIdentityTask
        guard state == .pending, pending == nil else { return }
        let generation = unit == .a ? unitAGeneration : unitBGeneration
        let parentGeneration = unitAGeneration
        let parent = device
        func isCurrent() -> Bool {
            let current = unit == .a ? device : unitBDevice
            return current === connection && device === parent && unitAGeneration == parentGeneration
                && (unit == .a ? unitAGeneration : unitBGeneration) == generation
        }
        guard isCurrent() else { return }
        // Bounded: a transport that never answers resolves as unknown (failed).
        let task = Task { await SymphonyIdentityReader.withDeadline { await read() } }
        if unit == .a { unitAIdentityTask = task }
        else { unitBIdentityTask = task; unitBIdentityAttempted = true }
        defer {
            // Cancellation during preference binding must end discovery too.
            // A replaced generation is owned exclusively by its new task.
            if isCurrent() {
                if unit == .a {
                    unitAIdentityTask = nil
                    if unitAIdentityState == .pending { unitAIdentityState = .failed }
                } else {
                    unitBIdentityTask = nil
                    if unitBIdentityState == .pending { unitBIdentityState = .failed }
                }
            }
        }
        func bindIdentity() async {
            let identity = await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
            guard isCurrent() else { return }
            if Task.isCancelled || task.isCancelled {
                if unit == .a { unitAIdentityState = .failed; unitAIdentityTask = nil }
                else { unitBIdentityState = .failed; unitBIdentityTask = nil }
                return
            }
            guard let identity else {
                if unit == .a { unitAIdentityState = .failed; unitAIdentityTask = nil }
                else { unitBIdentityState = .failed; unitBIdentityTask = nil }
                return
            }
            let store = (connection as? ThunderboltDeviceConnection)?.settingsStore
                ?? (connection as? XPCDeviceConnection)?.settingsStore
                ?? (connection as? ThunderboltUnitBConnection)?.settingsStore
            let allowMigration = store != nil && claimLegacyUnitState(unit: unit, identity: identity)
            let prefix = await store?.resolveIdentity(productID: connection.identifier.productID, unit: unit,
                                         identity: identity, allowLegacyMigration: allowMigration)
            guard !Task.isCancelled, isCurrent() else { return }
            if unit == .a {
                unitAIdentityState = .known(identity)
                unitAIdentityTask = nil
            } else {
                unitBIdentityState = .known(identity)
                unitBIdentityTask = nil
                unitBPeripheralPrefix = prefix.map(CardLayout.peripheralPrefix) ?? unitBPeripheralPrefix
                twoUnitReplayNeeded = true
                twoUnitRetryAfter = .distantPast
            }
            let preferences = unit == .a ? mixerPreferences : unitBChannelStateStore.mixerPreferences
            MixerPairLink.migrateSavedPairs(preferences: preferences)
        }
        await bindIdentity()
        guard isCurrent() else { return }
        // Finish discovery even when the read or preference binding was cancelled.
        // The connection/generation fence, not cancellation of the identity read,
        // decides whether this physical connection still needs its one restore.
        if unit == .a, unitAIdentityState == .pending { unitAIdentityState = .failed }
        if unit == .a { refreshSoftwareReturnMeterGains() }
        // D5: launch or reconnect asked for the card mixer restore while this
        // identity was pending.
        if unit == .a, let tb = connection as? ThunderboltDeviceConnection {
            rearmCardMixerRestoreAfterIdentity()
            // The restore was waiting for this identity: no backoff left.
            invalidateCardOutputTable(tb)
        }
        viewReloadToken = UUID()
        let preferences = mixerPreferences
        if unit == .a, let usb = connection as? XPCDeviceConnection,
           usbIdentityRestoreGeneration != generation, preferences.isWritable {
            usbIdentityRestoreGeneration = generation
            // The first restore must wait for UID/layout migration, otherwise
            // an unchanged USB unit would receive defaults before its settings.
            await restoreUSBUnit(usb, helperMixer: lastSelectedMixer)
        }
    }

    /// Pending discovery owns restoration. A recovery (the unit was
    /// power-cycled or re-enumerated while Maestro stayed connected) puts back
    /// everything the Mac owns, as the original did for a returning unit
    /// (og_source/maestrolink/Software/SymphonyIO.cpp:4660-4708
    /// ApplySettingsToHardware, called from :6373-6381), in the one order
    /// `restoreUSBUnit` uses for a connect too.
    @MainActor
    func restoreUSBMixerAfterRecovery(_ connection: XPCDeviceConnection, helperMixer: Int) async {
        guard device === connection, unitAIdentityState != .pending else { return }
        await restoreUSBUnit(connection, helperMixer: helperMixer)
    }

    /// Launch and reconnect, once the cards have been read: put the saved
    /// state on the unit. Over USB that is the ordered restore, which identity
    /// discovery has normally just run for this connection; it is not run a
    /// second time.
    @MainActor
    func syncSavedStateToHardware() async {
        if let usb = device as? XPCDeviceConnection {
            guard usbRestoredGeneration != unitAGeneration, unitAIdentityState != .pending else { return }
            await restoreUSBUnit(usb, helperMixer: lastSelectedMixer)
            return
        }
        await syncInputRoutingToHardware()
        await syncOutputRoutingToHardware()
        await syncDeviceSettingsToHardware()
    }

    /// The one USB restore, used by connect and by recovery, one at a time
    /// per connection: a restore that starts while another runs cancels it and
    /// waits for it to stop, then starts over from what is saved now.
    ///
    /// The order is a safety rule. A mixer must never be audible on an output
    /// unless the routing and that mixer's strips are the user's saved (or
    /// default) state, and a power-cycled unit comes back with its mixers at
    /// 0 dB, unmuted. The helper programs the direct default table every time
    /// it configures the unit, so no mixer feeds an output until this writes
    /// one, and that is the last thing it does:
    ///
    /// 1. every headphone crosspoint and every saved output route away from
    ///    the mixers: direct ones as saved, mixer-fed ones disabled. The unit
    ///    keeps its routing until it is power-cycled, and the helper's direct
    ///    table is not relied on for it;
    /// 2. both mixers: every input strip, then Software Return and Master;
    /// 3. the input routing;
    /// 4. the device settings (speaker mode first);
    /// 5. the output routes a mixer feeds, then the headphone crosspoints,
    ///    each from a mixer only if that mixer took every write of step 2.
    ///
    /// With the routing written before the mixers (as it was), a saved
    /// "Mixer 1 to Line 1/2" put live inputs and full-level playback on the
    /// monitors for the seconds the strip writes took.
    @MainActor
    func restoreUSBUnit(_ connection: XPCDeviceConnection, helperMixer: Int, owedOnly: Bool = false) async {
        let previous = usbRestoreTask
        previous?.cancel()
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            await self.performUSBRestore(connection, helperMixer: helperMixer, owedOnly: owedOnly)
        }
        usbRestoreTask = task
        await task.value
        if usbRestoreTask == task { usbRestoreTask = nil }
        updateRestoreStatus()
    }

    @MainActor
    private func performUSBRestore(_ connection: XPCDeviceConnection, helperMixer: Int, owedOnly: Bool) async {
        let generation = unitAGeneration
        let preferences = mixerPreferences
        guard device === connection, unitAIdentityState != .pending, !hardwareWritesSuspended else { return }
        func isCurrent() -> Bool {
            device === connection && unitAGeneration == generation && !hardwareWritesSuspended
                && !Task.isCancelled && mixerPreferences.isWritable == preferences.isWritable
                && mixerPreferences.storageKey == preferences.storageKey
        }
        // The unit's reset request (0xDB). It does not tell a replug from a
        // power cycle (both read None once the unit has started;
        // `SymphonyIOResetRequest`), so it decides only two things, as in
        // the original (SymphonyIO.cpp:6338-6432): a unit still starting is
        // waited for, polled every 200 ms; after a reset picked on the front
        // panel everything is written without asking the unit first, and
        // the request is acknowledged at the end.
        var reset = await connection.readResetRequest()
        var polls = 0
        while reset?.isStarting == true, polls < Self.usbResetRequestPolls {
            try? await Task.sleep(for: .milliseconds(200))
            guard isCurrent() else { return }
            reset = await connection.readResetRequest()
            polls += 1
        }
        guard isCurrent() else { return }
        // A front-panel reset is believed only once the unit is seen to say
        // so: two checks apart, each a read, a decoy and the read again, both
        // answering the same 3 or 4 (`confirmFrontPanelReset`). The read
        // above is a single transfer, and one the firmware does not answer
        // comes back with the bytes of the transfer before it; it must never
        // reset Maestro's saved state. Not confirmed: no reset, the unit is
        // asked before each write as on a replug, and 0xDB is not cleared.
        if reset?.isFrontPanelReset == true {
            let stillCurrent: @Sendable () async -> Bool = { @MainActor [weak self] in
                guard let self else { return false }
                return self.device === connection && self.unitAGeneration == generation
                    && !self.hardwareWritesSuspended && !Task.isCancelled
            }
            reset = await connection.confirmFrontPanelReset(separation: usbResetConfirmSeparation,
                                                            isCurrent: stillCurrent)
            guard isCurrent() else { return }
        }
        let identity: UInt64? = if case .known(let id) = unitAIdentityState { id } else { nil }
        // The reset of an earlier connection or launch is acknowledged once
        // the unit is seen to answer None (`FrontPanelResetMarker`).
        if reset == SymphonyIOResetRequest.none, let identity, FrontPanelResetMarker.stage(for: identity) != nil {
            if await connection.resetRequestReadsNone() {
                FrontPanelResetMarker.clear(for: identity)
                print("[Maestro] USB front panel reset: the unit answers None; the reset applied earlier is done")
            }
            guard isCurrent() else { return }
        }
        // Not on a unit whose cards were not read on this connection: the
        // defaults depend on them (the routing ones most of all), and a reset
        // of the wrong layout is not undone. A slot seen empty counts as
        // read (`frontPanelResetCardRefusal`); one read on an earlier
        // connection does not. 0xDB stays as it is, so the reset is applied
        // by the restore of a later connection (or a later restore of this
        // one) that finds the cards read; this restore asks the unit before
        // each write, as on a replug.
        var frontPanelReset = reset?.isFrontPanelReset == true
        if frontPanelReset {
            var refusal: String? = !isHardwareInitialized ? "the unit is not ready yet"
                : frontPanelResetCardRefusal(connection: connection, generation: generation)
            // A slot the reset relies on as empty is asked once more now.
            if refusal == nil {
                refusal = await frontPanelResetEmptySlotRecheck(connection: connection, generation: generation)
            }
            if let refusal {
                print("[Maestro] USB front panel reset (\(reset!)): not applied in this restore; \(refusal)")
                frontPanelReset = false
            }
        }
        // As the original did (SymphonyIO.cpp:6417-6432): the unit's saved
        // state goes back to defaults first, then the restore below writes
        // it, then the request is cleared (`AppState+FrontPanelReset`).
        // Only for a unit whose identity is known: without one the stores can
        // be the product-wide legacy ones, which are not this unit's alone.
        // Then everything is still written without asking and the request
        // cleared, but Maestro's saved state is left as it is.
        //
        // Once per reset: the marker is saved with the reset in the same
        // turn, and kept until the unit is seen to answer None. A clear that
        // did not land (or a quit before it) must not wipe, on the next
        // restore, relaunch or replug, what was edited after the reset.
        if frontPanelReset, let reset, usbFrontPanelResetGeneration != generation {
            usbFrontPanelResetGeneration = generation
            if let identity {
                if FrontPanelResetMarker.stage(for: identity) != nil {
                    print("[Maestro] USB front panel reset (\(reset)): already applied to Maestro's saved settings for this unit; not reset again")
                } else {
                    resetSavedStateForFrontPanelReset(reset, connection: connection)
                    FrontPanelResetMarker.set(.savedStateReset, for: identity)
                }
            } else {
                print("[Maestro] USB front panel reset (\(reset)): unit identity not known; Maestro's saved settings left as they are, every setting written")
            }
        }
        // What the unit already holds is not written again: a route of an
        // output or a headphone, or a digital format setting, that the helper
        // says the unit has (its configure's direct table, or an earlier
        // write since the unit was opened), and every setting whose value the
        // unit can be asked for (speaker mode, dim, sum to mono, analog and
        // digital reference levels, soft limit, mixer strips, routes, the
        // front panel meter settings) and already has. A plain replug leaves
        // the unit with all of them; 1140 still rewrote the speaker mode,
        // dim/sum, the meter settings and every channel's level and soft
        // limit while USB audio played, and the owner heard it. A power-cycled
        // unit answers its defaults and gets every write that differs. The
        // order below is unchanged: a skipped write is one the unit holds.
        //
        // A read is believed only once the unit is seen to answer that opcode
        // (`XPCDeviceConnection.trustedRead`); one it does not answer comes
        // back with the bytes of the transfer before it, and the write is
        // sent. With no mixer feeding an output nothing is silenced while
        // this runs and USB audio plays throughout, so the unit is asked
        // gently (`usbRestoreReadSpacing` between transfers); with one, its
        // outputs are silent until step 5 and the restore goes at its own
        // pace.
        let mixerFeedsOutput = mixerFeedsAudibleDestination()
        let elision = await connection.beginRestoreElision(
            compareReads: !frontPanelReset, spacing: mixerFeedsOutput ? .zero : usbRestoreReadSpacing,
            readGap: usbRestoreMinimumReadGap)
        defer {
            let total = connection.restoreCountsNow
            connection.endRestoreElision()
            if usbRestoreStarted?.generation == generation {
                usbRestoreStarted?.reachedUnit = connection.restoreReachedUnit
            }
            print("[Maestro] USB restore total: \(total.line)"
                + (elision ? "" : " (the helper did not say what it holds)"))
        }
        guard isCurrent() else { return }
        if frontPanelReset { print("[Maestro] USB restore: the unit was reset from its front panel (\(reset!)); writing every setting") }
        usbRestoreStarted = USBRestoreStart(generation: generation, at: Date())
        var mark = connection.restoreCountsNow
        func phase(_ name: String) {
            let now = connection.restoreCountsNow
            print("[Maestro] USB restore \(name): \((now - mark).line)")
            mark = now
        }
        usbRestoreRuns += 1
        // Anything that becomes owed from here on (an Output Routing edit, a
        // helper restart) is for the next run, not cleared by this one.
        usbRestoreOwed = false
        let helperEpoch = connection.helperEpoch
        updateRestoreStatus()
        // After a front-panel reset the speaker and headphone levels come
        // down first, before any other write: the reference levels, the
        // routing and the mixers written below are then heard at the lowered
        // level, never at the old one. Once per reset (not again on a retry,
        // a replug or a relaunch before 0xDB is cleared): a level raised
        // since stays where it was put. "Once" is noted only after the
        // lowering went through: one that was superseded or whose write
        // failed is tried again (by a later restore, connection or launch;
        // 0xDB is not cleared until it has been), and a repeat can only go
        // quieter. A level the unit does not answer is left alone.
        var levelsOwed = false
        if frontPanelReset, connectedUnit == nil, usbFrontPanelResetLevelsGeneration != generation,
           identity.map({ FrontPanelResetMarker.stage(for: $0) != .levelsLowered }) ?? true {
            let lowered = await applyFrontPanelResetLevels(connection)
            guard isCurrent() else { return }
            if lowered {
                usbFrontPanelResetLevelsGeneration = generation
                if let identity { FrontPanelResetMarker.set(.levelsLowered, for: identity) }
            } else {
                levelsOwed = true
            }
            phase("front panel reset levels")
        }
        // Mixers this connection already holds in full (a retry of something
        // owed) stay in step and keep their routes.
        let kept = Set((0..<2).filter { usbMixerIsWritten($0) })
        // Until step 1 has finished nothing may route a mixer to an output.
        usbMixersWritten = nil
        var mixers = [false, false]
        let symphony = !converterRoutingSurface && connectedUnit == nil
        // 0. An older helper puts Line 1/2 on Mixer 1 with that mixer's
        //    inputs muted every time it configures the unit: under it no
        //    mixer is written (nothing is unmuted), and it is said.
        let helper = await connection.helperStatus()
        guard isCurrent() else { return }
        usbHelperOutdated = helper == .outdated
        await refreshUSBHelperVersion()
        guard isCurrent() else { return }
        if usbHelperOutdated {
            // An older helper always moves the speakers: the Mac's volume is
            // the speaker's, and what was skipped until this was known is
            // read now.
            readASPVolume()
            readASPMute()
            print("[Maestro] USB restore: the installed USB helper is older than this app; mixers are not written. Reinstall Maestro with USB support.")
        }
        // 1. Every headphone and output away from the mixers about to be
        //    written (`usbPointRoutesAwayFromMixers`).
        var away = true
        if symphony {
            away = await usbPointRoutesAwayFromMixers(connection, keeping: kept)
            guard isCurrent() else { return }
            phase("routes before the mixers")
        }
        // 2. The mixers. Mixer state that cannot be read for this unit is
        //    not written, and then no mixer is routed either; the rest is
        //    still put back. Nor is one written while a destination could
        //    not be taken off it.
        if preferences.isWritable, away, !usbHelperOutdated {
            usbMixerLifecycleRestoreGeneration = generation
            mixers = await restoreUSBMixer(connection, generation: generation, helperMixer: helperMixer,
                                           preferences: preferences)
            mark = connection.restoreCountsNow
        }
        guard isCurrent() else { return }
        usbMixersWritten = (generation, mixers)
        // A retry of owed mixers or routes (`serviceUSBRestore`) does not send
        // the input routing and the device settings again, unless they have
        // not been sent on this connection and helper.
        if !owedOnly || frontPanelReset
            || usbSettingsRestored.map({ $0.generation != generation || $0.helperEpoch != helperEpoch }) ?? true {
            await syncInputRoutingToHardware()
            guard isCurrent() else { return }
            phase("input routing")
            await syncDeviceSettingsToHardware()
            guard isCurrent() else { return }
            phase("device and channel settings")
        }
        var routed: Bool
        if converterRoutingSurface {
            // Converters: their own routes, not the Symphony I/O table.
            await syncOutputRoutingToHardware()
            routed = true
        } else if hardwareWritesSuspended || (connectionMode == .hardware && unitAIdentity == nil) {
            routed = false
        } else {
            // 5. Last: the routes a mixer feeds, then the headphones.
            routed = await syncUSBOutputRouting(connection, mixerFedOnly: symphony)
            phase("mixer routes")
            if symphony, isCurrent() {
                let headphones = await syncUSBHeadphoneCrosspoints(connection)
                routed = routed && headphones
                phase("headphones")
            }
        }
        routed = routed && away
        // Launch reads the cards (and so runs this) only after the hardware is
        // marked ready; a run before that skipped the stored settings and
        // must not count as the connection's restore.
        guard isCurrent(), isHardwareInitialized else { return }
        usbSettingsRestored = (generation, helperEpoch)
        // A mixer that did not take every write, or a route that failed or
        // waits for its mixer, is owed: the connection does not count as
        // restored, and the meter loop tries again with a growing pause.
        // Without readable mixer state only a waiting route is owed.
        let mixersDone = (mixers == [true, true] || !preferences.isWritable) && !usbHelperOutdated
        guard routed, mixersDone, connection.helperEpoch == helperEpoch else {
            usbRestoreOwed = true
            usbRestoreRetryAttempts += 1
            let wait = Self.restoreRetryPause(usbRestoreRetryAttempts)
            usbRestoreRetryAfter = max(usbRestoreRetryAfter, Date().addingTimeInterval(wait))
            print("[Maestro] USB restore not complete (mixers written: \(mixers), routes written: \(routed)); retry in \(Int(wait)) s")
            updateRestoreStatus()
            return
        }
        usbRestoredGeneration = generation
        usbRestoredHelperEpoch = helperEpoch
        usbRestoredHelperConfigures = connection.restoreHelperConfigures
        usbRestoreRetryAttempts = 0
        if frontPanelReset, levelsOwed {
            print("[Maestro] USB restore: front panel reset not acknowledged yet; a speaker or headphone level was not written, the lowering is tried again by the next restore")
        } else if frontPanelReset {
            if await connection.clearResetRequest() {
                if let identity { FrontPanelResetMarker.clear(for: identity) }
                print("[Maestro] USB restore: front panel reset acknowledged")
            } else {
                print("[Maestro] USB restore: front panel reset not acknowledged (0xDB does not answer None); the reset stays applied once, not again")
            }
        }
        updateRestoreStatus()
    }

    /// How many times (200 ms apart) the restore asks a unit that is still
    /// starting before it goes ahead anyway: 5 s.
    static let usbResetRequestPolls = 25

    /// The 1 Hz tick: the helper configured the unit again since the restore
    /// (a stale handle or a port reset it recovered from by itself; it then
    /// puts every output and headphone back on the direct table, and the
    /// app's reads never fail long enough to call it a loss). The saved
    /// routing is owed; the retry asks the unit before each write, so only
    /// what the configure changed is sent.
    @MainActor
    func serviceHelperReconfigure(_ connection: XPCDeviceConnection) async {
        // Not while the unit is still settling after it appeared (the same
        // wait every other USB write honours), and not when a restore is
        // already owed or running: that one puts the routing back.
        func due() -> Bool {
            device === connection && usbRestoredGeneration == unitAGeneration
                && !usbRestoreOwed && usbRestoreTask == nil && usbSettleRemainingNow <= 0
        }
        guard due(), let restored = usbRestoredHelperConfigures,
              let now = await connection.helperConfigureCount(), now != restored,
              due(), usbRestoredHelperConfigures == restored else { return }
        usbRestoredHelperConfigures = nil
        usbRestoreOwed = true
        usbRestoreRetryAfter = .distantPast
        print("[Maestro] The USB helper configured the unit again (\(restored) -> \(now)): restoring the routing")
    }

    /// A healthy meter-loop cycle over USB: run the restore again when it is
    /// owed (a mixer or a route did not land, a mixer route was added while
    /// its mixer was not written, a second power cycle fell inside the
    /// recovery debounce) or when the helper restarted under the app.
    @MainActor
    func serviceUSBRestore(_ connection: XPCDeviceConnection) {
        guard device === connection, connectionMode == .hardware, isHardwareInitialized,
              !hardwareWritesSuspended else { return }
        if let seen = usbRestoredHelperEpoch, usbRestoredGeneration == unitAGeneration,
           seen != connection.helperEpoch, !usbRestoreOwed {
            // The helper restarted: no mixer route until the restore has run
            // on the helper now answering.
            usbMixersWritten = nil
            usbRestoreOwed = true
            usbRestoreRetryAfter = .distantPast
            print("[Maestro] USB helper restarted: restoring mixers and routing")
        }
        updateRestoreStatus()
        guard usbRestoreOwed, usbRestoreTask == nil, usbRestoreServiceTask == nil,
              unitAIdentityState != .pending, Date() >= usbRestoreRetryAfter else { return }
        let mixer = lastSelectedMixer
        usbRestoreServiceTask = Task { @MainActor [weak self] in
            defer { self?.usbRestoreServiceTask = nil }
            guard let self, self.device === connection else { return }
            await self.restoreUSBUnit(connection, helperMixer: mixer, owedOnly: true)
        }
    }

    /// The meter loop saw the unit come back from a power cycle. True when
    /// the recovery restore should start now. Inside the debounce (a second
    /// power cycle within 5 s of the last recovery) it is not started twice,
    /// but the unit is at its defaults again, so the restore is owed and
    /// `serviceUSBRestore` runs it when the debounce ends.
    @MainActor
    func usbRecoveryRestoreDueOrOwed(now: Date) -> Bool {
        guard mixerPreferences.isWritable else { return false }
        if Self.usbRecoveryRestoreDue(lastRecovery: lastRecoveryTime, now: now) { return true }
        usbRestoreOwed = true
        usbSettingsRestored = nil
        usbRestoreRetryAfter = lastRecoveryTime.addingTimeInterval(5.1)
        return false
    }

    /// Both mixers, complete: every input strip (saved or default), then the
    /// Software Return source, Master and Software Return, then the helper.
    /// The unit keeps its mixer until it is power-cycled, so strips are not
    /// left to whatever an earlier session wrote: a strip does what it shows.
    /// Each strip's saved value is read when the strip is written and checked
    /// again after it, so an edit made during the restore is what the unit
    /// ends on. Returns, per mixer, whether every write landed.
    @MainActor
    @discardableResult
    func restoreUSBMixer(_ connection: XPCDeviceConnection, generation: UUID, helperMixer: Int,
                         preferences: MixerPreferences) async -> [Bool] {
        let current: @Sendable () async -> Bool = { @MainActor [weak self] in
            guard let self else { return false }
            return self.device === connection && self.unitAGeneration == generation
                && !self.hardwareWritesSuspended && !Task.isCancelled
                && self.mixerPreferences.isWritable
                && self.mixerPreferences.storageKey == preferences.storageKey
        }
        let savedStrip: @Sendable (Int, Int) async -> MixerChannelState? = { @MainActor [weak self] mixer, strip in
            let saved: [MixerChannelState] = self?.channelStateStore.load(ChannelStateStore.mixerKey(mixer)) ?? []
            return strip < saved.count ? saved[strip] : nil
        }
        let before = connection.restoreCountsNow
        let strips = await connection.restoreMixerStrips(
            hardwareIndexes: cardLayout.mixerChannels.map(\.hardwareIndex),
            spacing: usbMixerStripSpacing, savedStrip: savedStrip, isCurrent: current)
        guard await current() else { return [false, false] }
        let afterStrips = connection.restoreCountsNow
        print("[Maestro] USB restore mixer strips: \((afterStrips - before).line), \(strips.failed) refused")
        let returnAndMaster = await connection.restoreReturnAndMaster(
            helperMixer: helperMixer, preferences: preferences, routedToOutput: mixersRoutedToOutput())
        guard await current() else { return [false, false] }
        print("[Maestro] USB restore mixer return and master: \((connection.restoreCountsNow - afterStrips).line)")
        return strips.mixersWritten.map { $0 && returnAndMaster }
    }

    /// Whether a mixer feeds anything heard over USB: an output in the saved
    /// Output Routing, or a headphone whose saved source follows a pair a
    /// mixer feeds. The restore paces its reads only when none does: with one,
    /// that output or headphone is silent until the restore routes it back,
    /// and 25 ms between transfers kept a mixer-fed headphone silent for
    /// 8-12 s. (A headphone's source comes from the same saved rows, so the
    /// first test already covers it; it is asked separately so a headphone
    /// is counted whatever the rows are built from.)
    @MainActor
    func mixerFeedsAudibleDestination() -> Bool {
        if mixersRoutedToOutput().contains(true) { return true }
        let routes = cachedOutputRouteMap()
        return SymphonyIOHeadphoneRouting.Headphone.allCases.contains { headphone in
            guard let sources = usbHeadphoneSources(headphone, cachedRoutes: routes) else { return false }
            return CardOutputTableOrder.mixer(ofSource: sources.left) != nil
                || CardOutputTableOrder.mixer(ofSource: sources.right) != nil
        }
    }

    /// Which of the two mixers feed an output, from the saved Output Routing
    /// (the default routes no mixer to any output).
    @MainActor
    func mixersRoutedToOutput() -> [Bool] {
        guard let device else { return [false, false] }
        return USBHelperSoftwareReturn.mixersRouted(
            rows: peripheralRoutingCache(direction: "output").loadMulti() ?? [:],
            softwarePairs: device.identifier.mode.channelCount / 2)
    }

    /// The helper's software stage for the saved mixers and routing, with
    /// `editing` standing in for a mixer whose Software Return is being changed
    /// and not saved yet (``USBHelperSoftwareReturn``).
    @MainActor
    func usbHelperSoftwareReturn(
        editing: (mixer: Int, source: UInt32, muted: Bool)? = nil
    ) -> USBHelperSoftwareReturn.State {
        let preferences = mixerPreferences
        let routed = mixersRoutedToOutput()
        return USBHelperSoftwareReturn.state((0..<2).map { mixer in
            if let editing, editing.mixer == mixer {
                return .init(source: editing.source, muted: editing.muted, routedToOutput: routed[mixer])
            }
            return .init(
                source: UInt32(clamping: preferences.integer(forKey: "mixerSoftwareReturnSource_\(mixer)")),
                muted: MixerStateSnapshot.savedSoftwareReturn(mixer: mixer, preferences: preferences).isMuted,
                routedToOutput: routed[mixer])
        })
    }

    /// Output Routing changed over USB: a mixer may have started or stopped
    /// feeding an output, which is what decides whether the helper acts.
    @MainActor
    func syncUSBHelperSoftwareReturn() {
        guard let usb = device as? XPCDeviceConnection, mixerPreferences.isWritable,
              !hardwareWritesSuspended else { return }
        usb.applyHelperSoftwareReturn(usbHelperSoftwareReturn())
    }


    func claimLegacyUnitState(unit: DeviceUnit, identity: UInt64) -> Bool {
        let layout = unit == .a ? cardLayout : unitBLayout
        guard let scope = layout?.savedStateScope else { return false }
        return UnitStateMigration.claim(scope: "\(unit == .a ? "unitA" : "unitB").\(scope)", identity: identity)
    }

    func allowsLegacyUnitState(unit: DeviceUnit) -> Bool {
        guard let identity = unit == .a ? unitAIdentity : unitBIdentity else { return false }
        return claimLegacyUnitState(unit: unit, identity: identity)
    }

    /// Physical state follows the hardware UID and fitted boards. Port is used
    /// only to find the prior app's source, never in the destination key.
    func unitPreferenceKey(legacy: String, category: String, unit: DeviceUnit = .a) -> String {
        let layout = unit == .a ? cardLayout : unitBLayout
        let identity = unit == .a ? unitAIdentity : unitBIdentity
        let simulation = connectionMode == .simulated || cardSimulation != nil || simulatedUnitB != nil
        if simulation { return "sim." + legacy }
        if let converters = layout?.converterLayout {
            return "conv.\(converters.routingSignature).\(category)"
        }
        if layout?.converter != nil { return "converter.\(category)" }
        guard let identity else {
            let generation = unit == .a ? unitAGeneration : unitBGeneration
            return "pending.\(generation).\(category)"
        }
        return UnitStateMigration.key(legacy: legacy, identity: identity,
                                      category: "\(category).\(layout?.savedStateScope ?? "unknown")",
                                      allowMigration: allowsLegacyUnitState(unit: unit))
    }

    var mixerPreferencesCacheKey: String {
        "\(unitAGeneration)|\(unitAIdentityState)|\(connectionMode)|\(cardSimulation != nil)|\(cardLayout)|\(device != nil)|\(UserDefaults.standard.string(forKey: "mixerWideState.migratedTo") ?? "")"
    }

    var mixerPreferences: MixerPreferences {
        // Cache the handle, not its values: reads still see edits and recalls.
        let key = mixerPreferencesCacheKey
        if let cachedMixerPreferences, cachedMixerPreferences.key == key {
            return cachedMixerPreferences.value
        }
        let value = channelStateStore.mixerPreferences
        cachedMixerPreferences = (key, value)
        return value
    }

    func mixerNamesKey(unit: DeviceUnit = .a) -> String {
        unitPreferenceKey(legacy: unit == .a ? "mixerChannelNames" : "mixerChannelNamesUnitB",
                          category: "mixerChannelNames", unit: unit)
    }

    /// The card owns output crosspoints; their sources are host/card slots.
    /// Bind them to the complete ordered topology, unlike peripheral P2P input
    /// routes and labels, which travel with a unit when it changes ports.
    var cardIdentityTopology: String {
        let a = unitAIdentity.map { String($0, radix: 16) } ?? "pending-\(unitAGeneration)"
        let b = unitBOnCard ? (unitBIdentity.map { String($0, radix: 16) } ?? "pending-\(unitBGeneration)") : "none"
        return "a=\(a).b=\(b).channels=\(unitBOnCard ? 64 : 32)"
    }

    func peripheralRoutingCache(direction: String, unit: DeviceUnit = .a) -> RoutingStateCache {
        if direction == "output", connectionMode == .hardware,
           unitAIdentity == nil || (unitBOnCard && unitBIdentity == nil) {
            let key = "pending.cardOutput.\(cardIdentityTopology).\(unit)"
            return RoutingStateCache(key: key, multiKey: key + "_multi")
        }
        let product = device?.identifier.productID ?? 0
        let layout = unit == .a ? cardLayout : unitBLayout
        let oldDirection = unit == .a ? direction : "\(direction).unitB.\(layout?.savedStateScope ?? "unknown")"
        let legacy = "routing_\(oldDirection)_\(product)_v2"
        if direction == "input", unit == .a, transportType == .thunderbolt,
           unitAIdentity != nil, !UserDefaults.standard.bool(forKey: ThunderboltInputRoutingMigration.doneKey) {
            // The old grid's pre-0.8.40 choices remain quarantined. Keep its
            // source for inspection, but never revive it via a new UID key.
            UserDefaults.standard.set("discarded-pre0840", forKey: legacy + ".migratedTo")
        }
        if direction == "output", connectionMode != .simulated, cardSimulation == nil,
           layout?.converterLayout == nil, layout?.converter == nil {
            let destination = "cardRouting.v3.\(product).\(cardIdentityTopology).\(unit).\(layout?.savedStateScope ?? "unknown")"
            let allowed = allowsLegacyUnitState(unit: unit)
            let key = UnitStateMigration.propertyKey(legacy: legacy, destination: destination, allowMigration: allowed)
            let multi = UnitStateMigration.propertyKey(legacy: legacy + "_multi", destination: destination + "_multi", allowMigration: allowed)
            return RoutingStateCache(key: key, multiKey: multi)
        }
        let category = direction == "output" ? "cardOutput" : "inputRouting"
        let key = unitPreferenceKey(legacy: legacy, category: category, unit: unit)
        let multi = unitPreferenceKey(legacy: legacy + "_multi", category: category + "_multi", unit: unit)
        return RoutingStateCache(key: key, multiKey: multi)
    }
}
