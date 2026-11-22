import AppKit
import CoreServices

@MainActor
final class MaestroAppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState? {
        didSet {
            if pendingOpenURL != nil { appState?.recentSetupRecallHandled = true }
            openPendingSetup()
        }
    }
    var showMainWindow: (@MainActor () -> Void)?
    private var pendingOpenURL: URL?
    private var quitFromMenuRequested = false
    private var terminatingFromSignal = false

    /// SIGTERM (the installer's `pkill` or `kill`) runs the normal quit,
    /// so Identify OFF and the other quit-time cleanup still happen.
    private var terminationSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            self?.terminatingFromSignal = true
            NSApp.terminate(nil)
        }
        source.resume()
        terminationSignal = source
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.last else { return }
        pendingOpenURL = url
        appState?.recentSetupRecallHandled = true
        openPendingSetup()
    }

    func openPendingSetup() {
        guard let state = appState, state.initialSetupRestoreFinished,
              let url = pendingOpenURL else { return }
        pendingOpenURL = nil
        showMainWindow?()
        Task { await state.openSetupFromUser(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The level overlay and front-panel sync keep running with the window closed.
        false
    }

    func quitFromMenu() {
        quitFromMenuRequested = true
        defer { quitFromMenuRequested = false }
        NSApp.terminate(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let reason = SetupQuitReason(
            fromMenu: quitFromMenuRequested,
            fromSignal: terminatingFromSignal,
            appleEventReason: event?.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue
        )
        if let state = appState,
           SetupDocumentDecision.forQuit(reason: reason, edited: state.setupDocumentEdited,
                                         hasCurrentFile: state.currentSetupURL != nil) == .askToSave,
           let url = state.existingSetupURL() {
            switch state.unsavedSetupAlert().runModal() {
            case .alertFirstButtonReturn:
                Task {
                    do {
                        try await state.savePresetBundle(to: url)
                        guard !state.setupDocumentEdited else {
                            sender.reply(toApplicationShouldTerminate: false)
                            return
                        }
                        if finishTermination(sender) == .terminateNow {
                            sender.reply(toApplicationShouldTerminate: true)
                        }
                    } catch {
                        NSAlert(error: error).runModal()
                        sender.reply(toApplicationShouldTerminate: false)
                    }
                }
                return .terminateLater
            case .alertSecondButtonReturn:
                state.setupDocumentEdited = false
            default:
                return .terminateCancel
            }
        }
        return finishTermination(sender)
    }

    private func finishTermination(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Quit at once unless a unit's Identify lights are on. Otherwise send
        // OFF first (a write started in willTerminate can be killed at exit),
        // but never let a stuck device hold up quitting: 1.5 s at most.
        guard let appState, appState.identifyA.isOn || appState.identifyB.isOn else { return .terminateNow }
        let a = appState.identifyA.reset()
        let b = appState.identifyB.reset()
        var replied = false
        let reply = { @MainActor in
            guard !replied else { return }
            replied = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        Task { @MainActor in
            await a.value
            await b.value
            reply()
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            reply()
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState?.identifyA.reset()
        appState?.identifyB.reset()
    }
}
