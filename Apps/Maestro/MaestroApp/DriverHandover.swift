// DriverHandover.swift — finish a driver update that macOS left half done.
//
// On a dext upgrade sysextd registers the new copy and reports the activation
// request .completed, but kernelmanagerd refuses to terminate the old copy
// while it holds the PCI device ("is being replaced and cannot be terminated
// right away") and defers its removal to the next restart. The card stays on
// the old binary until a replug, a restart, or the driver is turned off and on
// in System Settings (logged 2026-11-14, 121 → 122).
//
// When Maestro's own activation request completes and the build answering on
// the card is not the bundled one, Maestro asks that driver to retire
// (kSelectorRetireForUpgrade, dext 123+): it calls Terminate(0) on itself so
// Stop() runs and the device is free for the copy macOS registered. Maestro
// stops its own use of the device first, closes its connection once the driver
// accepts, shows "Finishing the driver update…", and waits about 10 s for the
// card to answer with the bundled build. Anything else (no selector, a refusal,
// no answer in time, the old copy put back) leaves the reconnect / turn off and
// on / restart guidance up until the serving build matches.
//
// Whether IOKit matches the replacement onto the PCI nub after a provider-
// matched service terminates itself is not documented; this needs the hardware
// test (exp64 9005 → 9006). See SymphonyThunderbridge::RetireForUpgrade.

import Foundation
import os
import MaestroCore
import MaestroDevice

extension AppState {

    private static let handoverLog = Logger(subsystem: "com.danielraffel.maestro", category: "driver-handover")

    /// How long the card has to come back on the bundled build.
    static let driverHandoverTimeout: Duration = .seconds(10)

    /// Start listening for activation requests that complete. Idempotent.
    @MainActor
    func installDriverHandoverObserver() {
        guard driverActivationObserver == nil else { return }
        driverActivationObserver = Task { @MainActor [weak self] in
            let completions = NotificationCenter.default.notifications(
                named: SystemExtensionInstaller.activationCompletedNotification)
            for await _ in completions {
                guard let self else { return }
                self.driverActivationCompleted()
            }
        }
    }

    /// Called after every serving-build read (`refreshServingDextBuild`):
    /// clears a timed-out hand-over once the bundled build answers, and acts
    /// on an activation that completed before a ThunderBridge connection was
    /// open to ask (at launch the request finishes in about a second, before
    /// the hardware is connected).
    @MainActor
    func considerDriverHandover() {
        // A completion that arrived before the observer was installed.
        let completed = SystemExtensionInstaller.shared.completedActivationCount
        if completed > driverActivationsHandled {
            driverActivationsHandled = completed
            driverActivationCompletedPending = true
        }
        if driverHandover == .timedOut, softwareInfoReport.servingDextMatchesBundled {
            Self.handoverLog.notice("bundled driver now serves the ThunderBridge; guidance cleared")
            driverHandover = .idle
        }
        guard driverActivationCompletedPending, driverHandover == .idle,
              transportType == .thunderbolt, let tb = device as? ThunderboltDeviceConnection,
              servingDextBuild != nil
        else { return }
        driverActivationCompletedPending = false
        Task { @MainActor [weak self] in await self?.retireServingDriverIfNeeded(tb) }
    }

    /// Maestro's activation request finished with `.completed`. Decided at
    /// the next serving-build read, which this starts.
    @MainActor
    func driverActivationCompleted() {
        driverActivationsHandled = SystemExtensionInstaller.shared.completedActivationCount
        driverActivationCompletedPending = true
        refreshInstalledDexts()
    }

    @MainActor
    private func retireServingDriverIfNeeded(_ tb: ThunderboltDeviceConnection) async {
        guard (device as? ThunderboltDeviceConnection) === tb else { return }
        let report = softwareInfoReport
        guard report.shouldAskServingDriverToRetire(activationCompleted: true),
              let bundled = report.bundledDextBuild, let bundledBuild = UInt32(bundled),
              case .build(let servingBuild)? = report.servingDextBuild
        else { return }
        let key = "\(servingBuild)->\(bundledBuild)"
        guard !driverHandoverAttempts.contains(key) else {
            Self.handoverLog.notice("already asked build \(servingBuild) to retire for \(bundledBuild); guidance only")
            return
        }
        driverHandoverAttempts.insert(key)

        // Stop Maestro's own use of the device before the driver goes.
        stopMeterPolling()
        stopThunderboltHealthCheck()
        thunderboltWatchTask?.cancel()

        Self.handoverLog.notice("asking build \(servingBuild) to retire for bundled build \(bundledBuild)")
        let reply = await Task.detached(priority: .userInitiated) {
            tb.retireServingDriver(replacementBuild: bundledBuild)
        }.value
        guard case .accepted(let retiring) = reply else {
            // No selector (an older driver), the wrong shape (an experimental
            // driver), or a refusal: nothing was torn down. Carry on as before;
            // the banner shows the guidance because the update is unfinished.
            Self.handoverLog.notice("retire not accepted (\(String(describing: reply), privacy: .public)); showing guidance")
            if connectionMode == .hardware { startMeterPolling() }
            startThunderboltHealthCheck()
            return
        }
        Self.handoverLog.notice("build \(retiring) is retiring; waiting for build \(bundledBuild)")
        driverHandover = .finishing
        let arrived = await Self.waitForServingBuild(bundledBuild, timeout: Self.driverHandoverTimeout)
        driverHandover = arrived ? .idle : .timedOut
        Self.handoverLog.notice("hand-over \(arrived ? "finished" : "timed out", privacy: .public)")
        // Either way the old connection is gone: find whatever serves the card now.
        await reconnectHardware()
        refreshInstalledDexts()
    }

    /// Poll the card with a throwaway user-client connection (independent of
    /// the app's own, which is closed) until it answers with `build`.
    private static func waitForServingBuild(_ build: UInt32, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(500))
            let answered = await Task.detached(priority: .utility) { () -> UInt32? in
                let probe = DextUserClient()
                probe.connect(audioDeviceID: 0)
                defer { probe.disconnect() }
                return probe.readDriverBuild()
            }.value
            if answered == build { return true }
        }
        return false
    }
}
