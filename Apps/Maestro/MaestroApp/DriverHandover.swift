// DriverHandover.swift — notice when a driver update finishes registering.
//
// On a dext upgrade sysextd registers the new copy and reports the activation
// request .completed, but kernelmanagerd refuses to terminate the old copy
// while it holds the PCI device ("is being replaced and cannot be terminated
// right away") and defers its removal to the next restart. The card stays on
// the old binary until the ThunderBridge cable is unplugged and plugged back
// in, the driver is turned off and on in System Settings, or the Mac restarts
// (logged 2026-11-14, 121 -> 122).
//
// Maestro does not retire the old driver itself: the banner tells the user to
// replug the cable. The driver still implements kSelectorRetireForUpgrade
// (selector 7) and DextUserClient can send it, but nothing in the app calls it.

import Foundation
import MaestroCore

extension AppState {

    /// Start listening for activation requests that complete, so the banner
    /// reflects the newly registered driver promptly. Idempotent. Never
    /// retires anything.
    @MainActor
    func installDriverHandoverObserver() {
        guard driverActivationObserver == nil else { return }
        // A request that was not submitted because Apogee's kernel driver is
        // loaded: look again, so the banner and the Device Settings warning
        // show it now (a kext that appeared after launch).
        Task { @MainActor [weak self] in
            let held = NotificationCenter.default.notifications(
                named: SystemExtensionInstaller.activationHeldNotification)
            for await _ in held {
                guard let self else { return }
                self.refreshOriginalApogeeDrivers()
            }
        }
        driverActivationObserver = Task { @MainActor [weak self] in
            let completions = NotificationCenter.default.notifications(
                named: SystemExtensionInstaller.activationCompletedNotification)
            for await _ in completions {
                guard let self else { return }
                self.driverActivationCompleted()
            }
        }
    }

    /// Maestro's activation request finished with `.completed`: re-read what
    /// is registered so the banner can say the update is unfinished.
    @MainActor
    func driverActivationCompleted() {
        refreshInstalledDexts()
    }
}
