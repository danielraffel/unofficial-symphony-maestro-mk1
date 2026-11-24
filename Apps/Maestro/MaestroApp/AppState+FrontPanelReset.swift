import Foundation
import MaestroCore
import MaestroDevice

// USB: a reset picked on the Symphony's front panel while it started (0xDB
// reads ResetAll or ResetAllButCalibration, `SymphonyIOResetRequest`).
//
// The original then reset its own copy of the unit's settings to defaults,
// put them on the unit, and acknowledged the request
// (og_source/maestrolink/Software/SymphonyIO.cpp:6417-6432:
// `ResetToDefaults(&m_ResetState)`, `ApplySettingsToHardware()`,
// `clearResetRequest()`). Maestro does the same: the saved state of this unit
// goes back to defaults here, the ordered restore writes it, and 0xDB is
// cleared once the restore has completed. What each reset covers follows the
// original's `ResetToDefaults` tree:
//
// - Monitor (SymphonyIO.cpp:1570-1637): speaker mode Stereo (Off with fewer
//   than two analog outputs), sum to mono off on all three outputs, speaker
//   set and both headphone sources back to default (headphone routing is
//   forced for an explicit reset, :1622-1623), meter sources to the card
//   default (ResetMeterSourceToDefault, :1702-1724), peak and over hold off
//   (USB Audio boot mode, :1603-1607).
// - Routing, both directions (:1626-1632, `ResetRoutings`): the saved Output
//   and Input Routing are removed and the unit is written its default tables
//   (`RoutingMixerReset.Pending`), as a new install would.
// - Mixers (SymphonyIOMixer.cpp:1184-1210; in USB Audio boot mode both mixers
//   are children of the unit, SymphonyIO.cpp:214-222): every strip 0 dB,
//   centre, unmuted, no solo; Software Return on USB 1-2, unmuted, 0 dB;
//   Master 0 dB. The routing reset is what keeps those off every output.
// - Channels (AnalogIn_SymphonyIO_Stream.cpp:26-48,
//   AnalogOut_SymphonyIO_Stream.cpp:28-48, SymphonyIOBoard_MicPre8ch.cpp:2301-2325;
//   `InputChannelLogic.resetToDefaults`): soft limit off in both; with
//   ResetAll also the reference levels and trims; ResetAllButCalibration
//   keeps the line channels' reference levels and trims; a MicPre channel is
//   reset in full either way.
//
// One exception to the original, for safety: nothing comes back louder. The
// original set every output to 20 dB attenuation and unmuted it. Maestro
// keeps every mute and every dim that is on, and puts the speaker and
// headphones at the quieter of -20 dB and what the unit says it has now
// (`applyFrontPanelResetLevels`); a level it cannot read is not written.
// Optical format is not saved by Maestro over USB (it reads the unit's), and
// the channel name prefix is left alone.
extension AppState {
    /// The original's speaker and headphone attenuation after a reset
    /// (`SymphonyIOMonitorDefaults.levelAttenuationDB`).
    static let frontPanelResetAttenuation = UInt32(SymphonyIOMonitorDefaults.levelAttenuationDB)

    /// Put this unit's saved USB state back to the defaults `reset` covers.
    /// Writes nothing to the unit: the restore that follows does.
    @MainActor
    func resetSavedStateForFrontPanelReset(_ reset: SymphonyIOResetRequest, connection: XPCDeviceConnection) {
        guard reset.isFrontPanelReset else { return }
        let includingCalibration = reset == .resetAll
        // Monitor settings.
        let store = connection.settingsStore
        let boardsMeasured = primaryBoardSource == .detected && secondaryBoardSource == .detected
        let mode: SymphonyIOSpeakerMode = boardsMeasured
            ? SymphonyIOMonitorDefaults.speakerMode(
                analogOutputChannels: primaryBoardType.analogOutputChannels + secondaryBoardType.analogOutputChannels)
            : .stereo
        store.record(.uint32(UInt32(mode.rawValue)), for: PropertyAddress(selector: .speakerOutputMode))
        speakerOutputMode = UInt32(mode.rawValue)
        for selector in [AudioPropertySelector.outputSumToMono, .headphone1SumToMono, .headphone2SumToMono] {
            store.record(.bool(SymphonyIOMonitorDefaults.summedToMono), for: PropertyAddress(selector: selector))
        }
        // Dim stays as it is: off would be louder.
        store.record(.uint32(SpeakerOutputLogic.defaultSpeakerSetMask), for: PropertyAddress(selector: .activeSpeakerSet))
        // No headphone source chosen: both follow the default (USB 1-2), as
        // on a new install; nothing is replayed for them afterwards.
        store.remove(PropertyAddress(selector: .headphone1RoutingID))
        store.remove(PropertyAddress(selector: .headphone2RoutingID))
        let bank1 = UInt32(SymphonyIOMonitorDefaults.meterSourceBank1(
            hasAnalogInputs: cardLayout.slot1.analogInputChannels + cardLayout.slot2.analogInputChannels > 0).rawValue)
        let bank2 = UInt32(SymphonyIOMonitorDefaults.meterSourceBank2(
            hasAnalogOutputs: cardLayout.slot1.analogOutputChannels + cardLayout.slot2.analogOutputChannels > 0).rawValue)
        store.record(.uint32(bank1), for: PropertyAddress(selector: .metersShowInput, element: 1))
        store.record(.uint32(bank2), for: PropertyAddress(selector: .metersShowInput, element: 2))
        for entry in store.entries() where entry.address.selector == .frontPanelMeterBank {
            if entry.address.element == 1 { store.record(.uint32(bank1), for: entry.address) }
            if entry.address.element == 2 { store.record(.uint32(bank2), for: entry.address) }
        }
        store.record(.uint32(UInt32(SymphonyIOMonitorDefaults.peakHoldMode)), for: PropertyAddress(selector: .peakHoldMode))
        store.record(.uint32(UInt32(SymphonyIOMonitorDefaults.oversHoldMode)), for: PropertyAddress(selector: .oversHoldMode))
        // Channels.
        var inputs: [InputChannelState] = channelStateStore.load(ChannelStateStore.inputKey) ?? []
        let host = primaryBoardType == .micPre8 ? secondaryBoardType : primaryBoardType
        InputChannelLogic.resetToDefaults(
            &inputs, includingCalibration: includingCalibration,
            micPreInstalled: InputChannelLogic.micPreIsUsable(primary: primaryBoardType, secondary: secondaryBoardType),
            hostAnalogInputChannels: host.analogInputChannels)
        channelStateStore.save(inputs, for: ChannelStateStore.inputKey)
        if includingCalibration {
            let outputs: [OutputChannelState] = channelStateStore.load(ChannelStateStore.outputKey) ?? []
            channelStateStore.save(Array(repeating: OutputChannelState(), count: outputs.count),
                                   for: ChannelStateStore.outputKey)
        }
        // Mixers: strips, Software Return, Master.
        for mixer in 0..<2 {
            channelStateStore.save([MixerChannelState](), for: ChannelStateStore.mixerKey(mixer))
        }
        let preferences = mixerPreferences
        for key in MixerPreferences.legacyKeys { preferences.set(nil, forKey: key) }
        // Routing, both directions: the defaults are written by the restore.
        for direction in ["output", "input"] {
            let cache = peripheralRoutingCache(direction: direction)
            UserDefaults.standard.removeObject(forKey: cache.key)
            UserDefaults.standard.removeObject(forKey: cache.multiKey)
        }
        RoutingMixerReset.setPending(.usbOutputRouting)
        RoutingMixerReset.setPending(.usbInputRouting)
        usbMixersWritten = nil
        viewReloadToken = UUID()
        print("[Maestro] USB front panel reset (\(reset)): Maestro's saved settings for this unit are back to defaults"
            + (includingCalibration ? "" : ", reference levels and trims kept") + "; levels never raised, mutes and dims kept")
    }

    /// After a front-panel reset, inside the restore: the speaker and both
    /// headphones at the quieter of -20 dB (the original's reset level) and
    /// what the unit reports, and never louder. A level whose read the unit
    /// is not seen to answer is left alone. Mutes are not touched.
    @MainActor
    func applyFrontPanelResetLevels(_ connection: XPCDeviceConnection) async {
        for selector in [AudioPropertySelector.outputLevel, .headphone1Level, .headphone2Level] {
            let address = PropertyAddress(selector: selector)
            let range: UInt8 = selector == .outputLevel ? 64 : 127
            guard device === connection,
                  let byte = await connection.restoreReadBelievedByte(address), byte <= range else {
                print("[Maestro] USB front panel reset: \(selector) not read; left as it is")
                continue
            }
            let current = UInt32(byte)
            guard current < Self.frontPanelResetAttenuation else { continue }
            do {
                try await connection.setProperty(address, value: .uint32(Self.frontPanelResetAttenuation))
                let level = -Double(Self.frontPanelResetAttenuation)
                let output: KeyboardVolumeOutput
                switch selector {
                case .outputLevel: speakerLevel = level; output = .speakers
                case .headphone1Level: hp1Level = level; output = .headphone1
                default: hp2Level = level; output = .headphone2
                }
                // The helper keeps the level it is sent (note_speaker_level),
                // and the Mac's volume follows when this is the output the
                // volume keys move, as the in-app reset does: the next key
                // press then starts from the lowered level, not the old one.
                writeASPVolume(level, output: output)
                print("[Maestro] USB front panel reset: \(selector) lowered from -\(current) dB to -\(Self.frontPanelResetAttenuation) dB")
            } catch {
                print("[Maestro] USB front panel reset: \(selector) not written: \(error)")
            }
        }
    }
}
