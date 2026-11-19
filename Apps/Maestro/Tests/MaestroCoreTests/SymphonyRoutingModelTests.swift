import Testing
@testable import MaestroCore

@Suite("Symphony routing namespaces")
struct SymphonyRoutingModelTests {
    typealias M = SymphonyRoutingModel
    let a = M.Unit(port: .one)!
    let b = M.Unit(port: .two)!

    @Test func addressBoundariesAndTDM() {
        for index in -1...65 {
            #expect((M.CardRX(index) != nil) == (0..<64).contains(index))
            #expect((M.CardTX(index) != nil) == (0..<64).contains(index))
            #expect((M.HostChannel(index) != nil) == (1...64).contains(index))
            #expect(M.playbackSlot(channel: index) == ((0..<64).contains(index) ? UInt8(64 + index) : nil))
            if let rx = M.CardRX(index) { #expect(rx.tdmSlot == UInt8(index)) }
        }
        for port in M.Port.allCases {
            #expect(port.vendorPortByte == UInt8(port.rawValue))
            for address in -1...5 {
                #expect((M.Unit(port: port, address: address) != nil) == (1...4).contains(address))
            }
            let unit = M.Unit(port: port)!
            for channel in -1...33 {
                #expect((M.P2P(unit: unit, channel: channel) != nil) == (0..<32).contains(channel))
                if let p2p = M.P2P(unit: unit, channel: channel) {
                    #expect(p2p.routeByte == UInt8(192 + channel))
                }
            }
            for board in -1...2 {
                for channel in -1...16 {
                    let terminal = M.Terminal(unit: unit, board: board, channel: channel)
                    #expect((terminal != nil) == ((0..<2).contains(board) && (0..<16).contains(channel)))
                    if let terminal { #expect(terminal.boardRouteByte == UInt8(32 + board * 16 + channel)) }
                }
            }
        }
        #expect(M.P2P(unit: M.Unit(port: .one, address: 2)!, channel: 0) == nil)
        for mixer in -1...2 {
            for side in -1...2 {
                #expect(M.mixerSlot(mixer: mixer, side: side) ==
                        ((0...1).contains(mixer) && (0...1).contains(side) ? UInt8(128 + mixer * 2 + side) : nil))
            }
        }
        #expect(M.playbackSlot(channel: Int.max) == nil)
        #expect(M.playbackSlot(channel: Int.min) == nil)
    }

    @Test func singleAndTwoSymphonyFixtures() throws {
        for count in [32, 64] {
            for configured in [false, true] {
                let model = M(topology: .symphonyOnly, hostChannels: count, unitBConfigured: configured)
                for slot in 0..<64 {
                    let active = slot < 32 || (count == 64 && configured)
                    let unit = slot < 32 ? a : b
                    let local = slot % 32
                    let p2p = M.P2P(unit: unit, channel: local)!
                    let terminal = M.Terminal(unit: unit, board: local / 16, channel: local % 16)!
                    #expect(model.cardRX(for: p2p) == (active ? M.CardRX(slot) : nil))
                    #expect(model.p2p(for: M.CardRX(slot)!) == (active ? p2p : nil))
                    #expect(model.cardTX(for: terminal) == (active ? M.CardTX(slot) : nil))
                    #expect(model.terminal(for: M.CardTX(slot)!) == (active ? terminal : nil))
                    #expect(model.terminal(for: p2p, table: [p2p: terminal]) == (active ? terminal : nil))
                }
            }
        }
        let model = M(topology: .symphonyOnly, hostChannels: 64, unitBConfigured: true)
        let p0 = M.P2P(unit: b, channel: 0)!
        let p1 = M.P2P(unit: b, channel: 1)!
        let physical = M.Terminal(unit: b, board: 1, channel: 7)!
        // Reordered and duplicated physical inputs are not an identity map.
        #expect(model.terminal(for: p0, table: [p0: physical, p1: physical]) == physical)
        #expect(model.terminal(for: p1, table: [p0: physical, p1: physical]) == physical)
        #expect(model.terminal(for: p0, table: [:]) == nil)
        #expect(model.terminal(for: p0, table: [p0: M.Terminal(unit: a, board: 1, channel: 7)!]) == nil)
        for hostNumber in 1...64 {
            let host = M.HostChannel(hostNumber)!
            let rx = M.CardRX(64 - hostNumber)!
            #expect(model.cardRX(for: host, routes: [host: rx]) == rx)
            #expect(model.cardRX(for: host, routes: [:]) == nil)
        }
        let single = M(topology: .symphonyOnly, hostChannels: 32)
        #expect(single.cardRX(for: M.HostChannel(1)!, routes: [M.HostChannel(1)!: M.CardRX(32)!]) == nil)
        #expect(single.cardRX(for: M.HostChannel(33)!, routes: [M.HostChannel(33)!: M.CardRX(0)!]) == nil)
    }

    @Test func converterFixtures() {
        // Original gap: Rosetta 0...7, then AD at 16...31, packed host 1...24.
        for mixed in [false, true] {
            let topology: M.Topology = mixed ? .symphonyAndConverters([.rosetta, .ad16x])
                : .converterOnly(.init(port1: [.rosetta, .ad16x]))
            let model = M(topology: topology, hostChannels: mixed ? 64 : 32)
            let routes = model.converterRoutes(input: true)
            #expect(routes.count == 24)
            for (i, route) in routes.enumerated() {
                #expect(route.host.number == (mixed ? 33 : 1) + i)
                #expect(route.rx?.index == (mixed ? 32 : 0) + (i < 8 ? i : i + 8))
                #expect(route.tx == nil)
                #expect(route.terminal.unit.port == (mixed ? .two : .one))
                #expect(route.terminal.unit.address == (i < 8 ? 1 : 2))
                #expect(route.terminal.channel == (i < 8 ? i : i - 8))
                #expect(model.cardTX(for: route.terminal) == nil)
                #expect(model.cardRX(for: M.P2P(unit: route.terminal.unit, channel: 0) ?? M.P2P(unit: b, channel: 0)!) == nil)
            }
            let outputs = model.converterRoutes(input: false)
            #expect(outputs.count == 8)
            for (i, route) in outputs.enumerated() {
                #expect(route.tx?.index == (mixed ? 32 : 0) + i)
                #expect(route.host.number == (mixed ? 33 : 1) + i)
                #expect(route.rx == nil)
            }
        }
        // Opposite-direction offsets: a DA before an AD reserves RX 16...31.
        let asymmetric = M(topology: .converterOnly(.init(port1: [.da16x, .ad16x])), hostChannels: 32)
        #expect(asymmetric.converterRoutes(input: true).compactMap { $0.rx?.index } == Array(16..<32))
        #expect(asymmetric.converterRoutes(input: false).compactMap { $0.tx?.index } == Array(0..<16))
        let twoPorts = M(topology: .converterOnly(.init(port1: [.rosetta], port2: [.ddAsDA])), hostChannels: 64)
        for input in [false, true] {
            let routes = twoPorts.converterRoutes(input: input)
            #expect(routes.map { $0.host.number } == Array(1...24))
            #expect(routes.map { $0.rx?.index ?? $0.tx!.index } == Array(0..<8) + Array(32..<48))
        }
        #expect(M(topology: .symphonyAndConverters([.ad16x]), hostChannels: 32).converterRoutes(input: true).isEmpty)
        #expect(M(topology: .unknown, hostChannels: 64).converterRoutes(input: true).isEmpty)
    }

    @Test func exhaustiveCapabilityMatrix() {
        // Each fixture states allowed endpoint columns: card, A, B. All other
        // unit addresses and every cross-family endpoint must be refused.
        let fixtures: [(M, Bool, Bool, Bool, Bool)] = [
            (M(topology: .symphonyOnly, hostChannels: 32), true, true, true, false),
            (M(topology: .symphonyOnly, hostChannels: 32, unitBConfigured: true), true, true, true, false),
            (M(topology: .symphonyOnly, hostChannels: 64), true, true, true, false),
            (M(topology: .symphonyOnly, hostChannels: 64, unitBConfigured: true), true, true, true, true),
            (M(topology: .converterOnly(.init(port1: [.ad16x])), hostChannels: 32), true, true, false, false),
            (M(topology: .converterOnly(.init(port1: [.ad16x], port2: [.da16x])), hostChannels: 64, unitBConfigured: true), true, true, false, false),
            (M(topology: .symphonyAndConverters([.ad16x]), hostChannels: 64, unitBConfigured: true), true, true, true, false),
            (M(topology: .symphonyAndConverters([.ad16x]), hostChannels: 32), true, false, true, false),
            (M(topology: .unknown, hostChannels: 64, unitBConfigured: true), false, false, false, false),
            (M(topology: .symphonyOnly, hostChannels: 48, unitBConfigured: true), false, false, false, false),
        ]
        for (model, output, inputReset, unitA, unitB) in fixtures {
            for command in M.CommandFamily.allCases {
                let peripheral = [.identify, .monitor, .micPre, .deviceInfo, .preferenceLock, .unitRouting].contains(command)
                #expect(model.allows(command, at: .card) == (command == .cardOutput ? output : (!peripheral && inputReset)))
                for port in M.Port.allCases {
                    for address in 1...4 {
                        let allowed = address == 1 && peripheral && (port == .one ? unitA : unitB)
                        #expect(model.allows(command, at: .peripheral(M.Unit(port: port, address: address)!)) == allowed)
                    }
                }
            }
        }
    }
}
