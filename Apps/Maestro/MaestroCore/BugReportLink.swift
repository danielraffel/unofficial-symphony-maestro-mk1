import Foundation

/// The GitHub bug form's address with what Maestro already knows filled in.
/// GitHub fills an issue form's text fields from query items named after the
/// field ids in `.github/ISSUE_TEMPLATE/bug_report.yml` (`version`, `mac`,
/// `connection`, `hardware`, `doing`); a value left nil leaves that field for the reporter.
public enum BugReportLink {
    public static let form = "https://github.com/danielraffel/unofficial-symphony-maestro-mk1/issues/new?template=bug_report.yml"

    public static func url(version: String?, macAndOS: String?, connection: String?,
                           hardware: String? = nil, doing: String? = nil) -> URL {
        var parts = URLComponents(string: form)!
        var items = parts.queryItems ?? []
        for (name, value) in [("version", version), ("mac", macAndOS), ("connection", connection),
                              ("hardware", hardware), ("doing", doing)] {
            if let value, !value.isEmpty { items.append(URLQueryItem(name: name, value: value)) }
        }
        parts.queryItems = items
        return parts.url!
    }

    /// "Mac14,13, macOS 27.2.1 (Build 26B131)": the model identifier, then the
    /// version as About shows it.
    public static func macAndOS(model: String?, osVersion: String) -> String {
        guard let model, !model.isEmpty else { return "macOS \(osVersion)" }
        return "\(model), macOS \(osVersion)"
    }

    /// What Maestro detected, for the form's Hardware field: one line per
    /// Symphony I/O with its two module slots, and one per port with
    /// converters. Nil when nothing was detected.
    public static func hardwareText(unitA: (slot1: String, slot2: String)?,
                                    unitB: (slot1: String, slot2: String)?,
                                    converterPorts: [[String]],
                                    firmware: String? = nil, fpga: String? = nil) -> String? {
        var lines: [String] = []
        if let a = unitA {
            lines.append("Symphony I/O\(unitB == nil ? "" : " (unit A, port 1)"): slot 1 \(a.slot1), slot 2 \(a.slot2)")
        }
        if let b = unitB {
            lines.append("Second Symphony I/O (unit B, port 2): slot 1 \(b.slot1), slot 2 \(b.slot2)")
        }
        let versions = [firmware.map { "firmware \($0)" }, fpga.map { "FPGA \($0)" }].compactMap { $0 }
        if !versions.isEmpty { lines.append("Symphony I/O " + versions.joined(separator: ", ")) }
        for (port, units) in converterPorts.enumerated() where !units.isEmpty {
            lines.append("Converters on port \(port + 1): " + units.joined(separator: "; "))
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// "48 kHz", "44.1 kHz".
    public static func rateText(_ hz: Double) -> String {
        let k = hz / 1000
        return k == k.rounded() ? "\(Int(k)) kHz" : String(format: "%.1f kHz", k)
    }

    /// The Mac's model identifier, e.g. `Mac14,13`.
    public static var modelIdentifier: String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return nil }
        return String(cString: bytes)
    }
}
