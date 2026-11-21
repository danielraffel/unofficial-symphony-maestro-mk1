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
    /// The routing and mixer reset's pending flags are cleared once this
    /// plan has run to the end. It starts from the default input tables and
    /// the card-input reset unless an earlier replay on the same connections
    /// already got those onto the hardware.
    public var consumesRoutingReset = false
    /// Both units' card layouts: what a complete card mixer consists of at 64
    /// channels, so the connection can tell when a mixer of this plan has
    /// been written in full.
    public var mixerLayouts: (a: CardLayout, b: CardLayout)?
    public init() {}

    public var writes: [Write] { tables + card + settings + [.headphones(.a), .headphones(.b)] }

    /// What a replay got onto the hardware before it ended, for a caller
    /// that must not repeat part of it on the retry.
    public final class Progress: @unchecked Sendable {
        private let lock = NSLock()
        private let tables: Int
        private var sent = 0
        private var cardInputReset = false
        private var plansCardInputReset = false
        private var stopped = false

        /// - Parameter tables: how many writes the plan's `tables` has.
        public init(tables: Int) { self.tables = tables }

        func begin(_ plan: TwoUnitReplay) {
            lock.withLock {
                plansCardInputReset = plan.card.contains {
                    if case .card(.cardInput(ConverterRouting.resetRoutingCommand)) = $0 { true } else { false }
                }
            }
        }

        /// A write failed: what the plan sends after that is its cleanup,
        /// not progress.
        func failed() { lock.withLock { stopped = true } }

        func landed(_ write: Write) {
            lock.withLock {
                guard !stopped else { return }
                sent += 1
                if case .card(.cardInput(ConverterRouting.resetRoutingCommand)) = write { cardInputReset = true }
            }
        }

        /// Every input table write landed, and the card-input reset too if
        /// the plan had one.
        public var resetDefaultsLanded: Bool {
            lock.withLock { sent >= tables && (cardInputReset || !plansCardInputReset) }
        }
    }

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
        if failure != nil {
            // Clear each unit independently; a failure on A must not prevent B's
            // safety cleanup. Validation still refuses a stale/replaced target.
            for write in settings {
                guard case .unit(let unit, let address, _) = write,
                      address.selector == .phantom else { continue }
                do { try validate(); try send(.unit(unit, address, .bool(false))) }
                catch { failure = error }
            }
        }
        for unit in DeviceUnit.allCases {
            var ready = false
            for attempt in 0..<10 {
                if attempt == 9 {
                    var clearedPhantom = false
                    for write in settings {
                        guard case .unit(let target, let address, _) = write,
                              target == unit, address.selector == .phantom else { continue }
                        clearedPhantom = true
                        do { try validate(); try send(.unit(unit, address, .bool(false))) }
                        catch { failure = error }
                    }
                    if clearedPhantom && failure == nil { failure = DeviceConnectionError.transportError("Preference unlock timed out") }
                }
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
