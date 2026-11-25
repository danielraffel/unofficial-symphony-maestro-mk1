import Testing
@testable import MaestroApp

@Suite("MicPre DAW refresh")
struct MicPreDAWRefreshTests {
    @Test("a cancelled read cannot clear the slot of a newer one")
    func cancelledTaskKeepsNewerSlot() throws {
        var gate = MicPreDAWRefreshGate()
        let firstToken = gate.begin()
        let first = try #require(firstToken)
        let coalesced = gate.begin()
        #expect(coalesced == nil)
        gate.cancel()                                // listeners stopped
        let secondToken = gate.begin()
        let second = try #require(secondToken)
        #expect(!gate.isCurrent(first))
        gate.finish(first)                           // the old task finishes late
        let duplicate = gate.begin()
        #expect(gate.isCurrent(second) && duplicate == nil)
        gate.finish(second)
        let next = gate.begin()
        #expect(next != nil)
    }

    @Test("a DAW edit does not reload the page during a gain drag; it reloads on release")
    func reloadWaitsForDrag() {
        var reload = MicPreDAWDeferredReload()
        let idle = reload.request(dragging: false)
        let afterIdle = reload.dragEnded()
        let duringDrag = reload.request(dragging: true)
        let onRelease = reload.dragEnded()
        let again = reload.dragEnded()
        #expect(idle && !afterIdle && !duringDrag && onRelease && !again)
    }
}
