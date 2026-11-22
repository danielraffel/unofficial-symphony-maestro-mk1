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
    public static func decide(unitMuted: Bool) -> (showMuted: Bool, writeUnit: Bool, tellMac: Bool) {
        (unitMuted, false, unitMuted)
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
        let daemon = names.contains { $0.hasPrefix("USBAudio_Symphony I_O_") && $0.hasSuffix(".plist") }
        if old && !ours { return .maestro2 }
        if ours && daemon { return .oursWithDaemon }
        if ours { return .ours }
        return .unknown
    }
}
