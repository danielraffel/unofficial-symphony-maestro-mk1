import Foundation
import MaestroDevice

/// USB only: what the meter loop reads from the unit, and how often.
///
/// Every meter read is a control transfer to the Symphony's USB controller,
/// which also serves the audio stream. Apogee's daemon read a meter group only
/// while a client had asked for those meters within the last second
/// (og_source/maestrolink/Software/SymphonyIO_IOBoard.cpp:199-250,
/// SymphonyIO.cpp:6904-7038). Maestro 0.9.25 read 19-36 groups a second for as
/// long as it was connected, whatever was on screen, and Maestro USB audio cut
/// out while it was open and not while it was closed (2026-11-23).
///
/// So the meters a page shows are read only while that page is on screen in a
/// window that can be seen, and nothing is read otherwise. The Input page
/// reads the input group, the Output page the output group, and the Mixer page
/// the input group (its strips) and the mixer group (Software Return and
/// Master), less often, so no page reads more than about 20 groups a second.
struct USBMeterPlan: Equatable {
    /// A page that shows meters is on screen: the cycle runs (it may still
    /// read nothing from the unit, e.g. software output meters).
    var active = false
    var input = false
    var output = false
    var mixer = false
    /// Pause after the cycle.
    var interval: Duration = Self.idleInterval

    /// Pause between looks at the screen while no meter is visible: the
    /// meters start within this time when a meter page is shown again.
    static let idleInterval: Duration = .milliseconds(250)

    /// Unit groups this cycle reads.
    var reads: Int { [input, output, mixer].filter { $0 }.count }

    /// - Parameters:
    ///   - area: the page on screen.
    ///   - windowVisible: Maestro's window is on screen (not hidden,
    ///     minimized or covered).
    ///   - outputGroupUsable: the unit answers the output and mixer groups
    ///     with meter data (false once they are known to be residue).
    static func plan(area: NavigationArea, windowVisible: Bool, outputGroupUsable: Bool) -> USBMeterPlan {
        guard windowVisible else { return USBMeterPlan() }
        switch area {
        case .input:
            return USBMeterPlan(active: true, input: true, interval: .milliseconds(50))
        case .output:
            // Software output meters stand in when the group is residue; they
            // come from the helper, not the unit.
            return USBMeterPlan(active: true, output: outputGroupUsable, interval: .milliseconds(50))
        case .mixer:
            // Two groups a cycle: half the cycle rate keeps the total near 20 a second.
            return USBMeterPlan(active: true, input: true, mixer: outputGroupUsable, interval: .milliseconds(100))
        case .inputRouting, .outputRouting, .deviceSettings, .appSettings:
            return USBMeterPlan()
        }
    }
}

/// USB only: tells a unit that really went away (powered off, unplugged, the
/// helper lost its handle) from a read that failed once.
///
/// Coming back from a real loss puts everything the Mac owns back on the unit
/// (the full restore). Before 0.9.26 one failed meter read was enough: the
/// helper then refuses meter reads for 2 s (`METER_BACKOFF_SEC` in
/// Drivers/VolumeProxy/MaestroVolumeProxy.c), the next good read looked like a
/// unit coming back, and the restore silenced every output fed from a mixer
/// for the seconds it took. Apogee restored once per unit start, when the
/// firmware said it had finished starting (SymphonyIO.cpp:6338-6432), never
/// after a failed read.
///
/// A loss is real when the helper says it has no unit open, the app has no
/// helper connection, or reads have kept failing for longer than the helper's
/// backoff.
struct USBLossDetector: Equatable {
    enum Failure: Equatable {
        /// The helper has no unit open, or there is no helper connection.
        case unitGone
        /// Any other failed read (a timeout, the helper's meter backoff).
        case readFailed
    }

    /// Failed reads for longer than this are a loss: longer than the helper's
    /// 2 s meter backoff, so the backoff alone never counts.
    static let sustainedFailure: TimeInterval = 2.5

    private(set) var failingSince: Date?
    private(set) var lost = false

    /// A read failed (any read: a meter read or the heartbeat).
    mutating func failed(_ failure: Failure, at now: Date) {
        if failingSince == nil { failingSince = now }
        if failure == .unitGone { lost = true }
        if let since = failingSince, now.timeIntervalSince(since) > Self.sustainedFailure { lost = true }
    }

    /// A read succeeded. True when the reads before it were a real loss: the
    /// unit is back and is put right.
    mutating func succeeded() -> Bool {
        defer { failingSince = nil; lost = false }
        return lost
    }

    /// Reads are failing now (whatever the reason).
    var isFailing: Bool { failingSince != nil }

    static func failure(for error: Error) -> Failure {
        if case DeviceConnectionError.notConnected = error { return .unitGone }
        return .readFailed
    }
}
