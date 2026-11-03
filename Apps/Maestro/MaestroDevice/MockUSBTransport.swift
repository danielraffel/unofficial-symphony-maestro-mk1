/// Mock USB transport for testing without real hardware.
///
/// Records all sent requests and returns preconfigured responses.
/// Useful for unit testing USBDeviceConnection logic.

import Foundation

// MARK: - Mock USB Transport

/// In-memory mock of USBTransport for testing.
///
/// Supports:
/// - Recording sent requests for assertion
/// - Configuring canned responses per command opcode
/// - Simulating errors
/// - Simulating disconnect
public final class MockUSBTransport: USBTransport, @unchecked Sendable {
    private let lock = NSLock()

    /// All requests sent through this transport, in order.
    public private(set) var sentRequests: [USBControlRequest] = []

    /// Canned responses keyed by command opcode. If a response is configured
    /// for a given opcode, it will be returned. Otherwise, a default empty
    /// response is returned.
    private var responses: [UInt8: Result<USBControlResponse, USBTransportError>] = [:]

    /// Whether the mock transport is "connected".
    public var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _connected
    }
    private var _connected: Bool = true

    /// Optional handler called for each request, allowing dynamic responses.
    /// If set, this takes priority over canned responses.
    public var requestHandler: ((USBControlRequest) -> Result<USBControlResponse, USBTransportError>)?

    public init() {}

    // MARK: - USBTransport

    public func send(_ request: USBControlRequest) async throws -> USBControlResponse {
        let (connected, handler, cannedResult) = recordAndFetch(request)

        guard connected else {
            throw USBTransportError.noDevice
        }

        // Dynamic handler takes priority
        if let handler {
            let result = handler(request)
            switch result {
            case .success(let response): return response
            case .failure(let error): throw error
            }
        }

        // Canned response
        if let cannedResult {
            switch cannedResult {
            case .success(let response): return response
            case .failure(let error): throw error
            }
        }

        // Default: return empty response
        return USBControlResponse(data: Data(), bytesTransferred: 0)
    }

    /// Synchronous helper to record a request and fetch state under the lock.
    private func recordAndFetch(
        _ request: USBControlRequest
    ) -> (
        connected: Bool,
        handler: ((USBControlRequest) -> Result<USBControlResponse, USBTransportError>)?,
        cannedResult: Result<USBControlResponse, USBTransportError>?
    ) {
        lock.lock()
        defer { lock.unlock() }
        let connected = _connected
        if connected {
            sentRequests.append(request)
        }
        return (connected, requestHandler, responses[request.request])
    }

    public func close() async {
        setConnected(false)
    }

    private func setConnected(_ value: Bool) {
        lock.lock()
        _connected = value
        lock.unlock()
    }

    // MARK: - Test Configuration

    /// Configure a canned successful response for a command opcode.
    public func setResponse(for command: SymphonyIOCommand, data: Data) {
        lock.lock()
        defer { lock.unlock() }
        responses[command.rawValue] = .success(
            USBControlResponse(data: data, bytesTransferred: data.count)
        )
    }

    /// Configure a canned error response for a command opcode.
    public func setError(for command: SymphonyIOCommand, error: USBTransportError) {
        lock.lock()
        defer { lock.unlock() }
        responses[command.rawValue] = .failure(error)
    }

    /// Clear all canned responses.
    public func clearResponses() {
        lock.lock()
        defer { lock.unlock() }
        responses.removeAll()
    }

    /// Clear recorded requests.
    public func clearSentRequests() {
        lock.lock()
        defer { lock.unlock() }
        sentRequests.removeAll()
    }

    /// Simulate a disconnect.
    public func simulateDisconnect() {
        lock.lock()
        defer { lock.unlock() }
        _connected = false
    }

    /// Simulate a reconnect.
    public func simulateReconnect() {
        lock.lock()
        defer { lock.unlock() }
        _connected = true
    }
}
