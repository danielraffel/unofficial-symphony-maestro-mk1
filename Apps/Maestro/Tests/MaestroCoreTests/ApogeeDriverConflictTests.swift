import Foundation
import Testing
@testable import MaestroCore

/// What Maestro does while one of Apogee's kernel drivers for the ThunderBridge
/// or PCIe card is loaded: every combination of the four facts.
@Suite("Apogee kernel driver conflict: the decision")
struct ApogeeDriverConflictTests {
    typealias State = ApogeeDriverConflict.State

    struct Case: Sendable, CustomTestStringConvertible {
        let kextLoaded: Bool, copyOnDisk: Bool, driverActive: Bool, updatePending: Bool
        let state: State, mayActivate: Bool, mayStop: Bool, mayUpdate: Bool, updateNote: Bool
        var testDescription: String {
            "loaded=\(kextLoaded) copy=\(copyOnDisk) active=\(driverActive) pending=\(updatePending)"
        }
    }

    /// All sixteen, written out: loaded, copy on disk, Maestro's driver active, update pending.
    static let cases: [Case] = [
        // Nothing of Apogee's for the card: everything allowed, no notice.
        .init(kextLoaded: false, copyOnDisk: false, driverActive: false, updatePending: false,
              state: .clear, mayActivate: true, mayStop: true, mayUpdate: true, updateNote: false),
        .init(kextLoaded: false, copyOnDisk: false, driverActive: false, updatePending: true,
              state: .clear, mayActivate: true, mayStop: true, mayUpdate: true, updateNote: false),
        .init(kextLoaded: false, copyOnDisk: false, driverActive: true, updatePending: false,
              state: .clear, mayActivate: true, mayStop: true, mayUpdate: true, updateNote: false),
        .init(kextLoaded: false, copyOnDisk: false, driverActive: true, updatePending: true,
              state: .clear, mayActivate: true, mayStop: true, mayUpdate: true, updateNote: false),
        // A copy on disk or staged, not loaded: today's warning, nothing blocked.
        .init(kextLoaded: false, copyOnDisk: true, driverActive: false, updatePending: false,
              state: .copyNotLoaded, mayActivate: true, mayStop: true, mayUpdate: true, updateNote: false),
        .init(kextLoaded: false, copyOnDisk: true, driverActive: false, updatePending: true,
              state: .copyNotLoaded, mayActivate: true, mayStop: true, mayUpdate: true, updateNote: false),
        .init(kextLoaded: false, copyOnDisk: true, driverActive: true, updatePending: false,
              state: .copyNotLoaded, mayActivate: true, mayStop: true, mayUpdate: true, updateNote: false),
        .init(kextLoaded: false, copyOnDisk: true, driverActive: true, updatePending: true,
              state: .copyNotLoaded, mayActivate: true, mayStop: true, mayUpdate: true, updateNote: false),
        // Loaded, Maestro's driver not active: it is not started.
        .init(kextLoaded: true, copyOnDisk: false, driverActive: false, updatePending: false,
              state: .driverHeld, mayActivate: false, mayStop: false, mayUpdate: false, updateNote: false),
        .init(kextLoaded: true, copyOnDisk: false, driverActive: false, updatePending: true,
              state: .driverHeld, mayActivate: false, mayStop: false, mayUpdate: false, updateNote: true),
        .init(kextLoaded: true, copyOnDisk: true, driverActive: false, updatePending: false,
              state: .driverHeld, mayActivate: false, mayStop: false, mayUpdate: false, updateNote: false),
        .init(kextLoaded: true, copyOnDisk: true, driverActive: false, updatePending: true,
              state: .driverHeld, mayActivate: false, mayStop: false, mayUpdate: false, updateNote: true),
        // Loaded, Maestro's driver active as well: not replaced, not stopped.
        .init(kextLoaded: true, copyOnDisk: false, driverActive: true, updatePending: false,
              state: .bothActive, mayActivate: false, mayStop: false, mayUpdate: false, updateNote: false),
        .init(kextLoaded: true, copyOnDisk: false, driverActive: true, updatePending: true,
              state: .bothActive, mayActivate: false, mayStop: false, mayUpdate: false, updateNote: true),
        .init(kextLoaded: true, copyOnDisk: true, driverActive: true, updatePending: false,
              state: .bothActive, mayActivate: false, mayStop: false, mayUpdate: false, updateNote: false),
        .init(kextLoaded: true, copyOnDisk: true, driverActive: true, updatePending: true,
              state: .bothActive, mayActivate: false, mayStop: false, mayUpdate: false, updateNote: true),
    ]

    @Test("The table has every combination once")
    func tableIsComplete() {
        let keys = Set(Self.cases.map { [$0.kextLoaded, $0.copyOnDisk, $0.driverActive, $0.updatePending] })
        #expect(keys.count == 16 && Self.cases.count == 16)
    }

    @Test("Each combination", arguments: cases)
    func decision(_ c: Case) {
        let d = ApogeeDriverConflict.decide(kextLoaded: c.kextLoaded, copyOnDisk: c.copyOnDisk,
                                            maestroDriverActive: c.driverActive, updatePending: c.updatePending)
        #expect(d.state == c.state)
        #expect(d.mayRequestActivation == c.mayActivate)
        #expect(d.mayStopMaestroDriver == c.mayStop)
        #expect(d.mayUpdate == c.mayUpdate)
        #expect(d.showsUpdateNote == c.updateNote)
        // The text follows the state.
        #expect((d.consequence != nil) == c.kextLoaded)
        #expect((d.what != nil) == c.kextLoaded)
        #expect((d.banner != nil) == c.kextLoaded)
        #expect((d.caution != nil) == (c.kextLoaded && c.driverActive))
        #expect((d.updateNote != nil) == c.updateNote)
    }

    @Test("The text: the installer's opening, the consequence, the caution, the update sentence and the installer's steps")
    func text() {
        #expect(ApogeeDriverConflict.detected == "Apogee's original Symphony I/O drivers were detected.")
        #expect(ApogeeDriverConflict.crashRisk == "Running both can crash your Mac and make it restart repeatedly.")
        #expect(ApogeeDriverConflict.consequence
            == "Maestro's driver is not being updated or started until Apogee's driver is removed.")
        let held = ApogeeDriverConflict.decide(kextLoaded: true, copyOnDisk: false, maestroDriverActive: false,
                                               updatePending: true)
        #expect(held.what == ApogeeDriverConflict.crashRisk)
        #expect(held.updateNote == "You are seeing this after updating because this version now checks for them. "
            + "Earlier versions did not check.")
        #expect(held.banner?.title == "Apogee's original Symphony I/O drivers were detected")
        #expect(held.banner?.message == ApogeeDriverConflict.crashRisk + " " + ApogeeDriverConflict.consequence
            + " Device Settings has the steps.")
        let both = ApogeeDriverConflict.decide(kextLoaded: true, copyOnDisk: true, maestroDriverActive: true,
                                               updatePending: false)
        #expect(both.what == "Apogee's driver and Maestro's driver are both running now. "
            + ApogeeDriverConflict.crashRisk)
        // Both running: the user guide's safest order. Shut down and disconnect
        // first, never "unplug" or "uninstall" with the card live.
        #expect(both.caution == "Do not unplug the ThunderBridge or PCIe chassis while your Mac is on, and do not "
            + "update Maestro. Shut down your Mac and disconnect the ThunderBridge or PCIe chassis, then start up "
            + "again, before you remove Apogee's drivers.")
        #expect(both.banner?.title == "Do not unplug the ThunderBridge or update Maestro")
        // On the PCIe card the title names that card.
        let pcie = PortStatusMessage.cardPhrase(pciIdentifier: "pci19c2,2100")
        #expect(both.banner(card: pcie)?.title == "Do not unplug the Symphony 64 PCIe card or update Maestro")
        #expect(both.banner(card: PortStatusMessage.cardPhrase(pciIdentifier: "pci19c2,2200"))?.title
            == both.banner?.title)
        #expect(both.banner(card: pcie)?.message == both.banner?.message)
        #expect(held.banner(card: pcie)?.title == held.banner?.title)
        #expect(both.banner?.message == ApogeeDriverConflict.detected + " One is running alongside Maestro's driver. "
            + ApogeeDriverConflict.crashRisk + " Shut down your Mac and disconnect the ThunderBridge or PCIe "
            + "chassis, then start up again. Device Settings has the steps.")
        #expect(both.banner?.message.contains("uninstaller") == false)
        #expect(both.updateNote == nil)
        // Apogee's uninstaller, restart, install again: never a command of ours.
        #expect(ApogeeDriverConflict.fixSteps.count == 4)
        #expect(ApogeeDriverConflict.fixSteps[0].contains("Apogee's latest installer"))
        #expect(ApogeeDriverConflict.fixSteps[1].contains("**Uninstall**"))
        #expect(ApogeeDriverConflict.fixSteps[2] == "Restart your Mac")
        #expect(ApogeeDriverConflict.fixSteps[3].hasPrefix("Install Maestro again"))
        let all = [ApogeeDriverConflict.heldWhat, ApogeeDriverConflict.bothActiveWhat,
                   ApogeeDriverConflict.bothActiveCaution, ApogeeDriverConflict.consequence,
                   ApogeeDriverConflict.updateNote, ApogeeDriverConflict.heldBannerMessage,
                   ApogeeDriverConflict.bothActiveBannerMessage, ApogeeDriverConflict.updateRefusal]
            + ApogeeDriverConflict.fixSteps
        for line in all {
            #expect(!line.contains("kmutil") && !line.contains("sudo") && !line.lowercased().contains("experimental"))
        }
        #expect(ApogeeDriverConflict.updateRefusal.contains(ApogeeDriverConflict.crashRisk))
    }

    private let thunderBridge = "com.apogeedigital.driver.Symphony64ThunderBridge"

    @Test("From a finding: only the ThunderBridge and PCIe kernel drivers count, and only when loaded")
    func fromFinding() {
        func finding(files: Set<String>, loaded: Set<String>) -> OriginalApogeeDriverFinding {
            OriginalApogeeDrivers.detect(fileExists: files.contains, loadedBundleIDs: loaded)
        }
        let staged = "\(OriginalApogeeDrivers.stagedExtensionsDirectory)/Symphony64Thunderbridge.kext/Contents/Info.plist"
        // Loaded, file gone.
        var d = finding(files: [], loaded: [thunderBridge]).conflict(maestroDriverActive: false, updatePending: false)
        #expect(d.state == .driverHeld && !d.mayRequestActivation)
        d = finding(files: [], loaded: ["com.apogeedigital.driver.Symphony64"])
            .conflict(maestroDriverActive: true, updatePending: true)
        #expect(d.state == .bothActive && !d.mayRequestActivation && !d.mayStopMaestroDriver && d.showsUpdateNote)
        // Staged, not loaded: the warning as it was, activation allowed.
        d = finding(files: [staged], loaded: []).conflict(maestroDriverActive: false, updatePending: true)
        #expect(d.state == .copyNotLoaded && d.mayRequestActivation && d.consequence == nil)
        // Staged and loaded.
        d = finding(files: [staged], loaded: [thunderBridge]).conflict(maestroDriverActive: false, updatePending: false)
        #expect(d.state == .driverHeld)
        // The USB override kext loaded, launch daemons, plug-ins, SymphonyMobile: not this.
        let leftovers: Set<String> = [
            "/Library/LaunchDaemons/com.SymphonyDaemon.plist",
            "\(OriginalApogeeDrivers.symphonySystemsDirectory)/SymphonyPlugin.bundle/Contents/Info.plist",
            "/Library/Extensions/SymphonyIOUSBOverideDriver.kext/Contents/Info.plist",
            "/Library/Extensions/SymphonyMobile.kext/Contents/Info.plist",
        ]
        let usb = finding(files: leftovers, loaded: ["com.apogee.driver.ApogeeUSBSymphonyIOAudio"])
        #expect(usb.items.count == 4 && !usb.hasLoadedPCIKernelDriver && !usb.hasUnloadedPCIKernelDriverCopy)
        d = usb.conflict(maestroDriverActive: true, updatePending: true)
        #expect(d.state == .clear && d.mayRequestActivation && d.mayUpdate)
        #expect(Set(OriginalApogeeDrivers.pciKernelExtensionBundleIDs)
            .isSubset(of: Set(OriginalApogeeDrivers.kernelExtensionBundleIDs)))
    }
}
