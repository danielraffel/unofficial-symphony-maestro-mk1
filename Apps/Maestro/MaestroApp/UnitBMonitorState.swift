import Foundation
import Observation
import MaestroCore
import MaestroDevice

/// Per-connection readings. A missing field is unknown; failed refreshes keep
/// the last reading. Unlike the original host recall, B reads the hardware at
/// connect, matching our unit A policy. Never replay these as saved settings.
// Like AppState and IdentifyState, accessed on the main thread.
@Observable
final class UnitBMonitorState: @unchecked Sendable {
    var values: [AudioPropertySelector: PropertyValue] = [:]

    @ObservationIgnored private var refreshing = false

    @MainActor
    func refresh(from device: any DeviceConnection) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        for selector in ThunderboltUnitBConnection.monitorSelectors.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard !Task.isCancelled, device.isConnected else { return }
            let previous = values[selector]
            if let value = try? await device.getProperty(PropertyAddress(selector: selector)) {
                guard device.isConnected, values[selector] == previous else { continue }
                // No legal active-set selection has a zero mask.
                // og_source/maestrolink/Software/SymphonyIO.cpp:1334-1339.
                if selector == .activeSpeakerSet, (value.asUInt32 ?? 0) & 7 == 0 { continue }
                values[selector] = value
            }
        }
    }
}
