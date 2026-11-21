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
// ResetRouting, output branch). So until the app's whole table is on the card,
// no strip may be unmuted: the driver's muted inputs are the holding state.

/// Splits an output table into the three phases it is written in.
public enum CardOutputTableOrder {
    /// The mixer (0 or 1) a source byte belongs to, nil for anything else.
    public static func mixer(ofSource source: UInt8) -> Int? {
        let mixer0 = SymphonyIORoutingAddress.mixer0Base, mixer1 = SymphonyIORoutingAddress.mixer1Base
        if source == mixer0 || source == mixer0 &+ 1 { return 0 }
        if source == mixer1 || source == mixer1 &+ 1 { return 1 }
        return nil
    }

    public struct Write: Equatable, Sendable {
        public let destination: UInt8
        public let source: UInt8
        public init(destination: UInt8, source: UInt8) {
            self.destination = destination; self.source = source
        }
    }

    public struct Phases: Equatable, Sendable {
        /// Every destination of the table. One the table feeds from a mixer
        /// whose strips are still to be written is silenced here, so after
        /// this phase no output carries a mixer through a route this run did
        /// not write.
        public var first: [Write] = []
        /// Mixers written between the two route phases, ascending.
        public var mixers: [Int] = []
        /// The routes fed by those mixers, written once their strips are.
        public var last: [Write] = []
    }

    /// - Parameter readyMixers: mixers whose strips on the card already are
    ///   the saved state (the driver reports it holds the app's state for
    ///   them, and nothing since has been held back). Their routes go in the
    ///   first phase; nothing is silenced for them.
    public static func phases(table: [UInt8: UInt8], readyMixers: Set<Int>) -> Phases {
        var phases = Phases()
        var pending: Set<Int> = []
        for destination in table.keys.sorted() {
            guard let source = table[destination] else { continue }
            if let mixer = mixer(ofSource: source), !readyMixers.contains(mixer) {
                pending.insert(mixer)
                phases.first.append(Write(destination: destination, source: SymphonyIORoutingAddress.none))
                phases.last.append(Write(destination: destination, source: source))
            } else {
                phases.first.append(Write(destination: destination, source: source))
            }
        }
        phases.mixers = pending.sorted()
        return phases
    }

    /// Whether a card route plays a card mixer's output.
    public static func isMixerFed(_ route: ThunderboltCardRouting.Route) -> Bool {
        route.enabled && route.slot >= ThunderboltCardRouting.mixerOutBase
            && route.slot < ThunderboltCardRouting.mixerOutBase &+ 4
    }

    /// The two-unit replay's card writes in the same order: every output
    /// route with the mixer-fed ones silenced, then everything else (card
    /// inputs and both mixers, as given), then the mixer-fed routes.
    public static func ordered(_ writes: [ThunderboltPreset.Write]) -> [ThunderboltPreset.Write] {
        var first: [ThunderboltPreset.Write] = [], middle: [ThunderboltPreset.Write] = []
        var last: [ThunderboltPreset.Write] = []
        for write in writes {
            guard case .output(let route) = write else { middle.append(write); continue }
            if isMixerFed(route) {
                first.append(.output(ThunderboltCardRouting.Route(
                    channel: route.channel, slot: ThunderboltCardRouting.pciOutBase &+ route.channel,
                    enabled: false)))
                last.append(write)
            } else {
                first.append(write)
            }
        }
        return first + middle + last
    }
}

/// Whether the app's complete output table is on the card, for one driver
/// state. A restarted driver (new instance nonce), an in-place link recovery
/// or a card re-init is a different state: the table counts as unwritten until
/// the ordered restore has run again.
public struct CardOutputTableLedger: Sendable, Equatable {
    public struct Instance: Sendable, Equatable {
        /// The driver's instance nonce (`DriverMixerInstance`); nil on a
        /// driver that does not report one.
        public let nonce: UInt64?
        public let recoveryCount: UInt32
        public let cardReinitCount: UInt32
        /// False when the driver gave no link report at all.
        public let reported: Bool

        /// A driver too old to report its link state is one fixed instance:
        /// nothing about it can be seen to change, and a restart of it comes
        /// with a new connection, which starts held and unwritten.
        public init(_ link: LinkState?) {
            self.init(nonce: link?.mixerInstance?.nonce, recoveryCount: link?.recoveryCount ?? 0,
                      cardReinitCount: link?.cardReinitCount ?? 0, reported: link != nil)
        }

        public init(nonce: UInt64?, recoveryCount: UInt32, cardReinitCount: UInt32, reported: Bool) {
            self.nonce = nonce; self.recoveryCount = recoveryCount
            self.cardReinitCount = cardReinitCount; self.reported = reported
        }
    }

    public private(set) var written: Instance?

    public init() {}

    public func isWritten(on link: LinkState?) -> Bool { written == Instance(link) }

    public mutating func recordWritten(_ instance: Instance) { written = instance }
    public mutating func invalidate() { written = nil }
}

/// Holds card mixer writes back while the output table is not on the card.
/// A new connection starts held. A held write is refused (the Mixer page has
/// already saved and shown it) and counted, so the restore knows to replay the
/// mixers once the table is written.
public final class CardMixerHold: Sendable {
    private let held = Atomic<Bool>(true)
    private let refused = Atomic<UInt64>(0)

    public init() {}

    public var isHeld: Bool { held.load(ordering: .sequentiallyConsistent) }
    public func hold() { held.store(true, ordering: .sequentiallyConsistent) }
    public func release() { held.store(false, ordering: .sequentiallyConsistent) }

    /// How many writes have been refused so far.
    public var refusedCount: UInt64 { refused.load(ordering: .sequentiallyConsistent) }

    /// Throws while held. Called before a card mixer write from the app's
    /// property path.
    public func admit(_ address: PropertyAddress) throws {
        guard isHeld else { return }
        refused.wrappingAdd(1, ordering: .sequentiallyConsistent)
        throw DeviceConnectionError.transportError(
            "card mixer write held until the output table is written (\(address.selector))")
    }
}

/// The ordered restore, with every outside effect injected so the order and
/// the failure handling can be tested.
public enum CardOutputTableRestore {
    public enum Outcome: Equatable, Sendable {
        /// Every route and every mixer was written.
        case written(routes: Int, mixers: [Int])
        /// A route write failed; nothing after it was sent.
        case routeFailed(destination: UInt8, source: UInt8, error: String)
        /// A mixer could not be written; its routes were not sent.
        case mixerFailed(mixers: [Int], error: String)
        /// The connection, layout or driver state changed under the run.
        case superseded

        public var isWritten: Bool {
            if case .written = self { return true }
            return false
        }
    }

    public struct Environment {
        public var writeRoute: @MainActor (UInt8, UInt8) async throws -> Void
        /// Writes these mixers in full (every strip, Software Return, Master).
        public var writeMixers: @MainActor ([Int]) async throws -> Void
        public var isCurrent: @MainActor () -> Bool

        public init(writeRoute: @escaping @MainActor (UInt8, UInt8) async throws -> Void,
                    writeMixers: @escaping @MainActor ([Int]) async throws -> Void,
                    isCurrent: @escaping @MainActor () -> Bool) {
            self.writeRoute = writeRoute; self.writeMixers = writeMixers; self.isCurrent = isCurrent
        }
    }

    @MainActor
    public static func run(_ phases: CardOutputTableOrder.Phases, _ env: Environment) async -> Outcome {
        func send(_ writes: [CardOutputTableOrder.Write]) async -> Outcome? {
            for write in writes {
                guard env.isCurrent() else { return .superseded }
                do {
                    try await env.writeRoute(write.destination, write.source)
                } catch {
                    return .routeFailed(destination: write.destination, source: write.source,
                                        error: "\(error)")
                }
            }
            return nil
        }
        if let failure = await send(phases.first) { return failure }
        if !phases.mixers.isEmpty {
            guard env.isCurrent() else { return .superseded }
            do {
                try await env.writeMixers(phases.mixers)
            } catch {
                return .mixerFailed(mixers: phases.mixers, error: "\(error)")
            }
        }
        if let failure = await send(phases.last) { return failure }
        guard env.isCurrent() else { return .superseded }
        return .written(routes: phases.first.count + phases.last.count, mixers: phases.mixers)
    }
}
