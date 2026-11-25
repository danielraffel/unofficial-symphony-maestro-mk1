import Foundation
import Testing
@testable import MaestroCore

/// The ThunderBridge driver's Mac output names and the app's ThunderBridge
/// Output Routing row labels are one rule: Mac output n is named after the
/// board output at the same position in the driver's host channel order. The
/// driver (build 150+) lays the outputs out analog first (every analog output
/// of slot 1, then of slot 2, then slot 1's digital, then slot 2's;
/// ``ThunderboltChannelOrder/analogFirst``); a driver up to 149 by position
/// (slot 1 output n for 1-16, slot 2 output n-16 for 17-32), still checked in
/// `positionOnCardByCardDrivers`. The current driver's names for several layouts are pinned in
/// `Drivers/Thunderbolt/Scripts/golden/output-channel-names.txt`, which
/// `test-channel-names.sh` regenerates from `SymphonyChannelNames.h` and
/// diffs; this suite checks the app against the same file.
@Suite("ThunderBridge output names match the driver")
struct OutputChannelNameParityTests {
    struct Layout {
        var slot1: IOCardType
        var slot2: IOCardType
        var rate: Double
        var spdif: [Bool]
        var prefix: String
        var known: Bool
        var names: [String?] = []   // per Mac output, nil = the driver sets none

        var cardLayout: CardLayout {
            CardLayout(slot1: slot1, slot2: slot2, isKnown: known,
                       naming: .init(sampleRate: rate, opticalIsSPDIF: spdif.map { Optional($0) }))
        }
    }

    static func driverLayouts() throws -> [Layout] {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Drivers/Thunderbolt/Scripts/golden/output-channel-names.txt")
        let text = try String(contentsOf: file, encoding: .utf8)
        var layouts: [Layout] = []
        for line in text.split(separator: "\n") {
            let words = line.split(separator: " ", maxSplits: 1).map(String.init)
            if words.first == "layout" {
                let f = words[1].split(separator: " ").map(String.init)
                let t1 = UInt8(f[0]).flatMap(IOCardType.init(rawValue:))
                let t2 = UInt8(f[1]).flatMap(IOCardType.init(rawValue:))
                layouts.append(Layout(
                    slot1: try #require(t1),
                    slot2: try #require(t2),
                    rate: try #require(Double(f[2])),
                    spdif: [f[3] == "1", f[4] == "1"],
                    prefix: f[5], known: f[6] == "1"))
            } else {
                #expect(Int(words[0]) == layouts[layouts.count - 1].names.count + 1)
                layouts[layouts.count - 1].names.append(words[1] == "-" ? nil : words[1])
            }
        }
        return layouts
    }

    /// The driver's two channel names as the routing grid shows a pair:
    /// without the prefix, joined, and a bare "N.A." when both are N.A.
    static func pair(_ left: String?, _ right: String?, prefix: String) -> String? {
        guard let left, let right else { return nil }
        func bare(_ name: String) -> String {
            name == CardLayout.notApplicable ? name : String(name.dropFirst(prefix.count + 1))
        }
        return CardLayout.softwarePairName(
            hardwarePair: CardLayout.stereoName(left: bare(left), right: bare(right)), prefix: prefix)
    }

    @Test("The driver's file covers the layouts the rule was agreed on")
    func coverage() throws {
        let layouts = try Self.driverLayouts()
        #expect(layouts.count >= 8)
        #expect(layouts.allSatisfy { $0.names.count == 32 })
        let rig = try #require(layouts.first { $0.slot1 == .optical && $0.slot2 == .analogAD16 && $0.spdif[0] })
        #expect(rig.names[0] == "A Line 1")
        #expect(rig.names[8] == "A SPDIF Opt 1")
        #expect(rig.names[10] == "A N.A.")
        #expect(rig.names[16] == "A ADAT 9")
        #expect(rig.names[31] == "A ADAT 24")
        // Two 8x8s: every Line first.
        let two = try #require(layouts.first { $0.slot1 == .optical && $0.slot2 == .optical })
        #expect(two.names[8] == "A Line 9" && two.names[16] == "A ADAT 1")
        #expect(layouts.contains { !$0.known && $0.names.allSatisfy { $0 == nil } })
    }

    @Test("Each Mac output's name equals the driver's")
    func channelNames() throws {
        for layout in try Self.driverLayouts() {
            let app = layout.cardLayout
            for n in 0..<32 {
                #expect(app.thunderboltOutputChannelName(hostOutput: n, prefix: layout.prefix, order: .analogFirst)
                        == layout.names[n],
                        "\(layout.slot1)/\(layout.slot2) \(layout.rate) Mac output \(n + 1)")
            }
            #expect(app.thunderboltOutputChannelName(hostOutput: 32, prefix: layout.prefix, order: .analogFirst) == nil)
        }
    }

    @Test("Each ThunderBridge Output Routing row is the driver's pair")
    func rowLabels() throws {
        for layout in try Self.driverLayouts() {
            let app = layout.cardLayout
            for row in 0..<16 {
                #expect(app.thunderboltOutputPairName(pair: row, prefix: layout.prefix, order: .analogFirst)
                        == Self.pair(layout.names[row * 2], layout.names[row * 2 + 1], prefix: layout.prefix),
                        "\(layout.slot1)/\(layout.slot2) \(layout.rate) row \(row * 2 + 1)-\(row * 2 + 2)")
            }
        }
    }

    /// A driver up to build 149 (``ThunderboltChannelOrder/cardByCard``, the
    /// default): rows follow position, not every Line first.
    @Test("Card-by-card drivers: rows follow position, not every Line first")
    func positionOnCardByCardDrivers() {
        let two = CardLayout(slot1: .optical, slot2: .optical, naming: .init(sampleRate: 48000))
        #expect(two.thunderboltOutputPairName(pair: 4, prefix: "A") == "A ADAT 1/2")
        #expect(two.thunderboltOutputPairName(pair: 8, prefix: "A") == "A Line 9/10")
        // Empty slot 1: slot 2 stays on Mac 17-32.
        let empty1 = CardLayout(slot1: .none, slot2: .optical, naming: .init(sampleRate: 48000))
        #expect(empty1.thunderboltOutputPairName(pair: 0, prefix: "A") == "N.A.")
        #expect(empty1.thunderboltOutputPairName(pair: 8, prefix: "A") == "A Line 1/2")
        #expect(CardLayout(isKnown: false).thunderboltOutputPairName(pair: 0, prefix: "A") == nil)
    }

    @Test("Analog-first drivers: every Line first, slot 2 from Mac 1 behind an empty slot 1")
    func analogFirstRows() {
        let two = CardLayout(slot1: .optical, slot2: .optical, naming: .init(sampleRate: 48000))
        #expect(two.thunderboltOutputPairName(pair: 4, prefix: "A", order: .analogFirst) == "A Line 9/10")
        #expect(two.thunderboltOutputPairName(pair: 8, prefix: "A", order: .analogFirst) == "A ADAT 1/2")
        let empty1 = CardLayout(slot1: .none, slot2: .optical, naming: .init(sampleRate: 48000))
        #expect(empty1.thunderboltOutputPairName(pair: 0, prefix: "A", order: .analogFirst) == "A Line 1/2")
        #expect(empty1.thunderboltOutputPairName(pair: 8, prefix: "A", order: .analogFirst) == "N.A.")
        #expect(CardLayout(isKnown: false).thunderboltOutputPairName(pair: 0, prefix: "A", order: .analogFirst) == nil)
    }
}
