import Testing
@testable import MaestroCore

@Suite("LED meter scale calibration")
struct MeterScaleTests {
    @Test(arguments: [48.0, 60.0])
    func everySegmentRoundTripsToItsDrawnCenter(range: Double) {
        let scale = MeterScale(rangeDB: range)
        // Match the actual 140-point LED ladder, including its one-point gaps.
        let segmentHeight = (140.0 - 23.0) / 24.0
        let top = segmentHeight / 2
        let bottom = 140.0 - segmentHeight / 2
        for i in 0..<24 {
            let expectedY = bottom - Double(i) * (segmentHeight + 1)
            let actualY = scale.perceptualY(db: -scale.dBForSegment(i),
                                            topCenter: top, bottomCenter: bottom)
            #expect(abs(actualY - expectedY) < 1e-10)
            #expect(scale.peakSegment(forDB: scale.dBForSegment(i)) == i)
        }
        #expect(scale.dBForSegment(0) == -range)
        #expect(scale.dBForSegment(23) == 0)
    }

    @Test(arguments: [-48.0, -41.0, -16.0, -14.0, -5.0, -4.0, 0.0])
    func reportedLevelsFallInCorrectPrintedInterval(level: Double) {
        let scale = MeterScale(rangeDB: 48)
        let i = scale.peakSegment(forDB: level)!
        #expect(scale.dBForSegment(i) <= level)
        if i < 23 { #expect(scale.dBForSegment(i + 1) > level) }
        let printedPosition = scale.position(forDB: level)
        let ledPosition = Double(23 - i) / 23
        #expect(ledPosition >= printedPosition - 1e-12)
        #expect(ledPosition - printedPosition < 1.0 / 23 + 1e-12)
    }

    @Test func silenceAndOverload() {
        let scale = MeterScale(rangeDB: 48)
        #expect(scale.peakSegment(forDB: -.infinity) == nil)
        #expect(scale.peakSegment(forDB: -60) == nil)
        #expect(scale.peakSegment(forDB: .nan) == nil)
        #expect(scale.peakSegment(forDB: 1) == 23)
        #expect(scale.position(forDB: -.infinity) == 1)
        #expect(scale.position(forDB: 1) == 0)
        #expect(scale.position(forDB: .nan) == 1)
    }
}
