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
}
