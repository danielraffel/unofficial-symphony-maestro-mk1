import Testing
@testable import MaestroCore

/// Tests for the device settings domain model.
///
/// Evidence sources:
/// - `og_source/maestro2/App/Model/APAudioDeviceModel.h`
/// - `og_source/maestro2/App/Resources/deviceDescriptions.plist`

@Suite("DeviceSettings")
struct DeviceSettingsTests {

    // MARK: - OutputControl

    @Test func outputControlDefaults() {
        let oc = OutputControl()
        #expect(oc.level == 0.0)
        #expect(oc.isMuted == false)
        #expect(oc.isDimmed == false)
        #expect(oc.isSummed == false)
    }

    @Test func outputControlCustomValues() {
        let oc = OutputControl(level: -20.0, isMuted: true, isDimmed: true, isSummed: true)
        #expect(oc.level == -20.0)
        #expect(oc.isMuted == true)
        #expect(oc.isDimmed == true)
        #expect(oc.isSummed == true)
    }

    @Test func outputControlEquatable() {
        let a = OutputControl(level: -10.0, isMuted: false)
        let b = OutputControl(level: -10.0, isMuted: false)
        let c = OutputControl(level: -10.0, isMuted: true)
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - OpticalFormat

    @Test func opticalFormatCaseIterable() {
        let formats = OpticalFormat.allCases
        #expect(formats.count == 3)
        #expect(formats.contains(.spdif))
        #expect(formats.contains(.adat))
        #expect(formats.contains(.off))
    }

    @Test func opticalFormatRawValues() {
        #expect(OpticalFormat.spdif.rawValue == "S/PDIF")
        #expect(OpticalFormat.adat.rawValue == "ADAT")
        #expect(OpticalFormat.off.rawValue == "Off")
    }

    // MARK: - SPDIFConfig

    @Test func spdifConfigDefaults() {
        let config = SPDIFConfig()
        #expect(config.replaceID == nil)
        #expect(config.mirrorID == nil)
    }

    @Test func spdifConfigCustomValues() {
        let config = SPDIFConfig(replaceID: 3, mirrorID: 5)
        #expect(config.replaceID == 3)
        #expect(config.mirrorID == 5)
    }

    @Test func spdifConfigEquatable() {
        let a = SPDIFConfig(replaceID: 1, mirrorID: 2)
        let b = SPDIFConfig(replaceID: 1, mirrorID: 2)
        let c = SPDIFConfig(replaceID: 1, mirrorID: nil)
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - MeterDisplaySettings

    @Test func meterDisplayDefaults() {
        let mds = MeterDisplaySettings()
        #expect(mds.peakHoldMode == .infinite)
        #expect(mds.oversHoldMode == .infinite)
    }

    /// The wire values ARE the menu order -- legacy binds the popup's
    /// selectedIndex straight to the property, so these cannot be reordered
    /// independently of the picker in SettingsViews. Evidence:
    /// SymphonyIOVendorSpecific.h:698-712, APSystemMetersViewController.m:69-74.
    @Test func peakHoldWireValues() {
        #expect(MeterDisplaySettings.PeakHoldMode.off.wireValue == 0)
        #expect(MeterDisplaySettings.PeakHoldMode.twoSeconds.wireValue == 1)
        #expect(MeterDisplaySettings.PeakHoldMode.infinite.wireValue == 2)
        #expect(MeterDisplaySettings.PeakHoldMode.allCases.count == 3)
    }

    /// Over Hold carries a fourth mode Peak Hold does not. Getting this list
    /// wrong is silent: the menu names one mode and the unit performs another.
    @Test func overHoldWireValues() {
        #expect(MeterDisplaySettings.OverHoldMode.off.wireValue == 0)
        #expect(MeterDisplaySettings.OverHoldMode.twoSeconds.wireValue == 1)
        #expect(MeterDisplaySettings.OverHoldMode.infinite.wireValue == 2)
        #expect(MeterDisplaySettings.OverHoldMode.autoClear.wireValue == 3)
        #expect(MeterDisplaySettings.OverHoldMode.allCases.count == 4)
    }

    /// Both enums are ordered so that allCases index == wireValue. The Settings
    /// picker relies on this, and so did the original.
    @Test func holdModeOrderMatchesWireValue() {
        for (i, m) in MeterDisplaySettings.PeakHoldMode.allCases.enumerated() {
            #expect(m.wireValue == UInt32(i))
        }
        for (i, m) in MeterDisplaySettings.OverHoldMode.allCases.enumerated() {
            #expect(m.wireValue == UInt32(i))
        }
    }

    @Test func meterDisplayEquatable() {
        let a = MeterDisplaySettings(peakHoldMode: .infinite, oversHoldMode: .infinite)
        let b = MeterDisplaySettings(peakHoldMode: .infinite, oversHoldMode: .infinite)
        let c = MeterDisplaySettings(peakHoldMode: .off, oversHoldMode: .infinite)
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - DeviceSettings

    @Test func deviceSettingsDefaults() {
        let ds = DeviceSettings()
        // Output controls default
        #expect(ds.mainOutput.level == 0.0)
        #expect(ds.mainOutput.isMuted == false)
        #expect(ds.headphone1.level == 0.0)
        #expect(ds.headphone2.level == 0.0)
        // Level range
        #expect(ds.outputLevelRange == -64.0...0.0)
        // Digital I/O
        #expect(ds.opticalFormatPort1 == .spdif)
        #expect(ds.opticalFormatPort2 == .spdif)
        #expect(ds.spdifConfig.replaceID == nil)
        #expect(ds.spdifConfig.mirrorID == nil)
        // Headphone routing
        #expect(ds.headphone1RoutingID == 0)
        #expect(ds.headphone2RoutingID == 0)
        // Meter display
        #expect(ds.meterDisplay.peakHoldMode == .infinite)
        #expect(ds.meterDisplay.oversHoldMode == .infinite)
        // Identity
        #expect(ds.namePrefix == "")
        #expect(ds.firmwareVersion == "")
    }

    @Test func deviceSettingsCustomValues() {
        let ds = DeviceSettings(
            mainOutput: OutputControl(level: -12.0, isMuted: false, isDimmed: true, isSummed: false),
            headphone1: OutputControl(level: -6.0),
            headphone2: OutputControl(level: -24.0, isMuted: true),
            outputLevelRange: -96.0...0.0,
            opticalFormatPort1: .adat,
            opticalFormatPort2: .off,
            spdifConfig: SPDIFConfig(replaceID: 2, mirrorID: 4),
            headphone1RoutingID: 1,
            headphone2RoutingID: 3,
            meterDisplay: MeterDisplaySettings(peakHoldMode: .twoSeconds, oversHoldMode: .off),
            namePrefix: "Studio A",
            firmwareVersion: "1.2.3"
        )
        #expect(ds.mainOutput.level == -12.0)
        #expect(ds.mainOutput.isDimmed == true)
        #expect(ds.headphone2.isMuted == true)
        #expect(ds.outputLevelRange == -96.0...0.0)
        #expect(ds.opticalFormatPort1 == .adat)
        #expect(ds.opticalFormatPort2 == .off)
        #expect(ds.spdifConfig.replaceID == 2)
        #expect(ds.headphone1RoutingID == 1)
        #expect(ds.meterDisplay.peakHoldMode == .twoSeconds)
        #expect(ds.namePrefix == "Studio A")
        #expect(ds.firmwareVersion == "1.2.3")
    }

    @Test func deviceSettingsEquatable() {
        let a = DeviceSettings()
        let b = DeviceSettings()
        let c = DeviceSettings(namePrefix: "Different")
        #expect(a == b)
        #expect(a != c)
    }

    /// Evidence: APAudioDeviceModel.h — mainOutLevel, mainOutMute, mainOutDim, mainOutSum
    /// The legacy model has three output pairs: main, headphone1, headphone2.
    @Test func threeOutputPairsMatchLegacy() {
        var ds = DeviceSettings()
        // Mutate each independently
        ds.mainOutput.isMuted = true
        ds.headphone1.isDimmed = true
        ds.headphone2.isSummed = true
        #expect(ds.mainOutput.isMuted == true)
        #expect(ds.mainOutput.isDimmed == false)
        #expect(ds.headphone1.isDimmed == true)
        #expect(ds.headphone1.isMuted == false)
        #expect(ds.headphone2.isSummed == true)
        #expect(ds.headphone2.isMuted == false)
    }

    /// Evidence: APAudioDeviceModel.h — outputLevelRange maps to min/max dB.
    @Test func outputLevelRangeContainsBounds() {
        let ds = DeviceSettings()
        #expect(ds.outputLevelRange.contains(-64.0))
        #expect(ds.outputLevelRange.contains(0.0))
        #expect(!ds.outputLevelRange.contains(-65.0))
        #expect(!ds.outputLevelRange.contains(1.0))
    }

    // MARK: - OutputControl Dim/Sum State Toggling

    /// Evidence: APAudioDeviceModel.h — mainOutDim, mainOutSum toggles.
    /// Verify dim state can be toggled independently from mute and sum.
    @Test func outputControlDimToggle() {
        var oc = OutputControl()
        #expect(oc.isDimmed == false)
        oc.isDimmed = true
        #expect(oc.isDimmed == true)
        #expect(oc.isMuted == false)
        #expect(oc.isSummed == false)
        oc.isDimmed = false
        #expect(oc.isDimmed == false)
    }

    /// Verify sum-to-mono state can be toggled independently.
    @Test func outputControlSumToggle() {
        var oc = OutputControl()
        #expect(oc.isSummed == false)
        oc.isSummed = true
        #expect(oc.isSummed == true)
        #expect(oc.isMuted == false)
        #expect(oc.isDimmed == false)
        oc.isSummed = false
        #expect(oc.isSummed == false)
    }

    /// Verify all three output states (mute, dim, sum) can be independently set.
    @Test func outputControlAllStatesToggledIndependently() {
        var oc = OutputControl()
        oc.isMuted = true
        oc.isDimmed = true
        oc.isSummed = true
        #expect(oc.isMuted == true)
        #expect(oc.isDimmed == true)
        #expect(oc.isSummed == true)

        // Toggle one off, verify others stay on
        oc.isDimmed = false
        #expect(oc.isMuted == true)
        #expect(oc.isDimmed == false)
        #expect(oc.isSummed == true)
    }

    // MARK: - Output Level Range Validation

    /// Evidence: APAudioDeviceModel.h — default output level range is -64..0 dB.
    @Test func defaultOutputLevelRangeIs64to0() {
        let ds = DeviceSettings()
        #expect(ds.outputLevelRange.lowerBound == -64.0)
        #expect(ds.outputLevelRange.upperBound == 0.0)
    }

    /// Verify level clamping logic: levels outside outputLevelRange can be
    /// clamped using Swift's standard ClosedRange.clamped(to:) or manual min/max.
    /// This tests the range itself to ensure it supports clamping correctly.
    @Test func outputLevelClampingToRange() {
        let ds = DeviceSettings()
        let range = ds.outputLevelRange

        // Value within range stays unchanged
        let withinRange = min(max(-32.0, range.lowerBound), range.upperBound)
        #expect(withinRange == -32.0)

        // Value below range clamps to lower bound
        let belowRange = min(max(-100.0, range.lowerBound), range.upperBound)
        #expect(belowRange == -64.0)

        // Value above range clamps to upper bound
        let aboveRange = min(max(10.0, range.lowerBound), range.upperBound)
        #expect(aboveRange == 0.0)

        // Exact boundaries
        let atLower = min(max(-64.0, range.lowerBound), range.upperBound)
        #expect(atLower == -64.0)
        let atUpper = min(max(0.0, range.lowerBound), range.upperBound)
        #expect(atUpper == 0.0)
    }

    /// Verify a custom output level range (e.g., -96..0) works correctly.
    @Test func customOutputLevelRangeClamping() {
        let ds = DeviceSettings(outputLevelRange: -96.0...0.0)
        let range = ds.outputLevelRange
        #expect(range.lowerBound == -96.0)
        #expect(range.upperBound == 0.0)
        #expect(range.contains(-96.0))
        #expect(range.contains(-64.0))
        #expect(range.contains(0.0))
        #expect(!range.contains(-97.0))
    }

    // MARK: - Headphone Level Defaults

    /// Evidence: APAudioDeviceModel.h — headPhone1Level, headPhone2Level default to 0 dB.
    @Test func headphoneLevelDefaults() {
        let ds = DeviceSettings()
        #expect(ds.headphone1.level == 0.0)
        #expect(ds.headphone2.level == 0.0)
        #expect(ds.headphone1.isMuted == false)
        #expect(ds.headphone2.isMuted == false)
        #expect(ds.headphone1.isDimmed == false)
        #expect(ds.headphone2.isDimmed == false)
        #expect(ds.headphone1.isSummed == false)
        #expect(ds.headphone2.isSummed == false)
    }

    /// Verify headphone levels can be set to custom values within range.
    @Test func headphoneCustomLevels() {
        let ds = DeviceSettings(
            headphone1: OutputControl(level: -12.0, isMuted: false, isDimmed: true),
            headphone2: OutputControl(level: -48.0, isMuted: true, isSummed: true)
        )
        #expect(ds.headphone1.level == -12.0)
        #expect(ds.headphone1.isDimmed == true)
        #expect(ds.headphone1.isMuted == false)
        #expect(ds.headphone2.level == -48.0)
        #expect(ds.headphone2.isMuted == true)
        #expect(ds.headphone2.isSummed == true)
    }

    // MARK: - Volume Popup Normalized Level Math

    /// The VolumePopupView (in MaestroApp) normalizes output level to 0..1
    /// using the formula: min(max((level + 64) / 64, 0), 1).
    /// These tests verify that the normalization math is correct for the
    /// default outputLevelRange of -64..0.
    ///
    /// Evidence: MaestroApp VolumePopupView.normalizedLevel
    @Test func normalizedLevelAtMinimum() {
        // Level -64 (lower bound) -> normalized 0.0
        let level: Float64 = -64.0
        let normalized = min(max((level + 64.0) / 64.0, 0.0), 1.0)
        #expect(normalized == 0.0)
    }

    @Test func normalizedLevelAtMaximum() {
        // Level 0 (upper bound) -> normalized 1.0
        let level: Float64 = 0.0
        let normalized = min(max((level + 64.0) / 64.0, 0.0), 1.0)
        #expect(normalized == 1.0)
    }

    @Test func normalizedLevelAtMidpoint() {
        // Level -32 (midpoint) -> normalized 0.5
        let level: Float64 = -32.0
        let normalized = min(max((level + 64.0) / 64.0, 0.0), 1.0)
        #expect(normalized == 0.5)
    }

    @Test func normalizedLevelClampsBelowRange() {
        // Level below -64 should clamp to 0.0
        let level: Float64 = -100.0
        let normalized = min(max((level + 64.0) / 64.0, 0.0), 1.0)
        #expect(normalized == 0.0)
    }

    @Test func normalizedLevelClampsAboveRange() {
        // Level above 0 should clamp to 1.0
        let level: Float64 = 10.0
        let normalized = min(max((level + 64.0) / 64.0, 0.0), 1.0)
        #expect(normalized == 1.0)
    }

    /// Verify normalization across the full range in even steps.
    @Test func normalizedLevelLinearSteps() {
        let ds = DeviceSettings()
        let range = ds.outputLevelRange
        let span = range.upperBound - range.lowerBound  // 64.0

        // Verify several evenly-spaced levels
        let testCases: [(level: Float64, expected: Float64)] = [
            (-64.0, 0.0),
            (-48.0, 0.25),
            (-32.0, 0.5),
            (-16.0, 0.75),
            (0.0,   1.0),
        ]
        for tc in testCases {
            let normalized = (tc.level - range.lowerBound) / span
            #expect(
                abs(normalized - tc.expected) < 0.001,
                "Level \(tc.level) should normalize to \(tc.expected), got \(normalized)"
            )
        }
    }

    // MARK: - OutputControl Level within DeviceSettings Range

    /// Verify that output level values can be checked against the device's outputLevelRange.
    @Test func outputLevelWithinRange() {
        let ds = DeviceSettings()
        #expect(ds.outputLevelRange.contains(ds.mainOutput.level))
        #expect(ds.outputLevelRange.contains(ds.headphone1.level))
        #expect(ds.outputLevelRange.contains(ds.headphone2.level))
    }

    /// Verify that custom output levels can be validated against the range.
    @Test func outputLevelOutOfRangeDetection() {
        let ds = DeviceSettings(
            mainOutput: OutputControl(level: -100.0)
        )
        // -100 is outside the default -64..0 range
        #expect(!ds.outputLevelRange.contains(ds.mainOutput.level))
    }

    // MARK: - P3F-37: Headphone Source Routing

    /// Evidence: APAudioDeviceModel.h — headphone1RoutingID, headphone2RoutingID
    /// 0 = Speaker, 1-8 = DAW pairs, 9-12 = Mixer buses
    @Test func headphoneRoutingIDDefaults() {
        let ds = DeviceSettings()
        #expect(ds.headphone1RoutingID == 0)  // Speaker
        #expect(ds.headphone2RoutingID == 0)  // Speaker
    }

    @Test func headphoneRoutingIDCustomValues() {
        let ds = DeviceSettings(headphone1RoutingID: 1, headphone2RoutingID: 9)
        #expect(ds.headphone1RoutingID == 1)  // DAW 1-2
        #expect(ds.headphone2RoutingID == 9)  // Mixer 1
    }

    @Test func headphoneRoutingIDRange() {
        // Valid range: 0-12 (0=Speaker, 1-8=DAW pairs, 9-12=Mixer)
        for id: UInt32 in 0...12 {
            let ds = DeviceSettings(headphone1RoutingID: id)
            #expect(ds.headphone1RoutingID == id)
        }
    }
}
