/// What is on the other end of a ThunderBridge or Symphony 64 cable, when it is
/// not a Symphony I/O.
///
/// Apogee's original driver also ran the older X-Symphony converters on this
/// cable and told them apart by asking each unit what it is (`XLINK_CMD_INQUIRE`).
/// The reply's high nibble names the unit's channel banks:
/// bit 7 outputs 9-16, bit 6 outputs 1-8, bit 5 inputs 9-16, bit 4 inputs 1-8
/// (`og_source/symphonymk1/ext/Symphony64/SymphonyAPI/XLinkRegisters.h:256-295`,
/// `SymphonyCommon.h:219-236`). The driver (dext 120+) asks only when the unit
/// does not answer as a Symphony I/O, and publishes the reply in the last word
/// of its link state.
///
/// Experimental: written from the original source, without one of these units
/// to test against.
public enum ConnectedUnit: Sendable, Equatable {
    case ad16x
    case da16x
    case dd16x
    case rosetta800
    /// The unit answered, with banks that match none of the known converters.
    case unrecognised(reply: UInt8)
    /// The unit did not answer as a Symphony I/O and did not answer the
    /// identification either.
    case silent
    /// Several converters chained on the cable, nearest first. These were
    /// normally used in chains (for example an AD-16X and a DA-16X), and the
    /// driver (dext 121+) addresses each one in turn as the original did
    /// (`Driver/XLink.cpp` BusInit `:596-660`), up to four.
    case chain([ConnectedUnit])

    /// Decode the driver's probe word. Nil when the driver did not probe, which
    /// is the case for a Symphony I/O and for drivers older than build 120.
    public init?(probeWord: UInt32) {
        guard probeWord & 0x8000_0000 != 0 else { return nil }
        guard probeWord & 0x4000_0000 != 0 else { self = .silent; return }
        let reply = UInt8(probeWord & 0xFF)
        let first = ConnectedUnit(bankNibble: reply >> 4) ?? .unrecognised(reply: reply)
        // Units 2-4: one bank nibble each in bits 16-27, zero meaning none.
        var units = [first]
        for index in 0..<3 {
            let nibble = UInt8((probeWord >> (16 + 4 * UInt32(index))) & 0xF)
            guard nibble != 0 else { break }
            units.append(ConnectedUnit(bankNibble: nibble) ?? .unrecognised(reply: nibble << 4))
        }
        self = units.count == 1 ? first : .chain(units)
    }

    /// The channel-bank nibble of an identification reply.
    private init?(bankNibble: UInt8) {
        switch bankNibble {
        case 0x3: self = .ad16x
        case 0xC: self = .da16x
        case 0xF: self = .dd16x
        case 0x5: self = .rosetta800
        default:  return nil
        }
    }

    /// Debug only: `-MaestroSimulateConnectedUnit ad16x+da16x` shows the app as
    /// it would look with those converters attached, with no hardware. Names:
    /// `ad16x`, `da16x`, `dd16x`, `rosetta800`, joined with `+`, at most four.
    public static let simulationKey = "MaestroSimulateConnectedUnit"

    public init?(simulationName: String) {
        let units = simulationName.lowercased().split(separator: "+").map { name -> ConnectedUnit? in
            switch name.trimmingCharacters(in: .whitespaces) {
            case "ad16x": return .ad16x
            case "da16x": return .da16x
            case "dd16x": return .dd16x
            case "rosetta800": return .rosetta800
            default: return nil
            }
        }
        guard !units.isEmpty, units.count <= 4, !units.contains(where: { $0 == nil }) else { return nil }
        let known = units.compactMap { $0 }
        self = known.count == 1 ? known[0] : .chain(known)
    }

    /// Channels the unit has, when it is a converter we recognise.
    public var channels: (inputs: Int, outputs: Int)? {
        switch self {
        case .ad16x:      return (16, 0)
        case .da16x:      return (0, 16)
        case .dd16x:      return (16, 16)
        case .rosetta800: return (8, 8)
        case .unrecognised, .silent: return nil
        case .chain(let units):
            // Each unit's channels follow the previous unit's, per direction.
            // The link carries 32 each way. If any unit is unknown the total is
            // unknown, and the generic layout is the honest answer.
            var inputs = 0, outputs = 0
            for unit in units {
                guard let channels = unit.channels else { return nil }
                inputs += channels.inputs
                outputs += channels.outputs
            }
            return (min(inputs, 32), min(outputs, 32))
        }
    }

    /// The units in cable order, nearest the computer first. One element unless
    /// this is a chain.
    public var units: [ConnectedUnit] {
        if case .chain(let units) = self { return units }
        return [self]
    }

    /// One line per unit for Device Info, in cable order:
    /// `("Unit 1", "AD-16X (16 inputs)")`.
    public var unitRows: [(label: String, value: String)] {
        units.enumerated().map { (label: "Unit \($0.offset + 1)", value: $0.element.displayName) }
    }

    /// The unit's model name, for a recognised converter.
    public var modelName: String? {
        switch self {
        case .ad16x:      return "Apogee AD-16X"
        case .da16x:      return "Apogee DA-16X"
        case .dd16x:      return "Apogee DD-16X"
        case .rosetta800: return "Apogee Rosetta 800"
        case .unrecognised, .silent: return nil
        case .chain:
            // The units are listed one per row; the name stays short.
            return "Apogee converters"
        }
    }

    /// Shown where a Symphony I/O would list its two option cards.
    public static let noOptionCards = "Not applicable (not a Symphony I/O)"

    /// One-line explanation for Device Info.
    public static let deviceInfoNotice =
        "This is not a Symphony I/O. Support for older Apogee converters is experimental and "
        + "written without the hardware. Up to four chained units are identified, nearest first."

    public var displayName: String {
        switch self {
        case .ad16x:      return "AD-16X (16 inputs)"
        case .da16x:      return "DA-16X (16 outputs)"
        case .dd16x:      return "DD-16X (16 inputs, 16 outputs)"
        case .rosetta800: return "Rosetta 800 (8 inputs, 8 outputs)"
        case .unrecognised(let reply):
            return "Not recognised (identification reply 0x" + String(reply, radix: 16) + ")"
        case .silent:
            return "No answer (not a Symphony I/O, and it did not identify itself)"
        case .chain(let units):
            return "\(units.count) units: " + units.map(\.displayName).joined(separator: ", then ")
        }
    }
}

/// The text for Device Info's "Connection" row.
public enum ConnectionLabel {
    /// `pciIdentifier` is the IOKit name of the attached Apogee PCI function,
    /// `pci19c2,2200` for a ThunderBridge or `pci19c2,2100` for the older
    /// Symphony 64 PCIe card in a Thunderbolt chassis. The same driver serves
    /// both, so the label has to say which one this is.
    public static func text(isThunderbolt: Bool, pciIdentifier: String?) -> String {
        guard isThunderbolt else { return "USB Hardware" }
        if let pciIdentifier, pciIdentifier.lowercased().hasSuffix(",2100") {
            return "Thunderbolt (Symphony 64 PCIe card, experimental)"
        }
        return "Thunderbolt (ThunderBridge)"
    }
}
