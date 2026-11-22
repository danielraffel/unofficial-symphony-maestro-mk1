import Testing
import Foundation
@testable import MaestroCore

@Suite("A card input as clock source is remembered")
struct SavedBoardClockTests {
    let aes = ClockSourceMenu.key(source: 4, boardInput: 0)

    @Test("nothing saved: nothing to do")
    func nothingSaved() {
        #expect(SavedBoardClock.decide(saved: nil, controlNow: 1, offered: [1, 2, aes]) == nil)
    }

    @Test("control as it was when chosen: the saved input is sent")
    func sent() {
        let saved = SavedBoardClock(key: aes, control: 1)
        #expect(SavedBoardClock.decide(saved: saved, controlNow: 1, offered: [1, 2, aes]) == .send(aes))
    }

    @Test("control changed elsewhere since: the saved input is dropped")
    func forgotten() {
        let saved = SavedBoardClock(key: aes, control: 1)
        #expect(SavedBoardClock.decide(saved: saved, controlNow: 2, offered: [1, 2, aes]) == .forget)
    }

    @Test("control unreadable, or the card is not there: wait, keep the choice")
    func waits() {
        let saved = SavedBoardClock(key: aes, control: 1)
        #expect(SavedBoardClock.decide(saved: saved, controlNow: nil, offered: [1, 2, aes]) == .wait)
        #expect(SavedBoardClock.decide(saved: saved, controlNow: 1, offered: [1, 2]) == .wait)
    }

    @Test("control not readable when chosen: sent whatever it reads now")
    func unknownControlAtWrite() {
        let saved = SavedBoardClock(key: aes, control: nil)
        #expect(SavedBoardClock.decide(saved: saved, controlNow: 2, offered: [aes]) == .send(aes))
    }

    @Test("stored per unit and removed")
    func storage() throws {
        let defaults = try #require(UserDefaults(suiteName: "SavedBoardClockTests.\(UUID().uuidString)"))
        SavedBoardClock.store(.init(key: aes, control: 1), identity: 0xABC, defaults: defaults)
        #expect(SavedBoardClock.load(identity: 0xABC, defaults: defaults) == .init(key: aes, control: 1))
        #expect(SavedBoardClock.load(identity: 0xDEF, defaults: defaults) == nil)
        SavedBoardClock.store(nil, identity: 0xABC, defaults: defaults)
        #expect(SavedBoardClock.load(identity: 0xABC, defaults: defaults) == nil)
    }
}
