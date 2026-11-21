// ApogeeDriverConflict.swift — what Maestro does while one of Apogee's kernel
// drivers for the ThunderBridge or PCIe card is loaded.
//
// A user's Mac kernel-panicked about 24 times in two days. Apogee's kernel
// extension com.apogeedigital.driver.Symphony64ThunderBridge (1.5) was loaded
// while Maestro's driver extension was attached to the same PCI device. Both
// had registered the card's interrupt, and macOS's kernel dereferenced NULL in
// IOSharedInterruptController::unregisterInterrupt when either one let go: our
// driver's Stop cancelling its interrupt source, or the kext being terminated.
//
// So, while such a kext is loaded:
// - Maestro submits no activation or replacement request for its driver
//   extension. A request starts our driver on the card, or replaces a running
//   one, which stops it.
// - If our driver is already on the card, Maestro does not stop, retire or
//   replace it either: any Stop of it in that state is what panics. It warns,
//   and tells the user not to unplug the ThunderBridge or update.
//
// The fix is always Apogee's own uninstaller and a restart. A copy that is on
// disk or staged but not loaded keeps the existing warning and blocks nothing
// in the app (the installer stops an install or update over it).

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

    public static let heldWhat = "Apogee's original Symphony driver is loaded on this Mac. With both drivers on the "
        + "ThunderBridge or PCIe card, macOS can crash and restart repeatedly."
    public static let bothActiveWhat = "Apogee's original Symphony driver and Maestro's driver are both running on "
        + "this Mac. With both drivers on the ThunderBridge or PCIe card, macOS can crash and restart repeatedly."
    public static let bothActiveCaution = "Do not unplug the ThunderBridge and do not update Maestro. Run Apogee's "
        + "own uninstaller, then restart your Mac."
    public static let consequence = "Maestro's driver is not being updated or started until Apogee's driver is removed."
    /// Someone who has just updated does not expect this. One sentence, the
    /// same idea as the installer's (UPDATE_NOTE in Installer/scripts-core/preinstall).
    public static let updateNote = "You are seeing this after updating because this version now checks for Apogee's "
        + "original driver, and it found it on this Mac. Earlier versions did not check."
    /// The fix, in the order the installer gives it.
    public static let fixSteps: [String] = [
        "Run Apogee's own uninstaller: open Apogee's Symphony I/O Release 5.5 installer and choose **Uninstall**.",
        "Restart your Mac.",
        "Install Maestro again. Apogee's Uninstall also removes Maestro and resets macOS's audio device settings.",
    ]

    public static let heldBannerTitle = "Apogee's original Symphony driver is loaded"
    public static let heldBannerMessage = consequence + " Run Apogee's own uninstaller, then restart your Mac. "
        + "Device Settings has the steps."
    public static let bothActiveBannerTitle = "Do not unplug the ThunderBridge or update Maestro"
    public static let bothActiveBannerMessage = "Apogee's original Symphony driver is running alongside Maestro's, "
        + "and macOS can crash when either one lets go of the card. Run Apogee's own uninstaller, then restart "
        + "your Mac. Device Settings has the steps."

    /// What the updater says when it declines an update (Sparkle shows it for a
    /// check the user started).
    public static let updateRefusal = "Maestro can't update while Apogee's original Symphony driver is loaded. With "
        + "both drivers on the ThunderBridge or PCIe card, macOS can crash and restart repeatedly. Run Apogee's own "
        + "uninstaller, restart your Mac, then install Maestro again. Device Settings has the steps."
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
