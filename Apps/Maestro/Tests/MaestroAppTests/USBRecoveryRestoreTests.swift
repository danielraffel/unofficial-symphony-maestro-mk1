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

    @Test("no setting makes the restore optional")
    func alwaysRestores() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("MaestroApp/AppState.swift"), encoding: .utf8)
        #expect(!source.contains("forKey: \"autoRecoverMixerState\""))
        #expect(source.contains("await self.restoreUSBMixerAfterRecovery(xpcDev, helperMixer: recoveryMixer)"))
        // The removed Input Monitoring setting leaves nothing behind in the app.
        for file in ["AppState.swift", "AppState+IdentityPersistence.swift", "MixerViews.swift",
                     "SettingsViews.swift", "AppState+TwoUnitReplay.swift", "ThunderboltPresetBundle.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent("MaestroApp/\(file)"), encoding: .utf8)
            #expect(!text.contains("routingMode"), "\(file) still reads the removed setting")
            #expect(!text.contains("Direct Monitor") && !text.contains("Input Monitoring"), "\(file)")
        }
    }
}
