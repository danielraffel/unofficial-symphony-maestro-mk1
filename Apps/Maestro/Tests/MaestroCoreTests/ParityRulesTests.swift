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
        let muted = SpeakerMuteAdoption.decide(unitMuted: true)
        #expect(muted.showMuted && !muted.writeUnit && muted.tellMac)
        let open = SpeakerMuteAdoption.decide(unitMuted: false)
        #expect(!open.showMuted && !open.writeUnit && !open.tellMac)
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
