import AppKit
import CoreServices
import MaestroCore
import MaestroDevice
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let maestroSetup = UTType(importedAs: "com.danielraffel.maestro.setup", conformingTo: .package)
}

enum SetupEditKind: String, CaseIterable {
    case routing
    case mixer
    case inputChannelSettings
    case outputChannelSettings
    case monitorControls
    case deviceSettings

    case presetRecallOrStore, loopSync, clockSource, sampleRate, vBus, identify, meterClear

    var marksDocumentEdited: Bool {
        switch self {
        case .routing, .mixer, .inputChannelSettings, .outputChannelSettings, .monitorControls, .deviceSettings:
            return true
        case .presetRecallOrStore, .loopSync, .clockSource, .sampleRate, .vBus, .identify, .meterClear:
            return false
        }
    }
}

enum SetupQuitReason: CaseIterable {
    case appMenu, signal, systemSession, external

    init(fromMenu: Bool, fromSignal: Bool, appleEventReason: OSType?) {
        if fromSignal {
            self = .signal
            return
        }
        switch appleEventReason {
        case kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAERestart, kAEShowShutdownDialog, kAEShutDown:
            self = .systemSession
        case nil:
            self = fromMenu ? .appMenu : .external
        default:
            self = .external
        }
    }
}

enum SetupDocumentDecision: Equatable {
    case askToSave
    case proceed

    static func forQuit(reason: SetupQuitReason, edited: Bool, hasCurrentFile: Bool) -> Self {
        guard reason == .appMenu else { return .proceed }
        return forClose(edited: edited, hasCurrentFile: hasCurrentFile)
    }

    static func forClose(edited: Bool, hasCurrentFile: Bool) -> Self {
        edited && hasCurrentFile ? .askToSave : .proceed
    }
}

enum SetupDocumentTitle {
    static func title(for url: URL?) -> String {
        guard let url else { return "Maestro" }
        let name = url.deletingPathExtension().lastPathComponent
        return name.isEmpty ? "Maestro" : name
    }
}

enum LevelOverlaySource: Equatable {
    case speaker, headphone1, headphone2
    case micPre(channel: Int, grouped: Bool, level: AnalogInputLevel)

    static func micPre(channel: Int, state: InputChannelState?) -> Self {
        .micPre(channel: channel, grouped: (state?.group ?? InputChannelLogic.groupOff) != InputChannelLogic.groupOff,
                level: state.flatMap { AnalogInputLevel(rawValue: $0.inputType) } ?? .mic)
    }
}

enum LevelOverlayChangeSource {
    case frontPanel
    case maestroControl
    case macVolume
    case maestroUSBVolume

    var showsOverlay: Bool {
        switch self {
        case .frontPanel, .maestroControl, .macVolume: return true
        case .maestroUSBVolume: return false
        }
    }
}

enum LevelOverlayMath {
    static func filledBars(level: Double, range: ClosedRange<Double>) -> Int {
        guard level.isFinite, range.upperBound > range.lowerBound else { return 0 }
        let fraction = (level - range.lowerBound) / (range.upperBound - range.lowerBound)
        return Int((min(1, max(0, fraction)) * 16).rounded(.down))
    }
}

struct LevelOverlayContent: View {
    let source: LevelOverlaySource
    let level: Double
    let muted: Bool

    private var title: String {
        switch source {
        case .speaker: return "Speakers"
        case .headphone1: return "Headphone 1"
        case .headphone2: return "Headphone 2"
        case .micPre(let channel, let grouped, let level):
            return "\(level == .instrument ? "Instrument" : "Mic") \(grouped ? "GP" : String(channel + 1))"
        }
    }

    private var symbol: String {
        switch source {
        case .speaker: return muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        case .headphone1, .headphone2: return "headphones"
        case .micPre(_, _, let level): return level == .instrument ? "guitars.fill" : "mic.fill"
        }
    }

    private var bars: Int {
        switch source {
        case .micPre(_, _, let inputLevel):
            return LevelOverlayMath.filledBars(level: level, range: InputChannelLogic.gainRange(for: inputLevel) ?? 0...85)
        default: return LevelOverlayMath.filledBars(level: level, range: -64...0)
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 34))
                .opacity(muted ? 0.35 : 1)
            Text(title).font(.headline)
            HStack(spacing: 2) {
                ForEach(0..<16, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(index < bars ? Color.primary : Color.secondary.opacity(0.22))
                        .frame(width: 8, height: 7)
                }
            }
            .opacity(muted ? 0.35 : 1)
        }
        .padding(18)
        .frame(width: 209, height: 206)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .allowsHitTesting(false)
    }
}

@MainActor
final class LevelOverlayController {
    static let shared = LevelOverlayController()
    private var panel: NSPanel?
    private var host: NSHostingView<LevelOverlayContent>?
    private var hideTask: Task<Void, Never>?
    private var generation = 0

    func show(source: LevelOverlaySource, level: Double, muted: Bool) {
        guard UserDefaults.standard.object(forKey: "showLevelOverlay") as? Bool ?? true else { return }
        hideTask?.cancel()
        generation &+= 1
        let shownGeneration = generation
        let content = LevelOverlayContent(source: source, level: level, muted: muted)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if let host {
            host.rootView = content
        } else {
            let host = NSHostingView(rootView: content)
            self.host = host
            panel.contentView = host
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
        position(panel)
        panel.orderFrontRegardless()
        hideTask = Task { @MainActor [weak self, weak panel] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, let self, let panel else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 1
                panel.animator().alphaValue = 0
            }
            guard !Task.isCancelled, self.generation == shownGeneration else { return }
            panel.orderOut(nil)
            self.hideTask = nil
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .init(x: 0, y: 0, width: 209, height: 206),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.frame
        panel.setFrameOrigin(.init(x: frame.midX - 104.5, y: frame.minY + 140))
    }
}

@MainActor
final class WindowDocumentBridge: NSObject, NSViewRepresentable {
    static weak var currentWindow: NSWindow?
    static weak var currentAppState: AppState?

    final class Coordinator: NSObject, NSWindowDelegate {
        weak var previousDelegate: NSWindowDelegate?

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || previousDelegate?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            if previousDelegate?.responds(to: selector) == true { return previousDelegate }
            return super.forwardingTarget(for: selector)
        }

        @MainActor
        func attach(to window: NSWindow?) {
            guard let window, window.delegate !== self else { return }
            previousDelegate = window.delegate
            window.delegate = self
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard sender === WindowDocumentBridge.currentWindow,
                  let state = WindowDocumentBridge.currentAppState,
                  let url = state.existingSetupURL(),
                  SetupDocumentDecision.forClose(edited: state.setupDocumentEdited, hasCurrentFile: true) == .askToSave else {
                return previousDelegate?.windowShouldClose?(sender) ?? true
            }
            let alert = state.unsavedSetupAlert()
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                Task { @MainActor in
                    do {
                        try await state.savePresetBundle(to: url)
                        if !state.setupDocumentEdited { sender.performClose(nil) }
                    } catch { NSAlert(error: error).runModal() }
                }
                return false
            case .alertSecondButtonReturn:
                state.setupDocumentEdited = false
                WindowDocumentBridge.updateEditedState()
                return previousDelegate?.windowShouldClose?(sender) ?? true
            default: return false
            }
        }
    }

    static func updateEditedState() {
        currentWindow?.isDocumentEdited = currentAppState?.setupDocumentEdited ?? false
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            self.updateNSView(view, context: context)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        Self.currentWindow = window
        context.coordinator.attach(to: window)
        Self.updateEditedState()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
}

@MainActor
extension AppState {
    func existingSetupURL() -> URL? {
        guard let url = currentSetupURL else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else {
            currentSetupURL = nil
            setupDocumentEdited = false
            WindowDocumentBridge.updateEditedState()
            return nil
        }
        return url
    }

    func unsavedSetupAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes to “\(setupDocumentTitle)”?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    func saveCurrentSetup(showPanel: Bool = false) async {
        let current = existingSetupURL()
        let url: URL
        if !showPanel, let current {
            url = current
        } else {
            let panel = NSSavePanel()
            panel.title = "Save Maestro Preset"
            panel.allowedContentTypes = [.maestroSetup]
            panel.nameFieldStringValue = current?.lastPathComponent ?? "Untitled.mst2"
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            url = chosen
        }
        do { try await savePresetBundle(to: url) }
        catch { NSAlert(error: error).runModal() }
    }

    func openSetupFromUser(_ url: URL) async {
        recentSetupRecallHandled = true
        do {
            if let notice = try await loadPresetBundle(from: url) {
                let alert = NSAlert()
                alert.alertStyle = .informational
                alert.messageText = notice
                alert.runModal()
            }
        } catch { NSAlert(error: error).runModal() }
    }

    func scheduleRecentSetupRecall() {
        guard !recentSetupRecallHandled, connectionMode == .hardware,
              isHardwareInitialized, let connection = device else { return }
        guard UserDefaults.standard.bool(forKey: "openMostRecentSetupAtLaunch"),
              let url = existingSetupURL() else {
            recentSetupRecallHandled = true
            return
        }
        if recentSetupRecallConnection === connection, recentSetupRecallTask != nil { return }
        recentSetupRecallTask?.cancel()
        recentSetupRecallConnection = connection
        recentSetupRecallTask = Task { [weak self] in
            guard let self else { return }
            await self.recallMostRecentSetup(from: url, on: connection)
            if !Task.isCancelled { self.recentSetupRecallTask = nil }
        }
    }

    private func recallMostRecentSetup(from url: URL, on connection: any DeviceConnection) async {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(30)
        while !Task.isCancelled, !recentSetupRecallHandled, device === connection,
              connectionMode == .hardware, currentSetupURL == url {
            guard clock.now < deadline else {
                recentSetupRecallHandled = true
                print("[Maestro] recent setup recall skipped: hardware restore did not finish within 30 seconds")
                return
            }
            if isHardwareInitialized, !hardwareWritesSuspended, recentSetupRestoreIsReady {
                recentSetupRecallHandled = true
                do { _ = try await loadPresetBundle(from: url) }
                catch { print("[Maestro] recent setup recall failed: \(error)") }
                return
            }
            try? await clock.sleep(for: .milliseconds(100))
        }
    }

    private var recentSetupRestoreIsReady: Bool {
        if let thunderbolt = device as? ThunderboltDeviceConnection {
            if portSelection.selection == .ports1And2 {
                return unitBInputRoutingAllowed && !twoUnitReplayNeeded && !twoUnitReplayRunning
            }
            guard !thunderbolt.cardMixers.needsRestore, cardMixerRestoreRun == nil else { return false }
            if cardMixerLedger.completed { return true }
            return !cardMixerRestoreAwaitingIdentity
                && !cardMixerLedger.needs.contains(true)
        }
        if device is XPCDeviceConnection {
            return usbRestoredGeneration == unitAGeneration && usbRestoreTask == nil
        }
        return true
    }
}

enum SetupPackage {
    static func replace(at destination: URL, with staged: URL, preserveUnwrittenItems: Bool) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: destination.path, isDirectory: &isDirectory) {
            if preserveUnwrittenItems, isDirectory.boolValue {
                for existing in try fm.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil) {
                    let target = staged.appendingPathComponent(existing.lastPathComponent)
                    if !fm.fileExists(atPath: target.path) {
                        try fm.copyItem(at: existing, to: target)
                    }
                }
            }
            _ = try fm.replaceItemAt(destination, withItemAt: staged)
        } else {
            try fm.moveItem(at: staged, to: destination)
        }
    }
}
