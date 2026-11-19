/// Identity discovery belongs to a connection generation, never to its port.
/// Failed is distinct from pending so health ticks do not restart retries.
public enum UnitIdentityState: Sendable, Equatable {
    case pending
    case known(UInt64)
    case failed

    public var identity: UInt64? {
        if case .known(let value) = self { return value }
        return nil
    }
}
