import Foundation
import Testing
@testable import MaestroDevice
@testable import MaestroCore

/// The ThunderBridge driver (build 150+) lays each unit's host channels out
/// analog first, and the app never reads that routing back: its tables and
/// names must equal the driver's. `test-channel-names.sh` regenerates
/// `Drivers/Thunderbolt/Scripts/golden/host-channel-order.txt` from
/// `SymphonyChannelNames.h` and diffs it, for every slot 1 x slot 2 case (every
/// card type, a value the driver does not know, a slot never read); this
/// suite checks the app's analog-first functions against the same file.
@Suite("ThunderBridge analog-first host channel order matches the driver")
struct HostChannelOrderParityTests {
    struct Pair {
        var tokens: (String, String)
        var slot1: IOCardType?   // nil: not read, or a value the app does not know
        var slot2: IOCardType?
        var capture: [UInt8] = []
        var playback: [UInt8] = []
        var inputNames: [String?] = []
        var outputNames: [String?] = []

        var bothKnown: Bool { slot1 != nil && slot2 != nil }
        var bothUnread: Bool { tokens.0 == "u" && tokens.1 == "u" }
        var label: String { "\(tokens.0)/\(tokens.1)" }
    }

    static func slot(_ token: String) -> IOCardType? {
        token == "u" ? nil : UInt8(token).flatMap(IOCardType.init(rawValue:))
    }

    static func driverPairs() throws -> [Pair] {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Drivers/Thunderbolt/Scripts/golden/host-channel-order.txt")
        let text = try String(contentsOf: file, encoding: .utf8)
        var pairs: [Pair] = []
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let words = line.split(separator: " ").map(String.init)
            switch words.first {
            case "pair":
                pairs.append(Pair(tokens: (words[1], words[2]), slot1: slot(words[1]), slot2: slot(words[2])))
            case "capture":
                pairs[pairs.count - 1].capture = words.dropFirst().compactMap { UInt8($0) }
            case "playback":
                pairs[pairs.count - 1].playback = words.dropFirst().compactMap { UInt8($0) }
            case "in", "out":
                let name = words.dropFirst(2).joined(separator: " ")
                let value: String? = name == "-" ? nil : name
                if words[0] == "in" {
                    #expect(Int(words[1]) == pairs[pairs.count - 1].inputNames.count + 1)
                    pairs[pairs.count - 1].inputNames.append(value)
                } else {
                    #expect(Int(words[1]) == pairs[pairs.count - 1].outputNames.count + 1)
                    pairs[pairs.count - 1].outputNames.append(value)
                }
            default:
                Issue.record("unexpected line \(line)")
            }
        }
        return pairs
    }

    /// The driver's two channel names as the routing grid shows a pair.
    static func pair(_ left: String?, _ right: String?, prefix: String) -> String? {
        guard let left, let right else { return nil }
        func bare(_ name: String) -> String {
            name == CardLayout.notApplicable ? name : String(name.dropFirst(prefix.count + 1))
        }
        return CardLayout.softwarePairName(
            hardwarePair: CardLayout.stereoName(left: bare(left), right: bare(right)), prefix: prefix)
    }

    @Test("The driver's file covers every slot pair")
    func coverage() throws {
        let pairs = try Self.driverPairs()
        #expect(pairs.count == 100)
        #expect(pairs.allSatisfy {
            $0.capture.count == 32 && $0.playback.count == 32 && $0.inputNames.count == 32 && $0.outputNames.count == 32
        })
        for type in IOCardType.allCases {
            #expect(pairs.contains { $0.slot1 == type && $0.slot2 == type })
        }
        #expect(pairs.contains { $0.tokens == ("9", "3") } && pairs.contains { $0.tokens == ("3", "u") })
        // The owner's example: 8x8 OPT + A16 IP reads Line 1-24, then ADAT 1-8.
        let rig = try #require(pairs.first { $0.slot1 == .optical && $0.slot2 == .analogAD16 })
        #expect(rig.inputNames == (1...24).map { "A Line \($0)" } + (1...8).map { "A ADAT \($0)" })
        #expect(rig.outputNames == (1...8).map { "A Line \($0)" } + (1...24).map { "A ADAT \($0)" })
    }

    @Test("Each capture table equals the driver's")
    func captureTables() throws {
        for pair in try Self.driverPairs() {
            let routes = SymphonyIODefaultRouting.thunderboltInputRoutes(slot1: pair.slot1, slot2: pair.slot2,
                                                                         order: .analogFirst)
            #expect(routes.map(\.destination) == (0..<32).map { SymphonyIORoutingAddress.p2pBase + UInt8($0) })
            #expect(routes.map(\.source) == pair.capture, "\(pair.label)")
        }
    }

    @Test("Each playback table equals the driver's")
    func playbackTables() throws {
        for pair in try Self.driverPairs() {
            let routes = SymphonyIODefaultRouting.thunderboltOutputRoutes(slot1: pair.slot1, slot2: pair.slot2,
                                                                          order: .analogFirst)
            #expect(routes.map(\.destination) == (0..<32).map { SymphonyIORoutingAddress.ioBoard0Base + UInt8($0) })
            #expect(routes.map(\.source) == pair.playback, "\(pair.label)")
        }
    }

    /// The app has one known/unknown flag for the whole layout, so only pairs
    /// with both slots known, or both unread, have an app counterpart for
    /// names; the half-read cases are pinned by the tables above and by the
    /// driver script.
    @Test("Each Mac output's name equals the driver's")
    func outputNames() throws {
        for pair in try Self.driverPairs() where pair.bothKnown || pair.bothUnread {
            let layout = pair.bothKnown
                ? CardLayout(slot1: pair.slot1!, slot2: pair.slot2!, naming: .init(sampleRate: 48000))
                : CardLayout(isKnown: false)
            for n in 0..<32 {
                #expect(layout.thunderboltOutputChannelName(hostOutput: n, prefix: "A", order: .analogFirst)
                        == pair.outputNames[n], "\(pair.label) Mac output \(n + 1)")
            }
            for row in 0..<16 {
                #expect(layout.thunderboltOutputPairName(pair: row, prefix: "A", order: .analogFirst)
                        == Self.pair(pair.outputNames[row * 2], pair.outputNames[row * 2 + 1], prefix: "A"),
                        "\(pair.label) output row \(row + 1)")
            }
        }
    }

    @Test("Each Input Routing row's default name is the driver's pair")
    func inputNames() throws {
        for pair in try Self.driverPairs() where pair.bothKnown {
            let layout = CardLayout(slot1: pair.slot1!, slot2: pair.slot2!, naming: .init(sampleRate: 48000))
            let columns = layout.inputRoutingColumns
            let routes = SymphonyIODefaultRouting.thunderboltInputRoutes(slot1: pair.slot1, slot2: pair.slot2,
                                                                         order: .analogFirst)
            let rows = CardLayout.softwareInputRowNames(
                rowCount: 16, routes: SymphonyIODefaultRouting.inputGrid(routes, columns: columns),
                columns: columns, prefix: "A")
            for row in 0..<16 {
                #expect(rows[row] == Self.pair(pair.inputNames[row * 2], pair.inputNames[row * 2 + 1], prefix: "A"),
                        "\(pair.label) input row \(row + 1)")
            }
        }
    }

    @Test("The order follows the serving driver build")
    func servingGate() {
        #expect(ServingDextBuild.firstAnalogFirstBuild == 150)
        #expect(ThunderboltChannelOrder.serving(.build(149)) == .cardByCard)
        #expect(ThunderboltChannelOrder.serving(.build(150)) == .analogFirst)
        #expect(ThunderboltChannelOrder.serving(.build(151)) == .analogFirst)
        #expect(ThunderboltChannelOrder.serving(.build(0)) == .analogFirst)   // unstamped local build of this code
        #expect(ThunderboltChannelOrder.serving(.olderThanBuildReporting) == .cardByCard)
        #expect(ThunderboltChannelOrder.serving(nil) == .cardByCard)
        // Card by card is the build-149 table, unchanged.
        #expect(SymphonyIODefaultRouting.thunderboltInputRoutes(slot1: .twoBySix, slot2: .analogAD16, order: .cardByCard).map(\.source)
                == SymphonyIODefaultRouting.thunderboltInputRoutes(slot1: .twoBySix).map(\.source))
        #expect(SymphonyIODefaultRouting.thunderboltOutputRoutes(slot1: .optical, slot2: .optical, order: .cardByCard).map(\.source)
                == SymphonyIODefaultRouting.thunderboltOutputRoutes(board0Outputs: 16, board1Outputs: 16).map(\.source))
    }
}
