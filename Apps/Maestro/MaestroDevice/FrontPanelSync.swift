import Foundation
import MaestroCore

/// The unit's answer to vendor read `0x28`, "parameter updates": what its front
/// panel currently has selected and whether someone is changing it.
///
/// This is how Apogee's daemon kept the Maestro window in step with the encoder.
/// A thread polled this read and pushed level, mute and clock changes to the UI
/// (`og_source/maestrolink/Software/SymphonyIO.cpp:6460-6871`); its gain branch
/// handles MicPre1…8 and calls `UpdateMicPreGain`
/// (`og_source/maestrolink/Software/SymphonyIO.cpp:6613-6719`); nothing on the
/// unit notifies the host. Layout is `SymphonyIOParameterUpdates`
/// (`SymphonyIOVendorSpecific.h:1036-1046`), 12 bytes, sample rate big-endian.
///
/// Measured on a Symphony I/O MK I over USB, 2026-11-13, while the encoder was
/// turned and pressed: selection 0/1/2 with the attenuation following every
/// click, `popupNeedsUpdate` 1 while a front panel change is in progress and 0
/// about 0.4 s after it stops, `allMuted` pulsing 2 then 1 for mute-all then
/// unmute-all, `metersCleared` pulsing on a front panel meter clear.
public struct SymphonyIOParameterUpdates: Sendable, Equatable {
    public enum Selection: UInt8, Sendable {
        case headphone1 = 0, headphone2 = 1, speaker = 2
        case micPre1 = 3, micPre2 = 4, micPre3 = 5, micPre4 = 6
        case micPre5 = 7, micPre6 = 8, micPre7 = 9, micPre8 = 10

        public var micPreChannel: Int? {
            switch self {
            case .micPre1: return 0; case .micPre2: return 1
            case .micPre3: return 2; case .micPre4: return 3
            case .micPre5: return 4; case .micPre6: return 5
            case .micPre7: return 6; case .micPre8: return 7
            default: return nil
            }
        }
    }

    public enum MuteAll: UInt8, Sendable {
        case none = 0, unmute = 1, mute = 2
    }

    public let measuredSampleRate: UInt32
    public let externalClockLocked: Bool
    public let clockSource: UInt8
    public let boardClockSource: UInt8
    public let muteAll: MuteAll
    /// What the encoder is controlling. Unknown indices are ignored.
    public let selection: Selection?
    /// Attenuation of the selected output in dB, from 0 (loudest) to 64 for the
    /// speaker or 127 for a headphone.
    public let selectionAttenuation: UInt8
    public let popupNeedsUpdate: Bool
    public let metersCleared: Bool

    public static let byteCount = 12

    /// Nil for a short reply or one that cannot be a real reading. A dead
    /// control endpoint answers with 0xFF bytes or stack residue, and neither
    /// may be allowed to move a volume control.
    public init?(data: Data) {
        guard data.count >= Self.byteCount else { return nil }
        let b = [UInt8](data.prefix(Self.byteCount))
        measuredSampleRate = (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
        guard (32_000...200_000).contains(measuredSampleRate),
              b[4] <= 1, b[10] <= 1, b[11] <= 1,
              let mute = MuteAll(rawValue: b[7]) else { return nil }
        // The speaker output attenuates 0-64 dB, the headphones 0-127
        // (`SymphonyIOVendorSpecific.h:112-129`), the same ranges as the
        // on-screen knobs. A value outside the selected output's range is not a
        // reading.
        let selected = Selection(rawValue: b[8])
        guard b[9] <= (selected == .speaker ? 64 : 127) else { return nil }
        externalClockLocked = b[4] == 1
        clockSource = b[5]
        boardClockSource = b[6]
        muteAll = mute
        selection = selected
        selectionAttenuation = b[9]
        popupNeedsUpdate = b[10] == 1
        metersCleared = b[11] == 1
    }

    /// `SendRequest(false, 0x28, nValue: 1, 12 bytes)`
    /// (`SymphonyIOControl.cpp:1468-1487`); nValue 1 splits to wValue 0, wIndex 1.
    public static var readRequest: USBControlRequest {
        USBControlRequest(direction: .read, request: 0x28, value: 0, index: 1,
                          data: Data(count: byteCount))
    }
}

/// Turns a stream of parameter-update readings into the changes the app should
/// show. Pure, so the rules can be tested without hardware.
///
/// Rules, following the original:
/// - A level is taken only while the unit says a front panel change is in
///   progress (`popupNeedsUpdate`), plus the first reading after it ends, which
///   carries the value the encoder stopped on. A level the app itself just
///   wrote never raises that flag, so the app's own changes are not echoed
///   back and a stale reading cannot fight a slider being dragged.
/// - Mute-all, unmute-all and a meter clear are one-shot pulses, applied on
///   their rising edge.
public struct FrontPanelSync: Sendable {
    public struct ObservedGain: Sendable, Equatable {
        public let channel: Int
        public let lane: UInt32
        public let gain: Double
    }

    /// Per-unit saved strips, using the original's common limited group offset.
    /// Return host notifications only; never consume GainChangeResult.hardwareWrites.
    /// Evidence: og_source/maestrolink/Software/SymphonyIO.cpp:6688-6718;
    /// SymphonyIOBoard_MicPre8ch.cpp:186-330.
    public static func applyGain(_ gain: Double, channel: Int,
                                 to saved: inout [InputChannelState]) -> [ObservedGain] {
        guard (0..<InputChannelLogic.micPreChannelCount).contains(channel), saved.indices.contains(channel),
              let level = AnalogInputLevel(rawValue: saved[channel].inputType),
              level == .mic || level == .instrument else { return [] }
        let result = InputChannelLogic.applyGainChange(&saved, channel: channel, to: gain)
        // Include the selected channel even if saved state already matches: HAL
        // may not yet know that value (e.g. the first observation after opening).
        return Set(result.changed + [channel]).sorted().filter { $0 < 8 }.map {
            ObservedGain(channel: $0, lane: saved[$0].inputType == AnalogInputLevel.instrument.rawValue ? 1 : 0,
                         gain: saved[$0].gain)
        }
    }

    public enum Change: Sendable, Equatable {
        /// Level in dB for one output, 0 down to -64. `settled` is true for
        /// the value the encoder stopped on, false while it is still turning.
        case level(SymphonyIOParameterUpdates.Selection, Double, settled: Bool)
        /// Mic/Instrument gain in dB for one of the eight MicPre channels.
        case micPreGain(channel: Int, Double, settled: Bool)
        case muteAll(Bool)
        /// The meters were cleared from the front panel.
        case metersCleared
    }

    private var changeInProgress = false
    private var lastMuteAll: SymphonyIOParameterUpdates.MuteAll = .none
    private var lastMetersCleared = false

    public init() {}

    public mutating func changes(for update: SymphonyIOParameterUpdates) -> [Change] {
        var result: [Change] = []
        if let selection = update.selection, update.popupNeedsUpdate || changeInProgress {
            if let channel = selection.micPreChannel {
                // The front-panel register carries the selected preamp gain
                // directly (0...85 dB for Mic; the app clamps Instrument to
                // its 0...65 dB range when it knows that channel's type).
                result.append(.micPreGain(channel: channel, Double(update.selectionAttenuation),
                                          settled: !update.popupNeedsUpdate))
            } else {
            // Every monitor output bottoms out at 64 dB of attenuation on the
            // unit's front panel and in the original software, which clamped a
            // headphone there (`SymphonyIO.cpp:5574-5586`) although the wire
            // format allows 127. The on-screen knobs use the same 0 to -64 range.
            result.append(.level(selection, -Double(min(update.selectionAttenuation, 64)),
                                 settled: !update.popupNeedsUpdate))
            }
        }
        changeInProgress = update.popupNeedsUpdate
        if update.muteAll != lastMuteAll, update.muteAll != .none {
            result.append(.muteAll(update.muteAll == .mute))
        }
        lastMuteAll = update.muteAll
        if update.metersCleared, !lastMetersCleared { result.append(.metersCleared) }
        lastMetersCleared = update.metersCleared
        return result
    }

    /// Forget any change in progress: used across a reconnect.
    public mutating func reset() { self = FrontPanelSync() }
}
