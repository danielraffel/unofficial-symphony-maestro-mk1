import Foundation
import Testing
@testable import MaestroCore
@testable import MaestroDevice

/// DAW edits of the 8MicPre reach Maestro's saved strips through the driver's
/// per-unit, per-channel records (selector 5's second tail), never through a
/// HAL element number.
@Suite struct MicPreDAWObservationTests {
    private static let layout = CardLayout(slot1: .analogADDA16, slot2: .micPre8)

    private static func record(_ stamp: UInt64, type: AnalogInputLevel? = nil, phase: Bool? = nil,
                               highPass: Bool? = nil, gain: (Int, Bool)? = nil) -> MicPreEditRecord {
        var fields: UInt32 = 0
        if let type { fields |= type.rawValue | MicPreEditRecord.typeValid }
        if let phase { fields |= MicPreEditRecord.phaseValid | (phase ? MicPreEditRecord.phaseBit : 0) }
        if let highPass { fields |= MicPreEditRecord.highPassValid | (highPass ? MicPreEditRecord.highPassBit : 0) }
        if let (value, instrument) = gain {
            fields |= UInt32(value) << MicPreEditRecord.gainShift | MicPreEditRecord.gainValid
            if instrument { fields |= MicPreEditRecord.gainInstrument }
        }
        return MicPreEditRecord(stamp: stamp, fields: fields)
    }

    private static func empty() -> [MicPreEditRecord] {
        Array(repeating: MicPreEditRecord(stamp: 0, fields: 0), count: 16)
    }

    @Test func linkStateDecodesEditsAfterTheMixerInstance() throws {
        var words = [UInt32](repeating: 0, count: 100)
        words[1] = 1
        words[16] = 5                       // A0 phantom OFF receipt
        words[48] = DriverMixerInstance.magic   // MIXS at 48-51
        words[50] = 9
        words[52 + 9 * 3] = 77              // B1 edit stamp, low word
        words[52 + 9 * 3 + 1] = 1           // high word
        words[52 + 9 * 3 + 2] = 3 | MicPreEditRecord.typeValid
        let state = try #require(LinkState.decode(words))
        #expect(state.phantomOffReceipts[0] == 5)
        #expect(state.micPreEdits.count == 16)
        #expect(state.micPreEdits[9].stamp == (UInt64(1) << 32 | 77))
        #expect(state.micPreEdits[9].inputType == .mic)
        #expect(state.micPreEdits[0].stamp == 0 && state.micPreEdits[0].inputType == nil)
        #expect(state.mixerInstance?.nonce == 9)
        let d5Only = try #require(LinkState.decode(Array(words.prefix(52))))
        #expect(d5Only.micPreEdits.isEmpty && d5Only.mixerInstance?.nonce == 9)
        let receiptsOnly = try #require(LinkState.decode(Array(words.prefix(48))))
        #expect(receiptsOnly.micPreEdits.isEmpty)
        #expect(receiptsOnly.phantomOffReceipts[0] == 5)
        #expect(LinkState.decode(Array(words.prefix(99))) == nil)
    }

    @Test func typeChangeAppliesMaestroLevelRules() {
        var mic = InputChannelState(gain: 30, phantom: true, inputType: AnalogInputLevel.mic.rawValue,
                                    trim: 1.5, group: 2, insert: 3, insertReturn: true)
        mic.recordPhantomRequest(true, identity: 42, boardSlot: 1, channel: 0)
        var states = [mic]
        var seen: [UInt64] = []
        var records = Self.empty()
        records[0] = Self.record(10, type: .plus4dBu)
        let changed = MicPreDAWObservation.apply(records[0..<8], seen: &seen, to: &states, stripCount: 16)
        #expect(changed)
        #expect(states.count == 16)
        #expect(states[0].inputType == AnalogInputLevel.plus4dBu.rawValue)
        #expect(!states[0].phantom && states[0].phantomProvenance == nil)
        #expect(states[0].group == InputChannelLogic.groupOff)
        #expect(states[0].insert == InputChannelLogic.insertNone && !states[0].insertReturn)
        #expect(states[0].micGain == 30)              // the Mic stage keeps its gain
        #expect(seen[0] == 10)
        // The same stamp is never applied twice, even after Maestro changes the strip.
        states[0].inputType = AnalogInputLevel.mic.rawValue
        #expect(!MicPreDAWObservation.apply(records[0..<8], seen: &seen, to: &states, stripCount: 16))
        #expect(states[0].inputType == AnalogInputLevel.mic.rawValue)
    }

    @Test func switchesAndGainLandOnTheirStage() {
        var states = (0..<16).map { _ in InputChannelState(inputType: AnalogInputLevel.instrument.rawValue) }
        var seen = [UInt64](repeating: 0, count: 8)
        var records = Self.empty()
        records[2] = Self.record(4, phase: true, highPass: false, gain: (40, true))
        records[3] = Self.record(5, gain: (70, false))
        #expect(MicPreDAWObservation.apply(records[0..<8], seen: &seen, to: &states, stripCount: 16))
        #expect(states[2].phase && !states[2].hpf)
        #expect(states[2].instrumentGain == 40 && states[2].gain == 40)
        #expect(states[3].micGain == 70 && states[3].gain == 0)   // Mic stage stored, Instrument shown
        #expect(states[1] == InputChannelState(inputType: AnalogInputLevel.instrument.rawValue))
    }

    @Test func unitBRecordsReachOnlyUnitBAndStripsAreCreated() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let a = ChannelStateStore(defaults: defaults, layout: Self.layout, isSimulatingCards: false, identity: 42)
        let b = ChannelStateStore(defaults: defaults, layout: Self.layout, isSimulatingCards: false,
                                  unit: .b, identity: 43)
        a.save([InputChannelState(inputType: AnalogInputLevel.mic.rawValue)], for: ChannelStateStore.inputKey)
        var records = Self.empty()
        records[8] = Self.record(9, type: .mic, phase: true)    // B MicPre 1
        #expect(!MicPreDAWObservation.apply(records, to: a, stripCount: 16))
        #expect(MicPreDAWObservation.apply(records, to: b, stripCount: 16))
        let savedA = try #require(a.load(ChannelStateStore.inputKey, as: [InputChannelState].self))
        let savedB = try #require(b.load(ChannelStateStore.inputKey, as: [InputChannelState].self))
        #expect(savedA == [InputChannelState(inputType: AnalogInputLevel.mic.rawValue)])
        #expect(savedB.count == 16)                             // no saved rows: full default page
        #expect(savedB[0].inputType == AnalogInputLevel.mic.rawValue && savedB[0].phase)
        #expect(!savedB[0].phantom)                             // a HAL Mic never grants phantom
        // Acknowledged: a later Maestro choice is not undone by the old record.
        var later = savedB
        later[0].phase = false
        b.save(later, for: ChannelStateStore.inputKey)
        #expect(!MicPreDAWObservation.apply(records, to: b, stripCount: 16))
        #expect(b.load(ChannelStateStore.inputKey, as: [InputChannelState].self)?[0].phase == false)
    }

    @Test func clearedRecordsUnknownIdentityAndSimulationChangeNothing() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let store = ChannelStateStore(defaults: defaults, layout: Self.layout, isSimulatingCards: false, identity: 42)
        store.save([InputChannelState()], for: ChannelStateStore.inputKey)
        var records = Self.empty()
        records[0] = MicPreEditRecord(stamp: 3, fields: 0)     // Maestro cleared every field
        #expect(!MicPreDAWObservation.apply(records, to: store, stripCount: 16))
        #expect(store.load(ChannelStateStore.inputKey, as: [InputChannelState].self) == [InputChannelState()])
        #expect(store.load(MicPreDAWObservation.seenKey, as: [UInt64].self)?[0] == 3)
        records[0] = Self.record(4, type: .variable)
        let anonymous = ChannelStateStore(defaults: defaults, layout: Self.layout, isSimulatingCards: false)
        let simulated = ChannelStateStore(defaults: defaults, layout: Self.layout, isSimulatingCards: true, identity: 42)
        #expect(!MicPreDAWObservation.apply(records, to: anonymous, stripCount: 16))
        #expect(!MicPreDAWObservation.apply(records, to: simulated, stripCount: 16))
        #expect(!MicPreDAWObservation.apply(Array(records.prefix(8)), to: store, stripCount: 16))
    }
}
