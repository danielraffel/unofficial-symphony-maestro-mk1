import SwiftUI

/// Keep the compact navigation list stationary when it fits, and avoid a scroll
/// edge overlay crossing the custom toolbar when the window is small enough to scroll.
struct SidebarScrollBehavior: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .scrollBounceBehavior(.basedOnSize, axes: .vertical)
                .scrollEdgeEffectHidden(true, for: .top)
        } else {
            content.scrollBounceBehavior(.basedOnSize, axes: .vertical)
        }
    }
}
