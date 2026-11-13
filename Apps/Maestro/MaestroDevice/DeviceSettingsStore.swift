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
    private let defaults: UserDefaults?
    private let key: String?

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
    public init(defaults: UserDefaults, productID: UInt16) {
        self.defaults = defaults
        self.key = Self.defaultsKey(productID: productID)
        self.values = Self.decode(defaults.data(forKey: Self.defaultsKey(productID: productID)))
    }

    /// The store the app uses for a real device.
    public static func persistent(for identifier: USBDeviceIdentifier) -> DeviceSettingsStore {
        DeviceSettingsStore(defaults: .standard, productID: identifier.productID)
    }

    public static func defaultsKey(productID: UInt16) -> String {
        "deviceSettings_\(productID)_v1"
    }

    public func value(for address: PropertyAddress) -> PropertyValue? {
        lock.lock()
        defer { lock.unlock() }
        return values[address]
    }

    /// Record a value the hardware has accepted. Values of a kind that cannot be
    /// saved (ranges, raw data) are ignored rather than stored half-way.
    public func record(_ value: PropertyValue, for address: PropertyAddress) {
        guard Entry(address: address, value: value) != nil else { return }
        lock.lock()
        values[address] = value
        let snapshot = values
        lock.unlock()
        guard let defaults, let key else { return }
        defaults.set(Self.encode(snapshot), forKey: key)
    }

    /// Every stored setting in a stable order, so a replay writes the same
    /// sequence each time.
    public func entries() -> [(address: PropertyAddress, value: PropertyValue)] {
        lock.lock()
        let snapshot = values
        lock.unlock()
        return snapshot
            .map { (address: $0.key, value: $0.value) }
            .sorted {
                ($0.address.selector.rawValue, $0.address.element)
                    < ($1.address.selector.rawValue, $1.address.element)
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
