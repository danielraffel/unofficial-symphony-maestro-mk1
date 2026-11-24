import Foundation
import Testing
@testable import MaestroApp
import MaestroCore
import MaestroDevice

extension StandardDefaultsSuites {
/// The app side of the analog-first channel order (driver build 150): the
/// order AppState follows, the one-time reset at connect, speaker-set
/// defaults and the Output Routing names.
@Suite("Channel order in the app", .serialized)
@MainActor
struct ChannelOrderAppTests {
    private func restoringDefaults() -> () -> Void {
        let defaults = UserDefaults.standard
        let before = defaults.dictionaryRepresentation()
        return {
            for key in defaults.dictionaryRepresentation().keys where before[key] == nil { defaults.removeObject(forKey: key) }
            for (key, value) in before { defaults.set(value, forKey: key) }
        }
    }

    private func makeState(slot1: IOCardType, slot2: IOCardType, build: UInt32?,
                           transport: TransportType = .thunderbolt) -> (AppState, ThunderboltDeviceConnection, FakeThunderboltDriver) {
        UserDefaults.standard.removeObject(forKey: "mixerWideState.migratedTo")
        let state = AppState()
        state.connectionMode = .hardware
        state.transportType = transport
        state.isHardwareInitialized = true
        let driver = FakeThunderboltDriver()
        driver.driverBuild = build
        driver.boards = (slot1.rawValue, slot2.rawValue)
        let tb = ThunderboltDeviceConnection(identifier: SimulatedDevice.symphonyIO32ch().identifier,
                                             audioDeviceID: 0, driver: driver)
        state.device = tb
        state.primaryBoardType = slot1
        state.secondaryBoardType = slot2
        state.primaryBoardSource = .detected
        state.secondaryBoardSource = .detected
        state.servingDextBuild = build.map { .build($0) }
        state.unitAIdentity = 0x1f
        state.unitAIdentityState = .known(0x1f)
        return (state, tb, driver)
    }

    @Test("AppState follows the driver's order: card by card under 149, what 150 applied, nothing written until known")
    func gate() async {
        let restore = restoringDefaults(); defer { restore() }
        UserDefaults.standard.set(true, forKey: ChannelOrderRoutingReset.doneKey)
        let (old, oldTB, _) = makeState(slot1: .optical, slot2: .analogAD16, build: 149)
        await old.refreshThunderboltChannelOrder(oldTB)
        #expect(old.thunderboltUnitOrder(unit: .a) == ThunderboltUnitChannelOrder(order: .cardByCard, slot1: .optical, slot2: .analogAD16))
        #expect(old.thunderboltChannelOrderUnknownReason == nil)
        // Card by card: ADAT 1-8 on Mac 9-16 (slot 1's digital after its analog).
        let oldInputs = Dictionary(old.thunderboltDefaultInputRoutes().map { (Int($0.destination), Int($0.source)) },
                                   uniquingKeysWith: { a, _ in a })
        #expect(oldInputs[192 + 8] == 32 + 8)

        let (new, newTB, driver) = makeState(slot1: .optical, slot2: .analogAD16, build: 150)
        driver.channelOrder = ThunderboltAppliedChannelOrder(unitA: .init(order: nil, slot1: nil, slot2: nil))
        await new.refreshThunderboltChannelOrder(newTB)
        #expect(new.thunderboltUnitOrder(unit: .a) == nil)
        #expect(new.thunderboltChannelOrderUnknownReason != nil)
        #expect(new.cardTableUnreadableReason() != nil)
        // An Output Routing click is not sent either while the order is not known.
        await #expect(throws: (any Error).self) {
            try await new.writeOutputRoute(destination: SymphonyIORoutingAddress.ioBoard1Base, source: 8, device: newTB)
        }
        #expect(!driver.log.contains { if case .route = $0 { true } else { false } })
        driver.channelOrder = nil   // the fake answers as a build-150 driver would
        await new.refreshThunderboltChannelOrder(newTB)
        #expect(new.thunderboltUnitOrder(unit: .a) == ThunderboltUnitChannelOrder(order: .analogFirst, slot1: .optical, slot2: .analogAD16))
        // Analog first: inputs 1-24 Line 1-24 (slot 2's 16 after slot 1's 8), 25-32 ADAT 1-8.
        let inputs = Dictionary(new.thunderboltDefaultInputRoutes().map { (Int($0.destination), Int($0.source)) },
                                uniquingKeysWith: { a, _ in a })
        #expect(inputs[192 + 8] == 48)
        #expect(inputs[192 + 24] == 32 + 8)
        // The output table: every XLink channel of the unit is declared.
        let table = new.thunderboltOutputTable(for: newTB, quiet: true)
        let channels = Set(table.keys.compactMap { new.thunderboltXLinkChannel(forDestination: $0) })
            .union(new.thunderboltUnreachedChannels)
        #expect(channels == Set(0..<32))
        // Once known a click is sent (the positive control): slot 1's ADAT 1
        // is XLink 8 (the A16 in slot 2 has no analog outputs).
        _ = try? await new.writeOutputRoute(destination: SymphonyIORoutingAddress.ioBoard0Base + 8, source: 8, device: newTB)
        #expect(driver.log.contains { if case .route(channel: 8, _, true) = $0 { true } else { false } })
    }

    @Test("The first connect with driver 150 and moving cards resets the routing once and shows the notice")
    func resetAtConnect() async {
        let restore = restoringDefaults(); defer { restore() }
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: ChannelOrderRoutingReset.doneKey)
        defaults.removeObject(forKey: ChannelOrderRoutingReset.noticePendingKey)
        defaults.removeObject(forKey: ChannelOrderRoutingReset.alertPendingKey)
        defaults.removeObject(forKey: ChannelOrderRoutingReset.noticeTextKey)
        RoutingMixerReset.clearPending(.thunderboltInputRouting)

        // USB never runs it, nor an older driver.
        let (usb, usbTB, _) = makeState(slot1: .optical, slot2: .optical, build: 150, transport: .usb)
        usb.runChannelOrderResetIfNeeded()
        _ = usbTB
        #expect(!defaults.bool(forKey: ChannelOrderRoutingReset.doneKey))
        let (old, oldTB, _) = makeState(slot1: .optical, slot2: .optical, build: 149)
        await old.refreshThunderboltChannelOrder(oldTB)
        #expect(!defaults.bool(forKey: ChannelOrderRoutingReset.doneKey))
        // Cards the order does not move: it waits for a setup that does.
        let (still, stillTB, _) = makeState(slot1: .analogADDA16, slot2: .analogADDA16, build: 150)
        await still.refreshThunderboltChannelOrder(stillTB)
        #expect(!defaults.bool(forKey: ChannelOrderRoutingReset.doneKey))

        let (state, tb, _) = makeState(slot1: .optical, slot2: .optical, build: 150)
        let input = state.peripheralRoutingCache(direction: "input")
        let output = state.peripheralRoutingCache(direction: "output")
        input.save([4: 0])
        output.save([0: Set([4])])
        #expect(input.load() != nil && output.loadMulti() != nil)
        await state.refreshThunderboltChannelOrder(tb)
        #expect(defaults.bool(forKey: ChannelOrderRoutingReset.doneKey))
        #expect(input.load() == nil)
        #expect(output.loadMulti() == nil)
        #expect(RoutingMixerReset.isPending(.thunderboltInputRouting))
        // Two 8x8s: both directions moved, and the notice says so, once as an alert.
        #expect(state.channelOrderResetNotice?.contains("Input Routing and Output Routing") == true)
        #expect(state.channelOrderResetNotice?.contains("different physical outputs") == true)
        #expect(state.channelOrderResetAlert == state.channelOrderResetNotice)
        #expect(state.inputRoutingReplayNeeded)
        #expect(state.cardOutputTableReplayNeeded)
        state.acknowledgeChannelOrderResetAlert()
        #expect(state.channelOrderResetAlert == nil && state.channelOrderResetNotice != nil)
        #expect(!defaults.bool(forKey: ChannelOrderRoutingReset.alertPendingKey))
        // Once: a routing saved after it stays.
        input.save([4: 1])
        await state.refreshThunderboltChannelOrder(tb)
        #expect(input.load() == [4: 1])
        state.dismissChannelOrderResetNotice()
        #expect(state.channelOrderResetNotice == nil)
        #expect(!defaults.bool(forKey: ChannelOrderRoutingReset.noticePendingKey))
    }

    @Test("The owner's rig (8x8 + A16): only Input Routing is reset; Output Routing is kept and not rewritten")
    func resetInputsOnly() async {
        let restore = restoringDefaults(); defer { restore() }
        let defaults = UserDefaults.standard
        for key in [ChannelOrderRoutingReset.doneKey, ChannelOrderRoutingReset.noticePendingKey,
                    ChannelOrderRoutingReset.alertPendingKey, ChannelOrderRoutingReset.noticeTextKey] {
            defaults.removeObject(forKey: key)
        }
        RoutingMixerReset.clearPending(.thunderboltInputRouting)
        let (state, tb, _) = makeState(slot1: .optical, slot2: .analogAD16, build: 150)
        let input = state.peripheralRoutingCache(direction: "input")
        let output = state.peripheralRoutingCache(direction: "output")
        input.save([4: 0])
        // Mixer 1 on Line 1-2, as monitored through the mixer.
        output.save([16: Set([0])])
        await state.refreshThunderboltChannelOrder(tb)
        #expect(defaults.bool(forKey: ChannelOrderRoutingReset.doneKey))
        #expect(input.load() == nil)
        #expect(output.loadMulti() == [16: Set([0])])
        #expect(RoutingMixerReset.isPending(.thunderboltInputRouting))
        #expect(state.inputRoutingReplayNeeded)
        #expect(!state.cardOutputTableReplayNeeded)
        let notice = state.channelOrderResetNotice ?? ""
        #expect(notice.contains("DAW input 9, was 17"))
        #expect(notice.contains("Output Routing was kept"))
        #expect(!notice.contains("different physical outputs"))
        #expect(state.channelOrderResetAlert == notice)
    }

    @Test("Selector 17 is trusted when the build read fails; a known build is not replaced by a failed read")
    func unknownBuild() async {
        let restore = restoringDefaults(); defer { restore() }
        UserDefaults.standard.set(true, forKey: ChannelOrderRoutingReset.doneKey)
        let (state, tb, driver) = makeState(slot1: .optical, slot2: .analogAD16, build: 150)
        // The build read failed: not known until selector 17 answers.
        state.servingDextBuild = nil
        driver.channelOrder = ThunderboltAppliedChannelOrder(unitA: .init(order: nil, slot1: nil, slot2: nil))
        await state.refreshThunderboltChannelOrder(tb)
        #expect(state.thunderboltUnitOrder(unit: .a) == nil)
        // A headphone skipped meanwhile is owed.
        #expect(!(await HeadphoneCrosspoint.apply(.headphone1, sourceID: 0, device: tb, cachedRoutes: [:],
                                                  transport: .thunderbolt, state: state)))
        #expect(state.thunderboltHeadphoneCrosspointOwed)
        driver.channelOrder = ThunderboltAppliedChannelOrder(unitA: .init(order: .analogFirst, slot1: .optical, slot2: .analogAD16))
        await state.refreshThunderboltChannelOrder(tb)
        #expect(state.thunderboltUnitOrder(unit: .a)?.order == .analogFirst)
        #expect(!state.thunderboltHeadphoneCrosspointOwed)
        // `.olderThanBuildReporting` from a failed read does not replace a known build.
        state.servingDextBuild = .build(150)
        state.noteServingDextBuild(.olderThanBuildReporting, from: tb)
        state.noteServingDextBuild(nil, from: tb)
        #expect(state.servingDextBuild == .build(150))
    }

    @Test("Without selector 17 an unknown build holds routing; a reported old build is card by card")
    func unknownBuildWithoutSelector17() async {
        let restore = restoringDefaults(); defer { restore() }
        UserDefaults.standard.set(true, forKey: ChannelOrderRoutingReset.doneKey)
        let (state, tb, _) = makeState(slot1: .optical, slot2: .analogAD16, build: 149)
        state.servingDextBuild = .olderThanBuildReporting
        await state.refreshThunderboltChannelOrder(tb)
        #expect(state.thunderboltUnitOrder(unit: .a) == nil)
        #expect(state.thunderboltChannelOrderUnknownReason != nil)
        state.noteServingDextBuild(.build(149), from: tb)
        #expect(state.thunderboltUnitOrder(unit: .a)?.order == .cardByCard)
        #expect(state.thunderboltChannelOrderUnknownReason == nil)
    }

    @Test("Speaker sets go back to the output the driver plays there in its order")
    func speakerSetDefaults() async {
        let restore = restoringDefaults(); defer { restore() }
        UserDefaults.standard.set(true, forKey: ChannelOrderRoutingReset.doneKey)
        // An A16 (no analog outputs) with a D16: the speaker outputs are slot 2's Line 1-6.
        let line3 = SymphonyIORoutingAddress.ioBoard1Base + 2
        let (old, oldTB, _) = makeState(slot1: .analogAD16, slot2: .analogDA16, build: 149)
        await old.refreshThunderboltChannelOrder(oldTB)
        #expect(old.speakerSetDefaultSource(forDestination: line3) == 18)
        let (new, newTB, _) = makeState(slot1: .analogAD16, slot2: .analogDA16, build: 150)
        await new.refreshThunderboltChannelOrder(newTB)
        #expect(new.speakerSetDefaultSource(forDestination: line3) == 2)
        // USB keeps its position rule.
        let (usb, _, _) = makeState(slot1: .analogAD16, slot2: .analogDA16, build: nil, transport: .usb)
        #expect(usb.speakerSetDefaultSource(forDestination: line3) == SymphonyIORoutingAddress.p2pBase + 18)
    }

    @Test("Output Routing rows read naturally in the analog-first order")
    func outputNames() {
        let layout = CardLayout(slot1: .optical, slot2: .optical)
        let names = (0..<16).compactMap { layout.thunderboltOutputPairName(pair: $0, prefix: "A", order: .analogFirst) }
        #expect(names == (0..<8).map { "A Line \($0 * 2 + 1)/\($0 * 2 + 2)" } + (0..<8).map { "A ADAT \($0 * 2 + 1)/\($0 * 2 + 2)" })
        // Card by card the same unit read Line 1-8, ADAT 1-8, Line 9-16, ADAT 9-16.
        let byCard = (0..<16).compactMap { layout.thunderboltOutputPairName(pair: $0, prefix: "A", order: .cardByCard) }
        #expect(byCard[4] == "A ADAT 1/2" && byCard[8] == "A Line 9/10")
    }
}
}
