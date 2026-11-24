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
