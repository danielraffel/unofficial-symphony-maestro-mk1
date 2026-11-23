import Foundation
import MaestroCore

/// Driver build 144 plays card-mixer faders above 0 dB as the original did
/// (up to +6, and +12 with Master at +6). Earlier drivers played anything
/// above 0 at 0. So that nothing gets louder at the update, the first time a
/// unit's mixers are restored with 144 every saved strip, Software Return and
/// Master fader above 0 dB is set to 0 dB, what the user has been hearing. The
/// old values are kept in a backup key; it runs once per unit (its mixer
/// preferences are per unit).
public enum MixerHeadroomMigration {
    public static let doneKey = "mixerHeadroom144.done"
    public static let backupKey = "mixerHeadroom144.backup"
    /// The first driver build that plays faders above 0 dB.
    public static let firstBuild: UInt32 = 144

    public static func applies(to build: ServingDextBuild?) -> Bool {
        if case .build(let n)? = build { return n >= firstBuild }
        return false
    }

    static let levelKeys = ["mixerSWReturnLeftLevel_", "mixerSWReturnRightLevel_",
                            "mixerMasterLevel_", "mixerMasterLeftLevel_", "mixerMasterRightLevel_"]

    /// Returns how many faders were lowered (0 also when it had already run).
    @discardableResult
    public static func run(store: ChannelStateStore, preferences: MixerPreferences,
                           mixers: Range<Int> = 0..<2) -> Int {
        guard preferences.isWritable, preferences.object(forKey: doneKey) == nil else { return 0 }
        var backup: [String: Double] = [:]
        var lowered = 0
        for mixer in mixers {
            if var strips: [MixerChannelState] = store.load(ChannelStateStore.mixerKey(mixer)) {
                var changed = false
                for i in strips.indices where strips[i].level > 0 {
                    backup["\(ChannelStateStore.mixerKey(mixer)).\(i)"] = strips[i].level
                    strips[i].level = 0
                    changed = true
                    lowered += 1
                }
                if changed { store.save(strips, for: ChannelStateStore.mixerKey(mixer)) }
            }
            for prefix in levelKeys {
                let key = prefix + String(mixer)
                if let level = preferences.object(forKey: key) as? Double, level > 0 {
                    backup[key] = level
                    preferences.set(0.0, forKey: key)
                    lowered += 1
                }
            }
        }
        // A Software Return level held only in a saved strip (a mixer that
        // never had its own level key falls back to these, see
        // MixerStateSnapshot.savedSoftwareReturn).
        let stripKeys = mixers.map { MixerStateSnapshot.softwareReturnKey(mixer: $0) }
            + [MixerStateSnapshot.sharedSoftwareReturnKey]
        for key in stripKeys {
            guard let data = preferences.data(forKey: key),
                  var strip = try? JSONDecoder().decode(MixerChannelState.self, from: data),
                  strip.level > 0 else { continue }
            backup[key] = strip.level
            strip.level = 0
            guard let encoded = try? JSONEncoder().encode(strip) else { continue }
            preferences.set(encoded, forKey: key)
            lowered += 1
        }
        if !backup.isEmpty { preferences.set(backup, forKey: backupKey) }
        preferences.set(true, forKey: doneKey)
        return lowered
    }
}
