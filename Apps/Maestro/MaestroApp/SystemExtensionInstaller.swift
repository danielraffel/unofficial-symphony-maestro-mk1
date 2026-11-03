// SystemExtensionInstaller.swift — activate the ThunderBridge dext from inside Maestro.app.
//
// Maestro.app and the old standalone DextInstaller.app both declare the bundle ID
// com.danielraffel.maestro, so they cannot coexist in /Applications. Maestro.app is the
// real app, so it owns activation. DextInstaller.app remains for development only.
//
// Requirements for this to work at runtime:
//   1. the dext lives at Contents/Library/SystemExtensions/<bundleID>.dext
//   2. the app is signed with com.apple.developer.system-extension.install
//   3. the app embeds a Developer ID profile granting that entitlement
//   4. the app runs from /Applications (OSSystemExtensionManager refuses elsewhere)
//
// Activation is idempotent: submitting for an already-active identical version is a no-op.
// The first activation on a machine requires user approval in
// System Settings > General > Login Items & Extensions > Driver Extensions.

import Foundation
import SystemExtensions
import IOKit
import os

/// `@unchecked Sendable`: every delegate callback is delivered on `.main` (we pass
/// `queue: .main` when submitting), and `onStatusChange` is only touched from there.
public final class SystemExtensionInstaller: NSObject, OSSystemExtensionRequestDelegate, @unchecked Sendable {

    public static let shared = SystemExtensionInstaller()

    private let dextBundleID = "com.danielraffel.maestro.thunderbridge"
    private let log = Logger(subsystem: "com.danielraffel.maestro", category: "sysext")

    /// macOS keeps an activation request alive while it waits for approval or a
    /// hardware swap.  A hot-plug callback and the Settings/banner button can
    /// arrive in that window at the same time; submitting a second request makes
    /// sysextd return error 4 and presents a false setup failure.  Keep one request
    /// in flight and let its delegate callback drive the next state.
    private var activationRequestInFlight = false

    /// Called when activation finishes, fails, or needs approval. Always on the main queue.
    public var onStatusChange: ((Status) -> Void)?
    /// Most recent activation outcome, retained so a view that appears after the
    /// asynchronous request can still present the right next step.
    public private(set) var lastStatus: Status?

    public enum Status: Sendable {
        case notBundled
        case activating
        case needsUserApproval
        case activated
        case willCompleteAfterReboot
        case upgradePending
        case failed(String)
    }

    private override init() { super.init() }

    /// True when the dext is actually inside this app bundle. False for `swift run` builds
    /// and for any bundle assembled without the embed step in build-installer.sh.
    public var isDextBundled: Bool {
        let path = Bundle.main.bundlePath
            + "/Contents/Library/SystemExtensions/\(dextBundleID).dext"
        return FileManager.default.fileExists(atPath: path)
    }

    /// CFBundleVersion of the dext this app bundle carries — what a relaunch would
    /// activate. Nil when no dext is embedded.
    ///
    /// CFBundleVersion and not the short version, because that is the only field
    /// `sysextd` compares when deciding whether an activation is an upgrade.
    public var bundledDextBuildVersion: String? {
        let plist = Bundle.main.bundlePath
            + "/Contents/Library/SystemExtensions/\(dextBundleID).dext/Info.plist"
        guard let data = FileManager.default.contents(atPath: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        else { return nil }
        return dict["CFBundleVersion"] as? String
    }

    /// Request activation. Safe to call on every launch.
    public func activate() {
        guard isDextBundled else {
            log.notice("No dext embedded in app bundle — skipping activation")
            report(.notBundled)
            return
        }

        guard !activationRequestInFlight else {
            log.notice("Driver extension activation already in flight; ignoring duplicate request")
            return
        }

        log.notice("Requesting activation of \(self.dextBundleID, privacy: .public)")
        activationRequestInFlight = true
        report(.activating)

        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: dextBundleID,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    // MARK: - ThunderBridge hardware detection (activate only when the card is present)

    /// IORegistry names of the supported Apogee PCIe devices. The IOPCIDevice nub exists whether
    /// or not our driver has matched it, so we can detect either card without the dext being
    /// active — that's what lets us stay dormant for USB-only users.
    private let thunderBridgeIONames = ["pci19c2,2200", "pci19c2,2100"]
    private var hardwareNotifyPort: IONotificationPortRef?
    private var hardwareIterator: io_iterator_t = 0

    /// Activate the driver only if the ThunderBridge is present now, and start watching so it
    /// activates automatically the moment the card is plugged in later. This is the ONLY activation
    /// entry point the app should use: a USB-only Mac never has this card, so the driver stays
    /// dormant and the user is never prompted to approve a system extension they don't need.
    /// Idempotent — safe to call once at launch.
    public func activateWhenThunderBridgePresent() {
        guard isDextBundled else { report(.notBundled); return }
        guard hardwareNotifyPort == nil else { return }

        let port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, .main)
        hardwareNotifyPort = port

        // C-callable, non-capturing: pulls `self` back out of refcon, drains the iterator (required
        // to re-arm the notification), and activates if the card appeared.
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            var appeared = false
            var obj = IOIteratorNext(iterator)
            while obj != 0 { appeared = true; IOObjectRelease(obj); obj = IOIteratorNext(iterator) }
            guard appeared, let refcon else { return }
            let installer = Unmanaged<SystemExtensionInstaller>.fromOpaque(refcon).takeUnretainedValue()
            if installer.shouldSubmitAutomaticActivation() {
                installer.activate()
            } else {
                installer.log.notice("ThunderBridge appeared with the bundled driver already active; waiting for any pending swap to finish")
            }
        }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let matching = IOServiceMatching("IOPCIDevice") as NSMutableDictionary
        matching[kIONameMatchKey as String] = thunderBridgeIONames
        let kr = IOServiceAddMatchingNotification(
            port, kIOMatchedNotification, matching,
            callback, selfPtr, &hardwareIterator)
        guard kr == KERN_SUCCESS else {
            log.error("Failed to install ThunderBridge match notification (0x\(String(UInt32(bitPattern: kr), radix: 16)))")
            // Self-heal: tear down the half-open port and clear the guard flag so a later call can
            // retry the watcher, then fall back to a one-shot presence check so a TB user still gets
            // activation even if the notification install failed this time.
            IONotificationPortDestroy(port)
            hardwareNotifyPort = nil
            if isThunderBridgePresent() { activate() }
            return
        }

        // The initial iterator drain both ARMS the notification AND reports any already-present
        // card — so this one call covers "present at launch" and "plugged in later".
        var presentNow = false
        var obj = IOIteratorNext(hardwareIterator)
        while obj != 0 { presentNow = true; IOObjectRelease(obj); obj = IOIteratorNext(hardwareIterator) }
        if presentNow {
            if shouldSubmitAutomaticActivation() {
                log.notice("ThunderBridge present — activating Thunderbolt driver")
                activate()
            } else {
                log.notice("ThunderBridge present — bundled driver is already active; no duplicate activation request")
            }
        } else {
            log.notice("No ThunderBridge present — Thunderbolt driver stays dormant (watching for hotplug)")
        }
    }

    /// One-shot check: is the ThunderBridge PCIe card present in IOKit right now?
    public func isThunderBridgePresent() -> Bool {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IOPCIDevice") as NSMutableDictionary
        matching[kIONameMatchKey as String] = thunderBridgeIONames
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return false }
        defer { IOObjectRelease(iterator) }
        let obj = IOIteratorNext(iterator)
        if obj != 0 { IOObjectRelease(obj); return true }
        return false
    }

    /// The PCI personality currently exposed by IOKit, when present.
    /// Keeping the raw identifier visible makes it clear whether the app is using
    /// ThunderBridge (`pci19c2,2200`) or the experimental Symphony 64 PCIe card
    /// (`pci19c2,2100`).
    public func presentThunderBridgePCIIdentifier() -> String? {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IOPCIDevice") as NSMutableDictionary
        matching[kIONameMatchKey as String] = thunderBridgeIONames
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        let obj = IOIteratorNext(iterator)
        guard obj != 0 else { return nil }
        defer { IOObjectRelease(obj) }
        var name = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(obj, &name) == KERN_SUCCESS else { return nil }
        return String(cString: name)
    }

    /// Avoid submitting an idempotent activation request on every launch and
    /// reconnect. macOS reports a duplicate request as
    /// `OSSystemExtensionErrorDomain` code 4, which looks like a setup failure
    /// to the user. An enabled copy matching the bundled build is already the
    /// desired state; when a second older copy is still terminating, the only
    /// useful next step is the physical reconnect that releases the old card.
    private func shouldSubmitAutomaticActivation() -> Bool {
        guard let bundled = bundledDextBuildVersion else { return false }
        guard let registered = installedDexts(), !registered.isEmpty else { return true }
        // A user-disabled, approval-pending, reboot-pending, or uninstalling
        // extension must be repaired through the explicit Settings/banner
        // action. Re-submitting activation on every launch/hot-plug can produce
        // OSSystemExtensionErrorDomain code 4 and turns a deliberate disabled
        // state into a repeated prompt loop.
        if registered.contains(where: {
            $0.isAwaitingUserApproval || $0.isAwaitingReboot || $0.isUninstalling || !$0.isEnabled
        }) {
            return false
        }
        // More than one registered copy means an upgrade is waiting for the old
        // driver to release the card. The safe action is a physical reconnect,
        // not another activation request.
        if registered.count > 1 {
            return false
        }
        // A single enabled copy with a different build is the normal clean
        // upgrade state. Submit one replacement request so the embedded dext
        // can become active after a reboot or physical reconnect. If the old
        // process still owns the PCI function, the delegate reports error 4 and
        // the request is not retried until the next hardware appearance. This
        // avoids the repeated-request wedge while still allowing an upgrade to
        // finish without a separate installer host.
        if registered[0].bundleVersion != bundled {
            log.notice("Older ThunderBridge dext (registered[0].bundleVersion, privacy: .public) is registered; requesting one replacement")
            return true
        }
        return false
    }

    private func report(_ status: Status) {
        lastStatus = status
        if Thread.isMainThread {
            onStatusChange?(status)
        } else {
            DispatchQueue.main.async { self.onStatusChange?(status) }
        }
    }

    // MARK: - OSSystemExtensionRequestDelegate

    public func request(_ request: OSSystemExtensionRequest,
                        didFinishWithResult result: OSSystemExtensionRequest.Result) {
        activationRequestInFlight = false
        switch result {
        case .completed:
            log.notice("Driver extension activated")
            report(.activated)
        case .willCompleteAfterReboot:
            log.notice("Driver extension activation completes after reboot")
            report(.willCompleteAfterReboot)
        @unknown default:
            log.notice("Driver extension activation: unknown result")
            report(.activated)
        }
    }

    public func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        activationRequestInFlight = false
        let ns = error as NSError
        log.error("Activation failed: \(error.localizedDescription, privacy: .public) (\(ns.domain, privacy: .public) \(ns.code))")
        if ns.domain == OSSystemExtensionErrorDomain && ns.code == 4 {
            report(.upgradePending)
            return
        }
        report(.failed(error.localizedDescription))
    }

    public func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        // Keep the request marked in-flight: sysextd can still complete this
        // same request after the user approves it in System Settings. A second
        // activation from the banner during that window produces error 4.
        log.notice("Driver extension needs user approval in System Settings")
        report(.needsUserApproval)
    }

    /// Always replace. sysextd compares CFBundleVersion, not the code hash — a rebuilt dext
    /// carrying the same CFBundleVersion is silently NOT replaced, and the old binary keeps
    /// running while `systemextensionsctl list` reports [activated enabled].
    public func request(_ request: OSSystemExtensionRequest,
                        actionForReplacingExtension existing: OSSystemExtensionProperties,
                        withExtension ext: OSSystemExtensionProperties)
        -> OSSystemExtensionRequest.ReplacementAction {
        log.notice("Replacing dext \(existing.bundleVersion, privacy: .public) with \(ext.bundleVersion, privacy: .public)")
        return .replace
    }
}

// MARK: - Installed-dext lookup (for the Software Info panel)

/// One registered copy of the ThunderBridge driver extension, as `sysextd` records it.
///
/// `bundleVersion` is the number that actually decides anything: `sysextd` compares
/// CFBundleVersion and nothing else when deciding whether an activation is an upgrade.
public struct InstalledDextInfo: Sendable, Equatable {
    public let bundleVersion: String
    public let bundleShortVersion: String
    public let isEnabled: Bool
    public let isAwaitingUserApproval: Bool
    public let isAwaitingReboot: Bool
    public let isUninstalling: Bool

    /// The short form the panel shows, e.g. `0.10.0 (54)`.
    public var displayVersion: String {
        bundleShortVersion.isEmpty ? bundleVersion : "\(bundleShortVersion) (\(bundleVersion))"
    }
}

extension SystemExtensionInstaller {

    /// sysextd's own database — the file `systemextensionsctl list` prints. Root-owned and
    /// world-readable.
    static let sysextDatabasePath = "/Library/SystemExtensions/db.plist"

    /// Which copies of the dext are registered on this Mac.
    ///
    /// This reads the database directly rather than asking `OSSystemExtensionManager`.
    /// `OSSystemExtensionRequest.propertiesRequest` is the documented API for the question
    /// and it is what this used to call, but on macOS 26 it answers a submitted request
    /// with neither `didFinishWithResult` nor `didFailWithError` — verified here with a
    /// 5s deadline that always expired, on a Mac where the dext was activated and enabled
    /// and an activation request through the same XPC link had just succeeded. A promise
    /// that never resolves reads on screen as a permanent "Unknown", so the file wins.
    ///
    /// More than one entry comes back while an upgrade is half-applied: the outgoing
    /// version cannot exit until it releases the PCI device, so it stays registered
    /// alongside the incoming one until the Thunderbolt cable is replugged. The panel says
    /// so rather than picking one and pretending it is the whole story.
    ///
    /// Returns an empty array when nothing is registered, and nil when the database could
    /// not be read or parsed — which is not the same claim, and the panel says so.
    public func installedDexts() -> [InstalledDextInfo]? {
        guard let data = FileManager.default.contents(atPath: Self.sysextDatabasePath),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
              let extensions = root["extensions"] as? [[String: Any]]
        else {
            log.notice("Could not read \(Self.sysextDatabasePath, privacy: .public)")
            return nil
        }
        let found = extensions
            .filter { $0["identifier"] as? String == dextBundleID }
            .map { Self.parseEntry($0) }
        log.notice("Registered driver extensions: \(found.map(\.displayVersion).joined(separator: ", "), privacy: .public)")
        return found
    }

    /// One `extensions` entry from the database.
    ///
    /// `state` is a single string such as `activated_enabled`, `activated_waiting_for_user`
    /// or `terminated_waiting_to_uninstall_on_reboot`, so the three flags are substring
    /// tests on it rather than separate keys.
    static func parseEntry(_ entry: [String: Any]) -> InstalledDextInfo {
        let version = entry["bundleVersion"] as? [String: Any] ?? [:]
        let state = entry["state"] as? String ?? ""
        return InstalledDextInfo(
            bundleVersion: version["CFBundleVersion"] as? String ?? "",
            bundleShortVersion: version["CFBundleShortVersionString"] as? String ?? "",
            isEnabled: state.contains("enabled"),
            isAwaitingUserApproval: state.contains("waiting_for_user"),
            isAwaitingReboot: state.contains("waiting_for_reboot") || state.contains("reboot"),
            isUninstalling: state.contains("uninstall")
        )
    }
}
