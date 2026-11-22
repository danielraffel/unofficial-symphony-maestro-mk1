import Foundation
import Testing
@testable import MaestroCore

@Suite("Output Routing grid drawn from what was saved")
struct SavedOutputRoutesTests {
    /// 16 software pairs, then Mixer 1 (row 16) and Mixer 2 (row 17); four output pairs.
    private let base: [Int: Set<Int>] = [0: [0], 1: [1], 2: [2], 3: [3]]

    @Test("a saved mixer row is drawn, and its output leaves the default software pair")
    func mixerRow() {
        let grid = SavedOutputRoutes.overlay(saved: [16: [0]], onto: base, rowCount: 18, columnCount: 4)
        #expect(grid[16] == [0])
        #expect(grid[0] == nil)
        #expect(grid[1] == [1] && grid[2] == [2] && grid[3] == [3])
    }

    @Test("a saved software row moves its output; Mixer 2 as well")
    func softwareAndSecondMixer() {
        let grid = SavedOutputRoutes.overlay(saved: [1: [0], 17: [3]], onto: base, rowCount: 18, columnCount: 4)
        #expect(grid[1] == [0])
        #expect(grid[0] == nil)
        #expect(grid[17] == [3] && grid[3] == nil)
    }

    @Test("rows and columns outside the grid are ignored; an empty saved row changes nothing")
    func outsideTheGrid() {
        let grid = SavedOutputRoutes.overlay(saved: [18: [0], 2: [9], 3: []], onto: base, rowCount: 18, columnCount: 4)
        #expect(grid == base)
    }
}
