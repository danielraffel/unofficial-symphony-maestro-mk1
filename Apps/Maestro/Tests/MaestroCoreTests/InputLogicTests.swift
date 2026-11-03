import Testing
import Foundation
@testable import MaestroCore

/// Input page business logic — the conditional rules that used to live (wrongly,
/// or not at all) inside `InputViews.swift`.
///
/// Evidence for every rule is cited on the corresponding member of
/// `InputChannelLogic`; the short form is repeated per test.
@Suite("InputChannelLogic")
struct InputLogicTests {

    // MARK: - Wire enum

    /// TRAP: the wire enum is NOT the property-layer enum. Wire is
    /// Variable=0, +4dBu=1, -10dBV=2, Mic=3, Instrument=4.
    /// Evidence: SymphonyIOVendorSpecific.h:714-723.
    @Test func wireEnumRawValues() {
        #expect(AnalogInputLevel.variable.rawValue == 0)
        #expect(AnalogInputLevel.plus4dBu.rawValue == 1)
        #expect(AnalogInputLevel.minus10dBV.rawValue == 2)
        #expect(AnalogInputLevel.mic.rawValue == 3)
        #expect(AnalogInputLevel.instrument.rawValue == 4)
    }

    @Test func defaultInputTypeIsPlus4dBu() {
        // The persisted default must decode to +4 dBu, not Variable.
        #expect(AnalogInputLevel(rawValue: InputChannelState().inputType) == .plus4dBu)
    }

    @Test func preampLevels() {
        #expect(AnalogInputLevel.mic.isPreampLevel)
        #expect(AnalogInputLevel.instrument.isPreampLevel)
        #expect(!AnalogInputLevel.variable.isPreampLevel)
        #expect(!AnalogInputLevel.plus4dBu.isPreampLevel)
        #expect(!AnalogInputLevel.minus10dBV.isPreampLevel)
    }

    // MARK: - Digital Ref visibility

    /// Variable → hidden (daemon reports the property not implemented).
    /// Mic/Instrument → present but disabled (legacy explicitly rejected hiding).
    /// Fixed line levels → shown and enabled.
    @Test func digitalRefVisibilityPerLevel() {
        #expect(InputChannelLogic.digitalRefVisibility(for: .variable) == .hidden)
        // Hidden, not greyed — see the corrected rule and its evidence.
        #expect(InputChannelLogic.digitalRefVisibility(for: .mic) == .hidden)
        #expect(InputChannelLogic.digitalRefVisibility(for: .instrument) == .hidden)
        #expect(InputChannelLogic.digitalRefVisibility(for: .plus4dBu) == .enabled)
        #expect(InputChannelLogic.digitalRefVisibility(for: .minus10dBV) == .enabled)
    }

    @Test func digitalRefVisibilityFromRawValue() {
        #expect(InputChannelLogic.digitalRefVisibility(forRawLevel: 0) == .hidden)
        #expect(InputChannelLogic.digitalRefVisibility(forRawLevel: 3) == .hidden)
        #expect(InputChannelLogic.digitalRefVisibility(forRawLevel: 1) == .enabled)
        // Unknown raw values fall back to the +4 dBu default rather than crashing.
        #expect(InputChannelLogic.digitalRefVisibility(forRawLevel: 99) == .enabled)
    }

    // MARK: - Channel label

    @Test func labelDerivesFromLevel() {
        #expect(InputChannelLogic.channelLabel(number: 3, level: .mic) == "Mic 3")
        #expect(InputChannelLogic.channelLabel(number: 3, level: .instrument) == "Inst 3")
        #expect(InputChannelLogic.channelLabel(number: 3, level: .plus4dBu) == "Line 3")
        #expect(InputChannelLogic.channelLabel(number: 3, level: .minus10dBV) == "Line 3")
        #expect(InputChannelLogic.channelLabel(number: 3, level: .variable) == "Line 3")
    }

    /// Setting a mic channel to +4 dBu turns its label back into "Line N" immediately.
    @Test func labelIsLive() {
        var state = InputChannelState(inputType: AnalogInputLevel.mic.rawValue)
        #expect(InputChannelLogic.channelLabel(number: 2, rawLevel: state.inputType) == "Mic 2")
        InputChannelLogic.applyLevelChange(&state, to: .plus4dBu)
        #expect(InputChannelLogic.channelLabel(number: 2, rawLevel: state.inputType) == "Line 2")
    }

    /// Numbering is continuous across the whole device, not per-card.
    @Test func labelNumberingIsDeviceWide() {
        #expect(InputChannelLogic.channelLabel(number: 16, level: .plus4dBu) == "Line 16")
        #expect(InputChannelLogic.channelLabel(number: 9, level: .variable) == "Line 9")
    }

    // MARK: - Analog level option list

    /// No MicPre: three line levels only.
    @Test func optionsWithoutMicPre() {
        for ch in 1...16 {
            let options = InputChannelLogic.analogLevelOptions(number: ch, micPreBacked: false)
            #expect(options == [.variable, .plus4dBu, .minus10dBV])
        }
    }

    /// MicPre channels 1-4 get Mic AND Instrument (four physical 1/4" jacks).
    @Test func optionsMicPreChannels1to4() {
        for ch in 1...4 {
            let options = InputChannelLogic.analogLevelOptions(number: ch, micPreBacked: true)
            #expect(options == [.variable, .plus4dBu, .minus10dBV, .mic, .instrument])
        }
    }

    /// MicPre channels 5-8 get Mic only.
    @Test func optionsMicPreChannels5to8() {
        for ch in 5...8 {
            let options = InputChannelLogic.analogLevelOptions(number: ch, micPreBacked: true)
            #expect(options == [.variable, .plus4dBu, .minus10dBV, .mic])
            #expect(!options.contains(.instrument))
        }
    }

    /// A MicPre8 delegates onto device inputs 1-8 only; 9+ are plain analog.
    @Test func micPreBackingWindow() {
        for ch in 1...8 {
            #expect(InputChannelLogic.isMicPreBacked(number: ch, micPreInstalled: true))
        }
        for ch in 9...16 {
            #expect(!InputChannelLogic.isMicPreBacked(number: ch, micPreInstalled: true))
        }
        for ch in 1...16 {
            #expect(!InputChannelLogic.isMicPreBacked(number: ch, micPreInstalled: false))
        }
    }

    // MARK: - Preamp strip gating

    /// The 48V / Ø / HPF row appears at Mic OR Instrument, not Mic alone.
    @Test func preampRowGating() {
        #expect(InputChannelLogic.showsPreampControls(micPreBacked: true, level: .mic))
        #expect(InputChannelLogic.showsPreampControls(micPreBacked: true, level: .instrument))
        #expect(!InputChannelLogic.showsPreampControls(micPreBacked: true, level: .plus4dBu))
        #expect(!InputChannelLogic.showsPreampControls(micPreBacked: true, level: .variable))
        // Never speculative: no MicPre means no preamp row at any level.
        #expect(!InputChannelLogic.showsPreampControls(micPreBacked: false, level: .mic))
    }

    @Test func highPassIsFixed80Hz() {
        #expect(InputChannelLogic.highPassFrequencyHz == 80)
    }

    // MARK: - 48 V interlock

    /// Phantom is Mic-only — the daemon silently refuses it at any other level.
    @Test func phantomAllowedOnlyAtMic() {
        #expect(InputChannelLogic.phantomAllowed(level: .mic))
        #expect(!InputChannelLogic.phantomAllowed(level: .instrument))
        #expect(!InputChannelLogic.phantomAllowed(level: .plus4dBu))
        #expect(!InputChannelLogic.phantomAllowed(level: .minus10dBV))
        #expect(!InputChannelLogic.phantomAllowed(level: .variable))
    }

    /// A phantom request on a non-Mic channel resolves to false — the daemon
    /// returns success, re-notifies, and never issues 0xC6, so the UI snaps back.
    @Test func phantomRequestRefusedOffMic() {
        #expect(InputChannelLogic.resolvePhantomRequest(true, level: .mic) == true)
        #expect(InputChannelLogic.resolvePhantomRequest(true, level: .instrument) == false)
        #expect(InputChannelLogic.resolvePhantomRequest(true, level: .plus4dBu) == false)
        #expect(InputChannelLogic.resolvePhantomRequest(false, level: .mic) == false)
    }

    /// FIXED legacy bug: leaving Mic clears phantom. Legacy declared
    /// `fTurnOffPhantomPower`, never read it, and re-pushed +48 V to a channel
    /// that was now Instrument or Line.
    @Test func leavingMicClearsPhantom() {
        for destination: AnalogInputLevel in [.instrument, .plus4dBu, .minus10dBV, .variable] {
            var state = InputChannelState(phantom: true, inputType: AnalogInputLevel.mic.rawValue)
            let cleared = InputChannelLogic.applyLevelChange(&state, to: destination)
            #expect(cleared, "phantom must be cleared when leaving Mic for \(destination)")
            #expect(state.phantom == false)
        }
    }

    @Test func stayingOnMicKeepsPhantom() {
        var state = InputChannelState(phantom: true, inputType: AnalogInputLevel.mic.rawValue)
        let cleared = InputChannelLogic.applyLevelChange(&state, to: .mic)
        #expect(!cleared)
        #expect(state.phantom)
    }

    @Test func phantomAlreadyOffReportsNoClear() {
        var state = InputChannelState(phantom: false, inputType: AnalogInputLevel.mic.rawValue)
        #expect(!InputChannelLogic.applyLevelChange(&state, to: .plus4dBu))
    }

    // MARK: - Gain (Mic / Instrument)

    /// Mic gain is 0-85 dB; instrument gain is 0-65 dB. Line levels have no gain.
    @Test func gainRanges() {
        #expect(InputChannelLogic.gainRange(for: .mic) == 0...85)
        #expect(InputChannelLogic.gainRange(for: .instrument) == 0...65)
        #expect(InputChannelLogic.gainRange(for: .plus4dBu) == nil)
        #expect(InputChannelLogic.gainRange(for: .minus10dBV) == nil)
        #expect(InputChannelLogic.gainRange(for: .variable) == nil)
    }

    @Test func gainKnobOnlyForPreampLevels() {
        #expect(InputChannelLogic.usesGainKnob(level: .mic))
        #expect(InputChannelLogic.usesGainKnob(level: .instrument))
        #expect(!InputChannelLogic.usesGainKnob(level: .plus4dBu))
        #expect(!InputChannelLogic.usesGainKnob(level: .variable))
    }

    /// Gain is integer dB and clamps into the level's range.
    @Test func gainClamping() {
        #expect(InputChannelLogic.clampGain(90, level: .mic) == 85)
        #expect(InputChannelLogic.clampGain(-5, level: .mic) == 0)
        #expect(InputChannelLogic.clampGain(42.6, level: .mic) == 43)
        // Mic 85 dB does not survive a swap to Instrument (max 65).
        #expect(InputChannelLogic.clampGain(85, level: .instrument) == 65)
        #expect(InputChannelLogic.clampGain(50, level: .plus4dBu) == 0)
    }

    @Test func gainClampedOnLevelChange() {
        var state = InputChannelState(gain: 85, inputType: AnalogInputLevel.mic.rawValue)
        InputChannelLogic.applyLevelChange(&state, to: .instrument)
        #expect(state.gain == 65)
        InputChannelLogic.applyLevelChange(&state, to: .plus4dBu)
        #expect(state.gain == 0)
    }

    // MARK: - Trim (line levels)

    /// ±2.0 dB at 0.1 dB steps for fixed line levels; 0…25.0 at 0.5 for Variable;
    /// Mic/Instrument send no trim at all.
    @Test func trimRanges() {
        let plus4 = InputChannelLogic.trimRange(for: .plus4dBu)
        #expect(plus4?.range == -2.0...2.0)
        #expect(plus4?.step == 0.1)

        let minus10 = InputChannelLogic.trimRange(for: .minus10dBV)
        #expect(minus10?.range == -2.0...2.0)
        #expect(minus10?.step == 0.1)

        let variable = InputChannelLogic.trimRange(for: .variable)
        #expect(variable?.range == 0.0...25.0)
        #expect(variable?.step == 0.5)

        #expect(InputChannelLogic.trimRange(for: .mic) == nil)
        #expect(InputChannelLogic.trimRange(for: .instrument) == nil)
    }

    @Test func trimClamping() {
        #expect(InputChannelLogic.clampTrim(5, level: .plus4dBu) == 2.0)
        #expect(InputChannelLogic.clampTrim(-5, level: .plus4dBu) == -2.0)
        #expect(InputChannelLogic.clampTrim(-3, level: .variable) == 0.0)
        #expect(InputChannelLogic.clampTrim(30, level: .variable) == 25.0)
        #expect(InputChannelLogic.clampTrim(1.5, level: .mic) == 0)
    }

    /// Trim byte encoding: round(10*dB) for fixed levels, round(2*dB) for Variable.
    @Test func trimByteEncoding() {
        #expect(InputChannelLogic.trimByte(trim: 1.5, level: .plus4dBu) == UInt8(bitPattern: 15))
        #expect(InputChannelLogic.trimByte(trim: -2.0, level: .minus10dBV) == UInt8(bitPattern: -20))
        #expect(InputChannelLogic.trimByte(trim: 0, level: .plus4dBu) == 0)
        // Variable: 25.0 dB in 0.5 dB steps → 50.
        #expect(InputChannelLogic.trimByte(trim: 25.0, level: .variable) == 50)
        #expect(InputChannelLogic.trimByte(trim: 12.5, level: .variable) == 25)
    }

    /// Mic/Instrument send the DO_NOT_SET_TRIM_VALUE sentinel (127).
    @Test func trimByteSentinelForPreampLevels() {
        #expect(InputChannelLogic.trimByte(trim: 1.0, level: .mic) == 127)
        #expect(InputChannelLogic.trimByte(trim: 0, level: .instrument) == 127)
        #expect(InputChannelLogic.doNotSetTrimByte == 127)
    }

    /// A computed 127 would be read as "do not set", so it is nudged to 126.
    /// No legal trim range can reach 127 today (max encoded value is 50), but the
    /// nudge is part of the daemon contract and must survive a range change.
    @Test func trimByteNeverCollidesWithSentinel() {
        for level: AnalogInputLevel in [.plus4dBu, .minus10dBV, .variable] {
            guard let spec = InputChannelLogic.trimRange(for: level) else { continue }
            var value = spec.range.lowerBound
            while value <= spec.range.upperBound {
                #expect(InputChannelLogic.trimByte(trim: value, level: level) != 127)
                value += spec.step
            }
        }
    }

    /// Packing: bits[7:0] = wire level, bits[15:8] = trim byte.
    @Test func analogIOTypePacking() {
        let packed = InputChannelLogic.analogIOTypeWithTrim(level: .plus4dBu, trim: 1.5)
        #expect(packed & 0xFF == AnalogInputLevel.plus4dBu.rawValue)
        #expect((packed >> 8) & 0xFF == 15)

        let micPacked = InputChannelLogic.analogIOTypeWithTrim(level: .mic, trim: 99)
        #expect(micPacked & 0xFF == AnalogInputLevel.mic.rawValue)
        #expect((micPacked >> 8) & 0xFF == 127)

        let negative = InputChannelLogic.analogIOTypeWithTrim(level: .minus10dBV, trim: -2.0)
        #expect((negative >> 8) & 0xFF == UInt32(UInt8(bitPattern: -20)))
    }

    @Test func trimClampedOnLevelChange() {
        // Variable trim of 20 dB is illegal at +4 dBu (±2.0).
        var state = InputChannelState(inputType: AnalogInputLevel.variable.rawValue, trim: 20)
        InputChannelLogic.applyLevelChange(&state, to: .plus4dBu)
        #expect(state.trim == 2.0)

        // A negative +4 dBu trim is illegal at Variable (0…25).
        var other = InputChannelState(inputType: AnalogInputLevel.plus4dBu.rawValue, trim: -1.5)
        InputChannelLogic.applyLevelChange(&other, to: .variable)
        #expect(other.trim == 0)
    }

    // MARK: - Soft limit

    /// Optical/AES (and everything else) expose the full five-value list.
    @Test func softLimitFullList() {
        for card: IOCardType in [.optical, .analogAES, .analogAD16, .analogDA16, .twoBySix, .none] {
            let options = InputChannelLogic.softLimitOptions(card: card)
            #expect(options.count == 5, "\(card) should expose five soft limit values")
            #expect(options.map(\.value) == [0, 1, 2, 3, 4])
            #expect(options.map(\.name) == ["Off", "-2 dBFS", "-4 dBFS", "Saturate", "Crunch"])
        }
    }

    /// The 16x16 overrides to Off / On, where On == -4 dBfs (value 2).
    @Test func softLimitADDA16IsOffOn() {
        let options = InputChannelLogic.softLimitOptions(card: .analogADDA16)
        #expect(options.count == 2)
        #expect(options.map(\.value) == [0, 2])
        #expect(options.map(\.name) == ["Off", "On"])
    }

    @Test func softLimitNames() {
        #expect(InputChannelLogic.softLimitName(2, card: .optical) == "-4 dBFS")
        #expect(InputChannelLogic.softLimitName(2, card: .analogADDA16) == "On")
        #expect(InputChannelLogic.softLimitName(3, card: .optical) == "Saturate")
        // A value the card rejects falls back to Off rather than showing "?".
        #expect(InputChannelLogic.softLimitName(3, card: .analogADDA16) == "Off")
    }

    /// Values carried over from another card collapse to something the card accepts.
    @Test func softLimitCoercion() {
        #expect(InputChannelLogic.coerceSoftLimit(0, card: .analogADDA16) == 0)
        #expect(InputChannelLogic.coerceSoftLimit(2, card: .analogADDA16) == 2)
        #expect(InputChannelLogic.coerceSoftLimit(3, card: .analogADDA16) == 2)
        #expect(InputChannelLogic.coerceSoftLimit(4, card: .analogADDA16) == 2)
        // Full-list cards keep every legal value untouched.
        for value: UInt32 in 0...4 {
            #expect(InputChannelLogic.coerceSoftLimit(value, card: .optical) == value)
        }
        #expect(InputChannelLogic.coerceSoftLimit(9, card: .optical) == 0)
    }

    // MARK: - The dev unit must be unaffected

    /// The user's hardware is Optical (3) + AnalogAD16 (4) with NO MicPre.
    /// Every rule must resolve to the pre-existing behaviour for that config,
    /// except the Digital Ref/Variable case and the level-dependent trim range.
    @Test func opticalPlusAD16NoMicPreIsUnchanged() {
        for ch in 1...24 {
            let micPreBacked = InputChannelLogic.isMicPreBacked(number: ch, micPreInstalled: false)
            #expect(!micPreBacked)
            #expect(InputChannelLogic.analogLevelOptions(number: ch, micPreBacked: micPreBacked)
                    == [.variable, .plus4dBu, .minus10dBV])
            #expect(!InputChannelLogic.showsPreampControls(micPreBacked: micPreBacked, level: .plus4dBu))
            #expect(InputChannelLogic.channelLabel(number: ch, level: .plus4dBu) == "Line \(ch)")
        }
        // Both installed cards keep the full soft limit list.
        #expect(InputChannelLogic.softLimitOptions(card: .optical).count == 5)
        #expect(InputChannelLogic.softLimitOptions(card: .analogAD16).count == 5)
        // Default level keeps Digital Ref visible and the ±2 dB trim fader.
        #expect(InputChannelLogic.digitalRefVisibility(for: .plus4dBu) == .enabled)
        #expect(InputChannelLogic.trimRange(for: .plus4dBu)?.range == -2.0...2.0)
        #expect(!InputChannelLogic.usesGainKnob(level: .plus4dBu))
    }

    /// Card detection is unreliable and often reports `.none`. Degrade sanely:
    /// three line-level options, no preamp row, "Line N" labels, full soft limits.
    @Test func undetectedCardDegradesSanely() {
        let options = InputChannelLogic.analogLevelOptions(number: 1, micPreBacked: false)
        #expect(options == [.variable, .plus4dBu, .minus10dBV])
        #expect(!InputChannelLogic.showsPreampControls(micPreBacked: false, level: .mic))
        #expect(InputChannelLogic.channelLabel(number: 1, level: .plus4dBu) == "Line 1")
        #expect(InputChannelLogic.softLimitOptions(card: .none).count == 5)
    }
}

// MARK: - Group, Insert, Reset Trims, option-click

/// The MicPre channel-strip rules that were missing from the rebuild: gain
/// groups, inserts, "Reset Trims", and legacy's option-click apply-to-all.
///
/// Evidence is cited per test; the primary sources are
/// `SymphonyIOBoard_MicPre8ch.cpp` (daemon rules) and
/// `APInputTabRowViewController.m` (option-click fan-out).
@Suite("InputChannelLogic — MicPre strip")
struct MicPreStripLogicTests {

    /// Eight mic-pre channels, all at Mic, with the given gains.
    private func micChannels(_ gains: [Double]) -> [InputChannelState] {
        gains.map { InputChannelState(gain: $0, inputType: AnalogInputLevel.mic.rawValue) }
    }

    // MARK: Group — options and gating

    @Test func groupOptionsAreOffThenOneToEight() {
        let options = InputChannelLogic.groupOptions()
        #expect(options.count == 9)
        #expect(options.first?.value == 0)
        #expect(options.first?.name == "Off")
        #expect(options.last?.value == 8)
        #expect(options.last?.name == "8")
        #expect(InputChannelLogic.groupName(0) == "Off")
        #expect(InputChannelLogic.groupName(5) == "5")
    }

    /// Group and Insert belong to the MicPre delegate, which only owns the
    /// channel while it sits at Mic or Instrument.
    @Test func groupAndInsertOnlyOnMicPrePreampChannels() {
        for level in AnalogInputLevel.allCases {
            let expected = level.isPreampLevel
            #expect(InputChannelLogic.showsGroupControl(micPreBacked: true, level: level) == expected)
            #expect(InputChannelLogic.showsInsertControls(micPreBacked: true, level: level) == expected)
            // No MicPre module → neither control exists at any level.
            #expect(!InputChannelLogic.showsGroupControl(micPreBacked: false, level: level))
            #expect(!InputChannelLogic.showsInsertControls(micPreBacked: false, level: level))
        }
    }

    // MARK: Group — relative moves

    /// A grouped move is RELATIVE: every member shifts by the same offset and
    /// the pre-existing differences between them survive.
    /// Evidence: `UpdateMicPreGain`, SymphonyIOBoard_MicPre8ch.cpp:249-320.
    @Test func groupedMoveIsRelativeAndPreservesOffsets() {
        var channels = micChannels([20, 30, 50, 0, 0, 0, 0, 0])
        channels[0].group = 1
        channels[1].group = 1
        channels[2].group = 2   // different group — must not move

        let result = InputChannelLogic.applyGainChange(&channels, channel: 0, to: 25)

        #expect(result.appliedOffset == 5)
        #expect(channels[0].gain == 25)
        #expect(channels[1].gain == 35)     // kept its +10 offset
        #expect(channels[2].gain == 50)     // other group untouched
        #expect(channels[3].gain == 0)      // ungrouped untouched
        #expect(result.changed == [0, 1])
    }

    /// Downward moves behave the same way.
    @Test func groupedMoveDownwardPreservesOffsets() {
        var channels = micChannels([40, 55, 0, 0, 0, 0, 0, 0])
        channels[0].group = 3
        channels[1].group = 3

        InputChannelLogic.applyGainChange(&channels, channel: 1, to: 45)

        #expect(channels[1].gain == 45)
        #expect(channels[0].gain == 30)
    }

    /// The offset is clamped against EVERY member, so the member closest to its
    /// ceiling limits the whole group — nobody is pinned and no offset is lost.
    /// Evidence: the first `for` loop of `UpdateMicPreGain` (:249-278).
    @Test func groupClampIsCollective() {
        var channels = micChannels([60, 80, 0, 0, 0, 0, 0, 0])
        channels[0].group = 1
        channels[1].group = 1

        // Asking for +25 on channel 1 would push channel 2 to 105; mic max is 85,
        // so the whole group can only move +5.
        let result = InputChannelLogic.applyGainChange(&channels, channel: 0, to: 85)

        #expect(result.appliedOffset == 5)
        #expect(channels[0].gain == 65)
        #expect(channels[1].gain == 85)
    }

    /// A group mixing Mic (0-85) and Instrument (0-65) members clamps to the
    /// tighter of the two ranges.
    @Test func groupClampRespectsPerMemberRange() {
        var channels = micChannels([10, 60, 0, 0, 0, 0, 0, 0])
        channels[1].inputType = AnalogInputLevel.instrument.rawValue
        channels[0].group = 2
        channels[1].group = 2

        let result = InputChannelLogic.applyGainChange(&channels, channel: 0, to: 40)

        #expect(result.appliedOffset == 5)   // instrument member caps at 65
        #expect(channels[0].gain == 15)
        #expect(channels[1].gain == 65)
    }

    /// Only the channel the user touched is written to the hardware — the
    /// firmware derives the rest of the group itself, and re-sending the derived
    /// values would double-apply the offset.
    /// Evidence: SymphonyIOBoard_MicPre8ch.cpp:293-299.
    @Test func onlyTheOriginatingChannelIsPushed() {
        var channels = micChannels([20, 20, 20, 0, 0, 0, 0, 0])
        for i in 0..<3 { channels[i].group = 4 }

        let result = InputChannelLogic.applyGainChange(&channels, channel: 2, to: 30)

        #expect(result.hardwareWrites == [2])
        #expect(channels.prefix(3).allSatisfy { $0.gain == 30 })
    }

    /// Group Off is not a group: two channels both set to Off stay independent.
    @Test func groupOffChannelsMoveAlone() {
        var channels = micChannels([20, 20, 0, 0, 0, 0, 0, 0])

        let result = InputChannelLogic.applyGainChange(&channels, channel: 0, to: 35)

        #expect(channels[0].gain == 35)
        #expect(channels[1].gain == 20)
        #expect(result.changed == [0])
        #expect(result.hardwareWrites == [0])
    }

    /// An ungrouped request is still clamped into the level's range.
    @Test func ungroupedMoveIsClamped() {
        var channels = micChannels([50, 0, 0, 0, 0, 0, 0, 0])
        InputChannelLogic.applyGainChange(&channels, channel: 0, to: 200)
        #expect(channels[0].gain == 85)

        channels[0].inputType = AnalogInputLevel.instrument.rawValue
        InputChannelLogic.applyGainChange(&channels, channel: 0, to: 200)
        #expect(channels[0].gain == 65)
    }

    /// Groups live on the MicPre8's own eight channels. A 16x16 strip beyond
    /// channel 8 that happens to carry the same stored group number is not a member.
    @Test func groupMembershipStopsAtTheMicPreChannelCount() {
        var channels = micChannels([10, 0, 0, 0, 0, 0, 0, 0])
            + micChannels([10, 10])          // device channels 9 and 10
        channels[0].group = 1
        channels[8].group = 1

        InputChannelLogic.applyGainChange(&channels, channel: 0, to: 20)

        #expect(channels[0].gain == 20)
        #expect(channels[8].gain == 10)      // outside the MicPre8 — untouched
        #expect(InputChannelLogic.groupMembers(1, in: channels) == [0])
    }

    /// Joining a group must not equalise or otherwise disturb gains — the daemon
    /// only writes the group assignment (0xC7); gains move at the next gain change.
    @Test func joiningAGroupPreservesExistingGains() {
        var channels = micChannels([15, 45, 0, 0, 0, 0, 0, 0])
        channels[0].group = 1
        channels[1].group = 1

        #expect(channels[0].gain == 15)
        #expect(channels[1].gain == 45)

        // ...and the first shared move keeps that 30 dB difference.
        InputChannelLogic.applyGainChange(&channels, channel: 0, to: 20)
        #expect(channels[1].gain - channels[0].gain == 30)
    }

    // MARK: Level change side effects

    /// Setting the analog level ALWAYS resets the channel's group to Off —
    /// unconditionally, Mic → Instrument included.
    /// Evidence: SymphonyIOBoard_MicPre8ch.cpp:513-526.
    @Test func levelChangeResetsGroupToOff() {
        for destination in AnalogInputLevel.allCases {
            var state = InputChannelState(inputType: AnalogInputLevel.mic.rawValue, group: 6)
            InputChannelLogic.applyLevelChange(&state, to: destination)
            #expect(state.group == InputChannelLogic.groupOff)
        }
    }

    /// Leaving Mic/Instrument frees the insert and disables its return; staying
    /// within the preamp levels keeps it.
    /// Evidence: SymphonyIOBoard_MicPre8ch.cpp:455-465.
    @Test func levelChangeClearsInsertOnlyWhenLeavingPreampLevels() {
        for destination: AnalogInputLevel in [.variable, .plus4dBu, .minus10dBV] {
            var state = InputChannelState(inputType: AnalogInputLevel.mic.rawValue,
                                          insert: 3, insertReturn: true)
            InputChannelLogic.applyLevelChange(&state, to: destination)
            #expect(state.insert == InputChannelLogic.insertNone)
            #expect(!state.insertReturn)
        }

        for destination: AnalogInputLevel in [.mic, .instrument] {
            var state = InputChannelState(inputType: AnalogInputLevel.mic.rawValue,
                                          insert: 3, insertReturn: true)
            InputChannelLogic.applyLevelChange(&state, to: destination)
            #expect(state.insert == 3)
            #expect(state.insertReturn)
        }
    }

    // MARK: Insert

    @Test func insertNamesMatchLegacy() {
        #expect(InputChannelLogic.insertName(0) == "None")
        #expect(InputChannelLogic.insertName(1) == "Insert 1")
        #expect(InputChannelLogic.insertName(8) == "Insert 8")
    }

    /// Insert IDs are exclusive: an ID held by another channel is offered but
    /// disabled. "None" is always selectable.
    /// Evidence: kmAEstroPropertyInsertEnableForID, SymphonyIOBoard_MicPre8ch.cpp:1216-1248.
    @Test func insertIDsAreExclusive() {
        var channels = micChannels([0, 0, 0, 0, 0, 0, 0, 0])
        channels[2].insert = 4

        #expect(!InputChannelLogic.insertAvailable(4, forChannel: 0, in: channels))
        // The owning channel still sees its own insert as available.
        #expect(InputChannelLogic.insertAvailable(4, forChannel: 2, in: channels))
        #expect(InputChannelLogic.insertAvailable(5, forChannel: 0, in: channels))
        #expect(InputChannelLogic.insertAvailable(0, forChannel: 0, in: channels))

        let options = InputChannelLogic.insertOptions(forChannel: 0, in: channels)
        #expect(options.count == 9)
        #expect(options[0].name == "None" && options[0].enabled)
        #expect(options[4].value == 4 && !options[4].enabled)
        #expect(options[5].enabled)
    }

    /// Assigning an insert enables the return; clearing it disables the return.
    /// Evidence: SymphonyIOBoard_MicPre8ch.cpp:608-617.
    @Test func insertReturnFollowsTheInsertAssignment() {
        var channels = micChannels([0, 0, 0, 0, 0, 0, 0, 0])

        #expect(InputChannelLogic.applyInsertChange(&channels, channel: 0, to: 2))
        #expect(channels[0].insert == 2)
        #expect(channels[0].insertReturn)

        #expect(InputChannelLogic.applyInsertChange(&channels, channel: 0, to: 0))
        #expect(channels[0].insert == 0)
        #expect(!channels[0].insertReturn)

        // Re-selecting the same insert changes nothing, so the return is not re-pushed.
        InputChannelLogic.applyInsertChange(&channels, channel: 0, to: 3)
        channels[0].insertReturn = false        // user turned "In" off by hand
        #expect(!InputChannelLogic.applyInsertChange(&channels, channel: 0, to: 3))
        #expect(!channels[0].insertReturn)      // left alone
    }

    /// A taken insert cannot be stolen — the request is refused outright.
    @Test func takenInsertCannotBeAssigned() {
        var channels = micChannels([0, 0, 0, 0, 0, 0, 0, 0])
        channels[1].insert = 7

        #expect(!InputChannelLogic.applyInsertChange(&channels, channel: 0, to: 7))
        #expect(channels[0].insert == InputChannelLogic.insertNone)
        #expect(channels[1].insert == 7)
    }

    // MARK: Reset Trims

    /// "Reset Trims" zeroes trim on every analog input and touches NOTHING else.
    /// Evidence: APInputTabRowViewController.m:247-255 → APAnalogInputController.m:545-548.
    @Test func resetTrimsOnlyZeroesTrims() {
        var channels = [
            InputChannelState(gain: 0, softLimit: 3, inputType: AnalogInputLevel.plus4dBu.rawValue,
                              trim: 1.7, digitalRefLevel: 4),
            InputChannelState(gain: 44, phantom: true, inputType: AnalogInputLevel.mic.rawValue,
                              trim: 0.5, group: 2, insert: 1, insertReturn: true),
            InputChannelState(inputType: AnalogInputLevel.variable.rawValue, trim: 18)
        ]

        let writes = InputChannelLogic.resetTrims(&channels)

        #expect(channels.allSatisfy { $0.trim == 0 })
        // Everything else survives.
        #expect(channels[0].softLimit == 3)
        #expect(channels[0].digitalRefLevel == 4)
        #expect(channels[1].gain == 44)
        #expect(channels[1].phantom)
        #expect(channels[1].group == 2)
        #expect(channels[1].insert == 1)
        #expect(channels[1].insertReturn)
        // Mic/Instrument carry no trim byte, so only the line levels are pushed.
        #expect(writes == [0, 2])
    }

    // MARK: Option-click — apply to all

    /// Option-clicking Analog Level applies it to every channel that OFFERS it,
    /// and skips the rest rather than coercing them.
    /// Evidence: APInputTabRowViewController.m:258-271 (`isThereAnalogReferenceLevel:`).
    @Test func optionClickLevelSkipsChannelsWithoutThatOption() {
        // 8 MicPre-backed channels + 16 plain analog ones.
        var channels = (0..<24).map { _ in InputChannelState() }

        let changed = InputChannelLogic.applyLevelToAll(
            &channels, to: .mic, micPreInstalled: true,
            hostAnalogInputChannels: 16, excluding: 0)

        #expect(changed == Array(1...7))
        #expect(channels[0].inputType == AnalogInputLevel.plus4dBu.rawValue)  // origin untouched
        #expect(channels[7].inputType == AnalogInputLevel.mic.rawValue)
        #expect(channels[8].inputType == AnalogInputLevel.plus4dBu.rawValue)  // no preamp there
    }

    /// Instrument exists on MicPre channels 1-4 only, so 5-8 are skipped too.
    @Test func optionClickInstrumentStopsAtChannelFour() {
        var channels = (0..<8).map { _ in InputChannelState() }

        let changed = InputChannelLogic.applyLevelToAll(
            &channels, to: .instrument, micPreInstalled: true,
            hostAnalogInputChannels: 16, excluding: 0)

        #expect(changed == [1, 2, 3])
        #expect(channels[4].inputType == AnalogInputLevel.plus4dBu.rawValue)
    }

    /// Every affected channel runs the full transition — phantom, group and
    /// insert are cleared exactly as a manual change would clear them.
    @Test func optionClickLevelRunsTheFullTransition() {
        var channels = (0..<8).map { _ in
            InputChannelState(phantom: true, inputType: AnalogInputLevel.mic.rawValue,
                              group: 1, insert: 0)
        }
        channels[1].insert = 5
        channels[1].insertReturn = true

        InputChannelLogic.applyLevelToAll(
            &channels, to: .plus4dBu, micPreInstalled: true,
            hostAnalogInputChannels: 16, excluding: 0)

        #expect(!channels[1].phantom)
        #expect(channels[1].group == InputChannelLogic.groupOff)
        #expect(channels[1].insert == InputChannelLogic.insertNone)
        #expect(!channels[1].insertReturn)
        // The origin is left for the caller's own (already applied) change.
        #expect(channels[0].phantom)
    }

    /// Digital Ref option-click applies unconditionally to every other channel.
    /// Evidence: APInputTabRowViewController.m:275-283.
    @Test func optionClickDigitalRefAppliesToAll() {
        var channels = (0..<6).map { _ in InputChannelState() }
        channels[3].digitalRefLevel = 5

        let changed = InputChannelLogic.applyDigitalRefToAll(&channels, to: 5, excluding: 3)

        #expect(changed == [0, 1, 2, 4, 5])
        #expect(channels.allSatisfy { $0.digitalRefLevel == 5 })
    }

    /// Soft Limit option-click falls back to OFF where the destination card does
    /// not offer the value — not to the nearest legal one.
    /// Evidence: APInputTabRowViewController.m:287-330 (bug 9466).
    @Test func optionClickSoftLimitFallsBackToOff() {
        var channels = (0..<4).map { _ in InputChannelState(softLimit: 0) }
        let cards: [IOCardType] = [.optical, .optical, .analogADDA16, .analogADDA16]

        // "Saturate" (3) exists on the Optical card only.
        let changed = InputChannelLogic.applySoftLimitToAll(
            &channels, to: 3, cards: cards, excluding: 0)

        #expect(changed == [1])
        #expect(channels[1].softLimit == 3)
        #expect(channels[2].softLimit == 0)
        #expect(channels[3].softLimit == 0)

        // A value both cards know propagates everywhere.
        let all = InputChannelLogic.applySoftLimitToAll(
            &channels, to: 2, cards: cards, excluding: 0)
        #expect(all == [1, 2, 3])
    }

    // MARK: Persistence

    /// Saved state written before Group/Insert existed must still decode, with
    /// the new fields taking their defaults. A hard failure here would wipe every
    /// channel setting, because the call site decodes with `try?`.
    @Test func olderSavedStateStillDecodes() throws {
        let legacy = """
        {"gain":42,"phantom":true,"phase":false,"hpf":false,"softLimit":2,
         "inputType":3,"trim":0,"digitalRefLevel":2}
        """.data(using: .utf8)!

        let state = try JSONDecoder().decode(InputChannelState.self, from: legacy)

        #expect(state.gain == 42)
        #expect(state.phantom)
        #expect(state.inputType == AnalogInputLevel.mic.rawValue)
        #expect(state.group == 0)
        #expect(state.insert == 0)
        #expect(!state.insertReturn)
    }

    @Test func roundTripKeepsGroupAndInsert() throws {
        let original = InputChannelState(gain: 30, inputType: AnalogInputLevel.mic.rawValue,
                                         group: 7, insert: 2, insertReturn: true)
        let decoded = try JSONDecoder().decode(
            InputChannelState.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }

    // MARK: The dev unit must be unaffected

    /// Optical (3) + AnalogAD16 (4), no MicPre: no group, no insert, no new
    /// hardware writes, and gain moves behave exactly as before.
    @Test func devUnitSeesNoMicPreStripAtAll() {
        for ch in 1...24 {
            let backed = InputChannelLogic.isMicPreBacked(number: ch, micPreInstalled: false)
            #expect(!backed)
            for level in AnalogInputLevel.allCases {
                #expect(!InputChannelLogic.showsGroupControl(micPreBacked: backed, level: level))
                #expect(!InputChannelLogic.showsInsertControls(micPreBacked: backed, level: level))
            }
        }

        // 24 line-level channels, all defaults: nothing to group, nothing to insert.
        var channels = (0..<24).map { _ in InputChannelState() }
        #expect(channels.allSatisfy { $0.group == 0 && $0.insert == 0 && !$0.insertReturn })

        // A gain move on a line-level channel stays a no-op (gain is 0 there).
        let result = InputChannelLogic.applyGainChange(&channels, channel: 0, to: 40)
        #expect(channels[0].gain == 0)
        #expect(result.changed.isEmpty)

        // Reset Trims pushes every one of the 24 line channels and nothing else.
        #expect(InputChannelLogic.resetTrims(&channels) == Array(0..<24))
    }

    /// With card detection reporting `.none` the strip degrades to plain line
    /// level: no group, no insert, three options, "Line N".
    @Test func undetectedCardHasNoMicPreStrip() {
        let backed = InputChannelLogic.isMicPreBacked(number: 1, micPreInstalled: false)
        #expect(!InputChannelLogic.showsGroupControl(micPreBacked: backed, level: .mic))
        #expect(!InputChannelLogic.showsInsertControls(micPreBacked: backed, level: .mic))
        #expect(InputChannelLogic.analogLevelOptions(number: 1, micPreBacked: backed).count == 3)
        #expect(InputChannelLogic.channelLabel(number: 1, level: .plus4dBu) == "Line 1")
    }
}

// MARK: - MicPre group / insert, now wired to hardware

/// Group (`0xC7`), Insert (`0xC8`) and Insert Return (`0xC9`) used to be hidden
/// behind `MaestroFeatureFlags.micPreGroupAndInsert`, because the property mapper
/// had no case for them and every write was thrown away. The mapper cases now
/// exist (see `MicPreGroupInsertWireTests` in MaestroDeviceTests), the flag is
/// gone, and these pin the model-side consequences of that.
@Suite("MicPre group/insert wiring")
struct MicPreGroupInsertWiringTests {

    /// The controls are visible whenever the channel is eligible — no flag left.
    @Test("Eligibility alone decides whether Group/Insert are shown")
    func eligibilityIsTheOnlyGate() {
        #expect(InputChannelLogic.showsGroupControl(micPreBacked: true, level: .mic))
        #expect(InputChannelLogic.showsInsertControls(micPreBacked: true, level: .instrument))
        #expect(!InputChannelLogic.showsGroupControl(micPreBacked: true, level: .plus4dBu))
        #expect(!InputChannelLogic.showsInsertControls(micPreBacked: false, level: .mic))
    }

    /// The firmware now KNOWS the grouping, so it derives every other member's
    /// gain itself. Re-sending the derived values would apply the offset twice.
    /// Evidence: `SymphonyIOBoard_MicPre8ch.cpp:293-299`.
    @Test("A grouped gain move writes ONLY the touched channel")
    func groupedGainWritesOneChannel() {
        var channels = [InputChannelState](repeating: InputChannelState(), count: 8)
        for i in 0..<8 {
            channels[i].inputType = AnalogInputLevel.mic.rawValue
            channels[i].gain = 20
        }
        for i in 0..<3 { channels[i].group = 4 }

        let result = InputChannelLogic.applyGainChange(&channels, channel: 2, to: 30)

        #expect(result.changed == [0, 1, 2], "the UI still moves every member")
        #expect(result.hardwareWrites == [2], "but only the touched channel is sent")
        #expect(channels.prefix(3).allSatisfy { $0.gain == 30 })
    }

    @Test("Pre-existing offsets survive a grouped move")
    func offsetsArePreserved() {
        var channels = [InputChannelState](repeating: InputChannelState(), count: 8)
        for i in 0..<8 { channels[i].inputType = AnalogInputLevel.mic.rawValue }
        channels[0].gain = 10; channels[1].gain = 20; channels[2].gain = 30
        for i in 0..<3 { channels[i].group = 1 }

        InputChannelLogic.applyGainChange(&channels, channel: 0, to: 15)

        #expect(channels[0].gain == 15)
        #expect(channels[1].gain == 25)
        #expect(channels[2].gain == 35)
    }

    @Test("An ungrouped move writes exactly one channel")
    func ungroupedWritesOneChannel() {
        var channels = [InputChannelState](repeating: InputChannelState(), count: 8)
        for i in 0..<8 { channels[i].inputType = AnalogInputLevel.mic.rawValue }

        let result = InputChannelLogic.applyGainChange(&channels, channel: 3, to: 40)
        #expect(result.hardwareWrites == [3])
    }

    /// Restoring coverage lost when the feature-flag tests were removed.
    ///
    /// Every member of the group is already pinned at the 85 dB mic ceiling, so
    /// pass 1 shrinks the offset to zero and pass 2 moves nobody. The touched
    /// channel must STILL be written. The knob has already moved under the
    /// user's finger, and if the host sends nothing the hardware keeps the old
    /// value while the UI shows the new one -- the two disagree until something
    /// else happens to resync them. `applyGainChange` returns `hardwareWrites:
    /// [index]` unconditionally on the grouped path for exactly this reason.
    @Test("The touched channel is written even when the group cannot move")
    func touchedChannelWrittenAtCeiling() {
        var channels = [InputChannelState](repeating: InputChannelState(), count: 8)
        for i in 0..<8 {
            channels[i].inputType = AnalogInputLevel.mic.rawValue
            channels[i].gain = 85           // already at the ceiling
        }
        for i in 0..<3 { channels[i].group = 4 }

        let result = InputChannelLogic.applyGainChange(&channels, channel: 0, to: 85)

        #expect(result.appliedOffset == 0)
        #expect(result.changed.isEmpty)      // nobody moved
        #expect(result.hardwareWrites == [0])  // but the touched channel is sent
        #expect(channels.allSatisfy { $0.gain == 85 })
    }
}

// MARK: - Insert channel bitmask (0xC8 payload)

/// `SetInsertAssignmentInHardware` (`SymphonyIOBoard_MicPre8ch.cpp:1790-1810`)
/// derives one CHANNEL BITMASK per INSERT and writes all eight every time.
@Suite("MicPre insert bitmask")
struct MicPreInsertBitmaskTests {

    private func micPreChannels(_ inserts: [UInt32]) -> [InputChannelState] {
        inserts.map { InputChannelState(inputType: AnalogInputLevel.mic.rawValue, insert: $0) }
    }

    @Test("Insert N on channel C yields mask 0x01 << C at wire index N-1")
    func maskIsOneShiftedByChannel() {
        // Channel 0 → Insert 1, channel 5 → Insert 3.
        let channels = micPreChannels([1, 0, 0, 0, 0, 3, 0, 0])
        let masks = InputChannelLogic.insertAssignmentMasks(in: channels)

        #expect(masks.count == 8)
        #expect(masks[0] == (insert: 0, mask: UInt8(0x01)), "Insert 1 is wire index 0, channel 0 → bit 0")
        #expect(masks[2] == (insert: 2, mask: UInt8(0x20)), "Insert 3 is wire index 2, channel 5 → bit 5")
    }

    @Test("Every unclaimed insert is written as mask 0 — that is what releases it")
    func unclaimedInsertsAreZeroed() {
        let channels = micPreChannels([4, 0, 0, 0, 0, 0, 0, 0])
        let masks = InputChannelLogic.insertAssignmentMasks(in: channels)

        #expect(masks[3].mask == 0x01, "Insert 4 → channel 0")
        for i in [0, 1, 2, 4, 5, 6, 7] {
            #expect(masks[i].mask == 0, "insert \(i + 1) is unclaimed and must be zeroed")
        }
    }

    @Test("The table always covers all eight inserts, in order")
    func tableIsAlwaysEightInOrder() {
        let masks = InputChannelLogic.insertAssignmentMasks(in: micPreChannels(Array(repeating: 0, count: 8)))
        #expect(masks.map(\.insert) == [0, 1, 2, 3, 4, 5, 6, 7])
        #expect(masks.allSatisfy { $0.mask == 0 })
    }

    @Test("Channel 7 (the top bit) is not truncated")
    func topChannelBit() {
        let channels = micPreChannels([0, 0, 0, 0, 0, 0, 0, 8])
        #expect(InputChannelLogic.insertAssignmentMasks(in: channels)[7].mask == 0x80)
    }

    /// Only the first eight channels feed inserts — a 16-channel device must not
    /// let channel 8+ shift a bit out of the byte.
    @Test("Channels past the MicPre's eight are ignored")
    func channelsPastEightIgnored() {
        var inserts = [UInt32](repeating: 0, count: 16)
        inserts[9] = 1          // not a MicPre channel
        let masks = InputChannelLogic.insertAssignmentMasks(insertPerChannel: inserts)
        #expect(masks.allSatisfy { $0.mask == 0 })
    }

    @Test("A short array is treated as all-None rather than crashing")
    func shortArrayIsSafe() {
        let masks = InputChannelLogic.insertAssignmentMasks(insertPerChannel: [2, 0])
        #expect(masks[1].mask == 0x01, "Insert 2 → channel 0")
        #expect(masks.filter { $0.mask != 0 }.count == 1)
    }

    /// The daemon uses `cNewMask = 0x01 << nCh` (assignment, NOT `|=`). Exclusivity
    /// is what makes that correct; reproduce the daemon rather than "fixing" it.
    @Test("Exclusivity keeps one bit per insert")
    func exclusivityKeepsOneBit() {
        var channels = micPreChannels(Array(repeating: 0, count: 8))
        InputChannelLogic.applyInsertChange(&channels, channel: 0, to: 5)
        // Channel 3 cannot take Insert 5 — it is already claimed.
        #expect(!InputChannelLogic.insertAvailable(5, forChannel: 3, in: channels))
        InputChannelLogic.applyInsertChange(&channels, channel: 3, to: 5)
        #expect(channels[3].insert == 0, "the request is refused, not honoured")

        let masks = InputChannelLogic.insertAssignmentMasks(in: channels)
        #expect(masks[4].mask == 0x01, "Insert 5 still belongs to channel 0 alone")
    }

    /// Leaving Mic/Instrument frees the insert; the rebuilt table must show it.
    @Test("A level change releases the insert in the rebuilt table")
    func levelChangeReleasesInsert() {
        var channels = micPreChannels([0, 6, 0, 0, 0, 0, 0, 0])
        channels[1].insertReturn = true
        #expect(InputChannelLogic.insertAssignmentMasks(in: channels)[5].mask == 0x02)

        InputChannelLogic.applyLevelChange(&channels[1], to: .plus4dBu)

        #expect(channels[1].insert == InputChannelLogic.insertNone)
        #expect(channels[1].insertReturn == false)
        #expect(InputChannelLogic.insertAssignmentMasks(in: channels)[5].mask == 0,
                "the freed insert must be written as 0, not simply left alone")
    }
}

// MARK: - Input reset to defaults

/// The reporter's question — "Is there a simple way to reset? I couldn't work out
/// how to get back to defaults once toying with it" — had no answer on the Input
/// page: "Reset Trims" sets trim to 0.0 and nothing else, and is a hardware no-op
/// on Mic/Instrument channels, which carry no trim byte at all.
///
/// The values here are legacy's, not invented:
/// `AnalogIn_SymphonyIO_Stream.cpp:26-48` and
/// `SymphonyIOBoard_MicPre8ch.cpp:2301-2325`.
@Suite("Input reset to defaults")
struct InputResetTests {

    /// Sixteen channels of a 16x16 + 8MicPre, all thoroughly meddled with.
    private func meddled() -> [InputChannelState] {
        var channels = [InputChannelState](repeating: InputChannelState(), count: 16)
        for i in 0..<8 {
            channels[i].inputType = AnalogInputLevel.mic.rawValue
            channels[i].gain = Double(20 + i)
            channels[i].phantom = true
            channels[i].phase = true
            channels[i].hpf = true
            channels[i].softLimit = 2
            channels[i].group = 1
            channels[i].insert = UInt32(i + 1)
            channels[i].insertReturn = true
            channels[i].digitalRefLevel = 5
            channels[i].trim = 1.5
        }
        for i in 8..<16 {
            channels[i].inputType = AnalogInputLevel.minus10dBV.rawValue
            channels[i].softLimit = 3
            channels[i].digitalRefLevel = 0
            channels[i].trim = -1.7
        }
        return channels
    }

    @Test("The default values are the daemon's, not invented ones")
    func defaultsMatchLegacy() {
        #expect(InputResetDefaults.softLimit == 0)
        #expect(InputResetDefaults.analogLevel == .plus4dBu)
        #expect(InputResetDefaults.analogLevel.rawValue == 1, "WIRE value for +4 dBu")
        #expect(InputResetDefaults.digitalRefLevel == 2, "index 2 == -16 dBfs")
        #expect(InputResetDefaults.trim == 0)
        #expect(InputResetDefaults.gain == 0)
        #expect(InputResetDefaults.group == InputChannelLogic.groupOff)
        #expect(InputResetDefaults.insert == InputChannelLogic.insertNone)
        #expect(InputResetDefaults.insertReturn == false)
        #expect(InputResetDefaults.highPassFilter == false)
        #expect(InputResetDefaults.phantom == false)
        #expect(InputResetDefaults.polarity == false)
    }

    // MARK: Full reset (ResetAll)

    @Test("Reset All restores every input value on both card types")
    func resetAll() {
        var channels = meddled()
        let result = InputChannelLogic.resetToDefaults(
            &channels, includingCalibration: true, micPreInstalled: true,
            hostAnalogInputChannels: 16)

        #expect(result.changed == Array(0..<16))
        #expect(result.micPreChannels == Array(0..<8))
        #expect(result.releasedAnInsert == true)

        for (i, c) in channels.enumerated() {
            #expect(c.softLimit == 0, "ch\(i + 1) soft limit")
            #expect(c.inputType == AnalogInputLevel.plus4dBu.rawValue, "ch\(i + 1) analog ref")
            #expect(c.digitalRefLevel == 2, "ch\(i + 1) digital ref")
            #expect(c.trim == 0, "ch\(i + 1) trim")
            #expect(c.gain == 0, "ch\(i + 1) gain")
            #expect(c.group == 0 && c.insert == 0 && !c.insertReturn, "ch\(i + 1) group/insert")
            #expect(!c.phantom && !c.phase && !c.hpf, "ch\(i + 1) preamp buttons")
        }
    }

    // MARK: Keep-trims reset (ResetAllButCalibration)

    /// The asymmetry is legacy's, and it is easy to mistake for a bug: the MicPre
    /// delegate's `ResetToDefaults` takes the cookie and ignores it, so a MicPre
    /// channel drops to +4 dBu either way, while a plain line channel keeps its
    /// reference level under "keep trims".
    @Test("Keep-trims spares line calibration but still resets MicPre channels in full")
    func resetAllButCalibration() {
        var channels = meddled()
        let before = channels
        let result = InputChannelLogic.resetToDefaults(
            &channels, includingCalibration: false, micPreInstalled: true,
            hostAnalogInputChannels: 16)

        #expect(result.changed == Array(0..<16))

        // MicPre channels 1-8: full preamp reset, but trim / digital ref survive.
        for i in 0..<8 {
            #expect(channels[i].inputType == AnalogInputLevel.plus4dBu.rawValue)
            #expect(channels[i].gain == 0)
            #expect(channels[i].group == 0 && channels[i].insert == 0)
            #expect(!channels[i].phantom && !channels[i].phase && !channels[i].hpf)
            #expect(channels[i].softLimit == 0)
            #expect(channels[i].trim == before[i].trim, "trim is calibration data")
            #expect(channels[i].digitalRefLevel == before[i].digitalRefLevel)
        }
        // Line channels 9-16: ONLY soft limit moves.
        for i in 8..<16 {
            #expect(channels[i].softLimit == 0)
            #expect(channels[i].inputType == before[i].inputType, "analog ref is calibration data")
            #expect(channels[i].digitalRefLevel == before[i].digitalRefLevel)
            #expect(channels[i].trim == before[i].trim)
        }
    }

    @Test("Soft limit is reset in BOTH scopes — it sits outside the calibration block")
    func softLimitAlwaysResets() {
        for includingCalibration in [true, false] {
            var channels = meddled()
            InputChannelLogic.resetToDefaults(
                &channels, includingCalibration: includingCalibration, micPreInstalled: false,
                hostAnalogInputChannels: 16)
            #expect(channels.allSatisfy { $0.softLimit == 0 },
                    "soft limit must reset with includingCalibration=\(includingCalibration)")
        }
    }

    // MARK: The dev unit — Optical + AnalogAD16, no MicPre

    /// The development unit has no 8MicPre. Reset must touch line-channel settings
    /// only: no gain, group, insert, phantom, polarity or high-pass state may move,
    /// so no preamp opcode is ever a candidate for a write.
    @Test("With no MicPre, only line-channel settings change")
    func devUnitTouchesOnlyLineSettings() {
        var channels = [InputChannelState](repeating: InputChannelState(), count: 24)
        for i in channels.indices {
            channels[i].softLimit = 1
            channels[i].trim = 0.9
            channels[i].digitalRefLevel = 4
            channels[i].inputType = AnalogInputLevel.minus10dBV.rawValue
            // Values a MicPre would own. Nothing may write these on this unit,
            // and nothing here should change them either.
            channels[i].gain = 33
            channels[i].phantom = true
            channels[i].phase = true
            channels[i].hpf = true
            channels[i].group = 4
            channels[i].insert = 2
            channels[i].insertReturn = true
        }
        let result = InputChannelLogic.resetToDefaults(
            &channels, includingCalibration: true, micPreInstalled: false,
            hostAnalogInputChannels: 16)

        #expect(result.micPreChannels.isEmpty, "no channel may be treated as MicPre-backed")
        #expect(result.releasedAnInsert == false,
                "no insert table rebuild on a unit with no MicPre")
        for c in channels {
            #expect(c.softLimit == 0)
            #expect(c.inputType == AnalogInputLevel.plus4dBu.rawValue)
            #expect(c.digitalRefLevel == 2)
            #expect(c.trim == 0)
            // Untouched — these belong to a module this unit does not have.
            #expect(c.gain == 33)
            #expect(c.phantom == true)
            #expect(c.phase == true)
            #expect(c.hpf == true)
            #expect(c.group == 4)
            #expect(c.insert == 2)
            #expect(c.insertReturn == true)
        }
    }

    // MARK: Idempotence / no-op

    @Test("A second reset changes nothing and asks for no writes")
    func resetIsIdempotent() {
        var channels = meddled()
        InputChannelLogic.resetToDefaults(&channels, includingCalibration: true, micPreInstalled: true,
            hostAnalogInputChannels: 16)
        let second = InputChannelLogic.resetToDefaults(
            &channels, includingCalibration: true, micPreInstalled: true,
            hostAnalogInputChannels: 16)
        #expect(second.changed.isEmpty)
        #expect(second.releasedAnInsert == false)
    }

    @Test("releasedAnInsert is false when nothing held an insert")
    func noInsertRebuildWhenNoneHeld() {
        var channels = [InputChannelState](repeating: InputChannelState(), count: 8)
        for i in channels.indices {
            channels[i].inputType = AnalogInputLevel.mic.rawValue
            channels[i].gain = 12
        }
        let result = InputChannelLogic.resetToDefaults(
            &channels, includingCalibration: true, micPreInstalled: true,
            hostAnalogInputChannels: 16)
        #expect(!result.changed.isEmpty)
        #expect(result.releasedAnInsert == false)
    }

    /// Reset Trims stays a separate, narrower control — it is a real legacy button
    /// with well-defined behaviour and the new reset does not replace it.
    @Test("Reset Trims still changes trim and nothing else")
    func resetTrimsIsUnchanged() {
        var channels = meddled()
        let before = channels
        InputChannelLogic.resetTrims(&channels)
        for (i, c) in channels.enumerated() {
            #expect(c.trim == 0, "ch\(i + 1) trim")
            #expect(c.softLimit == before[i].softLimit, "ch\(i + 1) soft limit untouched")
            #expect(c.inputType == before[i].inputType)
            #expect(c.gain == before[i].gain)
            #expect(c.phantom == before[i].phantom)
        }
    }
}

// MARK: - MicPre host-card gating

/// A MicPre8 is a delegate, not a card. It has no converters of its own and
/// installs onto the HOST board's analog input stream
/// (`SymphonyIO_IOBoard.cpp:606-625`). If the host has no analog input stream,
/// `installMicPre` returns false and no delegation happens -- and the caller
/// (`SymphonyIO.cpp:960`) ignores the return value, so the failure is silent.
@Suite("MicPre host-card gating")
struct MicPreHostGatingTests {

    /// The case that actually breaks: a 16 Digital In + 16 Analog Out card has
    /// zero analog inputs, so a MicPre8 beside it delegates onto nothing. Eight
    /// preamp strips in front of zero analog inputs is the same class of bug as
    /// the 32 output strips a MicPre8 used to draw via the bus slice.
    @Test("A card with no analog inputs backs no preamps")
    func da16HostBacksNothing() {
        #expect(IOCardType.analogDA16.analogInputChannels == 0)
        #expect(InputChannelLogic.micPreBackedChannelCount(
            hostAnalogInputChannels: IOCardType.analogDA16.analogInputChannels) == 0)
        for ch in 1...16 {
            #expect(!InputChannelLogic.isMicPreBacked(
                number: ch, micPreInstalled: true,
                hostAnalogInputChannels: IOCardType.analogDA16.analogInputChannels))
        }
    }

    /// The normal pairings: 8 or more analog inputs give all eight preamps.
    @Test("A host with 8+ analog inputs backs all eight preamps")
    func fullHostsBackEight() {
        for card in [IOCardType.analogAES, .optical, .analogAD16, .analogADDA16] {
            let n = card.analogInputChannels
            #expect(n >= 8)
            #expect(InputChannelLogic.micPreBackedChannelCount(hostAnalogInputChannels: n) == 8)
            #expect(InputChannelLogic.isMicPreBacked(
                number: 8, micPreInstalled: true, hostAnalogInputChannels: n))
            #expect(!InputChannelLogic.isMicPreBacked(
                number: 9, micPreInstalled: true, hostAnalogInputChannels: n))
        }
    }

    /// A 2x6 has two analog inputs, so it cannot host the module AT ALL.
    ///
    /// The User's Guide p.91 answers this directly -- "No. The Mic Pre module
    /// cannot be used with the 2x6 analog card or the 16 digital in + 16 analog
    /// out card because they do not have at least 8 channels of analog input
    /// available." An earlier version of this rule clamped to min(8, host) and
    /// offered TWO preamps on a 2x6, which is a state no real unit is ever in.
    @Test("A 2x6 host cannot carry the module at all")
    func twoBySixHostsNothing() {
        let n = IOCardType.twoBySix.analogInputChannels
        #expect(n == 2)
        #expect(n < InputChannelLogic.micPreMinimumHostAnalogInputs)
        #expect(InputChannelLogic.micPreBackedChannelCount(hostAnalogInputChannels: n) == 0)
        for ch in 1...16 {
            #expect(!InputChannelLogic.isMicPreBacked(
                number: ch, micPreInstalled: true, hostAnalogInputChannels: n))
        }
    }

    /// The rule is all-or-nothing, never a partial count: a host either clears
    /// the eight-channel bar and gets all eight preamps, or gets none.
    @Test("Backed count is only ever 0 or 8")
    func backedCountIsAllOrNothing() {
        for host in 0...32 {
            let n = InputChannelLogic.micPreBackedChannelCount(hostAnalogInputChannels: host)
            #expect(n == 0 || n == InputChannelLogic.micPreChannelCount)
            #expect((n == 8) == (host >= 8))
        }
    }

    /// Every card in our table, checked against the Guide's two p.91 answers:
    /// No for the 2x6 and the 16 Digital In + 16 Analog Out; Yes for the 16x16
    /// and the 16 Analog In + 16 Digital Out, with channels 9-16 line-level.
    @Test("Every card type lands on the side the Guide puts it")
    func everyCardMatchesTheGuide() {
        let canHost: [IOCardType] = [.analogAES, .optical, .analogAD16, .analogADDA16]
        let cannotHost: [IOCardType] = [.twoBySix, .analogDA16, .micPre8, .none]
        for card in canHost {
            #expect(InputChannelLogic.micPreBackedChannelCount(
                hostAnalogInputChannels: card.analogInputChannels) == 8)
        }
        for card in cannotHost {
            #expect(InputChannelLogic.micPreBackedChannelCount(
                hostAnalogInputChannels: card.analogInputChannels) == 0)
        }
    }

    /// No MicPre installed means no preamps regardless of the host card.
    @Test("No MicPre means no preamps on any host")
    func noMicPreNoPreamps() {
        for ch in 1...16 {
            #expect(!InputChannelLogic.isMicPreBacked(
                number: ch, micPreInstalled: false, hostAnalogInputChannels: 16))
        }
    }

    /// Negative or nonsense host counts clamp to zero rather than trapping.
    @Test("A nonsense host count clamps to zero")
    func negativeClampsToZero() {
        #expect(InputChannelLogic.micPreBackedChannelCount(hostAnalogInputChannels: -4) == 0)
    }
}

// MARK: - The single MicPre predicate

/// `micPreIsUsable` is what both the Input tab and the Help sheet key off. They
/// drifted apart once -- Input gained the host-card requirement while Help still
/// keyed on board type alone, so a pairing that drew no preamp controls still
/// offered a Mic Pre help section explaining them.
@Suite("MicPre usability predicate")
struct MicPreUsableTests {

    /// The Guide's p.91 "Yes" list, in both slot orders.
    @Test("Hosts the Guide says yes to are usable in either slot order")
    func supportedPairings() {
        for host in [IOCardType.analogAES, .optical, .analogAD16, .analogADDA16] {
            #expect(InputChannelLogic.micPreIsUsable(primary: host, secondary: .micPre8))
            #expect(InputChannelLogic.micPreIsUsable(primary: .micPre8, secondary: host))
        }
    }

    /// The Guide's p.91 "No" list.
    @Test("Hosts the Guide says no to are not usable")
    func unsupportedPairings() {
        for host in [IOCardType.twoBySix, .analogDA16, .none] {
            #expect(!InputChannelLogic.micPreIsUsable(primary: host, secondary: .micPre8))
            #expect(!InputChannelLogic.micPreIsUsable(primary: .micPre8, secondary: host))
        }
    }

    /// No module, no preamps -- including the dev unit's own pairing.
    @Test("No MicPre module means not usable")
    func noModule() {
        #expect(!InputChannelLogic.micPreIsUsable(primary: .optical, secondary: .analogAD16))
        #expect(!InputChannelLogic.micPreIsUsable(primary: .analogADDA16, secondary: .none))
    }

    /// Two MicPre8s cannot host each other -- neither contributes analog inputs.
    @Test("Two MicPre modules cannot host each other")
    func twoModules() {
        #expect(!InputChannelLogic.micPreIsUsable(primary: .micPre8, secondary: .micPre8))
    }
}

// MARK: - Insert labels

/// User-editable insert names, per the User's Guide p.65 item 4. Semantics follow
/// `kmAEstroPropertyInsertNameForID` in `SymphonyIOBoard_MicPre8ch.cpp:567-597`.
@Suite("Insert labels")
struct InsertLabelTests {

    @Test("Defaults are Insert 1...8, and 0 is None")
    func defaults() {
        let labels = InsertLabels()
        #expect(InsertLabels.defaultName(0) == "None")
        for id in UInt32(1)...8 { #expect(labels[id] == "Insert \(id)") }
        #expect(!labels.hasAnyCustom)
    }

    /// The daemon frees its stored string and only re-allocates for a non-empty
    /// value, after which the getter falls back to the built-in name. Clearing a
    /// field must restore the default, not store a blank that renders as an empty
    /// menu row.
    @Test("Clearing a name restores the default")
    func clearingRestoresDefault() {
        var labels = InsertLabels()
        labels[3] = "LA-2A"
        #expect(labels[3] == "LA-2A")
        #expect(labels.isCustom(3))
        labels[3] = ""
        #expect(labels[3] == "Insert 3")
        #expect(!labels.isCustom(3))
        labels[3] = "   "
        #expect(labels[3] == "Insert 3")
    }

    /// Typing the default back in is not an override -- it would otherwise
    /// persist a redundant entry and light up "Reset Insert Labels" for nothing.
    @Test("Typing the default name back in clears the override")
    func defaultNameIsNotAnOverride() {
        var labels = InsertLabels()
        labels[5] = "Insert 5"
        #expect(!labels.isCustom(5))
        #expect(!labels.hasAnyCustom)
    }

    @Test("Names are trimmed and length-capped")
    func trimmedAndCapped() {
        var labels = InsertLabels()
        labels[1] = "  Pultec  "
        #expect(labels[1] == "Pultec")
        labels[2] = String(repeating: "x", count: 100)
        #expect(labels[2].count == InsertLabels.maxLength)
    }

    /// ID 0 is "None" and is not renameable; out-of-range IDs are ignored rather
    /// than stored, so a stale preference cannot introduce a ninth insert.
    @Test("None and out-of-range IDs are not renameable")
    func rangeGuards() {
        var labels = InsertLabels()
        labels[0] = "Nope"
        labels[9] = "Nope"
        labels[99] = "Nope"
        #expect(labels[0] == "None")
        #expect(!labels.hasAnyCustom)
    }

    @Test("Round-trips through UserDefaults storage")
    func persistence() {
        var labels = InsertLabels()
        labels[2] = "1176"
        labels[7] = "Distressor"
        let restored = InsertLabels(storage: labels.storage)
        #expect(restored[2] == "1176")
        #expect(restored[7] == "Distressor")
        #expect(restored[1] == "Insert 1")
        #expect(restored == labels)
    }

    /// A stored value that is no longer valid must not resurrect as a label.
    @Test("Junk in storage is discarded on load")
    func junkStorageIgnored() {
        let restored = InsertLabels(storage: ["not-a-number": "x", "0": "y", "9": "z"])
        #expect(!restored.hasAnyCustom)
    }

    /// Renaming is keyed by insert, not channel: the daemon re-notifies all eight
    /// channels after one rename, so the popup shows the same name everywhere.
    @Test("A renamed insert shows its name in every channel's popup")
    func namesAreSharedAcrossChannels() {
        var labels = InsertLabels()
        labels[4] = "Fairchild"
        var channels = [InputChannelState](repeating: InputChannelState(), count: 8)
        for i in channels.indices { channels[i].inputType = AnalogInputLevel.mic.rawValue }
        for ch in 0..<8 {
            let options = InputChannelLogic.insertOptions(
                forChannel: ch, in: channels, labels: labels)
            #expect(options.first { $0.value == 4 }?.name == "Fairchild")
            #expect(options.first { $0.value == 0 }?.name == "None")
            #expect(options.first { $0.value == 5 }?.name == "Insert 5")
        }
    }
}
