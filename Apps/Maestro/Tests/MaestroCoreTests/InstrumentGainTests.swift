import Foundation
import Testing
@testable import MaestroCore

@Suite("Independent MicPre gain stages")
struct InstrumentGainTests {
    @Test func selectorsFollowInputType() {
        #expect(InputChannelLogic.gainSelector(for: .instrument) == .instrumentGain)
        #expect(InputChannelLogic.gainSelector(for: .mic) == .micGain)
    }

    @Test func legacyStateMigratesOnlyTheSelectedStage() throws {
        for type in [3, 4] {
            let data = Data("{\"gain\":42,\"inputType\":\(type)}".utf8)
            let state = try JSONDecoder().decode(InputChannelState.self, from: data)
            #expect(state.gain == 42)
            #expect(state.micGain == (type == 3 ? 42 : 0))
            #expect(state.instrumentGain == (type == 4 ? 42 : 0))
        }
    }

    @Test func groupedEditsPreserveBothStages() throws {
        var channels = [InputChannelState(gain: 30, inputType: 3, group: 1),
                        InputChannelState(gain: 20, inputType: 4, group: 1)]
        let result = InputChannelLogic.applyGainChange(&channels, channel: 0, to: 40)
        #expect(result.hardwareWrites == [0])
        #expect(channels[0].micGain == 40)
        #expect(channels[1].instrumentGain == 30)
        #expect(channels[0].instrumentGain == 0)
        #expect(channels[1].micGain == 0)
        let restored = try JSONDecoder().decode([InputChannelState].self,
            from: JSONEncoder().encode(channels))
        #expect(restored == channels)
        InputChannelLogic.applyLevelChange(&channels[1], to: .mic)
        #expect(channels[1].gain == 0)
        InputChannelLogic.applyLevelChange(&channels[1], to: .instrument)
        #expect(channels[1].gain == 30)
    }

    @Test func resetClearsBothStages() {
        var channels = [InputChannelState(gain: 20, micGain: 40, instrumentGain: 20, inputType: 4)]
        InputChannelLogic.resetToDefaults(&channels, includingCalibration: false,
            micPreInstalled: true, hostAnalogInputChannels: 8)
        #expect(channels[0].micGain == 0)
        #expect(channels[0].instrumentGain == 0)
    }
}
