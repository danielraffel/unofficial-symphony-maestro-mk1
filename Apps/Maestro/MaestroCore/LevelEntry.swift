import Foundation

/// The rules behind the typed value fields under the faders: the Mixer's fader
/// level and the Input/Output trim readouts share them.
///
/// Original: Symphony I/O User's Guide p. 55 item 6 (the trim value field) and
/// the Mixer's level value field — type a value, Return applies it, Tab moves
/// to the next channel.
public enum LevelEntry {

    /// The value a typed string sets, or nil when the text is not a number and
    /// the control keeps its current value.
    ///
    /// The number is clamped to `range` and rounded to the control's `step`,
    /// exactly as dragging the fader does, so typing can never set a value the
    /// fader could not reach. Only a plain decimal number with a point is
    /// accepted (as the Mixer field always has): no comma, no unit, no spaces.
    public static func value(typed text: String,
                             range: ClosedRange<Double>,
                             step: Double) -> Double? {
        guard let parsed = Double(text), parsed.isFinite else { return nil }
        let clamped = min(max(parsed, range.lowerBound), range.upperBound)
        guard step > 0 else { return clamped }
        let stepped = (clamped / step).rounded() * step
        // Rounding to a step can only leave the range when a bound is not
        // itself on the step grid; keep the bound in that case.
        return min(max(stepped, range.lowerBound), range.upperBound)
    }

    /// How a value is shown in the field and offered for editing: whole
    /// numbers for a step of 1 dB or more, one decimal place otherwise.
    public static func text(for value: Double, step: Double) -> String {
        String(format: step >= 1 ? "%.0f" : "%.1f", value)
    }

    /// The readout Tab (or Shift-Tab, `forward == false`) moves to from
    /// `current`: the nearest one in `order` on that side that is enabled.
    /// Returns nil at the end of the list — there is no wrap-around — and when
    /// `current` is not in the list.
    public static func neighbour<ID: Equatable>(of current: ID,
                                                in order: [ID],
                                                forward: Bool,
                                                isEnabled: (ID) -> Bool) -> ID? {
        guard let start = order.firstIndex(of: current) else { return nil }
        var index = start + (forward ? 1 : -1)
        while order.indices.contains(index) {
            if isEnabled(order[index]) { return order[index] }
            index += forward ? 1 : -1
        }
        return nil
    }
}

/// The Mixer page's fader level readouts, in the order Tab walks them.
public enum MixerLevelReadout: Hashable, Sendable {
    /// An input strip, by mixer channel index.
    case input(Int)
    case softwareReturn
    case master

    /// Tab order across the page: the input strips that are showing, left to
    /// right, then Software Return, then Master — the order the strips are
    /// laid out in.
    public static func order(visibleInputs: [Int]) -> [MixerLevelReadout] {
        visibleInputs.map(MixerLevelReadout.input) + [.softwareReturn, .master]
    }
}
