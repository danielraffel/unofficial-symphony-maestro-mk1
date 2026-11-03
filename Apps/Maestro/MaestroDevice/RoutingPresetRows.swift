import Foundation

/// Row numbering for saved output-routing presets.
///
/// The output matrix lists the DAW playback pairs first and the two mixer
/// buses after them, so the mixer rows' indices depend on how many playback
/// pairs the current transport has (8 over USB, 16 over ThunderBridge). A
/// preset is global, so it stores mixer rows under fixed sentinels instead of
/// their grid position; on load, DAW rows the current grid does not have are
/// dropped rather than aliased onto a mixer row.
///
/// Presets written before the sentinels (mixer rows stored at their grid
/// index) still decode: a row at or past the current DAW pair count is treated
/// as a mixer row only when it is exactly one of the two rows after them.
public enum RoutingPresetRows {
    public static let mixer1Sentinel = 1000
    public static let mixer2Sentinel = 1001

    /// Grid rows → stored rows.
    public static func encode(_ routes: [Int: Set<Int>], dawPairCount: Int) -> [Int: Set<Int>] {
        // Both sentinels are always present (empty when unused) so a preset
        // with no mixer routes is still recognised as sentinel-encoded.
        var out: [Int: Set<Int>] = [mixer1Sentinel: [], mixer2Sentinel: []]
        for (row, cols) in routes {
            if row == dawPairCount { out[mixer1Sentinel] = cols }
            else if row == dawPairCount + 1 { out[mixer2Sentinel] = cols }
            else if row >= 0 && row < dawPairCount { out[row] = cols }
        }
        return out
    }

    /// Stored rows → grid rows for a grid with `dawPairCount` playback pairs.
    /// Rows the grid cannot show are dropped.
    public static func decode(_ stored: [Int: Set<Int>], dawPairCount: Int) -> [Int: Set<Int>] {
        // A preset written with sentinels never stores a mixer row at its grid
        // index, so any row at or past the DAW pair count is a playback pair
        // this grid cannot show. Only sentinel-free (older) presets get the
        // legacy reading of the two rows after the DAW pairs as the mixers.
        let usesSentinels = stored.keys.contains { $0 == mixer1Sentinel || $0 == mixer2Sentinel }
        var out: [Int: Set<Int>] = [:]
        for (row, cols) in stored {
            switch row {
            case mixer1Sentinel: out[dawPairCount] = cols
            case mixer2Sentinel: out[dawPairCount + 1] = cols
            case 0..<dawPairCount: out[row] = cols
            case dawPairCount, dawPairCount + 1:
                if !usesSentinels { out[row] = cols }
            default: continue
            }
        }
        return out
    }
}
