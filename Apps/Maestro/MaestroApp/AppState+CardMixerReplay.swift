import Foundation
import MaestroCore
import MaestroDevice

extension AppState {
    /// Reconnect owns the card mixer even if MixerView was never opened.
    /// Initial single-unit startup does not call this path. The driver already restores
    /// its in-session coefficients on recovery, but not after endpoint replacement.
    /// Evidence: og_source/maestrolink/Software/SymphonyPCIeRoutingController.cpp:248-302,680-784.
    @MainActor
    func syncCardMixerToHardware() async {
        guard !recallInFlight, !twoUnitSleeping, !usesTwoUnitReplay,
              connectionMode == .hardware, isHardwareInitialized,
              unitAIdentity != nil, connectedUnit == nil, converterSystem == nil,
              let tb = device as? ThunderboltDeviceConnection,
              RoutingResetGuard.refusalReason(board1: primaryBoardReading, board2: secondaryBoardReading) == nil else { return }
        let endpoint = tb.endpointGeneration
        guard cardMixerReplayEndpoint != endpoint, mixerPageSyncedEndpoint != endpoint else { return }
        let generation = replayDeferral.currentEpoch()
        let edits = tb.mixerEdits
        let editGeneration = edits.capture()
        let layout = cardLayout
        // Reapply only destinations in this identity/layout's saved table.
        // The default routes stay with the driver when no output was edited.
        // Reconnect's normal routing phase already writes saved output pairs;
        // including them here would send every route twice.
        var groups: [[ThunderboltPreset.Write]] = []
        for mixer in 0..<2 {
            groups.append(CardMixerReplay.savedWrites(mixer: mixer, layout: layout, store: channelStateStore))
        }
        guard groups.contains(where: { !$0.isEmpty }) else { return }
        let plan = groups
        let deferral = replayDeferral
        do {
            // A new user client must be live and unchanged for five seconds.
            // This deliberately does not run for in-place recovery.
            guard let recovery = await Self.waitForStableMixerEndpoint(tb) else { return }
            guard device === tb, cardMixerReplayEndpoint != endpoint,
                  mixerPageSyncedEndpoint != endpoint,
                  deferral.isValid(generation), edits.isCurrent(editGeneration) else { return }
            let started = Date()
            try await Task.detached(priority: .utility) {
                try tb.replayCardMixer(plan, layout: layout, recoveryCount: recovery,
                    shouldContinue: { deferral.isValid(generation) && edits.isCurrent(editGeneration) })
            }.value
            guard device === tb else { return }
            cardMixerReplayEndpoint = endpoint
            refreshSoftwareReturnMeterGains()
            print(String(format: "[Maestro] D5 card mixer replay: %d commands, %.3f s (paced 20/100 ms)",
                         CardMixerReplay.commandCount(plan), Date().timeIntervalSince(started)))
        } catch {
            // Leave the endpoint unclaimed so a later fresh connection can
            // retry. A dropped link never gets a partial replay retried in place.
            print("[Maestro] Card mixer replay refused: \(error)")
        }
    }

    nonisolated private static func waitForStableMixerEndpoint(_ tb: ThunderboltDeviceConnection) async -> UInt32? {
        await Task.detached(priority: .utility) {
            guard let first = tb.linkState(), first.state == .up,
                  first.clockPresent, first.linkConfigured, !first.hwSuspended else { return nil }
            var samples = [first]
            for _ in 1..<21 {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return nil }
                guard let current = tb.linkState() else { return nil }
                samples.append(current)
            }
            return CardMixerReplay.stableRecoveryCount(samples)
        }.value
    }
}
