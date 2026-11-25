import Foundation
import MaestroCore

/// The Mac-side copy of device settings the hardware cannot be asked for.
///
/// This is how the original software worked. In the USB Audio and Symphony
/// (PCIe / ThunderBridge) interface modes Apogee's daemon kept these settings in
/// a preferences file on the Mac and wrote them to the unit on every connect;
/// only in Standalone and Pro Tools HD modes did the box hold them
/// (`og_source/maestrolink/Software/SymphonyIO.cpp:1395-1412`,
/// `ApplySettingsToHardware` at `:4665-4691`). The Maestro window held nothing
/// and displayed what the daemon reported.
///
/// Without one owner, each view kept its own copy in `@State` and re-read the
/// device whenever it appeared. Where the transport has no read for a setting
/// the view fell back to its hard-coded default, so the control forgot what the
/// user chose while the hardware kept it.
///
/// A connection records a setting here only after its write succeeded, answers
/// reads from here for settings it cannot read back, and replays the stored
/// values to the hardware on connect. Nothing is ever invented: a setting that
/// was never written through the app is absent, and its read still fails.
public final class DeviceSettingsStore: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PropertyAddress: PropertyValue] = [:]
    private var defaults: UserDefaults?
    private var key: String?

    /// A store that lives only as long as the connection. Used by tests and
    /// tools, which must not read or leave settings in the user's preferences.
    public init() {
        self.defaults = nil
        self.key = nil
    }

    /// A store saved in `defaults` under a key for one product.
    ///
    /// Keyed by product ID for the same reason as the routing cache:
    /// ThunderBridge and each USB mode are different devices to the app and
    /// must not replay one another's settings.
    public init(defaults: UserDefaults, productID: UInt16, unit: DeviceUnit = .a, identity: UInt64? = nil, allowLegacyMigration: Bool = true) {
        self.defaults = defaults
        let legacyKey = Self.defaultsKey(productID: productID, unit: unit)
        if let identity {
            let identityKey = Self.defaultsKey(productID: productID, unit: unit, identity: identity)
            self.key = identityKey
            let migrationKey = "\(legacyKey).migratedTo"
            if let data = defaults.data(forKey: identityKey) {
                self.values = Self.decode(data)
            } else if let data = ["unitA", "unitB"].compactMap({ role in
                defaults.data(forKey: "deviceSettings_\(productID)_\(role)_identity_v2_\(String(identity, radix: 16))")
            }).first {
                self.values = Self.decode(data)
                defaults.set(data, forKey: identityKey)
            } else if !allowLegacyMigration {
                self.values = [:]
            } else if let owner = defaults.string(forKey: migrationKey), owner != String(identity, radix: 16) {
                self.values = [:]
            } else {
                let data = UnitStateMigration.copyData(defaults: defaults, source: legacyKey,
                                                       destination: identityKey, owner: String(identity, radix: 16),
                                                       data: defaults.data(forKey: legacyKey))
                self.values = Self.decode(data)
            }
        } else {
            if let marker = defaults.string(forKey: "\(legacyKey).migratedTo"),
               let migratedIdentity = UInt64(marker, radix: 16) {
                let resolved = DeviceSettingsStore(defaults: defaults, productID: productID,
                                                   unit: unit, identity: migratedIdentity)
                self.key = resolved.key
                self.values = resolved.values
            } else {
                self.key = legacyKey
                self.values = Self.decode(defaults.data(forKey: legacyKey))
            }
        }
    }

    /// The store the app uses for a real device.
    public static func persistent(for identifier: USBDeviceIdentifier, unit: DeviceUnit = .a, identity: UInt64? = nil) -> DeviceSettingsStore {
        DeviceSettingsStore(defaults: .standard, productID: identifier.productID, unit: unit, identity: identity)
    }

    public static func defaultsKey(productID: UInt16) -> String {
        "deviceSettings_\(productID)_v1"
    }

    /// Historical role-scoped key, used only as a migration source.
    public static func defaultsKey(productID: UInt16, unit: DeviceUnit) -> String {
        unit == .a ? defaultsKey(productID: productID) : "deviceSettings_\(productID)_unitB_v1"
    }

    public static func defaultsKey(productID: UInt16, unit: DeviceUnit, identity: UInt64) -> String {
        "deviceSettings_\(productID)_identity_v3_\(String(identity, radix: 16))"
    }

    /// Resolve a connection's initially empty store before replay. Preference
    /// decoding and the short state lock execute off the main actor.
    @discardableResult
    public func resolveIdentity(productID: UInt16, unit: DeviceUnit, identity: UInt64, allowLegacyMigration: Bool = true) async -> String? {
        await Task.detached(priority: .utility) { [self] in
            let resolved = DeviceSettingsStore(defaults: .standard, productID: productID,
                                               unit: unit, identity: identity, allowLegacyMigration: allowLegacyMigration)
            lock.withLock {
                defaults = resolved.defaults
                key = resolved.key
                values = resolved.values
            }
            return resolved.values[PropertyAddress(selector: .prefix)]?.asString
        }.value
    }

    public func value(for address: PropertyAddress) -> PropertyValue? {
        lock.lock()
        defer { lock.unlock() }
        return values[address]
    }

    /// Record a value the write path has accepted. Values of a kind that cannot
    /// be saved (ranges, raw data) are ignored rather than stored half-way.
    ///
    /// Saved under the lock: two settings changed at the same moment must not
    /// reach the preferences file out of order and leave it one change behind.
    public func record(_ value: PropertyValue, for address: PropertyAddress) {
        guard Entry(address: address, value: value) != nil else { return }
        lock.lock()
        defer { lock.unlock() }
        values[address] = value
        guard let defaults, let key else { return }
        defaults.set(Self.encode(values), forKey: key)
    }

    /// Forget a setting (it is then never replayed, as on a new install).
    public func remove(_ address: PropertyAddress) {
        lock.lock()
        defer { lock.unlock() }
        guard values.removeValue(forKey: address) != nil, let defaults, let key else { return }
        defaults.set(Self.encode(values), forKey: key)
    }

    /// The settings the Mac owns, in the order they are written to the unit on
    /// connect. Both transports use this one list.
    ///
    /// Contents and order follow the original daemon's connect-time push
    /// (`SymphonyIO::ApplySettingsToHardware`,
    /// `og_source/maestrolink/Software/SymphonyIO.cpp:4660-4691`): monitor mode
    /// first, then dim, mono and the speaker set that only mean something within
    /// that mode, then each headphone's dim and mono, the two front panel meter
    /// sources, and peak and over hold. The prefix has no hardware behind it on
    /// any transport; it is kept here because this store is its only home.
    ///
    /// The headphone sources are stored here as well. Writing the stored value
    /// only restores the unit's record of the choice; the audible half is a
    /// crosspoint derived from the output routing, which the app re-applies
    /// right after the replay (`AppState.syncDeviceSettingsToHardware`).
    ///
    /// Left out on purpose, although the original pushed them:
    /// - Volume, mute and headphone levels. The original kept its copy in step
    ///   with the front panel encoder by polling and wrote it back as it was.
    ///   Over ThunderBridge/PCIe the levels are saved here too, outside this
    ///   list, and at connect each output is put at the QUIETER of the saved
    ///   level and the unit's (A4, `MonitorLevelsAtConnect`,
    ///   `ThunderboltDeviceConnection.applySavedMonitorLevels`), so a connect
    ///   never makes anything louder than either. Mutes are read from the
    ///   unit (`SpeakerMuteAdoption`). Over USB the helper keeps the speaker
    ///   level itself.
    /// - Clock source, which can also change on the unit, and where a saved
    ///   external clock could unlock a unit whose word clock is gone.
    /// - Built-in defaults for settings nobody has set. Pushing those would
    ///   change the monitoring of every existing user on first launch.
    public static let ownedSettings: [AudioPropertySelector] = [
        .speakerOutputMode,
        .outputDim, .outputSumToMono,
        .activeSpeakerSet,
        .headphone1Dim, .headphone1SumToMono,
        .headphone2Dim, .headphone2SumToMono,
        .headphone1RoutingID, .headphone2RoutingID,
        .frontPanelMeterBank, .metersShowInput,
        .peakHoldMode, .oversHoldMode,
        .prefix,
    ]

    /// The stored owned settings, in `ownedSettings` order (elements ascending
    /// within a setting). Anything else that found its way into the store is
    /// never replayed.
    public func entries() -> [(address: PropertyAddress, value: PropertyValue)] {
        lock.lock()
        let snapshot = values
        lock.unlock()
        return Self.ownedSettings.flatMap { selector in
            snapshot
                .filter { $0.key.selector == selector }
                .sorted { $0.key.element < $1.key.element }
                .map { (address: $0.key, value: $0.value) }
        }
    }

    // MARK: - Encoding

    /// One saved setting. Scope is not saved: every setting kept here is global.
    private struct Entry: Codable {
        var selector: UInt32
        var element: UInt32
        var uint32: UInt32?
        var string: String?
        var bool: Bool?

        init?(address: PropertyAddress, value: PropertyValue) {
            guard address.scope == .global else { return nil }
            selector = address.selector.rawValue
            element = address.element
            switch value {
            case .uint32(let v): uint32 = v
            case .string(let v): string = v
            case .bool(let v): bool = v
            default: return nil
            }
        }

        var address: PropertyAddress {
            PropertyAddress(selector: AudioPropertySelector(rawValue: selector), element: element)
        }

        var value: PropertyValue? {
            if let uint32 { return .uint32(uint32) }
            if let string { return .string(string) }
            if let bool { return .bool(bool) }
            return nil
        }
    }

    private static func encode(_ values: [PropertyAddress: PropertyValue]) -> Data {
        let entries = values
            .compactMap { Entry(address: $0.key, value: $0.value) }
            .sorted { ($0.selector, $0.element) < ($1.selector, $1.element) }
        return (try? JSONEncoder().encode(entries)) ?? Data()
    }

    /// Unreadable or damaged data is the same as no data: the settings are
    /// simply unknown again, which every caller already handles.
    private static func decode(_ data: Data?) -> [PropertyAddress: PropertyValue] {
        guard let data, let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            return [:]
        }
        var result: [PropertyAddress: PropertyValue] = [:]
        for entry in entries {
            if let value = entry.value { result[entry.address] = value }
        }
        return result
    }
}

/// What a replay of stored settings did. `failed` lists the settings the
/// hardware refused, so the caller can say so rather than assume they landed.
public struct DeviceSettingsReplay: Sendable, Equatable {
    public var applied: Int = 0
    public var failed: [AudioPropertySelector] = []

    public init(applied: Int = 0, failed: [AudioPropertySelector] = []) {
        self.applied = applied
        self.failed = failed
    }
}
