import Testing
@testable import MaestroCore
@testable import MaestroDevice

/// The text of the Reset Input Routing and Reset Output Routing
/// confirmations, whole: "Software", "Card 1/2", en dashes, no card model
/// names, no arrows, and a blank line before the closing sentence.
@Suite("Reset Routing confirmation text")
struct RoutingResetMessageTests {

    private func input(_ b1: IOCardType, _ b2: IOCardType, thunderbolt: Bool = true) -> String {
        RoutingResetGuard.inputResetMessage(
            board1: b1, board2: b2, usbChannelCount: 32,
            routes: thunderbolt ? SymphonyIODefaultRouting.thunderboltInputRoutes(slot1: b1) : nil)
    }

    private func output(_ b1: IOCardType, _ b2: IOCardType, transport: TransportType = .thunderbolt) -> String {
        RoutingResetGuard.outputResetMessage(board1: b1, board2: b2, transport: transport)
    }

    @Test("8x8 with optical and 16 analog in / 16 digital out, on ThunderBridge")
    func opticalAndAD16() {
        #expect(input(.optical, .analogAD16) == """
            Each software input goes back to its default hardware input:

            Software 1–8: Card 1 analog in 1–8
            Software 9–16: Card 1 ADAT in 1–8
            Software 17–32: Card 2 analog in 1–16

            Only what your Mac records from changes. Outputs are not affected.
            """)
        #expect(output(.optical, .analogAD16) == """
            Each hardware output goes back to playing its default software output:

            Card 1 analog out 1–8: Software 1–8
            Card 1 ADAT out 1–8: Software 9–16
            Card 2 ADAT out 1–16: Software 17–32

            No mixer will feed an output.
            """)
    }

    /// The 8 Mic Pre has no converters of its own: its preamps feed card 1.
    @Test("16x16 analog and 8 Mic Pre")
    func analog16AndMicPre() {
        #expect(input(.analogADDA16, .micPre8) == """
            Each software input goes back to its default hardware input:

            Software 1–16: Card 1 analog in 1–16
            Software 17–32: no hardware input, silent.

            Only what your Mac records from changes. Outputs are not affected.
            """)
        #expect(output(.analogADDA16, .micPre8) == """
            Each hardware output goes back to playing its default software output:

            Card 1 analog out 1–16: Software 1–16
            Card 2: no outputs.

            No mixer will feed an output.
            """)
    }

    @Test("a single card, over USB and on ThunderBridge")
    func singleCard() {
        #expect(input(.optical, .none) == """
            Each software input goes back to its default hardware input:

            Software 1–8: Card 1 analog in 1–8
            Software 9–16: Card 1 ADAT in 1–8
            Software 17–32: no hardware input, silent.

            Only what your Mac records from changes. Outputs are not affected.
            """)
        for transport in [TransportType.usb, .thunderbolt] {
            #expect(output(.optical, .none, transport: transport) == """
                Each hardware output goes back to playing its default software output:

                Card 1 analog out 1–8: Software 1–8
                Card 1 ADAT out 1–8: Software 9–16
                Card 2: no card.

                No mixer will feed an output.
                """)
        }
    }

    @Test("cards that were not read: the reset is refused, with the cards named Card 1 and Card 2")
    func unknownCards() {
        #expect(RoutingResetGuard.refusalReason(board1: .unknown, board2: .unknown) == """
            Reset Routing is not available, because Maestro has not read the installed cards since it connected.

            Card 1: Unknown (not detected)
            Card 2: Unknown (not detected)

            The default routing depends on which cards are installed. With the wrong card, hardware outputs \
            would play the wrong software outputs: with an optical card, the ADAT outputs. Nothing was changed.
            """)
    }

    @Test("the second unit's inputs are numbered from 33, and the card's own mapping is mentioned when it goes back too")
    func unitBAndCardMapping() {
        let text = RoutingResetGuard.inputResetMessage(
            board1: .analogADDA16, board2: .none, usbChannelCount: 32,
            hostChannelOffset: 32, alsoResetsCardMapping: true)
        #expect(text.contains("\n\nSoftware 33–48: Card 1 analog in 1–16\n"))
        #expect(text.hasSuffix("""


            Only what your Mac records from changes. Outputs are not affected.

            The card's software inputs for all connected units also go back to their default.
            """))
    }

    @Test("every card pair: Software and Card, en dashes, no arrows, model names or DAW, a blank line before the closing sentence",
          arguments: [IOCardType.none, .micPre8, .analogAES, .optical, .analogAD16, .analogDA16, .analogADDA16, .twoBySix])
    func everyPair(board1: IOCardType) {
        for board2 in [IOCardType.none, .micPre8, .analogAES, .optical, .analogAD16, .analogDA16, .analogADDA16, .twoBySix] {
            var texts = [input(board1, board2), input(board1, board2, thunderbolt: false)]
            for transport in [TransportType.usb, .thunderbolt] { texts.append(output(board1, board2, transport: transport)) }
            for text in texts {
                for banned in ["DAW", "Slot", "←", "→", "(detected)", "—", "NOT"] + (board1 == .none ? [] : [board1.productName])
                    + (board2 == .none ? [] : [board2.productName]) {
                    #expect(!text.contains(banned), "\(banned) in:\n\(text)")
                }
                // No range is written with a hyphen.
                #expect(text.range(of: #"[0-9]-[0-9]"#, options: .regularExpression) == nil, "\(text)")
                let paragraphs = text.components(separatedBy: "\n\n")
                #expect(paragraphs.count == 3, "\(text)")
                #expect(paragraphs.last == RoutingResetGuard.inputResetClosing
                        || paragraphs.last == RoutingResetGuard.outputResetClosing, "\(text)")
            }
        }
    }
}
