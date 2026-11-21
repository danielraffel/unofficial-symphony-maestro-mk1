// ApogeeDriverConflict.swift — what Maestro does while one of Apogee's kernel
// drivers for the ThunderBridge or PCIe card is loaded.
//
// Why (the full account, and what the installer and uninstall script do, is in
// AGENTS.md, "Apogee's original drivers: what we do and why"):
//
// Apogee's kernel extension (com.apogeedigital.driver.Symphony64ThunderBridge,
// or the PCIe card's com.apogeedigital.driver.Symphony64) and Maestro's driver
// extension can both attach to the same PCI card. Both register the card's
// interrupt, and macOS's kernel then crashes (a NULL dereference in
// IOSharedInterruptController::unregisterInterrupt) when either one releases
// it: our driver's Stop, or the kext being terminated. A Mac restarted about
// 24 times in two days this way. The fault is in macOS, but we are the second
// driver on the card, so Maestro keeps the combination from happening.
//
// So, while such a kext is loaded:
// - Maestro submits no activation or replacement request for its driver
//   extension. A request starts our driver on the card, or replaces a running
//   one, which stops it.
// - If our driver is already on the card, Maestro does not stop, retire or
//   replace it either: that Stop is the crash. It warns, and says to shut the
//   Mac down and disconnect the card before anything is removed.
//
// A copy that is on disk or staged but not loaded keeps the plain warning and
// blocks nothing in the app. (The installer stops an install or update over a
// copy in an Extensions folder, and a first install over a staged one.)
//
// Maestro never removes, unloads or changes anything of Apogee's: it detects,
// holds back, explains, and points to Apogee's own uninstaller and then the
// removal guide. That is a firm decision of the owner's (AGENTS.md).

import Foundation

public enum ApogeeDriverConflict {

    public enum State: String, Sendable, Equatable, CaseIterable {
        /// No kernel driver of Apogee's for the card is loaded or kept on disk.
        case clear
        /// A copy is on disk or staged, not loaded: today's warning, nothing blocked.
        case copyNotLoaded
        /// Loaded, and Maestro's driver is not active: it is not started.
        case driverHeld
        /// Loaded, and Maestro's driver is active too: nothing is touched.
        case bothActive
    }

    public struct Decision: Sendable, Equatable {
        public let state: State
        /// Whether Maestro may submit an activation or replacement request for
        /// its driver extension.
        public let mayRequestActivation: Bool
        /// Whether Maestro may do anything that stops its running driver
        /// (retire, replace, deactivate). False whenever Apogee's is loaded.
        public let mayStopMaestroDriver: Bool
        /// Whether the app may install an update of itself.
        public let mayUpdate: Bool
        /// Show `updateNote`: this copy of Maestro carries a driver build that
        /// is not the one registered, so the user has just updated.
        public let showsUpdateNote: Bool

        public init(state: State, mayRequestActivation: Bool, mayStopMaestroDriver: Bool, mayUpdate: Bool,
                    showsUpdateNote: Bool) {
            self.state = state
            self.mayRequestActivation = mayRequestActivation
            self.mayStopMaestroDriver = mayStopMaestroDriver
            self.mayUpdate = mayUpdate
            self.showsUpdateNote = showsUpdateNote
        }

        /// What the warning opens with, or nil for the existing message.
        public var what: String? {
            switch state {
            case .clear, .copyNotLoaded: return nil
            case .driverHeld: return ApogeeDriverConflict.heldWhat
            case .bothActive: return ApogeeDriverConflict.bothActiveWhat
            }
        }
        /// The instruction that must not be missed, when both are active.
        public var caution: String? { state == .bothActive ? ApogeeDriverConflict.bothActiveCaution : nil }
        /// What Maestro is not doing meanwhile.
        public var consequence: String? {
            switch state {
            case .clear, .copyNotLoaded: return nil
            case .driverHeld, .bothActive: return ApogeeDriverConflict.consequence
            }
        }
        public var updateNote: String? { showsUpdateNote ? ApogeeDriverConflict.updateNote : nil }
        /// The header banner's title and message, or nil when there is none.
        public var banner: (title: String, message: String)? {
            switch state {
            case .clear, .copyNotLoaded: return nil
            case .driverHeld: return (ApogeeDriverConflict.heldBannerTitle, ApogeeDriverConflict.heldBannerMessage)
            case .bothActive:
                return (ApogeeDriverConflict.bothActiveBannerTitle, ApogeeDriverConflict.bothActiveBannerMessage)
            }
        }
    }

    /// The decision, from four facts.
    ///
    /// Only a kext that is loaded now changes what the app does: with it in
    /// the kernel, starting, replacing or stopping our driver is what crashes
    /// the Mac, so all three are off and so is updating (an update replaces
    /// the driver). A copy that is merely on disk cannot be on the card until
    /// the next start, so the app only warns; the installer is what stops an
    /// install or update over one. Background: AGENTS.md, "Apogee's original
    /// drivers: what we do and why".
    ///
    /// - Parameters:
    ///   - kextLoaded: one of Apogee's kernel drivers for the ThunderBridge or
    ///     PCIe card is loaded in the kernel right now.
    ///   - copyOnDisk: a copy of one is in an Extensions folder or staged by
    ///     macOS (whether or not one is loaded).
    ///   - maestroDriverActive: Maestro's driver extension is registered and
    ///     enabled, so it is on the card whenever the card is connected.
    ///   - updatePending: this copy of Maestro carries a driver build other
    ///     than the registered one, or one is registered and not yet serving.
    public static func decide(kextLoaded: Bool, copyOnDisk: Bool, maestroDriverActive: Bool,
                              updatePending: Bool) -> Decision {
        guard kextLoaded else {
            return Decision(state: copyOnDisk ? .copyNotLoaded : .clear, mayRequestActivation: true,
                            mayStopMaestroDriver: true, mayUpdate: true, showsUpdateNote: false)
        }
        return Decision(state: maestroDriverActive ? .bothActive : .driverHeld, mayRequestActivation: false,
                        mayStopMaestroDriver: false, mayUpdate: false, showsUpdateNote: updatePending)
    }

    // MARK: Text
    //
    // The same message as the installer's dialog (DIALOG_OPENING and
    // dialog_fix_steps in Installer/scripts-core/preinstall), in the app's
    // terms; OriginalApogeeDriversWiringTests keeps the two in step.

    /// The warning's title and how the installer's dialog opens.
    public static let detected = "Apogee's original Symphony I/O drivers were detected."
    /// Its next sentence, here and in the dialog.
    public static let crashRisk = "Running both can crash your Mac and make it restart repeatedly."

    public static let heldWhat = crashRisk
    public static let bothActiveWhat = "Apogee's driver and Maestro's driver are both running now. " + crashRisk
    /// The safest order the user guide gives ("Removing Apogee's original
    /// drivers"): with both running, pulling the cable or removing a driver
    /// stops one of them on the card, which is the crash.
    public static let bothActiveCaution = "Do not unplug the ThunderBridge or PCIe chassis while your Mac is on, "
        + "and do not update Maestro. Shut down your Mac and disconnect the ThunderBridge or PCIe chassis, then "
        + "start up again, before you remove Apogee's drivers."
    public static let consequence = "Maestro's driver is not being updated or started until Apogee's driver is removed."
    /// Someone who has just updated does not expect this. One sentence, the
    /// same as the installer's (UPDATE_NOTE in Installer/scripts-core/preinstall)
    /// in the app's tense.
    public static let updateNote = "You are seeing this after updating because this version now checks for them. "
        + "Earlier versions did not check."
    /// The fix, in the installer's words and order.
    public static let fixSteps: [String] = [
        "Download Apogee's latest installer, Symphony I/O Release 5.5",
        "Open the DMG and choose **Uninstall**",
        "Restart your Mac",
        "Install Maestro again (Apogee's Uninstall also removes Maestro; this puts it back)",
    ]

    public static let heldBannerTitle = "Apogee's original Symphony I/O drivers were detected"
    public static let heldBannerMessage = crashRisk + " " + consequence + " Device Settings has the steps."
    public static let bothActiveBannerTitle = "Do not unplug the ThunderBridge or update Maestro"
    public static let bothActiveBannerMessage = detected + " One is running alongside Maestro's driver. "
        + crashRisk + " Shut down your Mac and disconnect the ThunderBridge or PCIe chassis, then start up "
        + "again. Device Settings has the steps."

    /// What the updater says when it declines an update (Sparkle shows it for a
    /// check the user started).
    public static let updateRefusal = "Maestro can't update while Apogee's original Symphony I/O drivers are "
        + "loaded. " + crashRisk + " Device Settings has the steps to remove them."
}

extension OriginalApogeeDriverFinding {
    /// The decision for this finding. `maestroDriverActive` and `updatePending`
    /// come from sysextd's records (SystemExtensionInstaller).
    public func conflict(maestroDriverActive: Bool, updatePending: Bool) -> ApogeeDriverConflict.Decision {
        ApogeeDriverConflict.decide(kextLoaded: hasLoadedPCIKernelDriver,
                                    copyOnDisk: hasUnloadedPCIKernelDriverCopy,
                                    maestroDriverActive: maestroDriverActive, updatePending: updatePending)
    }
}
