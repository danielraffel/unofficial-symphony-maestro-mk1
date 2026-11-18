import Foundation
import Testing
@testable import MaestroApp

/// What the report intake requires (pulp-diagnostickit server/cloudflare
/// src/validate.ts): a ZIP starting "PK\x03\x04" that names
/// diagnostic_report.md and findings.json, and a summary tagged
/// diagnostickit.findings.v1.
@Suite("Diagnostics sending")
struct DiagnosticsSenderTests {
    @Test("the note carries the description, issue, contact and version, unredacted")
    func messageText() {
        let m = DiagnosticsSender.Message(note: "  Logic froze on play  ", issue: "#28", contact: "a@b.example",
                                          version: "0.9.5", channel: "Beta")
        #expect(m.text.hasPrefix("Not working:\nLogic froze on play\n"))
        #expect(m.text.contains("GitHub issue: #28"))
        #expect(m.text.contains("Reply to: a@b.example"))
        #expect(m.text.contains("Maestro 0.9.5 (Beta)"))
        var full = m
        full.working = "USB is fine"
        full.doing = "recording vocals at 48k"
        full.connections = ["USB", "PCIe card"]
        full.symphony = "Two"
        full.cards = ["8x8 AES", "16x16 Analog"]
        full.converters = ["AD-16X", "DA-16X"]
        full.hardware = "Sonnet Echo chassis"
        #expect(full.text.contains("Not working:\nLogic froze on play\n\nWorking:\nUSB is fine\n\nWhat they were doing:\nrecording vocals at 48k"))
        #expect(full.text.contains("  Connection: USB, PCIe card"))
        #expect(full.text.contains("  Symphony I/O: Two"))
        #expect(full.text.contains("  Symphony I/O cards: 8x8 AES, 16x16 Analog"))
        #expect(full.text.contains("  Converters: AD-16X, DA-16X"))
        #expect(full.text.contains("  Other: Sonnet Echo chassis"))
        // No cards ticked: no cards line.
        #expect(!DiagnosticsSender.Message(symphony: "None", converters: ["DA-16X"]).text.contains("Symphony I/O cards"))
        let onlyDoing = DiagnosticsSender.Message(doing: "mixing").text
        #expect(onlyDoing.hasPrefix("What they were doing:\nmixing"))
        #expect(!onlyDoing.contains("(No description.)"))
        let empty = DiagnosticsSender.Message().text
        #expect(empty.contains("(No description.)"))
        #expect(empty.contains("Connection: not given"))
        #expect(empty.contains("Symphony I/O: not given"))
        #expect(empty.contains("Converters: none ticked"))
        #expect(empty.contains("Reply to: (not given)"))
        #expect(!empty.contains("GitHub issue"))
    }

    @Test("the summary has the schema tag the intake checks, and no findings")
    func summary() throws {
        let object = try JSONSerialization.jsonObject(with: DiagnosticsSender.summary(version: "0.9.5")) as? [String: Any]
        #expect(object?["schema"] as? String == "diagnostickit.findings.v1")
        #expect((object?["findings"] as? [Any])?.isEmpty == true)
    }

    @Test("the archive is a ZIP holding both files the intake requires")
    func archive() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dst-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let report = dir.appendingPathComponent("Maestro Diagnostics 2026-11-17 15-30.txt")
        try Data("== Checks ==\nok\n".utf8).write(to: report)

        let (zip, folder) = try DiagnosticsSender.makeArchive(
            report: report, message: .init(note: "test"), summary: DiagnosticsSender.summary(version: "0"))
        defer { try? FileManager.default.removeItem(at: folder) }
        let bytes = try Data(contentsOf: zip)
        #expect(Array(bytes.prefix(4)) == [0x50, 0x4B, 0x03, 0x04])
        let names = String(decoding: bytes, as: UTF8.self)
        #expect(names.contains("diagnostic_report.md"))
        #expect(names.contains("findings.json"))
        #expect(zip.lastPathComponent == "Maestro Diagnostics 2026-11-17 15-30.zip")
    }

    @Test("the multipart body has the four fields the intake reads")
    func body() {
        let body = String(decoding: DiagnosticsSender.body(
            boundary: "B", summary: Data("{}".utf8), note: "n", archiveName: "a.zip", archive: Data([1, 2])), as: UTF8.self)
        for name in ["product", "summary", "note"] { #expect(body.contains("name=\"\(name)\"")) }
        #expect(body.contains("name=\"archive\"; filename=\"a.zip\""))
        #expect(body.contains("Maestro"))
        #expect(body.hasSuffix("--B--\r\n"))
    }

    @Test("unchanged meter readings are left out, per group, and counted")
    func meterDumps() {
        let log = """
        1.0 [proxy] METERDUMP grp=0: [8]=1
        1.1 [proxy] METERDUMP grp=1: [2]=5
        2.0 [proxy] METERDUMP grp=0: [8]=1
        2.1 [proxy] METERDUMP grp=1: [2]=5
        2.5 [proxy] reconnect
        3.0 [proxy] METERDUMP grp=0: [8]=9
        """
        let out = DiagnosticsRecorder.dropRepeatedMeterDumps(log)
        #expect(out.contains("1.0 [proxy] METERDUMP grp=0"))
        #expect(out.contains("1.1 [proxy] METERDUMP grp=1"))
        #expect(!out.contains("2.0 [proxy]"))
        #expect(!out.contains("2.1 [proxy]"))
        #expect(out.contains("2.5 [proxy] reconnect"))
        #expect(out.contains("3.0 [proxy] METERDUMP grp=0: [8]=9"))
        #expect(out.contains("(2 unchanged meter readings left out)"))
        #expect(DiagnosticsRecorder.dropRepeatedMeterDumps("a\nb") == "a\nb")
    }

    @Test("the Thunderbolt section names devices but carries no identifiers")
    func thunderbolt() {
        let block = DiagnosticsRecorder.thunderboltBlock()
        #expect(block.hasPrefix("Thunderbolt:"))
        #expect(!block.contains("UID"))
        #expect(!block.contains("UUID"))
        #expect(!block.contains("Route String"))
    }

    @Test("the log from before the session is read with the same filter")
    func systemLogBefore() {
        let text = DiagnosticsRecorder.systemLog(minutesBefore: 1, until: Date())
        #expect(!text.contains("took longer than"))
        #expect(!text.contains("could not run"))
        #expect(!text.localizedCaseInsensitiveContains("invalid"))
    }

    @Test("only connection trouble, rate limits and server errors are retried")
    func retries() {
        #expect(DiagnosticsSender.isTransient(DiagnosticsSender.Failure.rejected(429, "")))
        #expect(DiagnosticsSender.isTransient(DiagnosticsSender.Failure.rejected(502, "")))
        #expect(!DiagnosticsSender.isTransient(DiagnosticsSender.Failure.rejected(401, "")))
        #expect(!DiagnosticsSender.isTransient(DiagnosticsSender.Failure.rejected(400, "")))
        #expect(DiagnosticsSender.isTransient(URLError(.timedOut)))
        #expect(DiagnosticsSender.userMessage(for: DiagnosticsSender.Failure.rejected(401, "")).contains("update Maestro"))
    }
}

/// At 176.4/192 kHz optical slots carry no audio, only data that read as full
/// scale on every meter (2026-11-18). An "N.A." pair shows silence.
@Suite("Not-applicable meters")
struct NotApplicableMeterTests {
    @Test("an N.A. pair is silent; a named pair is not")
    func naPairIsSilent() {
        #expect(ADATStereoPairView(label: "N.A.", leftLevel: 0, rightLevel: 0).isNotApplicable)
        #expect(!ADATStereoPairView(label: "ADAT 1/2", leftLevel: 0, rightLevel: 0).isNotApplicable)
        #expect(ADATStereoPairView.silent == -60)
    }
}
