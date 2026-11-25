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
    /// The Symphony I/O hardware: clock, connection, monitoring, front panel,
    /// cards, naming and device info. Replaces the old Device Settings and
    /// System Setup pages.
    case deviceSettings = "Device Settings"
    /// Maestro itself: appearance, connect behaviour, updates, diagnostics, about.
    case appSettings = "App Settings"

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
        return named(raw) ?? .input
    }

    /// The area a launch argument names, accepting the pages' former names:
    /// System Setup (and the interim Hardware) open Device Settings, and
    /// Preferences opens App Settings.
    static func named(_ raw: String) -> NavigationArea? {
        let want = raw.lowercased().replacingOccurrences(of: " ", with: "")
        if let area = allCases.first(where: { area in
            "\(area)".lowercased() == want
                || area.rawValue.lowercased().replacingOccurrences(of: " ", with: "") == want
        }) { return area }
        switch want {
        case "systemsetup", "hardware": return .deviceSettings
        case "preferences": return .appSettings
        default: return nil
        }
    }

    var systemImage: String {
        switch self {
        case .input:          return "mic"
        case .output:         return "speaker.wave.2"
        case .mixer:          return "slider.horizontal.3"
        case .inputRouting:   return "arrow.right.arrow.left"
        case .outputRouting:  return "arrow.triangle.branch"
        case .deviceSettings: return "hifireceiver"
        case .appSettings:    return "gearshape"
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
    @AppStorage("MaestroSelectedArea") private var storedSelectedArea = "Input"
    @Environment(DiagnosticsRecorder.self) private var diagnostics

    private var thunderBridgeReport: SoftwareInfoReport { appState.softwareInfoReport }

    /// The banner to show, or nil. A dismissible banner stays hidden after the
    /// user closes it until its content changes; one that only a finished
    /// update clears (dismissible == false) cannot be closed.
    private var visibleThunderBridgeBanner: (banner: ThunderBridgeBanner, token: String)? {
        // Apogee's kernel driver for the card is loaded: this replaces every
        // other driver banner. Those say to activate the driver, or to unplug
        // the cable to finish an update, and either can crash the Mac in this
        // state (ApogeeDriverConflict.swift). Its one button only opens Device
        // Settings, where the steps are; it cannot be closed.
        let card = PortStatusMessage.cardPhrase(pciIdentifier: thunderBridgeReport.pciDeviceIdentifier)
        if let conflict = appState.apogeeDriverConflict?.banner(card: card) {
            return (ThunderBridgeBanner(title: conflict.title, message: conflict.message, action: .showSteps,
                                        dismissible: false, inProgress: false), "apogee-driver")
        }
        guard let banner = thunderBridgeReport.thunderBridgeBanner else { return nil }
        let report = thunderBridgeReport
        let token = [banner.title, banner.message, report.bundledDextBuild ?? "", report.installedDextBuild ?? ""]
            .joined(separator: "|")
        if banner.dismissible && dismissedThunderBridgeBanner == token { return nil }
        return (banner, token)
    }

    var body: some View {
        @Bindable var state = appState
        NavigationSplitView {
            SidebarView()
        } detail: {
            VStack(spacing: 0) {
                if diagnostics.isRecording || diagnostics.isSaving {
                    DiagnosticsBar()
                }
                if let (banner, bannerToken) = visibleThunderBridgeBanner {
                    ThunderBridgeActionBanner(
                        banner: banner,
                        onAction: {
                            // While an upgrade is half applied another
                            // activation request produces OSSystemExtension
                            // error 4, and a request cannot re-enable a
                            // disabled extension: those states open the
                            // Driver Extensions pane instead.
                            switch banner.action {
                            case .openDriverSettings: openDriverExtensions()
                            case .activate: SystemExtensionInstaller.shared.activate()
                            // Only navigates: nothing that starts, stops or
                            // replaces a driver is offered in this state.
                            case .showSteps: appState.selectedArea = .deviceSettings
                            case .none: break
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
            .modifier(DiagnosticsAlerts())
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
            .background(WindowDocumentBridge())
            .navigationTitle(appState.setupDocumentTitle)
        }
        .onAppear {
            WindowDocumentBridge.currentAppState = appState
            WindowDocumentBridge.updateEditedState()
            if UserDefaults.standard.string(forKey: "MaestroInitialArea") == nil {
                appState.selectedArea = NavigationArea.named(storedSelectedArea) ?? .input
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            _ = appState.existingSetupURL()
        }
        .onChange(of: appState.selectedArea) { _, area in
            storedSelectedArea = area.rawValue
        }
        .sheet(isPresented: $state.showAbout) {
            AboutView()
        }
        .sheet(isPresented: $state.showHelp) {
            HelpView()
        }
        .task {
            // Keep the driver-update banner current after an activation
            // (DriverHandover.swift). Maestro never retires the old driver.
            appState.installDriverHandoverObserver()
            // What driver extension is registered. Read before the hardware work below,
            // which can take seconds, so the About box is never asked for a report it
            // cannot give. Refreshed on appear by the panels that show it.
            appState.refreshInstalledDexts()
            // Apogee's original Symphony I/O drivers (Device Settings warns while
            // they are installed). Off the main thread; does not wait.
            appState.refreshOriginalApogeeDrivers()
            // Find the Symphony from a background thread now that the window is
            // up, and connect to it (0.9.8; see AppState.completeLaunchDiscovery).
            await appState.completeLaunchDiscovery()
            // Auto-switch to Symphony when it's plugged in (device-list listener).
            appState.installHardwareDeviceListener()
            // Initialize hardware on launch (speaker mode, routing, unmute)
            await appState.initializeHardwareIfNeeded()
            // Read I/O card types for routing labels (P3G-15c).
            if appState.connectionMode == .hardware {
                await appState.readCardTypes()
                // Sync persisted output routing to hardware after card types are known.
                // This overwrites proxy boot defaults with any user-customized routes.
                // The input routing and the settings this Mac owns (peak hold,
                // monitor mode, ...) go with it, in the order each transport
                // needs (`syncSavedStateToHardware`).
                await appState.syncSavedStateToHardware()
                // And the names that follow them (prefix, optical format, Replaces).
                await appState.refreshChannelNaming()
            }
            // Follow the unit's front panel encoder (USB). Idles without a unit.
            appState.startFrontPanelSync()
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
                // D5: restore the card mixer on a fresh driver even when the
                // Mixer page is never opened. A stored task: launch goes on.
                if appState.connectionMode == .hardware { appState.syncCardMixerToHardware() }
            }
            // Connected over USB with a ThunderBridge also present: keep probing
            // it so a dext that comes back (same Core Audio ID, no device-list
            // change) still wins, as the front-panel rule says it should.
            if appState.transportType == .usb {
                appState.startThunderboltWatchWhileOnUSB(
                    appState.lastLaunchDiscovered ?? CoreAudioDeviceConnection.discoverAllSymphonyIO())
            }
            appState.initialSetupRestoreFinished = true
            appState.scheduleRecentSetupRecall()
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

/// Internal, not private, so MaestroAppTests can lay it out.
struct ThunderBridgeActionBanner: View {
    let banner: ThunderBridgeBanner
    let onAction: () -> Void
    let onDismiss: () -> Void

    private var actionTitle: String? {
        switch banner.action {
        case .openDriverSettings: return "Open Driver Settings…"
        case .activate: return "Set Up Driver…"
        case .showSteps: return "Show Steps"
        case .none: return nil
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            if banner.inProgress {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title)
                    .font(.headline)
                Text(banner.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let secondary = banner.secondaryMessage {
                    Text(secondary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                // No .fixedSize(vertical: true) here: the split view measures
                // its minimum at a near-zero width, the message then wraps a
                // word per line, and the window's content became taller than
                // the window, which then drew blank (MaestroAppTests).
            }
            Spacer(minLength: 8)
            if let actionTitle {
                // A blue button in every banner (a link read as plain text,
                // owner 2026-11-22).
                Button(actionTitle, action: onAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            if banner.dismissible {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .accessibilityLabel("Dismiss ThunderBridge driver notice")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
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
                                        cardName: appState.connectionShortName,
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
                                        transportPresent: appState.transportPresent,
                                        cardName: appState.connectionShortName)
                    }
                }
                .listRowBackground(Color.clear)
            }

            Section("Controls") {
                ForEach(NavigationArea.allCases) { area in
                    // Every icon gets the same centred slot so the labels line up,
                    // wide enough for hifireceiver (much wider than the other
                    // symbols), plus a gap so no icon touches its label.
                    Label {
                        Text(area.rawValue)
                    } icon: {
                        Image(systemName: area.systemImage)
                            .frame(width: 28, alignment: .center)
                            .padding(.trailing, 4)
                    }
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

// MARK: - Status pill

/// The small tinted capsule of the sidebar's connection badge, also used for
/// the "Newer" mark under the update channel picker.
struct StatusPillStyle: ViewModifier {
    let color: Color

    func body(content: Content) -> some View {
        content
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

extension View {
    func statusPill(_ color: Color) -> some View { modifier(StatusPillStyle(color: color)) }
}

// MARK: - Connection Badge

/// Connection status badge — color reflects actual connection health.
struct ConnectionBadge: View {
    let mode: ConnectionMode
    var status: String = ""
    var transportType: TransportType? = nil
    var transportPresent: Bool = false
    /// "Symphony 64 PCIe" on that card, otherwise the transport's name
    /// (`ConnectionLabel.shortName`); nil falls back to the transport's.
    var cardName: String? = nil
    /// The debug card-simulation harness is driving this session.
    var isSimulatingCards: Bool = false

    var body: some View {
        Text(label)
            .statusPill(color)
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
        cardName ?? transportType?.displayName ?? "USB"
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

// MARK: - Hardware Suspended Note

/// One line over a device page while hardware writes are suspended.
struct HardwareSuspendedBar: View {
    let note: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "moon.zzz")
                .foregroundStyle(.secondary)
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Detail View Router

/// Routes to the appropriate view based on sidebar selection.
struct DetailView: View {
    @Environment(AppState.self) private var appState
    let area: NavigationArea

    /// Input, Output, Input Routing and Device Settings belong to one unit:
    /// with a second Symphony I/O on port 2 they follow the unit picker, and
    /// are rebuilt when it changes.
    private var isPerUnit: Bool { UnitPicker.isPerUnit(page: area.rawValue) }

    /// Every page but App Settings writes the unit. While hardware writes are
    /// suspended (sleep, wake validation) an edit would be shown and saved but
    /// never sent, so the page is disabled and says why.
    private var suspendedNote: String? { Self.suspendedNote(area: area, appState: appState) }

    static func suspendedNote(area: NavigationArea, appState: AppState) -> String? {
        area == .appSettings ? nil : appState.hardwareSuspendedNote
    }

    var body: some View {
        VStack(spacing: 0) {
            if let suspendedNote { HardwareSuspendedBar(note: suspendedNote) }
            Group {
                if isPerUnit && appState.unitPickerVisible {
                    VStack(spacing: 0) {
                        UnitPickerBar()
                        page.id(appState.activeUnit)
                    }
                } else {
                    page
                }
            }
            .disabled(suspendedNote != nil)
        }
    }

    /// A failed slot probe leaves its layout unknown. Only live, empty reads
    /// count as an empty Symphony I/O, and converters do not have these slots.
    static func showsNoIOCards(mode: ConnectionMode, hasConverter: Bool,
                               slot1: BoardTypeReading, slot2: BoardTypeReading) -> Bool {
        mode == .hardware && !hasConverter
            && slot1.source.isTrustworthy && slot1.card == .none
            && slot2.source.isTrustworthy && slot2.card == .none
    }

    private func hasNoIOCards(on unit: DeviceUnit) -> Bool {
        let slot1: BoardTypeReading
        let slot2: BoardTypeReading
        if unit == .b, let second = appState.unitB {
            slot1 = BoardTypeReading(card: second.slot1, source: appState.unitBBoardSource(slot: 0))
            slot2 = BoardTypeReading(card: second.slot2, source: appState.unitBBoardSource(slot: 1))
        } else {
            slot1 = appState.primaryBoardReading
            slot2 = appState.secondaryBoardReading
        }
        return Self.showsNoIOCards(mode: appState.connectionMode,
                                   hasConverter: unit == .a && appState.converterRoutingSurface,
                                   slot1: slot1, slot2: slot2)
    }

    @ViewBuilder
    private var page: some View {
        switch area {
        case .input where hasNoIOCards(on: appState.activeUnit),
             .output where hasNoIOCards(on: appState.activeUnit),
             .mixer where hasNoIOCards(on: .a) && (!appState.unitBOnCard || hasNoIOCards(on: .b)):
            Text("No I/O cards detected.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .input:          InputControlsView(appState: appState)
            .id(appState.preferenceViewScope(for: appState.activeUnit))
        case .output:         OutputControlsView(appState: appState)
            .id(appState.preferenceViewScope(for: appState.activeUnit))
        case .mixer:          MixerView(appState: appState)
            .id(appState.mixerViewScopes)
        case .inputRouting:   InputRoutingView(appState: appState)
        case .outputRouting:  OutputRoutingView(appState: appState)
        case .deviceSettings: DeviceSettingsView()
        case .appSettings:    AppSettingsView()
        }
    }
}
