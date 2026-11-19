import Foundation
import MaestroCore

/// Lower routing layers precede card routes/mixers, then names, meters and
/// headphones. Evidence: og_source/maestrolink/Software/SymphonyCard.cpp:1031-1044,1089-1095;
/// og_source/maestrolink/Software/SymphonyController.cpp:2234-2249.
public struct TwoUnitReplay: Sendable {
    public enum Write: Sendable {
        case unit(DeviceUnit, PropertyAddress, PropertyValue)
        case card(ThunderboltPreset.Write)
        case headphones(DeviceUnit)
    }
    public var unitBBoards: [UInt8] = []
    public var tables: [Write] = []
    public var card: [Write] = []
    public var settings: [Write] = []
    public init() {}

    public var writes: [Write] { tables + card + settings + [.headphones(.a), .headphones(.b)] }

    /// The caller holds the connection's serial owner throughout, off MainActor.
    /// A stale target refuses cleanup too: never unlock a replacement unit.
    /// No lock-first command; original SetPeripheralReady ends recall even on
    /// failure (og_source/maestrolink/Software/SymphonyIO.cpp:4712-4735).
    public func run(validate: () throws -> Void, send: (Write) throws -> Void,
                    unlock: (DeviceUnit) throws -> Bool,
                    delay: () -> Void = { Thread.sleep(forTimeInterval: 0.005) }) throws {
        try validate()
        var failure: (any Error)?
        do {
            for write in writes {
                try validate()
                try send(write)
            }
        } catch { failure = error }
        for unit in DeviceUnit.allCases {
            var ready = false
            for attempt in 0..<10 {
                do {
                    try validate()
                    ready = try unlock(unit)
                } catch { if failure == nil { failure = error } }
                if ready { break }
                if attempt < 9 { delay() }
            }
            if !ready && failure == nil {
                failure = DeviceConnectionError.transportError("\(unit.name) did not unlock after routing replay")
            }
        }
        if let failure { throw failure }
    }

    public static func ready(channels: Int, link: LinkState?, unitB: UnitBState?, port2Locked: Bool) -> Bool {
        channels == 64 && port2Locked && link?.state == .up && link?.clockPresent == true
            && link?.linkConfigured == true && link?.hwSuspended == false
            && link?.unitProbe == 0 && unitB?.present == true && unitB?.info?.setupComplete == true
    }
}
