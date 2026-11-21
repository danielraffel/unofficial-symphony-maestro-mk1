import Foundation

/// The Software Return part of a mixer's Master meter over USB.
///
/// Over USB the helper measures host playback before the unit's mixer, so the
/// app adds a mixer's Software Return to its Master meter itself. That part
/// must follow the path the audio takes inside the mixer: the mixer's own
/// Software Return fader and mute, then its Master fader
/// (og_source/maestrolink/Software/SymphonyIOMixer.cpp:287-452: strip 32 is the
/// return, 33 the master). The raw peak used to be taken as it was, so the
/// Master meter ignored all three.
public enum USBMasterMeter {
    /// The unit's fader range over USB, dB. The bottom of the fader is off.
    public static let faderRange: ClosedRange<Double> = -48...6

    private static func linear(_ dB: Double) -> Double {
        guard dB.isFinite, dB > faderRange.lowerBound else { return 0 }
        return pow(10.0, min(dB, faderRange.upperBound) / 20.0)
    }

    /// Linear gain from host playback to the mixer's output for its Software
    /// Return: zero when the return is muted or either fader is at the bottom.
    public static func gain(softwareReturnLevelDB: Double, softwareReturnMuted: Bool,
                            masterLevelDB: Double) -> Double {
        softwareReturnMuted ? 0 : linear(softwareReturnLevelDB) * linear(masterLevelDB)
    }

    /// The Master meter reading (dBFS, floored at -60): the louder of what the
    /// unit reports for the mixer's output and the Software Return peak after
    /// `gain`.
    public static func level(unitMaster: Double, softwareReturnPeak: Float, gain: Double) -> Double {
        let scaled = Float(max(0, gain)) * max(0, softwareReturnPeak)
        return max(unitMaster, SoftwareOutputMeterMap.dBFS(linearPeak: scaled))
    }
}
