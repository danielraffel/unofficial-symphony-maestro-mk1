import SwiftUI
import AppKit
import Observation
import os
import ApplicationServices
import CoreAudio
import CoreGraphics
import MaestroCore
import MaestroDevice

/// Session-scroll preference shared by the three horizontally wide control tabs.
/// Missing UserDefaults data means the feature is enabled by default.
enum ControlTabScrollPreferences {
    static var remembers: Bool {
        UserDefaults.standard.object(forKey: "rememberControlTabScrollPositions") as? Bool ?? true
    }
}

// MARK: - ASP Volume/Mute Callbacks

/// CoreAudio property listener callback for ASP volume changes.
/// Called when media volume keys change the "Symphony I/O : Maestro" device.
private func aspVolumeChanged(
    _ objectID: AudioObjectID,
    _ numberAddresses: UInt32,
    _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    nonisolated(unsafe) let appState = Unmanaged<AppState>.fromOpaque(clientData).takeUnretainedValue()
    DispatchQueue.main.async {
        appState.adoptMacMonitorChange(mute: false)
    }
    return noErr
}


/// CoreAudio property listener callback for ASP mute changes.
private func aspMuteChanged(
    _ objectID: AudioObjectID,
    _ numberAddresses: UInt32,
    _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    nonisolated(unsafe) let appState = Unmanaged<AppState>.fromOpaque(clientData).takeUnretainedValue()
    DispatchQueue.main.async {
        appState.adoptMacMonitorChange(mute: true)
    }
    return noErr
}

private func micPreDAWPropertyChanged(
    _ objectID: AudioObjectID,
    _ numberAddresses: UInt32,
    _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    // A trigger only: the values come from the driver's per-unit, per-channel
    // records (see scheduleMicPreDAWRefresh), not from this HAL element.
    guard let clientData, numberAddresses > 0 else { return noErr }
    nonisolated(unsafe) let appState = Unmanaged<AppState>.fromOpaque(clientData).takeUnretainedValue()
    DispatchQueue.main.async {
        appState.scheduleMicPreDAWRefresh(objectID: objectID)
    }
    return noErr
}

/// CoreAudio listener: fires when the system audio device list changes (a device is plugged in
/// or removed). Drives "auto-switch to Symphony when connected."
private func hardwareDevicesChanged(
    _ objectID: AudioObjectID,
    _ numberAddresses: UInt32,
    _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    nonisolated(unsafe) let appState = Unmanaged<AppState>.fromOpaque(clientData).takeUnretainedValue()
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            appState.handleHardwareDeviceListChanged()
        }
    }
    return noErr
}

// MARK: - Connection Mode

/// Whether the app is connected to real hardware or a simulator.
enum ConnectionMode: Equatable {
    /// Connected to real hardware via IOUSBHost.
    case hardware
    /// Using in-memory simulated device for development.
    case simulated
    /// No device connected.
    case disconnected
}

// MARK: - App State

/// Observable application state shared across views.
///
/// On launch, attempts to discover real hardware via IOUSBHost.
/// Falls back to a simulated device for development if no hardware found.
///
/// Evidence: `og_source/maestro2/App/Controllers/APApplicationDelegate.m`
@Observable
final class AppState: @unchecked Sendable {
    struct FrontPanelMicPreUpdate: Equatable {
        let unit: DeviceUnit
        let channel: Int
        let gain: Double
        let revision: Int
    }

    /// Latest hardware encoder gain, consumed by the Input page. This is a
    /// state update only: the front-panel path never writes the value back.
    var frontPanelMicPreUpdate: FrontPanelMicPreUpdate?
    private var frontPanelMicPreRevision = 0
    var phantomObservationRevision = 0
    /// Session-only Identify latches, one per unit connection.
    let identifyA = IdentifyState()
    let identifyB = IdentifyState()
    /// Identity belongs to the connection generation. Pending discovery blocks
    /// edits; failed discovery follows the existing migration receipts.
    var unitAIdentityState: UnitIdentityState = .pending
    var unitBIdentityState: UnitIdentityState = .pending
    var unitAIdentity: UInt64? {
        get { unitAIdentityState.identity }
        set { unitAIdentityState = newValue.map(UnitIdentityState.known) ?? .pending }
    }
    var unitBIdentity: UInt64? {
        get { unitBIdentityState.identity }
        set { unitBIdentityState = newValue.map(UnitIdentityState.known) ?? .pending }
    }
    var unitAGeneration = UUID()
    var unitBGeneration = UUID()
    var unitAIdentityTask: Task<UInt64?, Never>?
    var unitBIdentityTask: Task<UInt64?, Never>?

    var identityRecoveryRetried = false
    private weak var identityRetryConnection: AnyObject?
    var usbIdentityRestoreGeneration: UUID?
    var cardDiscoveryTask: Task<Void, Never>?
    private var cardDiscoveryTaskGeneration: UUID?
    private weak var cardDiscoveryTaskConnection: AnyObject?
    var usbMixerLifecycleRestoreGeneration: UUID?
    /// The running USB restore (`restoreUSBUnit`): one at a time per connection.
    @ObservationIgnored var usbRestoreTask: Task<Void, Never>?
    /// Which mixers the USB restore has written in full on this connection,
    /// since the unit last came back from a power cycle. Output Routing sends
    /// a route fed by a mixer only when that mixer is listed here.
    @ObservationIgnored var usbMixersWritten: (generation: UUID, mixers: [Bool])?
    /// The connection generation whose ordered USB restore ran to the end.
    @ObservationIgnored var usbRestoredGeneration: UUID?
    /// The USB restore did not finish (a mixer or a route is still owed):
    /// tried again by the meter loop, with a growing pause.
    @ObservationIgnored var usbRestoreOwed = false
    /// The installed USB helper is older than this app (a custom install
    /// that left the USB support out): no mixer is written under it.
    @ObservationIgnored var usbHelperOutdated = false
    /// Mixer edits are not sent over USB while the installed helper is older
    /// than this app (see `MixerEditorState.canEdit`).
    var usbMixerEditsBlockedByOldHelper: Bool { usbHelperOutdated && device is XPCDeviceConnection }
    @ObservationIgnored var usbRestoreServiceTask: Task<Void, Never>?
    @ObservationIgnored var usbRestoreRetryAttempts = 0
    @ObservationIgnored var usbRestoreRetryAfter = Date.distantPast
    /// The helper connection the USB restore last ran on: a helper that
    /// reconnects re-programs the direct routes, so the restore runs again.
    @ObservationIgnored var usbRestoredHelperEpoch: UInt64?
    /// The connection generation whose input routing and device settings the
    /// restore has sent (a retry of owed mixers or routes leaves them alone).
    @ObservationIgnored var usbSettingsRestored: (generation: UUID, helperEpoch: UInt64)?
    /// ThunderBridge: the app asked for the restore (the connection's ledger,
    /// `ThunderboltDeviceConnection.cardMixers`, says by itself when one is
    /// owed), whether one is running, and when to try next.
    @ObservationIgnored var cardOutputTableReplayNeeded = false
    @ObservationIgnored var cardOutputRestoreRunning = false
    @ObservationIgnored var cardOutputRetryAttempts = 0
    @ObservationIgnored var cardOutputRetryAfter = Date.distantPast
    /// Checks in a row that found the cards or the unit's identity unread,
    /// and the driver state in which the direct defaults were then written
    /// (`cardRestoreStillBlocked`).
    @ObservationIgnored var cardBlockedChecks = 0
    @ObservationIgnored var cardBlockedConnection: ObjectIdentifier?
    @ObservationIgnored var cardDirectFallback: (connection: ObjectIdentifier, epoch: UInt64)?
    /// 64 channels: the pause after a replay that did not complete, and the
    /// connections on which the reset's default input tables have landed.
    @ObservationIgnored var twoUnitRetryAttempts = 0
    @ObservationIgnored var twoUnitRetryAfter = Date.distantPast
    @ObservationIgnored var twoUnitResetDefaultsSent: (a: ObjectIdentifier, b: ObjectIdentifier)?
    /// Whose saved state the connection's card mixer marks were written from.
    @ObservationIgnored var cardRestoreOwner: (connection: ObjectIdentifier, owner: CardRestoreOwner)?
    /// Counts Output Routing edits, so a restore can tell one happened under it.
    @ObservationIgnored var outputRouteEdits: UInt64 = 0
    @ObservationIgnored var outputRouteDeferredSinceSave = false
    /// A bundle recall has sent its first write (a failure after that leaves
    /// the unit differing from what is saved).
    @ObservationIgnored var recallWritesStarted = false
    /// Pause between a card mixer's writes, and before a whole-mixer write is
    /// started again after an edit (tests set zero).
    @ObservationIgnored var cardMixerCommandGap: Duration = CardMixerReplay.commandGap
    @ObservationIgnored var cardMixerEditQuietWindow: Duration = CardMixerReplay.quietWindow
    /// Status bar text while saved routing or mixer state is not on the unit
    /// yet (`updateRestoreStatus`).
    var restoreStatusNote: String?
    /// One-time explanation shown after the driver-144 fader migration.
    var mixerHeadroomNotice: String?
    /// One-time explanation shown on the routing pages after the analog-first
    /// channel order reset (`ChannelOrderRoutingReset`), until dismissed.
    var channelOrderResetNotice: String? = UserDefaults.standard.bool(forKey: ChannelOrderRoutingReset.noticePendingKey)
        ? ChannelOrderRoutingReset.noticeText : nil
    /// Observation token for per-unit preferences stored outside the model.
    var unitPreferenceRevision = 0
    /// Pause between the strip writes of a USB mixer restore (tests set zero).
    @ObservationIgnored var usbMixerStripSpacing: Duration = .milliseconds(5)
    @ObservationIgnored var cachedMixerPreferences: (key: String, value: MixerPreferences)?
    /// D5: which mixers are restored on which driver instance (keyed by the
    /// driver's own nonce), the stored restore task, and whether launch or
    /// reconnect asked for it while unit A's identity was still pending.
    @ObservationIgnored var cardMixerLedger = CardMixerRestoreLedger()
    @ObservationIgnored var cardMixerRestoreRun: CardMixerRestoreRun?
    @ObservationIgnored var cardMixerRestoreAwaitingIdentity = false
    @ObservationIgnored var cardMixerRestoreRequested = false

    func retryFailedIdentityOnRecovery() {
        guard unitAIdentityState == .failed, !identityRecoveryRetried,
              identityRetryConnection === (device as AnyObject?) else { return }
        identityRecoveryRetried = true
        unitAIdentityState = .pending
    }

    func invalidateUnitAIdentity() {
        unitAIdentityTask?.cancel()
        unitAIdentityTask = nil
        unitAGeneration = UUID()
        usbIdentityRestoreGeneration = nil
        // Keep the discovery handle until its task has been cancelled and
        // awaited by the next owner. This prevents a replacement discovery
        // from running concurrently against a retired connection.
        // Discovery's own unit/converter findings invalidate identity; that
        // must not cancel the discovery that made them (it re-captures the
        // generation and continues).
        if !discoveryOwnsInvalidation { cardDiscoveryTask?.cancel() }
        unitAIdentityState = .pending
    }
    @ObservationIgnored var discoveryOwnsInvalidation = false

    func invalidateUnitBIdentity() {
        unitBIdentityTask?.cancel()
        unitBIdentityTask = nil
        unitBGeneration = UUID()
        unitBIdentityState = .pending
        unitBIdentityAttempted = false
    }
    /// Latches the single unit-B identity attempt for the current connection.
    var unitBIdentityAttempted = false

    /// Currently connected device (real or simulated).
    var device: (any DeviceConnection)? {
        willSet {
            if device !== newValue {
                lastMacMonitorWrite = nil
                suppressMacVolumeOverlay()
                if hardwareWritesSuspended {
                    newValue?.hardwareWriteGate?.holdForValidation()
                    reconnectRequestedWhileSuspended = true
                    wakeStableRecoveryCount = nil
                    wakeStableProbeCount = 0
                }
                // D5: the restore belongs to the connection it started on.
                cardMixerRestoreRun?.task.cancel()
                cardMixerRestoreRun = nil
                cardMixerRestoreAwaitingIdentity = false
                cardMixerRestoreRequested = false
                identifyA.reset()
                identifyB.reset()
                invalidateUnitAIdentity()
                invalidateUnitBIdentity()
                unitBIdentityAttempted = false
                identityRecoveryRetried = false
                identityRetryConnection = newValue as AnyObject?
                thunderboltInputRoutingWritten = false
                thunderboltCaptureRoutesCache.removeAll()
            }
        }
    }
    /// Currently selected navigation area.
    var selectedArea: NavigationArea = .launchDefault
    /// Which mix the Mixer tab was last showing (0 = Mix 1, 1 = Mix 2), so
    /// leaving the tab and coming back does not silently return to Mix 1 and
    /// put someone's hands on the wrong mixer. Kept until Maestro quits; a
    /// fresh launch starts on Mix 1.
    var lastSelectedMixer: Int = 0
    /// Whether to show the About panel.
    var showAbout: Bool = false
    /// Whether to show the Help panel.
    var showHelp: Bool = false
    /// The section Help opens at, once (a pop-up's "See Help for more.").
    var helpSection: HelpSectionID?

    func openHelp(at section: HelpSectionID? = nil) {
        helpSection = section
        showHelp = true
    }
    /// Connection mode.
    var connectionMode: ConnectionMode = .disconnected {
        didSet {
            if connectionMode == .disconnected {
                invalidateUnitAIdentity()
                invalidateUnitBIdentity()
                identifyA.reset()
                identifyB.reset()
            }
        }
    }
    /// Active transport type (USB or Thunderbolt).
    var transportType: TransportType? = nil
    /// Whether the transport itself is present. ThunderBridge can remain
    /// enumerated while the downstream Symphony is powered off, so this must
    /// not be inferred from `connectionMode`.
    var transportPresent: Bool = false
    /// Status message for the user.
    var statusMessage: String = "Initializing..."
    /// The debug card-simulation request this process was launched with, or nil.
    ///
    /// Non-nil means: no hardware discovery, no reconnects, no device-list
    /// listener — the session is pinned to the simulated unit so the forced
    /// board types can never be clobbered by a real `0xA1` read, and nothing the
    /// harness does can reach a real unit. See `CardSimulation`.
    let cardSimulation: CardConfiguration?
    /// Per-channel saved state, scoped to the installed card pair.
    /// See `ChannelStateStore` for the migration rules.
    var channelStateStore: ChannelStateStore {
        // The converter simulation keeps its own (`sim:`) state too.
        ChannelStateStore(layout: cardLayout,
                          isSimulatingCards: cardSimulation != nil || connectionMode == .simulated,
                          identity: unitAIdentity,
                          awaitingIdentity: connectionMode == .hardware && unitAIdentityState == .pending && device != nil && cardLayout.converterLayout == nil && cardLayout.converter == nil,
                          allowLegacyMigration: allowsLegacyUnitState(unit: .a))
    }
    /// Whether hardware initialization is complete. Views must wait for this
    /// before reading from the device to avoid racing with initializeDevice().
    var isHardwareInitialized: Bool = false
    /// Metering-only CoreAudio connection. Used when `device` is XPCDeviceConnection
    /// (daemon broken on macOS 26) — software metering still works via CoreAudio IO proc
    /// because it reads from the USB audio class driver, not the daemon.
    var meterDevice: CoreAudioDeviceConnection?
    /// Trim visibility belongs to the physical unit, as it did in the original
    /// app. Evidence: `Docs/2026-11-21-parity-differences.md:242` (I10).
    /// The legacy global values are copied to unit A on first access.
    private func unitPreferenceKey(_ base: String, unit: DeviceUnit) -> String {
        let scope = preferenceViewScope(for: unit)
        return "\(base).\(unit == .a ? "a" : "b").\(scope.key ?? scope.generation.uuidString)"
    }

    private func unitBoolPreference(_ base: String, unit: DeviceUnit) -> Bool {
        _ = unitPreferenceRevision
        let scope = preferenceViewScope(for: unit)
        guard let scopeKey = scope.key else {
            return unit == .a ? (UserDefaults.standard.object(forKey: base) as? Bool ?? false) : false
        }
        let key = "\(base).\(unit == .a ? "a" : "b").\(scopeKey)"
        if UserDefaults.standard.object(forKey: key) == nil,
           unit == .a,
           let legacy = UserDefaults.standard.object(forKey: base) as? Bool {
            UserDefaults.standard.set(legacy, forKey: key)
        }
        return UserDefaults.standard.bool(forKey: key)
    }

    private func setUnitBoolPreference(_ value: Bool, _ base: String, unit: DeviceUnit) {
        guard let scopeKey = preferenceViewScope(for: unit).key else { return }
        UserDefaults.standard.set(value, forKey: "\(base).\(unit == .a ? "a" : "b").\(scopeKey)")
        unitPreferenceRevision &+= 1
    }

    var showInputTrims: Bool {
        get { unitBoolPreference("inputShowTrims", unit: activeUnit) }
        set { setUnitBoolPreference(newValue, "inputShowTrims", unit: activeUnit) }
    }
    var showOutputTrims: Bool {
        get { unitBoolPreference("outputShowTrims", unit: activeUnit) }
        set { setUnitBoolPreference(newValue, "outputShowTrims", unit: activeUnit) }
    }

    func insertLabelsJSON(for unit: DeviceUnit) -> String {
        _ = unitPreferenceRevision
        guard let scopeKey = preferenceViewScope(for: unit).key else {
            return unit == .a ? (UserDefaults.standard.string(forKey: "micPreInsertLabels") ?? "{}") : "{}"
        }
        let key = "micPreInsertLabels.\(unit == .a ? "a" : "b").\(scopeKey)"
        if UserDefaults.standard.object(forKey: key) == nil, unit == .a,
           let legacy = UserDefaults.standard.string(forKey: "micPreInsertLabels") {
            UserDefaults.standard.set(legacy, forKey: key)
        }
        return UserDefaults.standard.string(forKey: key) ?? "{}"
    }

    func setInsertLabelsJSON(_ value: String, for unit: DeviceUnit) {
        guard let scopeKey = preferenceViewScope(for: unit).key else { return }
        UserDefaults.standard.set(value, forKey: "micPreInsertLabels.\(unit == .a ? "a" : "b").\(scopeKey)")
        unitPreferenceRevision &+= 1
    }
    /// Whether idle meter segments show muted zone coloring (green/yellow/red gradient).
    /// Disabled by default — when enabled, unlit segments show a dim version of their zone color.
    var showMeterZoneColoring: Bool = UserDefaults.standard.bool(forKey: "meterZoneColoring") {
        didSet { UserDefaults.standard.set(showMeterZoneColoring, forKey: "meterZoneColoring") }
    }
    /// Current speaker level (shared between monitor panel and volume key handler).
    var unitBMonitor = UnitBMonitorState()
    var unitBDeviceInfo = SymphonyDeviceInfo()
    var speakerLevel: Double = -20
    /// Current speaker mute state (shared between monitor panel and volume key handler).
    var speakerMuted: Bool = false
    /// Current Analog Out Format. Line mode disables the speaker monitor
    /// controls, and the Mac's volume keys then do nothing unless a headphone
    /// is chosen under Volume Keys › Audio Output (a ThunderBridge driver
    /// before build 142 moves Headphone 1 by itself in Line mode).
    var speakerOutputMode: UInt32 = SpeakerOutputLogic.stereo
    /// HP1 level (shared between output tab and monitor panel).
    var hp1Level: Double = -20
    /// HP1 mute (shared between output tab and monitor panel).
    var hp1Muted: Bool = false
    /// HP2 level (shared between output tab and monitor panel).
    var hp2Level: Double = -20
    /// HP2 mute (shared between output tab and monitor panel).
    var hp2Muted: Bool = false
    /// The setup file currently associated with the document window.
    var currentSetupURL: URL? = AppState.loadCurrentSetupURL() {
        didSet { UserDefaults.standard.set(currentSetupURL?.path, forKey: "currentSetupURL") }
    }
    /// Whether a stored setup value changed since the last save or recall.
    var setupDocumentEdited = false
    var initialSetupRestoreFinished = false {
        didSet { if initialSetupRestoreFinished && !oldValue { suppressMacVolumeOverlay() } }
    }
    @ObservationIgnored var recentSetupRecallHandled = false
    @ObservationIgnored var recentSetupRecallTask: Task<Void, Never>?
    @ObservationIgnored weak var recentSetupRecallConnection: (any DeviceConnection)?
    @ObservationIgnored var setupRecallDepth = 0
    @ObservationIgnored var setupRecallRevision = 0
    @ObservationIgnored private var setupEditRevision = 0
    var setupDocumentTitle: String { SetupDocumentTitle.title(for: currentSetupURL) }

    static func loadCurrentSetupURL() -> URL? {
        guard let path = UserDefaults.standard.string(forKey: "currentSetupURL"),
              FileManager.default.fileExists(atPath: path) else {
            UserDefaults.standard.removeObject(forKey: "currentSetupURL")
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    @MainActor
    func markSetupEdited(_ kind: SetupEditKind) {
        guard kind.marksDocumentEdited, setupRecallDepth == 0 else { return }
        // Over USB a setup file holds only channel names: nothing in it to
        // save, so no edited mark and no save prompt.
        guard transportType != .usb else { return }
        setupEditRevision &+= 1
        guard currentSetupURL != nil else { return }
        setupDocumentEdited = true
        WindowDocumentBridge.updateEditedState()
    }

    @MainActor
    func showLevelOverlay(source: LevelOverlaySource, level: Double, muted: Bool = false,
                          change: LevelOverlayChangeSource = .maestroControl) {
        guard change.showsOverlay, !hardwareWritesSuspended, setupRecallDepth == 0 else { return }
        LevelOverlayController.shared.show(source: source, level: level, muted: muted)
    }
    /// Changes whenever every reading a page holds has gone stale and the panels
    /// must re-read from scratch: a preset load, or a reconnect. Pages observe it
    /// with `.task(id: appState.viewReloadToken)`.
    var viewReloadToken: UUID = UUID()

    /// The UI-facing split between transport presence and Symphony endpoint
    /// health. Both ThunderBridge PCI personalities use the same transport
    /// state; USB only reports a transport when its audio endpoint exists.
    var connectionPresentation: ConnectionPresentation {
        ConnectionPresentation(
            transportType: transportType,
            transportPresent: transportPresent,
            endpointState: connectionMode == .hardware ? .connected : .disconnected
        )
    }

    /// Status text for the right side of the detail toolbar. A powered-off
    /// Symphony behind an enumerated ThunderBridge is distinct from a missing
    /// transport, while the existing scanning/error messages remain intact.
    var endpointStatusMessage: String {
        if let hardwareSuspendedNote { return hardwareSuspendedNote }
        if connectionMode == .hardware, let restoreStatusNote { return restoreStatusNote }
        if endpointDisconnected {
            if portStatusMessage != nil,
               let short = PortStatusMessage.shortStatus(thunderboltPortLink, port: .primary,
                                                         bothPortsInUse: thunderboltBothPortsInUse) {
                return short
            }
            return connectionPresentation.endpointLabel
        }
        return statusMessage
    }

    /// The transport is there but the unit behind it is not answering.
    var endpointDisconnected: Bool {
        connectionMode == .disconnected && transportPresent && transportType != nil
    }

    /// The driver's link watch on port 1, as the status message needs it.
    /// Updated by the ThunderBridge health loop only when it changes.
    var thunderboltPortLink: PortStatusMessage.Link = .other

    /// Apogee's wording for why nothing answers on port 1 of the ThunderBridge
    /// or Symphony 64 PCIe card ("No hardware has been detected on the primary
    /// port of the ThunderBridge. Verify…"), nil when the driver does not say.
    var portStatusMessage: String? {
        guard endpointDisconnected, transportType == .thunderbolt else { return nil }
        return PortStatusMessage.primary(thunderboltPortLink, card: thunderboltCardPhrase)
    }

    /// "the ThunderBridge" or "the Symphony 64 PCIe card", looked up by the
    /// health loop when the link state changes (an IOKit query).
    var thunderboltCardPhrase: String = PortStatusMessage.defaultCard

    /// 64 channels (both ports) are selected on the device. Read by the
    /// health loop while the link is down, because `portSelection` is cleared
    /// when the unit stops answering. The short status names the port only
    /// then ("No hardware detected on port 1").
    var thunderboltBothPortsInUse = false

    /// The health loop's link reading: store it (and which card it is) only
    /// when it changes, so the 2 s loop does not churn the views.
    /// `bothPortsInUse` is asked for only while the link is down.
    @MainActor
    func updateThunderboltPortLink(_ link: PortStatusMessage.Link,
                                   bothPortsInUse: @autoclosure () -> Bool = false) {
        if link != .other {
            let both = bothPortsInUse()
            if both != thunderboltBothPortsInUse { thunderboltBothPortsInUse = both }
        }
        guard link != thunderboltPortLink else { return }
        if link != .other {
            let phrase = PortStatusMessage.cardPhrase(
                pciIdentifier: SystemExtensionInstaller.shared.presentThunderBridgePCIIdentifier())
            if phrase != thunderboltCardPhrase { thunderboltCardPhrase = phrase }
        }
        thunderboltPortLink = link
    }

    /// Session-only horizontal offsets for the wide Input, Output, and Mixer
    /// tabs. These reset naturally when AppState is recreated on relaunch.
    /// Session-only UI bookkeeping. Scroll position writes can arrive once per
    /// display frame from both SwiftUI and AppKit. This state is read explicitly
    /// when a control tab is created/restored, so it must not participate in
    /// Observation and invalidate the whole tab tree during a drag.
    @ObservationIgnored
    var controlTabScrollOffsets: [NavigationArea: CGFloat] = [:]

    func controlTabScrollOffset(for area: NavigationArea) -> CGFloat {
        controlTabScrollOffsets[area] ?? 0
    }

    func setControlTabScrollOffset(_ offset: CGFloat, for area: NavigationArea) {
        controlTabScrollOffsets[area] = max(0, offset)
    }

    // MARK: - USB Recovery Detection

    /// Incremented when USB recovery is detected (meter polling failure→success transition).
    /// MixerView observes via .onChange to re-sync persisted state to hardware.
    var deviceRecoveryCount: Int = 0
    /// Tracks whether meter polling was in a disconnected/failed state.
    private var meterPollWasDisconnected: Bool = false
    /// Debounce guard — prevents rapid recovery events from triggering multiple re-syncs.
    var lastRecoveryTime: Date = .distantPast

    /// ThunderBridge remains enumerated when the interface loses power, so its
    /// PCI/Core Audio presence cannot drive lifecycle state. This task polls the
    /// dext's FPGA-backed health probe and reconnects only after it recovers.
    private var thunderboltHealthTask: Task<Void, Never>?
    /// Last live FPGA/XLink presence verdict. Meter polling consults this
    /// cached result instead of issuing a control transaction every 50 ms.
    /// Hidden opt-in for the Core Audio input tap behind the software meters
    /// (`defaults write com.danielraffel.maestro MaestroSoftwareMetering -bool YES`).
    /// Off by default since 0.8.29: both transports meter from hardware, and an
    /// input IOProc makes macOS treat the app as a microphone client.
    static var softwareMeteringOptedIn: Bool {
        UserDefaults.standard.bool(forKey: "MaestroSoftwareMetering")
    }

    private var thunderboltHardwareResponsive = true
    /// Distinguish reconnect startup grace from a device that was already
    /// proven healthy. Once a live probe has succeeded, use the shorter loss
    /// threshold so power-off is reflected promptly.
    private var thunderboltHasHealthyProbe = false
    /// The driver's link-recovery count when last seen, nil until the first
    /// probe. A recovery re-sends the board-order capture table.
    private var thunderboltSeenRecoveryCount: UInt32?
    /// Avoid reopening the private dext client on every one-second failed probe.
    private var thunderboltControlReconnectAttempted = false
    /// Bounded tolerance for a DriverKit upgrade handoff, owned by the health
    /// loop and read by the meter poll so the two can never disagree. sysextd
    /// can list a `terminating_for_upgrade` record for hours (2026-10-21: build
    /// 105 still owned the PCI card 30+ min after 106 was "activated"), so a
    /// second registration must never be an unbounded exception.
    private var thunderboltExtensionSwapGrace = ExtensionSwapGrace()
    private var thunderboltExtensionSwapGraceActive = false
    /// Linear trims (SW Return fader and mute) applied to the host-playback
    /// peaks that drive the ThunderBridge SW Return meters, so they read the
    /// same as USB, where the proxy meters after its own trims. Refreshed from
    /// the persisted mixer state whenever the mixer saves and when polling starts.
    var softwareReturnMeterGains: [(left: Double, right: Double)] = [(1.0, 1.0), (1.0, 1.0)]
    /// The same strips' fader and mute whatever Pre-Mute Metering says: what
    /// the Software Return passes on to its mixer's Master.
    var softwareReturnPostFaderGains: [(left: Double, right: Double)] = [(1.0, 1.0), (1.0, 1.0)]

    /// Per mixer, the gain from host playback to the mixer's output over USB
    /// (`USBMasterMeter.gain`): what its Software Return adds to the Master meter.
    var usbMasterMeterGains: [Double] = [1.0, 1.0]

    /// Recompute `softwareReturnMeterGains` and `usbMasterMeterGains` from the
    /// persisted Software Return and Master state.
    @MainActor
    func refreshSoftwareReturnMeterGains() {
        let defaults = mixerPreferences
        // Each mixer has its own mute; the stereo fader's level is stored per
        // mixer (both sides hold the same value). Software Return has no pan.
        let returns = (0..<2).map { mixer -> (level: Double, muted: Bool, soloed: Bool) in
            let saved = MixerStateSnapshot.savedSoftwareReturn(mixer: mixer, preferences: defaults)
            return (defaults.object(forKey: "mixerSWReturnLeftLevel_\(mixer)") as? Double ?? saved.level,
                    saved.isMuted, saved.isSoloed)
        }
        // With Pre-Mute Metering on (the default) the meter shows what arrives
        // at the strip, as the input strips do; off, what the strip passes on.
        let preMute = UserDefaults.standard.object(forKey: SoftwareReturnMeterGain.preMuteMeteringKey) as? Bool ?? true
        softwareReturnMeterGains = returns.map {
            SoftwareReturnMeterGain.meterGains(preMuteMetering: preMute, levelDB: $0.level, isMuted: $0.muted)
        }
        softwareReturnPostFaderGains = returns.map {
            SoftwareReturnMeterGain.meterGains(preMuteMetering: false, levelDB: $0.level, isMuted: $0.muted)
        }
        usbMasterMeterGains = returns.enumerated().map { mixer, own in
            // A soloed input strip silences the return in the unit's mixer,
            // so it adds nothing to the Master meter either.
            let inputs: [MixerChannelState] = channelStateStore.load(ChannelStateStore.mixerKey(mixer)) ?? []
            return USBMasterMeter.gain(
                softwareReturnLevelDB: own.level, softwareReturnMuted: own.muted,
                silencedBySolo: USBMasterMeter.softwareReturnSilencedBySolo(
                    returnSoloed: own.soloed, anyInputSoloed: inputs.contains(where: \.isSoloed)),
                masterLevelDB: MixerStateSnapshot.savedMasterLevel(mixer: mixer, preferences: defaults))
        }
    }

    /// A ThunderBridge device that just appeared (or a Symphony that just
    /// powered on) should become the default output only once its endpoint is
    /// live; the device exists even while the Symphony is off (dext 108+).
    private var pendingAutoSwitchAfterReconnect = false
    /// The USB auto-switch's wait for "Maestro USB"; cancelled by a newer edge.
    private var usbAutoSwitchTask: Task<Void, Never>?
    /// Re-probes a present ThunderBridge while the app is connected over USB.
    var thunderboltWatchTask: Task<Void, Never>?
    /// Change detection for the persisted probe log (see `logThunderboltProbe`).
    private var thunderboltLastProbeKey = ""
    private var thunderboltProbeCount = 0
    /// Persisted lifecycle evidence: `log show --predicate 'subsystem == "com.danielraffel.maestro" AND category == "tb-lifecycle"'`.
    private static let tbLog = Logger(subsystem: "com.danielraffel.maestro", category: "tb-lifecycle")
    /// Allow the dext/Core Audio service a short startup window after a
    /// reconnect. Device-list appearance can precede a usable FPGA/XLink
    /// response by several polling intervals; removal notifications still
    /// provide the immediate unplug path.
    private let thunderboltHealthFailureThreshold = 4
    /// A terminating older registration is expected briefly during an upgrade,
    /// but it must not suppress power-cycle recovery indefinitely. macOS can
    /// leave that registration around for much longer than the actual handoff.
    private let thunderboltExtensionSwapGraceInterval: TimeInterval = 15

    // No separate USB health check. The optional 30-second probe that was here
    // was redundant and broken: the front panel sync already reads the unit
    // through the same helper every 300 ms for the life of the app (a failed
    // read is what makes the helper reopen a stale connection), and the probe
    // kept using the connection it started with after a reconnect, and never
    // started unless Maestro launched on USB.

    @MainActor
    func startThunderboltHealthCheck() {
        thunderboltHealthTask?.cancel()
        guard device is ThunderboltDeviceConnection else { return }
        // Do not let the first meter poll trust stale DMA contents while the
        // first live FPGA/XLink probe is still in flight.
        thunderboltHardwareResponsive = false
        thunderboltHasHealthyProbe = false
        thunderboltExtensionSwapGrace = ExtensionSwapGrace(interval: thunderboltExtensionSwapGraceInterval)
        thunderboltExtensionSwapGraceActive = false
        thunderboltLastProbeKey = ""
        thunderboltProbeCount = 0
        Self.tbLog.notice("health loop start mode=\(String(describing: self.connectionMode), privacy: .public)")
        thunderboltHealthTask = Task { @MainActor [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self else { break }
                guard let tb = self.device as? ThunderboltDeviceConnection else { break }
                if self.deferHealthCheckForSleep() {
                    try? await Task.sleep(for: .seconds(2))
                    continue
                }
                // One read per cycle of the dext's link-watch state (dext 113,
                // kSelectorReadLinkState): no bus traffic. The driver samples the
                // card's XLink clock-detect bit itself (2 s while down, 5 s idle,
                // not at all while audio wraps flow) and re-locks on the clock's
                // return. The PCI endpoint can remain enumerated after the
                // Symphony is powered off, in which case stale timing and meter
                // memory must never keep the UI in Connected state.
                let verdict = await Task.detached(priority: .utility) {
                    tb.probeEndpoint()
                }.value
                // The probe is not cancellable. If a reconnect ran while it was
                // in flight (front-panel switch to a USB mode, cable pull) this
                // task is cancelled and `device` is no longer `tb`; acting on
                // the stale verdict marked a freshly connected USB session
                // "Symphony disconnected" (2026-10-22 12:59).
                guard !Task.isCancelled,
                      (self.device as? ThunderboltDeviceConnection) === tb else { break }
                if self.deferHealthCheckForSleep() {
                    try? await Task.sleep(for: .seconds(2))
                    continue
                }
                self.applyPhantomObservations(tb.lastLinkState)
                // D5: latch the driver instance from the read just made, before
                // anything could edit a mixer on it.
                self.observeCardMixerInstance(tb.lastLinkState)
                let audioRunning = tb.isAudioRunning
                let healthy = verdict.isLive
                self.updateThunderboltPortLink(
                    tb.lastLinkState?.state.portStatusLink ?? .other,
                    bothPortsInUse: PortSelection(dataSourceID: tb.portSelectionID()) == .ports1And2)
                // Registrations come from the list AppShell refreshes every two
                // seconds; populate it once here if nothing has yet, rather
                // than re-reading sysextd's database every second.
                if self.installedDexts == nil {
                    self.installedDexts = SystemExtensionInstaller.shared.installedDexts()
                }
                let registrations = self.installedDexts
                // During a DriverKit replacement macOS can expose the new
                // registration before the outgoing user-server releases the
                // PCI function. Tolerate failed probes for a bounded window
                // measured from the FIRST FAILED probe while two registrations
                // are listed; a lingering terminating record can sit in the
                // database for 30+ min with every probe live.
                let swapGraceActive: Bool
                if healthy {
                    self.thunderboltExtensionSwapGrace.reset()
                    swapGraceActive = false
                } else {
                    swapGraceActive = self.thunderboltExtensionSwapGrace.update(
                        registrationCount: registrations?.count ?? 0, now: Date())
                }
                self.thunderboltExtensionSwapGraceActive = swapGraceActive
                self.thunderboltHardwareResponsive = healthy
                self.logThunderboltProbe(verdict, audioRunning: audioRunning, linkState: tb.lastLinkState,
                                         registrations: registrations,
                                         swapGrace: swapGraceActive, failures: failures)
                if healthy {
                    self.thunderboltHasHealthyProbe = true
                    self.thunderboltControlReconnectAttempted = false
                    // The order each unit's tables are in (it can change on a
                    // link recovery or when unit B is set up), before anything
                    // below writes routing in it.
                    await self.refreshThunderboltChannelOrder(tb)
                    // A link recovery in place (no disconnect, so no connect
                    // replay) puts the driver's board-order capture table back
                    // on the unit: put the saved input routing back over it.
                    // Every ConfigureSymphonyLink after Start is a recovery and
                    // bumps this count; != also covers a driver restart.
                    if let count = tb.lastLinkState?.recoveryCount {
                        if let seen = self.thunderboltSeenRecoveryCount, count != seen,
                           self.connectionMode == .hardware {
                            print("[Maestro] ThunderBridge link recovery \(seen) → \(count): re-reading cards, replaying output table, mixers and input routing")
                            // D5 never runs across an in-place recovery.
                            self.cancelCardMixerRestore()
                            // The recovery itself put the driver's table on
                            // the unit, whether or not the replay below can
                            // run (cards unread, identity unknown): until a
                            // replay lands, strips and meters are numbered
                            // from the driver's table, not the saved one.
                            self.thunderboltInputRoutingWritten = false
                            self.invalidateThunderboltInputMeterMap()
                            // The strips have just been renumbered: the
                            // mixers are owed a complete write whether or
                            // not the input replay below succeeds.
                            tb.cardMixers.noteOwed()
                            // The driver lays its capture table out from the
                            // cards it read during the recovery (a Symphony off
                            // at Start, or a card swapped while off): read them
                            // too, so the grid and the replay use the same table.
                            self.retryFailedIdentityOnRecovery()
                            await self.readCardTypes()
                            // The whole ordered sequence, not the input
                            // routing alone: the output table, the card
                            // mixers, the routes they feed, then the input
                            // routing.
                            self.invalidateCardOutputTable(tb)
                            if self.recallInFlight {
                                self.replayDeferral.request()
                            } else if self.usesTwoUnitReplay {
                                self.twoUnitReplayNeeded = true
                            } else {
                                await self.syncInputRoutingToHardware()
                                await self.syncOutputRoutingToHardware()
                            }
                        }
                        self.thunderboltSeenRecoveryCount = count
                    }
                    // A card re-init or a restarted driver without a recovery
                    // count change, a failed write, a deferred route or mixer
                    // edit: the restore runs again until nothing is owed.
                    await self.serviceCardOutputTable(tb)
                    // The volume keys' output, where the driver now serving
                    // has not been told it.
                    await self.serviceKeyboardVolumeOutput()
                    // The VBus size, where the driver now serving has not
                    // been told it (a new driver starts without VBus).
                    await self.serviceVBus()
                    if self.inputRoutingReplayNeeded, !self.recallInFlight,
                       self.connectionMode == .hardware {
                        self.inputRoutingReplayNeeded = false
                        await self.syncInputRoutingToHardware()
                    }
                    // A new converter chain (32 <-> 64 channels, a Device
                    // Type change): its saved routes go to the driver.
                    if self.converterRoutingReplayNeeded, self.connectionMode == .hardware {
                        self.converterRoutingReplayNeeded = false
                        await self.replayConverterRouting(resetFirst: true)
                    }
                    // Unit B is configured by the driver a moment after 64
                    // channels start, and forgotten when port 2 stops.
                    await self.refreshUnitBOffMain(tb)
                    await self.replayUnitBSettings()
                    // D5: a restore still pending on this driver instance.
                    self.rearmCardMixerRestoreIfPending()
                    if failures > 0 {
                        print("[Maestro] ThunderBridge health probe recovered")
                        Self.tbLog.notice("probe recovered after \(failures) failures")
                    }
                    failures = 0
                    if self.connectionMode == .disconnected {
                        Self.tbLog.notice("endpoint live while disconnected — reconnecting hardware")
                        // A Symphony coming back is "the device you just
                        // connected": let the reconnect path auto-switch once
                        // the endpoint is live, like a cable plug-in.
                        self.pendingAutoSwitchAfterReconnect = true
                        Task { @MainActor [weak self] in await self?.reconnectHardware() }
                        break
                    }
                } else {
                    failures += 1
                    print("[Maestro] ThunderBridge health probe failed \(failures) times (\(verdict.label))")
                    // 3 samples at the 2 s cadence (≈6 s) once a healthy probe has
                    // been seen: long enough to ride out a re-lock in progress,
                    // short enough that a powered-off unit reads as off promptly.
                    let threshold = self.thunderboltHasHealthyProbe
                        ? 3
                        : self.thunderboltHealthFailureThreshold
                    if failures >= threshold && self.connectionMode == .hardware && !swapGraceActive {
                        print("[Maestro] ThunderBridge health probe failed \(failures) times — marking hardware disconnected")
                        Self.tbLog.notice("marking Symphony disconnected after \(failures) failed probes (\(verdict.label, privacy: .public))")
                        self.cancelCardMixerRestore()
                        self.markHardwareDisconnected()
                        // A powered-off Symphony can leave the PCI/Core Audio
                        // service registered while its existing IOUserClient
                        // has gone stale. Reopen only this private control path;
                        // the next health iterations will promote the device
                        // back to Connected once timing and XLink both answer.
                        if !self.thunderboltControlReconnectAttempted {
                            self.thunderboltControlReconnectAttempted = true
                            if let tb = self.device as? ThunderboltDeviceConnection {
                                Task.detached(priority: .utility) { tb.reconnectDextClient() }
                            }
                        }
                    }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Shared by health failure and wake exhaustion, including the startup settle.
    @MainActor
    func markHardwareDisconnected() {
        stopMeterPolling()
        statusMessage = "Symphony disconnected"
        connectionMode = .disconnected
        awaitingSymphonyReturn = true
        transportPresent = true
        isHardwareInitialized = false
        thunderboltHardwareResponsive = false
        clearMeterState()
        viewReloadToken = UUID()
    }

    /// Persist each probe to the unified log so a power-cycle test leaves
    /// evidence even when the app was launched from Finder and its stdout went
    /// nowhere. Logs on every change of verdict / link word / audio state /
    /// registrations / mode, plus a heartbeat every ten probes.
    @MainActor
    private func logThunderboltProbe(_ verdict: ThunderboltEndpointVerdict, audioRunning: Bool?,
                                     linkState: LinkState? = nil,
                                     registrations: [InstalledDextInfo]?, swapGrace: Bool,
                                     failures: Int) {
        thunderboltProbeCount += 1
        let h = verdict.health
        func hex(_ v: UInt32?) -> String { v.map { "0x" + String($0, radix: 16) } ?? "-" }
        let regs = registrations.map { $0.map(\.displayVersion).joined(separator: "+") } ?? "?"
        let key = "\(verdict.label) xlink=\(hex(h?.xlinkStatus)) audio=\(audioRunning.map(String.init) ?? "?") regs=\(regs) grace=\(swapGrace) mode=\(String(describing: connectionMode))"
        let changed = key != thunderboltLastProbeKey
        guard changed || thunderboltProbeCount % 10 == 0 else { return }
        thunderboltLastProbeKey = key
        let detail = "clk=\(hex(h?.clkCtrl)) int=\(hex(h?.intStatus)) gcsr=\(hex(h?.gcsr)) rate=\(h?.sampleRate ?? 0) frame=\(h?.frameReadback ?? 0)/\(h?.expectedFrame ?? 0) failures=\(failures) n=\(thunderboltProbeCount)"
        let watch = linkState.map {
            " watch=\($0.watchTicks)t/\($0.audioWraps)w irq=\($0.irqCount) recov=\($0.recoveryCount) reinit=\($0.cardReinitCount)"
        } ?? ""
        Self.tbLog.notice("probe \(changed ? "changed" : "heartbeat", privacy: .public): \(key, privacy: .public) \(detail, privacy: .public)\(watch, privacy: .public)")
    }

    @MainActor
    func stopThunderboltHealthCheck() {
        thunderboltHealthTask?.cancel()
        thunderboltHealthTask = nil
        // EXPERIMENT (64 channels): the port selector belongs to the device
        // that is going away. A no-op unless a two-port driver published one.
        stopPortSelectionObservation()
    }

    @MainActor
    func clearMeterState() {
        inputMeterLevels = Array(repeating: -60.0, count: inputMeterLevels.count)
        outputMeterLevels = Array(repeating: -60.0, count: outputMeterLevels.count)
        mixerMeterLevels = Array(repeating: -60.0, count: mixerMeterLevels.count)
        digitalInputMeterLevels = Array(repeating: -60.0, count: digitalInputMeterLevels.count)
        digitalOutputMeterLevels = Array(repeating: -60.0, count: digitalOutputMeterLevels.count)
        inputPeakHold = Array(repeating: -60.0, count: inputPeakHold.count)
        outputPeakHold = Array(repeating: -60.0, count: outputPeakHold.count)
        digitalInputPeakHold = Array(repeating: -60.0, count: digitalInputPeakHold.count)
        digitalOutputPeakHold = Array(repeating: -60.0, count: digitalOutputPeakHold.count)
    }

    // MARK: - I/O Card Types (P3G-15c)

    /// Primary option board type (slot 0). Read via USB 0xA1.
    var primaryBoardType: IOCardType = .none
    /// Secondary option board type (slot 1). Read via USB 0xA1.
    var secondaryBoardType: IOCardType = .none

    /// Where `primaryBoardType` actually came from this session.
    ///
    /// `0xA1` card detection fails on USB (`kIOReturnNotResponding`; the proxy has
    /// no `0xA1` handler), so the value on screen is very often a `UserDefaults`
    /// restore. Anything that rewrites the routing table from the card complement
    /// - Reset Routing - MUST refuse on a value that was not measured: a WRONG
    /// card (stale cache), not `.none`, is the expected failure mode, and a wrong
    /// card re-points the ADAT outputs.
    var primaryBoardSource: BoardDetectionSource = .unknown
    /// Where `secondaryBoardType` came from. See `primaryBoardSource`.
    var secondaryBoardSource: BoardDetectionSource = .unknown

    /// The Device Info panel's last assembled content, published by Device Settings when it
    /// loads. The About box copies it so a bug report is one Copy button, not two pages;
    /// nil until Device Settings has been opened once, and the About box falls back to what
    /// this object knows on its own.
    var deviceInfoSnapshot: DeviceInfoReport?
    /// ThunderBridge component versions a Device Settings load read, kept for
    /// the connection and identity generation they were read on. See
    /// AppState+DeviceVersions.swift.
    @ObservationIgnored var deviceInfoVersionsCache: DeviceInfoVersionsCache?

    /// What `sysextd` reports about the ThunderBridge driver extension, fetched once at
    /// launch. Empty means nothing is registered; nil means the query itself failed,
    /// which is a different claim and is reported as such.
    var installedDexts: [InstalledDextInfo]?

    /// Apogee's original Symphony I/O MkI drivers found on this Mac, checked at
    /// launch and when Device Settings opens. nil until the first check has run.
    /// See OriginalApogeeDriverCheck.swift.
    var originalApogeeDrivers: OriginalApogeeDriverFinding?
    @ObservationIgnored
    var originalApogeeDriverCheckInFlight = false
    /// A second Symphony I/O on port 2 takes its clock from unit A through
    /// Loop Sync, so unit A cannot take Loop Sync itself.
    var unitBFollowsUnitA: Bool { unitB != nil }

    /// The Clock Source menu's rows for what is connected. One list for the
    /// menu in Device Settings and the name in the status bar, so the two
    /// always read the same ("SPDIF Coax 1-2", not "I/O Board 1").
    func clockSourceChoices(sampleRate: Double?) -> [ClockSourceChoice] {
        // Older converters: their own clock or word clock, as the original
        // offered, written as the converter config's clock bit.
        if convertersIdentified { return ClockSourceMenu.converters }
        guard transportType != .usb else { return ClockSourceMenu.usb }
        return ClockSourceMenu.unitAChoices(
            ClockSourceMenu.thunderbolt(slot1: primaryBoardType,
                                        slot2: secondaryBoardType,
                                        sampleRate: sampleRate,
                                        opticalIsSPDIF: channelNaming.opticalIsSPDIF),
            unitBFollows: unitBFollowsUnitA)
    }

    /// The name of the reported clock source as its menu row reads; the plain
    /// source name when no row matches (a board the menu does not list).
    func reportedClockSourceName(sampleRate: Double?) -> String? {
        guard let key = reportedClockSource else { return nil }
        let choices = clockSourceChoices(sampleRate: sampleRate)
        if let row = ClockSourceMenu.row(for: key, in: choices),
           let choice = choices.first(where: { $0.id == row }) {
            return choice.name
        }
        return ClockSourceMenu.statusName(for: key)
    }
    /// The clock source the connection reports now, as a `ClockSourceMenu`
    /// key, kept current by the front panel sync from the reading it already
    /// takes of the unit (the unit's own answer, no extra traffic) and by
    /// Device Settings when it writes one. A Core Audio change notification
    /// was tried first and showed the old source: it arrives before the unit
    /// reports the change, and nothing re-read it afterwards (2026-11-20).
    /// It follows changes
    /// made outside Maestro (Audio MIDI Setup, a DAW) and by the driver, which
    /// the status bar and the Clock Source menu both showed stale before:
    /// the bar always read "Internal", and the menu kept its last value.
    /// Nil until read, and while converters own the clock.
    var reportedClockSource: UInt32?
    /// Whether the unit is locked to its clock source, by the original's rule
    /// (`ClockSourceMenu.isLocked`): Internal always, otherwise the unit's own
    /// "external clock locked" flag from the front panel sync's reading.
    /// ThunderBridge and PCIe only; nil elsewhere and until the first reading,
    /// where the views keep their Core Audio rate comparison. That comparison
    /// can never report an unlocked external clock there: the card keeps
    /// running at the nominal rate whatever the unit's clock input is doing.
    var reportedClockLocked: Bool?

    /// The build the driver serving the ThunderBridge reports for itself (nil
    /// when no ThunderBridge connection is open). Differs from what sysextd
    /// lists when macOS keeps an old copy on the card until restart.
    var servingDextBuild: ServingDextBuild? {
        didSet {
            // Whose level the driver's volume control holds depends on the
            // build; what was skipped while it was unknown is read now.
            if servingDextBuild != oldValue, transportType == .thunderbolt {
                readASPVolume()
                readASPMute()
            }
        }
    }
    /// A read of `servingDextBuild` is under way (`refreshServingDextBuild`).
    @ObservationIgnored
    var servingDextBuildReadInFlight = false
    @ObservationIgnored
    var driverActivationObserver: Task<Void, Never>?

    /// Board hardware major versions, when read (0xA0). See
    /// `BoardTypeReading.hardwareMajor`.
    var primaryBoardHardwareMajor: UInt8?
    var secondaryBoardHardwareMajor: UInt8?

    /// Slot 0 board type WITH provenance.
    var primaryBoardReading: BoardTypeReading {
        BoardTypeReading(card: primaryBoardType, source: primaryBoardSource,
                         hardwareMajor: primaryBoardHardwareMajor)
    }
    /// Slot 1's card as the ThunderBridge driver lays its capture table out
    /// from it (`SymphonyIODefaultRouting.thunderboltInputRoutes(slot1:)`):
    /// nil until the type has been read from the unit this session by a
    /// driver that packs.
    var thunderboltCaptureSlot1: IOCardType? {
        SymphonyIODefaultRouting.thunderboltCaptureSlot1(
            card: primaryBoardType, source: primaryBoardSource, serving: servingDextBuild)
    }
    /// Slot 2's counterpart of `thunderboltCaptureSlot1`, by the same trust
    /// rule: nil until slot 2's type has been read from the unit this session
    /// by a driver that reports its build.
    var thunderboltCaptureSlot2: IOCardType? {
        SymphonyIODefaultRouting.thunderboltCaptureSlot1(
            card: secondaryBoardType, source: secondaryBoardSource, serving: servingDextBuild)
    }
    /// What the serving driver (build 150+) reports it programmed into each
    /// unit's routing layer (selector 17): read at connect, after each link
    /// recovery and on every healthy probe (`refreshThunderboltChannelOrder`).
    /// Nil from an older driver and off ThunderBridge.
    var thunderboltAppliedChannelOrder: ThunderboltAppliedChannelOrder?
    /// How `unit`'s host channels are laid out on ThunderBridge, and the slot
    /// types to build its tables and names from
    /// (`ThunderboltUnitChannelOrder.resolve`): what a build-150 driver
    /// reports it applied, card by card under an older one (from the app's
    /// own trusted slot types). Nil while a build-150 driver has not
    /// reported it: no routing is written then. Card by card off ThunderBridge.
    func thunderboltUnitOrder(unit: DeviceUnit = .a) -> ThunderboltUnitChannelOrder? {
        guard transportType == .thunderbolt else {
            return ThunderboltUnitChannelOrder(order: .cardByCard, slot1: nil, slot2: nil)
        }
        let fallback: (slot1: IOCardType?, slot2: IOCardType?) = unit == .a
            ? (thunderboltCaptureSlot1, thunderboltCaptureSlot2)
            : (unitB?.channelOrderSlot1, unitB?.channelOrderSlot2)
        // Simulated cards and units: no driver to ask, the order the build
        // would serve from the simulated types.
        if unit == .a ? primaryBoardSource == .simulated : simulatedUnitB != nil {
            return ThunderboltUnitChannelOrder(order: .serving(servingDextBuild),
                                               slot1: fallback.slot1, slot2: fallback.slot2)
        }
        return ThunderboltUnitChannelOrder.resolve(serving: servingDextBuild,
                                                   applied: thunderboltAppliedChannelOrder?.unit(unit),
                                                   fallback: fallback)
    }
    /// `thunderboltUnitOrder` for drawing: while the order is not known,
    /// the tables the driver keeps for unknown types (card by card).
    func thunderboltDisplayOrder(unit: DeviceUnit = .a) -> ThunderboltUnitChannelOrder {
        thunderboltUnitOrder(unit: unit) ?? ThunderboltUnitChannelOrder(order: .cardByCard, slot1: nil, slot2: nil)
    }
    /// Slot 1 board type WITH provenance.
    var secondaryBoardReading: BoardTypeReading {
        BoardTypeReading(card: secondaryBoardType, source: secondaryBoardSource,
                         hardwareMajor: secondaryBoardHardwareMajor)
    }

    /// Every user-facing channel count in the app, derived from the two slots.
    ///
    /// Views ask this and nothing else: strip counts, routing columns, mixer
    /// channels, digital pairs, headphone sources and the S/PDIF popups all come
    /// from here, so a card change moves them together. See ``CardLayout`` for
    /// why the `*PairsPerBoard` bus-slice counts must never be used for this.
    ///
    /// `isKnown` is false while neither slot has reported a card — see
    /// `CardLayout.readingsDescribeAUnit`. With a card in one slot, an empty
    /// other slot is knowledge and contributes nothing.
    var cardLayout: CardLayout {
        CardLayout(
            slot1: primaryBoardType,
            slot2: secondaryBoardType,
            // Converters on port 1: no Symphony I/O cards, whatever board
            // types an earlier session cached (they made the converter
            // pages show 32/32 and no routing).
            isKnown: converterSystem?.ports.first?.isEmpty == false ? false
                : CardLayout.readingsDescribeAUnit(slot1: primaryBoardType, slot2: secondaryBoardType),
            fallbackChannelCount: device?.identifier.mode.channelCount ?? 16,
            converter: connectedUnit,
            converters: converterSystem,
            naming: channelNaming)
    }

    /// What channel names follow besides the cards: the sample rate (the status
    /// bar's), each slot's optical format and S/PDIF Coax Replaces setting. The
    /// views that read or write those settings keep this current, so routing,
    /// mixer and strip labels re-label as soon as one changes, the way Apogee's
    /// daemon re-named its channels (`OpticalIn_SymphonyIO_Stream.cpp:70-80, 141-153`).
    var channelNaming = CardLayout.ChannelNaming()

    /// The unit's Peripheral Prefix letter, which software channel names start
    /// with ("A Line 1/2"). Read at connect (`refreshChannelNaming`) and set by
    /// Device Settings, so routing labels follow it without opening that tab.
    var peripheralPrefix = CardLayout.defaultPeripheralPrefix

    // MARK: Per-slot digital settings the Mac owns

    /// UserDefaults key for this card pair's remembered optical format,
    /// Replaces and Mirrors (see `SlotDigitalSettings`). Per card pair, as the
    /// daemon kept them per board.
    var digitalSettingsKey: String? {
        cardLayout.savedStateScope.map { unitPreferenceKey(legacy: "slotDigitalSettings.\($0)", category: "slotDigitalSettings") }
    }

    var rememberedDigitalSettings: SlotDigitalSettings {
        guard let key = digitalSettingsKey else { return SlotDigitalSettings() }
        return SlotDigitalSettings.load(key: key)
    }

    /// Remember a value written to (or confirmed by) the unit, so it is put back
    /// at the next connect.
    @MainActor
    func rememberDigitalSetting(_ selector: AudioPropertySelector, slot: Int, value: UInt32) {
        guard let key = digitalSettingsKey else { return }
        SlotDigitalSettings.remember(selector, slot: slot, value: value, key: key)
    }

    /// Put the remembered optical formats, Replaces and Mirrors back on the
    /// unit, as the daemon did at connect. Both drivers start the optical ports
    /// at ADAT/SMUX and the firmware starts Replaces Off, Mirrors Analog 1-2.
    @MainActor
    func reapplyDigitalSettings() async {
        guard !hardwareWritesSuspended else { return }
        if usesTwoUnitReplay { twoUnitReplayNeeded = true; return }
        guard let device else { return }
        for write in rememberedDigitalSettings.writes(layout: cardLayout) {
            do {
                try await device.setProperty(write.address, value: .uint32(write.value))
            } catch {
                print("[Maestro] reapplyDigitalSettings \(write.address.selector) slot \(write.address.element): \(error)")
            }
        }
    }

    /// Read each slot's optical format and S/PDIF Coax Replaces from the unit
    /// for `channelNaming`. A read that fails leaves the value as it was.
    @MainActor
    func refreshChannelNaming() async {
        guard let device else { return }
        // The prefix is the Symphony I/O's; a converter is not asked for it.
        if connectedUnit == nil,
           let raw = (try? await device.getProperty(PropertyAddress(selector: .prefix)))?.asString {
            peripheralPrefix = CardLayout.peripheralPrefix(raw)
        }
        for slot in 0..<2 {
            let card = cardLayout.card(atSlot: slot)
            if card.hasOpticalPorts {
                let selector: AudioPropertySelector = card.opticalFormatUsesInput ? .opticalInFormat : .opticalOutFormat
                if let raw = (try? await device.getProperty(
                        PropertyAddress(selector: selector, element: UInt32(slot))))?.asUInt32, raw <= 1 {
                    channelNaming.opticalIsSPDIF[slot] = raw == 1
                }
            } else {
                channelNaming.opticalIsSPDIF[slot] = nil
            }
            if card.hasSPDIFCoax,
               let raw = (try? await device.getProperty(
                    PropertyAddress(selector: .spdifReplaceID, scope: .input, element: UInt32(slot))))?.asUInt32,
               raw <= 8 {
                channelNaming.spdifReplace[slot] = raw
            }
        }
    }

    /// "Connection" as shown in Device Info and the copied details: names the
    /// Symphony 64 PCIe card when that is what the driver is attached to.
    /// The short connection name for the sidebar badge and the status bar.
    var connectionShortName: String {
        ConnectionLabel.shortName(
            transport: transportType,
            pciIdentifier: transportType == .thunderbolt
                ? SystemExtensionInstaller.shared.presentThunderBridgePCIIdentifier() : nil)
    }

    var connectionLabel: String {
        ConnectionLabel.text(
            isThunderbolt: transportType == .thunderbolt,
            pciIdentifier: SystemExtensionInstaller.shared.presentThunderBridgePCIIdentifier())
    }

    /// Set when the ThunderBridge driver found something other than a Symphony
    /// I/O on the cable (an older Apogee converter). Nil for a Symphony I/O.
    var connectedUnit: ConnectedUnit? {
        didSet {
            if connectedUnit != oldValue {
                invalidateUnitAIdentity()
                invalidateUnitBIdentity()
                if connectedUnit != nil {
                    unitAIdentityState = .failed
                    unitBIdentityState = .failed
                }
            }
        }
    }
    /// The driver's raw probe word behind `connectedUnit`, for the copied
    /// Device Info. Zero when the driver did not probe.
    var connectedUnitProbeWord: UInt32 = 0
    /// Every converter unit on both ports (selector 9, dext 131+), or port 1
    /// from the probe word with an older driver, or the converter simulation.
    /// Nil for a Symphony I/O. Lays out, names and meters converter channels.
    var converterSystem: ConverterSystem? {
        didSet {
            if converterSystem != oldValue {
                // Converters on port 1 replace any Symphony I/O cards an
                // earlier session cached: the card-type reads do not answer.
                if converterSystem?.ports.first?.isEmpty == false {
                    let defaults = UserDefaults.standard
                    defaults.removeObject(forKey: "cachedPrimaryBoardType")
                    defaults.removeObject(forKey: "cachedSecondaryBoardType")
                    if primaryBoardSource == .cached { primaryBoardType = .none }
                    if secondaryBoardSource == .cached { secondaryBoardType = .none }
                }
                invalidateUnitAIdentity()
                invalidateUnitBIdentity()
                if converterSystem != nil {
                    unitAIdentityState = .failed
                    unitBIdentityState = .failed
                }
                converterSystemChanged()
            }
        }
    }

    var symphonyCardInputNamingRevision = 0
    var symphonyCardInputEdits: [Int: Int] = [:]
    @ObservationIgnored var symphonyCardInputVersion: UInt64 = 0
    @ObservationIgnored var symphonyCardInputTail: Task<Bool, Never>?

    // MARK: Converter routing

    /// The chain the converter routes on screen belong to
    /// (`ConverterSystem.routingSignature`), nil without a converter layout.
    private(set) var converterRoutingSignature: String?
    /// The user's converter routes for that chain (both directions), shared
    /// by the Output and Input Routing pages: Reset Routing (0xB7) clears both.
    var converterRoutingEdits = ConverterRoutingEdits()
    /// The chain whose saved routes were last sent to the driver.
    @ObservationIgnored private var converterRoutingReplayedSignature: String?

    /// Whether the routing pages are the converters' (port 1 carries
    /// converters, identified or not): the Symphony I/O grids must not show,
    /// since their writes would land on converter channels.
    var converterRoutingSurface: Bool {
        connectedUnit != nil || converterSystem?.ports[0].isEmpty == false
    }

    /// The converter channels the routing pages show, nil unless the layout
    /// follows converters.
    /// Nil too with an older driver (converters from the probe word), which
    /// cannot route converters: nothing is shown, sent or replayed then.
    var converterRoutingLayout: ConverterRoutingLayout? {
        guard let system = cardLayout.converterLayout, system.driverSupportsConverterControls else { return nil }
        return ConverterRoutingLayout(system: system)
    }

    /// Kept per chain; the converter simulation keeps its own (`sim:`).
    var converterRoutingStore: ConverterRoutingStore? {
        converterRoutingSignature.map {
            ConverterRoutingStore(signature: Self.converterRoutingStoreSignature($0, simulated: connectionMode == .simulated))
        }
    }

    static func converterRoutingStoreSignature(_ signature: String, simulated: Bool) -> String {
        simulated ? "sim:" + signature : signature
    }

    private func converterSystemChanged() {
        let signature = converterSystem.flatMap { $0.layoutKnown ? $0.routingSignature : nil }
        guard signature != converterRoutingSignature else { return }
        converterRoutingSignature = signature
        converterRoutingEdits = converterRoutingStore?.load() ?? ConverterRoutingEdits()
        // A new chain while connected (32 <-> 64 channels, a Device Type
        // change): the driver has dropped the old chain's routes; put this
        // chain's saved ones on it (the ThunderBridge health loop sends them
        // on its next pass). The connect-time replay covers connects.
        if let signature, let replayed = converterRoutingReplayedSignature, replayed != signature,
           connectionMode == .hardware {
            converterRoutingReplayNeeded = true
        }
    }

    /// Set when the chain changed under a connected session; the health loop
    /// replays this chain's saved routes and clears it.
    @ObservationIgnored var converterRoutingReplayNeeded = false

    /// The last converter routing send. Every send waits for the one before
    /// it, so the card gets commands in the order they were made (two quick
    /// clicks, or a click racing a replay); the card has no readback to
    /// correct a reordered pair.
    @ObservationIgnored private var converterRoutingTail: Task<Bool, Never>?

    /// Send converter routing commands to the driver, in order, each batch
    /// off the main thread. True when every command was accepted (always in
    /// the simulation).
    @MainActor
    func sendConverterRouting(_ commands: [ConverterRouting.Command]) async -> Bool {
        await sendConverterRoutingRefused(commands).isEmpty
    }

    /// The same, returning the commands the driver refused (all of them
    /// without a ThunderBridge, none in the simulation).
    @MainActor
    func sendConverterRoutingRefused(_ commands: [ConverterRouting.Command]) async -> [ConverterRouting.Command] {
        guard !commands.isEmpty else { return [] }
        let previous = converterRoutingTail
        let tb = device as? ThunderboltDeviceConnection
        let simulated = connectionMode == .simulated
        let send = Task<[ConverterRouting.Command], Never> {
            _ = await previous?.value
            guard let tb else { return simulated ? [] : commands }
            let failures = await Task.detached(priority: .userInitiated) { () -> [(ConverterRouting.Command, String)] in
                var failed: [(ConverterRouting.Command, String)] = []
                for command in commands {
                    do { try tb.sendConverterRouting(command) } catch { failed.append((command, "\(command): \(error)")) }
                }
                return failed
            }.value
            if !failures.isEmpty {
                print("[Maestro] Converter routing: \(failures.count) of \(commands.count) command(s) refused: \(failures.map(\.1))")
            }
            return failures.map(\.0)
        }
        converterRoutingTail = Task { await send.value.isEmpty }
        return await send.value
    }

    /// The user changed converter routes. The grid shows them at once (so a
    /// second click on the same cell undoes the first); they are saved for
    /// this chain only once the driver has accepted every command, and put
    /// back as they were if it refused (an older driver, or a Symphony I/O).
    @MainActor
    func changeConverterRouting(_ edits: ConverterRoutingEdits, commands: [ConverterRouting.Command],
                                completion: @escaping @MainActor (Bool) -> Void = { _ in }) {
        let previous = converterRoutingEdits
        let store = converterRoutingStore
        converterRoutingEdits = edits
        Task { @MainActor [weak self] in
            guard let self else { return }
            let refused = await self.sendConverterRoutingRefused(commands)
            if refused.isEmpty {
                store?.save(edits)
            } else {
                // Only the refused routes go back; the accepted ones stay
                // and are saved, and a newer change to the same route stays.
                store?.save(edits.reverting(refused, attempted: edits, previous: previous))
                if self.converterRoutingStore?.key == store?.key {
                    self.converterRoutingEdits = self.converterRoutingEdits.reverting(
                        refused, attempted: edits, previous: previous)
                }
            }
            completion(refused.isEmpty)
        }
    }

    /// Reset Routing for converters: both tables back on the default
    /// placement (0xB7). Nothing stays saved for this chain, once the driver
    /// has accepted it.
    @MainActor
    @discardableResult
    func resetConverterRouting() async -> Bool {
        let store = converterRoutingStore
        guard await sendConverterRouting([ConverterRouting.resetRoutingCommand]) else { return false }
        converterRoutingEdits = ConverterRoutingEdits()
        store?.save(ConverterRoutingEdits())
        return true
    }

    /// Put this chain's saved converter routes on the driver (connect, or a
    /// new chain). The driver keeps them over card resets itself.
    /// `resetFirst` (a chain change while connected) starts from the default
    /// placement, so no route made for the previous chain stays on the card,
    /// whatever the driver kept.
    @MainActor
    func replayConverterRouting(resetFirst: Bool = false) async {
        guard !hardwareWritesSuspended else { return }
        guard let layout = converterRoutingLayout, let signature = converterRoutingSignature else { return }
        converterRoutingReplayedSignature = signature
        converterRoutingReplayNeeded = false
        let edits = converterRoutingStore?.load() ?? ConverterRoutingEdits()
        converterRoutingEdits = edits
        let commands = (resetFirst ? [ConverterRouting.resetRoutingCommand] : []) + layout.replayCommands(edits)
        guard !commands.isEmpty else {
            print("[Maestro] Converter routing: default placement (nothing saved for \(signature))")
            return
        }
        let ok = await sendConverterRouting(commands)
        print("[Maestro] Converter routing: replayed \(commands.count) command(s) for \(signature)"
              + (ok ? "" : " (some refused)"))
    }

    /// The firmware notices already logged for this connection, so each is
    /// said once.
    private var loggedConverterNotices: Set<String> = []

    /// Whether the clock picker offers only the converters' Internal and
    /// External choices: port-1 converters are identified (or simulated).
    var convertersIdentified: Bool { connectedUnit != nil && converterSystem != nil }

    /// Read the driver's converter report again (no bus access) and rebuild
    /// `converterSystem`. With an older driver it is rebuilt from the probe
    /// word and the stored Device Types.
    func refreshConverterSystem() {
        guard connectionMode != .simulated else { return }
        guard let tb = device as? ThunderboltDeviceConnection else {
            if converterSystem != nil { converterSystem = nil }
            return
        }
        let system = Self.converterSystem(state: tb.converterState(), probeWord: connectedUnitProbeWord)
        if system != converterSystem { converterSystem = system }
        if connectedUnit == nil, let unit = system?.connectedUnit { connectedUnit = unit }
        for notice in system?.firmwareNotices ?? [] where !loggedConverterNotices.contains(notice) {
            loggedConverterNotices.insert(notice)
            print("[Maestro] \(notice)")
        }
    }

    /// The driver's converter report when it identifies converters; otherwise
    /// the older probe word (an older driver, or a report taken while the driver
    /// re-identifies the cable). The probe word is 0 once a Symphony I/O
    /// answers, so a Symphony never gets a converter layout from it.
    static func converterSystem(state: ConverterState?, probeWord: UInt32) -> ConverterSystem? {
        // A zero probe is the driver's authoritative indication that port 1
        // answered a Symphony I/O read.  If a stale selector-9 snapshot still
        // carries the old port-1 converter flag from the same transition,
        // prefer the Symphony result so the UI leaves converter mode without
        // requiring a relaunch.  Port-2 converters remain valid because this
        // only rejects the contradictory port-1 flag.
        if probeWord == 0, state?.port1Converters == true {
            return nil
        }
        if let state, state.port1Converters || state.port2Converters,
           let system = ConverterSystem(state: state) {
            return system
        }
        return ConverterSystem.withStoredConfig(simulated: false) {
            ConverterSystem(probeWord: probeWord, config: $0)
        }
    }

    /// At connect: send the stored Device Types and clock choice before the
    /// layout is read, so the first report already has them. With no stored
    /// clock choice the driver's current clock is kept. Older drivers reject
    /// the call and nothing changes.
    nonisolated static func applyStoredConverterConfig(_ tb: ThunderboltDeviceConnection) {
        // Either port: port-2 converters behind a Symphony I/O need their
        // Device Types too.
        guard let state = tb.converterState(), state.port1Converters || state.port2Converters,
              let system = ConverterSystem(state: state) else { return }
        var word = ConverterConfig.load(for: system, simulated: false).word(currentClockExternal: state.clockExternal)
        if !state.port1Converters {
            // A Symphony I/O on port 1 owns the clock: keep the driver's bit
            // (it applies the converter clock only with port-1 converters).
            word = (word & ~ConverterConfig.clockExternalBit)
                | (state.clockExternal ? ConverterConfig.clockExternalBit : 0)
        }
        if word != state.config, !tb.setConverterConfig(word) {
            print("[Maestro] Converter config 0x\(String(word, radix: 16)) was not accepted")
        }
    }

    /// The user chose a converter clock source (bit 0 of the converter
    /// config). Never sent as a Symphony I/O ClockMode.
    @discardableResult
    func setConverterClock(external: Bool) -> Bool {
        if let system = converterSystem {
            ConverterConfig.saveClockExternal(external, for: system, simulated: connectionMode == .simulated)
        }
        return sendConverterConfig()
    }

    /// The user chose a Device Type for a unit whose routing does not say
    /// what it is (0x0F or 0x05).
    func setConverterDeviceType(_ type: ConverterDeviceType, port: Int, address: Int) {
        guard let system = converterSystem,
              let unit = (system.ports[0] + system.ports[1]).first(where: { $0.port == port && $0.address == address })
        else { return }
        let simulated = connectionMode == .simulated
        ConverterConfig.saveDeviceType(type, unit: unit, simulated: simulated)
        if simulated {
            // Rebuild the simulated units with the new choice.
            let name = UserDefaults.standard.string(forKey: ConnectedUnit.simulationKey) ?? ""
            converterSystem = ConverterSystem.withStoredConfig(simulated: true) {
                ConverterSystem(simulationName: name, config: $0)
            } ?? system
            return
        }
        sendConverterConfig()
    }

    @discardableResult
    private func sendConverterConfig() -> Bool {
        guard let tb = device as? ThunderboltDeviceConnection else { return connectionMode == .simulated }
        guard let system = converterSystem else { return false }
        let current = system.clockExternal
        let ok = tb.setConverterConfig(
            ConverterConfig.load(for: system, simulated: false).word(currentClockExternal: current))
        refreshConverterSystem()
        return ok
    }
    /// The update channel in effect (mirrored from UpdateController), for the
    /// copied software report.
    var updateChannel: UpdateChannel?
    /// Converters only on the cable (no Symphony I/O): the driver sends the
    /// volume and mute keys to mixer 1, and the speaker and headphone controls
    /// have nothing to control. Also true in the converter simulation.
    var converterVolumeKeys: Bool {
        ConnectedUnit.driverRoutesVolumeKeysToMixer(connectedUnitProbeWord)
            || (connectionMode == .simulated && connectedUnit != nil)
    }

    /// EXPERIMENT (64 channels): the driver's port-2 findings, and only when the
    /// driver reports the two-port experiment on. Nil with every released
    /// driver, with the experiment off, over USB and in simulation, so nothing
    /// is shown or copied in those cases.
    var secondPortState: SecondPortState?

    /// EXPERIMENT (64 channels, stage 2): the port selection (32 or 64
    /// channels) as the Core Audio device reports it. Empty (nothing
    /// shown) unless a two-port driver publishes the selector.
    var portSelection = PortSelectionModel()
    private var portSelectionTask: Task<Void, Never>?

    // MARK: Unit B (a second Symphony I/O on port 2, while 64 channels run)
    // See AppState+UnitB.swift. All nil / empty with one unit, so nothing
    // about unit A changes then.

    /// Selector 13: requested topology, application validity and measured locks.
    var loopSyncState: LoopSyncState?
    var loopSyncNeedsRestore = false
    var loopSyncBusy = false
    var loopSyncError: String?
    /// What the driver reports about unit B (selector 11), nil unless it is
    /// configured, which it is only while 64 channels run.
    var unitB: SecondUnitInfo?
    @ObservationIgnored var twoUnitReplayNeeded = false
    @ObservationIgnored var twoUnitReplayRunning = false
    enum HardwareSleepState { case awake, sleeping, validating }
    var hardwareSleepState: HardwareSleepState = .awake {
        // The wake generation advances before sleep, which can last well past the overlay delay.
        didSet { if hardwareSleepState == .validating && oldValue != .validating { suppressMacVolumeOverlay() } }
    }
    var hardwareWritesSuspended: Bool { hardwareSleepState != .awake }
    /// Why hardware edits are unavailable right now, or nil when they are. The
    /// status bar and the note over the device pages show the same words.
    var hardwareSuspendedNote: String? {
        switch hardwareSleepState {
        case .validating: "Validating hardware after wake…"
        case .sleeping: "Hardware sleeping"
        case .awake: nil
        }
    }
    var twoUnitSleeping: Bool { hardwareWritesSuspended }
    @ObservationIgnored var wakeReconnectTask: Task<Void, Never>?
    @ObservationIgnored var wakeFallbackTask: Task<Void, Never>?
    @ObservationIgnored var reconnectRequestedWhileSuspended = false
    @ObservationIgnored var wakeRetryInterval: Duration = .seconds(2)
    @ObservationIgnored var wakeRetryLimit = 30
    @ObservationIgnored var wakeReadTimeout: Duration = .seconds(2)
    @ObservationIgnored var wakeFallbackDelay: Duration = .seconds(10)
    /// No sleep observed this long after willSleep: treat it as an aborted sleep.
    @ObservationIgnored var wakeFallbackAbortLimit: Duration = .seconds(120)
    @ObservationIgnored var wakeFallbackFired = false
    @ObservationIgnored var cardDiscoverySkippedDuringSleep = false
    @ObservationIgnored private var sleepWakeObservers: [NSObjectProtocol] = []
    // Injectable boundaries let tests exercise the real orchestration without hardware.
    @ObservationIgnored var launchDiscoveryOperation: (@MainActor () async -> [CoreAudioDeviceConnection.DiscoveredSymphonyIO])?
    @ObservationIgnored var reconnectOperation: (@MainActor () async -> Void)?
    @ObservationIgnored var wakeLinkProbe: (@Sendable (ThunderboltDeviceConnection) async -> LinkState?)?
    @ObservationIgnored var wakeValidationGeneration = 0 {
        didSet { if wakeValidationGeneration != oldValue { suppressMacVolumeOverlay() } }
    }
    @ObservationIgnored var wakeBaselineWatchTicks: UInt32?
    @ObservationIgnored var wakeBaselineRecoveryCount: UInt32?
    @ObservationIgnored var wakeStableRecoveryCount: UInt32?
    @ObservationIgnored var wakeStableProbeCount = 0
    @ObservationIgnored var wakeDownProbeCount = 0
    @ObservationIgnored var inputRoutingReplayNeeded = false
    @ObservationIgnored var replayDeferral = ReplayDeferral()

    var recallInFlight: Bool { replayDeferral.isInFlight() }

    @MainActor
    func beginRecall() { replayDeferral.beginRecall() }

    @MainActor
    func finishRecall() {
        // An epoch-invalidated two-unit replay re-arms itself when it throws;
        // only a replay that was deferred during the recall is requested here.
        guard replayDeferral.finishRecall() else { return }
        if usesTwoUnitReplay {
            twoUnitReplayNeeded = true
        } else {
            inputRoutingReplayNeeded = true
        }
    }
    /// Unit B's connection: unit A's driver client with port byte 1.
    var unitBDevice: (any DeviceConnection)? {
        willSet {
            if unitBDevice !== newValue {
                identifyB.reset()
                invalidateUnitBIdentity()
            }
        }
    }
    /// The unit the per-unit pages show. Only `.b` while the picker is shown.
    var selectedUnit: DeviceUnit = .a
    /// The unit whose monitor receives Mac volume keys. Unit A is the default;
    /// the picker is only shown for two configured Symphony I/Os at 64 channels.
    var monitorDevice: DeviceUnit = .a
    @ObservationIgnored private var monitorSelectionTask: Task<Void, Never>?
    /// Bumped when a unit's Volume Keys › Audio Output choice changes, so the
    /// pop-up follows (the choice itself lives in the unit's settings store).
    var keyboardVolumeRevision = 0
    /// Unit B's speaker mode, for the name of its Speaker entry; nil until read.
    var unitBSpeakerOutputMode: UInt32?
    /// A choice made while the unit's identity, which its saved settings
    /// hang on, was still being read. Saved once the identity is known
    /// (`flushPendingKeyboardVolumeChoices`); until then the store is a
    /// temporary one that the identity's own replaces.
    @ObservationIgnored var keyboardVolumePending: [DeviceUnit: UInt32] = [:]
    /// The Audio Output that setting Line replaced with Headphone 1, per
    /// unit, until the user leaves Line or picks an Audio Output themselves.
    @ObservationIgnored var keyboardVolumeDisplacedByLine: [DeviceUnit: KeyboardVolumeOutput] = [:]
    /// The USB helper's version, with the connection and helper epoch it was
    /// read for; nil until read.
    var usbHelperVersion: UInt64?
    @ObservationIgnored var usbHelperVersionKey: (connection: ObjectIdentifier, epoch: UInt64)?
    /// The choices while no hardware is connected (simulation): not saved.
    @ObservationIgnored var keyboardVolumeSimulated: [DeviceUnit: UInt32] = [:]
    /// What has reached the driver or the helper (`serviceKeyboardVolumeOutput`).
    @ObservationIgnored var keyboardVolumeSent: KeyboardVolumeSent?
    @ObservationIgnored var keyboardVolumeRetryAfter = Date.distantPast
    @ObservationIgnored var keyboardVolumeServiceRunning = false
    /// Bumped when the VBus choice changes, so the pop-up follows (the choice
    /// itself is saved per card, `VBusChannels.saved`).
    var vbusRevision = 0
    /// The VBus size was changed in the pop-up since Maestro opened (not
    /// saved): the note about open applications is shown from then on.
    var vbusChangedThisSession = false
    /// The driver's last VBus report; nil until read, and over USB.
    var vbusState: VBusState?
    /// What has reached the driver (`serviceVBus`).
    @ObservationIgnored var vbusSent: VBusSent?
    @ObservationIgnored var vbusRetryAfter = Date.distantPast
    /// When the size was last sent (`serviceVBus` sends it again a pause later
    /// if the device still does not have it).
    @ObservationIgnored var vbusSentAt = Date.distantPast
    /// How often the size was sent again by itself (`vbusMaxRetries`); the
    /// status line under the pop-up follows it.
    var vbusRetries = 0
    @ObservationIgnored var vbusServiceRunning = false
    /// Where the VBus choice is saved (the app's preferences; tests give their own).
    @ObservationIgnored var vbusDefaults: UserDefaults = .standard
    @ObservationIgnored private var monitorSelectionGeneration = 0
    /// Unit B's naming state (its optical formats and Replaces).
    var unitBChannelNaming = CardLayout.ChannelNaming()
    /// Unit B's prefix letter, as its channels are named.
    var unitBPeripheralPrefix = "B"
    /// Unit B's meters: its input strips (card words 32-63, in its layout's
    /// mixer order), digital input strips, and outputs (words 96-127).
    var unitBInputMeterLevels: [Double] = []
    var unitBInputPeakHold: [Double] = []
    var unitBDigitalInputMeterLevels: [Double] = Array(repeating: -60.0, count: CardLayout.digitalMeterSlots)
    var unitBDigitalInputPeakHold: [Double] = Array(repeating: -60.0, count: CardLayout.digitalMeterSlots)
    var unitBOutputMeterLevels: [Double] = []
    var unitBOutputPeakHold: [Double] = []
    var unitBDigitalOutputMeterLevels: [Double] = Array(repeating: -60.0, count: CardLayout.digitalMeterSlots)
    var unitBDigitalOutputPeakHold: [Double] = Array(repeating: -60.0, count: CardLayout.digitalMeterSlots)
    /// Debug only: `-MaestroSimulateSecondUnit` (see `SecondUnitSimulation`).
    @ObservationIgnored var simulatedUnitB: SecondUnitInfo?
    /// The unit A connection unit B's connection was made from.
    @ObservationIgnored var unitBOwner: ObjectIdentifier?

    /// Ask the driver again. It costs no bus access, and a chain switched on
    /// after the Mac is only found by the driver's later probe.
    func refreshSecondPortState() {
        let shown = currentSecondPortState()
        if shown != secondPortState { secondPortState = shown }
        refreshUnitB()
        if let tb = device as? ThunderboltDeviceConnection,
           let selection = portSelection.selection,
           selection == .ports1And2,
           unitB?.setupComplete == true {
            let saved = MonitorDeviceSelectionStore.load(productID: tb.identifier.productID)
            if monitorSelectionTask == nil { requestMonitorDevice(saved, persist: false) }
        } else if monitorDevice != .a || monitorSelectionTask != nil {
            monitorDevice = .a
            requestMonitorDevice(.a, persist: false)
        }
        // The converter report follows 32/64 channels too (port 2 counts only
        // while 64 run), and costs no bus access either.
        refreshConverterSystem()
    }

    /// Follow the device's port selector for as long as this device is
    /// connected: a change made in Audio MIDI Setup, in Sound settings, here, or
    /// by the driver itself all arrive through the same Core Audio listener.
    /// Does nothing unless the driver reports the two-port experiment on.
    @MainActor
    func startPortSelectionObservation() {
        portSelectionTask?.cancel()
        portSelectionTask = nil
        guard let connection = device as? ThunderboltDeviceConnection,
              currentSecondPortState() != nil,
              connection.portSelectionID() != nil else {
            if portSelection != PortSelectionModel() { portSelection = PortSelectionModel() }
            return
        }
        portSelectionTask = Task { @MainActor [weak self] in
            do {
                let observation = try connection.observePortSelection()
                defer { observation.stop() }
                for await id in observation.selections {
                    guard !Task.isCancelled, let self else { return }
                    self.applyPortSelection(id: id)
                    // The driver performs the switch a moment after the selector
                    // changes; its verdict (running, or refused and why) is
                    // ready shortly afterwards.
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    self.applyPortSelection(id: connection.portSelectionID())
                }
            } catch {
                print("[Maestro] Port selection observation failed: \(error)")
            }
        }
    }

    @MainActor
    func stopPortSelectionObservation() {
        portSelectionTask?.cancel()
        portSelectionTask = nil
        if portSelection != PortSelectionModel() { portSelection = PortSelectionModel() }
    }

    @MainActor
    private func applyPortSelection(id: UInt32?) {
        let was64 = portSelection.selection?.channelCount == 64
        let shown = currentSecondPortState()
        if shown != secondPortState { secondPortState = shown }
        var model = portSelection
        model.deviceReported(dataSourceID: id, state: secondPortState,
                             card: PortStatusMessage.cardPhrase(
                                pciIdentifier: SystemExtensionInstaller.shared.presentThunderBridgePCIIdentifier()))
        if model != portSelection {
            if model.selection != portSelection.selection {
                twoUnitReplayNeeded = model.selection == .ports1And2
                (unitBDevice as? ThunderboltUnitBConnection)?.invalidate()
                applyUnitB(nil, from: nil, confirmedAbsent: model.selection == .port1)
            }
            portSelection = model
            print("[Maestro] Port selection: \(model.selection?.name ?? "none")"
                  + (model.notice.map { " (\($0))" } ?? ""))
        }
        if was64, model.selection?.channelCount != 64 {
            // No card mixer replay here (D5 runs only on a fresh driver). The
            // driver keeps both mixers across 64 -> 32: DisablePort2Audio,
            // Port2AudioFallBack and LeaveTwoUnit leave mixer[2] and
            // mixerStateValid alone (LeaveTwoUnit resets only a Software Return
            // source above 7, as this app's display does), and the coefficient
            // table is cleared only at Start and card re-init
            // (SymphonyThunderbridge.cpp, step 21d and ReprogramCardAfterReset).
            // Known driver gap: a unit-B strip soloed at 64 keeps unit A's
            // inputs muted until the next mixer command recomputes at 32.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.portSelection.selection?.channelCount == 32 else { return }
                await self.replaySymphonyCardInputs()
            }
        }
        refreshSecondPortState()
    }

    /// The user picked an entry in Maestro: write it to the device, the way
    /// Audio MIDI Setup does. What is shown changes when the device reports it.
    @MainActor
    func choosePortSelection(_ choice: PortSelection) {
        guard let connection = device as? ThunderboltDeviceConnection else { return }
        var model = portSelection
        guard model.userChose(choice) != nil else { return }
        portSelection = model
        do {
            try connection.setPortSelection(choice)
        } catch {
            print("[Maestro] Port selection write failed: \(error)")
            model.writeFailed()
            portSelection = model
            return
        }
        // If the device never answers, do not leave the picker disabled.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self else { return }
            self.applyPortSelection(id: connection.portSelectionID())
            if self.portSelection.pending != nil {
                var expired = self.portSelection
                expired.requestExpired()
                self.portSelection = expired
            }
        }
    }

    @MainActor
    func chooseMonitorDevice(_ unit: DeviceUnit) {
        requestMonitorDevice(unit, persist: true)
    }

    private func requestMonitorDevice(_ unit: DeviceUnit, persist: Bool) {
        guard SymphonyExtendedSelectors.supported(by: servingDextBuild) else { return }
        guard unit == .a || (unitB?.setupComplete == true &&
                             portSelection.selection == .ports1And2),
              let tb = device as? ThunderboltDeviceConnection else { return }
        monitorSelectionGeneration += 1
        let generation = monitorSelectionGeneration
        let previous = monitorSelectionTask
        let bDevice = unitBDevice
        // AppState lives on the main actor in practice (same pattern as the
        // Loop Sync restore); the task below runs there.
        nonisolated(unsafe) weak var weakSelf = self
        monitorSelectionTask = Task { @MainActor in
            // Preserve request order even if a previous off-main transaction is
            // already in the driver. Stale completions never publish app state.
            await previous?.value
            guard let self = weakSelf, generation == self.monitorSelectionGeneration else { return }
            defer { if generation == self.monitorSelectionGeneration { self.monitorSelectionTask = nil } }
            guard self.device === tb, self.unitBDevice === bDevice,
                  SymphonyExtendedSelectors.supported(by: self.servingDextBuild) else { return }
            let accepted = await tb.setMonitorDevice(unit)
            guard accepted, generation == self.monitorSelectionGeneration,
                  self.device === tb, self.unitBDevice === bDevice,
                  unit == .a || (self.unitB?.setupComplete == true &&
                                  self.portSelection.selection == .ports1And2) else { return }
            self.monitorDevice = unit
            if persist { MonitorDeviceSelectionStore.save(unit, productID: tb.identifier.productID) }
        }
    }

    /// The driver's answer right now, without storing it. Nil unless the
    /// driver reports the experiment on.
    func currentSecondPortState() -> SecondPortState? {
        let state = (device as? ThunderboltDeviceConnection)?.secondPortState()
        return state?.experimentOn == true ? state : nil
    }

    /// Changes whenever the installed cards change, so a view can rebuild its
    /// strip arrays. `initializeChannels()` runs from `.task` before the async
    /// `readCardTypes()` has answered, and `ForEach(0..<min(channels.count, n))`
    /// then pins the pre-detection count permanently.
    var cardLayoutToken: Int {
        Int(primaryBoardType.rawValue) << 8 | Int(secondaryBoardType.rawValue)
            | (connectedUnit?.channels.map { ($0.inputs + 1) << 24 | ($0.outputs + 1) << 16 } ?? 0)
            ^ (converterSystem.map { $0.layoutToken << 32 } ?? 0)
            ^ unitBLayoutToken
    }

    /// Load cached board types from UserDefaults (called at init, before USB reads).
    ///
    /// Everything restored here is marked `.cached` - a restore is not a
    /// measurement, and `readCardTypes()` upgrades a slot to `.detected` only when
    /// a live read actually succeeds.
    func loadCachedBoardTypes() {
        let defaults = UserDefaults.standard
        // Earlier versions cached "both slots empty" whenever the card-type read
        // went unanswered. That pair is not a reading of anything; restoring it
        // would label two failed reads as cached knowledge.
        let cachedPair = (defaults.object(forKey: "cachedPrimaryBoardType") as? Int,
                          defaults.object(forKey: "cachedSecondaryBoardType") as? Int)
        if (cachedPair.0 ?? 0) == 0, (cachedPair.1 ?? 0) == 0 { return }
        if let raw = defaults.object(forKey: "cachedPrimaryBoardType") as? Int,
           raw >= 0, raw <= Int(UInt8.max),
           let card = IOCardType(rawValue: UInt8(raw)) {
            primaryBoardType = card
            primaryBoardSource = .cached
        }
        if let raw = defaults.object(forKey: "cachedSecondaryBoardType") as? Int,
           raw >= 0, raw <= Int(UInt8.max),
           let card = IOCardType(rawValue: UInt8(raw)) {
            secondaryBoardType = card
            secondaryBoardSource = .cached
        }
    }

    /// Persist detected board types to UserDefaults.
    private func saveBoardTypeCache() {
        // Nothing to remember when no card was reported: writing 0/0 here is how
        // a unit that never answered ended up "known" to have no cards.
        guard CardLayout.readingsDescribeAUnit(
            slot1: primaryBoardType, slot2: secondaryBoardType) else { return }
        let defaults = UserDefaults.standard
        defaults.set(Int(primaryBoardType.rawValue), forKey: "cachedPrimaryBoardType")
        defaults.set(Int(secondaryBoardType.rawValue), forKey: "cachedSecondaryBoardType")
    }

    // MARK: - Live Meters (P3F-30)

    /// Real-time meter levels for input channels (dBFS, -60..0).
    var inputMeterLevels: [Double] = []
    /// Real-time meter levels for output channels (dBFS, -60..0).
    var outputMeterLevels: [Double] = []
    /// Displayed input peak marks.
    var inputPeakHold: [Double] = []
    /// Displayed output peak marks.
    var outputPeakHold: [Double] = []
    /// Digital input levels in board order.
    var digitalInputMeterLevels: [Double] = Array(repeating: -60.0, count: CardLayout.digitalMeterSlots)
    /// Peak hold for digital input meters.
    var digitalInputPeakHold: [Double] = Array(repeating: -60.0, count: CardLayout.digitalMeterSlots)
    /// Digital output levels in board order.
    var digitalOutputMeterLevels: [Double] = Array(repeating: -60.0, count: CardLayout.digitalMeterSlots)
    /// Peak hold for digital output meters.
    var digitalOutputPeakHold: [Double] = Array(repeating: -60.0, count: CardLayout.digitalMeterSlots)
    /// Mixer TDM meter levels — 8 values from hardware (TDM group 2):
    ///   [0..1] = Mixer 0 SW Return L/R, [2..3] = Mixer 1 SW Return L/R,
    ///   [4..5] = Mixer 0 Master L/R,    [6..7] = Mixer 1 Master L/R.
    /// Evidence: SymphonyIO.cpp:7029-7052, SymphonyIOMixer.h:18-20.
    var mixerMeterLevels: [Double] = Array(repeating: -60.0, count: 8)
    var mixerPeakHold: [Double] = Array(repeating: -60, count: 8)
    var meterOvers: [DisplayMeterBank: Set<Int>] = [:]
    @ObservationIgnored var meterHolds: [DisplayMeterBank: [MeterHold]] = [:]

    /// Meter polling task handle.
    var meterPollingTask: Task<Void, Never>?
    /// Whether TDM hardware metering via XPC is available (set false on first failure).
    private var tdmMeteringAvailable: Bool = true
    /// Latched per connection once the output-group TDM payload has been proven
    /// to be XMOS EP0 stack residue -- the request's own USB setup packet echoed
    /// back at bytes 32-39 -- on 3 consecutive reads. From then on groups 1 and 2
    /// are not requested (they share the firmware path) and output meters are
    /// modelled in software from the proxy's per-channel playback peaks.
    /// Measured on hardware 2026-09-10; see MaestroCore.TDMMeterPayload.
    private(set) var tdmOutputMeteringUnavailable: Bool = false
    private var tdmOutputEchoStreak: Int = 0
    /// The first output-group reply of a USB connection is logged once, so a
    /// diagnostics report shows whether the unit sends real output meters.
    private var tdmOutputReplyLogged = false
    /// Over USB the unit has answered the mixer meter group with real levels
    /// on this connection (measured 2026-11-21 on a Symphony I/O: words 0-3
    /// are each mixer's Software Return before its fader, words 4-7 each
    /// mixer's Master). From then on the Mixer page's Software Return and
    /// Master meters are the unit's, as in the original, and the helper's
    /// playback peaks and the worked-out Master level are not laid over them.
    private var usbUnitMixerMetersSeen = false
    /// Meter routing state requested on the previous poll (true = Output).
    /// A change means the firmware's next reply is its zeroed/phantom buffer
    /// (SymphonyIOMeterManager.cpp:159-163, :204-207) and must be discarded.
    private var lastMeterPollWantedOutput: Bool? = nil
    /// Cached output routes (destination byte -> source byte) for the software
    /// output meter model; re-read from RoutingStateCache every ~2 s.
    private var softwareOutputRoutes: [UInt8: UInt8] = [:]
    private var softwareOutputRoutesPollStamp: Int = -1
    /// ThunderBridge: the meter word (host input) each input strip reads,
    /// from the unit's capture table (`ThunderboltInputMeterMap`); re-derived
    /// every ~2 s so card detection and Input Routing changes are followed.
    private var thunderboltInputMeterWords = ThunderboltInputMeterMap.Words(channels: [], digital: [])
    private var thunderboltInputMeterWordsPollStamp: Int = -1
    private var thunderboltInputMeterLayout: CardLayout?
    @ObservationIgnored var thunderboltCaptureRoutesCache: [DeviceUnit: (key: ThunderboltCaptureRoutesKey, routes: [ThunderboltInputMeterMap.Route])] = [:]
    @ObservationIgnored var thunderboltInputRoutingWritten = false
    /// ThunderBridge: the meter word each analog and digital output strip
    /// reads, from the output table (`ThunderboltOutputMeterMap`); nil while
    /// the cards or the table are not known, and for converters. Re-derived
    /// every ~2 s, and at once when Output Routing is saved.
    private var thunderboltOutputMeterWords: ThunderboltOutputMeterMap.Words?
    @ObservationIgnored var unitBOutputMeterWords: ThunderboltOutputMeterMap.Words?
    @ObservationIgnored var unitBOutputMeterLayout: CardLayout?
    @ObservationIgnored var unitBOutputMeterWordsPollStamp: Int = -1
    /// ThunderBridge: the Symphony's own output meters, read from the unit
    /// while the Output page shows (`UnitOutputMeters`), and when they were
    /// read. The card's snapshot through the routing map is the fallback.
    private var symphonyOutputMeterLevels: UnitOutputMeters.Levels?
    private var unitOutputMeterStamp = Date.distantPast
    private var unitOutputMeterReadInFlight = false
    private var unitOutputMeterFailures: [DeviceUnit: Int] = [.a: 0, .b: 0]
    private var unitOutputMeterRetryAfter: [DeviceUnit: Date] = [.a: .distantPast, .b: .distantPast]
    private var unitOutputMeterLastStart: [DeviceUnit: Date] = [:]
    private var unitOutputMeterLastEnd: [DeviceUnit: Date] = [:]
    private var unitOutputMeterContext: (DeviceUnit, CardLayout, ObjectIdentifier)?
    private var unitOutputMeterLevelsByUnit: [DeviceUnit: UnitOutputMeters.Levels] = [:]
    private var unitOutputMeterWindowStart = Date()
    private var unitOutputMeterWindowDurations: [TimeInterval] = []
    private var thunderboltOutputMeterWordsPollStamp: Int = -1
    private var thunderboltOutputMeterLayout: CardLayout?
    /// Count of consecutive all-zero TDM reads. Used to detect when signal stops
    /// and begin decaying held meter values (firmware returns zeros when idle too).
    private var tdmZeroReadCount: Int = 0

    // MARK: - ASP Volume Sync

    /// Exact CoreAudio name of the USB AudioServerPlugin device. Single source of truth so a
    /// rename in ApogeeDriver.cpp (dp.Name) only needs updating here. Must match that value.
    static let aspUSBDeviceName = "Symphony I/O : Maestro USB"

    /// AudioDeviceID of the ASP "Symphony I/O : Maestro USB" virtual device.
    /// Used to listen for volume/mute changes from media keys.
    private var aspDeviceID: AudioDeviceID = kAudioObjectUnknown {
        didSet { if aspDeviceID != oldValue { lastMacMonitorWrite = nil } }
    }
    private var lastMacMonitorWrite: ObservedMonitorLevel?
    private var macVolumeOverlayAfter = ContinuousClock.now + .seconds(3)

    private func suppressMacVolumeOverlay() {
        macVolumeOverlayAfter = ContinuousClock.now + .seconds(3)
    }
    private var micPreDAWListenerAddresses: [AudioObjectPropertyAddress] = []
    private var micPreDAWRefreshTask: Task<Void, Never>?
    private var micPreDAWRefreshGate = MicPreDAWRefreshGate()
    var micPreObservationRevision = 0
    /// Timestamp of last ASP write from this app. Used to suppress feedback
    /// loops when our own writes trigger the listener callback.
    private var aspWriteTimestamp: Date = .distantPast

    /// Until this passes, report the clock as locked regardless of what the
    /// hardware says.
    ///
    /// A sample-rate change genuinely unlocks the PLL for a moment while it
    /// re-acquires; showing a red "Unlocked" for that moment is noise, not
    /// information, and it looks like the rate change broke something. Apogee's
    /// own daemon did exactly this -- "Force state to locked so we don't report
    /// unlock from rate change", suppressed for 5 seconds
    /// (og_source/maestrolink/Software/SymphonyIO.cpp:6558-6573) -- so the window
    /// below is theirs, not a guess.
    var clockLockSuppressedUntil: Date = .distantPast

    /// True while a just-requested rate change is still settling.
    var clockLockSuppressed: Bool { Date() < clockLockSuppressedUntil }

    /// Call right after changing the sample rate.
    func suppressClockLockReporting() {
        clockLockSuppressedUntil = Date().addingTimeInterval(5)
    }

    // MARK: - Auto-switch to Symphony on connect

    /// Symphony device IDs present at the last device-list check. Used for rising-edge detection
    /// so we only auto-switch when a Symphony *newly appears* (a plug-in), never on unrelated
    /// device-list changes or while it stays connected — that would fight a deliberate user choice.
    private var knownSymphonyDeviceIDs: Set<AudioDeviceID> = []
    /// The CoreAudio device ID currently backing the app's active hardware connection.
    /// Used to invalidate the UI immediately when that device disappears.
    private var activeAudioDeviceID: AudioDeviceID?
    /// Last default-output ID observed by the device-list listener. Capturing
    /// this before CoreAudio finishes its removal fallback lets us distinguish
    /// "Symphony was the default and vanished" from an unrelated device event.
    private var knownDefaultOutputDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var deviceListenerInstalled = false

    /// Install the system device-list listener that powers auto-switch-on-connect. Idempotent.
    @MainActor
    func installHardwareDeviceListener() {
        guard !deviceListenerInstalled else { return }
        // Card simulation: a plug-in must not swap the simulated unit for hardware.
        guard cardSimulation == nil else { return }
        deviceListenerInstalled = true
        // Seed the known set so the currently-present device isn't treated as "newly appeared"
        // at launch — we only hijack the default output on an actual plug-in event.
        knownSymphonyDeviceIDs = Set((lastLaunchDiscovered ?? CoreAudioDeviceConnection.discoverAllSymphonyIO())
                                         .map { $0.audioDeviceID })
        knownDefaultOutputDeviceID = CoreAudioDeviceConnection.currentDefaultOutputDevice()
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject), &addr,
            hardwareDevicesChanged, Unmanaged.passUnretained(self).toOpaque()
        )
    }

    /// When a Symphony audio device last appeared in the system device list.
    /// See `waitForUSBUnitToSettle()`.
    private var symphonyAppearedAt: Date?
    /// The active unit went away and has not been seen since. The reconnect loop
    /// can find the returning unit by polling before the device-list callback
    /// has stamped `symphonyAppearedAt`, so it stamps it itself.
    var awaitingSymphonyReturn = false

    /// How long after its audio device appears a USB unit is left alone.
    static let usbSettleInterval: TimeInterval = 3.0
    /// How long a Symphony that has just come back over ThunderBridge is left
    /// alone before Maestro writes to it.
    static let thunderboltSettleInterval: Duration = .seconds(2)

    /// Whether a USB recovery should restore Software Return and Master now:
    /// only the 5 s debounce.
    nonisolated static func usbRecoveryRestoreDue(lastRecovery: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastRecovery) > 5.0
    }

    /// Seconds still to wait before a unit that appeared at `appearedAt` may be
    /// written to. Zero for a unit that has been up for a while (launch, Rescan).
    /// How much of the USB settle interval is left for the unit connected now.
    var usbSettleRemainingNow: TimeInterval {
        Self.usbSettleRemaining(appearedAt: symphonyAppearedAt, now: Date())
    }

    nonisolated static func usbSettleRemaining(appearedAt: Date?, now: Date) -> TimeInterval {
        guard let appearedAt else { return 0 }
        let elapsed = now.timeIntervalSince(appearedAt)
        guard elapsed >= 0 else { return 0 }
        return max(0, usbSettleInterval - elapsed)
    }

    /// Hold the app's own reconnect traffic until a freshly powered-up USB unit
    /// has finished starting.
    ///
    /// A power-cycled Symphony reappears, the helper configures it and starts
    /// the audio stream about half a second later, and this app used to follow
    /// within a second of that with 64 mixer writes, its routing table and a
    /// burst of reads from every open view, then meter polling. On 2026-11-13
    /// some of those reconnects were followed by digital clicking that only a
    /// USB replug cleared; reconnects with Maestro closed, where none of this is
    /// sent, were all clean. The cause is not proven, but nothing the app sends
    /// here is urgent: the helper has already muted the hardware inputs and set
    /// the routing it needs for playback.
    @MainActor
    private func waitForUSBUnitToSettle() async {
        if awaitingSymphonyReturn, symphonyAppearedAt == nil { symphonyAppearedAt = Date() }
        let remaining = Self.usbSettleRemaining(appearedAt: symphonyAppearedAt, now: Date())
        awaitingSymphonyReturn = false
        guard remaining > 0 else { return }
        print("[Maestro] reconnect: unit appeared \(String(format: "%.1f", Self.usbSettleInterval - remaining)) s ago — waiting \(String(format: "%.1f", remaining)) s before sending anything")
        statusMessage = "Waiting for the Symphony to finish starting…"
        try? await Task.sleep(for: .milliseconds(Int(remaining * 1000)))
    }

    /// Called on any audio-device-list change. If a Symphony device NEWLY appeared, reconnect the
    /// app to it and (if the preference is on) make it the macOS default output.
    @MainActor
    func handleHardwareDeviceListChanged() {
        let discovered = CoreAudioDeviceConnection.discoverAllSymphonyIO()
        let currentIDs = Set(discovered.map { $0.audioDeviceID })
        let previousDefaultOutput = knownDefaultOutputDeviceID == kAudioObjectUnknown
            ? CoreAudioDeviceConnection.currentDefaultOutputDevice()
            : knownDefaultOutputDeviceID
        let removedSymphonyIDs = knownSymphonyDeviceIDs.subtracting(currentIDs)
        let newlyAppeared = !currentIDs.subtracting(knownSymphonyDeviceIDs).isEmpty
        if newlyAppeared { symphonyAppearedAt = Date() }
        // coreaudiod restart signature: EVERY previously-known Symphony ID vanished (all IDs were
        // reassigned), vs a real plug-in where existing devices keep their IDs. On a restart we must
        // still reconnect (grab the new IDs) but must NOT hijack the default output — that would
        // silently revert a deliberate user output choice on a crash/deploy/screen-share restart.
        let looksLikeCoreAudioRestart = !knownSymphonyDeviceIDs.isEmpty
            && knownSymphonyDeviceIDs.isDisjoint(with: currentIDs)
        let newlyAppearedIDs = currentIDs.subtracting(knownSymphonyDeviceIDs)
        knownSymphonyDeviceIDs = currentIDs

        // A removal notification is the authoritative disconnect signal. Previously we only
        // handled the rising edge (newly appeared), so unplugging ThunderBridge left the UI
        // claiming "Connected" until the user pressed Rescan. Invalidate the visible state now;
        // reconnectHardware() still performs the normal short retry loop for a quick re-enumeration.
        // Honor the removal while the Symphony endpoint is merely marked
        // disconnected too (power-off with the cable in): otherwise pulling the
        // ThunderBridge cable in that state left the transport badge up and the
        // health loop probing a client whose provider was gone.
        if let activeAudioDeviceID,
           removedSymphonyIDs.contains(activeAudioDeviceID),
           connectionMode == .hardware || (connectionMode == .disconnected && transportPresent) {
            print("[Maestro] Active Symphony audio device (activeAudioDeviceID) disappeared")
            // Whatever comes back next is a unit that has just started.
            symphonyAppearedAt = nil
            awaitingSymphonyReturn = true
            Self.tbLog.notice("audio device removed while \(String(describing: self.connectionMode), privacy: .public) — transport gone, reconnect retry starts")
            stopThunderboltHealthCheck()
            statusMessage = "Disconnected"
            connectionMode = .disconnected
            transportType = nil
            transportPresent = false
            isHardwareInitialized = false
            invalidateUnitAIdentity()
            invalidateUnitBIdentity()
            unitBIdentityAttempted = false
            viewReloadToken = UUID()
            Task { await reconnectHardware() }
        }

        // If the Symphony that was actually selected as the system output was
        // unplugged, CoreAudio may choose an arbitrary virtual endpoint. That
        // leaves the menu-bar volume control muted/ineffective (notably with
        // remote-desktop devices). Recover only this narrow case: the old
        // default must have been a removed Symphony. A deliberate non-Symphony
        // output choice is never changed.
        if CoreAudioDeviceConnection.shouldRecoverRemovedDefault(
            removedSymphonyIDs: removedSymphonyIDs,
            previousDefault: previousDefaultOutput),
           let fallback = CoreAudioDeviceConnection.builtInOutputDevice(),
           CoreAudioDeviceConnection.setDefaultOutputDevice(fallback) {
            // This is a safety recovery, not the connect-time auto-switch
            // preference. If Symphony was already the user's default and then
            // disappears, leaving CoreAudio's arbitrary virtual fallback can
            // make the menu-bar volume control appear muted/ineffective. The
            // preference still controls whether a newly connected Symphony is
            // selected; it must not prevent recovery from a removed default.
            print("[Maestro] Symphony output disappeared; default output → built-in device \(fallback)")
            knownDefaultOutputDeviceID = fallback
        } else {
            // Refresh this snapshot after CoreAudio has processed the event;
            // future removals should compare against the latest user choice.
            knownDefaultOutputDeviceID = CoreAudioDeviceConnection.currentDefaultOutputDevice()
        }

        guard newlyAppeared else { return }

        // Reconnect the app's own control connection to the best (Thunderbolt-preferred) device.
        Task { await reconnectHardware() }

        // Then, if enabled, switch the macOS default OUTPUT device — only on a genuine plug-in.
        guard !looksLikeCoreAudioRestart else { return }
        guard UserDefaults.standard.object(forKey: "autoSwitchToSymphony") as? Bool ?? true else { return }
        applyAutoOutputSwitch(discovered, newlyAppearedIDs: newlyAppearedIDs)
    }

    /// Set the macOS default output to the appropriate Symphony device per the user's preference.
    /// Thunderbolt → the ThunderBridge device. USB → the volume-capable "Maestro USB" ASP device by
    /// default, or Apple's raw "USB Audio" device if the user chose that. No-op if already default.
    @MainActor
    private func applyAutoOutputSwitch(_ discovered: [CoreAudioDeviceConnection.DiscoveredSymphonyIO],
                                      newlyAppearedIDs: Set<AudioDeviceID>) {
        // THE DEVICE YOU JUST PLUGGED IN WINS. That's the least surprising behavior (you performed a
        // deliberate action; honor it), and it *is* "last one connected" with zero extra state to
        // persist. If BOTH transports appear in the same tick, the reconnect path decides which one
        // is real (ThunderBridge only when its endpoint answers), so defer to it rather than
        // guessing here.
        let justConnected = discovered.filter { newlyAppearedIDs.contains($0.audioDeviceID) }
        let target = justConnected.first(where: { $0.transportType == .thunderbolt })
            ?? justConnected.first
            ?? discovered.first                             // fallback: shouldn't happen (we only get here on a rising edge)
        guard let best = target else { return }
        guard best.transportType == .usb else {
            // ThunderBridge: the audio device exists even while the Symphony is
            // off (dext 108+). Never make a clockless device the default output;
            // the reconnect path switches once it knows which transport is live.
            pendingAutoSwitchAfterReconnect = true
            return
        }
        switchDefaultOutputToUSB()
    }

    /// Make the USB Symphony the default output, preferring "Maestro USB".
    /// The AudioServerPlugin hides "Maestro USB" while the hardware is absent
    /// and un-hides it on its own timer after the class-compliant device has
    /// already arrived, so at the plug-in instant the name lookup can fail
    /// (2026-10-21). Wait briefly for it before settling for the class-compliant
    /// device, which bypasses the proxy's software level / pan / mute.
    @MainActor
    private func switchDefaultOutputToUSB() {
        func switchTo(_ targetID: AudioDeviceID) {
            guard CoreAudioDeviceConnection.currentDefaultOutputDevice() != targetID else { return }
            if CoreAudioDeviceConnection.setDefaultOutputDevice(targetID) {
                print("[Maestro] Auto-switch: default output → device \(targetID) (USB)")
            } else {
                print("[Maestro] Auto-switch: FAILED to set default output to device \(targetID)")
            }
        }
        func classCompliantUSB() -> AudioDeviceID? {
            CoreAudioDeviceConnection.discoverAllSymphonyIO().first(where: { $0.transportType == .usb })?.audioDeviceID
        }
        let preferAppleUSB = UserDefaults.standard.integer(forKey: "preferredUSBOutput") == 1
        if preferAppleUSB {
            if let usb = classCompliantUSB() { switchTo(usb) }
            return
        }
        usbAutoSwitchTask?.cancel()
        usbAutoSwitchTask = Task { @MainActor in
            for _ in 0..<12 {
                if Task.isCancelled { return }
                if let maestro = CoreAudioDeviceConnection.deviceID(named: Self.aspUSBDeviceName) {
                    switchTo(maestro)
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            if Task.isCancelled { return }
            print("[Maestro] Auto-switch: '\(Self.aspUSBDeviceName)' not found after 3 s (AudioServerPlugin not installed?) — falling back to Apple's USB Audio device")
            // Re-resolve: the ID captured at plug-in may be gone or renumbered by now.
            if let usb = classCompliantUSB() { switchTo(usb) }
        }
    }

    /// Complete a deferred auto-switch once the reconnect path has decided
    /// which transport is live: ThunderBridge → its device; USB → Maestro USB.
    @MainActor
    private func applyPendingAutoSwitch() {
        guard pendingAutoSwitchAfterReconnect else { return }
        pendingAutoSwitchAfterReconnect = false
        guard UserDefaults.standard.object(forKey: "autoSwitchToSymphony") as? Bool ?? true else { return }
        guard connectionMode == .hardware else { return }
        switch transportType {
        case .thunderbolt:
            guard let id = activeAudioDeviceID else { return }
            guard CoreAudioDeviceConnection.currentDefaultOutputDevice() != id else { return }
            if CoreAudioDeviceConnection.setDefaultOutputDevice(id) {
                print("[Maestro] Auto-switch: default output → device \(id) (ThunderBridge, endpoint live)")
            } else {
                print("[Maestro] Auto-switch: FAILED to set default output to device \(id)")
            }
        case .usb:
            switchDefaultOutputToUSB()
        default:
            break
        }
    }

    /// While connected over USB with a ThunderBridge also present, re-probe its
    /// endpoint every few seconds and move back to it when it becomes live. A
    /// `.unavailable` verdict at selection time can also mean "dext mid-upgrade",
    /// and a dext that comes back keeps its Core Audio ID, so no device-list
    /// change would re-run the selection.
    @MainActor
    func startThunderboltWatchWhileOnUSB(_ discovered: [CoreAudioDeviceConnection.DiscoveredSymphonyIO]) {
        thunderboltWatchTask?.cancel()
        guard let tb = discovered.first(where: { $0.transportType == .thunderbolt }) else { return }
        let identifier = tb.identifier
        let audioDeviceID = tb.audioDeviceID
        thunderboltWatchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled, self.transportType == .usb else { break }
                let live = await Task.detached(priority: .utility) {
                    // A throwaway probe: no settings store to load every tick.
                    let probe = ThunderboltDeviceConnection(identifier: identifier, audioDeviceID: audioDeviceID)
                    let verdict = probe.probeEndpoint()
                    probe.closeDextClient()
                    return verdict.isLive
                }.value
                // Same stale-verdict guard as the health loop: a reconnect
                // may have replaced the session while the probe was in flight.
                guard !Task.isCancelled, self.transportType == .usb else { break }
                if live {
                    Self.tbLog.notice("ThunderBridge endpoint live while on USB — reconnecting to prefer it")
                    self.scheduleThunderboltSwitch()
                    break
                }
            }
        }
    }

    @MainActor
    @discardableResult
    func scheduleThunderboltSwitch() -> Task<Void, Never> {
        pendingAutoSwitchAfterReconnect = true
        return Task { @MainActor [weak self] in await self?.reconnectHardware() }
    }

    // MARK: - Primary output level helpers

    /// Max level across all even-indexed output channels (L of each stereo pair).
    /// Used by the mixer master strip when the active output pair is not channels 0-1.
    var primaryOutputL: Double {
        stride(from: 0, to: outputMeterLevels.count, by: 2).map { outputMeterLevels[$0] }.max() ?? -60.0
    }
    /// Max level across all odd-indexed output channels (R of each stereo pair).
    var primaryOutputR: Double {
        stride(from: 1, to: outputMeterLevels.count, by: 2).map { outputMeterLevels[$0] }.max() ?? -60.0
    }
    /// Peak hold for primary output L.
    var primaryOutputPeakL: Double {
        stride(from: 0, to: outputPeakHold.count, by: 2).map { outputPeakHold[$0] }.max() ?? -60.0
    }
    /// Peak hold for primary output R.
    var primaryOutputPeakR: Double {
        stride(from: 1, to: outputPeakHold.count, by: 2).map { outputPeakHold[$0] }.max() ?? -60.0
    }

    init() {
        // Pair migration runs only after selecting the physical mixer scope.
        // Load cached board types so routing labels are correct before USB reads complete.
        // Card simulation (debug only). Lets us run the app as hardware we do not
        // physically own -- chiefly a MicPre8, so the mic preamp UI can be seen
        // and screenshotted against the original Maestro. Inert unless a launch
        // argument is present; nothing in the UI writes these keys.
        //
        //   /Applications/Maestro.app/Contents/MacOS/MaestroApp \
        //     -MaestroSimulatePrimaryBoard analogADDA16 \
        //     -MaestroSimulateSecondaryBoard micPre8
        //
        // Applied BEFORE loadCachedBoardTypes so the simulated pair wins over
        // whatever this machine last cached, and marked .simulated so Device Info
        // says so rather than presenting it as a detection.
        // `try?` would be wrong here. An invalid pairing (an 8MicPre in slot 1,
        // say) throws, and swallowing that would leave `simulationRequest` nil —
        // which does not mean "no simulation was asked for", it means discovery
        // runs and the harness talks to whatever real Symphony is plugged in,
        // exactly what the comment below says must not happen. The request was
        // impossible, so fail loudly instead of quietly doing something else.
        // Debug only: `-MaestroSimulateSecondUnit analogADDA16+optical` adds a
        // simulated unit B (port 2, 64 channels). It pins the session to
        // simulation like the card simulation; unit A takes the
        // `-MaestroSimulatePrimaryBoard`/`SecondaryBoard` cards, or unit B's.
        let secondUnitRequest = SecondUnitSimulation.request()
        if UserDefaults.standard.string(forKey: SecondUnitSimulation.key) != nil, secondUnitRequest == nil {
            print("[Maestro] SECOND UNIT SIMULATION: invalid request; exiting.")
            exit(1)
        }
        let simulationRequest: CardConfiguration?
        do {
            simulationRequest = try SimulatedDevice.simulationRequest()
                ?? secondUnitRequest.map { CardConfiguration(slot1: $0.slot1, slot2: $0.slot2) }
        } catch {
            print("[Maestro] CARD SIMULATION: invalid request — \(error)")
            print("[Maestro] CARD SIMULATION: refusing to fall through to real hardware; exiting.")
            exit(1)
        }
        self.cardSimulation = simulationRequest
        if let sim = simulationRequest {
            primaryBoardType   = sim.slot1
            secondaryBoardType = sim.slot2
            primaryBoardSource   = .simulated
            secondaryBoardSource = .simulated
            print("[Maestro] CARD SIMULATION: slot1=\(sim.slot1.productName) slot2=\(sim.slot2.productName)")
        } else {
            loadCachedBoardTypes()
        }

        // Debug only: show the app as it would look with older converters
        // attached. No hardware is discovered or touched.
        if let name = UserDefaults.standard.string(forKey: ConnectedUnit.simulationKey) {
            // One port ("ad16x+da16x") or two ("...|..."), which means 64 channels.
            guard let system = ConverterSystem.withStoredConfig(simulated: true, {
                      ConverterSystem(simulationName: name, config: $0)
                  }),
                  let unit = system.connectedUnit else {
                print("[Maestro] CONVERTER SIMULATION: invalid request '\(name)'; exiting.")
                exit(1)
            }
            print("[Maestro] CONVERTER SIMULATION: \(unit.displayName) — no hardware")
            primaryBoardType = .none
            secondaryBoardType = .none
            primaryBoardSource = .unknown
            secondaryBoardSource = .unknown
            self.connectedUnit = unit
            self.converterSystem = system
            self.device = SimulatedDevice.symphonyIO32ch()
            self.connectionMode = .simulated
            self.transportType = .thunderbolt
            self.statusMessage = "Simulating \(unit.modelName ?? "converters") — no hardware"
            self.isHardwareInitialized = true
            installSleepWakeObservers()
            return
        }

        // Discover hardware via CoreAudio. Prefers Thunderbolt (lower latency PCIe DMA)
        // over USB (via XPC proxy). Both paths connect to the same Symphony IO hardware.
        //
        // NOT under card simulation: a real unit on this machine would otherwise
        // win, `readCardTypes()` would overwrite the forced board types with the
        // detected ones (and cache them), and the harness would push mixer and
        // routing writes at hardware it was never meant to touch.
        // 0.9.8: Core Audio is not asked for its devices here. Asking it on the
        // main thread before the window exists made Maestro bounce in the Dock
        // whenever Core Audio was slow, as it is for a minute or two after every
        // install (the installer restarts it). The window opens now, in the "no
        // device" state below, and completeLaunchDiscovery() asks from a
        // background thread and connects exactly as this did.
        if simulationRequest == nil {
            launchDiscoveryPending = true
            print("[Maestro] AppState.init: Symphony discovery deferred until the window is up")
        } else {
            print("[Maestro] CARD SIMULATION: hardware discovery skipped — session pinned to the simulated unit")
        }


        // Fall back to simulated device. Under card simulation this must be the
        // device that PRESENTS those cards -- its identifier.mode channel count
        // and per-channel property scoping follow the simulated modules -- or the
        // pages render a 16ch unit's counts over a simulated 32ch card pair and
        // the screenshots prove nothing.
        let simDevice = AppState.makeSimulatedDevice(configuration: simulationRequest)
        self.device = simDevice
        self.connectionMode = cardSimulation != nil ? .simulated : .disconnected
        self.statusMessage = launchDiscoveryPending
            ? "Looking for your Symphony…"
            : AppState.simulatedStatusMessage(configuration: simulationRequest)
        self.isHardwareInitialized = true
        if let secondUnitRequest {
            applySecondUnitSimulation(secondUnitRequest, identifier: simDevice.identifier)
        }
        installSleepWakeObservers()
    }

    private func installSleepWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        sleepWakeObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspendTwoUnitReplay() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.wakeTwoUnitReplay() }
            }
        ]
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for observer in sleepWakeObservers { center.removeObserver(observer) }
    }

    /// Set by init when Core Audio still has to be asked for the Symphony.
    var launchDiscoveryPending = false
    /// What the launch discovery found, reused by the device-list listener and the
    /// ThunderBridge watch so they do not ask Core Audio again straight away.
    private(set) var lastLaunchDiscovered: [CoreAudioDeviceConnection.DiscoveredSymphonyIO]?

    /// Testing only: `-MaestroDebugDiscoveryDelay 20` makes the launch discovery
    /// wait that many seconds first, as a slow Core Audio would.
    private static var launchDiscoveryTestDelay: Double {
        UserDefaults.standard.double(forKey: "MaestroDebugDiscoveryDelay")
    }

    /// Ask Core Audio for the Symphony from a background thread and connect to it,
    /// as init used to. Called first by the main window's launch task.
    @MainActor
    func completeLaunchDiscovery() async {
        guard launchDiscoveryPending else { return }
        launchDiscoveryPending = false
        let generation = wakeValidationGeneration
        print("[Maestro] Launch: discovering Symphony IO via CoreAudio (background)...")
        let slowNotice = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled, self.connectionMode != .hardware else { return }
            self.statusMessage = "Waiting for macOS audio to respond…"
            print("[Maestro] Launch: Core Audio slow to answer — still waiting")
        }
        let delay = Self.launchDiscoveryTestDelay
        let started = Date()
        let discovered: [CoreAudioDeviceConnection.DiscoveredSymphonyIO]
        if let launchDiscoveryOperation { discovered = await launchDiscoveryOperation() }
        else {
            discovered = await Task.detached(priority: .userInitiated) {
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                return CoreAudioDeviceConnection.discoverAllSymphonyIO()
            }.value
        }
        slowNotice.cancel()
        lastLaunchDiscovered = discovered
        print(String(format: "[Maestro] Launch: discovery took %.2f s", Date().timeIntervalSince(started)))
        guard admitConnectionWork(generation: generation) else {
            replaySuspendedReconnectIfNeeded()
            return
        }
        if connectAtLaunch(discovered) {
            viewReloadToken = UUID()
        } else {
            print("[Maestro] AppState.init: No Symphony IO device found via CoreAudio")
            statusMessage = AppState.simulatedStatusMessage(configuration: nil)
        }
    }

    /// Connect to the preferred device the launch discovery found: the code that
    /// was the second half of init, unchanged. Returns whether a Symphony was found.
    @MainActor
    private func connectAtLaunch(_ discovered: [CoreAudioDeviceConnection.DiscoveredSymphonyIO]) -> Bool {
        if let pref = Self.preferredDevice(in: discovered) {
        let best = pref.device
            let audioDeviceID = best.audioDeviceID
            let identifier = best.identifier
            print("[Maestro] AppState.init: Found \(best.name) via \(best.transportType.displayName) (AudioDeviceID: \(audioDeviceID), PID: 0x\(String(identifier.productID, radix: 16)))")

            if best.transportType == .thunderbolt {
                // ── Thunderbolt path: standard CoreAudio properties → AudioDriverKit dext
                let tbDevice = pref.tbConnection ?? ThunderboltDeviceConnection(identifier: identifier, audioDeviceID: audioDeviceID,
                        settingsStore: DeviceSettingsStore())
                self.device = tbDevice
                self.connectionMode = .hardware
                self.transportType = .thunderbolt
                self.transportPresent = true
                self.statusMessage = "Connected via \(self.connectionShortName)"
                self.isHardwareInitialized = true
                self.activeAudioDeviceID = audioDeviceID
                // Store TB device ID for volume sync — media keys change this device directly
                self.aspDeviceID = audioDeviceID
                print("[Maestro] AppState.init: Connected to hardware via ThunderBridge (Thunderbolt)")
                let attachProbe = pref.tbVerdict ?? tbDevice.probeEndpoint()
                if case .live(let health) = attachProbe {
                    print("[Maestro] TB timing health: rate=\(health.sampleRate) frame=\(health.frameReadback)/\(health.expectedFrame) latency=\(health.inputLatency)/\(health.outputLatency) safety=\(health.inputSafety)/\(health.outputSafety) int=0x\(String(health.intStatus, radix: 16)) xlink=0x\(String(health.xlinkStatus, radix: 16))")
                } else {
                    print("[Maestro] TB endpoint not live at attach: \(attachProbe.label)")
                    Self.tbLog.notice("attach: endpoint \(attachProbe.label, privacy: .public) — presenting Symphony disconnected")
                    // Core Audio can retain the PCI audio object after the
                    // downstream Symphony powers off. Do not start metering or
                    // issue board/routing reads until the dext proves the FPGA
                    // endpoint is live. Keep the transport visible and let the
                    // health loop promote this connection when power returns.
                    self.connectionMode = .disconnected
                    self.statusMessage = "Symphony disconnected"
                    self.isHardwareInitialized = false
                    self.thunderboltHardwareResponsive = false
                    self.viewReloadToken = UUID()
                    return true
                }
            } else {
                // ── USB path: XPC proxy → USB vendor EP0 commands
                let xpcDevice = XPCDeviceConnection(identifier: identifier,
                        settingsStore: DeviceSettingsStore())
                self.device = xpcDevice
                self.connectionMode = .hardware
                self.transportType = .usb
                self.transportPresent = true
                self.statusMessage = "Connected via USB"
                self.isHardwareInitialized = true
                self.activeAudioDeviceID = audioDeviceID
                print("[Maestro] AppState.init: Connected to hardware via XPC proxy (USB)")

                // Mixer restoration follows identity resolution.
            }

            // The Core Audio IOProc is an input tap, so starting it makes macOS treat
            // Maestro as a microphone client (permission prompt, orange indicator).
            // Both transports draw their meters from hardware (FPGA meter DMA on
            // ThunderBridge, TDM 0x30 on USB), so the tap is off unless a user opts in.
            let meterCA = CoreAudioDeviceConnection(identifier: identifier, audioDeviceID: audioDeviceID)
            if Self.softwareMeteringOptedIn {
                meterCA.startSoftwareMetering()
                print("[Maestro] AppState.init: Software metering started (\(best.transportType.displayName))")
            }
            self.meterDevice = meterCA

            // Sync volume/mute UI with the ASP device (media keys → app knob).
            startASPVolumeSync()
            return true
        }
        return false
    }

    /// Status-bar text for a session on the in-memory device. Under card
    /// simulation it names the forced cards so a screenshot cannot be mistaken
    /// for a real unit — or for a failure to connect.
    static func simulatedStatusMessage(configuration: CardConfiguration?) -> String {
        guard let configuration else { return "No device connected" }
        return "Simulating \(configuration.slot1.productName) + \(configuration.slot2.productName) — no hardware"
    }

    /// Read I/O card types from hardware via USB 0xA1 (async, fire-and-forget).
    /// Retries the secondary board read with delays — some firmware revisions need
    /// time between sequential EP0 vendor reads to different board slots.
    /// Read identity only after card/converter capabilities are known; this
    /// keeps converter chains away from the Symphony-only 0xC0 command.
    @MainActor
    private func readUnitAIdentityAfterCapabilities() async {
        guard let captured = device else { return }
        guard cardLayout.converter == nil, cardLayout.converterLayout == nil,
              (captured is XPCDeviceConnection || SymphonyIdentityReader.isSupported(layout: cardLayout, unit: .a)) else {
            invalidateUnitAIdentity()
            unitAIdentityState = .failed
            viewReloadToken = UUID()
            return
        }
        await resolveUnitIdentity(for: .a, connection: captured) {
            if let tb = captured as? ThunderboltDeviceConnection { return await tb.readHardwareUniqueID() }
            if let usb = captured as? XPCDeviceConnection { return await usb.readHardwareUniqueID() }
            return nil
        }
    }

    /// Converter (or non-Symphony) verdict: identity is invalidated and marked
    /// failed once, not on every discovery pass. Re-invalidating made a new unit
    /// generation each pass, rebuilding the pages keyed on it (blank window).
    nonisolated static func converterVerdictNeedsInvalidation(isConverter: Bool,
                                                              unitA: UnitIdentityState,
                                                              unitB: UnitIdentityState) -> Bool {
        isConverter && (unitA != .failed || unitB != .failed)
    }

    @MainActor
    func readCardTypes() async {
        guard hardwareSleepState != .sleeping else { cardDiscoverySkippedDuringSleep = true; return }
        let generation = unitAGeneration
        let connection = device as AnyObject?
        // Loop: after each await another caller may have started a newer task.
        while let old = cardDiscoveryTask {
            if cardDiscoveryTaskGeneration == generation,
               cardDiscoveryTaskConnection === connection {
                await old.value
                return
            }
            old.cancel()
            await old.value
            cardDiscoveryTask = nil
            cardDiscoveryTaskGeneration = nil
            cardDiscoveryTaskConnection = nil
        }
        let task = Task {
            guard self.unitAGeneration == generation, !Task.isCancelled else { return }
            await self.discoverCardsAndIdentity()
        }
        cardDiscoveryTask = task
        cardDiscoveryTaskGeneration = generation
        cardDiscoveryTaskConnection = connection
        await task.value
        startMicPreDAWSync()
        if cardDiscoveryTaskGeneration == generation {
            cardDiscoveryTask = nil
            cardDiscoveryTaskGeneration = nil
            cardDiscoveryTaskConnection = nil
        }
    }

    @MainActor
    private func discoverCardsAndIdentity() async {
        guard let device = self.device else { return }
        var generation = unitAGeneration
        /// Apply a finding of this discovery that may invalidate identity,
        /// then continue under the new generation instead of cancelling.
        func ownChange(_ change: () -> Void) {
            discoveryOwnsInvalidation = true
            change()
            discoveryOwnsInvalidation = false
            generation = unitAGeneration
        }
        // What the driver found on the cable, if it is not a Symphony I/O.
        let probeWord: UInt32
        if let tb = device as? ThunderboltDeviceConnection {
            probeWord = await Task.detached(priority: .utility) { tb.linkState()?.unitProbe ?? 0 }.value
            guard self.device === device, unitAGeneration == generation, !Task.isCancelled else { return }
        } else { probeWord = 0 }
        connectedUnitProbeWord = probeWord
        ownChange { connectedUnit = ConnectedUnit(probeWord: probeWord) }
        // The converter report (dext 131+): the stored Device Types and clock
        // go to the driver first, then both ports are read. Port-1 converters
        // reported there count as identified even without a probe word, so the
        // guards that keep Symphony I/O commands away from them still hold.
        loggedConverterNotices = []
        if let tb = device as? ThunderboltDeviceConnection {
            await Task.detached(priority: .utility) { Self.applyStoredConverterConfig(tb) }.value
            guard self.device === device, unitAGeneration == generation, !Task.isCancelled else { return }
            let state = await Task.detached(priority: .utility) { tb.converterState() }.value
            guard self.device === device, !Task.isCancelled else { return }
            let system = Self.converterSystem(state: state, probeWord: probeWord)
            ownChange {
                if system != converterSystem { converterSystem = system }
                connectedUnit = connectedUnit ?? system?.connectedUnit
            }
        } else { ownChange { refreshConverterSystem() } }
        // Only when the verdict changes. Re-running this on every pass made a new
        // unit generation each time, which rebuilt the pages keyed on it on every
        // health-loop recovery (blank window seen by Daniel, 2026-11-19).
        if Self.converterVerdictNeedsInvalidation(isConverter: connectedUnit != nil || converterSystem != nil,
                                                  unitA: unitAIdentityState, unitB: unitBIdentityState) {
            ownChange {
                invalidateUnitAIdentity()
                invalidateUnitBIdentity()
                unitAIdentityState = .failed
                unitBIdentityState = .failed
            }
        }
        // Needed before the input routing is laid out (thunderboltCaptureSlot1),
        // so it is awaited here; read off the main thread like every other
        // user-client call that can wait on the driver.
        if let tb = device as? ThunderboltDeviceConnection {
            let build = await Task.detached(priority: .utility) { tb.servingDriverBuild() }.value
            guard self.device === device, unitAGeneration == generation, !Task.isCancelled else { return }
            if (self.device as? ThunderboltDeviceConnection) === tb { servingDextBuild = build }
            // Which order the driver programmed the tables in, before anything
            // reads the saved routing (and the one-time reset that may follow).
            // A new connection reads it afresh.
            thunderboltAppliedChannelOrder = nil
            await refreshThunderboltChannelOrder(tb)
            guard self.device === device, unitAGeneration == generation, !Task.isCancelled else { return }
        } else {
            servingDextBuild = nil
            thunderboltAppliedChannelOrder = nil
        }
        if let connectedUnit {
            print("[Maestro] Connected unit is not a Symphony I/O: \(connectedUnit.displayName)")
        }
        // Each slot's hardware version, which tells an 8x8 AES/OPT combo from
        // an AES-only or optical-only 8x8. One read per slot, as the original.
        for slot in 0..<2 {
            let major: UInt8?
            if let usb = device as? XPCDeviceConnection {
                major = await usb.readBoardHardwareMajor(slot: slot)
            } else if let thunderbolt = device as? ThunderboltDeviceConnection, connectedUnit == nil {
                major = await thunderbolt.readBoardHardwareMajor(slot: slot)
            } else {
                major = nil
            }
            guard self.device === device, unitAGeneration == generation, !Task.isCancelled else { return }
            if slot == 0 { primaryBoardHardwareMajor = major } else { secondaryBoardHardwareMajor = major }
        }
        refreshSecondPortState()
        if let secondPortState {
            print("[Maestro] Two-port driver: \(secondPortState.rawText)")
        }
        startPortSelectionObservation()
        // ThunderBridge's dext returns a validity bit alongside each raw
        // OptionBoardType value, so a valid raw zero means the slot was
        // measured empty. USB's proxy cannot make that distinction and keeps
        // the conservative unknown behavior below.
        let thunderboltReadDistinguishesEmptySlot = device is ThunderboltDeviceConnection
        let primaryRaw = try? await device.getProperty(PropertyAddress(selector: .primaryBoardType))
        guard self.device === device, unitAGeneration == generation, !Task.isCancelled else { return }
        if let raw = primaryRaw?.asUInt32,
           raw <= UInt32(UInt8.max),
           let card = IOCardType(rawValue: UInt8(raw)) {
            guard self.device === device, unitAGeneration == generation, !Task.isCancelled else { return }
            self.primaryBoardType = card
            // A live read of 0 means "nothing reported", not "measured empty".
            // The secondary path already refuses to record .none for exactly this
            // reason; the primary lacked the check. Marking a spurious 0 as
            // .detected would unlock Reset Routing, whose plan text promises
            // nothing is written to an empty slot while it actually writes 16
            // silence routes -- on this unit that silences Line 1-8 AND ADAT 1-8.
            self.primaryBoardSource = (card == .none && !thunderboltReadDistinguishesEmptySlot)
                ? .unknown : .detected
            print("[Maestro] Primary board: \(card.digitalLabel) (raw=\(raw))")
        }

        guard self.device === device, unitAGeneration == generation, !Task.isCancelled else { return }
        // Secondary board: retry up to 3 times with increasing delays.
        // The XMOS USB controller may need time between sequential slot reads.
        for attempt in 1...3 {
            if attempt > 1 {
                do { try await Task.sleep(for: .milliseconds(100 * attempt)) } catch { return }
                guard self.device === device, unitAGeneration == generation, !Task.isCancelled else { return }
            }
            let secondaryRaw = try? await device.getProperty(PropertyAddress(selector: .secondaryBoardType))
            guard self.device === device, unitAGeneration == generation, !Task.isCancelled else { return }
            if let raw = secondaryRaw?.asUInt32,
               raw <= UInt32(UInt8.max),
               let card = IOCardType(rawValue: UInt8(raw)),
               (card != .none || thunderboltReadDistinguishesEmptySlot) {
                guard self.device === device, unitAGeneration == generation, !Task.isCancelled else { return }
                self.secondaryBoardType = card
                self.secondaryBoardSource = .detected
                print("[Maestro] Secondary board: \(card.digitalLabel) (raw=\(raw)) [attempt \(attempt)]")
                saveBoardTypeCache()
                await readUnitAIdentityAfterCapabilities()
                return
            }
        }
        guard self.device === device, unitAGeneration == generation, !Task.isCancelled else { return }
        print("[Maestro] Secondary board: not detected after 3 attempts (hardware may have 1 board or slot 1 empty)")
        // Still save whatever we got (primary may have succeeded)
        saveBoardTypeCache()
        await readUnitAIdentityAfterCapabilities()
    }

    /// Sync persisted output routing to hardware on connect/reconnect.
    /// Reads cached dual routing state and writes each (row, col) pair to USB.
    /// Called after readCardTypes() so board types are available for byte mapping.
    @MainActor
    func syncOutputRoutingToHardware() async {
        guard !hardwareWritesSuspended else { return }
        if usesTwoUnitReplay { twoUnitReplayNeeded = true; return }
        guard let device = self.device else { return }
        // Converters: their own routes, kept per chain, never the Symphony
        // I/O table below (same product ID) and never behind the card
        // detection guard (a converter has no option cards).
        if converterRoutingSurface {
            // The Symphony I/O output table (and the rule that waits for a
            // card mixer to be written) does not apply to converters.
            (device as? ThunderboltDeviceConnection)?.cardMixers.isBypassed = true
            // Nothing is replayed while a unit is not identified (no layout).
            // From the default placement first, so no route the driver kept
            // from before stays on the card.
            await replayConverterRouting(resetFirst: true)
            return
        }
        // ThunderBridge: the restore checks the unit's identity itself, so
        // that an unidentified unit is retried and said in the status bar.
        guard device is ThunderboltDeviceConnection || connectionMode != .hardware || unitAIdentity != nil else {
            return
        }
        // The cache is keyed by product ID, so ThunderBridge (0x12) and the USB
        // modes keep separate tables. On ThunderBridge the dext replays its
        // default routing on every Start and in-place recovery, so without this
        // replay the user's routes silently revert after each power cycle or
        // replug. Replaying a cached table can target stale board destinations
        // after a card change, so on ThunderBridge require this session's card
        // types to have been detected (the same provenance rule Reset Routing
        // applies) before writing anything.
        if let tb = device as? ThunderboltDeviceConnection, transportType == .thunderbolt {
            // The ordered restore: the table, the card mixers it routes, then
            // the routes they feed (`restoreThunderboltOutputTable`).
            tb.cardMixers.isBypassed = false
            await restoreThunderboltOutputTable(tb)
            return
        }
        await syncUSBOutputRouting(device)
    }

    /// USB: the saved Output Routing rows over the helper's direct default
    /// table (it programs that every time it configures the unit). Returns
    /// whether every saved route is on the unit.
    ///
    /// A route fed by a mixer the restore has not written is not skipped: an
    /// earlier session's route may still be on the unit, so its destination
    /// is disabled (the "no source" byte the grid writes when a route is
    /// removed) and the route stays owed until the mixer is written.
    ///
    /// `mixerFedOnly`: the last step of the USB restore. Its first step
    /// (`usbPointRoutesAwayFromMixers`) has already written the direct routes.
    @MainActor
    @discardableResult
    func syncUSBOutputRouting(_ device: any DeviceConnection, mixerFedOnly: Bool = false) async -> Bool {
        let id = device.identifier
        let cache = peripheralRoutingCache(direction: "output")
        let routes = cache.loadMulti() ?? [:]
        guard !routes.isEmpty else {
            print("[Maestro] syncOutputRouting: no saved routes, the direct default stands")
            syncUSBHelperSoftwareReturn()
            return true
        }
        let board1 = self.primaryBoardType
        let board2 = self.secondaryBoardType
        let swPairs = (id.mode.channelCount) / 2
        var written = 0, failed = 0, withheld = 0
        for (row, cols) in routes.sorted(by: { $0.key < $1.key }) {
            for col in cols.sorted() {
                guard self.device === device, !hardwareWritesSuspended else { return false }
                guard let destByte = IOCardType.columnToRoutingByte(
                    col: col, isInput: false, board1: board1, board2: board2
                ) else { continue }
                let srcLeft: UInt8
                if let pair = TwoUnitOutputRouting.playbackPair(
                    unitARow: row, unitAPairs: swPairs, unitBActive: unitBOnCard) {
                    srcLeft = SymphonyIORoutingAddress.hostPlaybackBase(for: transportType ?? .usb) + UInt8(pair * 2)
                } else if row == swPairs {
                    srcLeft = SymphonyIORoutingAddress.mixer0Base
                } else if row == swPairs + 1 {
                    srcLeft = SymphonyIORoutingAddress.mixer1Base
                } else { continue }
                if mixerFedOnly, CardOutputTableOrder.mixer(ofSource: srcLeft) == nil { continue }
                do {
                    // A mixer is routed only once its strips are on the unit
                    // (`restoreUSBUnit`); `writeOutputRoute` disables the
                    // destination until then and reports it deferred.
                    if try await writeOutputRoutePair(destLeft: destByte, srcLeft: srcLeft, device: device,
                                                      restoring: true) == .deferred {
                        withheld += 1
                    } else {
                        written += 1
                    }
                } catch {
                    failed += 1
                    print("[Maestro] syncOutputRouting: output \(destByte) ← source \(srcLeft) failed: \(error)")
                }
            }
        }
        print("[Maestro] syncOutputRouting: wrote \(written) saved routes to hardware"
            + (failed == 0 ? "" : ", \(failed) failed")
            + (withheld == 0 ? "" : ", \(withheld) mixer route(s) owed and their outputs disabled: that mixer's strips are not on the unit yet"))
        syncUSBHelperSoftwareReturn()
        return failed == 0 && withheld == 0
    }

    /// Whether the USB restore has written this mixer in full on this
    /// connection since the unit last came back (`usbMixersWritten`).
    @MainActor
    func usbMixerIsWritten(_ mixer: Int) -> Bool {
        guard let record = usbMixersWritten, record.generation == unitAGeneration,
              record.mixers.indices.contains(mixer) else { return false }
        return record.mixers[mixer]
    }

    /// Put the input routing choices saved on this Mac back on a ThunderBridge
    /// unit. The driver programs its board-order capture table every time it
    /// starts, and the Input Routing grid lays saved choices over that same
    /// table, so without this the grid showed choices the unit no longer had.
    /// Only rows the user picked are written; the rest stay at the driver's
    /// table. Card types must have been read this session (Reset Routing's
    /// provenance rule), since a column means a different routing byte on
    /// other cards. Then the unit's 32 capture routes are read back and logged
    /// once, as evidence of what it really carries.
    @MainActor
    func syncInputRoutingToHardware() async {
        guard !hardwareWritesSuspended, connectionMode != .hardware || unitAIdentity != nil else { return }
        if usesTwoUnitReplay { twoUnitReplayNeeded = true; return }
        guard transportType == .thunderbolt, let tb = device as? ThunderboltDeviceConnection else { return await syncUSBInputRoutingToHardware() }
        // Symphony I/O routing. Nothing is sent to a converter unprompted, the
        // read-back included (see syncDeviceSettingsToHardware).
        guard connectedUnit == nil else {
            print("[Maestro] syncInputRouting: skipped — connected unit is not a Symphony I/O")
            return
        }
        // The driver's recovery count this replay is made against. A recovery
        // that completes after this read programs the driver's table over
        // these writes; the health loop then sees the count differ from this
        // one and replays again. Without it a recovery between this replay
        // and the loop's next probe went unnoticed.
        let recoveryCountAtStart = await Task.detached(priority: .utility) {
            tb.linkState()?.recoveryCount
        }.value
        defer { if let recoveryCountAtStart { thunderboltSeenRecoveryCount = recoveryCountAtStart } }
        if let reason = RoutingResetGuard.refusalReason(board1: primaryBoardReading, board2: secondaryBoardReading) {
            print("[Maestro] syncInputRouting: skipped on ThunderBridge — \(reason)")
        } else if let reason = thunderboltChannelOrderUnknownReason {
            // The rows mean other inputs in the other order: nothing is sent
            // until the driver says which one it programmed.
            print("[Maestro] syncInputRouting: skipped on ThunderBridge — \(reason)")
            inputRoutingReplayNeeded = true
        } else {
            let cache = peripheralRoutingCache(direction: "input")
            if ThunderboltInputRoutingMigration.run(routingKey: cache.key) {
                print("[Maestro] syncInputRouting: cleared input routing saved before 0.8.40 (made on the old grid); the driver's default stands")
            }
            // Once after the routing and mixer reset: the default table first,
            // because a driver that kept running still has the unit on the
            // routes the reset removed from this Mac.
            let resetPending = RoutingMixerReset.isPending(.thunderboltInputRouting)
            let wasWritten = thunderboltInputRoutingWritten
            thunderboltInputRoutingWritten = false
            var writes = resetPending ? thunderboltDefaultInputRoutes(unit: .a) : []
            writes += InputRoutingReplay.writes(
                saved: cache.load() ?? [:], columns: cardLayout.inputRoutingColumns,
                pairCount: tb.identifier.mode.channelCount / 2)
            var written = 0
            var allSucceeded = true
            for write in writes {
                do {
                    try await tb.setProperty(
                        PropertyAddress(selector: .routing, scope: .input, element: UInt32(write.destination)),
                        value: .uint32(UInt32(write.source)))
                    written += 1
                } catch {
                    allSucceeded = false
                    print("[Maestro] syncInputRouting: dest \(write.destination) failed: \(error)")
                }
            }
            print("[Maestro] syncInputRouting: wrote \(written) of \(writes.count) input routes\(resetPending ? " (default table, then saved)" : " (saved)")")
            if resetPending, written == writes.count, self.device === tb {
                var cardReset = true
                if symphonyCardInputs.channelCount > 0 {
                    cardReset = await applySymphonyCardInputs([:], reset: true)
                }
                if cardReset { RoutingMixerReset.clearPending(.thunderboltInputRouting) }
            }
            thunderboltInputRoutingWritten = allSucceeded && written == writes.count
            inputRoutingReplayNeeded = !allSucceeded || written != writes.count
            // The table on the unit is now the saved one, or (after a failed
            // write) not known to be: the strips' card inputs may have moved,
            // so the mixers are owed a complete write with the new numbers. At
            // connect the restore that follows covers it; after a retry here
            // it runs at once. Not when a replay that had failed fails again:
            // nothing changed, and the health loop retries it every cycle.
            if thunderboltInputRoutingWritten || wasWritten {
                thunderboltCaptureTableDidChange()
            } else {
                invalidateThunderboltInputMeterMap()
            }
        }
        await replaySymphonyCardInputs()
        await tb.logInputRoutes()
    }

    /// Over USB the unit holds its capture table until it is power-cycled, and
    /// comes back at its own default after one. The saved choices are put back
    /// on connect and after a recovery, as the original did
    /// (og_source/maestrolink/Software/SymphonyIO.cpp:4692-4701: the routing
    /// controller's ApplySettingsToHardware in the USB Audio mode). Only rows
    /// the user picked are written, except once after the routing and mixer
    /// reset, when the original's default table
    /// (SymphonyIOUSBAudioRoutingController::ResetInputRouting) goes first so a
    /// unit that was never power-cycled does not keep the removed routes.
    /// Card types must have been read this session, as for Reset Routing.
    @MainActor
    private func syncUSBInputRoutingToHardware() async {
        guard let usb = device as? XPCDeviceConnection, connectedUnit == nil else { return }
        if let reason = RoutingResetGuard.refusalReason(board1: primaryBoardReading, board2: secondaryBoardReading) {
            print("[Maestro] syncInputRouting: skipped over USB — \(reason)")
            return
        }
        let channels = usb.identifier.mode.channelCount
        let resetPending = RoutingMixerReset.isPending(.usbInputRouting)
        var writes = resetPending
            ? SymphonyIODefaultRouting.inputRoutes(
                board0: .init(analog: primaryBoardType.analogInputChannels,
                              digital: primaryBoardType.digitalInputChannels),
                board1: .init(analog: secondaryBoardType.analogInputChannels,
                              digital: secondaryBoardType.digitalInputChannels),
                usbChannelCount: channels)
            : []
        writes += InputRoutingReplay.writes(
            saved: peripheralRoutingCache(direction: "input").load() ?? [:],
            columns: cardLayout.inputRoutingColumns, pairCount: channels / 2)
        guard !writes.isEmpty else { return }
        var written = 0
        for write in writes {
            guard self.device === usb, !hardwareWritesSuspended else { return }
            if written > 0 { try? await Task.sleep(for: .milliseconds(25)) }
            do {
                try await usb.setProperty(
                    PropertyAddress(selector: .routing, scope: .input, element: UInt32(write.destination)),
                    value: .uint32(UInt32(write.source)))
                written += 1
            } catch {
                print("[Maestro] syncInputRouting: dest \(write.destination) failed: \(error)")
            }
        }
        print("[Maestro] syncInputRouting: wrote \(written) of \(writes.count) input routes over USB\(resetPending ? " (default table, then saved)" : " (saved)")")
        if resetPending, written == writes.count { RoutingMixerReset.clearPending(.usbInputRouting) }
    }

    /// Write one mono output route to whichever routing stage the transport
    /// uses: the Symphony's `0x31` table over USB, the ThunderBridge card's
    /// output routing registers on ThunderBridge (`ThunderboltCardRouting`).
    ///
    /// A mixer is never routed to an output before that mixer is the user's:
    /// over ThunderBridge the connection decides (`setCardOutputRoute`), over
    /// USB the restore's record (`usbMixerIsWritten`). Such a route is
    /// `.deferred`, not an error: the choice is saved and shown, the
    /// destination is disabled meanwhile (never left on a stale route), the
    /// status bar says so, and the restore sends it once the mixer is written.
    @MainActor
    @discardableResult
    func writeOutputRoute(destination: UInt8, source: UInt8, device: any DeviceConnection,
                          restoring: Bool = false) async throws -> CardWriteResult {
        if !restoring { outputRouteEdits &+= 1 }
        if let thunderbolt = device as? ThunderboltDeviceConnection {
            // Converters route through `applyConverterRouting` (their own
            // grid and channels); this path is the Symphony I/O table.
            // The XLink channel depends on the order the driver programmed;
            // nothing is sent while it has not said which.
            if let reason = thunderboltChannelOrderUnknownReason {
                throw DeviceConnectionError.transportError("Output route not sent: \(reason)")
            }
            guard let route = thunderboltCardRoute(destination: destination, source: source, unitBActive: unitBOnCard) else {
                throw DeviceConnectionError.transportError(
                    "No ThunderBridge card route for output \(destination) ← source \(source)")
            }
            let result = try await Task.detached(priority: .userInitiated) {
                let result = try thunderbolt.setCardOutputRoute(route)
                if result == .deferred { _ = try thunderbolt.setCardOutputRoute(CardOutputTableOrder.disabled(route)) }
                return result
            }.value
            if result == .deferred, !restoring {
                outputRouteDeferredSinceSave = true
                cardOutputTableReplayNeeded = true
                cardOutputRetryAfter = .distantPast
                updateRestoreStatus()
            }
            return result
        }
        return try await writeUSBRoute(destination: destination, source: source, device: device, restoring: restoring)
    }

    /// Write a stereo output route (left + right channel) — see ``writeOutputRoute``.
    @MainActor
    @discardableResult
    func writeOutputRoutePair(destLeft: UInt8, srcLeft: UInt8, device: any DeviceConnection,
                              restoring: Bool = false) async throws -> CardWriteResult {
        let left = try await writeOutputRoute(destination: destLeft, source: srcLeft, device: device,
                                              restoring: restoring)
        let right = try await writeOutputRoute(destination: destLeft &+ 1,
                                               source: SymphonyIORoutingAddress.rightChannelSource(of: srcLeft),
                                               device: device, restoring: restoring)
        return left == .deferred || right == .deferred ? .deferred : .written
    }

    /// The software output a speaker-set pair goes back to when sets are
    /// removed (and the source of Line 1-2 when nothing is saved for it):
    /// on ThunderBridge the one the driver's playback table plays on that
    /// output in its channel order (analog first from driver 150, by
    /// position before); over USB by position, as before.
    func speakerSetDefaultSource(forDestination destination: UInt8) -> UInt8 {
        if transportType == .thunderbolt,
           let source = thunderboltDefaultOutputRoutes(unit: .a).first(where: { $0.destination == destination })?.source,
           source != SymphonyIORoutingAddress.none {
            return source
        }
        let hostBase = SymphonyIORoutingAddress.hostPlaybackBase(for: transportType ?? .usb)
        let boardBase = destination >= SymphonyIORoutingAddress.ioBoard1Base
            ? SymphonyIORoutingAddress.ioBoard1Base : SymphonyIORoutingAddress.ioBoard0Base
        let channel = (destination >= SymphonyIORoutingAddress.ioBoard1Base ? 16 : 0)
            + Int(destination - boardBase)
        return hostBase + UInt8(channel)
    }

    /// Match the legacy routing side effect of changing the Analog Out Format.
    /// When speaker sets are added, every new pair repeats the source feeding
    /// Line 1-2. When sets are removed, those pairs return to the defaults the
    /// original routing controller uses (`SymphonyPCIeRoutingController.cpp:2056-2093`,
    /// `SymphonyIORoutingController.cpp:612-664`).
    @MainActor
    func applySpeakerSetRouting(from oldMode: UInt32, to newMode: UInt32,
                                device: (any DeviceConnection)?) async {
        guard !converterRoutingSurface, let device, device === self.device else { return }
        let oldCount = SpeakerOutputLogic.routingSpeakerSetCount(mode: oldMode)
        let newCount = SpeakerOutputLogic.routingSpeakerSetCount(mode: newMode)
        guard oldCount != newCount else { return }
        let analogColumns = cardLayout.outputRoutingColumns.filter { !$0.isDigital }
        guard analogColumns.count >= max(oldCount, newCount) else { return }

        let hostBase = SymphonyIORoutingAddress.hostPlaybackBase(for: transportType ?? .usb)
        let firstDestination = analogColumns[0].routingByte
        let cached = cachedOutputRouteMap()
        func defaultPlaybackSource(for destination: UInt8) -> UInt8 {
            speakerSetDefaultSource(forDestination: destination)
        }
        let source = cached[firstDestination] ?? defaultPlaybackSource(for: firstDestination)
        let sourceRow: Int? = {
            if source == SymphonyIORoutingAddress.mixer0Base { return device.identifier.mode.channelCount / 2 }
            if source == SymphonyIORoutingAddress.mixer1Base { return device.identifier.mode.channelCount / 2 + 1 }
            guard source >= hostBase else { return nil }
            let offset = Int(source - hostBase)
            guard offset.isMultiple(of: 2), offset < device.identifier.mode.channelCount else { return nil }
            return offset / 2
        }()

        var saved = peripheralRoutingCache(direction: "output").loadMulti() ?? [:]
        func removeColumn(_ column: Int) {
            for row in saved.keys {
                saved[row]?.remove(column)
                if saved[row]?.isEmpty == true { saved.removeValue(forKey: row) }
            }
        }
        func addColumn(_ column: Int, to row: Int) {
            removeColumn(column)
            saved[row, default: []].insert(column)
        }

        if newCount > oldCount, let sourceRow {
            for pair in 1..<newCount {
                let destination = analogColumns[pair].routingByte
                guard let column = analogColumns.firstIndex(where: { $0.routingByte == destination }) else { continue }
                do {
                    _ = try await writeOutputRoutePair(destLeft: destination, srcLeft: source,
                                                        device: device)
                    addColumn(column, to: sourceRow)
                } catch {
                    print("[Maestro] speaker-set route (destination) failed: \(error)")
                }
            }
        } else if newCount < oldCount {
            for pair in newCount..<oldCount {
                let destination = analogColumns[pair].routingByte
                let defaultSource = defaultPlaybackSource(for: destination)
                let row = Int(defaultSource - hostBase) / 2
                guard let column = analogColumns.firstIndex(where: { $0.routingByte == destination }) else { continue }
                do {
                    _ = try await writeOutputRoutePair(destLeft: destination, srcLeft: defaultSource,
                                                        device: device)
                    addColumn(column, to: row)
                } catch {
                    print("[Maestro] speaker-set default route (destination) failed: \(error)")
                }
            }
        }
        peripheralRoutingCache(direction: "output").save(saved)
        outputRoutingSaved()
    }

    /// Write the settings saved on this Mac back to the unit on connect/reconnect.
    ///
    /// The original daemon did this on every connect (`ApplySettingsToHardware`),
    /// because in the USB and Symphony interface modes the Mac, not the box, owns
    /// these settings. Without it a power-cycled unit, or a ThunderBridge driver
    /// that restarted, comes back at its own defaults while Maestro shows what
    /// the user last chose. Only settings that were changed through Maestro are
    /// stored, so a unit nobody has configured here is left alone.
    @MainActor
    func syncDeviceSettingsToHardware() async {
        guard !hardwareWritesSuspended else { return }
        // Over USB the monitor mode goes first and always, also for a unit
        // whose identity could not be read: the saved mode, or Stereo when
        // none is saved, as the original
        // (og_source/maestrolink/Software/SymphonyIO.cpp:4669, default :128).
        // The helper used to force Stereo each time it configured the unit and
        // no longer writes the mode at all. Over ThunderBridge the driver
        // reads the unit's mode at start and writes it back, so nothing is
        // added there.
        if let xpc = device as? XPCDeviceConnection, connectionMode == .hardware, connectedUnit == nil,
           let mode = await xpc.applySpeakerOutputMode() {
            guard self.device === xpc else { return }
            speakerOutputMode = mode
        }
        guard unitAIdentity != nil else { return }
        if usesTwoUnitReplay { twoUnitReplayNeeded = true; return }
        guard connectionMode == .hardware, isHardwareInitialized, let device else { return }
        // These are Symphony I/O settings. A converter does not have them, and
        // what its firmware does with Symphony commands is unknown, so nothing
        // is sent to one unprompted.
        guard connectedUnit == nil else {
            print("[Maestro] syncDeviceSettings: skipped — connected unit is not a Symphony I/O")
            return
        }
        let replay: DeviceSettingsReplay
        if let tb = device as? ThunderboltDeviceConnection {
            if cardLayout.slot2 == .micPre8 {
                let link = await Task.detached(priority: .utility) { tb.linkState() }.value
                // The read suspends the main actor. Recheck every admission
                // guard before applying a single-unit replay; a converter or
                // two-unit transition must never inherit this target.
                guard unitAIdentity != nil, connectedUnit == nil,
                      connectionMode == .hardware, isHardwareInitialized,
                      !usesTwoUnitReplay, converterSystem == nil,
                      self.device === tb else { return }
                applyPhantomObservations(link)
            }
            replay = await tb.reapplyStoredSettings()
            await replaySavedBoardClock(tb)
            guard self.device === tb else { return }
            // B7: one unit's Loop Sync output, which the driver starts off
            // each session.
            if loopSyncOneUnit {
                await refreshLoopSync()
                guard self.device === tb else { return }
            }
            // The monitor mode is shown outside the Output tab too; start from
            // the saved one rather than the built-in default.
            if let mode = tb.settingsStore.value(
                for: PropertyAddress(selector: .speakerOutputMode))?.asUInt32 {
                speakerOutputMode = mode
            }
        } else if let xpc = device as? XPCDeviceConnection {
            // The monitor mode was applied above (`applySpeakerOutputMode`).
            replay = await xpc.reapplyStoredSettings()
        } else {
            return
        }
        // `MAESTRO_USB_REPLAY_SETTINGS=0` turns this off over USB too.
        var channelReplay = AnalogChannelSettingsReplay.Result()
        if AnalogChannelSettingsReplay.runs(overUSB: device is XPCDeviceConnection,
                                            usbReplayEnabled: XPCDeviceConnection.replaysOnConnect) {
            let inputStates: [InputChannelState] = channelStateStore.load(ChannelStateStore.inputKey) ?? []
            let outputStates: [OutputChannelState] = channelStateStore.load(ChannelStateStore.outputKey) ?? []
            channelReplay = await AnalogChannelSettingsReplay.apply(
                inputs: inputStates,
                outputs: outputStates,
                layout: cardLayout,
                device: device,
                identity: unitAIdentity,
                spacing: device is XPCDeviceConnection ? .milliseconds(25) : nil)
        }
        if channelReplay.applied > 0 || channelReplay.failed > 0 {
            print("[Maestro] syncDeviceSettings: re-applied " + String(channelReplay.applied)
                + " analog channel setting(s)"
                + (channelReplay.skipped == 0 ? "" : ", " + String(channelReplay.skipped) + " already set")
                + (channelReplay.failed == 0 ? "" : ", " + String(channelReplay.failed) + " refused"))
        }
        // The audible half of a saved headphone source: the crosspoint, taken
        // from the output routing as it stands after the routing replay.
        let store = (device as? ThunderboltDeviceConnection)?.settingsStore
            ?? (device as? XPCDeviceConnection)?.settingsStore
        let replaysHeadphones = !(device is XPCDeviceConnection) || XPCDeviceConnection.replaysOnConnect
        // Over USB the restore writes them itself: away from the mixers
        // before any strip, the saved source last (`performUSBRestore`).
        if let store, replaysHeadphones, !usesTwoUnitReplay, !(device is XPCDeviceConnection) {
            let saved: [(SymphonyIOHeadphoneRouting.Headphone, AudioPropertySelector)] =
                [(.headphone1, .headphone1RoutingID), (.headphone2, .headphone2RoutingID)]
            for (headphone, selector) in saved {
                guard let id = store.value(for: PropertyAddress(selector: selector))?.asUInt32 else { continue }
                await HeadphoneCrosspoint.apply(headphone, sourceID: id, device: device,
                                                cachedRoutes: cachedOutputRouteMap(),
                                                transport: transportType ?? .usb, state: self)
            }
        }
        guard replay.applied > 0 || !replay.failed.isEmpty
                || channelReplay.applied > 0 || channelReplay.failed > 0 else { return }
        print("[Maestro] syncDeviceSettings: re-applied \(replay.applied) saved setting(s)"
            + (replay.failed.isEmpty ? "" : ", \(replay.failed.count) refused: \(replay.failed)"))
        // On USB the views read these settings from the hardware, and one that
        // loaded before the replay finished may be showing the unit's
        // pre-replay state. ThunderBridge reads come from the store, which the
        // replay does not change, so there is nothing to re-read there.
        if device is XPCDeviceConnection {
            viewReloadToken = UUID()
        }
    }

    /// Mark hardware as ready for property access.
    /// XPC connection is ready immediately — proxy handles USB init on boot.
    @MainActor
    func initializeHardwareIfNeeded() async {
        guard !hardwareWritesSuspended else { return }
        guard connectionMode == .hardware else { return }
        if transportType == .thunderbolt {
            statusMessage = "Connected via \(connectionShortName)"
        } else {
            statusMessage = "Connected via XPC proxy"
        }
        isHardwareInitialized = true
    }

    /// True while a reconnect is in flight. Coalesces overlapping reconnects: the auto-switch
    /// device-list listener can fire repeatedly during a Thunderbolt flap or a quick unplug/replug,
    /// and two interleaved reconnects would double-install the ASP volume listener and orphan the
    /// software-metering IOProc. The check+set below is atomic (no await between them) on the MainActor.
    var isReconnecting = false
    /// A reconnect was asked for while one was running (a device appeared or
    /// went away meanwhile). It is not dropped: one more runs when the current
    /// one ends. Dropping it once left Maestro "Disconnected" on the old USB
    /// connection after a switch from USB to ThunderBridge (2026-11-22).
    @ObservationIgnored var reconnectRequestedWhileReconnecting = false

    struct PreferredDevice: Sendable {
        let device: CoreAudioDeviceConnection.DiscoveredSymphonyIO
        /// The ThunderBridge connection and verdict already probed while
        /// choosing, so the caller does not open a second user client and read
        /// the link twice. Nil when the choice is USB (the probe was closed).
        let tbConnection: ThunderboltDeviceConnection?
        let tbVerdict: ThunderboltEndpointVerdict?
    }

    /// The unit's front-panel mode decides which transport is real: in a USB
    /// mode the ThunderBridge endpoint never answers, and in Symphony mode the
    /// USB port is a control-only device with no audio class, so no USB
    /// Symphony device exists. Prefer ThunderBridge, but only when its endpoint
    /// is live; with a USB Symphony present and ThunderBridge not answering,
    /// the unit is in a USB mode (2026-10-22: a front-panel switch to USB left
    /// Maestro on "Symphony disconnected" while the system output had correctly
    /// moved to Maestro USB). `.unavailable` can also mean "dext mid-upgrade",
    /// which is why the USB path keeps watching ThunderBridge
    /// (`startThunderboltWatchWhileOnUSB`).
    nonisolated static func preferredDevice(
        in discovered: [CoreAudioDeviceConnection.DiscoveredSymphonyIO]
    ) -> PreferredDevice? {
        guard let tb = discovered.first(where: { $0.transportType == .thunderbolt }) else {
            return discovered.first.map { PreferredDevice(device: $0, tbConnection: nil, tbVerdict: nil) }
        }
        let probe = ThunderboltDeviceConnection(identifier: tb.identifier, audioDeviceID: tb.audioDeviceID,
                        settingsStore: DeviceSettingsStore())
        let verdict = probe.probeEndpoint()
        if !verdict.isLive, let usb = discovered.first(where: { $0.transportType == .usb }) {
            probe.closeDextClient()
            print("[Maestro] ThunderBridge endpoint \(verdict.label) while a USB Symphony is present — the unit is in a USB mode; connecting via USB")
            return PreferredDevice(device: usb, tbConnection: nil, tbVerdict: nil)
        }
        return PreferredDevice(device: tb, tbConnection: probe, tbVerdict: verdict)
    }

    /// Reconnect to hardware (called after toggle-driver.sh, plug-in, or USB reset).
    @MainActor
    func reconnectHardware() async {
        if hardwareSleepState == .validating, connectionMode == .disconnected {
            endWakeValidationForReconnect()
        }
        guard admitConnectionWork() else { return }
        if cardSimulation != nil {
            print("[Maestro] CARD SIMULATION: reconnect ignored — session pinned to the simulated unit")
            return
        }
        if isReconnecting { reconnectRequestedWhileReconnecting = true; return }
        isReconnecting = true
        let reconnectGeneration = wakeValidationGeneration
        defer {
            isReconnecting = false
            if reconnectGeneration != wakeValidationGeneration {
                reconnectRequestedWhileReconnecting = false
                reconnectRequestedWhileSuspended = true
                replaySuspendedReconnectIfNeeded()
            } else if reconnectRequestedWhileReconnecting {
                reconnectRequestedWhileReconnecting = false
                Task { @MainActor [weak self] in await self?.reconnectHardware() }
            }
        }
        stopThunderboltHealthCheck()
        thunderboltWatchTask?.cancel()
        stopMeterPolling()
        // Test seam. Mirrors the real path's cancellation early return below, so
        // a reconnect that runs inside a cancelled task fails the tests too.
        if let reconnectOperation { guard !Task.isCancelled else { return }; await reconnectOperation(); return }
        // Rebuild the AUDIO path too, not just the app's link to the proxy.
        //
        // Reconnecting the app re-establishes app<->proxy and clears stale
        // meters. But audio flows proxy<->hardware, so if the proxy's AudioUnit
        // is bound to a device that has gone away or re-enumerated with a new
        // ID, none of that helps -- which is exactly what a user hits after a
        // replug, and why this button appeared to do nothing. Asking the proxy
        // to rebuild re-resolves the device, re-coerces the sample rate and
        // re-anchors the clock.
        if let xpcDev = device as? XPCDeviceConnection {
            xpcDev.resetAudioOutput()
        }

        let identifyAOff = identifyA.reset()
        let identifyBOff = identifyB.reset()
        await identifyAOff.value
        await identifyBOff.value
        guard admitConnectionWork(generation: reconnectGeneration), !Task.isCancelled else { return }

        // Close existing connection if any
        if let existing = device {
            await existing.disconnect()
        }
        stopASPVolumeSync()
        stopMicPreDAWSync()
        meterDevice = nil

        statusMessage = "Scanning for hardware..."
        connectionMode = .disconnected
        isHardwareInitialized = false

        // Clear meter values carried over from the previous connection. The mixer/digital
        // meter arrays and peak-holds are only written+decayed on the XPC (USB) branch of
        // startMeterPolling; on Thunderbolt nothing resets them. Without this, e.g. SW Return
        // levels captured while on USB stay frozen (permanently lit) after an auto-switch to
        // ThunderBridge, which has no writer for these. Preserve sizes to avoid index shifts.
        // (Fable review 2026-07-14; screenshot showed a stuck-green SW Return meter on TB.)
        mixerMeterLevels = Array(repeating: -60.0, count: mixerMeterLevels.count)
        digitalInputMeterLevels = Array(repeating: -60.0, count: digitalInputMeterLevels.count)
        digitalOutputMeterLevels = Array(repeating: -60.0, count: digitalOutputMeterLevels.count)
        digitalInputPeakHold = Array(repeating: -60.0, count: digitalInputPeakHold.count)
        digitalOutputPeakHold = Array(repeating: -60.0, count: digitalOutputPeakHold.count)
        inputMeterLevels = Array(repeating: -60.0, count: inputMeterLevels.count)
        outputMeterLevels = Array(repeating: -60.0, count: outputMeterLevels.count)
        inputPeakHold = Array(repeating: -60.0, count: inputPeakHold.count)
        outputPeakHold = Array(repeating: -60.0, count: outputPeakHold.count)
        // A new connection gets a fresh verdict on whether the firmware returns
        // output meter data over USB.
        tdmOutputMeteringUnavailable = false
        tdmOutputEchoStreak = 0
        tdmOutputReplyLogged = false
        usbUnitMixerMetersSeen = false
        lastMeterPollWantedOutput = nil

        // Retry discovery with delays — XMOS firmware needs time to re-enumerate
        for attempt in 1...5 {
            guard admitConnectionWork(generation: reconnectGeneration), !Task.isCancelled else { return }
            // Off the main thread (0.9.8): a slow Core Audio must not freeze the window.
            let discovered = await Task.detached(priority: .userInitiated) {
                CoreAudioDeviceConnection.discoverAllSymphonyIO()
            }.value
            guard admitConnectionWork(generation: reconnectGeneration), !Task.isCancelled else { return }
            let preferred = await Task.detached(priority: .utility) { Self.preferredDevice(in: discovered) }.value
            guard admitConnectionWork(generation: reconnectGeneration), !Task.isCancelled else { return }
            if let pref = preferred {
        let best = pref.device
                let audioDeviceID = best.audioDeviceID
                let identifier = best.identifier
                print("[Maestro] reconnect: Found \(best.name) via \(best.transportType.displayName)")

                if best.transportType == .thunderbolt {
                    let tbDevice = pref.tbConnection ?? ThunderboltDeviceConnection(identifier: identifier, audioDeviceID: audioDeviceID,
                        settingsStore: DeviceSettingsStore())
                    self.device = tbDevice
                    // Probe before declaring the endpoint ready. A powered-off
                    // Symphony can still be discoverable as a ThunderBridge
                    // Core Audio object, but its dext timing-health selector
                    // now performs the serialized live XLink check.
                    let reconnectProbe: ThunderboltEndpointVerdict
                    if let verdict = pref.tbVerdict { reconnectProbe = verdict }
                    else { reconnectProbe = await Task.detached(priority: .utility) { tbDevice.probeEndpoint() }.value }
                    guard admitConnectionWork(generation: reconnectGeneration), !Task.isCancelled else { return }
                    guard case .live(let health) = reconnectProbe else {
                        Self.tbLog.notice("reconnect: endpoint \(reconnectProbe.label, privacy: .public) — staying disconnected, health loop continues")
                        // Remember the Core Audio object so a later cable pull is
                        // recognised as a removal even in this disconnected state.
                        self.activeAudioDeviceID = audioDeviceID
                        self.connectionMode = .disconnected
                        self.invalidateUnitAIdentity()
                        self.invalidateUnitBIdentity()
                        self.unitBIdentityAttempted = false
                        self.transportType = .thunderbolt
                        self.transportPresent = true
                        self.statusMessage = "Symphony disconnected"
                        self.isHardwareInitialized = false
                        self.thunderboltHardwareResponsive = false
                        self.clearMeterState()
                        self.startThunderboltHealthCheck()
                        self.viewReloadToken = UUID()
                        return
                    }
                    // A Symphony that has just powered up over ThunderBridge is
                    // given a moment before Maestro writes saved settings and
                    // routes to it, for the same reason as over USB: nothing
                    // Maestro sends is urgent, and a unit that is still starting
                    // is the wrong moment for a burst of commands. The driver
                    // has already configured the link by the time it reports
                    // the endpoint live.
                    if self.awaitingSymphonyReturn {
                        self.statusMessage = "Waiting for the Symphony to finish starting…"
                        try? await Task.sleep(for: Self.thunderboltSettleInterval)
                    }
                    guard admitConnectionWork(generation: reconnectGeneration), !Task.isCancelled else { return }
                    self.awaitingSymphonyReturn = false
                    self.thunderboltHardwareResponsive = true
                    self.connectionMode = .hardware
                    self.transportType = .thunderbolt
                    self.transportPresent = true
                    self.statusMessage = "Connected via \(self.connectionShortName)"
                    self.isHardwareInitialized = !hardwareWritesSuspended
                    self.activeAudioDeviceID = audioDeviceID
                    self.aspDeviceID = audioDeviceID
                    print("[Maestro] reconnect TB timing health: rate=\(health.sampleRate) frame=\(health.frameReadback)/\(health.expectedFrame) latency=\(health.inputLatency)/\(health.outputLatency) safety=\(health.inputSafety)/\(health.outputSafety) int=0x\(String(health.intStatus, radix: 16)) xlink=0x\(String(health.xlinkStatus, radix: 16))")
                    self.applyPendingAutoSwitch()
                } else {
                    // Nothing is sent to a unit that is still starting up.
                    await waitForUSBUnitToSettle()
                    guard admitConnectionWork(generation: reconnectGeneration), !Task.isCancelled else { return }
                    let xpcDevice = XPCDeviceConnection(identifier: identifier,
                        settingsStore: DeviceSettingsStore())
                    self.device = xpcDevice
                    self.connectionMode = .hardware
                    self.transportType = .usb
                    self.transportPresent = true
                    self.statusMessage = "Connected via USB"
                    self.isHardwareInitialized = true
                    self.activeAudioDeviceID = audioDeviceID
                    self.applyPendingAutoSwitch()
                    self.startThunderboltWatchWhileOnUSB(discovered)

                    // Mixer restoration follows identity resolution.
                }

                // Read card types and sync routing (USB-specific but harmless for TB)
                await self.readCardTypes()
                await self.reapplyDigitalSettings()
                await self.refreshChannelNaming()
                // Over ThunderBridge the output table goes first and card
                // mixer writes are held until it is on the card; over USB the
                // ordered restore (mixers first, output routing last).
                await self.syncSavedStateToHardware()

                guard admitConnectionWork(generation: reconnectGeneration), !Task.isCancelled else { return }
                let meterCA = CoreAudioDeviceConnection(identifier: identifier, audioDeviceID: audioDeviceID)
                if Self.softwareMeteringOptedIn { meterCA.startSoftwareMetering() }
                self.meterDevice = meterCA

                suppressMacVolumeOverlay()
                startASPVolumeSync()

                // Own the polling lifecycle here rather than relying on the view's
                // isHardwareInitialized observer. A reconnect can go true -> false
                // -> true before SwiftUI observes it, including a cold offline
                // launch. Start only after the new meter connection is installed.
                startMeterPolling()
                if transportType == .thunderbolt {
                    startThunderboltHealthCheck()
                    // D5: a stored task; this pipeline does not wait for it.
                    syncCardMixerToHardware()
                }

                // Every value the panels are showing was read over the connection we
                // just tore down, so force them to re-read. Device Info is the visible
                // case: it resolves board types with its own live 0xA1 read, and
                // without this Rescan left it reporting "(cached -- not detected this
                // session)" even after `readCardTypes()` above had just read both
                // slots back off the hardware.
                viewReloadToken = UUID()
                if initialSetupRestoreFinished { scheduleRecentSetupRecall() }
                return
            }

            if attempt < 5 {
                statusMessage = "Scanning for hardware (attempt \(attempt)/5)..."
                try? await Task.sleep(for: .seconds(2))
            }
        }
        statusMessage = "No hardware found"
        connectionMode = .disconnected
        transportType = nil
        transportPresent = false
        activeAudioDeviceID = nil
    }

    /// Build the in-memory device for a session with no hardware.
    ///
    /// With a card-simulation request, `SimulatedDevice.symphonyIO(configuration:)`
    /// publishes the `0xA1` board-type properties, sizes the channel scoping to
    /// the modules and installs mic-pre controls only where a preamp exists.
    /// Without one, the historical plain 16ch unit.
    private static func makeSimulatedDevice(configuration: CardConfiguration?) -> SimulatedDevice {
        if let configuration,
           let configured = try? SimulatedDevice.symphonyIO(configuration: configuration) {
            print("[Maestro] CARD SIMULATION: simulated device presenting "
                  + "\(configuration.slot1.productName) + \(configuration.slot2.productName)")
            return configured
        }
        return SimulatedDevice.symphonyIO16ch()
    }

    /// Switch to simulated device.
    func useSimulatedDevice() {
        let simDevice = AppState.makeSimulatedDevice(configuration: cardSimulation)
        self.device = simDevice
        self.connectionMode = cardSimulation != nil ? .simulated : .disconnected
        self.statusMessage = AppState.simulatedStatusMessage(configuration: cardSimulation)
    }

    /// Start polling real-time meter data from the hardware.
    /// Polls input and output meters at ~33ms intervals (~30 fps).
    @MainActor
    func startMeterPolling() {
        guard !hardwareWritesSuspended else { return }
        meterPollingTask?.cancel()
        refreshSoftwareReturnMeterGains()
        // Use actual stream-derived channel count when available (inputMeterStreamCount × 8).
        // Falls back to identifier.mode.channelCount which is the USB audio class channel count.
        // The stream count reflects actual hardware routing channels (e.g. 32 for 4-stream device).
        // When using XPC path, meterDevice provides CoreAudio metering independently.
        let caDev = (device as? CoreAudioDeviceConnection) ?? meterDevice
        let inChCount = (caDev?.inputMeterChannelCount ?? 0) > 0
            ? caDev!.inputMeterChannelCount
            : (device?.identifier.mode.channelCount ?? 16)
        let outChCount = (caDev?.outputMeterChannelCount ?? 0) > 0
            ? caDev!.outputMeterChannelCount
            : (device?.identifier.mode.channelCount ?? 16)
        if inputMeterLevels.count != inChCount {
            inputMeterLevels = Array(repeating: -60.0, count: inChCount)
        }
        if outputMeterLevels.count != outChCount {
            outputMeterLevels = Array(repeating: -60.0, count: outChCount)
        }
        if inputPeakHold.count != inChCount {
            inputPeakHold = Array(repeating: -60.0, count: inChCount)
        }
        if outputPeakHold.count != outChCount {
            outputPeakHold = Array(repeating: -60.0, count: outChCount)
        }
        meterPollingTask = Task { @MainActor [weak self] in
            // One-shot diagnostic: log per-stream meter peaks 3s after start.
            // Helps identify which NonCA stream IDs carry input vs output signal.
            // Play audio and send analog input before this fires to see non-silent streams.
            let diagCaDev = (self?.device as? CoreAudioDeviceConnection) ?? self?.meterDevice
            if let diagCaDev {
                nonisolated(unsafe) let diagDev = diagCaDev
                Task.detached(priority: .background) {
                    try? await Task.sleep(for: .seconds(3))
                    diagDev.logMeterDiagnostics()
                }
            }

            var pollCount = 0
            var displayedUnitOutputStamp = Date.distantPast
            // The poll count starts again here, so the maps stamped with the
            // last task's count are read again at once.
            if let self {
                self.softwareOutputRoutesPollStamp = -1
                self.thunderboltInputMeterWordsPollStamp = -1
                self.thunderboltOutputMeterWordsPollStamp = -1
                self.unitBOutputMeterWordsPollStamp = -1
            }
            while !Task.isCancelled {
                guard let self, let device = self.device, self.isHardwareInitialized else {
                    try? await Task.sleep(for: .milliseconds(100))
                    continue
                }
                // Hardware TDM metering via XPC (command 0x30) — reads directly from
                // FPGA meter taps. Provides both input AND output levels. More accurate
                // than software metering and shows output from all audio clients.
                var over: [DisplayMeterBank: Set<Int>] = [:]
                var newInput: [Double]
                var newOutput: [Double]
                if self.tdmMeteringAvailable, let xpcDev = device as? XPCDeviceConnection {
                    do {
                        // Poll ONLY the routing group the visible page needs.
                        //
                        // The FPGA has two meter routing states: Output, and
                        // InputAndMixer (groups 0 and 2 share it). The firmware
                        // refreshes its meter buffer ONLY when the routing did
                        // not change since the last request
                        // (SymphonyIOMeterManager.cpp:158-163), and a routing
                        // change zeroes the buffer outright (:204-207).
                        //
                        // We used to read input -> output -> mixer every 50 ms,
                        // which flips the routing on essentially every request.
                        // The refresh was therefore skipped almost every time and
                        // we got back a just-zeroed buffer -- or worse, whatever
                        // the shared packet buffer last held, since the firmware
                        // ships the reply even when it declines to fill it
                        // (SymphonyIOCore3MainController.cpp:2290). That is why
                        // meters showed signal on channels with nothing playing,
                        // and why this loop needed a "skip zero reads" workaround.
                        //
                        // Legacy fetched one routing group per cycle and paired
                        // mixer only with input, for exactly this reason
                        // (SymphonyIO.cpp:6904-7038). Do the same, keyed on what
                        // is actually on screen.
                        let wantsOutput = (self.selectedArea == .output)
                        // Hardware output/mixer groups are requested only until
                        // they have been proven absent for this connection.
                        //
                        // MEASURED 2026-09-10: on the dev unit the group-1/2
                        // replies are not meter data at all. The XMOS EP0 handler
                        // ships the host's full wLength from an uninitialised
                        // stack buffer no matter how few bytes the Core3 returned
                        // (SymphonyIOVendorSpecifics.xc:15,60,109-113); bytes
                        // 32-39 are the request's own setup packet and bytes
                        // 12-31 are identical across unrelated commands. No
                        // polling cadence changes that -- it survived 12+
                        // consecutive same-group reads. Group 0 IS filled by the
                        // Core3 (64 zero bytes when silent), so inputs stay on
                        // hardware metering.
                        let hwOutputUsable = !self.tdmOutputMeteringUnavailable
                        // A change of meter routing state (Output <-> InputAndMixer)
                        // makes the firmware skip its refresh and hand back its
                        // zeroed buffer -- "phantom values from the previous
                        // routing for a few samples" (SymphonyIOMeterManager.cpp:159-163).
                        // Everything read on the switching cycle is discarded.
                        let routingSwitched = (self.lastMeterPollWantedOutput != wantsOutput)
                        self.lastMeterPollWantedOutput = wantsOutput

                        var inVal: PropertyValue? = nil
                        var outVal: PropertyValue? = nil
                        var mixVal: PropertyValue? = nil

                        if wantsOutput {
                            if hwOutputUsable {
                                outVal = try await xpcDev.getProperty(
                                    PropertyAddress(selector: .meterData, scope: .output))
                                // Residue check before anything else looks at the bytes.
                                if case .data(let reply)? = outVal, !self.tdmOutputReplyLogged, !routingSwitched {
                                    self.tdmOutputReplyLogged = true
                                    print("[MeterPoll] USB output meter reply (first of this connection, \(reply.count) bytes): "
                                        + reply.map { String(format: "%02x", $0) }.joined(separator: " "))
                                }
                                if case .data(let outBytes)? = outVal,
                                   TDMMeterPayload.isSetupPacketEcho(outBytes, group: 1, requestLength: 64) {
                                    outVal = nil
                                    self.tdmOutputEchoStreak += 1
                                    if self.tdmOutputEchoStreak >= 3 {
                                        self.tdmOutputMeteringUnavailable = true
                                        print("[MeterPoll] Output TDM payload is the echoed request (XMOS EP0 stack residue) on \(self.tdmOutputEchoStreak) consecutive reads -- firmware returns no output/mixer meter data over USB. Using software output meters; groups 1/2 will not be requested again on this connection.")
                                    }
                                } else {
                                    self.tdmOutputEchoStreak = 0
                                }
                            }
                        } else {
                            // Input and mixer share the InputAndMixer routing
                            // state, so reading both in one cycle costs nothing:
                            // the routing does not change between them, which is
                            // precisely what lets the second read see a refresh.
                            inVal = try await xpcDev.getProperty(
                                PropertyAddress(selector: .meterData, scope: .input))
                            if hwOutputUsable {
                                mixVal = try await xpcDev.getProperty(
                                    PropertyAddress(selector: .meterData, scope: .global))
                            }
                        }
                        if routingSwitched {
                            inVal = nil; outVal = nil; mixVal = nil
                        }
                        // One proxy round-trip per cycle for software peaks: the
                        // render callback sees every sample sent to the device.
                        // Reading resets the proxy's accumulators, so this is the
                        // only software-meter call in the cycle; SW Return L/R are
                        // channels 0/1 of it.
                        let softwareOutputPeaks = await xpcDev.getSoftwareOutputPeaks()
                        // USB recovery detection: if we were disconnected and reads now succeed,
                        // the FPGA has been power-cycled and mixer state needs re-syncing.
                        if self.meterPollWasDisconnected {
                            self.meterPollWasDisconnected = false
                            // The unit's mixers are back at 0 dB, unmuted:
                            // no mixer is routed until the restore has
                            // written them again.
                            self.usbMixersWritten = nil
                            self.usbSettingsRestored = nil
                            self.tdmMeteringAvailable = true
                            // Re-evaluate the firmware's output-meter verdict after
                            // a power-cycle rather than trusting the old latch.
                            self.tdmOutputMeteringUnavailable = false
                            self.tdmOutputEchoStreak = 0
                            self.usbUnitMixerMetersSeen = false
                            self.tdmOutputReplyLogged = false
                            self.lastMeterPollWantedOutput = nil
                            if self.unitAIdentityState == .pending {
                                Task { await self.readCardTypes() }
                            }
                            let now = Date()
                            if self.usbRecoveryRestoreDueOrOwed(now: now) {
                                self.lastRecoveryTime = now
                                // The unit comes back at 0 dB, unmuted, with its
                                // routing, speaker mode and mixer at defaults, so
                                // all of it is put back, always: the original restored a
                                // returning unit's settings without asking
                                // (SymphonyIO::ApplySettingsToHardware), and the
                                // "Restore my mixer after a USB reconnect" switch
                                // that used to make part of this optional is gone.
                                // Like the reconnect path, leave a unit that has just
                                // appeared alone until it has settled.
                                let recoveryMixer = self.lastSelectedMixer
                                Task { @MainActor [weak self] in
                                    guard let self, self.device === xpcDev else { return }
                                    let generation = self.unitAGeneration
                                    let restoreGenerationAtStart = self.usbIdentityRestoreGeneration
                                    // A failed connect already consumed its initial restore.
                                    // Retry identity before this ordinary recovery restore.
                                    self.retryFailedIdentityOnRecovery()
                                    if self.unitAIdentityState == .pending { await self.readCardTypes() }
                                    guard self.device === xpcDev, self.unitAGeneration == generation else { return }
                                    // Identity discovery owns the first restore. If this
                                    // recovery joined that pending discovery, do not replay
                                    // the mixer a second time.
                                    if restoreGenerationAtStart != self.usbIdentityRestoreGeneration { return }
                                    do {
                                        let wait = Self.usbSettleRemaining(
                                            appearedAt: self.symphonyAppearedAt, now: Date())
                                        if wait > 0 {
                                            try? await Task.sleep(for: .milliseconds(Int(wait * 1000)))
                                        }
                                    }
                                    guard self.device === xpcDev, self.unitAGeneration == generation, !Task.isCancelled,
                                          self.mixerPreferences.isWritable else { return }
                                    await self.restoreUSBMixerAfterRecovery(xpcDev, helperMixer: recoveryMixer)
                                }
                                self.deviceRecoveryCount += 1
                                print("[Maestro] USB recovery detected — re-syncing mixer state (count: \(self.deviceRecoveryCount))")
                            }
                        }
                        // A USB restore that did not finish, or a helper that
                        // restarted under the app, is put right here.
                        self.serviceUSBRestore(xpcDev)
                        // The volume keys' output, where the helper now
                        // answering has not been told it.
                        await self.serviceKeyboardVolumeOutput()
                        // FPGA meter registers return all-zero when no new data is ready.
                        // Real data arrives ~3Hz (every ~300ms). All-zero means "no update" —
                        // NOT silence. Skip zero reads to hold the last valid meter values.
                        // After 20+ consecutive zero reads (~1s), start decaying toward silence
                        // so meters don't hang when signal truly stops.
                        let inHasData: Bool
                        if let inVal, case .data(let inBytes) = inVal,
                           !inBytes.allSatisfy({ $0 == 0 }) {
                            let analog = self.tdmMeterReadings(from: inBytes, count: self.inputMeterLevels.count,
                                                               isInput: true)
                            newInput = analog.map(\.level)
                            let digital = TDMMeterPayload.digitalReadings(inBytes, layout: self.cardLayout,
                                                                         isInput: true)
                            self.digitalInputMeterLevels = self.smoothMeterLevels(
                                self.digitalInputMeterLevels, raw: digital.map(\.level))
                            over[.input] = Self.overChannels(analog)
                            over[.digitalInput] = Self.overChannels(digital)
                            inHasData = true
                        } else {
                            newInput = self.inputMeterLevels
                            inHasData = false
                        }
                        let outHasData: Bool
                        if let outVal, case .data(let outBytes) = outVal,
                           !outBytes.allSatisfy({ $0 == 0 }) {
                            let analog = self.tdmMeterReadings(from: outBytes, count: self.outputMeterLevels.count,
                                                               isInput: false)
                            newOutput = analog.map(\.level)
                            let digital = TDMMeterPayload.digitalReadings(outBytes, layout: self.cardLayout,
                                                                         isInput: false)
                            self.digitalOutputMeterLevels = self.smoothMeterLevels(
                                self.digitalOutputMeterLevels, raw: digital.map(\.level))
                            over[.output] = Self.overChannels(analog)
                            over[.digitalOutput] = Self.overChannels(digital)
                            outHasData = true
                        } else {
                            newOutput = self.outputMeterLevels
                            outHasData = false
                        }
                        // Software output meters once the hardware group is known
                        // to be residue: each output shows the level of the source
                        // the app routed to it, exactly as the firmware's own taps
                        // would (SymphonyIOAudioRouteManager.cpp:672-715), using
                        // the proxy's per-USB-channel peaks as the source levels.
                        // Updated on every page so Input/Output tab bars stay live.
                        var softwareOutputApplied = false
                        if !hwOutputUsable, let peaks = softwareOutputPeaks {
                            self.refreshSoftwareOutputRoutesIfNeeded(pollCount: pollCount)
                            newOutput = self.softwareOutputLevels(peaks: peaks, count: self.outputMeterLevels.count)
                            self.digitalOutputMeterLevels = self.smoothMeterLevels(
                                self.digitalOutputMeterLevels,
                                raw: self.softwareDigitalOutputLevels(peaks: peaks))
                            softwareOutputApplied = true
                        }
                        // Track consecutive zero HARDWARE reads to detect when signal
                        // stops. Software output levels are authoritative and do not
                        // feed this counter -- otherwise a live software path would
                        // keep silent hardware inputs from ever decaying.
                        if inHasData || outHasData {
                            self.tdmZeroReadCount = 0
                        } else {
                            self.tdmZeroReadCount += 1
                            // After ~1s of all-zero reads (20 × 50ms), decay held values
                            if self.tdmZeroReadCount > 20 {
                                let silence = [Double](repeating: -60.0, count: newInput.count)
                                newInput = silence
                                if !softwareOutputApplied {
                                    let silenceOut = [Double](repeating: -60.0, count: newOutput.count)
                                    newOutput = silenceOut
                                }
                            }
                        }
                        // Mixer TDM meters (group 2) — SW Return + Master per mixer.
                        // Already fetched above alongside input when the visible
                        // page needs them; only the first 8 words are meaningful
                        // regardless of the length the firmware reports.
                        if let mixVal, case .data(let mixBytes) = mixVal,
                           !mixBytes.allSatisfy({ $0 == 0 }) {
                            let readings = TDMMeterPayload.mixerReadings(mixBytes)
                            var rawMixer = readings.map(\.level)
                            over[.mixer] = Self.overChannels(readings)
                            if !self.usbUnitMixerMetersSeen {
                                self.usbUnitMixerMetersSeen = true
                                print("[MeterPoll] USB: the unit reports mixer meters; Software Return and Master meters read from it. First reply: "
                                    + mixBytes.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " "))
                            }
                            // The unit's Software Return words are taken
                            // before the strip's fader and mute: with
                            // Pre-Mute Metering off, show what the strip
                            // passes on, as the input strips do.
                            if rawMixer.count >= 4 {
                                for mixer in 0..<2 {
                                    let trim = self.softwareReturnMeterGains[mixer]
                                    for (slot, gain) in [(mixer * 2, trim.left), (mixer * 2 + 1, trim.right)] {
                                        rawMixer[slot] = gain <= 0 ? -60.0 : max(-60.0, rawMixer[slot] + 20.0 * log10(gain))
                                    }
                                }
                            }
                            self.mixerMeterLevels = self.smoothMeterLevels(self.mixerMeterLevels, raw: rawMixer)
                        } else if self.tdmZeroReadCount > 20 {
                            let silenceMix = [Double](repeating: -60.0, count: 8)
                            self.mixerMeterLevels = self.smoothMeterLevels(self.mixerMeterLevels, raw: silenceMix)
                        }

                        // Software return meters — measured in proxy render callback.
                        // TDM group 2 does NOT contain SW Return levels without
                        // FPGA meter tap configuration (which requires XLink register
                        // writes, not possible via USB EP0).
                        // Only until the unit has shown it reports these itself.
                        if !self.usbUnitMixerMetersSeen, let peaks = softwareOutputPeaks, peaks.count >= 2 {
                            // Each mixer can select a different USB playback pair through
                            // AEsR.  The proxy reports one peak pair per USB pair, so do
                            // not mirror channels 0/1 into both mixer strips.
                            func softwareReturnPeaks(mixer: Int) -> (Float, Float) {
                                let source = self.mixerPreferences.integer(forKey: "mixerSoftwareReturnSource_\(mixer)")
                                let left = source * 2
                                guard left >= 0, left + 1 < peaks.count else { return (0, 0) }
                                return (peaks[left], peaks[left + 1])
                            }
                            let mixer0Linear = softwareReturnPeaks(mixer: 0)
                            let mixer1Linear = softwareReturnPeaks(mixer: 1)
                            let mixer0Peaks = (SoftwareOutputMeterMap.dBFS(linearPeak: mixer0Linear.0),
                                               SoftwareOutputMeterMap.dBFS(linearPeak: mixer0Linear.1))
                            let mixer1Peaks = (SoftwareOutputMeterMap.dBFS(linearPeak: mixer1Linear.0),
                                               SoftwareOutputMeterMap.dBFS(linearPeak: mixer1Linear.1))

                            // Slots [0..1] = Mixer 0 SW Return L/R, [2..3] = Mixer 1 SW Return L/R.
                            if self.mixerMeterLevels.count >= 4 {
                                // Software peaks arrive from the proxy render callback and are
                                // reset on every read.  Do not assign them directly: unlike the
                                // TDM path, that made SW Return flash between callback windows
                                // while Master used the normal meter decay.  Keep the same
                                // snap-up/decay contract for every mixer meter source.
                                let swL0 = self.smoothMeterLevels([self.mixerMeterLevels[0]], raw: [mixer0Peaks.0])[0]
                                let swR0 = self.smoothMeterLevels([self.mixerMeterLevels[1]], raw: [mixer0Peaks.1])[0]
                                let swL1 = self.smoothMeterLevels([self.mixerMeterLevels[2]], raw: [mixer1Peaks.0])[0]
                                let swR1 = self.smoothMeterLevels([self.mixerMeterLevels[3]], raw: [mixer1Peaks.1])[0]
                                self.mixerMeterLevels[0] = swL0
                                self.mixerMeterLevels[1] = swR0
                                self.mixerMeterLevels[2] = swL1
                                self.mixerMeterLevels[3] = swR1
                            }
                            // Blend SW Return into Master meter (slots [4..7]).
                            // The helper's peaks are taken before the unit's
                            // mixer, so each mixer's part goes through that
                            // mixer's Software Return fader and mute and its
                            // Master fader first (USBMasterMeter).
                            if self.mixerMeterLevels.count >= 8 {
                                let gains = self.usbMasterMeterGains
                                self.mixerMeterLevels[4] = USBMasterMeter.level(
                                    unitMaster: self.mixerMeterLevels[4], softwareReturnPeak: mixer0Linear.0, gain: gains[0])
                                self.mixerMeterLevels[5] = USBMasterMeter.level(
                                    unitMaster: self.mixerMeterLevels[5], softwareReturnPeak: mixer0Linear.1, gain: gains[0])
                                self.mixerMeterLevels[6] = USBMasterMeter.level(
                                    unitMaster: self.mixerMeterLevels[6], softwareReturnPeak: mixer1Linear.0, gain: gains[1])
                                self.mixerMeterLevels[7] = USBMasterMeter.level(
                                    unitMaster: self.mixerMeterLevels[7], softwareReturnPeak: mixer1Linear.1, gain: gains[1])
                            }
                        }
                    } catch {
                        // TDM reads failed — mark disconnected for recovery detection.
                        // Don't permanently disable TDM; retry each cycle so we detect
                        // when USB recovers (XPC fails fast when USB is down).
                        if !self.meterPollWasDisconnected {
                            print("[MeterPoll] TDM metering failed, tracking for recovery: \(error)")
                        }
                        self.meterPollWasDisconnected = true
                        newInput = self.inputMeterLevels
                        newOutput = self.outputMeterLevels
                    }
                } else if let tbDev = device as? ThunderboltDeviceConnection {
                    // ThunderBridge can remain present on the PCIe link after the
                    // Symphony is powered down. In that state the FPGA meter DMA
                    // buffer stops advancing but still contains the last coherent
                    // frame, which otherwise looks like live input forever. Core
                    // Audio's running-state property is the authoritative cheap
                    // guard: no active I/O cycle means no fresh meter frame.
                    let tbAudioRunning = tbDev.isAudioRunning == true
                    // A DriverKit handoff can leave the outgoing dext carrying
                    // audio while the new registration is not yet probeable.
                    // Keep the host-side meter usable during that bounded window,
                    // but never do so when Core Audio has stopped the device.
                    // The window is the health loop's ExtensionSwapGrace. This
                    // used to re-read sysextd's database on every 33 ms poll and
                    // treated a lingering terminating record as a permanent
                    // exception, which kept stale meters moving with the
                    // Symphony powered off.
                    let extensionSwapPending = self.thunderboltExtensionSwapGraceActive
                    let allowMeterRead = tbAudioRunning &&
                        (self.thunderboltHardwareResponsive || extensionSwapPending)
                    self.pollUnitOutputMetersIfNeeded(pollCount: pollCount, device: tbDev)
                    let words: [UInt32]?
                    if !allowMeterRead {
                        words = nil
                    } else {
                        words = tbDev.readMeters()
                    }
                    if let words {
                        // Thunderbolt: real hardware meters from the card FPGA meter DMA.
                        // Word peak = bits[31:24] → dB = 20*log10(peak/256). Layout (legacy):
                        // 0-31 = hardware inputs, 64-95 = host playback, 128-131 = mixer0/1 out.
                        let cardReadings = words.map(MeterReading.card(word:))
                        func reading(_ i: Int) -> MeterReading {
                            cardReadings.indices.contains(i) ? cardReadings[i] : .silence
                        }
                        func dbW(_ i: Int) -> Double { reading(i).level }
                        func isOver(_ i: Int) -> Bool { reading(i).isOver }
                        // Words 0-31 meter host inputs 1-32: what the unit's
                        // capture table sends over XLink, not the device-wide
                        // input order the strips use. Each strip reads the word
                        // of the host input its hardware channel is routed to
                        // (ThunderboltInputMeterMap).
                        self.refreshThunderboltInputMeterWordsIfNeeded(pollCount: pollCount, device: tbDev)
                        var meterWords = self.thunderboltInputMeterWords
                        // Converters are read by bus slot over both ports (64
                        // words); a Symphony I/O keeps host inputs 0-31.
                        let convertersMetered = self.thunderboltInputMeterLayout?.converterLayout != nil
                        var hostInputs = (0..<(convertersMetered ? ThunderboltInputMeterMap.converterWordCount
                                                : ThunderboltInputMeterMap.hostInputCount)).map { dbW($0) }
                        // Each output strip, analog or digital, reads the word
                        // of what Output Routing plays on it: a software output
                        // (64 + n) or a card mixer (128-131).
                        self.refreshThunderboltOutputMeterWordsIfNeeded(pollCount: pollCount, device: tbDev)
                        let outputWords = self.thunderboltOutputMeterWords
                        let unitOutputs = self.freshUnitOutputMeterLevels()
                        let overSources = MeterOverSources.available(
                            card: true, build: self.servingDextBuild, unitOutputsFresh: unitOutputs != nil)
                        if overSources.output, let unitOutputs, self.unitOutputMeterStamp != displayedUnitOutputStamp {
                            displayedUnitOutputStamp = self.unitOutputMeterStamp
                            let isB = self.activeUnit == .b
                            over[isB ? .unitBOutput : .output] = Self.overChannels(unitOutputs.analogReadings)
                            over[isB ? .unitBDigitalOutput : .digitalOutput] = Self.overChannels(unitOutputs.digitalReadings)
                        }
                        if self.activeUnit == .b, let unitOutputs {
                            self.unitBOutputMeterLevels = self.smoothMeterLevels(
                                self.unitBOutputMeterLevels, raw: unitOutputs.analog)
                            self.unitBDigitalOutputMeterLevels = self.smoothMeterLevels(
                                self.unitBDigitalOutputMeterLevels, raw: unitOutputs.digital)
                        }
                        if self.activeUnit == .a, let unitOutputs {
                            // The Symphony's own meters, taken at each output.
                            newOutput = (0..<self.outputMeterLevels.count).map {
                                $0 < unitOutputs.analog.count ? unitOutputs.analog[$0] : -60.0
                            }
                            self.digitalOutputMeterLevels = self.smoothMeterLevels(
                                self.digitalOutputMeterLevels, raw: unitOutputs.digital)
                        } else if let outputWords {
                            newOutput = ThunderboltOutputMeterMap.levels(
                                outputWords.analog, count: self.outputMeterLevels.count, level: dbW)
                            self.digitalOutputMeterLevels = self.smoothMeterLevels(
                                self.digitalOutputMeterLevels,
                                raw: ThunderboltOutputMeterMap.levels(outputWords.digital, level: dbW))
                        } else {
                            // Cards or table not known yet, or converters:
                            // strip i is software output i.
                            var outp = self.outputMeterLevels
                            for i in 0..<outp.count { outp[i] = dbW(64 + i) }
                            newOutput = outp
                        }

                        // If the FPGA input snapshot is unavailable or silent,
                        // use the active Core Audio capture stream. This keeps
                        // Input and Mixer hardware strips useful on cards whose
                        // meter DMA is absent, while preserving real FPGA peaks.
                        // Its channel n is host input n too.
                        if (hostInputs.max() ?? -60.0) <= -60.0,
                           let softwareInputs = self.hardwareSoftwarePeaks(self.meterDevice?.softwareInputPeaks()),
                           !softwareInputs.isEmpty {
                            // Core Audio's channel n is host channel n, not a bus
                            // slot: converter strips read it one to one.
                            if convertersMetered {
                                hostInputs = self.linearMeterLevels(
                                    from: softwareInputs, count: ThunderboltInputMeterMap.converterWordCount)
                                meterWords = ThunderboltInputMeterMap.Words(channels: [], digital: meterWords.digital)
                            } else {
                            hostInputs = self.linearMeterLevels(
                                from: softwareInputs, count: ThunderboltInputMeterMap.hostInputCount)
                            }
                        }
                        // Converters: 32 to 64 channels can change without a
                        // reconnect, so the arrays grow to the host channels in use.
                        if let needed = self.thunderboltInputMeterLayout?.converterLayout?.hostInputCount,
                           self.inputMeterLevels.count < needed {
                            self.inputMeterLevels += [Double](repeating: -60.0, count: needed - self.inputMeterLevels.count)
                            self.inputPeakHold += [Double](repeating: -60.0, count: max(0, needed - self.inputPeakHold.count))
                        }
                        newInput = ThunderboltInputMeterMap.stripLevels(
                            host: hostInputs, words: meterWords, count: self.inputMeterLevels.count)
                        self.digitalInputMeterLevels = self.smoothMeterLevels(
                            self.digitalInputMeterLevels,
                            raw: ThunderboltInputMeterMap.digitalLevels(host: hostInputs, words: meterWords))
                        // Keep the clip flag on the same routed word as the Mixer strip.
                        if overSources.mixer {
                            over[.input] = Self.cardMixerInputOvers(
                                meterWords, count: self.inputMeterLevels.count, isOver: isOver)
                        }
                        // Unit B (64 channels, a second Symphony I/O): its own
                        // strips read words 32-63 and 96-127.
                        over[.unitBInput] = self.updateUnitBMeters(
                            dB: dbW, isOver: isOver, pollCount: pollCount,
                            preferUnitRead: self.activeUnit == .b && unitOutputs != nil)

                        // The FPGA meter DMA is not available on every
                        // ThunderBridge FPGA revision and may be temporarily
                        // unavailable during a dext handoff. Maestro already
                        // has a Core Audio IOProc on this device, so use its
                        // host-playback peaks as a bounded fallback. This is
                        // also the correct source for SW Return because that
                        // strip represents host playback before the card mixer.
                        if let softwarePeaks = self.hardwareSoftwarePeaks(self.meterDevice?.softwareOutputPeaks()),
                           softwarePeaks.count >= 2 {
                            func softwareReturnDBFS(mixer: Int, post: Bool = false) -> (Double, Double) {
                                let source = self.mixerPreferences.integer(forKey: "mixerSoftwareReturnSource_\(mixer)")
                                let left = source * 2
                                guard left >= 0, left + 1 < softwarePeaks.count else {
                                    return (-60.0, -60.0)
                                }
                                // Mirror what the card mixer delivers: USB meters
                                // SW Return after its level and mute, so
                                // apply the same trims to the host-playback peaks
                                // here (SoftwareReturnMeterGain) rather than
                                // showing the pre-mixer signal.
                                let trim = (post ? self.softwareReturnPostFaderGains : self.softwareReturnMeterGains)[min(max(0, mixer), 1)]
                                return (
                                    SoftwareOutputMeterMap.dBFS(linearPeak: softwarePeaks[left] * Float(trim.left)),
                                    SoftwareOutputMeterMap.dBFS(linearPeak: softwarePeaks[left + 1] * Float(trim.right))
                                )
                            }
                            let mixer0Peaks = softwareReturnDBFS(mixer: 0)
                            let mixer1Peaks = softwareReturnDBFS(mixer: 1)
                            // Prefer the software source when the FPGA snapshot
                            // is all silence. Keep real FPGA values when present.
                            if unitOutputs != nil {
                                // The unit's reading stands.
                            } else if let outputWords {
                                // Only when the snapshot carries no playback at
                                // all; otherwise a silent strip is a true reading.
                                if (64..<128).allSatisfy({ dbW($0) <= -60.0 }) {
                                    let software = self.softwarePlaybackWordLevel(softwarePeaks)
                                    newOutput = ThunderboltOutputMeterMap.levels(
                                        outputWords.analog, count: self.outputMeterLevels.count, level: software)
                                    // Assigned, not smoothed again: this poll's
                                    // smoothing above started from the same levels.
                                    let digital = ThunderboltOutputMeterMap.levels(outputWords.digital, level: software)
                                    self.digitalOutputMeterLevels = zip(self.digitalOutputMeterLevels, digital).map(max)
                                }
                            } else if newOutput.max() ?? -60.0 <= -60.0 {
                                newOutput = self.linearMeterLevels(
                                    from: softwarePeaks, count: self.outputMeterLevels.count)
                            }
                            if self.mixerMeterLevels.count >= 4 {
                                var rawMixer = self.mixerMeterLevels
                                rawMixer[0] = max(rawMixer[0], mixer0Peaks.0)
                                rawMixer[1] = max(rawMixer[1], mixer0Peaks.1)
                                rawMixer[2] = max(rawMixer[2], mixer1Peaks.0)
                                rawMixer[3] = max(rawMixer[3], mixer1Peaks.1)
                                if self.mixerMeterLevels.count >= 8 {
                                    let post0 = softwareReturnDBFS(mixer: 0, post: true)
                                    let post1 = softwareReturnDBFS(mixer: 1, post: true)
                                    rawMixer[4] = max(rawMixer[4], post0.0)
                                    rawMixer[5] = max(rawMixer[5], post0.1)
                                    rawMixer[6] = max(rawMixer[6], post1.0)
                                    rawMixer[7] = max(rawMixer[7], post1.1)
                                }
                                self.mixerMeterLevels = self.smoothMeterLevels(
                                    self.mixerMeterLevels, raw: rawMixer)
                            }
                        }
                        // Mixer meters: SW Return (Mix 1) L/R = playback 64/65;
                        // master outputs are two stereo pairs in the FPGA meter
                        // snapshot: mixer 1 at 128/129 and mixer 2 at 130/131.
                        // Keep these on the same smoothing path as the input/output
                        // strips. The FPGA writes the DMA snapshot asynchronously;
                        // assigning these words directly made a one-poll zero or
                        // torn value appear as an intermittent blink in Maestro.
                        if self.mixerMeterLevels.count >= 6 {
                            var rawMixer = self.mixerMeterLevels
                            // Playback words 64/65 are the host signal before the
                            // card mixer's level/pan/mute; apply the strip's trims
                            // so the SW Return meters read as they do on USB.
                            // Each mixer's Software Return meters the pair
                            // chosen in its menu, not always playback 1-2.
                            func trimmed(_ dB: Double, _ gain: Double) -> Double {
                                gain <= 0 ? -60.0 : max(-60.0, dB + 20.0 * log10(gain))
                            }
                            var mixerOvers: Set<Int> = []
                            for mixer in 0..<2 {
                                let trim = self.softwareReturnMeterGains[mixer]
                                let word = SoftwareReturnMeterGain.playbackWord(
                                    source: self.mixerPreferences.integer(forKey: "mixerSoftwareReturnSource_\(mixer)"))
                                rawMixer[mixer * 2] = trimmed(dbW(word), trim.left)
                                rawMixer[mixer * 2 + 1] = trimmed(dbW(word + 1), trim.right)
                                if isOver(word) { mixerOvers.insert(mixer * 2) }
                                if isOver(word + 1) { mixerOvers.insert(mixer * 2 + 1) }
                            }
                            rawMixer[4] = dbW(128); rawMixer[5] = dbW(129)
                            if self.mixerMeterLevels.count >= 8 {
                                rawMixer[6] = dbW(130); rawMixer[7] = dbW(131)
                            }
                            for index in 4..<rawMixer.count where isOver(128 + index - 4) {
                                mixerOvers.insert(index)
                            }
                            if overSources.mixer { over[.mixer] = mixerOvers }
                            self.mixerMeterLevels = self.smoothMeterLevels(
                                self.mixerMeterLevels, raw: rawMixer)
                        }
                        // Keep the SW Return source visible even when the FPGA
                        // snapshot has no mixer tap data. The Core Audio IOProc
                        // measures the same host playback that feeds PCI_OUT.
                        if let softwarePeaks = self.hardwareSoftwarePeaks(self.meterDevice?.softwareOutputPeaks()),
                           softwarePeaks.count >= 2,
                           self.mixerMeterLevels.count >= 4 {
                            func softwareReturnDBFS(mixer: Int, post: Bool = false) -> (Double, Double) {
                                let source = max(0, min(self.softwareReturnPairCount - 1, self.mixerPreferences.integer(forKey: "mixerSoftwareReturnSource_\(mixer)")))
                                let left = source * 2
                                guard left + 1 < softwarePeaks.count else { return (-60.0, -60.0) }
                                // Mirror what the card mixer delivers: USB meters
                                // SW Return after its level and mute, so
                                // apply the same trims to the host-playback peaks
                                // here (SoftwareReturnMeterGain) rather than
                                // showing the pre-mixer signal.
                                let trim = (post ? self.softwareReturnPostFaderGains : self.softwareReturnMeterGains)[min(max(0, mixer), 1)]
                                return (
                                    SoftwareOutputMeterMap.dBFS(linearPeak: softwarePeaks[left] * Float(trim.left)),
                                    SoftwareOutputMeterMap.dBFS(linearPeak: softwarePeaks[left + 1] * Float(trim.right))
                                )
                            }
                            let mix0 = softwareReturnDBFS(mixer: 0)
                            let mix1 = softwareReturnDBFS(mixer: 1)
                            var rawMixer = self.mixerMeterLevels
                            rawMixer[0] = max(rawMixer[0], mix0.0)
                            rawMixer[1] = max(rawMixer[1], mix0.1)
                            rawMixer[2] = max(rawMixer[2], mix1.0)
                            rawMixer[3] = max(rawMixer[3], mix1.1)
                            if rawMixer.count >= 8 {
                                let post0 = softwareReturnDBFS(mixer: 0, post: true)
                                let post1 = softwareReturnDBFS(mixer: 1, post: true)
                                rawMixer[4] = max(rawMixer[4], post0.0)
                                rawMixer[5] = max(rawMixer[5], post0.1)
                                rawMixer[6] = max(rawMixer[6], post1.0)
                                rawMixer[7] = max(rawMixer[7], post1.1)
                            }
                            self.mixerMeterLevels = self.smoothMeterLevels(
                                self.mixerMeterLevels, raw: rawMixer)
                        }
                        // Raw-word diagnostic for empirical mapping confirmation (throttled).
                        if pollCount % 60 == 1 {
                            let nz = words.enumerated()
                                .filter { (($0.element >> 24) & 0xFF) > 4 }
                                .prefix(14)
                                .map { "[\($0.offset)]=\((($0.element) >> 24) & 0xFF)" }
                                .joined(separator: " ")
                            print("[MeterPoll] TB raw nonzero peaks: \(nz.isEmpty ? "(silence)" : nz)")
                        }
                    } else {
                        var softwareDigitalOut: [Double]?
                        // FPGA meter DMA may be unavailable on this card revision.
                        // Preserve useful host-playback meters through the Core
                        // Audio IOProc while the device is actively streaming.
                        if allowMeterRead,
                           let softwarePeaks = self.hardwareSoftwarePeaks(self.meterDevice?.softwareOutputPeaks()),
                           softwarePeaks.count >= 2 {
                            if let softwareInputs = self.hardwareSoftwarePeaks(self.meterDevice?.softwareInputPeaks()),
                               !softwareInputs.isEmpty {
                                // Core Audio channel n is host input n: map it
                                // to the strips as the FPGA words are.
                                self.refreshThunderboltInputMeterWordsIfNeeded(pollCount: pollCount, device: tbDev)
                                if self.thunderboltInputMeterLayout?.converterLayout != nil {
                                    // Converters: host channel n is strip n.
                                    newInput = ThunderboltInputMeterMap.stripLevels(
                                        host: self.linearMeterLevels(
                                            from: softwareInputs, count: ThunderboltInputMeterMap.converterWordCount),
                                        words: ThunderboltInputMeterMap.Words(channels: [], digital: []),
                                        count: self.inputMeterLevels.count)
                                } else {
                                newInput = ThunderboltInputMeterMap.stripLevels(
                                    host: self.linearMeterLevels(
                                        from: softwareInputs, count: ThunderboltInputMeterMap.hostInputCount),
                                    words: self.thunderboltInputMeterWords,
                                    count: self.inputMeterLevels.count)
                                }
                            } else {
                                newInput = [Double](repeating: -60.0, count: self.inputMeterLevels.count)
                            }
                            self.refreshThunderboltOutputMeterWordsIfNeeded(pollCount: pollCount, device: tbDev)
                            if let outputWords = self.thunderboltOutputMeterWords {
                                let software = self.softwarePlaybackWordLevel(softwarePeaks)
                                newOutput = ThunderboltOutputMeterMap.levels(
                                    outputWords.analog, count: self.outputMeterLevels.count, level: software)
                                softwareDigitalOut = ThunderboltOutputMeterMap.levels(outputWords.digital, level: software)
                            } else {
                                newOutput = self.linearMeterLevels(
                                    from: softwarePeaks, count: self.outputMeterLevels.count)
                            }
                            let sources = [0, 1].map { mixer in
                                let pair = max(0, min(self.softwareReturnPairCount - 1, self.mixerPreferences.integer(forKey: "mixerSoftwareReturnSource_\(mixer)"))) * 2
                                guard pair + 1 < softwarePeaks.count else { return (-60.0, -60.0) }
                                return (
                                    SoftwareOutputMeterMap.dBFS(linearPeak: softwarePeaks[pair]),
                                    SoftwareOutputMeterMap.dBFS(linearPeak: softwarePeaks[pair + 1])
                                )
                            }
                            if self.mixerMeterLevels.count >= 4 {
                                var rawMixer = [Double](repeating: -60.0, count: self.mixerMeterLevels.count)
                                rawMixer[0] = sources[0].0; rawMixer[1] = sources[0].1
                                rawMixer[2] = sources[1].0; rawMixer[3] = sources[1].1
                                if self.mixerMeterLevels.count >= 8 {
                                    rawMixer[4] = sources[0].0; rawMixer[5] = sources[0].1
                                    rawMixer[6] = sources[1].0; rawMixer[7] = sources[1].1
                                }
                                self.mixerMeterLevels = self.smoothMeterLevels(
                                    self.mixerMeterLevels, raw: rawMixer)
                            }
                        } else {
                            let silence = [Double](repeating: -60.0, count: self.inputMeterLevels.count)
                            newInput = silence
                            newOutput = [Double](repeating: -60.0, count: self.outputMeterLevels.count)
                            self.mixerMeterLevels = [Double](repeating: -60.0, count: self.mixerMeterLevels.count)
                        }
                        self.inputPeakHold = [Double](repeating: -60.0, count: self.inputPeakHold.count)
                        self.outputPeakHold = [Double](repeating: -60.0, count: self.outputPeakHold.count)
                        self.digitalInputMeterLevels = [Double](repeating: -60.0, count: self.digitalInputMeterLevels.count)
                        self.digitalOutputMeterLevels = softwareDigitalOut.map {
                            self.smoothMeterLevels(self.digitalOutputMeterLevels, raw: $0)
                        } ?? [Double](repeating: -60.0, count: self.digitalOutputMeterLevels.count)
                        self.digitalInputPeakHold = [Double](repeating: -60.0, count: self.digitalInputPeakHold.count)
                        self.digitalOutputPeakHold = [Double](repeating: -60.0, count: self.digitalOutputPeakHold.count)
                    }
                } else if let caDev = (device as? CoreAudioDeviceConnection) ?? self.meterDevice {
                    // Fallback: software metering via CoreAudio IO proc.
                    // Input works (reads ADC samples), output is always -inf.
                    let inputPeaks = await Task.detached(priority: .userInitiated) {
                        caDev.getStreamMeterLevels(isInput: true)
                    }.value
                    let outputPeaks = await Task.detached(priority: .userInitiated) {
                        caDev.getStreamMeterLevels(isInput: false)
                    }.value
                    newInput = self.linearMeterLevels(from: inputPeaks, count: inputPeaks.count > 0 ? inputPeaks.count : self.inputMeterLevels.count)
                    newOutput = self.linearMeterLevels(from: outputPeaks, count: outputPeaks.count > 0 ? outputPeaks.count : self.outputMeterLevels.count)
                } else {
                    newInput = self.inputMeterLevels
                    newOutput = self.outputMeterLevels
                }

                pollCount += 1
                if pollCount % 200 == 1 {
                    let inMax = newInput.max() ?? -60.0
                    let outMax = newOutput.max() ?? -60.0
                    print("[MeterPoll] poll#\(pollCount): in=\(newInput.count)ch maxIn=\(String(format: "%.1f", inMax)) out=\(newOutput.count)ch maxOut=\(String(format: "%.1f", outMax)) tdm=\(self.tdmMeteringAvailable) swOut=\(self.tdmOutputMeteringUnavailable)")
                }
                // Smooth TDM meter levels: snap up immediately on new peaks, decay gradually
                // when readings drop. Prevents "flashing" caused by polling faster (~20fps)
                // than FPGA meter taps update (~25Hz), which returns stale/zero data between
                // firmware refresh cycles.
                self.inputMeterLevels = self.smoothMeterLevels(self.inputMeterLevels, raw: newInput)
                self.outputMeterLevels = self.smoothMeterLevels(self.outputMeterLevels, raw: newOutput)
                self.updateMeterHolds(over: over)
                // 20 fps while the hardware answers; 1 Hz once it stops.
                //
                // Every cycle in the failed state is a round trip that can only
                // fail again, and at 20 fps that is 1,200 a minute. MEASURED
                // 2026-09-13 with the Symphony powered off for four minutes: 4,647
                // `getProperty: USB device not open` lines in the proxy log, which
                // buried the presence and reconnect lines that explain the outage.
                //
                // Recovery is still noticed inside a second, and the re-sync that
                // follows it is debounced at 5 s anyway (`lastRecoveryTime`), so
                // nothing downstream can tell the difference. Meters are already
                // frozen at their last values in this state — there is nothing on
                // screen for the faster cadence to update.
                let idle = self.meterPollWasDisconnected
                try? await Task.sleep(for: .milliseconds(idle ? 1000 : 50))
            }
        }
    }

    /// Smooth meter levels: snap up to new readings, decay at 3 dB/frame on drops.
    /// At 20fps, 3 dB/frame = 60 dB/s → silence in ~1s after signal stops.
    /// Prevents "flashing" from stale FPGA reads between firmware meter update cycles.
    func smoothMeterLevels(_ previous: [Double], raw: [Double]) -> [Double] {
        var result = previous
        for i in 0..<min(previous.count, raw.count) {
            if raw[i] >= previous[i] {
                result[i] = raw[i]  // snap up immediately
            } else {
                result[i] = max(previous[i] - 3.0, raw[i])  // decay 3 dB/frame
            }
        }
        return result
    }

    static func overChannels(_ readings: [MeterReading]) -> Set<Int> {
        Set(readings.indices.filter { readings[$0].isOver })
    }

    static func cardMixerInputOvers(_ words: ThunderboltInputMeterMap.Words, count: Int,
                                   isOver: (Int) -> Bool) -> Set<Int> {
        Set((0..<count).filter { index in
            if words.channels.isEmpty { return isOver(index) }
            guard words.channels.indices.contains(index), let word = words.channels[index] else { return false }
            return isOver(word)
        })
    }

    /// Stop meter polling.
    @MainActor
    func stopMeterPolling() {
        meterPollingTask?.cancel()
        meterPollingTask = nil
        clearDisplayedMeterHolds()
    }

    // MARK: - Front Panel Sync

    private var frontPanelSyncTask: Task<Void, Never>?
    private var lastFrontPanelSpeakerPush: (output: KeyboardVolumeOutput, dB: Double)?

    /// Off only with `MAESTRO_FRONT_PANEL_SYNC=0`.
    static let frontPanelSyncEnabled: Bool =
        ProcessInfo.processInfo.environment["MAESTRO_FRONT_PANEL_SYNC"] != "0"

    /// How often the unit is asked what its front panel is doing. The original
    /// daemon polled continuously; this is deliberately gentle, and still fast
    /// enough that a turning encoder looks live.
    static let frontPanelSyncInterval: Duration = .milliseconds(300)

    /// Keep the on-screen speaker and headphone levels and mutes in step with
    /// the unit's front panel encoder (USB).
    ///
    /// Nothing on the unit notifies the host, so this asks it (`0x28`), as the
    /// original software did; see `FrontPanelSync` for the rules. One task for
    /// the life of the app: it idles while there is no USB unit, never reads a
    /// unit that is still starting up, and backs off when a read fails.
    @MainActor
    func startFrontPanelSync() {
        guard Self.frontPanelSyncEnabled, frontPanelSyncTask == nil else { return }
        frontPanelSyncTask = Task { @MainActor [weak self] in
            var sync = FrontPanelSync()
            var syncB = FrontPanelSync()
            var ownerA: ObjectIdentifier?
            var ownerB: ObjectIdentifier?
            var baselinePending = true
            var baselineBPending = true
            var observationEpoch: (wake: Int, recall: Int)?
            while !Task.isCancelled {
                guard let self else { return }
                guard !self.hardwareWritesSuspended, self.setupRecallDepth == 0,
                      self.connectionMode == .hardware, self.isHardwareInitialized,
                      let device = self.device else {
                    sync.reset(); syncB.reset()
                    baselinePending = true; baselineBPending = true
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                let epoch = (wake: self.wakeValidationGeneration, recall: self.setupRecallRevision)
                if ownerA != ObjectIdentifier(device) || observationEpoch?.wake != epoch.wake
                    || observationEpoch?.recall != epoch.recall {
                    observationEpoch = epoch
                    baselinePending = true; baselineBPending = true
                    sync.reset(); syncB.reset()
                    ownerA = ObjectIdentifier(device); ownerB = nil
                }
                let update: SymphonyIOParameterUpdates?
                let interval: Duration
                if let usb = device as? XPCDeviceConnection,
                   Self.usbSettleRemaining(appearedAt: self.symphonyAppearedAt, now: Date()) == 0 {
                    update = await usb.readParameterUpdates()
                    interval = Self.frontPanelSyncInterval
                } else if let thunderbolt = device as? ThunderboltDeviceConnection,
                          self.thunderboltHardwareResponsive, self.connectedUnit == nil {
                    // Same question, asked through the driver. A converter has
                    // no Symphony front panel to ask. Slower than USB: each read
                    // is a round trip on the link the driver also uses.
                    update = await thunderbolt.readParameterUpdates()
                    interval = Self.thunderboltFrontPanelSyncInterval
                } else {
                    sync.reset(); syncB.reset()
                    await MainActor.run {
                        if self.reportedClockSource != nil { self.reportedClockSource = nil }
                        if self.reportedClockLocked != nil { self.reportedClockLocked = nil }
                    }
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                // The clock source came with this read, whatever the reading's
                // rate says: on an external source with no signal the unit
                // reports a rate of 0, the reading is rejected below, and that
                // is exactly when the source must still be shown (found on
                // Daniel's unit 2026-11-20: Word Clock with nothing connected
                // left the status bar on "Internal"). Asked of the connection,
                // so a board input keeps its row and USB's cached value is used.
                if device === self.device {
                    let reported = (try? await device.getProperty(PropertyAddress(selector: .clockSource)))?.asUInt32
                    let key = reported.flatMap { ClockSourceMenu.decode($0) != nil ? $0 : nil }
                    let flag = (device as? ThunderboltDeviceConnection)?.lastExternalClockLocked
                    let locked = key.flatMap { k in flag.map { ClockSourceMenu.isLocked(sourceKey: k, externalClockLocked: $0) } }
                    await MainActor.run {
                        guard device === self.device else { return }
                        if self.reportedClockSource != key || self.reportedClockLocked != locked {
                            // In the diagnostics report as it happens, not only
                            // at the next five-second snapshot.
                            print("[Maestro] clock: source key=\(key.map { String(format: "0x%04x", $0) } ?? "none")"
                                + " unit lock flag=\(flag.map { $0 ? "locked" : "not locked" } ?? "none")"
                                + " status=\(locked.map { PortStatusMessage.clock(locked: $0) } ?? "not reported")")
                        }
                        if self.reportedClockSource != key { self.reportedClockSource = key }
                        if self.reportedClockLocked != locked { self.reportedClockLocked = locked }
                    }
                }
                guard let update else {
                    sync.reset(); syncB.reset()
                    try? await Task.sleep(for: .seconds(5))
                    continue
                }
                // The connection may have been replaced while the read was out.
                guard self.wakeValidationGeneration == epoch.wake,
                      self.setupRecallRevision == epoch.recall else { continue }
                if device === self.device {
                    (device as? XPCDeviceConnection)?.seedClockSource(reported: update.clockSource)
                    for change in sync.changes(for: update) {
                        guard device === self.device, !Task.isCancelled else { break }
                        await self.applyFrontPanelChange(change, isUserChange: !baselinePending, selection: update.selection)
                    }
                    baselinePending = false
                }
                // B shares this bounded owner/cadence; never spawn another timer.
                if !Task.isCancelled, self.connectionMode == .hardware, self.isHardwareInitialized,
                   self.thunderboltHardwareResponsive,
                   device === self.device, device is ThunderboltDeviceConnection,
                   self.portSelection.selection == .ports1And2, self.unitB?.setupComplete == true,
                   let b = self.unitBDevice as? ThunderboltUnitBConnection {
                    if ownerB != ObjectIdentifier(b) {
                        syncB.reset(); ownerB = ObjectIdentifier(b); baselineBPending = true
                    }
                    let bUpdate = await b.readParameterUpdates()
                    if device === self.device, b === self.unitBDevice,
                       self.portSelection.selection == .ports1And2, self.unitB?.setupComplete == true,
                       self.wakeValidationGeneration == epoch.wake,
                       self.setupRecallRevision == epoch.recall,
                       let bUpdate {
                        for change in syncB.changes(for: bUpdate) {
                            if case .micPreGain = change {
                                await self.applyFrontPanelChange(change, unit: .b, isUserChange: !baselineBPending)
                            }
                        }
                        baselineBPending = false
                    } else { syncB.reset() }
                } else {
                    syncB.reset(); ownerB = nil
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    static let thunderboltFrontPanelSyncInterval: Duration = .milliseconds(500)

    /// True when the serving ThunderBridge/PCIe driver predates build 132.
    /// Those builds do not consume the front panel's 0x28 report themselves, so
    /// the app must tell the Mac's volume and mute controls about a front-panel
    /// change, as 0.9.9 did. Unknown (not read yet) counts as new: pushing to a
    /// 132+ driver could reach the wrong unit's monitor (4ca8d90).
    var frontPanelNeedsHALEcho: Bool {
        transportType == .thunderbolt && servingDextBuild != nil
            && !SymphonyExtendedSelectors.supported(by: servingDextBuild)
    }

    @MainActor
    func applyFrontPanelChange(_ change: FrontPanelSync.Change, unit: DeviceUnit = .a,
                               isUserChange: Bool = true,
                               selection: SymphonyIOParameterUpdates.Selection? = nil) async {
        guard !hardwareWritesSuspended, setupRecallDepth == 0 else { return }
        switch change {
        case .micPreGain(let channel, let gain, _):
            guard channel >= 0, channel < InputChannelLogic.micPreChannelCount else { return }
            // Each physical unit owns its saved group offsets, regardless of the
            // visible page. Firmware already applied the hardware change.
            let store = unit == .b ? unitBChannelStateStore : channelStateStore
            var saved = store.load(ChannelStateStore.inputKey, as: [InputChannelState].self) ?? []
            let previous = saved.indices.contains(channel) ? saved[channel].gain : nil
            let gains = FrontPanelSync.applyGain(gain, channel: channel, to: &saved)
            if !gains.isEmpty { store.save(saved, for: ChannelStateStore.inputKey) }
            frontPanelMicPreRevision += 1
            frontPanelMicPreUpdate = FrontPanelMicPreUpdate(
                unit: unit, channel: channel, gain: gain, revision: frontPanelMicPreRevision)
            let channelState = saved.indices.contains(channel) ? saved[channel] : nil
            if isUserChange, previous != (channelState?.gain ?? gain) {
                showLevelOverlay(source: .micPre(channel: channel, state: channelState),
                                 level: channelState?.gain ?? gain, change: .frontPanel)
                markSetupEdited(.inputChannelSettings)
            }
            if let tb = device as? ThunderboltDeviceConnection {
                if SymphonyExtendedSelectors.supported(by: servingDextBuild) {
                    await tb.publishObservedMicGains(gains, port: unit.portByte)
                }
            }
        // Physical monitor changes edit the level and mute stored in the setup file.
        case .level(.speaker, let dB, _):
            if speakerLevel != dB {
                speakerLevel = dB
                if isUserChange {
                    showLevelOverlay(source: .speaker, level: dB, muted: speakerMuted, change: .frontPanel)
                    markSetupEdited(.monitorControls)
                }
            }
            if transportType != .thunderbolt || frontPanelNeedsHALEcho { scheduleSpeakerLevelPush(dB) }
        // Over USB a headphone that is the volume keys' output is passed on
        // to the Mac's control too, with the same wait as the speaker.
        case .level(.headphone1, let dB, _):
            if hp1Level != dB {
                hp1Level = dB
                if isUserChange {
                    showLevelOverlay(source: .headphone1, level: dB, muted: hp1Muted, change: .frontPanel)
                    markSetupEdited(.monitorControls)
                }
            }
            if transportType != .thunderbolt { scheduleSpeakerLevelPush(dB, output: .headphone1) }
        case .level(.headphone2, let dB, _):
            if hp2Level != dB {
                hp2Level = dB
                if isUserChange {
                    showLevelOverlay(source: .headphone2, level: dB, muted: hp2Muted, change: .frontPanel)
                    markSetupEdited(.monitorControls)
                }
            }
            if transportType != .thunderbolt { scheduleSpeakerLevelPush(dB, output: .headphone2) }
        case .level: break   // MicPre selections arrive as .micPreGain
        case .muteAll(let muted):
            // The front-panel firmware updates all three output mute states
            // together, including outputs at minimum and the speaker in Line
            // mode (`SymphonyIOFrontPanel.cpp:773-783`). Keep the app's own
            // MonitorOutputToggle rule for direct clicks, but mirror this
            // hardware event in every output's copy.
            let targets = SymphonyIORequestBuilder.MonitorOutput.allCases
            let changed = targets.contains { output in
                switch output {
                case .speaker: return speakerMuted != muted
                case .headphone1: return hp1Muted != muted
                case .headphone2: return hp2Muted != muted
                }
            }
            for output in targets {
                switch output {
                case .speaker: speakerMuted = muted
                case .headphone1: hp1Muted = muted
                case .headphone2: hp2Muted = muted
                }
            }
            if isUserChange, changed {
                switch selection {
                case .headphone1: showLevelOverlay(source: .headphone1, level: hp1Level, muted: muted, change: .frontPanel)
                case .headphone2: showLevelOverlay(source: .headphone2, level: hp2Level, muted: muted, change: .frontPanel)
                default: showLevelOverlay(source: .speaker, level: speakerLevel, muted: muted, change: .frontPanel)
                }
                markSetupEdited(.monitorControls)
            }
            // Driver build 132+ consumes the physical observation itself; no
            // echo through the card's selected-monitor HAL control. An older
            // driver knows nothing of a front-panel mute: Maestro reads that
            // control whenever the Mac's volume changes, so without the echo
            // the speaker flipped back to "unmuted" on screen while the unit
            // stayed muted (2026-11-13). Setting it sends the unit the state
            // it is already in.
            if frontPanelNeedsHALEcho, let device {
                Task { try? await device.setProperty(
                    PropertyAddress(selector: .outputMute), value: .bool(muted)) }
            }
        case .metersCleared:
            clearDisplayedMeterHolds()
        }
    }

    /// How long the speaker encoder must be still before its level is passed on
    /// to the Mac's volume control.
    static let frontPanelPushQuietInterval: Duration = .milliseconds(1500)
    @ObservationIgnored var frontPanelPushQuietInterval: Duration = AppState.frontPanelPushQuietInterval

    private var speakerPushGeneration = 0

    /// Tell the Mac's volume control about a level set on the front panel, once
    /// the encoder has been still for a while.
    ///
    /// The Mac's control has to learn the level: it is what the volume keys step
    /// from, and what the audio helper restores after a reconnect, which would
    /// otherwise bring back an older and possibly louder level. But setting it
    /// sends that level to the unit, so it must never happen while the encoder
    /// may still be turning. The first version pushed as soon as the unit's
    /// "change in progress" flag dropped, which it does between clicks; stale
    /// levels were written back mid-turn and the volume jumped around
    /// (2026-11-13). Each new front panel reading restarts the wait.
    @MainActor
    private func scheduleSpeakerLevelPush(_ dB: Double, output: KeyboardVolumeOutput = .speakers) {
        guard !hardwareWritesSuspended else { return }
        speakerPushGeneration += 1
        let generation = speakerPushGeneration
        let sourceDevice = device
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.frontPanelPushQuietInterval ?? Self.frontPanelPushQuietInterval)
            guard let self, !self.hardwareWritesSuspended, generation == self.speakerPushGeneration, self.device === sourceDevice,
                  self.keyboardVolumeLevel(of: output)?.dB == dB,
                  self.lastFrontPanelSpeakerPush.map({ $0.output != output || $0.dB != dB }) ?? true else { return }
            if self.transportType != .thunderbolt {
                self.lastFrontPanelSpeakerPush = (output, dB)
                // Only the output the keys move is shown on the Mac's control.
                self.writeASPVolume(dB, output: output)
            } else if output == .speakers, self.frontPanelNeedsHALEcho {
                // Driver before build 132 (re-checked: a handover may have
                // happened during the wait). Its volume control is the
                // driver's own; setting the level through the connection
                // updates it, as 0.9.9 did.
                self.lastFrontPanelSpeakerPush = (output, dB)
                let attenuation = UInt32(max(0, min(64, -dB)))
                try? await self.device?.setProperty(
                    PropertyAddress(selector: .outputLevel), value: .uint32(attenuation))
            }
        }
    }

    // MARK: - ASP Volume Sync

    /// Find the "Symphony I/O : Maestro" ASP device and install CoreAudio property
    /// listeners for volume and mute changes. When the user presses media volume
    /// keys, the ASP handles them. This listener syncs those changes back to the
    /// Maestro app UI so the volume knob reflects the current hardware state.
    func startASPVolumeSync() {
        // Tests never listen to or set a real device's volume.
        guard !TestEnvironment.isRunningTests else { return }
        if transportType == .thunderbolt {
            // Thunderbolt: aspDeviceID was set to the ThunderBridge device in init().
            // Media keys change this device's volume directly — listen to VolumeDecibels.
            guard aspDeviceID != kAudioObjectUnknown else {
                print("[Maestro] TB volume sync: ThunderBridge device ID not set")
                return
            }
            print("[Maestro] TB volume sync: listening to ThunderBridge device \(aspDeviceID)")
        } else {
            // USB: find the ASP virtual device ("Symphony I/O : Maestro").
            var propAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var dataSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject),
                &propAddress, 0, nil, &dataSize
            ) == noErr, dataSize > 0 else { return }

            let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
            var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
            guard AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &propAddress, 0, nil, &dataSize, &deviceIDs
            ) == noErr else { return }

            for devID in deviceIDs {
                var nameAddr = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyDeviceNameCFString,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                var name: CFString = "" as CFString
                var nameSize = UInt32(MemoryLayout<CFString>.size)
                if AudioObjectGetPropertyData(devID, &nameAddr, 0, nil, &nameSize, &name) == noErr,
                   (name as String) == Self.aspUSBDeviceName {
                    aspDeviceID = devID
                    break
                }
            }

            guard aspDeviceID != kAudioObjectUnknown else {
                print("[Maestro] ASP volume sync: '\(Self.aspUSBDeviceName)' device not found")
                return
            }
            print("[Maestro] ASP volume sync: found device ID \(aspDeviceID)")
        }

        // Read initial volume.
        readASPVolume()
        readASPMute()

        // Install volume listener — VolumeDecibels for Thunderbolt, VolumeScalar for USB/ASP.
        let volumeSelector = transportType == .thunderbolt
            ? kAudioDevicePropertyVolumeDecibels
            : kAudioDevicePropertyVolumeScalar
        var volumeAddr = AudioObjectPropertyAddress(
            mSelector: volumeSelector,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListener(
            aspDeviceID, &volumeAddr, aspVolumeChanged, Unmanaged.passUnretained(self).toOpaque())

        // Install mute listener on output scope (same for both transports).
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListener(
            aspDeviceID, &muteAddr, aspMuteChanged, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Observe the standard HAL controls that a DAW edits on an installed 8MicPre
    /// (polarity, high-pass, input type and the input-scope gain). Installed only
    /// when a unit has the board, so rigs without it add no listeners or reads.
    /// A notification is only a prompt to read the driver's host-edit records
    /// sooner than the next health poll: the HAL element is a host input whose
    /// MicPre (unit A or B, any channel) depends on routing, so its value is
    /// never written to a strip here. The records are already resolved to a
    /// physical unit and channel by the driver (`MicPreDAWObservation`).
    @MainActor
    func startMicPreDAWSync() {
        stopMicPreDAWSync()
        guard transportType == .thunderbolt,
              cardLayout.slot2 == .micPre8 || unitBLayout?.slot2 == .micPre8,
              aspDeviceID != kAudioObjectUnknown else { return }
        let selectors: [AudioObjectPropertySelector] = [
            kAudioDevicePropertyPhaseInvert,
            kAudioDevicePropertyHighPassFilterSetting,
            kAudioDevicePropertyChannelNominalLineLevel,
            kAudioDevicePropertyVolumeDecibels,
        ]
        for element in 1...8 {
            for selector in selectors {
                var address = AudioObjectPropertyAddress(mSelector: selector,
                    mScope: kAudioObjectPropertyScopeInput,
                    mElement: AudioObjectPropertyElement(element))
                if AudioObjectAddPropertyListener(aspDeviceID, &address, micPreDAWPropertyChanged,
                    Unmanaged.passUnretained(self).toOpaque()) == noErr {
                    micPreDAWListenerAddresses.append(address)
                }
            }
        }
    }

    @MainActor
    func stopMicPreDAWSync() {
        micPreDAWRefreshTask?.cancel()
        micPreDAWRefreshTask = nil
        micPreDAWRefreshGate.cancel()
        guard aspDeviceID != kAudioObjectUnknown else { micPreDAWListenerAddresses.removeAll(); return }
        for var address in micPreDAWListenerAddresses {
            AudioObjectRemovePropertyListener(aspDeviceID, &address, micPreDAWPropertyChanged,
                Unmanaged.passUnretained(self).toOpaque())
        }
        micPreDAWListenerAddresses.removeAll()
    }

    /// Coalesce a burst of HAL notifications (a fader drag, a DAW recall) into
    /// one selector-5 read, made off the main actor, then apply the records.
    @MainActor
    func scheduleMicPreDAWRefresh(objectID: AudioObjectID) {
        guard objectID == aspDeviceID, let tb = device as? ThunderboltDeviceConnection,
              let token = micPreDAWRefreshGate.begin() else { return }
        micPreDAWRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            let link = await Task.detached(priority: .utility) { tb.linkState() }.value
            guard let self else { return }
            // A cancelled task leaves a newer task's slot alone.
            guard self.micPreDAWRefreshGate.isCurrent(token) else { return }
            self.micPreDAWRefreshGate.finish(token)
            self.micPreDAWRefreshTask = nil
            guard !Task.isCancelled, (self.device as? ThunderboltDeviceConnection) === tb else { return }
            self.applyPhantomObservations(link)
        }
    }

    /// Read current volume from the synced audio device and update speakerLevel.
    func readASPVolume() {
        if transportType == .thunderbolt && (monitorDevice != .a || monitorSelectionTask != nil) { return }
        guard aspDeviceID != kAudioObjectUnknown else { return }
        // Skip if we just wrote — avoids feedback loop where our own write
        // triggers the listener which re-reads the same value.
        if Date().timeIntervalSince(aspWriteTimestamp) < 0.2 { return }

        if transportType == .thunderbolt {
            // Thunderbolt: read VolumeDecibels directly (-64..0 dB range)
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeDecibels,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var dB: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(aspDeviceID, &addr, 0, nil, &size, &dB) == noErr {
                // Whose level the control holds (`macVolumeAdoption`).
                switch currentMacVolumeAdoption() {
                case .level(let output): setKeyboardVolumeLevel(Double(dB), of: output)
                case .legacyHeadphone1: hp1Level = Double(dB)
                case .legacySpeaker: speakerLevel = Double(dB)
                case .ignore, .putBack: break
                }
            }
        } else {
            // USB/ASP: read VolumeScalar and convert to dB
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var scalar: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(aspDeviceID, &addr, 0, nil, &size, &scalar) == noErr {
                // ASP maps: scalar 0.0 → raw 0 → -64 dB, scalar 1.0 → raw 64 → 0 dB
                let dB = Double(scalar) * 64.0 - 64.0
                // Whose level the control holds (`macVolumeAdoption`). With
                // Speaker chosen in Line mode the helper ignored the change:
                // the Mac's control is put back to the speaker level, so the
                // next key press after leaving Line does not step from a
                // level that was never applied.
                switch currentMacVolumeAdoption() {
                case .level(let output): setKeyboardVolumeLevel(dB, of: output)
                case .legacySpeaker, .legacyHeadphone1: speakerLevel = dB
                case .putBack: if abs(dB - speakerLevel) > 0.5 { showSpeakerLevelOnMacVolume() }
                case .ignore: break
                }
            }
        }
    }

    /// Read current mute state from the ASP device and update speakerMuted.
    func readASPMute() {
        if transportType == .thunderbolt && (monitorDevice != .a || monitorSelectionTask != nil) { return }
        guard aspDeviceID != kAudioObjectUnknown else { return }
        if Date().timeIntervalSince(aspWriteTimestamp) < 0.2 { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(aspDeviceID, &addr, 0, nil, &size, &muted) == noErr {
            // Whose mute the control holds (`macVolumeAdoption`).
            switch currentMacVolumeAdoption(mute: true) {
            case .level(let output): setKeyboardVolumeMute(muted != 0, of: output)
            case .legacyHeadphone1: hp1Muted = muted != 0
            case .legacySpeaker: speakerMuted = muted != 0
            case .putBack: if (muted != 0) != speakerMuted { writeMacMute(speakerMuted) }
            case .ignore: break
            }
        }
    }

    private struct ObservedMonitorLevel: Equatable {
        let output: LevelOverlaySource
        let level: Double
        let muted: Bool

        func matches(_ other: Self) -> Bool {
            output == other.output && abs(level - other.level) <= 0.5 && muted == other.muted
        }

        static func source(for output: KeyboardVolumeOutput) -> LevelOverlaySource? {
            switch output {
            case .speakers, .mixer1Level: .speaker
            case .headphone1: .headphone1
            case .headphone2: .headphone2
            case .none: nil
            }
        }
    }

    private func rememberMacMonitorWrite(for output: KeyboardVolumeOutput, level: Double? = nil, muted: Bool? = nil) {
        guard let source = ObservedMonitorLevel.source(for: output),
              let current = keyboardVolumeLevel(of: output) else { return }
        lastMacMonitorWrite = .init(output: source, level: level ?? current.dB,
                                   muted: muted ?? current.muted)
    }

    private func observedMonitorLevels() -> [ObservedMonitorLevel] {
        [
            .init(output: .speaker, level: speakerLevel, muted: speakerMuted),
            .init(output: .headphone1, level: hp1Level, muted: hp1Muted),
            .init(output: .headphone2, level: hp2Level, muted: hp2Muted)
        ]
    }

    @MainActor
    func adoptMacMonitorChange(mute: Bool) {
        let previous = observedMonitorLevels()
        if mute { readASPMute() } else { readASPVolume() }
        guard initialSetupRestoreFinished, connectionMode == .hardware, isHardwareInitialized,
              !hardwareWritesSuspended, setupRecallDepth == 0, usbRestoreTask == nil else { return }
        for (before, after) in zip(previous, observedMonitorLevels()) where before != after {
            if let lastMacMonitorWrite, after.matches(lastMacMonitorWrite) { continue }
            // Like front-panel changes, Mac volume changes edit levels stored in the setup file.
            markSetupEdited(.monitorControls)
            if ContinuousClock.now >= macVolumeOverlayAfter {
                showLevelOverlay(source: after.output, level: after.level, muted: after.muted,
                                 change: transportType == .usb ? .maestroUSBVolume : .macVolume)
            }
        }
    }

    /// What a change of the Mac's volume or mute control means right now.
    private func currentMacVolumeAdoption(mute: Bool = false) -> MacVolumeAdoption {
        let output = keyboardVolumeOutput(for: .a)
        return Self.macVolumeAdoption(
            thunderbolt: transportType == .thunderbolt, servingBuild: servingDextBuild,
            helperOutdated: usbKeysMoveSpeakerOnly, output: output,
            settled: keyboardVolumeSettled(output), speakerMode: speakerOutputMode, mute: mute)
    }

    /// USB, Speaker chosen in Line mode: put the Mac's "Maestro USB" volume
    /// and mute back to the speaker's (the helper ignores both there).
    func showSpeakerLevelOnMacVolume() {
        guard transportType != .thunderbolt else { return }
        writeMacVolume(speakerLevel)
    }

    /// Write the current speakerLevel to the synced audio device.
    /// For USB: writes VolumeScalar to ASP so macOS Sound slider reflects the change.
    /// For Thunderbolt: no-op — ThunderboltDeviceConnection already writes VolumeDecibels
    /// directly, and the listener callback keeps the UI in sync.
    ///
    /// `output` is the output whose level changed: only the one chosen under
    /// Volume Keys › Audio Output is shown on the Mac's control (a helper
    /// before version 3 always moves the speakers).
    func writeASPVolume(_ dB: Double, output: KeyboardVolumeOutput = .speakers) {
        if transportType == .thunderbolt {
            // ThunderboltDeviceConnection.setProperty already wrote VolumeDecibels
            // to this same device. Remember the value for its HAL notification.
            if ObservedMonitorLevel.source(for: keyboardVolumeOutput(for: .a)) == ObservedMonitorLevel.source(for: output) {
                rememberMacMonitorWrite(for: output, level: dB)
            }
            return
        }
        guard (usbKeysMoveSpeakerOnly ? .speakers : keyboardVolumeOutput(for: .a)) == output else { return }
        writeMacVolume(dB)
    }

    private func writeMacVolume(_ dB: Double) {
        guard !hardwareWritesSuspended else { return }
        guard aspDeviceID != kAudioObjectUnknown, transportType != .thunderbolt else { return }
        aspWriteTimestamp = Date()
        // Convert dB (-64..0) to scalar (0..1): scalar = (dB + 64) / 64
        let scalar = Float32(max(0, min(1, (dB + 64.0) / 64.0)))
        let targetID = aspDeviceID
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = scalar
        if AudioObjectSetPropertyData(targetID, &addr, 0, nil,
                                      UInt32(MemoryLayout<Float32>.size), &value) == noErr {
            let output = usbKeysMoveSpeakerOnly ? .speakers : keyboardVolumeOutput(for: .a)
            rememberMacMonitorWrite(for: output, level: Double(scalar) * 64 - 64)
        }
    }

    /// Write mute state to the synced audio device.
    /// For Thunderbolt: no-op (same reason as writeASPVolume).
    func writeASPMute(_ muted: Bool, output: KeyboardVolumeOutput = .speakers) {
        if transportType == .thunderbolt {
            if ObservedMonitorLevel.source(for: keyboardVolumeOutput(for: .a)) == ObservedMonitorLevel.source(for: output) {
                rememberMacMonitorWrite(for: output, muted: muted)
                // Also set the driver's Core Audio mute control, so macOS saves
                // the mute with the device and restores it within the driver's
                // start-up hold after a replug (it saved "unmuted" before, and
                // the speakers played for a few seconds; 2026-11-22 21:53).
                writeThunderboltMacMute(muted)
            }
            return
        }
        guard (usbKeysMoveSpeakerOnly ? .speakers : keyboardVolumeOutput(for: .a)) == output else { return }
        writeMacMute(muted)
    }

    private func writeThunderboltMacMute(_ muted: Bool) {
        guard !hardwareWritesSuspended, let targetID = activeAudioDeviceID,
              targetID != kAudioObjectUnknown else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        // Always set, even when the control already shows this value: the
        // driver mirrors the unit's mute onto its control itself, and macOS
        // saves only what a client sets (diagnostics 2026-11-23 09-59: the
        // control showed muted, Maestro skipped, macOS restored "unmuted").
        var value: UInt32 = muted ? 1 : 0
        _ = AudioObjectSetPropertyData(targetID, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    private func writeMacMute(_ muted: Bool) {
        guard !hardwareWritesSuspended else { return }
        guard aspDeviceID != kAudioObjectUnknown, transportType != .thunderbolt else { return }
        aspWriteTimestamp = Date()
        let targetID = aspDeviceID
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = muted ? 1 : 0
        if AudioObjectSetPropertyData(targetID, &addr, 0, nil,
                                      UInt32(MemoryLayout<UInt32>.size), &value) == noErr {
            let output = usbKeysMoveSpeakerOnly ? .speakers : keyboardVolumeOutput(for: .a)
            rememberMacMonitorWrite(for: output, muted: muted)
        }
    }

    /// Remove volume/mute listeners from the synced audio device.
    func stopASPVolumeSync() {
        guard aspDeviceID != kAudioObjectUnknown else { return }
        let volumeSelector = transportType == .thunderbolt
            ? kAudioDevicePropertyVolumeDecibels
            : kAudioDevicePropertyVolumeScalar
        var volumeAddr = AudioObjectPropertyAddress(
            mSelector: volumeSelector,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListener(
            aspDeviceID, &volumeAddr, aspVolumeChanged, Unmanaged.passUnretained(self).toOpaque())
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListener(
            aspDeviceID, &muteAddr, aspMuteChanged, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Parse raw USB meter data (UInt8 bytes) into dBFS array.
    /// Each byte is a linear 0-255 value representing signal level.
    private func parseMeterData(_ data: Data, into levels: inout [Double], count: Int) {
        for i in 0..<min(count, data.count) {
            let raw = data[i]
            if raw == 0 {
                levels[i] = -60
            } else {
                // Convert 0-255 linear to dBFS: 20 * log10(value / 255)
                let linear = Double(raw) / 255.0
                levels[i] = 20.0 * log10(max(linear, 0.0001))
            }
        }
    }

    /// Build a [Double] dBFS array from TDM hardware meter data.
    /// TDM meter data: 16-bit little-endian pairs per channel (64 bytes → 32 channels).
    /// Bits 0-13 = 14-bit level (0-16383), bit 15 = over/clip flag (0x8000).
    /// Evidence: SymphonyIO_Stream.cpp:563 — 20*log10(val/16383.0)
    /// Parse TDM meter data from firmware into dBFS levels.
    ///
    /// TDM layout for input/output (64 bytes = 32 words):
    ///   Board 1: words 0-15  (8 analog + 8 digital per AnalogOptical board)
    ///   Board 2: words 16-31 (8 analog + 8 digital)
    /// User-visible channels 1-8 = Board 1 analog (words 0-7)
    /// User-visible channels 9-16 = Board 2 analog (words 16-23)
    ///
    /// Mixer TDM (32 bytes = 16 words) has no board structure — linear layout.
    ///
    /// Evidence: `SymphonyIO.cpp` line 7010 — `SetBoardMeterData(true, rawTDMMeterData+16*nBrdIdx, 16)`
    /// Evidence: `SymphonyIOBoard_AnalogOptical.cpp` — 8 analog + 8 optical streams per board
    private func tdmMeterReadings(from data: Data, count: Int, isInput: Bool) -> [MeterReading] {
        let layout = cardLayout
        if layout.isKnown {
            let words = layout.slots.enumerated().flatMap { board, card in
                let channels = isInput ? card.analogInputChannels : card.analogOutputChannels
                return (0..<channels).map { board * IOCardType.busChannelsPerBoard + $0 }
            }
            return (0..<count).map { index in
                guard words.indices.contains(index) else { return .silence }
                return TDMMeterPayload.reading(data, word: words[index])
            }
        }
        return (0..<count).map { index in
            let word = MeterSlotMap.analogWordIndex(channel: index, analogOnBoard0: 8,
                                                    twoBoards: data.count >= 64 && count > 8)
            return TDMMeterPayload.reading(data, word: word)
        }
    }

    // MARK: Software output meters (hardware output group proven absent)

    /// Re-read the app's persisted output routing for the software output meter
    /// model. Cheap (UserDefaults) but not free at 20 fps, so throttled to ~2 s.
    private func refreshSoftwareOutputRoutesIfNeeded(pollCount: Int) {
        guard softwareOutputRoutesPollStamp < 0 || pollCount < softwareOutputRoutesPollStamp
                || pollCount - softwareOutputRoutesPollStamp >= 40 else { return }
        softwareOutputRoutesPollStamp = pollCount
        softwareOutputRoutes = cachedOutputRouteMap()
    }

    /// Re-derive `thunderboltInputMeterWords` every ~2 s, and at once when the
    /// card layout changes. The table is the driver's board-order table with
    /// the saved Input Routing choices that `syncInputRoutingToHardware`
    /// writes over it (only when the cards were read this session, as there).
    func invalidateThunderboltInputMeterMap() {
        thunderboltInputMeterWordsPollStamp = -1
        thunderboltCaptureRoutesCache.removeAll()
    }

    /// Output Routing changed: read the output meter map again at the next poll.
    func invalidateThunderboltOutputMeterMap() {
        thunderboltOutputMeterWordsPollStamp = -1
        unitBOutputMeterWordsPollStamp = -1
    }

    @MainActor
    private func refreshThunderboltOutputMeterWordsIfNeeded(pollCount: Int, device tb: ThunderboltDeviceConnection) {
        let layout = cardLayout
        guard thunderboltOutputMeterWordsPollStamp < 0
                || pollCount < thunderboltOutputMeterWordsPollStamp
                || pollCount - thunderboltOutputMeterWordsPollStamp >= 40
                || thunderboltOutputMeterLayout != layout else { return }
        thunderboltOutputMeterWordsPollStamp = pollCount
        thunderboltOutputMeterLayout = layout
        // Converters keep host channel n on strip n; unit A's table needs its
        // cards and identity read (as the restore does).
        guard layout.converterLayout == nil, cardTableUnreadableReason() == nil else {
            thunderboltOutputMeterWords = nil
            return
        }
        thunderboltOutputMeterWords = ThunderboltOutputMeterMap.words(
            layout: layout, table: thunderboltOutputTable(for: tb, quiet: true), unitBActive: unitBOnCard,
            order: thunderboltDisplayOrder(unit: .a))
    }

    /// A level per meter word from Core Audio's playback peaks, for when the
    /// card's snapshot has none: word 64 + n is software output n. The card
    /// mixers' outputs cannot be measured this way and read as silence.
    private func softwarePlaybackWordLevel(_ peaks: [Float]) -> (Int) -> Double {
        let mixerBase = Int(ThunderboltCardRouting.mixerOutBase)
        // A card mixer's output cannot be measured this way: show its
        // Software Return source, as the Mixer page's fallback does.
        let pairs = softwareReturnPairCount
        let returns = [0, 1].map { max(0, min(pairs - 1, mixerPreferences.integer(forKey: "mixerSoftwareReturnSource_\($0)"))) * 2 }
        return { word in
            var channel = word - Int(ThunderboltCardRouting.pciOutBase)
            if word >= mixerBase, word < mixerBase + 4 {
                channel = returns[(word - mixerBase) / 2] + (word - mixerBase) % 2
            }
            guard channel >= 0, channel < peaks.count else { return -60.0 }
            return SoftwareOutputMeterMap.dBFS(linearPeak: peaks[channel])
        }
    }

    /// Read only the unit shown on the Output page. The context captured before
    /// the worker starts is required again before its reply can be displayed.
    @MainActor
    private func pollUnitOutputMetersIfNeeded(pollCount: Int, device tb: ThunderboltDeviceConnection) {
        guard selectedArea == .output, !hardwareWritesSuspended,
              thunderboltHardwareResponsive, UnitOutputMeters.driverSupports(servingDextBuild),
              !unitOutputMeterReadInFlight else { return }
        let unit = activeUnit
        let layout = unit == .b ? unitBLayout : cardLayout
        guard let layout, layout.isKnown, layout.converterLayout == nil,
              Date() >= (unitOutputMeterRetryAfter[unit] ?? .distantPast) else { return }
        let bConnection = unit == .b ? unitBDevice as? ThunderboltUnitBConnection : nil
        guard unit == .a || bConnection != nil else { return }
        let contextID: ObjectIdentifier = unit == .a ? ObjectIdentifier(tb) : ObjectIdentifier(bConnection!)
        let now = Date()
        let next = MeterPollPacing.nextStart(
            now: now.timeIntervalSinceReferenceDate,
            previousStart: unitOutputMeterLastStart[unit]?.timeIntervalSinceReferenceDate,
            previousEnd: unitOutputMeterLastEnd[unit]?.timeIntervalSinceReferenceDate,
            backoffUntil: (unitOutputMeterRetryAfter[unit] ?? .distantPast).timeIntervalSinceReferenceDate)
        guard now.timeIntervalSinceReferenceDate >= next else { return }
        unitOutputMeterReadInFlight = true
        unitOutputMeterLastStart[unit] = now
        let context = (unit, layout, contextID)
        Task.detached(priority: .userInitiated) { [weak self] in
            let payload: Data?
            if unit == .a {
                payload = try? tb.readUnitOutputMeters()
            } else {
                payload = try? bConnection!.readUnitOutputMeters()
            }
            let end = Date()
            await MainActor.run {
                guard let self else { return }
                self.unitOutputMeterReadInFlight = false
                self.unitOutputMeterLastEnd[unit] = end
                if self.unitOutputMeterWindowDurations.isEmpty { self.unitOutputMeterWindowStart = now }
                self.unitOutputMeterWindowDurations.append(end.timeIntervalSince(now))
                if end.timeIntervalSince(self.unitOutputMeterWindowStart) >= 30 {
                    let sorted = self.unitOutputMeterWindowDurations.sorted()
                    let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
                    let worst = sorted.max() ?? 0
                    let medianText = String(format: "%.3f", median)
                    let worstText = String(format: "%.3f", worst)
                    print("[MeterPoll] reads=\(self.unitOutputMeterWindowDurations.count) median=\(medianText)s worst=\(worstText)s")
                    self.unitOutputMeterWindowStart = end
                    self.unitOutputMeterWindowDurations.removeAll(keepingCapacity: true)
                }
                guard let payload else {
                    let failures = (self.unitOutputMeterFailures[unit] ?? 0) + 1
                    self.unitOutputMeterFailures[unit] = failures
                    self.unitOutputMeterRetryAfter[unit] = end.addingTimeInterval(MeterPollPacing.backoff(consecutiveFailures: failures))
                    return
                }
                self.unitOutputMeterFailures[unit] = 0
                let activeLayout = context.0 == .b ? self.unitBLayout : self.cardLayout
                let activeConnection = (context.0 == .b ? self.unitBDevice : self.device).map { ObjectIdentifier($0) }
                guard self.selectedArea == .output, !self.hardwareWritesSuspended,
                      UnitOutputMeters.replyBelongs(unit: context.0, layout: context.1,
                                                    connection: context.2, activeUnit: self.activeUnit,
                                                    activeLayout: activeLayout, activeConnection: activeConnection) else { return }
                if let levels = UnitOutputMeters.levels(payload: payload, layout: layout) {
                    self.unitOutputMeterLevelsByUnit[unit] = levels
                    self.symphonyOutputMeterLevels = levels
                    self.unitOutputMeterStamp = Date()
                    self.unitOutputMeterContext = context
                }
            }
        }
    }

    /// Keep our last reading for 500 ms when a read fails. The 500 ms fallback
    /// is Maestro's rule. Apogee cleared a stream's meters after that interval.
    @MainActor
    private func freshUnitOutputMeterLevels() -> UnitOutputMeters.Levels? {
        guard selectedArea == .output, Date().timeIntervalSince(unitOutputMeterStamp) < 0.5,
              let context = unitOutputMeterContext else { return nil }
        let currentID = activeUnit == .b
            ? unitBDevice.map { ObjectIdentifier($0) }
            : device.map { ObjectIdentifier($0) }
        guard UnitOutputMeters.replyBelongs(unit: context.0, layout: context.1,
                                            connection: context.2, activeUnit: activeUnit,
                                            activeLayout: activeUnit == .b ? unitBLayout : cardLayout,
                                            activeConnection: currentID) else { return nil }
        return unitOutputMeterLevelsByUnit[activeUnit]
    }

    private func refreshThunderboltInputMeterWordsIfNeeded(pollCount: Int, device tb: ThunderboltDeviceConnection) {
        let layout = cardLayout
        guard thunderboltInputMeterWordsPollStamp < 0
                || pollCount < thunderboltInputMeterWordsPollStamp
                || pollCount - thunderboltInputMeterWordsPollStamp >= 40
                || thunderboltInputMeterLayout != layout else { return }
        thunderboltInputMeterWordsPollStamp = pollCount
        thunderboltInputMeterLayout = layout
        // Converters: each host input reads its bus slot's word (port * 32 +
        // slot), over both ports while 64 channels run.
        if let system = layout.converterLayout {
            thunderboltInputMeterWords = ThunderboltInputMeterMap.converterWords(system)
            return
        }
        let routes = thunderboltCaptureRoutes(unit: .a)
        thunderboltInputMeterWords = ThunderboltInputMeterMap.words(layout: layout, routes: routes)
    }

    /// The output routes the app has persisted, as destination byte -> source
    /// byte. Mirrors the encoding in `syncOutputRoutingToHardware` exactly, but
    /// READS ONLY -- nothing here touches the device.
    func cachedOutputRouteMap() -> [UInt8: UInt8] {
        guard let device = self.device else { return [:] }
        let id = device.identifier
        let cache = peripheralRoutingCache(direction: "output")
        guard let routes = cache.loadMulti(), !routes.isEmpty else { return [:] }
        let board1 = self.primaryBoardType
        let board2 = self.secondaryBoardType
        let swPairs = id.mode.channelCount / 2
        var map: [UInt8: UInt8] = [:]
        for (row, cols) in routes {
            for col in cols {
                guard let destByte = IOCardType.columnToRoutingByte(
                    col: col, isInput: false, board1: board1, board2: board2
                ) else { continue }
                let srcLeft: UInt8
                if let pair = TwoUnitOutputRouting.playbackPair(
                    unitARow: row, unitAPairs: swPairs, unitBActive: unitBOnCard) {
                    srcLeft = SymphonyIORoutingAddress.hostPlaybackBase(for: transportType ?? .usb) + UInt8(pair * 2)
                } else if row == swPairs {
                    srcLeft = SymphonyIORoutingAddress.mixer0Base
                } else if row == swPairs + 1 {
                    srcLeft = SymphonyIORoutingAddress.mixer1Base
                } else { continue }
                map[destByte] = srcLeft
                map[destByte &+ 1] = srcLeft &+ 1
            }
        }
        return map
    }

    /// Persisted USB pair selected as each mixer's Software Return source.
    /// Source IDs are pair indices: 0 = USB 1–2, ..., 7 = USB 15–16.
    private func cachedMixerSoftwareReturnSources() -> [Int] {
        [0, 1].map { mixer in
            max(0, min(7, self.mixerPreferences.integer(forKey: "mixerSoftwareReturnSource_\(mixer)")))
        }
    }

    /// Analog output levels from the proxy's per-USB-channel peaks, laid out
    /// through the same slot map as the hardware payload so a `.none` card
    /// degrades identically (MeterSlotMap falls back to 8 analog per board).
    private func softwareOutputLevels(peaks: [Float], count: Int) -> [Double] {
        var result = [Double](repeating: -60.0, count: count)
        let hasTwoBoards = count > 8
        let analogOnBoard0 = self.primaryBoardType.analogOutputChannels
        let mixerSources = cachedMixerSoftwareReturnSources()
        for i in 0..<count {
            let word = MeterSlotMap.analogWordIndex(
                channel: i, analogOnBoard0: analogOnBoard0, twoBoards: hasTwoBoards)
            let source = SoftwareOutputMeterMap.source(forWord: word, routes: softwareOutputRoutes)
            result[i] = SoftwareOutputMeterMap.level(
                for: source, usbPeaks: peaks,
                mixerSoftwareReturnSources: mixerSources)
        }
        return result
    }

    /// Digital output levels follow the routed sources, in board order.
    private func softwareDigitalOutputLevels(peaks: [Float]) -> [Double] {
        let mixerSources = cachedMixerSoftwareReturnSources()
        return MeterSlotMap.digitalWords(layout: cardLayout, isInput: false).map { word in
            guard let word else { return -60 }
            let source = SoftwareOutputMeterMap.source(forWord: word, routes: softwareOutputRoutes)
            return SoftwareOutputMeterMap.level(for: source, usbPeaks: peaks,
                                                mixerSoftwareReturnSources: mixerSources)
        }
    }

    /// Build a fresh [Double] dBFS array from Float32 mAEstroStreamMeter peaks.
    /// Returns a full-length array so @Observable detects the property assignment.
    /// Evidence: SymphonyIO_Stream.cpp:563 — m_aPeaks are already dBFS (20*log10(val/16383))
    /// Evidence: SymphonyIO_Stream.cpp:571 — silent channels store -INFINITY
    private func linearMeterLevels(from peaks: [Float], count: Int) -> [Double] {
        var result = [Double](repeating: -60.0, count: count)
        for i in 0..<min(count, peaks.count) {
            let peak = peaks[i]
            result[i] = (peak.isNaN || peak.isInfinite || peak < -60.0) ? -60.0 : Double(peak)
        }
        return result
    }

    // MARK: - Preset Save / Load (P3F-31)

    /// Snapshot the current device state into a `MaestroPreset`.
    ///
    /// Reads device properties via daemon IPC where available. Input channel states
    /// come from UserDefaults (per-channel reads are blocked on Symphony IO MKI — P3G-31).
    /// Properties unavailable on this hardware are left at preset defaults.
    ///
    /// Evidence: `og_source/maestro2/App/APDocument.m` — storeMaestroPreferenceFile:
    @MainActor
    private func makePreset(reading captureDevice: (any DeviceConnection)?) async -> MaestroPreset {
        var preset = MaestroPreset()

        // Output level + mute: kept in sync by volume key handler + loadMonitorState
        preset.outputLevel = speakerLevel
        preset.outputMuted = speakerMuted

        if let dev = captureDevice {
            // Output dim + sum-to-mono
            if let dim = (try? await dev.getProperty(PropertyAddress(selector: .outputDim)))?.asBool {
                preset.outputDimmed = dim
            }
            if let mono = (try? await dev.getProperty(PropertyAddress(selector: .outputSumToMono)))?.asBool {
                preset.outputSumToMono = mono
            }
            // Headphone 1 — use AppState values (synced from output tab/monitor panel)
            preset.hp1Level = hp1Level
            preset.hp1Muted = hp1Muted
            if let rid = (try? await dev.getProperty(PropertyAddress(selector: .headphone1RoutingID)))?.asUInt32 {
                preset.hp1RoutingID = rid
            }
            // Headphone 2 — use AppState values
            preset.hp2Level = hp2Level
            preset.hp2Muted = hp2Muted
            if let rid = (try? await dev.getProperty(PropertyAddress(selector: .headphone2RoutingID)))?.asUInt32 {
                preset.hp2RoutingID = rid
            }
            // Device settings
            // Per slot, as the daemon saved them. The optical format is read
            // through the direction the card has (an A16 IP has optical outputs
            // only), and only for a card with optical ports or coax jacks.
            for slot in 0..<2 {
                let card = cardLayout.card(atSlot: slot)
                let element = UInt32(slot)
                var fmt: UInt32?
                if card.hasOpticalPorts {
                    let selector: AudioPropertySelector = card.opticalFormatUsesInput ? .opticalInFormat : .opticalOutFormat
                    fmt = (try? await dev.getProperty(PropertyAddress(selector: selector, element: element)))?.asUInt32
                }
                var rep: UInt32?, mir: UInt32?
                if card.hasSPDIFCoax {
                    rep = (try? await dev.getProperty(
                        PropertyAddress(selector: .spdifReplaceID, scope: .input, element: element)))?.asUInt32
                    mir = (try? await dev.getProperty(
                        PropertyAddress(selector: .spdifMirrorID, scope: .output, element: element)))?.asUInt32
                }
                if slot == 0 {
                    if let fmt { preset.opticalInFormat = fmt }
                    if let rep { preset.spdifReplaceID = rep }
                    if let mir { preset.spdifMirrorID = mir }
                } else {
                    preset.slot2OpticalFormat = fmt
                    preset.slot2SPDIFReplaceID = rep
                    preset.slot2SPDIFMirrorID = mir
                }
            }
            if let pk = (try? await dev.getProperty(PropertyAddress(selector: .peakHoldMode)))?.asUInt32 {
                preset.peakHoldMode = pk
            }
            if let ov = (try? await dev.getProperty(PropertyAddress(selector: .oversHoldMode)))?.asUInt32 {
                preset.overHoldMode = ov
            }
            if let mb1 = (try? await dev.getProperty(PropertyAddress(selector: .metersShowInput, element: 1)))?.asUInt32 {
                preset.meterBank1Source = mb1
            }
            if let mb2 = (try? await dev.getProperty(PropertyAddress(selector: .metersShowInput, element: 2)))?.asUInt32 {
                preset.meterBank2Source = mb2
            }
        }

        // Input channel states from UserDefaults (device reads blocked on MKI — P3G-31)
        let store = channelStateStore
        if let states: [InputChannelState] = store.load(ChannelStateStore.inputKey) {
            preset.inputChannelStates = states
        }

        // Output channel states from UserDefaults (device reads blocked on MKI — P3G-31)
        if let states: [OutputChannelState] = store.load(ChannelStateStore.outputKey) {
            preset.outputChannelStates = states
        }

        // Mixer channel names (app-side labels, not hardware state — P3F-39)
        if let str = UserDefaults.standard.string(forKey: mixerNamesKey()),
           let names = try? JSONDecoder().decode([String].self, from: Data(str.utf8)) {
            preset.channelNames = names
        }

        return preset
    }

    // MARK: - Bundle Preset Save/Recall (daemon-native format)

    /// Save all current device state to an `.mst2` bundle (daemon-native format).
    ///
    /// Creates a macOS package bundle at `url` containing:
    /// - A device plist written by the daemon via `'AESP'`, capturing the full hardware
    ///   state: output/headphone levels, routing (RoutingSourceToIOBoard0/1/USBStream),
    ///   mixer faders/pans/mutes/solos, per-stream trim/refLevel/softLimit, and all other
    ///   device properties. This is identical to what the original Maestro 2 app saves.
    /// - `MaestroApp.plist` — app-level state (channel names, output level snapshot).
    ///
    /// Evidence: storeMaestroPreferenceFile (APMaestroFullViewWindow.m:445)
    ///           kmAEstroPropertyStorePreferenceFile = 'AESP' (mAEstro.h:1197)
    @MainActor
    func savePresetBundle(to url: URL, associateWithDocument: Bool = true) async throws {
        let editRevision = setupEditRevision
        // Core Audio can keep the ThunderBridge device around while the Symphony is off.
        let captureDevice = connectionMode == .disconnected ? nil : device
        if let connection = captureDevice as? ThunderboltDeviceConnection {
            try await saveThunderboltPresetBundle(to: url, connection: connection)
            if associateWithDocument {
                currentSetupURL = url
                setupDocumentEdited = setupEditRevision != editRevision
                WindowDocumentBridge.updateEditedState()
            }
            return
        }
        let fm = FileManager.default
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".maestro-\(UUID().uuidString).mst2", isDirectory: true)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: temporary) }

        // 1. Ask daemon to write the full hardware state plist inside the bundle.
        //    The daemon uses 'AESP' (AudioObjectSetPropertyData) to write a file like
        //    "USBAudio_Symphony I_O_<UID>.plist". This goes through the Apogee HAL plugin
        //    which converts the CFString path to a C string and forwards to the daemon.
        //    Non-fatal: if the daemon can't write (HAL plugin missing, permission issue),
        //    we still save our own MaestroApp.plist so presets aren't empty.
        var wroteHardware = false
        if let conn = captureDevice as? CoreAudioDeviceConnection {
            let fileName = conn.getPreferenceFileName()
                ?? "USBAudio_Symphony_IO.plist"  // fallback if HAL plugin absent
            let plistURL = temporary.appendingPathComponent(fileName)
            do {
                try conn.storePreferenceFile(at: plistURL.path)
                wroteHardware = fm.fileExists(atPath: plistURL.path)
                if wroteHardware { print("[Maestro] savePresetBundle: daemon plist written to \(fileName)") }
            } catch {
                if fm.fileExists(atPath: plistURL.path) { try fm.removeItem(at: plistURL) }
                print("[Maestro] savePresetBundle: daemon AESP failed (\(error)) — saving app metadata")
            }
        } else {
            print("[Maestro] savePresetBundle: no CoreAudioDeviceConnection — daemon plist skipped")
        }

        // 2. Save app-level metadata alongside the daemon plist.
        //    This always runs regardless of daemon AESP success, ensuring the preset
        //    bundle is never empty. Contains all device state our app can read/write.
        let appMeta = await makePreset(reading: captureDevice)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let metaData = try encoder.encode(appMeta)
        try metaData.write(to: temporary.appendingPathComponent("MaestroApp.plist"))
        try SetupPackage.replace(at: url, with: temporary, preserveUnwrittenItems: !wroteHardware)
        print("[Maestro] savePresetBundle: bundle saved to \(url.lastPathComponent)")
        if associateWithDocument {
            currentSetupURL = url
            setupDocumentEdited = setupEditRevision != editRevision
            WindowDocumentBridge.updateEditedState()
        }
    }

    /// Load and apply an `.mst2` preset from disk, supporting both bundle and flat formats.
    ///
    /// **Bundle format** (directory): Passes the device plist path to the daemon via `'AERP'`.
    /// The daemon calls SetSettingsFromDictionary() + ApplySettingsToHardware(), restoring
    /// the full hardware state. Also reads `MaestroApp.plist` for channel names. Supports
    /// original Maestro 2 bundles created by the legacy app.
    ///
    /// **Flat format** (file): Applies via the existing `applyPreset()` path (our old format).
    ///
    /// Evidence: recallMaestroPreferenceFile (APMaestroFullViewWindow.m:497)
    ///           kmAEstroPropertyRecallPreferenceFile = 'AERP' (mAEstro.h:1199)
    ///           ONEv2DeviceController.cpp:3239–3331 — daemon recall implementation
    @MainActor
    @discardableResult
    func loadPresetBundle(from url: URL, associateWithDocument: Bool = true,
                          recallsMonitorLevels: Bool = true) async throws -> String? {
        guard !hardwareWritesSuspended else { throw DeviceConnectionError.notConnected }
        // A setup file from Apogee's Maestro 2 holds nothing this app can
        // apply, on any connection: say so instead of failing oddly or silently.
        if let names = try? FileManager.default.contentsOfDirectory(atPath: url.path),
           PresetPackageKind.classify(fileNames: names) == .maestro2 {
            throw PresetOpenError.maestro2
        }
        guard setupRecallDepth == 0 else {
            throw DeviceConnectionError.transportError("A setup recall is already in progress.")
        }
        setupRecallDepth += 1
        setupRecallRevision &+= 1
        defer {
            setupRecallDepth -= 1
            setupRecallRevision &+= 1
            suppressMacVolumeOverlay()
        }
        var notice: String?
        if let connection = device as? ThunderboltDeviceConnection {
            try await loadThunderboltPresetBundle(from: url, connection: connection,
                                                  recallsMonitorLevels: recallsMonitorLevels)
            if associateWithDocument {
                currentSetupURL = url
                setupDocumentEdited = false
                WindowDocumentBridge.updateEditedState()
            }
            return nil
        }
        if FileManager.default.fileExists(atPath: url.appendingPathComponent(ThunderboltPreset.fileName).path) {
            throw ThunderboltPreset.RecallError.unsupported("this hardware preset requires a ThunderBridge connection.")
        }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)

        if isDir.boolValue {
            // Bundle format — delegate hardware state recall to daemon
            let contents = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil)

            // Find the device plist (any .plist that isn't our app metadata)
            let devicePlist = contents.first(where: {
                $0.pathExtension == "plist" && $0.lastPathComponent != "MaestroApp.plist"
            })
            if let plist = devicePlist, let conn = device as? CoreAudioDeviceConnection {
                try conn.recallPreferenceFile(from: plist.path)
                // Give the daemon time to apply all settings before re-reading state.
                // The daemon call is synchronous in the HAL plugin dispatch but hardware
                // writes are USB round-trips that may take a few frames.
                try? await Task.sleep(for: .milliseconds(300))
                await refreshAfterRecall()
            } else if devicePlist == nil {
                print("[Maestro] loadPresetBundle: no device plist found in bundle — app-only recall")
            }

            // Read app-level metadata (channel names)
            let metaURL = url.appendingPathComponent("MaestroApp.plist")
            var namesRestored = false
            if FileManager.default.fileExists(atPath: metaURL.path),
               let data = try? Data(contentsOf: metaURL),
               let meta = try? PropertyListDecoder().decode(MaestroPreset.self, from: data) {
                if !meta.channelNames.isEmpty,
                   let encoded = try? JSONEncoder().encode(meta.channelNames),
                   let str = String(data: encoded, encoding: .utf8) {
                    UserDefaults.standard.set(str, forKey: mixerNamesKey())
                    namesRestored = true
                }
            }
            // Over USB a package holds nothing else that is applied.
            if device is XPCDeviceConnection {
                notice = namesRestored ? PresetOpenError.usbNamesOnlyNotice : PresetOpenError.usbNothingNotice
            }
            print("[Maestro] loadPresetBundle: bundle loaded from \(url.lastPathComponent)")
        } else {
            // Flat format — our legacy single-file format
            let preset = try MaestroPreset.load(from: url)
            await applyPreset(preset)
            print("[Maestro] loadPresetBundle: flat preset loaded from \(url.lastPathComponent)")
        }
        viewReloadToken = UUID()
        if associateWithDocument {
            currentSetupURL = url
            setupDocumentEdited = false
            WindowDocumentBridge.updateEditedState()
        }
        return notice
    }

    /// Re-read hardware-tracked state into AppState after a daemon preset recall.
    ///
    /// The daemon has just applied a preset, which may have changed output level, mute,
    /// and other properties that AppState caches. Re-reading ensures the volume HUD,
    /// menu bar level indicator, and volume keys stay in sync with hardware.
    @MainActor
    func refreshAfterRecall() async {
        guard let dev = device else { return }
        let inLine = await Self.speakersInLine(dev, known: speakerOutputMode)
        if !inLine, let att = (try? await dev.getProperty(PropertyAddress(selector: .outputLevel)))?.asUInt32 {
            speakerLevel = -Double(att)
        }
        if !inLine, let muted = (try? await dev.getProperty(PropertyAddress(selector: .outputMute)))?.asBool {
            speakerMuted = muted
        }
        if let level = (try? await dev.getProperty(PropertyAddress(selector: .headphone1Level)))?.asUInt32 { hp1Level = -Double(level) }
        if let muted = (try? await dev.getProperty(PropertyAddress(selector: .headphone1Mute)))?.asBool { hp1Muted = muted }
        if let level = (try? await dev.getProperty(PropertyAddress(selector: .headphone2Level)))?.asUInt32 { hp2Level = -Double(level) }
        if let muted = (try? await dev.getProperty(PropertyAddress(selector: .headphone2Mute)))?.asBool { hp2Muted = muted }
    }

    /// Whether a preset's speaker, headphone and device settings are sent:
    /// only to a Symphony I/O on port 1 (converters on port 2 behind it do
    /// not change that).
    static func presetWritesSymphonySettings(connectedUnit: ConnectedUnit?) -> Bool {
        connectedUnit == nil
    }

    /// Apply a `MaestroPreset` to the current device and update AppState.
    ///
    /// Writes all preset fields to the device via daemon IPC. Updates AppState speaker
    /// level/mute immediately so the volume key handler stays in sync. Sets
    /// `viewReloadToken` to trigger `.task(id:)` view reloads.
    ///
    /// Evidence: `og_source/maestro2/App/Views/APMaestroFullViewWindow.m` lines 497-650
    @MainActor
    func applyPreset(_ preset: MaestroPreset) async {
        // Update AppState immediately so volume key + menu bar extra reflect new state
        speakerLevel = preset.outputLevel
        speakerMuted = preset.outputMuted

        if let dev = device {
            let write: (PropertyAddress, PropertyValue) async -> Void = { addr, value in
                do {
                    try await dev.setProperty(addr, value: value)
                } catch {
                    print("[Maestro] applyPreset: \(addr.selector) write failed: \(error)")
                }
            }
            // Output (the Mac's volume and mute: on converters the driver
            // gives these to Mixer 1).
            await write(PropertyAddress(selector: .outputLevel), .uint32(UInt32(max(0, -preset.outputLevel))))
            await write(PropertyAddress(selector: .outputMute), .bool(preset.outputMuted))
        }

        // The rest are Symphony I/O commands: never to converters on port 1.
        if let dev = device, Self.presetWritesSymphonySettings(connectedUnit: connectedUnit) {
            let write: (PropertyAddress, PropertyValue) async -> Void = { addr, value in
                do { try await dev.setProperty(addr, value: value) } catch {
                    print("[Maestro] applyPreset: \(addr.selector) write failed: \(error)")
                }
            }
            await write(PropertyAddress(selector: .outputDim), .bool(preset.outputDimmed))
            await write(PropertyAddress(selector: .outputSumToMono), .bool(preset.outputSumToMono))
            // HP1
            await write(PropertyAddress(selector: .headphone1Level), .uint32(UInt32(max(0, -preset.hp1Level))))
            await write(PropertyAddress(selector: .headphone1Mute), .bool(preset.hp1Muted))
            await write(PropertyAddress(selector: .headphone1RoutingID), .uint32(preset.hp1RoutingID))
            // HP2
            await write(PropertyAddress(selector: .headphone2Level), .uint32(UInt32(max(0, -preset.hp2Level))))
            await write(PropertyAddress(selector: .headphone2Mute), .bool(preset.hp2Muted))
            await write(PropertyAddress(selector: .headphone2RoutingID), .uint32(preset.hp2RoutingID))
            // Device settings
            for digital in PresetDigitalWrites.writes(for: preset, layout: cardLayout) {
                await write(digital.address, .uint32(digital.value))
                rememberDigitalSetting(digital.address.selector, slot: Int(digital.address.element),
                                       value: digital.value)
            }
            await refreshChannelNaming()
            await write(PropertyAddress(selector: .peakHoldMode), .uint32(preset.peakHoldMode))
            let overHold = MeterDisplaySettings.OverHoldMode.allCases
                .first { $0.wireValue == preset.overHoldMode }?.userFacingValue.wireValue
                ?? MeterDisplaySettings.OverHoldMode.twoSeconds.wireValue
            await write(PropertyAddress(selector: .oversHoldMode), .uint32(overHold))
            await write(PropertyAddress(selector: .metersShowInput, element: 1), .uint32(preset.meterBank1Source))
            await write(PropertyAddress(selector: .metersShowInput, element: 2), .uint32(preset.meterBank2Source))
        }

        // Restore input channel states to UserDefaults (applied by InputControlsView on reload)
        let store = channelStateStore
        if !preset.inputChannelStates.isEmpty {
            store.save(preset.inputChannelStates.enumerated().map { $0.element.recalled(identity: nil, boardSlot: 1, channel: $0.offset) }, for: ChannelStateStore.inputKey)
        }

        // Restore output channel states to UserDefaults (applied by OutputControlsView on reload)
        if !preset.outputChannelStates.isEmpty {
            store.save(preset.outputChannelStates, for: ChannelStateStore.outputKey)
        }

        // Restore mixer channel names to UserDefaults (P3F-39).
        // @AppStorage("mixerChannelNames") in MixerView observes UserDefaults — updates automatically.
        if !preset.channelNames.isEmpty,
           let data = try? JSONEncoder().encode(preset.channelNames),
           let str = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(str, forKey: mixerNamesKey())
        }

        // Trigger view reloads (.task(id: appState.viewReloadToken) re-runs on UUID change)
        viewReloadToken = UUID()
        print("[Maestro] applyPreset: applied \(preset.inputChannelStates.count) input channels, \(preset.channelNames.count) channel names, output level \(preset.outputLevel) dB")
    }
}
