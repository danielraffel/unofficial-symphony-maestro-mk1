import Foundation
import MaestroCore

/// Card coefficients are restored independently of the Mixer view.
/// Evidence: og_source/maestrolink/Software/SymphonyPCIeRoutingController.cpp:248-302,680-784.
public enum CardMixerReplay {
    public static func supportsSingleUnit(channelCount: Int, converterFlags: UInt32) -> Bool {
        channelCount == 32 && (converterFlags & 3) == 0
    }

    public static func stableRecoveryCount(_ samples: [LinkState], requiredSamples: Int = 21) -> UInt32? {
        guard samples.count >= requiredSamples, let first = samples.first,
              first.state == .up, first.clockPresent, first.linkConfigured, !first.hwSuspended else { return nil }
        let recovery = first.recoveryCount
        guard samples.prefix(requiredSamples).allSatisfy({
            $0.state == .up && $0.clockPresent && $0.linkConfigured && !$0.hwSuspended
                && $0.recoveryCount == recovery
        }) else { return nil }
        return recovery
    }

    public static func commandCount(_ groups: [[ThunderboltPreset.Write]]) -> Int {
        groups.reduce(0) { $0 + $1.count }
    }

    /// Full layout validation once per group; lightweight live fences before
    /// every write and every unlock attempt. The caller holds the bus owner.
    public static func run(_ groups: [[ThunderboltPreset.Write]],
                           validateMixer: () throws -> Void, validate: () throws -> Void,
                           send: (ThunderboltPreset.Write) throws -> Void,
                           unlock: () throws -> Bool,
                           pace: () -> Void = { Thread.sleep(forTimeInterval: 0.005) },
                           delay: () -> Void = { Thread.sleep(forTimeInterval: 0.005) }) throws {
        var writes: [ThunderboltPreset.Write] = []
        var boundaries: Set<Int> = []
        for group in groups where !group.isEmpty {
            boundaries.insert(writes.count)
            writes += group
        }
        var index = 0
        try ThunderboltPreset.recall(writes, send: { write in
            if boundaries.contains(index) { try validateMixer() }
            // Full validation may take time; check the edit fence afterwards.
            try validate()
            index += 1
            try send(write)
            // Keep the XLink lane at most 20 commands per 100 ms. The caller
            // owns the serial lock; this sleep is deliberately off MainActor.
            if index < writes.count { pace() }
        }, unlock: {
            try validate()
            return try unlock()
        }, retryDelay: delay)
    }

    public static func outputWrites(_ routes: [UInt8: UInt8]) -> [ThunderboltPreset.Write] {
        routes.sorted { $0.key < $1.key }.compactMap {
            ThunderboltCardRouting.route(destination: $0.key, source: $0.value, unitBActive: false).map {
                ThunderboltPreset.Write.output($0)
            }
        }
    }

    public static func savedWrites(mixer: Int, layout: CardLayout, store: ChannelStateStore) -> [ThunderboltPreset.Write] {
        let defaults = store.mixerPreferences
        let saved: [MixerChannelState]? = store.load(ChannelStateStore.mixerKey(mixer))
        let hasReturn = defaults.object(forKey: "mixerState_swReturn") != nil
            || defaults.object(forKey: "mixerSWReturnLeftLevel_\(mixer)") != nil
            || defaults.object(forKey: "mixerSWReturnRightLevel_\(mixer)") != nil
            || defaults.object(forKey: "mixerSoftwareReturnSource_\(mixer)") != nil
            || defaults.object(forKey: "mixerMasterLevel_\(mixer)") != nil
        guard saved != nil || hasReturn else { return [] }
        let snapshot = MixerStateSnapshot(channelCount: layout.mixerChannelCount, mixer: mixer,
                                          store: store, preferences: defaults)
        return writes(mixer: mixer, layout: layout, snapshot: snapshot,
                      directMonitor: defaults.integer(forKey: "routingMode") != 0)
    }

    public static func writes(mixer: Int, layout: CardLayout, snapshot: MixerStateSnapshot,
                              second: (CardLayout, MixerStateSnapshot)? = nil,
                              directMonitor: Bool) -> [ThunderboltPreset.Write] {
        var writes: [ThunderboltPreset.Write] = []
        let base = UInt32(mixer + 1) << 16
        func put(_ selector: AudioPropertySelector, _ value: PropertyValue, _ channel: Int = 0) {
            writes.append(.property(PropertyAddress(selector: selector, element: base | UInt32(channel)), value))
        }
        let source = TwoUnitMixer.shownSoftwareReturnSource(snapshot.softwareReturnSource,
            pairCount: TwoUnitMixer.softwareReturnPairCount(unitBActive: second != nil))
        put(.mixerSoftwareReturnID, .uint32(source))
        let ids = layout.mixerChannels.map(\.hardwareIndex)
            + (second?.0.mixerChannels.map { 32 + $0.hardwareIndex } ?? []) + [1000]
        let states = snapshot.channels + (second?.1.channels ?? []) + [snapshot.swReturnChannel]
        for (id, state) in zip(ids, states) {
            put(.mixerChannelLevel, .float64(state.level), id)
            put(.mixerChannelPan, .float64(state.pan), id)
            put(.mixerChannelMute, .bool(state.isMuted || (id != 1000 && !directMonitor)), id)
            put(.mixerChannelSolo, .bool(state.isSoloed), id)
        }
        // SymphonyPCIeCardMixer uses a distinct right-side return ID.
        // Evidence: og_source/maestrolink/Software/SymphonyPCIeCardMixer.cpp:27-46,249-261.
        put(.mixerChannelLevel, .float64(snapshot.swReturnRightLevel), 0x1002)
        put(.mixerChannelLevel, .float64(snapshot.masterLevel), 2000)
        return writes
    }
}
