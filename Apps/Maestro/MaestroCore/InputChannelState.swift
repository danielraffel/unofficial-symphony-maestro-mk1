/// State for a single input channel.
///
/// `Codable` so values can be persisted to UserDefaults and `.mst2` preset files.
/// Since the Symphony IO MKI cannot be read back per-channel (P3G-31 BLOCKED),
/// state is restored from UserDefaults on startup so the UI reflects the last session.
///
/// Evidence: `og_source/maestro2/App/Model/APAudioDeviceModel.h`
/// Evidence: `og_source/maestro2/App/Model/CoreAudioPropertyKeys.plist`
/// - AEmg = micGain, AEph = phantom, AEre = phaseReverse
/// - AEhf = highPassFilter, AEsl = softLimit, AErl = analogIOType
public struct InputChannelState: Codable, Sendable, Equatable {
    /// Mic/line gain in dB (range 0..85). Maps to 'AEmg' (micGain).
    public var gain: Double = 0
    /// +48V phantom power enable. Maps to 'AEph' (phantom).
    public var phantom: Bool = false
    /// Phase inversion enable. Maps to 'AEre' (phaseReverse).
    public var phase: Bool = false
    /// High-pass filter enable. Maps to 'AEhf' (highPassFilter).
    public var hpf: Bool = false
    /// Soft limiter mode: 0=off, 1=−2dBFS, 2=−4dBFS, 3=Saturate, 4=Crunch.
    /// Maps to 'AEsl' (softLimit).
    public var softLimit: UInt32 = 0
    /// Analog input type (mic/line/instrument). Maps to 'AErl' (analogIOType).
    /// Default +4 dBu (1) matches original Maestro 2 line-level default.
    public var inputType: UInt32 = 1
    /// Calibration trim in dB. Range ±2.0 for +4dBu/-10dBV modes.
    /// Sent as part of the analog ref level USB command (byte[1]).
    /// Evidence: `SymphonyIOVendorSpecific.h` — DO_NOT_SET_TRIM_VALUE = 127
    public var trim: Double = 0
    /// Digital reference level ID. Maps to 'AEdr' (digitalRefLevel).
    /// 0=-20dBfs, 1=-18dBfs, 2=-16dBfs, 3=-14dBfs, 4=-12dBfs, 5=-10dBfs.
    /// Only shown in line-level modes (+4 dBu, -10 dBV).
    public var digitalRefLevel: UInt32 = 2  // default -16 dBfs (matches original)

    /// Mic-pre gain group. 0 = Off, 1...8 = group number. Maps to 'AEgp'
    /// (`kmAEstroPropertyGroup`, USB opcode `0xC7 SymphonyIOCommands_ChannelGroup`).
    /// Grouped channels move by a shared *relative* offset; their pre-existing
    /// gain differences are preserved.
    /// Evidence: `SymphonyIOVendorSpecific.h:1072-1083` (`eSymphonyIOMicPre8ChGroup_*`),
    /// `SymphonyIOBoard_MicPre8ch.cpp:186-330` (`UpdateMicPreGain`).
    public var group: UInt32 = 0

    /// Mic-pre insert assignment. 0 = None, 1...8 = "Insert N". Maps to 'AEit'
    /// (`kmAEstroPropertyInsert`, USB opcode `0xC8 SymphonyIOCommands_Insert`).
    /// Insert IDs are EXCLUSIVE across channels — an ID claimed by another
    /// channel is offered greyed out (`SymphonyIOBoard_MicPre8ch.cpp:1216-1248`).
    public var insert: UInt32 = 0

    /// Insert return ("In") enable. Maps to 'AEir'
    /// (`kmAEstroPropertyInsertReturnEnable`, USB opcode
    /// `0xC9 SymphonyIOCommands_InsertEnable`). Follows the insert assignment
    /// automatically whenever that changes (`SymphonyIOBoard_MicPre8ch.cpp:608-617`).
    public var insertReturn: Bool = false

    public init(
        gain: Double = 0,
        phantom: Bool = false,
        phase: Bool = false,
        hpf: Bool = false,
        softLimit: UInt32 = 0,
        inputType: UInt32 = 1,
        trim: Double = 0,
        digitalRefLevel: UInt32 = 2,
        group: UInt32 = 0,
        insert: UInt32 = 0,
        insertReturn: Bool = false
    ) {
        self.gain = gain
        self.phantom = phantom
        self.phase = phase
        self.hpf = hpf
        self.softLimit = softLimit
        self.inputType = inputType
        self.trim = trim
        self.digitalRefLevel = digitalRefLevel
        self.group = group
        self.insert = insert
        self.insertReturn = insertReturn
    }

    /// Tolerant decoding: every key is optional and falls back to its default.
    ///
    /// The synthesized `init(from:)` requires **every** key to be present, so
    /// adding a stored property would make the whole saved `[InputChannelState]`
    /// in UserDefaults (and every older `.mst2` preset) fail to decode — silently,
    /// because the call site uses `try?`, wiping the user's channel settings.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = InputChannelState()
        gain            = try c.decodeIfPresent(Double.self, forKey: .gain) ?? d.gain
        phantom         = try c.decodeIfPresent(Bool.self,   forKey: .phantom) ?? d.phantom
        phase           = try c.decodeIfPresent(Bool.self,   forKey: .phase) ?? d.phase
        hpf             = try c.decodeIfPresent(Bool.self,   forKey: .hpf) ?? d.hpf
        softLimit       = try c.decodeIfPresent(UInt32.self, forKey: .softLimit) ?? d.softLimit
        inputType       = try c.decodeIfPresent(UInt32.self, forKey: .inputType) ?? d.inputType
        trim            = try c.decodeIfPresent(Double.self, forKey: .trim) ?? d.trim
        digitalRefLevel = try c.decodeIfPresent(UInt32.self, forKey: .digitalRefLevel) ?? d.digitalRefLevel
        group           = try c.decodeIfPresent(UInt32.self, forKey: .group) ?? d.group
        insert          = try c.decodeIfPresent(UInt32.self, forKey: .insert) ?? d.insert
        insertReturn    = try c.decodeIfPresent(Bool.self,   forKey: .insertReturn) ?? d.insertReturn
    }
}

// MARK: - Analog reference level (WIRE enum)

/// Analog reference level, in the **wire** encoding used by USB command `0x20`
/// (`SymphonyIOCommands_AnalogReferenceLevel`) and stored in
/// `InputChannelState.inputType`.
///
/// TRAP: two different enums exist for this concept and they do NOT agree.
/// - Wire (this one): `Variable=0, Plus4dBu=1, Minus10dBV=2, Mic=3, Instrument=4`
///   Evidence: `og_source/symphonymk1/ext/SymphonyIO/generic/Products/SymphonyIO/SymphonyIOVendorSpecific.h:714-723`
/// - CoreAudio property layer: `4dBu=0, 10dBV=1, Variable=2, Mic=3, Instrument=4`
///   Evidence: `og_source/generic/CoreAudio/mAEstro.h:352-360`
///
/// The app persists and transmits the WIRE values (see
/// `SymphonyIOPropertyMapper` `.analogIOType`, which passes byte[0] straight
/// through), so this enum is wire-ordered.
public enum AnalogInputLevel: UInt32, Sendable, CaseIterable {
    case variable   = 0
    case plus4dBu   = 1
    case minus10dBV = 2
    case mic        = 3
    case instrument = 4

    /// UI label for the level.
    public var displayName: String {
        switch self {
        case .variable:   return "Variable"
        case .plus4dBu:   return "+4 dBu"
        case .minus10dBV: return "-10 dBV"
        case .mic:        return "Mic"
        case .instrument: return "Instrument"
        }
    }

    /// True for the two mic-preamp-backed levels (Mic, Instrument).
    /// These are the levels that expose the preamp strip (48V / Ø / HPF)
    /// and swap the trim fader for a gain knob.
    public var isPreampLevel: Bool { self == .mic || self == .instrument }
}

/// How the Digital Ref popup should be presented for a given analog level.
///
/// Evidence: `og_source/symphonymk1/ext/maestrolink/Software/AnalogIn_SymphonyIO_Stream.cpp:768-787`
/// — the daemon reports `kmAEstroPropertyDigitalRefLevel` NOT IMPLEMENTED when the
/// level is Variable, so the legacy app had a nil value and hid the popup.
/// Evidence: `og_source/maestro2/App/Controllers/Input/APAnalogInputController.m:854`
/// — for Mic/Instrument the control is `setEnabled:NO`; the adjacent `setHidden:YES`
/// is commented out, i.e. hiding was deliberately rejected.
public enum DigitalRefVisibility: Sendable, Equatable {
    /// Shown and interactive (fixed line levels: +4 dBu, -10 dBV).
    case enabled
    /// Shown but greyed out (Mic, Instrument).
    case disabled
    /// Not rendered at all (Variable — property not implemented).
    case hidden
}

// MARK: - Input page business logic

/// Pure, view-independent rules for the Input page.
///
/// Everything here is a function of (analog level, channel number, installed
/// card) — no CoreAudio, no SwiftUI — so it is unit-testable and shared by the
/// channel strip and any future preset/reset code.
public enum InputChannelLogic {

    // MARK: Digital Ref

    /// Whether the Digital Ref popup is shown, greyed, or hidden.
    public static func digitalRefVisibility(for level: AnalogInputLevel) -> DigitalRefVisibility {
        switch level {
        case .variable:              return .hidden
        // HIDDEN, not greyed. Corrected 2026-09-11 against two independent
        // sources: the reporter's own screenshot of the original app and
        // Apogee's manual (p. 56) both show the Digital Ref cell BLANK on Mic
        // channels while Soft Limit still shows "Off" beneath it.
        //
        // An earlier reading of APAnalogInputController.m concluded "present but
        // disabled" from a setEnabled:NO call. The binding is what actually
        // governs (:349-354): `hidden` is bound to trackingDigitalRefLevel with
        // NSNotApplicablePlaceholderBindingOption = YES, so when the analog
        // level makes a digital reference meaningless the popup is hidden.
        //
        // Which makes sense: Digital Ref maps a FIXED analog reference onto
        // digital full scale. Mic and Instrument have no fixed reference, so
        // there is nothing to map -- the same reason Variable hides it.
        case .mic, .instrument:      return .hidden
        case .plus4dBu, .minus10dBV: return .enabled
        }
    }

    public static func digitalRefVisibility(forRawLevel raw: UInt32) -> DigitalRefVisibility {
        digitalRefVisibility(for: AnalogInputLevel(rawValue: raw) ?? .plus4dBu)
    }

    // MARK: Channel label

    /// Channel strip label. Derived live from the channel's current analog level.
    ///
    /// The MicPre delegate names its channels from their current level and returns
    /// NULL for anything else, falling through to the analog stream's "Line N".
    /// Numbering is continuous across the whole device, not per-card.
    ///
    /// Evidence: `SymphonyIOBoard_MicPre8ch.cpp:914-961` (Mic N / Inst N / NULL),
    /// `SymphonyIO_Stream.cpp:653-655` (Line N fallback).
    ///
    /// - Parameter number: 1-based device-wide channel number.
    public static func channelLabel(number: Int, level: AnalogInputLevel) -> String {
        switch level {
        case .mic:        return "Mic \(number)"
        case .instrument: return "Inst \(number)"
        default:          return "Line \(number)"
        }
    }

    public static func channelLabel(number: Int, rawLevel raw: UInt32) -> String {
        channelLabel(number: number, level: AnalogInputLevel(rawValue: raw) ?? .plus4dBu)
    }

    // MARK: Analog level options

    /// Analog level choices for one channel.
    ///
    /// Capability is per-CHANNEL, not per-card:
    /// - plain analog input → Variable, +4 dBu, -10 dBV
    /// - MicPre-backed channels 1-4 → + Mic + Instrument
    /// - MicPre-backed channels 5-8 → + Mic only
    ///
    /// `Instrument` on channels 1-4 only is a hardware constraint — the module has
    /// exactly four 1/4" instrument jacks (`cstNumInputsWithInstrument = 4`,
    /// `SymphonyIOBoard_MicPre8ch.cpp:26`, option-list trim at `:965-980`).
    ///
    /// - Parameters:
    ///   - number: 1-based device-wide channel number.
    ///   - micPreBacked: whether a MicPre8 module feeds this channel.
    public static func analogLevelOptions(number: Int, micPreBacked: Bool) -> [AnalogInputLevel] {
        var options: [AnalogInputLevel] = [.variable, .plus4dBu, .minus10dBV]
        guard micPreBacked else { return options }
        options.append(.mic)
        if number >= 1 && number <= micPreInstrumentChannelCount {
            options.append(.instrument)
        }
        return options
    }

    /// Number of MicPre channels that have a physical instrument jack.
    /// Evidence: `cstNumInputsWithInstrument = 4` (`SymphonyIOBoard_MicPre8ch.cpp:26`).
    public static let micPreInstrumentChannelCount = 4

    /// Number of channels a MicPre8 module delegates onto the primary card.
    /// Evidence: `kSymphonyIOMicPre8_NumberOfChannels` — the module is a delegate
    /// on the slot-0 analog input stream (`SymphonyIO.cpp:955-961`).
    public static let micPreChannelCount = 8

    /// Whether the given 1-based channel is backed by a MicPre module.
    ///
    /// A MicPre8 has no channels of its own — it installs as a delegate on the
    /// primary board's analog input stream, so its eight preamps appear as
    /// analog inputs 1-8 of the whole device.
    /// Host-blind: assumes any MicPre8 delegates onto eight channels. Correct
    /// only while `micPreInstalled` is already the usable flag. Prefer the
    /// host-aware overload -- a MicPre8 delegates onto the host card's analog
    /// input stream, so the host is what decides whether preamps exist.
    @available(*, deprecated, message: "Use the hostAnalogInputChannels overload.")
    public static func isMicPreBacked(number: Int, micPreInstalled: Bool) -> Bool {
        micPreInstalled && number >= 1 && number <= micPreChannelCount
    }

    /// How many channels a MicPre8 actually delegates onto, given the number of
    /// ANALOG INPUT channels the host card contributes.
    ///
    /// A MicPre8 is not an independent card: `installMicPre`
    /// (`SymphonyIO_IOBoard.cpp:606-625`) walks the HOST board's input streams
    /// looking for one whose terminal type is `ExtAnalogConnector` and delegates
    /// onto it. If the host has no analog input stream the function returns false
    /// and no delegation happens at all -- and `SymphonyIO.cpp:960` ignores that
    /// return value, so nothing reports the failure. The preamps simply do not
    /// exist, silently.
    ///
    /// The case that matters is a **16 Digital In + 16 Analog Out** card, which
    /// contributes zero analog inputs: pairing it with a MicPre8 gives eight
    /// preamps attached to nothing. The User's Guide says so outright (p. 91:
    /// the module "cannot be used with the 2x6 analog card or the 16 digital in +
    /// 16 analog out card because they do not have at least 8 channels of analog
    /// input available").
    ///
    /// Where the Guide and the source disagree, this follows the SOURCE. The
    /// Guide calls a 2x6 pairing unsupported outright; `installMicPre` will
    /// happily delegate onto the 2x6's two analog inputs, and that is what the
    /// original Maestro would then have displayed. Hiding the controls entirely
    /// there would deviate from legacy behaviour on real hardware, so the count
    /// is clamped to what the host card can actually carry instead.
    public static func micPreBackedChannelCount(hostAnalogInputChannels: Int) -> Int {
        hostAnalogInputChannels >= micPreMinimumHostAnalogInputs ? micPreChannelCount : 0
    }

    /// Analog INPUT channels a host card must have before a MicPre8 can attach.
    ///
    /// The User's Guide states this as a threshold twice on p. 91, in both
    /// directions. Asked about the 2x6 and the 16 Digital In + 16 Analog Out
    /// card: "No. The Mic Pre module cannot be used with [them] because they do
    /// not have at least 8 channels of analog input available." Asked about the
    /// 16x16 and the 16 Analog In + 16 Digital Out card: "Yes. The first 8 of the
    /// 16 input channels can be set as Mic ... channels 9-16 are limited to
    /// line-level." The module page says the same in product terms -- it
    /// "upgrades the functionality of any 8x8 or 16x16 module".
    ///
    /// This is a DELIBERATE DEVIATION from what the daemon would do, adopted
    /// because the Guide states the product rule and the daemon does not encode
    /// one. Reviewed against og_source: nothing in `SymphonyIO.cpp` refuses a
    /// 2x6 + MicPre pairing. The 2x6 pushes a 2-wide analog input stream first
    /// (`SymphonyIOBoard_2x6.cpp:40-43`) whose terminal type is
    /// `ExtAnalogConnector`, so `installMicPre` attaches to it, and Maestro 2
    /// decided "is this a mic pre channel" per channel from whether the daemon
    /// offered Mic/Inst (`APAnalogInputController.m:557-579`) rather than from a
    /// board table. Legacy would therefore have drawn TWO Mic-capable strips on
    /// a 2x6 + MicPre. Delegation is not all-or-nothing either: the MicPre
    /// answers elements 1-8 and defers the rest to the host stream
    /// (`MicPre8ch.cpp:373`, `AnalogIn_SymphonyIO_Stream.cpp:150-155`), so the
    /// mechanical count is `min(8, host stream width)`.
    ///
    /// We follow the Guide anyway: it says "No" twice and in as many words, and
    /// two preamps on a card Apogee documents as unsupported is a worse thing to
    /// ship than one missing edge case. Whether the hardware honours Mic mode on
    /// a 2x6 at all is not modelled anywhere in og_source, so neither rule can be
    /// proven against the unit -- nobody has the hardware to test it.
    public static let micPreMinimumHostAnalogInputs = 8

    /// Whether an installed MicPre8 can actually deliver preamps, given the two
    /// installed cards. THE single predicate -- the Input tab and the Help sheet
    /// both key off this, because they drifted apart once already: Input gained
    /// the host-card requirement while Help still keyed on board type alone, so a
    /// pairing that showed no preamp controls still offered a Mic Pre help
    /// section explaining them.
    ///
    /// A MicPre8 belongs in slot 2; the daemon refuses to initialise at all with
    /// one in slot 1 (`SymphonyIO.cpp:935-951`, which alerts and returns false).
    /// Either order is accepted here and the OTHER card is treated as the host,
    /// so a mis-reported slot degrades to the right answer rather than none.
    ///
    /// A MicPre in slot 2 with slot 1 EMPTY also makes the daemon refuse the unit
    /// (`SymphonyIO.cpp:957-958`). Here that falls out as host `.none` -> 0
    /// analog inputs -> not usable: the same visible outcome by a different
    /// route, which is the safe direction to be wrong in.
    public static func micPreIsUsable(primary: IOCardType, secondary: IOCardType) -> Bool {
        guard primary == .micPre8 || secondary == .micPre8 else { return false }
        let host = primary == .micPre8 ? secondary : primary
        return micPreBackedChannelCount(hostAnalogInputChannels: host.analogInputChannels) > 0
    }

    /// Whether the given 1-based channel is backed by a MicPre, accounting for
    /// the host card's analog input count. See `micPreBackedChannelCount`.
    public static func isMicPreBacked(
        number: Int,
        micPreInstalled: Bool,
        hostAnalogInputChannels: Int
    ) -> Bool {
        guard micPreInstalled else { return false }
        return number >= 1
            && number <= micPreBackedChannelCount(hostAnalogInputChannels: hostAnalogInputChannels)
    }

    // MARK: Preamp strip

    /// Whether the 48V / Ø / HPF row is shown for this channel.
    ///
    /// Per the Symphony I/O user guide these appear when a Mic Pre module is
    /// installed AND the analog level is Mic **or Instrument** (polarity and the
    /// high-pass filter are useful on an instrument DI too). Phantom is separately
    /// interlocked to Mic — see `phantomAllowed`.
    public static func showsPreampControls(micPreBacked: Bool, level: AnalogInputLevel) -> Bool {
        micPreBacked && level.isPreampLevel
    }

    /// Whether +48 V may be engaged at this level.
    ///
    /// The daemon REFUSES phantom on any channel not set to Mic: it returns
    /// success and re-notifies (so the UI snaps back) but never issues `0xC6`
    /// (`SymphonyIOBoard_MicPre8ch.cpp:686-696`, contract at `mAEstro.h:924-927`).
    public static func phantomAllowed(level: AnalogInputLevel) -> Bool { level == .mic }

    /// High-pass filter corner frequency. Fixed in firmware — the corner is never
    /// exposed over USB. The user guide supplies the value: "engage an 80Hz
    /// high-pass filter on the input".
    public static let highPassFrequencyHz = 80

    // MARK: Gain (Mic / Instrument)

    /// Preamp gain range in dB for a preamp level, or nil for line levels.
    ///
    /// Mic gain `0xC3` is 0-85 dB, instrument gain `0xC4` is 0-65 dB, both in
    /// 1 dB steps (`SymphonyIOConstants.micGainMaximum` / `instrumentGainMaximum`).
    public static func gainRange(for level: AnalogInputLevel) -> ClosedRange<Double>? {
        switch level {
        case .mic:        return 0...85
        case .instrument: return 0...65
        default:          return nil
        }
    }

    /// True when the strip should render a gain KNOB instead of a trim fader.
    /// The widget swap is driven by the analog level, not the card
    /// (`APAnalogInputController.m:583-590`).
    public static func usesGainKnob(level: AnalogInputLevel) -> Bool { level.isPreampLevel }

    /// Clamp a gain value into the legal range for the level (0 for line levels).
    public static func clampGain(_ gain: Double, level: AnalogInputLevel) -> Double {
        guard let range = gainRange(for: level) else { return 0 }
        return min(max(gain.rounded(), range.lowerBound), range.upperBound)
    }

    // MARK: Group (MicPre only)

    /// Number of gain groups a MicPre8 offers, in addition to "Off".
    /// Evidence: `eSymphonyIOMicPre8ChGroup_Off=0 … _8=8`
    /// (`SymphonyIOVendorSpecific.h:1072-1083`).
    public static let micPreGroupCount = 8

    /// The "no group" value (wire value 0).
    public static let groupOff: UInt32 = 0

    /// Group popup contents: Off, then 1...8.
    /// Evidence: `s_szSymphonyIOMicPreGroupNames[] = {"Off","1"..."8"}`
    /// (`SymphonyIOBoard_MicPre8ch.cpp:29`).
    public static func groupOptions() -> [(value: UInt32, name: String)] {
        [(groupOff, "Off")] + (1...UInt32(micPreGroupCount)).map { ($0, "\($0)") }
    }

    public static func groupName(_ value: UInt32) -> String {
        value == groupOff ? "Off" : "\(value)"
    }

    /// Whether the Group popup is shown for this channel.
    ///
    /// Group and Insert exist only on MicPre-backed channels, and only while the
    /// channel sits at a preamp level: leaving Mic/Instrument forces the group to
    /// Off and frees the insert (`SymphonyIOBoard_MicPre8ch.cpp:455-465`, `:513-526`).
    ///
    /// MATCHES LEGACY. An earlier comment here called this a deliberate deviation,
    /// on the reading that legacy's popups were static and left a dead "Off"/
    /// "None" popup on a MicPre channel switched to a line level. That was wrong:
    /// the daemon answers `kmAEstroPropertyGroup`/`Insert` at any level, but the
    /// APP hides the controls -- `APAnalogInputController.m:737-742`
    /// (`initTrimControl` sends `setHidden:YES` to groupLabel, groupPopup,
    /// insertLabel and insertPopup) with `initMicPreMode` showing them again.
    /// The User's Guide FAQ (p. 91) agrees: the insert option "is only visible on
    /// channels that have the source set to Mic or Instrument".
    public static func showsGroupControl(micPreBacked: Bool, level: AnalogInputLevel) -> Bool {
        micPreBacked && level.isPreampLevel
    }

    /// The 0-based indices that belong to `group`, limited to the eight MicPre channels.
    /// `Off` is never a group — channels set to Off are independent.
    public static func groupMembers(_ group: UInt32, in channels: [InputChannelState]) -> [Int] {
        guard group != groupOff else { return [] }
        return (0..<min(channels.count, micPreChannelCount)).filter { channels[$0].group == group }
    }

    /// What a gain move did, so the caller knows what to persist and what to push.
    public struct GainChangeResult: Sendable, Equatable {
        /// 0-based indices whose stored gain value moved.
        public var changed: [Int]
        /// The offset actually applied, after the group-wide clamp.
        public var appliedOffset: Double
        /// 0-based indices that must be written to the hardware.
        ///
        /// For a grouped move this is ONLY the channel the user touched: the
        /// firmware derives every other member's gain itself, and re-sending the
        /// derived values would apply the offset twice.
        /// Evidence: `SymphonyIOBoard_MicPre8ch.cpp:293-299` ("Don't set any derived
        /// group gains down to firmware … The device is also calculating grouped
        /// gain changes").
        public var hardwareWrites: [Int]
    }

    /// Apply a gain request to one channel, honouring group membership.
    ///
    /// Ungrouped: a plain clamped assignment.
    ///
    /// Grouped: the request becomes a *relative* offset
    /// (`requested - current`), the offset is then clamped against **every**
    /// member in ascending channel order so no member would leave its own legal
    /// range, and the surviving offset is added to each member. Pre-existing
    /// differences between members are therefore preserved — the group moves, it
    /// does not converge. Line-level members (only reachable if a group somehow
    /// outlived a level change) neither clamp nor move, exactly as the `default:`
    /// branches in the daemon do nothing.
    ///
    /// Evidence: `SymphonyIOBoard_MicPre8ch.cpp:186-330` (`UpdateMicPreGain`).
    ///
    /// MODEL NOTE: the daemon keeps SEPARATE mic and instrument gain stores per
    /// channel and switches between them with the level; `InputChannelState` has a
    /// single `gain`, so a Mic → Instrument → Mic round trip does not restore the
    /// old mic gain. Splitting the store belongs with the `0xC4` instrument-gain
    /// work (see `SymphonyIOCommand.instrumentGain`, still unmapped).
    @discardableResult
    public static func applyGainChange(
        _ channels: inout [InputChannelState],
        channel index: Int,
        to requested: Double
    ) -> GainChangeResult {
        guard channels.indices.contains(index) else {
            return GainChangeResult(changed: [], appliedOffset: 0, hardwareWrites: [])
        }

        let level = AnalogInputLevel(rawValue: channels[index].inputType) ?? .plus4dBu
        let group = channels[index].group

        // Ungrouped — or a level that carries no gain at all.
        guard group != groupOff, gainRange(for: level) != nil else {
            let before = channels[index].gain
            channels[index].gain = clampGain(requested, level: level)
            let changed = channels[index].gain == before ? [] : [index]
            return GainChangeResult(
                changed: changed,
                appliedOffset: channels[index].gain - before,
                hardwareWrites: [index])
        }

        var offset = requested.rounded() - channels[index].gain
        let members = groupMembers(group, in: channels)

        // Pass 1 — shrink the offset until every member can take it.
        for member in members {
            let memberLevel = AnalogInputLevel(rawValue: channels[member].inputType) ?? .plus4dBu
            guard let range = gainRange(for: memberLevel) else { continue }
            let gain = channels[member].gain
            if offset + gain > range.upperBound { offset = range.upperBound - gain }
            if offset + gain < range.lowerBound { offset = range.lowerBound - gain }
        }

        // Pass 2 — move every member by the surviving offset.
        var changed: [Int] = []
        if offset != 0 {
            for member in members {
                let memberLevel = AnalogInputLevel(rawValue: channels[member].inputType) ?? .plus4dBu
                guard gainRange(for: memberLevel) != nil else { continue }
                channels[member].gain += offset
                changed.append(member)
            }
        }
        return GainChangeResult(changed: changed, appliedOffset: offset, hardwareWrites: [index])
    }

    // MARK: Insert (MicPre only)

    /// Number of inserts a MicPre8 offers, in addition to "None".
    /// Evidence: `eSymphonyIOMicPre8ChInsert_Off=0 … _8=8`
    /// (`SymphonyIOVendorSpecific.h:1086-1097`).
    public static let micPreInsertCount = 8

    /// The "no insert" value (wire value 0).
    public static let insertNone: UInt32 = 0

    /// Display name for an insert ID.
    /// Evidence: `s_szSymphonyIOMicPreInsertNames[] = {"None","Insert 1"...}`
    /// (`SymphonyIOBoard_MicPre8ch.cpp:31`).
    public static func insertName(_ value: UInt32) -> String {
        InsertLabels.defaultName(value)
    }

    /// Display name honouring the user's own insert labels (Device Settings).
    /// Legacy shares one set of names across every channel -- see `InsertLabels`.
    public static func insertName(_ value: UInt32, labels: InsertLabels) -> String {
        value == insertNone ? "None" : labels[value]
    }

    /// Whether the Insert popup and its "In" button are shown for this channel.
    /// Same rule, and the same deliberate deviation, as `showsGroupControl`.
    public static func showsInsertControls(micPreBacked: Bool, level: AnalogInputLevel) -> Bool {
        micPreBacked && level.isPreampLevel
    }

    /// Whether insert `id` may be chosen for `index`.
    ///
    /// Insert IDs are exclusive: the daemon reports an ID already claimed by a
    /// *different* channel as disabled, and the legacy popup greys it out rather
    /// than hiding it. "None" is always available.
    /// Evidence: `kmAEstroPropertyInsertEnableForID`
    /// (`SymphonyIOBoard_MicPre8ch.cpp:1216-1248`), menu-item enabling at
    /// `APAnalogInputController.m:425-441`.
    public static func insertAvailable(_ id: UInt32, forChannel index: Int, in channels: [InputChannelState]) -> Bool {
        guard id != insertNone else { return true }
        for other in 0..<min(channels.count, micPreChannelCount) where other != index {
            if channels[other].insert == id { return false }
        }
        return true
    }

    /// Insert popup contents for one channel, each entry carrying its enabled state.
    public static func insertOptions(
        forChannel index: Int,
        in channels: [InputChannelState],
        labels: InsertLabels = InsertLabels()
    ) -> [(value: UInt32, name: String, enabled: Bool)] {
        (0...UInt32(micPreInsertCount)).map { id in
            (id, insertName(id, labels: labels), insertAvailable(id, forChannel: index, in: channels))
        }
    }

    /// Assign an insert to a channel.
    ///
    /// The insert return follows the assignment whenever the assignment actually
    /// changes: picking an insert enables the return, picking None disables it.
    /// Evidence: `SymphonyIOBoard_MicPre8ch.cpp:608-617`.
    ///
    /// - Returns: `true` when the insert-return state changed and must be pushed too.
    @discardableResult
    public static func applyInsertChange(
        _ channels: inout [InputChannelState],
        channel index: Int,
        to insert: UInt32
    ) -> Bool {
        guard channels.indices.contains(index) else { return false }
        guard insertAvailable(insert, forChannel: index, in: channels) else { return false }
        let previous = channels[index].insert
        channels[index].insert = insert
        guard previous != insert else { return false }
        channels[index].insertReturn = (insert != insertNone)
        return true
    }

    /// The channel bitmask the firmware expects for one insert.
    ///
    /// Mirrors `SetInsertAssignmentInHardware`
    /// (`SymphonyIOBoard_MicPre8ch.cpp:1790-1810`) byte for byte:
    ///
    /// ```cpp
    /// if(m_anInsert[nCh]==(SymphonyIOMicPre8ChInsert)(nInsert+1))
    ///     cNewMask=0x01<<nCh;
    /// ```
    ///
    /// Note the **assignment**, not `|=`. Two channels claiming the same insert
    /// would yield only the last one's bit — correct only because
    /// ``insertAvailable(_:forChannel:in:)`` keeps inserts exclusive. This
    /// reproduces that exactly rather than "fixing" it, so the wire bytes match
    /// the daemon the firmware was written against.
    ///
    /// - Parameters:
    ///   - insert: 0-based INSERT index (insert ID 1...8 → 0...7).
    ///   - insertPerChannel: insert ID per 0-based MicPre channel.
    /// - Returns: `0x01 << channel`, or 0 when no channel holds that insert.
    public static func insertChannelMask(insert: Int, insertPerChannel: [UInt32]) -> UInt8 {
        var mask: UInt8 = 0
        for channel in 0..<micPreChannelCount where channel < insertPerChannel.count {
            if insertPerChannel[channel] == UInt32(insert + 1) {
                mask = 0x01 << UInt8(channel)
            }
        }
        return mask
    }

    /// The complete eight-entry insert table the firmware is handed on every
    /// change — an insert nobody holds is written as mask 0, which is what
    /// releases it. Insert 0 first.
    ///
    /// Evidence: `SymphonyIOBoard_MicPre8ch.cpp:1790-1810` — the loop runs over
    /// all `kSymphonyIOMicPre8_NumberOfChannels` inserts, not just the one that moved.
    public static func insertAssignmentMasks(
        insertPerChannel: [UInt32]
    ) -> [(insert: Int, mask: UInt8)] {
        (0..<micPreInsertCount).map {
            ($0, insertChannelMask(insert: $0, insertPerChannel: insertPerChannel))
        }
    }

    /// Convenience over ``insertAssignmentMasks(insertPerChannel:)`` for channel state.
    public static func insertAssignmentMasks(
        in channels: [InputChannelState]
    ) -> [(insert: Int, mask: UInt8)] {
        insertAssignmentMasks(insertPerChannel: channels.map(\.insert))
    }

    // MARK: Trim (line levels)

    /// Trim fader range + step for a line level, or nil when the level sends no trim.
    ///
    /// +4 dBu / -10 dBV → ±2.0 dB at 0.1 dB resolution (`round(10*dB)`).
    /// Variable          → 0…25.0 dB at 0.5 dB resolution (`round(2*dB)`).
    /// Mic / Instrument  → no trim byte at all.
    ///
    /// Evidence: `SymphonyIOControl.cpp:595-618` (encoding),
    /// `SymphonyIO_Stream.h:22-25` (kSymIO_TrimMax/Min constants).
    public static func trimRange(for level: AnalogInputLevel) -> (range: ClosedRange<Double>, step: Double)? {
        switch level {
        case .plus4dBu, .minus10dBV: return (-2.0...2.0, 0.1)
        case .variable:              return (0.0...25.0, 0.5)
        case .mic, .instrument:      return nil
        }
    }

    /// Clamp a trim value into the legal range for the level (0 when no trim applies).
    public static func clampTrim(_ trim: Double, level: AnalogInputLevel) -> Double {
        guard let spec = trimRange(for: level) else { return 0 }
        return min(max(trim, spec.range.lowerBound), spec.range.upperBound)
    }

    /// The sentinel meaning "set the type, leave trim alone".
    /// Evidence: `DO_NOT_SET_TRIM_VALUE = 127` (`SymphonyIOVendorSpecific.h`).
    public static let doNotSetTrimByte: UInt8 = 127

    /// Encode the trim byte (byte[1] of command `0x20`) for a level + trim value.
    ///
    /// Mic/Instrument send the do-not-set sentinel. A computed value that would
    /// collide with the sentinel is nudged to 126 — exactly as the daemon does
    /// (`SymphonyIOControl.cpp:631-634`).
    public static func trimByte(trim: Double, level: AnalogInputLevel) -> UInt8 {
        guard let spec = trimRange(for: level) else { return doNotSetTrimByte }
        let scale = 1.0 / spec.step          // 10 for ±2 dB, 2 for Variable
        let clamped = clampTrim(trim, level: level)
        var encoded = Int((clamped * scale).rounded())
        encoded = min(max(encoded, -128), 127)
        if encoded == Int(doNotSetTrimByte) { encoded = Int(doNotSetTrimByte) - 1 }
        return UInt8(bitPattern: Int8(encoded))
    }

    /// Pack analog level + trim into the single UInt32 the property mapper expects:
    /// bits[7:0] = wire level, bits[15:8] = trim byte.
    public static func analogIOTypeWithTrim(level: AnalogInputLevel, trim: Double) -> UInt32 {
        (UInt32(trimByte(trim: trim, level: level)) << 8) | level.rawValue
    }

    // MARK: Soft limit

    /// Soft limit choices for the card that owns this channel.
    ///
    /// Most cards expose the full five-value list. The 16x16 (`analogADDA16`)
    /// overrides it to Off / On, where "On" is the -4 dBfs setting, and rejects
    /// anything else (`ADDA16AnalogIn_SymphonyIO_Stream.cpp:14`, `:100-140`).
    ///
    /// TODO(card-capability): this really belongs on `IOCardType` (or better, a
    /// per-channel capability read), but `DeviceDescriptor.swift` is owned elsewhere.
    public static func softLimitOptions(card: IOCardType) -> [(value: UInt32, name: String)] {
        if card == .analogADDA16 {
            return [(0, "Off"), (2, "On")]
        }
        return [(0, "Off"), (1, "-2 dBFS"), (2, "-4 dBFS"), (3, "Saturate"), (4, "Crunch")]
    }

    /// Display name for a soft limit value on a given card.
    public static func softLimitName(_ value: UInt32, card: IOCardType) -> String {
        softLimitOptions(card: card).first(where: { $0.value == value })?.name ?? "Off"
    }

    /// Coerce a stored soft limit value into something the card accepts.
    /// The ADDA16 only knows Off (0) and -4 dBfs (2); any other stored value
    /// (e.g. carried over from a different card) collapses to the nearest legal one.
    public static func coerceSoftLimit(_ value: UInt32, card: IOCardType) -> UInt32 {
        let options = softLimitOptions(card: card)
        if options.contains(where: { $0.value == value }) { return value }
        return value == 0 ? 0 : (card == .analogADDA16 ? 2 : 0)
    }

    // MARK: Level transitions

    /// Apply an analog level change to a channel, enforcing every dependent rule.
    ///
    /// Fixes a legacy bug rather than copying it: leaving Mic CLEARS phantom.
    /// Legacy declared `fTurnOffPhantomPower`, assigned it, and never read it, so
    /// +48 V stayed latched and `ApplySettingsToHardware` re-pushed it to a channel
    /// that was now Instrument or Line.
    ///
    /// - Returns: `true` when phantom was cleared as a side effect, so the caller
    ///   knows it must also push `AEph = false` to the hardware.
    @discardableResult
    public static func applyLevelChange(_ state: inout InputChannelState, to level: AnalogInputLevel) -> Bool {
        state.inputType = level.rawValue

        // Phantom is Mic-only. Any transition out of Mic drops it.
        var clearedPhantom = false
        if state.phantom && !phantomAllowed(level: level) {
            state.phantom = false
            clearedPhantom = true
        }

        // Gain and trim are mutually exclusive and range-dependent on the level.
        state.gain = clampGain(state.gain, level: level)
        state.trim = clampTrim(state.trim, level: level)

        // Setting the analog level ALWAYS drops the channel out of its gain group
        // — unconditionally, even Mic → Instrument.
        // Evidence: `SymphonyIOBoard_MicPre8ch.cpp:513-526`.
        state.group = groupOff

        // Leaving Mic/Instrument frees the insert and disables its return: the
        // MicPre delegate hands the channel back to the plain analog stream and
        // releases the insert on the way out.
        // Evidence: `SymphonyIOBoard_MicPre8ch.cpp:455-465`.
        if !level.isPreampLevel {
            state.insert = insertNone
            state.insertReturn = false
        }

        return clearedPhantom
    }

    // MARK: Reset Trims / Hide Trims

    /// "Reset Trims" — set trim to 0.0 on every analog input and change NOTHING else.
    ///
    /// The name oversells it: legacy simply calls `setTrim:0.0` on each analog
    /// input controller (`APInputTabRowViewController.m:247-255` →
    /// `APAnalogInputController.m:545-548`). Gain, level, phantom, soft limit,
    /// group and insert are untouched, and it is a hardware no-op on
    /// Mic/Instrument channels, which carry no trim byte at all.
    ///
    /// "Hide Trims" is purely cosmetic — it toggles the visibility of the trim
    /// fader and is remembered per device UID
    /// (`APAnalogInputSidebarViewController.m:99-124`). It does not gate Reset
    /// Trims: legacy only *hides* the Reset button when no channel supports trim
    /// at all (`:92-93`).
    ///
    /// - Returns: the 0-based indices that must actually be pushed to the
    ///   hardware — i.e. the channels whose level has a trim byte.
    @discardableResult
    public static func resetTrims(_ channels: inout [InputChannelState]) -> [Int] {
        var writes: [Int] = []
        for i in channels.indices {
            channels[i].trim = 0
            let level = AnalogInputLevel(rawValue: channels[i].inputType) ?? .plus4dBu
            if trimRange(for: level) != nil { writes.append(i) }
        }
        return writes
    }

    // MARK: Option-click — apply to every channel

    /// Option-clicking the Analog Level popup applies the choice to every other
    /// channel that offers it.
    ///
    /// Channels that cannot offer the level are SKIPPED, not coerced — legacy
    /// guards with `isThereAnalogReferenceLevel:` before assigning, so
    /// option-clicking "Mic" on a MicPre-backed strip leaves the plain analog
    /// strips alone, and "Instrument" leaves channels 5-8 alone.
    /// Evidence: `APInputTabRowViewController.m:258-271`.
    ///
    /// Each affected channel runs the full transition (clamping, phantom,
    /// group and insert clearing), so the caller must push those too.
    ///
    /// - Returns: the 0-based indices that changed level.
    @discardableResult
    public static func applyLevelToAll(
        _ channels: inout [InputChannelState],
        to level: AnalogInputLevel,
        micPreInstalled: Bool,
        hostAnalogInputChannels: Int,
        excluding origin: Int
    ) -> [Int] {
        var changed: [Int] = []
        for i in channels.indices where i != origin {
            let micPreBacked = isMicPreBacked(
                number: i + 1, micPreInstalled: micPreInstalled,
                hostAnalogInputChannels: hostAnalogInputChannels)
            let options = analogLevelOptions(number: i + 1, micPreBacked: micPreBacked)
            guard options.contains(level), channels[i].inputType != level.rawValue else { continue }
            applyLevelChange(&channels[i], to: level)
            changed.append(i)
        }
        return changed
    }

    /// Option-clicking the Digital Ref popup applies the value to every other
    /// channel, unconditionally.
    /// Evidence: `APInputTabRowViewController.m:275-283`.
    ///
    /// - Returns: the 0-based indices that changed.
    @discardableResult
    public static func applyDigitalRefToAll(
        _ channels: inout [InputChannelState],
        to value: UInt32,
        excluding origin: Int
    ) -> [Int] {
        var changed: [Int] = []
        for i in channels.indices where i != origin && channels[i].digitalRefLevel != value {
            channels[i].digitalRefLevel = value
            changed.append(i)
        }
        return changed
    }

    /// Option-clicking the Soft Limit popup applies the value to every other
    /// channel — falling back to **Off** where the channel's card does not offer
    /// that value, rather than to the nearest legal one.
    ///
    /// This is deliberately NOT `coerceSoftLimit`: legacy bug 9466 was fixed by
    /// looking the value up in the destination channel's own option list and
    /// setting 0 when it is missing (`APInputTabRowViewController.m:287-330`).
    ///
    /// - Parameter cards: the owning card per 0-based channel index; missing
    ///   entries are treated as `.none` (full five-value list).
    /// - Returns: the 0-based indices that changed.
    @discardableResult
    public static func applySoftLimitToAll(
        _ channels: inout [InputChannelState],
        to value: UInt32,
        cards: [IOCardType],
        excluding origin: Int
    ) -> [Int] {
        var changed: [Int] = []
        for i in channels.indices where i != origin {
            let card = i < cards.count ? cards[i] : .none
            let available = softLimitOptions(card: card).contains { $0.value == value }
            let resolved: UInt32 = available ? value : 0
            guard channels[i].softLimit != resolved else { continue }
            channels[i].softLimit = resolved
            changed.append(i)
        }
        return changed
    }

    // MARK: Reset to defaults

    /// What a reset restored, so the caller knows what to push and in what order.
    public struct InputResetResult: Sendable, Equatable {
        /// 0-based indices whose stored state actually moved.
        public var changed: [Int]
        /// Of those, the ones a MicPre module feeds (device inputs 1-8).
        public var micPreChannels: [Int]
        /// True when at least one channel gave up an insert, so the eight-insert
        /// table has to be rewritten (`0xC8` is addressed by insert, not channel).
        public var releasedAnInsert: Bool

        public init(changed: [Int] = [], micPreChannels: [Int] = [], releasedAnInsert: Bool = false) {
            self.changed = changed
            self.micPreChannels = micPreChannels
            self.releasedAnInsert = releasedAnInsert
        }
    }

    /// Restore the Input page to the factory defaults the legacy daemon defines.
    ///
    /// TWO code paths, and they do NOT obey the scope the same way:
    ///
    /// * `AnalogIn_SymphonyIO_Stream::ResetToDefaults`
    ///   (`AnalogIn_SymphonyIO_Stream.cpp:26-48`) resets **soft limit on every
    ///   channel unconditionally**, and only then, *if the scope is not
    ///   `ResetAllButCalibration`*, resets analog ref to +4 dBu, digital ref to
    ///   -16 dBfs and all three trim stores to 0.0. Trims are calibration data,
    ///   and so — in the legacy grouping — are the two reference levels.
    /// * `SymphonyIOBoard_MicPre8ch::ResetToDefaults`
    ///   (`SymphonyIOBoard_MicPre8ch.cpp:2301-2325`) takes the cookie and
    ///   **ignores it**: a MicPre channel is reset in full either way — input type
    ///   +4 dBu, mic and instrument gain 0, group Off, insert Off, insert return,
    ///   high-pass, phantom and polarity all false.
    ///
    /// The asymmetry is deliberate legacy behaviour, not a simplification: under
    /// "keep trims" a MicPre channel still drops to +4 dBu while a plain line
    /// channel keeps its reference level. Reproduced as-is.
    ///
    /// - Parameters:
    ///   - includingCalibration: `SymphonyIOResetScope.resetsTrims` — true for
    ///     `ResetAll`, false for `ResetAllButCalibration`.
    ///   - micPreInstalled: whether an 8MicPre module is present at all. With no
    ///     module this touches line-channel settings only.
    @discardableResult
    public static func resetToDefaults(
        _ channels: inout [InputChannelState],
        includingCalibration: Bool,
        micPreInstalled: Bool,
        hostAnalogInputChannels: Int
    ) -> InputResetResult {
        var result = InputResetResult()
        for i in channels.indices {
            let before = channels[i]
            let isMicPre = isMicPreBacked(
                number: i + 1, micPreInstalled: micPreInstalled,
                hostAnalogInputChannels: hostAnalogInputChannels)

            // Analog input stream: soft limit is reset in BOTH scopes.
            channels[i].softLimit = InputResetDefaults.softLimit

            // MicPre delegate: full reset, no scope check.
            if isMicPre {
                channels[i].inputType = InputResetDefaults.analogLevel.rawValue
                channels[i].gain = InputResetDefaults.gain
                channels[i].group = InputResetDefaults.group
                channels[i].insert = InputResetDefaults.insert
                channels[i].insertReturn = InputResetDefaults.insertReturn
                channels[i].hpf = InputResetDefaults.highPassFilter
                channels[i].phantom = InputResetDefaults.phantom
                channels[i].phase = InputResetDefaults.polarity
            }

            // The calibration block — skipped by ResetAllButCalibration.
            if includingCalibration {
                channels[i].inputType = InputResetDefaults.analogLevel.rawValue
                channels[i].digitalRefLevel = InputResetDefaults.digitalRefLevel
                channels[i].trim = InputResetDefaults.trim
            }

            guard channels[i] != before else { continue }
            result.changed.append(i)
            if isMicPre { result.micPreChannels.append(i) }
            // Only a MicPre-backed channel can hold a hardware insert, and only
            // the MicPre branch clears one. A stale `insert` value on a unit with
            // no module (left over from a saved layout, or a card swap) must NOT
            // trigger an eight-write `0xC8` rebuild at hardware that has no
            // inserts to release.
            if isMicPre && before.insert != insertNone { result.releasedAnInsert = true }
        }
        return result
    }

    /// Whether a phantom request should actually reach the hardware.
    /// Mirrors the daemon: a request on a non-Mic channel is silently dropped and
    /// the UI is re-notified with the unchanged (false) value.
    public static func resolvePhantomRequest(_ requested: Bool, level: AnalogInputLevel) -> Bool {
        phantomAllowed(level: level) ? requested : false
    }
}


// MARK: - Input reset defaults

/// The factory values the legacy daemon restores on the Input page.
///
/// Evidence: `AnalogIn_SymphonyIO_Stream.cpp:26-48` (soft limit, analog ref,
/// digital ref, trims) and `SymphonyIOBoard_MicPre8ch.cpp:2301-2325` (input type,
/// gains, group, insert, insert return, high-pass, phantom, polarity).
/// Gain defaults: `kSymphonyIOMicPre8_MicGainDefault = 0` and
/// `kSymphonyIOMicPre8_InstrumentGainDefault = 0`
/// (`SymphonyIOVendorSpecific.h:1061`, `:1065`).
public enum InputResetDefaults {
    /// `eSymphonyIOSoftLimit_Off`.
    public static let softLimit: UInt32 = 0
    /// `emAEstroPropertyAnalogIOType_4dBu` — WIRE value 1, see `AnalogInputLevel`.
    public static let analogLevel: AnalogInputLevel = .plus4dBu
    /// The daemon stores the magnitude (`m_anDigitalRefLevel[i] = 16`); the app
    /// stores the option index, and -16 dBfs is index 2.
    public static let digitalRefLevel: UInt32 = 2
    public static let trim: Double = 0
    /// Both mic (`0xC3`) and instrument (`0xC4`) gain default to 0 dB.
    public static let gain: Double = 0
    public static let group = InputChannelLogic.groupOff
    public static let insert = InputChannelLogic.insertNone
    public static let insertReturn = false
    public static let highPassFilter = false
    public static let phantom = false
    public static let polarity = false
}
