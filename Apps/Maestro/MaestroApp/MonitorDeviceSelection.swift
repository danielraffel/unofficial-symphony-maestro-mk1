import Foundation
import MaestroCore

/// The original System Setup keyboard-volume control persisted the selected
/// monitor device with the Symphony device. F2 identity is not in this branch,
/// so the compatibility key is scoped to the card product and A/B role.
enum MonitorDeviceSelectionStore {
    static func key(productID: UInt16) -> String {
        "monitorDeviceSelection_\(productID)_v1"
    }

    static func load(productID: UInt16, defaults: UserDefaults = .standard) -> DeviceUnit {
        let raw = defaults.integer(forKey: key(productID: productID))
        return DeviceUnit(rawValue: raw) ?? .a
    }

    static func save(_ unit: DeviceUnit, productID: UInt16, defaults: UserDefaults = .standard) {
        defaults.set(unit.rawValue, forKey: key(productID: productID))
    }
}
