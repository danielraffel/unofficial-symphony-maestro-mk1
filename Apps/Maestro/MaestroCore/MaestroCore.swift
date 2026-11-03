/// MaestroCore — Domain model and business logic for Apogee Maestro.
///
/// This module contains:
/// - Device model types (channels, mixers, routing graphs)
/// - CoreAudio property abstractions
/// - Protocol definitions for device communication
/// - State management (observable device state)
///
/// MaestroCore has NO dependencies on AppKit, SwiftUI, or IOKit.
/// It is pure Swift and fully testable without hardware.

public enum MaestroCore {
    public static let version = "0.8.34"
}
