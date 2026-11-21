import Testing
@testable import MaestroCore

/// Over USB the Software Return part of a mixer's Master meter follows that
/// mixer's Software Return fader and mute and its Master fader.
@Suite("USB Master meter")
struct USBMasterMeterTests {
    private func close(_ a: Double, _ b: Double, _ tolerance: Double = 0.01) -> Bool { abs(a - b) < tolerance }

    @Test("gain is the return fader times the Master fader; a mute or a fader at the bottom is silence")
    func gain() {
        #expect(USBMasterMeter.gain(softwareReturnLevelDB: 0, softwareReturnMuted: false, masterLevelDB: 0) == 1)
        #expect(close(USBMasterMeter.gain(softwareReturnLevelDB: -6, softwareReturnMuted: false, masterLevelDB: 0), 0.5012, 0.001))
        #expect(close(USBMasterMeter.gain(softwareReturnLevelDB: 0, softwareReturnMuted: false, masterLevelDB: -20), 0.1, 0.001))
        #expect(close(USBMasterMeter.gain(softwareReturnLevelDB: -6, softwareReturnMuted: false, masterLevelDB: -14), 0.1, 0.001))
        // The unit's faders go to +6 dB.
        #expect(close(USBMasterMeter.gain(softwareReturnLevelDB: 6, softwareReturnMuted: false, masterLevelDB: 0), 1.9953, 0.001))
        #expect(close(USBMasterMeter.gain(softwareReturnLevelDB: 12, softwareReturnMuted: false, masterLevelDB: 0), 1.9953, 0.001))
        #expect(USBMasterMeter.gain(softwareReturnLevelDB: 0, softwareReturnMuted: true, masterLevelDB: 0) == 0)
        #expect(USBMasterMeter.gain(softwareReturnLevelDB: -48, softwareReturnMuted: false, masterLevelDB: 0) == 0)
        #expect(USBMasterMeter.gain(softwareReturnLevelDB: 0, softwareReturnMuted: false, masterLevelDB: -48) == 0)
        #expect(USBMasterMeter.gain(softwareReturnLevelDB: .nan, softwareReturnMuted: false, masterLevelDB: 0) == 0)
    }

    @Test("the meter follows the Software Return fader, its mute and the Master fader")
    func level() {
        let peak: Float = 0.5          // -6.02 dBFS of host playback
        let silentUnit = -60.0
        func meter(_ returnDB: Double, _ muted: Bool, _ masterDB: Double, unit: Double = -60) -> Double {
            USBMasterMeter.level(unitMaster: unit, softwareReturnPeak: peak,
                                 gain: USBMasterMeter.gain(softwareReturnLevelDB: returnDB,
                                                           softwareReturnMuted: muted, masterLevelDB: masterDB))
        }
        #expect(close(meter(0, false, 0), -6.02))
        // The reported fault: these three used to read -6 whatever the faders said.
        #expect(close(meter(-10, false, 0), -16.02))
        #expect(close(meter(0, false, -10), -16.02))
        #expect(close(meter(-10, false, -10), -26.02))
        #expect(meter(0, true, 0) == silentUnit)
        #expect(meter(-48, false, 0) == silentUnit)
        // What the unit reports for the mixer's output (its inputs) is never hidden.
        #expect(meter(0, true, 0, unit: -12) == -12)
        #expect(meter(-30, false, 0, unit: -12) == -12)
        #expect(close(meter(0, false, 0, unit: -12), -6.02))
        // Floor and bad input.
        #expect(USBMasterMeter.level(unitMaster: -60, softwareReturnPeak: 0, gain: 1) == -60)
        #expect(USBMasterMeter.level(unitMaster: -60, softwareReturnPeak: -1, gain: 1) == -60)
        #expect(USBMasterMeter.level(unitMaster: -60, softwareReturnPeak: 1, gain: -3) == -60)
    }
}
