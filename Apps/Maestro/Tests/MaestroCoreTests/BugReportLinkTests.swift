import Foundation
import Testing
@testable import MaestroCore

struct BugReportLinkTests {
    private func items(_ url: URL) -> [String: String] {
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: q.map { ($0.name, $0.value ?? "") })
    }

    @Test func fillsTheFormFieldsByTheirIds() {
        let url = BugReportLink.url(version: "0.9.23 (build 1112 · 5a04aed)",
                                    macAndOS: "Mac14,13, macOS 27.2.1 (Build 26B131)",
                                    connection: "ThunderBridge")
        let q = items(url)
        #expect(q["template"] == "bug_report.yml")
        #expect(q["version"] == "0.9.23 (build 1112 · 5a04aed)")
        #expect(q["mac"] == "Mac14,13, macOS 27.2.1 (Build 26B131)")
        #expect(q["connection"] == "ThunderBridge")
        #expect(url.host == "github.com")
        #expect(url.path == "/danielraffel/unofficial-symphony-maestro-mk1/issues/new")
    }

    @Test func leavesUnknownFieldsEmpty() {
        let q = items(BugReportLink.url(version: "0.9.23", macAndOS: nil, connection: nil))
        #expect(q["connection"] == nil)
        #expect(q["mac"] == nil)
        #expect(q["version"] == "0.9.23")
    }

    @Test func macLineWithAndWithoutModel() {
        #expect(BugReportLink.macAndOS(model: "Mac14,13", osVersion: "27.2.1 (Build 26B131)")
                == "Mac14,13, macOS 27.2.1 (Build 26B131)")
        #expect(BugReportLink.macAndOS(model: nil, osVersion: "27.2.1") == "macOS 27.2.1")
    }

    @Test func formFieldIdsMatchTheTemplate() throws {
        // The ids above must exist in the bug form, or GitHub ignores them.
        var dir = URL(fileURLWithPath: #filePath)
        while dir.path != "/" && !FileManager.default.fileExists(atPath: dir.appendingPathComponent(".github").path) {
            dir.deleteLastPathComponent()
        }
        let template = try String(contentsOf: dir.appendingPathComponent(".github/ISSUE_TEMPLATE/bug_report.yml"), encoding: .utf8)
        for id in ["version", "mac", "connection"] {
            #expect(template.contains("id: \(id)\n"))
        }
        // GitHub fills text fields from the link, not dropdowns.
        #expect(template.contains("type: input\n    id: connection"))
    }
}
