import Testing
@testable import MaestroCore

/// Tests for the mixer domain model.
///
/// Evidence sources:
/// - `og_source/generic/CoreAudio/mAEstro.h` (MaestroMixerChannelBitMask)
/// - `og_source/maestrolink/Software/SymphonyIO/SymphonyIOVendorSpecific.h`
/// - `og_source/maestrolink/Software/SymphonyIO/SymphonyIOControl.cpp`
/// - `og_source/maestro2/App/Model/APAudioMixerChannelModel.h`

@Suite("MixerModel")
struct MixerModelTests {

    // MARK: - MixerElementID

    @Test func elementIDInputChannel() {
        let id = MixerElementID.inputChannel(mixer: 0, channel: 5)
        #expect(id.mixerIndex == 0)
        #expect(id.channelIndex == 5)
        #expect(id.isSoftwareReturn == false)
        #expect(id.isMasterOutput == false)
    }

    @Test func elementIDInputChannelMixer2() {
        let id = MixerElementID.inputChannel(mixer: 2, channel: 31)
        #expect(id.mixerIndex == 2)
        #expect(id.channelIndex == 31)
        #expect(id.rawValue == (2 << 16) | 31)
    }

    @Test func elementIDSoftwareReturn() {
        let id = MixerElementID.softwareReturn(mixer: 1)
        #expect(id.mixerIndex == 1)
        #expect(id.isSoftwareReturn == true)
        #expect(id.isMasterOutput == false)
        #expect(id.rawValue == (1 << 16) | 0x01000)
    }

    @Test func elementIDMasterOutput() {
        let id = MixerElementID.masterOutput(mixer: 3)
        #expect(id.mixerIndex == 3)
        #expect(id.isMasterOutput == true)
        #expect(id.isSoftwareReturn == false)
        #expect(id.rawValue == (3 << 16) | 0x02000)
    }

    @Test func elementIDEquatableHashable() {
        let a = MixerElementID.inputChannel(mixer: 0, channel: 5)
        let b = MixerElementID.inputChannel(mixer: 0, channel: 5)
        let c = MixerElementID.inputChannel(mixer: 1, channel: 5)
        #expect(a == b)
        #expect(a != c)
        let set: Set<MixerElementID> = [a, b, c]
        #expect(set.count == 2)
    }

    /// Verify bitmask values match the legacy C enum.
    /// Evidence: mAEstro.h lines 595-602
    @Test func elementIDBitmaskMatchesLegacy() {
        // eMaestroMixerChannelBitMask_SoftwareReturn = 0x01000
        let sr = MixerElementID(rawValue: 0x01000)
        #expect(sr.isSoftwareReturn == true)
        #expect(sr.isMasterOutput == false)

        // eMaestroMixerChannelBitMask_MasterOutput = 0x02000
        let master = MixerElementID(rawValue: 0x02000)
        #expect(master.isMasterOutput == true)
        #expect(master.isSoftwareReturn == false)

        // eMaestroMixerChannelBitMask_MixerIndex = 0xF0000
        let mixer3 = MixerElementID(rawValue: 0x30000 | 7) // mixer 3, channel 7
        #expect(mixer3.mixerIndex == 3)
        #expect(mixer3.channelIndex == 7)
    }

    // MARK: - MixerChannel

    @Test func channelDefaultValues() {
        let ch = MixerChannel()
        #expect(ch.level == MixerConstants.levelMinimum)
        #expect(ch.pan == 0.0)
        #expect(ch.isMuted == false)
        #expect(ch.isSoloed == false)
        #expect(ch.label == "")
    }

    @Test func channelCustomValues() {
        let ch = MixerChannel(level: -12.0, pan: -0.5, isMuted: true, isSoloed: false, label: "Vocal")
        #expect(ch.level == -12.0)
        #expect(ch.pan == -0.5)
        #expect(ch.isMuted == true)
        #expect(ch.label == "Vocal")
    }

    // MARK: - Mixer

    @Test func mixerDefaultFactory() {
        let m = MixerDefaults.mixer(index: 0, inputChannelCount: 32)
        #expect(m.index == 0)
        #expect(m.inputChannels.count == 32)
        #expect(m.inputChannels[0].label == "In 1")
        #expect(m.inputChannels[31].label == "In 32")
        #expect(m.softwareReturn.label == "SW Return")
        #expect(m.master.label == "Master")
        #expect(m.master.level == 0.0) // Master starts at 0 dB (unity)
    }

    @Test func mixerInputChannelsAtMinLevel() {
        let m = MixerDefaults.mixer(index: 0)
        for ch in m.inputChannels {
            #expect(ch.level == MixerConstants.levelMinimum)
            #expect(ch.pan == 0.0) // center
        }
    }

    // MARK: - MixerBank

    @Test func bankDefault4Mixers() {
        let bank = MixerDefaults.bank(mixerCount: 4)
        #expect(bank.mixers.count == 4)
        #expect(bank.mixers[0].index == 0)
        #expect(bank.mixers[3].index == 3)
        #expect(bank.mixers[0].inputChannels.count == MixerConstants.inputChannelCount)
    }

    @Test func bankLookupByIndex() {
        let bank = MixerDefaults.bank(mixerCount: 4)
        #expect(bank.mixer(at: 2)?.index == 2)
        #expect(bank.mixer(at: 5) == nil)
    }

    @Test func bankEquatable() {
        let a = MixerDefaults.bank(mixerCount: 2)
        let b = MixerDefaults.bank(mixerCount: 2)
        #expect(a == b)
    }

    // MARK: - MixerConstants

    @Test func constantsMatchLegacy() {
        // kSymphonyIOMixer_NumberOfMixers = 4
        #expect(MixerConstants.maxMixerCount == 4)
        // kSymphonyIOMixer_InputChanelCount = 33 (legacy includes SW return; we separate it)
        #expect(MixerConstants.inputChannelCount == 32)
        // kSymphonyIOMixer_FaderCount = 34
        #expect(MixerConstants.faderCount == 34)
        // kSymphonyIOMixer_FaderIndexSoftwareReturn = 32
        #expect(MixerConstants.faderIndexSoftwareReturn == 32)
        // kSymphonyIOMixer_FaderIndexMasterOut = 33
        #expect(MixerConstants.faderIndexMasterOut == 33)
        // kSymphonyIOMixer_ScaledFaderSettingZeroOffset = 48
        #expect(MixerConstants.scaledFaderZeroOffset == 48)
        // kSymphonyIOMixer_ScaledPanSettingZeroOffset = 64
        #expect(MixerConstants.scaledPanZeroOffset == 64)
    }

    // MARK: - Value Conversion

    /// Evidence: SymphonyIOControl.cpp line 1910
    /// `fpScaledValue = fpLevel + kSymphonyIOMixer_ScaledFaderSettingZeroOffset`
    @Test func levelToScaledConversion() {
        #expect(MixerValueConversion.levelToScaled(-48.0) == 0)
        #expect(MixerValueConversion.levelToScaled(0.0) == 48)
        #expect(MixerValueConversion.levelToScaled(6.0) == 54)
    }

    /// Evidence: SymphonyIOControl.cpp line 1990
    /// `fpLevel = cLevel - kSymphonyIOMixer_ScaledFaderSettingZeroOffset`
    @Test func scaledToLevelConversion() {
        #expect(MixerValueConversion.scaledToLevel(0) == -48.0)
        #expect(MixerValueConversion.scaledToLevel(48) == 0.0)
        #expect(MixerValueConversion.scaledToLevel(54) == 6.0)
    }

    /// Evidence: SymphonyIOControl.cpp line 1930
    /// `fpScaledValue = (fpPan * 64) + kSymphonyIOMixer_ScaledPanSettingZeroOffset`
    @Test func panToScaledConversion() {
        #expect(MixerValueConversion.panToScaled(-1.0) == 0)
        #expect(MixerValueConversion.panToScaled(0.0) == 64)
        #expect(MixerValueConversion.panToScaled(1.0) == 128)
    }

    /// Evidence: SymphonyIOControl.cpp line 2011
    /// `fpPan = cLevel - kSymphonyIOMixer_ScaledPanSettingZeroOffset`
    @Test func scaledToPanConversion() {
        #expect(MixerValueConversion.scaledToPan(0) == -1.0)
        #expect(MixerValueConversion.scaledToPan(64) == 0.0)
        #expect(MixerValueConversion.scaledToPan(128) == 1.0)
    }

    @Test func panConversionRoundTrip() {
        for pan in stride(from: -1.0, through: 1.0, by: 0.25) {
            let scaled = MixerValueConversion.panToScaled(pan)
            let back = MixerValueConversion.scaledToPan(scaled)
            #expect(abs(back - pan) < 0.02, "Round-trip failed for pan \(pan)")
        }
    }

    @Test func levelConversionRoundTrip() {
        for level in stride(from: -48.0, through: 6.0, by: 6.0) {
            let scaled = MixerValueConversion.levelToScaled(level)
            let back = MixerValueConversion.scaledToLevel(scaled)
            #expect(back == level, "Round-trip failed for level \(level)")
        }
    }

    // MARK: - Channel Level Range

    /// Evidence: SymphonyIOVendorSpecific.h — mixer fader range is -48 (min) to +6 (max).
    @Test func channelLevelRangeConstants() {
        #expect(MixerConstants.levelMinimum == -48.0)
        #expect(MixerConstants.levelMaximum == 6.0)
        #expect(MixerConstants.levelMinimum < MixerConstants.levelMaximum)
    }

    /// Verify default channel level is at minimum (silence).
    @Test func channelDefaultLevelIsMinimum() {
        let ch = MixerChannel()
        #expect(ch.level == MixerConstants.levelMinimum)
        #expect(ch.level == -48.0)
    }

    /// Verify channel level can be set within the valid range.
    @Test func channelLevelWithinRange() {
        let range = MixerConstants.levelMinimum...MixerConstants.levelMaximum
        let ch = MixerChannel(level: -12.0)
        #expect(range.contains(ch.level))
    }

    /// Verify channel level at extremes of the range.
    @Test func channelLevelAtExtremes() {
        let atMin = MixerChannel(level: MixerConstants.levelMinimum)
        #expect(atMin.level == -48.0)

        let atMax = MixerChannel(level: MixerConstants.levelMaximum)
        #expect(atMax.level == 6.0)
    }

    /// Verify that levels outside the documented range can be detected.
    @Test func channelLevelOutOfRangeDetection() {
        let range = MixerConstants.levelMinimum...MixerConstants.levelMaximum
        let chBelow = MixerChannel(level: -100.0)
        #expect(!range.contains(chBelow.level))

        let chAbove = MixerChannel(level: 20.0)
        #expect(!range.contains(chAbove.level))
    }

    /// Verify level clamping arithmetic for mixer channels.
    @Test func channelLevelClampingMath() {
        let range = MixerConstants.levelMinimum...MixerConstants.levelMaximum
        // Clamp too-low value
        let clampedLow = min(max(-100.0, range.lowerBound), range.upperBound)
        #expect(clampedLow == -48.0)

        // Clamp too-high value
        let clampedHigh = min(max(20.0, range.lowerBound), range.upperBound)
        #expect(clampedHigh == 6.0)

        // Value within range stays unchanged
        let withinRange = min(max(-12.0, range.lowerBound), range.upperBound)
        #expect(withinRange == -12.0)
    }

    // MARK: - Pan Defaults and Range

    /// Evidence: APAudioMixerChannelModel.h — pan default is 0.0 (center).
    @Test func channelPanDefaultIsCenter() {
        let ch = MixerChannel()
        #expect(ch.pan == 0.0)
    }

    /// Verify pan at full left and full right.
    @Test func channelPanExtremes() {
        let left = MixerChannel(pan: -1.0)
        #expect(left.pan == -1.0)

        let right = MixerChannel(pan: 1.0)
        #expect(right.pan == 1.0)
    }

    /// Verify pan clamping arithmetic: values outside -1..1 can be clamped.
    @Test func channelPanClampingMath() {
        let panRange: ClosedRange<Float64> = -1.0...1.0

        // Pan below -1 should clamp to -1
        let clampedLeft = min(max(-2.5, panRange.lowerBound), panRange.upperBound)
        #expect(clampedLeft == -1.0)

        // Pan above +1 should clamp to +1
        let clampedRight = min(max(3.0, panRange.lowerBound), panRange.upperBound)
        #expect(clampedRight == 1.0)

        // Pan within range stays unchanged
        let withinRange = min(max(0.5, panRange.lowerBound), panRange.upperBound)
        #expect(withinRange == 0.5)

        // Center stays at 0
        let center = min(max(0.0, panRange.lowerBound), panRange.upperBound)
        #expect(center == 0.0)
    }

    /// Verify that out-of-range pan values can be detected.
    @Test func channelPanOutOfRangeDetection() {
        let panRange: ClosedRange<Float64> = -1.0...1.0
        #expect(!panRange.contains(-1.5))
        #expect(!panRange.contains(1.5))
        #expect(panRange.contains(-1.0))
        #expect(panRange.contains(0.0))
        #expect(panRange.contains(1.0))
    }

    // MARK: - Mixer Channel Defaults in Context

    /// Verify all default mixer input channels have center pan and minimum level.
    @Test func allDefaultInputChannelsHaveCenterPanAndMinLevel() {
        let m = MixerDefaults.mixer(index: 0, inputChannelCount: 32)
        for (i, ch) in m.inputChannels.enumerated() {
            #expect(ch.pan == 0.0, "Channel \(i) should have center pan")
            #expect(ch.level == MixerConstants.levelMinimum, "Channel \(i) should be at minimum level")
            #expect(ch.isMuted == false, "Channel \(i) should not be muted")
            #expect(ch.isSoloed == false, "Channel \(i) should not be soloed")
        }
    }

    /// Verify software return defaults.
    @Test func softwareReturnDefaults() {
        let m = MixerDefaults.mixer(index: 0)
        #expect(m.softwareReturn.level == MixerConstants.levelMinimum)
        #expect(m.softwareReturn.pan == 0.0)
        #expect(m.softwareReturn.isMuted == false)
        #expect(m.softwareReturn.isSoloed == false)
        #expect(m.softwareReturn.label == "SW Return")
    }

    /// Verify master output defaults to unity (0 dB) with center pan.
    @Test func masterOutputDefaults() {
        let m = MixerDefaults.mixer(index: 0)
        #expect(m.master.level == 0.0)
        #expect(m.master.pan == 0.0)
        #expect(m.master.isMuted == false)
        #expect(m.master.isSoloed == false)
        #expect(m.master.label == "Master")
    }

    /// Verify level scaling matches pan range mapping.
    /// Level -48..+6 maps to scaled 0..54 (54 steps).
    /// Pan -1..+1 maps to scaled 0..128 (128 steps).
    @Test func scaledRangeSpans() {
        let levelMin = MixerValueConversion.levelToScaled(MixerConstants.levelMinimum)
        let levelMax = MixerValueConversion.levelToScaled(MixerConstants.levelMaximum)
        #expect(levelMin == 0)
        #expect(levelMax == 54)

        let panMin = MixerValueConversion.panToScaled(-1.0)
        let panMax = MixerValueConversion.panToScaled(1.0)
        #expect(panMin == 0)
        #expect(panMax == 128)
    }

    /// Verify pan conversion at center (0.0 -> 64).
    @Test func panScaledAtCenter() {
        #expect(MixerValueConversion.panToScaled(0.0) == MixerConstants.scaledPanZeroOffset)
        #expect(MixerValueConversion.scaledToPan(MixerConstants.scaledPanZeroOffset) == 0.0)
    }

    /// Verify level conversion at unity (0.0 dB -> 48).
    @Test func levelScaledAtUnity() {
        #expect(MixerValueConversion.levelToScaled(0.0) == MixerConstants.scaledFaderZeroOffset)
        #expect(MixerValueConversion.scaledToLevel(MixerConstants.scaledFaderZeroOffset) == 0.0)
    }

    // MARK: - Batch Operation Pure-Function Tests

    /// Helper: apply batch mute to channels. Replicates MixerView.batchToggleMute logic.
    private static func batchMute(_ channels: inout [(level: Double, pan: Double, isMuted: Bool, isSoloed: Bool)],
                                  targets: Set<Int>, newValue: Bool) {
        for i in targets {
            guard i < channels.count else { continue }
            channels[i].isMuted = newValue
        }
    }

    /// Helper: apply batch level delta. Replicates MixerView.batchApplyLevelDelta logic.
    private static func batchLevelDelta(_ channels: inout [(level: Double, pan: Double, isMuted: Bool, isSoloed: Bool)],
                                        startLevels: [Int: Double], delta: Double) {
        for (i, startLevel) in startLevels {
            guard i < channels.count else { continue }
            channels[i].level = min(max(startLevel + delta, MixerConstants.levelMinimum), MixerConstants.levelMaximum)
        }
    }

    /// Helper: apply batch pan delta. Replicates MixerView.batchApplyPanDelta logic.
    private static func batchPanDelta(_ channels: inout [(level: Double, pan: Double, isMuted: Bool, isSoloed: Bool)],
                                      startPans: [Int: Double], delta: Double) {
        for (i, startPan) in startPans {
            guard i < channels.count else { continue }
            channels[i].pan = min(max(startPan + delta, -1.0), 1.0)
        }
    }

    /// Helper: apply solo state to all channels. Replicates MixerView.batchApplySolo logic.
    private static func batchApplySolo(_ channels: inout [(level: Double, pan: Double, isMuted: Bool, isSoloed: Bool)], newValue: Bool) {
        for i in 0..<channels.count {
            channels[i].isSoloed = newValue
        }
    }

    @Test func batchMuteAllChannels() {
        var channels = (0..<16).map { _ in (level: -6.0, pan: 0.0, isMuted: false, isSoloed: false) }
        let allTargets = Set(0..<16)
        Self.batchMute(&channels, targets: allTargets, newValue: true)
        for ch in channels {
            #expect(ch.isMuted == true)
        }
    }

    @Test func batchMuteSelectedOnly() {
        var channels = (0..<16).map { _ in (level: -6.0, pan: 0.0, isMuted: false, isSoloed: false) }
        let selected: Set<Int> = [2, 5, 9]
        Self.batchMute(&channels, targets: selected, newValue: true)
        for i in 0..<16 {
            if selected.contains(i) {
                #expect(channels[i].isMuted == true, "Channel \(i) should be muted")
            } else {
                #expect(channels[i].isMuted == false, "Channel \(i) should NOT be muted")
            }
        }
    }

    @Test func batchApplySoloSetAll() {
        var channels = (0..<16).map { _ in (level: -6.0, pan: 0.0, isMuted: false, isSoloed: false) }
        channels[3].isSoloed = true
        // Option+click solo ON → all channels get soloed
        Self.batchApplySolo(&channels, newValue: true)
        for ch in channels {
            #expect(ch.isSoloed == true)
        }
    }

    @Test func batchApplySoloClearAll() {
        var channels = (0..<16).map { _ in (level: -6.0, pan: 0.0, isMuted: false, isSoloed: true) }
        channels[3].isSoloed = false
        // Option+click solo OFF → all channels get un-soloed
        Self.batchApplySolo(&channels, newValue: false)
        for ch in channels {
            #expect(ch.isSoloed == false)
        }
    }

    @Test func batchLevelDeltaPreservesRelative() {
        var channels = [
            (level: -6.0, pan: 0.0, isMuted: false, isSoloed: false),
            (level: -12.0, pan: 0.0, isMuted: false, isSoloed: false),
            (level: -24.0, pan: 0.0, isMuted: false, isSoloed: false),
        ]
        let startLevels: [Int: Double] = [0: -6.0, 1: -12.0, 2: -24.0]
        Self.batchLevelDelta(&channels, startLevels: startLevels, delta: 3.0)
        #expect(channels[0].level == -3.0)
        #expect(channels[1].level == -9.0)
        #expect(channels[2].level == -21.0)
    }

    @Test func batchLevelDeltaClampsAtRange() {
        var channels = [
            (level: -1.0, pan: 0.0, isMuted: false, isSoloed: false),
        ]
        let startLevels: [Int: Double] = [0: -1.0]
        Self.batchLevelDelta(&channels, startLevels: startLevels, delta: 15.0)
        // Clamped to MixerConstants.levelMaximum (6.0)
        #expect(channels[0].level == MixerConstants.levelMaximum)
    }

    @Test func batchPanDeltaClampsAtRange() {
        var channels = [
            (level: 0.0, pan: 0.9, isMuted: false, isSoloed: false),
        ]
        let startPans: [Int: Double] = [0: 0.9]
        Self.batchPanDelta(&channels, startPans: startPans, delta: 0.5)
        #expect(channels[0].pan == 1.0)
    }

    /// Verify MixerChannel preserves all fields through copy (value-type semantics).
    @Test func mixerChannelValueSemantics() {
        let original = MixerChannel(level: -12.5, pan: 0.3, isMuted: true, isSoloed: false, label: "Guitar")
        var copy = original
        copy.level = -6.0
        copy.isMuted = false
        // Original unchanged (value type)
        #expect(original.level == -12.5)
        #expect(original.isMuted == true)
        // Copy has new values
        #expect(copy.level == -6.0)
        #expect(copy.isMuted == false)
        // Unchanged fields preserved
        #expect(copy.pan == 0.3)
        #expect(copy.label == "Guitar")
    }
}
