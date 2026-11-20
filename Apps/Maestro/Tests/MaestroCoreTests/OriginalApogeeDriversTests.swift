import Testing
@testable import MaestroCore

@Suite("Apogee's original Symphony I/O MkI drivers")
struct OriginalApogeeDriversTests {
    private let hal = "/Library/Audio/Plug-Ins/HAL/Apogee/Symphony Systems"

    private func detect(_ files: Set<String> = [], loaded: Set<String> = []) -> OriginalApogeeDriverFinding {
        OriginalApogeeDrivers.detect(fileExists: { files.contains($0) }, loadedBundleIDs: loaded)
    }

    @Test("Nothing installed: nothing found, and the report says so")
    func nothing() {
        let finding = detect()
        #expect(finding.isEmpty)
        #expect(finding.reportText == "Original Apogee Symphony I/O drivers: none found")
    }

    @Test("Each HAL plug-in is found by its Info.plist", arguments: [
        "SymphonyPlugin.bundle", "SymphonyIOUSBPlugIn.bundle", "usbApogeePlugin.bundle",
    ])
    func halPlugIn(_ bundle: String) {
        let finding = detect(["\(hal)/\(bundle)/Contents/Info.plist"])
        #expect(finding.items == [.init(kind: .audioPlugIn, path: "\(hal)/\(bundle)", bundleID: nil, loaded: false)])
        #expect(finding.lines == ["Audio plug-in: \(hal)/\(bundle)"])
    }

    @Test("Each kext is found on disk in /Library/Extensions and /System/Library/Extensions")
    func kextFiles() {
        for directory in ["/Library/Extensions", "/System/Library/Extensions"] {
            for kext in OriginalApogeeDrivers.kernelExtensions {
                let path = "\(directory)/\(kext.file)"
                let finding = detect(["\(path)/Contents/Info.plist"])
                #expect(finding.items == [.init(kind: .kernelExtension, path: path, bundleID: kext.bundleID, loaded: false)])
            }
        }
    }

    @Test("The ThunderBridge kext from issue 31: on disk and loaded, one line")
    func thunderBridgeInstalledAndLoaded() {
        let path = "/Library/Extensions/Symphony64Thunderbridge.kext"
        let id = "com.apogeedigital.driver.Symphony64ThunderBridge"
        let finding = detect(["\(path)/Contents/Info.plist"], loaded: [id])
        #expect(finding.lines == ["Kernel extension: \(path) (\(id), loaded)"])
        #expect(finding.reportText.contains("FOUND"))
        #expect(finding.reportText.contains(path))
    }

    @Test("A kext still loaded after its file was removed (needs a restart)", arguments: [
        "com.apogeedigital.driver.Symphony64ThunderBridge",
        "com.apogeedigital.driver.Symphony64",
        "com.apogee.driver.ApogeeUSBSymphonyIOAudio",
    ])
    func loadedOnly(_ id: String) {
        let finding = detect(loaded: [id])
        #expect(finding.items == [.init(kind: .kernelExtension, path: nil, bundleID: id, loaded: true)])
        #expect(finding.lines == ["Kernel extension: \(id) (loaded; restart to unload)"])
    }

    @Test("Only a loaded kext with no file left: awaiting a restart, not another Uninstall")
    func awaitingRestart() {
        let id = "com.apogeedigital.driver.Symphony64ThunderBridge"
        #expect(detect(loaded: [id]).isAwaitingRestartOnly)
        #expect(!detect().isAwaitingRestartOnly)
        #expect(!detect(["/Library/Extensions/Symphony64Thunderbridge.kext/Contents/Info.plist"], loaded: [id])
            .isAwaitingRestartOnly)
        #expect(!detect(["/Library/LaunchDaemons/com.SymphonyDaemon.plist"], loaded: [id]).isAwaitingRestartOnly)
        #expect(OriginalApogeeDrivers.restartAdvice.contains("Restart your Mac"))
    }

    @Test("Each Symphony launch daemon is found", arguments: [
        "com.SymphonyDaemon.plist", "com.SymphonyIOUSBDaemon.plist",
    ])
    func launchDaemon(_ plist: String) {
        let path = "/Library/LaunchDaemons/\(plist)"
        #expect(detect([path]).items == [.init(kind: .launchDaemon, path: path, bundleID: nil, loaded: false)])
    }

    @Test("Bundles renamed .disabled-maestro or .disabled-asp are ignored")
    func disabledBundlesIgnored() {
        let files: Set<String> = [
            "\(hal)/SymphonyPlugin.bundle/Contents/Info.plist.disabled-maestro",
            "\(hal)/SymphonyIOUSBPlugIn.bundle/Contents/Info.plist.disabled-asp",
            "\(hal)/usbApogeePlugin.bundle.disabled-maestro/Contents/Info.plist",
            "\(hal)/SymphonyPlugin.bundle.disabled-asp/Contents/Info.plist",
            // A bundle directory with no Info.plist is not an active bundle.
            "\(hal)/SymphonyPlugin.bundle",
            "/Library/Extensions/Symphony64Thunderbridge.kext",
        ]
        #expect(detect(files).isEmpty)
    }

    @Test("Maestro's own drivers, Apogee Maestro 2, Apogee Control and other Apogee products are not flagged")
    func othersNotFlagged() {
        let files: Set<String> = [
            // Maestro's own Core Audio plug-in, dext and helper.
            "/Library/Audio/Plug-Ins/HAL/ApogeeSymIO.driver/Contents/Info.plist",
            "/Library/LaunchDaemons/com.danielraffel.Maestro.volumeproxy.plist",
            // Shipped in the same Release 5.5 package but shared with other products.
            "/Applications/Apogee Maestro 2.app/Contents/Info.plist",
            "/Library/Application Support/Apogee/ApogeePopup.bundle/Contents/Info.plist",
            "/Library/Frameworks/ApogeeServices.framework/Contents/Info.plist",
            "/Library/LaunchAgents/com.ApogeePopup.plist",
            "/Library/LaunchDaemons/com.usbApogeeDaemon.plist",
            // Symphony I/O MkII and other Apogee products.
            "/Applications/Apogee Control 2.app/Contents/Info.plist",
            "/Library/Audio/Plug-Ins/HAL/Apogee/Symphony I/O Mk II/SymphonyIO2.driver/Contents/Info.plist",
            "/Library/Audio/Plug-Ins/HAL/ApogeeSymphonyIO2T.driver/Contents/Info.plist",
            "/Library/Extensions/DuetUSBOverideDriver.kext/Contents/Info.plist",
            "/Library/Extensions/QuartetUSBOverideDriver.kext/Contents/Info.plist",
        ]
        let loaded: Set<String> = [
            "com.danielraffel.maestro.thunderbridge",
            "com.apogee.driver.ApogeeUSBDuetAudio",
            "com.apogee.driver.ApogeeUSBQuartetAudio",
            "com.apogeedigital.driver.Symphony64ThunderBridgeMkII", // not an exact match
        ]
        #expect(detect(files, loaded: loaded).isEmpty)
    }

    @Test("Several components: listed in report order, a loaded kext not repeated")
    func several() {
        let finding = detect([
            "/Library/LaunchDaemons/com.SymphonyDaemon.plist",
            "\(hal)/SymphonyPlugin.bundle/Contents/Info.plist",
            "/Library/Extensions/Symphony64.kext/Contents/Info.plist",
        ], loaded: ["com.apogeedigital.driver.Symphony64", "com.apogeedigital.driver.Symphony64ThunderBridge"])
        #expect(finding.lines == [
            "Audio plug-in: \(hal)/SymphonyPlugin.bundle",
            "Kernel extension: /Library/Extensions/Symphony64.kext (com.apogeedigital.driver.Symphony64, loaded)",
            "Launch daemon: /Library/LaunchDaemons/com.SymphonyDaemon.plist",
            "Kernel extension: com.apogeedigital.driver.Symphony64ThunderBridge (loaded; restart to unload)",
        ])
    }

    @Test("Symphony plug-ins in their pre-10.9 home count; usbApogeePlugin there does not")
    func oldPlugInLocation() {
        let finding = detect([
            "/Library/Extensions/SymphonyPlugin.bundle/Contents/Info.plist",
            "/System/Library/Extensions/SymphonyIOUSBPlugIn.bundle/Contents/Info.plist",
            "/System/Library/Extensions/usbApogeePlugin.bundle/Contents/Info.plist",
            "/Library/Extensions/usbApogeePlugin.bundle/Contents/Info.plist",
        ])
        #expect(finding.lines == [
            "Audio plug-in: /Library/Extensions/SymphonyPlugin.bundle",
            "Audio plug-in: /System/Library/Extensions/SymphonyIOUSBPlugIn.bundle",
        ])
    }

    @Test("The advice: uninstaller first, then reinstall Maestro; the last resort names parts, not commands")
    func advice() {
        #expect(OriginalApogeeDrivers.removalAdvice.contains("**Uninstall**"))
        #expect(OriginalApogeeDrivers.removalAdvice.contains("reinstall Maestro"))
        #expect(OriginalApogeeDrivers.manualRemovalIntro.hasPrefix("If Apogee's uninstaller won't run on your Mac"))
        #expect(OriginalApogeeDrivers.manualRemovalIntro.contains("Restart afterwards."))
        let text = ([OriginalApogeeDrivers.manualRemovalIntro] + OriginalApogeeDrivers.manualRemovalParts)
            .joined(separator: "\n")
        for forbidden in ["/System", "Maestro.app", "rm ", "`", "sudo", "Terminal"] {
            #expect(!text.contains(forbidden), "\(forbidden)")
        }
        #expect(!text.replacingOccurrences(of: "**", with: "").contains("*"))
        // Every kext the detector looks for by name is named.
        for kext in OriginalApogeeDrivers.kernelExtensions {
            #expect(text.contains("**\(kext.file)**"), "\(kext.file)")
        }
    }

    @Test("The download is the installer warning page's Release 5.5 link")
    func downloadLink() throws {
        #expect(OriginalApogeeDrivers.releaseDMGURL.absoluteString.hasSuffix("/SymphonyIO_Release_5.5.dmg"))
    }
}
