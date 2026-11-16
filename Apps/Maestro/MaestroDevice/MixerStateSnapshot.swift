import Foundation
import MaestroCore

/// Restores a complete mixer page synchronously, before its first render.
/// Loading never sends controls to hardware or overwrites saved mixer values.
public struct MixerStateSnapshot: Sendable {
    public let channels: [MixerChannelState]
    public let swReturnChannel: MixerChannelState
    public let softwareReturnSource: UInt32
    public let masterLevel: Double

    public init(
        channelCount: Int,
        mixer: Int,
        store: ChannelStateStore,
        defaults: UserDefaults = .standard
    ) {
        let count = max(0, channelCount)
        let empty = MixerChannelState(level: 0, pan: 0, isMuted: false, isSoloed: false)
        if let saved: [MixerChannelState] = store.load(ChannelStateStore.mixerKey(mixer)),
           !saved.isEmpty {
            channels = saved.count >= count
                ? Array(saved.prefix(count))
                : saved + Array(repeating: empty, count: count - saved.count)
        } else {
            channels = Array(repeating: empty, count: count)
        }

        // Software return is shared by both mixers because it is one USB path.
        swReturnChannel = Self.savedSoftwareReturn(defaults: defaults)
        softwareReturnSource = UInt32(clamping: defaults.integer(forKey: "mixerSoftwareReturnSource_\(mixer)"))
        masterLevel = Self.savedMasterLevel(mixer: mixer, defaults: defaults)
    }

    /// The saved Software Return strip (shared by both mixers), or a neutral one.
    public static func savedSoftwareReturn(defaults: UserDefaults = .standard) -> MixerChannelState {
        if let data = defaults.data(forKey: "mixerState_swReturn"),
           let saved = try? JSONDecoder().decode(MixerChannelState.self, from: data) {
            return saved
        }
        return MixerChannelState(level: 0, pan: 0, isMuted: false, isSoloed: false)
    }

    public static func savedMasterLevel(mixer: Int, defaults: UserDefaults = .standard) -> Double {
        defaults.object(forKey: "mixerMasterLevel_\(mixer)") as? Double ?? 0
    }
}
