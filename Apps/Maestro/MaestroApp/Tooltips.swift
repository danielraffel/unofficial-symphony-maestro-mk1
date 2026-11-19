import SwiftUI

/// Shared preference-aware help text for Maestro controls.
struct MaestroHelpModifier: ViewModifier {
    static let preferenceKey = "showTooltips"

    @AppStorage("showTooltips") private var showTooltips = true

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: preferenceKey) as? Bool ?? true
    }

    let text: String

    // An empty help string shows no tooltip. Keeping one view structure means
    // toggling the preference never rebuilds controls or resets their state.
    func body(content: Content) -> some View {
        content.help(showTooltips ? text : "")
    }
}

extension View {
    /// Shows the control's help text when tooltips are enabled in Preferences.
    func maestroHelp(_ text: String) -> some View {
        modifier(MaestroHelpModifier(text: text))
    }
}
