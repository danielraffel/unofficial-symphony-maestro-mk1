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
        removePersistentDomain(forName: scratchSuiteName)
        guard scratchSuiteName.hasPrefix("maestro.tests.") else { return }
        let preferences = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Preferences", isDirectory: true)
        try? FileManager.default.removeItem(at: preferences.appendingPathComponent("\(scratchSuiteName).plist"))
    }
}

