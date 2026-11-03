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
