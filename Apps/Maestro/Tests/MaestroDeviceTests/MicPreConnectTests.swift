import Foundation
import Testing
@testable import MaestroCore
@testable import MaestroDevice

@Suite("C1/C2 MicPre connect safety")
struct MicPreConnectTests {
    let layout = CardLayout(slot1: .analogADDA16, slot2: .micPre8)
    func mic() -> InputChannelState {
        var state = InputChannelState(micGain: 80, instrumentGain: 20, inputType: 3,
                                      group: 2, insert: 1, insertReturn: true)
        state.recordPhantomRequest(true, identity: 42, boardSlot: 1, channel: 0)
        return state
    }
    func properties(_ writes: [ThunderboltPreset.Write]) -> [(PropertyAddress, PropertyValue)] {
        writes.compactMap { if case .property(let a, let v) = $0 { return (a, v) }; return nil }
    }
    @Test func refusedPhantomWithConcurrentGainChange() {
        var request = mic()
        request.recordPhantomRequest(true, identity: nil, boardSlot: 1, channel: 0)
        #expect(request.phantomProvenance == nil)
        var saved = request
        var visible = request
        saved.micGain = 37
        visible.micGain = 37
        saved.finishPhantomRequest(request, accepted: false, identity: 42, boardSlot: 1, channel: 0)
        visible.finishPhantomRequest(request, accepted: false, identity: 42, boardSlot: 1, channel: 0)
        #expect(!saved.phantom)
        #expect(saved.phantomProvenance == nil)
        #expect(!visible.phantom)
        #expect(visible.phantomProvenance == nil)
        #expect(saved.micGain == 37)
        #expect(visible.micGain == 37)
    }
    @Test func acceptedPhantomPreservesConcurrentGainAndNewerOff() {
        var request = mic()
        request.recordPhantomRequest(true, identity: nil, boardSlot: 1, channel: 0)
        var current = request
        current.micGain = 37
        current.finishPhantomRequest(request, accepted: true, identity: 42, boardSlot: 1, channel: 0)
        #expect(current.restoresPhantom(identity: 42, boardSlot: 1, channel: 0))
        #expect(current.micGain == 37)
        current.phantom = false
        current.finishPhantomRequest(request, accepted: true, identity: 42, boardSlot: 1, channel: 0)
        #expect(!current.phantom)
        #expect(current.phantomProvenance == nil)
    }
    @Test func exactOriginalOrderAndBothGains() {
        let writes = properties(MicPreSettingsReplay.writes(inputs: [mic()], layout: layout, identity: 42))
        let expected: [AudioPropertySelector] = [.analogIOType, .insertReturnEnable]
            + Array(repeating: .insertID, count: 8)
            + [.micGain, .instrumentGain, .groupID, .phaseReverse, .phantom, .highPassFilter]
        #expect(writes.map(\.0.selector) == expected)
        #expect(writes[10].1 == .uint32(80))
        #expect(writes[11].1 == .uint32(20))
        #expect(writes[14].1 == .bool(true))
        #expect(writes[2..<10].map(\.0.element) == Array(0..<8))
        let masks: [PropertyValue] = [.uint32(1)] + Array(repeating: .uint32(0), count: 7)
        #expect(writes[2..<10].map(\.1) == masks)
    }
    @Test func provenanceDoesNotFollowTypeSlotChannelOrUnit() throws {
        let state = mic()
        #expect(state.restoresPhantom(identity: 42, boardSlot: 1, channel: 0))
        #expect(!state.restoresPhantom(identity: 43, boardSlot: 1, channel: 0))
        #expect(!state.restoresPhantom(identity: nil, boardSlot: 1, channel: 0))
        #expect(!state.restoresPhantom(identity: 42, boardSlot: 0, channel: 0))
        #expect(!state.restoresPhantom(identity: 42, boardSlot: 1, channel: 1))
        var changed = state
        InputChannelLogic.applyLevelChange(&changed, to: .instrument)
        InputChannelLogic.applyLevelChange(&changed, to: .mic)
        #expect(changed.micGain == 80)
        #expect(changed.instrumentGain == 20)
        #expect(changed.phantomProvenance == nil)
        #expect(!changed.phantom)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(InputChannelState.self, from: data)
        #expect(decoded == state)
    }
    @Test func defaultLegacyAndMigratedStateOnlyRestoreOff() throws {
        let legacy = try JSONDecoder().decode(InputChannelState.self,
            from: Data(#"{"inputType":3,"phantom":true}"#.utf8))
        for state in [InputChannelState(), legacy] {
            let writes = properties(MicPreSettingsReplay.writes(inputs: [state], layout: layout, identity: 42))
            let phantom = writes.filter { $0.0.selector == .phantom }.map(\.1)
            #expect(!phantom.isEmpty)
            #expect(phantom.allSatisfy { $0 == .bool(false) })
        }
        let defaults = ScratchUserDefaults(suiteName: "C2.\(UUID())")!
        let old = ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: false)
        old.save([mic()], for: ChannelStateStore.inputKey)
        let current = ChannelStateStore(defaults: defaults, layout: layout, isSimulatingCards: false, identity: 42)
        let loaded: [InputChannelState] = try #require(current.load(ChannelStateStore.inputKey))
        #expect(loaded[0].phantomProvenance == nil)
        current.save(loaded, for: ChannelStateStore.inputKey)
        #expect(!current.hasVerifiedInputIdentity)
    }
    @Test func everyPartialFailureAttemptsOffThenUnlock() {
        let writes = MicPreSettingsReplay.writes(inputs: [mic()], layout: layout, identity: 42)
        for failAt in writes.indices {
            var count = 0
            var delivered: [ThunderboltPreset.Write] = []
            var unlocked = false
            var failed = false
            do {
                try ThunderboltPreset.recall(writes, send: { write in
                    defer { count += 1 }
                    if count == failAt { throw DeviceConnectionError.notConnected }
                    delivered.append(write)
                }, unlock: { unlocked = true; return true }, retryDelay: {})
            } catch { failed = true }
            let last = properties(delivered).last
            #expect(failed)
            #expect(unlocked)
            #expect(last?.0.selector == .phantom)
            #expect(last?.1 == .bool(false))
        }
    }
    @Test func unlockTimeoutClearsPowerBeforeFinalReadback() {
        let writes = MicPreSettingsReplay.writes(inputs: [mic()], layout: layout, identity: 42)
        var delivered: [ThunderboltPreset.Write] = []
        var attempts = 0
        var failed = false
        var lastWasOff = false
        do {
            try ThunderboltPreset.recall(writes, send: { delivered.append($0) }, unlock: {
                attempts += 1
                if attempts == 10 {
                    let last = properties(delivered).last
                    lastWasOff = last?.0.selector == .phantom && last?.1 == .bool(false)
                }
                return false
            }, retryDelay: {})
        } catch { failed = true }
        #expect(failed)
        #expect(attempts == 10)
        #expect(lastWasOff)
    }

    @Test func leavingMicIsOffEvenWhenTypeWriteFails() {
        for level in [AnalogInputLevel.instrument, .plus4dBu] {
            var state = mic()
            InputChannelLogic.applyLevelChange(&state, to: level)
            let writes = MicPreSettingsReplay.writes(inputs: [state], layout: layout, identity: 42)
            var delivered: [ThunderboltPreset.Write] = []
            var unlocked = false
            do {
                try ThunderboltPreset.recall(writes, send: { write in
                    if case .property(let address, _) = write, address.selector == .analogIOType {
                        throw DeviceConnectionError.notConnected
                    }
                    delivered.append(write)
                }, unlock: { unlocked = true; return true }, retryDelay: {})
            } catch {}
            let power = properties(delivered).filter { $0.0.selector == .phantom }.map(\.1)
            #expect(!power.isEmpty)
            #expect(power.allSatisfy { $0 == .bool(false) })
            #expect(unlocked)
        }
    }

    @Test func convertersAndMissingBoardGetNoPreampWrites() {
        let unknown = MicPreSettingsReplay.writes(inputs: [mic()], layout: CardLayout(isKnown: false), identity: 42)
        let noBoard = MicPreSettingsReplay.writes(inputs: [mic()], layout: CardLayout(slot1: .analogADDA16), identity: 42)
        #expect(unknown.isEmpty)
        #expect(noBoard.isEmpty)
    }
    @Test func usbSequenceFinishesAndCleansUpFailure() async throws {
        for fails in [false, true] {
            let transport = MockXPCTransport()
            transport.failFirstSets = fails ? 1 : 0
            let connection = XPCDeviceConnection(identifier: SimulatedDevice.symphonyIO32ch().identifier,
                                                   transport: transport)
            let writes = MicPreSettingsReplay.writes(inputs: [mic()], layout: layout, identity: 42)
            var failed = false
            do { try await MicPreSettingsReplay.apply(writes, layout: layout, device: connection) }
            catch { failed = true }
            #expect(failed == fails)
            #expect(transport.setPropertyCalls.last?.bRequest == 0xDD)
            #expect(transport.getPropertyCalls.last?.bRequest == 0xDD)
            let phantom = transport.setPropertyCalls.filter { $0.bRequest == 0xC6 }.map(\.data)
            #expect(phantom == [Data([fails ? 0 : 1])])
        }
    }

    @Test @MainActor func unitBIsIsolatedAndEndsWithUnlockReadback() async throws {
        let transport = RecordingVendorTransport()
        transport.reply = [0]
        let state = UnitBState(present: true, boardType: [IOCardType.analogADDA16.rawValue, IOCardType.micPre8.rawValue],
                              boardValid: [1, 1], prefix: 0x42, clockSource: 2, setupFlags: 1, txErrors: 0)
        let connection = ThunderboltUnitBConnection(identifier: SimulatedDevice.symphonyIO32ch().identifier,
            transport: transport, infoRouting: {
                SymphonyRoutingModel(topology: .symphonyOnly, hostChannels: 64, unitBConfigured: true)
            }, state: { state })
        let writes = MicPreSettingsReplay.writes(inputs: [mic()], layout: layout, identity: 42)
        try await MicPreSettingsReplay.apply(writes, layout: layout, device: connection)
        #expect(transport.sent.allSatisfy { $0.port == 1 })
        #expect(transport.sent.last?.command == 0xDD)
        #expect(transport.reads.last?.command == 0xDD)
        #expect(!transport.readOnMainThread)
        connection.invalidate()
        let before = transport.sent.count
        do { try await MicPreSettingsReplay.apply(writes, layout: layout, device: connection) } catch {}
        #expect(transport.sent.count == before)
    }
}
