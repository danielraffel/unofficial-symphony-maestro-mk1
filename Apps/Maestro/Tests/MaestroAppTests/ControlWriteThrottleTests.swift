import Foundation
import Testing
@testable import MaestroApp

@Suite("Control write throttle")
@MainActor
struct ControlWriteThrottleTests {
    @Test func newestValueWinsAndLastIsSent() async {
        let throttle = await MainActor.run { ControlWriteThrottle(interval: .milliseconds(1)) }
        let values = LockedValues()
        await MainActor.run {
            throttle.submit(1, 1) { value in values.append(value) }
            throttle.submit(1, 2) { value in values.append(value) }
            throttle.submit(1, 3) { value in values.append(value) }
        }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(values.snapshot().last == 3)
        #expect(values.snapshot().count >= 1)
    }

    @Test func oneSenderPerKey() async {
        let throttle = await MainActor.run { ControlWriteThrottle(interval: .milliseconds(1)) }
        let values = LockedValues()
        await MainActor.run {
            throttle.submit(2, 1) { value in values.append(value) }
            throttle.submit(3, 4) { value in values.append(value) }
        }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(Set(values.snapshot()) == Set([1, 4]))
    }
}

private final class LockedValues: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var values: [Double] = []
    func append(_ value: Double) { lock.lock(); values.append(value); lock.unlock() }
    func snapshot() -> [Double] { lock.lock(); defer { lock.unlock() }; return values }
}
