/// Type-safe wrapper for CoreAudio four-char property selectors.
///
/// Each selector is a `UInt32` encoding a four-character ASCII code used by
/// CoreAudio to identify device properties. The legacy code defines these in
/// two headers:
/// - `og_source/generic/CoreAudio/mAEstro.h` (legacy namespace, `kmAEstroProperty*`)
/// - `og_source/generic/CoreAudio/ApogeeCustomProperties.h` (newer namespace, `kApogeeCustomProperty_*`)
///
/// Many selectors appear in both headers with the same four-char code.
/// This Swift type unifies them under a single namespace.
public struct AudioPropertySelector: RawRepresentable, Sendable, Equatable, Hashable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Create from a four-character ASCII code (e.g. "AEmg").
    public init(_ fourCC: StaticString) {
        precondition(fourCC.utf8CodeUnitCount == 4, "FourCC must be exactly 4 ASCII characters")
        let p = fourCC.utf8Start
        self.rawValue = UInt32(p[0]) << 24
                      | UInt32(p[1]) << 16
                      | UInt32(p[2]) << 8
                      | UInt32(p[3])
    }
}

// MARK: - Input Channel Properties
// Evidence: og_source/maestrolink/Software/SymphonyIOBoard_MicPre8ch.cpp

extension AudioPropertySelector {
    /// Mic preamp gain in dB. `mAEstroData{in UInt32}`.
    /// FourCC: `AEmg` — `kmAEstroPropertyMicGain` / `kApogeeCustomProperty_InputGain`
    public static let micGain = AudioPropertySelector("AEmg")

    /// Analog I/O type (line +4dBu, -10dBV, mic, instrument). `mAEstroData{in UInt32}`.
    /// FourCC: `AErl` — `kmAEstroPropertyAnalogIOType` / `kApogeeCustomProperty_AnalogIOTypeID`
    public static let analogIOType = AudioPropertySelector("AErl")

    /// Available analog I/O type IDs. `UInt32[]`.
    /// FourCC: `AErM` — `kmAEstroPropertyRefLevelIDs`
    public static let analogIOTypeIDs = AudioPropertySelector("AErM")

    /// Name for an analog I/O type ID. `AudioValueTranslation(UInt32 → CFString)`.
    /// FourCC: `AErN` — `kmAEstroPropertyRefLevelNameForID`
    public static let analogIOTypeNameForID = AudioPropertySelector("AErN")

    /// Phantom power enable. `mAEstroData{in UInt32}`.
    /// FourCC: `AEph` — `kmAEstroPropertyPhantom` / `kApogeeCustomProperty_PhantomPower`
    public static let phantom = AudioPropertySelector("AEph")

    /// Phase reverse enable. `mAEstroData{in UInt32}`.
    /// FourCC: `AEre` — `kmAEstroPropertyPhaseReverse` / `kApogeeCustomProperty_PhaseInverse`
    public static let phaseReverse = AudioPropertySelector("AEre")

    /// High-pass filter enable. `UInt32`.
    /// FourCC: `AEhf` — `kmAEstroPropertyHighPassFilter` / `kApogeeCustomProperty_HighPassFilter`
    public static let highPassFilter = AudioPropertySelector("AEhf")

    /// Input gain range. `AudioValueRange`. Read-only.
    /// FourCC: `AEgr` — `kmAEstroPropertyGainRange` / `kApogeeCustomProperty_InputGainRange`
    public static let gainRange = AudioPropertySelector("AEgr")

    /// Soft limit enable. `mAEstroData{in UInt32}`.
    /// FourCC: `AEsl` — `kmAEstroPropertySoftLimit` / `kApogeeCustomProperty_SoftLimitID`
    public static let softLimit = AudioPropertySelector("AEsl")

    /// Insert assignment ID. `mAEstroData{in UInt32}`.
    /// FourCC: `AEit` — `kmAEstroPropertyInsert` / `kApogeeCustomProperty_InsertID`
    public static let insertID = AudioPropertySelector("AEit")

    /// Available insert IDs. `UInt32[]`.
    /// FourCC: `AEiu` — `kmAEstroPropertyInsertIDs` / `kApogeeCustomProperty_InsertIDList`
    public static let insertIDs = AudioPropertySelector("AEiu")

    /// Name for an insert ID. `AudioValueTranslation(UInt32 → CFString)`.
    /// FourCC: `AEiv` — `kmAEstroPropertyInsertNameForID`
    public static let insertNameForID = AudioPropertySelector("AEiv")

    /// Insert enable for a specific ID. `AudioValueTranslation(UInt32 → UInt32)`.
    /// FourCC: `AEie` — `kmAEstroPropertyInsertEnableForID`
    public static let insertEnableForID = AudioPropertySelector("AEie")

    /// Insert return enable. `UInt32`.
    /// FourCC: `AEir` — `kmAEstroPropertyInsertReturnEnable`
    public static let insertReturnEnable = AudioPropertySelector("AEir")

    /// Group assignment ID. `mAEstroData{in UInt32}`.
    /// FourCC: `AEgp` — `kmAEstroPropertyGroup` / `kApogeeCustomProperty_GroupID`
    public static let groupID = AudioPropertySelector("AEgp")

    /// Available group IDs. `UInt32[]`.
    /// FourCC: `AEgQ` — `kmAEstroPropertyGroupIDs` / `kApogeeCustomProperty_GroupIDList`
    public static let groupIDs = AudioPropertySelector("AEgQ")

    /// Name for a group ID. `AudioValueTranslation(UInt32 → CFString)`.
    /// FourCC: `AEgR` — `kmAEstroPropertyGroupNameForID`
    public static let groupNameForID = AudioPropertySelector("AEgR")
}

// MARK: - Output / Peripheral Properties
// Evidence: og_source/generic/CoreAudio/mAEstro.h lines 933–1035

extension AudioPropertySelector {
    /// Output level. `mAEstroData{in UInt32}`. Peripheral level.
    /// FourCC: `AEl3` — `kmAEstroPropertyMainOutLevel` / `kApogeeCustomProperty_OutputLevel`
    public static let outputLevel = AudioPropertySelector("AEl3")

    /// Output level range. `AudioValueRange`. Read-only.
    /// FourCC: `AEor` — `kApogeeCustomProperty_OutputLevelRange`
    public static let outputLevelRange = AudioPropertySelector("AEor")

    /// Output mute. `UInt32`.
    /// FourCC: `AEm3` — `kmAEstroPropertyMainOutMute`
    public static let outputMute = AudioPropertySelector("AEm3")

    /// Output dim. `UInt32`.
    /// FourCC: `AEm4` — `kmAEstroPropertyMainOutDim` / `kApogeeCustomProperty_OutputDim`
    public static let outputDim = AudioPropertySelector("AEm4")

    /// Output sum to mono. `UInt32`.
    /// FourCC: `AEm5` — `kmAEstroPropertyMainOutSum` / `kApogeeCustomProperty_OutputSumToMono`
    public static let outputSumToMono = AudioPropertySelector("AEm5")

    /// Headphone 1 level. `mAEstroData{in UInt32}`.
    /// FourCC: `AEl1` — `kmAEstroPropertyHeadPhone1Level`
    public static let headphone1Level = AudioPropertySelector("AEl1")

    /// Headphone 2 level. `mAEstroData{in UInt32}`.
    /// FourCC: `AEl2` — `kmAEstroPropertyHeadPhone2Level`
    public static let headphone2Level = AudioPropertySelector("AEl2")

    /// Headphone 1 routing ID. `UInt32`.
    /// FourCC: `AEsB` — `kMaestroPropertyHP1RoutingID`
    public static let headphone1RoutingID = AudioPropertySelector("AEsB")

    /// Headphone 1 routing IDs. `UInt32[]`.
    /// FourCC: `AEsC` — `kMaestroPropertyHP1RoutingIDs`
    public static let headphone1RoutingIDs = AudioPropertySelector("AEsC")

    /// Headphone 1 routing name for ID. `CFString`.
    /// FourCC: `AEsD` — `kMaestroPropertyHP1RoutingNameForID`
    public static let headphone1RoutingNameForID = AudioPropertySelector("AEsD")

    /// Headphone 2 routing ID. `UInt32`.
    /// FourCC: `AEsE` — `kMaestroPropertyHP2RoutingID`
    public static let headphone2RoutingID = AudioPropertySelector("AEsE")

    /// Headphone 2 routing IDs. `UInt32[]`.
    /// FourCC: `AEsF` — `kMaestroPropertyHP2RoutingIDs`
    public static let headphone2RoutingIDs = AudioPropertySelector("AEsF")

    /// Headphone 2 routing name for ID. `CFString`.
    /// FourCC: `AEt0` — `kMaestroPropertyHP2RoutingNameForID`
    public static let headphone2RoutingNameForID = AudioPropertySelector("AEt0")

    /// Monitor output ID. `UInt32`.
    /// FourCC: `AEmo` — `kApogeeCustomProperty_MonitorOutputID`
    public static let monitorOutputID = AudioPropertySelector("AEmo")

    /// Monitor output IDs. `UInt32[]`.
    /// FourCC: `AEos` — `kApogeeCustomProperty_MonitorOutputIDList`
    public static let monitorOutputIDs = AudioPropertySelector("AEos")

    /// Monitor output name for ID. `CFString`.
    /// FourCC: `AEon` — `kApogeeCustomProperty_MonitorOutputNameForID`
    public static let monitorOutputNameForID = AudioPropertySelector("AEon")

    /// Headphone 1 mute. `UInt32`.
    /// FourCC: `AEm1` — `kMaestroPropertyHeadphone1Mute`
    /// Evidence: og_source/maestrolink/Software/mAEstro.h:995,
    ///           og_source/maestrolink/Software/SymphonyIO.cpp:2073
    public static let headphone1Mute = AudioPropertySelector("AEm1")

    /// Headphone 2 mute. `UInt32`.
    /// FourCC: `AEm2` — `kMaestroPropertyHeadphone2Mute`
    /// Evidence: og_source/maestrolink/Software/mAEstro.h:996,
    ///           og_source/maestrolink/Software/SymphonyIO.cpp:2073
    public static let headphone2Mute = AudioPropertySelector("AEm2")

    /// Headphone 1 dim. `UInt32`.
    /// Custom selector for Symphony IO USB control (opcode 0xE7, wValue=1).
    public static let headphone1Dim = AudioPropertySelector("AEhd")

    /// Headphone 2 dim. `UInt32`.
    /// Custom selector for Symphony IO USB control (opcode 0xE7, wValue=2).
    public static let headphone2Dim = AudioPropertySelector("AEhe")

    /// Headphone 1 sum to mono. `UInt32`.
    /// Custom selector (opcode 0xE8, wValue=1).
    public static let headphone1SumToMono = AudioPropertySelector("AEhs")

    /// Headphone 2 sum to mono. `UInt32`.
    /// Custom selector (opcode 0xE8, wValue=2).
    public static let headphone2SumToMono = AudioPropertySelector("AEht")

    // headphone1Source / headphone2Source removed: custom USB-opcode selectors ('AEha'/'AEhb')
    // do not exist in the daemon. Use headphone1RoutingID ('AEsB') / headphone2RoutingID ('AEsE')
    // with scope .output, element 0. Evidence: probe 2026-02-19 confirmed 'AEha'/'AEhb' return
    // 'who?' (2003332927); 'AEsB'/'AEsE' return UInt32 routing ID successfully.

    /// Active speaker set bitmask. `UInt32`. A=1, B=2, C=4.
    /// Custom selector (opcode 0xE9).
    public static let activeSpeakerSet = AudioPropertySelector("AEas")

    /// Speaker output mode. `UInt32`.
    /// Evidence: SymphonyIOVendorSpecific.h — SymphonyIOSpeakerOutputMode enum
    /// Values: 0=Off/Line, 2=Stereo, 6=5.1, 8=7.1, 9=2SpeakerSets, 10=3SpeakerSets
    /// USB command 0x25 (SymphonyIOCommands_SpeakerOutputMode).
    public static let speakerOutputMode = AudioPropertySelector("AEsO")

    /// Front panel meter bank selection. `UInt32`. 0=bank1, 1=bank2.
    /// Custom selector (opcode 0x10).
    public static let frontPanelMeterBank = AudioPropertySelector("AEfm")

    /// Device operating mode. `UInt32`. Read-only from USB.
    /// Custom selector (opcode 0xA6).
    public static let deviceMode = AudioPropertySelector("AEdm")

    /// Keyboard volume control — peripheral ID. `UInt32`.
    /// FourCC: `AEkp` — custom for Symphony IO USB control.
    public static let keyboardVolumePeripheralID = AudioPropertySelector("AEkp")

    /// Keyboard volume control — audio output ID. `UInt32`.
    /// FourCC: `AEko` — custom for Symphony IO USB control.
    public static let keyboardVolumeOutputID = AudioPropertySelector("AEko")

    /// Primary I/O option board type. `UInt32` (IOCardType raw value).
    /// USB-only (opcode 0xA1, wValue=0). No legacy FourCC — custom selector.
    public static let primaryBoardType = AudioPropertySelector("AEb1")

    /// Secondary I/O option board type. `UInt32` (IOCardType raw value).
    /// USB-only (opcode 0xA1, wValue=1). No legacy FourCC — custom selector.
    public static let secondaryBoardType = AudioPropertySelector("AEb2")
}

// MARK: - Routing Properties
// Evidence: og_source/maestrolink/Software/SymphonyIO_Stream.cpp
// Evidence: og_source/maestrolink/Software/SymphonyIOUSBAudioRoutingController.cpp

extension AudioPropertySelector {
    /// Routing payload. `maestroRoute` struct.
    /// FourCC: `AErt` — `kmAEstroPropertyRoute`
    public static let route = AudioPropertySelector("AErt")

    /// Routing (newer). `maestroRoute` struct.
    /// FourCC: `AEsA` — `kMaestroPropertyRouting`
    public static let routing = AudioPropertySelector("AEsA")

    /// Reset routing to default. `UInt32` (set 1 to reset, get returns 1 if default).
    /// FourCC: `AEt2` — `kMaestroPropertyResetRouting`
    public static let resetRouting = AudioPropertySelector("AEt2")

    /// SPDIF replace ID. `UInt32`.
    /// FourCC: `AEs0` — `kMaestroPropertySPDIFReplaceID`
    public static let spdifReplaceID = AudioPropertySelector("AEs0")

    /// SPDIF replace IDs. `UInt32[]`.
    /// FourCC: `AEs1` — `kMaestroPropertySPDIFReplaceIDs`
    public static let spdifReplaceIDs = AudioPropertySelector("AEs1")

    /// SPDIF replace name for ID. `CFString`.
    /// FourCC: `AEs2` — `kMaestroPropertySPDIFReplaceNameForID`
    public static let spdifReplaceNameForID = AudioPropertySelector("AEs2")

    /// SPDIF mirror ID. `UInt32`.
    /// FourCC: `AEs7` — `kMaestroPropertySPDIFMirrorID`
    public static let spdifMirrorID = AudioPropertySelector("AEs7")

    /// SPDIF mirror IDs. `UInt32[]`.
    /// FourCC: `AEs8` — `kMaestroPropertySPDIFMirrorIDs`
    public static let spdifMirrorIDs = AudioPropertySelector("AEs8")

    /// SPDIF mirror name for ID. `CFString`.
    /// FourCC: `AEs9` — `kMaestroPropertySPDIFMirrorNameForID`
    public static let spdifMirrorNameForID = AudioPropertySelector("AEs9")

    /// SPDIF mirror 2 ID (second coax pair). `UInt32`.
    /// FourCC: `AEsJ` — `kApogeeCustomProperty_SPDIFMirror2ID`
    /// Evidence: ApogeeCustomProperties.h line 705
    public static let spdifMirror2ID = AudioPropertySelector("AEsJ")

    /// SPDIF mirror 2 IDs. `UInt32[]`.
    /// FourCC: `AEsK` — `kApogeeCustomProperty_SPDIFMirror2IDs`
    public static let spdifMirror2IDs = AudioPropertySelector("AEsK")

    /// SPDIF mirror 2 name for ID. `CFString`.
    /// FourCC: `AEsL` — `kApogeeCustomProperty_SPDIFMirror2NameForID`
    public static let spdifMirror2NameForID = AudioPropertySelector("AEsL")
}

// MARK: - Mixer Properties
// Evidence: og_source/generic/CoreAudio/mAEstro.h lines 1150–1177

extension AudioPropertySelector {
    /// Mixer channel pan. `Float64`.
    /// FourCC: `AEMp` — `kmAEstroPropertyMixerChannelPan` / `kApogeeCustomProperty_MixerChannelPan`
    public static let mixerChannelPan = AudioPropertySelector("AEMp")

    /// Mixer channel solo. `UInt32`.
    /// FourCC: `AEMs` — `kmAEstroPropertyMixerChannelSolo` / `kApogeeCustomProperty_MixerChannelSolo`
    public static let mixerChannelSolo = AudioPropertySelector("AEMs")

    /// Mixer channel mute. `UInt32`.
    /// FourCC: `AEMm` — `kmAEstroPropertyMixerChannelMute` / `kApogeeCustomProperty_MixerChannelMute`
    public static let mixerChannelMute = AudioPropertySelector("AEMm")

    /// Mixer channel level. `Float64`.
    /// FourCC: `AEMl` — `kmAEstroPropertyMixerChannelLevel` / `kApogeeCustomProperty_MixerChannelLevel`
    public static let mixerChannelLevel = AudioPropertySelector("AEMl")

    /// Mixer channel level range. `AudioValueRange`.
    /// FourCC: `AEMR` — `kmAEstroPropertyMixerChannelLevelRange`
    public static let mixerChannelLevelRange = AudioPropertySelector("AEMR")

    /// Mixer channel label. `CFString`.
    /// FourCC: `AEML` — `kmAEstroPropertyMixerChannelLabel`
    public static let mixerChannelLabel = AudioPropertySelector("AEML")

    /// Active mixer ID. `UInt32`.
    /// FourCC: `AEMI` — `kmAEstroPropertyMixerID` / `kApogeeCustomProperty_MixerID`
    public static let mixerID = AudioPropertySelector("AEMI")

    /// Available mixer IDs. `UInt32[]`.
    /// FourCC: `AEmI` — `kmAEstroPropertyMixerIDs` / `kApogeeCustomProperty_MixerIDList`
    public static let mixerIDs = AudioPropertySelector("AEmI")

    /// Software return ID. `UInt32`.
    /// FourCC: `AEsR` — `kmAEstroPropertyMixerSoftwareReturnID`
    public static let mixerSoftwareReturnID = AudioPropertySelector("AEsR")

    /// Software return IDs. `UInt32[]`.
    /// FourCC: `AEsS` — `kmAEstroPropertyMixerSoftwareReturnIDs`
    public static let mixerSoftwareReturnIDs = AudioPropertySelector("AEsS")

    /// Software return name for ID. `CFString`.
    /// FourCC: `AEsT` — `kmAEstroPropertyMixerSoftwareReturnNameForID`
    public static let mixerSoftwareReturnNameForID = AudioPropertySelector("AEsT")
}

// MARK: - Meter Properties
// Evidence: og_source/maestrolink/Software/SymphonyIO_Stream.cpp (kMaestroPropertymAEstroStreamMeter)

extension AudioPropertySelector {
    /// Stream meter data. `mAEstroStreamMeter` (variable-size).
    /// FourCC: `AEsm` — `kMaestroPropertymAEstroStreamMeter`
    public static let streamMeter = AudioPropertySelector("AEsm")

    /// Meter data (newer API). Custom payload.
    /// FourCC: `AEmD` — `kApogeeCustomProperty_MeterData`
    public static let meterData = AudioPropertySelector("AEmD")

    /// Clear peak meters. Trigger.
    /// FourCC: `AEpc` — `kmAEstroPropertyGlobalPeaksClear`
    public static let peaksClear = AudioPropertySelector("AEpc")

    /// Clear over indicators. Trigger.
    /// FourCC: `AEoc` — `kmAEstroPropertyGlobalOversClear`
    public static let oversClear = AudioPropertySelector("AEoc")

    /// Over hold mode. `UInt32` (eOversHoldMode).
    /// FourCC: `AEs5` — `kMaestroPropertyOversHoldMode`
    public static let oversHoldMode = AudioPropertySelector("AEs5")

    /// Peak hold mode. `UInt32` (ePeakHoldMode).
    /// FourCC: `AEs6` — `kMaestroPropertyPeakHoldMode`
    public static let peakHoldMode = AudioPropertySelector("AEs6")

    /// Meters show input source IDs. `UInt32[]`.
    /// FourCC: `AEM1` — `kmAEstroPropertyMetersShowIDs`
    public static let metersShowIDs = AudioPropertySelector("AEM1")

    /// Meters show name for ID. `CFString`.
    /// FourCC: `AEM2` — `kmAEstroPropertyMetersShowNameForIDCFString`
    public static let metersShowNameForID = AudioPropertySelector("AEM2")

    /// Front panel meter bank source selection. `UInt32` (eMaestroEnum_MetersShowValues 0-15).
    /// Element = bank index (1 = bank 1, 2 = bank 2).
    /// Values: 0=AnalogOut1-8, 1=AnalogIn1-8, 2=DigitalOut1-8, 3=DigitalIn1-8,
    ///         4=AnalogOut9-16, 5=AnalogIn9-16, 6=DigitalOut9-16, 7=DigitalIn9-16, etc.
    /// Evidence: og_source/generic/mAEstroTypes.h — eMaestroEnum_MetersShowValues (lines 17-39)
    /// FourCC: `AEmi` — `kmAEstroPropertyMetersShowInput`
    public static let metersShowInput = AudioPropertySelector("AEmi")
}

// MARK: - Clock / System Properties
// Evidence: og_source/generic/CoreAudio/mAEstro.h lines 816, 989–994, 1036–1039

extension AudioPropertySelector {
    /// Sample rate. `Float64`.
    /// FourCC: `AEf1` — `kApogeeCustomProperty_SampleRate`
    public static let sampleRate = AudioPropertySelector("AEf1")

    /// Clock source. `mAEstroData{in UInt32}`.
    /// FourCC: `AEck` — `kmAEStroPropertyClockSource`
    public static let clockSource = AudioPropertySelector("AEck")

    /// Clock status (locked/unlocked/syncing). `UInt32`. Read-only.
    /// FourCC: `AEs3` — `kApogeeCustomProperty_ClockStatus`
    public static let clockStatus = AudioPropertySelector("AEs3")

    /// Optical input format (ADAT vs S/PDIF). `mAEstroData{in UInt32}`.
    /// FourCC: `AEoi` — `kmAEstroPropertyOpticalInFormat`
    public static let opticalInFormat = AudioPropertySelector("AEoi")

    /// Optical output format. `mAEstroData{in UInt32}`.
    /// FourCC: `AEoo` — `kmAEstroPropertyOpticalOutFormat`
    public static let opticalOutFormat = AudioPropertySelector("AEoo")

    /// Word clock divide (1:1 vs 1:2). `mAEstroData{in UInt32}`.
    /// FourCC: `AEwd` — `kmAEstroPropertyWCDivide`
    public static let wordClockDivide = AudioPropertySelector("AEwd")

    /// Word clock termination. `UInt32`.
    /// FourCC: `AEwt` — `kMaestroPropertyWordClockTermination`
    public static let wordClockTermination = AudioPropertySelector("AEwt")
}

// MARK: - Device Info Properties
// Evidence: og_source/maestrolink/Software/SymphonyIO_Stream.cpp (kmAEstroPropertyVersion)
// Evidence: og_source/maestrolink/Software/SymphonyIOUSBAudioDeviceController.cpp

extension AudioPropertySelector {
    /// Version info. `mAEstroVersionInfoSymphonyIO` for Symphony IO.
    /// FourCC: `AEve` — `kmAEstroPropertyVersion`
    public static let version = AudioPropertySelector("AEve")

    /// Version as CFString.
    /// FourCC: `AEt1` — `kMaestroPropertyVersionCFString` / `kApogeeCustomProperty_VersionInfo`
    public static let versionString = AudioPropertySelector("AEt1")

    /// Audio system name. `CFString`.
    /// FourCC: `AEs4` — `kMaestroPropertyAudioSystemNameCFString`
    public static let audioSystemName = AudioPropertySelector("AEs4")

    /// Peripheral name prefix. `CFString`.
    /// FourCC: `AEpx` — `kMaestroPropertyPrefix` / `kApogeeCustomProperty_Prefix`
    public static let prefix = AudioPropertySelector("AEpx")

    /// Identify (flash LEDs). `mAEstroData{in UInt32}`.
    /// FourCC: `AEbb` — `kmAEstroPropertyIdentify` / `kApogeeCustomProperty_Identify`
    public static let identify = AudioPropertySelector("AEbb")

    /// Daemon alive check. `UInt32`. Read-only.
    /// FourCC: `AEda` — `kmAEstroPropertyDaemonAlive`
    public static let daemonAlive = AudioPropertySelector("AEda")

    /// Device type. `mAEstroApogeeDeviceType`.
    /// FourCC: `AEdt` — `kmAEstroPropertyDeviceType`
    public static let deviceType = AudioPropertySelector("AEdt")

    /// Dirty count (increments on property changes). `UInt32`. Read-only.
    /// FourCC: `AEt3` — `kMaestroPropertyDirtyCount`
    public static let dirtyCount = AudioPropertySelector("AEt3")

    /// Digital reference level. `mAEstroData{in UInt32}`.
    /// FourCC: `AEdr` — `kmAEstroPropertyDigitalRefLevel`
    public static let digitalRefLevel = AudioPropertySelector("AEdr")

    /// Digital reference level IDs. `UInt32[]`.
    /// FourCC: `AEdS` — `kmAEstroPropertyDigitalRefLevelIDs`
    public static let digitalRefLevelIDs = AudioPropertySelector("AEdS")

    /// Digital reference level name for ID. `CFString`.
    /// FourCC: `AEdT` — `kmAEstroPropertyDigitalRefLevelNameForID`
    public static let digitalRefLevelNameForID = AudioPropertySelector("AEdT")

    /// Calibration trim value. `Float64`.
    /// FourCC: `AEtr` — `kMaestroPropertyTrim`
    public static let trim = AudioPropertySelector("AEtr")

    /// Calibration trim value range. `AudioValueRange`. Read-only.
    /// FourCC: `AEtv` — `kMaestroPropertyTrimValueRange`
    public static let trimRange = AudioPropertySelector("AEtv")
}

// MARK: - CustomStringConvertible

extension AudioPropertySelector: CustomStringConvertible {
    public var description: String {
        let bytes = [
            UInt8((rawValue >> 24) & 0xFF),
            UInt8((rawValue >> 16) & 0xFF),
            UInt8((rawValue >> 8) & 0xFF),
            UInt8(rawValue & 0xFF),
        ]
        let chars = bytes.map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "?" }
        return "'\(String(chars))'"
    }
}
