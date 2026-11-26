import Testing
@testable import MaestroCore

@Suite struct CardMeterReadRuleTests {
    @Test func readsWithNoAudioClientWhileTheUnitAnswers() {
        // The report: Symphony on, no DAW open. The meters must still read.
        #expect(CardMeterReadRule.readsCard(hardwareResponsive: true, extensionSwapGrace: false, audioRunning: false))
        #expect(CardMeterReadRule.readsCard(hardwareResponsive: true, extensionSwapGrace: false, audioRunning: true))
    }

    @Test func stopsWhenTheUnitStopsAnswering() {
        // A Symphony switched off leaves its last frame on the card.
        #expect(!CardMeterReadRule.readsCard(hardwareResponsive: false, extensionSwapGrace: false, audioRunning: false))
        #expect(!CardMeterReadRule.readsCard(hardwareResponsive: false, extensionSwapGrace: false, audioRunning: true))
    }

    @Test func driverSwapWindowNeedsRunningAudio() {
        #expect(CardMeterReadRule.readsCard(hardwareResponsive: false, extensionSwapGrace: true, audioRunning: true))
        #expect(!CardMeterReadRule.readsCard(hardwareResponsive: false, extensionSwapGrace: true, audioRunning: false))
    }

    @Test func aMissedFrameIsHeldBrieflyOnlyWithNoAudioClient() {
        #expect(CardMeterReadRule.holdsLastLevels(readDue: true, audioRunning: false, missedPolls: 1))
        #expect(CardMeterReadRule.holdsLastLevels(readDue: true, audioRunning: false, missedPolls: CardMeterReadRule.heldPolls))
        #expect(!CardMeterReadRule.holdsLastLevels(readDue: true, audioRunning: false, missedPolls: CardMeterReadRule.heldPolls + 1))
        // Streaming: the host-side levels are the fallback, as before.
        #expect(!CardMeterReadRule.holdsLastLevels(readDue: true, audioRunning: true, missedPolls: 1))
        // No read was due (unit not answering): silence, as before.
        #expect(!CardMeterReadRule.holdsLastLevels(readDue: false, audioRunning: false, missedPolls: 1))
    }
}
