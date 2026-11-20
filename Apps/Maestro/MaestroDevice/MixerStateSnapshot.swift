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
    /// Pan is always centre: the original had no Software Return pan (its
    /// mixers' pan only addresses input channels, SymphonyIOMixer.cpp:262-290,
    /// SymphonyPCIeCardMixer.cpp:104-130; the app's Software Return controller
    /// has level, solo and mute only), so a pan saved by an earlier Maestro is
    /// not replayed and every restore centres it.
    public static func savedSoftwareReturn(mixer: Int, preferences defaults: MixerPreferences) -> MixerChannelState {
        for key in [softwareReturnKey(mixer: mixer), sharedSoftwareReturnKey] {
            if let data = defaults.data(forKey: key),
               var saved = try? JSONDecoder().decode(MixerChannelState.self, from: data) {
                saved.pan = 0
                return saved
            }
        }
        return MixerChannelState(level: 0, pan: 0, isMuted: false, isSoloed: false)
    }

    public static func savedMasterLevel(mixer: Int, preferences defaults: MixerPreferences) -> Double {
        defaults.object(forKey: "mixerMasterLevel_\(mixer)") as? Double ?? 0
    }
}
