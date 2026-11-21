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
        if unit == .a, connection is ThunderboltDeviceConnection { rearmCardMixerRestoreAfterIdentity() }
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
        await syncOutputRoutingToHardware()
        await syncInputRoutingToHardware()
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
    /// 1. both mixers: every input strip, then Software Return and Master;
    /// 2. the input routing;
    /// 3. the device settings (speaker mode first);
    /// 4. the output routing, and a route fed by a mixer only if that mixer
    ///    took every write of step 1.
    ///
    /// With the routing written before the mixers (as it was), a saved
    /// "Mixer 1 to Line 1/2" put live inputs and full-level playback on the
    /// monitors for the seconds the strip writes took.
    @MainActor
    func restoreUSBUnit(_ connection: XPCDeviceConnection, helperMixer: Int) async {
        let previous = usbRestoreTask
        previous?.cancel()
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            await self.performUSBRestore(connection, helperMixer: helperMixer)
        }
        usbRestoreTask = task
        await task.value
        if usbRestoreTask == task { usbRestoreTask = nil }
    }

    @MainActor
    private func performUSBRestore(_ connection: XPCDeviceConnection, helperMixer: Int) async {
        let generation = unitAGeneration
        let preferences = mixerPreferences
        guard device === connection, unitAIdentityState != .pending, !hardwareWritesSuspended else { return }
        func isCurrent() -> Bool {
            device === connection && unitAGeneration == generation && !hardwareWritesSuspended
                && !Task.isCancelled && mixerPreferences.isWritable == preferences.isWritable
                && mixerPreferences.storageKey == preferences.storageKey
        }
        // Until step 1 has finished nothing may route a mixer to an output.
        usbMixersWritten = nil
        var mixers = [false, false]
        // Mixer state that cannot be read for this unit is not written, and
        // then no mixer is routed either; the rest is still put back.
        if preferences.isWritable {
            usbMixerLifecycleRestoreGeneration = generation
            mixers = await restoreUSBMixer(connection, generation: generation, helperMixer: helperMixer,
                                           preferences: preferences)
        }
        guard isCurrent() else { return }
        usbMixersWritten = (generation, mixers)
        await syncInputRoutingToHardware()
        guard isCurrent() else { return }
        await syncDeviceSettingsToHardware()
        guard isCurrent() else { return }
        await syncOutputRoutingToHardware()
        // Launch reads the cards (and so runs this) only after the hardware is
        // marked ready; a run before that skipped the stored settings and
        // must not count as the connection's restore.
        guard isCurrent(), isHardwareInitialized else { return }
        usbRestoredGeneration = generation
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
        let strips = await connection.restoreMixerStrips(
            hardwareIndexes: cardLayout.mixerChannels.map(\.hardwareIndex),
            spacing: usbMixerStripSpacing, savedStrip: savedStrip, isCurrent: current)
        guard await current() else { return [false, false] }
        print("[Maestro] USB mixer restore: \(strips.applied) strip writes, \(strips.failed) refused")
        let returnAndMaster = await connection.restoreReturnAndMaster(
            helperMixer: helperMixer, preferences: preferences, routedToOutput: mixersRoutedToOutput())
        guard await current() else { return [false, false] }
        return strips.mixersWritten.map { $0 && returnAndMaster }
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

    var mixerPreferences: MixerPreferences {
        // Cache the handle, not its values: reads still see edits and recalls.
        let key = "\(unitAGeneration)|\(unitAIdentityState)|\(connectionMode)|\(cardSimulation != nil)|\(cardLayout)|\(device != nil)|\(UserDefaults.standard.string(forKey: "mixerWideState.migratedTo") ?? "")"
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
