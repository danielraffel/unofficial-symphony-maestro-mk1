import Foundation
import MaestroCore

extension ChannelStateStore {
    /// Bundle recall commits to the same physical owner as page edits/replay.
    /// Called only after the existing hardware transaction and commit fences.
    public func saveMixerPreset(_ mixers: [ThunderboltPreset.Mixer], routingMode: Int?, sourceCount: Int) throws {
        let preferences = mixerPreferences
        for (index, mixer) in mixers.enumerated() {
            save(mixer.channels, for: Self.mixerKey(index))
            if mixer.source < sourceCount {
                preferences.set(mixer.source, forKey: "mixerSoftwareReturnSource_\(index)")
            }
            preferences.set(mixer.master, forKey: "mixerMasterLevel_\(index)")
            preferences.set(try JSONEncoder().encode(mixer.softwareReturn),
                            forKey: MixerStateSnapshot.softwareReturnKey(mixer: index))
        }
        if let routingMode { preferences.set(routingMode, forKey: "routingMode") }
    }
}
