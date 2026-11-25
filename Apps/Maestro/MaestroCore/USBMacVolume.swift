import Foundation

/// The level of the Mac's "Symphony I/O : Maestro USB" volume control, as the
/// scalar Core Audio exchanges for it.
///
/// The audio plug-in's control (`Drivers/AudioServerPlugin/ApogeeDriver.cpp`,
/// raw 0...64 for -64...0 dB, attenuation = 64 - raw) is a libASPL
/// `VolumeControl`. libASPL's `VolumeCurve` applies its default transfer
/// function, `kPow2Over1Curve`, because the range is wider than 30 dB
/// (`libaspl-src/src/VolumeCurve.cpp`):
///
///     ConvertRawToScalar: scalar = ((raw - min) / range) ^ (2 / 1)
///     ConvertScalarToRaw: raw = min + roundf(range * scalar ^ (1 / 2))
///
/// So the scalar is NOT linear in dB. Writing `(dB + 64) / 64` put -52 dB on
/// the control as raw 28, attenuation 36, and the helper sent that louder
/// level to the unit; reading it back with the same linear formula showed
/// -52 again, so nothing on screen gave it away.
///
/// Both directions go through this one type so there is never a second
/// correction. The scalar transport is kept (rather than the decibel
/// property) because it is the one the out-of-process plug-in is known to
/// receive on macOS 26.
public enum USBMacVolume {
    /// The control's raw range and dB range (ApogeeDriver.cpp VolumeControlParameters).
    public static let rawRange: Int = 64

    /// The attenuation shown on the Mac's control for a level in dB: never less
    /// than the level asks for, so the Mac's control (and the helper, which
    /// sends it to the unit) can never be louder than the level. Whole dB
    /// levels, which is all the knobs, the front panel and the keys produce,
    /// map exactly.
    public static func attenuation(forDB dB: Double) -> Int {
        guard dB.isFinite else { return rawRange }
        // A hair of tolerance so -52.000000001 is 52, not 53.
        let att = (-dB - 1e-6).rounded(.up)
        return Int(max(0, min(Double(rawRange), att)))
    }

    /// The scalar to write for a level in dB: the exact inverse of libASPL's
    /// `ConvertScalarToRaw` for the attenuation above.
    public static func scalar(forDB dB: Double) -> Float32 {
        let raw = Float32(rawRange - attenuation(forDB: dB))
        let linear = raw / Float32(rawRange)
        return linear * linear
    }

    /// The raw value libASPL stores for a scalar (`ConvertScalarToRaw`, in
    /// Float32 as there).
    public static func raw(forScalar scalar: Float32) -> Int {
        let s = min(1, max(0, scalar.isFinite ? scalar : 0))
        let steps = (powf(s, 1.0 / 2.0) * Float32(rawRange)).rounded()
        return Int(steps)
    }

    /// The level in dB the control holds, from the scalar read back.
    public static func dB(forScalar scalar: Float32) -> Double {
        Double(raw(forScalar: scalar) - rawRange)
    }
}
