import Foundation

/// Removes personal details from a diagnostics file before it is saved.
///
/// Two kinds of removal:
/// - exact values read from this Mac (computer name, account name, full name,
///   home folder, serial number, hardware UUID), replaced wherever they appear;
/// - patterns: IPv4, IPv6 and MAC addresses, and email addresses.
///
/// Best effort, as the app tells the user: anything not covered here stays.
public struct DiagnosticsRedactor: Sendable {
    /// (value, replacement, whole word), applied longest value first so a home
    /// folder path is replaced before the account name inside it.
    public private(set) var secrets: [(String, String, Bool)] = []

    public init() {}

    /// Add a value to remove. Values shorter than three characters are ignored:
    /// replacing them would mangle unrelated text. `wholeWord` is for names
    /// (account, full name, computer name), so an account called "audio" does
    /// not turn "USB Audio" into "USB <user>"; paths, serial numbers and UUIDs
    /// are replaced wherever they appear.
    public mutating func add(_ value: String?, as replacement: String, wholeWord: Bool = false) {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.count >= 3 else { return }
        secrets.append((value, replacement, wholeWord))
        secrets.sort { $0.0.count > $1.0.count }
    }

    private static let patterns: [(NSRegularExpression, String)] = {
        let specs: [(String, String)] = [
            // Email first, so its domain is not read as something else.
            (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "<email>"),
            // MAC address: six hex pairs.
            (#"(?<![\w:])(?:[0-9A-Fa-f]{2}[\-\:]){5}[0-9A-Fa-f]{2}(?![\w:])"#, "<mac>"),
            // IPv6, full form.
            (#"(?<![\w:])(?:[0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}(?![\w:])"#, "<ipv6>"),
            // IPv6 with "::". The look-behind keeps C++ names such as
            // "SymphonyThunderbridge::Start" intact.
            (#"(?<![\w:])(?:[0-9A-Fa-f]{1,4}:){1,6}:(?:[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4})*)?(?:%\w+)?(?![\w:])"#, "<ipv6>"),
            // IPv4: four numbers 0-255.
            (#"(?<![\d.])(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)(?![\d.])"#, "<ipv4>"),
        ]
        return specs.map { (try! NSRegularExpression(pattern: $0.0), $0.1) }
    }()

    public func redact(_ text: String) -> String {
        var out = text
        for (value, replacement, wholeWord) in secrets {
            if wholeWord {
                // A name counts only where it is not part of a longer word.
                let pattern = "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: value)
                    + "(?![\\p{L}\\p{N}_])"
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
                out = regex.stringByReplacingMatches(
                    in: out, range: NSRange(out.startIndex..., in: out),
                    withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
            } else {
                out = out.replacingOccurrences(of: value, with: replacement, options: [.caseInsensitive])
            }
        }
        for (regex, replacement) in Self.patterns {
            let range = NSRange(out.startIndex..., in: out)
            out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: replacement)
        }
        return out
    }

    /// "Maestro Diagnostics 2026-11-17 15-30.txt", in local time. No colons:
    /// Finder shows them as slashes.
    public static func fileName(for date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH-mm"
        return "Maestro Diagnostics \(f.string(from: date)).txt"
    }
}
