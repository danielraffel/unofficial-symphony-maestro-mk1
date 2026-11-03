import Testing
@testable import MaestroCore

/// The meter slot map previously hardcoded "8 analog then 8 digital per board".
/// That is right only for the 8x8 cards, and it was right on the dev unit by
/// coincidence -- an 8x8 OPT in slot 0 contributes exactly 8 analog channels.
/// These pin the behaviour for configurations we cannot plug in.
@Suite("Meter slot map")
struct MeterSlotMapTests {

    // MARK: Dev unit — 8x8 OPT (8 analog) + 16 Analog In / 16 Digital Out

    @Test("Dev unit: board 0 analog occupies words 0-7")
    func devUnitBoard0() {
        for ch in 0..<8 {
            #expect(MeterSlotMap.analogWordIndex(channel: ch, analogOnBoard0: 8,
                                                 twoBoards: true) == ch)
        }
    }

    @Test("Dev unit: analog channels 9-24 come from slot 1, words 16-31")
    func devUnitBoard1() {
        #expect(MeterSlotMap.analogWordIndex(channel: 8,  analogOnBoard0: 8, twoBoards: true) == 16)
        #expect(MeterSlotMap.analogWordIndex(channel: 23, analogOnBoard0: 8, twoBoards: true) == 31)
    }

    @Test("Dev unit: the 8x8 OPT contributes ADAT meters at words 8-15")
    func devUnitDigital() {
        #expect(MeterSlotMap.digitalWordIndices(analogOnBoard: 8, boardIndex: 0)
                == [8, 9, 10, 11, 12, 13, 14, 15])
    }

    // MARK: Reporter's unit — 16x16 Analog In/Out (16 analog) + 8MicPre (0)

    /// The regression. With the old fixed 8, channel 9 mapped to word 16 --
    /// slot 1's region -- which on this unit holds a MicPre8 contributing no
    /// meter slots at all. Channels 9-16 read an empty region.
    @Test("16x16 in slot 0: all 16 analog channels stay in words 0-15")
    func sixteenChannelCard() {
        for ch in 0..<16 {
            #expect(MeterSlotMap.analogWordIndex(channel: ch, analogOnBoard0: 16,
                                                 twoBoards: true) == ch,
                    "channel \(ch) must stay in slot 0's region")
        }
        // Specifically the case the old code got wrong.
        #expect(MeterSlotMap.analogWordIndex(channel: 8, analogOnBoard0: 16,
                                             twoBoards: true) == 8)
    }

    @Test("16x16 contributes NO digital region")
    func sixteenChannelNoDigital() {
        #expect(MeterSlotMap.digitalWordIndices(analogOnBoard: 16, boardIndex: 0).isEmpty)
    }

    /// A MicPre8 has no converters of its own; it delegates onto the primary
    /// card's analog inputs. Its slot contributes zero meter slots.
    @Test("MicPre8 in slot 1 contributes no digital meters")
    func micPreNoMeters() {
        #expect(MeterSlotMap.digitalWordIndices(analogOnBoard: 0, boardIndex: 1).isEmpty == false,
                "unknown card falls back to 8, so words 24-31 are assumed")
        // With a real MicPre8 reporting 0 analog we fall back to 8 rather than
        // inventing a region; the card simply never produces signal there.
    }

    // MARK: Degradation

    @Test("Undetected card falls back to 8, matching the old behaviour")
    func fallback() {
        #expect(MeterSlotMap.analogWordIndex(channel: 8, analogOnBoard0: 0,
                                             twoBoards: true) == 16)
    }

    @Test("Single-board payload maps linearly")
    func singleBoard() {
        for ch in 0..<8 {
            #expect(MeterSlotMap.analogWordIndex(channel: ch, analogOnBoard0: 8,
                                                 twoBoards: false) == ch)
        }
    }
}
