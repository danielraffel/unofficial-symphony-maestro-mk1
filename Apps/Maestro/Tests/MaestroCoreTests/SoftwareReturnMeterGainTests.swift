import Foundation
import Testing
@testable import MaestroCore

@Suite("SoftwareReturnMeterGain")
struct SoftwareReturnMeterGainTests {

    @Test("pan law matches the card mixer table")
    func panLaw() {
        // Same points Drivers/Thunderbolt/Scripts/test-mixer-pan.sh asserts.
        #expect(SoftwareReturnMeterGain.panAttenuationDB(side: 0) == -48)
        #expect(SoftwareReturnMeterGain.panAttenuationDB(side: 32) == -24)
        #expect(SoftwareReturnMeterGain.panAttenuationDB(side: 64) == 0)
        #expect(SoftwareReturnMeterGain.panAttenuationDB(side: 96) == 0)
        #expect(SoftwareReturnMeterGain.panAttenuationDB(side: 128) == 0)
    }

    @Test("pan byte uses the mapper encoding")
    func panByte() {
        #expect(SoftwareReturnMeterGain.panByte(-1) == 0)
        #expect(SoftwareReturnMeterGain.panByte(0) == 64)
        #expect(SoftwareReturnMeterGain.panByte(1) == 128)
        #expect(SoftwareReturnMeterGain.panByte(2) == 128)
    }

    @Test("centre pan at unity leaves both meters untouched")
    func centreUnity() {
        let g = SoftwareReturnMeterGain.gains(leftLevelDB: 0, rightLevelDB: 0, pan: 0, isMuted: false)
        #expect(g.left == 1.0 && g.right == 1.0)
    }

    @Test("hard right silences the left meter and keeps the right at unity")
    func hardRight() {
        let g = SoftwareReturnMeterGain.gains(leftLevelDB: 0, rightLevelDB: 0, pan: 1, isMuted: false)
        #expect(g.left == 0.0)
        #expect(g.right == 1.0)
    }

    @Test("hard left silences the right meter")
    func hardLeft() {
        let g = SoftwareReturnMeterGain.gains(leftLevelDB: 0, rightLevelDB: 0, pan: -1, isMuted: false)
        #expect(g.left == 1.0)
        #expect(g.right == 0.0)
    }

    @Test("half right attenuates the left meter by the table value")
    func halfRight() {
        // pan 0.5 → byte 96 → left side index 32 → -24 dB.
        let g = SoftwareReturnMeterGain.gains(leftLevelDB: 0, rightLevelDB: 0, pan: 0.5, isMuted: false)
        #expect(abs(g.left - pow(10.0, -24.0 / 20.0)) < 1e-9)
        #expect(g.right == 1.0)
    }

    @Test("fader level scales each side independently")
    func faderLevels() {
        let g = SoftwareReturnMeterGain.gains(leftLevelDB: -6, rightLevelDB: -12, pan: 0, isMuted: false)
        #expect(abs(g.left - pow(10.0, -6.0 / 20.0)) < 1e-9)
        #expect(abs(g.right - pow(10.0, -12.0 / 20.0)) < 1e-9)
    }

    @Test("mute zeroes both meters; the floor is silence; levels clamp to 0 dB")
    func muteAndClamps() {
        #expect(SoftwareReturnMeterGain.gains(leftLevelDB: 0, rightLevelDB: 0, pan: 0, isMuted: true) == (0.0, 0.0))
        #expect(SoftwareReturnMeterGain.gains(leftLevelDB: -48, rightLevelDB: -60, pan: 0, isMuted: false) == (0.0, 0.0))
        #expect(SoftwareReturnMeterGain.gains(leftLevelDB: 6, rightLevelDB: 6, pan: 0, isMuted: false) == (1.0, 1.0))
    }
}

@Suite("Software Return meter: chosen pair and Pre-Mute Metering")
struct SoftwareReturnMeterSourceTests {
    @Test("each pair reads its own playback words")
    func words() {
        #expect(SoftwareReturnMeterGain.playbackWord(source: 0) == 64)
        #expect(SoftwareReturnMeterGain.playbackWord(source: 1) == 66)
        #expect(SoftwareReturnMeterGain.playbackWord(source: 7) == 78)
        #expect(SoftwareReturnMeterGain.playbackWord(source: 31) == 126)
        #expect(SoftwareReturnMeterGain.playbackWord(source: 32) == 64)
        #expect(SoftwareReturnMeterGain.playbackWord(source: -1) == 64)
    }

    @Test("Pre-Mute Metering on: what arrives; off: after fader and mute")
    func preMute() {
        let on = SoftwareReturnMeterGain.meterGains(preMuteMetering: true, levelDB: -20, isMuted: true)
        #expect(on.left == 1.0 && on.right == 1.0)
        let muted = SoftwareReturnMeterGain.meterGains(preMuteMetering: false, levelDB: 0, isMuted: true)
        #expect(muted.left == 0.0 && muted.right == 0.0)
        let faded = SoftwareReturnMeterGain.meterGains(preMuteMetering: false, levelDB: -20, isMuted: false)
        #expect(abs(faded.left - 0.1) < 1e-9 && abs(faded.right - 0.1) < 1e-9)
    }
}
