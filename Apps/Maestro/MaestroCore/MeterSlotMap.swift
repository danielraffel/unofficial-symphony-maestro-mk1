/// Maps TDM meter payload word indices to user-visible channels.
///
/// Extracted from AppState so the mapping can be proven against card
/// configurations we do not own. The layout is documented in
/// Docs/issue-1-research.md and comes from SymphonyIO.cpp:6931-6944 and
/// :7041-7100:
///
///   words  0-15 -> card slot 0        words 16-31 -> card slot 1
///
/// The outer split is rigid and card-INDEPENDENT: each physical slot always
/// gets exactly 16 words whether the card fills 0, 8 or 16 of them. Within a
/// board the order is N analog channels first, then digital -- and N is
/// per-card. Hardcoding N = 8 was correct only for the 8x8 cards.
public enum MeterSlotMap {

    /// Word index carrying analog channel `channel` (0-based, device-wide).
    ///
    /// - Parameters:
    ///   - analogOnBoard0: analog channels contributed by the slot-0 card.
    ///     Pass 8 when detection has told us nothing -- a wrong guess is better
    ///     placed at the common case than at zero.
    ///   - twoBoards: whether the payload actually covers both slots (64 bytes).
    public static func analogWordIndex(channel: Int,
                                       analogOnBoard0: Int,
                                       twoBoards: Bool) -> Int {
        let n = analogOnBoard0 > 0 ? analogOnBoard0 : 8
        guard twoBoards, channel >= n else { return channel }
        // Past board 0's analog channels, continue into slot 1's region, which
        // begins at word 16 regardless of how much of slot 0 the first card used.
        return 16 + (channel - n)
    }

    /// Word indices carrying a board's digital channels, in order.
    ///
    /// Empty when the card uses its whole region for analog -- a 16x16 or
    /// AD16/DA16 contributes no digital region at all, and reading words 8-15
    /// unconditionally showed such a card's analog channels 9-16 as ADAT meters.
    public static func digitalWordIndices(analogOnBoard: Int,
                                          boardIndex: Int) -> [Int] {
        let start = analogOnBoard > 0 ? analogOnBoard : 8
        let count = max(0, 16 - start)
        guard count > 0 else { return [] }
        let base = boardIndex * 16
        return (0..<min(8, count)).map { base + start + $0 }
    }
}
