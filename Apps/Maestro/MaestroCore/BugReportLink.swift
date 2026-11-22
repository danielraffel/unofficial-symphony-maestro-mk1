import Foundation

/// The GitHub bug form's address with what Maestro already knows filled in.
/// GitHub fills an issue form's text fields from query items named after the
/// field ids in `.github/ISSUE_TEMPLATE/bug_report.yml` (`version`, `mac`,
/// `connection`); a value left nil leaves that field for the reporter.
public enum BugReportLink {
    public static let form = "https://github.com/danielraffel/unofficial-symphony-maestro-mk1/issues/new?template=bug_report.yml"

    public static func url(version: String?, macAndOS: String?, connection: String?) -> URL {
        var parts = URLComponents(string: form)!
        var items = parts.queryItems ?? []
        for (name, value) in [("version", version), ("mac", macAndOS), ("connection", connection)] {
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

    /// The Mac's model identifier, e.g. `Mac14,13`.
    public static var modelIdentifier: String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return nil }
        return String(cString: bytes)
    }
}
