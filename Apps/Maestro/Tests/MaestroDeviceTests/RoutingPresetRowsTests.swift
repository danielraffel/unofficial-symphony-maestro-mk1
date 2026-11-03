import Testing
@testable import MaestroDevice

@Suite("Output routing preset rows")
struct RoutingPresetRowsTests {

    @Test("Mixer rows are stored under sentinels, DAW rows by index")
    func encode() {
        let grid: [Int: Set<Int>] = [0: [0], 7: [7], 8: [1], 9: [2]]   // USB: 8 pairs, mixers at 8/9
        let stored = RoutingPresetRows.encode(grid, dawPairCount: 8)
        #expect(stored == [0: [0], 7: [7], RoutingPresetRows.mixer1Sentinel: [1], RoutingPresetRows.mixer2Sentinel: [2]])
    }

    @Test("A ThunderBridge preset with no mixer routes still drops DAW 17-20 on USB")
    func noMixerRoutesStillSentinelEncoded() {
        let tbGrid: [Int: Set<Int>] = [8: [0], 9: [1]]      // DAW 17-18 and 19-20 only
        let stored = RoutingPresetRows.encode(tbGrid, dawPairCount: 16)
        let onUSB = RoutingPresetRows.decode(stored, dawPairCount: 8).filter { !$0.value.isEmpty }
        #expect(onUSB == [:])
    }

    @Test("A ThunderBridge preset loads on USB without turning DAW 17-18 into Mixer 1")
    func thunderboltPresetOnUSB() {
        let tbGrid: [Int: Set<Int>] = [0: [1], 8: [0], 15: [15], 16: [2], 17: [3]]  // 16 pairs, mixers at 16/17
        let stored = RoutingPresetRows.encode(tbGrid, dawPairCount: 16)
        let onUSB = RoutingPresetRows.decode(stored, dawPairCount: 8)
        #expect(onUSB == [0: [1], 8: [2], 9: [3]])          // DAW 17-18 and 31-32 dropped; mixers at 8/9
        let onTB = RoutingPresetRows.decode(stored, dawPairCount: 16)
        #expect(onTB == tbGrid)
    }

    @Test("A USB preset loads on ThunderBridge with the mixers in the right rows")
    func usbPresetOnThunderbolt() {
        let usbGrid: [Int: Set<Int>] = [1: [0], 8: [4], 9: [5]]
        let stored = RoutingPresetRows.encode(usbGrid, dawPairCount: 8)
        #expect(RoutingPresetRows.decode(stored, dawPairCount: 16) == [1: [0], 16: [4], 17: [5]])
    }

    @Test("Presets saved before the sentinels still load on the grid that saved them")
    func legacyEncoding() {
        let legacyUSB: [Int: Set<Int>] = [0: [0], 8: [1], 9: [2]]
        #expect(RoutingPresetRows.decode(legacyUSB, dawPairCount: 8) == legacyUSB)
        // Rows the grid cannot show are dropped, never aliased.
        #expect(RoutingPresetRows.decode([12: [3]], dawPairCount: 8) == [:])
    }
}
