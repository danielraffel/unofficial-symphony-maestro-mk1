import Foundation

/// Restart a settings read when discovery finishes or the device is replaced.
struct DeviceSettingsLoadID: Equatable {
    let reloadToken: UUID
    let cardLayoutToken: Int
    let deviceID: ObjectIdentifier?
}
