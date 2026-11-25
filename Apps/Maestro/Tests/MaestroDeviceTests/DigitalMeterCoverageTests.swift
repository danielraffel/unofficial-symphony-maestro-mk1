import Foundation
import Testing
import MaestroCore
@testable import MaestroDevice

struct DigitalMeterCoverageTests {
    // Analog offset and digital channel count from each module's I/O complement.
    private static let modules: [(IOCardType, Int, Int, Int, Int)] = [
        (.none, 0, 0, 0, 0),
        (.micPre8, 0, 0, 0, 0),
        (.analogAES, 8, 8, 8, 8),
        (.optical, 8, 8, 8, 8),
        (.analogAD16, 16, 0, 0, 16),
        (.analogDA16, 0, 16, 16, 0),
        (.analogADDA16, 16, 0, 16, 0),
        (.twoBySix, 2, 10, 6, 10),
    ]

    @Test(arguments: modules)
    func everyCardDigitalPairReadsBothChannelsOnUSBAndCard(
        card: IOCardType, analogIn: Int, digitalIn: Int, analogOut: Int, digitalOut: Int
    ) throws {
        // The inactive slot carries a known analog-only module so the digital
        // map must expose just this card's channels.
        for board in 0..<2 {
            let layout = board == 0 ? CardLayout(slot1: card, slot2: .analogADDA16)
                : CardLayout(slot1: .analogADDA16, slot2: card)
            let input = (0..<digitalIn).map { board * 16 + analogIn + $0 }
            let output = (0..<digitalOut).map { board * 16 + analogOut + $0 }

            // USB and the card's unit-output read share the unit word layout.
            var data = Data()
            for word in 0..<32 {
                data.append(UInt8(word + 0x80))
                data.append(0xA0)
            }
            func expectedUnit(_ words: [Int]) -> [MeterReading] {
                words.map { MeterReading.unit(word: 0xA080 + UInt16($0)) }
            }
            let usbInput = TDMMeterPayload.digitalReadings(data, layout: layout, isInput: true)
            let usbOutput = TDMMeterPayload.digitalReadings(data, layout: layout, isInput: false)
            let unitOutput = try #require(UnitOutputMeters.levels(payload: data, layout: layout))
            #expect(usbInput.count == 32 && usbOutput.count == 32)
            #expect(usbInput.filter(\.isOver) == expectedUnit(input))
            #expect(usbOutput.filter(\.isOver) == expectedUnit(output))
            #expect(unitOutput.digitalReadings == usbOutput)

            // Make each card input's host tap unambiguous, even for a partial
            // card. Unit B sees the same routes with the second port's offset.
            let inputRoutes: [ThunderboltInputMeterMap.Route] = (0..<32).map { index in
                (destination: SymphonyIORoutingAddress.p2pBase + UInt8(index),
                 source: SymphonyIORoutingAddress.ioBoard0Base + UInt8(index))
            }
            let aInput = ThunderboltInputMeterMap.words(layout: layout, routes: inputRoutes).digital
            let bInput = UnitBMeterMap.inputWords(layout: layout, routes: inputRoutes).digital
            #expect(aInput.count == 32 && bInput.count == 32)
            #expect(aInput.compactMap { $0 } == input)
            #expect(bInput.compactMap { $0 } == input.map { $0 + 32 })

            let aRoutes = Dictionary(uniqueKeysWithValues: (0..<32).map {
                (SymphonyIORoutingAddress.ioBoard0Base + UInt8($0), UInt8($0))
            })
            let bRoutes = aRoutes.mapValues { $0 + 32 }
            let aOutput = try #require(ThunderboltOutputMeterMap.words(
                layout: layout, table: aRoutes, unitBActive: true)).digital
            let bOutput = try #require(ThunderboltOutputMeterMap.words(
                layout: layout, table: bRoutes, unitBActive: true, unitB: true)).digital
            #expect(aOutput.count == 32 && bOutput.count == 32)
            #expect(aOutput.compactMap { $0 } == output.map { $0 + 64 })
            #expect(bOutput.compactMap { $0 } == output.map { $0 + 96 })

            let inputIndices = try layout.digitalInputPairs.map { pair in try #require(pair.meterIndex) }
            let outputIndices = try layout.digitalOutputPairs.map { pair in try #require(pair.meterIndex) }
            #expect(inputIndices.count * 2 == digitalIn)
            #expect(outputIndices.count * 2 == digitalOut)
            for (pair, index) in inputIndices.enumerated() {
                #expect(Array(usbInput[index...index + 1]) == expectedUnit(Array(input[pair * 2...pair * 2 + 1])))
                #expect(aInput[index] == input[pair * 2] && bInput[index + 1] == 32 + input[pair * 2 + 1])
            }
            for (pair, index) in outputIndices.enumerated() {
                #expect(Array(usbOutput[index...index + 1]) == expectedUnit(Array(output[pair * 2...pair * 2 + 1])))
                #expect(aOutput[index] == 64 + output[pair * 2] && bOutput[index + 1] == 96 + output[pair * 2 + 1])
            }
        }
    }
}
