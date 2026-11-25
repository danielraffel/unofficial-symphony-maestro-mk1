import Foundation
import MaestroCore
import MaestroDevice

/// Unlike a task group, this deadline does not wait for a non-cancellable XPC
/// reply. A late reply cannot reopen a gate or complete the continuation twice.
final class WakeReadDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var completed = false

    private func install(_ value: CheckedContinuation<Bool, Never>) {
        let alreadyCompleted = lock.withLock {
            if completed { return true }
            continuation = value
            return false
        }
        if alreadyCompleted { value.resume(returning: false) }
    }

    private func finish(_ value: Bool) {
        let pending = lock.withLock {
            completed = true
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume(returning: value)
    }

    static func validate(_ connection: any DeviceConnection, timeout: Duration) async -> Bool {
        let deadline = WakeReadDeadline()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                deadline.install(continuation)
                let read = Task {
                    do {
                        for selector: AudioPropertySelector in [.outputLevel, .outputMute] {
                            try Task.checkCancellation()
                            do { _ = try await connection.getProperty(PropertyAddress(selector: selector)) }
                            catch DeviceConnectionError.unsupportedProperty(_) { continue }
                        }
                        deadline.finish(true)
                    } catch { deadline.finish(false) }
                }
                Task {
                    try? await Task.sleep(for: timeout)
                    deadline.finish(false)
                    read.cancel()
                }
            }
        } onCancel: { deadline.finish(false) }
    }
}
