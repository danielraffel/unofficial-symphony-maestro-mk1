import Testing
@testable import MaestroCore

/// The typed value fields under the faders: the Mixer's fader level and the
/// Input/Output trim readouts (Symphony I/O User's Guide p. 55 item 6 — type a
/// value, Tab moves to the next channel).
@Suite("LevelEntry")
struct LevelEntryTests {

    private let lineTrim = InputChannelLogic.trimRange(for: .plus4dBu)!
    private let variableTrim = InputChannelLogic.trimRange(for: .variable)!

    private func near(_ a: Double?, _ b: Double) -> Bool {
        guard let a else { return false }
        return abs(a - b) < 1e-9
    }

    // MARK: Typed values

    @Test func inRangeValueIsKept() {
        #expect(near(LevelEntry.value(typed: "1.3", range: lineTrim.range, step: lineTrim.step), 1.3))
        #expect(near(LevelEntry.value(typed: "-0.7", range: lineTrim.range, step: lineTrim.step), -0.7))
        #expect(near(LevelEntry.value(typed: "0", range: lineTrim.range, step: lineTrim.step), 0))
        #expect(near(LevelEntry.value(typed: "+2", range: lineTrim.range, step: lineTrim.step), 2))
        #expect(near(LevelEntry.value(typed: "12.5", range: variableTrim.range, step: variableTrim.step), 12.5))
    }

    @Test func outOfRangeValueClampsToTheFaderLimits() {
        #expect(LevelEntry.value(typed: "9", range: lineTrim.range, step: lineTrim.step) == 2.0)
        #expect(LevelEntry.value(typed: "-9", range: lineTrim.range, step: lineTrim.step) == -2.0)
        #expect(LevelEntry.value(typed: "-3", range: variableTrim.range, step: variableTrim.step) == 0.0)
        #expect(LevelEntry.value(typed: "40", range: variableTrim.range, step: variableTrim.step) == 25.0)
        // Mixer fader: -48 … +6 dB.
        #expect(LevelEntry.value(typed: "100", range: -48...6, step: 0.5) == 6.0)
        #expect(LevelEntry.value(typed: "-100", range: -48...6, step: 0.5) == -48.0)
    }

    /// An output at -20 dBFS digital reference only trims downwards (User's
    /// Guide p. 74 step 6); typing a positive value there lands on 0.0.
    @Test func outputTrimAtMinus20AcceptsNoPositiveValue() {
        let spec = OutputChannelLogic.trimRange(digitalRefLevel: OutputChannelLogic.digitalRefMinus20dBfs)
        #expect(LevelEntry.value(typed: "1.5", range: spec.range, step: spec.step) == 0.0)
        #expect(near(LevelEntry.value(typed: "-1.5", range: spec.range, step: spec.step), -1.5))
        let other = OutputChannelLogic.trimRange(digitalRefLevel: 2)
        #expect(near(LevelEntry.value(typed: "1.5", range: other.range, step: other.step), 1.5))
    }

    @Test func valueIsRoundedToTheFaderStep() {
        #expect(near(LevelEntry.value(typed: "1.26", range: lineTrim.range, step: lineTrim.step), 1.3))
        #expect(near(LevelEntry.value(typed: "-0.44", range: lineTrim.range, step: lineTrim.step), -0.4))
        // Variable trims in half dB steps, the Mixer fader too.
        #expect(near(LevelEntry.value(typed: "12.3", range: variableTrim.range, step: variableTrim.step), 12.5))
        #expect(near(LevelEntry.value(typed: "12.2", range: variableTrim.range, step: variableTrim.step), 12.0))
        #expect(near(LevelEntry.value(typed: "-3.3", range: -48...6, step: 0.5), -3.5))
    }

    /// Whatever is typed, the trim byte sent to the unit is one the fader
    /// could also have produced.
    @Test func typedTrimEncodesLikeADraggedTrim() {
        let typed = LevelEntry.value(typed: "0.34", range: lineTrim.range, step: lineTrim.step)!
        #expect(InputChannelLogic.trimByte(trim: typed, level: .plus4dBu) == 3)
        let variable = LevelEntry.value(typed: "7.8", range: variableTrim.range, step: variableTrim.step)!
        #expect(InputChannelLogic.trimByte(trim: variable, level: .variable) == 16)   // 8.0 dB in half-dB units
    }

    @Test func textThatIsNotANumberIsRejected() {
        for text in ["", "abc", "1.2dB", "--1", "1.2.3", " ", "nan", "inf", "-infinity"] {
            #expect(LevelEntry.value(typed: text, range: lineTrim.range, step: lineTrim.step) == nil,
                    "\(text.debugDescription) must leave the value alone")
        }
    }

    /// The Mixer field has only ever taken a decimal point; a comma is not a
    /// number here and leaves the value alone, rather than being read as "1".
    @Test func commaDecimalSeparatorIsRejected() {
        #expect(LevelEntry.value(typed: "1,5", range: lineTrim.range, step: lineTrim.step) == nil)
    }

    @Test func displayTextMatchesTheStep() {
        #expect(LevelEntry.text(for: 1.3, step: 0.1) == "1.3")
        #expect(LevelEntry.text(for: 12.5, step: 0.5) == "12.5")
        #expect(LevelEntry.text(for: 0, step: 0.1) == "0.0")
        #expect(LevelEntry.text(for: -20, step: 1) == "-20")
    }

    // MARK: Tab order

    @Test func tabMovesToTheNextAndShiftTabToThePrevious() {
        let order = [0, 1, 2, 3]
        #expect(LevelEntry.neighbour(of: 1, in: order, forward: true) { _ in true } == 2)
        #expect(LevelEntry.neighbour(of: 1, in: order, forward: false) { _ in true } == 0)
    }

    @Test func tabStopsAtEitherEndWithoutWrapping() {
        let order = [0, 1, 2, 3]
        #expect(LevelEntry.neighbour(of: 3, in: order, forward: true) { _ in true } == nil)
        #expect(LevelEntry.neighbour(of: 0, in: order, forward: false) { _ in true } == nil)
        #expect(LevelEntry.neighbour(of: 0, in: [0], forward: true) { _ in true } == nil)
    }

    @Test func tabSkipsDisabledChannels() {
        let order = [0, 1, 2, 3, 4]
        let enabled: Set<Int> = [0, 3]
        #expect(LevelEntry.neighbour(of: 0, in: order, forward: true) { enabled.contains($0) } == 3)
        #expect(LevelEntry.neighbour(of: 3, in: order, forward: false) { enabled.contains($0) } == 0)
        // Nothing enabled beyond: Tab just commits.
        #expect(LevelEntry.neighbour(of: 3, in: order, forward: true) { enabled.contains($0) } == nil)
        // The channel being left does not need to be enabled itself.
        #expect(LevelEntry.neighbour(of: 2, in: order, forward: true) { enabled.contains($0) } == 3)
    }

    @Test func aReadoutThatIsNotOnThePageHasNoNeighbour() {
        #expect(LevelEntry.neighbour(of: 9, in: [0, 1, 2], forward: true) { _ in true } == nil)
        #expect(LevelEntry.neighbour(of: 0, in: [Int](), forward: true) { _ in true } == nil)
    }

    // MARK: Which strips take part

    /// Mic and Instrument strips show the gain knob, not a trim; hidden trims
    /// and converters (where the setting does nothing) have no field to type in.
    @Test func inputTrimReadoutIsEditableOnlyWhereTheTrimFaderIs() {
        for level in [AnalogInputLevel.plus4dBu, .minus10dBV, .variable] {
            #expect(InputChannelLogic.hasEditableTrimReadout(level: level, showTrims: true, convertersOnly: false))
            #expect(!InputChannelLogic.hasEditableTrimReadout(level: level, showTrims: false, convertersOnly: false))
            #expect(!InputChannelLogic.hasEditableTrimReadout(level: level, showTrims: true, convertersOnly: true))
        }
        for level in [AnalogInputLevel.mic, .instrument] {
            #expect(!InputChannelLogic.hasEditableTrimReadout(level: level, showTrims: true, convertersOnly: false))
        }
    }

    @Test func outputTrimReadoutIsEditableOnlyWhereTheTrimFaderIs() {
        #expect(OutputChannelLogic.hasEditableTrimReadout(showTrims: true, convertersOnly: false))
        #expect(!OutputChannelLogic.hasEditableTrimReadout(showTrims: false, convertersOnly: false))
        #expect(!OutputChannelLogic.hasEditableTrimReadout(showTrims: true, convertersOnly: true))
    }

    /// Tab across an 8-channel rack whose channels 3-4 are on Mic: 2 → 5.
    @Test func tabAcrossAMixedInputRackSkipsMicStrips() {
        let levels: [AnalogInputLevel] = [.plus4dBu, .plus4dBu, .mic, .instrument, .variable, .plus4dBu, .plus4dBu, .plus4dBu]
        let editable: (Int) -> Bool = {
            InputChannelLogic.hasEditableTrimReadout(level: levels[$0], showTrims: true, convertersOnly: false)
        }
        #expect(LevelEntry.neighbour(of: 1, in: Array(levels.indices), forward: true, isEnabled: editable) == 4)
        #expect(LevelEntry.neighbour(of: 4, in: Array(levels.indices), forward: false, isEnabled: editable) == 1)
    }

    // MARK: Mixer

    @Test func mixerTabOrderIsInputsThenSoftwareReturnThenMaster() {
        let order = MixerLevelReadout.order(visibleInputs: [0, 2, 5])
        #expect(order == [.input(0), .input(2), .input(5), .softwareReturn, .master])
        #expect(LevelEntry.neighbour(of: .input(0), in: order, forward: true) { _ in true } == .input(2))
        #expect(LevelEntry.neighbour(of: .input(5), in: order, forward: true) { _ in true } == .softwareReturn)
        #expect(LevelEntry.neighbour(of: .softwareReturn, in: order, forward: true) { _ in true } == .master)
        #expect(LevelEntry.neighbour(of: .master, in: order, forward: true) { _ in true } == nil)
        #expect(LevelEntry.neighbour(of: .softwareReturn, in: order, forward: false) { _ in true } == .input(5))
        #expect(MixerLevelReadout.order(visibleInputs: []) == [.softwareReturn, .master])
    }
}
