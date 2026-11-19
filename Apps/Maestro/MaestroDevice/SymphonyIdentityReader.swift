import Foundation
import MaestroCore

/// Reads the Symphony I/O hardware identity through an already established
/// transport. The read is deliberately separate from connection/start-up work:
/// it is asynchronous, bounded, and never changes the driver sequence.
public enum SymphonyIdentityReader {
    public static let command: UInt8 = SymphonyIOCommand.uniqueID.rawValue // 0xC0
    public static let responseLength = 8
    public static let maximumAttempts = 10
    public static let retryDelay: Duration = .milliseconds(100)

    /// Capability gate from CardLayout/ConverterSystem. Converters have no
    /// Symphony identity, so callers must refuse their ports.
    public static func isSupported(layout: CardLayout, unit: DeviceUnit) -> Bool {
        guard layout.isKnown, layout.converter == nil else { return false }
        return unit == .a || layout.converters == nil
    }

    /// Decode the firmware's eight-byte big-endian identity. Short, failed,
    /// and all-zero replies are unknown identities.
    public static func decode(_ data: Data) -> UInt64? {
        guard data.count >= responseLength else { return nil }
        let value = data.prefix(responseLength).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return value == 0 ? nil : value
    }

    /// Apply the original ten-read rule without blocking the caller's actor.
    /// A zero identity is retried at most nine times after the first read.
    public static func read(
        attempts: Int = maximumAttempts,
        delay: Duration = retryDelay,
        operation: @escaping @Sendable () async throws -> Data
    ) async -> UInt64? {
        guard attempts > 0 else { return nil }
        for attempt in 0..<attempts {
            guard !Task.isCancelled else { return nil }
            let data = try? await operation()
            guard !Task.isCancelled else { return nil }
            if let data, let id = decode(data) { return id }
            if attempt + 1 < attempts {
                do { try await Task.sleep(for: delay) } catch { return nil }
            }
        }
        return nil
    }

    /// Existing ThunderBridge vendor-read path. The synchronous IOKit call is
    /// moved to a utility task so connect/main-actor work never waits on it.
    public static func readThunderbolt(
        transport: any VendorTransport,
        port: UInt8,
        attempts: Int = maximumAttempts,
        delay: Duration = retryDelay
    ) async -> UInt64? {
        await read(attempts: attempts, delay: delay) {
            try await Task.detached(priority: .utility) {
                try transport.readVendorCommand(command: command, value: 0,
                                                responseLength: responseLength, port: port)
            }.value
        }
    }

    /// Existing USB vendor-read path, used only after USB connection setup.
    public static func readUSB(
        transport: USBTransport,
        attempts: Int = maximumAttempts,
        delay: Duration = retryDelay
    ) async -> UInt64? {
        await read(attempts: attempts, delay: delay) {
            let response = try await transport.send(SymphonyIORequestBuilder.getUniqueID())
            return response.data
        }
    }
}
