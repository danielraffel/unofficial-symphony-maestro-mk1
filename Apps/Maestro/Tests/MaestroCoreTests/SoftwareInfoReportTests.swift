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
        pciDeviceIdentifier: String? = "pci19c2,2200",
        servingDextBuild: ServingDextBuild? = nil
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
            pciDeviceIdentifier: pciDeviceIdentifier,
            servingDextBuild: servingDextBuild
        )
    }

    // MARK: - Version line

    @Test func clipboardNamesTheUpdateChannelWhenKnown() {
        let base = SoftwareInfoReport(appVersion: "0.9.3", appPath: "/Applications/Maestro.app",
                                      osVersion: "27.2", audioPath: "USB")
        #expect(!base.clipboardText.contains("Update channel"))
        var beta = base; beta.updateChannel = .beta
        var stable = base; stable.updateChannel = .stable
        #expect(beta.clipboardText.split(separator: "\n").dropFirst().first == "Update channel: Beta")
        #expect(stable.clipboardText.contains("Update channel: Stable"))
    }

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

    /// Not asked which build serves the card (no ThunderBridge connection
    /// open): an older copy is still registered, and nothing more is claimed.
    @Test func activeBundledBuildWithAnOlderCopyAndNoServingAnswerClaimsNothingMore() {
        let r = report(registeredDextCount: 2,
                       bundledDextBuild: "54", installedDextBuild: "54")
        #expect(r.dextCleanupPending)
        #expect(!r.dextUpgradePending)
        #expect(!r.dextNeedsAction)
        #expect(r.dextStatusLine == "Enabled — 0.10.0 (54) (older copy still registered)")
        #expect(r.dextLine.contains("active; an older copy is still registered"))
        #expect(!r.dextLine.contains("cleanup"))
        #expect(r.dextNotice == nil)
        #expect(!r.shouldShowThunderBridgeBanner)
    }

    /// The bundled build serves the card and the old copy only waits for
    /// sysextd to remove it at the next restart: that is cleanup.
    @Test func activeBundledBuildServingWithAnOlderCopyIsCleanup() {
        let r = report(registeredDextCount: 2, bundledDextBuild: "124", installedDextBuild: "124",
                       servingDextBuild: .build(124))
        #expect(r.dextCleanupPending)
        #expect(!r.driverUpdateUnfinished)
        #expect(r.dextStatusLine == "Enabled — 0.10.0 (54) (cleanup finishing)")
        #expect(r.dextLine.contains("active; older copy finishing cleanup"))
        #expect(r.thunderBridgeBanner == nil)
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
        Audio path: Thunderbolt (ThunderBridge driver extension)
        PCI device: pci19c2,2200
        Driver extension: 0.10.0 (54)
        Bundled driver extension: build 54
        App path: /Applications/Maestro.app
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

    // MARK: - Serving driver build

    /// The 2026-11 report: sysextd lists 122 enabled with an older copy
    /// finishing cleanup, but the card is still served by 121, which predates
    /// the build selector and so does not answer it.
    @Test func olderServingCopyThatCannotReportIsAnUnfinishedUpdate() {
        let r = report(installedDextVersion: "0.10.17 (123)", registeredDextCount: 2,
                       bundledDextBuild: "123", installedDextBuild: "123",
                       servingDextBuild: .olderThanBuildReporting)
        #expect(r.servingDextDiffersFromBundled)
        #expect(r.driverUpdateUnfinished)
        #expect(!r.dextCleanupPending)
        #expect(r.dextLine == "0.10.17 (123) installed; a build before 123 still serves the ThunderBridge — update not finished")
        #expect(!r.dextLine.contains("cleanup"))
        #expect(r.dextStatusLine == "Driver update not finished")
        #expect(r.dextNotice == r.driverUpdateGuidance)
        #expect(r.dextNotice?.contains("(a build before 123)") == true)
        #expect(r.clipboardText.contains("Serving driver extension: a build before 123"))
        #expect(r.shouldShowThunderBridgeBanner)
        #expect(r.thunderBridgeBanner?.message == ThunderBridgeBanner.unfinishedUpdateMessage)
    }

    @Test func servingBuildThatDiffersIsNamed() {
        let r = report(installedDextVersion: "0.10.18 (124)", registeredDextCount: 2,
                       bundledDextBuild: "124", installedDextBuild: "124",
                       servingDextBuild: .build(123))
        #expect(r.servingDextDiffersFromBundled)
        #expect(r.dextLine.contains("build 123 still serves the ThunderBridge"))
        #expect(r.dextNotice == "The ThunderBridge is still using the previous Maestro driver (build 123); "
                + "this Maestro carries build 124, so the driver update is not finished. "
                + "To finish it, reconnect the ThunderBridge cable, or turn the Maestro driver off and on "
                + "in System Settings › General › Login Items & Extensions › Driver Extensions, "
                + "or restart your Mac.")
    }

    // MARK: - Unfinished update (2026-11-14: 122 registered and enabled, 121 still on the card)

    private func loggedUpgrade(serving: ServingDextBuild? = .build(123)) -> SoftwareInfoReport {
        report(installedDextVersion: "0.10.18 (124)", registeredDextCount: 2,
               bundledDextBuild: "124", installedDextBuild: "124",
               servingDextBuild: serving)
    }

    @Test func twoCopiesWithAnotherBuildServingIsNeverCleanup() {
        let r = loggedUpgrade()
        #expect(r.driverUpdateUnfinished)
        #expect(!r.dextCleanupPending)
        #expect(r.dextUpgradePending)
        #expect(r.dextNeedsAction)
        #expect(r.dextActionOpensSettings)
        for text in [r.dextLine, r.dextStatusLine, r.dextNotice ?? "", r.thunderBridgeBanner?.message ?? ""] {
            #expect(!text.contains("cleanup"))
        }
    }

    @Test func unfinishedUpdateBannerIsPersistentAndMatchesDeviceInfo() throws {
        let r = loggedUpgrade()
        let banner = try #require(r.thunderBridgeBanner)
        #expect(banner.title == "Unplug the ThunderBridge cable and plug it back in")
        #expect(banner.message == "This finishes the Maestro driver update. Audio stops for a few seconds.")
        #expect(banner.secondaryMessage
                == "Other ways: turn the Maestro driver off and on in System Settings, or restart your Mac.")
        // Build numbers live in Device Info, not the banner.
        for text in [banner.title, banner.message, banner.secondaryMessage ?? ""] {
            #expect(!text.contains("build"))
            #expect(!text.contains("123"))
            #expect(!text.contains("124"))
        }
        #expect(r.dextNotice?.contains("previous Maestro driver (build 123)") == true)
        #expect(banner.action == .openDriverSettings)
        #expect(!banner.dismissible)
        #expect(!banner.inProgress)
    }

    /// Reconnect first, then off and on in the named pane, then restart.
    @Test func guidanceOffersTheThreeWaysInOrder() throws {
        let text = try #require(loggedUpgrade().driverUpdateGuidance)
        let reconnect = try #require(text.range(of: "reconnect the ThunderBridge cable"))
        let toggle = try #require(text.range(of: "turn the Maestro driver off and on"))
        let pane = try #require(text.range(of: "System Settings › General › Login Items & Extensions › Driver Extensions"))
        let restart = try #require(text.range(of: "restart your Mac"))
        #expect(reconnect.lowerBound < toggle.lowerBound)
        #expect(toggle.lowerBound < pane.lowerBound)
        #expect(pane.lowerBound < restart.lowerBound)
    }

    @Test func bannerStaysUntilTheServingBuildMatches() {
        #expect(loggedUpgrade(serving: .build(123)).thunderBridgeBanner != nil)
        #expect(loggedUpgrade(serving: .olderThanBuildReporting).thunderBridgeBanner != nil)
        let done = loggedUpgrade(serving: .build(124))
        #expect(!done.driverUpdateUnfinished)
        #expect(done.thunderBridgeBanner == nil)
    }

    /// No "Finish Update Now", no in-progress or timed-out state: the one
    /// instruction is the cable, in every unfinished-update variant.
    @Test func noFinishUpdateNowIsOfferedAnywhere() throws {
        for serving: ServingDextBuild? in [.build(123), .build(9005), .olderThanBuildReporting, .build(122)] {
            let banner = try #require(loggedUpgrade(serving: serving).thunderBridgeBanner)
            #expect(banner.title == ThunderBridgeBanner.unfinishedUpdateTitle)
            #expect(!banner.inProgress)
            #expect(!banner.dismissible)
            #expect(banner.action == .openDriverSettings)
            let all = [banner.title, banner.message, banner.secondaryMessage ?? ""].joined(separator: " ")
            #expect(!all.contains("Finish Update"))
            #expect(!all.contains("did not come back"))
        }
        // Not asked: no claim, so no unfinished-update banner.
        #expect(loggedUpgrade(serving: nil).thunderBridgeBanner == nil)
    }

    @Test func otherBannersKeepTheirWordingAndCanBeDismissed() throws {
        let approval = try #require(report(dextEnabled: false, dextAwaitingApproval: true).thunderBridgeBanner)
        #expect(approval.message == "ThunderBridge is connected. Approve the Maestro ThunderBridge driver extension in System Settings.")
        #expect(approval.action == .openDriverSettings)
        #expect(approval.dismissible)
        let disabled = try #require(report(dextEnabled: false).thunderBridgeBanner)
        #expect(disabled.message == "ThunderBridge is connected. Enable the Maestro ThunderBridge driver extension in System Settings.")
        let missing = try #require(report(installedDextVersion: nil, registeredDextCount: 0,
                                          installedDextBuild: nil).thunderBridgeBanner)
        #expect(missing.action == .activate)
        let upgrade = try #require(report(bundledDextBuild: "55", installedDextBuild: "54").thunderBridgeBanner)
        #expect(upgrade.message.hasPrefix("The Maestro ThunderBridge driver extension is updating."))
        #expect(upgrade.action == .openDriverSettings)
        // USB-only and failed lookups never get one.
        #expect(report(thunderBridgePresent: false, servingDextBuild: .build(1)).thunderBridgeBanner == nil)
        #expect(loggedUpgrade().withLookupFailed.thunderBridgeBanner == nil)
    }

    @Test func servingBuildThatMatchesKeepsTheUsualLines() {
        let r = report(registeredDextCount: 2, bundledDextBuild: "123", installedDextBuild: "123",
                       servingDextBuild: .build(123))
        #expect(!r.servingDextDiffersFromBundled)
        #expect(r.dextLine.contains("active; older copy finishing cleanup"))
        #expect(r.dextStatusLine.hasPrefix("Enabled"))
        #expect(r.clipboardText.contains("Serving driver extension: build 123"))
    }

    /// The bundled build is not the registered one yet (the swap has not been
    /// submitted or approved): a restart alone does not finish that, so the
    /// upgrade-pending lines stand. The serving build is still in the details.
    @Test func restartIsNotAdvisedBeforeTheBundledBuildIsInstalled() {
        let r = report(installedDextVersion: "0.10.16 (121)", bundledDextBuild: "123",
                       installedDextBuild: "121", servingDextBuild: .olderThanBuildReporting)
        #expect(r.servingDextDiffersFromBundled)
        #expect(!r.restartFinishesDriverUpdate)
        #expect(r.dextStatusLine == "Upgrade pending — 0.10.16 (121)")
        #expect(r.dextLine == "0.10.16 (121)")
        #expect(r.dextNotice?.contains("Restart your Mac") == false)
        #expect(r.dextNotice?.contains("reconnect it to let the swap finish") == true)
        #expect(r.clipboardText.contains("Serving driver extension: a build before 123"))
    }

    /// The bundled build is registered but waits for approval or is disabled:
    /// the approval and disabled lines stand.
    @Test func restartIsNotAdvisedWhileTheBundledBuildWaitsForApproval() {
        let waiting = report(installedDextVersion: "0.10.17 (123)", bundledDextBuild: "123",
                             installedDextBuild: "123", dextEnabled: false, dextAwaitingApproval: true,
                             servingDextBuild: .olderThanBuildReporting)
        #expect(!waiting.restartFinishesDriverUpdate)
        #expect(waiting.dextStatusLine == "Installed — approval required")
        let disabled = report(installedDextVersion: "0.10.17 (123)", bundledDextBuild: "123",
                              installedDextBuild: "123", dextEnabled: false,
                              servingDextBuild: .build(122))
        #expect(!disabled.restartFinishesDriverUpdate)
        #expect(disabled.dextStatusLine == "Installed — disabled")
    }

    /// Going back from a newer build (a tester build to the release): the
    /// newer copy still serving is a restart case like any other.
    @Test func newerServingCopyIsAnUnfinishedUpdateOnceTheBundledBuildIsInstalled() {
        let r = report(installedDextVersion: "0.10.17 (123)", bundledDextBuild: "123",
                       installedDextBuild: "123", servingDextBuild: .build(9004))
        #expect(r.driverUpdateUnfinished)
        #expect(r.restartFinishesDriverUpdate)
        #expect(r.dextLine.contains("build 9004 still serves the ThunderBridge"))
        #expect(r.dextActionOpensSettings)
        #expect(r.thunderBridgeBanner?.dismissible == false)
    }

    /// Not asked (USB, or no ThunderBridge connection open): no claim either way.
    @Test func notAskedMakesNoClaim() {
        let r = report(registeredDextCount: 2, bundledDextBuild: "123", installedDextBuild: "123")
        #expect(!r.servingDextDiffersFromBundled)
        #expect(!r.clipboardText.contains("Serving driver extension"))
    }

    /// A dev build without the stamped number answers 0: proves nothing.
    @Test func unstampedServingBuildIsNotAMismatch() {
        let r = report(bundledDextBuild: "123", installedDextBuild: "123", servingDextBuild: .build(0))
        #expect(!r.servingDextDiffersFromBundled)
    }

    /// An app whose bundled dext itself predates the selector cannot read a
    /// missing answer as "older".
    @Test func silentDriverIsNotOlderThanAPreReportingBundle() {
        let r = report(bundledDextBuild: "122", installedDextBuild: "122",
                       servingDextBuild: .olderThanBuildReporting)
        #expect(!r.servingDextDiffersFromBundled)
    }
}

private extension SoftwareInfoReport {
    var withLookupFailed: SoftwareInfoReport {
        var copy = self
        copy.dextLookupFailed = true
        return copy
    }
}
