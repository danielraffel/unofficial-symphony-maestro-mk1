// OriginalApogeeDrivers.swift — is Apogee's original Symphony I/O MkI software installed?
//
// Maestro is not supported alongside Apogee's own Symphony I/O MkI drivers. A
// tester's Mac kernel-panicked with Apogee's ThunderBridge kernel extension
// loaded next to Maestro's driver (GitHub issue 31). The installer refuses to
// install over them (Installer/scripts-core/preinstall); this is the app's
// read-only version of the same check, for a Mac where they came back or were
// installed afterwards.
//
// Only the Symphony I/O MkI release installs these. The same release also
// installs Apogee Maestro 2, ApogeePopup and ApogeeServices.framework, which
// other Apogee products share, so those are deliberately not on this list, and
// nothing here matches by substring ("Apogee", "Symphony", "ThunderBridge"):
// Maestro's own dext and ApogeeSymIO.driver plug-in carry those words.
//
// Evidence, all in og_source/symphonymk1:
// - Makefile:92-104 (`symphony_installer`): what Release 5.5 installs, and where.
// - Makefile:76-84 (`symphony_kexts`): the three kexts' bundle identifiers, as signed.
// - ext/Symphony64/Driver/Symphony64Thunderbridge-Info.plist:11-12 and
//   ext/Symphony64/Driver/Info-symphony_64.plist:11-12: the PCIe kexts' identifiers.
// - ext/maestrolink/OverideDriver/SymphonyIOUSBOverideDriver.plist:15-16: the USB
//   override kext's identifier (no other OverideDriver plist uses it).
// - ApogeeUninstaller/uninstaller_info.xml:4-13: the kexts it removes, in both
//   /Library/Extensions and /System/Library/Extensions, including SymphonyMobile.kext.
// - ApogeeUninstaller/uninstaller_info.xml:17-22 and scripts/postflight:24-35: the
//   plug-ins' pre-10.9 home in /Library/Extensions and /System/Library/Extensions.
//   Only the two Symphony-named ones are checked there: usbApogeePlugIn.bundle in
//   /System/Library/Extensions is also where Apogee's other USB products put theirs
//   (ext/maestrolink/Resources/com.usbApogeeDaemon.plist, WorkingDirectory).
// - com.SymphonyDaemon.plist, com.SymphonyIOUSBDaemon.plist: the two launch
//   daemons, which run from the Symphony Systems plug-ins. com.usbApogeeDaemon.plist
//   is left out: other Apogee USB products install a daemon under that name
//   (ext/maestrolink/buildUSBApogeeDaemon:13). So is the ApogeePopup launch agent,
//   which Apogee Maestro 2 uses for every product.
//
// Apogee's Uninstall also deletes /Applications/Maestro.app (uninstaller_info.xml:26,
// an older Apogee app's path that is now Maestro's) and macOS's audio device settings
// (lines 31-34). Every instruction to run it therefore ends with reinstalling Maestro.

import Foundation

/// One piece of Apogee's original Symphony I/O MkI software.
public struct OriginalApogeeComponent: Sendable, Equatable, Hashable {
    public enum Kind: String, Sendable {
        case audioPlugIn = "Audio plug-in"
        case kernelExtension = "Kernel extension"
        case launchDaemon = "Launch daemon"
    }

    public let kind: Kind
    /// The file or bundle Apogee's installer writes.
    public let path: String
    /// The file whose presence means it is installed and active. For a bundle
    /// this is its Contents/Info.plist, so a bundle whose Info.plist has been
    /// renamed (".disabled-maestro", ".disabled-asp") is not counted, as the
    /// installer does.
    public let checkPath: String
    /// The kernel extension's bundle identifier, when known.
    public let bundleID: String?

    public init(kind: Kind, path: String, checkPath: String? = nil, bundleID: String? = nil) {
        self.kind = kind
        self.path = path
        self.checkPath = checkPath ?? path
        self.bundleID = bundleID
    }
}

/// What the check found. Empty when nothing of Apogee's original MkI software is installed.
public struct OriginalApogeeDriverFinding: Sendable, Equatable {
    /// A component found on disk, loaded in the kernel, or both.
    public struct Item: Sendable, Equatable, Hashable {
        public let kind: OriginalApogeeComponent.Kind
        /// The installed path, nil when only the loaded kext was seen.
        public let path: String?
        public let bundleID: String?
        public let loaded: Bool

        public init(kind: OriginalApogeeComponent.Kind, path: String?, bundleID: String?, loaded: Bool) {
            self.kind = kind
            self.path = path
            self.bundleID = bundleID
            self.loaded = loaded
        }

        /// One line for the disclosure and the report.
        public var line: String {
            var detail: [String] = []
            if let bundleID, path != nil { detail.append(bundleID) }
            if loaded { detail.append(path == nil ? "loaded; restart to unload" : "loaded") }
            let subject = path ?? bundleID ?? "?"
            return "\(kind.rawValue): \(subject)" + (detail.isEmpty ? "" : " (\(detail.joined(separator: ", ")))")
        }
    }

    public let items: [Item]

    public init(items: [Item]) { self.items = items }

    public var isEmpty: Bool { items.isEmpty }
    public var lines: [String] { items.map(\.line) }

    /// The block the diagnostics text carries, found or not.
    public var reportText: String {
        guard !isEmpty else { return "Original Apogee Symphony I/O drivers: none found" }
        return (["Original Apogee Symphony I/O drivers: FOUND (not supported alongside Maestro)"]
            + lines.map { "  \($0)" }).joined(separator: "\n")
    }
}

public enum OriginalApogeeDrivers {
    /// Apogee's Symphony I/O Release 5.5 disk image, whose Uninstall removes all of this.
    /// The same link as the installer's warning page (Installer/resources/warning.html).
    public static let releaseDMGURL = URL(string:
        "https://22712264.fs1.hubspotusercontent-na1.net/hubfs/22712264/Software%20Installers/Symphony%20IO/SymphonyIO_Release_5.5.dmg")!

    /// Where Release 5.5 puts its Core Audio plug-ins (Makefile:99-101).
    public static let symphonySystemsDirectory = "/Library/Audio/Plug-Ins/HAL/Apogee/Symphony Systems"

    /// The kernel extensions, by file name and bundle identifier. SymphonyMobile.kext is
    /// an older one the uninstaller still removes (uninstaller_info.xml:7-8); its
    /// identifier is not in the source, so it is found by path only.
    public static let kernelExtensions: [(file: String, bundleID: String?)] = [
        ("Symphony64Thunderbridge.kext", "com.apogeedigital.driver.Symphony64ThunderBridge"),
        ("Symphony64.kext", "com.apogeedigital.driver.Symphony64"),
        ("SymphonyIOUSBOverideDriver.kext", "com.apogee.driver.ApogeeUSBSymphonyIOAudio"),
        ("SymphonyMobile.kext", nil),
    ]

    /// The bundle identifiers to look for among the loaded kernel extensions.
    public static var kernelExtensionBundleIDs: [String] { kernelExtensions.compactMap(\.bundleID) }

    /// Everything checked on disk, in report order.
    public static let components: [OriginalApogeeComponent] = {
        var list: [OriginalApogeeComponent] = []
        for bundle in ["SymphonyPlugin.bundle", "SymphonyIOUSBPlugIn.bundle", "usbApogeePlugin.bundle"] {
            let path = "\(symphonySystemsDirectory)/\(bundle)"
            list.append(.init(kind: .audioPlugIn, path: path, checkPath: "\(path)/Contents/Info.plist"))
        }
        // Their pre-10.9 home (uninstaller_info.xml:17-22). Symphony-named ones only.
        for directory in ["/Library/Extensions", "/System/Library/Extensions"] {
            for bundle in ["SymphonyPlugin.bundle", "SymphonyIOUSBPlugIn.bundle"] {
                let path = "\(directory)/\(bundle)"
                list.append(.init(kind: .audioPlugIn, path: path, checkPath: "\(path)/Contents/Info.plist"))
            }
        }
        for directory in ["/Library/Extensions", "/System/Library/Extensions"] {
            for kext in kernelExtensions {
                let path = "\(directory)/\(kext.file)"
                list.append(.init(kind: .kernelExtension, path: path,
                                  checkPath: "\(path)/Contents/Info.plist", bundleID: kext.bundleID))
            }
        }
        for plist in ["com.SymphonyDaemon.plist", "com.SymphonyIOUSBDaemon.plist"] {
            list.append(.init(kind: .launchDaemon, path: "/Library/LaunchDaemons/\(plist)"))
        }
        return list
    }()

    /// What the warning tells people to do. Apogee's Uninstall also deletes
    /// /Applications/Maestro.app and macOS's audio device settings, hence the
    /// reinstall.
    public static let removalAdvice = "Remove them with **Uninstall** in Apogee's Symphony I/O installer, "
        + "restart your Mac, then reinstall Maestro. Apogee's Uninstall also removes Maestro and resets "
        + "macOS's audio device settings."

    /// The last resort, for a Mac that cannot run Apogee's uninstaller: what has
    /// to go, in general terms, not a procedure. Always behind a collapsed
    /// disclosure, never the primary instruction. Exact names only, nothing in
    /// /System (read-only on current macOS), never Maestro.app, no Terminal
    /// commands. A restart is enough: Apogee's own uninstaller does no more than
    /// delete these, `touch /Library/Extensions` and restart
    /// (ApogeeUninstaller/Source/MainComponent.cpp:128-138). The daemon names are
    /// as installed (Makefile:102-104). The same text is in Help, the Device
    /// Settings warning and docs/UserManual.md.
    public static let manualRemovalIntro = "If Apogee's uninstaller won't run on your Mac, these are the parts "
        + "of Apogee's original Symphony I/O software that need to be removed. We recommend the uninstaller "
        + "whenever it runs. Restart afterwards."

    public static let manualRemovalParts: [String] = [
        "Kernel extensions in **/Library/Extensions**: **Symphony64Thunderbridge.kext**, **Symphony64.kext**, "
            + "**SymphonyIOUSBOverideDriver.kext**, **SymphonyMobile.kext**",
        "Audio plug-ins: the **Symphony Systems** folder in **/Library/Audio/Plug-Ins/HAL/Apogee**",
        "Background helpers: **com.SymphonyDaemon.plist**, **com.usbApogeeDaemon.plist** and "
            + "**com.SymphonyIOUSBDaemon.plist** in **/Library/LaunchDaemons**, and **com.ApogeePopup.plist** "
            + "in **/Library/LaunchAgents**",
    ]

    /// The check itself, over injected lookups so it can be tested.
    ///
    /// - Parameters:
    ///   - fileExists: whether a file exists at an absolute path.
    ///   - loadedBundleIDs: the bundle identifiers of loaded kernel extensions. Only
    ///     the exact identifiers in `kernelExtensionBundleIDs` count.
    public static func detect(fileExists: (String) -> Bool,
                              loadedBundleIDs: Set<String>) -> OriginalApogeeDriverFinding {
        var items: [OriginalApogeeDriverFinding.Item] = []
        var reportedLoaded = Set<String>()
        for component in components where fileExists(component.checkPath) {
            let loaded = component.bundleID.map { loadedBundleIDs.contains($0) } ?? false
            if loaded, let id = component.bundleID { reportedLoaded.insert(id) }
            items.append(.init(kind: component.kind, path: component.path,
                               bundleID: component.bundleID, loaded: loaded))
        }
        // Loaded with its file already gone: Apogee's Uninstall ran, but the
        // kext stays in the kernel until the Mac restarts.
        for id in kernelExtensionBundleIDs where loadedBundleIDs.contains(id) && !reportedLoaded.contains(id) {
            items.append(.init(kind: .kernelExtension, path: nil, bundleID: id, loaded: true))
        }
        return OriginalApogeeDriverFinding(items: items)
    }
}
