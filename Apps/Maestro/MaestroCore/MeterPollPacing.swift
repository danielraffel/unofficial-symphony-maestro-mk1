import Foundation

/// Timing policy for the optional ThunderBridge unit-meter read.
public enum MeterPollPacing {
    public static let minimumInterval: TimeInterval = 0.1

    /// The next attempt is governed by the latest of the three safety bounds.
    public static func nextStart(now: TimeInterval, previousStart: TimeInterval?, previousEnd: TimeInterval?, backoffUntil: TimeInterval) -> TimeInterval {
        var result = max(now, backoffUntil)
        if let start = previousStart { result = max(result, start + minimumInterval) }
        if let start = previousStart, let end = previousEnd {
            result = max(result, end + max(0, end - start) * 4)
        }
        return result
    }

    /// A first failure keeps the current value. Backoff begins on failure two.
    public static func backoff(consecutiveFailures: Int) -> TimeInterval {
        guard consecutiveFailures >= 2 else { return 0 }
        return min(30, 2 * pow(2, Double(consecutiveFailures - 2)))
    }
}
