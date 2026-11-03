import Testing
import Foundation
import MaestroCore

/// Parity tests for the Output tab against the Symphony I/O User's Guide
/// (July 2018, "Output Tab Window", p. 57 and the calibration walk-through on
/// p. 74) and the legacy controllers it describes.
///
/// The three rules under test are the ones the page cannot get right by
/// accident: option-click fan-out, the digital-reference-dependent trim range,
/// and the per-card S/PDIF Mirrors list.
@Suite("Output tab parity")
struct OutputTabParityTests {

    // MARK: - Helpers

    private func strips(_ n: Int,
                        analog: UInt32 = OutputChannelLogic.plus4dBu,
                        digital: UInt32 = 2,
                        trim: Double = 0) -> [OutputChannelState] {
        (0..<n).map { _ in
            OutputChannelState(analogRefLevel: analog, digitalRefLevel: digital, trim: trim)
        }
    }

    /// The developer's unit: 8x8 Optical in module 1, 16 Analog In / 16 Digital
    /// Out in module 2.
    private var devUnit: CardLayout { CardLayout(slot1: .optical, slot2: .analogAD16) }

    // MARK: - 1/4. Analog Ref Level — option-click sets ALL channels
    //
    // "Option+Select any channel to set the reference for all channels."
    // Evidence: APOutputTabRowViewController.m:230-243.

    @Test func optionClickAnalogRefReachesEveryOtherStrip() {
        var channels = strips(8)
        let changed = OutputChannelLogic.applyAnalogRefToAll(
            &channels, to: OutputChannelLogic.minus10dBV, excluding: 3)

        #expect(changed == [0, 1, 2, 4, 5, 6, 7])
        // Every strip but the origin, which the caller applies and pushes itself.
        #expect(changed.allSatisfy { channels[$0].analogRefLevel == OutputChannelLogic.minus10dBV })
        #expect(channels[3].analogRefLevel == OutputChannelLogic.plus4dBu)
    }

    @Test func analogRefFanOutLeavesTheClickedStripToTheCaller() {
        // The origin is excluded because the caller has already applied and
        // pushed it; the fan-out must not double-report it.
        var channels = strips(4)
        channels[2].analogRefLevel = OutputChannelLogic.minus10dBV
        let changed = OutputChannelLogic.applyAnalogRefToAll(
            &channels, to: OutputChannelLogic.minus10dBV, excluding: 2)

        #expect(changed == [0, 1, 3])
        #expect(!changed.contains(2))
    }

    @Test func analogRefFanOutReportsOnlyStripsThatActuallyChanged() {
        var channels = strips(4, analog: OutputChannelLogic.minus10dBV)
        channels[1].analogRefLevel = OutputChannelLogic.plus4dBu

        let changed = OutputChannelLogic.applyAnalogRefToAll(
            &channels, to: OutputChannelLogic.minus10dBV, excluding: 0)
        #expect(changed == [1])
    }

    @Test func outputsOfferOnlyTheTwoRealReferenceLevels() {
        // Variable / Mic / Instrument are input-only: AnalogOut_SymphonyIO_Stream.cpp
        // maps anything that is not -10 dBV onto +4 dBu.
        #expect(OutputChannelLogic.offersAnalogRef(OutputChannelLogic.plus4dBu))
        #expect(OutputChannelLogic.offersAnalogRef(OutputChannelLogic.minus10dBV))
        #expect(!OutputChannelLogic.offersAnalogRef(0))  // Variable
        #expect(!OutputChannelLogic.offersAnalogRef(3))  // Mic
        #expect(!OutputChannelLogic.offersAnalogRef(4))  // Instrument

        var channels = strips(2)
        #expect(OutputChannelLogic.applyAnalogRefToAll(&channels, to: 3, excluding: 0).isEmpty)
        #expect(channels.allSatisfy { $0.analogRefLevel == OutputChannelLogic.plus4dBu })
    }

    // MARK: - 5. Digital Ref Level — option-click sets ALL channels

    @Test func optionClickDigitalRefReachesEveryOtherStrip() {
        var channels = strips(8, digital: 2)
        let changed = OutputChannelLogic.applyDigitalRefToAll(&channels, to: 4, excluding: 0)

        #expect(changed.map(\.index) == [1, 2, 3, 4, 5, 6, 7])
        #expect(changed.allSatisfy { !$0.trimChanged })
        #expect(changed.allSatisfy { channels[$0.index].digitalRefLevel == 4 })
        #expect(channels[0].digitalRefLevel == 2)  // origin left to the caller
    }

    @Test func digitalRefFanOutToMinus20ClampsEveryPositiveTrim() {
        // p. 74 step 6: "when Output Digital Ref is set to -20dBfs, only a
        // negative Trim value is possible (0dB to -2 dB)."
        var channels = strips(4, digital: 2)
        channels[0].trim = 1.5
        channels[1].trim = -0.4
        channels[2].trim = 0.1
        channels[3].trim = 2.0

        let changed = OutputChannelLogic.applyDigitalRefToAll(
            &channels, to: OutputChannelLogic.digitalRefMinus20dBfs, excluding: 0)

        // Every strip but the origin moves to -20 dBfs …
        #expect(changed.map(\.index) == [1, 2, 3])
        // … and only the ones with a positive trim also need the packed
        // analog-IO-type write that carries the trim byte.
        #expect(changed.first { $0.index == 1 }?.trimChanged == false)
        #expect(changed.first { $0.index == 2 }?.trimChanged == true)
        #expect(changed.first { $0.index == 3 }?.trimChanged == true)

        #expect(channels[0].trim == 1.5)   // origin untouched by the fan-out
        #expect(channels[1].trim == -0.4)  // negative trims survive
        #expect(channels[2].trim == 0.0)
        #expect(channels[3].trim == 0.0)
    }

    @Test func digitalRefFanOutReportsAStripAlreadyAtTheLevelWhenItsTrimIsClamped() {
        // A strip that is already at -20 dBfs but holds a stale positive trim
        // still needs a hardware write — the clamp is the change, not the level.
        var channels = strips(3, digital: OutputChannelLogic.digitalRefMinus20dBfs)
        channels[1].trim = 1.0

        let changed = OutputChannelLogic.applyDigitalRefToAll(
            &channels, to: OutputChannelLogic.digitalRefMinus20dBfs, excluding: 0)

        #expect(changed.map(\.index) == [1])
        #expect(changed[0].trimChanged)
        #expect(channels[1].trim == 0.0)
    }

    @Test func leavingMinus20DoesNotRestoreTheClampedTrim() {
        // The clamp is destructive, exactly as the daemon's is: it overwrites
        // m_aflTrimPlus4[i] rather than remembering the old value.
        var channels = strips(2, digital: OutputChannelLogic.digitalRefMinus20dBfs, trim: 1.2)
        OutputChannelLogic.applyDigitalRefChange(
            &channels, channel: 0, to: OutputChannelLogic.digitalRefMinus20dBfs)
        #expect(channels[0].trim == 0.0)

        OutputChannelLogic.applyDigitalRefChange(&channels, channel: 0, to: 2)
        #expect(channels[0].trim == 0.0)
    }

    // MARK: - 6. Trim Fader — +/- 0.1 dB, range follows the DIGITAL reference

    @Test func trimResolutionIsOneTenthOfADecibel() {
        // "use the Trim fader to precisely trim the D/A conversion level within
        // +- 0.1 dB" — and the wire encoding is round(10 * dB).
        for level in OutputChannelLogic.digitalRefLevels {
            #expect(OutputChannelLogic.trimRange(digitalRefLevel: level).step == 0.1)
        }
    }

    @Test func trimRangeIsPlusMinusTwoExceptAtMinus20dBfs() {
        // AnalogOut_SymphonyIO_Stream.cpp:369-376 (outputTrimRange).
        let atMinus20 = OutputChannelLogic.trimRange(
            digitalRefLevel: OutputChannelLogic.digitalRefMinus20dBfs).range
        #expect(atMinus20 == -2.0...0.0)

        for level in OutputChannelLogic.digitalRefLevels
        where level != OutputChannelLogic.digitalRefMinus20dBfs {
            #expect(OutputChannelLogic.trimRange(digitalRefLevel: level).range == -2.0...2.0)
        }
    }

    @Test func trimClampHonoursBothEndsOfTheRange() {
        #expect(OutputChannelLogic.clampTrim(3.0, digitalRefLevel: 2) == 2.0)
        #expect(OutputChannelLogic.clampTrim(-3.0, digitalRefLevel: 2) == -2.0)
        #expect(OutputChannelLogic.clampTrim(0.7, digitalRefLevel: 2) == 0.7)

        let minus20 = OutputChannelLogic.digitalRefMinus20dBfs
        #expect(OutputChannelLogic.clampTrim(0.7, digitalRefLevel: minus20) == 0.0)
        #expect(OutputChannelLogic.clampTrim(-1.9, digitalRefLevel: minus20) == -1.9)
        #expect(OutputChannelLogic.clampTrim(-2.5, digitalRefLevel: minus20) == -2.0)
    }

    // MARK: - 3. Reset Trims

    @Test func resetTrimsZeroesEveryTrimAndTouchesNothingElse() {
        var channels = strips(4, analog: OutputChannelLogic.minus10dBV, digital: 5)
        channels[0].trim = 1.4
        channels[2].trim = -0.3

        let writes = OutputChannelLogic.resetTrims(&channels)

        #expect(writes == [0, 2])  // strips already at 0.0 need no write
        #expect(channels.allSatisfy { $0.trim == 0.0 })
        #expect(channels.allSatisfy { $0.analogRefLevel == OutputChannelLogic.minus10dBV })
        #expect(channels.allSatisfy { $0.digitalRefLevel == 5 })
    }

    // MARK: - 8. S/PDIF Mirrors — card-aware, and never "Off"

    /// Every mirror list, on every card, must stay inside the wire enum.
    /// `SymphonyIOBoardSPDIFCoaxReplace` has exactly nine values (Off + 1…8);
    /// an earlier slot-2 list ran to ID 12, four past the end.
    @Test(arguments: [IOCardType.none, .micPre8, .analogAES, .optical,
                      .analogAD16, .analogDA16, .analogADDA16, .twoBySix])
    func mirrorIDsNeverLeaveTheWireEnum(card: IOCardType) {
        for other in [IOCardType.none, .micPre8, .optical, .analogAD16] {
            for slot in 0...1 {
                let layout = slot == 0
                    ? CardLayout(slot1: card, slot2: other)
                    : CardLayout(slot1: other, slot2: card)
                let options = OutputChannelLogic.mirrorOptions(
                    layout.spdifOptions(slot: slot, isInput: false))

                #expect(options.allSatisfy { (1...8).contains($0.id) },
                        "\(card) in slot \(slot + 1) offered an out-of-range mirror ID")
                #expect(options.count == Set(options.map(\.id)).count,
                        "\(card) in slot \(slot + 1) offered a duplicate mirror ID")
                #expect(options.count <= 8)
            }
        }
    }

    /// The coax output is always tapped from *some* pair, so the Mirrors popup
    /// has no Off — unlike the Input page's Replaces popup, which does.
    /// Evidence: `SymphonyIO_IOBoard.cpp:1204-1215`.
    @Test(arguments: [IOCardType.analogAES, .optical, .analogAD16,
                      .analogDA16, .analogADDA16, .twoBySix])
    func mirrorListsHaveNoOffButReplaceListsDo(card: IOCardType) {
        let layout = CardLayout(slot1: card, slot2: .none)
        let mirrors = OutputChannelLogic.mirrorOptions(
            layout.spdifOptions(slot: 0, isInput: false))
        let replaces = layout.spdifOptions(slot: 0, isInput: true)

        #expect(!mirrors.contains { $0.id == OutputChannelLogic.spdifOffID })
        #expect(!mirrors.contains { $0.name == "Off" })
        #expect(replaces.first?.name == "Off")
        #expect(!mirrors.isEmpty)
    }

    /// A module with no coax jack offers no mirror at all. The 8MicPre is the
    /// only one: it has instrument jacks and insert DB-25s and nothing else
    /// (User's Guide p. 13).
    @Test func micPreAndEmptySlotsOfferNoMirror() {
        let layout = CardLayout(slot1: .analogADDA16, slot2: .micPre8)
        #expect(OutputChannelLogic.mirrorOptions(
            layout.spdifOptions(slot: 1, isInput: false)).isEmpty)
        #expect(!layout.hasSPDIF(slot: 1))

        let empty = CardLayout(slot1: .optical, slot2: .none)
        #expect(OutputChannelLogic.mirrorOptions(
            empty.spdifOptions(slot: 1, isInput: false)).isEmpty)
    }

    /// The names come from the installed card, not from the 8x8 card the enum
    /// was named after. `SymphonyIOVendorSpecific.h:936` says so explicitly.
    @Test func mirrorNamesFollowTheInstalledCard() {
        func names(_ card: IOCardType) -> [String] {
            OutputChannelLogic.mirrorOptions(
                CardLayout(slot1: card, slot2: .none)
                    .spdifOptions(slot: 0, isInput: false)).map(\.name)
        }

        // 8x8 optical: four analog output pairs, then four ADAT.
        #expect(names(.optical) == ["Analog 1-2", "Analog 3-4", "Analog 5-6", "Analog 7-8",
                                    "ADAT 1-2", "ADAT 3-4", "ADAT 5-6", "ADAT 7-8"])
        // 8x8 AES names its digital pairs AES, not ADAT.
        #expect(names(.analogAES) == ["Analog 1-2", "Analog 3-4", "Analog 5-6", "Analog 7-8",
                                      "AES 1-2", "AES 3-4", "AES 5-6", "AES 7-8"])
        // 16x16 analog: eight analog output pairs and no digital at all.
        #expect(names(.analogADDA16) == ["Analog 1-2", "Analog 3-4", "Analog 5-6", "Analog 7-8",
                                         "Analog 9-10", "Analog 11-12", "Analog 13-14",
                                         "Analog 15-16"])
        // 16 Digital In / 16 Analog Out: all eight pairs are analog outputs.
        #expect(names(.analogDA16).allSatisfy { $0.hasPrefix("Analog ") })
        #expect(names(.analogDA16).count == 8)
    }

    /// A 16 Analog In / 16 Digital Out module has ZERO analog outputs, so every
    /// pair its coax can mirror is a digital one.
    @Test func analogInOnlyCardMirrorsOnlyDigitalPairs() {
        let layout = CardLayout(slot1: .analogAD16, slot2: .none)
        let options = OutputChannelLogic.mirrorOptions(
            layout.spdifOptions(slot: 0, isInput: false))

        #expect(layout.analogOutputStripCount == 0)
        #expect(options.count == 8)
        #expect(options.allSatisfy { $0.name.hasPrefix("ADAT ") })
        #expect(options.first?.name == "ADAT 1-2")
        #expect(options.last?.name == "ADAT 15-16")
    }

    // MARK: - The developer's unit must not change

    @Test func devUnitKeepsEightLineOutputStrips() {
        #expect(devUnit.analogOutputStripCount == 8)
        #expect(devUnit.slot1.analogOutputChannels == 8)   // 8x8 Optical
        #expect(devUnit.slot2.analogOutputChannels == 0)   // AD16 has no D/A
    }

    @Test func devUnitDigitalOutputPairsAreUnchanged() {
        let pairs = devUnit.digitalOutputPairs
        #expect(pairs.count == 12)                          // 4 optical + 8 AD16
        #expect(pairs.first?.label == "ADAT 1/2")
        #expect(pairs.last?.label == "ADAT 23/24")
        // Only the first four pairs of each board are metered: module 1
        // contributes pairs 0-3, module 2 pairs 4-11, of which only 4-7 have a
        // word in the meter payload.
        #expect(pairs[3].meterIndex == 6)
        #expect(pairs[4].meterIndex == 8)
        #expect(pairs[8].meterIndex == nil)
    }

    @Test func devUnitMirrorListsAreTheLegacyOnes() {
        let slot1 = OutputChannelLogic.mirrorOptions(
            devUnit.spdifOptions(slot: 0, isInput: false))
        #expect(slot1.map(\.id) == [1, 2, 3, 4, 5, 6, 7, 8])
        #expect(slot1.map(\.name) == ["Analog 1-2", "Analog 3-4", "Analog 5-6", "Analog 7-8",
                                      "ADAT 1-2", "ADAT 3-4", "ADAT 5-6", "ADAT 7-8"])

        // Module 2's channel numbers continue from module 1 — the legacy name
        // builder adds NumberPrecedingChannels() of the same plug type
        // (SymphonyIOBoard_AD16ch.cpp:176-180).
        let slot2 = OutputChannelLogic.mirrorOptions(
            devUnit.spdifOptions(slot: 1, isInput: false))
        #expect(slot2.map(\.id) == [1, 2, 3, 4, 5, 6, 7, 8])
        #expect(slot2.first?.name == "ADAT 9-10")
        #expect(slot2.last?.name == "ADAT 23-24")
    }

    // MARK: - Stored-value resolution

    @Test func aStoredMirrorIDThatThisCardCannotOfferFallsBackToItsFirstPair() {
        let ad16 = OutputChannelLogic.mirrorOptions(
            CardLayout(slot1: .analogAD16, slot2: .none)
                .spdifOptions(slot: 0, isInput: false))

        #expect(OutputChannelLogic.resolvedMirrorID(5, options: ad16) == 5)
        // Off (0) is never a mirror, and 12 is past the end of the enum — the
        // two values the old page could end up displaying.
        #expect(OutputChannelLogic.resolvedMirrorID(0, options: ad16) == 1)
        #expect(OutputChannelLogic.resolvedMirrorID(12, options: ad16) == 1)

        // A 2x6 offers only three analog pairs before its digital ones.
        let twoBySix = OutputChannelLogic.mirrorOptions(
            CardLayout(slot1: .twoBySix, slot2: .none)
                .spdifOptions(slot: 0, isInput: false))
        #expect(twoBySix.count == 8)
        #expect(twoBySix.prefix(3).map(\.name) == ["Analog 1-2", "Analog 3-4", "Analog 5-6"])

        // A slot with no coax resolves to nothing rather than to a phantom pair.
        #expect(OutputChannelLogic.resolvedMirrorID(1, options: []) == nil)
    }

    @Test func anUnreadLayoutStillOffersTheEightByEightShapedList() {
        // Board detection is async; the page must not render an empty popup
        // while the 0xA1 reads are in flight.
        let unknown = CardLayout(slot1: .none, slot2: .none, isKnown: false)
        let options = OutputChannelLogic.mirrorOptions(
            unknown.spdifOptions(slot: 0, isInput: false))
        #expect(options.count == 8)
        #expect(options.map(\.id) == [1, 2, 3, 4, 5, 6, 7, 8])
        #expect(!options.contains { $0.name == "Off" })
    }

    // MARK: - Speaker & Headphone Controls (User's Guide pp. 58 & 60)

    /// The Analog Out Format list is an analog-output COUNT rule, not a card
    /// identity rule. `SymphonyIO.cpp:3429-3480`.
    @Test func analogOutFormatTiersFollowTheAnalogOutputCount() {
        let line = SpeakerOutputLogic.line

        // No analog outputs at all — a 16 Analog In / 16 Digital Out pair.
        #expect(SpeakerOutputLogic.availableModes(analogOutputChannels: 0,
                                                  module1IsTwoBySix: false) == [line])
        // A 2x6 has two analog INPUTS but six outputs; the two-output tier is
        // reached by e.g. a partially populated unit.
        #expect(SpeakerOutputLogic.availableModes(analogOutputChannels: 2,
                                                  module1IsTwoBySix: false)
                == [line, SpeakerOutputLogic.stereo])
        // There is NO four-output tier — four analog outs get Stereo and
        // nothing more. The old local rule offered "2 Speaker Sets" here.
        #expect(SpeakerOutputLogic.availableModes(analogOutputChannels: 4,
                                                  module1IsTwoBySix: false)
                == [line, SpeakerOutputLogic.stereo])
        // Six outputs: everything but 7.1.
        #expect(SpeakerOutputLogic.availableModes(analogOutputChannels: 6,
                                                  module1IsTwoBySix: false)
                == [line, SpeakerOutputLogic.stereo, SpeakerOutputLogic.twoSpeakerSets,
                    SpeakerOutputLogic.threeSpeakerSets, SpeakerOutputLogic.surround51])
        // Eight or more: 7.1 as well.
        #expect(SpeakerOutputLogic.availableModes(analogOutputChannels: 16,
                                                  module1IsTwoBySix: false)
                == [line, SpeakerOutputLogic.stereo, SpeakerOutputLogic.twoSpeakerSets,
                    SpeakerOutputLogic.threeSpeakerSets, SpeakerOutputLogic.surround51,
                    SpeakerOutputLogic.surround71])
    }

    @Test func aTwoBySixInModuleOneNeverReachesTheSevenPointOneTier() {
        // A 2x6 plus a 16-out module clears eight analog outputs on the count
        // alone, but the speakers hang off module 1's six.
        let withTwoBySix = SpeakerOutputLogic.availableModes(
            analogOutputChannels: 22, module1IsTwoBySix: true)
        #expect(!withTwoBySix.contains(SpeakerOutputLogic.surround71))
        #expect(withTwoBySix.contains(SpeakerOutputLogic.surround51))

        let without = SpeakerOutputLogic.availableModes(
            analogOutputChannels: 22, module1IsTwoBySix: false)
        #expect(without.contains(SpeakerOutputLogic.surround71))
    }

    /// Every card pair must produce a list the hardware accepts, and Line must
    /// always be offered — it is the only mode a zero-output unit has.
    @Test(arguments: [IOCardType.none, .micPre8, .analogAES, .optical,
                      .analogAD16, .analogDA16, .analogADDA16, .twoBySix])
    func everyCardPairGetsALegalFormatList(card: IOCardType) {
        let legal: Set<UInt32> = [SpeakerOutputLogic.line, SpeakerOutputLogic.stereo,
                                  SpeakerOutputLogic.surround51, SpeakerOutputLogic.surround71,
                                  SpeakerOutputLogic.twoSpeakerSets,
                                  SpeakerOutputLogic.threeSpeakerSets]
        for other in [IOCardType.none, .micPre8, .optical, .analogADDA16, .twoBySix] {
            let layout = CardLayout(slot1: card, slot2: other)
            let modes = SpeakerOutputLogic.availableModes(
                analogOutputChannels: layout.analogOutputStripCount,
                module1IsTwoBySix: layout.slot1 == .twoBySix)

            #expect(modes.first == SpeakerOutputLogic.line)
            #expect(modes.allSatisfy { legal.contains($0) })
            #expect(modes.count == Set(modes).count)
        }
    }

    @Test func anAnalogInOnlyUnitOffersLineAndNothingElse() {
        // 16 Analog In / 16 Digital Out + 8MicPre: zero analog outputs.
        let layout = CardLayout(slot1: .analogAD16, slot2: .micPre8)
        #expect(layout.analogOutputStripCount == 0)
        let modes = SpeakerOutputLogic.availableModes(
            analogOutputChannels: layout.analogOutputStripCount,
            module1IsTwoBySix: false)
        #expect(modes == [SpeakerOutputLogic.line])
        #expect(!SpeakerOutputLogic.speakerControlsEnabled(
            mode: SpeakerOutputLogic.stereo, analogOutputChannels: 0))
    }

    @Test func theDevUnitOffersEveryFormatIncludingSevenPointOne() {
        // 8x8 Optical (8 analog outs) + AD16 (0): exactly the eight-output tier.
        #expect(devUnit.analogOutputStripCount == 8)
        let modes = SpeakerOutputLogic.availableModes(
            analogOutputChannels: devUnit.analogOutputStripCount,
            module1IsTwoBySix: false)
        #expect(modes.count == 6)
        #expect(modes.contains(SpeakerOutputLogic.surround71))
        #expect(modes.map(SpeakerOutputLogic.name)
                == ["Line", "Stereo (Out 1-2)", "2 Speaker Sets", "3 Speaker Sets",
                    "5.1 (Out 1-6)", "7.1 (Out 1-8)"])
    }

    /// Mode 0's display name is "Line", not "Off" (`SymphonyIO.cpp:3500-3510`).
    @Test func modeZeroIsCalledLine() {
        #expect(SpeakerOutputLogic.name(SpeakerOutputLogic.line) == "Line")
        #expect(SpeakerOutputLogic.line == 0)
        // The IDs are non-contiguous — a row index must never be sent as a mode.
        #expect(SpeakerOutputLogic.stereo == 2)
        #expect(SpeakerOutputLogic.surround51 == 6)
        #expect(SpeakerOutputLogic.surround71 == 8)
        #expect(SpeakerOutputLogic.twoSpeakerSets == 9)
        #expect(SpeakerOutputLogic.threeSpeakerSets == 10)
    }

    /// "Functions such as level control, Mute, Dim, and Sum to Mono are
    /// disabled" in Line mode (p. 60) — `SymphonyIO.cpp:7327-7344`.
    @Test func lineModeDisablesTheMonitorFunctions() {
        #expect(!SpeakerOutputLogic.speakerControlsEnabled(
            mode: SpeakerOutputLogic.line, analogOutputChannels: 16))
        #expect(!SpeakerOutputLogic.sumToMonoEnabled(
            mode: SpeakerOutputLogic.line, analogOutputChannels: 16))

        #expect(SpeakerOutputLogic.speakerControlsEnabled(
            mode: SpeakerOutputLogic.stereo, analogOutputChannels: 16))
        #expect(SpeakerOutputLogic.sumToMonoEnabled(
            mode: SpeakerOutputLogic.stereo, analogOutputChannels: 16))
    }

    @Test func changingAnalogOutFormatClearsLegacyMonitorState() {
        #expect(SpeakerOutputLogic.modeChangeClearsMonitorState(
            from: SpeakerOutputLogic.stereo, to: SpeakerOutputLogic.line))
        #expect(SpeakerOutputLogic.modeChangeClearsMonitorState(
            from: SpeakerOutputLogic.line, to: SpeakerOutputLogic.stereo))
        #expect(!SpeakerOutputLogic.modeChangeClearsMonitorState(
            from: SpeakerOutputLogic.stereo, to: SpeakerOutputLogic.stereo))
    }

    @Test func sumToMonoIsAlsoDeadInSurroundModes() {
        for mode in [SpeakerOutputLogic.surround51, SpeakerOutputLogic.surround71] {
            #expect(SpeakerOutputLogic.speakerControlsEnabled(
                mode: mode, analogOutputChannels: 16))
            #expect(!SpeakerOutputLogic.sumToMonoEnabled(
                mode: mode, analogOutputChannels: 16))
        }
        // …but not in the multi-set modes, which are still stereo pairs.
        for mode in [SpeakerOutputLogic.twoSpeakerSets, SpeakerOutputLogic.threeSpeakerSets] {
            #expect(SpeakerOutputLogic.sumToMonoEnabled(
                mode: mode, analogOutputChannels: 16))
        }
    }

    // MARK: Speaker Select

    @Test func speakerSelectButtonCountFollowsTheMode() {
        #expect(SpeakerOutputLogic.speakerSetCount(mode: SpeakerOutputLogic.twoSpeakerSets) == 2)
        #expect(SpeakerOutputLogic.speakerSetCount(mode: SpeakerOutputLogic.threeSpeakerSets) == 3)
        for mode in [SpeakerOutputLogic.line, SpeakerOutputLogic.stereo,
                     SpeakerOutputLogic.surround51, SpeakerOutputLogic.surround71] {
            #expect(SpeakerOutputLogic.speakerSetCount(mode: mode) == 0)
        }
    }

    @Test func aPlainSpeakerSelectClickSelectsThatSetAlone() {
        #expect(SpeakerOutputLogic.speakerSetMask(clicking: 0, current: 0x7, extending: false) == 0x1)
        #expect(SpeakerOutputLogic.speakerSetMask(clicking: 1, current: 0x1, extending: false) == 0x2)
        #expect(SpeakerOutputLogic.speakerSetMask(clicking: 2, current: 0x3, extending: false) == 0x4)
    }

    @Test func commandClickAddsAndRemovesSetsButNeverEmptiesTheMask() {
        // "Do not allow all speaker sets to disengage."
        #expect(SpeakerOutputLogic.speakerSetMask(clicking: 1, current: 0x1, extending: true) == 0x3)
        #expect(SpeakerOutputLogic.speakerSetMask(clicking: 1, current: 0x3, extending: true) == 0x1)
        #expect(SpeakerOutputLogic.speakerSetMask(clicking: 0, current: 0x1, extending: true) == 0x1)
        #expect(SpeakerOutputLogic.speakerSetMask(clicking: 5, current: 0x1, extending: false) == 0x1)
    }

    @Test func aButtonTheModeDoesNotEnableAlwaysReadsOff() {
        // The mask can outlive a mode change — a stale bit C must not light up
        // button 3 in 2-Speaker-Sets mode.
        #expect(SpeakerOutputLogic.speakerSetIsOn(
            index: 2, mask: 0x7, mode: SpeakerOutputLogic.threeSpeakerSets))
        #expect(!SpeakerOutputLogic.speakerSetIsOn(
            index: 2, mask: 0x7, mode: SpeakerOutputLogic.twoSpeakerSets))
        #expect(!SpeakerOutputLogic.speakerSetIsOn(
            index: 0, mask: 0x1, mode: SpeakerOutputLogic.stereo))
        #expect(SpeakerOutputLogic.defaultSpeakerSetMask == 0x1)
    }
}
