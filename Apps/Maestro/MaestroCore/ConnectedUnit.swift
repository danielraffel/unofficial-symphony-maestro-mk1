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

    /// Decode the driver's probe word. Nil when the driver did not probe, which
    /// is the case for a Symphony I/O and for drivers older than build 120.
    public init?(probeWord: UInt32) {
        guard probeWord & 0x8000_0000 != 0 else { return nil }
        guard probeWord & 0x4000_0000 != 0 else { self = .silent; return }
        let reply = UInt8(probeWord & 0xFF)
        switch reply >> 4 {
        case 0x3: self = .ad16x
        case 0xC: self = .da16x
        case 0xF: self = .dd16x
        case 0x5: self = .rosetta800
        default:  self = .unrecognised(reply: reply)
        }
    }

    /// Channels the unit has, when it is a converter we recognise.
    public var channels: (inputs: Int, outputs: Int)? {
        switch self {
        case .ad16x:      return (16, 0)
        case .da16x:      return (0, 16)
        case .dd16x:      return (16, 16)
        case .rosetta800: return (8, 8)
        case .unrecognised, .silent: return nil
        }
    }

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
        }
    }
}
