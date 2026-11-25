import Foundation
import CoreGraphics

/// Pure selection and grouped-control rules used by the Mixer page.
public enum MixerSelection {
    public static let softwareReturn = -1
    public static let master = -2
    public static func applyingClick(
        index: Int,
        modifiers: MixerSelectionModifiers,
        visible: [Int],
        selected: Set<Int>,
        last: Int?
    ) -> Set<Int> {
        guard visible.contains(index) else { return selected }
        if modifiers.shift && modifiers.command && modifiers.option {
            return selected.subtracting(range(from: last, to: index, visible: visible))
        }
        if modifiers.shift && modifiers.command {
            var result = selected
            result.remove(index)
            return result
        }
        if modifiers.shift {
            guard let last else { return [index] }
            return selected.union(range(from: last, to: index, visible: visible))
        }
        return [index]
    }

    public static func range(from: Int?, to: Int, visible: [Int]) -> Set<Int> {
        guard let from, let start = visible.firstIndex(of: from), let end = visible.firstIndex(of: to) else {
            return [to]
        }
        let bounds = min(start, end)...max(start, end)
        return Set(visible[bounds])
    }

    /// Returns strips whose layout frames intersect the rubber-band rectangle.
    public static func stripsTouching(_ rectangle: CGRect, frames: [Int: CGRect]) -> Set<Int> {
        Set(frames.compactMap { id, frame in rectangle.intersects(frame) ? id : nil })
    }
}

public struct MixerSelectionModifiers: Sendable, Equatable {
    public let shift: Bool
    public let command: Bool
    public let option: Bool

    public init(shift: Bool = false, command: Bool = false, option: Bool = false) {
        self.shift = shift
        self.command = command
        self.option = option
    }
}

public enum MixerGroupMath {
    /// Applies one relative delta to a group. The group stops as soon as any
    /// member reaches a bound, preserving every member's offset.
    public static func applyingDelta(_ delta: Double, to values: [Double], in bounds: ClosedRange<Double>) -> [Double] {
        guard !values.isEmpty else { return [] }
        let clamped = values.map { min(max($0, bounds.lowerBound), bounds.upperBound) }
        if delta > 0, values.contains(where: { $0 > bounds.upperBound }) { return clamped }
        if delta < 0, values.contains(where: { $0 < bounds.lowerBound }) { return clamped }
        let allowed: Double
        if delta > 0 {
            allowed = min(delta, clamped.map { bounds.upperBound - $0 }.min() ?? delta)
        } else {
            allowed = max(delta, clamped.map { bounds.lowerBound - $0 }.max() ?? delta)
        }
        return clamped.map { min(max($0 + allowed, bounds.lowerBound), bounds.upperBound) }
    }
}
