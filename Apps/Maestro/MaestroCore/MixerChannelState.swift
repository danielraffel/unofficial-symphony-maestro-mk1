/// Persisted controls for a single mixer channel.
public struct MixerChannelState: Codable, Equatable, Sendable {
    public var level: Double    // -48..+6 dB
    public var pan: Double      // -1..+1
    public var isMuted: Bool
    public var isSoloed: Bool

    public init(level: Double, pan: Double, isMuted: Bool, isSoloed: Bool) {
        self.level = level
        self.pan = pan
        self.isMuted = isMuted
        self.isSoloed = isSoloed
    }
}
