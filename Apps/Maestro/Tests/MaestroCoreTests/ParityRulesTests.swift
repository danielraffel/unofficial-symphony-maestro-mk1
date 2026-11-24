import Testing
@testable import MaestroCore

@Suite("Parity rules for beta 0.9.22")
struct ParityRulesTests {
    @Test("a mixer level is shown as the whole dB that plays")
    func mixerFloor() {
        for (input, expected) in [(-0.5, -1.0), (-1.5, -2.0), (5.5, 5.0), (-47.5, -48.0), (-48, -48), (6, 6), (0, 0), (-60, -48), (9, 6)] {
            #expect(MixerFaderLevel.played(input) == expected)
        }
        #expect(MixerFaderLevel.played(-0.0).sign == .plus)
    }

    @Test("Master names the first output its mixer feeds, or None")
    func masterLabel() {
        let names = ["Line 1/2", "Line 3/4", "ADAT 1/2"]
        #expect(MasterOutputLabel.text(unitA: ([:], 16, names)) == "None")
        #expect(MasterOutputLabel.text(unitA: ([16: [1]], 16, names)) == "Line 3/4")
        #expect(MasterOutputLabel.text(unitA: ([16: [2, 0]], 16, names)) == "Line 1/2")
        // Mixer 2's row is its own.
        #expect(MasterOutputLabel.text(unitA: ([16: [0]], 17, names)) == "None")
        #expect(MasterOutputLabel.text(unitA: ([17: [2]], 17, names)) == "ADAT 1/2")
        // A saved column the cards no longer have is not named.
        #expect(MasterOutputLabel.text(unitA: ([16: [7]], 16, names)) == "None")
        // Two units: unit A first, then unit B.
        #expect(MasterOutputLabel.text(unitA: ([:], 16, names), unitB: ([32: [1]], 32, ["B Line 1/2", "B Line 3/4"])) == "B Line 3/4")
        #expect(PresetPackageKind.classify(fileNames: ["USBAudio_Symphony I_O_77.plist"]) == .maestro2)
        #expect(MasterOutputLabel.text(unitA: ([16: [0]], 16, names), unitB: ([32: [1]], 32, ["B Line 1/2", "B Line 3/4"])) == "Line 1/2")
    }

    @Test("a muted speaker is shown muted, the unit is not written")
    func mute() {
        // Muted in this session, unit forgot it across a replug: muted again.
        let rearmed = SpeakerMuteAdoption.decide(unitMuted: false, keptMuted: true)
        #expect(rearmed.showMuted && rearmed.writeUnit && rearmed.tellMac)
        // Never unmutes: a kept "unmuted" leaves a muted unit muted.
        let stays = SpeakerMuteAdoption.decide(unitMuted: true, keptMuted: false)
        #expect(stays.showMuted && !stays.writeUnit)
        let muted = SpeakerMuteAdoption.decide(unitMuted: true)
        #expect(muted.showMuted && !muted.writeUnit && muted.tellMac)
        let open = SpeakerMuteAdoption.decide(unitMuted: false)
        #expect(!open.showMuted && !open.writeUnit && !open.tellMac)
    }

    @Test("A4: at connect the quieter of the saved level and the unit's wins")
    func levelsAtConnectQuieterWins() {
        typealias Rule = MonitorLevelsAtConnect
        for output in Rule.Output.allCases {
            // Unit came up at its own -20 dB, -30 saved: down to -30.
            #expect(Rule.write(output: output, saved: 30, unit: 20, speakersInLine: false) == 30)
            #expect(Rule.settled(output: output, saved: 30, unit: 20, speakersInLine: false, written: true) == 30)
            // Saved louder than the unit (turned down on the front panel while
            // Maestro was closed, or the unit's default is quieter): left alone.
            #expect(Rule.write(output: output, saved: 10, unit: 20, speakersInLine: false) == nil)
            #expect(Rule.settled(output: output, saved: 10, unit: 20, speakersInLine: false, written: false) == 20)
            // Same level (a replug with the unit still on): nothing sent.
            #expect(Rule.write(output: output, saved: 25, unit: 25, speakersInLine: false) == nil)
            // Nothing saved: the unit is left alone and its level is what is saved from now on.
            #expect(Rule.write(output: output, saved: nil, unit: 20, speakersInLine: false) == nil)
            #expect(Rule.settled(output: output, saved: nil, unit: 20, speakersInLine: false, written: false) == 20)
            // The unit's level unreadable: nothing sent, the saved level kept.
            #expect(Rule.write(output: output, saved: 30, unit: nil, speakersInLine: false) == nil)
            #expect(Rule.settled(output: output, saved: 30, unit: nil, speakersInLine: false, written: false) == nil)
            // Out-of-range values are unreadable, never clamped (0xFF sentinel).
            #expect(Rule.write(output: output, saved: 30, unit: 0xFF, speakersInLine: false) == nil)
            #expect(Rule.write(output: output, saved: 0xFF, unit: 20, speakersInLine: false) == nil)
            #expect(Rule.settled(output: output, saved: nil, unit: 0xFF, speakersInLine: false, written: false) == nil)
            // Fully down is a level like any other.
            #expect(Rule.write(output: output, saved: 64, unit: 0, speakersInLine: false) == 64)
        }
    }

    @Test("A4: in Line the speakers are never written or saved; the headphones still are")
    func levelsAtConnectLine() {
        typealias Rule = MonitorLevelsAtConnect
        #expect(Rule.write(output: .speakers, saved: 40, unit: 0, speakersInLine: true) == nil)
        #expect(Rule.settled(output: .speakers, saved: 40, unit: 0, speakersInLine: true, written: false) == nil)
        #expect(Rule.write(output: .headphone1, saved: 40, unit: 20, speakersInLine: true) == 40)
        #expect(Rule.write(output: .headphone2, saved: 40, unit: 20, speakersInLine: true) == 40)
    }

    @Test("A4: a shown level is saved as its whole-dB attenuation")
    func levelsAtConnectAttenuation() {
        #expect(MonitorLevelsAtConnect.attenuation(dB: -20) == 20)
        #expect(MonitorLevelsAtConnect.attenuation(dB: 0) == 0)
        #expect(MonitorLevelsAtConnect.attenuation(dB: -64) == 64)
        #expect(MonitorLevelsAtConnect.attenuation(dB: -20.4) == 20)
        // As the knobs send it: -20.6 dB reaches the unit as 20.
        #expect(MonitorLevelsAtConnect.attenuation(dB: -20.6) == UInt32(max(0, 20.6)))
        #expect(MonitorLevelsAtConnect.attenuation(dB: -20.6) == 20)
        #expect(MonitorLevelsAtConnect.attenuation(dB: -70) == nil)
        #expect(MonitorLevelsAtConnect.attenuation(dB: 3) == nil)
        #expect(MonitorLevelsAtConnect.attenuation(dB: .nan) == nil)
    }

    @Test("sample rates read as the original's")
    func rates() {
        #expect(SampleRateText.format(48000) == "48 kHz")
        #expect(SampleRateText.format(44100) == "44.1 kHz")
        #expect(SampleRateText.format(96000) == "96 kHz")
        #expect(SampleRateText.format(176400) == "176.4 kHz")
        #expect(SampleRateText.format(192000) == "192 kHz")
        #expect(SampleRateText.format(47952) == "47.952 kHz")
    }

    @Test("USB always reads Ready; the card reads what the unit reports")
    func clock() {
        #expect(ClockStatusRule.shownLocked(isUSB: true, reported: false))
        #expect(!ClockStatusRule.shownLocked(isUSB: false, reported: false))
        #expect(ClockStatusRule.shownLocked(isUSB: false, reported: true))
    }

    @Test("setup-file packages are told apart by their files")
    func packages() {
        #expect(PresetPackageKind.classify(fileNames: ["MaestroApp.plist"]) == .ours)
        #expect(PresetPackageKind.classify(fileNames: ["ThunderBridge.plist", "MaestroApp.plist"]) == .ours)
        #expect(PresetPackageKind.classify(fileNames: ["symphonyAIMDeviceList.plist", "Symphony_Symphony I_O_1A2B.plist"]) == .maestro2)
        #expect(PresetPackageKind.classify(fileNames: ["SymphonyPreference.plist"]) == .maestro2)
        #expect(PresetPackageKind.classify(fileNames: ["MaestroApp.plist", "USBAudio_Symphony I_O_77.plist"]) == .oursWithDaemon)
        #expect(PresetPackageKind.classify(fileNames: ["notes.txt"]) == .unknown)
    }
}
