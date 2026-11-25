import Synchronization

/// Independent of the bus owner: editing invalidates a queued or running
/// snapshot immediately, without taking a blocking lock on MainActor.
public final class MixerEditGeneration: Sendable {
    private let generation = Atomic<UInt64>(0)
    public init() {}
    public func capture() -> UInt64 { generation.load(ordering: .sequentiallyConsistent) }
    public func invalidate() { generation.wrappingAdd(1, ordering: .sequentiallyConsistent) }
    public func isCurrent(_ captured: UInt64) -> Bool { capture() == captured }
}
