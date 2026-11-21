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

    /// What the helper's software stage should do, given which mixers are
    /// routed to an output (see ``USBHelperSoftwareReturn``).
    public func helper(routedToOutput: [Bool]) -> USBHelperSoftwareReturn.State {
        USBHelperSoftwareReturn.state(mixes.enumerated().map { index, mix in
            .init(source: mix.softwareReturnSource, muted: mix.softwareReturn.isMuted,
                  routedToOutput: index < routedToOutput.count && routedToOutput[index])
        })
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

/// The one rule for the helper's software Software Return stage over USB.
///
/// The helper renders "Maestro USB" into USB playback 1-2, ahead of the unit:
/// a mute there silences everything that pair feeds, a direct output included.
/// Apogee's Software Return mute lived in the mixer and never touched a direct
/// output (og_source/maestrolink/Software/SymphonyIOMixer.cpp:287-452 writes
/// strip 32 of the mixer only). So the helper acts only while a mixer that
/// takes USB 1-2 as its Software Return is routed to some output, and then
/// mutes only when every such mixer is muted. With the default routing (no
/// mixer on any output) it is neutral: not processing, not muted.
///
/// There is no balance: Software Return has no pan, and the helper's stays
/// centred.
public enum USBHelperSoftwareReturn {
    public struct Mixer: Equatable, Sendable {
        /// Software Return source pair, 0 = USB 1-2.
        public var source: UInt32
        public var muted: Bool
        /// Whether this mixer feeds at least one output in Output Routing.
        public var routedToOutput: Bool

        public init(source: UInt32, muted: Bool, routedToOutput: Bool) {
            self.source = source; self.muted = muted; self.routedToOutput = routedToOutput
        }
    }

    public struct State: Equatable, Sendable {
        /// Whether the helper's software stage is in the path at all.
        public var processing: Bool
        public var muted: Bool

        public init(processing: Bool, muted: Bool) {
            self.processing = processing; self.muted = muted
        }

        public static let neutral = State(processing: false, muted: false)
    }

    public static func state(_ mixers: [Mixer]) -> State {
        let heard = mixers.filter { $0.source == 0 && $0.routedToOutput }
        guard !heard.isEmpty else { return .neutral }
        return State(processing: true, muted: heard.allSatisfy(\.muted))
    }

    /// Which of the two mixers feed an output, from the Output Routing rows
    /// (software pairs first, then Mixer 1 and Mixer 2).
    public static func mixersRouted(rows: [Int: Set<Int>], softwarePairs: Int) -> [Bool] {
        (0..<2).map { !(rows[softwarePairs + $0] ?? []).isEmpty }
    }
}

/// The writes that put the unit and the helper back to what Maestro shows.
public enum USBMixerRestorePlan {
    public enum Step: Equatable, Sendable {
        /// A write to the unit's mixer, addressed with the real strip numbers.
        case hardware(PropertyAddress, PropertyValue)
        /// The helper's software level to 0 dB, with the mute
        /// ``USBHelperSoftwareReturn`` allows. Solo has no helper step.
        case helperNeutral(muted: Bool)
        case helperProcessing(Bool)
    }

    /// The unit's strips come first, for both mixers. The helper may still hold
    /// an attenuation or mute from an older Maestro while the unit sits at 0 dB,
    /// so it is only made neutral once the unit has taken its values: no
    /// sequence is louder than the faders show.
    ///
    /// - Parameter helperMixer: unused (the helper has no per-mixer state).
    /// - Parameter routedToOutput: which mixers feed an output in Output
    ///   Routing; the helper is neutral for the rest (``USBHelperSoftwareReturn``).
    public static func steps(for state: USBMixerSavedState, helperMixer: Int = 0,
                             routedToOutput: [Bool] = [false, false]) -> [Step] {
        var steps: [Step] = []
        for (m, mix) in state.mixes.enumerated() {
            let id = UInt32(m + 1) << 16
            func at(_ selector: AudioPropertySelector, _ strip: UInt16) -> PropertyAddress {
                PropertyAddress(selector: selector, element: id | UInt32(strip))
            }
            // The Software Return source first: the helper no longer programs
            // it, and a power-cycled unit comes back on its own default. A
            // source the USB modes cannot carry is left alone.
            if mix.softwareReturnSource < 8 {
                steps.append(.hardware(PropertyAddress(selector: .mixerSoftwareReturnID, element: id),
                                       .uint32(mix.softwareReturnSource)))
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
        let helper = state.helper(routedToOutput: routedToOutput)
        steps.append(.helperNeutral(muted: helper.muted))
        steps.append(.helperProcessing(helper.processing))
        return steps
    }

    /// The input strips of both mixers, saved or default (0 dB, centre,
    /// unmuted, no solo: og_source/maestrolink/Software/SymphonyIOMixer.h:28-33).
    /// The unit keeps its mixer until it is power-cycled and comes back at its
    /// own defaults after one, so every strip is written, not only saved ones:
    /// a strip then always does what Maestro shows. Level before mute, so an
    /// unmute never precedes its level.
    ///
    /// - Parameter hardwareIndexes: the unit's channel number of each strip,
    ///   in strip order (`CardLayout.mixerChannels`).
    public static func stripSteps(saved: [[MixerChannelState]], hardwareIndexes: [Int]) -> [Step] {
        var steps: [Step] = []
        for mixer in 0..<2 {
            let states = mixer < saved.count ? saved[mixer] : []
            for (strip, channel) in hardwareIndexes.enumerated() where (0...31).contains(channel) {
                steps += stripSteps(mixer: mixer, channel: channel,
                                    state: strip < states.count ? states[strip] : defaultStrip)
            }
        }
        return steps
    }

    /// A strip nobody has saved: 0 dB, centre, unmuted, no solo.
    public static let defaultStrip = MixerChannelState(level: 0, pan: 0, isMuted: false, isSoloed: false)

    /// One input strip's four writes: level, pan, mute, solo.
    public static func stripSteps(mixer: Int, channel: Int, state: MixerChannelState) -> [Step] {
        func at(_ selector: AudioPropertySelector) -> PropertyAddress {
            PropertyAddress(selector: selector, element: UInt32(mixer + 1) << 16 | UInt32(channel))
        }
        return [
            .hardware(at(.mixerChannelLevel), .float64(state.level)),
            .hardware(at(.mixerChannelPan), .float64(state.pan)),
            .hardware(at(.mixerChannelMute), .bool(state.isMuted)),
            .hardware(at(.mixerChannelSolo), .bool(state.isSoloed)),
        ]
    }
}
