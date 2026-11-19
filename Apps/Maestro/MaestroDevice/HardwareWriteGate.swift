import Foundation

/// App-side admission only: never holds a transport/sequence lock or performs I/O.
/// The current connection is held closed at sleep and reopens only after
/// wake validation. A replaced connection is held by the app before use.
/// Evidence: og_source/maestrolink/Software/SymphonyIOSymphonyPeripheralDevice.cpp:247-325.
public final class HardwareWriteGate: @unchecked Sendable {
    private enum State { case open, validating, retired }
    private let lock = NSLock()
    private var state: State = .open

    public init() {}
    public var allowsWrites: Bool { lock.withLock { state == .open } }
    public func holdForValidation() { lock.withLock { if state == .open { state = .validating } } }
    public func retire() { lock.withLock { state = .retired } }
    public func openAfterValidation() { lock.withLock { if state == .validating { state = .open } } }
    public func check() throws {
        guard allowsWrites else { throw DeviceConnectionError.notConnected }
    }
}
