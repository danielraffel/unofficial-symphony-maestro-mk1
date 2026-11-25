import Foundation
import Testing
@testable import MaestroCore
@testable import MaestroDevice

@Suite("Two-unit ordered recovery")
struct TwoUnitReplayTests {
    private func link(_ state: LinkState.State = .up, suspended: Bool = false) -> LinkState {
        LinkState(state: state, clockPresent: true, ioRunning: true, irqCount: 0,
                  recoveryCount: 1, hwSuspended: suspended, linkConfigured: true,
                  lastClockReg: 0, watchTicks: 0, audioWraps: 0)
    }

    @Test("64 -> 32 -> 64 never admits A writes at 32; both locks and configured are required")
    func modeAndLockGates() {
        let b = UnitBConnectionTests.state
        let states = [64, 32, 64].map {
            TwoUnitReplay.ready(channels: $0, link: link(), unitB: b, port2Locked: true)
        }
        #expect(states == [true, false, true])
        var counts: [Int] = []
        for channels in [64, 32, 64] {
            var sent = 0
            do {
                try plan().run(validate: {
                    guard TwoUnitReplay.ready(channels: channels, link: link(), unitB: b, port2Locked: true) else {
                        throw DeviceConnectionError.notConnected
                    }
                }, send: { _ in sent += 1 }, unlock: { _ in sent += 1; return true }, delay: {})
            } catch { }
            counts.append(sent)
        }
        #expect(counts == [8, 0, 8])
        #expect(!TwoUnitReplay.ready(channels: 64, link: link(), unitB: b, port2Locked: false))
        #expect(!TwoUnitReplay.ready(channels: 64, link: link(.recovering), unitB: b, port2Locked: true))
        let unconfigured = UnitBState(present: true, boardType: b.boardType, boardValid: b.boardValid,
                                     prefix: b.prefix, clockSource: b.clockSource, setupFlags: 0, txErrors: 0)
        #expect(!TwoUnitReplay.ready(channels: 64, link: link(), unitB: unconfigured, port2Locked: true))
    }

    @Test("Sleep suspends writes; wake waits for configured B")
    func wakeGate() {
        let b = UnitBConnectionTests.state
        #expect(!TwoUnitReplay.ready(channels: 64, link: link(suspended: true), unitB: b, port2Locked: true))
        #expect(!TwoUnitReplay.ready(channels: 64, link: link(), unitB: nil, port2Locked: true))
        #expect(TwoUnitReplay.ready(channels: 64, link: link(), unitB: b, port2Locked: true))
    }

    private func plan() -> TwoUnitReplay {
        var plan = TwoUnitReplay()
        plan.tables = [.unit(.a, .init(selector: .routing, scope: .input, element: 192), .uint32(32)),
                       .unit(.b, .init(selector: .routing, scope: .input, element: 192), .uint32(48))]
        plan.card = [.card(.property(.init(selector: .mixerSoftwareReturnID), .uint32(20)))]
        plan.settings = [.unit(.b, .init(selector: .prefix), .string("B"))]
        return plan
    }

    @Test("Both tables, card, names, both headphones, both unlocks; each failed step still unlocks")
    func orderedAndFaults() throws {
        let plan = plan()
        for failAt in [-1] + Array(plan.writes.indices) {
            var events: [String] = []
            var sent = 0
            var failed = false
            do {
                try plan.run(validate: {}, send: { write in
                    let index = sent
                    sent += 1
                    if index == failAt { throw DeviceConnectionError.notConnected }
                    switch write {
                    case .unit(let unit, let address, _):
                        events.append("\(unit)-\(address.selector == .routing ? "table" : "name")")
                    case .card: events.append("card")
                    case .headphones(let unit): events.append("\(unit)-hp")
                    }
                }, unlock: { unit in events.append("\(unit)-unlock"); return true }, delay: {})
            } catch { failed = true }
            #expect(failed == (failAt >= 0))
            #expect(Array(events.suffix(2)) == ["a-unlock", "b-unlock"])
            if failAt == -1 {
                let expected = ["a-table", "b-table", "card", "b-name", "a-hp", "b-hp", "a-unlock", "b-unlock"]
                #expect(events == expected)
            } else { #expect(sent == failAt + 1) }
        }
    }

    @Test("B lost mid-replay refuses remaining writes and stale unlocks, never falls back to A")
    func lostMidReplay() {
        var live = true
        var writes = 0
        var unlocks = 0
        var failed = false
        do {
            try plan().run(validate: {
                if !live { throw DeviceConnectionError.notConnected }
            }, send: { _ in writes += 1; live = false }, unlock: { _ in unlocks += 1; return true }, delay: {})
        } catch { failed = true }
        #expect(failed)
        #expect(writes == 1)
        #expect(unlocks == 0)
    }

    @Test("Unlock readback is bounded at ten attempts per unit")
    func unlockRetry() {
        var attempts: [DeviceUnit: Int] = [:]
        var failed = false
        do {
            try TwoUnitReplay().run(validate: {}, send: { _ in }, unlock: { unit in
                attempts[unit, default: 0] += 1
                return false
            }, delay: {})
        } catch { failed = true }
        #expect(failed)
        #expect(attempts[.a] == 10)
        #expect(attempts[.b] == 10)
    }

    @Test("A configured-state loss refuses the next real B property write")
    func configuredLoss() async throws {
        let transport = RecordingVendorTransport()
        let b = ThunderboltUnitBConnection(identifier: SimulatedDevice.symphonyIO32ch().identifier,
            transport: transport, state: { transport.sent.isEmpty ? UnitBConnectionTests.state : nil })
        try await b.setProperty(.init(selector: .routing, scope: .input, element: 192), value: .uint32(32))
        var failed = false
        do { try await b.setProperty(.init(selector: .peakHoldMode), value: .uint32(1)) }
        catch { failed = true }
        #expect(failed)
        #expect(transport.sent.count == 1)
        #expect(transport.sent.first?.port == 1)
    }

    @Test("Recovery reads B headphone assignments afresh and uses local crosspoints")
    func freshHeadphones() throws {
        let transport = RecordingVendorTransport()
        transport.reply = [0x21]
        let b = ThunderboltUnitBConnection(identifier: SimulatedDevice.symphonyIO32ch().identifier,
                                          transport: transport, state: { UnitBConnectionTests.state })
        try b.replayRecoveryHeadphones()
        let payloads = transport.sent.map(\.payload)
        let expected = [Data([224, 2, 225, 3]), Data([226, 4, 227, 5])]
        #expect(payloads == expected)
        #expect(transport.sent.allSatisfy { $0.command == 0x31 && $0.port == 1 })
        #expect(transport.reads.first?.command == 0x54)
        transport.emptyRead = true
        var failed = false
        do { try b.replayRecoveryHeadphones() } catch { failed = true }
        #expect(failed)
        #expect(transport.sent.count == 2)
    }

    @Test("Invalidated B refuses scalar writes as well as routing")
    func invalidatedConnection() async {
        let transport = RecordingVendorTransport()
        let b = ThunderboltUnitBConnection(identifier: SimulatedDevice.symphonyIO32ch().identifier,
                                          transport: transport, state: { UnitBConnectionTests.state })
        b.invalidate()
        var failed = false
        do { try await b.setProperty(.init(selector: .prefix), value: .string("C")) }
        catch { failed = true }
        #expect(failed)
        #expect(transport.sent.isEmpty)
    }
}
