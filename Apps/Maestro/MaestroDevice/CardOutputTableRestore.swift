import Foundation
import MaestroCore
import Synchronization

// ThunderBridge: the order in which the card's output table and its mixers are
// written, and the record of whether the table is on the card.
//
// The rule: a mixer's unmuted input strips must never be audible on an output
// unless the routing and that mixer's strips are the user's saved (or default)
// state. The driver starts the card, and re-programs it after a reset, with
// the main pair on card mixer 1 and the mixer inputs muted
// (Drivers/Thunderbolt/Source/SymphonyThunderbridge.cpp, "Output routing:
// ch0/1 <- Mixer0/1 out" and "inputs start muted"). The default here is every
// output direct, as the original
// (og_source/maestrolink/Software/SymphonyPCIeRoutingController.cpp,
// ResetRouting, output branch).
//
// The rule is enforced in one place, `CardMixerLedger`, which every card output
// route and every card mixer write of a `ThunderboltDeviceConnection` passes:
//
// * a route whose source is a mixer is sent only when that mixer is marked
//   written for the serving driver state; otherwise it is deferred and owed;
// * a mixer write is sent when the mixer feeds no output (it cannot be heard)
//   or when the mixer is marked written (the write is an edit that keeps it in
//   step); otherwise it is deferred and owed;
// * a mixer is marked written only by a complete write (Master, Software
//   Return, every strip) that the connection itself saw land in full;
// * the marks are dropped whenever the driver's state changes (a new driver
//   instance, a link recovery, a card re-init) and at connect.
//
// The driver's own "holds app state" flag is never used as evidence: one
// write sets it, and it says nothing about whose state it was.

/// Helpers for reading card output routes.
public enum CardOutputTableOrder {
    /// The mixer (0 or 1) a source byte belongs to, nil for anything else.
    public static func mixer(ofSource source: UInt8) -> Int? {
        let mixer0 = SymphonyIORoutingAddress.mixer0Base, mixer1 = SymphonyIORoutingAddress.mixer1Base
        if source == mixer0 || source == mixer0 &+ 1 { return 0 }
        if source == mixer1 || source == mixer1 &+ 1 { return 1 }
        return nil
    }

    /// Whether a card route plays a card mixer's output.
    public static func isMixerFed(_ route: ThunderboltCardRouting.Route) -> Bool { mixer(of: route) != nil }

    /// The card mixer (0 or 1) a card route plays, nil for a direct or
    /// disabled route.
    public static func mixer(of route: ThunderboltCardRouting.Route) -> Int? {
        guard route.enabled, route.slot >= ThunderboltCardRouting.mixerOutBase,
              route.slot < ThunderboltCardRouting.mixerOutBase &+ 4 else { return nil }
        return Int(route.slot - ThunderboltCardRouting.mixerOutBase) / 2
    }

    /// The same channel, playing nothing.
    public static func disabled(_ route: ThunderboltCardRouting.Route) -> ThunderboltCardRouting.Route {
        ThunderboltCardRouting.Route(channel: route.channel,
                                     slot: ThunderboltCardRouting.pciOutBase &+ route.channel, enabled: false)
    }

    /// Card writes in the order that keeps the rule: every output route first
    /// (one fed by a mixer that is not marked written is sent disabled), then
    /// everything that is neither a route nor a mixer write, then the mixer
    /// writes, then the routes held back. A mixer in `written` keeps its
    /// routes in the first group, so nothing is silenced for it.
    public static func ordered(_ writes: [ThunderboltPreset.Write],
                               written: Set<Int> = []) -> [ThunderboltPreset.Write] {
        var first: [ThunderboltPreset.Write] = [], rest: [ThunderboltPreset.Write] = []
        var mixers: [ThunderboltPreset.Write] = [], last: [ThunderboltPreset.Write] = []
        for write in writes {
            switch write {
            case .output(let route):
                if let mixer = mixer(of: route), !written.contains(mixer) {
                    first.append(.output(disabled(route)))
                    last.append(write)
                } else {
                    first.append(write)
                }
            case .property(let address, _) where ThunderboltDeviceConnection.mixerEditSelectors.contains(address.selector):
                mixers.append(write)
            default:
                rest.append(write)
            }
        }
        return first + rest + mixers + last
    }
}

/// The driver state a card mixer's "written" mark belongs to: the driver's
/// instance nonce with its recovery and card re-init counts. Any change means
/// the driver may have re-programmed the card.
public struct CardDriverState: Sendable, Equatable {
    /// The driver's instance nonce (`DriverMixerInstance`); nil on a driver
    /// that does not report one.
    public let nonce: UInt64?
    public let recoveryCount: UInt32
    public let cardReinitCount: UInt32

    public init(_ link: LinkState) {
        self.init(nonce: link.mixerInstance?.nonce, recoveryCount: link.recoveryCount,
                  cardReinitCount: link.cardReinitCount)
    }

    public init(nonce: UInt64?, recoveryCount: UInt32, cardReinitCount: UInt32) {
        self.nonce = nonce; self.recoveryCount = recoveryCount; self.cardReinitCount = cardReinitCount
    }
}

/// What the chokepoint did with a card route or a whole-mixer write.
public enum CardWriteResult: Equatable, Sendable {
    /// Sent to the card.
    case written
    /// Not sent: it would have put a mixer on an output (or changed a mixer
    /// that may be on one) before that mixer was written. It is owed, and
    /// the restore sends it from the saved state.
    case deferred
}

/// Thrown for a single mixer control write that was deferred (the
/// `DeviceConnection` write has no result to return). The ledger has already
/// recorded it as owed, so a caller that ignores the error loses nothing.
public struct CardMixerWriteDeferred: Error, Sendable, Equatable, CustomStringConvertible {
    public let mixer: Int
    public var description: String {
        "card mixer \(mixer + 1) write deferred until that mixer is written for this driver state"
    }
}

/// The per-mixer "written in this driver state" ledger of one ThunderBridge
/// connection, and the admission rule for card routes and mixer writes (see
/// the top of this file). A new connection starts with nothing written and
/// nothing known about the card's routes.
public final class CardMixerLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var state: CardDriverState?
    private var epochValue: UInt64 = 0
    private var written: Set<Int> = []
    /// Card output channels written in this driver state: the mixer each
    /// plays, nil for direct or disabled.
    private var channels: [UInt8: Int?] = [:]
    /// The channels of the app's output table. Until every one of them has
    /// been written in this driver state, any of them may still be on a mixer
    /// (the driver's own default, or an earlier session's route).
    private var table: Set<UInt8>?
    private var owedCount: UInt64 = 0
    private var coveredCount: UInt64 = 0
    private var restoredEpoch: UInt64?
    private var bypassed = false
    private var appBypass = false
    private var driverBypass = false

    public init() {}

    /// Counts driver states: it changes each time the marks are dropped.
    public var epoch: UInt64 { lock.withLock { epochValue } }
    public var writtenMixers: Set<Int> { lock.withLock { written } }
    public func isWritten(_ mixer: Int) -> Bool { lock.withLock { written.contains(mixer) } }

    /// The driver state now serving. A change drops every mark. A read that
    /// failed (nil) says nothing either way and is ignored.
    @discardableResult
    public func observe(_ link: LinkState?) -> Bool {
        guard let link else { return false }
        let now = CardDriverState(link)
        return lock.withLock {
            guard let state else { self.state = now; return false }
            guard state != now else { return false }
            self.state = now
            clearLocked()
            return true
        }
    }

    /// Drop every mark: connect, a reopened driver client, a different unit
    /// or saved-state owner.
    public func clear() { lock.withLock { clearLocked() } }

    /// Drop these mixers' marks only (a recall that failed partway).
    public func clear(mixers: Set<Int>) {
        lock.withLock {
            written.subtract(mixers)
            restoredEpoch = nil
            owedCount &+= 1
        }
    }

    private func clearLocked() {
        epochValue &+= 1
        written = []
        channels = [:]
        restoredEpoch = nil
    }

    /// Converters on the cable: their routing is not the Symphony I/O table,
    /// and the rule does not apply.
    public var isBypassed: Bool {
        get { lock.withLock { bypassed } }
        set { lock.withLock { appBypass = newValue; bypassed = appBypass || driverBypass } }
    }

    /// The driver reports converters on port 1 (set by the connection).
    public func setConvertersOnPort1(_ present: Bool) {
        lock.withLock { driverBypass = present; bypassed = appBypass || driverBypass }
    }

    /// The card channels of the app's whole output table.
    public func declareTable(channels: Set<UInt8>) { lock.withLock { table = channels } }

    private func mayFeedLocked(_ mixer: Int) -> Bool {
        guard let table, table.allSatisfy({ channels[$0] != nil }) else { return true }
        return channels.values.contains { $0 == mixer }
    }

    /// Whether a mixer may be playing on an output, as far as this driver
    /// state's writes show.
    public func mayFeed(_ mixer: Int) -> Bool { lock.withLock { mayFeedLocked(mixer) } }

    /// Card channels known to play this mixer.
    public func channelsFed(by mixers: Set<Int>) -> [UInt8] {
        lock.withLock { channels.compactMap { channel, mixer in mixer.flatMap { mixers.contains($0) ? channel : nil } }.sorted() }
    }

    /// A route may be sent unless it plays a mixer that is not marked
    /// written. A refusal is recorded as owed.
    public func admitRoute(mixer: Int?) -> Bool {
        lock.withLock {
            guard !bypassed, let mixer, !written.contains(mixer) else { return true }
            owedCount &+= 1
            return false
        }
    }

    public func recordRoute(channel: UInt8, mixer: Int?) {
        lock.withLock { channels[channel] = .some(mixer) }
    }

    /// A mixer write may be sent when the mixer cannot be heard or is marked
    /// written. A refusal is recorded as owed.
    public func admitMixerWrite(_ mixer: Int) -> Bool {
        lock.withLock {
            if bypassed || written.contains(mixer) || !mayFeedLocked(mixer) { return true }
            owedCount &+= 1
            return false
        }
    }

    /// Something saved did not reach the card (a failed edit of a written
    /// mixer, a recall that left a control out): the restore runs again.
    public func noteOwed() { lock.withLock { owedCount &+= 1 } }

    /// Mark a mixer written: only when `sent` covers every address a complete
    /// write of it needs, in the driver state the write started in, and only
    /// while it feeds nothing (or is already marked).
    @discardableResult
    public func markWritten(_ mixer: Int, sent: Set<PropertyAddress>, required: Set<PropertyAddress>,
                            epoch: UInt64) -> Bool {
        lock.withLock {
            guard !bypassed, epoch == epochValue, required.isSubset(of: sent) else { return false }
            if written.contains(mixer) { return true }
            guard !mayFeedLocked(mixer) else { return false }
            written.insert(mixer)
            return true
        }
    }

    /// How many deferrals and failures have been recorded.
    public var owed: UInt64 { lock.withLock { owedCount } }

    /// The restore ran to the end in `epoch`, from state saved after
    /// `covering` deferrals had been recorded. False (and nothing recorded)
    /// when the driver state has moved on or a mixer is not marked.
    @discardableResult
    public func completeRestore(epoch: UInt64, covering: UInt64) -> Bool {
        lock.withLock {
            guard epoch == epochValue, written.isSuperset(of: [0, 1]) else { return false }
            restoredEpoch = epoch
            coveredCount = max(coveredCount, covering)
            return true
        }
    }

    /// Whether the restore still has work: nothing completed in this driver
    /// state, or something deferred or failed since.
    public var needsRestore: Bool {
        lock.withLock { !bypassed && (restoredEpoch != epochValue || owedCount > coveredCount) }
    }

    /// Whether a restore completed in this driver state (owed work aside).
    public var isRestored: Bool { lock.withLock { restoredEpoch == epochValue } }
}
