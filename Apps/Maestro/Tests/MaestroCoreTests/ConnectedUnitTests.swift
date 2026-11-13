import Testing
@testable import MaestroCore

/// Reply codes are from Apogee's original source (XLinkRegisters.h:279-295).
@Suite("ConnectedUnit")
struct ConnectedUnitTests {
    private let ran: UInt32 = 0x8000_0000, answered: UInt32 = 0x4000_0000

    @Test("no probe means a Symphony I/O, or an older driver")
    func notProbed() {
        #expect(ConnectedUnit(probeWord: 0) == nil)
        #expect(ConnectedUnit(probeWord: 0x0000_00C3) == nil)
    }

    @Test("each converter is recognised by its channel banks")
    func converters() {
        #expect(ConnectedUnit(probeWord: ran | answered | 0x3A) == .ad16x)
        #expect(ConnectedUnit(probeWord: ran | answered | 0xC1) == .da16x)
        #expect(ConnectedUnit(probeWord: ran | answered | 0xF0) == .dd16x)
        #expect(ConnectedUnit(probeWord: ran | answered | 0x52) == .rosetta800)
        // The extended reply in bits 8-15 does not change the type.
        #expect(ConnectedUnit(probeWord: ran | answered | 0x2000_0000 | 0xAB00 | 0xC1) == .da16x)
    }

    @Test("an unknown or missing answer is reported as such, with no layout")
    func unknowns() {
        #expect(ConnectedUnit(probeWord: ran | answered | 0x21) == .unrecognised(reply: 0x21))
        #expect(ConnectedUnit(probeWord: ran) == .silent)
        #expect(ConnectedUnit.silent.channels == nil)
        #expect(ConnectedUnit.unrecognised(reply: 0x21).channels == nil)
    }

    @Test("a DA-16X shows 16 outputs and no inputs; an unidentified unit keeps the generic layout")
    func layout() {
        let da = CardLayout(isKnown: false, fallbackChannelCount: 32, converter: .da16x)
        #expect(da.analogOutputStripCount == 16)
        #expect(da.analogInputStripCount == 0)
        let ad = CardLayout(isKnown: false, fallbackChannelCount: 32, converter: .ad16x)
        #expect(ad.analogInputStripCount == 16)
        #expect(ad.analogOutputStripCount == 0)
        let silent = CardLayout(isKnown: false, fallbackChannelCount: 32, converter: .silent)
        #expect(silent.analogOutputStripCount == 32)
        #expect(silent.analogInputStripCount == 32)
        // A Symphony I/O with cards is never overridden.
        let symphony = CardLayout(slot1: .analogADDA16, isKnown: true, converter: .da16x)
        #expect(symphony.analogOutputStripCount == symphony.slot1.analogOutputChannels)
    }
}
