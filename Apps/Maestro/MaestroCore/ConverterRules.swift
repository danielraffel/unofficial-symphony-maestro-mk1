/// What Apogee's software did for the older XLink converters (AD-16X, DA-16X,
/// DD-16X, Rosetta 800/200) on a ThunderBridge or Symphony 64 PCIe card: how
/// each unit is identified, which bus slots its channels occupy, what its
/// channels are called, how much latency it adds and which firmware it needs.
///
/// A line-for-line port of `Drivers/Thunderbolt/Source/SymphonyConverters.h`,
/// which carries the evidence. `ConverterRulesTests` pins the same vectors as
/// `Drivers/Thunderbolt/Scripts/test-converters.sh`, so the app and the driver
/// cannot drift apart.
public enum ConverterRules {
    // Routing byte: (XTD_INQUIRE & 0xF0) | (INQUIRE >> 4). Bits 0,1,4,5 are
    // 8-channel input banks, bits 2,3,6,7 output banks. 0 = no unit.
    public static let routingRosetta: UInt8 = 0x05   // Rosetta 800 (or 200)
    public static let routingAD: UInt8 = 0x03        // AD-16X
    public static let routingDA: UInt8 = 0x0C        // DA-16X
    public static let routingDD: UInt8 = 0x0F        // DD-16X, or AD/DA-16X in Advanced Routing
    public static let routingSymphony: UInt8 = 0xFF  // Symphony I/O (Sym2Sym)

    public static let maxUnitsPerPort = 4      // XLINK_MAX_DEVICES
    public static let channelsPerPort = 32     // MAX_SYMPHONY_CHANNELS_ON_BUS
    public static let maxHostChannels = 64

    public static func routing(inquire: UInt8, xtd: UInt8) -> UInt8 {
        (xtd & 0xF0) | (inquire >> 4)
    }

    /// What a unit is, after the user's Device Type choice for the two
    /// ambiguous routings (`ddIsAD` defaults to true, as the original's
    /// `m_fDD16XIsAD16`).
    public static func kind(routing: UInt8, ddIsAD: Bool = true) -> ConverterKind {
        switch routing {
        case routingRosetta: return .rosetta
        case routingAD: return .ad16x
        case routingDA: return .da16x
        case routingDD: return ddIsAD ? .ddAsAD : .ddAsDA
        case 0: return .none
        default: return .unknown
        }
    }

    public static func channels(_ kind: ConverterKind) -> (inputs: Int, outputs: Int) {
        switch kind {
        case .rosetta: return (8, 8)
        case .ad16x: return (16, 0)
        case .da16x: return (0, 16)
        case .ddAsAD, .ddAsDA: return (16, 16)
        case .none, .unknown: return (0, 0)
        }
    }

    /// The units on each port, nearest first. Port 2 is empty unless 64
    /// channels run with converters on it.
    public struct Chain: Sendable, Equatable {
        public var ports: [[ConverterKind]]
        public init(port1: [ConverterKind], port2: [ConverterKind] = []) {
            ports = [port1, port2]
        }
    }

    /// The unit channel behind one host channel.
    public struct Channel: Sendable, Equatable {
        /// 0 or 1.
        public let port: Int
        /// 0-31 on that port.
        public let slot: Int
        /// Index over all units, port 1's first, then port 2's. The unit's
        /// prefix letter is `"A"` plus this.
        public let unit: Int
        /// 0-based channel within the unit.
        public let element: Int

        public init(port: Int, slot: Int, unit: Int, element: Int) {
            self.port = port; self.slot = slot; self.unit = unit; self.element = element
        }

        /// The card's input meter word for this channel (bus slot over both ports).
        public var meterWord: Int { port * ConverterRules.channelsPerPort + slot }
    }

    /// The host channels of one direction (`ConverterHostMap`): 64 entries,
    /// nil where the host channel carries nothing, and the number of host
    /// channels used. Host channels are packed across the whole system, port
    /// 1's units then port 2's, nearest first; each unit channel is placed on a
    /// bus slot of its port with the offsets Apogee's routing layer shipped.
    /// A host channel whose slot would fall outside the port's 32 is counted
    /// but not routed.
    public static func hostMap(_ chain: Chain, input: Bool) -> (map: [Channel?], used: Int) {
        var map = [Channel?](repeating: nil, count: maxHostChannels)
        var host = 0, unitIndex = 0
        for port in 0..<2 {
            var pIn = 0, pOut = 0
            let units = port < chain.ports.count ? Array(chain.ports[port].prefix(maxUnitsPerPort)) : []
            for kind in units {
                let (a, d) = channels(kind)
                let count = input ? a : d
                var base: Int
                if input {
                    base = pIn
                    if a == 16 && pIn == 8 { base += 8 }
                    else if pIn == 0 && pOut > 0 { base += pOut }
                } else {
                    base = pOut
                    if d == 16 && pOut == 8 { base = 16 }
                    else if d == 8 && pOut == 0 && pIn == 16 { base += 16 }
                }
                var e = 0
                while e < count && host < maxHostChannels {
                    let slot = base + e
                    if slot < channelsPerPort {
                        map[host] = Channel(port: port, slot: slot, unit: unitIndex, element: e)
                    }
                    e += 1
                    host += 1
                }
                pIn += a
                pOut += d
                unitIndex += 1
            }
        }
        return (map, host)
    }

    /// The prefix letter of the unit at `unitIndex` over all units.
    public static func prefix(unitIndex: Int) -> Character {
        Character(UnicodeScalar(UInt8(65 + max(0, min(unitIndex, 25)))))
    }

    /// The name of one of a unit's channels (`n` 1-based within the unit), nil
    /// when the unit has no channel of that kind.
    public static func channelName(_ kind: ConverterKind, input: Bool, prefix: Character, n: Int) -> String? {
        let function: String?
        switch kind {
        case .rosetta: function = input ? "In" : "Out"
        case .ad16x: function = input ? "Line" : nil
        case .da16x: function = input ? nil : "Line"
        case .ddAsAD: function = input ? "Line" : "Dig Out"
        case .ddAsDA: function = input ? "Dig In" : "Line"
        case .none, .unknown: function = nil
        }
        guard let function else { return nil }
        return "\(prefix) \(function) \(n)"
    }

    /// The name of a host channel (0-based): the unit channel behind it, or "N.A.".
    public static func hostChannelName(_ chain: Chain, input: Bool, host: Int) -> String {
        let map = hostMap(chain, input: input).map
        return hostChannelName(chain, map: map, input: input, host: host)
    }

    static func hostChannelName(_ chain: Chain, map: [Channel?], input: Bool, host: Int) -> String {
        if host >= 0, host < map.count, let m = map[host] {
            var index = m.unit, port = 0
            let firstPort = chain.ports.first?.count ?? 0
            if index >= firstPort { index -= firstPort; port = 1 }
            if port < chain.ports.count, index < chain.ports[port].count,
               let name = channelName(chain.ports[port][index], input: input,
                                      prefix: prefix(unitIndex: m.unit), n: m.element + 1) {
                return name
            }
        }
        return CardLayout.notApplicable
    }

    /// Converter latency in samples (input or output), before the FPGA frame
    /// is added, as the original reported for the first unit on port 1.
    public static func latency(_ kind: ConverterKind, rateHz: Int, input: Bool) -> Int {
        let x1 = rateHz <= 48000, x2 = rateHz > 48000 && rateHz <= 96000
        switch kind {
        case .rosetta:
            if x1 { return input ? 36 : 34 }
            if x2 { return input ? 57 : 56 }
            return input ? 100 : 99
        case .ad16x, .da16x:
            if x1 { return input ? 36 : 35 }
            if x2 { return input ? 25 : 24 }
            return input ? 20 : 19
        case .ddAsAD, .ddAsDA:
            if rateHz <= 44100 { return input ? 36 : 35 }
            if x1 { return input ? 36 : 34 }
            if x2 { return input ? 24 : 23 }
            return input ? 18 : 17
        case .none, .unknown:
            return 0
        }
    }

    // X-Symphony firmware: major = XTD_INQUIRE low nibble, minor = INQUIRE low
    // nibble. 0.0 means unknown (no XTD reply). The original warned once below 2.7.
    public static let minFirmwareMajor: UInt8 = 2
    public static let minFirmwareMinor: UInt8 = 7

    public static func firmwareOutOfDate(major: UInt8, minor: UInt8) -> Bool {
        if major == 0 && minor == 0 { return false }
        return major < minFirmwareMajor || (major == minFirmwareMajor && minor < minFirmwareMinor)
    }
}

/// What a unit is, after the Device Type choice (`ConverterKind` in
/// `SymphonyConverters.h`).
public enum ConverterKind: Sendable, Equatable {
    case none
    /// 8 in, 8 out (Rosetta 800, or 200).
    case rosetta
    /// 16 in.
    case ad16x
    /// 16 out.
    case da16x
    /// Routing 0x0F used as AD: 16 analog in, 16 digital out.
    case ddAsAD
    /// Routing 0x0F used as DA: 16 digital in, 16 analog out.
    case ddAsDA
    /// Answered with banks we do not recognise.
    case unknown
}
