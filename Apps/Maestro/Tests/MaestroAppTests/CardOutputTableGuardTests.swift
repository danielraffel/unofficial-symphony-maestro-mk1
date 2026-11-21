import Foundation
import Testing
@testable import MaestroApp
import MaestroCore
import MaestroDevice

private final class SilentVendorTransport: VendorTransport, @unchecked Sendable {
    var isConnected: Bool { true }
    func sendVendorCommand(command: UInt8, value: UInt32, payload: Data, port: UInt8) throws {}
    func readVendorCommand(command: UInt8, value: UInt32, responseLength: Int, port: UInt8) throws -> Data {
        Data(count: responseLength)
    }
}

extension StandardDefaultsSuites {
/// ThunderBridge: while the app's output table is not on the card, nothing
/// unmutes a card mixer strip or routes a mixer.
@Suite("ThunderBridge output table guard", .serialized)
@MainActor
struct CardOutputTableGuardTests {
    private func restoringDefaults() -> () -> Void {
        let defaults = UserDefaults.standard
        let before = defaults.dictionaryRepresentation()
        return {
            for key in defaults.dictionaryRepresentation().keys where before[key] == nil { defaults.removeObject(forKey: key) }
            for (key, value) in before { defaults.set(value, forKey: key) }
        }
    }

    private func makeState(identity: UInt64, cardsRead: Bool) -> (AppState, ThunderboltDeviceConnection) {
        let state = AppState()
        state.connectionMode = .hardware
        state.transportType = .thunderbolt
        state.isHardwareInitialized = true
        // No driver behind it: every card write and the link-state read fail.
        let tb = ThunderboltDeviceConnection(identifier: SimulatedDevice.symphonyIO32ch().identifier, audioDeviceID: 0)
        state.device = tb
        state.primaryBoardType = .analogADDA16
        state.secondaryBoardType = .analogADDA16
        state.primaryBoardSource = cardsRead ? .detected : .cached
        state.secondaryBoardSource = cardsRead ? .detected : .cached
        state.unitAIdentity = identity
        state.unitAIdentityState = .known(identity)
        return (state, tb)
    }

    private let unmute = PropertyAddress(selector: .mixerChannelMute, element: 1 << 16 | 0)

    private func refusal(_ body: () async throws -> Void) async -> String {
        do { try await body() } catch { return "\(error)" }
        return ""
    }

    @Test("cards not read this session: the table is refused, and no strip is unmuted or mixer routed")
    func guardRefused() async {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, tb) = makeState(identity: 0xF2B0_0001, cardsRead: false)
        // Whatever let writes through before, a refused table takes it back.
        tb.cardMixerHold.release()
        await state.syncOutputRoutingToHardware()
        #expect(tb.cardMixerHold.isHeld)
        #expect(state.cardOutputTableReplayNeeded)
        #expect(state.cardOutputLedger.written == nil)
        // The retry waits its turn on the health cadence.
        #expect(state.cardOutputRetryAttempts == 1)
        #expect(state.cardOutputRetryAfter > Date())
        // The Mixer page's sync defers...
        #expect(await state.mixerPageDefersToCardMixerRestore(mixer: 0))
        #expect(await state.mixerPageDefersToCardMixerRestore(mixer: 1))
        // ...an unmute the user makes is refused before it reaches the card
        // (the page has saved and shown it), and is owed a replay...
        #expect(!state.cardMixerOwesReplay(tb))
        let message = await refusal { try await tb.setProperty(unmute, value: .bool(false)) }
        #expect(message.contains("held until the output table is written"))
        #expect(state.cardMixerOwesReplay(tb))
        // ...and a mixer cannot be routed to an output from the grid.
        let route = await refusal {
            try await state.writeOutputRoute(destination: 32, source: SymphonyIORoutingAddress.mixer0Base, device: tb)
        }
        #expect(route.contains("its strips have not been written"))
        // D5 does not start either.
        state.syncCardMixerToHardware()
        #expect(state.cardMixerRestoreRun == nil)
    }

    @Test("cards read but the card refuses the first route write: reported, still unwritten, still held, retried later")
    func failedWriteKeepsTheHold() async {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, tb) = makeState(identity: 0xF2B0_0002, cardsRead: true)
        tb.cardMixerHold.release()
        await state.syncOutputRoutingToHardware()
        #expect(tb.cardMixerHold.isHeld)
        #expect(state.cardOutputLedger.written == nil)
        #expect(state.cardOutputTableReplayNeeded)
        let message = await refusal { try await tb.setProperty(unmute, value: .bool(false)) }
        #expect(message.contains("held until the output table is written"))
        // A second failure waits longer.
        let firstWait = state.cardOutputRetryAfter
        await state.syncOutputRoutingToHardware()
        #expect(state.cardOutputRetryAttempts == 2)
        #expect(state.cardOutputRetryAfter > firstWait)
    }

    @Test("a link recovery or card re-init takes the table back until the ordered restore has run again")
    func invalidation() async {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, tb) = makeState(identity: 0xF2B0_0003, cardsRead: true)
        let link = LinkState(state: .up, clockPresent: true, ioRunning: true, irqCount: 1, recoveryCount: 4,
                             hwSuspended: false, linkConfigured: true, lastClockReg: 0, watchTicks: 1, audioWraps: 1,
                             cardReinitCount: 2, mixerInstance: DriverMixerInstance(nonce: 9, holdsAppState: [true, true]))
        state.cardOutputLedger.recordWritten(.init(link))
        state.cardOutputTableReplayNeeded = false
        tb.cardMixerHold.release()
        state.invalidateCardOutputTable(tb)
        #expect(tb.cardMixerHold.isHeld)
        #expect(!state.cardOutputLedger.isWritten(on: link))
        #expect(state.cardOutputTableReplayNeeded)
    }

    @Test("the table is the whole default with the saved rows over it, mixer routes included")
    func table() {
        let restore = restoringDefaults()
        defer { restore() }
        let (state, tb) = makeState(identity: 0xF2B0_0004, cardsRead: true)
        var table = state.thunderboltOutputTable(for: tb)
        // Default: 32 outputs, each from its own playback channel, no mixer.
        #expect(table.count == 32)
        #expect(table.values.allSatisfy { CardOutputTableOrder.mixer(ofSource: $0) == nil })
        // 32 channels: 16 software pairs, so row 16 is Mixer 1. Column 0 is Line 1/2.
        state.peripheralRoutingCache(direction: "output").save([16: Set([0])])
        table = state.thunderboltOutputTable(for: tb)
        #expect(table[32] == SymphonyIORoutingAddress.mixer0Base)
        #expect(table[33] == SymphonyIORoutingAddress.mixer0Base + 1)
        let phases = CardOutputTableOrder.phases(table: table, readyMixers: [])
        #expect(phases.mixers == [0])
        #expect(phases.first.count == 32)
        #expect(phases.first.contains(.init(destination: 32, source: SymphonyIORoutingAddress.none)))
        #expect(phases.last.map(\.destination) == [32, 33])
    }

    @Test("two-unit replay: the reset's defaults and card-input reset go out, and the flags are consumed only when it has run")
    func twoUnitResetConsumer() throws {
        let restore = restoringDefaults()
        defer { restore() }
        let defaults = UserDefaults.standard
        for item in RoutingMixerReset.Pending.allCases {
            defaults.set(true, forKey: "routingMixerReset.pending.\(item.rawValue)")
        }
        let (state, tb) = makeState(identity: 0xF2B0_0005, cardsRead: true)
        // A driver that takes the card's own input routes (build 132 and later).
        state.servingDextBuild = .build(140)
        #expect(state.symphonyCardInputs.resetCommand != nil)
        let layoutB = CardLayout(slot1: .analogADDA16, slot2: .none)
        let b = ThunderboltUnitBConnection(identifier: SimulatedDevice.symphonyIO32ch().identifier,
                                           transport: SilentVendorTransport(), state: { nil })
        state.peripheralRoutingCache(direction: "output").save([16: Set([0])])

        let plan = state.makeTwoUnitReplay(tb: tb, b: b, layoutB: layoutB)
        #expect(plan.consumesRoutingReset)
        // Building a plan consumes nothing.
        #expect(RoutingMixerReset.isPending(.thunderboltInputRouting))
        // The default input table of unit A is in the plan (the saved copy is gone).
        #expect(plan.tables.contains {
            if case .unit(.a, let address, _) = $0 { return address.selector == .routing && address.scope == .input }
            return false
        })
        let card: [ThunderboltPreset.Write] = plan.card.compactMap {
            if case .card(let write) = $0 { return write }
            return nil
        }
        // The card's own input routes go back to straight through.
        #expect(card.contains(.cardInput(ConverterRouting.resetRoutingCommand)))
        // No strip write comes before every output route has been written
        // with the mixer-fed ones silent, and Mixer 1 is routed to Line 1/2
        // only after the last strip write.
        let firstStrip = try #require(card.firstIndex {
            if case .property(let address, _) = $0 { return address.selector == .mixerChannelMute }
            return false
        })
        let lastStrip = try #require(card.lastIndex {
            if case .property = $0 { return true }
            return false
        })
        let fed = card.indices.filter {
            if case .output(let route) = card[$0] { return CardOutputTableOrder.isMixerFed(route) }
            return false
        }
        #expect(fed.count == 2)
        #expect(fed.allSatisfy { $0 > lastStrip })
        let silenced = card[..<firstStrip].filter {
            if case .output(let route) = $0 { return !route.enabled && route.channel < 2 }
            return false
        }
        #expect(silenced.count == 2)

        // A replay that did not finish leaves the flags; one that did consumes them.
        let link = LinkState(state: .up, clockPresent: true, ioRunning: true, irqCount: 1, recoveryCount: 1,
                             hwSuspended: false, linkConfigured: true, lastClockReg: 0, watchTicks: 1, audioWraps: 1)
        state.finishTwoUnitReplay(plan, tb: tb, link: link, refusedAtPlan: tb.cardMixerHold.refusedCount)
        #expect(!RoutingMixerReset.isPending(.thunderboltInputRouting))
        #expect(!RoutingMixerReset.isPending(.thunderboltCardMixer))
        #expect(RoutingMixerReset.isPending(.usbInputRouting))
        #expect(!tb.cardMixerHold.isHeld)
        #expect(state.cardOutputLedger.isWritten(on: link))
        // With the flag consumed the next plan no longer starts from the defaults.
        let next = state.makeTwoUnitReplay(tb: tb, b: b, layoutB: layoutB)
        #expect(!next.consumesRoutingReset)
        #expect(!next.card.contains {
            if case .card(.cardInput(let command)) = $0 { return command == ConverterRouting.resetRoutingCommand }
            return false
        })
    }
}
}
