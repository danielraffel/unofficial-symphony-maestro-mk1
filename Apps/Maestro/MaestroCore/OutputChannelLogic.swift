import Foundation

/// Pure rules for the Output tab's per-channel controls — the output-side
/// counterpart to `InputChannelLogic`.
///
/// Everything here is a value transform over `[OutputChannelState]` so the
/// semantics can be tested without a device, a view, or an `NSEvent`. The view
/// owns the hardware writes; this type owns *what* changes.
///
/// # Why the output rules are not the input rules
///
/// The output side has no Variable/Mic/Instrument levels, so every analog output
/// channel always offers both reference levels and the option-click fan-out
/// never has to skip a strip. In exchange it has a rule the input side does not:
/// the trim fader's **upper bound depends on the DIGITAL reference level**, not
/// the analog one.
///
/// Evidence:
/// * `AnalogOut_SymphonyIO_Stream.cpp:369-376` (`outputTrimRange`) — the range
///   the legacy trim fader binds to: minimum always `kSymIO_TrimMin_plus4min10`
///   (-2.0), maximum `0.0` when the channel's digital reference level is
///   -20 dBFS and `kSymIO_TrimMax_plus4max10` (+2.0) otherwise.
/// * `AnalogOut_SymphonyIO_Stream.cpp:206-236` — the setter enforces the same
///   ceiling before the value reaches the FPGA.
/// * User's Guide p. 74, calibration step 6: "when Output Digital Ref is set to
///   -20dBfs, only a negative Trim value is possible (0dB to -2 dB)."
/// * `APOutputTabRowViewController.m:230-253` — the two option-click fan-outs.
public enum OutputChannelLogic {

    // MARK: - Reference level wire values

    /// `eSymphonyIOAnalogIOType_Plus4dBu` (`SymphonyIOVendorSpecific.h:721`).
    public static let plus4dBu: UInt32 = 1
    /// `eSymphonyIOAnalogIOType_Minus10dBV` (`SymphonyIOVendorSpecific.h:722`).
    public static let minus10dBV: UInt32 = 2

    /// The analog reference levels an analog OUTPUT channel offers. Variable,
    /// Mic and Instrument are input-only — `AnalogOut_SymphonyIO_Stream.cpp:308-321`
    /// maps anything that is not -10 dBV onto +4 dBu.
    public static let analogRefLevels: [UInt32] = [plus4dBu, minus10dBV]

    /// `eSymphonyIODigitalReferenceLevel_Minus20dBfs` (`SymphonyIOVendorSpecific.h:740`).
    public static let digitalRefMinus20dBfs: UInt32 = 0
    /// The six digital reference levels, -20 dBFS through -10 dBFS.
    public static let digitalRefLevels: [UInt32] = [0, 1, 2, 3, 4, 5]

    /// Whether an analog output channel can be set to this analog reference level.
    ///
    /// Legacy guards the fan-out with "does the other channel's popup contain an
    /// item with this title" (`APOutputTabRowViewController.m:236`). On the
    /// output side every analog strip carries the same two-item popup, so this
    /// only rejects values that are not reference levels at all.
    public static func offersAnalogRef(_ level: UInt32) -> Bool {
        analogRefLevels.contains(level)
    }

    public static func offersDigitalRef(_ level: UInt32) -> Bool {
        digitalRefLevels.contains(level)
    }

    // MARK: - Trim

    /// Trim resolution, in dB. `round(10 * dB)` on the wire — the user guide's
    /// "+/- 0.1 dB".
    public static let trimStep: Double = 0.1
    /// `kSymIO_TrimMin_plus4min10` (`SymphonyIO_Stream.h:25`).
    public static let trimMinimum: Double = -2.0
    /// `kSymIO_TrimMax_plus4max10` (`SymphonyIO_Stream.h:24`).
    public static let trimMaximum: Double = 2.0

    /// Trim fader range + step for an output channel at this digital reference
    /// level. See the type comment for the evidence; the short version is that
    /// -20 dBFS already spends the headroom a positive trim would need.
    public static func trimRange(digitalRefLevel: UInt32)
        -> (range: ClosedRange<Double>, step: Double) {
        let upper = digitalRefLevel == digitalRefMinus20dBfs ? 0.0 : trimMaximum
        return (trimMinimum...upper, trimStep)
    }

    /// Clamp a trim into the legal range for a digital reference level.
    public static func clampTrim(_ trim: Double, digitalRefLevel: UInt32) -> Double {
        let spec = trimRange(digitalRefLevel: digitalRefLevel)
        return min(max(trim, spec.range.lowerBound), spec.range.upperBound)
    }

    /// "Reset Trims" — 0.0 dB on every analog output, nothing else touched.
    ///
    /// Legacy walks its analog output controllers calling `setTrim:0.0`
    /// (`APOutputTabRowViewController.m:218-228` →
    /// `APAnalogOutputController.m:264-277`). Reference levels are untouched.
    ///
    /// - Returns: the indices that must be pushed to the hardware — i.e. the
    ///   ones that were not already at 0.
    @discardableResult
    public static func resetTrims(_ channels: inout [OutputChannelState]) -> [Int] {
        var writes: [Int] = []
        for i in channels.indices where channels[i].trim != 0 {
            channels[i].trim = 0
            writes.append(i)
        }
        return writes
    }

    // MARK: - Single-channel changes

    /// Apply an analog reference level to one channel.
    ///
    /// - Returns: `true` when the stored value changed and a write is needed.
    @discardableResult
    public static func applyAnalogRefChange(
        _ channels: inout [OutputChannelState],
        channel index: Int,
        to level: UInt32
    ) -> Bool {
        guard channels.indices.contains(index), offersAnalogRef(level) else { return false }
        guard channels[index].analogRefLevel != level else { return false }
        channels[index].analogRefLevel = level
        return true
    }

    /// Apply a digital reference level to one channel, clamping its trim into
    /// the range the new level allows.
    ///
    /// - Returns: `trimChanged` — true when the clamp moved the trim, in which
    ///   case the caller must re-push the packed analog-IO-type command as well
    ///   as the digital reference level (the trim byte rides in byte[1] of
    ///   `0x20`, not in the digital-reference command).
    @discardableResult
    public static func applyDigitalRefChange(
        _ channels: inout [OutputChannelState],
        channel index: Int,
        to level: UInt32
    ) -> Bool {
        guard channels.indices.contains(index), offersDigitalRef(level) else { return false }
        channels[index].digitalRefLevel = level
        let clamped = clampTrim(channels[index].trim, digitalRefLevel: level)
        guard clamped != channels[index].trim else { return false }
        channels[index].trim = clamped
        return true
    }

    // MARK: - Option-click "apply to all"

    /// One channel touched by a fan-out.
    public struct FanOutChange: Sendable, Equatable {
        /// 0-based strip index.
        public let index: Int
        /// True when the trim was clamped as a side effect and the packed
        /// analog-IO-type command must be re-sent for this channel too.
        public let trimChanged: Bool

        public init(index: Int, trimChanged: Bool) {
            self.index = index
            self.trimChanged = trimChanged
        }
    }

    /// Option-clicking the Analog Ref popup applies the choice to every other
    /// analog output channel.
    ///
    /// Evidence: `APOutputTabRowViewController.m:230-243`. Legacy iterates
    /// `analogOutputs` only — digital output pairs have no reference level — and
    /// guards on the other channel's popup offering that title, which on the
    /// output side is always true for the two real levels.
    ///
    /// - Returns: the indices whose stored level changed, in ascending order.
    @discardableResult
    public static func applyAnalogRefToAll(
        _ channels: inout [OutputChannelState],
        to level: UInt32,
        excluding origin: Int
    ) -> [Int] {
        guard offersAnalogRef(level) else { return [] }
        var changed: [Int] = []
        for i in channels.indices where i != origin {
            if applyAnalogRefChange(&channels, channel: i, to: level) { changed.append(i) }
        }
        return changed
    }

    /// Option-clicking the Digital Ref popup applies the choice to every other
    /// analog output channel, clamping each one's trim.
    ///
    /// Evidence: `APOutputTabRowViewController.m:245-253`. Unlike the analog
    /// fan-out there is no "does it offer this" guard — every analog output
    /// carries the same six-item popup.
    ///
    /// - Returns: one entry per channel that needs a write. A channel already at
    ///   `level` is still reported when its trim had to be clamped, because the
    ///   clamp is a hardware change even though the reference level is not.
    @discardableResult
    public static func applyDigitalRefToAll(
        _ channels: inout [OutputChannelState],
        to level: UInt32,
        excluding origin: Int
    ) -> [FanOutChange] {
        guard offersDigitalRef(level) else { return [] }
        var changed: [FanOutChange] = []
        for i in channels.indices where i != origin {
            let wasAtLevel = channels[i].digitalRefLevel == level
            let trimChanged = applyDigitalRefChange(&channels, channel: i, to: level)
            if !wasAtLevel || trimChanged {
                changed.append(FanOutChange(index: i, trimChanged: trimChanged))
            }
        }
        return changed
    }

    // MARK: - S/PDIF Coax Mirrors

    /// `SymphonyIOBoardSPDIFCoaxReplace_Off` (`SymphonyIOVendorSpecific.h:941`).
    public static let spdifOffID: UInt32 = 0

    /// The S/PDIF Coax **Mirrors** list for an output slot.
    ///
    /// The coax output is always "tapped" from some other stereo pair (User's
    /// Guide p. 76: *"The S/PDIF Coax Output is 'tapped' from one of the other
    /// analog or digital stereo output pairs"*), so the mirror popup has no
    /// `Off`. Legacy builds the two lists from the same enum but with different
    /// lengths — `SymphonyIO_IOBoard.cpp:1204-1215`:
    ///
    /// ```
    /// Replace (input):  nNumIDs = 9;  aIDs[i] = i + 1;   // includes OFF
    /// Mirror  (output): nNumIDs = 8;  aIDs[i] = i + 2;   // doesn't includes OFF
    /// ```
    ///
    /// (Those are the daemon's 1-based property IDs; the wire enum they map onto
    /// is 0-based, so "mirror starts at 2" means "mirror starts at wire value
    /// 1".) `SymphonyIO_IOBoard::RecallSettingsFromHardware` agrees: its mirror
    /// switch has no `_Off` case and falls through to
    /// `"Invalid value for getSPDIFCoaxMirrorOutput"` (`:466-479`).
    ///
    /// `CardLayout.spdifOptions` prepends `Off` for both directions because the
    /// input side needs it; the output page drops it here.
    public static func mirrorOptions(
        _ options: [CardLayout.SPDIFOption]
    ) -> [CardLayout.SPDIFOption] {
        options.filter { $0.id != spdifOffID }
    }

    /// The mirror ID to display for a stored value: the stored one when the
    /// installed card offers it, else the first pair the card does offer.
    ///
    /// A card swap can strand a saved ID (an 8x8's "ADAT 7-8" is id 8; a 2x6
    /// offers ids 1-8 with entirely different meanings), and a device that never
    /// answered the read leaves the startup default in place. Both must land on
    /// a real entry rather than render an empty pill.
    public static func resolvedMirrorID(
        _ stored: UInt32,
        options: [CardLayout.SPDIFOption]
    ) -> UInt32? {
        let mirrors = mirrorOptions(options)
        if mirrors.contains(where: { $0.id == stored }) { return stored }
        return mirrors.first?.id
    }
}

// MARK: - Speaker & Headphone controls

/// Rules for the Output tab's Speaker / Headphone section — the "Analog Out
/// Format" modes a card pair can drive, which monitor functions each mode
/// leaves live, and the Speaker Select mask.
///
/// The speaker-mode IDs are deliberately raw `UInt32` here rather than
/// `SymphonyIOSpeakerMode`: that enum lives in `MaestroDevice`, which depends on
/// `MaestroCore` and not the other way round. The values are the same wire
/// values (`SymphonyIOVendorSpecific.h:967-975`) and the view converts.
public enum SpeakerOutputLogic {

    // MARK: Mode IDs — NON-CONTIGUOUS

    /// `eSymphonyIOSpeakerOutputMode_Off`. The daemon's own display name for it
    /// is **"Line"**, not "Off" (`SymphonyIO.cpp:3502`), which is also what the
    /// User's Guide calls it (p. 60, "Analog Out Format"): outputs 1/2 become
    /// plain line outputs and the monitor functions go away.
    public static let line: UInt32 = 0
    public static let stereo: UInt32 = 2
    public static let surround51: UInt32 = 6
    public static let surround71: UInt32 = 8
    public static let twoSpeakerSets: UInt32 = 9
    public static let threeSpeakerSets: UInt32 = 10

    /// Apogee's own name for a mode (`SymphonyIO.cpp:3500-3510`).
    public static func name(_ mode: UInt32) -> String {
        switch mode {
        case line:             return "Line"
        case stereo:           return "Stereo (Out 1-2)"
        case twoSpeakerSets:   return "2 Speaker Sets"
        case threeSpeakerSets: return "3 Speaker Sets"
        case surround51:       return "5.1 (Out 1-6)"
        case surround71:       return "7.1 (Out 1-8)"
        default:               return "Mode \(mode)"
        }
    }

    /// The Analog Out Format modes this unit can actually drive.
    ///
    /// The User's Guide says "5.1, 7.1: … (8x8 or 16x16 cards only)" (p. 60),
    /// but the daemon expresses the rule as an **analog output count**, which is
    /// the version implemented here — `kmAEstroPropertyMainOutChannelIDs`,
    /// `SymphonyIO.cpp:3429-3480`:
    ///
    /// ```
    /// >= 8 analog outs AND module 1 is not a 2x6 → Line, Stereo, 2 Sets, 3 Sets, 5.1, 7.1
    /// >= 6 analog outs                           → Line, Stereo, 2 Sets, 3 Sets, 5.1
    /// >= 2 analog outs                           → Line, Stereo
    /// 0 analog outs                              → Line
    /// ```
    ///
    /// Two details that are easy to get wrong and that the count rule settles:
    /// there is **no four-output tier**, so a card pair with four analog outs
    /// gets Stereo and nothing else — never "2 Speaker Sets" — and the count is
    /// the **device-wide** one (`NumberChannels(eAudioPlugType_Analog, false)`),
    /// so a 2x6 plus a 16-out module reaches the eight-output tier. The explicit
    /// 2x6-in-module-1 exclusion is what still keeps 7.1 off that pairing: the
    /// speakers hang off module 1's six outputs.
    ///
    /// - Parameters:
    ///   - analogOutputChannels: analog outputs across both modules.
    ///   - module1IsTwoBySix: true when the 2x6 occupies the module 1 slot.
    public static func availableModes(analogOutputChannels: Int,
                                      module1IsTwoBySix: Bool) -> [UInt32] {
        if analogOutputChannels >= 8 && !module1IsTwoBySix {
            return [line, stereo, twoSpeakerSets, threeSpeakerSets, surround51, surround71]
        }
        if analogOutputChannels >= 6 {
            return [line, stereo, twoSpeakerSets, threeSpeakerSets, surround51]
        }
        if analogOutputChannels >= 2 {
            return [line, stereo]
        }
        return [line]
    }

    // MARK: Which monitor functions a mode leaves live

    /// Whether the speaker level knob, Mute and Dim are live.
    ///
    /// `UpdateGUIDisableMask` (`SymphonyIO.cpp:7327-7333`) disables
    /// `eMaestroGUIComponentEnableBitMask_SpeakerOutput` when the mode is Line
    /// or the unit has no analog output. The User's Guide says the same: in Line
    /// mode "functions such as level control, Mute, Dim, and Sum to Mono are
    /// disabled" (p. 60).
    public static func speakerControlsEnabled(mode: UInt32,
                                              analogOutputChannels: Int) -> Bool {
        mode != line && analogOutputChannels > 0
    }

    /// Whether Sum to Mono is live. Disabled everywhere the speaker controls are,
    /// **plus** in 5.1 and 7.1 — folding six or eight channels to mono is not a
    /// meaningful operation. Evidence: `SymphonyIO.cpp:7335-7344`.
    public static func sumToMonoEnabled(mode: UInt32, analogOutputChannels: Int) -> Bool {
        guard speakerControlsEnabled(mode: mode, analogOutputChannels: analogOutputChannels)
        else { return false }
        return mode != surround51 && mode != surround71
    }

    /// Legacy `SymphonyIO::UpdateMainOutputChannelMode` clears the speaker
    /// monitor state whenever the user changes Analog Out Format. Keeping the
    /// rule in the shared logic makes the USB and ThunderBridge UI paths agree
    /// before either transport sends the ordered writes.
    public static func modeChangeClearsMonitorState(from oldMode: UInt32,
                                                     to newMode: UInt32) -> Bool {
        oldMode != newMode
    }

    // MARK: Speaker Select

    /// How many Speaker Select buttons this mode enables.
    /// `kMaestroProperty_NumberOfSpeakerSetSelections`, `SymphonyIO.cpp:3516-3533`:
    /// 2 in 2-Speaker-Sets, 3 in 3-Speaker-Sets, 0 in every other mode.
    public static func speakerSetCount(mode: UInt32) -> Int {
        switch mode {
        case twoSpeakerSets:   return 2
        case threeSpeakerSets: return 3
        default:               return 0
        }
    }

    /// Default Speaker Select mask — set A only (`SymphonyIO.cpp:168`).
    public static let defaultSpeakerSetMask: UInt32 = 0x1

    /// The mask a Speaker Select click produces.
    ///
    /// `selectSpeakerSet:` (`APSpeakerOutputViewController.m:738-760`): a plain
    /// click selects **only** that set; a Command-click ORs the buttons that are
    /// on, i.e. toggles this one into or out of the set; and a mask of zero is
    /// refused outright — "Do not allow all speaker sets to disengage".
    ///
    /// - Parameters:
    ///   - index: 0-based button (A/B/C, shown as 1/2/3).
    ///   - current: the mask in force.
    ///   - extending: true when Command is held.
    public static func speakerSetMask(clicking index: Int,
                                      current: UInt32,
                                      extending: Bool) -> UInt32 {
        guard (0..<3).contains(index) else { return current }
        let bit = UInt32(1 << index)
        guard extending else { return bit }
        let next = (current ^ bit) & 0x7
        return next == 0 ? current : next
    }

    /// Whether Speaker Select button `index` reads as engaged.
    /// A button the mode does not enable always reads off, whatever the mask
    /// says (`APSpeakerOutputViewController.m:797-812`).
    public static func speakerSetIsOn(index: Int, mask: UInt32, mode: UInt32) -> Bool {
        guard index < speakerSetCount(mode: mode) else { return false }
        return mask & UInt32(1 << index) != 0
    }
}
