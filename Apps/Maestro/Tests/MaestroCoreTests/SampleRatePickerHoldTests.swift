import Testing
@testable import MaestroCore

@Suite("Sample Rate picker hold after a change")
struct SampleRatePickerHoldTests {
    @Test("Held at least 1.5 s, released on re-lock, never more than 3 s")
    func window() {
        #expect(!SampleRatePickerHold.shouldRelease(elapsed: .zero, clockLocked: true))
        #expect(!SampleRatePickerHold.shouldRelease(elapsed: .milliseconds(1499), clockLocked: true))
        #expect(SampleRatePickerHold.shouldRelease(elapsed: .milliseconds(1500), clockLocked: true))
        #expect(!SampleRatePickerHold.shouldRelease(elapsed: .milliseconds(2500), clockLocked: false))
        #expect(SampleRatePickerHold.shouldRelease(elapsed: .milliseconds(3000), clockLocked: false))
        // Shorter than the old fixed 5 s hold.
        #expect(SampleRatePickerHold.maximum < .seconds(5))
    }
}
