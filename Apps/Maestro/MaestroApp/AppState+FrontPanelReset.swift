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
// Those levels come down before anything else is written. A line output's
// reference level and trims keep the quieter of saved and default
// (`frontPanelResetOutput`): -10 dBV is not put back on +4 dBu.
//
// Also for safety: a reset is believed only when 0xDB answers it twice, each
// time seen to be the unit's answer (`confirmFrontPanelReset`), and only for
// a unit whose cards were read this session; it is applied once
// (`FrontPanelResetMarker`, until 0xDB is seen to answer None); and the same
// unit's ThunderBridge routes are taken off the mixers
// (`makeOtherTransportsSafeAfterFrontPanelReset`).
// Optical format is not saved by Maestro over USB (it reads the unit's), and
// the channel name prefix is left alone.
extension AppState {
    /// An output channel after a front-panel Reset All: the original's
    /// defaults (+4 dBu, -16 dBFS, trims 0), except that nothing is moved in
    /// the louder direction. The original put every output on its defaults;
    /// for a channel set to -10 dBV that is about 12 dB louder, and the owner's
    /// rule is that nothing Maestro does comes back louder than intended. So
    /// each field keeps the quieter of the saved value and the default:
    ///
    /// - analog reference: -10 dBV (`minus10dBV`) is kept; +4 dBu otherwise;
    /// - digital reference: the higher of the saved index and -16 dBFS (2). A
    ///   higher index (-10 dBFS at 5) puts full scale lower, so it is quieter;
    ///   -20 dBFS (0) is the loudest, which is why it allows no positive trim
    ///   (`OutputChannelLogic.trimRange`);
    /// - trims (the one in use and the one kept for each reference): the
    ///   lower of the saved trim and 0 dB, then clamped to the range of the
    ///   digital reference.
    ///
    /// Input reference levels and trims go back to their defaults in full:
    /// an input is not an output that can be heard louder.
    static func frontPanelResetOutput(_ saved: OutputChannelState) -> OutputChannelState {
        let defaults = OutputChannelState()
        let analog = saved.analogRefLevel == OutputChannelLogic.minus10dBV
            ? OutputChannelLogic.minus10dBV : defaults.analogRefLevel
        let digital = OutputChannelLogic.offersDigitalRef(saved.digitalRefLevel)
            ? max(saved.digitalRefLevel, defaults.digitalRefLevel) : defaults.digitalRefLevel
        func quieter(_ trim: Double) -> Double {
            OutputChannelLogic.clampTrim(min(trim, defaults.trim), digitalRefLevel: digital)
        }
        var output = OutputChannelState(analogRefLevel: analog, digitalRefLevel: digital, trim: quieter(saved.trim))
        output.trimPlus4 = quieter(saved.trimPlus4)
        output.trimMinus10 = quieter(saved.trimMinus10)
        return output
    }

    /// The stores the reset clears are not this transport's alone: the channel
    /// and mixer stores are keyed by the unit's identity and card layout, the
    /// input routing by identity, and the output routing by product, which
    /// ThunderBridge shares with 32-channel USB. Over ThunderBridge the same
    /// unit's mixers would then load the reset strips (0 dB, unmuted), and a
    /// saved ThunderBridge route "Mixer 1 to Line 1/2" would play them:
    /// live inputs at 0 dB.
    ///
    /// So, of the choices (restrict the reset to USB-only state, or make
    /// ThunderBridge safe), Maestro makes ThunderBridge safe, which is the one
    /// that guarantees no ThunderBridge mixer is routed with reset strips
    /// whatever key it shares: restricting would have to tell the shared
    /// stores apart, and they cannot be (the same keys serve both).
    ///
    /// - Every saved output routing table of a card topology this unit is in
    ///   (`cardRouting.v3.<product>.a=<A>.b=<B>...`, as unit A or B, either
    ///   unit's table) has its two mixer rows emptied: the rows after unit
    ///   A's playback pairs, in the 32- and the 64-channel grid alike
    ///   (`cachedOutputRouteMap`, `TwoUnitOutputRouting.playbackPair`).
    ///   Direct routes are kept. With no mixer row no
    ///   output is fed by a mixer, so no headphone following one is either.
    /// - ThunderBridge's input routing and card mixers are marked pending
    ///   (`RoutingMixerReset.Pending`): the next ThunderBridge connect writes
    ///   the default input table first, then both mixers in full, then the
    ///   routes. Always, not only when ThunderBridge state is found: the
    ///   shared keys do not say which transport saved them, and the only cost
    ///   is one full write at the next ThunderBridge connect.
    func makeOtherTransportsSafeAfterFrontPanelReset(identity: UInt64) {
        let defaults = UserDefaults.standard
        let hex = String(identity, radix: 16)
        var changed: [String] = []
        for (key, value) in defaults.dictionaryRepresentation() {
            guard let softwarePairs = Self.frontPanelResetOutputRoutingKey(key, identityHex: hex) else { continue }
            let mixerRows = [softwarePairs, softwarePairs + 1].map(String.init)
            if let rows = value as? [String: [Int]] {
                // Emptied, not removed: a table with every row present is
                // "complete" (`thunderboltOutputTable`), and its outputs
                // with no source stay silent instead of taking the defaults.
                guard mixerRows.contains(where: { !(rows[$0] ?? []).isEmpty }) else { continue }
                var emptied = rows
                for row in mixerRows where rows[row] != nil { emptied[row] = [] }
                defaults.set(emptied, forKey: key)
            } else if var rows = value as? [String: Int] {
                // The single-route form has no empty row: the mixer rows go.
                guard mixerRows.contains(where: { rows[$0] != nil }) else { continue }
                for row in mixerRows { rows[row] = nil }
                defaults.set(rows, forKey: key)
            } else {
                continue
            }
            changed.append(key)
        }
        RoutingMixerReset.setPending(.thunderboltInputRouting)
        RoutingMixerReset.setPending(.thunderboltCardMixer)
        print("[Maestro] USB front panel reset: no saved route of this unit plays a mixer on any transport"
            + (changed.isEmpty ? "" : " (\(changed.count) saved routing table(s) changed)")
            + "; ThunderBridge writes its default input table and both mixers at its next connect")
    }

    /// A saved output routing key of a topology the unit `identityHex` is in
    /// (`peripheralRoutingCache`: `cardRouting.v3.<product>.<topology>.<unit>.<scope>`,
    /// with or without `_multi`): the first mixer row (unit A's playback
    /// pairs). The identity must be a whole topology field (`a=<hex>` or
    /// `b=<hex>`), never a prefix of another unit's.
    static func frontPanelResetOutputRoutingKey(_ key: String, identityHex hex: String) -> Int? {
        let prefix = "cardRouting.v3."
        guard key.hasPrefix(prefix), !key.hasSuffix(".migratedTo") else { return nil }
        let parts = key.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        // product, a=<A>, b=<B>, channels=<N>, unit, scope (which may hold dots)
        guard parts.count >= 6, let product = UInt16(parts[0]),
              parts[1].hasPrefix("a="), parts[2].hasPrefix("b="), parts[3].hasPrefix("channels=") else { return nil }
        let a = parts[1].dropFirst(2), b = parts[2].dropFirst(2)
        guard a == hex || b == hex else { return nil }
        // `peripheralRoutingCache` keys its tables by a Symphony product
        // (unit A's mode); none other is saved.
        guard let mode = USBMode(productID: product) else { return nil }
        return mode.channelCount / 2
    }

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
            // Outputs: never louder (`frontPanelResetOutput`).
            let outputs: [OutputChannelState] = channelStateStore.load(ChannelStateStore.outputKey) ?? []
            channelStateStore.save(outputs.map(Self.frontPanelResetOutput), for: ChannelStateStore.outputKey)
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
        if let identity = unitAIdentity { makeOtherTransportsSafeAfterFrontPanelReset(identity: identity) }
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

/// "A front-panel reset was applied to Maestro's saved state for unit <id>",
/// saved until the unit is seen to answer None to 0xDB
/// (`XPCDeviceConnection.resetRequestReadsNone`). While it is there, a reset
/// request the unit still reports (its clear did not land, or Maestro quit
/// before it) is not applied again on a retry, a replug or a relaunch: what
/// was edited after the reset stays, and a level raised since is not lowered
/// again. The restore still writes every setting and clears the request.
enum FrontPanelResetMarker {
    enum Stage: Int, Sendable {
        /// The saved state went back to defaults.
        case savedStateReset = 1
        /// The speaker and headphone levels were lowered too.
        case levelsLowered = 2
    }

    static func key(for identity: UInt64) -> String {
        "usbFrontPanelReset.applied.\(String(identity, radix: 16))"
    }

    static func stage(for identity: UInt64, defaults: UserDefaults = .standard) -> Stage? {
        Stage(rawValue: defaults.integer(forKey: key(for: identity)))
    }

    /// Records `stage`; never moves back to an earlier one.
    static func set(_ stage: Stage, for identity: UInt64, defaults: UserDefaults = .standard) {
        guard (self.stage(for: identity, defaults: defaults)?.rawValue ?? 0) < stage.rawValue else { return }
        defaults.set(stage.rawValue, forKey: key(for: identity))
    }

    static func clear(for identity: UInt64, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(for: identity))
    }
}
