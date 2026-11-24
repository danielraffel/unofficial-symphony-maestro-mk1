import Foundation
import MaestroCore

/// Host playback → hardware output routing on the ThunderBridge card.
///
/// On ThunderBridge the Symphony's own routing table (`0x31`) is not where a
/// host playback route lives. The original PCIe routing controller never wrote
/// a host-playback source into that table; it programmed the card: the XLink TX
/// channel that feeds Symphony output k selects a TDM slot — `PCI_OUT n` for
/// DAW playback n, `MIXER0_OUT + 2m + side` for a mixer bus — and a cleared
/// route is the same register with its enable bit dropped.
///
/// Evidence: `og_source/maestrolink/Software/SymphonyPCIeRoutingController.cpp`
/// `routeSymphonyHW` (:964-1216: `nValue = SYMPHONY64_PCI_OUT0 + src`,
/// `SYMPHONY64_MIXER0_OUT + 2*mixer + offset`, `nDest = board channel +
/// 32*port`, `pDriver->RouteOutput`), `Symphony64Card.cpp` `CMD_ROUTE_OUTPUTS`,
/// `Sym64Routing::SetOutputSource` (`SM_REG_OUTPUT_ROUTING + xlink_chan =
/// slot | ENABLE`), `Sym64RoutingRegisters.h:94/159/226`. The Symphony side
/// stays at the driver's fixed table (XLink n → board output n; dext step 19b-1).
public enum ThunderboltCardRouting {
    /// DriverKit-local command handled by the card FPGA, never sent over XLink.
    /// Payload: `[xlinkChannel, tdmSlot, enabled]`.
    public static let outputRouteCommand: UInt8 = 0xB5
    /// TDM slot of host playback channel 0 (`SYMPHONY64_PCI_OUT0`).
    public static let pciOutBase = UInt8(SymphonyRoutingModel.pciOutBase)
    /// TDM slot of card mixer 0 output left (`SYMPHONY64_MIXER0_OUT`); mixer m
    /// occupies `128 + 2m` and `+1`.
    public static let mixerOutBase = UInt8(SymphonyRoutingModel.mixerOutBase)
    /// XLink TX channels on the port (`MAX_SYMPHONY_CHANNELS_ON_BUS`).
    public static let channelCount = UInt8(SymphonyRoutingModel.channelsPerPort)

    public struct Route: Equatable, Sendable {
        /// XLink TX channel 0...31 (Symphony output: board 0 ch 0-15, board 1 ch 16-31).
        public let channel: UInt8
        public let slot: UInt8
        public let enabled: Bool

        public init(channel: UInt8, slot: UInt8, enabled: Bool) {
            self.channel = channel
            self.slot = slot
            self.enabled = enabled
        }

        public var payload: Data { Data([channel, slot, enabled ? 1 : 0]) }
    }

    /// The XLink TX channel feeding a Symphony output destination byte
    /// (IOBoard0 32-47 → 0-15, IOBoard1 48-63 → 16-31), nil otherwise.
    public static func channel(forDestination destination: UInt8) -> UInt8? {
        let board0 = SymphonyIORoutingAddress.ioBoard0Base
        let board1 = SymphonyIORoutingAddress.ioBoard1Base
        let perBoard = UInt8(SymphonyIORoutingAddress.channelsPerIOBoard)
        if destination >= board0, destination < board0 &+ perBoard {
            return destination &- board0
        }
        if destination >= board1, destination < board1 &+ perBoard {
            return perBoard &+ (destination &- board1)
        }
        return nil
    }

    /// The XLink TX channel feeding a Symphony output destination byte under
    /// the serving driver's `order`: card by card (driver 149 and earlier) as
    /// ``channel(forDestination:)``; analog first (driver 150+) the channel the
    /// unit's playback table plays on that output
    /// (``SymphonyIODefaultRouting/thunderboltOutputRoutes(slot1:slot2:order:)``,
    /// `SymphonyPlaybackSource` in the driver): XLink n for the n-th board
    /// output in host order, nil for a board output no XLink channel reaches.
    /// The card layer itself stays identity (XLink TX n ← `PCI_OUT n`).
    public static func channel(forDestination destination: UInt8, slot1: IOCardType?, slot2: IOCardType?,
                               order: ThunderboltChannelOrder) -> UInt8? {
        guard order == .analogFirst, slot1 != nil, slot2 != nil else { return channel(forDestination: destination) }
        let routes = SymphonyIODefaultRouting.thunderboltOutputRoutes(slot1: slot1, slot2: slot2, order: order)
        guard let source = routes.first(where: { $0.destination == destination })?.source,
              source < channelCount else { return nil }
        return source
    }

    /// The TDM slot for a source byte as the app addresses it on ThunderBridge:
    /// XLink 0...31 (DAW playback n) → `PCI_OUT n`; `mixer0Base`/`mixer1Base`
    /// pairs → card mixer 0/1 outputs. With unit B active, DAW 0...63 are
    /// available independently of the destination port.
    /// Evidence: og_source/maestrolink/Software/SymphonyPCIeRoutingController.cpp:1173-1187.
    /// Hardware inputs are not routable to outputs from the matrix and return nil.
    public static func slot(forSource source: UInt8, unitBActive: Bool = false) -> UInt8? {
        if source < (unitBActive ? 64 : channelCount) { return pciOutBase &+ source }
        let mixer0 = SymphonyIORoutingAddress.mixer0Base
        let mixer1 = SymphonyIORoutingAddress.mixer1Base
        if source == mixer0 || source == mixer0 &+ 1 { return mixerOutBase &+ (source &- mixer0) }
        if source == mixer1 || source == mixer1 &+ 1 { return mixerOutBase &+ 2 &+ (source &- mixer1) }
        return nil
    }

    /// The card route for one mono (destination, source) pair of the app's
    /// routing table.
    ///
    /// * `clearRoute` / `none` disable the channel (its slot is left at the
    ///   straight `PCI_OUT` default, as `Sym64Routing::SetOutputSource(fMute)`).
    /// * A software output always goes straight to the output (`PCI_OUT`),
    ///   bypassing the card mixer, as in the original
    ///   (`SymphonyPCIeRoutingController.cpp:1139-1185`). Until 0.8.36 DAW 1/2
    ///   onto the main pair was quietly sent through card mixer 0 instead, so
    ///   Master and Software Return changed a route the grid showed as direct.
    ///   The mixer is reached only by choosing a Mixer source; no output
    ///   defaults to one.
    public static func route(destination: UInt8, source: UInt8, unitBActive: Bool = false) -> Route? {
        guard let channel = channel(forDestination: destination) else { return nil }
        return route(channel: channel, source: source, unitBActive: unitBActive)
    }

    /// ``route(destination:source:unitBActive:)`` under the serving driver's
    /// `order`: the XLink channel is the one the unit's playback table plays
    /// on `destination` (``channel(forDestination:slot1:slot2:order:)``);
    /// nil for a board output no XLink channel reaches.
    public static func route(destination: UInt8, source: UInt8, unitBActive: Bool = false,
                             slot1: IOCardType?, slot2: IOCardType?, order: ThunderboltChannelOrder) -> Route? {
        guard let channel = channel(forDestination: destination, slot1: slot1, slot2: slot2, order: order) else { return nil }
        return route(channel: channel, source: source, unitBActive: unitBActive)
    }

    /// The XLink TX channels (0-31 of one unit) that no board output
    /// destination reaches under `order`: analog first, the channels past the
    /// unit's outputs. Nothing plays them, but the card keeps whatever route
    /// it last had on them, so a whole-table write sends them disabled.
    public static func unreachedChannels(slot1: IOCardType?, slot2: IOCardType?,
                                         order: ThunderboltChannelOrder) -> [UInt8] {
        let reached = Set((SymphonyIORoutingAddress.ioBoard0Base..<(SymphonyIORoutingAddress.ioBoard1Base
            &+ UInt8(SymphonyIORoutingAddress.channelsPerIOBoard))).compactMap {
            channel(forDestination: $0, slot1: slot1, slot2: slot2, order: order)
        })
        return (0..<channelCount).filter { !reached.contains($0) }
    }

    /// A disabled card route for XLink TX `channel`, left on its straight
    /// `PCI_OUT` slot.
    public static func disabled(channel: UInt8) -> Route {
        Route(channel: channel, slot: pciOutBase &+ channel, enabled: false)
    }

    private static func route(channel: UInt8, source: UInt8, unitBActive: Bool) -> Route? {
        if source == SymphonyIORoutingAddress.clearRoute || source == SymphonyIORoutingAddress.none {
            return Route(channel: channel, slot: pciOutBase &+ channel, enabled: false)
        }
        guard let slot = slot(forSource: source, unitBActive: unitBActive) else { return nil }
        return Route(channel: channel, slot: slot, enabled: true)
    }

    // MARK: - Unit B (64 channels, a second Symphony I/O on port 2)

    /// XLink TX channel of unit B's first output: its outputs are TX 32-63,
    /// which the driver accepts only while 64 channels run with unit B
    /// (`kPort2FirstChannel`, `CardMixerUnitBActive`).
    public static let unitBChannelBase = UInt8(SymphonyRoutingModel.Port.two.cardBase)

    /// TDM slot of host playback channel `channel` (0-63): `PCI_OUT n`.
    public static func playbackSlot(channel: Int) -> UInt8? {
        SymphonyRoutingModel.playbackSlot(channel: channel)
    }

    /// TDM slot of card mixer `mixer` (0 or 1), `side` 0 = left, 1 = right.
    public static func mixerSlot(mixer: Int, side: Int) -> UInt8? {
        SymphonyRoutingModel.mixerSlot(mixer: mixer, side: side)
    }

    /// The card route for one of unit B's outputs: `destination` is the output
    /// as unit B addresses it (IOBoard0 32-47, IOBoard1 48-63), `slot` the TDM
    /// slot to play (nil clears the route: the channel is disabled and left on
    /// its straight `PCI_OUT 32 + c` slot, as the driver starts it).
    public static func unitBRoute(destination: UInt8, slot: UInt8?) -> Route? {
        unitBRoute(destination: destination, slot: slot, slot1: nil, slot2: nil, order: .cardByCard)
    }

    /// ``unitBRoute(destination:slot:)`` under unit B's `order`: the XLink
    /// channel unit B's playback table plays on `destination`, plus 32.
    public static func unitBRoute(destination: UInt8, slot: UInt8?, slot1: IOCardType?, slot2: IOCardType?,
                                  order: ThunderboltChannelOrder) -> Route? {
        guard let local = channel(forDestination: destination, slot1: slot1, slot2: slot2, order: order) else { return nil }
        let channel = unitBChannelBase &+ local
        guard let slot else { return Route(channel: channel, slot: pciOutBase &+ channel, enabled: false) }
        return Route(channel: channel, slot: slot, enabled: true)
    }
}
