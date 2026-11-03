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
        appState.readASPVolume()
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
        appState.readASPMute()
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
final class AppState {
    /// Currently connected device (real or simulated).
    var device: (any DeviceConnection)?
    /// Currently selected navigation area.
    var selectedArea: NavigationArea = .launchDefault
    /// Whether to show the About panel.
    var showAbout: Bool = false
    /// Whether to show the Help panel.
    var showHelp: Bool = false
    /// Connection mode.
    var connectionMode: ConnectionMode = .disconnected
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
        ChannelStateStore(layout: cardLayout, isSimulatingCards: cardSimulation != nil)
    }
    /// Whether hardware initialization is complete. Views must wait for this
    /// before reading from the device to avoid racing with initializeDevice().
    var isHardwareInitialized: Bool = false
    /// Metering-only CoreAudio connection. Used when `device` is XPCDeviceConnection
    /// (daemon broken on macOS 26) — software metering still works via CoreAudio IO proc
    /// because it reads from the USB audio class driver, not the daemon.
    var meterDevice: CoreAudioDeviceConnection?
    /// Whether input trim faders are visible. Persisted via UserDefaults.
    var showInputTrims: Bool = UserDefaults.standard.bool(forKey: "inputShowTrims") {
        didSet { UserDefaults.standard.set(showInputTrims, forKey: "inputShowTrims") }
    }
    /// Whether output trim faders are visible. Persisted via UserDefaults.
    var showOutputTrims: Bool = UserDefaults.standard.bool(forKey: "outputShowTrims") {
        didSet { UserDefaults.standard.set(showOutputTrims, forKey: "outputShowTrims") }
    }
    /// Whether idle meter segments show muted zone coloring (green/yellow/red gradient).
    /// Disabled by default — when enabled, unlit segments show a dim version of their zone color.
    var showMeterZoneColoring: Bool = UserDefaults.standard.bool(forKey: "meterZoneColoring") {
        didSet { UserDefaults.standard.set(showMeterZoneColoring, forKey: "meterZoneColoring") }
    }
    /// Current speaker level (shared between monitor panel and volume key handler).
    var speakerLevel: Double = -20
    /// Current speaker mute state (shared between monitor panel and volume key handler).
    var speakerMuted: Bool = false
    /// Current Analog Out Format. Line mode disables the speaker monitor controls
    /// while Core Audio volume/mute writes are redirected to Headphone 1.
    var speakerOutputMode: UInt32 = SpeakerOutputLogic.stereo
    /// HP1 level (shared between output tab and monitor panel).
    var hp1Level: Double = -20
    /// HP1 mute (shared between output tab and monitor panel).
    var hp1Muted: Bool = false
    /// HP2 level (shared between output tab and monitor panel).
    var hp2Level: Double = -20
    /// HP2 mute (shared between output tab and monitor panel).
    var hp2Muted: Bool = false
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
        if connectionMode == .disconnected && transportPresent && transportType != nil {
            return connectionPresentation.endpointLabel
        }
        return statusMessage
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
    /// Incremented when routing mode changes (DAW ↔ Direct Monitor).
    /// MixerView observes via .onChange to apply force-mute/restore.
    var routingModeChangeCount: Int = 0
    /// Tracks whether meter polling was in a disconnected/failed state.
    private var meterPollWasDisconnected: Bool = false
    /// Debounce guard — prevents rapid recovery events from triggering multiple re-syncs.
    private var lastRecoveryTime: Date = .distantPast

    // MARK: - USB Health Check

    /// Periodic USB health check task. Sends a lightweight read every 30s to detect
    /// stale connections. If the read fails, the proxy's recovery logic fires automatically.
    private var healthCheckTask: Task<Void, Never>?
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
    /// Avoid reopening the private dext client on every one-second failed probe.
    private var thunderboltControlReconnectAttempted = false
    /// Bounded tolerance for a DriverKit upgrade handoff, owned by the health
    /// loop and read by the meter poll so the two can never disagree. sysextd
    /// can list a `terminating_for_upgrade` record for hours (2026-10-21: build
    /// 105 still owned the PCI card 30+ min after 106 was "activated"), so a
    /// second registration must never be an unbounded exception.
    private var thunderboltExtensionSwapGrace = ExtensionSwapGrace()
    private var thunderboltExtensionSwapGraceActive = false
    /// Linear trims (SW Return faders, pan, mute) applied to the host-playback
    /// peaks that drive the ThunderBridge SW Return meters, so they read the
    /// same as USB, where the proxy meters after its own trims. Refreshed from
    /// the persisted mixer state whenever the mixer saves and when polling starts.
    var softwareReturnMeterGains: [(left: Double, right: Double)] = [(1.0, 1.0), (1.0, 1.0)]

    /// Recompute `softwareReturnMeterGains` from the persisted SW Return state.
    @MainActor
    func refreshSoftwareReturnMeterGains() {
        let defaults = UserDefaults.standard
        var pan = 0.0
        var muted = false
        var level = 0.0
        if let data = defaults.data(forKey: "mixerState_swReturn"),
           let saved = try? JSONDecoder().decode(MixerChannelState.self, from: data) {
            pan = saved.pan
            muted = saved.isMuted
            level = saved.level
        }
        let linked = defaults.object(forKey: "mixerSWReturnFadersLinked") as? Bool ?? true
        // Pan/mute are shared; the per-side fader levels are stored per mixer.
        softwareReturnMeterGains = (0..<2).map { mixer in
            let left = linked ? level
                : (defaults.object(forKey: "mixerSWReturnLeftLevel_\(mixer)") as? Double ?? level)
            let right = linked ? level
                : (defaults.object(forKey: "mixerSWReturnRightLevel_\(mixer)") as? Double ?? level)
            return SoftwareReturnMeterGain.gains(
                leftLevelDB: left, rightLevelDB: right, pan: pan, isMuted: muted)
        }
    }

    /// A ThunderBridge device that just appeared (or a Symphony that just
    /// powered on) should become the default output only once its endpoint is
    /// live; the device exists even while the Symphony is off (dext 108+).
    private var pendingAutoSwitchAfterReconnect = false
    /// The USB auto-switch's wait for "Maestro USB"; cancelled by a newer edge.
    private var usbAutoSwitchTask: Task<Void, Never>?
    /// Re-probes a present ThunderBridge while the app is connected over USB.
    private var thunderboltWatchTask: Task<Void, Never>?
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

    func startUSBHealthCheck() {
        healthCheckTask?.cancel()
        guard let xpcDev = device as? XPCDeviceConnection else { return }
        healthCheckTask = Task.detached(priority: .low) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                do {
                    // Lightweight probe — deviceMode is a small read, no side effects.
                    // EP0 control transfers don't interfere with isochronous audio stream.
                    _ = try await xpcDev.getProperty(PropertyAddress(selector: .deviceMode))
                } catch {
                    // Read failed → proxy's usb_vendor_read recovery will fire automatically.
                    // No action needed here — recovery is proxy-side.
                    print("[Maestro] USB health check: read failed (\(error)) — proxy recovery should fire")
                }
            }
        }
    }

    func stopUSBHealthCheck() {
        healthCheckTask?.cancel()
        healthCheckTask = nil
    }

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
                let audioRunning = tb.isAudioRunning
                let healthy = verdict.isLive
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
                        await self.reconnectHardware()
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
                        self.stopMeterPolling()
                        self.statusMessage = "Symphony disconnected"
                        self.connectionMode = .disconnected
                        // Keep the transport visible in the sidebar. The
                        // ThunderBridge PCI service is still present; only
                        // the downstream Symphony endpoint failed its probe.
                        self.transportPresent = true
                        self.isHardwareInitialized = false
                        self.thunderboltHardwareResponsive = false
                        self.clearMeterState()
                        self.viewReloadToken = UUID()
                        // A powered-off Symphony can leave the PCI/Core Audio
                        // service registered while its existing IOUserClient
                        // has gone stale. Reopen only this private control path;
                        // the next health iterations will promote the device
                        // back to Connected once timing and XLink both answer.
                        if !self.thunderboltControlReconnectAttempted {
                            self.thunderboltControlReconnectAttempted = true
                            if let tb = self.device as? ThunderboltDeviceConnection {
                                tb.reconnectDextClient()
                            }
                        }
                    }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
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
    }

    @MainActor
    private func clearMeterState() {
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

    /// The Device Info panel's last assembled content, published by System Setup when it
    /// loads. The About box copies it so a bug report is one Copy button, not two pages;
    /// nil until System Setup has been opened once, and the About box falls back to what
    /// this object knows on its own.
    var deviceInfoSnapshot: DeviceInfoReport?

    /// What `sysextd` reports about the ThunderBridge driver extension, fetched once at
    /// launch. Empty means nothing is registered; nil means the query itself failed,
    /// which is a different claim and is reported as such.
    var installedDexts: [InstalledDextInfo]?

    /// Slot 0 board type WITH provenance.
    var primaryBoardReading: BoardTypeReading {
        BoardTypeReading(card: primaryBoardType, source: primaryBoardSource)
    }
    /// Slot 1 board type WITH provenance.
    var secondaryBoardReading: BoardTypeReading {
        BoardTypeReading(card: secondaryBoardType, source: secondaryBoardSource)
    }

    /// Every user-facing channel count in the app, derived from the two slots.
    ///
    /// Views ask this and nothing else: strip counts, routing columns, mixer
    /// channels, digital pairs, headphone sources and the S/PDIF popups all come
    /// from here, so a card change moves them together. See ``CardLayout`` for
    /// why the `*PairsPerBoard` bus-slice counts must never be used for this.
    ///
    /// `isKnown` is false only while slot 1 has told us nothing at all —
    /// a *detected* empty slot 2 is knowledge, and contributes nothing.
    var cardLayout: CardLayout {
        CardLayout(
            slot1: primaryBoardType,
            slot2: secondaryBoardType,
            isKnown: primaryBoardSource != .unknown || primaryBoardType != .none
                || secondaryBoardSource != .unknown || secondaryBoardType != .none,
            fallbackChannelCount: device?.identifier.mode.channelCount ?? 16)
    }

    /// Changes whenever the installed cards change, so a view can rebuild its
    /// strip arrays. `initializeChannels()` runs from `.task` before the async
    /// `readCardTypes()` has answered, and `ForEach(0..<min(channels.count, n))`
    /// then pins the pre-detection count permanently.
    var cardLayoutToken: Int {
        Int(primaryBoardType.rawValue) << 8 | Int(secondaryBoardType.rawValue)
    }

    /// Load cached board types from UserDefaults (called at init, before USB reads).
    ///
    /// Everything restored here is marked `.cached` - a restore is not a
    /// measurement, and `readCardTypes()` upgrades a slot to `.detected` only when
    /// a live read actually succeeds.
    func loadCachedBoardTypes() {
        let defaults = UserDefaults.standard
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
        let defaults = UserDefaults.standard
        defaults.set(Int(primaryBoardType.rawValue), forKey: "cachedPrimaryBoardType")
        defaults.set(Int(secondaryBoardType.rawValue), forKey: "cachedSecondaryBoardType")
    }

    // MARK: - Live Meters (P3F-30)

    /// Real-time meter levels for input channels (dBFS, -60..0).
    var inputMeterLevels: [Double] = []
    /// Real-time meter levels for output channels (dBFS, -60..0).
    var outputMeterLevels: [Double] = []
    /// Peak hold values for input meters — rises instantly, decays at ~8 dB/sec.
    var inputPeakHold: [Double] = []
    /// Peak hold values for output meters — rises instantly, decays at ~8 dB/sec.
    var outputPeakHold: [Double] = []
    /// Digital input meter levels (ADAT/Optical) — 24 values for up to 12 stereo pairs.
    /// TDM provides 8 per board (words 8-15, 24-31); remaining slots stay at -60 dB.
    var digitalInputMeterLevels: [Double] = Array(repeating: -60.0, count: 24)
    /// Peak hold for digital input meters.
    var digitalInputPeakHold: [Double] = Array(repeating: -60.0, count: 24)
    /// Digital output meter levels (ADAT/Optical) — 24 values for up to 12 stereo pairs.
    /// TDM provides 8 per board (words 8-15, 24-31); remaining slots stay at -60 dB.
    var digitalOutputMeterLevels: [Double] = Array(repeating: -60.0, count: 24)
    /// Peak hold for digital output meters.
    var digitalOutputPeakHold: [Double] = Array(repeating: -60.0, count: 24)
    /// Mixer TDM meter levels — 8 values from hardware (TDM group 2):
    ///   [0..1] = Mixer 0 SW Return L/R, [2..3] = Mixer 1 SW Return L/R,
    ///   [4..5] = Mixer 0 Master L/R,    [6..7] = Mixer 1 Master L/R.
    /// Evidence: SymphonyIO.cpp:7029-7052, SymphonyIOMixer.h:18-20.
    var mixerMeterLevels: [Double] = Array(repeating: -60.0, count: 8)
    /// Meter polling task handle.
    private var meterPollingTask: Task<Void, Never>?
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
    /// Meter routing state requested on the previous poll (true = Output).
    /// A change means the firmware's next reply is its zeroed/phantom buffer
    /// (SymphonyIOMeterManager.cpp:159-163, :204-207) and must be discarded.
    private var lastMeterPollWantedOutput: Bool? = nil
    /// Cached output routes (destination byte -> source byte) for the software
    /// output meter model; re-read from RoutingStateCache every ~2 s.
    private var softwareOutputRoutes: [UInt8: UInt8] = [:]
    private var softwareOutputRoutesPollStamp: Int = -1
    /// Count of consecutive all-zero TDM reads. Used to detect when signal stops
    /// and begin decaying held meter values (firmware returns zeros when idle too).
    private var tdmZeroReadCount: Int = 0

    // MARK: - ASP Volume Sync

    /// Exact CoreAudio name of the USB AudioServerPlugin device. Single source of truth so a
    /// rename in ApogeeDriver.cpp (dp.Name) only needs updating here. Must match that value.
    static let aspUSBDeviceName = "Symphony I/O : Maestro USB"

    /// AudioDeviceID of the ASP "Symphony I/O : Maestro USB" virtual device.
    /// Used to listen for volume/mute changes from media keys.
    private var aspDeviceID: AudioDeviceID = kAudioObjectUnknown
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
        knownSymphonyDeviceIDs = Set(CoreAudioDeviceConnection.discoverAllSymphonyIO().map { $0.audioDeviceID })
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
            Self.tbLog.notice("audio device removed while \(String(describing: self.connectionMode), privacy: .public) — transport gone, reconnect retry starts")
            stopThunderboltHealthCheck()
            statusMessage = "Disconnected"
            connectionMode = .disconnected
            transportType = nil
            transportPresent = false
            isHardwareInitialized = false
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
                    self.pendingAutoSwitchAfterReconnect = true
                    await self.reconnectHardware()
                    break
                }
            }
        }
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
        let simulationRequest: CardConfiguration?
        do {
            simulationRequest = try SimulatedDevice.simulationRequest()
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

        // Discover hardware via CoreAudio. Prefers Thunderbolt (lower latency PCIe DMA)
        // over USB (via XPC proxy). Both paths connect to the same Symphony IO hardware.
        //
        // NOT under card simulation: a real unit on this machine would otherwise
        // win, `readCardTypes()` would overwrite the forced board types with the
        // detected ones (and cache them), and the harness would push mixer and
        // routing writes at hardware it was never meant to touch.
        let discovered: [CoreAudioDeviceConnection.DiscoveredSymphonyIO]
        if simulationRequest == nil {
            print("[Maestro] AppState.init: Discovering Symphony IO via CoreAudio...")
            discovered = CoreAudioDeviceConnection.discoverAllSymphonyIO()
        } else {
            print("[Maestro] CARD SIMULATION: hardware discovery skipped — session pinned to the simulated unit")
            discovered = []
        }
        if let pref = Self.preferredDevice(in: discovered) {
        let best = pref.device
            let audioDeviceID = best.audioDeviceID
            let identifier = best.identifier
            print("[Maestro] AppState.init: Found \(best.name) via \(best.transportType.displayName) (AudioDeviceID: \(audioDeviceID), PID: 0x\(String(identifier.productID, radix: 16)))")

            if best.transportType == .thunderbolt {
                // ── Thunderbolt path: standard CoreAudio properties → AudioDriverKit dext
                let tbDevice = pref.tbConnection ?? ThunderboltDeviceConnection(identifier: identifier, audioDeviceID: audioDeviceID)
                self.device = tbDevice
                self.connectionMode = .hardware
                self.transportType = .thunderbolt
                self.transportPresent = true
                self.statusMessage = "Connected via ThunderBridge"
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
                    return
                }
            } else {
                // ── USB path: XPC proxy → USB vendor EP0 commands
                let xpcDevice = XPCDeviceConnection(identifier: identifier)
                self.device = xpcDevice
                self.connectionMode = .hardware
                self.transportType = .usb
                self.transportPresent = true
                self.statusMessage = "Connected via USB"
                self.isHardwareInitialized = true
                self.activeAudioDeviceID = audioDeviceID
                print("[Maestro] AppState.init: Connected to hardware via XPC proxy (USB)")

                // Sync SW Return state with proxy — the proxy persists across app restarts
                // so its mute/gain/pan may be stale from a previous session.
                if let data = UserDefaults.standard.data(forKey: "mixerState_swReturn"),
                   let saved = try? JSONDecoder().decode(MixerChannelState.self, from: data) {
                    xpcDevice.setSwReturnMute(saved.isMuted)
                    xpcDevice.setSwReturnLevel(saved.level)
                    xpcDevice.setSwReturnPan(saved.pan)
                    print("[Maestro] AppState.init: Synced persisted SW Return to proxy")
                } else {
                    xpcDevice.setSwReturnMute(false)
                    xpcDevice.setSwReturnLevel(0)
                    xpcDevice.setSwReturnPan(0)
                    print("[Maestro] AppState.init: Synced SW Return defaults to proxy")
                }

                // Sync routing mode with proxy
                let routingMode = UserDefaults.standard.integer(forKey: "routingMode")
                xpcDevice.setRoutingMode(routingMode)
                if routingMode == 0 {
                    for mixerID: UInt16 in 1...2 {
                        for ch: UInt16 in 0..<32 {
                            xpcDevice.sendMixerParam(usbCmd: 0xB3, mixer: mixerID, channel: ch, value: 1)
                        }
                    }
                    print("[Maestro] AppState.init: DAW mode — force-muted HW inputs")
                }
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

            return
        }

        if simulationRequest == nil {
            print("[Maestro] AppState.init: No Symphony IO device found via CoreAudio")
        }

        // Fall back to simulated device. Under card simulation this must be the
        // device that PRESENTS those cards -- its identifier.mode channel count
        // and per-channel property scoping follow the simulated modules -- or the
        // pages render a 16ch unit's counts over a simulated 32ch card pair and
        // the screenshots prove nothing.
        let simDevice = AppState.makeSimulatedDevice(configuration: simulationRequest)
        self.device = simDevice
        self.connectionMode = cardSimulation != nil ? .simulated : .disconnected
        self.statusMessage = AppState.simulatedStatusMessage(configuration: simulationRequest)
        self.isHardwareInitialized = true
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
    @MainActor
    func readCardTypes() async {
        guard let device = self.device else { return }
        // ThunderBridge's dext returns a validity bit alongside each raw
        // OptionBoardType value, so a valid raw zero means the slot was
        // measured empty. USB's proxy cannot make that distinction and keeps
        // the conservative unknown behavior below.
        let thunderboltReadDistinguishesEmptySlot = device is ThunderboltDeviceConnection
        if let raw = (try? await device.getProperty(PropertyAddress(selector: .primaryBoardType)))?.asUInt32,
           raw <= UInt32(UInt8.max),
           let card = IOCardType(rawValue: UInt8(raw)) {
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

        // Secondary board: retry up to 3 times with increasing delays.
        // The XMOS USB controller may need time between sequential slot reads.
        for attempt in 1...3 {
            if attempt > 1 {
                try? await Task.sleep(for: .milliseconds(100 * attempt))
            }
            if let raw = (try? await device.getProperty(PropertyAddress(selector: .secondaryBoardType)))?.asUInt32,
               raw <= UInt32(UInt8.max),
               let card = IOCardType(rawValue: UInt8(raw)),
               (card != .none || thunderboltReadDistinguishesEmptySlot) {
                self.secondaryBoardType = card
                self.secondaryBoardSource = .detected
                print("[Maestro] Secondary board: \(card.digitalLabel) (raw=\(raw)) [attempt \(attempt)]")
                saveBoardTypeCache()
                return
            }
        }
        print("[Maestro] Secondary board: not detected after 3 attempts (hardware may have 1 board or slot 1 empty)")
        // Still save whatever we got (primary may have succeeded)
        saveBoardTypeCache()
    }

    /// Sync persisted output routing to hardware on connect/reconnect.
    /// Reads cached dual routing state and writes each (row, col) pair to USB.
    /// Called after readCardTypes() so board types are available for byte mapping.
    @MainActor
    func syncOutputRoutingToHardware() async {
        guard let device = self.device else { return }
        // The cache is keyed by product ID, so ThunderBridge (0x12) and the USB
        // modes keep separate tables. On ThunderBridge the dext replays its
        // default routing on every Start and in-place recovery, so without this
        // replay the user's routes silently revert after each power cycle or
        // replug. Replaying a cached table can target stale board destinations
        // after a card change, so on ThunderBridge require this session's card
        // types to have been detected (the same provenance rule Reset Routing
        // applies) before writing anything.
        if transportType == .thunderbolt,
           let reason = RoutingResetGuard.refusalReason(board1: primaryBoardReading, board2: secondaryBoardReading) {
            print("[Maestro] syncOutputRouting: skipped on ThunderBridge — \(reason)")
            return
        }
        let id = device.identifier
        let cache = RoutingStateCache(direction: "output", productID: id.productID)
        guard let routes = cache.loadMulti(), !routes.isEmpty else {
            print("[Maestro] syncOutputRouting: no cached routes, proxy defaults apply")
            return
        }
        let board1 = self.primaryBoardType
        let board2 = self.secondaryBoardType
        let swPairs = (id.mode.channelCount) / 2
        var written = 0
        for (row, cols) in routes.sorted(by: { $0.key < $1.key }) {
            for col in cols.sorted() {
                guard let destByte = IOCardType.columnToRoutingByte(
                    col: col, isInput: false, board1: board1, board2: board2
                ) else { continue }
                let srcLeft: UInt8
                if row < swPairs {
                    srcLeft = SymphonyIORoutingAddress.hostPlaybackBase(for: transportType ?? .usb) + UInt8(row * 2)
                } else if row == swPairs {
                    srcLeft = SymphonyIORoutingAddress.mixer0Base
                } else if row == swPairs + 1 {
                    srcLeft = SymphonyIORoutingAddress.mixer1Base
                } else { continue }
                do {
                    try await writeOutputRoutePair(destLeft: destByte, srcLeft: srcLeft, device: device)
                    written += 1
                } catch {}
            }
        }
        print("[Maestro] syncOutputRouting: wrote \(written) cached routes to hardware")
    }

    /// Write one mono output route to whichever routing stage the transport
    /// uses: the Symphony's `0x31` table over USB, the ThunderBridge card's
    /// output routing registers on ThunderBridge (`ThunderboltCardRouting`).
    @MainActor
    func writeOutputRoute(destination: UInt8, source: UInt8, device: any DeviceConnection) async throws {
        if let thunderbolt = device as? ThunderboltDeviceConnection {
            guard let route = ThunderboltCardRouting.route(destination: destination, source: source) else {
                throw DeviceConnectionError.transportError(
                    "No ThunderBridge card route for output \(destination) ← source \(source)")
            }
            try thunderbolt.setCardOutputRoute(route)
            return
        }
        try await device.setProperty(
            PropertyAddress(selector: .routing, scope: .output, element: UInt32(destination)),
            value: .uint32(UInt32(source)))
    }

    /// Write a stereo output route (left + right channel) — see ``writeOutputRoute``.
    @MainActor
    func writeOutputRoutePair(destLeft: UInt8, srcLeft: UInt8, device: any DeviceConnection) async throws {
        try await writeOutputRoute(destination: destLeft, source: srcLeft, device: device)
        try await writeOutputRoute(destination: destLeft &+ 1,
                                   source: SymphonyIORoutingAddress.rightChannelSource(of: srcLeft),
                                   device: device)
    }

    /// Mark hardware as ready for property access.
    /// XPC connection is ready immediately — proxy handles USB init on boot.
    @MainActor
    func initializeHardwareIfNeeded() async {
        guard connectionMode == .hardware else { return }
        if transportType == .thunderbolt {
            statusMessage = "Connected via ThunderBridge"
        } else {
            statusMessage = "Connected via XPC proxy"
        }
        isHardwareInitialized = true
    }

    /// True while a reconnect is in flight. Coalesces overlapping reconnects: the auto-switch
    /// device-list listener can fire repeatedly during a Thunderbolt flap or a quick unplug/replug,
    /// and two interleaved reconnects would double-install the ASP volume listener and orphan the
    /// software-metering IOProc. The check+set below is atomic (no await between them) on the MainActor.
    private var isReconnecting = false

    struct PreferredDevice {
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
        let probe = ThunderboltDeviceConnection(identifier: tb.identifier, audioDeviceID: tb.audioDeviceID)
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
        if cardSimulation != nil {
            print("[Maestro] CARD SIMULATION: reconnect ignored — session pinned to the simulated unit")
            return
        }
        if isReconnecting { return }
        isReconnecting = true
        defer { isReconnecting = false }
        stopThunderboltHealthCheck()
        thunderboltWatchTask?.cancel()
        stopMeterPolling()
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

        // Close existing connection if any
        if let existing = device {
            await existing.disconnect()
        }
        stopASPVolumeSync()
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
        lastMeterPollWantedOutput = nil

        // Retry discovery with delays — XMOS firmware needs time to re-enumerate
        for attempt in 1...5 {
            let discovered = CoreAudioDeviceConnection.discoverAllSymphonyIO()
            if let pref = Self.preferredDevice(in: discovered) {
        let best = pref.device
                let audioDeviceID = best.audioDeviceID
                let identifier = best.identifier
                print("[Maestro] reconnect: Found \(best.name) via \(best.transportType.displayName)")

                if best.transportType == .thunderbolt {
                    let tbDevice = pref.tbConnection ?? ThunderboltDeviceConnection(identifier: identifier, audioDeviceID: audioDeviceID)
                    self.device = tbDevice
                    // Probe before declaring the endpoint ready. A powered-off
                    // Symphony can still be discoverable as a ThunderBridge
                    // Core Audio object, but its dext timing-health selector
                    // now performs the serialized live XLink check.
                    let reconnectProbe = pref.tbVerdict ?? tbDevice.probeEndpoint()
                    guard case .live(let health) = reconnectProbe else {
                        Self.tbLog.notice("reconnect: endpoint \(reconnectProbe.label, privacy: .public) — staying disconnected, health loop continues")
                        // Remember the Core Audio object so a later cable pull is
                        // recognised as a removal even in this disconnected state.
                        self.activeAudioDeviceID = audioDeviceID
                        self.connectionMode = .disconnected
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
                    self.thunderboltHardwareResponsive = true
                    self.connectionMode = .hardware
                    self.transportType = .thunderbolt
                    self.transportPresent = true
                    self.statusMessage = "Connected via ThunderBridge"
                    self.isHardwareInitialized = true
                    self.activeAudioDeviceID = audioDeviceID
                    self.aspDeviceID = audioDeviceID
                    print("[Maestro] reconnect TB timing health: rate=\(health.sampleRate) frame=\(health.frameReadback)/\(health.expectedFrame) latency=\(health.inputLatency)/\(health.outputLatency) safety=\(health.inputSafety)/\(health.outputSafety) int=0x\(String(health.intStatus, radix: 16)) xlink=0x\(String(health.xlinkStatus, radix: 16))")
                    self.applyPendingAutoSwitch()
                } else {
                    let xpcDevice = XPCDeviceConnection(identifier: identifier)
                    self.device = xpcDevice
                    self.connectionMode = .hardware
                    self.transportType = .usb
                    self.transportPresent = true
                    self.statusMessage = "Connected via USB"
                    self.isHardwareInitialized = true
                    self.activeAudioDeviceID = audioDeviceID
                    self.applyPendingAutoSwitch()
                    self.startThunderboltWatchWhileOnUSB(discovered)

                    // Sync persisted SW Return state on reconnect
                    if let data = UserDefaults.standard.data(forKey: "mixerState_swReturn"),
                       let saved = try? JSONDecoder().decode(MixerChannelState.self, from: data) {
                        xpcDevice.setSwReturnMute(saved.isMuted)
                        xpcDevice.setSwReturnLevel(saved.level)
                        xpcDevice.setSwReturnPan(saved.pan)
                    } else {
                        xpcDevice.setSwReturnMute(false)
                        xpcDevice.setSwReturnLevel(0)
                        xpcDevice.setSwReturnPan(0)
                    }

                    // Sync routing mode on reconnect
                    let routingMode = UserDefaults.standard.integer(forKey: "routingMode")
                    xpcDevice.setRoutingMode(routingMode)
                    if routingMode == 0 {
                        for mixerID: UInt16 in 1...2 {
                            for ch: UInt16 in 0..<32 {
                                xpcDevice.sendMixerParam(usbCmd: 0xB3, mixer: mixerID, channel: ch, value: 1)
                            }
                        }
                        print("[Maestro] reconnect: DAW mode — force-muted HW inputs")
                    }
                }

                // Read card types and sync routing (USB-specific but harmless for TB)
                await self.readCardTypes()
                await self.syncOutputRoutingToHardware()

                let meterCA = CoreAudioDeviceConnection(identifier: identifier, audioDeviceID: audioDeviceID)
                if Self.softwareMeteringOptedIn { meterCA.startSoftwareMetering() }
                self.meterDevice = meterCA

                startASPVolumeSync()

                // Own the polling lifecycle here rather than relying on the view's
                // isHardwareInitialized observer. A reconnect can go true -> false
                // -> true before SwiftUI observes it, including a cold offline
                // launch. Start only after the new meter connection is installed.
                startMeterPolling()
                if transportType == .thunderbolt {
                    startThunderboltHealthCheck()
                }

                // Every value the panels are showing was read over the connection we
                // just tore down, so force them to re-read. Device Info is the visible
                // case: it resolves board types with its own live 0xA1 read, and
                // without this Rescan left it reporting "(cached -- not detected this
                // session)" even after `readCardTypes()` above had just read both
                // slots back off the hardware.
                viewReloadToken = UUID()
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
            while !Task.isCancelled {
                guard let self, let device = self.device, self.isHardwareInitialized else {
                    try? await Task.sleep(for: .milliseconds(100))
                    continue
                }
                // Hardware TDM metering via XPC (command 0x30) — reads directly from
                // FPGA meter taps. Provides both input AND output levels. More accurate
                // than software metering and shows output from all audio clients.
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
                            self.tdmMeteringAvailable = true
                            // Re-evaluate the firmware's output-meter verdict after
                            // a power-cycle rather than trusting the old latch.
                            self.tdmOutputMeteringUnavailable = false
                            self.tdmOutputEchoStreak = 0
                            self.lastMeterPollWantedOutput = nil
                            let autoRecover = UserDefaults.standard.object(forKey: "autoRecoverMixerState") as? Bool ?? true
                            if autoRecover {
                                let now = Date()
                                if now.timeIntervalSince(self.lastRecoveryTime) > 5.0 {
                                    self.lastRecoveryTime = now
                                    self.deviceRecoveryCount += 1
                                    // Re-sync SW Return state to proxy from persisted state
                                    if let data = UserDefaults.standard.data(forKey: "mixerState_swReturn"),
                                       let saved = try? JSONDecoder().decode(MixerChannelState.self, from: data) {
                                        xpcDev.setSwReturnMute(saved.isMuted)
                                        xpcDev.setSwReturnLevel(saved.level)
                                        xpcDev.setSwReturnPan(saved.pan)
                                    }
                                    // Re-sync routing mode to proxy
                                    let routingMode = UserDefaults.standard.integer(forKey: "routingMode")
                                    xpcDev.setRoutingMode(routingMode)
                                    if routingMode == 0 {
                                        for mixerID: UInt16 in 1...2 {
                                            for ch: UInt16 in 0..<32 {
                                                xpcDev.sendMixerParam(usbCmd: 0xB3, mixer: mixerID, channel: ch, value: 1)
                                            }
                                        }
                                        print("[Maestro] USB recovery: DAW mode — force-muted HW inputs")
                                    }
                                    print("[Maestro] USB recovery detected — re-syncing mixer state (count: \(self.deviceRecoveryCount))")
                                }
                            }
                        }
                        // FPGA meter registers return all-zero when no new data is ready.
                        // Real data arrives ~3Hz (every ~300ms). All-zero means "no update" —
                        // NOT silence. Skip zero reads to hold the last valid meter values.
                        // After 20+ consecutive zero reads (~1s), start decaying toward silence
                        // so meters don't hang when signal truly stops.
                        let inHasData: Bool
                        if let inVal, case .data(let inBytes) = inVal,
                           !inBytes.allSatisfy({ $0 == 0 }) {
                            newInput = self.tdmMeterLevels(from: inBytes, count: self.inputMeterLevels.count)
                            // Extract digital (ADAT/Optical) meter levels: words 8-15 (Board 1), 24-31 (Board 2)
                            let rawDigital = self.tdmDigitalMeterLevels(from: inBytes)
                            self.digitalInputMeterLevels = self.smoothMeterLevels(self.digitalInputMeterLevels, raw: rawDigital)
                            inHasData = true
                        } else {
                            newInput = self.inputMeterLevels
                            inHasData = false
                        }
                        let outHasData: Bool
                        if let outVal, case .data(let outBytes) = outVal,
                           !outBytes.allSatisfy({ $0 == 0 }) {
                            newOutput = self.tdmMeterLevels(from: outBytes, count: self.outputMeterLevels.count)
                            // Extract digital output (ADAT/Optical) meter levels: words 8-15, 24-31
                            let rawDigitalOut = self.tdmDigitalMeterLevels(from: outBytes)
                            self.digitalOutputMeterLevels = self.smoothMeterLevels(self.digitalOutputMeterLevels, raw: rawDigitalOut)
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
                            let rawMixer = self.tdmMeterLevels(from: mixBytes, count: 8)
                            self.mixerMeterLevels = self.smoothMeterLevels(self.mixerMeterLevels, raw: rawMixer)
                        } else if self.tdmZeroReadCount > 20 {
                            let silenceMix = [Double](repeating: -60.0, count: 8)
                            self.mixerMeterLevels = self.smoothMeterLevels(self.mixerMeterLevels, raw: silenceMix)
                        }

                        // Software return meters — measured in proxy render callback.
                        // TDM group 2 does NOT contain SW Return levels without
                        // FPGA meter tap configuration (which requires XLink register
                        // writes, not possible via USB EP0).
                        if let peaks = softwareOutputPeaks, peaks.count >= 2 {
                            // Each mixer can select a different USB playback pair through
                            // AEsR.  The proxy reports one peak pair per USB pair, so do
                            // not mirror channels 0/1 into both mixer strips.
                            func softwareReturnDBFS(mixer: Int) -> (Double, Double) {
                                let source = UserDefaults.standard.integer(
                                    forKey: "mixerSoftwareReturnSource_\(mixer)")
                                let left = source * 2
                                guard left >= 0, left + 1 < peaks.count else {
                                    return (-60.0, -60.0)
                                }
                                return (
                                    SoftwareOutputMeterMap.dBFS(linearPeak: peaks[left]),
                                    SoftwareOutputMeterMap.dBFS(linearPeak: peaks[left + 1])
                                )
                            }
                            let mixer0Peaks = softwareReturnDBFS(mixer: 0)
                            let mixer1Peaks = softwareReturnDBFS(mixer: 1)

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
                            // USB audio bypasses the FPGA mixer so TDM master output
                            // doesn't include it. Convert linear peaks to dB and take max.
                            if self.mixerMeterLevels.count >= 8 {
                                // swPeaks are already dBFS. (The previous code
                                // re-applied 20*log10 to a dB value, which is never
                                // > 0, so the master blend was always -60.)
                                self.mixerMeterLevels[4] = max(self.mixerMeterLevels[4], mixer0Peaks.0)
                                self.mixerMeterLevels[5] = max(self.mixerMeterLevels[5], mixer0Peaks.1)
                                self.mixerMeterLevels[6] = max(self.mixerMeterLevels[6], mixer1Peaks.0)
                                self.mixerMeterLevels[7] = max(self.mixerMeterLevels[7], mixer1Peaks.1)
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
                        func dbW(_ i: Int) -> Double {
                            guard i < words.count else { return -60 }
                            let peak = Double((words[i] >> 24) & 0xFF)
                            return peak <= 0 ? -60 : max(-60, 20 * log10(peak / 256.0))
                        }
                        var inp = self.inputMeterLevels
                        for i in 0..<inp.count { inp[i] = dbW(i) }            // inputs 0-31
                        var outp = self.outputMeterLevels
                        for i in 0..<outp.count { outp[i] = dbW(64 + i) }     // host playback 64-95
                        newInput = inp
                        newOutput = outp

                        // If the FPGA input snapshot is unavailable or silent,
                        // use the active Core Audio capture stream. This keeps
                        // Input and Mixer hardware strips useful on cards whose
                        // meter DMA is absent, while preserving real FPGA peaks.
                        if (newInput.max() ?? -60.0) <= -60.0,
                           let softwareInputs = self.meterDevice?.softwareInputPeaks(),
                           !softwareInputs.isEmpty {
                            newInput = self.linearMeterLevels(
                                from: softwareInputs, count: self.inputMeterLevels.count)
                        }

                        // The FPGA meter DMA is not available on every
                        // ThunderBridge FPGA revision and may be temporarily
                        // unavailable during a dext handoff. Maestro already
                        // has a Core Audio IOProc on this device, so use its
                        // host-playback peaks as a bounded fallback. This is
                        // also the correct source for SW Return because that
                        // strip represents host playback before the card mixer.
                        if let softwarePeaks = self.meterDevice?.softwareOutputPeaks(),
                           softwarePeaks.count >= 2 {
                            func softwareReturnDBFS(mixer: Int) -> (Double, Double) {
                                let source = UserDefaults.standard.integer(
                                    forKey: "mixerSoftwareReturnSource_\(mixer)")
                                let left = source * 2
                                guard left >= 0, left + 1 < softwarePeaks.count else {
                                    return (-60.0, -60.0)
                                }
                                // Mirror what the card mixer delivers: USB meters
                                // SW Return after level/pan/mute in the proxy, so
                                // apply the same trims to the host-playback peaks
                                // here (SoftwareReturnMeterGain) rather than
                                // showing the pre-mixer signal.
                                let trim = self.softwareReturnMeterGains[min(max(0, mixer), 1)]
                                return (
                                    SoftwareOutputMeterMap.dBFS(linearPeak: softwarePeaks[left] * Float(trim.left)),
                                    SoftwareOutputMeterMap.dBFS(linearPeak: softwarePeaks[left + 1] * Float(trim.right))
                                )
                            }
                            let mixer0Peaks = softwareReturnDBFS(mixer: 0)
                            let mixer1Peaks = softwareReturnDBFS(mixer: 1)
                            // Prefer the software source when the FPGA snapshot
                            // is all silence. Keep real FPGA values when present.
                            if newOutput.max() ?? -60.0 <= -60.0 {
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
                                    rawMixer[4] = max(rawMixer[4], mixer0Peaks.0)
                                    rawMixer[5] = max(rawMixer[5], mixer0Peaks.1)
                                    rawMixer[6] = max(rawMixer[6], mixer1Peaks.0)
                                    rawMixer[7] = max(rawMixer[7], mixer1Peaks.1)
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
                            let trim = self.softwareReturnMeterGains[0]
                            func trimmed(_ dB: Double, _ gain: Double) -> Double {
                                gain <= 0 ? -60.0 : max(-60.0, dB + 20.0 * log10(gain))
                            }
                            rawMixer[0] = trimmed(dbW(64), trim.left)
                            rawMixer[1] = trimmed(dbW(65), trim.right)
                            rawMixer[4] = dbW(128); rawMixer[5] = dbW(129)
                            if self.mixerMeterLevels.count >= 8 {
                                rawMixer[6] = dbW(130); rawMixer[7] = dbW(131)
                            }
                            self.mixerMeterLevels = self.smoothMeterLevels(
                                self.mixerMeterLevels, raw: rawMixer)
                        }
                        // Keep the SW Return source visible even when the FPGA
                        // snapshot has no mixer tap data. The Core Audio IOProc
                        // measures the same host playback that feeds PCI_OUT.
                        if let softwarePeaks = self.meterDevice?.softwareOutputPeaks(),
                           softwarePeaks.count >= 2,
                           self.mixerMeterLevels.count >= 4 {
                            func softwareReturnDBFS(mixer: Int) -> (Double, Double) {
                                let source = max(0, min(7, UserDefaults.standard.integer(
                                    forKey: "mixerSoftwareReturnSource_\(mixer)")))
                                let left = source * 2
                                guard left + 1 < softwarePeaks.count else { return (-60.0, -60.0) }
                                // Mirror what the card mixer delivers: USB meters
                                // SW Return after level/pan/mute in the proxy, so
                                // apply the same trims to the host-playback peaks
                                // here (SoftwareReturnMeterGain) rather than
                                // showing the pre-mixer signal.
                                let trim = self.softwareReturnMeterGains[min(max(0, mixer), 1)]
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
                                rawMixer[4] = max(rawMixer[4], mix0.0)
                                rawMixer[5] = max(rawMixer[5], mix0.1)
                                rawMixer[6] = max(rawMixer[6], mix1.0)
                                rawMixer[7] = max(rawMixer[7], mix1.1)
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
                        // FPGA meter DMA may be unavailable on this card revision.
                        // Preserve useful host-playback meters through the Core
                        // Audio IOProc while the device is actively streaming.
                        if allowMeterRead,
                           let softwarePeaks = self.meterDevice?.softwareOutputPeaks(),
                           softwarePeaks.count >= 2 {
                            if let softwareInputs = self.meterDevice?.softwareInputPeaks(),
                               !softwareInputs.isEmpty {
                                newInput = self.linearMeterLevels(
                                    from: softwareInputs, count: self.inputMeterLevels.count)
                            } else {
                                newInput = [Double](repeating: -60.0, count: self.inputMeterLevels.count)
                            }
                            newOutput = self.linearMeterLevels(
                                from: softwarePeaks, count: self.outputMeterLevels.count)
                            let sources = [0, 1].map { mixer in
                                let pair = max(0, min(7, UserDefaults.standard.integer(
                                    forKey: "mixerSoftwareReturnSource_\(mixer)"))) * 2
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
                        self.digitalOutputMeterLevels = [Double](repeating: -60.0, count: self.digitalOutputMeterLevels.count)
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
                self.inputPeakHold = self.advancePeakHold(self.inputPeakHold, levels: self.inputMeterLevels)
                self.outputPeakHold = self.advancePeakHold(self.outputPeakHold, levels: self.outputMeterLevels)
                self.digitalInputPeakHold = self.advancePeakHold(self.digitalInputPeakHold, levels: self.digitalInputMeterLevels)
                self.digitalOutputPeakHold = self.advancePeakHold(self.digitalOutputPeakHold, levels: self.digitalOutputMeterLevels)
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
    private func smoothMeterLevels(_ previous: [Double], raw: [Double]) -> [Double] {
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

    /// Advance peak hold values: snap up to new peaks, decay at 0.4 dB/frame when level drops.
    private func advancePeakHold(_ hold: [Double], levels: [Double]) -> [Double] {
        var result = hold
        for i in 0..<min(hold.count, levels.count) {
            result[i] = levels[i] > hold[i] ? levels[i] : max(hold[i] - 0.4, levels[i])
        }
        return result
    }

    /// Stop meter polling.
    @MainActor
    func stopMeterPolling() {
        meterPollingTask?.cancel()
        meterPollingTask = nil
    }

    // MARK: - ASP Volume Sync

    /// Find the "Symphony I/O : Maestro" ASP device and install CoreAudio property
    /// listeners for volume and mute changes. When the user presses media volume
    /// keys, the ASP handles them. This listener syncs those changes back to the
    /// Maestro app UI so the volume knob reflects the current hardware state.
    func startASPVolumeSync() {
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

    /// Read current volume from the synced audio device and update speakerLevel.
    func readASPVolume() {
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
                speakerLevel = Double(dB)
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
                speakerLevel = dB
            }
        }
    }

    /// Read current mute state from the ASP device and update speakerMuted.
    func readASPMute() {
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
            speakerMuted = muted != 0
        }
    }

    /// Write the current speakerLevel to the synced audio device.
    /// For USB: writes VolumeScalar to ASP so macOS Sound slider reflects the change.
    /// For Thunderbolt: no-op — ThunderboltDeviceConnection already writes VolumeDecibels
    /// directly, and the listener callback keeps the UI in sync.
    func writeASPVolume(_ dB: Double) {
        guard aspDeviceID != kAudioObjectUnknown else { return }
        if transportType == .thunderbolt {
            // ThunderboltDeviceConnection.setProperty already wrote VolumeDecibels
            // to this same device. No need to double-write.
            return
        }
        aspWriteTimestamp = Date()
        // Convert dB (-64..0) to scalar (0..1): scalar = (dB + 64) / 64
        let scalar = Float32(max(0, min(1, (dB + 64.0) / 64.0)))
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = scalar
        AudioObjectSetPropertyData(aspDeviceID, &addr, 0, nil,
                                   UInt32(MemoryLayout<Float32>.size), &value)
    }

    /// Write mute state to the synced audio device.
    /// For Thunderbolt: no-op (same reason as writeASPVolume).
    func writeASPMute(_ muted: Bool) {
        guard aspDeviceID != kAudioObjectUnknown else { return }
        if transportType == .thunderbolt { return }
        aspWriteTimestamp = Date()
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(aspDeviceID, &addr, 0, nil,
                                   UInt32(MemoryLayout<UInt32>.size), &value)
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
    private func tdmMeterLevels(from data: Data, count: Int) -> [Double] {
        var result = [Double](repeating: -60.0, count: count)
        let wordsAvailable = data.count / 2

        // Slot layout, from SymphonyIO.cpp:6931-6944 and :7041-7100:
        //
        //   words  0-15 -> card slot 0      words 16-31 -> card slot 1
        //
        // That outer split is rigid and card-INDEPENDENT: each physical slot
        // always gets exactly 16 words whether the card fills 0, 8 or 16 of
        // them. Within a board the order is N analog first, then digital.
        //
        // N is per-card and we previously hardcoded it to 8, which is right only
        // for the 8x8 cards. A 16x16 or AD16/DA16 contributes 16 analog and no
        // digital, and a MicPre8 contributes NOTHING -- it has no converters of
        // its own and delegates onto the primary card's analog inputs. Hardcoding
        // 8 sends channels 9-16 of a 16-channel card into slot 1's region, which
        // on a 16x16 + MicPre8 unit is empty.
        let hasTwoBoards = data.count >= 64 && count > 8
        let board0Analog = self.primaryBoardType.analogInputChannels
        // Fall back to the old assumption only when detection has told us
        // nothing; a wrong guess is better placed at 8 than at 0.
        let analogOnBoard0 = board0Analog > 0 ? board0Analog : 8

        for i in 0..<count {
            // Mapping lives in MaestroCore.MeterSlotMap so it can be proven
            // against card configurations we do not physically own.
            let wordIndex = MeterSlotMap.analogWordIndex(
                channel: i, analogOnBoard0: analogOnBoard0, twoBoards: hasTwoBoards)

            guard wordIndex < wordsAvailable else { continue }

            let lo = UInt16(data[wordIndex * 2])
            let hi = UInt16(data[wordIndex * 2 + 1])
            let rawWord = lo | (hi << 8)
            let meterVal = rawWord & 0x3FFF  // mask off over bit
            if meterVal <= 0x40 {
                result[i] = -60.0  // silence threshold
            } else {
                let dBFS = 20.0 * log10(Double(meterVal) / 16383.0)
                result[i] = max(dBFS, -60.0)
            }
        }
        return result
    }

    // MARK: Software output meters (hardware output group proven absent)

    /// Re-read the app's persisted output routing for the software output meter
    /// model. Cheap (UserDefaults) but not free at 20 fps, so throttled to ~2 s.
    private func refreshSoftwareOutputRoutesIfNeeded(pollCount: Int) {
        guard softwareOutputRoutesPollStamp < 0 || pollCount - softwareOutputRoutesPollStamp >= 40 else { return }
        softwareOutputRoutesPollStamp = pollCount
        softwareOutputRoutes = cachedOutputRouteMap()
    }

    /// The output routes the app has persisted, as destination byte -> source
    /// byte. Mirrors the encoding in `syncOutputRoutingToHardware` exactly, but
    /// READS ONLY -- nothing here touches the device.
    func cachedOutputRouteMap() -> [UInt8: UInt8] {
        guard let device = self.device else { return [:] }
        let id = device.identifier
        let cache = RoutingStateCache(direction: "output", productID: id.productID)
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
                if row < swPairs {
                    srcLeft = SymphonyIORoutingAddress.hostPlaybackBase(for: transportType ?? .usb) + UInt8(row * 2)
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
            max(0, min(7, UserDefaults.standard.integer(
                forKey: "mixerSoftwareReturnSource_\(mixer)")))
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

    /// Digital output levels (same 24-slot layout as `tdmDigitalMeterLevels`).
    private func softwareDigitalOutputLevels(peaks: [Float]) -> [Double] {
        var result = [Double](repeating: -60.0, count: 24)
        let mixerSources = cachedMixerSoftwareReturnSources()
        let board0Words = MeterSlotMap.digitalWordIndices(
            analogOnBoard: self.primaryBoardType.analogOutputChannels, boardIndex: 0)
        let board1Words = MeterSlotMap.digitalWordIndices(
            analogOnBoard: self.secondaryBoardType.analogOutputChannels, boardIndex: 1)
        for (i, word) in board0Words.enumerated() where i < 8 {
            let source = SoftwareOutputMeterMap.source(forWord: word, routes: softwareOutputRoutes)
            result[i] = SoftwareOutputMeterMap.level(
                for: source, usbPeaks: peaks,
                mixerSoftwareReturnSources: mixerSources)
        }
        for (i, word) in board1Words.enumerated() where i < 8 {
            let source = SoftwareOutputMeterMap.source(forWord: word, routes: softwareOutputRoutes)
            result[8 + i] = SoftwareOutputMeterMap.level(
                for: source, usbPeaks: peaks,
                mixerSoftwareReturnSources: mixerSources)
        }
        return result
    }

    /// Extract digital (ADAT/Optical) meter levels from TDM input data.
    /// Board 1 digital = words 8-15, Board 2 digital = words 24-31.
    /// Returns 24 values: [Board1_dig0..dig7, Board2_dig0..dig7, 8×-60].
    /// The last 8 are placeholders for ADAT ports 3 (channels 17-24).
    ///
    /// Evidence: `SymphonyIOBoard_AnalogOptical.cpp` — 8 analog + 8 digital per board
    private func tdmDigitalMeterLevels(from data: Data) -> [Double] {
        var result = [Double](repeating: -60.0, count: 24)
        let wordsAvailable = data.count / 2

        // Digital channels sit AFTER that board's analog channels within its own
        // 16-word region (SymphonyIO.cpp:7041-7100). The offset is therefore
        // per-card, not a fixed 8: a 16x16 or AD16/DA16 uses all 16 words for
        // analog and contributes NO digital region at all. Reading words 8-15
        // unconditionally showed such a card's analog channels 9-16 as though
        // they were ADAT meters.
        let board0Words = MeterSlotMap.digitalWordIndices(
            analogOnBoard: self.primaryBoardType.analogInputChannels, boardIndex: 0)
        let board1Words = MeterSlotMap.digitalWordIndices(
            analogOnBoard: self.secondaryBoardType.analogInputChannels, boardIndex: 1)

        // Board 0 digital
        for (i, wordIndex) in board0Words.enumerated() {
            guard wordIndex < wordsAvailable else { continue }
            let lo = UInt16(data[wordIndex * 2])
            let hi = UInt16(data[wordIndex * 2 + 1])
            let rawWord = lo | (hi << 8)
            let meterVal = rawWord & 0x3FFF
            if meterVal > 0x40 {
                result[i] = max(20.0 * log10(Double(meterVal) / 16383.0), -60.0)
            }
        }
        // Board 1 digital
        for (i, wordIndex) in board1Words.enumerated() {
            guard wordIndex < wordsAvailable else { continue }
            let lo = UInt16(data[wordIndex * 2])
            let hi = UInt16(data[wordIndex * 2 + 1])
            let rawWord = lo | (hi << 8)
            let meterVal = rawWord & 0x3FFF
            if meterVal > 0x40 {
                result[8 + i] = max(20.0 * log10(Double(meterVal) / 16383.0), -60.0)
            }
        }
        return result
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
    func makePreset() async -> MaestroPreset {
        var preset = MaestroPreset()

        // Output level + mute: kept in sync by volume key handler + loadMonitorState
        preset.outputLevel = speakerLevel
        preset.outputMuted = speakerMuted

        if let dev = device {
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
            if let fmt = (try? await dev.getProperty(PropertyAddress(selector: .opticalInFormat)))?.asUInt32 {
                preset.opticalInFormat = fmt
            }
            if let rep = (try? await dev.getProperty(PropertyAddress(selector: .spdifReplaceID)))?.asUInt32 {
                preset.spdifReplaceID = rep
            }
            if let mir = (try? await dev.getProperty(PropertyAddress(selector: .spdifMirrorID)))?.asUInt32 {
                preset.spdifMirrorID = mir
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
        if let str = UserDefaults.standard.string(forKey: "mixerChannelNames"),
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
    func savePresetBundle(to url: URL) async throws {
        let fm = FileManager.default
        // Remove existing item at this URL (NSSavePanel may reuse the name)
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        // Create the bundle directory
        try fm.createDirectory(at: url, withIntermediateDirectories: true)

        // 1. Ask daemon to write the full hardware state plist inside the bundle.
        //    The daemon uses 'AESP' (AudioObjectSetPropertyData) to write a file like
        //    "USBAudio_Symphony I_O_<UID>.plist". This goes through the Apogee HAL plugin
        //    which converts the CFString path to a C string and forwards to the daemon.
        //    Non-fatal: if the daemon can't write (HAL plugin missing, permission issue),
        //    we still save our own MaestroApp.plist so presets aren't empty.
        if let conn = device as? CoreAudioDeviceConnection {
            let fileName = conn.getPreferenceFileName()
                ?? "USBAudio_Symphony_IO.plist"  // fallback if HAL plugin absent
            let plistPath = url.appendingPathComponent(fileName).path
            do {
                try conn.storePreferenceFile(at: plistPath)
                print("[Maestro] savePresetBundle: daemon plist written to \(fileName)")
            } catch {
                print("[Maestro] savePresetBundle: daemon AESP failed (\(error)) — saving app-only preset")
            }
        } else {
            print("[Maestro] savePresetBundle: no CoreAudioDeviceConnection — daemon plist skipped")
        }

        // 2. Save app-level metadata alongside the daemon plist.
        //    This always runs regardless of daemon AESP success, ensuring the preset
        //    bundle is never empty. Contains all device state our app can read/write.
        let appMeta = await makePreset()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let metaData = try encoder.encode(appMeta)
        try metaData.write(to: url.appendingPathComponent("MaestroApp.plist"))
        print("[Maestro] savePresetBundle: bundle saved to \(url.lastPathComponent)")
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
    func loadPresetBundle(from url: URL) async throws {
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
            if FileManager.default.fileExists(atPath: metaURL.path),
               let data = try? Data(contentsOf: metaURL),
               let meta = try? PropertyListDecoder().decode(MaestroPreset.self, from: data) {
                if !meta.channelNames.isEmpty,
                   let encoded = try? JSONEncoder().encode(meta.channelNames),
                   let str = String(data: encoded, encoding: .utf8) {
                    UserDefaults.standard.set(str, forKey: "mixerChannelNames")
                }
            }
            print("[Maestro] loadPresetBundle: bundle loaded from \(url.lastPathComponent)")
        } else {
            // Flat format — our legacy single-file format
            let preset = try MaestroPreset.load(from: url)
            await applyPreset(preset)
            print("[Maestro] loadPresetBundle: flat preset loaded from \(url.lastPathComponent)")
        }
        viewReloadToken = UUID()
    }

    /// Re-read hardware-tracked state into AppState after a daemon preset recall.
    ///
    /// The daemon has just applied a preset, which may have changed output level, mute,
    /// and other properties that AppState caches. Re-reading ensures the volume HUD,
    /// menu bar level indicator, and volume keys stay in sync with hardware.
    @MainActor
    private func refreshAfterRecall() async {
        guard let dev = device else { return }
        if let att = (try? await dev.getProperty(PropertyAddress(selector: .outputLevel)))?.asUInt32 {
            speakerLevel = -Double(att)
        }
        if let muted = (try? await dev.getProperty(PropertyAddress(selector: .outputMute)))?.asBool {
            speakerMuted = muted
        }
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
            // Output
            await write(PropertyAddress(selector: .outputLevel), .uint32(UInt32(max(0, -preset.outputLevel))))
            await write(PropertyAddress(selector: .outputMute), .bool(preset.outputMuted))
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
            await write(PropertyAddress(selector: .opticalInFormat), .uint32(preset.opticalInFormat))
            await write(PropertyAddress(selector: .spdifReplaceID), .uint32(preset.spdifReplaceID))
            await write(PropertyAddress(selector: .spdifMirrorID), .uint32(preset.spdifMirrorID))
            await write(PropertyAddress(selector: .peakHoldMode), .uint32(preset.peakHoldMode))
            await write(PropertyAddress(selector: .oversHoldMode), .uint32(preset.overHoldMode))
            await write(PropertyAddress(selector: .metersShowInput, element: 1), .uint32(preset.meterBank1Source))
            await write(PropertyAddress(selector: .metersShowInput, element: 2), .uint32(preset.meterBank2Source))
        }

        // Restore input channel states to UserDefaults (applied by InputControlsView on reload)
        let store = channelStateStore
        if !preset.inputChannelStates.isEmpty {
            store.save(preset.inputChannelStates, for: ChannelStateStore.inputKey)
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
            UserDefaults.standard.set(str, forKey: "mixerChannelNames")
        }

        // Trigger view reloads (.task(id: appState.viewReloadToken) re-runs on UUID change)
        viewReloadToken = UUID()
        print("[Maestro] applyPreset: applied \(preset.inputChannelStates.count) input channels, \(preset.channelNames.count) channel names, output level \(preset.outputLevel) dB")
    }
}
