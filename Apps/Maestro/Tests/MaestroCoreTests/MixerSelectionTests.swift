import Testing
@testable import MaestroCore

@Suite("MixerSelection")
struct MixerSelectionTests {
    @Test func rubberBandSelectsIntersectingStrips() {
        let frames = [0: CGRect(x: 0, y: 0, width: 40, height: 100),
                      1: CGRect(x: 45, y: 0, width: 40, height: 100),
                      MixerSelection.master: CGRect(x: 90, y: 0, width: 40, height: 100)]
        #expect(MixerSelection.stripsTouching(CGRect(x: 35, y: 20, width: 20, height: 40)) == [0, 1])
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
        #expect(MixerGroupMath.applyingDelta(10, to: [-4, 0, 5], in: -1...1) == [-1, -1, 1])
    }
}
