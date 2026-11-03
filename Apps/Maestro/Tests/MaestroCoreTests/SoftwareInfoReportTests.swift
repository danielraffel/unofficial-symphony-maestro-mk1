import Testing
@testable import MaestroCore

/// Software Info panel / Copy button tests.
///
/// Same shape as `DeviceInfoReportTests`: the panel's text is a pure function of
/// the report's fields, so the clipboard output and the two "you are not running
/// what you think you are running" notices are testable without hardware.
@Suite("Software Info report")
struct SoftwareInfoReportTests {

    private func report(
        buildNumber: Int = 585,
        gitHash: String = "483d8e7",
        installedDextVersion: String? = "0.10.0 (54)",
        registeredDextCount: Int = 1,
        bundledDextBuild: String? = "54",
        installedDextBuild: String? = "54",
        dextLookupFailed: Bool = false,
        dextEnabled: Bool = true,
        dextAwaitingApproval: Bool = false,
        dextAwaitingReboot: Bool = false,
        thunderBridgePresent: Bool = true,
        pciDeviceIdentifier: String? = "pci19c2,2200"
    ) -> SoftwareInfoReport {
        SoftwareInfoReport(
            appVersion: "0.8.4",
            buildNumber: buildNumber,
            gitHash: gitHash,
            appPath: "/Applications/Maestro.app",
            osVersion: "26.0 (Build 25A123)",
            audioPath: "Thunderbolt (ThunderBridge driver extension)",
            installedDextVersion: installedDextVersion,
            registeredDextCount: registeredDextCount,
            bundledDextBuild: bundledDextBuild,
            installedDextBuild: installedDextBuild,
            dextLookupFailed: dextLookupFailed,
            dextEnabled: dextEnabled,
            dextAwaitingApproval: dextAwaitingApproval,
            dextAwaitingReboot: dextAwaitingReboot,
            thunderBridgePresent: thunderBridgePresent,
            pciDeviceIdentifier: pciDeviceIdentifier
        )
    }

    // MARK: - Version line

    @Test func versionLineCarriesBuildAndCommit() {
        #expect(report().versionLine == "0.8.4 (build 585 · 483d8e7)")
    }

    /// A `swift run` build has no generated build info. Printing "build 0" would be
    /// worse than printing nothing.
    @Test func versionLineIsBareWhenThereIsNoBuildNumber() {
        #expect(report(buildNumber: 0, gitHash: "").versionLine == "0.8.4")
    }

    @Test func versionLineOmitsAnEmptyCommitHash() {
        #expect(report(gitHash: "").versionLine == "0.8.4 (build 585)")
    }

    @Test func clipboardIncludesPCIIdentity() {
        #expect(report().clipboardText.contains("PCI device: pci19c2,2200"))
        #expect(report(pciDeviceIdentifier: "pci19c2,2100").clipboardText.contains("PCI device: pci19c2,2100"))
    }

    // MARK: - Driver extension line

    @Test func dextLineIsJustTheVersionWhenOneIsRegistered() {
        #expect(report().dextLine == "0.10.0 (54)")
    }

    /// The normal state for a USB-only user, who never needs one.
    @Test func dextLineSaysNotInstalledWhenThereIsNone() {
        let r = report(installedDextVersion: nil, registeredDextCount: 0,
                       installedDextBuild: nil)
        #expect(r.dextLine == "Not installed")
        #expect(r.dextNotice == nil)
    }

    @Test func dextLineCountsExtraRegisteredCopies() {
        #expect(report(registeredDextCount: 2, bundledDextBuild: "55", installedDextBuild: "54").dextLine
                == "0.10.0 (54) — 2 versions registered")
    }

    // MARK: - Settings status

    @Test func enabledThunderBridgeReportsEnabledVersion() {
        #expect(report().dextStatusLine == "Enabled — 0.10.0 (54)")
        #expect(!report().dextNeedsAction)
        #expect(!report().shouldShowThunderBridgeBanner)
    }

    @Test func USBOnlyUserSeesReadyWithoutAnAction() {
        let r = report(installedDextVersion: nil, registeredDextCount: 0,
                       bundledDextBuild: "54", installedDextBuild: nil,
                       thunderBridgePresent: false)
        #expect(r.dextStatusLine == "Ready — no ThunderBridge connected")
        #expect(!r.dextNeedsAction)
        #expect(!r.shouldShowThunderBridgeBanner)
    }

    @Test func PresentThunderBridgeWithoutRegistrationOffersInstall() {
        let r = report(installedDextVersion: nil, registeredDextCount: 0,
                       bundledDextBuild: "54", installedDextBuild: nil,
                       thunderBridgePresent: true)
        #expect(r.dextStatusLine == "Not registered — install or approve the driver")
        #expect(r.dextNeedsAction)
        #expect(r.shouldShowThunderBridgeBanner)
    }

    @Test func AwaitingApprovalIsDistinctFromDisabled() {
        let awaiting = report(dextEnabled: false, dextAwaitingApproval: true)
        #expect(awaiting.dextStatusLine == "Installed — approval required")
        let disabled = report(dextEnabled: false, dextAwaitingApproval: false)
        #expect(disabled.dextStatusLine == "Installed — disabled")
        #expect(awaiting.dextNeedsAction)
        #expect(disabled.dextNeedsAction)
        #expect(awaiting.shouldShowThunderBridgeBanner)
        #expect(disabled.shouldShowThunderBridgeBanner)
    }

    @Test func AwaitingRebootIsExplicit() {
        let r = report(dextEnabled: false, dextAwaitingReboot: true)
        #expect(r.dextStatusLine == "Installed — restart required")
        #expect(r.dextNeedsAction)
        #expect(!r.shouldShowThunderBridgeBanner)
    }

    @Test func RegisteredOlderBuildOffersUpgradeAction() {
        let r = report(bundledDextBuild: "55", installedDextBuild: "54")
        #expect(r.dextNeedsAction)
        #expect(r.dextUpgradePending)
        #expect(r.dextStatusLine == "Upgrade pending — 0.10.0 (54)")
        #expect(r.shouldShowThunderBridgeBanner)
    }

    @Test func multipleRegisteredCopiesKeepUpgradeActionVisible() {
        let r = report(registeredDextCount: 2, bundledDextBuild: "55", installedDextBuild: "54")
        #expect(r.dextNeedsAction)
        #expect(r.dextStatusLine == "Upgrade pending — 0.10.0 (54)")
        #expect(r.shouldShowThunderBridgeBanner)
    }

    @Test func activeBundledBuildWithTerminatingOlderCopyIsInformationalCleanup() {
        let r = report(registeredDextCount: 2,
                       bundledDextBuild: "54", installedDextBuild: "54")
        #expect(r.dextCleanupPending)
        #expect(!r.dextUpgradePending)
        #expect(!r.dextNeedsAction)
        #expect(r.dextStatusLine == "Enabled — 0.10.0 (54) (cleanup finishing)")
        #expect(r.dextLine.contains("active; older copy finishing cleanup"))
        #expect(r.dextNotice == nil)
        #expect(!r.shouldShowThunderBridgeBanner)
    }

    @Test func MissingEmbeddedDextDoesNotOfferAnAction() {
        let r = report(installedDextVersion: nil, registeredDextCount: 0,
                       bundledDextBuild: nil, installedDextBuild: nil,
                       thunderBridgePresent: true)
        #expect(r.dextStatusLine == "Not included — reinstall Maestro")
        #expect(!r.dextNeedsAction)
        #expect(!r.shouldShowThunderBridgeBanner)
    }

    /// "We could not ask" is not "nothing is installed". An app signed without
    /// `system-extension.install` — a plain deploy.sh build — gets the first.
    @Test func aFailedLookupSaysUnknownRatherThanNotInstalled() {
        let r = report(installedDextVersion: nil, registeredDextCount: 0,
                       installedDextBuild: nil, dextLookupFailed: true)
        #expect(r.dextLine == "Unknown — could not query the system")
        #expect(r.dextNotice == nil)
        #expect(!r.shouldShowThunderBridgeBanner)
    }

    // MARK: - Notices

    @Test func noNoticeWhenBundledAndRegisteredBuildsAgree() {
        #expect(report().dextNotice == nil)
    }

    /// A half-applied upgrade: the outgoing dext cannot exit while it holds the PCI
    /// device, so both stay registered until the cable is replugged.
    @Test func twoRegisteredCopiesAskForAReplug() {
        let notice = report(registeredDextCount: 2, bundledDextBuild: "55", installedDextBuild: "54").dextNotice
        #expect(notice?.contains("More than one version") == true)
        #expect(notice?.contains("disconnect and reconnect the ThunderBridge") == true)
    }

    @Test func aDifferentBundledBuildNamesBothBuildNumbers() {
        let notice = report(bundledDextBuild: "55", installedDextBuild: "54").dextNotice
        #expect(notice?.contains("build 55") == true)
        #expect(notice?.contains("build 54") == true)
    }

    @Test func usbOnlyUserDoesNotSeeThunderBridgeSwapInstruction() {
        let notice = report(bundledDextBuild: "55", installedDextBuild: "54",
                            thunderBridgePresent: false).dextNotice
        #expect(notice == nil)
    }

    /// The count check wins: when both are true, the replug is the same fix and
    /// saying it twice helps nobody.
    @Test func theMultipleCopiesNoticeTakesPrecedence() {
        let notice = report(registeredDextCount: 2,
                            bundledDextBuild: "55", installedDextBuild: "54").dextNotice
        #expect(notice?.contains("More than one version") == true)
    }

    @Test func noNoticeWhenTheAppCarriesNoDext() {
        #expect(report(bundledDextBuild: nil).dextNotice == nil)
    }

    // MARK: - Clipboard

    @Test func clipboardCarriesEveryRowThePanelShows() {
        let text = report().clipboardText
        #expect(text == """
        Maestro: 0.8.4 (build 585 · 483d8e7)
        macOS: 26.0 (Build 25A123)
        App path: /Applications/Maestro.app
        Audio path: Thunderbolt (ThunderBridge driver extension)
        PCI device: pci19c2,2200
        Driver extension: 0.10.0 (54)
        Bundled driver extension: build 54
        """)
    }

    @Test func clipboardOmitsTheBundledLineWhenThereIsNoEmbeddedDext() {
        let text = report(bundledDextBuild: nil).clipboardText
        #expect(!text.contains("Bundled driver extension"))
        #expect(text.contains("Driver extension: 0.10.0 (54)"))
    }

    @Test func clipboardSaysNotInstalledRatherThanOmittingTheRow() {
        let text = report(installedDextVersion: nil, registeredDextCount: 0,
                          bundledDextBuild: nil, installedDextBuild: nil).clipboardText
        #expect(text.contains("Driver extension: Not installed"))
    }
}
