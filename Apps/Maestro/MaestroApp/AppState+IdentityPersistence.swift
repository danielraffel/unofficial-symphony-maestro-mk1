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
        let task = Task { await read() }
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
        viewReloadToken = UUID()
        let preferences = mixerPreferences
        if unit == .a, let usb = connection as? XPCDeviceConnection {
            // The first restore must wait for UID/layout migration, otherwise
            // an unchanged USB unit would receive defaults before its settings.
            await usb.restoreReturnAndMaster(helperMixer: lastSelectedMixer, preferences: preferences)
            guard isCurrent() else { return }
            let mode = preferences.integer(forKey: "routingMode")
            usb.setRoutingMode(mode)
            if mode == 0 {
                for mixer: UInt16 in 1...2 {
                    for channel: UInt16 in 0..<32 {
                        usb.sendMixerParam(usbCmd: 0xB3, mixer: mixer, channel: channel, value: 1)
                    }
                }
            }
        }
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
        if unitAIdentityState == .failed, connectionMode == .hardware, cardSimulation == nil,
           cardLayout.converter == nil, cardLayout.converterLayout == nil {
            return MixerPreferences(legacyDefaults: .standard, readOnly: true)
        }
        return channelStateStore.mixerPreferences
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
