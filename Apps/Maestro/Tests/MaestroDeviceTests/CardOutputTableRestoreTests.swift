import Foundation
import Testing
import MaestroCore
@testable import MaestroDevice

/// ThunderBridge: no card mixer strip is unmuted, and no mixer is routed,
/// before the app's whole output table is on the card.
@Suite("ThunderBridge output table before the card mixers")
@MainActor
struct CardOutputTableRestoreTests {
    private let mixer0 = SymphonyIORoutingAddress.mixer0Base
    private let mixer1 = SymphonyIORoutingAddress.mixer1Base
    private let none = SymphonyIORoutingAddress.none

    /// Line 1/2 (32, 33) from Mixer 1, Line 3/4 direct, Line 5/6 from Mixer 2.
    private var table: [UInt8: UInt8] {
        [32: mixer0, 33: mixer0 + 1, 34: 2, 35: 3, 36: mixer1, 37: mixer1 + 1]
    }

    @MainActor private final class Recorder {
        var events: [String] = []
        var failRoute: (UInt8, UInt8)?
        var failMixers = false
        var current = true

        var environment: CardOutputTableRestore.Environment {
            .init(writeRoute: { destination, source in
                if let fail = self.failRoute, fail == (destination, source) {
                    self.events.append("route \(destination)<-\(source) FAILED")
                    throw DeviceConnectionError.transportError("card refused")
                }
                self.events.append("route \(destination)<-\(source)")
            }, writeMixers: { mixers in
                if self.failMixers { throw DeviceConnectionError.notConnected }
                self.events.append("mixers \(mixers)")
            }, isCurrent: { self.current })
        }
    }

    @Test("the table first with mixer-fed outputs silent, then the mixers, then the routes they feed")
    func order() async {
        let phases = CardOutputTableOrder.phases(table: table, readyMixers: [])
        let recorder = Recorder()
        let outcome = await CardOutputTableRestore.run(phases, recorder.environment)
        #expect(outcome == .written(routes: 10, mixers: [0, 1]))
        #expect(recorder.events == [
            "route 32<-\(none)", "route 33<-\(none)", "route 34<-2", "route 35<-3",
            "route 36<-\(none)", "route 37<-\(none)",
            "mixers [0, 1]",
            "route 32<-\(mixer0)", "route 33<-\(mixer0 + 1)", "route 36<-\(mixer1)", "route 37<-\(mixer1 + 1)",
        ])
        // Stated as the rule: before the mixers are written no route has a
        // mixer as its source, and every destination has been written.
        let mixersAt = recorder.events.firstIndex(of: "mixers [0, 1]")!
        let before = recorder.events[..<mixersAt]
        #expect(before.count == table.count)
        #expect(!before.contains { $0.hasSuffix("<-\(mixer0)") || $0.hasSuffix("<-\(mixer1)") })
    }

    @Test("a mixer the driver already holds the app's state for keeps its route; only the other waits")
    func readyMixer() async {
        let phases = CardOutputTableOrder.phases(table: table, readyMixers: [0])
        #expect(phases.mixers == [1])
        #expect(phases.first.contains(.init(destination: 32, source: mixer0)))
        #expect(phases.first.contains(.init(destination: 36, source: none)))
        #expect(phases.last == [.init(destination: 36, source: mixer1), .init(destination: 37, source: mixer1 + 1)])
    }

    @Test("a table with no mixer routes writes no mixer")
    func directOnly() async {
        let phases = CardOutputTableOrder.phases(table: [32: 0, 33: 1], readyMixers: [])
        let recorder = Recorder()
        #expect(await CardOutputTableRestore.run(phases, recorder.environment) == .written(routes: 2, mixers: []))
        #expect(recorder.events == ["route 32<-0", "route 33<-1"])
    }

    @Test("a failed route write is reported, stops the run and leaves the table unwritten")
    func routeFailureIsReported() async {
        let phases = CardOutputTableOrder.phases(table: table, readyMixers: [])
        let recorder = Recorder()
        recorder.failRoute = (34, 2)
        let outcome = await CardOutputTableRestore.run(phases, recorder.environment)
        #expect(outcome == .routeFailed(destination: 34, source: 2,
                                        error: "\(DeviceConnectionError.transportError("card refused"))"))
        #expect(!outcome.isWritten)
        // Nothing after the failure: no mixer was written, no mixer routed.
        #expect(recorder.events == ["route 32<-\(none)", "route 33<-\(none)", "route 34<-2 FAILED"])
    }

    @Test("a failed mixer-fed route in the last phase is reported too")
    func lastPhaseFailure() async {
        let recorder = Recorder()
        recorder.failRoute = (36, mixer1)
        let outcome = await CardOutputTableRestore.run(
            CardOutputTableOrder.phases(table: table, readyMixers: []), recorder.environment)
        #expect(!outcome.isWritten)
        #expect(recorder.events.last == "route 36<-\(mixer1) FAILED")
    }

    @Test("mixers that cannot be written are never routed")
    func mixerFailure() async {
        let recorder = Recorder()
        recorder.failMixers = true
        let outcome = await CardOutputTableRestore.run(
            CardOutputTableOrder.phases(table: table, readyMixers: []), recorder.environment)
        #expect(outcome == .mixerFailed(mixers: [0, 1], error: "\(DeviceConnectionError.notConnected)"))
        #expect(!recorder.events.contains { $0.hasSuffix("<-\(mixer0)") || $0.hasSuffix("<-\(mixer1)") })
    }

    @Test("a replaced connection ends the run unwritten")
    func superseded() async {
        let recorder = Recorder()
        recorder.current = false
        let outcome = await CardOutputTableRestore.run(
            CardOutputTableOrder.phases(table: table, readyMixers: []), recorder.environment)
        #expect(outcome == .superseded)
        #expect(recorder.events.isEmpty)
    }

    private func link(nonce: UInt64? = 7, recovery: UInt32 = 1, reinit: UInt32 = 0) -> LinkState {
        LinkState(state: .up, clockPresent: true, ioRunning: true, irqCount: 1, recoveryCount: recovery,
                  hwSuspended: false, linkConfigured: true, lastClockReg: 0, watchTicks: 1, audioWraps: 1,
                  cardReinitCount: reinit,
                  mixerInstance: nonce.map { DriverMixerInstance(nonce: $0, holdsAppState: [false, false]) })
    }

    @Test("the table counts as written only for the driver state it was written on")
    func ledger() {
        var ledger = CardOutputTableLedger()
        #expect(!ledger.isWritten(on: link()))
        ledger.recordWritten(.init(link()))
        #expect(ledger.isWritten(on: link()))
        // A restarted driver, an in-place recovery, a card re-init, no report.
        #expect(!ledger.isWritten(on: link(nonce: 8)))
        #expect(!ledger.isWritten(on: link(recovery: 2)))
        #expect(!ledger.isWritten(on: link(reinit: 1)))
        #expect(!ledger.isWritten(on: nil))
        // A driver without the instance report is keyed by its counters.
        ledger.recordWritten(.init(link(nonce: nil)))
        #expect(ledger.isWritten(on: link(nonce: nil)))
        #expect(!ledger.isWritten(on: link(nonce: nil, reinit: 1)))
        // A driver that reports nothing is one instance, distinct from any that does.
        ledger.recordWritten(.init(nil))
        #expect(ledger.isWritten(on: nil))
        #expect(!ledger.isWritten(on: link(nonce: nil, recovery: 0)))
        ledger.invalidate()
        #expect(!ledger.isWritten(on: nil))
    }

    @Test("a new connection refuses every card mixer write until the hold is released")
    func holdRefusesMixerWrites() async {
        let connection = ThunderboltDeviceConnection(
            identifier: SimulatedDevice.symphonyIO32ch().identifier, audioDeviceID: 0)
        #expect(connection.cardMixerHold.isHeld)
        let edits = connection.mixerEdits.capture()
        let unmute = PropertyAddress(selector: .mixerChannelMute, element: 1 << 16 | 3)
        for (address, value) in [(unmute, PropertyValue.bool(false)),
                                 (PropertyAddress(selector: .mixerChannelLevel, element: 2 << 16 | 0), .float64(0)),
                                 (PropertyAddress(selector: .mixerChannelSolo, element: 1 << 16 | 1), .bool(true)),
                                 (PropertyAddress(selector: .mixerSoftwareReturnID, element: 1 << 16), .uint32(1))] {
            var message = ""
            do { try await connection.setProperty(address, value: value) } catch { message = "\(error)" }
            #expect(message.contains("held until the output table is written"), "\(address.selector): \(message)")
        }
        #expect(connection.cardMixerHold.refusedCount == 4)
        // A refused write is not an edit on the card: D5's fence is untouched.
        #expect(connection.mixerEdits.isCurrent(edits))
        // Released: the write is admitted (and then fails only because this
        // test connection has no driver behind it).
        connection.cardMixerHold.release()
        var message = ""
        do { try await connection.setProperty(unmute, value: .bool(false)) } catch { message = "\(error)" }
        #expect(!message.contains("held until"))
        #expect(connection.cardMixerHold.refusedCount == 4)
        #expect(!connection.mixerEdits.isCurrent(edits))
    }

    @Test("two-unit card writes: routes with mixer-fed ones silent, then inputs and mixers, then mixer-fed routes")
    func twoUnitOrder() {
        let direct = ThunderboltCardRouting.Route(channel: 2, slot: ThunderboltCardRouting.pciOutBase + 2, enabled: true)
        let fed = ThunderboltCardRouting.Route(channel: 0, slot: ThunderboltCardRouting.mixerOutBase, enabled: true)
        let fedB = ThunderboltCardRouting.Route(channel: 33, slot: ThunderboltCardRouting.mixerOutBase + 3, enabled: true)
        let cardInput = ThunderboltPreset.Write.cardInput(ConverterRouting.resetRoutingCommand)
        let unmute = ThunderboltPreset.Write.property(
            PropertyAddress(selector: .mixerChannelMute, element: 1 << 16 | 0), .bool(false))
        let ordered = CardOutputTableOrder.ordered([cardInput, .output(fed), .output(direct), .output(fedB), unmute])
        let silent = { (route: ThunderboltCardRouting.Route) in
            ThunderboltPreset.Write.output(.init(channel: route.channel,
                slot: ThunderboltCardRouting.pciOutBase + route.channel, enabled: false))
        }
        #expect(ordered == [silent(fed), .output(direct), silent(fedB), cardInput, unmute, .output(fed), .output(fedB)])
        let unmuteAt = ordered.firstIndex(of: unmute)!
        #expect(!ordered[..<unmuteAt].contains {
            if case .output(let route) = $0 { return CardOutputTableOrder.isMixerFed(route) }
            return false
        })
    }
}
