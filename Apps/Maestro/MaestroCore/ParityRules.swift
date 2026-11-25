import Foundation

/// Mixer fader levels are sent to the unit as whole dB, rounded down
/// (`SymphonyIOPropertyMapper`: `UInt8(clamping: Int(level + 48))`), as the
/// original did (og_source/maestrolink/Software/SymphonyIO/SymphonyIOControl.cpp:1910-1913).
/// The Mixer page shows and steps in the same whole dB, so a strip never
/// reads a level other than the one that plays.
public enum MixerFaderLevel {
    /// The level that plays for a stored level: floor, within -48...6.
    public static func played(_ value: Double) -> Double {
        let floored = floor(min(max(value, -48), 6))
        return floored == 0 ? 0 : floored   // never -0
    }
}

/// The output a mixer's Master strip names: the first Output Routing column
/// its row feeds, in column order (analog, then digital), as the original's
/// label did (og_source/maestro2/App/Controllers/APMixerMasterViewController.m:114-208).
public enum MasterOutputLabel {
    public static let none = "None"

    /// `rows` is the saved Output Routing (row → columns); the default
    /// routes no mixer, so saved rows are all that can name one.
    public static func firstColumn(rows: [Int: Set<Int>], mixerRow: Int, columnCount: Int) -> Int? {
        rows[mixerRow]?.filter { (0..<columnCount).contains($0) }.min()
    }

    /// Unit A's outputs first, then unit B's.
    public static func text(unitA: (rows: [Int: Set<Int>], mixerRow: Int, names: [String]),
                            unitB: (rows: [Int: Set<Int>], mixerRow: Int, names: [String])? = nil) -> String {
        if let col = firstColumn(rows: unitA.rows, mixerRow: unitA.mixerRow, columnCount: unitA.names.count) {
            return unitA.names[col]
        }
        if let unitB, let col = firstColumn(rows: unitB.rows, mixerRow: unitB.mixerRow, columnCount: unitB.names.count) {
            return unitB.names[col]
        }
        return none
    }
}

/// What the Monitor toolbar does with the unit's speaker mute when it loads
/// (launch, reconnect, wake, preset recall): shows it. The original kept a
/// muted speaker muted; nothing is written to the unit. The Mac's own mute
/// control is told, so it does not flip the screen back.
public enum SpeakerMuteAdoption {
    /// `keptMuted`: the speakers were muted in this Maestro session before the
    /// unit was lost (a replug, power cycle or link drop). The unit forgets
    /// its mute then and answers unmuted; it is muted again (only ever
    /// towards muted, never louder). Owner, 2026-11-22, replug test.
    public static func decide(unitMuted: Bool, keptMuted: Bool = false)
        -> (showMuted: Bool, writeUnit: Bool, tellMac: Bool) {
        if !unitMuted && keptMuted { return (true, true, true) }
        return (unitMuted, false, unitMuted)
    }
}

/// A4: the speaker and headphone levels put on the unit when Maestro
/// connects to it, or the unit comes back under a running connection (a
/// power cycle, a link recovery).
///
/// The original owned these levels on the Mac and wrote its own copy at every
/// connect, whatever the unit held (`SymphonyIO::ApplySettingsToHardware`,
/// og_source/maestrolink/Software/SymphonyIO.cpp:4660-4687: speaker volume at
/// :4670, each headphone's at :4677; saved to its preferences from :5103). It
/// also polled the unit for front panel changes to keep that copy current
/// (`getParameterUpdates`, :6459-6460). Ours sends the QUIETER of the level saved on
/// this Mac and the level the unit reports, so a connect never makes anything
/// louder than either: a unit that came up at its own default (-20 dB) goes
/// back down to a lower saved level, and a level turned down on the front
/// panel while Maestro was closed is kept.
///
/// Levels are attenuations, 0...64 dB, where more is quieter (the unit's own
/// unit, `SymphonyIOControl` speaker/headphone volume).
public enum MonitorLevelsAtConnect {
    public enum Output: CaseIterable, Sendable, Equatable {
        case speakers, headphone1, headphone2
    }

    /// Highest valid attenuation; the unit's quietest step.
    public static let maximumAttenuation: UInt32 = 64

    /// The attenuation to write to one output, or nil to leave it alone.
    ///
    /// - `saved`: what this Mac last saw on the output (nil: nothing saved).
    /// - `unit`: what the unit reports now (nil: the read failed).
    /// - `speakersInLine`: the unit's speaker mode is Line, or could not be
    ///   read. Line has no speaker level (the unit answers 0), so the
    ///   speakers are never written then. The headphones still are.
    ///
    /// A value outside 0...64 is treated as unreadable, never clamped: a
    /// failed read can come back as 0xFF.
    public static func write(output: Output, saved: UInt32?, unit: UInt32?,
                             speakersInLine: Bool) -> UInt32? {
        if output == .speakers && speakersInLine { return nil }
        guard let saved, let unit, saved <= maximumAttenuation, unit <= maximumAttenuation else { return nil }
        return saved > unit ? saved : nil
    }

    /// The level the output is at once the connect step is done, which is
    /// what is saved from then on: the quieter of the two, or the unit's own
    /// when nothing is saved. Nil when the unit's level is not known (the
    /// saved one is then kept as it is).
    public static func settled(output: Output, saved: UInt32?, unit: UInt32?,
                               speakersInLine: Bool, written: Bool) -> UInt32? {
        if output == .speakers && speakersInLine { return nil }
        guard let unit, unit <= maximumAttenuation else { return nil }
        if written, let saved, saved <= maximumAttenuation { return max(saved, unit) }
        return unit
    }

    /// A level Maestro shows (dB, 0 loudest) as the attenuation saved for it;
    /// nil outside -64...0. Truncated, as the level knobs convert it for the
    /// unit (`UInt32(max(0, -level))`, MonitorViews/OutputViews), so what is
    /// saved is what landed.
    public static func attenuation(dB: Double) -> UInt32? {
        guard dB.isFinite, dB <= 0.5, dB >= -64.5 else { return nil }
        return UInt32(min(64, max(0, -dB)))
    }
}

public enum SampleRateText {
    /// "48 kHz", "44.1 kHz", "176.4 kHz"; other rates with up to three
    /// decimals and no trailing zeros ("47.952 kHz").
    public static func format(_ rate: Double) -> String {
        guard rate >= 1000 else { return "\(Int(rate)) Hz" }
        var text = String(format: "%.3f", rate / 1000)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return "\(text) kHz"
    }
}

/// Over USB the unit is its own clock master on Internal, and the original
/// showed "Ready" there. Elsewhere the reported state stands.
public enum ClockStatusRule {
    public static func shownLocked(isUSB: Bool, reported: Bool) -> Bool {
        isUSB || reported
    }
}

/// What a setup-file package is, from the names of the files in it.
public enum PresetPackageKind: Equatable, Sendable {
    case ours
    /// Saved by Apogee's Maestro 2: nothing of ours in it.
    case maestro2
    case oursWithDaemon
    case unknown

    public static let maestro2Message =
        "This setup file was saved by Apogee's Maestro 2. Maestro can't open those files."

    public static func classify(fileNames: [String]) -> PresetPackageKind {
        let names = Set(fileNames.map { URL(fileURLWithPath: $0).lastPathComponent })
        let ours = names.contains("ThunderBridge.plist") || names.contains("MaestroApp.plist")
        let old = names.contains("symphonyAIMDeviceList.plist") || names.contains("SymphonyPreference.plist")
        // Maestro 2 named each unit's file "<mode>_Symphony I_O_<id>.plist"
        // and wrote the device list only with a Symphony card present.
        let daemon = names.contains { $0.contains("_Symphony I_O_") && $0.hasSuffix(".plist") }
        if (old || daemon) && !ours { return .maestro2 }
        if ours && daemon { return .oursWithDaemon }
        if ours { return .ours }
        return .unknown
    }
}
