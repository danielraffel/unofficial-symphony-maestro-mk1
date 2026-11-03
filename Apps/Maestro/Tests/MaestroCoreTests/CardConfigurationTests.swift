import Testing
@testable import MaestroCore

/// Two-slot option-board configuration rules and channel arithmetic.
///
/// The rules are real hardware constraints, not preferences:
/// - An **8MicPre must be in slot 2**. The legacy daemon treats slot 1 as a hard
///   init failure with a user alert (`SymphonyIO.cpp:933-948`), and the FPGA's
///   PRIMARY-slot board-ID switch has no MicPre case at all
///   (`SymphonyIOMainFPGA.cpp:322-346`) while the secondary switch does (`:348-375`).
/// - Slot 1 must supply analog INPUTS for the preamps to feed
///   (`SymphonyIO.cpp:955-961` → `SymphonyIO_IOBoard.cpp:606-627`).
/// - An 8MicPre contributes **zero** channels of its own.
@Suite("CardConfiguration")
struct CardConfigurationTests {

    // MARK: - MicPre placement

    @Test func micPreInSlot1IsRejected() {
        for companion in IOCardType.allCases {
            let config = CardConfiguration(slot1: .micPre8, slot2: companion)
            #expect(config.isValid == false, "MicPre in slot 1 with \(companion) must be invalid")
            #expect(throws: CardConfiguration.ValidationError.micPreInSlot1) {
                try config.validate()
            }
        }
    }

    @Test func micPreInSlot2NeedsAHostBoard() {
        let config = CardConfiguration(slot1: .none, slot2: .micPre8)
        #expect(throws: CardConfiguration.ValidationError.micPreWithoutHostBoard) {
            try config.validate()
        }
    }

    /// A DA16 has no analog inputs, so its preamps would feed nothing.
    @Test func micPreNeedsAnalogInputsInSlot1() {
        let config = CardConfiguration(slot1: .analogDA16, slot2: .micPre8)
        #expect(throws: CardConfiguration.ValidationError.micPreHostHasNoAnalogInputs(host: .analogDA16)) {
            try config.validate()
        }
    }

    /// A 2x6 has two analog inputs — not enough for eight preamps, and Apogee
    /// requires "an 8x8 or 16x16 module in slot 1" (user guide pp. 9, 13).
    @Test func micPreNeedsEightAnalogInputsInSlot1() {
        let config = CardConfiguration(slot1: .twoBySix, slot2: .micPre8)
        #expect(config.isValid == false)
        #expect(throws: CardConfiguration.ValidationError.micPreHostHasNoAnalogInputs(host: .twoBySix)) {
            try config.validate()
        }
    }

    /// The legal MicPre hosts: the 8x8s and the 16-channel analog-input modules.
    @Test func legalMicPreHosts() {
        let legal: [IOCardType] = [.analogAES, .optical, .analogAD16, .analogADDA16]
        for host in legal {
            let config = CardConfiguration(slot1: host, slot2: .micPre8)
            #expect(config.isValid, "\(host) + MicPre should be valid")
            #expect(config.hasMicPre)
            #expect(config.micPreHostCard == host)
        }
    }

    @Test func dualMicPreIsRejected() {
        #expect(CardConfiguration(slot1: .micPre8, slot2: .micPre8).isValid == false)
    }

    // MARK: - Non-MicPre configurations are unconstrained

    @Test func everyNonMicPreCombinationIsValid() {
        for c1 in IOCardType.allCases where c1 != .micPre8 {
            for c2 in IOCardType.allCases where c2 != .micPre8 {
                #expect(CardConfiguration(slot1: c1, slot2: c2).isValid,
                        "\(c1) + \(c2) should be valid")
            }
        }
    }

    // MARK: - MicPre contributes no channels

    /// The legacy bug at `SymphonyIO.cpp:975-978` adds 16 in/out per non-None
    /// board including MicPre8. A 16x16 + MicPre unit has 16 in / 16 out, not 32.
    @Test func micPreAddsNoChannels() {
        let config = CardConfiguration.sixteenBySixteenPlusMicPre
        #expect(config.isValid)
        #expect(config.analogInputChannels == 16)
        #expect(config.analogOutputChannels == 16)
        #expect(config.digitalInputChannels == 0)
        #expect(config.digitalOutputChannels == 0)
        #expect(config.totalInputChannels == 16)
        #expect(config.totalOutputChannels == 16)
    }

    @Test func micPreChannelCountFollowsTheHostsAnalogInputs() {
        // 16x16 host: preamps cover the first 8 of its 16 analog inputs.
        #expect(CardConfiguration(slot1: .analogADDA16, slot2: .micPre8).micPreChannelCount == 8)
        // 8x8 OPT host: 8 analog inputs, all 8 preamped.
        #expect(CardConfiguration(slot1: .optical, slot2: .micPre8).micPreChannelCount == 8)
        // 2x6 host: two analog inputs. The pairing is rejected by validate(),
        // but the arithmetic still answers for anything that asks.
        #expect(CardConfiguration(slot1: .twoBySix, slot2: .micPre8).micPreChannelCount == 2)
        // No MicPre at all.
        #expect(CardConfiguration.devUnit.micPreChannelCount == 0)
    }

    /// Only four physical 1/4" instrument jacks exist.
    /// Evidence: `cstNumInputsWithInstrument = 4` (`SymphonyIOBoard_MicPre8ch.cpp:26`).
    @Test func instrumentChannelsCapAtFour() {
        #expect(CardConfiguration(slot1: .analogADDA16, slot2: .micPre8).instrumentChannelCount == 4)
        #expect(CardConfiguration(slot1: .twoBySix, slot2: .micPre8).instrumentChannelCount == 2)
        #expect(CardConfiguration.devUnit.instrumentChannelCount == 0)
    }

    // MARK: - Channel arithmetic for real pairings

    /// The user's dev unit: 8x8 OPT + 16 Analog In / 16 Digital Out.
    @Test func devUnitChannelCounts() {
        let config = CardConfiguration.devUnit
        #expect(config.slot1 == .optical)
        #expect(config.slot2 == .analogAD16)
        #expect(config.isValid)
        #expect(config.analogInputChannels == 8 + 16)
        #expect(config.digitalInputChannels == 8 + 0)
        #expect(config.analogOutputChannels == 8 + 0)
        #expect(config.digitalOutputChannels == 8 + 16)
        #expect(config.totalInputChannels == 32)
        #expect(config.totalOutputChannels == 32)
        #expect(config.hasMicPre == false)
    }

    @Test func dualOpticalChannelCounts() {
        let config = CardConfiguration(slot1: .optical, slot2: .optical)
        #expect(config.totalInputChannels == 32)
        #expect(config.totalOutputChannels == 32)
        #expect(config.analogInputChannels == 16)
        #expect(config.digitalInputChannels == 16)
    }

    @Test func emptyChassisHasNoChannels() {
        let config = CardConfiguration(slot1: .none, slot2: .none)
        #expect(config.isValid)
        #expect(config.totalInputChannels == 0)
        #expect(config.totalOutputChannels == 0)
        #expect(config.hasMicPre == false)
    }

    @Test func meterGeometryIsCardIndependent() {
        #expect(CardConfiguration.meterSlotsPerBoard == 16)
        #expect(CardConfiguration.meterWordCount == 32)
    }

    // MARK: - Debug simulation token parsing

    @Test func parsesCaseNames() {
        #expect(CardSimulation.parseCard("micPre8") == .micPre8)
        #expect(CardSimulation.parseCard("analogADDA16") == .analogADDA16)
        #expect(CardSimulation.parseCard("OPTICAL") == .optical)
        #expect(CardSimulation.parseCard("  optical  ") == .optical)
    }

    @Test func parsesRawFirmwareValues() {
        for card in IOCardType.allCases {
            #expect(CardSimulation.parseCard("\(card.rawValue)") == card)
        }
    }

    @Test func parsesApogeeProductNames() {
        #expect(CardSimulation.parseCard("8MicPre") == .micPre8)
        #expect(CardSimulation.parseCard("8x8 OPT") == .optical)
        #expect(CardSimulation.parseCard("16x16 Analog In/Out") == .analogADDA16)
    }

    @Test func rejectsGarbage() {
        #expect(CardSimulation.parseCard("banana") == nil)
        #expect(CardSimulation.parseCard("") == nil)
        #expect(CardSimulation.parseCard("8") == nil)   // past the end of the enum
        #expect(CardSimulation.parseCard("255") == nil)
    }

    /// Inert unless asked: no tokens means no simulation.
    @Test func resolveIsInertWithoutTokens() throws {
        #expect(try CardSimulation.resolve(primaryToken: nil, secondaryToken: nil) == nil)
    }

    @Test func resolveBuildsTheRequestedConfiguration() throws {
        let config = try CardSimulation.resolve(primaryToken: "analogADDA16", secondaryToken: "micPre8")
        #expect(config == CardConfiguration.sixteenBySixteenPlusMicPre)
    }

    @Test func resolveDefaultsAMissingSlotToNone() throws {
        let config = try CardSimulation.resolve(primaryToken: "optical", secondaryToken: nil)
        #expect(config == CardConfiguration(slot1: .optical, slot2: .none))
    }

    /// A typo becomes `.none`, so an impossible request fails loudly rather than
    /// producing a screenshot of hardware that cannot exist.
    @Test func resolveRejectsImpossibleRequests() {
        #expect(throws: CardConfiguration.ValidationError.micPreInSlot1) {
            try CardSimulation.resolve(primaryToken: "micPre8", secondaryToken: "optical")
        }
        #expect(throws: CardConfiguration.ValidationError.micPreWithoutHostBoard) {
            try CardSimulation.resolve(primaryToken: "typo", secondaryToken: "micPre8")
        }
    }
}
