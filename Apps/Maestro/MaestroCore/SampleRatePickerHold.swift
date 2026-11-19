import Foundation

/// How long the Sample Rate picker stays disabled after the hardware has
/// accepted a new rate.
///
/// The computer reporting the new rate is not quite the end of the change:
/// the Symphony's clock re-acquires and its relays click a moment later. The
/// picker used to stay disabled for the whole 5 second window Apogee's daemon
/// gave the source to stabilise, which felt stuck. It now comes back as soon
/// as the clock has re-locked, but never sooner than `minimum` (the relays)
/// and never later than `maximum`. The clock status keeps its own 5 second
/// grace (`AppState.suppressClockLockReporting`), so a late re-lock is still
/// not shown as "Clock Mismatch".
public enum SampleRatePickerHold {
    /// Never released sooner than this after the new rate is reported.
    public static let minimum: Duration = .milliseconds(1500)
    /// Always released by this time, locked or not.
    public static let maximum: Duration = .milliseconds(3000)
    /// How often the clock is checked between the two.
    public static let pollInterval: Duration = .milliseconds(250)

    /// True when the picker may come back, `elapsed` after the hardware
    /// reported the new rate.
    public static func shouldRelease(elapsed: Duration, clockLocked: Bool) -> Bool {
        if elapsed >= maximum { return true }
        return elapsed >= minimum && clockLocked
    }
}
