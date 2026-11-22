import Testing
@testable import MaestroCore

@Suite("ThunderBridge unit meter gating and pacing")
struct MeterPollPacingTests {
    @Test("the 64-byte unit reply is gated by driver build")
    func gate() {
        #expect(!UnitOutputMeters.driverSupports(.build(143)))
        #expect(!UnitOutputMeters.driverSupports(nil))
        #expect(UnitOutputMeters.driverSupports(.build(144)))
    }

    @Test("next read uses the later timing bound")
    func pacing() {
        #expect(abs(MeterPollPacing.nextStart(now: 10, previousStart: 9.95, previousEnd: 10, backoffUntil: 0) - 10.2) < 0.000001)
        #expect(MeterPollPacing.nextStart(now: 10, previousStart: 9.95, previousEnd: 10.01, backoffUntil: 11) == 11)
        #expect(MeterPollPacing.backoff(consecutiveFailures: 1) == 0)
        #expect(MeterPollPacing.backoff(consecutiveFailures: 2) == 2)
        #expect(MeterPollPacing.backoff(consecutiveFailures: 5) == 16)
        #expect(MeterPollPacing.backoff(consecutiveFailures: 10) == 30)
    }
}
