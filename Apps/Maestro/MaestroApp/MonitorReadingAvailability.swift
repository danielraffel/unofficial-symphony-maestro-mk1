import SwiftUI

/// Do not display an unmeasured monitor value as a real hardware setting.
struct MonitorReadingAvailability: ViewModifier {
    let unknown: Bool

    func body(content: Content) -> some View {
        content
            .disabled(unknown)
            .opacity(unknown ? 0 : 1)
            .overlay {
                if unknown { Text("—").accessibilityLabel("Unknown") }
            }
    }
}
