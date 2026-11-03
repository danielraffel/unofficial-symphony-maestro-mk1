import AppKit
import SwiftUI

/// App-local appearance; Auto follows macOS and is the default for existing installs.
enum AppAppearance: String, CaseIterable, Identifiable {
    case auto
    case light
    case dark

    static let storageKey = "appAppearance"

    var id: Self { self }

    var title: String {
        switch self {
        case .auto: "Auto"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .auto: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var appKitAppearance: NSAppearance? {
        switch self {
        case .auto: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
