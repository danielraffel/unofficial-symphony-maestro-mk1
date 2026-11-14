/// EXPERIMENT (64 channels, stage 1): what the ThunderBridge driver found on
/// its second XLink port.
///
/// The driver uses one port unless it was packaged with `SymphonyPortCount=2`.
/// With that it switches port 2 on and asks the units cabled to it what they
/// are; port 2 carries no audio. It publishes the result through user-client
/// selector 6 as `SymphonyPort2StateOutput`, sixteen 32-bit words
/// (`Drivers/Thunderbolt/Source/SymphonyThunderbridgeShared.h`). macOS does not
/// keep this driver's log, so this is the only way a tester's findings reach us:
/// Device Info shows it and the copied details carry it, raw words included.
///
/// A released driver has no selector 6, and a one-port build of this driver
/// answers with `portCount` 1. In both cases nothing is shown and the copied
/// text is exactly what it was.
public struct SecondPortState: Sendable, Equatable {
    /// Words in `SymphonyPort2StateOutput`. The driver checks the size exactly.
    public static let wordCount = 16

    // SymphonyPort2StateOutput.flags (kSymphonyPort2Flag*).
    public static let flagProbed: UInt32 = 0x01
    public static let flagClockDetected: UInt32 = 0x02
    public static let flagDataLinkUp: UInt32 = 0x04
    public static let flagLocked: UInt32 = 0x08
    public static let flagTxTimeout: UInt32 = 0x10

    // SymphonyPort2StateOutput.unit[n] (kSymphonyPort2Unit*): bits 7:0 the
    // INQUIRE reply, bits 15:8 the XTD_INQUIRE reply, then these.
    public static let unitInquireOK: UInt32 = 0x0001_0000
    public static let unitXtdOK: UInt32 = 0x0002_0000
    public static let unitAddressed: UInt32 = 0x0004_0000

    public let portCount: UInt32
    public let flags: UInt32
    /// XLink 2 status, XLink clocking and GCSR2 registers at the last probe.
    public let xlink2Status: UInt32
    public let xlinkClocking: UInt32
    public let gcsr2: UInt32
    /// One word per unit that answered, nearest the computer first.
    public let units: [UInt32]
    public let probeCount: UInt32

    public init(portCount: UInt32, flags: UInt32 = 0, xlink2Status: UInt32 = 0,
                xlinkClocking: UInt32 = 0, gcsr2: UInt32 = 0, units: [UInt32] = [],
                probeCount: UInt32 = 0) {
        self.portCount = portCount
        self.flags = flags
        self.xlink2Status = xlink2Status
        self.xlinkClocking = xlinkClocking
        self.gcsr2 = gcsr2
        self.units = units
        self.probeCount = probeCount
    }

    /// Decode the driver's sixteen words. Nil when the size is wrong or the
    /// status word is nonzero, both of which mean the selector did not answer.
    public static func decode(_ words: [UInt32]) -> SecondPortState? {
        guard words.count == wordCount, words[0] == 0 else { return nil }
        let count = Int(min(words[6], 4))
        return SecondPortState(portCount: words[1], flags: words[2], xlink2Status: words[3],
                               xlinkClocking: words[4], gcsr2: words[5],
                               units: Array(words[7..<(7 + count)]), probeCount: words[11])
    }

    /// True only for a driver packaged with the two-port experiment switched on.
    public var experimentOn: Bool { portCount == 2 }

    public var probed: Bool { flags & Self.flagProbed != 0 }
    public var clockDetected: Bool { flags & Self.flagClockDetected != 0 }
    public var dataLinkUp: Bool { flags & Self.flagDataLinkUp != 0 }
    public var locked: Bool { flags & Self.flagLocked != 0 }
    public var txTimedOut: Bool { flags & Self.flagTxTimeout != 0 }

    /// The rate port 2's receiver detected, from bits 16-21 of the clocking
    /// register (the port-1 detect bits, sixteen places up). Nil when none or
    /// more than one bit is set.
    public var detectedRate: Int? {
        switch (xlinkClocking >> 16) & 0x3F {
        case 0x01: return 44_100
        case 0x02: return 48_000
        case 0x04: return 88_200
        case 0x08: return 96_000
        case 0x10: return 176_400
        case 0x20: return 192_000
        default: return nil
        }
    }

    /// Shown in Device Info whenever the driver reports the experiment on.
    public static let experimentLabel = "Experimental two-port driver"
    public static let experimentValue = "On. Port 2 is identified only and carries no audio."

    public var linkText: String {
        guard probed else { return "Not looked at yet" }
        guard clockDetected else { return "Nothing found (no unit clock on port 2)" }
        guard dataLinkUp else { return "Unit clock found, data link down" }
        var text = locked ? "Data link up and locked" : "Data link up, not locked (still slipping)"
        if txTimedOut { text += "; the port stopped accepting commands" }
        return text
    }

    public var clockText: String {
        guard probed else { return "Unknown" }
        let receiverClock = xlinkClocking & 0x0100_0000 != 0
        if let detectedRate { return "\(detectedRate) Hz" + (receiverClock ? "" : " (receive clock not detected)") }
        let bits = (xlinkClocking >> 16) & 0x3F
        if bits != 0 { return "Unclear (rate bits 0x" + String(bits, radix: 16) + ")" }
        return receiverClock ? "Receive clock, no rate detected" : "None"
    }

    /// What one unit word says the unit is.
    public static func unitText(_ word: UInt32) -> String {
        let inquire = UInt8(word & 0xFF), xtd = UInt8((word >> 8) & 0xFF)
        let inquireOK = word & unitInquireOK != 0, xtdOK = word & unitXtdOK != 0
        guard inquireOK || xtdOK else { return "No answer" }
        // The original's unit identity: the XTD_INQUIRE channel bits above the
        // INQUIRE ones (CONVERT_ROUTING_COMMANDS_TO_NEW_FORMAT,
        // og_source/.../SymphonyAPI/XLinkRegisters.h:444). 0xFF is its
        // "Symphony" type (DEVICE_ROUTING_SYM2SYM); the rest are the older
        // converters, which `ConnectedUnit` already names.
        let groups = (xtd & 0xF0) | (inquire >> 4)
        var text: String
        if groups == 0xFF {
            text = "32-channel unit, probably a Symphony I/O (32 inputs, 32 outputs)"
        } else if xtd & 0xF0 == 0, inquireOK,
                  let unit = ConnectedUnit(probeWord: 0xC000_0000 | UInt32(inquire)) {
            text = unit.displayName
        } else {
            text = "Not recognised"
        }
        text += " [replies " + (inquireOK ? hex(UInt32(inquire), digits: 2) : "none")
            + ", " + (xtdOK ? hex(UInt32(xtd), digits: 2) : "none") + "]"
        if groups != 0, word & unitAddressed == 0 { text += ", could not be addressed" }
        return text
    }

    /// The rows Device Info shows. Empty unless the experiment is on.
    public var deviceInfoRows: [(label: String, value: String)] {
        guard experimentOn else { return [] }
        var rows: [(label: String, value: String)] = [
            (Self.experimentLabel, Self.experimentValue),
            ("Port 2 Link", linkText),
            ("Port 2 Clock", clockText),
        ]
        if units.isEmpty {
            rows.append(("Port 2 Units", probed ? "None found" : "Unknown"))
        } else {
            for (index, word) in units.enumerated() {
                rows.append(("Port 2 Unit \(index + 1)", Self.unitText(word)))
            }
        }
        return rows
    }

    /// The status words as the driver sent them, for the copied details.
    public var rawText: String {
        "ports=\(portCount) flags=\(Self.hex(flags)) xlink2Status=\(Self.hex(xlink2Status)) "
            + "xlinkClocking=\(Self.hex(xlinkClocking)) gcsr2=\(Self.hex(gcsr2)) "
            + "units=[" + units.map { Self.hex($0) }.joined(separator: ", ") + "] probes=\(probeCount)"
    }

    /// The lines added to the copied device details. Empty unless the
    /// experiment is on, so every other report is unchanged.
    public var reportLines: [String] {
        guard experimentOn else { return [] }
        return deviceInfoRows.map { "\($0.label): \($0.value)" } + ["Port 2 Raw: \(rawText)"]
    }

    private static func hex(_ value: UInt32, digits: Int = 8) -> String {
        let text = String(value, radix: 16)
        return "0x" + String(repeating: "0", count: max(0, digits - text.count)) + text
    }
}
