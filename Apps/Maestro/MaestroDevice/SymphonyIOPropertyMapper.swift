/// Maps Apogee property selectors to USB vendor-specific control requests.
///
/// Extracted from USBDeviceConnection to enable reuse by XPCDeviceConnection.
/// All methods are static — caller manages any caching of write-only properties
/// (e.g., sampleRate and clockSource).
///
/// Evidence: `og_source/generic/CoreAudio/mAEstro.h` — property selectors
/// Evidence: `og_source/maestrolink/Software/SymphonyIO/SymphonyIOControl.cpp` — USB command usage
/// Evidence: `og_source/maestrolink/Software/SymphonyIO/SymphonyIOVendorSpecific.h` — opcodes

import MaestroCore
import Foundation

// MARK: - SymphonyIOPropertyMapper

/// Static mapper from AudioPropertySelector ↔ USBControlRequest.
///
/// Three core operations:
/// - `buildReadRequest` — property address → USB read request
/// - `buildWriteRequest` — property address + value → USB write request
/// - `decodeResponse` — USB response data → PropertyValue
public enum SymphonyIOPropertyMapper {

    /// Whether the front-panel meter bank write (`0x10`) is sent to hardware.
    ///
    /// **ON by default since 2026-09-11**, after the root cause was found and both
    /// banks were exercised through the UI on real hardware.
    ///
    /// This flag was flipped on once before, prematurely, and that is why it
    /// survives as a kill switch. The history was wrong twice, and both errors are
    /// worth keeping:
    ///
    /// 1. It was turned ON (2026-09-11) after one clean hardware write. A second
    ///    bank change in the same session took the unit off the USB bus entirely
    ///    (`ioreg` 13 matching nodes → 0). "EP0 survived one write" was nowhere
    ///    near sufficient.
    /// 2. The failures were then attributed to `0x10` being an inherently
    ///    FPGA-disruptive command, and to a timing collision with `0x30` meter
    ///    polling. Both were wrong. The real cause was that we sent the bank in
    ///    the wrong 16-bit field: legacy composes one 32-bit `nValue` and the
    ///    transport splits it `wValue = nValue >> 16, wIndex = nValue & 0xFFFF`
    ///    (`og_source/maestrolink/Software/ControlProtocol/SimpleControlProtocolUSB.cpp:56-57`),
    ///    so bank 1 belongs on the wire as `wValue=0, wIndex=1`. We sent
    ///    `wValue=1, wIndex=0`, and the firmware reconstructed `0x00010000` — a
    ///    value legacy cannot produce. Bank 0 encodes identically under both
    ///    schemes, which is exactly why only bank 1 ever wedged, and why that
    ///    asymmetry read as "bank 1 is fragile". Fixed in `95668ac`; see
    ///    `Docs/Learnings.md` 2026-09-11 (resolved).
    ///
    /// With the encoding corrected, `Tools/probe-front-panel-bank.swift` sent four
    /// bank-1 writes 10s apart, twice, with `0x30` polling at ~12 reads/s
    /// throughout: 717 and 685 consecutive meter reads, zero failures, `ioreg`
    /// steady at 13, the second run with the app running and polling concurrently
    /// — the condition all three wedging runs had.
    ///
    /// Both dropdowns were then driven from the UI: 13 writes across both banks at
    /// click spacing — far tighter than the probe's 10s — with 17,542 concurrent
    /// `0x30` reads, zero EP0 failures, the read backoff never armed, and the unit
    /// enumerated throughout.
    ///
    /// What makes that different from the premature flip is the mechanism, not the
    /// sample size. The first time there was a clean run and no explanation. Now
    /// there is a cited reason the old request was malformed, a reason only bank 1
    /// could fail, and confirmation on the bank the bug could not have touched.
    ///
    /// `MAESTRO_ALLOW_FRONT_PANEL_METER_WRITE=0` disables it — the escape hatch if
    /// this is wrong a third time. Any other value leaves it on, so a typo cannot
    /// silently disable a working control.
    ///
    /// Preset application writes both banks (`AppState.swift:1884-1885`), so loading
    /// a preset sends two `0x10` writes back to back. That is the tightest spacing
    /// this command sees in normal use.
    ///
    /// Recovery, if it ever does go wrong again, depends on which state it is in —
    /// they look similar and have different fixes. Check with
    /// `ioreg -r -c IOUSBHostDevice -l | grep -c 3168`:
    /// - **nonzero** (still enumerated, EP0 not answering): USB replug. A device
    ///   power cycle is overkill.
    /// - **zero** (genuinely off the bus): power-cycle the Apogee. This is the one
    ///   case where that is the right first move.
    ///
    /// Neither needs a Mac reboot. The February 2026 wedge that did was a
    /// different failure.
    public static let allowFrontPanelMeterWrites: Bool =
        ProcessInfo.processInfo.environment["MAESTRO_ALLOW_FRONT_PANEL_METER_WRITE"] != "0"

    /// Properties that are always read-only.
    public static let readOnlySelectors: Set<AudioPropertySelector> = [
        .clockStatus, .version, .versionString, .outputLevelRange,
        .gainRange, .mixerChannelLevelRange, .daemonAlive, .dirtyCount,
        .trimRange, .deviceType, .deviceMode,
        .primaryBoardType, .secondaryBoardType
    ]

    /// Properties that are write-only and must be cached by the caller.
    /// The XMOS firmware accepts writes for these but doesn't support reads.
    /// keyboardVolumePeripheralID/OutputID are daemon-only prefs with no USB opcode.
    ///
    /// `peakHoldMode` and `oversHoldMode` are readable in principle — they are
    /// bytes 2 and 3 of the same `0xDE` block that answers the meter sources — but
    /// neither has a read route or a decode case yet, so they would throw
    /// `unsupportedProperty` if moved out. They stay here until that is built.
    ///
    /// `frontPanelMeterBank`/`metersShowInput` were here too, which meant the
    /// Device Settings > Front Panel pickers never read the device: they showed the
    /// `@State` defaults at `SettingsViews.swift:24-25` and happened to look
    /// plausible. They now read `0xDE`.
    public static let writeOnlySelectors: Set<AudioPropertySelector> = [
        .sampleRate, .clockSource,
        .peakHoldMode, .oversHoldMode, .prefix,
        .keyboardVolumePeripheralID, .keyboardVolumeOutputID
    ]

    // MARK: - Read Request

    /// Build a USB read request for the given property address.
    ///
    /// Returns nil for write-only properties (sampleRate, clockSource) — the caller
    /// must return cached values for those.
    ///
    /// - Throws: `DeviceConnectionError.unsupportedProperty` for unknown selectors.
    public static func buildReadRequest(for address: PropertyAddress) throws -> USBControlRequest {
        let selector = address.selector
        // Truncating: mixer selectors encode (mixerID << 16 | channel) which exceeds UInt16.
        // Mixer cases use splitMixerElement() instead of this variable.
        let channel = UInt16(truncatingIfNeeded: address.element)

        switch selector {
        // Clock status (lock state) — opcode 0x51
        case .clockStatus:
            return SymphonyIORequestBuilder.getClockRateAndLock()

        // Mic preamp
        case .micGain:
            return SymphonyIORequestBuilder.getMicGain(channel: channel)
        case .phantom:
            return SymphonyIORequestBuilder.getPhantomPower(channel: channel)
        case .phaseReverse:
            return USBControlRequest(
                direction: .read,
                request: SymphonyIOCommand.phaseInverse.rawValue,
                index: channel,
                data: Data(count: 1)
            )
        case .highPassFilter:
            return USBControlRequest(
                direction: .read,
                request: SymphonyIOCommand.highPassFilter.rawValue,
                index: channel,
                data: Data(count: 1)
            )

        // Mic preamp — group / insert return. Both are channel-indexed on the
        // wire, so the read mirrors the write exactly.
        //
        // `.insertID` (0xC8) has NO read case on purpose: the write is addressed
        // by INSERT (see buildWriteRequest), while the daemon's unused
        // `getMicPreInsert` (SymphonyIOControl.cpp:1840-1856) is addressed by
        // channel. The two disagree and nothing in the daemon ever calls the
        // getter, so there is no verified read encoding to pin. Insert state is
        // restored from `ChannelStateStore`, like every other per-channel value
        // (Symphony IO MKI vendor EP0 reads fail anyway — see CLAUDE.md).
        case .groupID:
            return SymphonyIORequestBuilder.getChannelGroup(channel: channel)
        case .insertReturnEnable:
            return SymphonyIORequestBuilder.getInsertReturnEnable(channel: channel)

        // Output levels
        case .outputLevel:
            return USBControlRequest(
                direction: .read,
                request: SymphonyIOCommand.speakerOutputVolume.rawValue,
                data: Data(count: 1)
            )
        case .outputMute:
            return USBControlRequest(
                direction: .read,
                request: SymphonyIOCommand.speakerOutputMute.rawValue,
                data: Data(count: 1)
            )
        case .outputDim:
            return SymphonyIORequestBuilder.getMonitorDim(output: .speaker)
        case .headphone1Level:
            return USBControlRequest(
                direction: .read,
                request: SymphonyIOCommand.headphoneVolume.rawValue,
                index: 0,
                data: Data(count: 1)
            )
        case .headphone2Level:
            return USBControlRequest(
                direction: .read,
                request: SymphonyIOCommand.headphoneVolume.rawValue,
                index: 1,
                data: Data(count: 1)
            )

        // Monitor output controls
        case .headphone1Mute:
            return USBControlRequest(
                direction: .read,
                request: SymphonyIOCommand.headphoneMute.rawValue,
                index: 0,
                data: Data(count: 1)
            )
        case .headphone2Mute:
            return USBControlRequest(
                direction: .read,
                request: SymphonyIOCommand.headphoneMute.rawValue,
                index: 1,
                data: Data(count: 1)
            )
        case .headphone1Dim:
            return SymphonyIORequestBuilder.getMonitorDim(output: .headphone1)
        case .headphone2Dim:
            return SymphonyIORequestBuilder.getMonitorDim(output: .headphone2)
        case .headphone1SumToMono:
            return SymphonyIORequestBuilder.getMonitorSumToMono(output: .headphone1)
        case .headphone2SumToMono:
            return SymphonyIORequestBuilder.getMonitorSumToMono(output: .headphone2)
        case .headphone1RoutingID, .headphone2RoutingID:
            return SymphonyIORequestBuilder.getHeadphoneAssignments()
        case .activeSpeakerSet:
            return SymphonyIORequestBuilder.getActiveSpeakerSet()
        case .outputSumToMono:
            return SymphonyIORequestBuilder.getMonitorSumToMono(output: .speaker)

        // Speaker output mode (0x25). Previously absent from BOTH switches, so
        // every read threw .unsupportedProperty and every write was silently
        // discarded before it reached the wire — the "speaker mode popup does
        // nothing" half of the monitor report.
        // Evidence: SymphonyIOControl.cpp:410-427 — getSpeakerOutputMode().
        case .speakerOutputMode:
            return SymphonyIORequestBuilder.getSpeakerMode()

        // Metering — scope selects TDM group: input(0), output(1), mixer(2)
        case .meterData, .streamMeter:
            let group: SymphonyIOMeterGroup
            switch address.scope {
            case .output: group = .output
            case .global: group = .mixer
            default:      group = .input
            }
            return SymphonyIORequestBuilder.getMeterData(group: group)

        // Routing
        case .route, .routing:
            return SymphonyIORequestBuilder.getAudioRoute(destination: channel)

        // Front-panel meter bank source. The `0x10` READ is disabled in the XMOS
        // firmware, so the only readback is `0xDE GetCurrentPreferenceSettings`,
        // whose 4-byte SymphonyIOSettings payload leads with m_cMetersShow1 and
        // m_cMetersShow2 (SymphonyIOVendorSpecific.h:526-530, :1050-1056).
        //
        // Live since 2026-09-11. Both selectors used to sit in `writeOnlySelectors`,
        // so every connection answered reads from its cache and never reached this
        // builder — the pickers showed `@State` defaults that merely looked right.
        //
        // Legacy works the same way: `getFrontPanelMeteringMode` is `#if 0` with the
        // note "Disabled in XMOS!! use getPreferenceSettings instead"
        // (og_source/maestrolink/Software/SymphonyIO/SymphonyIOControl.cpp:64-66),
        // and the daemon seeds its own `m_aMeterShow[]` cache from this same 0xDE
        // block (og_source/maestrolink/Software/SymphonyIO.cpp:1345-1346).
        //
        // 0xDE sends nValue = 0, so wValue and wIndex are both 0 — unaffected by the
        // encoding bug fixed in 95668ac.
        case .frontPanelMeterBank, .metersShowInput:
            guard SymphonyIOFrontPanelMeterBank(propertyElement: address.element) != nil else {
                throw DeviceConnectionError.unsupportedProperty(selector)
            }
            return SymphonyIORequestBuilder.getCurrentPreferenceSettings()

        // Mixer — element encodes (mixerID << 16) | channelIndex.
        // Evidence: SymphonyIOControl.cpp:1904-1942 — nValue = (nMixer << 16) | channel.
        // USB split: wValue = mixerID, wIndex = channelIndex.
        case .mixerChannelLevel:
            let (mixID, chIdx) = Self.splitMixerElement(address.element)
            return USBControlRequest(
                direction: .read,
                request: SymphonyIOCommand.mixerFaderLevel.rawValue,
                value: mixID,
                index: chIdx,
                data: Data(count: 1)
            )
        case .mixerChannelPan:
            let (mixID, chIdx) = Self.splitMixerElement(address.element)
            return USBControlRequest(
                direction: .read,
                request: SymphonyIOCommand.mixerInputPan.rawValue,
                value: mixID,
                index: chIdx,
                data: Data(count: 1)
            )
        case .mixerChannelMute:
            let (mixID, chIdx) = Self.splitMixerElement(address.element)
            return USBControlRequest(
                direction: .read,
                request: SymphonyIOCommand.mixerInputMute.rawValue,
                value: mixID,
                index: chIdx,
                data: Data(count: 1)
            )
        case .mixerChannelSolo:
            let (mixID, chIdx) = Self.splitMixerElement(address.element)
            return USBControlRequest(
                direction: .read,
                request: SymphonyIOCommand.mixerInputSolo.rawValue,
                value: mixID,
                index: chIdx,
                data: Data(count: 1)
            )
        case .mixerSoftwareReturnID:
            return SymphonyIORequestBuilder.getAudioRoute(
                destination: UInt16(Self.softwareReturnRoutingDestination(for: address.element)))

        // Device info
        case .version:
            return SymphonyIORequestBuilder.getFirmwareVersion(type: .mainBoard)
        case .softLimit:
            return USBControlRequest(
                direction: .read,
                request: SymphonyIOCommand.softLimit.rawValue,
                index: channel,
                data: Data(count: 1)
            )
        case .analogIOType:
            return USBControlRequest(
                direction: .read,
                request: SymphonyIOCommand.currentAnalogInputType.rawValue,
                index: channel,
                data: Data(count: 1)
            )
        case .digitalRefLevel:
            let isOutput = address.scope == .output
            return SymphonyIORequestBuilder.getDigitalReferenceLevel(
                channel: channel, isOutput: isOutput)

        // Digital I/O — element selects board (0=primary, 1=secondary)
        case .opticalInFormat, .opticalOutFormat:
            return SymphonyIORequestBuilder.getOpticalFormat(board: UInt16(address.element))
        case .spdifReplaceID:
            return SymphonyIORequestBuilder.getSPDIFCoaxReplaceInput(board: UInt16(address.element))
        case .spdifMirrorID:
            return SymphonyIORequestBuilder.getSPDIFCoaxMirrorOutput(board: UInt16(address.element))

        // Device info
        case .deviceMode:
            return SymphonyIORequestBuilder.getDeviceMode()
        case .primaryBoardType:
            return SymphonyIORequestBuilder.getOptionBoardType(slot: 0)
        case .secondaryBoardType:
            return SymphonyIORequestBuilder.getOptionBoardType(slot: 1)

        // Word clock divide ('AEwd') has NO vendor EP0 opcode on Symphony IO MKI — it was
        // an Ensemble-only HAL-plugin property (mAEstro.h:1036-1039), not a USB command.
        // The old code routed it to proToolsStarSync (0x53), which reads an UNRELATED
        // register ("star sync for Pro Tools HD", SymphonyIOVendorSpecific.h:269-271).
        // Fall through to `default` (throws .unsupportedProperty) until a real path exists.

        default:
            throw DeviceConnectionError.unsupportedProperty(selector)
        }
    }

    // MARK: - Headphone routing register cache

    /// HP1 and HP2 assignments share one hardware register (opcode 0x54):
    /// low nibble = HP1 source, high nibble = HP2 source. Writing one output
    /// must preserve the sibling's nibble — the device has no reliable EP0 read
    /// to fetch the current value, so we cache the last-written nibbles here.
    /// There is a single physical register, so this cache is process-global.
    /// Defaults to 0 — the FIRST output pair. Source IDs are output-pair indices
    /// (`SymphonyIO_Stream.cpp:264-276`), not the `kmAEstroHeadPhoneAssign*`
    /// constants, so "Line 1-2" is 0. The previous default of 1 pre-seeded the
    /// sibling nibble with "Line 3-4".
    private static let hpRoutingLock = NSLock()
    private nonisolated(unsafe) static var cachedHP1Nibble: UInt8 = 0
    private nonisolated(unsafe) static var cachedHP2Nibble: UInt8 = 0

    /// Build a headphone-assignments write that preserves the sibling nibble.
    private static func headphoneAssignmentsRequest(
        settingHP1 hp1: UInt8? = nil,
        settingHP2 hp2: UInt8? = nil
    ) -> USBControlRequest {
        hpRoutingLock.lock()
        defer { hpRoutingLock.unlock() }
        if let hp1 { cachedHP1Nibble = hp1 & 0x0F }
        if let hp2 { cachedHP2Nibble = hp2 & 0x0F }
        return SymphonyIORequestBuilder.setHeadphoneAssignments(
            hp1: cachedHP1Nibble, hp2: cachedHP2Nibble
        )
    }

    // MARK: - Write Request

    /// Build a USB write request for the given property address and value.
    ///
    /// - Throws: `DeviceConnectionError.unsupportedProperty` for unknown selectors,
    ///           `DeviceConnectionError.typeMismatch` for wrong value types.
    public static func buildWriteRequest(for address: PropertyAddress, value: PropertyValue) throws -> USBControlRequest {
        let selector = address.selector
        // Truncating: mixer selectors encode (mixerID << 16 | channel) which exceeds UInt16.
        // Mixer cases use splitMixerElement() instead of this variable.
        let channel = UInt16(truncatingIfNeeded: address.element)

        switch selector {
        // Sample rate
        case .sampleRate:
            guard let hz = value.asFloat64,
                  let code = SymphonyIOSampleRateCode(sampleRate: hz) else {
                throw DeviceConnectionError.typeMismatch(
                    expected: "Float64 (valid sample rate)", got: "\(value)")
            }
            return SymphonyIORequestBuilder.setSampleRate(code)

        // Clock
        case .clockSource:
            guard let raw = value.asUInt32, raw <= UInt32(UInt8.max),
                  let source = SymphonyIOClockSource(rawValue: UInt8(raw)) else {
                throw DeviceConnectionError.typeMismatch(
                    expected: "UInt32 (clock source)", got: "\(value)")
            }
            return SymphonyIORequestBuilder.setClockMode(source: source)

        // Mic preamp
        case .micGain:
            guard let gain = value.asUInt32 else {
                throw DeviceConnectionError.typeMismatch(expected: "UInt32", got: "\(value)")
            }
            return SymphonyIORequestBuilder.setMicGain(channel: channel, gain: UInt8(min(gain, 85)))

        case .phantom:
            guard let enabled = value.asBool else {
                throw DeviceConnectionError.typeMismatch(expected: "Bool", got: "\(value)")
            }
            return SymphonyIORequestBuilder.setPhantomPower(channel: channel, enabled: enabled)

        case .phaseReverse:
            guard let enabled = value.asBool else {
                throw DeviceConnectionError.typeMismatch(expected: "Bool", got: "\(value)")
            }
            return SymphonyIORequestBuilder.setPhaseInvert(channel: channel, enabled: enabled)

        case .highPassFilter:
            guard let enabled = value.asBool else {
                throw DeviceConnectionError.typeMismatch(expected: "Bool", got: "\(value)")
            }
            return SymphonyIORequestBuilder.setHighPassFilter(channel: channel, enabled: enabled)

        case .softLimit:
            guard let raw = value.asUInt32, raw <= UInt32(UInt8.max),
                  let mode = SymphonyIOSoftLimitMode(rawValue: UInt8(raw)) else {
                throw DeviceConnectionError.typeMismatch(
                    expected: "UInt32 (soft limit mode)", got: "\(value)")
            }
            return SymphonyIORequestBuilder.setSoftLimit(channel: channel, mode: mode)

        // MicPre gain group (0xC7) — element is the 0-based channel, value is the
        // group ID (0 = Off, 1...8).
        // Evidence: `SymphonyIOBoard_MicPre8ch.cpp:844` — `setMicPreGroup(nChannel-1, nNewGroupIndex)`.
        case .groupID:
            guard let raw = value.asUInt32,
                  raw <= UInt32(InputChannelLogic.micPreGroupCount) else {
                throw DeviceConnectionError.typeMismatch(
                    expected: "UInt32 group ID 0...\(InputChannelLogic.micPreGroupCount)",
                    got: "\(value)")
            }
            return SymphonyIORequestBuilder.setChannelGroup(channel: channel, group: UInt8(raw))

        // MicPre insert assignment (0xC8) — THE WIRE TRAP.
        //
        // `SymphonyIOVendorSpecific.h:429-431` says "nValue: Channel Index /
        // pData: insert #". The daemon does the OPPOSITE
        // (`SymphonyIOBoard_MicPre8ch.cpp:1790-1810`):
        //
        //     for(nInsert = 0..7)
        //         cNewMask = (some channel holds insert nInsert+1) ? 0x01<<nCh : 0
        //         setMicPreInsert(nInsert, cNewMask)    // wIndex = INSERT
        //
        // So this selector's `element` is the 0-based **INSERT** index and the
        // value is the 0-based **CHANNEL BITMASK**, NOT (channel, insert ID).
        // That is deliberate and matches how this mapper already treats element
        // as "whatever the opcode addresses" (`.outputDim` carries a MonitorOutput,
        // `.opticalInFormat` a board, `.frontPanelMeterBank` a bank).
        //
        // One write moves at most one insert, but the firmware is only ever handed
        // a COMPLETE table: callers send all eight, built by
        // `InputChannelLogic.insertAssignmentMasks(in:)`, because writing mask 0 is
        // the only thing that releases an insert a channel just gave up.
        case .insertID:
            guard let mask = value.asUInt32, mask <= UInt32(UInt8.max) else {
                throw DeviceConnectionError.typeMismatch(
                    expected: "UInt32 channel bitmask 0...255", got: "\(value)")
            }
            guard address.element < UInt32(InputChannelLogic.micPreInsertCount) else {
                throw DeviceConnectionError.invalidElement(address.element)
            }
            return SymphonyIORequestBuilder.setInsertAssignment(
                insert: channel, channelMask: UInt8(mask))

        // MicPre insert return "In" (0xC9) — element is the 0-based channel.
        // This opcode DOES match its header comment.
        // Evidence: `SymphonyIOBoard_MicPre8ch.cpp:554`, `:613` — `SetInsertEn(nChannel-1, …)`.
        case .insertReturnEnable:
            guard let enabled = value.asBool else {
                throw DeviceConnectionError.typeMismatch(expected: "Bool", got: "\(value)")
            }
            return SymphonyIORequestBuilder.setInsertReturnEnable(
                channel: channel, enabled: enabled)

        // Output
        case .outputLevel:
            let outputAttenuation: Int
            if let level = value.asFloat64 {
                outputAttenuation = Int(-level)
            } else if let att = value.asUInt32 {
                outputAttenuation = Int(att)
            } else {
                throw DeviceConnectionError.typeMismatch(expected: "Float64 or UInt32", got: "\(value)")
            }
            return SymphonyIORequestBuilder.setSpeakerVolume(attenuation: UInt8(clamping: outputAttenuation))

        case .outputMute:
            guard let muted = value.asBool else {
                throw DeviceConnectionError.typeMismatch(expected: "Bool", got: "\(value)")
            }
            return SymphonyIORequestBuilder.setSpeakerMute(muted: muted)

        case .outputDim:
            guard let enabled = value.asBool else {
                throw DeviceConnectionError.typeMismatch(expected: "Bool", got: "\(value)")
            }
            return SymphonyIORequestBuilder.setMonitorDim(output: .speaker, enabled: enabled)

        case .outputSumToMono:
            guard let enabled = value.asBool else {
                throw DeviceConnectionError.typeMismatch(expected: "Bool", got: "\(value)")
            }
            return SymphonyIORequestBuilder.setMonitorSumToMono(output: .speaker, enabled: enabled)

        case .headphone1Mute:
            guard let muted = value.asBool else {
                throw DeviceConnectionError.typeMismatch(expected: "Bool", got: "\(value)")
            }
            return SymphonyIORequestBuilder.setHeadphoneMute(channel: 0, muted: muted)

        case .headphone2Mute:
            guard let muted = value.asBool else {
                throw DeviceConnectionError.typeMismatch(expected: "Bool", got: "\(value)")
            }
            return SymphonyIORequestBuilder.setHeadphoneMute(channel: 1, muted: muted)

        case .headphone1Dim:
            guard let enabled = value.asBool else {
                throw DeviceConnectionError.typeMismatch(expected: "Bool", got: "\(value)")
            }
            return SymphonyIORequestBuilder.setMonitorDim(output: .headphone1, enabled: enabled)

        case .headphone2Dim:
            guard let enabled = value.asBool else {
                throw DeviceConnectionError.typeMismatch(expected: "Bool", got: "\(value)")
            }
            return SymphonyIORequestBuilder.setMonitorDim(output: .headphone2, enabled: enabled)

        case .headphone1SumToMono:
            guard let enabled = value.asBool else {
                throw DeviceConnectionError.typeMismatch(expected: "Bool", got: "\(value)")
            }
            return SymphonyIORequestBuilder.setMonitorSumToMono(output: .headphone1, enabled: enabled)

        case .headphone2SumToMono:
            guard let enabled = value.asBool else {
                throw DeviceConnectionError.typeMismatch(expected: "Bool", got: "\(value)")
            }
            return SymphonyIORequestBuilder.setMonitorSumToMono(output: .headphone2, enabled: enabled)

        // Headphone source ID. The 0x54 register holds one 4-BIT nibble per
        // headphone, so only 0-15 can be represented — legacy logs an error for
        // anything larger (SymphonyIOControl.cpp:826-833). Reject rather than mask:
        // masking turned "Optical 7-8" (the Ensemble-style ID 17) into 1, silently
        // re-selecting "Line 1-2", and the UI had no way to notice.
        case .headphone1RoutingID:
            guard let raw = value.asUInt32 else {
                throw DeviceConnectionError.typeMismatch(expected: "UInt32", got: "\(value)")
            }
            guard SymphonyIOHeadphoneRouting.isValidSourceID(raw) else {
                throw DeviceConnectionError.typeMismatch(
                    expected: "UInt32 headphone source ID 0-15", got: "\(raw)")
            }
            // Preserve HP2's nibble — shared register (S2).
            return headphoneAssignmentsRequest(settingHP1: UInt8(raw))

        case .headphone2RoutingID:
            guard let raw = value.asUInt32 else {
                throw DeviceConnectionError.typeMismatch(expected: "UInt32", got: "\(value)")
            }
            guard SymphonyIOHeadphoneRouting.isValidSourceID(raw) else {
                throw DeviceConnectionError.typeMismatch(
                    expected: "UInt32 headphone source ID 0-15", got: "\(raw)")
            }
            // Preserve HP1's nibble — shared register (S2).
            return headphoneAssignmentsRequest(settingHP2: UInt8(raw))

        case .activeSpeakerSet:
            guard let mask = value.asUInt32 else {
                throw DeviceConnectionError.typeMismatch(expected: "UInt32", got: "\(value)")
            }
            return SymphonyIORequestBuilder.setActiveSpeakerSet(mask: UInt8(mask & 0x07))

        // Speaker output mode (0x25). The legal IDs are NON-CONTIGUOUS
        // (0, 2, 6, 8, 9, 10 — SymphonyIOVendorSpecific.h:967-975), so a raw
        // integer that happens to be a popup row index must be rejected rather
        // than truncated onto a neighbouring mode. `UpdateMainOutputChannelMode`
        // does the same, returning kAudioHardwareUnsupportedOperationError for an
        // unknown mode (SymphonyIO.cpp:6185-6190).
        case .speakerOutputMode:
            guard let raw = value.asUInt32 else {
                throw DeviceConnectionError.typeMismatch(expected: "UInt32", got: "\(value)")
            }
            guard raw <= UInt32(UInt8.max),
                  let mode = SymphonyIOSpeakerMode(rawValue: UInt8(raw)) else {
                throw DeviceConnectionError.typeMismatch(
                    expected: "UInt32 (one of 0, 2, 6, 8, 9, 10 — SymphonyIOSpeakerMode)",
                    got: "\(value)")
            }
            return SymphonyIORequestBuilder.setSpeakerMode(mode)

        case .headphone1Level:
            let hp1Attenuation: Int
            if let level = value.asFloat64 { hp1Attenuation = Int(-level) }
            else if let att = value.asUInt32 { hp1Attenuation = Int(att) }
            else { throw DeviceConnectionError.typeMismatch(expected: "Float64 or UInt32", got: "\(value)") }
            return SymphonyIORequestBuilder.setHeadphoneVolume(channel: 0, attenuation: UInt8(clamping: hp1Attenuation))

        case .headphone2Level:
            let hp2Attenuation: Int
            if let level = value.asFloat64 { hp2Attenuation = Int(-level) }
            else if let att = value.asUInt32 { hp2Attenuation = Int(att) }
            else { throw DeviceConnectionError.typeMismatch(expected: "Float64 or UInt32", got: "\(value)") }
            return SymphonyIORequestBuilder.setHeadphoneVolume(channel: 1, attenuation: UInt8(clamping: hp2Attenuation))

        // Mixer — element encodes (mixerID << 16) | channelIndex.
        // USB split: wValue = mixerID, wIndex = channelIndex.
        case .mixerChannelLevel:
            guard let level = value.asFloat64 else {
                throw DeviceConnectionError.typeMismatch(expected: "Float64", got: "\(value)")
            }
            let scaled = UInt8(clamping: Int(level + 48))
            let (mixID, chIdx) = Self.splitMixerElement(address.element)
            return USBControlRequest(
                direction: .write,
                request: SymphonyIOCommand.mixerFaderLevel.rawValue,
                value: mixID,
                index: chIdx,
                data: Data([scaled])
            )

        case .mixerChannelPan:
            guard let pan = value.asFloat64 else {
                throw DeviceConnectionError.typeMismatch(expected: "Float64", got: "\(value)")
            }
            let scaled = UInt8(clamping: Int((pan + 1.0) * 64.0))
            let (mixID, chIdx) = Self.splitMixerElement(address.element)
            return USBControlRequest(
                direction: .write,
                request: SymphonyIOCommand.mixerInputPan.rawValue,
                value: mixID,
                index: chIdx,
                data: Data([scaled])
            )

        case .mixerChannelMute:
            guard let muted = value.asBool else {
                throw DeviceConnectionError.typeMismatch(expected: "Bool", got: "\(value)")
            }
            let (mixID, chIdx) = Self.splitMixerElement(address.element)
            return USBControlRequest(
                direction: .write,
                request: SymphonyIOCommand.mixerInputMute.rawValue,
                value: mixID,
                index: chIdx,
                data: Data([muted ? 1 : 0])
            )

        case .mixerChannelSolo:
            guard let solo = value.asBool else {
                throw DeviceConnectionError.typeMismatch(expected: "Bool", got: "\(value)")
            }
            let (mixID, chIdx) = Self.splitMixerElement(address.element)
            return USBControlRequest(
                direction: .write,
                request: SymphonyIOCommand.mixerInputSolo.rawValue,
                value: mixID,
                index: chIdx,
                data: Data([solo ? 1 : 0])
            )

        case .mixerSoftwareReturnID:
            guard let raw = value.asUInt32,
                  let source = SymphonyIOSoftwareReturnSource(rawValue: raw) else {
                throw DeviceConnectionError.typeMismatch(
                    expected: "UInt32 software return source 0...7", got: "\(value)")
            }
            let sourceByte = SymphonyIORoutingAddress.p2pBase &+ UInt8(source.rawValue * 2)
            let destination = Self.softwareReturnRoutingDestination(for: address.element)
            // The original SymphonyIOMixer writes both stereo application-input
            // destinations in one 0x31 transfer. Writing only L leaves R stale
            // and makes AEsR read-back appear inconsistent on hardware.
            return SymphonyIORequestBuilder.setAudioRoutes([
                (destination: destination, source: sourceByte),
                (destination: destination &+ 1, source: sourceByte &+ 1)
            ])

        // Routing
        case .route, .routing:
            guard let source = value.asUInt32 else {
                throw DeviceConnectionError.typeMismatch(expected: "UInt32", got: "\(value)")
            }
            return SymphonyIORequestBuilder.setAudioRoutes([
                (destination: UInt8(truncatingIfNeeded: channel),
                 source: UInt8(truncatingIfNeeded: source))
            ])

        // Reset Routing ('AEt2') is deliberately NOT mapped to opcode 0xC2.
        //
        // 0xC2 is the FIRMWARE's routing reset — a flat 1:1 map with no knowledge
        // of which board slot holds which card. The legacy USB routing controller
        // never issues it; it computes the board-aware default table in software
        // and writes it as ordinary 0x31 pairs
        // (SymphonyIOUSBAudioRoutingController.cpp:623-712 / :714-812). Only the
        // PCIe controller calls 0xC2 (SymphonyIORoutingController.cpp:371-381).
        //
        // Routing a blind 1:1 map onto a unit with an optical card re-points the
        // ADAT destinations, which is precisely the regression we must not ship.
        // Reset is therefore composed in the app from explicit 0x31 writes; see
        // OutputRoutingView.defaultOutputRoutes / InputRoutingView.defaultInputRoutes.
        case .resetRouting:
            throw DeviceConnectionError.unsupportedProperty(selector)

        // Meter config
        case .peakHoldMode:
            guard let raw = value.asUInt32 else {
                throw DeviceConnectionError.typeMismatch(expected: "UInt32", got: "\(value)")
            }
            return USBControlRequest(
                direction: .write,
                request: SymphonyIOCommand.peakHold.rawValue,
                data: Data([UInt8(truncatingIfNeeded: raw)])
            )

        case .oversHoldMode:
            guard let raw = value.asUInt32 else {
                throw DeviceConnectionError.typeMismatch(expected: "UInt32", got: "\(value)")
            }
            return USBControlRequest(
                direction: .write,
                request: SymphonyIOCommand.overHold.rawValue,
                data: Data([UInt8(truncatingIfNeeded: raw)])
            )

        case .peaksClear:
            return USBControlRequest(
                direction: .write,
                request: SymphonyIOCommand.clearMeters.rawValue,
                data: Data([0])
            )

        // Digital I/O — element selects board (0=primary, 1=secondary)
        case .opticalInFormat, .opticalOutFormat:
            guard let raw = value.asUInt32 else {
                throw DeviceConnectionError.typeMismatch(expected: "UInt32", got: "\(value)")
            }
            return SymphonyIORequestBuilder.setOpticalFormat(
                board: UInt16(truncatingIfNeeded: address.element),
                format: UInt8(truncatingIfNeeded: raw))

        case .spdifReplaceID:
            guard let raw = value.asUInt32 else {
                throw DeviceConnectionError.typeMismatch(expected: "UInt32", got: "\(value)")
            }
            return SymphonyIORequestBuilder.setSPDIFCoaxReplaceInput(
                board: UInt16(truncatingIfNeeded: address.element),
                replacement: UInt8(truncatingIfNeeded: raw))

        case .spdifMirrorID:
            guard let raw = value.asUInt32 else {
                throw DeviceConnectionError.typeMismatch(expected: "UInt32", got: "\(value)")
            }
            return SymphonyIORequestBuilder.setSPDIFCoaxMirrorOutput(
                board: UInt16(truncatingIfNeeded: address.element),
                mirror: UInt8(truncatingIfNeeded: raw))

        // Front panel meter config — sent to hardware, verified 2026-09-11.
        //
        // `wValue` selects the physical LED bank; `pData[0]` selects which channel
        // octet it shows — Analog Out 9-16 needs payload 4. The previous builder
        // hardcoded pData[0] = 0, which made channels 9-16 unreachable and is the
        // reported "bank source does nothing". It also returned a 0xFF sentinel,
        // and 0xFF is the connectivityVerification READ opcode, so the XPC and
        // dext paths were sending that instead.
        //
        // The 2026-02-22 EP0 wedge (Docs/Learnings.md) was that malformed request.
        // The shape below is the legacy-correct one and survived hardware test with
        // vendor reads still working afterwards. See allowFrontPanelMeterWrites.
        //
        // `'AEmi'` addresses banks 1-based (`m_aMeterShow[nChan-1]`,
        // SymphonyIO.cpp:2574-2619); element 0 is also accepted as bank 1 so a
        // caller that already converted does not double-decrement.
        case .frontPanelMeterBank, .metersShowInput:
            guard let raw = value.asUInt32 else {
                throw DeviceConnectionError.typeMismatch(expected: "UInt32", got: "\(value)")
            }
            guard let bank = SymphonyIOFrontPanelMeterBank(propertyElement: address.element),
                  raw <= UInt32(UInt8.max),
                  let source = SymphonyIOFrontPanelMeterSource(rawValue: UInt8(raw)) else {
                throw DeviceConnectionError.typeMismatch(
                    expected: "bank element 1/2 and a UInt32 eMaestroEnum_MetersShowValues (0-15)",
                    got: "element \(address.element), value \(value)")
            }
            guard Self.allowFrontPanelMeterWrites else {
                throw DeviceConnectionError.cacheOnly(selector)
            }
            return SymphonyIORequestBuilder.setFrontPanelMeterShow(bank: bank, source: source)

        // Peripheral prefix — display-only name prefix. The XMOS firmware has no
        // USB opcode for this, so it is cache-only (never send the 0xFF sentinel).
        case .prefix:
            throw DeviceConnectionError.cacheOnly(selector)

        // Analog reference level (+ optional trim encoded in upper byte)
        // Encoding: bits[7:0] = type, bits[15:8] = trim (UInt8 bit-pattern of Int8 tenths-of-dB)
        // A trim byte of 127 (0x7F) means "do not set" (SymphonyIOConstants.doNotSetTrimValue).
        case .analogIOType:
            guard let raw = value.asUInt32 else {
                throw DeviceConnectionError.typeMismatch(expected: "UInt32", got: "\(value)")
            }
            let isOutput = address.scope == .output
            let type = UInt8(raw & 0xFF)
            let trimByte = UInt8((raw >> 8) & 0xFF)
            return SymphonyIORequestBuilder.setAnalogReferenceLevel(
                channel: channel, isOutput: isOutput, type: type, trimValue: trimByte)

        // Digital reference level
        case .digitalRefLevel:
            guard let raw = value.asUInt32 else {
                throw DeviceConnectionError.typeMismatch(expected: "UInt32", got: "\(value)")
            }
            let isOutput = address.scope == .output
            return SymphonyIORequestBuilder.setDigitalReferenceLevel(
                channel: channel, isOutput: isOutput, level: UInt8(truncatingIfNeeded: raw))

        default:
            throw DeviceConnectionError.unsupportedProperty(selector)
        }
    }

    // MARK: - Response Decoder

    /// Decode a USB response into a PropertyValue for the given address.
    ///
    /// - Parameters:
    ///   - response: The raw USB response data.
    ///   - address: The property address that was queried.
    ///   - cachedSampleRate: Caller-provided cached sample rate for write-only fallback.
    ///   - cachedClockSource: Caller-provided cached clock source for write-only fallback.
    public static func decodeResponse(
        _ response: USBControlResponse,
        for address: PropertyAddress,
        cachedSampleRate: Double = 48000,
        cachedClockSource: UInt32 = 0
    ) throws -> PropertyValue {
        let data = response.data

        switch address.selector {
        // Sample rate: never decoded from USB (opcode 0x03 is write-only).
        case .sampleRate:
            return .float64(cachedSampleRate)

        // Clock source is cached — safety fallback.
        case .clockSource:
            return .uint32(cachedClockSource)

        case .clockStatus:
            guard data.count >= 1 else {
                throw DeviceConnectionError.transportError("Empty clock status response")
            }
            return .uint32(UInt32(data[0]))

        // Single-byte boolean values
        case .phantom, .phaseReverse, .highPassFilter, .outputMute,
             .headphone1Mute, .headphone2Mute,
             .headphone1Dim, .headphone2Dim,
             .headphone1SumToMono, .headphone2SumToMono,
             .outputSumToMono, .insertReturnEnable,
             .mixerChannelMute, .mixerChannelSolo:
            guard let byte = data.first else {
                throw DeviceConnectionError.transportError("Empty bool response")
            }
            return .bool(byte != 0)

        // HP source: decode from headphone assignments byte
        case .headphone1RoutingID:
            guard let byte = data.first else {
                throw DeviceConnectionError.transportError("Empty HP assignment response")
            }
            return .uint32(UInt32(byte & 0x0F))

        case .headphone2RoutingID:
            guard let byte = data.first else {
                throw DeviceConnectionError.transportError("Empty HP assignment response")
            }
            return .uint32(UInt32((byte >> 4) & 0x0F))

        // Active speaker set: raw bitmask
        case .activeSpeakerSet:
            guard let byte = data.first else {
                throw DeviceConnectionError.transportError("Empty speaker set response")
            }
            return .uint32(UInt32(byte & 0x07))

        // Single-byte UInt32 values
        case .micGain, .softLimit, .analogIOType, .digitalRefLevel,
             .opticalInFormat, .opticalOutFormat, .spdifReplaceID, .spdifMirrorID,
             .deviceMode, .speakerOutputMode, .groupID,
             .primaryBoardType, .secondaryBoardType:
            guard let byte = data.first else {
                throw DeviceConnectionError.transportError("Empty uint8 response")
            }
            return .uint32(UInt32(byte))

        // Volume/attenuation → Float64 (negate for dB)
        case .outputLevel:
            guard let byte = data.first else {
                throw DeviceConnectionError.transportError("Empty level response")
            }
            return .float64(Double(-Int(byte)))

        case .headphone1Level, .headphone2Level:
            guard let byte = data.first else {
                throw DeviceConnectionError.transportError("Empty hp level response")
            }
            return .float64(Double(-Int(byte)))

        case .outputDim:
            guard let byte = data.first else {
                throw DeviceConnectionError.transportError("Empty dim response")
            }
            return .bool(byte != 0)

        // Mixer fader: 0-54 → -48..+6 dB
        case .mixerChannelLevel:
            guard let byte = data.first else {
                throw DeviceConnectionError.transportError("Empty fader response")
            }
            return .float64(Double(Int(byte) - 48))

        // Mixer pan: 0-128 → -1.0..+1.0
        case .mixerChannelPan:
            guard let byte = data.first else {
                throw DeviceConnectionError.transportError("Empty pan response")
            }
            return .float64((Double(byte) / 64.0) - 1.0)

        case .mixerSoftwareReturnID:
            guard let source = data.first,
                  source >= SymphonyIORoutingAddress.p2pBase,
                  source <= SymphonyIORoutingAddress.p2pBase &+ 14,
                  (source &- SymphonyIORoutingAddress.p2pBase).isMultiple(of: 2) else {
                throw DeviceConnectionError.transportError("Invalid software return route")
            }
            return .uint32(UInt32((source &- SymphonyIORoutingAddress.p2pBase) / 2))

        // Front-panel meter bank source, extracted from the 0xDE settings block.
        // Byte 0 is bank 1 (meters 1-8), byte 1 is bank 2 (meters 9-16).
        case .frontPanelMeterBank, .metersShowInput:
            guard let settings = SymphonyIOPreferenceSettings(data: data) else {
                throw DeviceConnectionError.transportError(
                    "Short preference-settings response (\(data.count) of 4 bytes)")
            }
            let bank = SymphonyIOFrontPanelMeterBank(propertyElement: address.element) ?? .left
            let source = bank == .left ? settings.meterSourceBank1 : settings.meterSourceBank2
            guard let source else {
                throw DeviceConnectionError.transportError(
                    "Device reported an unknown meter source for bank \(bank.rawValue + 1)")
            }
            return .uint32(UInt32(source.rawValue))

        // Routing: single byte source index
        case .route, .routing:
            guard let byte = data.first else {
                throw DeviceConnectionError.transportError("Empty route response")
            }
            return .uint32(UInt32(byte))

        // Meter data: raw bytes
        case .meterData, .streamMeter:
            return .data(data)

        // Firmware version: 3 bytes (major.minor.build)
        case .version:
            guard data.count >= 3 else {
                throw DeviceConnectionError.transportError("Short version response")
            }
            return .string("\(data[0]).\(data[1]).\(data[2])")

        default:
            if data.count == 1 {
                return .uint32(UInt32(data[0]))
            } else {
                return .data(data)
            }
        }
    }

    // MARK: - Helpers

    /// Split a compound mixer element into (mixerID, channelIndex).
    /// Mixer elements are encoded as `(mixerID << 16) | channelIndex`.
    /// Evidence: SymphonyIOControl.cpp:1904-1942 — nValue = (nMixer << 16) | (nChannel & 0xFFFF).
    /// USB split: wValue = nMixer, wIndex = channel.
    public static func splitMixerElement(_ element: UInt32) -> (mixerID: UInt16, channelIndex: UInt16) {
        (UInt16(element >> 16), UInt16(element & 0xFFFF))
    }

    /// Software-return property elements carry the mixer ID in the high word,
    /// matching mixer channel elements. For compatibility with CoreAudio callers
    /// that pass the legacy zero-based mixer element, accept a bare 0/1 too.
    public static func softwareReturnRoutingDestination(for element: UInt32) -> UInt8 {
        let encodedMixer = UInt16(element >> 16)
        // The current UI uses 1-based mixer IDs in the high word. A bare
        // zero-based element is accepted for CoreAudio compatibility.
        let mixerIndex = encodedMixer == 0
            ? UInt16(element & 0xFFFF)
            : encodedMixer &- 1
        return mixerIndex == 0
            ? SymphonyIORoutingAddress.mixer0AppInputBase
            : SymphonyIORoutingAddress.mixer1AppInputBase
    }
}
