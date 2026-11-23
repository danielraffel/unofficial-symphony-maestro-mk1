import Foundation
import Testing
@testable import MaestroCore
@testable import MaestroDevice

/// On ThunderBridge and PCIe a Mixer strip must address the card mixer input
/// its hardware channel arrives on (the XLink receive slot), not its position
/// in the strip list. Expected values here are worked out from each card's
/// input layout and the driver's rule for where slot 2 starts, independently
/// of the function under test.
@Suite("Card mixer: each strip's input, for every pair of cards")
struct CardMixerStripInputTests {
    /// Inputs on the board, in board order: analog first, then digital.
    private struct Board {
        let analog: Int
        /// One label per digital input, in board order.
        let digital: [String]
    }
    private static func board(_ card: IOCardType) -> Board {
        switch card {
        case .none, .micPre8: return Board(analog: 0, digital: [])
        case .analogAES: return Board(analog: 8, digital: Array(repeating: "AES", count: 8))
        case .optical: return Board(analog: 8, digital: Array(repeating: "ADAT", count: 8))
        case .analogAD16, .analogADDA16: return Board(analog: 16, digital: [])
        case .analogDA16: return Board(analog: 0, digital: Array(repeating: "ADAT", count: 16))
        case .twoBySix: return Board(analog: 2, digital: ["AES", "AES"] + Array(repeating: "ADAT", count: 8))
        }
    }
    /// The driver's rule (`SymphonySlot2InputBase`): 12 behind a 2x6, else 16.
    private static func slot2Base(_ slot1: IOCardType) -> Int { slot1 == .twoBySix ? 12 : 16 }

    /// (kind, receive slot) for every strip in the Mixer's order: analog of
    /// slot 1 then slot 2, then AES, then optical.
    private static func expected(_ slot1: IOCardType, _ slot2: IOCardType) -> [(kind: String, slot: Int)] {
        let boards = [board(slot1), board(slot2)], bases = [0, slot2Base(slot1)]
        var analog: [(String, Int)] = [], aes: [(String, Int)] = [], optical: [(String, Int)] = []
        for b in 0..<2 {
            for c in 0..<boards[b].analog { analog.append(("Line", bases[b] + c)) }
            for (j, label) in boards[b].digital.enumerated() {
                let entry = (label, bases[b] + boards[b].analog + j)
                if label == "AES" { aes.append(entry) } else { optical.append(entry) }
            }
        }
        return (analog + aes + optical).map { (kind: $0.0, slot: $0.1) }
    }

    private static let slot1Cards: [IOCardType] = [.none, .analogAES, .optical, .analogAD16, .analogDA16, .analogADDA16, .twoBySix]
    private static let slot2Cards: [IOCardType] = [.none, .analogAES, .optical, .analogAD16, .analogDA16, .analogADDA16, .twoBySix, .micPre8]

    private func inputs(_ slot1: IOCardType, _ slot2: IOCardType,
                        replayed: [ThunderboltInputMeterMap.Route] = []) -> [Int?] {
        ThunderboltInputMeterMap.mixerInputs(
            layout: CardLayout(slot1: slot1, slot2: slot2),
            routes: ThunderboltInputMeterMap.currentRoutes(slot1: slot1, replayed: replayed))
    }

    @Test("every pair: each strip addresses its own input, none shared, none outside the unit")
    func everyPair() {
        var changed: [String] = []
        for slot1 in Self.slot1Cards {
            for slot2 in Self.slot2Cards where !(slot1 == .none && slot2 == .none) {
                let layout = CardLayout(slot1: slot1, slot2: slot2)
                guard layout.isKnown else { continue }
                let want = Self.expected(slot1, slot2)
                let got = inputs(slot1, slot2)
                let name = "\(slot1) + \(slot2)"
                #expect(got.count == want.count, "\(name): strip count")
                #expect(layout.mixerChannels.count == want.count, "\(name): strips drawn")
                for (i, strip) in want.enumerated() where i < got.count {
                    #expect(got[i] == strip.slot, "\(name): strip \(i) \(layout.mixerChannels[i].label)")
                    let label = layout.mixerChannels[i].label
                    #expect(label.hasPrefix(strip.kind) || (strip.kind == "ADAT" && !label.hasPrefix("Line") && !label.hasPrefix("AES")),
                            "\(name): strip \(i) is \(label), expected a \(strip.kind) input")
                }
                let used = got.compactMap { $0 }
                #expect(Set(used).count == used.count, "\(name): two strips on one input")
                #expect(used.allSatisfy { (0..<32).contains($0) }, "\(name): input outside 0-31")
                if got != layout.mixerChannels.map({ Optional($0.hardwareIndex) }) { changed.append(name) }
            }
        }
        // Wrong before the fix: slot 1 with digital inputs and slot 2 with analog
        // inputs, or slot 1 empty with a card with inputs in slot 2.
        var wantChanged: [String] = []
        for slot1 in Self.slot1Cards {
            for slot2 in Self.slot2Cards where !(slot1 == .none && slot2 == .none) {
                guard CardLayout(slot1: slot1, slot2: slot2).isKnown else { continue }
                let b1 = Self.board(slot1), b2 = Self.board(slot2)
                let slot2HasInputs = b2.analog + b2.digital.count > 0
                if (!b1.digital.isEmpty && b2.analog > 0) || (slot1 == .none && slot2HasInputs) {
                    wantChanged.append("\(slot1) + \(slot2)")
                }
            }
        }
        #expect(changed.sorted() == wantChanged.sorted())
        #expect(changed.count == 26)
    }

    @Test("the owner's unit: 8x8 OPT + 16 Analog In")
    func ownersUnit() {
        let got = inputs(.optical, .analogAD16)
        #expect(got.count == 32)
        #expect(got[0] == 0 && got[7] == 7)            // Line 1-8
        #expect(got[8] == 16 && got[23] == 31)         // Line 9-24: slot 2
        #expect(got[24] == 8 && got[31] == 15)         // ADAT 1-8: slot 1's digital
    }

    @Test("spot values from the review")
    func spotValues() {
        let a = inputs(.twoBySix, .analogADDA16)       // Line 1-2, Line 3-18, AES 1-2, ADAT 1-8
        #expect(a[2] == 12 && a[17] == 27 && a[18] == 2 && a[20] == 4)
        #expect(inputs(.none, .analogADDA16)[0] == 16)
        let b = inputs(.analogDA16, .analogAES)        // Line 1-8, AES 1-8, ADAT 1-16
        #expect(b[0] == 16 && b[8] == 24 && b[16] == 0)
    }

    @Test("a 2x6 in slot 1 the driver did not know about: slot 2 starts at 16")
    func twoBySixUnknownToDriver() {
        let got = ThunderboltInputMeterMap.mixerInputs(
            layout: CardLayout(slot1: .twoBySix, slot2: .analogADDA16),
            routes: ThunderboltInputMeterMap.currentRoutes(slot1: nil, replayed: []))
        #expect(got[2] == 16 && got[17] == 31)         // Line 3-18
        #expect(got[18] == 2)                          // AES 1
    }

    @Test("Input Routing moves an input, routes one nowhere, and sends one to two places")
    func inputRouting() {
        let p2p = SymphonyIORoutingAddress.p2pBase, board0 = SymphonyIORoutingAddress.ioBoard0Base
        // Host input 1 takes Line 3; host input 3 takes Line 1; Line 2 goes nowhere
        // (host input 2 takes Line 1 too, so Line 1 is on two receive slots).
        let replayed: [ThunderboltInputMeterMap.Route] = [
            (destination: p2p + 0, source: board0 + 2),
            (destination: p2p + 2, source: board0 + 0),
            (destination: p2p + 1, source: board0 + 0),
        ]
        let got = inputs(.optical, .none, replayed: replayed)
        #expect(got[2] == 0)                           // Line 3 now arrives on receive slot 0
        #expect(got[0] == 1)                           // Line 1: the lowest of its two slots
        #expect(got[1] == nil)                         // Line 2 reaches no receive slot
        #expect(got[3] == 3)                           // untouched
    }

    @Test("converters and an unknown layout keep the numbers they send today")
    func unchangedLayouts() {
        let unknown = CardLayout(isKnown: false)
        #expect(ThunderboltInputMeterMap.mixerInputs(layout: unknown, routes: [])
                == unknown.mixerChannels.map { Optional($0.hardwareIndex) })
    }

    @Test("over USB a strip's number is its position in the list, for every pair")
    func usbUnchanged() {
        for slot1 in Self.slot1Cards {
            for slot2 in Self.slot2Cards {
                let layout = CardLayout(slot1: slot1, slot2: slot2)
                #expect(layout.mixerChannels.map(\.hardwareIndex) == Array(0..<layout.mixerChannels.count))
            }
        }
    }

    /// An Input Routing change marks the mixers owed on the connection's
    /// ledger; the restore snapshots what is owed before it writes them and
    /// only covers that much, so a second change during the run leaves a
    /// restore owed and is not lost. The marks stay, so no mixer-fed output
    /// is switched off for it.
    @Test("a second routing change during a rewrite leaves another rewrite owed; the mixers stay written")
    func changeDuringRewriteIsNotLost() {
        let ledger = CardMixerLedger()
        // Every channel of the table is written and none is on a mixer.
        ledger.declareTable(channels: [0])
        ledger.recordRoute(channel: 0, mixer: nil)
        let address = PropertyAddress(selector: .mixerChannelMute, element: 0)
        #expect(ledger.markWritten(0, sent: [address], required: [address], epoch: ledger.epoch))
        #expect(ledger.markWritten(1, sent: [address], required: [address], epoch: ledger.epoch))
        #expect(ledger.completeRestore(epoch: ledger.epoch, covering: ledger.owed))
        #expect(!ledger.needsRestore)

        ledger.noteOwed()                              // first routing change
        #expect(ledger.needsRestore)
        let covering = ledger.owed                     // the restore begins
        ledger.noteOwed()                              // second change, mid-run
        #expect(ledger.completeRestore(epoch: ledger.epoch, covering: covering))
        #expect(ledger.needsRestore)                   // still owed: runs again
        #expect(ledger.writtenMixers == [0, 1])        // nothing was unmarked
        #expect(ledger.completeRestore(epoch: ledger.epoch, covering: ledger.owed))
        #expect(!ledger.needsRestore)
    }

    @Test("a complete mixer write mutes and unsolos the inputs no strip maps to before it writes any strip")
    func unmappedInputsFirst() throws {
        // 8x8 OPT alone: strips on receive slots 0-15, 16-31 unmapped.
        let layout = CardLayout(slot1: .optical, slot2: .none)
        let routes = ThunderboltInputMeterMap.currentRoutes(slot1: .optical, replayed: [])
        let name = "strip-order-\(UUID())"
        let defaults = ScratchUserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: false, identity: 9)
        let strip = MixerChannelState(level: -3, pan: 0, isMuted: false, isSoloed: false)
        store.save(Array(repeating: strip, count: layout.mixerChannelCount), for: ChannelStateStore.mixerKey(0))
        let snapshot = MixerStateSnapshot(channelCount: layout.mixerChannelCount, mixer: 0, store: store)
        let writes = CardMixerReplay.writes(mixer: 0, layout: layout, snapshot: snapshot, routes: routes)
        let inputs = writes.compactMap { write -> (Int, AudioPropertySelector)? in
            guard case .property(let address, _) = write else { return nil }
            let id = Int(address.element & 0xFFFF)
            return id < 64 && address.selector != .mixerSoftwareReturnID ? (id, address.selector) : nil
        }
        let firstStrip = try #require(inputs.firstIndex { $0.0 < 16 })
        let unmapped = inputs.enumerated().filter { $0.element.0 >= 16 }
        #expect(unmapped.count == 32)                  // mute and solo for 16-31
        #expect(unmapped.allSatisfy { $0.offset < firstStrip })
    }
}
