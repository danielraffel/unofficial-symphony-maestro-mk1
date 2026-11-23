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

    @Test func hardwareLines() {
        #expect(BugReportLink.hardwareText(unitA: ("8x8 AES/OPT", "16x16 Analog In"), unitB: nil, converterPorts: [[], []])
                == "Symphony I/O: slot 1 8x8 AES/OPT, slot 2 16x16 Analog In")
        #expect(BugReportLink.hardwareText(unitA: ("8MicPre", "None"), unitB: ("8x8 AES", "None"), converterPorts: [])
                == "Symphony I/O (unit A, port 1): slot 1 8MicPre, slot 2 None\nSecond Symphony I/O (unit B, port 2): slot 1 8x8 AES, slot 2 None")
        #expect(BugReportLink.hardwareText(unitA: nil, unitB: nil,
                                           converterPorts: [["AD-16X (16 inputs)", "DA-16X (16 outputs)"], []])
                == "Converters on port 1: AD-16X (16 inputs); DA-16X (16 outputs)")
        #expect(BugReportLink.hardwareText(unitA: ("8x8 AES", "None"), unitB: nil, converterPorts: [],
                                           firmware: "1.6.48", fpga: "v73")
                == "Symphony I/O: slot 1 8x8 AES, slot 2 None\nSymphony I/O firmware 1.6.48, FPGA v73")
        #expect(BugReportLink.rateText(48000) == "48 kHz")
        #expect(BugReportLink.rateText(44100) == "44.1 kHz")
        #expect(items(BugReportLink.url(version: nil, macAndOS: nil, connection: nil, doing: "Sample rate 48 kHz. DAW: "))["doing"]
                == "Sample rate 48 kHz. DAW: ")
        #expect(BugReportLink.hardwareText(unitA: nil, unitB: nil, converterPorts: [[], []]) == nil)
        let q = items(BugReportLink.url(version: nil, macAndOS: nil, connection: nil, hardware: "a\nb"))
        #expect(q["hardware"] == "a\nb")
    }

    @Test func formFieldIdsMatchTheTemplate() throws {
        // The ids above must exist in the bug form, or GitHub ignores them.
        var dir = URL(fileURLWithPath: #filePath)
        while dir.path != "/" && !FileManager.default.fileExists(atPath: dir.appendingPathComponent(".github").path) {
            dir.deleteLastPathComponent()
        }
        let template = try String(contentsOf: dir.appendingPathComponent(".github/ISSUE_TEMPLATE/bug_report.yml"), encoding: .utf8)
        for id in ["version", "mac", "connection", "hardware", "doing"] {
            #expect(template.contains("id: \(id)\n"))
        }
        // GitHub fills text fields from the link, not dropdowns.
        #expect(template.contains("type: input\n    id: connection"))
    }
}
