import Observation
import MaestroCore
import MaestroDevice

/// AppState owns one of these per unit, independent of the routing view.
/// Like AppState, accessed on the main thread; tasks explicitly use the main actor.
/// Evidence: og_source/symphonymk1/ext/Symphony64/generic/Products/SymphonyIO/SymphonyIOVendorSpecific.h:178-182
/// Identify is latched until OFF, not a timed flash.
/// Per-unit state: og_source/symphonymk1/ext/maestrolink/Software/SymphonyIO.cpp:1414-1425,2512-2521
/// Wire write: og_source/symphonymk1/ext/Symphony64/generic/Products/SymphonyIO/SymphonyIOControl.cpp:136-150
@Observable
final class IdentifyState: @unchecked Sendable {
    private(set) var isOn = false
    @ObservationIgnored private var connection: (any DeviceConnection)?
    @ObservationIgnored private var needsOff = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pending: Task<Void, Never>?

    @discardableResult
    func toggle(device: any DeviceConnection) -> Task<Void, Never> {
        connection = device
        let previous = pending
        let capturedGeneration = generation
        let task = Task { @MainActor in
            await previous?.value
            guard generation == capturedGeneration, device.isConnected else { return }
            let next = !isOn
            do {
                try await device.setProperty(PropertyAddress(selector: .identify), value: .bool(next))
                needsOff = next
                guard generation == capturedGeneration else { return }
                isOn = next
            } catch {
                print("[Maestro] ERROR: Identify failed: \(error)")
            }
        }
        pending = task
        return task
    }

    /// Invalidate queued clicks immediately, but order OFF after any in-flight ON.
    /// Use the captured connection, never a replacement unit's connection.
    @discardableResult
    func reset() -> Task<Void, Never> {
        let previous = pending
        let target = connection
        generation += 1
        isOn = false
        connection = nil
        let task = Task { @MainActor in
            await previous?.value
            guard let target else { return }
            defer { needsOff = false }
            guard needsOff, target.isConnected else { return }
            do {
                try await target.setProperty(PropertyAddress(selector: .identify), value: .bool(false))
            } catch {
                print("[Maestro] ERROR: Identify OFF failed: \(error)")
            }
        }
        pending = task
        return task
    }
}
