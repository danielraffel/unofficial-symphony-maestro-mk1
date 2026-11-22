import AppKit

/// Double-clicking the title bar zooms the window (or minimizes it), as in
/// other Mac apps. The toolbar's title and controls cover the title bar, and
/// AppKit's own handling does not reach the window there, so the double-click
/// is caught here: in the title-bar area, not on a control, it does what
/// System Settings › Desktop & Dock › "Double-click a window's title bar to"
/// says (Zoom by default, Minimize, or nothing).
@MainActor
enum TitleBarDoubleClick {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard event.clickCount == 2, let window = event.window,
                  isInTitleBar(event.locationInWindow, of: window),
                  !hitsControl(event.locationInWindow, in: window) else { return event }
            perform(on: window)
            return nil
        }
    }

    /// Above the content layout rect: the title bar and the toolbar that
    /// shares it.
    static func isInTitleBar(_ point: NSPoint, of window: NSWindow) -> Bool {
        point.y > window.contentLayoutRect.maxY && point.y <= window.frame.height
    }

    private static func hitsControl(_ point: NSPoint, in window: NSWindow) -> Bool {
        guard let frameView = window.contentView?.superview else { return false }
        var view = frameView.hitTest(frameView.convert(point, from: nil))
        while let v = view {
            if v is NSControl || v is NSTextView { return true }
            // SwiftUI buttons, sliders and menus in the toolbar are not
            // NSControls; their hosting views accept first mouse.
            if String(describing: type(of: v)).contains("PlatformViewHost")
                || String(describing: type(of: v)).contains("Button") { return true }
            view = v.superview
        }
        return false
    }

    enum Action: Equatable, Sendable { case zoom, minimize, none }

    /// The system's choice: "Maximize" or "Fill" zoom, "Minimize" minimizes,
    /// "None" does nothing; absent means zoom.
    nonisolated static func action(for setting: String?) -> Action {
        switch setting {
        case "Minimize": return .minimize
        case "None", "Do Nothing": return .none
        default: return .zoom
        }
    }

    private static func perform(on window: NSWindow) {
        let setting = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleActionOnDoubleClick"] as? String
        switch action(for: setting) {
        case .zoom: window.performZoom(nil)
        case .minimize: window.performMiniaturize(nil)
        case .none: break
        }
    }
}
