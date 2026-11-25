import Testing
@testable import MaestroApp
import MaestroCore

@MainActor
struct StripPresentationTests {
    @Test func inputRowsHaveNoCaptions() {
        #expect(InputRowCaption.visible(levels: [.variable, .plus4dBu], showTrims: true).isEmpty)
        #expect(InputRowCaption.visible(levels: [.mic, .instrument], showTrims: false).isEmpty)
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
