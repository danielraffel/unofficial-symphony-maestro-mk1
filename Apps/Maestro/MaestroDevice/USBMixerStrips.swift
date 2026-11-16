import Foundation
import MaestroCore

// MARK: - Strip addresses

/// How the Symphony's own mixer numbers its strips on USB: inputs 0-31, then
/// Software Return, then Master.
///
/// Evidence: `og_source/symphonymk1/ext/SymphonyIO/generic/Products/SymphonyIO/
/// SymphonyIOVendorSpecific.h` (~1097-1120) and the original daemon,
/// `og_source/maestrolink/Software/SymphonyIOMixer.cpp` (~287-452), which sends
/// 32 and 33. Measured on the unit: 0xB0/0xB2/0xB3 at 32 and 0xB0 at 33 change
/// the audio; the same commands at 1000/2000 do nothing.
///
/// 1000 and 2000 are the CoreAudio-level IDs for the same strips. The
/// ThunderBridge driver translates those itself and keeps receiving them.
public enum USBMixerStrip {
    public static let softwareReturn: UInt16 = 32
    public static let master: UInt16 = 33

    /// CoreAudio-level IDs (ThunderBridge only; never on the USB wire).
    public static let softwareReturnLogicalID: UInt16 = 1000
    public static let masterLogicalID: UInt16 = 2000

    /// Channel IDs that must never reach the USB wire.
    public static let neverOnUSBWire: Set<UInt16> = [
        1000, 2000, 0x1001, 0x1002, 0x2001, 0x2002,
    ]
}

/// Translates the app's mixer addresses to what the unit understands on USB.
///
/// `SymphonyIOPropertyMapper` is shared with the ThunderBridge connection (it
/// builds the requests the driver receives), so it is left alone. The two USB
/// connections call this before the mapper instead.
public enum USBMixerAddressing {
    private static let mixerSelectors: Set<AudioPropertySelector> = [
        .mixerChannelLevel, .mixerChannelPan, .mixerChannelMute, .mixerChannelSolo,
    ]

    /// The address to hand to the mapper on USB. Non-mixer addresses and input
    /// strips (0-31) come back unchanged.
    ///
    /// - 1000 becomes 32 and 2000 becomes 33.
    /// - Pan on Software Return or Master is refused: the strips have none.
    /// - The stereo side IDs and anything else past Master are refused.
    public static func usbAddress(for address: PropertyAddress) throws -> PropertyAddress {
        guard mixerSelectors.contains(address.selector) else { return address }
        let mixer = address.element & 0xFFFF_0000
        let channel = UInt16(address.element & 0xFFFF)
        let target: UInt16
        switch channel {
        case 0...31:
            return address
        case USBMixerStrip.softwareReturn, USBMixerStrip.softwareReturnLogicalID:
            target = USBMixerStrip.softwareReturn
        case USBMixerStrip.master, USBMixerStrip.masterLogicalID:
            target = USBMixerStrip.master
        default:
            throw DeviceConnectionError.unsupportedProperty(address.selector)
        }
        if address.selector == .mixerChannelPan {
            throw DeviceConnectionError.unsupportedProperty(address.selector)
        }
        return PropertyAddress(
            selector: address.selector, scope: address.scope,
            element: mixer | UInt32(target))
    }
}

// MARK: - Fader arithmetic

/// What one Software Return fader pair becomes: one hardware fader plus the
/// helper's per-side attenuation.
public struct SoftwareReturnFaderSplit: Equatable, Sendable {
    /// The mixer strip's single fader, dB.
    public let hardwareLevel: Double
    /// Attenuation relative to `hardwareLevel`, dB. Never above 0; one side of
    /// an unlinked pair is exactly 0.
    public let leftTrim: Double
    public let rightTrim: Double
}

public enum MixerFaderMath {
    /// The mixer's fader range, dB.
    public static let range: ClosedRange<Double> = -48...6

    private static func clamp(_ value: Double) -> Double {
        value.isNaN ? 0 : min(max(value, range.lowerBound), range.upperBound)
    }

    /// Software Return. The strip has one fader, so an unlinked pair puts the
    /// louder side on it and leaves the difference to the helper's per-side
    /// gains. Linked, the helper stays at 0 dB on both sides and the fader
    /// takes `linkedLevel`.
    public static func softwareReturn(
        left: Double, right: Double, linked: Bool, linkedLevel: Double
    ) -> SoftwareReturnFaderSplit {
        if linked {
            return SoftwareReturnFaderSplit(
                hardwareLevel: clamp(linkedLevel), leftTrim: 0, rightTrim: 0)
        }
        let l = clamp(left), r = clamp(right)
        let loud = max(l, r)
        return SoftwareReturnFaderSplit(
            hardwareLevel: loud, leftTrim: l - loud, rightTrim: r - loud)
    }

    /// Master. The unit has one Master fader per mixer and no software stage,
    /// so an unlinked pair sends the quieter side: never louder than either
    /// fader shows.
    public static func master(
        left: Double, right: Double, linked: Bool, linkedLevel: Double
    ) -> Double {
        linked ? clamp(linkedLevel) : min(clamp(left), clamp(right))
    }
}

// MARK: - Connect-time restore

/// The saved Master and Software Return state for both mixers, as the Mixer
/// page keeps it in `UserDefaults`.
public struct USBMixerSavedState: Equatable, Sendable {
    public struct Mix: Equatable, Sendable {
        public var masterLevel: Double
        public var masterLeft: Double
        public var masterRight: Double
        public var softwareReturnLeft: Double
        public var softwareReturnRight: Double
        public var softwareReturnSource: UInt32
    }

    public var mixes: [Mix]
    public var masterLinked: Bool
    public var softwareReturnLinked: Bool
    /// Level (unused here), pan, mute and solo are shared by both mixers.
    public var softwareReturn: MixerChannelState

    /// Read the keys the page writes: `mixerMasterLevel_<n>`,
    /// `mixerMasterLeftLevel_<n>`/`RightLevel_<n>`, `mixerMasterFadersLinked`,
    /// `mixerSWReturnLeftLevel_<n>`/`RightLevel_<n>`, `mixerSWReturnFadersLinked`,
    /// `mixerState_swReturn`, `mixerSoftwareReturnSource_<n>`. Missing keys
    /// default exactly as the page does.
    public static func load(defaults: UserDefaults = .standard) -> USBMixerSavedState {
        let swReturn = MixerStateSnapshot.savedSoftwareReturn(defaults: defaults)
        let mixes = (0..<2).map { m -> Mix in
            let master = MixerStateSnapshot.savedMasterLevel(mixer: m, defaults: defaults)
            return Mix(
                masterLevel: master,
                masterLeft: defaults.object(forKey: "mixerMasterLeftLevel_\(m)") as? Double ?? master,
                masterRight: defaults.object(forKey: "mixerMasterRightLevel_\(m)") as? Double ?? master,
                softwareReturnLeft: defaults.object(forKey: "mixerSWReturnLeftLevel_\(m)") as? Double ?? swReturn.level,
                softwareReturnRight: defaults.object(forKey: "mixerSWReturnRightLevel_\(m)") as? Double ?? swReturn.level,
                softwareReturnSource: UInt32(clamping: defaults.integer(forKey: "mixerSoftwareReturnSource_\(m)")))
        }
        return USBMixerSavedState(
            mixes: mixes,
            masterLinked: defaults.object(forKey: "mixerMasterFadersLinked") as? Bool ?? true,
            softwareReturnLinked: defaults.object(forKey: "mixerSWReturnFadersLinked") as? Bool ?? true,
            softwareReturn: swReturn)
    }
}

/// The writes that put the unit and the helper back to what Maestro shows.
public enum USBMixerRestorePlan {
    public enum Step: Equatable, Sendable {
        /// A write to the unit's mixer, addressed with the real strip numbers.
        case hardware(PropertyAddress, PropertyValue)
        /// The helper's software Software Return stage.
        case helperLevel(Double)
        case helperMute(Bool)
        case helperSideLevel(side: Int, dB: Double)
        case helperPan(Double)
    }

    /// - Parameter helperMixer: the mixer (0 or 1) whose page last drove the
    ///   helper. The helper has one software stage for both mixers; it only
    ///   carries pan and the unlinked left/right difference, and only for a
    ///   mixer whose Software Return source is USB playback 1-2.
    public static func steps(for state: USBMixerSavedState, helperMixer: Int) -> [Step] {
        var steps: [Step] = [
            // The unit's mixer is the authority for level and mute. A helper
            // that still holds an attenuation or mute from an older app must
            // not apply it a second time.
            .helperLevel(0),
            .helperMute(false),
        ]
        func split(_ mix: USBMixerSavedState.Mix) -> SoftwareReturnFaderSplit {
            MixerFaderMath.softwareReturn(
                left: mix.softwareReturnLeft, right: mix.softwareReturnRight,
                linked: state.softwareReturnLinked, linkedLevel: mix.softwareReturnLeft)
        }
        let order = [helperMixer, 1 - helperMixer].filter { (0..<state.mixes.count).contains($0) }
        if let m = order.first(where: { state.mixes[$0].softwareReturnSource == 0 }),
           !state.softwareReturnLinked {
            let s = split(state.mixes[m])
            steps.append(.helperSideLevel(side: 0, dB: s.leftTrim))
            steps.append(.helperSideLevel(side: 1, dB: s.rightTrim))
        }
        steps.append(.helperPan(state.softwareReturn.pan))

        for (m, mix) in state.mixes.enumerated() {
            let id = UInt32(m + 1) << 16
            func at(_ selector: AudioPropertySelector, _ strip: UInt16) -> PropertyAddress {
                PropertyAddress(selector: selector, element: id | UInt32(strip))
            }
            steps.append(.hardware(
                at(.mixerChannelLevel, USBMixerStrip.master),
                .float64(MixerFaderMath.master(
                    left: mix.masterLeft, right: mix.masterRight,
                    linked: state.masterLinked, linkedLevel: mix.masterLevel))))
            steps.append(.hardware(
                at(.mixerChannelLevel, USBMixerStrip.softwareReturn),
                .float64(split(mix).hardwareLevel)))
            steps.append(.hardware(
                at(.mixerChannelMute, USBMixerStrip.softwareReturn),
                .bool(state.softwareReturn.isMuted)))
            steps.append(.hardware(
                at(.mixerChannelSolo, USBMixerStrip.softwareReturn),
                .bool(state.softwareReturn.isSoloed)))
        }
        return steps
    }
}
