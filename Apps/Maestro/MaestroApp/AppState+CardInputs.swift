import Foundation
import MaestroCore
import MaestroDevice

extension AppState {
    var symphonyCardInputs: SymphonyCardInputRouting {
        let symphony = transportType == .thunderbolt && connectedUnit == nil && converterSystem == nil
        return SymphonyCardInputRouting(model: SymphonyRoutingModel(
            topology: symphony ? .symphonyOnly : .unknown,
            hostChannels: portSelection.selection?.channelCount ?? 32,
            unitBConfigured: unitBInputRoutingAllowed), servingBuild: servingDextBuild)
    }

    var symphonyCardInputStore: SymphonyCardInputStore? {
        guard symphonyCardInputs.channelCount > 0, let scope = cardLayout.savedStateScope else { return nil }
        if connectionMode == .hardware,
           unitAIdentity == nil || (symphonyCardInputs.channelCount == 64 && unitBIdentity == nil) { return nil }
        let b = symphonyCardInputs.channelCount == 64 ? (unitBLayout?.savedStateScope ?? "unknown") : "none"
        let simulation = connectionMode == .simulated || cardSimulation != nil || simulatedUnitB != nil
        return SymphonyCardInputStore(scope: (simulation ? "sim:" : "") + "\(scope).\(b).\(symphonyCardInputs.channelCount).\(cardIdentityTopology)")
    }

    /// Serialize clicks/replay/reset and send off the main actor. Revalidate
    /// the connection and layout after waiting; never retarget queued work.
    @MainActor
    func applySymphonyCardInputs(_ edits: [Int: Int], reset: Bool = false) async -> Bool {
        guard !hardwareWritesSuspended, let tb = device as? ThunderboltDeviceConnection,
              let store = symphonyCardInputStore else { return false }
        let previous = symphonyCardInputTail
        let admissionVersion = symphonyCardInputVersion
        let replayDeferral = self.replayDeferral
        let admissionEpoch = replayDeferral.currentEpoch()
        let task = Task { @MainActor [weak self] in
            _ = await previous?.value
            guard let self, !self.hardwareWritesSuspended, self.device as? ThunderboltDeviceConnection === tb,
                  self.symphonyCardInputStore?.key == store.key,
                  replayDeferral.isValid(admissionEpoch) else { return false }
            let effectiveEdits = admissionVersion == self.symphonyCardInputVersion ? edits : self.symphonyCardInputEdits
            let routing = self.symphonyCardInputs
            let commands: [ConverterRouting.Command]
            if reset {
                guard let command = routing.resetCommand else { return false }
                commands = [command]
            } else {
                commands = routing.commands(edits: effectiveEdits)
                guard commands.count == effectiveEdits.count else { return false }
            }
            // The store is only touched under the connection's transaction lock
            // (hardware writes and their persistence commit together).
            nonisolated(unsafe) let lockedStore = store
            let accepted: [ConverterRouting.Command] = await Task.detached(priority: .userInitiated) { () -> [ConverterRouting.Command] in
                (try? tb.withPresetLock { () throws -> [ConverterRouting.Command] in
                    guard replayDeferral.isValid(admissionEpoch) else { return [] }
                    var accepted: [ConverterRouting.Command] = []
                    for command in commands {
                        guard replayDeferral.isValid(admissionEpoch) else { break }
                        do { try tb.sendConverterRouting(command); accepted.append(command) }
                        catch { break }
                    }
                    let saved = SymphonyCardInputRouting.applying(accepted, to: lockedStore.load())
                    lockedStore.save(saved)
                    return accepted
                }) ?? []
            }.value
            guard self.device as? ThunderboltDeviceConnection === tb,
                  self.symphonyCardInputStore?.key == store.key else { return false }
            let saved = SymphonyCardInputRouting.applying(accepted, to: store.load())
            self.symphonyCardInputEdits = saved
            self.symphonyCardInputVersion &+= 1
            return accepted.count == commands.count
        }
        symphonyCardInputTail = task
        return await task.value
    }

    @MainActor
    func replaySymphonyCardInputs() async {
        guard let store = symphonyCardInputStore else { return }
        let loaded = store.load()
        symphonyCardInputEdits = symphonyCardInputs.channelCount == 32
            ? SymphonyCardInputTransitionPolicy.restoreSingleUnitRoutes(loaded)
            : loaded
        if !(await applySymphonyCardInputs(symphonyCardInputEdits)) {
            print("[Maestro] Card input routing replay refused")
        }
    }

    /// Stream names follow the per-unit P2P choices, never host destination
    /// numbers. Same default/cache contract as the existing per-unit grids.
    func symphonyCardInputNames() -> [String] {
        _ = symphonyCardInputNamingRevision
        func names(layout: CardLayout, cache: RoutingStateCache?, slot1: IOCardType?, prefix: String) -> [String] {
            let defaults = SymphonyIODefaultRouting.thunderboltInputRoutes(slot1: slot1)
            var routes = SymphonyIODefaultRouting.inputGrid(defaults, columns: layout.inputRoutingColumns)
            routes.merge(cache?.load() ?? [:]) { _, saved in saved }
            return CardLayout.softwareInputRowNames(rowCount: 16, routes: routes,
                                                    columns: layout.inputRoutingColumns, prefix: prefix)
        }
        let cache = device.map { _ in peripheralRoutingCache(direction: "input") }
        var result = names(layout: cardLayout, cache: cache, slot1: thunderboltCaptureSlot1, prefix: peripheralPrefix)
        if symphonyCardInputs.channelCount == 64, let layout = unitBLayout {
            result += names(layout: layout, cache: unitBInputRoutingCache, slot1: unitB?.slot1, prefix: unitBPeripheralPrefix)
        }
        return result
    }
}
