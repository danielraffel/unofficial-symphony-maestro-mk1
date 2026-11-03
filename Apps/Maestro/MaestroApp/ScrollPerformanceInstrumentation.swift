import Foundation
import os

/// Opt-in instrumentation for validating native horizontal scrolling.
///
/// Enable with:
///   defaults write com.danielraffel.maestro ScrollPerformanceInstrumentation -bool YES
///
/// The probe is deliberately dormant by default. When enabled, Instruments'
/// Animation Hitches and Points of Interest templates can correlate each
/// native clip-view update with the surrounding frame work.
enum ScrollPerformanceInstrumentation {
    private static let log = OSLog(
        subsystem: "com.danielraffel.maestro",
        category: "ScrollPerformance"
    )
    private static let enabledKey = "ScrollPerformanceInstrumentation"
    private static let lock = NSLock()
    private static let signpostName: StaticString = "HorizontalScroll"
    nonisolated(unsafe) private static var activeTabs: Set<String> = []
    nonisolated(unsafe) private static var endWorkItems: [String: DispatchWorkItem] = [:]

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static func record(tab: String, offset: CGFloat) {
        guard isEnabled else { return }
        os_signpost(.event, log: log, name: signpostName, "tab=%{public}s offset=%.1f", tab, Double(offset))

        lock.lock()
        let wasActive = activeTabs.contains(tab)
        if !wasActive { activeTabs.insert(tab) }
        endWorkItems[tab]?.cancel()
        let work = DispatchWorkItem {
            guard isEnabled else { return }
            os_signpost(.end, log: log, name: signpostName)
            lock.lock()
            activeTabs.remove(tab)
            endWorkItems[tab] = nil
            lock.unlock()
        }
        endWorkItems[tab] = work
        lock.unlock()

        if !wasActive {
            os_signpost(.begin, log: log, name: signpostName, "tab=%{public}s", tab)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120), execute: work)
    }
}
