/// EXPERIMENT (64 channels): what the ThunderBridge driver found on its second
/// XLink port, and (stage 2) whether port 2 is carrying audio.
///
/// The driver uses one port unless it was packaged with `SymphonyPortCount=2`.
/// With that, when 64 channels are selected (see `PortSelection`), it
/// switches port 2 on, asks the units cabled to it what they are and runs
/// audio there; at 32 channels port 2 stays off and is not looked at, as
/// in Apogee's driver. It publishes the result through user-client
/// selector 8 as `SymphonyPort2StateOutput`, sixteen 32-bit words
/// (`Drivers/Thunderbolt/Source/SymphonyThunderbridgeShared.h`). macOS does not
/// keep this driver's log, so this is the only way a tester's findings reach us:
/// Device Info shows it and the copied details carry it, raw words included.
///
/// A released driver has no selector 8 (7 is its retire request), and a one-port build of this driver
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
    public static let flagRateFailed: UInt32 = 0x20

    // SymphonyPort2StateOutput.unit[n] (kSymphonyPort2Unit*): bits 7:0 the
    // INQUIRE reply, bits 15:8 the XTD_INQUIRE reply, then these.
    public static let unitInquireOK: UInt32 = 0x0001_0000
    public static let unitXtdOK: UInt32 = 0x0002_0000
    public static let unitAddressed: UInt32 = 0x0004_0000

    // SymphonyPort2StateOutput.audio (kSymphonyPort2Audio*), stage 2. Zero from
    // a stage-1 driver, which had these two words reserved.
    public static let audioCapable: UInt32 = 0x01
    public static let audioActiveFlag: UInt32 = 0x02
    public static let audioPhaseAligned: UInt32 = 0x04
    public static let audioPhaseFailed: UInt32 = 0x08
    public static let audioRefusedFlag: UInt32 = 0x10
    public static let audioFellBackFlag: UInt32 = 0x20
    public static let audioPublished64: UInt32 = 0x40
    /// Always set by a two-port driver that has stage 2, so the word is never 0.
    public static let audioStage2: UInt32 = 0x80
    // SymphonyPort2StateOutput.phase (kSymphonyPort2Phase*).
    public static let phaseValid: UInt32 = 0x8000_0000

    public let portCount: UInt32
    public let flags: UInt32
    /// XLink 2 status, XLink clocking and GCSR2 registers at the last probe.
    public let xlink2Status: UInt32
    public let xlinkClocking: UInt32
    public let gcsr2: UInt32
    /// One word per unit that answered, nearest the computer first.
    public let units: [UInt32]
    public let probeCount: UInt32
    /// The rate port 2's units locked to and reported after the last sample
    /// rate change, 0 if they did not (or none since the last probe).
    public let rateHz: UInt32
    /// Sample rate changes the driver has sent to port 2 since it started.
    public let rateChanges: UInt32
    /// Stage 2: the audio state word and the last phase alignment. Both zero
    /// from a driver that only identifies port 2.
    public let audio: UInt32
    public let phase: UInt32

    public init(portCount: UInt32, flags: UInt32 = 0, xlink2Status: UInt32 = 0,
                xlinkClocking: UInt32 = 0, gcsr2: UInt32 = 0, units: [UInt32] = [],
                probeCount: UInt32 = 0, rateHz: UInt32 = 0, rateChanges: UInt32 = 0,
                audio: UInt32 = 0, phase: UInt32 = 0) {
        self.portCount = portCount
        self.flags = flags
        self.xlink2Status = xlink2Status
        self.xlinkClocking = xlinkClocking
        self.gcsr2 = gcsr2
        self.units = units
        self.probeCount = probeCount
        self.rateHz = rateHz
        self.rateChanges = rateChanges
        self.audio = audio
        self.phase = phase
    }

    /// Decode the driver's sixteen words. Nil when the size is wrong or the
    /// status word is nonzero, both of which mean the selector did not answer.
    public static func decode(_ words: [UInt32]) -> SecondPortState? {
        guard words.count == wordCount, words[0] == 0 else { return nil }
        let count = Int(min(words[6], 4))
        return SecondPortState(portCount: words[1], flags: words[2], xlink2Status: words[3],
                               xlinkClocking: words[4], gcsr2: words[5],
                               units: Array(words[7..<(7 + count)]), probeCount: words[11],
                               rateHz: words[12], rateChanges: words[13],
                               audio: words[14], phase: words[15])
    }

    /// True only for a driver packaged with the two-port experiment switched on.
    public var experimentOn: Bool { portCount == 2 }

    public var probed: Bool { flags & Self.flagProbed != 0 }
    public var clockDetected: Bool { flags & Self.flagClockDetected != 0 }
    public var dataLinkUp: Bool { flags & Self.flagDataLinkUp != 0 }
    public var locked: Bool { flags & Self.flagLocked != 0 }
    public var txTimedOut: Bool { flags & Self.flagTxTimeout != 0 }
    public var rateChangeFailed: Bool { flags & Self.flagRateFailed != 0 }

    /// Nil until the driver has sent port 2 a sample rate change, and again
    /// after port 2 has been looked at afresh (the driver then clears the
    /// rate and the failure flag, so there is no result to show).
    public var rateChangeText: String? {
        guard rateChanges > 0 else { return nil }
        if rateChangeFailed { return "Did not follow the last change" }
        if rateHz != 0 { return "Followed the last change (\(rateHz) Hz)" }
        return nil
    }

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

    // MARK: Stage 2: audio on port 2

    /// The driver can run both ports (it has stage 2 and its port-2 buffers).
    public var supportsPort2Audio: Bool { audio & Self.audioCapable != 0 }
    /// The card is running both ports now.
    public var audioActive: Bool { audio & Self.audioActiveFlag != 0 }
    /// Core Audio's streams are 64 channels wide now.
    public var audioPublished64: Bool { audio & Self.audioPublished64 != 0 }
    /// The last request for 64 channels was refused.
    public var audioRefused: Bool { audio & Self.audioRefusedFlag != 0 }
    /// The driver went from 64 back to 32 channels by itself.
    public var audioFellBack: Bool { audio & Self.audioFellBackFlag != 0 }
    /// The driver's reason code (kSymphonyPort2Reason*), 0 for none.
    public var audioReason: UInt32 { (audio >> 8) & 0xFF }
    /// Times the card has switched between 32 and 64 since the driver started.
    public var audioModeChanges: UInt32 { audio >> 16 }

    /// A reason code in words. The codes are `kSymphonyPort2Reason*` in
    /// `SymphonyThunderbridgeShared.h`.
    public static func reasonText(_ code: UInt32) -> String {
        switch code {
        case 1: return "there is no unit with its link up on port 2"
        case 2: return "the driver could not set up port 2's audio buffers"
        case 3: return "port 2 did not lock at the current sample rate"
        case 4: return "the card did not accept port 2's buffer addresses"
        case 5: return "port 2's unit clock went away"
        case 6: return "the card was reset (after sleep); select 64 channels again"
        case 7: return "port 2 did not follow a sample rate change"
        case 8: return "the card could not be reached, or it is stopped after a failed sample rate change"
        default: return "reason \(code)"
        }
    }

    /// A reason code as the end of a plain sentence, for Maestro's own
    /// screen. `reasonText` keeps the driver's wording for the copied details.
    public static func plainReason(_ code: UInt32) -> String {
        switch code {
        case 1: return "no second unit was found on port 2"
        case 2: return "the driver could not set up audio for port 2"
        case 3: return "the unit on port 2 did not lock to the current sample rate"
        case 4: return "the ThunderBridge did not accept the settings for port 2"
        case 5: return "the unit on port 2 stopped sending its clock"
        case 6: return "the ThunderBridge was reset after sleep; choose 64 channels again"
        case 7: return "the unit on port 2 did not follow a sample rate change"
        case 8: return "the ThunderBridge could not be reached, or it stopped after a failed sample rate change"
        default: return "the driver gave reason \(code)"
        }
    }

    /// Why 64 channels are not running, in plain words. Nil when they are
    /// running, or were never asked for.
    public var plainProblemText: String? {
        guard !audioActive else { return nil }
        if audioFellBack { return "Back to 32 channels: " + Self.plainReason(audioReason) + "." }
        if audioRefused {
            if audioReason == 1 { return "64 channels needs a second unit on port 2, and none was found." }
            return "64 channels could not start: " + Self.plainReason(audioReason) + "."
        }
        return nil
    }

    /// Why 64 channels are not running although they were asked for or were
    /// running before. Nil when they are running, or were never asked for.
    public var audioProblemText: String? {
        guard !audioActive else { return nil }
        if audioFellBack { return "Went back to 32 channels: " + Self.reasonText(audioReason) + "." }
        if audioRefused { return "64 channels refused: " + Self.reasonText(audioReason) + "." }
        return nil
    }

    public var audioText: String {
        if audioActive {
            return "On: 64 channels, 33-64 are port 2"
                + (audioPublished64 ? "" : " (Core Audio has not switched yet)")
        }
        if let problem = audioProblemText { return "Off. " + problem }
        if !supportsPort2Audio { return "Not available: " + Self.reasonText(2) }
        return "Off: 32 channels, port 1 only"
    }

    /// The last phase alignment, nil until one has run.
    public var phaseText: String? {
        guard phase & Self.phaseValid != 0 else { return nil }
        let units = (phase >> 8) & 0xFF
        let read = "\(units) unit" + (units == 1 ? "" : "s") + " read"
        if audio & Self.audioPhaseFailed != 0 {
            return "Not aligned (a unit did not answer, or the card was busy); " + read
        }
        return "Aligned, jam " + Self.hex(phase & 0xFF, digits: 2) + "; " + read
    }

    /// Shown in Device Info whenever the driver reports the experiment on.
    public static let experimentLabel = "Two-port driver"
    /// A driver that only identifies port 2 (stage 1).
    public static let experimentValue = "On. Port 2 is identified only and carries no audio."
    /// A driver that can also run port 2 (stage 2).
    public static let experimentValueWithAudio =
        "On. Port 2 is switched on, looked at and carries audio only while 64 channels are selected."

    /// Port 2 is looked at only when 64 channels are chosen, as the
    /// original driver did, so until then there is nothing to report.
    public static let notLookedAtText = "Not looked at yet (port 2 is used only with 64 channels)"

    public var linkText: String {
        guard probed else { return Self.notLookedAtText }
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

    /// Every row, for the copied details (and for a stage-1 driver, which has
    /// no picker). Empty unless the experiment is on.
    public var deviceInfoRows: [(label: String, value: String)] {
        guard experimentOn else { return [] }
        var rows: [(label: String, value: String)] = [
            (Self.experimentLabel, audio == 0 ? Self.experimentValue : Self.experimentValueWithAudio),
        ]
        // Stage 2 rows only from a driver that reports stage 2.
        if audio != 0 {
            rows.append(("Port 2 Audio", audioText))
            if let phaseText { rows.append(("Port 2 Phase", phaseText)) }
        }
        rows.append(("Port 2 Link", linkText))
        rows.append(("Port 2 Clock", clockText))
        if let rateChangeText { rows.append(("Port 2 Rate Change", rateChangeText)) }
        if units.isEmpty {
            rows.append(("Port 2 Units", probed ? "None found" : "Unknown"))
        } else {
            for (index, word) in units.enumerated() {
                rows.append(("Port 2 Unit \(index + 1)", Self.unitText(word)))
            }
        }
        return rows
    }

    /// The rows Device Info shows while 64 channels are running
    /// (`PortsPresentation`): link, clock, units and phase.
    public var port2DetailRows: [(label: String, value: String)] {
        guard experimentOn else { return [] }
        var rows: [(label: String, value: String)] = [
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
        if let phaseText { rows.append(("Port 2 Phase", phaseText)) }
        return rows
    }

    /// The status words as the driver sent them, for the copied details.
    public var rawText: String {
        "ports=\(portCount) flags=\(Self.hex(flags)) xlink2Status=\(Self.hex(xlink2Status)) "
            + "xlinkClocking=\(Self.hex(xlinkClocking)) gcsr2=\(Self.hex(gcsr2)) "
            + "units=[" + units.map { Self.hex($0) }.joined(separator: ", ") + "] probes=\(probeCount)"
            + (rateChanges > 0 ? " rate=\(rateHz) rateChanges=\(rateChanges)" : "")
            + (audio != 0 ? " audio=\(Self.hex(audio)) phase=\(Self.hex(phase))" : "")
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
