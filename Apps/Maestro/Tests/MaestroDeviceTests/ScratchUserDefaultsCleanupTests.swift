import Foundation
import Testing

@Test("device scratch defaults cleanup removes its persistent plist")
func deviceScratchDefaultsCleanupRemovesPersistentPlist() {
    let suite = "maestro.tests.cleanup.\(UUID().uuidString)"
    let preferences = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Preferences", isDirectory: true)
    let plist = preferences.appendingPathComponent("\(suite).plist")

    let defaults = ScratchUserDefaults(suiteName: suite)!
    defaults.set("value", forKey: "key")
    defaults.cleanup()

    #expect(!FileManager.default.fileExists(atPath: plist.path))
}
