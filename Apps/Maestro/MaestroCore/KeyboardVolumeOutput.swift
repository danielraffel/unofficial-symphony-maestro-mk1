import Foundation

/// Device Settings › Volume Keys › Audio Output: which output of a unit the
/// Mac's volume and mute keys move.
///
/// The original's "Keyboard Volume Control" had this pop-up
/// (`og_source/symphonymk1/ext/maestro2/App/Controllers/
/// APSystemKeyboardVolumeControlViewController.m:41-84`), filled per unit with
/// Speakers, Headphone 1 and Headphone 2 in that order
/// (`og_source/symphonymk1/ext/maestrolink/Software/SymphonyIO.cpp:3675-3698`).
/// Raw values 1-3 are the original's `eSymphonyIO_MonitorOutput`
/// (`og_source/symphonymk1/ext/SymphonyIO/generic/Products/SymphonyIO/
/// SymphonyIOVendorSpecific.h:977-982`) and are what the driver and the USB
/// helper are sent.
///
/// `mixer1Level` and `none` are for a cable of converters only, and are
/// ours: the original had no working volume there
/// (`og_source/symphonymk1/ext/maestrolink/Software/SymphonyController.cpp:
/// 638-646, 1834-1849, 4308-4323`).
public enum KeyboardVolumeOutput: UInt32, Sendable, Equatable, CaseIterable {
    /// Converters only: the keys do nothing and the card mixer level is back
    /// at 0 dB, unmuted.
    case none = 0
    case speakers = 1
    case headphone1 = 2
    case headphone2 = 3
    /// Converters only: the keys turn card Mixer 1 down and up.
    case mixer1Level = 4

    /// The first driver build with the selector that sets this.
    public static let requiredDriverBuild: UInt32 = 142

    /// Whether the serving ThunderBridge/PCIe driver can be told the choice.
    /// An older one moves the speakers, or Headphone 1 in Line mode, by itself.
    public static func driverSupports(_ servingBuild: ServingDextBuild?) -> Bool {
        guard case .build(let build) = servingBuild else { return false }
        return build >= requiredDriverBuild
    }

    /// The pop-up's entries, in order. A Symphony I/O: Speaker, Headphone 1,
    /// Headphone 2; without an analog output card the Speaker entry is left
    /// out (SymphonyIO.cpp:3680-3692). No "None" there. Converters only: the
    /// card mixer level, and None.
    public static func entries(hasAnalogOutput: Bool, convertersOnly: Bool) -> [KeyboardVolumeOutput] {
        if convertersOnly { return [.mixer1Level, .none] }
        return hasAnalogOutput ? [.speakers, .headphone1, .headphone2] : [.headphone1, .headphone2]
    }

    /// What is chosen when nothing is saved: Speakers (SymphonyIO.cpp:131,
    /// :1597), Headphone 1 without an analog output card (:1015-1018,
    /// :6087-6093); the card mixer level on converters.
    public static func defaultOutput(hasAnalogOutput: Bool, convertersOnly: Bool) -> KeyboardVolumeOutput {
        entries(hasAnalogOutput: hasAnalogOutput, convertersOnly: convertersOnly)[0]
    }

    /// The saved choice if this unit offers it, the default otherwise (a
    /// saved Speaker on a unit whose analog card was taken out becomes
    /// Headphone 1, as `SymphonyIO::changeMonitorOutput` did).
    ///
    /// With nothing saved and the unit in Line mode the choice is Headphone
    /// 1: in the original a unit with an analog output card only got into
    /// Line mode by the user setting it, which made Headphone 1 the choice
    /// (see `afterUserChange`), and Maestro versions before 0.9.20 moved
    /// Headphone 1 in Line mode without saving anything.
    public static func resolve(saved: UInt32?, hasAnalogOutput: Bool, convertersOnly: Bool,
                               speakerMode: UInt32? = nil) -> KeyboardVolumeOutput {
        let offered = entries(hasAnalogOutput: hasAnalogOutput, convertersOnly: convertersOnly)
        if let saved, let output = KeyboardVolumeOutput(rawValue: saved), offered.contains(output) { return output }
        if saved == nil, !convertersOnly, speakerMode == 0 { return .headphone1 }
        return offered[0]
    }

    /// The choice after the user changed the speaker mode on the Output page,
    /// as `SymphonyIO::UpdateMainOutputChannelMode` did
    /// (SymphonyIO.cpp:6107-6258): setting the mode to Off (Line) from
    /// another mode makes Headphone 1 the choice, whatever it was
    /// (:6142-6168), and the Mac's volume then shows Headphone 1's level. No
    /// other change touches it: leaving Line keeps the choice (Headphone 1
    /// unless the user picked another since), and setting the mode it already
    /// has does nothing (:6111). The original did this only here: a mode
    /// restored from saved settings (:4890-4930) or read from the unit
    /// (:1305-1322) was assigned without it, and the saved choice was then
    /// restored as it was (:4945-4950).
    public func afterUserChange(ofSpeakerModeFrom old: UInt32, to new: UInt32) -> KeyboardVolumeOutput {
        guard self != .none, self != .mixer1Level else { return self }
        return new == 0 && old != 0 ? .headphone1 : self
    }

    /// Whether the mute key does nothing with this choice: only None. With
    /// Speaker chosen in Line mode the original still set the speaker mute
    /// (SymphonyIO.cpp:2239-2251; only the volume set checks the mode).
    public var muteKeyDoesNothing: Bool { self == .none }

    /// How many speaker channels a speaker mode has, as the original counted
    /// them for the entry's name (SymphonyIO.cpp:3562-3571): 0 with the
    /// speaker mode Off (the Output page's Line), 6 for 5.1, 8 for 7.1, and 2
    /// for everything else (Stereo, and two or three speaker sets).
    public static func speakerChannelCount(speakerMode: UInt32) -> Int {
        switch speakerMode {
        case 0: return 0
        case 6: return 6
        case 8: return 8
        default: return 2
        }
    }

    /// The entry's name. The Symphony I/O names are the original's
    /// (SymphonyIO.cpp:3549-3580).
    public func label(speakerMode: UInt32) -> String {
        switch self {
        case .speakers: return "Speaker (\(Self.speakerChannelCount(speakerMode: speakerMode))ch)"
        case .headphone1: return "Headphone 1"
        case .headphone2: return "Headphone 2"
        case .mixer1Level: return "Mixer 1 level"
        case .none: return "None"
        }
    }

    /// Whether the volume keys move nothing with this choice: None, or
    /// Speaker while the speaker mode is Off (Line), where the original
    /// ignored the volume set (SymphonyIO.cpp:2345-2351). Speaker in Line
    /// mode is reached by choosing Speaker again after setting Line, which
    /// makes Headphone 1 the choice (`afterUserChange`).
    public func keysDoNothing(speakerMode: UInt32) -> Bool {
        switch self {
        case .none: return true
        case .speakers: return speakerMode == 0
        case .headphone1, .headphone2, .mixer1Level: return false
        }
    }

    /// The `output` word of the driver's selector 15
    /// (`SymphonyMonitorOutputInput`): 1-3 for a Symphony I/O; on converters
    /// 1 is the card mixer level and 0 is None.
    public var driverValue: UInt32 {
        switch self {
        case .none: return 0
        case .speakers, .mixer1Level: return 1
        case .headphone1: return 2
        case .headphone2: return 3
        }
    }

    /// The `output` of the USB helper's "setMonitorOutput" command; nil for
    /// the converter choices, which do not exist over USB.
    public var helperValue: UInt64? {
        switch self {
        case .speakers: return 1
        case .headphone1: return 2
        case .headphone2: return 3
        case .none, .mixer1Level: return nil
        }
    }

    /// The property that holds this output's level (an attenuation, 0-64 dB)
    /// and the one that holds its mute; nil for the converter choices.
    public var levelSelector: AudioPropertySelector? {
        switch self {
        case .speakers: return .outputLevel
        case .headphone1: return .headphone1Level
        case .headphone2: return .headphone2Level
        case .none, .mixer1Level: return nil
        }
    }

    public var muteSelector: AudioPropertySelector? {
        switch self {
        case .speakers: return .outputMute
        case .headphone1: return .headphone1Mute
        case .headphone2: return .headphone2Mute
        case .none, .mixer1Level: return nil
        }
    }

    /// A unit's name in the Peripheral pop-up: its prefix letter, a space and
    /// its name, as the original built it
    /// (`og_source/symphonymk1/ext/maestrolink/Software/SymphonyController.cpp:
    /// 1614-1637`, `"%c %s"`).
    public static func peripheralName(prefix: String, name: String) -> String {
        let letter = prefix.trimmingCharacters(in: .whitespaces)
        return letter.isEmpty ? name : "\(letter) \(name)"
    }
}
