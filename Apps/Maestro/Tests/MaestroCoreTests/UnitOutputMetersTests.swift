import Foundation
import Testing
@testable import MaestroCore

/// The Symphony's own output meters (vendor read 0x30, group Output): 16
/// words for each board, analog outputs first, digital straight after.
@Suite("Unit output meters")
struct UnitOutputMetersTests {
    private func payload(_ words: [Int: UInt16]) -> Data {
        var data = Data(count: UnitOutputMeters.payloadLength)
        for (word, value) in words {
            data[word * 2] = UInt8(value & 0xFF)
            data[word * 2 + 1] = UInt8(value >> 8)
        }
        return data
    }

    @Test("a word's level: 14 bits, full scale 0x3FFF, silence at or below 0x40, over bit ignored")
    func wordLevel() {
        #expect(UnitOutputMeters.level(word: 0x3FFF) == 0)
        #expect(UnitOutputMeters.level(word: 0x8000 | 0x3FFF) == 0)
        #expect(abs(UnitOutputMeters.level(word: 0x2000) - (-6.02)) < 0.01)
        #expect(UnitOutputMeters.level(word: 0x40) == -60)
        #expect(UnitOutputMeters.level(word: 0) == -60)
    }

    /// GitHub issue 31: 16x16 Analog in slot 1, 8x8 AES/OPT in slot 2, music
    /// on AES 3/4: board 1's digital outputs 3/4 are words 16 + 8 + 2 and + 3.
    @Test("16x16 + 8x8: slot 2's digital outputs follow its eight analog ones")
    func secondCardDigital() throws {
        let levels = try #require(UnitOutputMeters.levels(
            payload: payload([26: 0x3FFF, 27: 0x2000, 0: 0x1000, 16: 0x0800]),
            layout: CardLayout(slot1: .analogADDA16, slot2: .optical)))
        #expect(levels.analog.count == 24)
        #expect(levels.analog[0] > -60 && levels.analog[16] > -60 && levels.analog[1] == -60)
        #expect(levels.digital[16 + 2] == 0)
        #expect(abs(levels.digital[16 + 3] - (-6.02)) < 0.01)
        #expect(levels.digital[16 + 1] == -60 && levels.digital[0] == -60)
    }

    @Test("8x8 + 16x16: slot 2's analog outputs start at word 16, slot 1's digital at word 8")
    func analogAfterDigital() throws {
        let levels = try #require(UnitOutputMeters.levels(
            payload: payload([8: 0x3FFF, 16: 0x3FFF]),
            layout: CardLayout(slot1: .optical, slot2: .analogADDA16)))
        #expect(levels.analog.count == 24)
        #expect(levels.analog[8] == 0)          // slot 2 Line 1
        #expect(levels.digital[0] == 0)         // slot 1 digital 1
        #expect(levels.analog[7] == -60)
    }

    @Test("16 Analog In / 16 Digital Out: its digital outputs start at the board's first word")
    func digitalOnlyCard() throws {
        let levels = try #require(UnitOutputMeters.levels(
            payload: payload([16: 0x3FFF, 23: 0x3FFF, 24: 0x3FFF]),
            layout: CardLayout(slot1: .optical, slot2: .analogAD16)))
        #expect(levels.analog.count == 8)
        #expect(levels.digital[16] == 0 && levels.digital[23] == 0 && levels.digital[24] == 0)
    }

    @Test("2x6: six analog outputs, then AES and optical")
    func twoBySix() throws {
        let levels = try #require(UnitOutputMeters.levels(
            payload: payload([5: 0x3FFF, 6: 0x3FFF, 13: 0x3FFF, 15: 0x3FFF]),
            layout: CardLayout(slot1: .twoBySix, slot2: .none)))
        #expect(levels.analog.count == 6 && levels.analog[5] == 0)
        #expect(levels.digital[0] == 0 && levels.digital[7] == 0 && levels.digital[9] == 0)
    }

    @Test("no reading from an all-zero or short reply, or an unknown layout")
    func noReading() {
        let layout = CardLayout(slot1: .optical, slot2: .none)
        #expect(UnitOutputMeters.levels(payload: Data(count: 64), layout: layout) == nil)
        #expect(UnitOutputMeters.levels(payload: Data([1, 2, 3]), layout: layout) == nil)
        #expect(UnitOutputMeters.levels(payload: payload([0: 0x3FFF]), layout: CardLayout(isKnown: false)) == nil)
    }
}
