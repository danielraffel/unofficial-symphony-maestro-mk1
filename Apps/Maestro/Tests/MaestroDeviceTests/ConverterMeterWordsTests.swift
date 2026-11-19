import Foundation
import Testing
@testable import MaestroDevice
import MaestroCore

@Suite("Converter meter words and config input")
struct ConverterMeterWordsTests {
    @Test("each converter host input reads its bus slot's word")
    func words() throws {
        let two = try #require(ConverterSystem(simulationName: "rosetta800+ad16x|ad16x"))
        let words = ThunderboltInputMeterMap.converterWords(two)
        #expect(words.channels.count == 40)
        #expect(words.channels[7] == 7)    // A In 8
        #expect(words.channels[8] == 16)   // B Line 1 on slot 17
        #expect(words.channels[24] == 32)  // C Line 1: port 2, slot 1
        #expect(words.digital.allSatisfy { $0 == nil })
        // Strip levels from 64 words: strip 8 shows word 16.
        var host = [Double](repeating: -60, count: ThunderboltInputMeterMap.converterWordCount)
        host[16] = -6; host[32] = -12
        let levels = ThunderboltInputMeterMap.stripLevels(host: host, words: words, count: 40)
        #expect(levels[8] == -6 && levels[24] == -12 && levels[0] == -60)
    }

    @Test("selector 10 input is {magic 'SYMP', config}, 8 bytes")
    func configInput() {
        let data = DextUserClient.converterConfigInput(0x0000_0101)
        #expect(data.count == 8)
        #expect([UInt8](data) == [0x50, 0x4D, 0x59, 0x53, 0x01, 0x01, 0x00, 0x00])
    }
}
