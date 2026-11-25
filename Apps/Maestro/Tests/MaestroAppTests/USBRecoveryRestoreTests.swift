import Foundation
import Testing
@testable import MaestroApp

@Suite("USB recovery restore")
struct USBRecoveryRestoreTests {
    @Test("restore is gated by the 5 s debounce only")
    func debounceOnly() {
        let now = Date()
        #expect(AppState.usbRecoveryRestoreDue(lastRecovery: now.addingTimeInterval(-6), now: now))
        #expect(AppState.usbRecoveryRestoreDue(lastRecovery: .distantPast, now: now))
        #expect(!AppState.usbRecoveryRestoreDue(lastRecovery: now.addingTimeInterval(-4), now: now))
    }
    // That no setting makes the restore optional, and the order it writes in,
    // are tested against a recording unit in USBRestoreOrderTests.
}
