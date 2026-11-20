// AppState+DeviceVersions.swift — unit A's 0xA0 component versions over ThunderBridge.
//
// Read only by Device Settings' properties load (`loadProperties`), never at
// connect, recovery or on a timer. USB keeps its own path (the daemon XML and
// the `.version` property).

import Foundation
import MaestroCore
import MaestroDevice

/// Versions read on one connection and identity generation.
struct DeviceInfoVersionsCache {
    let device: ObjectIdentifier
    let generation: UUID
    let components: [SymphonyVersionComponent]
    let versions: SymphonyVersions
}

extension AppState {
    /// Whether a Device Settings load may send the 0xA0 version reads: a
    /// ThunderBridge Symphony I/O (no converter on the cable, a known Symphony
    /// card layout) that is not asleep. The connection rechecks the driver's
    /// converter and link state before every read.
    var thunderboltVersionReadsAllowed: Bool {
        connectionMode == .hardware && transportType == .thunderbolt && device is ThunderboltDeviceConnection
            && connectedUnit == nil && converterSystem == nil
            && SymphonyIdentityReader.isSupported(layout: cardLayout, unit: .a)
            && !twoUnitSleeping
    }

    /// The versions for Device Settings › Info, read at most once per
    /// connection and identity generation: a load that runs again on the same
    /// connection (a preset load, Rescan, reopening the page) reuses a complete
    /// earlier reading. Nil when the reads are not allowed. A partial reading
    /// is shown but not kept, so the next load asks again.
    @MainActor
    func loadThunderboltVersions(slot1: IOCardType?, slot2: IOCardType?) async -> SymphonyVersions? {
        guard thunderboltVersionReadsAllowed, let tb = device as? ThunderboltDeviceConnection else { return nil }
        let components = SymphonyVersions.componentsToRead(slot1: slot1, slot2: slot2)
        let key = ObjectIdentifier(tb)
        let generation = unitAGeneration
        if let cache = deviceInfoVersionsCache, cache.device == key, cache.generation == generation,
           cache.components == components {
            return cache.versions
        }
        let versions = await tb.readSymphonyVersions(components)
        guard (device as? ThunderboltDeviceConnection) === tb, unitAGeneration == generation else { return nil }
        if versions.replies.count == components.count {
            deviceInfoVersionsCache = DeviceInfoVersionsCache(device: key, generation: generation,
                                                              components: components, versions: versions)
        }
        return versions
    }

    /// Unit A's identity (0xC0, read at connect) as Device Info shows it.
    var unitAHardwareIDText: String? {
        unitAIdentity.map(SymphonyHardwareID.text)
    }
}
