import Testing
@testable import MaestroApp
import MaestroCore

@MainActor
struct StripPresentationTests {
    @Test func inputCaptionsFollowTheDisplayedRows() {
        // Only Level Trim is captioned; the three setting pills are not.
        #expect(InputRowCaption.visible(levels: [], showTrims: true).isEmpty)
        #expect(InputRowCaption.visible(levels: [.variable, .variable], showTrims: false).isEmpty)
        #expect(InputRowCaption.visible(levels: [.variable, .plus4dBu], showTrims: false).isEmpty)
        #expect(InputRowCaption.visible(levels: [.variable], showTrims: true) == [.levelTrim])
        #expect(InputRowCaption.visible(levels: [.variable, .mic], showTrims: false) == [.levelTrim])
        #expect(InputRowCaption.visible(levels: [.instrument, .minus10dBV], showTrims: false) == [.levelTrim])
    }

    @Test func onlyConnectedHardwareWithTwoConfirmedEmptySlotsHasNoCards() {
        let empty = BoardTypeReading.detected(.none)
        #expect(DetailView.showsNoIOCards(mode: .hardware, hasConverter: false, slot1: empty, slot2: empty))
        #expect(!DetailView.showsNoIOCards(mode: .simulated, hasConverter: false, slot1: empty, slot2: empty))
        #expect(!DetailView.showsNoIOCards(mode: .disconnected, hasConverter: false, slot1: empty, slot2: empty))
        #expect(!DetailView.showsNoIOCards(mode: .hardware, hasConverter: true, slot1: empty, slot2: empty))
        #expect(!DetailView.showsNoIOCards(mode: .hardware, hasConverter: false, slot1: .unknown, slot2: empty))
        #expect(!DetailView.showsNoIOCards(mode: .hardware, hasConverter: false, slot1: empty, slot2: .detected(.optical)))
    }
}
