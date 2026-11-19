import Foundation

/// Original System Setup clocking controls:
/// og_source/maestro2/App/Controllers/APSystemClockingViewController.m:195-260.
/// Off uses the first unit as master, while retaining the Loop Sync master choice:
/// og_source/maestrolink/Software/SymphonyPeripheralDevice.cpp:340-346.
public struct LoopSyncSettings: Equatable, Sendable {
    public var enabled: Bool
    public var master: DeviceUnit
    public init(enabled: Bool = true, master: DeviceUnit = .a) {
        self.enabled = enabled; self.master = master
    }
    public init?(word: UInt32) {
        guard word <= 3 else { return nil }
        self.init(enabled: word & 1 == 0, master: word & 2 == 0 ? .a : .b)
    }
    public static let defaultsKey = "symphony.loopSync.v1"
    public static func saved(in defaults: UserDefaults) -> Self? {
        guard let number = defaults.object(forKey: defaultsKey) as? NSNumber else { return nil }
        return Self(word: number.uint32Value)
    }
    public func save(in defaults: UserDefaults) { defaults.set(word, forKey: Self.defaultsKey) }
    public var word: UInt32 { (enabled ? 0 : 1) | (master == .a ? 0 : 2) }
    public var effectiveMaster: DeviceUnit { enabled ? master : .a }
    public func role(_ unit: DeviceUnit) -> String {
        if unit == effectiveMaster { return enabled ? "Loop Sync master" : "Master (Loop Sync off)" }
        return enabled ? "Loop Sync (follows \(effectiveMaster.name))" : "Word Clock"
    }
    public static func available(in routing: SymphonyRoutingModel) -> Bool {
        guard routing.hostChannels == 64, routing.unitBConfigured else { return false }
        return DeviceUnit.allCases.allSatisfy {
            let port: SymphonyRoutingModel.Port = $0 == .a ? .one : .two
            return routing.allows(.clock, at: .peripheral(.init(port: port)!))
        }
    }
}

/// Configuration is never evidence of lock. Selector 13 reports each separately.
public struct LoopSyncState: Equatable, Sendable {
    public let settings: LoopSyncSettings
    public let valid: Bool
    public let lockA: UInt32
    public let lockB: UInt32
    public let sourceA: UInt32
    public let sourceB: UInt32
    public static func decode(_ words: [UInt32]) -> Self? {
        guard words.count == 6, let settings = LoopSyncSettings(word: words[0]),
              words[1] <= 1, words[2] <= 2, words[3] <= 2 else { return nil }
        return Self(settings: settings, valid: words[1] == 1, lockA: words[2], lockB: words[3],
                    sourceA: words[4], sourceB: words[5])
    }
    public func lockText(_ unit: DeviceUnit) -> String {
        switch unit == .a ? lockA : lockB {
        case 2: return "Ready"
        case 1: return "Clock Mismatch"
        default: return "Not read"
        }
    }
    public func role(_ unit: DeviceUnit) -> String { valid ? settings.role(unit) : "Not confirmed" }
    public func sourceKey(_ unit: DeviceUnit) -> UInt32 {
        let value = unit == .a ? sourceA : sourceB
        let source = UInt8(truncatingIfNeeded: value)
        return source >= 4 ? ClockSourceMenu.key(source: source, boardInput: UInt8(truncatingIfNeeded: value >> 8)) : UInt32(source)
    }
}
