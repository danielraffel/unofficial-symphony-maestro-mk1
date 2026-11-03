import Foundation

/// Shared square-root scale for LED thresholds, printed ticks, and peak hold.
/// Segment 0 is at -rangeDB; the last segment is at 0 dBFS.
public struct MeterScale: Sendable {
    public let rangeDB: Double
    public let segmentCount: Int

    public init(rangeDB: Double, segmentCount: Int = 24) {
        precondition(rangeDB.isFinite && rangeDB > 0 && segmentCount > 1)
        self.rangeDB = rangeDB
        self.segmentCount = segmentCount
    }

    public func dBForSegment(_ index: Int) -> Double {
        precondition((0..<segmentCount).contains(index))
        let distanceFromTop = Double(segmentCount - 1 - index) / Double(segmentCount - 1)
        return -rangeDB * distanceFromTop * distanceFromTop
    }

    /// Normalized distance below the top LED center (0 = top, 1 = bottom).
    public func position(forDB level: Double) -> Double {
        guard !level.isNaN else { return 1 }
        return sqrt(min(1, max(0, -level / rangeDB)))
    }

    public func perceptualY(db: Double, topCenter: Double, bottomCenter: Double) -> Double {
        topCenter + (bottomCenter - topCenter) * position(forDB: -db)
    }

    /// The highest reached threshold, shared with the lit ladder. No peak below
    /// the scale floor; values at or above full scale map to the top LED only.
    public func peakSegment(forDB level: Double) -> Int? {
        guard !level.isNaN, level >= -rangeDB else { return nil }
        return (0..<segmentCount).last { level >= dBForSegment($0) }
    }
}
