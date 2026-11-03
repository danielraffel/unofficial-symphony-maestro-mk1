/// Endpoint liveness for a Symphony I/O behind a ThunderBridge.
///
/// The ThunderBridge PCI function, its Core Audio device, and the dext all stay
/// enumerated when the downstream Symphony loses power. The only evidence that a
/// Symphony is actually there is (a) a live XLink transaction answered by the
/// unit and (b) the XLink 1 status register reporting the link up *right now*.
/// The dext's `kSelectorReadTimingHealth` performs (a) and hands back the raw
/// status word; this file performs (b) on the app side so the verdict does not
/// depend on which dext build happens to own the card (an upgrade can leave the
/// previous build running for a long time — see Docs/Learnings.md 2026-10-21).
///
/// The fault bits and policy mirror the legacy Symphony 64 driver's periodic
/// link check, `XLink::CheckLinkStatus`
/// (og_source/symphonymk1/ext/Symphony64/Driver/XLink.cpp:2004-2012), which
/// fails the link on `XLINK_RX1_8_DOWN_CURRENT | XLINK_RX1_8_SLIP_CURRENT |
/// XLINK_DATA_DOWN_CURRENT`. Register layout:
/// og_source/symphonymk1/ext/maestrolink/SymphonyAPI/pci2k5_sys.h:79-99.

import Foundation

/// XLink 1 status register (`kRegXLink1Status`, BAR offset 0x40) bits.
public enum XLinkStatusBit {
    public static let rx1_8DownSticky:  UInt32 = 0x0000_0001
    public static let dataDownSticky:   UInt32 = 0x0000_0010
    public static let rx1_8SlipSticky:  UInt32 = 0x0000_0020
    public static let dataSlipSticky:   UInt32 = 0x0000_0200
    public static let rx1_8DownCurrent: UInt32 = 0x0000_0400
    public static let dataDownCurrent:  UInt32 = 0x0000_4000
    public static let rx1_8SlipCurrent: UInt32 = 0x0000_8000
    public static let dataSlipCurrent:  UInt32 = 0x0008_0000
    public static let slaveMode:        UInt32 = 0x0010_0000
}

/// A current-state (non-sticky) link fault that disqualifies the endpoint.
public enum ThunderboltLinkFault: String, CaseIterable, Sendable {
    case rx1_8Down = "RX1_8_DOWN"
    case rx1_8Slip = "RX1_8_SLIP"
    case dataDown  = "DATA_DOWN"
    case dataSlip  = "DATA_SLIP"
    /// dext 113 link watch: the card sees no Symphony clock (unit off, PC-32 out).
    /// Not a status-register bit — `mask` is 0 so `faults(in:)` never derives it.
    case noClock   = "NO_CLOCK"
    /// dext 113 link watch: clock returned, XLink bus re-init in progress.
    case recovering = "RECOVERING"

    public var mask: UInt32 {
        switch self {
        case .rx1_8Down: return XLinkStatusBit.rx1_8DownCurrent
        case .rx1_8Slip: return XLinkStatusBit.rx1_8SlipCurrent
        case .dataDown:  return XLinkStatusBit.dataDownCurrent
        case .dataSlip:  return XLinkStatusBit.dataSlipCurrent
        case .noClock, .recovering: return 0
        }
    }
}

/// What one health probe proved about the downstream Symphony.
public enum ThunderboltEndpointVerdict: Equatable, Sendable {
    /// The dext answered a live XLink read and the link reports no current fault.
    case live(TimingHealth)
    /// The dext selector failed: no user client, the XLink read timed out, or
    /// the dext itself rejected the link state (build 106+ does this too).
    case unavailable
    /// The dext returned a snapshot but the status register says the link is
    /// down or slipping right now, so the answer cannot have come from a
    /// powered, locked Symphony.
    case linkDown(TimingHealth, faults: [ThunderboltLinkFault])

    public var isLive: Bool {
        if case .live = self { return true }
        return false
    }

    /// Short label for logs and diagnostics.
    public var label: String {
        switch self {
        case .live: return "live"
        case .unavailable: return "unavailable"
        case .linkDown(_, let faults):
            return "linkDown[" + faults.map(\.rawValue).joined(separator: ",") + "]"
        }
    }

    public var health: TimingHealth? {
        switch self {
        case .live(let h), .linkDown(let h, _): return h
        case .unavailable: return nil
        }
    }
}

public enum ThunderboltEndpointHealth {

    /// Current-state faults present in an XLink 1 status word, in a stable order.
    public static func faults(in xlinkStatus: UInt32) -> [ThunderboltLinkFault] {
        ThunderboltLinkFault.allCases.filter { xlinkStatus & $0.mask != 0 }
    }

    /// Turn a timing-health read into a verdict. `nil` means the dext selector
    /// failed, which is already a "not live" answer and needs no interpretation.
    public static func evaluate(_ health: TimingHealth?) -> ThunderboltEndpointVerdict {
        guard let health else { return .unavailable }
        let faults = faults(in: health.xlinkStatus)
        return faults.isEmpty ? .live(health) : .linkDown(health, faults: faults)
    }

    /// Verdict from the dext 113 link watch (no bus traffic). Maps onto the same
    /// enum the 0x51 probe produced so every consumer — swap grace, meter gating,
    /// failure threshold, the disconnected→live reconnect — is unchanged:
    /// `up` → live; `down` → linkDown[NO_CLOCK]; `recovering` → linkDown[RECOVERING];
    /// a selector that did not answer (nil) or `unknown` → unavailable.
    /// The embedded TimingHealth carries the watch's last XLink clocking register in
    /// `clkCtrl` so the tb-lifecycle log keeps a register value to show.
    public static func evaluate(linkState: LinkState?) -> ThunderboltEndpointVerdict {
        guard let ls = linkState, ls.state != .unknown else { return .unavailable }
        let h = TimingHealth(clkCtrl: ls.lastClockReg, intStatus: 0, xlinkStatus: ls.lastXlinkStatus,
                             gcsr: ls.lastGcsr,
                             frameReadback: 0, expectedFrame: 0, sampleRate: 0,
                             inputLatency: 0, outputLatency: 0, inputSafety: 0, outputSafety: 0)
        switch ls.state {
        case .up:         return .live(h)
        case .down:       return .linkDown(h, faults: [.noClock])
        case .recovering: return .linkDown(h, faults: [.recovering])
        case .unknown:    return .unavailable
        }
    }
}

/// Bounded tolerance for a DriverKit upgrade handoff.
///
/// While sysextd replaces the dext, its database lists two registrations and the
/// outgoing user-server can still own the PCI card while the new one is not yet
/// probeable. Lifecycle code tolerates failed probes for `interval` after the
/// second registration first appears — and no longer. A `terminating_for_upgrade`
/// record can linger for hours (observed 2026-10-21 with 105 → 106), so an
/// unbounded "two registrations means a swap is in progress" rule would let stale
/// meter memory count as a live Symphony forever.
public struct ExtensionSwapGrace: Sendable {
    public let interval: TimeInterval
    public private(set) var pendingSince: Date?

    public init(interval: TimeInterval = 15) {
        self.interval = interval
    }

    /// Whether a second registration is currently listed.
    public var isPending: Bool { pendingSince != nil }

    /// A live probe closes any open window: the tolerance is measured from
    /// the first *failed* probe while a second registration is listed, not
    /// from the first sighting of that registration (which can precede the
    /// real handoff by half an hour).
    public mutating func reset() { pendingSince = nil }

    /// Feed the latest registration count. Returns true while the grace window
    /// is open: more than one registration, seen for less than `interval`.
    @discardableResult
    public mutating func update(registrationCount: Int, now: Date = Date()) -> Bool {
        guard registrationCount > 1 else {
            pendingSince = nil
            return false
        }
        let since = pendingSince ?? now
        pendingSince = since
        return now.timeIntervalSince(since) < interval
    }
}
