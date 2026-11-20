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

public enum MixerFaderMath {
    /// The mixer's fader range, dB.
    public static let range: ClosedRange<Double> = -48...6

    private static func clamp(_ value: Double) -> Double {
        value.isNaN ? 0 : min(max(value, range.lowerBound), range.upperBound)
    }

    /// Software Return on USB. The unit has one fader per strip, so an unlinked
    /// pair sends the quieter side: never louder than either fader shows. The
    /// helper stays at 0 dB.
    public static func softwareReturn(
        left: Double, right: Double, linked: Bool, linkedLevel: Double
    ) -> Double {
        linked ? clamp(linkedLevel) : min(clamp(left), clamp(right))
    }

    /// Master. Same rule: one fader per mixer, no software stage, so an
    /// unlinked pair sends the quieter side.
    public static func master(
        left: Double, right: Double, linked: Bool, linkedLevel: Double
    ) -> Double {
        linked ? clamp(linkedLevel) : min(clamp(left), clamp(right))
    }
}

// MARK: - Left/right pairs

/// The Master and Software Return left/right fader pairs. Each pair is one
/// stereo fader drawn with two handles that always move together, as in
/// Apogee's Maestro (user guide, July 2018: "Software Return: Stereo fader",
/// "Mixer Master: Stereo Master fader"; its mixer code writes one level into
/// both sides on every transport). The Symphony's own mixer, used over USB,
/// has one fader per strip (`kSymphonyIOMixer_FaderCount = 34`: 32 inputs,
/// Software Return, Master).
///
/// Earlier versions of this app had a link button that could unlink a pair
/// over ThunderBridge. `savedLinked` is that old saved flag: a pair saved
/// unlinked is shown, and sent, at its quieter side.
public enum MixerPairLink {
    public struct Pair: Equatable, Sendable {
        public let left: Double
        public let right: Double
        public let linked: Bool
    }

    /// What the pair shows: both faders at `linkedLevel`, or at the quieter
    /// side if an earlier version saved the pair unlinked.
    public static func shown(
        left: Double, right: Double, savedLinked: Bool, linkedLevel: Double
    ) -> Pair {
        let level = savedLinked ? linkedLevel : min(left, right)
        return Pair(left: level, right: level, linked: true)
    }

    /// Rewrite pairs that an earlier version saved unlinked as linked pairs at
    /// their quieter side, so nothing gets louder. Run once at launch, before
    /// anything reads the saved mixer state. Does nothing when both flags are
    /// already linked (or were never saved).
    public static func migrateSavedPairs(defaults: UserDefaults) {
        migrateSavedPairs(preferences: MixerPreferences(legacyDefaults: defaults))
    }

    public static func migrateSavedPairs(preferences defaults: MixerPreferences) {
        if defaults.object(forKey: "mixerMasterFadersLinked") as? Bool == false {
            for m in 0..<2 {
                let saved = MixerStateSnapshot.savedMasterLevel(mixer: m, preferences: defaults)
                let left = defaults.object(forKey: "mixerMasterLeftLevel_\(m)") as? Double ?? saved
                let right = defaults.object(forKey: "mixerMasterRightLevel_\(m)") as? Double ?? saved
                let level = min(left, right)
                defaults.set(level, forKey: "mixerMasterLevel_\(m)")
                defaults.set(level, forKey: "mixerMasterLeftLevel_\(m)")
                defaults.set(level, forKey: "mixerMasterRightLevel_\(m)")
            }
            defaults.set(true, forKey: "mixerMasterFadersLinked")
        }
        if defaults.object(forKey: "mixerSWReturnFadersLinked") as? Bool == false {
            for m in 0..<2 {
                let saved = MixerStateSnapshot.savedSoftwareReturn(mixer: m, preferences: defaults).level
                let left = defaults.object(forKey: "mixerSWReturnLeftLevel_\(m)") as? Double ?? saved
                let right = defaults.object(forKey: "mixerSWReturnRightLevel_\(m)") as? Double ?? saved
                let level = min(left, right)
                defaults.set(level, forKey: "mixerSWReturnLeftLevel_\(m)")
                defaults.set(level, forKey: "mixerSWReturnRightLevel_\(m)")
            }
            defaults.set(true, forKey: "mixerSWReturnFadersLinked")
        }
    }

    /// The level the unit's single fader gets over USB: what the pair shows.
    public static func usbUnitLevel(
        left: Double, right: Double, savedLinked: Bool, linkedLevel: Double
    ) -> Double {
        let pair = shown(left: left, right: right, savedLinked: savedLinked,
                         linkedLevel: linkedLevel)
        return MixerFaderMath.master(left: pair.left, right: pair.right, linked: true,
                                     linkedLevel: pair.left)
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
        /// This mixer's own Software Return mute and solo (level unused here).
        public var softwareReturn: MixerChannelState

        public init(masterLevel: Double, masterLeft: Double, masterRight: Double,
                    softwareReturnLeft: Double, softwareReturnRight: Double, softwareReturnSource: UInt32,
                    softwareReturn: MixerChannelState = MixerChannelState(level: 0, pan: 0, isMuted: false, isSoloed: false)) {
            self.masterLevel = masterLevel; self.masterLeft = masterLeft; self.masterRight = masterRight
            self.softwareReturnLeft = softwareReturnLeft; self.softwareReturnRight = softwareReturnRight
            self.softwareReturnSource = softwareReturnSource; self.softwareReturn = softwareReturn
        }
    }

    /// Whether the helper's one software mute should be on. The helper renders
    /// "Maestro USB" into USB playback 1-2 before either mixer, so it may only
    /// mute when every mixer that takes that pair is muted; a mixer on another
    /// source does not hear the helper at all.
    public var helperMuted: Bool {
        let onDefaultPair = mixes.filter { $0.softwareReturnSource == 0 }
        return !onDefaultPair.isEmpty && onDefaultPair.allSatisfy { $0.softwareReturn.isMuted }
    }

    public var mixes: [Mix]
    public var masterLinked: Bool
    public var softwareReturnLinked: Bool


    /// Read the keys the page writes: `mixerMasterLevel_<n>`,
    /// `mixerMasterLeftLevel_<n>`/`RightLevel_<n>`, `mixerMasterFadersLinked`,
    /// `mixerSWReturnLeftLevel_<n>`/`RightLevel_<n>`, `mixerSWReturnFadersLinked`,
    /// `mixerState_swReturn_<n>` (or the older shared `mixerState_swReturn`),
    /// `mixerSoftwareReturnSource_<n>`. Missing keys
    /// default exactly as the page does.
    public static func load(defaults: UserDefaults) -> USBMixerSavedState {
        load(preferences: MixerPreferences(legacyDefaults: defaults))
    }

    public static func load(preferences defaults: MixerPreferences) -> USBMixerSavedState {
        let mixes = (0..<2).map { m -> Mix in
            let swReturn = MixerStateSnapshot.savedSoftwareReturn(mixer: m, preferences: defaults)
            let master = MixerStateSnapshot.savedMasterLevel(mixer: m, preferences: defaults)
            return Mix(
                masterLevel: master,
                masterLeft: defaults.object(forKey: "mixerMasterLeftLevel_\(m)") as? Double ?? master,
                masterRight: defaults.object(forKey: "mixerMasterRightLevel_\(m)") as? Double ?? master,
                softwareReturnLeft: defaults.object(forKey: "mixerSWReturnLeftLevel_\(m)") as? Double ?? swReturn.level,
                softwareReturnRight: defaults.object(forKey: "mixerSWReturnRightLevel_\(m)") as? Double ?? swReturn.level,
                softwareReturnSource: UInt32(clamping: defaults.integer(forKey: "mixerSoftwareReturnSource_\(m)")),
                softwareReturn: swReturn)
        }
        return USBMixerSavedState(
            mixes: mixes,
            masterLinked: defaults.object(forKey: "mixerMasterFadersLinked") as? Bool ?? true,
            softwareReturnLinked: defaults.object(forKey: "mixerSWReturnFadersLinked") as? Bool ?? true)
    }
}

/// The writes that put the unit and the helper back to what Maestro shows.
public enum USBMixerRestorePlan {
    public enum Step: Equatable, Sendable {
        /// A write to the unit's mixer, addressed with the real strip numbers.
        case hardware(PropertyAddress, PropertyValue)
        /// The helper's software level to 0 dB, with the saved Software
        /// Return mute (the helper renders "Maestro USB", so a mute applies
        /// there as well as on the unit). Solo has no helper step.
        case helperNeutral(muted: Bool)
        case helperPan(Double)
        case helperProcessing(Bool)
    }

    /// The unit's strips come first, for both mixers. The helper may still hold
    /// an attenuation or mute from an older Maestro while the unit sits at 0 dB,
    /// so it is only made neutral once the unit has taken its values: no
    /// sequence is louder than the faders show.
    ///
    /// - Parameter helperMixer: kept for the pan rule (the helper has one pan
    ///   for both mixers, shared state); the level is no longer split.
    public static func steps(for state: USBMixerSavedState, helperMixer: Int = 0) -> [Step] {
        var steps: [Step] = []
        for (m, mix) in state.mixes.enumerated() {
            let id = UInt32(m + 1) << 16
            func at(_ selector: AudioPropertySelector, _ strip: UInt16) -> PropertyAddress {
                PropertyAddress(selector: selector, element: id | UInt32(strip))
            }
            steps.append(.hardware(
                at(.mixerChannelLevel, USBMixerStrip.master),
                .float64(MixerPairLink.usbUnitLevel(
                    left: mix.masterLeft, right: mix.masterRight,
                    savedLinked: state.masterLinked, linkedLevel: mix.masterLevel))))
            steps.append(.hardware(
                at(.mixerChannelLevel, USBMixerStrip.softwareReturn),
                .float64(MixerPairLink.usbUnitLevel(
                    left: mix.softwareReturnLeft, right: mix.softwareReturnRight,
                    savedLinked: state.softwareReturnLinked, linkedLevel: mix.softwareReturnLeft))))
            steps.append(.hardware(
                at(.mixerChannelMute, USBMixerStrip.softwareReturn),
                .bool(mix.softwareReturn.isMuted)))
            steps.append(.hardware(
                at(.mixerChannelSolo, USBMixerStrip.softwareReturn),
                .bool(mix.softwareReturn.isSoloed)))
        }
        steps.append(.helperNeutral(muted: state.helperMuted))
        // No Software Return pan: the helper's balance is always centred.
        steps.append(.helperPan(0))
        // Same rule as the Mixer page: on when either mixer uses the default pair.
        steps.append(.helperProcessing(state.mixes.contains { $0.softwareReturnSource == 0 }))
        return steps
    }
}
