import Foundation
import Testing
@testable import MaestroCore

struct MeterHoldTests {
    @Test(arguments: [
        (UInt32(0), 0.0, -60.0),
        (UInt32(1), 1.5, -3.0),
        (UInt32(1), 2.0, -3.0),
        (UInt32(1), 2.25, -13.0),
        (UInt32(1), 4.0, -30.0),
        (UInt32(2), 400.0, -3.0),
    ])
    func peakHoldTiming(mode: UInt32, elapsed: Double, expected: Double) {
        let settings = MeterDisplaySettings(peakWireValue: mode, overWireValue: 0)
        var hold = MeterHold()
        hold.update(level: -3, over: false, at: 0, settings: settings)
        hold.update(level: -30, over: false, at: elapsed, settings: settings)
        #expect(hold.peak == expected)
    }

    @Test(arguments: [
        (UInt32(0), 0.099, true),
        (UInt32(0), 0.1, false),
        (UInt32(1), 1.999, true),
        (UInt32(1), 2.0, false),
        (UInt32(2), 400.0, true),
        (UInt32(3), 1.999, true),
        (UInt32(3), 2.0, false),
    ])
    func overHoldTiming(mode: UInt32, elapsed: Double, expected: Bool) {
        let settings = MeterDisplaySettings(peakWireValue: 0, overWireValue: mode)
        var hold = MeterHold()
        hold.update(level: -3, over: true, at: 0, settings: settings)
        hold.update(level: -3, over: false, at: elapsed, settings: settings)
        #expect(hold.isOver == expected)
    }

    @Test func newClipsExtendHoldAndClearResetsBothIndicators() {
        let settings = MeterDisplaySettings(peakHoldMode: .infinite, oversHoldMode: .twoSeconds)
        var hold = MeterHold()
        hold.update(level: -8, over: true, at: 0, settings: settings)
        hold.update(level: -3, over: true, at: 1.9, settings: settings)
        hold.update(level: -15, over: false, at: 2.1, settings: settings)
        #expect(hold.isOver)
        #expect(hold.peak == -3)
        hold = MeterHold()
        #expect(!hold.isOver)
        #expect(hold.peak == -60)
    }

    @Test func clipBitsSurviveUSBCardAndUnitOutputDecoding() throws {
        let clean = MeterReading.unit(word: 0x3FFF)
        #expect(clean.level == 0 && !clean.isOver)
        let card = MeterReading.card(word: 0x80000002)
        #expect(card.level == MeterReading.card(word: 0x80000000).level && card.isOver)
        #expect(!MeterReading.card(word: 0x80000001).isOver)

        var payload = Data(repeating: 0, count: 64)
        payload[0] = 0xFF
        payload[1] = 0xBF
        payload[63] = 0x80
        #expect(TDMMeterPayload.reading(payload, word: 0).isOver)
        #expect(TDMMeterPayload.mixerReadings(payload)[0].isOver)
        #expect(!TDMMeterPayload.mixerReadings(payload)[1].isOver)
        let outputs = try #require(UnitOutputMeters.levels(
            payload: payload, layout: CardLayout(slot1: .optical, slot2: .analogAD16)))
        #expect(outputs.analogReadings[0].level == 0 && outputs.analogReadings[0].isOver)
        #expect(outputs.digitalReadings[31].level == -60 && outputs.digitalReadings[31].isOver)
        #expect(outputs.digitalReadings[30] == .silence)
    }

    @Test func overSourceSnapshotForUSBAndCardBuilds() {
        func snapshot(_ sources: (input: Bool, output: Bool, mixer: Bool)) -> [Bool] {
            [sources.input, sources.output, sources.mixer]
        }
        #expect(snapshot(MeterOverSources.available(card: false)) == [true, true, true])
        #expect(snapshot(MeterOverSources.available(card: false, usbOutputs: false, usbMixer: false))
                == [true, false, false])
        #expect(snapshot(MeterOverSources.available(card: true)) == [false, false, MeterOverSources.cardOverBitConfirmed])
        #expect(snapshot(MeterOverSources.available(card: true, build: .build(143), unitOutputsFresh: true))
                == [false, false, MeterOverSources.cardOverBitConfirmed])
        #expect(snapshot(MeterOverSources.available(card: true, build: .build(144)))
                == [false, false, MeterOverSources.cardOverBitConfirmed])
        #expect(snapshot(MeterOverSources.available(card: true, build: .build(144), unitOutputsFresh: true))
                == [false, true, MeterOverSources.cardOverBitConfirmed])
    }
}
