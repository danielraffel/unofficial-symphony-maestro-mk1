import Foundation

/// How the serving ThunderBridge driver lays a Symphony I/O's channels out on
/// the Mac's 32 host channels per unit (the unit's routing layer, vendor
/// AudioRouting 0x31; the card layer stays identity either way).
///
/// - ``cardByCard``: drivers up to build 149. Host input n is slot 1 channel
///   n, then slot 2's channels from where slot 1's real inputs end
///   (`SymphonyCardByCardCaptureSource`); Mac output n plays slot 1 output n
///   for 1-16 and slot 2 output n-16 for 17-32.
/// - ``analogFirst``: driver build 150 and later, as Apogee's original did
///   (og_source/symphonymk1/ext/maestrolink/Software/SymphonyIO_Stream.cpp:138-185,
///   SymphonyPCIeRoutingController.cpp:849-952): every analog channel of slot
///   1, then of slot 2, then slot 1's digital channels, then slot 2's, each
///   board's digital channels in board order (AES before optical). The same
///   order as the USB default table and the routing grid columns
///   (`CardLayout.routingColumns`). While a slot's type is unknown the driver
///   keeps the card-by-card tables (`SymphonyAnalogFirstApplies` in
///   `Drivers/Thunderbolt/Source/SymphonyChannelNames.h`), and so do the app's
///   functions given a nil slot.
///
/// `Drivers/Thunderbolt/Scripts/golden/host-channel-order.txt` pins the
/// driver's tables and names for every slot pair; HostChannelOrderParityTests
/// checks the app's functions against it.
public enum ThunderboltChannelOrder: Sendable, Equatable {
    case cardByCard
    case analogFirst

    /// The order the serving driver programs: analog first from build 150
    /// (``ServingDextBuild/firstAnalogFirstBuild``) and for an unstamped local
    /// build (0) of this code; card by card for an older driver, and when the
    /// serving build is not known.
    public static func serving(_ serving: ServingDextBuild?) -> ThunderboltChannelOrder {
        guard case .build(let build)? = serving else { return .cardByCard }
        return build == 0 || build >= UInt32(ServingDextBuild.firstAnalogFirstBuild) ? .analogFirst : .cardByCard
    }

    /// One board channel: `board` 0 = slot 1, 1 = slot 2; `channel` 0-15 on
    /// the board, analog first, then AES, then optical (the board's own layout).
    public struct BoardChannel: Sendable, Equatable {
        public var board: Int
        public var channel: Int
        public init(board: Int, channel: Int) {
            self.board = board
            self.channel = channel
        }
    }

    /// The board channels in analog-first host order (`SymphonyHostChannelOrder`):
    /// element n is what host channel n carries. At most 32; an empty slot and
    /// an 8MicPre contribute nothing.
    public static func analogFirstOrder(slot1: IOCardType, slot2: IOCardType, isInput: Bool) -> [BoardChannel] {
        let cards = [slot1, slot2]
        func analog(_ card: IOCardType) -> Int { isInput ? card.analogInputChannels : card.analogOutputChannels }
        func total(_ card: IOCardType) -> Int { isInput ? card.totalInputChannels : card.totalOutputChannels }
        var order: [BoardChannel] = []
        for board in 0..<2 {
            for channel in 0..<min(analog(cards[board]), IOCardType.busChannelsPerBoard) {
                order.append(BoardChannel(board: board, channel: channel))
            }
        }
        for board in 0..<2 {
            for channel in analog(cards[board])..<min(total(cards[board]), IOCardType.busChannelsPerBoard) {
                order.append(BoardChannel(board: board, channel: channel))
            }
        }
        return Array(order.prefix(32))
    }

    /// The board output Mac output `hostOutput` (0-based) plays through by
    /// default, as the serving driver programs it (`SymphonyHostOutputBoardChannel`).
    /// Card by card: by position. Analog first: the n-th board output in host
    /// order, nil past the unit's outputs; by position while a slot is nil.
    /// Nil past the 32.
    public func outputBoardChannel(hostOutput: Int, slot1: IOCardType?, slot2: IOCardType?) -> BoardChannel? {
        guard (0..<32).contains(hostOutput) else { return nil }
        guard self == .analogFirst, let slot1, let slot2 else {
            return BoardChannel(board: hostOutput / 16, channel: hostOutput % 16)
        }
        let order = Self.analogFirstOrder(slot1: slot1, slot2: slot2, isInput: false)
        return hostOutput < order.count ? order[hostOutput] : nil
    }
}

extension ThunderboltChannelOrder {
    /// Whether laying `slot1` + `slot2` out analog first moves any of the
    /// unit's real channels to another host channel than card by card did:
    /// for some host input or output that carries a real board channel under
    /// either order, the two orders give it different board channels. Host
    /// channels that are silent under both (past the unit's channels) do not
    /// count, though the tables write them differently (card by card feeds
    /// slot 2's unused bytes, analog first None). False while a slot is nil
    /// (the driver keeps card by card then). A single card, 16x16 + 16x16,
    /// 2x6 + empty and 16x16 + 8MicPre do not differ; 8x8 + A16 does.
    public static func differs(slot1: IOCardType?, slot2: IOCardType?) -> Bool {
        guard let slot1, let slot2 else { return false }
        let cards = [slot1, slot2]
        for isInput in [true, false] {
            func real(_ at: BoardChannel?) -> BoardChannel? {
                guard let at, (0..<2).contains(at.board) else { return nil }
                let card = cards[at.board]
                let total = isInput ? card.totalInputChannels : card.totalOutputChannels
                return at.channel < min(total, IOCardType.busChannelsPerBoard) ? at : nil
            }
            let analogFirst = analogFirstOrder(slot1: slot1, slot2: slot2, isInput: isInput)
            for host in 0..<32 {
                let first = real(host < analogFirst.count ? analogFirst[host] : nil)
                let byCard = real(cardByCardBoardChannel(host: host, slot1: slot1, isInput: isInput))
                if first != byCard { return true }
            }
        }
        return false
    }

    /// The board channel host channel `host` carries under a card-by-card
    /// driver (build 149 and earlier): outputs by position (slot 1 for 1-16,
    /// slot 2 for 17-32); inputs slot 1's channels, then slot 2's from where
    /// slot 1's real inputs end (`SymphonyCardByCardCaptureSource`), the
    /// fixed 16 + 16 behind an empty slot 1 or an 8MicPre.
    static func cardByCardBoardChannel(host: Int, slot1: IOCardType, isInput: Bool) -> BoardChannel? {
        guard (0..<32).contains(host) else { return nil }
        let perBoard = IOCardType.busChannelsPerBoard
        guard isInput else { return BoardChannel(board: host / perBoard, channel: host % perBoard) }
        let inputs = slot1.totalInputChannels
        let base = (inputs == 0 || inputs > perBoard) ? perBoard : inputs
        if host < base { return BoardChannel(board: 0, channel: host) }
        let channel = host - base
        return channel < perBoard ? BoardChannel(board: 1, channel: channel) : nil
    }
}

/// What the serving driver (build 150+, selector 17
/// `kSelectorReadChannelOrder`) reports it last programmed into each unit's
/// routing layer, and the board types it built the tables from. Output names
/// are published from the same values. `SymphonyChannelOrderOutput` in
/// `Drivers/Thunderbolt/Source/SymphonyThunderbridgeShared.h`.
public struct ThunderboltAppliedChannelOrder: Sendable, Equatable {
    public struct Unit: Sendable, Equatable {
        /// Nil: the driver has not programmed this unit's tables yet (no
        /// Symphony I/O answering, unit B not set up).
        public var order: ThunderboltChannelOrder?
        /// The slot types the tables were built from; nil where the type
        /// was not read or is not one the app knows.
        public var slot1: IOCardType?
        public var slot2: IOCardType?
        public init(order: ThunderboltChannelOrder?, slot1: IOCardType?, slot2: IOCardType?) {
            self.order = order
            self.slot1 = slot1
            self.slot2 = slot2
        }
    }

    public var generation: UInt32
    public var unitA: Unit
    public var unitB: Unit

    public init(generation: UInt32 = 0, unitA: Unit, unitB: Unit = Unit(order: nil, slot1: nil, slot2: nil)) {
        self.generation = generation
        self.unitA = unitA
        self.unitB = unitB
    }

    public func unit(_ unit: DeviceUnit) -> Unit { unit == .a ? unitA : unitB }

    /// The 24-byte selector output: status, generation, then per unit the
    /// order word, two raw types and two known bytes. Nil for a short buffer,
    /// a non-zero status or an order value this app does not know.
    public static func decode(_ bytes: [UInt8]) -> ThunderboltAppliedChannelOrder? {
        guard bytes.count >= 24 else { return nil }
        func u32(_ offset: Int) -> UInt32 {
            bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        }
        guard u32(0) == 0 else { return nil }
        func unit(at offset: Int) -> Unit? {
            let order: ThunderboltChannelOrder?
            switch u32(offset) {
            case 0: order = nil
            case 1: order = .cardByCard
            case 2: order = .analogFirst
            default: return nil
            }
            func slot(_ index: Int) -> IOCardType? {
                bytes[offset + 6 + index] != 0 ? IOCardType(rawValue: bytes[offset + 4 + index]) : nil
            }
            return Unit(order: order, slot1: slot(0), slot2: slot(1))
        }
        guard let a = unit(at: 8), let b = unit(at: 16) else { return nil }
        return ThunderboltAppliedChannelOrder(generation: u32(4), unitA: a, unitB: b)
    }
}

/// The order one unit's host channels are in, and the slot types to build
/// its tables and names from: what every ThunderBridge table, name and
/// write in the app follows (`AppState.thunderboltUnitOrder`).
public struct ThunderboltUnitChannelOrder: Sendable, Equatable {
    public var order: ThunderboltChannelOrder
    public var slot1: IOCardType?
    public var slot2: IOCardType?
    public init(order: ThunderboltChannelOrder, slot1: IOCardType?, slot2: IOCardType?) {
        self.order = order
        self.slot1 = slot1
        self.slot2 = slot2
    }

    /// Whether this unit's channels sit elsewhere than card by card put them.
    public var movesChannels: Bool {
        order == .analogFirst && ThunderboltChannelOrder.differs(slot1: slot1, slot2: slot2)
    }

    /// The order to follow, nil while it is not known.
    ///
    /// - A driver from build 150 (or an unstamped local build, 0) reports
    ///   what it applied (`applied`, selector 17): that order and the types
    ///   it built the tables from. Not known until it has programmed the
    ///   unit, or when the read fails: nothing is written then.
    /// - An older driver, one that does not report its build, or no reading
    ///   (`serving` nil): card by card, from `fallback` (the app's own trusted
    ///   slot types), as up to 0.9.24.
    public static func resolve(serving: ServingDextBuild?, applied: ThunderboltAppliedChannelOrder.Unit?,
                               fallback: (slot1: IOCardType?, slot2: IOCardType?)) -> ThunderboltUnitChannelOrder? {
        guard ThunderboltChannelOrder.serving(serving) == .analogFirst else {
            return ThunderboltUnitChannelOrder(order: .cardByCard, slot1: fallback.slot1, slot2: fallback.slot2)
        }
        guard let applied, let order = applied.order else { return nil }
        return ThunderboltUnitChannelOrder(order: order, slot1: applied.slot1, slot2: applied.slot2)
    }
}
