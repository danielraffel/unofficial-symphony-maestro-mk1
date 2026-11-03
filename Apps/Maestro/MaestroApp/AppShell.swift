import SwiftUI
import AppKit
import ApplicationServices
import CoreAudio
import CoreGraphics
import MaestroCore
import MaestroDevice


// MARK: - Navigation Areas

/// The main navigation areas, matching the legacy Maestro tab structure.
///
/// Evidence: `og_source/maestro2/App/MaestroDefines.h` — TAB_ID_* constants
/// Evidence: `og_source/maestro2/App/Resources/deviceDescriptions.plist` — tab flags
enum NavigationArea: String, CaseIterable, Identifiable {
    case input = "Input"
    case output = "Output"
    case mixer = "Mixer"
    case inputRouting = "Input Routing"
    case outputRouting = "Output Routing"
    case deviceSettings = "Device Settings"
    case systemSetup = "System Setup"

    var id: String { rawValue }

    /// Screen the app opens on, overridable by a launch argument.
    ///
    ///   /Applications/Maestro.app/Contents/MacOS/MaestroApp -MaestroInitialArea outputRouting
    ///
    /// This exists so the README screenshots can be regenerated non-interactively.
    /// The selected tab is in-memory only (nothing persists it), and driving the
    /// ⌘1..⌘7 shortcuts from a script needs Accessibility permission that a build
    /// machine may not have — so the screen is chosen at launch instead. Matched
    /// case- and space-insensitively against both the case name (`outputRouting`)
    /// and the display name (`Output Routing`); an absent or unrecognised value
    /// keeps the normal default. Nothing in the UI writes this key.
    static var launchDefault: NavigationArea {
        guard let raw = UserDefaults.standard.string(forKey: "MaestroInitialArea") else { return .input }
        let want = raw.lowercased().replacingOccurrences(of: " ", with: "")
        return allCases.first { area in
            "\(area)".lowercased() == want
                || area.rawValue.lowercased().replacingOccurrences(of: " ", with: "") == want
        } ?? .input
    }

    var systemImage: String {
        switch self {
        case .input:          return "mic"
        case .output:         return "speaker.wave.2"
        case .mixer:          return "slider.horizontal.3"
        case .inputRouting:   return "arrow.right.arrow.left"
        case .outputRouting:  return "arrow.triangle.branch"
        case .deviceSettings: return "gearshape"
        case .systemSetup:    return "clock"
        }
    }
}

// MARK: - Content View

/// Main content view with sidebar navigation and persistent status bar (includes monitor controls).
///
/// Evidence: `og_source/maestro2/App/Views/APMaestroFullViewWindow.m`
/// — legacy app uses a tab bar + persistent toolbar; we use sidebar + status bar + monitor panel.
struct ContentView: View {
    @Environment(AppState.self) private var appState
    @EnvironmentObject private var updates: UpdateController
    @Environment(\.colorScheme) private var colorScheme  // P3F-44
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .auto
    @AppStorage("maestro.thunderbridge.bannerDismissedToken") private var dismissedThunderBridgeBanner = ""

    private var thunderBridgeReport: SoftwareInfoReport { appState.softwareInfoReport }

    private var thunderBridgeBannerToken: String? {
        let report = thunderBridgeReport
        guard report.shouldShowThunderBridgeBanner else { return nil }
        return [report.dextStatusLine, report.dextNotice ?? "", report.bundledDextBuild ?? "", report.installedDextBuild ?? ""].joined(separator: "|")
    }

    /// Activation requests register/replace an extension; they cannot turn an
    /// already-registered extension back on after the user disabled it in
    /// Login Items & Extensions. In those states the useful action is the
    /// system settings panel, not another request (which commonly returns the
    /// misleading OSSystemExtension error 4).
    private func thunderBridgeNeedsSettings(_ report: SoftwareInfoReport) -> Bool {
        report.dextUpgradePending
            || report.dextAwaitingApproval
            || report.dextAwaitingReboot
            || (report.installedDextVersion != nil && !report.dextEnabled)
    }

    var body: some View {
        @Bindable var state = appState
        NavigationSplitView {
            SidebarView()
        } detail: {
            VStack(spacing: 0) {
                if let bannerToken = thunderBridgeBannerToken,
                   dismissedThunderBridgeBanner != bannerToken {
                    ThunderBridgeActionBanner(
                        report: thunderBridgeReport,
                        onActivate: {
                            // A second registered copy is an in-progress swap;
                            // submitting another activation request produces
                            // OSSystemExtensionErrorDomain code 4. The safe
                            // action there is to show the reconnect/settings
                            // guidance, while approval/missing/disabled states
                            // still submit a fresh activation request.
                            if thunderBridgeNeedsSettings(thunderBridgeReport) {
                                openDriverExtensions()
                            } else {
                                SystemExtensionInstaller.shared.activate()
                            }
                        },
                        onDismiss: { dismissedThunderBridgeBanner = bannerToken }
                    )
                }
                StatusBarView()
                DetailView(area: appState.selectedArea)
                    .frame(maxHeight: .infinity)
            }
            // P3F-44: warm cream overlay in light mode; neutral in dark mode.
            .background(Color(.windowBackgroundColor).overlay(
                colorScheme == .light
                    ? Color(red: 1.0, green: 0.97, blue: 0.94).opacity(0.05)
                    : Color.black.opacity(0.02)
            ))
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    MonitorToolbarView()
                }
            }
            // Keep the shared title bar independent of the selected page's
            // scroll/form material while respecting the app's appearance.
            .toolbarBackground(Color(.windowBackgroundColor), for: .windowToolbar)
            .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
            .background(UnborderedToolbarApplicator())
        }
        .sheet(isPresented: $state.showAbout) {
            AboutView()
        }
        .sheet(isPresented: $state.showHelp) {
            HelpView()
        }
        .task {
            // What driver extension is registered. Read before the hardware work below,
            // which can take seconds, so the About box is never asked for a report it
            // cannot give. Refreshed on appear by the panels that show it.
            appState.refreshInstalledDexts()
            // Auto-switch to Symphony when it's plugged in (device-list listener).
            appState.installHardwareDeviceListener()
            // Initialize hardware on launch (speaker mode, routing, unmute)
            await appState.initializeHardwareIfNeeded()
            // Read I/O card types for routing labels (P3G-15c).
            if appState.connectionMode == .hardware {
                await appState.readCardTypes()
                // Sync persisted output routing to hardware after card types are known.
                // This overwrites proxy boot defaults with any user-customized routes.
                await appState.syncOutputRoutingToHardware()
            }
            // Start meter polling immediately so Input/Output tab meter bars
            // show live levels without requiring the user to visit the Meters tab.
            if appState.connectionMode == .hardware {
                appState.startMeterPolling()
            }
            // A ThunderBridge can remain enumerated while the downstream
            // Symphony is powered off. Keep retrying its endpoint health even
            // when launch correctly classified the endpoint as disconnected.
            if appState.transportType == .thunderbolt {
                appState.startThunderboltHealthCheck()
            }
            // Connected over USB with a ThunderBridge also present: keep probing
            // it so a dext that comes back (same Core Audio ID, no device-list
            // change) still wins, as the front-panel rule says it should.
            if appState.transportType == .usb {
                appState.startThunderboltWatchWhileOnUSB(CoreAudioDeviceConnection.discoverAllSymphonyIO())
            }
            // Start USB health check if user previously enabled it
            if UserDefaults.standard.bool(forKey: "usbHealthCheckEnabled") {
                appState.startUSBHealthCheck()
            }
        }
        .task(id: appState.connectionMode) {
            while !Task.isCancelled {
                appState.refreshInstalledDexts()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onChange(of: thunderBridgeReport.thunderBridgePresent) { _, present in
            if !present { dismissedThunderBridgeBanner = "" }
        }
        .onChange(of: appState.isHardwareInitialized) { _, initialized in
            if initialized && appState.connectionMode == .hardware {
                appState.startMeterPolling()
            } else if !initialized {
                appState.stopMeterPolling()
            }
        }
        // AppKit owns the app-wide override. A changing preferredColorScheme can
        // leave SwiftUI's hosting views dark after the preference returns to nil.
        .preferredColorScheme(nil)
        .onChange(of: appearance, initial: true) { _, newAppearance in
            // Also cover AppKit-hosted toolbar controls, menus, panels and popovers.
            // nil restores automatic system appearance.
            NSApp.appearance = newAppearance.appKitAppearance
        }
    }

    private func openDriverExtensions() {
        // Open the supported Driver Extensions category directly. macOS does
        // not expose a stable URL for a specific dext's detail sheet, so keep
        // the broader Login Items page only as a compatibility fallback.
        let driverExtensions = "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.system_extension.driver_extension.extension-point"
        if let url = URL(string: driverExtensions), NSWorkspace.shared.open(url) { return }
        if let fallback = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(fallback)
        }
    }
}

private struct ThunderBridgeActionBanner: View {
    let report: SoftwareInfoReport
    let onActivate: () -> Void
    let onDismiss: () -> Void

    private var message: String {
        if report.dextUpgradePending {
            return "The Maestro ThunderBridge driver extension is updating. Close audio applications, then reconnect the ThunderBridge."
        }
        if let notice = report.dextNotice, notice.contains("build") {
            return "A newer Maestro ThunderBridge driver extension is ready. Close audio applications, then reconnect the ThunderBridge to finish the update."
        }
        switch report.dextStatusLine {
        case "Installed — approval required":
            return "ThunderBridge is connected. Approve the Maestro ThunderBridge driver extension in System Settings."
        case "Installed — disabled":
            return "ThunderBridge is connected. Enable the Maestro ThunderBridge driver extension in System Settings."
        case "Installed — restart required":
            return "Restart your Mac to finish enabling the Maestro ThunderBridge driver extension."
        case "Not registered — install or approve the driver":
            return "ThunderBridge is connected, but the Maestro ThunderBridge driver extension still needs to be installed and approved."
        default:
            return "The Maestro ThunderBridge driver extension needs attention before Maestro can use it."
        }
    }

    private var actionTitle: String {
        (report.dextUpgradePending || report.dextAwaitingApproval
         || report.dextAwaitingReboot || (report.installedDextVersion != nil && !report.dextEnabled))
            ? "Open Driver Settings…" : "Set Up Driver…"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("Maestro ThunderBridge driver extension")
                    .font(.headline)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(actionTitle, action: onActivate)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .accessibilityLabel("Dismiss ThunderBridge driver notice")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.yellow.opacity(0.14))
        .overlay(alignment: .bottom) { Rectangle().fill(.yellow.opacity(0.35)).frame(height: 1) }
    }
}

// MARK: - Unbordered Toolbar Style

/// Removes the Liquid Glass capsule/container from toolbar items by setting
/// isBordered = false. Per WWDC25 "Build an AppKit app with the new design":
/// "you cannot add custom views without the glass container unless you set
/// isBordered = false."
private struct UnborderedToolbarApplicator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        scheduleApplication(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        scheduleApplication(from: nsView)
    }

    private func scheduleApplication(from view: NSView) {
        // Apply on next runloop (after SwiftUI creates toolbar items),
        // and again after a brief delay (SwiftUI may rebuild items).
        DispatchQueue.main.async { self.removeGlassBacking(from: view) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.removeGlassBacking(from: view) }
    }

    private func removeGlassBacking(from view: NSView) {
        guard let window = view.window else { return }
        // The automatic sidebar titlebar separator can appear through the window
        // buttons while scrolling. The persistent status bar already divides the
        // detail toolbar from its content, so no additional titlebar line is needed.
        window.titlebarSeparatorStyle = .none
        guard let toolbar = window.toolbar else { return }
        for item in toolbar.items {
            if item.isBordered { item.isBordered = false }
            if let group = item as? NSToolbarItemGroup {
                for subItem in group.subitems {
                    if subItem.isBordered { subItem.isBordered = false }
                }
            }
        }
    }
}


// MARK: - Sidebar

/// Sidebar with device info and navigation areas.
struct SidebarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        List(selection: $state.selectedArea) {
            // Device info header — non-selectable
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    if appState.device != nil {
                        HStack {
                            Image(systemName: "hifispeaker")
                                .foregroundStyle(.secondary)
                            Text("Symphony I/O")
                                .font(.headline)
                                .lineLimit(1)
                                .fixedSize()
                        }
                        ConnectionBadge(mode: appState.connectionMode, status: appState.statusMessage,
                                        transportType: appState.transportType,
                                        transportPresent: appState.transportPresent,
                                        isSimulatingCards: appState.cardSimulation != nil)
                    } else {
                        HStack {
                            Image(systemName: "hifispeaker.slash")
                                .foregroundStyle(.secondary)
                            Text("No Device")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                        ConnectionBadge(mode: .disconnected, status: appState.statusMessage,
                                        transportType: appState.transportType,
                                        transportPresent: appState.transportPresent)
                    }
                }
                .listRowBackground(Color.clear)
            }

            Section("Controls") {
                ForEach(NavigationArea.allCases) { area in
                    Label(area.rawValue, systemImage: area.systemImage)
                        .tag(area)
                }
            }
        }
        .listStyle(.sidebar)
        .modifier(SidebarScrollBehavior())
        .navigationTitle("Maestro")
        .frame(minWidth: 158, idealWidth: 158)
    }
}

// MARK: - Connection Badge

/// Connection status badge — color reflects actual connection health.
struct ConnectionBadge: View {
    let mode: ConnectionMode
    var status: String = ""
    var transportType: TransportType? = nil
    var transportPresent: Bool = false
    /// The debug card-simulation harness is driving this session.
    var isSimulatingCards: Bool = false

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var label: String {
        switch mode {
        case .hardware:
            if hasError { return "\(transportName) Error" }
            return "\(transportName) Connected"
        case .simulated: return isSimulatingCards ? "Simulated" : "Offline"
        case .disconnected:
            // Keep the transport badge useful when ThunderBridge is still
            // enumerated but the downstream Symphony is powered off.
            return transportPresent ? "\(transportName) Connected" : "Disconnected"
        }
    }

    private var transportName: String {
        transportType?.displayName ?? "USB"
    }

    private var hasError: Bool {
        status.contains("not responding") || status.contains("error")
    }

    private var color: Color {
        switch mode {
        case .hardware:
            if hasError { return .orange }
            return .green
        case .simulated: return isSimulatingCards ? .purple : .blue
        case .disconnected: return transportPresent ? .green : .red
        }
    }
}

// MARK: - Detail View Router

/// Routes to the appropriate view based on sidebar selection.
struct DetailView: View {
    @Environment(AppState.self) private var appState
    let area: NavigationArea

    var body: some View {
        switch area {
        case .input:          InputControlsView(appState: appState)
        case .output:         OutputControlsView(appState: appState)
        case .mixer:          MixerView(appState: appState)
        case .inputRouting:   InputRoutingView(appState: appState)
        case .outputRouting:  OutputRoutingView(appState: appState)
        case .deviceSettings: DeviceSettingsView()
        case .systemSetup:    SystemSetupView()
        }
    }
}
