import Foundation
import MaestroCore

/// Restores a complete mixer page synchronously, before its first render.
/// Loading never sends controls to hardware or overwrites saved mixer values.
public struct MixerStateSnapshot: Sendable {
    public let channels: [MixerChannelState]
    public let swReturnChannel: MixerChannelState
    public let swReturnLeftLevel: Double
    public let swReturnRightLevel: Double
    public let softwareReturnSource: UInt32
    public let masterLevel: Double

    public init(
        channelCount: Int,
        mixer: Int,
        store: ChannelStateStore,
        defaults: UserDefaults = .standard,
        preferences: MixerPreferences? = nil
    ) {
        let defaults = preferences ?? store.mixerPreferences
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

        let savedReturn = Self.savedSoftwareReturn(mixer: mixer, preferences: defaults)
        swReturnLeftLevel = defaults.object(forKey: "mixerSWReturnLeftLevel_\(mixer)") as? Double ?? savedReturn.level
        swReturnRightLevel = defaults.object(forKey: "mixerSWReturnRightLevel_\(mixer)") as? Double ?? swReturnLeftLevel
        var softwareReturn = savedReturn
        softwareReturn.level = swReturnLeftLevel
        swReturnChannel = softwareReturn
        softwareReturnSource = UInt32(clamping: defaults.integer(forKey: "mixerSoftwareReturnSource_\(mixer)"))
        masterLevel = Self.savedMasterLevel(mixer: mixer, preferences: defaults)
    }

    /// Where one mixer's Software Return mute and solo are saved. Each mixer
    /// keeps its own, as the original did: every `SymphonyIOMixer` and
    /// `SymphonyPCIeCardMixer` instance holds its own return mute and solo
    /// (og_source/maestrolink/Software/SymphonyIOMixer.cpp:25-29, 933-943;
    /// SymphonyPCIeCardMixer.cpp:46-47), and Apogee's Maestro had one Software
    /// Return model per mixer (maestro2/App/Model/APAudioMixerSoftwareReturnModel.h).
    public static func softwareReturnKey(mixer: Int) -> String { "mixerState_swReturn_\(mixer)" }
    /// Before 0.9.16 one strip was saved for both mixers under this key; it is
    /// what a mixer starts from until its own is saved.
    public static let sharedSoftwareReturnKey = "mixerState_swReturn"

    /// Whether anything was saved for this mixer's Software Return strip.
    public static func hasSavedSoftwareReturn(mixer: Int, preferences defaults: MixerPreferences) -> Bool {
        defaults.object(forKey: softwareReturnKey(mixer: mixer)) != nil
            || defaults.object(forKey: sharedSoftwareReturnKey) != nil
    }

    /// The saved Software Return strip of one mixer, or a neutral one.
    ///
    /// Mute and solo are the mixer's own. Pan is one value for both mixers,
    /// as it always was here (over USB it is a single balance in the helper,
    /// ahead of both mixers); it is carried by the shared key.
    public static func savedSoftwareReturn(mixer: Int, preferences defaults: MixerPreferences) -> MixerChannelState {
        func strip(_ key: String) -> MixerChannelState? {
            guard let data = defaults.data(forKey: key) else { return nil }
            return try? JSONDecoder().decode(MixerChannelState.self, from: data)
        }
        let shared = strip(sharedSoftwareReturnKey)
        var own = strip(softwareReturnKey(mixer: mixer)) ?? shared
            ?? MixerChannelState(level: 0, pan: 0, isMuted: false, isSoloed: false)
        if let shared { own.pan = shared.pan }
        return own
    }

    /// Save one mixer's Software Return strip. The other mixer keeps what it
    /// had: if it never had a strip of its own, the one it was showing until
    /// now is written down for it first, so this save cannot change it.
    public static func saveSoftwareReturn(_ strip: MixerChannelState, mixer: Int, mixerCount: Int = 2,
                                          preferences defaults: MixerPreferences) {
        let encoder = JSONEncoder()
        for other in 0..<mixerCount where other != mixer
            && defaults.object(forKey: softwareReturnKey(mixer: other)) == nil {
            if let data = try? encoder.encode(savedSoftwareReturn(mixer: other, preferences: defaults)) {
                defaults.set(data, forKey: softwareReturnKey(mixer: other))
            }
        }
        guard let data = try? encoder.encode(strip) else { return }
        defaults.set(data, forKey: softwareReturnKey(mixer: mixer))
        // The shared key now only carries the pan (and serves older builds).
        defaults.set(data, forKey: sharedSoftwareReturnKey)
    }

    public static func savedMasterLevel(mixer: Int, preferences defaults: MixerPreferences) -> Double {
        defaults.object(forKey: "mixerMasterLevel_\(mixer)") as? Double ?? 0
    }
}
