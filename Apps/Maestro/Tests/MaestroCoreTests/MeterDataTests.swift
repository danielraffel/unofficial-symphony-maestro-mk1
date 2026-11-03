import Foundation
import Testing
@testable import MaestroCore

/// Tests for the metering domain model.
///
/// Evidence sources:
/// - `og_source/generic/CoreAudio/mAEstro.h` (mAEstroStreamMeter, mAEstroHardwareMeteringData)

@Suite("MeterData")
struct MeterDataTests {

    // MARK: - MeterSample

    @Test func sampleDefaultIsSilence() {
        let s = MeterSample()
        #expect(s.peak == 0.0)
        #expect(s.isOver == false)
    }

    @Test func sampleSilenceConstant() {
        #expect(MeterSample.silence.peak == 0.0)
        #expect(MeterSample.silence.isOver == false)
    }

    @Test func sampleEquality() {
        let a = MeterSample(peak: 0.5, isOver: false)
        let b = MeterSample(peak: 0.5, isOver: false)
        let c = MeterSample(peak: 0.5, isOver: true)
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - MeterBank

    @Test func bankWithChannelCount() {
        let bank = MeterBank(channelCount: 8)
        #expect(bank.channels.count == 8)
        for ch in bank.channels {
            #expect(ch.peak == 0.0)
            #expect(ch.isOver == false)
        }
    }

    @Test func bankClearOvers() {
        var bank = MeterBank(channels: [
            MeterSample(peak: 0.8, isOver: true),
            MeterSample(peak: 0.3, isOver: false),
            MeterSample(peak: 0.95, isOver: true),
        ])
        bank.clearOvers()
        #expect(bank.channels[0].peak == 0.8) // peak preserved
        #expect(bank.channels[0].isOver == false) // over cleared
        #expect(bank.channels[2].isOver == false)
    }

    @Test func bankReset() {
        var bank = MeterBank(channels: [
            MeterSample(peak: 0.8, isOver: true),
            MeterSample(peak: 0.3, isOver: false),
        ])
        bank.reset()
        #expect(bank.channels[0] == .silence)
        #expect(bank.channels[1] == .silence)
    }

    // MARK: - MeterSnapshot

    @Test func snapshotDefault() {
        let snap = MeterSnapshot()
        #expect(snap.inputs.channels.isEmpty)
        #expect(snap.playback.channels.isEmpty)
        #expect(snap.mixOutput.channels.isEmpty)
    }

    @Test func snapshotClearOvers() {
        var snap = MeterSnapshot(
            inputs: MeterBank(channels: [MeterSample(peak: 0.9, isOver: true)]),
            playback: MeterBank(channels: [MeterSample(peak: 0.7, isOver: true)]),
            mixOutput: MeterBank(channels: [MeterSample(peak: 0.5, isOver: true)])
        )
        snap.clearOvers()
        #expect(snap.inputs.channels[0].isOver == false)
        #expect(snap.playback.channels[0].isOver == false)
        #expect(snap.mixOutput.channels[0].isOver == false)
        // Peaks preserved
        #expect(snap.inputs.channels[0].peak == 0.9)
    }

    @Test func snapshotReset() {
        var snap = MeterSnapshot(
            inputs: MeterBank(channels: [MeterSample(peak: 0.9, isOver: true)]),
            playback: MeterBank(channels: [MeterSample(peak: 0.7, isOver: false)]),
            mixOutput: MeterBank(channels: [MeterSample(peak: 0.5, isOver: true)])
        )
        snap.reset()
        #expect(snap.inputs.channels[0] == .silence)
        #expect(snap.playback.channels[0] == .silence)
        #expect(snap.mixOutput.channels[0] == .silence)
    }

    // MARK: - MeterDefaults

    /// Symphony IO at 44.1/48k: 16 inputs (8 analog + 8 digital), 16 outputs, 2 mix.
    @Test func defaultSnapshotSymphonyIO() {
        let snap = MeterDefaults.snapshot(inputChannels: 16, outputChannels: 16, mixOutputChannels: 2)
        #expect(snap.inputs.channels.count == 16)
        #expect(snap.playback.channels.count == 16)
        #expect(snap.mixOutput.channels.count == 2)
    }

    // MARK: - MeterConfiguration

    @Test func configurationDefaults() {
        let config = MeterConfiguration()
        #expect(config.followsSelection == true)
        #expect(config.isEnabled == true)
        #expect(config.isMinimal == false)
    }

    // MARK: - Value Conversion

    @Test func uint8ToLinearConversion() {
        #expect(MeterValueConversion.uint8ToLinear(0) == 0.0)
        #expect(MeterValueConversion.uint8ToLinear(255) == 1.0)
        #expect(abs(MeterValueConversion.uint8ToLinear(128) - 0.502) < 0.01)
    }

    @Test func linearToUInt8Conversion() {
        #expect(MeterValueConversion.linearToUInt8(0.0) == 0)
        #expect(MeterValueConversion.linearToUInt8(1.0) == 255)
        #expect(MeterValueConversion.linearToUInt8(0.5) == 127)
    }

    @Test func uint8ConversionRoundTrip() {
        for v: UInt8 in [0, 1, 64, 127, 128, 200, 255] {
            let linear = MeterValueConversion.uint8ToLinear(v)
            let back = MeterValueConversion.linearToUInt8(linear)
            #expect(abs(Int(back) - Int(v)) <= 1, "Round-trip failed for \(v)")
        }
    }

    /// Evidence: mAEstro.h line 129-140 — bitmask with overs LSb=ch0
    @Test func overBitmaskExtraction() {
        let bitmask: UInt32 = 0b0000_0101 // ch0 and ch2 are over
        #expect(MeterValueConversion.isOver(bitmask: bitmask, channel: 0) == true)
        #expect(MeterValueConversion.isOver(bitmask: bitmask, channel: 1) == false)
        #expect(MeterValueConversion.isOver(bitmask: bitmask, channel: 2) == true)
        #expect(MeterValueConversion.isOver(bitmask: bitmask, channel: 3) == false)
    }

    @Test func overWordIndex() {
        #expect(MeterValueConversion.overWordIndex(for: 0) == 0)
        #expect(MeterValueConversion.overWordIndex(for: 31) == 0)
        #expect(MeterValueConversion.overWordIndex(for: 32) == 1)
        #expect(MeterValueConversion.overWordIndex(for: 33) == 1)
    }

    // MARK: - P3F-30: Meter Data Parsing Tests

    /// Verify UInt8 value 0 maps to silence.
    @Test func uint8ZeroIsSilence() {
        let linear = MeterValueConversion.uint8ToLinear(0)
        #expect(linear == 0.0)
    }

    /// Verify UInt8 value 255 maps to full scale (0 dBFS).
    @Test func uint8MaxIsFullScale() {
        let linear = MeterValueConversion.uint8ToLinear(255)
        #expect(linear == 1.0)
        // In dBFS: 20 * log10(1.0) == 0 dBFS
        let dbfs = 20.0 * log10(Double(linear))
        #expect(abs(dbfs - 0.0) < 0.001)
    }

    /// Verify mid-range UInt8 value converts to expected dBFS.
    @Test func uint8MidRangeToDBFS() {
        // Value 128 / 255 ≈ 0.502, 20*log10(0.502) ≈ -5.99 dBFS
        let linear = MeterValueConversion.uint8ToLinear(128)
        let dbfs = 20.0 * log10(Double(linear))
        #expect(abs(dbfs - (-5.99)) < 0.1)
    }

    /// Verify low UInt8 value maps to expected low dBFS.
    @Test func uint8LowValueToDBFS() {
        // Value 1 / 255 ≈ 0.00392, 20*log10(0.00392) ≈ -48.1 dBFS
        let linear = MeterValueConversion.uint8ToLinear(1)
        let dbfs = 20.0 * log10(Double(linear))
        #expect(dbfs < -40.0)
    }

}
