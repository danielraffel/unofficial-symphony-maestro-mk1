import Foundation
import Testing
@testable import MaestroCore

@Suite("Diagnostics redaction")
struct DiagnosticsRedactorTests {
    private func redactor() -> DiagnosticsRedactor {
        var r = DiagnosticsRedactor()
        r.add("/Users/janedoe", as: "~")
        r.add("janedoe", as: "<user>", wholeWord: true)
        r.add("Jane Doe", as: "<full name>", wholeWord: true)
        r.add("Jane’s MacBook Pro", as: "<computer>", wholeWord: true)
        r.add("C02XK1ABJG5H", as: "<serial>")
        r.add("564D1C2B-1111-2222-3333-444455556666", as: "<hardware uuid>")
        return r
    }

    @Test("values read from the Mac are removed, the home folder before the name")
    func exactValues() {
        let text = "App path: /Users/janedoe/Applications/Maestro.app on Jane’s MacBook Pro by jane doe, serial C02XK1ABJG5H, uuid 564D1C2B-1111-2222-3333-444455556666"
        let out = redactor().redact(text)
        #expect(out == "App path: ~/Applications/Maestro.app on <computer> by <full name>, serial <serial>, uuid <hardware uuid>")
    }

    @Test("network and email addresses are removed")
    func patterns() {
        let out = redactor().redact("ip 192.168.1.20 v6 fe80::1c2b:3a4d%en0 full 2001:0db8:85a3:0000:0000:8a2e:0370:7334 mac a4:83:e7:12:34:56 mail someone@example.com")
        #expect(out == "ip <ipv4> v6 <ipv6> full <ipv6> mac <mac> mail <email>")
    }

    @Test("what we need stays: versions, times, C++ names, hex registers, device names")
    func keepsUsefulText() {
        let text = """
        Maestro: 0.9.4 (build 1050 · 7ec6a01)
        macOS: 27.2.1 (Build 26B131)
        15:30:22.123 SymphonyTB: SymphonyThunderbridge::Start GCSR=0x2db8009b rate 48000
        Driver extension: 0.11.2 (126)
        Symphony I/O : USB Audio  AppleUSBAudioEngine:Apogee:Symphony I/O : USB Audio:2100000:1,2
        """
        #expect(redactor().redact(text) == text)
    }

    @Test("short or common names are matched as whole words only")
    func wholeWordNames() {
        var r = DiagnosticsRedactor()
        r.add("dan", as: "<user>", wholeWord: true)
        r.add("audio", as: "<user>", wholeWord: true)
        r.add("/Users/dan", as: "~")
        #expect(r.redact("Redundant USB Audio device") == "Redundant USB Audio device".replacingOccurrences(of: "Audio", with: "<user>"))
        #expect(r.redact("Redundant") == "Redundant")
        #expect(r.redact("user dan opened /Users/dan/Music, dan's mac") == "user <user> opened ~/Music, <user>'s mac")
        #expect(r.redact("Danielle") == "Danielle")
    }

    @Test("too-short values are not used, so they cannot mangle the file")
    func ignoresShortValues() {
        var r = DiagnosticsRedactor()
        r.add("ab", as: "<user>")
        r.add(nil, as: "<user>")
        #expect(r.secrets.isEmpty)
        #expect(r.redact("tab label") == "tab label")
    }

    @Test("file name is dated, in local time, with no colons")
    func fileName() {
        let date = Date(timeIntervalSince1970: 1_795_000_000)
        let name = DiagnosticsRedactor.fileName(for: date, timeZone: TimeZone(identifier: "UTC")!)
        #expect(name.hasPrefix("Maestro Diagnostics 2026-"))
        #expect(name.hasSuffix(".txt"))
        #expect(!name.contains(":"))
    }
}
