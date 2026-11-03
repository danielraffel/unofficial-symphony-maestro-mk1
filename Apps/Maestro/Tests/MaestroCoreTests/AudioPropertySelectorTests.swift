import Testing
@testable import MaestroCore

/// Tests derived from known four-char codes in:
/// - `og_source/generic/CoreAudio/mAEstro.h`
/// - `og_source/generic/CoreAudio/ApogeeCustomProperties.h`

@Suite("AudioPropertySelector")
struct AudioPropertySelectorTests {

    // MARK: - FourCC encoding

    @Test func fourCCEncodingMicGain() {
        // 'AEmg' = 0x41456D67
        let selector = AudioPropertySelector.micGain
        #expect(selector.rawValue == 0x4145_6D67)
    }

    @Test func fourCCEncodingRoute() {
        // 'AErt' = 0x41457274
        let selector = AudioPropertySelector.route
        #expect(selector.rawValue == 0x4145_7274)
    }

    @Test func fourCCEncodingVersion() {
        // 'AEve' = 0x41457665
        let selector = AudioPropertySelector.version
        #expect(selector.rawValue == 0x4145_7665)
    }

    @Test func fourCCEncodingClockSource() {
        // 'AEck': A=0x41 E=0x45 c=0x63 k=0x6B
        let selector = AudioPropertySelector.clockSource
        #expect(selector.rawValue == 0x4145_636B)
    }

    @Test func fourCCEncodingMixerID() {
        // 'AEMI' = 0x41454D49
        let selector = AudioPropertySelector.mixerID
        #expect(selector.rawValue == 0x4145_4D49)
    }

    // MARK: - Legacy four-char code cross-references

    /// Verify selectors match their legacy `kmAEstroProperty*` four-char codes.
    /// These values can be computed from the C enum: 'AExx' → big-endian UInt32.

    @Test func phantomMatchesLegacyFourCC() {
        // kmAEstroPropertyPhantom = 'AEph'
        #expect(AudioPropertySelector.phantom == AudioPropertySelector("AEph"))
    }

    @Test func phaseReverseMatchesLegacyFourCC() {
        // kmAEstroPropertyPhaseReverse = 'AEre'
        #expect(AudioPropertySelector.phaseReverse == AudioPropertySelector("AEre"))
    }

    @Test func analogIOTypeMatchesLegacyFourCC() {
        // kmAEstroPropertyAnalogIOType = 'AErl'
        #expect(AudioPropertySelector.analogIOType == AudioPropertySelector("AErl"))
    }

    @Test func streamMeterMatchesLegacyFourCC() {
        // kMaestroPropertymAEstroStreamMeter = 'AEsm'
        #expect(AudioPropertySelector.streamMeter == AudioPropertySelector("AEsm"))
    }

    @Test func routingMatchesLegacyFourCC() {
        // kMaestroPropertyRouting = 'AEsA'
        #expect(AudioPropertySelector.routing == AudioPropertySelector("AEsA"))
    }

    @Test func spdifReplaceMatchesLegacyFourCC() {
        // kMaestroPropertySPDIFReplaceID = 'AEs0'
        #expect(AudioPropertySelector.spdifReplaceID == AudioPropertySelector("AEs0"))
    }

    // MARK: - Equatable / Hashable

    @Test func selectorsAreEquatable() {
        #expect(AudioPropertySelector.micGain == AudioPropertySelector("AEmg"))
        #expect(AudioPropertySelector.micGain != AudioPropertySelector.phantom)
    }

    @Test func selectorsAreHashable() {
        let set: Set<AudioPropertySelector> = [.micGain, .phantom, .micGain]
        #expect(set.count == 2)
    }

    // MARK: - Description

    @Test func descriptionShowsFourCC() {
        #expect(AudioPropertySelector.micGain.description == "'AEmg'")
        #expect(AudioPropertySelector.version.description == "'AEve'")
        #expect(AudioPropertySelector.mixerID.description == "'AEMI'")
    }

    // MARK: - Coverage of all Symphony IO USB direct-use selectors

    /// Context builder identified these as directly used in Symphony IO USB controllers.
    @Test func allDirectUseSelectorsExist() {
        // From SymphonyIOBoard_MicPre8ch.cpp
        _ = AudioPropertySelector.micGain
        _ = AudioPropertySelector.analogIOType
        _ = AudioPropertySelector.analogIOTypeIDs
        _ = AudioPropertySelector.analogIOTypeNameForID
        _ = AudioPropertySelector.phantom
        _ = AudioPropertySelector.phaseReverse
        _ = AudioPropertySelector.highPassFilter
        _ = AudioPropertySelector.gainRange
        _ = AudioPropertySelector.insertID
        _ = AudioPropertySelector.insertIDs
        _ = AudioPropertySelector.insertNameForID
        _ = AudioPropertySelector.insertEnableForID
        _ = AudioPropertySelector.insertReturnEnable
        _ = AudioPropertySelector.groupID
        _ = AudioPropertySelector.groupIDs
        _ = AudioPropertySelector.groupNameForID

        // From SymphonyIO_Stream.cpp
        _ = AudioPropertySelector.version
        _ = AudioPropertySelector.route
        _ = AudioPropertySelector.streamMeter

        // From SymphonyIOBoard_2x6.cpp
        _ = AudioPropertySelector.spdifReplaceID
        _ = AudioPropertySelector.spdifMirrorID
        _ = AudioPropertySelector.metersShowNameForID

        // From SymphonyIOUSBAudioRoutingController.cpp
        _ = AudioPropertySelector.routing
    }

    // MARK: - New selectors for monitor/headphone/system controls

    @Test func outputDimMatchesFourCC() {
        #expect(AudioPropertySelector.outputDim == AudioPropertySelector("AEm4"))
    }

    @Test func outputSumToMonoMatchesFourCC() {
        #expect(AudioPropertySelector.outputSumToMono == AudioPropertySelector("AEm5"))
    }

    @Test func headphone1LevelMatchesFourCC() {
        #expect(AudioPropertySelector.headphone1Level == AudioPropertySelector("AEl1"))
    }

    @Test func headphone2LevelMatchesFourCC() {
        #expect(AudioPropertySelector.headphone2Level == AudioPropertySelector("AEl2"))
    }

    @Test func headphoneMuteMatchesFourCC() {
        // Fixed 2026-02-19: 'AEhm'/'AEhn' were custom USB-opcode selectors that don't
        // exist in the daemon. Correct selectors from og_source/maestrolink/Software/mAEstro.h:995-996
        #expect(AudioPropertySelector.headphone1Mute == AudioPropertySelector("AEm1"))
        #expect(AudioPropertySelector.headphone2Mute == AudioPropertySelector("AEm2"))
    }

    @Test func headphoneDimMatchesFourCC() {
        #expect(AudioPropertySelector.headphone1Dim == AudioPropertySelector("AEhd"))
        #expect(AudioPropertySelector.headphone2Dim == AudioPropertySelector("AEhe"))
    }

    @Test func headphoneSumToMonoMatchesFourCC() {
        #expect(AudioPropertySelector.headphone1SumToMono == AudioPropertySelector("AEhs"))
        #expect(AudioPropertySelector.headphone2SumToMono == AudioPropertySelector("AEht"))
    }

    @Test func headphoneRoutingIDMatchesFourCC() {
        // headphone1Source/headphone2Source removed — 'AEha'/'AEhb' are USB-opcode selectors
        // that don't exist in the daemon. Use headphone1RoutingID/headphone2RoutingID instead.
        // Evidence: probe 2026-02-19 — 'AEha'/'AEhb' return 'who?'; 'AEsB'/'AEsE' respond.
        #expect(AudioPropertySelector.headphone1RoutingID == AudioPropertySelector("AEsB"))
        #expect(AudioPropertySelector.headphone2RoutingID == AudioPropertySelector("AEsE"))
    }

    @Test func activeSpeakerSetMatchesFourCC() {
        #expect(AudioPropertySelector.activeSpeakerSet == AudioPropertySelector("AEas"))
    }

    @Test func frontPanelMeterBankMatchesFourCC() {
        #expect(AudioPropertySelector.frontPanelMeterBank == AudioPropertySelector("AEfm"))
    }

    @Test func deviceModeMatchesFourCC() {
        #expect(AudioPropertySelector.deviceMode == AudioPropertySelector("AEdm"))
    }

    @Test func opticalInFormatMatchesFourCC() {
        #expect(AudioPropertySelector.opticalInFormat == AudioPropertySelector("AEoi"))
    }

    @Test func wordClockDivideMatchesFourCC() {
        #expect(AudioPropertySelector.wordClockDivide == AudioPropertySelector("AEwd"))
    }

    @Test func headphoneRoutingMatchesFourCC() {
        #expect(AudioPropertySelector.headphone1RoutingID == AudioPropertySelector("AEsB"))
        #expect(AudioPropertySelector.headphone2RoutingID == AudioPropertySelector("AEsE"))
    }

    @Test func trimMatchesFourCC() {
        // Evidence: AudioPropertySelector.swift — .trim = "AEtr" (0x41457472)
        // Maps to per-channel output calibration trim (±2 dB on Symphony IO MKI).
        #expect(AudioPropertySelector.trim == AudioPropertySelector("AEtr"))
    }

    @Test func trimRangeMatchesFourCC() {
        // Evidence: AudioPropertySelector.swift — .trimRange = "AEtv" (0x41457476)
        // Returns AudioValueRange with mMinimum/mMaximum for the trim property.
        #expect(AudioPropertySelector.trimRange == AudioPropertySelector("AEtv"))
    }

    @Test func allNewMonitorSelectorsAreDistinct() {
        let selectors: [AudioPropertySelector] = [
            .outputDim, .outputSumToMono,
            .headphone1Level, .headphone2Level,
            .headphone1Mute, .headphone2Mute,
            .headphone1Dim, .headphone2Dim,
            .headphone1SumToMono, .headphone2SumToMono,
            .headphone1RoutingID, .headphone2RoutingID,
            .activeSpeakerSet, .frontPanelMeterBank,
            .deviceMode, .opticalInFormat, .wordClockDivide,
            .trim, .trimRange,
        ]
        let set = Set(selectors)
        #expect(set.count == selectors.count, "All new selectors must have unique fourCC codes")
    }
}
