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
    public static let pciOutBase: UInt8 = 64
    /// TDM slot of card mixer 0 output left (`SYMPHONY64_MIXER0_OUT`); mixer m
    /// occupies `128 + 2m` and `+1`.
    public static let mixerOutBase: UInt8 = 128
    /// XLink TX channels on the port (`MAX_SYMPHONY_CHANNELS_ON_BUS`).
    public static let channelCount: UInt8 = 32

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

    /// The TDM slot for a source byte as the app addresses it on ThunderBridge:
    /// XLink 0...31 (DAW playback n) → `PCI_OUT n`; `mixer0Base`/`mixer1Base`
    /// pairs → card mixer 0/1 outputs. Hardware inputs are not routable to
    /// outputs from the matrix and return nil.
    public static func slot(forSource source: UInt8) -> UInt8? {
        if source < channelCount { return pciOutBase &+ source }
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
    /// * DAW 1/2 → the main output pair (channels 0/1) is fed through card
    ///   mixer 0 (slots 128/129), which is the driver's default for those two
    ///   channels so the Software Return fader stays in the speaker path.
    public static func route(destination: UInt8, source: UInt8) -> Route? {
        guard let channel = channel(forDestination: destination) else { return nil }
        if source == SymphonyIORoutingAddress.clearRoute || source == SymphonyIORoutingAddress.none {
            return Route(channel: channel, slot: pciOutBase &+ channel, enabled: false)
        }
        if channel < 2, source == channel {
            return Route(channel: channel, slot: mixerOutBase &+ channel, enabled: true)
        }
        guard let slot = slot(forSource: source) else { return nil }
        return Route(channel: channel, slot: slot, enabled: true)
    }
}
