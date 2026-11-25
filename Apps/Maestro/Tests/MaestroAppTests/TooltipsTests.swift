import Foundation
import Testing
@testable import MaestroApp

@Suite("Tooltips")
@MainActor
struct TooltipsTests {
    @Test("tooltips are enabled by default and follow the preference")
    func preferenceControlsHelp() {
        let defaults = ScratchUserDefaults(suiteName: "TooltipsTests-\(UUID().uuidString)")!
        let byDefault = MaestroHelpModifier.isEnabled(defaults: defaults)
        #expect(byDefault)
        defaults.set(false, forKey: MaestroHelpModifier.preferenceKey)
        let off = MaestroHelpModifier.isEnabled(defaults: defaults)
        #expect(!off)
        defaults.set(true, forKey: MaestroHelpModifier.preferenceKey)
        let on = MaestroHelpModifier.isEnabled(defaults: defaults)
        #expect(on)
    }

    @Test("all app help text goes through the shared modifier")
    func noRawHelpCallsRemain() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let appRoot = testFile
            .deletingLastPathComponent()   // MaestroAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Apps/Maestro
            .appendingPathComponent("MaestroApp")
        let files = try FileManager.default.contentsOfDirectory(at: appRoot,
                                                                  includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "Tooltips.swift" }
        #expect(files.count > 10)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            #expect(!source.contains(".help("), "raw help call in \(file.lastPathComponent)")
        }
    }
}
