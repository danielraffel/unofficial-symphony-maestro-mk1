import Foundation

/// A per-test defaults suite whose persistent plist is removed when the suite is released.
final class ScratchUserDefaults: UserDefaults {
    private let scratchSuiteName: String

    init?(suiteName: String) {
        let name = suiteName.hasPrefix("maestro.tests.") ? suiteName : "maestro.tests.\(suiteName)"
        scratchSuiteName = name
        super.init(suiteName: name)
    }

    deinit {
        cleanup()
    }

    func cleanup() {
        removePersistentDomain(forName: scratchSuiteName)
        _ = CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        guard scratchSuiteName.hasPrefix("maestro.tests.") else { return }
        let preferences = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Preferences", isDirectory: true)
        try? FileManager.default.removeItem(at: preferences.appendingPathComponent("\(scratchSuiteName).plist"))
    }
}


import Testing

@Test("scratch defaults remove their plist during cleanup")
func scratchDefaultsRemoveTheirPlist() {
    let suite = "maestro.tests.cleanup.\(UUID().uuidString)"
    let preferences = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Preferences", isDirectory: true)
    let plist = preferences.appendingPathComponent("\(suite).plist")

    do {
        let defaults = ScratchUserDefaults(suiteName: suite)!
        defaults.set("value", forKey: "key")
        defaults.cleanup()
    }

    #expect(!FileManager.default.fileExists(atPath: plist.path))
}
