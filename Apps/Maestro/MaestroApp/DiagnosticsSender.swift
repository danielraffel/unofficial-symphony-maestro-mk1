import Foundation
import MaestroCore

/// Sends a saved diagnostics file privately to the developer, through the
/// DiagnosticKit report intake (a Cloudflare Worker that emails it, attached,
/// to a fixed inbox; see github.com/danielraffel/pulp-diagnostickit,
/// server/cloudflare). Nothing goes to GitHub.
///
/// The intake accepts only a DiagnosticKit-shaped ZIP: `diagnostic_report.md`
/// plus `findings.json` carrying the `diagnostickit.findings.v1` schema tag,
/// with the same JSON sent as the `summary` field.
///
/// The endpoint and upload key are written into the app's Info.plist at
/// package time (Installer/build-installer.sh) and never committed. A build
/// without them cannot send, and the user is told to email the file instead.
/// The key ships inside every copy, so it is recoverable by design: the
/// intake's destination is fixed server-side, so it can only ever mail us.
struct DiagnosticsSender: Sendable {
    let endpoint: URL
    let key: String

    /// The configured sender, or nil when this build cannot send.
    static var configured: DiagnosticsSender? {
        let info = Bundle.main.infoDictionary ?? [:]
        let env = ProcessInfo.processInfo.environment
        // Info.plist in packaged builds; the environment for local test runs.
        let endpoint = (info["MaestroDiagnosticsEndpoint"] as? String) ?? env["DIAGNOSTICKIT_SEND_ENDPOINT"] ?? ""
        let key = (info["MaestroDiagnosticsKey"] as? String) ?? env["DIAGNOSTICKIT_SEND_KEY"] ?? ""
        guard !key.isEmpty, let url = URL(string: endpoint), url.scheme == "https" else { return nil }
        return DiagnosticsSender(endpoint: url, key: key)
    }

    /// What the person sending adds. All optional.
    struct Message: Sendable {
        /// What isn't working.
        var note = ""
        /// What is working.
        var working = ""
        /// What they were doing when it happened (DAW, sample rate, ...).
        var doing = ""
        /// What the person says they have, from the known hardware. Compared
        /// with what the file shows Maestro detected: what is missing from the
        /// file is often the problem, so the file alone cannot say.
        var connections: [String] = []
        /// "None", "One", "Two", "Not sure", or empty when not answered.
        var symphony = ""
        /// The cards in their Symphony I/O units (any of them).
        var cards: [String] = []
        /// External converter models they have.
        var converters: [String] = []
        /// Anything else about the setup (chassis, other gear), in their words.
        var hardware = ""
        var issue = ""
        var contact = ""
        var version = ""
        var channel = ""

        /// The text the intake puts at the top of the email. Kept out of the
        /// redactor on purpose: the person typed their email to be reached.
        var text: String {
            func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
            var blocks: [String] = []
            if !clean(note).isEmpty { blocks.append("Not working:\n\(clean(note))") }
            if !clean(working).isEmpty { blocks.append("Working:\n\(clean(working))") }
            if !clean(doing).isEmpty { blocks.append("What they were doing:\n\(clean(doing))") }
            var lines = [blocks.isEmpty ? "(No description.)" : blocks.joined(separator: "\n\n"), ""]
            func list(_ items: [String]) -> String { items.isEmpty ? "not given" : items.joined(separator: ", ") }
            lines.append("Their setup (as they described it; compare with what the file shows was detected):")
            lines.append("  Connection: \(list(connections))")
            lines.append("  Symphony I/O: \(symphony.isEmpty ? "not given" : symphony)")
            if !cards.isEmpty { lines.append("  Symphony I/O cards: \(list(cards))") }
            lines.append("  Converters: \(converters.isEmpty ? "none ticked" : converters.joined(separator: ", "))")
            if !clean(hardware).isEmpty { lines.append("  Other: \(clean(hardware))") }
            let i = issue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !i.isEmpty { lines.append("GitHub issue: \(i)") }
            let c = contact.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("Reply to: \(c.isEmpty ? "(not given)" : c)")
            lines.append("Maestro \(version)\(channel.isEmpty ? "" : " (\(channel))")")
            return lines.joined(separator: "\n")
        }
    }

    enum Failure: Error {
        case rejected(Int, String)
        case unreadableReply
        case packaging(String)
    }

    // MARK: - Packaging

    /// findings.json. Maestro's file has no automatic verdicts, so the list
    /// is empty; the intake then titles the email "nothing found", which here
    /// means "read the attachment".
    static func summary(version: String) -> Data {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        let object: [String: Any] = [
            "schema": "diagnostickit.findings.v1",
            "product": "Maestro",
            "macos": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "architecture": arch,
            "diagnostics_version": "Maestro \(version)",
            "findings": [] as [Any],
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
    }

    /// Builds the ZIP next to nothing the user sees, in a temporary folder.
    /// Returns the ZIP's URL; the caller removes `folder` when done.
    static func makeArchive(report: URL, message: Message, summary: Data) throws -> (zip: URL, folder: URL) {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("MaestroDiagnosticsSend-\(UUID().uuidString)", isDirectory: true)
        let base = report.deletingPathExtension().lastPathComponent
        let inner = folder.appendingPathComponent(base, isDirectory: true)
        try fm.createDirectory(at: inner, withIntermediateDirectories: true)
        let body = try String(contentsOf: report, encoding: .utf8)
        let md = "# From the person sending\n\n\(message.text)\n\n# Diagnostics\n\n```\n\(body)\n```\n"
        try Data(md.utf8).write(to: inner.appendingPathComponent("diagnostic_report.md"))
        try summary.write(to: inner.appendingPathComponent("findings.json"))
        let zip = folder.appendingPathComponent("\(base).zip")
        let out = DiagnosticsRecorder.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", inner.path, zip.path], timeout: 60)
        guard fm.fileExists(atPath: zip.path) else { throw Failure.packaging(out) }
        return (zip, folder)
    }

    // MARK: - Sending

    static func body(boundary: String, summary: Data, note: String, archiveName: String, archive: Data) -> Data {
        var body = Data()
        func field(_ name: String, _ value: Data, filename: String? = nil, type: String = "text/plain; charset=utf-8") {
            body.append(Data("--\(boundary)\r\n".utf8))
            let disposition = filename.map { "form-data; name=\"\(name)\"; filename=\"\($0.replacingOccurrences(of: "\"", with: ""))\"" }
                ?? "form-data; name=\"\(name)\""
            body.append(Data("Content-Disposition: \(disposition)\r\nContent-Type: \(type)\r\n\r\n".utf8))
            body.append(value)
            body.append(Data("\r\n".utf8))
        }
        field("product", Data("Maestro".utf8))
        field("summary", summary, type: "application/json")
        field("note", Data(note.utf8))
        field("archive", archive, filename: archiveName, type: "application/zip")
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }

    /// Sends the saved file; returns the intake's short reference.
    /// Retries once after a pause on failures that pass.
    func send(report: URL, message: Message) async throws -> String {
        let summary = Self.summary(version: message.version)
        let (zip, folder) = try Self.makeArchive(report: report, message: message, summary: summary)
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = try Data(contentsOf: zip)
        do {
            return try await post(summary: summary, note: message.text, archiveName: zip.lastPathComponent, archive: archive)
        } catch where Self.isTransient(error) {
            try await Task.sleep(for: .seconds(3))
            return try await post(summary: summary, note: message.text, archiveName: zip.lastPathComponent, archive: archive)
        }
    }

    private func post(summary: Data, note: String, archiveName: String, archive: Data) async throws -> String {
        let boundary = "maestro-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let payload = Self.body(boundary: boundary, summary: summary, note: note, archiveName: archiveName, archive: archive)
        let (data, response) = try await URLSession.shared.upload(for: request, from: payload)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200 else { throw Failure.rejected(status, reply?["error"] as? String ?? "") }
        guard let reference = reply?["reference"] as? String else { throw Failure.unreadableReply }
        return reference
    }

    static func isTransient(_ error: Error) -> Bool {
        if let failure = error as? Failure, case .rejected(let status, _) = failure {
            return status == 429 || status >= 500 || status == 0
        }
        if let url = error as? URLError {
            return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                    .cannotFindHost, .dnsLookupFailed].contains(url.code)
        }
        return false
    }

    /// What to tell the user, in plain words.
    static func userMessage(for error: Error) -> String {
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "This Mac doesn't seem to be connected to the internet."
            case .timedOut:
                return "Sending took too long; the connection may be slow."
            case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost:
                return "The diagnostics server couldn't be reached."
            default:
                return "The diagnostics couldn't be sent (\(url.localizedDescription))."
            }
        }
        if let failure = error as? Failure {
            switch failure {
            case .rejected(401, _): return "This version of Maestro can't send diagnostics any more. Please update Maestro, or email the file instead."
            case .rejected(413, _): return "The diagnostics file is too large to send. Please email it instead."
            case .rejected(429, _): return "Too many reports were sent from this network recently. Try again in a minute."
            case .rejected(let status, let reason):
                return "The diagnostics server refused the file (\(status)\(reason.isEmpty ? "" : ": \(reason)"))."
            case .unreadableReply: return "The diagnostics server's reply couldn't be read."
            case .packaging: return "Maestro couldn't prepare the file for sending."
            }
        }
        return "The diagnostics couldn't be sent (\(error.localizedDescription))."
    }
}
