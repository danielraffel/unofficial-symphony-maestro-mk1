/// Address spaces for the Symphony 64 card. This describes routing; it does
/// not send commands or infer a physical input from a host channel number.
/// Evidence: og_source/maestrolink/Software/SymphonyPCIeRoutingController.cpp:976-1075,1860-1957.
public struct SymphonyRoutingModel: Sendable {
    public static let channelsPerPort = 32
    public static let channelsPerBoard = 16
    public static let hostChannelCount = 64
    public static let xlinkRXBase = 0
    public static let pciOutBase = 64
    public static let mixerOutBase = 128

    public enum Port: Int, CaseIterable, Sendable { case one = 0, two = 1
        public var vendorPortByte: UInt8 { UInt8(rawValue) }
        public var cardBase: Int { rawValue * SymphonyRoutingModel.channelsPerPort }
    }

    public struct Unit: Hashable, Sendable {
        public let port: Port
        /// XLink peripheral address (1...4), not the vendor port byte.
        public let address: Int
        public init?(port: Port, address: Int = 1) {
            guard (1...4).contains(address) else { return nil }
            self.port = port; self.address = address
        }
    }

    public struct Terminal: Hashable, Sendable {
        public let unit: Unit
        /// Zero-based option board and channel. Converters use board 0.
        /// Address validity does not establish that a board/channel is fitted.
        public let board: Int
        public let channel: Int
        public init?(unit: Unit, board: Int, channel: Int) {
            guard (0..<2).contains(board), (0..<16).contains(channel) else { return nil }
            self.unit = unit; self.board = board; self.channel = channel
        }
        public var localChannel: Int { board * SymphonyRoutingModel.channelsPerBoard + channel }
        /// Unit-local IOBoard byte in vendor 0x31; identical on A and B.
        public var boardRouteByte: UInt8 { UInt8(32 + localChannel) }
    }

    /// A position in one Symphony I/O's own 0x31 P2P table. Its source is a
    /// separate physical terminal; routing may reorder or duplicate sources.
    public struct P2P: Hashable, Sendable {
        public let unit: Unit
        public let channel: Int
        public init?(unit: Unit, channel: Int) {
            guard unit.address == 1, (0..<32).contains(channel) else { return nil }
            self.unit = unit; self.channel = channel
        }
        public var routeByte: UInt8 { UInt8(192 + channel) }
    }

    public struct CardRX: Hashable, Sendable {
        public let index: Int
        public init?(_ index: Int) {
            guard (0..<64).contains(index) else { return nil }; self.index = index
        }
        public var tdmSlot: UInt8 { UInt8(SymphonyRoutingModel.xlinkRXBase + index) }
    }
    public struct CardTX: Hashable, Sendable {
        public let index: Int
        public init?(_ index: Int) {
            guard (0..<64).contains(index) else { return nil }; self.index = index
        }
    }
    public struct HostChannel: Hashable, Sendable {
        public let number: Int
        public init?(_ number: Int) {
            guard (1...64).contains(number) else { return nil }; self.number = number
        }
        public var playbackSlot: UInt8 { UInt8(SymphonyRoutingModel.pciOutBase + number - 1) }
    }

    public enum Topology: Sendable {
        case symphonyOnly
        case converterOnly(ConverterRules.Chain)
        /// Port 1 is reserved for Symphony; converters occupy port 2.
        case symphonyAndConverters([ConverterKind])
        case unknown
    }
    public enum Endpoint: Sendable { case card, peripheral(Unit) }
    public enum CommandFamily: CaseIterable, Sendable {
        case identify, monitor, micPre
        /// Symphony preference load lock (0xDD).
        case preferenceLock
        /// Per-unit crosspoint table (0x31).
        case unitRouting
        /// Card-local routes (0xB5 / 0xB6) and reset (0xB7).
        case cardOutput, cardInput, cardReset
    }
    public let topology: Topology
    public let hostChannels: Int
    public let unitBConfigured: Bool

    public init(topology: Topology, hostChannels: Int, unitBConfigured: Bool = false) {
        self.topology = topology
        // Invalid/unknown modes authorize nothing.
        self.hostChannels = [32, 64].contains(hostChannels) ? hostChannels : 0
        self.unitBConfigured = unitBConfigured
    }

    private func isSymphony(_ unit: Unit) -> Bool {
        guard hostChannels > 0, unit.address == 1 else { return false }
        switch topology {
        case .symphonyOnly:
            return unit.port == .one || (hostChannels == 64 && unitBConfigured)
        case .symphonyAndConverters: return unit.port == .one
        case .converterOnly, .unknown: return false
        }
    }

    /// Current app/driver contract, not a new dispatch gate. Card commands
    /// never acquire a peripheral port byte. B1b permits B6/B7 for Symphony
    /// endpoints too (SymphonyCardMixerRouting.h:77-82).
    public func allows(_ command: CommandFamily, at endpoint: Endpoint) -> Bool {
        guard hostChannels > 0 else { return false }
        switch endpoint {
        case .peripheral(let unit):
            switch command {
            case .identify, .monitor, .micPre, .preferenceLock, .unitRouting: return isSymphony(unit)
            case .cardOutput, .cardInput, .cardReset: return false
            }
        case .card:
            switch command {
            case .cardOutput:
                if case .unknown = topology { return false }; return true
            case .cardInput, .cardReset:
                switch topology {
                case .symphonyOnly, .converterOnly: return true
                case .symphonyAndConverters: return hostChannels == 64
                default: return false
                }
            default: return false
            }
        }
    }

    public func cardRX(for p2p: P2P) -> CardRX? {
        guard isSymphony(p2p.unit) else { return nil }
        return CardRX(p2p.unit.port.cardBase + p2p.channel)
    }

    public func p2p(for rx: CardRX) -> P2P? {
        let unit = Unit(port: rx.index < 32 ? .one : .two)!
        guard isSymphony(unit) else { return nil }
        return P2P(unit: unit, channel: rx.index % Self.channelsPerPort)
    }

    /// Resolve the selected unit table explicitly; never assume physical
    /// channel n is P2P n. A table belonging to another unit cannot alias it.
    public func terminal(for p2p: P2P, table: [P2P: Terminal]) -> Terminal? {
        guard isSymphony(p2p.unit), let terminal = table[p2p], terminal.unit == p2p.unit else { return nil }
        return terminal
    }

    /// Fixed Symphony output table used by the existing ThunderBridge setup.
    /// Evidence: og_source/maestrolink/Software/SymphonyPCIeRoutingController.cpp:1075-1187.
    public func cardTX(for terminal: Terminal) -> CardTX? {
        guard isSymphony(terminal.unit) else { return nil }
        return CardTX(terminal.unit.port.cardBase + terminal.localChannel)
    }

    public func terminal(for tx: CardTX) -> Terminal? {
        let unit = Unit(port: tx.index < 32 ? .one : .two)!
        guard isSymphony(unit) else { return nil }
        let local = tx.index % Self.channelsPerPort
        return Terminal(unit: unit, board: local / Self.channelsPerBoard, channel: local % Self.channelsPerBoard)
    }

    /// Card routing is mutable: this conversion requires the actual input
    /// route table. A host channel is not implicitly a card RX slot.
    public func cardRX(for host: HostChannel, routes: [HostChannel: CardRX]) -> CardRX? {
        guard host.number <= hostChannels, let rx = routes[host], rx.index < hostChannels else { return nil }
        return rx
    }

    public struct ConverterRoute: Equatable, Sendable {
        public let terminal: Terminal
        public let host: HostChannel
        public let rx: CardRX?
        public let tx: CardTX?
    }

    /// Default placement only. Reuse the original converter offset rules,
    /// including the Rosetta/16-channel gap and asymmetric input/output maps.
    /// Evidence: og_source/maestrolink/Software/SymphonyPCIeRoutingController.cpp:1015-1069,1860-1920.
    public func converterRoutes(input: Bool) -> [ConverterRoute] {
        let chain: ConverterRules.Chain
        let hostBase: Int
        switch topology {
        case .converterOnly(let value):
            chain = .init(port1: value.ports.first ?? [], port2: hostChannels == 64 && value.ports.count > 1 ? value.ports[1] : [])
            hostBase = 0
        case .symphonyAndConverters(let units) where hostChannels == 64:
            chain = .init(port1: [], port2: units); hostBase = 32
        default: return []
        }
        return ConverterRules.hostMap(chain, input: input).map.enumerated().compactMap { index, channel in
            guard let channel, index + hostBase < hostChannels else { return nil }
            let address = channel.unit - (channel.port == 1 ? min(chain.ports[0].count, 4) : 0) + 1
            guard let unit = Unit(port: channel.port == 0 ? .one : .two, address: address),
                  let terminal = Terminal(unit: unit, board: 0, channel: channel.element),
                  let host = HostChannel(index + hostBase + 1) else { return nil }
            return ConverterRoute(terminal: terminal, host: host,
                                  rx: input ? CardRX(channel.meterWord) : nil,
                                  tx: input ? nil : CardTX(channel.meterWord))
        }
    }

    public static func playbackSlot(channel: Int) -> UInt8? {
        guard (0..<hostChannelCount).contains(channel) else { return nil }
        return HostChannel(channel + 1)?.playbackSlot
    }
    public static func mixerSlot(mixer: Int, side: Int) -> UInt8? {
        guard (0...1).contains(mixer), (0...1).contains(side) else { return nil }
        return UInt8(mixerOutBase + mixer * 2 + side)
    }
}
