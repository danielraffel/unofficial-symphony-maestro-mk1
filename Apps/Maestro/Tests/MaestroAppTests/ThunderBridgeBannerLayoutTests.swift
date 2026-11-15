import AppKit
import SwiftUI
import Testing
import MaestroCore
@testable import MaestroApp

/// The driver-update banner must not make the main window's minimum size
/// taller than the window.
///
/// Tester build 9005 with driver 9004 still serving drew a blank main window
/// (sidebar, status bar and page empty; only the toolbar showed) whenever the
/// "Unplug the ThunderBridge cable" banner was up. The banner's message had
/// `.fixedSize(horizontal: false, vertical: true)`: when the split view asks
/// for its minimum size it proposes a near-zero width, the long guidance then
/// wraps one word per line, and the window's content needed about 3,600 pt of
/// height. The window stays 700 pt tall, so everything SwiftUI drew sat above
/// the visible area.
///
/// Hosts the real banner in the same structure as `ContentView` (split view,
/// banner at the top of the detail column, the window's 800 x 500 minimum)
/// without `ContentView` itself, whose launch task would look for hardware.
@MainActor
@Suite("ThunderBridge banner layout")
struct ThunderBridgeBannerLayoutTests {

    /// Driver 9004 still serves the card; this app carries 9005, which is
    /// registered and enabled next to it.
    private func unfinishedUpdateReport() -> SoftwareInfoReport {
        SoftwareInfoReport(
            appVersion: "0.8.4",
            buildNumber: 9005,
            gitHash: "77bca2c",
            appPath: "/Applications/Maestro.app",
            osVersion: "26.0 (Build 25A123)",
            audioPath: "Thunderbolt (ThunderBridge driver extension)",
            installedDextVersion: "0.10.0 (9005)",
            registeredDextCount: 2,
            bundledDextBuild: "9005",
            installedDextBuild: "9005",
            dextLookupFailed: false,
            dextEnabled: true,
            dextAwaitingApproval: false,
            dextAwaitingReboot: false,
            thunderBridgePresent: true,
            pciDeviceIdentifier: "pci19c2,2200",
            servingDextBuild: .build(9004)
        )
    }

    private func window(with banner: ThunderBridgeBanner) -> (NSWindow, NSHostingView<AnyView>) {
        let root = AnyView(
            NavigationSplitView {
                List { ForEach(0..<7, id: \.self) { Text("Area \($0)") } }
                    .frame(minWidth: 158, idealWidth: 158)
            } detail: {
                VStack(spacing: 0) {
                    ThunderBridgeActionBanner(banner: banner, onAction: {}, onDismiss: {})
                    Text("Status").frame(maxWidth: .infinity)
                    Color.clear.frame(maxHeight: .infinity)
                }
            }
            .frame(minWidth: 800, minHeight: 500)
        )
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: -5000, y: 0, width: 1440, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    @Test func unfinishedUpdateBannerKeepsTheWindowsMinimumHeight() throws {
        let banner = try #require(unfinishedUpdateReport().thunderBridgeBanner)
        #expect(banner.title == "Unplug the ThunderBridge cable and plug it back in")
        #expect(banner.secondaryMessage != nil)
        let (window, host) = window(with: banner)
        defer { window.close() }
        // 500 is the window's own minimum; the banner must not raise it.
        #expect(host.fittingSize.height <= 500)
    }

    /// The shorter, dismissible banner shares the layout and had the same
    /// problem (1,344 pt).
    @Test func dismissibleBannerKeepsTheWindowsMinimumHeight() throws {
        var report = unfinishedUpdateReport()
        report.registeredDextCount = 1
        report.servingDextBuild = nil
        report.installedDextBuild = "9004"
        let banner = try #require(report.thunderBridgeBanner)
        let (window, host) = window(with: banner)
        defer { window.close() }
        #expect(host.fittingSize.height <= 500)
    }
}
