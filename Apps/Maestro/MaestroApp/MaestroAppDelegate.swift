import AppKit

@MainActor
final class MaestroAppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?
    /// SIGTERM (the installer's `pkill`, a logout, `kill`) runs the normal quit,
    /// so Identify OFF and the other quit-time cleanup still happen.
    private var terminationSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        terminationSignal = source
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
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
