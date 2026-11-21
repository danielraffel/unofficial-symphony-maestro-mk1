/// Trims applied to the host-playback peaks that drive the Software Return
/// meters on ThunderBridge.
///
/// On ThunderBridge the card FPGA mixer applies the Software Return fader and
/// mute and the app only sees the host playback before the mixer, so the
/// meters stayed full whatever the strip said. Applying the same trims here
/// makes the meters follow the strip.
///
/// Software Return has no pan (0.9.21): callers pass centre. The pan law is
/// kept because the card mixer still has one; it mirrors that balance law exactly
/// (`Drivers/Thunderbolt/Source/SymphonyMixerPan.h`): the centre and the
/// favoured side stay at unity, the opposite side fades linearly in dB to a
/// -48 dB floor. The pan byte is the same `(pan + 1) * 64` encoding the
/// property mapper sends with MixerInputPan (0xB1).
import Foundation

public enum SoftwareReturnMeterGain {

    /// `side` is the 0...128 attenuation-table index for one output side.
    public static func panAttenuationDB(side: Int) -> Int {
        let s = max(0, min(128, side))
        if s >= 64 { return 0 }
        return -((48 * (64 - s) + 32) / 64)
    }

    /// Pan position (-1...+1) to the 0...128 byte the hardware receives.
    public static func panByte(_ pan: Double) -> Int {
        max(0, min(128, Int((max(-1.0, min(1.0, pan)) + 1.0) * 64.0)))
    }

    /// Linear gains for the left and right meter, from the strip's own
    /// faders (dB, clamped to the card mixer's -48...0 range), pan and mute.
    public static func gains(leftLevelDB: Double, rightLevelDB: Double,
                             pan: Double, isMuted: Bool) -> (left: Double, right: Double) {
        if isMuted { return (0.0, 0.0) }
        let byte = panByte(pan)
        let leftDB = max(-48.0, min(0.0, leftLevelDB)) + Double(panAttenuationDB(side: 128 - byte))
        let rightDB = max(-48.0, min(0.0, rightLevelDB)) + Double(panAttenuationDB(side: byte))
        func linear(_ dB: Double) -> Double { dB <= -48.0 ? 0.0 : pow(10.0, dB / 20.0) }
        return (linear(leftDB), linear(rightDB))
    }
}
