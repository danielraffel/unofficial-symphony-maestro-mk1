import Foundation
import Testing

/// SwiftUI stops the app (a precondition in NSViewRepresentable._makeView)
/// when a view is a class. Package 1113 crashed at launch because
/// WindowDocumentBridge was `final class …: NSObject, NSViewRepresentable`;
/// tests never draw the window, so only this source check catches it.
@Suite("SwiftUI views are value types")
struct ViewValueTypeTests {
    private static let appDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // MaestroAppTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // Apps/Maestro
        .appendingPathComponent("MaestroApp")

    @Test func noClassConformsToAViewProtocol() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.appDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        let pattern = try NSRegularExpression(
            pattern: #"^\s*(?:@\w+\s+)*(?:(?:public|internal|private|fileprivate|final)\s+)*class\s+\w+\s*:[^{]*\b(?:NSViewRepresentable|NSViewControllerRepresentable|View)\b"#,
            options: [.anchorsMatchLines])
        var offenders: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                offenders.append("\(file.lastPathComponent): \(text[Range(m.range, in: text)!].trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        #expect(offenders.isEmpty, "a class used as a SwiftUI view crashes the app: \(offenders)")
    }

    /// Device Settings is redacted while it loads, and a popover opened from
    /// a row label kept that look: the explanations were grey bars (1114).
    @Test func infoPopoversAreNeverRedacted() throws {
        for name in ["InfoLabel.swift", "LoopSyncControls.swift"] {
            let text = try String(contentsOf: Self.appDir.appendingPathComponent(name), encoding: .utf8)
            #expect(text.contains(".unredacted()"), "\(name): its popover must be .unredacted()")
        }
    }

    /// The level overlay (a HUD) is off until the user turns it on (owner, 2026-11-22).
    @Test func levelOverlayIsOffByDefault() throws {
        let settings = try String(contentsOf: Self.appDir.appendingPathComponent("SettingsViews.swift"), encoding: .utf8)
        let document = try String(contentsOf: Self.appDir.appendingPathComponent("SetupDocument.swift"), encoding: .utf8)
        #expect(settings.contains(#"@AppStorage("showLevelOverlay") private var showLevelOverlay = false"#))
        #expect(document.contains(#"forKey: "showLevelOverlay") as? Bool ?? false"#))
    }

    /// Software Return and Master are selected as -1 and -2: a bounds check of
    /// the form `i < channels.count` let them through and a group drag with
    /// everything selected crashed (2026-11-23). Index checks must reject
    /// negatives.
    @Test func mixerIndexChecksRejectNegativeSelectionIDs() throws {
        let text = try String(contentsOf: Self.appDir.appendingPathComponent("MixerViews.swift"), encoding: .utf8)
        #expect(!text.contains("guard i < editor.channels.count"))
    }

    /// The Edit menu listed Select All twice, the standard one disabled
    /// (owner, 2026-11-23). Maestro replaces the standard group with one
    /// working Select All (⌘A) and one Deselect All (⇧⌘A).
    @Test func editMenuHasOneSelectAll() throws {
        let text = try String(contentsOf: Self.appDir.appendingPathComponent("MaestroApp.swift"), encoding: .utf8)
        #expect(text.contains("CommandGroup(replacing: .pasteboard)"))
        #expect(text.components(separatedBy: #"Button("Select All")"#).count == 2)
        #expect(text.components(separatedBy: #"Button("Deselect All")"#).count == 2)
    }
}
