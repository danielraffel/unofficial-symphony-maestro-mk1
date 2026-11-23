import CoreGraphics
import Testing
@testable import MaestroCore

@Suite("MixerSelection")
struct MixerSelectionTests {
    @Test func rubberBandSelectsIntersectingStrips() {
        let frames = [0: CGRect(x: 0, y: 0, width: 40, height: 100),
                      1: CGRect(x: 45, y: 0, width: 40, height: 100),
                      MixerSelection.master: CGRect(x: 90, y: 0, width: 40, height: 100)]
        #expect(MixerSelection.stripsTouching(CGRect(x: 35, y: 20, width: 20, height: 40), frames: frames) == [0, 1])
    }
    @Test func shiftAddsVisibleRange() {
        let result = MixerSelection.applyingClick(index: 4,
            modifiers: MixerSelectionModifiers(shift: true), visible: [0, 1, 2, 4, 6],
            selected: [1], last: 1)
        #expect(result == [1, 2, 4])
    }

    @Test func commandShiftRemovesOneAndRangeVariantRemovesRange() {
        let one = MixerSelection.applyingClick(index: 2,
            modifiers: MixerSelectionModifiers(shift: true, command: true), visible: [0, 1, 2, 3],
            selected: [0, 1, 2], last: 0)
        #expect(one == [0, 1])
        let range = MixerSelection.applyingClick(index: 3,
            modifiers: MixerSelectionModifiers(shift: true, command: true, option: true), visible: [0, 1, 2, 3],
            selected: [0, 1, 2, 3], last: 0)
        #expect(range.isEmpty)
    }

    @Test func emptyShiftSelectsClickedStripAndPlainClickReplaces() {
        #expect(MixerSelection.applyingClick(index: 2, modifiers: MixerSelectionModifiers(shift: true), visible: [1, 2, 3], selected: [], last: nil) == [2])
        #expect(MixerSelection.applyingClick(index: 3, modifiers: MixerSelectionModifiers(), visible: [1, 2, 3], selected: [1, 2], last: 1) == [3])
    }

    @Test func groupedDeltaStopsAtFirstLimit() {
        #expect(MixerGroupMath.applyingDelta(10, to: [-4, 0, 5], in: -48...6) == [-3, 1, 6])
        #expect(MixerGroupMath.applyingDelta(-10, to: [-4, 0, 5], in: -48...6) == [-14, -10, -5])
        #expect(MixerGroupMath.applyingDelta(10, to: [-4, 0, 5], in: -1...1) == [-1, 0, 1])
        #expect(MixerGroupMath.applyingDelta(10, to: [-2, 1, 4], in: -48...6) == [0, 3, 6])
        #expect(MixerGroupMath.applyingDelta(-10, to: [-50, -1, 4], in: -48...6) == [-48, -1, 4])
    }

    /// A modified click on a strip's name is seen twice (by the name and by
    /// the strip), so applying the same click again must not change the
    /// selection (2026-11-23).
    @Test func applyingTheSameClickTwiceIsHarmless() {
        let visible = [0, 1, 2, 3, 4]
        for mods in [MixerSelectionModifiers(shift: true),
                     MixerSelectionModifiers(shift: true, command: true),
                     MixerSelectionModifiers(shift: true, command: true, option: true)] {
            let once = MixerSelection.applyingClick(index: 3, modifiers: mods, visible: visible, selected: [0, 1, 2, 3], last: 1)
            let twice = MixerSelection.applyingClick(index: 3, modifiers: mods, visible: visible, selected: once, last: 3)
            #expect(once == twice)
        }
    }
}
